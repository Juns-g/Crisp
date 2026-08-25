// Crisp/Services/BrightnessBoostService.swift
import AppKit
import CoreGraphics
import ObjectiveC
#if canImport(CrispControlCore)
import CrispControlCore
#endif

/// All private MonitorPanel ABI calls live here. Selector presence and the full
/// Objective-C method signature are checked before invocation; callers receive
/// nil/false on ABI drift.
@MainActor
private final class MonitorPanelRuntimeAdapter: HDRPreferenceAdapting {
    private let manager: NSObject?

    init() {
        guard dlopen("/System/Library/PrivateFrameworks/MonitorPanel.framework/MonitorPanel", RTLD_LAZY) != nil,
              let cls = NSClassFromString("MPDisplayMgr") as? NSObject.Type else {
            manager = nil
            return
        }
        manager = cls.init()
    }

    func snapshot(for displayID: CGDirectDisplayID) -> HDRAdapterState? {
        guard let state = readState(displayID: displayID), state.canSet else { return nil }
        return state
    }

    func readState(displayID: UInt32) -> HDRAdapterState? {
        guard let display = displayObject(for: displayID),
              let supports = boolGetter("hasHDRModes", on: display),
              let prefers = boolGetter("preferHDRModes", on: display) else { return nil }
        let setter = NSSelectorFromString("setPreferHDRModes:")
        return HDRAdapterState(
            supportsHDR: supports,
            prefersHDR: prefers,
            canSet: hasCompatibleMethod(setter, on: display, as: .boolSetter),
            identity: String(describing: ObjectIdentifier(display))
        )
    }

    func setPreference(
        _ enabled: Bool,
        displayID: UInt32,
        expectedIdentity: String
    ) -> Bool {
        guard let display = displayObject(for: displayID),
              String(describing: ObjectIdentifier(display)) == expectedIdentity else { return false }
        let selector = NSSelectorFromString("setPreferHDRModes:")
        guard let method = compatibleMethod(selector, on: display, as: .boolSetter) else { return false }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(display, selector, enabled)
        return true
    }

    private func displayObject(for displayID: CGDirectDisplayID) -> NSObject? {
        let displaysSelector = NSSelectorFromString("displays")
        guard let manager,
              hasCompatibleMethod(displaysSelector, on: manager, as: .displaysGetter),
              let value = manager.perform(displaysSelector)?.takeUnretainedValue(),
              let displays = value as? [NSObject] else { return nil }
        return displays.first { display in
            let selector = NSSelectorFromString("displayID")
            guard let method = compatibleMethod(selector, on: display, as: .displayIDGetter) else { return false }
            typealias Getter = @convention(c) (AnyObject, Selector) -> UInt32
            return unsafeBitCast(method_getImplementation(method), to: Getter.self)(
                display, selector
            ) == displayID
        }
    }

    private func boolGetter(_ name: String, on object: NSObject) -> Bool? {
        let selector = NSSelectorFromString(name)
        guard let method = compatibleMethod(selector, on: object, as: .boolGetter) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(method_getImplementation(method), to: Getter.self)(object, selector)
    }

    private func hasCompatibleMethod(
        _ selector: Selector,
        on object: NSObject,
        as method: MonitorPanelABIMethod
    ) -> Bool {
        compatibleMethod(selector, on: object, as: method) != nil
    }

    private func compatibleMethod(
        _ selector: Selector,
        on object: NSObject,
        as expectedMethod: MonitorPanelABIMethod
    ) -> Method? {
        guard object.responds(to: selector),
              let runtimeMethod = class_getInstanceMethod(type(of: object), selector),
              let encoding = methodEncoding(runtimeMethod) else { return nil }
        guard MonitorPanelABISignatureValidator.isCompatible(
            encoding,
            with: expectedMethod
        ) else { return nil }
        return runtimeMethod
    }

    private func methodEncoding(_ method: Method) -> ObjectiveCMethodEncoding? {
        let returnType = method_copyReturnType(method)
        defer { free(returnType) }
        var argumentTypes: [String] = []
        argumentTypes.reserveCapacity(Int(method_getNumberOfArguments(method)))
        for index in 0..<method_getNumberOfArguments(method) {
            guard let argumentType = method_copyArgumentType(method, index) else { return nil }
            argumentTypes.append(String(cString: argumentType))
            free(argumentType)
        }
        return ObjectiveCMethodEncoding(
            returnType: String(cString: returnType),
            argumentTypes: argumentTypes
        )
    }
}

