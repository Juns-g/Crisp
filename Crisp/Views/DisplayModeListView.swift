import SwiftUI

/// Resolution and refresh-rate selection as native checkmarked lists, each a
/// top-level expandable row like the System Settings display menu: resolution is
/// one click away (not nested under a "Display Mode" popup), and refresh rate is
/// its own section, shown only when the current resolution offers more than one.
struct DisplayModeSection: View {
    @ObservedObject var display: DisplayInfo
    @State private var showResolution: Bool = false
    @State private var showRefresh: Bool = false
    @State private var pendingResolutionID: String?
    @State private var pendingRefreshID: Int32?
    @State private var errorMessage: String?

    private var currentMode: DisplayMode? { display.currentDisplayMode }

    /// Group modes by (resolution + HiDPI), sorted by resolution descending.
    private var resolutionGroups: [ResolutionGroup] {
        let base = display.availableModes.filter {
            $0.width >= 1280 && $0.height >= 720
        }

        var grouped: [String: [DisplayMode]] = [:]
        for mode in base {
            let key = "\(mode.width)x\(mode.height)_\(mode.isHiDPI)"
            grouped[key, default: []].append(mode)
        }

        return grouped.map { (_, modes) in
            let sorted = modes.sorted { $0.refreshRate > $1.refreshRate }
            return ResolutionGroup(
                width: sorted[0].width,
                height: sorted[0].height,
                isHiDPI: sorted[0].isHiDPI,
                modes: sorted
            )
        }
        .sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.height != rhs.height { return lhs.height > rhs.height }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return false
        }
    }

    private var currentGroup: ResolutionGroup? {
        resolutionGroups.first { $0.modes.contains { $0.id == currentMode?.id } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Resolution: its own top-level row, list opens in one click.
            ExpandableRow(
                icon: "rectangle.on.rectangle",
                label: "Resolution",
                subtitle: currentGroup?.menuLabel,
                isExpanded: $showResolution
            )
            resolutionList
                .curtainReveal(showResolution)

            // Refresh Rate: a sibling section, not nested under resolution.
            // Only shown when the current resolution actually offers a choice.
            if let group = currentGroup, group.hasMultipleRates {
                ExpandableRow(
                    icon: "speedometer",
                    iconColor: .teal,
                    label: "Refresh Rate",
                    subtitle: currentMode?.refreshRateString,
                    isExpanded: $showRefresh
                )
                refreshList(group)
                    .curtainReveal(showRefresh)
            }

            if let msg = errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Text(msg)
                        .font(.caption2)
                        .foregroundColor(.red)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .transition(.opacity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            showResolution = false
            showRefresh = false
        }
    }

    // MARK: - Lists

    @ViewBuilder
    private var resolutionList: some View {
        if resolutionGroups.isEmpty {
            Text("No display modes available")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(resolutionGroups) { group in
                    CheckmarkRow(
                        label: group.menuLabel,
                        isSelected: group.id == currentGroup?.id,
                        isPending: group.id == pendingResolutionID
                    ) {
                        selectResolution(group)
                    }
                }
            }
        }
    }

    private func refreshList(_ group: ResolutionGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.modes) { mode in
                CheckmarkRow(
                    label: mode.refreshRateString,
                    isSelected: mode.id == currentMode?.id,
                    isPending: mode.id == pendingRefreshID
                ) {
                    selectRefresh(mode)
                }
            }
        }
    }

    // MARK: - Actions

    private func selectResolution(_ group: ResolutionGroup) {
        guard group.id != currentGroup?.id, pendingResolutionID == nil else { return }
        // Keep the current refresh rate when the new resolution offers it.
        let target = group.modes.first { $0.refreshRate == currentMode?.refreshRate } ?? group.bestMode
        pendingResolutionID = group.id
        switchTo(target) { pendingResolutionID = nil }
    }

    private func selectRefresh(_ mode: DisplayMode) {
        guard mode.id != currentMode?.id, pendingRefreshID == nil else { return }
        pendingRefreshID = mode.id
        switchTo(mode) { pendingRefreshID = nil }
    }

    private func switchTo(_ mode: DisplayMode, done: @escaping () -> Void) {
        let displayID = display.displayID
        Task { @MainActor in
            var success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            if !success {
                try? await Task.sleep(nanoseconds: 200_000_000)
                success = await ResolutionService.shared.setDisplayMode(mode, for: displayID)
            }
            if success {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let refreshedMode = await Task.detached(priority: .userInitiated) {
                    DisplayMode.currentMode(for: displayID)
                }.value
                if let rm = refreshedMode, rm.width == mode.width && rm.height == mode.height {
                    display.currentDisplayMode = rm
                } else {
                    display.currentDisplayMode = mode
                }
                errorMessage = nil
            } else {
                withAnimation {
                    errorMessage = String(localized: "Unable to switch to \(mode.resolutionString), please try again")
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { errorMessage = nil }
                }
            }
            done()
        }
    }
}

// MARK: - Checkmark row

/// One selectable line in a native display-menu list (resolution, refresh rate,
/// preset): a leading checkmark column, the label, and a hover highlight. The
/// checkmark slot becomes a spinner while an async switch is pending.
struct CheckmarkRow: View {
    let label: String
    let isSelected: Bool
    var isPending: Bool = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                if isPending {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .opacity(isSelected ? 1 : 0)
                }
            }
            .frame(width: 16)
            Text(label)
                .font(.body)
                .fontWeight(isSelected ? .semibold : .regular)
            Spacer()
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation, !isSelected, !isPending else { return }
            action()
        }
        .onHover { isHovered = $0 }
        .accessibilityLabel(isSelected ? "\(label), selected" : label)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Data model

private struct ResolutionGroup: Identifiable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    let modes: [DisplayMode] // sorted by refresh rate descending

    var id: String { "\(width)x\(height)_\(isHiDPI)" }
    var resolutionString: String { "\(width)×\(height)" }
    var menuLabel: String { isHiDPI ? "\(resolutionString) (HiDPI)" : resolutionString }
    var hasMultipleRates: Bool { modes.count > 1 }
    var bestMode: DisplayMode { modes[0] }
}
