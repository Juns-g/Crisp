import AppKit
import Carbon.HIToolbox

/// Registers the user's global HiDPI-toggle shortcut and performs its action (issue #61).
///
/// Uses Carbon RegisterEventHotKey, which works in an LSUIElement app with no
/// Accessibility permission (unlike the CGEventTap the brightness keys need) and
/// fires regardless of which app has focus.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()
    private init() {}

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// (Re)registers the given shortcut; nil unregisters. Also called with nil while
    /// the recorder is capturing, so the current combo can be typed to re-record it.
    func apply(_ shortcut: KeyboardShortcut?) {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        guard let shortcut else { return }
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4372_7370), id: 1)  // "Crsp"
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                            GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    /// One process-wide handler for the app's single hotkey; no EventHotKeyID
    /// dispatch needed until there is a second shortcut.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, _ in
            // C-function callback, no captures; hop to the main actor for the action.
            Task { @MainActor in HotkeyService.shared.toggleHiDPIUnderCursor() }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    // MARK: - Action

    /// Flips the display under the pointer between the HiDPI and low-resolution
    /// variant of its current logical size: an instant mode switch, same as picking
    /// the twin row in the Resolution list (no override plist, no reconnect).
    /// Under-cursor targeting matches the brightness keys (BrightnessKeyService).
    func toggleHiDPIUnderCursor() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = DisplayManagerAccessor.shared.displays.first(where: { $0.displayID == displayID }),
              let current = display.currentDisplayMode,
              let target = Self.hiDPITwin(of: current, in: display.availableModes)
        else {
            // No twin at this size (or the display vanished): audible no-op instead of
            // a shortcut that silently does nothing.
            NSSound.beep()
            return
        }
        Task { @MainActor in
            _ = await ResolutionService.shared.setDisplayMode(target, for: displayID)
        }
    }

    /// Same logical size, opposite scaling; keeps the current refresh rate when the
    /// twin offers it (tolerant match, CG reports fractional rates), else the
    /// highest-refresh twin.
    static func hiDPITwin(of current: DisplayMode, in modes: [DisplayMode]) -> DisplayMode? {
        let twins = modes.filter {
            $0.width == current.width && $0.height == current.height && $0.isHiDPI != current.isHiDPI
        }
        return twins.first { ResolutionService.refreshMatches($0.refreshRate, current.refreshRate) }
            ?? twins.max { $0.refreshRate < $1.refreshRate }
    }
}
