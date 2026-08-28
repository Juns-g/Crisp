import CoreGraphics
import Foundation
import os.log

/// True HiDPI past WindowServer's scaled-backing cap (issue #65). On 5K2K
/// ultrawides macOS refuses scaled backings wider than ~6720px, so looks-like
/// sizes between the ladder top (~3360 wide) and native never enumerate as
/// HiDPI on the physical display. This service delivers them anyway: it creates
/// a hidden virtual display whose framebuffer is rendered, not scanned out (the
/// cap does not apply there), drives it to the wanted looks-like HiDPI mode,
/// and hardware-mirrors the physical panel onto it; the scanout engine
/// downscales. The findings behind the recipe (mode declaration rules, the
/// ~400-object applySettings ceiling, unmirror-before-destroy order) live in
/// scripts/mirror-hidpi-probe.swift and its commit history.
///
/// Lazy lifecycle: the virtual display exists only while a beyond-cap size is
/// active; `restore` unmirrors first, then destroys. Nothing is persisted, a
/// relaunch comes up unmirrored. Rotated panels are unverified with mirroring.
@MainActor
final class MirroredModeService: ObservableObject {
    static let shared = MirroredModeService()
    private init() {}

    /// Mirror mode only misbehaves on live hardware, so every failure branch
    /// logs; `log stream --predicate 'subsystem == "com.crisp.app"'` while
    /// reproducing tells which step broke without a debug build.
    private static let log = Logger(subsystem: "com.crisp.app", category: "mirroredmode")

    /// Live CGVirtualDisplay per mirrored physical display. Releasing a value
    /// is what destroys its virtual display, so this dictionary IS the state.
    private var active: [CGDirectDisplayID: CGVirtualDisplay] = [:]

    /// Published mirror of `active`'s keys so views can observe activity.
    @Published private(set) var activePhysicalIDs: Set<CGDirectDisplayID> = []

    /// Serial-number marker stamped on every mirror virtual ("MIRR"), alongside
    /// the shared 0xEEEE vendor stamp (which keeps every existing
    /// isVirtualDisplay filter treating these as virtual). Lets launch recovery
    /// recognize a stray mirror virtual left by a crash.
    static let mirrorSerialMarker: UInt32 = 0x4D49_5252

    // MARK: - Queries

    func isActive(for physicalID: CGDirectDisplayID) -> Bool {
        active[physicalID] != nil
    }

    func virtualDisplayID(for physicalID: CGDirectDisplayID) -> CGDirectDisplayID? {
        active[physicalID]?.displayID
    }

    /// The looks-like size currently rendered for a mirrored physical display
    /// (read from the virtual master's active mode), or nil when not mirrored.
    func currentLooksLike(for physicalID: CGDirectDisplayID) -> (width: Int, height: Int)? {
        guard let vdID = active[physicalID]?.displayID,
              let cur = CGDisplayCopyDisplayMode(vdID) else { return nil }
        return (cur.width, cur.height)
    }

    // MARK: - Apply / Restore

    /// Puts `display` on a beyond-cap looks-like size: first call creates the
    /// mirror virtual and enables the mirror; subsequent calls only switch the
    /// virtual's mode. Returns false with everything unwound on failure, so a
    /// failed attempt never leaves a half-built mirror.
    @discardableResult
    func apply(display: DisplayInfo, width: Int, height: Int) async -> Bool {
        guard !display.isBuiltin else { return false }
        let physicalID = display.displayID

        if let vdID = active[physicalID]?.displayID {
            guard await setLooksLike(width: width, height: height, on: vdID) else {
                Self.log.error("apply \(width)x\(height): setLooksLike failed on existing virtual \(vdID)")
                return false
            }
            // Re-arm the mirror if something dropped it under us (a wake or a
            // WindowServer reset can collapse a mirror set without telling us).
            if CGDisplayMirrorsDisplay(physicalID) != vdID {
                Self.log.info("apply \(width)x\(height): reused virtual \(vdID), re-arming mirror")
                return await MirrorService.shared.enableMirror(source: vdID, target: physicalID)
            }
            Self.log.info("apply \(width)x\(height): reused virtual \(vdID)")
            return true
        }

        guard let virtualDisplay = await createMirrorVirtual(for: display,
                                                             mustInclude: (width, height))
        else {
            Self.log.error("apply \(width)x\(height): createMirrorVirtual failed")
            return false
        }
        active[physicalID] = virtualDisplay
        activePhysicalIDs.insert(physicalID)

        guard await setLooksLike(width: width, height: height, on: virtualDisplay.displayID) else {
            Self.log.error("apply \(width)x\(height): setLooksLike failed on fresh virtual \(virtualDisplay.displayID)")
            await restore(physicalID: physicalID)
            return false
        }
        guard await MirrorService.shared.enableMirror(source: virtualDisplay.displayID,
                                                      target: physicalID) else {
            Self.log.error("apply \(width)x\(height): enableMirror failed (virtual \(virtualDisplay.displayID) -> physical \(physicalID))")
            await restore(physicalID: physicalID)
            return false
        }
        Self.log.info("apply \(width)x\(height): mirrored physical \(physicalID) onto virtual \(virtualDisplay.displayID)")
        return true
    }

