import SwiftUI

/// Color profile selection as a native checkmarked list (same style as the
/// resolution and preset lists), grouped into Recommended / All Profiles like
/// the system Displays panel; checkmark on the active profile.
struct ColorProfileView: View {
    @ObservedObject var display: DisplayInfo
    @State private var profiles: [ICCProfile] = []
    @State private var isLoading: Bool = false
    @State private var selectedPath: URL?
    @State private var applyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text("Loading profiles…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.leading, 24)
                .padding(.vertical, 6)
            } else {
                if !recommendedProfiles.isEmpty {
                    groupHeader("Recommended")
                    ForEach(recommendedProfiles) { profile in
                        CheckmarkRow(label: profile.name, isSelected: profile.path == selectedPath) {
                            select(profile)
                        }
                    }
                }
                if !otherProfiles.isEmpty {
                    groupHeader("All Profiles")
                    ForEach(otherProfiles) { profile in
                        CheckmarkRow(label: profile.name, isSelected: profile.path == selectedPath) {
                            select(profile)
                        }
                    }
                }
            }

            if let error = applyError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.leading, 24)
                    .padding(.bottom, 4)
            }
        }
        .task { await loadProfiles() }
    }

    private func groupHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 24)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    // MARK: - Grouping

    private var recommendedProfiles: [ICCProfile] {
        let keywords = ["sRGB", "P3", "Display", "LCD", "Apple", "Color LCD"]
        return profiles.filter { p in
            keywords.contains { p.name.localizedCaseInsensitiveContains($0) }
        }
    }

    private var otherProfiles: [ICCProfile] {
        let recommended = Set(recommendedProfiles.map(\.path))
        return profiles.filter { !recommended.contains($0.path) }
    }

    // MARK: - Actions

    private func select(_ profile: ICCProfile) {
        guard profile.path != selectedPath else { return }
        let previous = selectedPath
        selectedPath = profile.path
        applyProfile(profile, revertTo: previous)
    }

    @MainActor
    private func loadProfiles() async {
        isLoading = true
        let displayID = display.displayID
        let svc = ColorProfileService.shared
        let loaded = await svc.enumerateProfiles()
        let currentURL = svc.currentProfileURL(for: displayID)
        profiles = loaded
        // Snap to the enumerated entry by file path: the device registry URL
        // and FileManager's can differ in percent-encoding, and the selection
        // shows as unset unless the path matches exactly.
        if let cur = currentURL,
           let match = loaded.first(where: { $0.path.path == cur.path }) {
            selectedPath = match.path
        } else {
            selectedPath = currentURL
        }
        isLoading = false
    }

    @MainActor
    private func applyProfile(_ profile: ICCProfile, revertTo previous: URL?) {
        applyError = nil
        let success = ColorProfileService.shared.setProfile(profile, for: display.displayID)
        if !success {
            selectedPath = previous
            applyError = String(localized: "Failed to apply. Please try again.")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                applyError = nil
            }
        }
    }
}
