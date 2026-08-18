import AppKit
import Carbon.HIToolbox

/// Registers all of Crisp's global shortcuts via Carbon RegisterEventHotKey and dispatches presses to their actions (issue #61).
///
/// Uses Carbon RegisterEventHotKey, which works in an LSUIElement app with no
/// Accessibility permission (unlike the CGEventTap the brightness keys need) and
/// fires regardless of which app has focus.
@MainActor
final class HotkeyService {
    static let shared = HotkeyService()
    private init() {}

    /// What a registered hotkey triggers.
    private enum Target {
        case preset(UUID)
        case hidpiToggle
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, target: Target)] = [:]
    /// Monotonic id source for EventHotKeyID.id; presses look the id up in
    /// `registrations`, so stale ids from a previous sync simply miss.
    private var nextID: UInt32 = 1
    /// While true, syncRegistrations() registers nothing, so a recorder can
    /// capture any combo, including ones currently bound.
    var suspended = false {
        didSet { syncRegistrations() }
    }

    /// Rebuilds every registration from current state: one hotkey per preset
    /// with a shortcut, plus the static Toggle HiDPI action. Idempotent; called
    /// from launch, PresetService.savePresets(), and the recorder.
    func syncRegistrations() {
        for reg in registrations.values { UnregisterEventHotKey(reg.ref) }
        registrations = [:]
        guard !suspended else { return }
        for preset in PresetService.shared.presets {
            if let shortcut = preset.shortcut { register(shortcut, for: .preset(preset.id)) }
        }
        if let shortcut = SettingsService.shared.hidpiShortcut {
            register(shortcut, for: .hidpiToggle)
        }
    }

    private func register(_ shortcut: KeyboardShortcut, for target: Target) {
        installHandlerIfNeeded()
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4372_7370), id: id)  // "Crsp"
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                            GetEventDispatcherTarget(), 0, &ref)
        if let ref { registrations[id] = (ref, target) }
    }

    /// One process-wide handler; presses carry the EventHotKeyID that fired.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            // C-function callback, no captures; read which hotkey fired, then
            // hop to the main actor for the action.
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in HotkeyService.shared.fire(id: id) }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    private func fire(id: UInt32) {
        switch registrations[id]?.target {
        case .preset(let presetID):
            guard let preset = PresetService.shared.presets.first(where: { $0.id == presetID })
            else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        case .hidpiToggle:
            toggleHiDPIUnderCursor()
        case nil:
            break
        }
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