    /// Leaves mirror mode: unmirrors the physical display, then destroys the
    /// virtual. The caller applies whatever real mode it wants afterwards.
    /// Order matters: destroying the master of a live mirror is undefined, so
    /// always unmirror first (the probe's verified-safe order).
    @discardableResult
    func restore(display: DisplayInfo) async -> Bool {
        await restore(physicalID: display.displayID)
    }

    @discardableResult
    func restore(physicalID: CGDirectDisplayID) async -> Bool {
        guard let vdID = active[physicalID]?.displayID else { return true }
        Self.log.info("restore: unmirroring physical \(physicalID), destroying virtual \(vdID)")
        // Only a confirmed unmirror may let the virtual go. disableMirror's false
        // covers both a refused transaction and a slow one still in flight
        // (runWithTimeout's fallback), and in either case the panel may still be
        // mirroring this virtual; keep the entry, so the master stays alive and
        // the next slider move or reconcile() gets another go.
        guard await MirrorService.shared.disableMirror(displayID: physicalID) else {
            Self.log.error("restore: unmirror of physical \(physicalID) failed, keeping virtual \(vdID)")
            return false
        }
        // Dropping the last reference starts WindowServer's async teardown.
        active.removeValue(forKey: physicalID)
        activePhysicalIDs.remove(physicalID)
        await waitForDisplayOffline(vdID)
        return true
    }

    /// Keeps the bookkeeping truthful against the fresh online list (called from
    /// DisplayManager.refreshDisplays). Two cases matter: the mirrored physical
    /// was unplugged (nothing to unmirror anymore, dropping the entry lets the
    /// orphan virtual die), or our virtual died without us (WindowServer
    /// collapses the mirror set itself when a master disappears; dropping the
    /// stale entry makes the next slider move take the normal create path).
    /// Set-based rather than per removed ID because the mirror virtual is never
    /// in `DisplayManager.displays`, so its death never shows in that diff.
    func reconcile(online: Set<CGDirectDisplayID>) {
        for (physicalID, virtualDisplay) in active
        where !online.contains(physicalID) || !online.contains(virtualDisplay.displayID) {
            active.removeValue(forKey: physicalID)
            activePhysicalIDs.remove(physicalID)
        }
    }

    /// A Crisp mirror virtual, ours or a stray from a crashed session: the shared
    /// vendor stamp plus the MIRR serial. DisplayManager keeps these out of
    /// `displays`, so no view, preset, or brightness path ever sees one.
    static func isMirrorVirtual(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayVendorNumber(displayID) == VirtualDisplayService.crispVirtualVendorID
            && CGDisplaySerialNumber(displayID) == mirrorSerialMarker
    }

    /// The looks-like sizes a display can only reach through mirror mode: every
    /// smooth-scaling grid step between the widest HiDPI mode WindowServer let
    /// the panel enumerate and native. Empty when the whole ladder enumerated
    /// (nothing is capped) and for the built-in panel. One definition for the
    /// slider, presets, and the virtual's mode list, so they can never disagree.
    static func beyondCapStops(for display: DisplayInfo) -> [(width: Int, height: Int)] {
        guard !display.isBuiltin else { return [] }
        let (nativeW, nativeH) = display.nativeResolution
        guard nativeW > 0, nativeH > 0 else { return [] }
        // ponytail: ultrawide-only (21:9 and wider) until a 16:9 4K or 5K panel is
        // verified with the mirror. Those are capped too (7680 and 10240 backings)
        // and would otherwise grow the same stops, untested. Drop this guard to widen.
        guard Double(nativeW) / Double(nativeH) >= 2.0 else { return [] }
        let hidpiTop = display.availableModes.filter { $0.isHiDPI }.map(\.width).max() ?? 0
        guard hidpiTop > 0 else { return [] }
        return HiDPIService.shared
            .smoothScaledLogicalSizes(nativeWidth: nativeW, nativeHeight: nativeH)
            .filter { $0.width > hidpiTop && $0.width < nativeW }
    }

