// Diagnostic spike for the Extra Brightness feature. Run: swift scripts/edr-spike.swift
// 1) Prints EDR headroom values for every screen.
// 2) Dumps MonitorPanel MPDisplay HDR-related properties/selectors per display.
// 3) Shows a fullscreen EDR multiply overlay (factor 1.5) on the main screen for 8s.
//    Expected on an XDR/HDR display: the whole desktop visibly brightens.
//
// Findings from a run on this machine (2 screens: built-in Retina + external Q27G3XMN):
//   EDR headroom:
//     screen 1 'Built-in Retina Display': maximumEDR=1.0, maximumPotentialEDR=16.0, maximumReferenceEDR=0.0
//     screen 4 'Q27G3XMN' (external, non-HDR): maximumEDR=1.0, maximumPotentialEDR=1.0, maximumReferenceEDR=0.0
//   MPDisplay HDR-related property names found in the property dump (both displays): hasHDRModes, preferHDRModes.
//   MPDisplay HDR selectors probed, all responded true on both displays:
//     hasHDRModes: true, preferHDRModes: true, setPreferHDRModes:: true
//   Overlay: ran cleanly with compositingFilter = "multiplyBlendMode" as written, no "no drawable" error.
//   Visual brightening on-screen not yet confirmed by a human; script output alone confirms a clean run.
import AppKit
import Metal
import ObjectiveC.runtime

// ---- 1) EDR headroom per screen ----
for screen in NSScreen.screens {
    let did = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    print("screen \(did) '\(screen.localizedName)'")
    print("  maximumEDR (current):   \(screen.maximumExtendedDynamicRangeColorComponentValue)")
    print("  maximumPotentialEDR:    \(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)")
    print("  maximumReferenceEDR:    \(screen.maximumReferenceExtendedDynamicRangeColorComponentValue)")
}

// ---- 2) MonitorPanel HDR probe ----
if dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
   let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type {
    let mgr = cls.init()
    if let displays = mgr.value(forKey: "displays") as? [NSObject] {
        for d in displays {
            let did = d.value(forKey: "displayID") as? UInt32 ?? 0
            print("MPDisplay \(did):")
            // Dump every property name so we discover the real HDR key names.
            var count: UInt32 = 0
            if let props = class_copyPropertyList(object_getClass(d), &count) {
                let names = (0..<Int(count)).map { String(cString: property_getName(props[$0])) }
                free(props)
                print("  properties: \(names.sorted().joined(separator: ", "))")
            }
            // Probe the candidate HDR selectors directly.
            for sel in ["hasHDRModes", "preferHDRModes", "setPreferHDRModes:"] {
                print("  responds to \(sel): \(d.responds(to: NSSelectorFromString(sel)))")
            }
        }
    }
} else {
    print("MonitorPanel unavailable")
}

// ---- 3) EDR multiply overlay on the main screen ----
guard let screen = NSScreen.main else { exit(1) }
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
// Uniform color: an 8x8 drawable scaled to fullscreen costs nothing.
metalLayer.drawableSize = CGSize(width: 8, height: 8)
metalLayer.compositingFilter = "multiplyBlendMode"

let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
host.wantsLayer = true
host.layer = metalLayer
window.contentView = host

let factor = 1.5
let queue = device.makeCommandQueue()!
func render() {
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
render()
window.orderFrontRegardless()
print("Overlay up at factor \(factor) for 8 seconds. Screen should visibly brighten...")
DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    window.close()
    print("Done.")
    app.terminate(nil)
}
app.run()
