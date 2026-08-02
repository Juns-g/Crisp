import SwiftUI

// MARK: - DisplayDetailView

struct DisplayDetailView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var displayManager: DisplayManager
    @State private var showPreset: Bool = false
    @State private var showColorProfile: Bool = false
    @State private var showImageAdjustment: Bool = false
    @State private var activeProfileName: String = ""
    @State private var presetName: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // Brightness slider is inline at the top level (avoid duplication); HiDPI toggle moved to Settings

            // Resolution + Refresh Rate, each a top-level one-click section
            DisplayModeSection(display: display)

            SectionDivider()

            // Reference preset section (XDR builtin panels), mirrors the
            // System Settings "Preset" menu
            if !presetName.isEmpty {
                ExpandableRow(
                    icon: "camera.filters",
                    iconActive: false,
                    label: "Preset",
                    subtitle: presetName,
                    isExpanded: $showPreset
                )

                DisplayPresetView(displayID: display.displayID, activeName: $presetName)
                    .curtainReveal(showPreset)
            }

            // Color profile section; hidden when the display has presets,
            // matching System Settings (XDR panels get Preset instead)
            if presetName.isEmpty {
                ExpandableRow(
                    icon: "paintpalette.fill",
                    iconActive: false,
                    label: "Color Profile",
                    subtitle: activeProfileName,
                    isExpanded: $showColorProfile
                )

                VStack(spacing: 0) {
                    if showColorProfile {
                        ColorProfileView(display: display, activeProfileName: $activeProfileName)
                            .transition(.opacity)
                    }
                }
                .clipped()
            }

            // Image adjustment section
            ExpandableRow(
                icon: "slider.horizontal.3",
                iconActive: false,
                label: "Image Adjustment",
                isExpanded: $showImageAdjustment
            )

            ImageAdjustmentView(display: display, isExpanded: showImageAdjustment)
                .padding(.leading, 8)
                .curtainReveal(showImageAdjustment)

            SectionDivider()

            // Set as main display
            MainDisplayView(display: display)

            // Disconnect this physical display (Apple Silicon only; hidden for the last screen)
            DisconnectDisplayRow(display: display)

            // macOS "Automatically adjust brightness" (ambient light), grouped with the
            // other built-in-only toggles; renders only on ALS panels, absent on externals.
            SystemAutoBrightnessView(display: display)

            // Notch management (built-in with notch only)
            NotchView(display: display)

        }
        .padding(.leading, 4)
        // Region background: a full-width shaded band behind the whole expanded
        // detail so its start and end are obvious. Color.primary adapts to mode
        // (darkens in light, lifts in dark); no rounded corners/inset, so it reads
        // as a grouped band, not a floating card.
        .background(Color.primary.opacity(0.08))
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // Reopen fresh, like a native menu (this view persists across opens, so
            // its sections stay expanded until reset).
            showPreset = false
            showColorProfile = false
            showImageAdjustment = false
        }
        .task(id: display.displayID) {
            activeProfileName = ""
            presetName = ""
            guard !Task.isCancelled else { return }
            activeProfileName = ColorProfileService.shared.currentColorSpaceName(for: display.displayID)
            let svc = DisplayPresetService.shared
            if let idx = svc.activePresetIndex(for: display.displayID) {
                presetName = svc.presets(for: display.displayID)
                    .first(where: { $0.index == idx })?.name ?? ""
            }
        }
    }
}

