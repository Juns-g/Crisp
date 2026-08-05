// Diagnostic: per-display HDR capability as the OS reports it right now.
// Run: swift scripts/hdr-probe.swift
// Prints every MPDisplay (private MonitorPanel.framework) with hasHDRModes /
// preferHDRModes, plus NSScreen EDR values and the current CG display mode.
import AppKit

guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
      let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
    print("MonitorPanel unavailable"); exit(1)
}
let manager = cls.init()
guard let displays = manager.value(forKey: "displays") as? [NSObject] else {
    print("no MPDisplays"); exit(1)
}
for d in displays {
    let name = d.value(forKey: "displayName") ?? "?"
    let id = d.value(forKey: "displayID") ?? "?"
    let hasHDR = d.value(forKey: "hasHDRModes") ?? "?"
    let preferHDR = d.value(forKey: "preferHDRModes") ?? "?"
    print("MPDisplay \(id): \(name)  hasHDRModes=\(hasHDR)  preferHDRModes=\(preferHDR)")
}
for screen in NSScreen.screens {
    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    else { continue }
    let cur = screen.maximumExtendedDynamicRangeColorComponentValue
    let pot = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
    var modeDesc = "mode unavailable"
    if let mode = CGDisplayCopyDisplayMode(id) {
        modeDesc = "\(mode.width)x\(mode.height) (px \(mode.pixelWidth)x\(mode.pixelHeight)) @\(Int(mode.refreshRate))Hz"
    }
    print("NSScreen \(id): \(screen.localizedName)  currentEDR=\(String(format: "%.3f", cur))  potentialEDR=\(String(format: "%.3f", pot))  \(modeDesc)")
}
