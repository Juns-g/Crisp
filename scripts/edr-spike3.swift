// Calibration spike 3: find the true usable multiply-factor ceiling with the
// FIXED overlay technique (continuous 5Hz rendering, "multiply" filter,
// shielding level), which spike 2 lacked; its readings were contaminated by
// WindowServer dropping the filter on idle windows. Run: swift scripts/edr-spike3.swift
// One BEEP per step, 4s each. Observer notes after which beep brightness stops
// increasing or whites start clipping. DOUBLE beep = done, overlay closes.
import AppKit
import Metal

let steps: [Double] = [1.6, 2.0, 2.4, 2.8, 3.2, 3.6, 4.0]
let stepSeconds = 4.0

func builtinScreen() -> NSScreen? {
    NSScreen.screens.first { screen in
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return false }
        return CGDisplayIsBuiltin(id) != 0
    }
}
guard let screen = builtinScreen() else { print("no built-in screen found"); exit(1) }
func edrNow() -> Double {
    Double((builtinScreen() ?? screen).maximumExtendedDynamicRangeColorComponentValue)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                      backing: .buffered, defer: false, screen: screen)
window.isReleasedWhenClosed = false
window.backgroundColor = .clear
window.isOpaque = false
window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
window.ignoresMouseEvents = true
window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle,
                             .canJoinAllApplications, .fullScreenAuxiliary]
window.hasShadow = false

let metalLayer = CAMetalLayer()
let device = MTLCreateSystemDefaultDevice()!
metalLayer.device = device
metalLayer.pixelFormat = .rgba16Float
metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
metalLayer.wantsExtendedDynamicRangeContent = true
metalLayer.isOpaque = false
metalLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
metalLayer.drawableSize = CGSize(width: 1, height: 1)
metalLayer.compositingFilter = "multiply"

let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
host.wantsLayer = true
host.layer = metalLayer
window.contentView = host

let queue = device.makeCommandQueue()!
var currentFactor = 1.0
func render() {
    guard let drawable = metalLayer.nextDrawable() else { return }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: currentFactor, green: currentFactor,
                                                        blue: currentFactor, alpha: 1.0)
    let cmd = queue.makeCommandBuffer()!
    cmd.makeRenderCommandEncoder(descriptor: pass)!.endEncoding()
    cmd.present(drawable)
    cmd.commit()
}

print("Before overlay: currentEDR=\(edrNow())")
print("\(steps.count) beeps, \(Int(stepSeconds))s apart. Note the beep number where it stops getting brighter or whites clip.")
render()
window.orderFrontRegardless()

// The fix under test: keep the compositor honoring the filter by presenting
// a frame 5x per second for the overlay's whole life.
Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in render() }

var stepIndex = -1
Timer.scheduledTimer(withTimeInterval: stepSeconds, repeats: true) { timer in
    stepIndex += 1
    if stepIndex < steps.count {
        currentFactor = steps[stepIndex]
        NSSound.beep()
        print("BEEP \(stepIndex + 1): factor \(currentFactor)  currentEDR=\(edrNow())")
    } else {
        timer.invalidate()
        NSSound.beep()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSSound.beep() }
        currentFactor = 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            window.close()
            print("Overlay closed. currentEDR=\(edrNow())")
            print("Done. Report the beep number where brightness plateaued or whites clipped.")
            app.terminate(nil)
        }
    }
}
// Watch whether sustained full-screen boost drags the reported headroom down
// (ABL); if currentEDR sinks below the active factor, that step is dishonest.
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    print("  sample: currentEDR=\(edrNow())")
}
app.run()