    /// Frees any physical display left mirroring a STRAY Crisp mirror virtual
    /// (vendor stamp + MIRR serial) that this process does not own, i.e. one a
    /// crashed session left behind. We hold no object for it so we cannot
    /// destroy it, but unmirroring gives the panel its desktop back; the ghost
    /// display stays hidden from the UI by the vendor-stamp filters. Called on
    /// every refreshDisplays; a cheap no-op when nothing is stray.
    func recoverStrandedMirrors() {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        guard count > 0 else { return }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        for id in ids where CGDisplayVendorNumber(id) == VirtualDisplayService.crispVirtualVendorID
            && CGDisplaySerialNumber(id) == Self.mirrorSerialMarker
            && !active.values.contains(where: { $0.displayID == id }) {
            guard let target = MirrorService.shared.mirrorTargets(of: id) else { continue }
            Task { await MirrorService.shared.disableMirror(displayID: target) }
        }
    }

    /// Quit-path teardown. applicationWillTerminate cannot await, so the
    /// unmirror runs as a direct synchronous transaction; a rare WindowServer
    /// hang at quit beats leaving the panel mirrored. (Process death would
    /// also collapse the mirror set, this just makes it orderly.)
    func teardownAll() {
        for physicalID in active.keys {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else { continue }
            CGConfigureDisplayMirrorOfDisplay(cfg, physicalID, kCGNullDirectDisplay)
            if CGCompleteDisplayConfiguration(cfg, .forSession) != .success {
                CGCancelDisplayConfiguration(cfg)
            }
        }
        active.removeAll()
        activePhysicalIDs.removeAll()
    }

    // MARK: - Creation

    /// Builds the mirror virtual for a physical display: stable identity (so
    /// macOS's "what do you want to show" picker appears at most once per
    /// monitor and its answer is remembered), the panel's physical size (sane
    /// PPI), and a backing + half-size mode PAIR for every beyond-cap stop.
    /// The pair is mandatory: backing-only declarations get WindowServer to
    /// mint enumerable looks-like twins, but those twins fail every apply
    /// (verified live on a 5K2K panel). One refresh rate keeps the dense
    /// ladder under the ~400-object ceiling where applySettings rejects the
    /// whole set.
    private func createMirrorVirtual(for display: DisplayInfo,
                                     mustInclude: (width: Int, height: Int)) async -> CGVirtualDisplay? {
        let (nativeW, nativeH) = display.nativeResolution
        guard nativeW > 0, nativeH > 0 else { return nil }

        // The new-display registration pops macOS's picker, which steals key
        // focus and would trip the panel's auto-dismiss; same suppression as
        // VirtualDisplayService.create.
        PanelOpenGuard.suppressAutoDismiss = true
        defer {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                PanelOpenGuard.suppressAutoDismiss = false
            }
        }

        let descriptor = CGVirtualDisplayDescriptor()
        let mm = CGDisplayScreenSize(display.displayID)
        descriptor.sizeInMillimeters = mm.width > 0 ? mm
            : CGSize(width: Double(nativeW) / 110.0 * 25.4, height: Double(nativeH) / 110.0 * 25.4)
        descriptor.maxPixelsWide = UInt32(nativeW * 2)
        descriptor.maxPixelsHigh = UInt32(nativeH * 2)
        // Panel name plus a marker: system UI lists the virtual while
        // mirrored (Control Center, the first-run Extend picker), and a
        // distinct name reads as a feature where a duplicate "Name (2)"
        // reads as a glitch.
        descriptor.name = String(localized: "\(display.name) (Crisp)")
        descriptor.vendorID = VirtualDisplayService.crispVirtualVendorID
        // Stable per monitor; the serial carries the mirror marker. Two
        // identical monitors mirroring at once would collide, accepted edge.
        let panelIdentity = display.vendorNumber ^ display.modelNumber
        descriptor.productID = panelIdentity != 0 ? panelIdentity : 0x4D52
        descriptor.serialNum = Self.mirrorSerialMarker

        // Every beyond-cap stop on the smooth-scaling grid, in the same
        // (rotated) space as availableModes and the slider; the requested size
        // is force-included in case it sits off that grid.
        var stops = Self.beyondCapStops(for: display)
        if !stops.contains(where: { $0.width == mustInclude.width && $0.height == mustInclude.height }) {
            stops.append((width: mustInclude.width, height: mustInclude.height))
        }

