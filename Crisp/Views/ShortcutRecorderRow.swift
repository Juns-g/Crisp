import SwiftUI

/// One record-in-place shortcut row, shared by the Settings > Shortcuts section
/// and the preset form (issue #61): action label leading, then the combo glyphs
/// (or "Record Shortcut"), with an × to clear. Tapping toggles recording; a local
/// keyDown monitor captures the next valid combo, Esc cancels. All registered
/// hotkeys are suspended while recording so bound combos can be re-captured.
/// Commit semantics live in the binding: Settings commits immediately, the preset
/// form holds the value in @State until Save.
struct ShortcutRecorderRow: View {
    let label: String
    @Binding var shortcut: KeyboardShortcut?
    /// Extra leading inset so the row aligns under a section's icon chip.
    var leadingInset: CGFloat = 0
    @State private var isRecording = false
    @State private var monitor: Any? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(label))
                .font(.body)
            Spacer()
            if isRecording {
                Text("Type shortcut… (Esc to cancel)")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else if let shortcut {
                Text(verbatim: shortcut.display)
                    .font(.callout)
                    .foregroundColor(.secondaryReadable)
                Button {
                    self.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Shortcut")
            } else {
                Text("Record Shortcut")
                    .font(.caption)
                    .foregroundColor(.secondaryReadable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.leading, leadingInset)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            if isRecording { stopRecording() } else { startRecording() }
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // The panel resigns key on close; an in-flight recording can't finish.
            stopRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispStopShortcutRecording)) { _ in
            // The preset form is committing/closing; finish now (see MenuBarView).
            stopRecording()
        }
        // The preset form unmounts on Save/Cancel; don't leak the monitor.
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        // Only one recording at a time: the form row and the Settings row can both
        // be on screen, and whichever other row is mid-recording must stop first,
        // or its stop would set suspended = false and re-arm every hotkey while
        // this row still shows "recording". Delivery is synchronous; our own
        // monitor is still nil here, so the self-notification is a no-op.
        NotificationCenter.default.post(name: .crispStopShortcutRecording, object: nil)
        isRecording = true
        // Free every bound combo so any of them can be re-recorded here.
        HotkeyService.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // kVK_Escape cancels
                stopRecording()
                return nil
            }
            let label = KeyboardShortcut.keyLabel(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            // nil = no ⌘⌥⌃ anchor yet (typing, not a shortcut): swallow, keep listening.
            if let recorded = KeyboardShortcut(
                keyCode: event.keyCode, nsModifierFlags: event.modifierFlags.rawValue,
                keyLabel: label) {
                shortcut = recorded
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotkeyService.shared.suspended = false
    }
}
