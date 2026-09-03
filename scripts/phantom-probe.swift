// Phantom display probe: what the system knows about a display whose cable is
// gone while CoreGraphics still lists it (issue #112). Run: swift scripts/phantom-probe.swift
// Samples every 200 ms and prints a line whenever anything changes, plus a "." every
// 2 s so a gap in the output means the sampler was frozen, not that nothing happened.
// Per line: the CG online list with vendor/model, A for active, B for built-in, and
// COUNTED (what physicalActiveDisplayCount would return); the IOMobileFramebufferShim
// nodes' attached product id and height; the Thunderbolt switch count; and every
// IOAccessoryManager display transport node (dp: DisplayPort alt mode, tb: Thunderbolt)
// with its port, HPD state, sink count and driver status. Start it, do the undock or
// cable pull, wait for the screens to come back, then Ctrl-C and attach the output.
import CoreGraphics
import Foundation
import IOKit
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
func cgState() -> String {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    var active = 0, counted = 0, parts: [String] = []
    for i in 0..<Int(n) {
        let d = ids[i]; let a = CGDisplayIsActive(d) == 1
        let v = CGDisplayVendorNumber(d), m = CGDisplayModelNumber(d)
        let sane = v != 0 && m != 0 && v <= 0xFFFF && m <= 0xFFFF
        if a { active += 1 }; if a && sane { counted += 1 }
        parts.append("\(d)[\(String(v, radix: 16))/\(String(m, radix: 16)) \(a ? "A" : "-")\(CGDisplayIsBuiltin(d) == 1 ? "B" : "")]")
    }
    return "online=\(n) active=\(active) COUNTED=\(counted) | " + parts.joined(separator: " ")
}
func fbState() -> String {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &it) == KERN_SUCCESS else { return "fb: n/a" }
    var parts: [String] = []
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        var nameBuf = [CChar](repeating: 0, count: 128); IORegistryEntryGetName(s, &nameBuf)
        let attrs = IORegistryEntryCreateCFProperty(s, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
        let prod = attrs?["ProductAttributes"] as? [String: Any]
        let h = IORegistryEntryCreateCFProperty(s, "DisplayHeight" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int ?? 0
        let name = String(cString: nameBuf)
        if let prod, let pid = prod["ProductID"] as? Int { parts.append("\(name):pid=\(String(pid & 0xFFFF, radix: 16)),h=\(h)") } else { parts.append("\(name):empty,h=\(h)") }
    }
    IOObjectRelease(it)
    return "fb " + parts.sorted().joined(separator: " ")
}
func tbState() -> String {
    var it: io_iterator_t = 0; var n = 0
    if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOThunderboltSwitch"), &it) == KERN_SUCCESS {
        while case let s = IOIteratorNext(it), s != 0 { n += 1; IOObjectRelease(s) }; IOObjectRelease(it)
    }
    return "tbSwitches=\(n)"
}

func prop(_ s: io_service_t, _ k: String) -> String {
    guard let v = IORegistryEntryCreateCFProperty(s, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else { return "?" }
    return "\(v)"
}
func portState() -> String {
    var parts: [String] = []
    for cls in ["IOPortTransportStateDisplayPort", "IOPortTransportStateCIO"] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
        while case let s = IOIteratorNext(it), s != 0 {
            defer { IOObjectRelease(s) }
            let tag = cls.hasSuffix("CIO") ? "tb" : "dp"
            parts.append("\(tag):\(prop(s, "ParentPortTypeDescription"))\(prop(s, "ParentPortNumber")) hpd=\(prop(s, "HPD_StateDescription")) sink=\(prop(s, "SinkCount")) drv=\(prop(s, "DriverStatusDescription"))")
        }
        IOObjectRelease(it)
    }
    return "ports[" + parts.sorted().joined(separator: "; ") + "]"
}

var last = ""; var beat = Date()
while true {
    let s = cgState() + " || " + fbState() + " || " + tbState() + " || " + portState()
    let now = Date()
    if s != last { print("\(fmt.string(from: now)) * \(s)"); last = s; beat = now; fflush(stdout) }
    else if now.timeIntervalSince(beat) >= 2 { print("\(fmt.string(from: now)) ."); beat = now; fflush(stdout) }
    usleep(200_000)
}
