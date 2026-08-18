// Mirror-HiDPI probe for issue #65: WindowServer refuses scaled backings wider
// than ~6720px on 5K2K panels, so HiDPI sizes above looks-like ~3360x945 never
// enumerate. The plan is a virtual display that carries the big HiDPI mode (its
// framebuffer is rendered, not scanned out, so the cap should not apply), with
// the physical panel hardware-mirroring it and downscaling on scanout. This
// probe tests exactly that mechanism, standalone, before any app wiring:
//   1. create a CGVirtualDisplay with a 2x backing for the requested size
//   2. verify the looks-like HiDPI mode enumerates and becomes current
//   3. mirror the physical display onto it (virtual = master)
//   4. report the resulting state of both displays
//   5. tear down on Enter or Ctrl-C (unmirror, destroy, verify it is gone)
//
// Run: swift scripts/mirror-hidpi-probe.swift <WxH> [displayID]
//   <WxH>       logical ("looks like") size, e.g. 3840x1080 on a 5K2K panel
//   [displayID] physical display to mirror; default: first external, else main
//
// Creating the display pops macOS's "What do you want to show?" picker; ignore
// it, the probe configures the mirror itself. If the screen goes wrong, Ctrl-C
// restores it; worst case, quitting the process kills the virtual display.
import AppKit

func fail(_ msg: String) -> Never { print("FAIL: \(msg)"); exit(1) }

// MARK: - Args

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: swift scripts/mirror-hidpi-probe.swift <WxH> [displayID]")
}
let sizeParts = args[1].lowercased().split(separator: "x")
guard sizeParts.count == 2, let logicalW = Int(sizeParts[0]), let logicalH = Int(sizeParts[1]),
      logicalW > 0, logicalH > 0 else {
    fail("bad size '\(args[1])', expected e.g. 3840x1080")
}

var displayCount: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &displayCount)
var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
CGGetOnlineDisplayList(displayCount, &onlineIDs, &displayCount)

let physical: CGDirectDisplayID
if args.count >= 3 {
    guard let want = UInt32(args[2]), onlineIDs.contains(want) else {
        fail("display \(args[2]) not online (online: \(onlineIDs))")
    }
    physical = want
} else {
    physical = onlineIDs.first { CGDisplayIsBuiltin($0) == 0 } ?? CGMainDisplayID()
}

// MARK: - Reporting helpers

func modeString(_ m: CGDisplayMode) -> String {
    let kind = m.pixelWidth > m.width ? " HiDPI" : ""
    return "\(m.width)x\(m.height)\(kind) (px \(m.pixelWidth)x\(m.pixelHeight)) @\(Int(m.refreshRate.rounded()))Hz"
}

func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
    return (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
}

func report(_ label: String, _ id: CGDirectDisplayID) {
    let cur = CGDisplayCopyDisplayMode(id).map(modeString) ?? "no mode"
    let mirrors = CGDisplayMirrorsDisplay(id)
    let mirrorStr = mirrors == kCGNullDirectDisplay ? "not mirroring" : "mirrors \(mirrors)"
    print("\(label) \(id): \(cur) | \(mirrorStr) | hwMirrorSet=\(CGDisplayIsInHWMirrorSet(id) != 0) primary=\(CGDisplayPrimaryDisplay(id))")
}

let physName = NSScreen.screens.first {
    $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == physical
}?.localizedName ?? "?"
let physModes = allModes(physical)
let hidpiTop = physModes.filter { $0.pixelWidth > $0.width }.map(\.width).max() ?? 0
print("Physical: \(physName) (\(physical)), \(physModes.count) modes, HiDPI ladder top \(hidpiTop)px wide")
report("  before:", physical)
print("Target: looks like \(logicalW)x\(logicalH), backing \(logicalW * 2)x\(logicalH * 2)")

// MARK: - CGVirtualDisplay via the ObjC runtime (no bridging header in scripts)

guard let descCls = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
      let modeCls: AnyClass = NSClassFromString("CGVirtualDisplayMode"),
      let settingsCls = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
      let displayCls: AnyClass = NSClassFromString("CGVirtualDisplay")
else { fail("CGVirtualDisplay private API unavailable") }

func alloc(_ cls: AnyClass) -> AnyObject {
    let imp = class_getMethodImplementation(object_getClass(cls), NSSelectorFromString("alloc"))
    let fn = unsafeBitCast(imp, to: (@convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>).self)
    return fn(cls, NSSelectorFromString("alloc")).takeRetainedValue()
}

func makeMode(_ pixelW: Int, _ pixelH: Int, _ hz: Double) -> AnyObject {
    let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
    let imp = class_getMethodImplementation(modeCls, sel)
    let fn = unsafeBitCast(imp, to: (@convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>).self)
    return fn(alloc(modeCls), sel, UInt(pixelW), UInt(pixelH), hz).takeRetainedValue()
}

