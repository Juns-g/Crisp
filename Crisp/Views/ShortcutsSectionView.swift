import SwiftUI

/// Settings > Shortcuts: the curated list of named global-shortcut actions
/// (issue #61). One action today, Toggle HiDPI; the bar for adding another is
/// "someone asked" (see the 2026-08-18 spec). Per-preset shortcuts live on the
/// presets themselves, not here. Expands in place per DESIGN.md.
struct ShortcutsSection: View {
    @ObservedObject private var settings = SettingsService.shared
    // Owned by SettingsView so its panel-close reset collapses this section
    // like every other.
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "command",
                iconActive: settings.hidpiShortcut != nil,
                label: "Keyboard Shortcuts",
                // Collapsed only: expanded, the Toggle HiDPI row right below
                // shows the same combo, and the duplicate reads as two bindings.
                subtitle: expanded ? nil : settings.hidpiShortcut?.display,
                isExpanded: $expanded
            )
            if expanded {
                ShortcutRecorderRow(
                    label: "Toggle HiDPI",
                    shortcut: Binding(
                        get: { settings.hidpiShortcut },
                        set: { newValue in
                            // Commits immediately (no form): store, steal the
                            // combo from any preset holding it, re-register.
                            settings.hidpiShortcut = newValue
                            if let newValue {
                                PresetService.shared.stealShortcutFromPresets(newValue)
                            } else {
                                HotkeyService.shared.syncRegistrations()
                            }
                        }
                    ),
                    leadingInset: 34
                )
                Text("Switches the display under the pointer between HiDPI and low resolution.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.leading, 34)
                    .padding(.bottom, 4)
            }
        }
    }
}
