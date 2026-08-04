// Crisp/Services/BrightnessBoostService.swift
import AppKit
import CoreGraphics

/// Policy brain for the Extra Brightness (EDR upscaling) feature. Decides which
/// displays can boost, maps brightness above 100% to an overlay factor (via
/// BrightnessBoostMath + EDROverlayManager), switches external monitors in and
/// out of HDR mode (private MonitorPanel.framework, same dlopen + KVC pattern
/// as DisplayPresetService), and persists the per-display toggle by displayUUID.
@MainActor
final class BrightnessBoostService {
    static let shared = BrightnessBoostService()

    /// MPDisplayMgr instance; nil when MonitorPanel is unavailable.
    private let manager: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
              let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    /// Animates DisplayInfo.maxBrightness so the slider range grows and
    /// shrinks with the same ~125Hz ease-out glide brightness itself uses,
    /// instead of snapping the thumb to a new position. Also holds the
    /// disable-collapse animator (see collapseAndDisable), keyed the same way
    /// so a rapid re-enable cancels whichever of the two is running.
    private var maxAnimators: [CGDirectDisplayID: BrightnessAnimator] = [:]

    private func animateMaxBrightness(to target: Double, for display: DisplayInfo) {
        let animator = maxAnimators[display.displayID] ?? BrightnessAnimator()
        maxAnimators[display.displayID] = animator
        animator.animate(
            from: display.maxBrightness, to: target,
            steps: max(8, Int(0.2 / 0.008)), duration: 0.2
        ) { [weak display] value, _ in
            display?.maxBrightness = value
        }
    }

    /// Displays currently running the disable-collapse animation (see
    /// collapseAndDisable below). syncOverlay returns early for these so the
    /// headroom poll and other callers cannot fight the collapse mid-flight.
    private var collapsingDisplays: Set<CGDirectDisplayID> = []

    /// While any boost is engaged, the display's deliverable headroom moves
    /// with panel brightness and thermals, and macOS does not reliably post a
    /// notification when it drops. A factor above the deliverable range clips
    /// bright content to white, so poll and re-clamp; the loop ends itself
    /// once nothing is boosted.
    private var headroomPollTask: Task<Void, Never>?