let desc = descCls.init()
// Report the physical panel's own physical size so macOS computes a sane PPI.
let mm = CGDisplayScreenSize(physical)
desc.setValue(NSValue(size: NSSize(width: mm.width, height: mm.height)), forKey: "sizeInMillimeters")
desc.setValue(UInt32(logicalW * 2), forKey: "maxPixelsWide")
desc.setValue(UInt32(logicalH * 2), forKey: "maxPixelsHigh")
desc.setValue("Crisp Mirror Probe", forKey: "name")
desc.setValue(UInt32(0xEEEE), forKey: "vendorID")   // Crisp's virtual-display stamp
desc.setValue(UInt32(0x50524F42), forKey: "productID")  // "PROB"
desc.setValue(UInt32(1), forKey: "serialNum")

let physRate = CGDisplayCopyDisplayMode(physical)?.refreshRate ?? 60
var rates: [Double] = [60]
if physRate > 0, abs(physRate - 60) >= 1 { rates.append(physRate) }

let settings = settingsCls.init()
settings.setValue(true, forKey: "hiDPI")
var modeObjs: [AnyObject] = []
for hz in rates {
    modeObjs.append(makeMode(logicalW * 2, logicalH * 2, hz))  // the 2x backing
    modeObjs.append(makeMode(logicalW, logicalH, hz))          // 1x fallback
}
settings.setValue(modeObjs as NSArray, forKey: "modes")

let initSel = NSSelectorFromString("initWithDescriptor:")
let initImp = class_getMethodImplementation(displayCls, initSel)
let initFn = unsafeBitCast(initImp, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Unmanaged<AnyObject>?).self)
// Kept in a global so teardown() can release it; releasing destroys the display.
var virtualDisplay: AnyObject? = initFn(alloc(displayCls), initSel, desc)?.takeRetainedValue()
guard let vd = virtualDisplay else { fail("CGVirtualDisplay init returned nil") }

let applySel = NSSelectorFromString("applySettings:")
let applyImp = class_getMethodImplementation(displayCls, applySel)
let applyFn = unsafeBitCast(applyImp, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Bool).self)
guard applyFn(vd, applySel, settings) else { fail("applySettings failed") }

guard let vdID = (vd as? NSObject)?.value(forKey: "displayID") as? CGDirectDisplayID,
      vdID != kCGNullDirectDisplay else { fail("virtual display has no displayID") }
print("Virtual display created: id \(vdID)")

// MARK: - Mirror config + teardown

func setMirror(_ display: CGDirectDisplayID, master: CGDirectDisplayID) -> Bool {
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg else { return false }
    CGConfigureDisplayMirrorOfDisplay(c, display, master)
    if CGCompleteDisplayConfiguration(c, .forSession) != .success {
        CGCancelDisplayConfiguration(c)
        return false
    }
    return true
}

func teardown() {
    print("\nTearing down: unmirror -> destroy virtual display")
    if !setMirror(physical, master: kCGNullDirectDisplay) { print("  unmirror FAILED") }
    virtualDisplay = nil   // last strong reference: WindowServer removes the display
    usleep(1_500_000)
    var n: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &n)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
    CGGetOnlineDisplayList(n, &ids, &n)
    print(ids.contains(vdID) ? "  virtual display STILL ONLINE (check after exit)" : "  virtual display gone")
    report("  physical after:", physical)
}

signal(SIGINT, SIG_IGN)
let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
sigSrc.setEventHandler { teardown(); exit(0) }
sigSrc.resume()

// MARK: - Drive the virtual display to the looks-like HiDPI mode

// WindowServer finishes bringing the display up (and picks its own default
// mode) asynchronously; retry briefly like VirtualDisplayService does.
var hidpiMode: CGDisplayMode?
for attempt in 0..<10 {
    if attempt > 0 { usleep(300_000) }
    let modes = allModes(vdID)
    if modes.isEmpty { continue }
    if hidpiMode == nil {
        print("Virtual modes (\(modes.count)):")
        for m in modes { print("  \(modeString(m))") }
    }
    hidpiMode = modes.first { $0.width == logicalW && $0.height == logicalH && $0.pixelWidth == logicalW * 2 }
    if hidpiMode != nil { break }
}
guard let target = hidpiMode else {
    teardown()
    fail("looks-like \(logicalW)x\(logicalH) HiDPI mode never enumerated on the virtual display — the cap may apply to virtual framebuffers too")
}

var cfg: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&cfg) == .success, let c = cfg,
      CGConfigureDisplayWithDisplayMode(c, vdID, target, nil) == .success,
      CGCompleteDisplayConfiguration(c, .forSession) == .success else {
    teardown()
    fail("could not set the virtual display to \(modeString(target))")
}
usleep(500_000)
report("Virtual", vdID)

// MARK: - Mirror the physical onto it

print("Mirroring physical \(physical) onto virtual \(vdID)...")
guard setMirror(physical, master: vdID) else {
    teardown()
    fail("mirror configuration failed")
}
usleep(1_000_000)
print("--- Mirrored state ---")
report("Physical", physical)
report("Virtual ", vdID)
if CGDisplayMirrorsDisplay(physical) == vdID {
    print("SUCCESS: physical is mirroring the virtual display.")
    print("Look at the screen: is it the \(logicalW)x\(logicalH) desktop, sharp, full-screen?")
    print("Drag a window, check refresh feel, then judge text sharpness up close.")
} else {
    print("MIRROR DID NOT STICK — WindowServer reports no mirror on the physical display.")
}
print("\nPress Enter (or Ctrl-C) to tear down and restore.")
_ = readLine()
teardown()