        // One rate only (the panel's own, 60 when unreadable): every stop costs
        // TWO mode objects below, and a second rate would put a dense ladder
        // past the ~400-object ceiling where applySettings rejects the set.
        let panelRate = display.currentDisplayMode?.refreshRate ?? 60
        let rate: Double = panelRate > 0 ? panelRate : 60

        // Declare BOTH the 2x backing and the half-size pixel mode per stop
        // (the probe's recipe). Backing-only declarations look sufficient,
        // WindowServer mints enumerable looks-like twins for them, but those
        // twins refuse to apply: CGConfigureDisplayWithDisplayMode fails on
        // every attempt (found live on a 5K2K panel, 2026-08-25). Only the
        // declared pair yields a twin that can actually become current.
        var modes: [CGVirtualDisplayMode] = []
        for stop in stops where stop.width >= 1 && stop.height >= 1 {
            modes.append(CGVirtualDisplayMode(width: UInt(stop.width * 2),
                                              height: UInt(stop.height * 2),
                                              refreshRate: rate))
            modes.append(CGVirtualDisplayMode(width: UInt(stop.width),
                                              height: UInt(stop.height),
                                              refreshRate: rate))
        }
        guard !modes.isEmpty else {
            Self.log.error("createMirrorVirtual: no beyond-cap stops (native \(nativeW)x\(nativeH))")
            return nil
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = true
        settings.modes = modes

        guard let virtualDisplay = CGVirtualDisplay(descriptor: descriptor) else {
            Self.log.error("createMirrorVirtual: CGVirtualDisplay init returned nil")
            return nil
        }
        // apply blocks on WindowServer IPC; off-main with a timeout like every
        // CG transaction (same as VirtualDisplayService.create).
        let vd = virtualDisplay
        let s = settings
        let applied: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(s)
        }
        guard applied, virtualDisplay.displayID != kCGNullDirectDisplay else {
            Self.log.error("createMirrorVirtual: applySettings \(applied ? "ok but null displayID" : "failed") (\(modes.count) modes)")
            return nil
        }
        Self.log.info("createMirrorVirtual: virtual \(virtualDisplay.displayID) up, \(modes.count) modes declared")
        return virtualDisplay
    }

    // MARK: - Helpers

    /// Drives the virtual display to the looks-like HiDPI mode, retrying while
    /// WindowServer finishes enumerating the fresh display. Prefers the highest
    /// refresh rate offered at that size (the panel's own rate when kept).
    private func setLooksLike(width: Int, height: Int, on virtualID: CGDirectDisplayID) async -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        for attempt in 0..<10 {
            if attempt > 0 {
                await ReconfigEvents.shared.next(for: virtualID,
                                                 matching: [.setModeFlag, .addFlag], timeout: 0.4)
            }
            if let cur = CGDisplayCopyDisplayMode(virtualID),
               cur.width == width, cur.height == height, cur.pixelWidth == width * 2 { return true }
            guard let modes = CGDisplayCopyAllDisplayModes(virtualID, options) as? [CGDisplayMode],
                  let target = modes.filter({
                      $0.width == width && $0.height == height && $0.pixelWidth == width * 2
                  }).max(by: { $0.refreshRate < $1.refreshRate })
            else { continue }
            if await ResolutionService.applyModeSync(target, on: virtualID) { return true }
        }
        // Distinguish "twin never enumerated" from "apply kept failing".
        let options2 = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        let seen = (CGDisplayCopyAllDisplayModes(virtualID, options2) as? [CGDisplayMode]) ?? []
        let hasTwin = seen.contains { $0.width == width && $0.height == height && $0.pixelWidth == width * 2 }
        Self.log.error("setLooksLike \(width)x\(height) on \(virtualID): gave up after 10 attempts, \(seen.count) modes enumerated, HiDPI twin \(hasTwin ? "present (apply failed)" : "never minted")")
        return false
    }

    /// Waits (bounded) for a torn-down virtual display to leave the online
    /// list; same event-driven pattern as VirtualDisplayService, duplicated
    /// because both keep it private to their own teardown story.
    private func waitForDisplayOffline(_ displayID: CGDirectDisplayID) async {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        guard ids.contains(displayID) else { return }
        await ReconfigEvents.shared.next(for: displayID, matching: .removeFlag, timeout: 1.5)
    }
}