    private func startHeadroomPollIfNeeded() {
        guard headroomPollTask == nil else { return }
        headroomPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self else { return }
                var anyBoosted = false
                for display in DisplayManagerAccessor.shared.displays where display.maxBrightness > 100 {
                    anyBoosted = true
                    self.syncOverlay(for: display)
                }
                if !anyBoosted {
                    self.headroomPollTask = nil
                    return
                }
            }
        }
    }

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // MARK: - Persistence (displayUUID keyed, survives displayID reassignment)

    private func enabledKey(_ uuid: String) -> String { "crisp.BoostEnabled.\(uuid)" }
    private func switchedHDRKey(_ uuid: String) -> String { "crisp.BoostSwitchedHDR.\(uuid)" }

    func isEnabled(for display: DisplayInfo) -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey(display.displayUUID))
    }

    // MARK: - Screen and headroom helpers

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screen(for: displayID)
    }

    /// Potential headroom: what the display could do (basis for eligibility and
    /// the slider ceiling). 1.0 on SDR-only displays.
    private func potentialHeadroom(for displayID: CGDirectDisplayID) -> Double {
        guard let s = screen(for: displayID) else { return 1.0 }
        return Double(s.maximumPotentialExtendedDynamicRangeColorComponentValue)
    }

    /// Current headroom: what the display can do right now (basis for clamping
    /// the overlay factor; macOS moves this with panel brightness and thermals).
    private func currentHeadroom(for displayID: CGDirectDisplayID) -> Double {
        guard let s = screen(for: displayID) else { return 1.0 }
        return Double(s.maximumExtendedDynamicRangeColorComponentValue)
    }

    // MARK: - Eligibility

    /// A display can boost when it reports usable EDR headroom (built-in XDR,
    /// or an external already in HDR mode) or when we know how to switch it
    /// into HDR mode (external with MonitorPanel HDR support).
    func isEligible(_ display: DisplayInfo) -> Bool {
        guard display.isOnline, !VirtualDisplayService.shared.isVirtualDisplay(display.displayID) else { return false }
        if potentialHeadroom(for: display.displayID) > 1.05 { return true }
        if !display.isBuiltin, supportsHDRMode(display.displayID) { return true }
        return false
    }

    // MARK: - Toggle

    /// Enable or disable boost. Async because switching an external monitor to
    /// HDR mode takes a moment to settle. Returns false when enabling failed
    /// (caller reverts the toggle UI).
    @discardableResult
    func setEnabled(_ enabled: Bool, for display: DisplayInfo) async -> Bool {
        let uuid = display.displayUUID
        if enabled {
            // A disable-collapse may still be running from a rapid off/on
            // flip; cancel it where it is (through the same maxAnimators slot
            // the collapse itself uses) so it cannot keep walking brightness
            // down after we re-enable, and clear isCollapsing so syncOverlay
            // stops skipping this display.
            BrightnessService.shared.cancelAnimation(for: display.displayID)
            maxAnimators[display.displayID]?.cancel()
            collapsingDisplays.remove(display.displayID)
            // Externals in SDR mode: switch to HDR first, remember that we did.
            if !display.isBuiltin, potentialHeadroom(for: display.displayID) <= 1.05 {
                guard supportsHDRMode(display.displayID), setHDRMode(true, for: display.displayID) else { return false }
                UserDefaults.standard.set(true, forKey: switchedHDRKey(uuid))
                // Give WindowServer a moment to re-sync the display in HDR mode.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(
                isBuiltin: display.isBuiltin, model: BrightnessBoostMath.currentModelIdentifier,
                potentialHeadroom: potential
            )
            guard newMax > 100 else {
                // HDR came up without usable headroom: undo and fail quietly.
                undoHDRSwitchIfNeeded(for: display)
                return false
            }
            UserDefaults.standard.set(true, forKey: enabledKey(uuid))
            animateMaxBrightness(to: newMax, for: display)
            syncOverlay(for: display)
            return true
        } else {
            UserDefaults.standard.set(false, forKey: enabledKey(uuid))
            collapseAndDisable(for: display)
            return true
        }
    }

    /// Single combined collapse: brightness and maxBrightness glide back to
    /// 100 together, driven by one progress animator, instead of fading
    /// brightness to 100 first and only then collapsing maxBrightness. That
    /// two-phase sequence made the slider thumb (value/max) visibly drop
    /// then rise; driving both from the same progress keeps it monotonic.
    /// sliderMax for the overlay factor is the frozen starting maxBrightness
    /// (max0), not the live (shrinking) one, so the multiplier tracks the
    /// thumb instead of jumping.
    private func collapseAndDisable(for display: DisplayInfo) {
        let displayID = display.displayID
        let v0 = display.brightness
        let max0 = display.maxBrightness
        guard abs(v0 - 100) > 0.001 || abs(max0 - 100) > 0.001 else {
            finishDisable(for: display)
            return
        }
        collapsingDisplays.insert(displayID)
        let animator = maxAnimators[displayID] ?? BrightnessAnimator()
        maxAnimators[displayID] = animator
        animator.animate(
            from: 1.0, to: 0.0,
            steps: max(8, Int(0.35 / 0.008)), duration: 0.35
        ) { [weak self, weak display] p, isLast in
            guard let self, let display else { return }
            display.brightness = 100 + p * (v0 - 100)
            display.maxBrightness = 100 + p * (max0 - 100)
            let factor = BrightnessBoostMath.overlayFactor(
                brightness: display.brightness, sliderMax: max0,
                isBuiltin: display.isBuiltin, model: BrightnessBoostMath.currentModelIdentifier,
                currentEDR: self.currentHeadroom(for: displayID)
            )
            EDROverlayManager.shared.setFactor(factor, for: displayID)
            if isLast {
                self.collapsingDisplays.remove(displayID)
                self.finishDisable(for: display)
            }
        }
    }

    private func finishDisable(for display: DisplayInfo) {
        undoHDRSwitchIfNeeded(for: display)
        // Close the EDR surface only after everything is static: closing
        // exits EDR mode, and doing that mid-motion is what flashed.
        let displayID = display.displayID
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !self.isEnabled(for: display) else { return }
            EDROverlayManager.shared.removeOverlay(for: displayID)
        }
    }

    private func undoHDRSwitchIfNeeded(for display: DisplayInfo) {
        let key = switchedHDRKey(display.displayUUID)
        guard UserDefaults.standard.bool(forKey: key) else { return }
        _ = setHDRMode(false, for: display.displayID)
        UserDefaults.standard.set(false, forKey: key)
    }

    // MARK: - Overlay sync (called on every brightness change)

    /// Recompute and apply the overlay factor for the display's current
    /// brightness. Live currentEDR gates the target: below
    /// BrightnessBoostMath.hdrReadyThreshold the panel has not ramped EDR yet,
    /// so a small pending factor is applied instead of the full target (see
    /// BrightnessBoostMath.overlayFactor). Headroom changes post
    /// didChangeScreenParameters (observed above) and are also polled (see
    /// startHeadroomPollIfNeeded), so the factor converges to what the panel
    /// can actually deliver within a beat of engaging.
    func syncOverlay(for display: DisplayInfo) {
        guard display.maxBrightness > 100 else { return }
        // The disable-collapse animation drives the overlay factor itself;
        // letting this run concurrently (e.g. from the headroom poll) would
        // fight it.
        guard !collapsingDisplays.contains(display.displayID) else { return }
        let factor = BrightnessBoostMath.overlayFactor(
            brightness: display.brightness,
            sliderMax: display.maxBrightness,
            isBuiltin: display.isBuiltin,
            model: BrightnessBoostMath.currentModelIdentifier,
            currentEDR: currentHeadroom(for: display.displayID)
        )
        EDROverlayManager.shared.setFactor(factor, for: display.displayID)
        if factor > 1.001 { startHeadroomPollIfNeeded() }
    }

    // MARK: - Lifecycle

    /// Re-establish boost state for every connected display. Called at launch,
    /// after wake, and on display reconfiguration.
    func reapplyAll() {
        for display in DisplayManagerAccessor.shared.displays where isEnabled(for: display) {
            guard isEligible(display) else { continue }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(
                isBuiltin: display.isBuiltin, model: BrightnessBoostMath.currentModelIdentifier,
                potentialHeadroom: potential
            )
            guard newMax > 100 else { continue }
            display.maxBrightness = newMax
            syncOverlay(for: display)
        }
        EDROverlayManager.shared.rerenderAll()
    }

    /// Quit: drop overlays (they die with the process anyway) and restore SDR
    /// on externals we switched, so a monitor is never left in HDR mode with
    /// no boost and no DDC control.
    func prepareForTermination() {
        EDROverlayManager.shared.removeAll()
        for display in DisplayManagerAccessor.shared.displays {
            undoHDRSwitchIfNeeded(for: display)
        }
    }

    @objc private func screenParametersChanged() {
        // Reconcile after connect/disconnect storms settle (mirrors the panel's
        // own debounce; mid-reconfig geometry and headroom reads are garbage).
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self.reapplyAll()
        }
    }

    // MARK: - MonitorPanel HDR mode (private API; selectors verified by the Task 1 spike)

    private func mpDisplay(for displayID: CGDirectDisplayID) -> NSObject? {
        guard let displays = manager?.value(forKey: "displays") as? [NSObject] else { return nil }
        return displays.first { ($0.value(forKey: "displayID") as? UInt32) == displayID }
    }

    private func supportsHDRMode(_ displayID: CGDirectDisplayID) -> Bool {
        guard let d = mpDisplay(for: displayID) else { return false }
        return (d.value(forKey: "hasHDRModes") as? Bool) == true
    }

    @discardableResult
    private func setHDRMode(_ on: Bool, for displayID: CGDirectDisplayID) -> Bool {
        guard let d = mpDisplay(for: displayID) else { return false }
        let sel = NSSelectorFromString("setPreferHDRModes:")
        guard d.responds(to: sel) else { return false }
        typealias Fn = @convention(c) (NSObject, Selector, Bool) -> Void
        unsafeBitCast(d.method(for: sel), to: Fn.self)(d, sel, on)
        return true
    }
}
