import SwiftUI

/// Settings section for the global HiDPI-toggle shortcut (issue #61): an expandable
/// row showing the recorded combo, expanding in place (DESIGN.md) to a recorder row,
/// a remove row, and a caption. Recording swallows keystrokes via a local keyDown
/// monitor while the panel is key; Esc cancels. The active hotkey is unregistered
/// during recording so the current combo can be typed to replace itself.
struct HiDPIShortcutSection: View {
    @ObservedObject private var settings = SettingsService.shared
    // Owned by SettingsView so its panel-close reset collapses this section like
    // every other (see SupportRow's binding for the same reason).
    @Binding var expanded: Bool
    @State private var isRecording = false
    @State private var monitor: Any? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "command",
                iconActive: settings.hidpiShortcut != nil,
                label: "HiDPI Shortcut",
                subtitle: settings.hidpiShortcut?.display,
                isExpanded: $expanded
            )
            if expanded {
                ShortcutActionRow(
                    title: isRecording ? "Type shortcut… (Esc to cancel)" : "Record Shortcut",
                    isProminent: isRecording
                ) {
                    if isRecording { stopRecording() } else { startRecording() }
                }
                if settings.hidpiShortcut != nil && !isRecording {
                    ShortcutActionRow(title: "Remove Shortcut") {
                        settings.hidpiShortcut = nil
                        HotkeyService.shared.apply(nil)
                    }
                }
                Text("Switches the display under the pointer between HiDPI and low resolution.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.leading, 34)
                    .padding(.bottom, 4)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // The panel resigns key on close, so an in-flight recording can never finish.
            stopRecording()
        }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        // Free the current combo so typing it re-records instead of firing the toggle.
        HotkeyService.shared.apply(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // kVK_Escape cancels
                stopRecording()
                return nil
            }
            let label = KeyboardShortcut.keyLabel(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            // nil = no ⌘⌥⌃ anchor yet (typing, not a shortcut): swallow and keep listening.
            if let shortcut = KeyboardShortcut(
                keyCode: event.keyCode, nsModifierFlags: event.modifierFlags.rawValue, keyLabel: label) {
                settings.hidpiShortcut = shortcut
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotkeyService.shared.apply(settings.hidpiShortcut)
    }
}

/// Plain action row for the shortcut section, indented under the section's icon chip
/// (the SupportLinkRow idiom, minus the external-link affordance).
private struct ShortcutActionRow: View {
    let title: String
    var isProminent: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack {
            Text(LocalizedStringKey(title))
                .font(.body)
                .foregroundColor(isProminent ? .accentColor : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.leading, 34)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
    }
}
