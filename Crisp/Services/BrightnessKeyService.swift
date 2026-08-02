import AppKit
import CoreGraphics

// MARK: - C Event Tap Callback

/// Global C callback for the CGEventTap. `userInfo` carries an Unmanaged<BrightnessKeyService>.
/// The tap is registered on the main run loop, so this callback always fires on the main thread.
private func brightnessKeyEventCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passRetained(event) }
    let service = Unmanaged<BrightnessKeyService>.fromOpaque(userInfo).takeUnretainedValue()
    return service.handleEventFromCallback(type: type, event: event)
}

// MARK: - BrightnessKeyService

/// Intercepts macOS brightness keys and routes them to the display under the mouse cursor.
/// When the cursor is on an external display the key event is consumed and the external
/// display's brightness is adjusted via BrightnessService. When the cursor is on the
/// built-in display the event is passed through so macOS adjusts it normally.
@MainActor
final class BrightnessKeyService: @unchecked Sendable {
    static let shared = BrightnessKeyService()
    private init() {}

    // MARK: - Private State

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    /// Retained Unmanaged reference passed into the C callback. Released in stop().
    private var selfRetained: Unmanaged<BrightnessKeyService>?

    // MARK: - NX Media Key Constants
    // Marked nonisolated(unsafe) so they can be read from the nonisolated callback method.
    // These are immutable compile-time constants so there is no data-race risk.

    /// CGEventType raw value for NSSystemDefined / NX_SYSDEFINED events (media keys).
    private nonisolated(unsafe) static let cgEventTypeSystemDefinedRaw: UInt32 = 14
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS, the subtype value for media/function keys.
    private nonisolated(unsafe) static let nxSubtypeAuxControlButtons: Int16 = 8
    /// NX_KEYTYPE_BRIGHTNESS_UP
    private nonisolated(unsafe) static let nxKeytypeBrightnessUp: Int = 2
    /// NX_KEYTYPE_BRIGHTNESS_DOWN
    private nonisolated(unsafe) static let nxKeytypeBrightnessDown: Int = 3

    /// Each key press moves brightness by 1/16 (≈ 6.25 %), matching macOS native behaviour.
    private nonisolated(unsafe) static let brightnessStep: Double = 100.0 / 16.0

    // MARK: - Start / Stop

    /// Installs the event tap. Requires Accessibility permissions.
    /// Safe to call multiple times, a running tap will not be re-created.
    func start() {
        guard eventTap == nil else { return }

        // Try creating the tap directly, AXIsProcessTrusted can be unreliable
        // with ad-hoc signed Debug builds (TCC entry invalidates after each rebuild).
        let retained = Unmanaged.passRetained(self)
        selfRetained = retained

        let systemDefinedMask = CGEventMask(1 << Self.cgEventTypeSystemDefinedRaw)

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: systemDefinedMask,
            callback: brightnessKeyEventCallback,
            userInfo: retained.toOpaque()
        )

        guard let tap else {
            retained.release()
            selfRetained = nil
            retryUntilArmed()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
        stopRetrying()
    }

    /// Removes the event tap and releases the retained self reference.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        eventTap = nil
        runLoopSource = nil