/// Policy brain for the Extra Brightness (EDR upscaling) feature. Decides which
/// displays can boost, maps brightness above 100% to an overlay factor (via
/// BrightnessBoostMath + EDROverlayManager), switches external monitors into
/// HDR mode when boost needs it, and persists the per-display toggle by
/// displayUUID. Also exposes the explicit per-display HDR toggle (private
/// MonitorPanel.framework behind the runtime-checked adapter above).
@MainActor
final class BrightnessBoostService {
    static let shared = BrightnessBoostService()
    private let monitorPanel = MonitorPanelRuntimeAdapter()

    /// Animates DisplayInfo.maxBrightness so the slider range grows and
    /// shrinks with the same ~125Hz ease-out glide brightness itself uses,
    /// instead of snapping the thumb to a new position. Also holds the
    /// disable-collapse animator (see collapseAndDisable), keyed the same way
    /// so a rapid re-enable cancels whichever of the two is running.
    private var maxAnimators: [CGDirectDisplayID: BrightnessAnimator] = [:]
    private var boostTransitions = BoostTransitionCoordinator()
    private var hdrMutations = HDRMutationCoordinator()
    /// Last factor committed through Crisp's app-owned overlay/transfer-table
    /// path. Queued external writes publish only from their completion callback
    /// after the UUID guard and transfer-table write both ran.
    private var appliedFactorCommits = AppliedFactorCommitCoordinator()

    private func recordControlAppliedFactor(_ factor: Double, for display: DisplayInfo) {
        let identity = displayIdentity(display)
        let token = appliedFactorCommits.begin(
            uuid: display.displayUUID,
            identity: identity,
            factor: factor
        )
        _ = appliedFactorCommits.complete(
            token,
            queueAccepted: true,
            currentUUID: display.displayUUID,
            currentIdentity: identity
        )
    }

    private func queueExternalFactor(_ factor: Double, for display: DisplayInfo) {
        let uuid = display.displayUUID
        let displayID = display.displayID
        let identity = displayIdentity(display)
        let token = appliedFactorCommits.begin(uuid: uuid, identity: identity, factor: factor)
        BrightnessService.shared.setBoostFactor(
            factor,
            for: displayID,
            expectedDisplayUUID: uuid
        ) { [weak self] queueAccepted in
            Task { @MainActor [weak self] in
                guard let self,
                      let current = DisplayManagerAccessor.shared.displays.first(where: {
                          $0.displayUUID == uuid && $0.displayID == displayID
                      }) else { return }
                _ = self.appliedFactorCommits.complete(
                    token,
                    queueAccepted: queueAccepted,
                    currentUUID: current.displayUUID,
                    currentIdentity: self.displayIdentity(current)
                )
            }
        }
    }

    /// Restore the app-owned boost path to identity and await the external
    /// transfer-table queue. This verifies committed Crisp app state only.
    private func restoreIdentityFactor(for display: DisplayInfo) async throws -> Bool {
        if display.isBuiltin {
            guard EDROverlayManager.shared.setFactor(1, for: display.displayID) else { return false }
            recordControlAppliedFactor(1, for: display)
        } else {
            let identity = displayIdentity(display)
            let token = appliedFactorCommits.begin(
                uuid: display.displayUUID,
                identity: identity,
                factor: 1
            )
            let queueAccepted = await BrightnessService.shared.setBoostFactorForControl(
                1, for: display.displayID, expectedDisplayUUID: display.displayUUID
            )
            try Task.checkCancellation()
            guard currentDisplayMatches(display) else { return false }
            guard appliedFactorCommits.complete(
                token,
                queueAccepted: queueAccepted,
                currentUUID: display.displayUUID,
                currentIdentity: displayIdentity(display)
            ) else { return false }
        }
        return true
    }

    private func displayIdentity(_ display: DisplayInfo) -> String {
        String(describing: ObjectIdentifier(display))
    }

    private func currentDisplayMatches(_ display: DisplayInfo) -> Bool {
        DisplayManagerAccessor.shared.displays.contains {
            $0 === display && $0.displayUUID == display.displayUUID && $0.displayID == display.displayID
        }
    }

