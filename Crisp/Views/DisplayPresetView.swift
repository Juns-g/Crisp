import SwiftUI

/// Reference-mode preset picker, mirroring the System Settings "Preset" menu
/// for displays that have presets (XDR builtin panels). A native checkmarked
/// list (same style as the resolution list), not a nested popup.
struct DisplayPresetView: View {
    let displayID: CGDirectDisplayID
    /// The parent row's subtitle; updated here so it refreshes on switch.
    @Binding var activeName: String
    @State private var presets: [DisplayPresetService.Preset] = []
    @State private var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presets) { preset in
                CheckmarkRow(
                    label: preset.name,
                    isSelected: preset.index == selectedIndex
                ) {
                    select(preset)
                }
            }
        }
        .onAppear {
            presets = DisplayPresetService.shared.presets(for: displayID)
            selectedIndex = DisplayPresetService.shared.activePresetIndex(for: displayID)
        }
    }

    private func select(_ preset: DisplayPresetService.Preset) {
        guard preset.index != selectedIndex else { return }
        if DisplayPresetService.shared.setActivePreset(index: preset.index, for: displayID) {
            selectedIndex = preset.index
            activeName = preset.name
        }
    }
}
