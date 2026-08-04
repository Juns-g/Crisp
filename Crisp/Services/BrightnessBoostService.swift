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
            // Externals in SDR mode: switch to HDR first, remember that we did.
            if !display.isBuiltin, potentialHeadroom(for: display.displayID) <= 1.05 {
                guard supportsHDRMode(display.displayID), setHDRMode(true, for: display.displayID) else { return false }
                UserDefaults.standard.set(true, forKey: switchedHDRKey(uuid))
                // Give WindowServer a moment to re-sync the display in HDR mode.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
            guard newMax > 100 else {
                // HDR came up without usable headroom: undo and fail quietly.
                undoHDRSwitchIfNeeded(for: display)
                return false
            }
            UserDefaults.standard.set(true, forKey: enabledKey(uuid))
            display.maxBrightness = newMax
            syncOverlay(for: display)
            return true
        } else {
            UserDefaults.standard.set(false, forKey: enabledKey(uuid))
            if display.brightness > 100 {
                // Glide down through the boost region first: maxBrightness is
                // still raised, so each fade step's syncOverlay walks the
                // overlay factor down and removes the overlay when it reaches
                // 1.0. Teardown happens after the fade lands.
                BrightnessService.shared.setBrightnessSmooth(100, for: display)
                try? await Task.sleep(nanoseconds: 300_000_000)
                // The user may have re-enabled during the glide; leave the
                // re-enabled state alone.
                guard !isEnabled(for: display) else { return true }
            }
            display.maxBrightness = 100
            EDROverlayManager.shared.removeOverlay(for: display.displayID)
            undoHDRSwitchIfNeeded(for: display)
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
    /// brightness. Spike finding: current headroom reads 1.0 until EDR content
    /// is on screen, so gating on it would deadlock the overlay off. Instead
    /// map onto the capped potential, and clamp by current headroom only once
    /// macOS has ramped it above 1. Headroom changes post
    /// didChangeScreenParameters (observed above), so the factor converges to
    /// what the panel can actually deliver within a beat of engaging.
    func syncOverlay(for display: DisplayInfo) {
        guard display.maxBrightness > 100 else { return }
        let ceiling = min(potentialHeadroom(for: display.displayID), 2.0)
        var factor = BrightnessBoostMath.overlayFactor(
            brightness: display.brightness,
            sliderMax: display.maxBrightness,
            currentHeadroom: ceiling
        )
        let current = currentHeadroom(for: display.displayID)
        if current > 1.0 { factor = min(factor, current) }
        EDROverlayManager.shared.setFactor(factor, for: display.displayID)
    }

    // MARK: - Lifecycle

    /// Re-establish boost state for every connected display. Called at launch,
    /// after wake, and on display reconfiguration.
    func reapplyAll() {
        for display in DisplayManagerAccessor.shared.displays where isEnabled(for: display) {
            guard isEligible(display) else { continue }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
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