        selfRetained?.release()
        selfRetained = nil
    }

    // MARK: - Accessibility retry
    // There is no system notification for Accessibility-trust changes, so we keep trying to
    // arm the tap on two triggers until it takes: a slow recurring poll (reliable) and
    // app-activation (fast path when the user returns from System Settings after granting).
    // Whichever arms the tap calls stopRetrying(). This replaces the old bounded 30s give-up
    // that left the feature dead until an app restart. (b00d.2)

    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private func retryUntilArmed() {
        // ponytail: unbounded 2s poll; tapCreate is cheap and it stops the instant the grant
        // lands. The activation observer just makes it feel instant when the user clicks back in.
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                self.start()
            }
        }
        if activationObserver == nil {
            activationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.start() }
            }
        }
    }

    private func stopRetrying() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let obs = activationObserver {
            NotificationCenter.default.removeObserver(obs)
            activationObserver = nil
        }
    }

    // MARK: - Event Handling
    // Called from the C callback which runs on the main run loop thread.
    // We use nonisolated so Swift 6 doesn't complain about CGEvent (non-Sendable) crossing
    // actor boundaries; all actual state access is done synchronously on the main thread.

    /// Returns `false` to pass the event through, `true` to consume it.
    /// Separated from the callback to keep the C-bridging function minimal.
    nonisolated func handleEventFromCallback(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // Re-enable the tap if the system disabled it (e.g. after a timeout).
        if type.rawValue == CGEventType.tapDisabledByTimeout.rawValue ||
           type.rawValue == CGEventType.tapDisabledByUserInput.rawValue {
            DispatchQueue.main.async {
                if let tap = self.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
            }
            return Unmanaged.passRetained(event)
        }

        guard type.rawValue == Self.cgEventTypeSystemDefinedRaw else {
            return Unmanaged.passRetained(event)
        }

        // Convert to NSEvent to inspect media-key subtype.
        guard let nsEvent = NSEvent(cgEvent: event) else { return Unmanaged.passRetained(event) }
        guard nsEvent.subtype.rawValue == Self.nxSubtypeAuxControlButtons else {
            return Unmanaged.passRetained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 >> 16) & 0xFF
        let isKeyDown = (data1 & 0x0100) == 0   // bit 8 clear → key down

        // Only intercept brightness keys.
        guard keyCode == Self.nxKeytypeBrightnessUp || keyCode == Self.nxKeytypeBrightnessDown else {
            return Unmanaged.passRetained(event)
        }

        // For key-up events always pass through, only consume key-down on external displays.
        guard isKeyDown else { return Unmanaged.passRetained(event) }

        // Route by user preference. Read on the main actor, this callback runs on
        // the main run loop (see class docs), so assumeIsolated is safe here.
        switch MainActor.assumeIsolated({ SettingsService.shared.brightnessKeyTarget }) {
        case .allDisplays:
            let step = (keyCode == Self.nxKeytypeBrightnessUp) ? Self.brightnessStep : -Self.brightnessStep
            Task { @MainActor in self.adjustDisplays(DisplayManagerAccessor.shared.displays, step: step) }
            // Consume: we adjust every display (built-in included) ourselves, so
            // macOS must not also bump the built-in on top.
            return nil
        case .selected:
            // Adjust only the chosen displays that are currently attached. If none
            // are attached, fall through to the under-cursor path so the key still
            // does something instead of being dead.
            let selected = MainActor.assumeIsolated { SettingsService.shared.brightnessKeySelectedDisplayUUIDs }
            let anyAttached = MainActor.assumeIsolated {
                DisplayManagerAccessor.shared.displays.contains { selected.contains($0.displayUUID) }
            }
            if anyAttached {
                let step = (keyCode == Self.nxKeytypeBrightnessUp) ? Self.brightnessStep : -Self.brightnessStep
                Task { @MainActor in
                    let targets = DisplayManagerAccessor.shared.displays.filter { selected.contains($0.displayUUID) }
                    self.adjustDisplays(targets, step: step)
                }
                return nil
            }
        case .underCursor:
            break
        }
        // .underCursor (or .selected with none of the chosen displays attached):
        // fall through to the under-cursor path below.

        // Determine which display is under the cursor.
        // NSEvent.mouseLocation and NSScreen.screens are safe to call on the main thread.
        // The tap runs on the main run loop so this is fine.
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }),
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            return Unmanaged.passRetained(event)
        }

        // Consume the key ONLY when we can synchronously confirm the cursor is on a
        // currently-connected, controllable EXTERNAL display. Leaving clamshell mode
        // (external unplugged, then lid opened) briefly leaves NSScreen reporting a
        // stale external screen while Crisp's display list has already dropped it. The
        // old code consumed the key on that stale screen, then no-op'd asynchronously on
        // the vanished display, swallowing the press so the built-in stayed dead until
        // macOS settled (~30s). Fail safe instead: if we can't confirm a live external,
        // pass the key through so macOS drives the built-in immediately. (issue #12)
        let displayID = screenNumber
        let isControllableExternal = MainActor.assumeIsolated {
            guard let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID })
            else { return false }
            return !display.isBuiltin
        }
        guard isControllableExternal else {
            return Unmanaged.passRetained(event)
        }

        let step = (keyCode == Self.nxKeytypeBrightnessUp) ? Self.brightnessStep : -Self.brightnessStep

        // All data captured here is Sendable (CGDirectDisplayID = UInt32, Double).
        Task { @MainActor in
            let displays = DisplayManagerAccessor.shared.displays
            guard let display = displays.first(where: { $0.displayID == displayID }) else { return }
            let newBrightness = max(0.0, min(100.0, display.brightness + step))
            // Use smooth animation, cancels any in-progress animation automatically.
            BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)

            // Show OSD on the external display where brightness was adjusted.
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
            }) {
                BrightnessHUDService.shared.show(brightness: newBrightness, on: screen)
            }
        }

        // Return nil to consume (suppress) the event so macOS doesn't also adjust built-in brightness.
        return nil
    }

    /// Applies the same relative step to each given display (built-in or external),
    /// through BrightnessService's smooth fade (reusing its DDC/gamma/IOKit paths +
    /// coalescing), and shows the brightness HUD on each display's own screen.
    /// Backs the `.allDisplays` and `.selected` brightness-key modes.
    @MainActor
    private func adjustDisplays(_ displays: [DisplayInfo], step: Double) {
        let screens = NSScreen.screens
        for display in displays {
            let newBrightness = max(0.0, min(100.0, display.brightness + step))
            BrightnessService.shared.setBrightnessSmooth(newBrightness, for: display)
            if let screen = screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
            }) {
                BrightnessHUDService.shared.show(brightness: newBrightness, on: screen)
            }
        }
    }
}
