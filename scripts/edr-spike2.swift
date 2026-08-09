// Calibration spike 2 for Extra Brightness. Run: swift scripts/edr-spike2.swift
// Finds the multiply factor at which whites start clipping on this panel, and
// whether the reported EDR headroom tracks reality while the overlay is active.
// Protocol: 8 steps, one BEEP per step, 3s each, factor shown per step in the
// terminal. The observer counts beeps and notes after which beep whites start
// crushing. A final DOUBLE beep holds factor 1.0 (identity) for 5s to check
// that an identity overlay is truly invisible.
import AppKit
import Metal

let steps: [Double] = [1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.8, 2.0]
let stepSeconds = 3.0

// Target the BUILT-IN panel explicitly: NSScreen.main follows keyboard focus
// and could pick a non-HDR external, which would invalidate the measurement.
func builtinScreen() -> NSScreen? {
    NSScreen.screens.first { screen in
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}
guard let screen = builtinScreen() else { print("no built-in screen found"); exit(1) }
func edrNow() -> (current: Double, potential: Double) {
    let s = builtinScreen() ?? screen
    return (Double(s.maximumExtendedDynamicRangeColorComponentValue),
            Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                      backing: .buffered, defer: false, screen: screen)
window.isReleasedWhenClosed = false
window.backgroundColor = .clear
window.isOpaque = false
window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
window.hasShadow = false

let metalLayer = CAMetalLayer()
let device = MTLCreateSystemDefaultDevice()!
metalLayer.device = device
metalLayer.pixelFormat = .rgba16Float
metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
metalLayer.wantsExtendedDynamicRangeContent = true
metalLayer.isOpaque = false
metalLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
metalLayer.drawableSize = CGSize(width: 8, height: 8)
metalLayer.compositingFilter = "multiplyBlendMode"

let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
host.wantsLayer = true
host.layer = metalLayer
window.contentView = host

let queue = device.makeCommandQueue()!
func render(_ factor: Double) {
    guard let drawable = metalLayer.nextDrawable() else { print("no drawable"); return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: factor, green: factor, blue: factor, alpha: 1.0)
    let cmd = queue.makeCommandBuffer()!
    cmd.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
    cmd.present(drawable)
    cmd.commit()
}

let e0 = edrNow()
print("Before overlay: currentEDR=\(e0.current) potentialEDR=\(e0.potential)")
print("Set the panel to FULL brightness before this run. \(steps.count) beeps, one per step, \(Int(stepSeconds))s apart.")

render(1.0)
window.orderFrontRegardless()

var stepIndex = -1
Timer.scheduledTimer(withTimeInterval: stepSeconds, repeats: true) { timer in
    stepIndex += 1
    if stepIndex < steps.count {
        let f = steps[stepIndex]
        NSSound.beep()
        render(f)
        let e = edrNow()
        print("BEEP \(stepIndex + 1): factor \(f)  currentEDR=\(e.current)  potentialEDR=\(e.potential)")
    } else if stepIndex == steps.count {
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSSound.beep() }
        render(1.0)
        let e = edrNow()
        print("DOUBLE BEEP: identity hold (factor 1.0), overlay still up. currentEDR=\(e.current)")
        print("Watch: screen should look completely normal for these 5 seconds.")
        timer.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            window.close()
            let eEnd = edrNow()
            print("Overlay closed. currentEDR=\(eEnd.current)")
            print("Done. Report: after which BEEP did whites start crushing, and did the identity hold look normal?")
            app.terminate(nil)
        }
    }
}
// Mid-step headroom samples show how fast macOS ramps and whether reads move.
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    let e = edrNow()
    print("  sample: currentEDR=\(e.current)")
}
app.run()
