import Foundation
import CoreGraphics

// Global C-compatible callback for display reconfiguration.
// Must be a top-level function (not a closure) to be used as a C function pointer.
private func displayReconfigCallback(
    displayID: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let ptr = userInfo else { return }
    let manager = Unmanaged<DisplayManager>.fromOpaque(ptr).takeUnretainedValue()

    // .movedFlag fires when a display's origin changes (a rearrange, in Crisp or
    // in System Settings). Without it the arranger keeps rendering stale bounds.
    let relevant: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .setMainFlag, .setModeFlag, .movedFlag]
    guard !flags.intersection(relevant).isEmpty else { return }

    // Skip the begin-configuration notification; only act when the change is complete.
    // (beginConfigurationFlag is set at the start of a transaction; absence means it finished.)
    guard !flags.contains(.beginConfigurationFlag) else { return }

    Task { @MainActor in
        if flags.intersection([.addFlag, .removeFlag, .movedFlag]).isEmpty {
            // Mode or main-display change: refresh mode info for existing displays only.
            manager.refreshExistingDisplayModes()
        } else {
            // Add/remove/move: rebuild so display bounds (arrangement) are current;
            // refreshExistingDisplayModes doesn't re-read bounds.
            manager.refreshDisplays()
        }
    }
}

@MainActor
class DisplayManager: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    /// Display whose menu bar the panel was opened on; listed first, like the native displays panel.
    @Published var activePanelDisplayID: CGDirectDisplayID?

    /// A smooth-scaling toggle soft-reconnects the display, which drops it from the list and
    /// re-adds it as a fresh DisplayInfo, wiping its row's expansion @State. The enable flow
    /// sets this to the display's stable UUID afterward so the menu re-expands that display's
    /// detail and Resolution section, landing the user back where they were. Cleared once applied.
    @Published var pendingResolutionExpandUUID: String?

    // nonisolated(unsafe) allows deinit (which is nonisolated in Swift 6) to access this value.
    nonisolated(unsafe) private var callbackContext: UnsafeMutableRawPointer?

    init() {
        refreshDisplays()
        setupReconfigCallback()
    }

    deinit {
        if let ctx = callbackContext {
            CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, ctx)
            Unmanaged<DisplayManager>.fromOpaque(ctx).release()
        }
    }

    func refreshDisplays() {
        var displayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &displayCount)
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetOnlineDisplayList(displayCount, &displayIDs, &displayCount)

        let currentIDs = Set(displays.map { $0.displayID })
        let newIDSet = Set((0..<Int(displayCount)).map { displayIDs[$0] })

        // Clean up DDC cache for removed displays to prevent stale entries accumulating
        let removedIDs = currentIDs.subtracting(newIDSet)
        removedIDs.forEach {
            DDCService.shared.clearCache(for: $0)
            BrightnessService.shared.invalidateDDCState(for: $0)
        }

        // Diff-based refresh: keep existing DisplayInfo objects (preserves @Published state)
        var existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.displayID, $0) })

        var updatedDisplays: [DisplayInfo] = []
        var addedDisplays: [DisplayInfo] = []

        for i in 0..<Int(displayCount) {
            let id = displayIDs[i]
            if let existing = existingByID[id] {
                updatedDisplays.append(existing)
            } else {
                let info = DisplayInfo(displayID: id)
                updatedDisplays.append(info)
                addedDisplays.append(info)
            }
        }

        displays = updatedDisplays
        DisplayManagerAccessor.shared.displays = updatedDisplays

        // Regenerate built-in presets (HiDPI mode / Native mode) from updated display list.
        PresetService.shared.refreshBuiltins()

        // Only load details / refresh brightness for newly appeared displays
        for display in addedDisplays {
            Task { await BrightnessService.shared.refreshBrightness(for: display) }
            Task {
                await display.loadDetails()
                // Auto-enable HiDPI for new external 2K+ displays that don't have it yet
                if !display.isBuiltin {
                    await self.autoEnableHiDPIIfNeeded(for: display)
                }
                PresetService.shared.refreshBuiltins()
            }
            // Restore saved gamma/software-brightness adjustments for the reconnected display.
            // Brief delay lets WindowServer settle before we write transfer tables.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                BrightnessService.shared.reapplySoftwareBrightnessIfNeeded(for: display)
                GammaService.shared.reapplyIfNeeded(for: display.displayID)
            }
        }

        // For displays that were already present, only update bounds/main flag (no DDC probe).
        let keptIDs = currentIDs.intersection(newIDSet)
        for display in updatedDisplays where keptIDs.contains(display.displayID) {
            display.bounds = CGDisplayBounds(display.displayID)
            display.isMain = CGDisplayIsMain(display.displayID) != 0
        }

        // Keep the physical-disconnect list honest: drop any record whose display came back
        // online (re-plugged, or macOS re-enabled it).
        PhysicalDisplayToggleService.shared.reconcile()

        // Keep the built-in brightness observer pointed at the current built-in so the
        // slider tracks system brightness changes (keys, auto-brightness) live.
        BrightnessService.shared.startObservingBuiltinBrightness()
    }

    /// Auto-enables HiDPI plist override for external 2K+ displays that don't have it yet.
    /// This ensures switching between different monitors "just works" without manual re-enable.
    private func autoEnableHiDPIIfNeeded(for display: DisplayInfo) async {
        let vendor = display.vendorNumber
        let product = display.modelNumber
        guard vendor != 0, product != 0 else { return }

        // Already enabled — nothing to do
        guard !HiDPIService.shared.isHiDPIEnabled(vendor: vendor, product: product) else { return }

        // Determine native resolution from available modes
        let (nativeW, nativeH) = display.nativeResolution

        // Only auto-enable for 2K+ displays (width >= 2560 or total pixels >= 2560*1440)
        guard nativeW >= 2560 || (nativeW * nativeH >= 2560 * 1440) else { return }

        // CGS-direct already surfaces the panel's HiDPI scaled modes with no override (the normal
        // case for 2K+ panels). When those are present, skip the override write + soft-reconnect
        // entirely: no admin prompt, no blank. The override path below is only a fallback for a
        // panel that genuinely lacks HiDPI in CGS.
        if display.availableModes.contains(where: {
            $0.isHiDPI && $0.pixelWidth >= nativeW && $0.width >= nativeW / 2
        }) { return }

        print("[DisplayManager] Auto-enabling smooth scaling for \(display.name) (\(nativeW)×\(nativeH), vendor=\(vendor), product=\(product))")

        // Install the dense smooth-scaling ladder directly, not just the coarse HiDPI set: this
        // admin prompt is the one interruption, so make it deliver the full scaled slider in one
        // shot. Anyone enabling HiDPI on a 2K+ external wants that range anyway.
        let err = HiDPIService.shared.enableSmoothScaling(
            vendor: vendor, product: product, nativeWidth: nativeW, nativeHeight: nativeH)

        if let err {
            print("[DisplayManager] Auto-enable smooth scaling failed: \(err)")
        } else {
            print("[DisplayManager] Auto-enable smooth scaling succeeded, re-enumerating")
            // Soft-reconnect so the freshly written override enumerates now (screen blanks ~1s),
            // instead of the weak probe that left the modes dormant until a physical reconnect.
            await PhysicalDisplayToggleService.shared.softReconnect(display)
            HiDPIService.shared.refreshModes(for: display)
            await display.loadDetails()
            PresetService.shared.refreshBuiltins()
        }
    }

    private func setupReconfigCallback() {
        let ctx = Unmanaged.passRetained(self).toOpaque()
        callbackContext = ctx
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, ctx)
    }

    /// Refreshes mode info and main-display flag for already-tracked displays
    /// (for setModeFlag / setMainFlag events).
    /// Cheaper than a full `refreshDisplays()` — does not add/remove DisplayInfo objects.
    func refreshExistingDisplayModes() {
        for display in displays {
            // Always refresh isMain synchronously since it's cheap and needed for setMainFlag events.
            display.isMain = CGDisplayIsMain(display.displayID) != 0
            Task {
                let newMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: display.displayID)
                }.value
                display.currentDisplayMode = newMode
            }
        }
    }

    /// Disconnects a physical display from the layout (Apple Silicon only) via
    /// PhysicalDisplayToggleService. Returns false if unsupported or refused (e.g. it would
    /// leave no active display). The display list refreshes via the reconfiguration callback.
    @discardableResult
    func disconnectDisplay(_ display: DisplayInfo) async -> Bool {
        let result = await PhysicalDisplayToggleService.shared.disconnect(display)
        refreshDisplays()
        if case .success = result { return true }
        return false
    }

    /// Makes the target display the main display by repositioning it to origin (0, 0).
    func setAsMainDisplay(_ display: DisplayInfo) {
        Task { @MainActor in
            let ok = await ArrangementService.shared.setAsMainDisplay(display.displayID, among: self.displays)
            if ok { self.refreshDisplays() }
        }
    }

}