    private func transitionAccepts(_ token: BoostTransitionToken, display: DisplayInfo) -> Bool {
        currentDisplayMatches(display) && boostTransitions.accepts(
            token,
            currentUUID: display.displayUUID,
            currentIdentity: displayIdentity(display)
        )
    }

    private func animateMaxBrightness(
        to target: Double,
        for display: DisplayInfo,
        token: BoostTransitionToken
    ) {
        let animator = maxAnimators[display.displayID] ?? BrightnessAnimator()
        maxAnimators[display.displayID] = animator
        animator.animate(
            from: display.maxBrightness, to: target,
            steps: max(8, Int(0.2 / 0.008)), duration: 0.2
        ) { [weak self, weak display] value, _ in
            guard let self, let display, self.transitionAccepts(token, display: display) else { return }
            display.maxBrightness = value
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

    /// Pending post-reconfiguration reconcile. One at a time: a connect or
    /// disconnect storm posts didChangeScreenParametersNotification many
    /// times, and each reapplyAll is a full DDC/gamma/overlay pass.
    private var reapplyAfterReconfigTask: Task<Void, Never>?

    /// When an enabled external first reported potentialHeadroom at or below
    /// hdrReadyThreshold: HDR capability disappeared out from under it (user
    /// turned HDR off, or a HiDPI mode switch dropped HDR advertisement).
    /// Auto-disable fires only after the loss has persisted 1.5s (wall clock,
    /// so the fast-poll window cannot rush it) to ride out transient dips
    /// during mode-change storms.
    private var headroomLossSince: [CGDirectDisplayID: Date] = [:]

    /// While set and in the future, the poll runs at 16ms instead of 500ms.
    /// Armed when a display first enters the boost region: macOS ramps EDR
    /// headroom over the next second or two, and catching that ramp in 500ms
    /// chunks reads as laggy, steppy brightness right when the user starts
    /// pushing the slider past 100.
    private var fastPollUntil: Date?
    /// Displays whose overlay factor is currently above identity; used to
    /// detect the first entry into the boost region (arms fastPollUntil).
    private var activeBoostDisplays: Set<CGDirectDisplayID> = []

    private func startHeadroomPollIfNeeded() {
        guard headroomPollTask == nil else { return }
        headroomPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let fast = self.flatMap { s in s.fastPollUntil.map { Date() < $0 } } ?? false
                try? await Task.sleep(nanoseconds: fast ? 16_000_000 : 500_000_000)
                guard let self else { return }
                var anyBoosted = false
                // Visit inert-but-enabled displays too (flag set, capability
                // currently missing, maxBrightness back at 100): the debounced
                // auto-disable below is what resolves them; syncOverlay
                // no-ops for them.
                for display in DisplayManagerAccessor.shared.displays
                where display.maxBrightness > 100 || self.isEnabled(for: display) {
                    anyBoosted = true
                    self.syncOverlay(for: display)
                    guard !display.isBuiltin else { continue }
                    guard self.isEnabled(for: display), self.potentialHeadroom(for: display.displayID) <= 1.05 else {
                        self.headroomLossSince.removeValue(forKey: display.displayID)
                        continue
                    }
                    let since = self.headroomLossSince[display.displayID] ?? Date()
                    self.headroomLossSince[display.displayID] = since
                    if Date().timeIntervalSince(since) >= 1.5 {
                        self.headroomLossSince.removeValue(forKey: display.displayID)
                        _ = try? await self.setEnabled(false, for: display)
                    }
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

    /// Narrow read-only automation snapshot. Values are relative EDR component
    /// headroom reported by NSScreen, never inferred nits.
    func controlHeadroomSnapshot(for display: DisplayInfo) -> EDRHeadroomSnapshot {
        let appliedFactor = appliedFactorCommits.appliedFactor(
            uuid: display.displayUUID,
            identity: displayIdentity(display)
        )
        return EDRHeadroomSnapshot(
            potential: potentialHeadroom(for: display.displayID),
            current: currentHeadroom(for: display.displayID),
            appliedFactor: appliedFactor,
            factorVerification: appliedFactor == nil ? nil : "app_state"
        )
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

    /// A disable remains available after live eligibility disappears when
    /// Crisp still has persisted or active boost state to collapse and clear.
    func needsDisableCleanup(for display: DisplayInfo) -> Bool {
        isEnabled(for: display)
            || display.maxBrightness > 100
            || display.brightness > 100
            || activeBoostDisplays.contains(display.displayID)
            || collapsingDisplays.contains(display.displayID)
    }

    // MARK: - Toggle

    /// Enable or disable boost. Async because switching an external monitor to
    /// HDR mode takes a moment to settle. Returns false when enabling failed
    /// (caller reverts the toggle UI).
    @discardableResult
    func setEnabled(_ enabled: Bool, for display: DisplayInfo) async throws -> Bool {
        let uuid = display.displayUUID
        let token = boostTransitions.begin(
            uuid: uuid, identity: displayIdentity(display), enabled: enabled
        )
        if enabled {
            // A disable-collapse may still be running from a rapid off/on
            // flip; cancel it where it is (through the same maxAnimators slot
            // the collapse itself uses) so it cannot keep walking brightness
            // down after we re-enable, and clear isCollapsing so syncOverlay
            // stops skipping this display.
            BrightnessService.shared.cancelAnimation(for: display.displayID)
            maxAnimators[display.displayID]?.cancel()
            collapsingDisplays.remove(display.displayID)
            // Externals in SDR mode: switch to HDR first. A matching live
            // preference read-back is necessary but not sufficient; EDR
            // headroom can appear later, so readiness settles separately.
            var switchedHDRForThisAttempt = false
            var potential = potentialHeadroom(for: display.displayID)
            if !display.isBuiltin, potential <= 1.05 {
                guard supportsHDRMode(display.displayID) else { return false }
                if controlHDRState(for: display) != true {
                    guard try await setHDRMode(true, for: display) else { return false }
                    switchedHDRForThisAttempt = true
                }
                let settlement = try await EDRHeadroomSettlement.wait(
                    maxSamples: 20,
                    threshold: 1.05,
                    isCurrent: {
                        self.transitionAccepts(token, display: display)
                    },
                    isCapable: {
                        self.supportsHDRMode(display.displayID)
                            && self.controlHDRState(for: display) == true
                    },
                    potentialHeadroom: {
                        self.potentialHeadroom(for: display.displayID)
                    },
                    pause: {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                )
                try Task.checkCancellation()
                switch settlement {
                case let .ready(potentialHeadroom):
                    potential = potentialHeadroom
                case .timedOut, .capabilityLost:
                    if switchedHDRForThisAttempt, transitionAccepts(token, display: display) {
                        _ = try await setHDRMode(false, for: display, requiring: token)
                    }
                    return false
                case .invalidated:
                    return false
                }
            }
            guard transitionAccepts(token, display: display) else { return false }
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
            guard newMax > 100 else {
                // No usable headroom: fail quietly. A user-set HDR mode is
                // left alone (explicit toggle), but an HDR switch made by
                // THIS failed attempt is rolled back: a half-engaged switch
                // (preference recorded, mode never applied) leaves the OS
                // rendering HDR into an SDR link, washing the screen out.
                if switchedHDRForThisAttempt {
                    _ = try await setHDRMode(false, for: display, requiring: token)
                }
                return false
            }
            UserDefaults.standard.set(true, forKey: enabledKey(uuid))
            guard boostTransitions.completeEnable(token) else { return false }
            animateMaxBrightness(to: newMax, for: display, token: token)
            syncOverlay(for: display)
            try Task.checkCancellation()
            return true
        } else {
            UserDefaults.standard.set(false, forKey: enabledKey(uuid))
            return try await collapseAndDisable(for: display, token: token)
        }
    }

    /// Automation needs more truth than the GUI's legacy Boolean completion:
    /// a disable can be accepted and persisted while a same-display collapse
    /// is still observable. Unknown identity or terminal-factor outcomes stay
    /// indeterminate, and cancellation continues to throw.
    func setEnabledForControl(
        _ enabled: Bool,
        for display: DisplayInfo
    ) async throws -> ExtraBrightnessControlMutationOutcome {
        if enabled {
            return try await setEnabled(true, for: display)
                ? .accepted : .rejectedBeforeAcceptance
        }
        let operationCompleted = try await setEnabled(enabled, for: display)
        return ExtraBrightnessControlMutationOutcome.classify(
            mutationAccepted: true,
            operationCompleted: operationCompleted,
            identityMatches: currentDisplayMatches(display),
            persistedEnabled: isEnabled(for: display),
            liveEnabled: display.maxBrightness > 100,
            maxBrightness: display.maxBrightness,
            cleanupInProgress: collapsingDisplays.contains(display.displayID)
        )
    }

    /// Single combined collapse: brightness and maxBrightness glide back to
    /// 100 together, driven by one progress animator, instead of fading
    /// brightness to 100 first and only then collapsing maxBrightness. That
    /// two-phase sequence made the slider thumb (value/max) visibly drop
    /// then rise; driving both from the same progress keeps it monotonic.
    /// sliderMax for the overlay factor is the frozen starting maxBrightness
    /// (max0), not the live (shrinking) one, so the multiplier tracks the
    /// thumb instead of jumping.
    private func collapseAndDisable(
        for display: DisplayInfo,
        token: BoostTransitionToken
    ) async throws -> Bool {
        let displayID = display.displayID
        let v0 = display.brightness
        let max0 = display.maxBrightness
        guard abs(v0 - 100) > 0.001 || abs(max0 - 100) > 0.001 else {
            display.brightness = min(display.brightness, 100)
            display.maxBrightness = 100
            guard try await restoreIdentityFactor(for: display),
                  transitionAccepts(token, display: display) else { return false }
            return try await finishDisable(for: display, token: token)
        }
        collapsingDisplays.insert(displayID)
        let animator = maxAnimators[displayID] ?? BrightnessAnimator()
        maxAnimators[displayID] = animator
        animator.animate(
            from: 1.0, to: 0.0,
            steps: max(8, Int(0.35 / 0.008)), duration: 0.35
        ) { [weak self, weak display] p, isLast in
            guard let self else { return }
            guard let display else {
                // The display deallocated mid-collapse (disconnect). Drop the
                // collapse marker so a reconnect reusing this CGDirectDisplayID
                // is not stuck with syncOverlay muted forever.
                self.collapsingDisplays.remove(displayID)
                self.maxAnimators[displayID]?.cancel()
                return
            }
            guard self.transitionAccepts(token, display: display) else { return }
            // A brightness already at or below 100 is in the native range and
            // must stay put; only the boosted excess collapses toward 100.
            let vEnd = min(v0, 100)
            display.brightness = vEnd + p * (v0 - vEnd)
            display.maxBrightness = 100 + p * (max0 - 100)
            if display.isBuiltin {
                let factor = BrightnessBoostMath.overlayFactor(
                    brightness: display.brightness, sliderMax: max0,
                    currentEDR: self.currentHeadroom(for: displayID),
                    potentialHeadroom: self.potentialHeadroom(for: displayID)
                )
                if EDROverlayManager.shared.setFactor(factor, for: displayID) {
                    self.recordControlAppliedFactor(factor, for: display)
                }
            } else {
                let factor = BrightnessBoostMath.externalBoostFactor(
                    brightness: display.brightness, sliderMax: max0)
                self.queueExternalFactor(factor, for: display)
            }
            if isLast {
                self.collapsingDisplays.remove(displayID)
            }
        }
        var polls = 0
        while collapsingDisplays.contains(displayID), polls < 100 {
            try await Task.sleep(nanoseconds: 20_000_000)
            guard transitionAccepts(token, display: display) else { return false }
            polls += 1
        }
        guard !collapsingDisplays.contains(displayID),
              display.brightness <= 100.001, display.maxBrightness <= 100.001 else { return false }
        display.brightness = min(display.brightness, 100)
        display.maxBrightness = 100
        guard try await restoreIdentityFactor(for: display),
              transitionAccepts(token, display: display) else { return false }
        return try await finishDisable(for: display, token: token)
    }

    private func finishDisable(
        for display: DisplayInfo,
        token: BoostTransitionToken
    ) async throws -> Bool {
        // Close the EDR surface only after everything is static: closing
        // exits EDR mode, and doing that mid-motion is what flashed.
        let displayID = display.displayID
        try await Task.sleep(nanoseconds: 2_000_000_000)
        guard transitionAccepts(token, display: display), !isEnabled(for: display) else { return false }
        EDROverlayManager.shared.removeOverlay(for: displayID)
        return boostTransitions.completeDisable(token, atIdentity: true)
    }

    // MARK: - Overlay sync (called on every brightness change)

    /// Recompute and apply the overlay factor for the display's current
    /// brightness. Live currentEDR gates the target: below
    /// BrightnessBoostMath.hdrReadyThreshold the panel has not ramped EDR yet,
    /// so a small pending factor is applied instead of the full target (see
    /// BrightnessBoostMath.overlayFactor); potentialHeadroom gates that pending
    /// factor itself, so a display genuinely back in SDR gets 1.0 instead of a
    /// nudge that can never ramp. Headroom changes post didChangeScreenParameters
    /// (observed above) and are also polled (see startHeadroomPollIfNeeded), so
    /// the factor converges to what the panel can actually deliver within a
    /// beat of engaging, and the poll auto-disables boost once potentialHeadroom
    /// stays lost for a display that needs it (see headroomLossPolls).
    func syncOverlay(for display: DisplayInfo) {
        guard display.maxBrightness > 100 else { return }
        // The disable-collapse animation drives the overlay factor itself;
        // letting this run concurrently (e.g. from the headroom poll) would
        // fight it.
        guard !collapsingDisplays.contains(display.displayID) else { return }
        guard boostTransitions.headroomMaySync(
            uuid: display.displayUUID, identity: displayIdentity(display)
        ) else { return }
        if display.isBuiltin {
            let factor = BrightnessBoostMath.overlayFactor(
                brightness: display.brightness,
                sliderMax: display.maxBrightness,
                currentEDR: currentHeadroom(for: display.displayID),
                potentialHeadroom: potentialHeadroom(for: display.displayID)
            )
            if EDROverlayManager.shared.setFactor(factor, for: display.displayID) {
                recordControlAppliedFactor(factor, for: display)
            }
            // First entry into the boost region arms the fast-poll window: the
            // EDR ramp that follows is what the poll needs to track closely.
            if factor > 1.001 {
                if activeBoostDisplays.insert(display.displayID).inserted {
                    fastPollUntil = Date().addingTimeInterval(3.0)
                }
            } else {
                activeBoostDisplays.remove(display.displayID)
            }
        } else {
            // Externals boost through the display transfer table, not the EDR
            // overlay (see BrightnessBoostMath.externalBoostCeiling for why).
            // Written unconditionally: the 500ms poll landing here re-heals
            // the table after an ICC-restore clobber without extra plumbing.
            let factor = BrightnessBoostMath.externalBoostFactor(
                brightness: display.brightness, sliderMax: display.maxBrightness)
            queueExternalFactor(factor, for: display)
        }
        if display.maxBrightness > 100 { startHeadroomPollIfNeeded() }
    }

    // MARK: - Lifecycle

    /// Re-establish boost state for every connected display. Called at launch,
    /// after wake, and on display reconfiguration.
    func reapplyAll() {
        syncHDRRouting()
        var anyEnabled = false
        for display in DisplayManagerAccessor.shared.displays {
            guard isEnabled(for: display) else {
                if display.maxBrightness > 100 {
                    display.brightness = min(display.brightness, 100)
                    display.maxBrightness = 100
                    if display.isBuiltin {
                        EDROverlayManager.shared.removeOverlay(for: display.displayID)
                        recordControlAppliedFactor(1, for: display)
                    } else {
                        queueExternalFactor(1, for: display)
                    }
                }
                continue
            }
            anyEnabled = true
            guard isEligible(display) else { continue }
            let potential = potentialHeadroom(for: display.displayID)
            let newMax = BrightnessBoostMath.sliderMax(potentialHeadroom: potential)
            // No usable headroom right now: do NOT decide anything here. Wake
            // and reconfig headroom reads are unreliable single samples; the
            // headroom poll below owns auto-disable with a debounce, and
            // re-engagement happens on the next reapply once reads are sane.
            guard newMax > 100 else { continue }
            display.maxBrightness = newMax
            syncOverlay(for: display)
        }
        // Ensure the poll is watching every enabled display, including inert
        // ones (flag set but capability currently missing), so the debounced
        // auto-disable can resolve them into a coherent off state.
        if anyEnabled { startHeadroomPollIfNeeded() }
        EDROverlayManager.shared.rerenderAll()
    }

    /// Quit: drop overlays (they die with the process anyway). HDR mode is
    /// left as the user set it: it is now an explicit per-display toggle (see
    /// HDRToggleView), and boost no longer silently reverts it on exit.
    func prepareForTermination() {
        EDROverlayManager.shared.removeAll()
    }

    /// Drop all per-display state for a disconnected display so a reused
    /// displayID cannot inherit it (same hazard as BrightnessService's
    /// invalidateDDCState; DisplayManager calls both from its removed loop).
    func invalidate(for displayID: CGDirectDisplayID) {
        if let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID }) {
            boostTransitions.invalidate(uuid: display.displayUUID, identity: displayIdentity(display))
            appliedFactorCommits.removeAll()
            hdrMutations = HDRMutationCoordinator()
        }
        maxAnimators[displayID]?.cancel()
        maxAnimators.removeValue(forKey: displayID)
        headroomLossSince.removeValue(forKey: displayID)
        activeBoostDisplays.remove(displayID)
        hdrRequestGeneration.removeValue(forKey: displayID)
        collapsingDisplays.remove(displayID)
        hdrSupportCache.removeValue(forKey: displayID)
    }

    @objc private func screenParametersChanged() {
        // DisplayIDs can be reassigned across a reconfiguration; drop the
        // capability cache and all in-flight identity generations before
        // anything re-reads or mutates a potentially re-used display ID.
        hdrSupportCache.removeAll()
        boostTransitions = BoostTransitionCoordinator()
        hdrMutations = HDRMutationCoordinator()
        hdrRequestGeneration.removeAll()
        maxAnimators.values.forEach { $0.cancel() }
        maxAnimators.removeAll()
        collapsingDisplays.removeAll()
        appliedFactorCommits.removeAll()
        headroomPollTask?.cancel()
        headroomPollTask = nil
        headroomLossSince.removeAll()
        activeBoostDisplays.removeAll()
        fastPollUntil = nil
        // Reconcile ONCE after connect/disconnect storms settle (mirrors the
        // panel's own debounce; mid-reconfig geometry and headroom reads are
        // garbage): cancel any reconcile a previous notification scheduled.
        reapplyAfterReconfigTask?.cancel()
        reapplyAfterReconfigTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.reapplyAll()
        }
    }

    // MARK: - HDR toggle (explicit, per-display)

    /// Whether this display is offered the explicit HDR row at all: externals
    /// only (the built-in panel never shows it, matching System Settings)
    /// that MonitorPanel reports as HDR-capable.
    func isEligibleForHDRToggle(_ display: DisplayInfo) -> Bool {
        !display.isBuiltin && supportsHDRMode(display.displayID)
    }

    /// Live HDR mode state, read straight from MPDisplay (not persisted: the
    /// OS already remembers HDR preference itself).
    func isHDREnabled(for display: DisplayInfo) -> Bool {
        controlHDRState(for: display) == true
    }

    /// Narrow read-only automation state. Nil means MonitorPanel cannot
    /// currently provide a live preference value for this display.
    func controlHDRState(for display: DisplayInfo) -> Bool? {
        monitorPanel.readState(displayID: display.displayID)?.prefersHDR
    }

    /// Newest HDR-preference request per display. An off request waits out
    /// the boost collapse before switching modes; if a newer request lands
    /// during that wait, the older one must not fire its stale mode switch
    /// afterward (a fast off-then-on flip would otherwise end on SDR half a
    /// second after the user chose HDR).
    private var hdrRequestGeneration: [CGDirectDisplayID: Int] = [:]

    /// Explicit HDR on/off for a display. Turning off while boost is enabled
    /// for it first runs boost's own disable-collapse to completion (waiting
    /// out collapsingDisplays, then a short settle) so brightness is back at
    /// 100 before the mode switch, instead of the collapse animation fighting
    /// an SDR display underneath it.
    @discardableResult
    func setHDRPreference(_ on: Bool, for display: DisplayInfo) async throws -> Bool {
        let displayID = display.displayID
        let generation = (hdrRequestGeneration[displayID] ?? 0) + 1
        hdrRequestGeneration[displayID] = generation
        if on {
            return try await setHDRMode(true, for: display)
        }
        let hadBoostState = isEnabled(for: display) || collapsingDisplays.contains(displayID)
        if isEnabled(for: display) {
            guard try await setEnabled(false, for: display) else { return false }
        }
        // Wait on the live collapse set, not the isEnabled flag: a collapse
        // started moments earlier from the Extra Brightness row has already
        // cleared the flag but is still animating this display. Capped at 2s
        // (the collapse runs 0.35s): an animator cancelled without its final
        // tick would otherwise leave the marker set and spin this forever.
        var waited = 0
        while collapsingDisplays.contains(displayID), waited < 40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 1
        }
        // Brief settle so the collapse's last brightness write lands
        // before the mode switch.
        try await Task.sleep(nanoseconds: 200_000_000)
        guard hdrRequestGeneration[displayID] == generation,
              currentDisplayMatches(display),
              !collapsingDisplays.contains(displayID),
              !isEnabled(for: display),
              display.brightness <= 100.001,
              display.maxBrightness <= 100.001 else { return false }
        if hadBoostState {
            guard appliedFactorCommits.isCommitted(
                factor: 1,
                uuid: display.displayUUID,
                identity: displayIdentity(display),
                tolerance: 0.001
            ) else { return false }
        }
        return try await setHDRMode(false, for: display)
    }

    // MARK: - MonitorPanel HDR mode (private API; selectors verified by the Task 1 spike)

    /// Hardware capability, cached per displayID: the MPDisplay read is a
    /// synchronous WindowServer round-trip (SLSDisplaySupportsHDRMode), and
    /// HDRToggleView's body hits this on every render, 125x/s during a
    /// brightness glide. The cache clears on screen reconfiguration, the only
    /// time capability (or displayID assignment) can change.
    private var hdrSupportCache: [CGDirectDisplayID: Bool] = [:]

    private func supportsHDRMode(_ displayID: CGDirectDisplayID) -> Bool {
        if let cached = hdrSupportCache[displayID] { return cached }
        let supported = monitorPanel.snapshot(for: displayID)?.supportsHDR == true
        hdrSupportCache[displayID] = supported
        return supported
    }

    @discardableResult
    private func setHDRMode(
        _ on: Bool,
        for display: DisplayInfo,
        requiring boostToken: BoostTransitionToken? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()
        if let boostToken {
            guard transitionAccepts(boostToken, display: display) else { return false }
        }
        guard display.isOnline, !display.isBuiltin,
              !VirtualDisplayService.shared.isVirtualDisplay(display.displayID),
              currentDisplayMatches(display),
              let monitorPanelIdentity = HDRPreferenceAdapterDriver.beginSet(
                  using: monitorPanel, displayID: display.displayID, requested: on
              ) else { return false }
        let mutationIdentity = "\(displayIdentity(display))|\(monitorPanelIdentity)"
        let token = hdrMutations.begin(
            uuid: display.displayUUID, identity: mutationIdentity, requested: on
        )
        guard hdrMutations.recordSetterInvocation(token) else { return false }
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard currentDisplayMatches(display) else { return false }
            if let liveState = monitorPanel.readState(displayID: display.displayID),
               liveState.identity == monitorPanelIdentity,
               hdrMutations.observe(
                   token,
                   currentUUID: display.displayUUID,
                   currentIdentity: mutationIdentity,
                   readback: liveState.prefersHDR
               ), let verified = hdrMutations.verifiedRoutingState(for: token) {
                BrightnessService.shared.setHDRSoftwareDimming(verified, for: display.displayID)
                return true
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Keeps BrightnessService's DDC-vs-software routing in step with each
    /// external's live HDR mode. A DisplayHDR monitor owns its luminance and
    /// silently discards DDC brightness writes (they still ack), so the whole
    /// 0-100 range must dim in software while HDR is on. Covers HDR changes
    /// made outside Crisp (System Settings): every HDR flip fires a screen
    /// reconfiguration, which lands here via reapplyAll.
    private func syncHDRRouting() {
        // Every external gets an explicit answer, not just HDR-eligible ones:
        // a display inheriting a reused ID from a disconnected HDR display
        // must be actively cleared out of the software-dimming set, or its
        // DDC control stays silently routed to gamma.
        for display in DisplayManagerAccessor.shared.displays where !display.isBuiltin {
            let dimmed = controlHDRState(for: display) == true
            BrightnessService.shared.setHDRSoftwareDimming(dimmed, for: display.displayID)
        }
    }
}
