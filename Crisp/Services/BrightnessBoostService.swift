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
    /// shrinks with the same 60Hz ease-out glide brightness itself uses,
    /// instead of snapping the thumb to a new position.
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
            // A disable-glide may still be running from a rapid off/on flip;
            // stop it where it is so it cannot keep walking brightness down
            // (and drop the overlay) after we re-enable.
            BrightnessService.shared.cancelAnimation(for: display.displayID)
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
            if display.brightness > 100 {
                // Glide down through the boost region first: maxBrightness is
                // still raised, so each fade step's syncOverlay walks the
                // overlay factor down with it.
                BrightnessService.shared.setBrightnessSmooth(100, for: display)
                try? await Task.sleep(nanoseconds: 300_000_000)
                // The user may have re-enabled during the glide; leave the
                // re-enabled state alone.
                guard !isEnabled(for: display) else { return true }
            }
            animateMaxBrightness(to: 100, for: display)
            undoHDRSwitchIfNeeded(for: display)
            // Close the EDR surface only after everything is static: closing
            // exits EDR mode, and doing that mid-motion is what flashed.
            let displayID = display.displayID
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !self.isEnabled(for: display) else { return }
                EDROverlayManager.shared.removeOverlay(for: displayID)
            }
            return true
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
