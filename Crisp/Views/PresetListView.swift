import SwiftUI

extension DisplayPreset {
    static let colorOptions: [(name: String, color: Color)] = [
        ("indigo", .indigo), ("blue", .blue), ("purple", .purple), ("pink", .pink),
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green),
        ("teal", .teal), ("gray", .gray),
    ]
    var chipColor: Color {
        Self.colorOptions.first(where: { $0.name == colorName })?.color ?? .indigo
    }
}

// MARK: - PresetListView

/// Section in MenuBarView listing user-created presets + Save Preset row.
/// (Built-in Native/HiDPI segmented control has been moved to the HiDPI section in Settings.)
struct PresetListView: View {
    @ObservedObject private var presetService = PresetService.shared

    private var userPresets: [DisplayPreset] {
        presetService.presets.filter { !$0.isBuiltin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // User-created presets as rows
            ForEach(userPresets) { preset in
                PresetRow(
                    preset: preset,
                    isCurrentMatch: presetService.activePresetID == preset.id,
                    isApplying: presetService.applyingPresetID == preset.id
                )
            }

            // Save preset button
            SavePresetView()
        }
    }
}

// MARK: - PresetRow (for user-created presets)

struct PresetRow: View {
    let preset: DisplayPreset
    let isCurrentMatch: Bool
    let isApplying: Bool

    @State private var isHovered = false
    @State private var isEditing = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if isEditing {
                SavePresetForm(
                    editing: preset,
                    onClose: { withAnimation(.panelResize) { isEditing = false } },
                    nameFocused: $nameFocused
                )
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 8)
                .transition(.opacity)
            } else {
                rowContent
                    .transition(.opacity)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            if isApplying {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 20, height: 20)
            } else {
                MenuItemIcon(systemName: preset.icon, color: preset.chipColor)
            }

            Text(preset.name)
                .font(.body)
                .fontWeight(isCurrentMatch ? .semibold : .regular)
                .lineLimit(1)

            Spacer()

            if isCurrentMatch {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .accessibilityLabel("Currently active")
            }

            // Visible ⋯ menu, revealed on hover. Same actions as the right-click
            // menu below, now discoverable.
            Menu {
                rowActions
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovered ? 1 : 0)
            .accessibilityLabel("Preset options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation, !PresetService.shared.isApplying else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        }
        .onHover { isHovered = $0 }
        .contextMenu { rowActions }
        .disabled(PresetService.shared.isApplying)
    }

    @ViewBuilder
    private var rowActions: some View {
        Button {
            PresetService.shared.updatePreset(id: preset.id)
        } label: {
            Label("Update to Current Settings", systemImage: "arrow.triangle.2.circlepath")
        }

        Button {
            withAnimation(.panelResize) {
                isEditing = true
            } completion: {
                nameFocused = true
            }
        } label: {
            Label("Edit…", systemImage: "pencil")
        }

        Section {
            Button(role: .destructive) {
                PresetService.shared.deletePreset(id: preset.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}
