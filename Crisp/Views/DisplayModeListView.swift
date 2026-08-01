import SwiftUI

/// Resolution and refresh-rate selection as native checkmarked lists, each a
/// top-level expandable row like the System Settings display menu: resolution is
/// one click away (not nested under a "Display Mode" popup), and refresh rate is
/// its own section, shown only when the current resolution offers more than one.
struct DisplayModeSection: View {
    @ObservedObject var display: DisplayInfo
    @State private var showResolution: Bool = false
    @State private var showAllResolutions: Bool = false
    @State private var showRefresh: Bool = false
    @State private var pendingResolutionID: String?
    @State private var pendingRefreshID: Int32?
    @State private var errorMessage: String?
    @State private var sliderIndex: Double = 0
    @State private var smoothBusy: Bool = false
    @State private var smoothRowHovered: Bool = false
    @State private var smoothWouldPrompt: Bool = true

    private var currentMode: DisplayMode? { display.currentDisplayMode }

    /// Group modes by (resolution + HiDPI), sorted by resolution descending.
    private var resolutionGroups: [ResolutionGroup] {
        let (nativeW, nativeH) = display.nativeResolution

        let base = display.availableModes.filter {
            $0.width >= 1280 && $0.height >= 720
        }

        var grouped: [String: [DisplayMode]] = [:]
        for mode in base {
            let key = "\(mode.width)x\(mode.height)_\(mode.isHiDPI)"
            grouped[key, default: []].append(mode)
        }

        // Native label convention (matches System Settings): a non-HiDPI mode is
        // "low resolution" only when a HiDPI mode of the same logical size also
        // exists (so the retina twin is strictly better). The display's native mode
        // is the "(Default)"; only tagged for external displays, since the built-in's
        // native mode is a 1x physical size that macOS does not treat as the default.
        let hiDPISizes = Set(base.filter { $0.isHiDPI }.map { "\($0.width)x\($0.height)" })

        return grouped.map { (_, modes) -> ResolutionGroup in
            let sorted = modes.sorted { $0.refreshRate > $1.refreshRate }
            let w = sorted[0].width, h = sorted[0].height, hidpi = sorted[0].isHiDPI
            let isDefault = !display.isBuiltin && !hidpi && w == nativeW && h == nativeH
            let isLowResolution = !hidpi && !isDefault && hiDPISizes.contains("\(w)x\(h)")
            return ResolutionGroup(
                width: w,
                height: h,
                isHiDPI: hidpi,
                isDefault: isDefault,
                isLowResolution: isLowResolution,
                modes: sorted
            )
        }
        .filter { group in
            // Built-in (notched) panel: macOS only offers scaled sizes at the panel's
            // native aspect. CGDisplayCopyAllDisplayModes also returns 16:10 "non-notch"
            // modes (e.g. 1512x945, 2560x1600) that letterbox the notch away and aren't
            // selectable in System Settings, so drop them; always keep the active mode.
            // Non-notched built-ins share the native aspect, so nothing is dropped there.
            // ponytail: 2% tolerance cleanly splits 1.60 (16:10) from ~1.54 (notched).
            if display.isBuiltin {
                let nativeAR = Double(nativeW) / Double(nativeH)
                let ar = Double(group.width) / Double(group.height)
                return abs(ar - nativeAR) / nativeAR < 0.02
                    || group.modes.contains { $0.id == currentMode?.id }
            }
            // External: drop standalone 1x oddballs (non-HiDPI, no HiDPI twin, not
            // the native default) that clutter the list, e.g. 2048x1152, 1344x756,
            // and the off-aspect 4:3/5:4/portrait sizes. Keep native, the HiDPI
            // ladder, the "(low resolution)" twins, and whatever is current.
            if group.isHiDPI || group.isDefault || group.isLowResolution { return true }
            return group.modes.contains { $0.id == currentMode?.id }
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
                iconActive: false,
                label: "Resolution",
                subtitle: currentGroup?.menuLabel,
                isExpanded: $showResolution
            )
            resolutionReveal
                .curtainReveal(showResolution)

            // Refresh Rate: a sibling section, not nested under resolution.
            // Only shown when the current resolution actually offers a choice.
            if let group = currentGroup, group.hasMultipleRates {
                ExpandableRow(
                    icon: "speedometer",
                    iconActive: false,
                    label: "Refresh Rate",
                    subtitle: currentMode.map(refreshLabel),
                    isExpanded: $showRefresh
                )
                refreshList(group)
                    .curtainReveal(showRefresh)
            }

            // Smooth scaling: opt-in dense HiDPI ladder driven by a slider. External
            // displays only (built-ins already scale smoothly via System Settings).
            if !display.isBuiltin {
                smoothScalingSection
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
            showAllResolutions = false
            showRefresh = false
        }
    }

    // MARK: - Lists

    /// The Resolution picker: a "looks like" slider (matching System Settings) over
    /// sliderModes, with the full exact-mode list kept behind a "Show all resolutions"
    /// disclosure. Falls back to the plain list when there are too few slider stops.
    @ViewBuilder
    private var resolutionReveal: some View {
        let modes = sliderModes
        if modes.count >= 2 {
            VStack(alignment: .leading, spacing: 0) {
                modeSlider(modes)
                DisclosureSubRow(label: "Show all resolutions", isExpanded: $showAllResolutions)
                resolutionList
                    .curtainReveal(showAllResolutions)
            }
        } else {
            resolutionList
        }
    }

    @ViewBuilder
    private var resolutionList: some View {
        let groups = resolutionGroups
        if groups.isEmpty {
            Text("No display modes available")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        } else {
            // HiDPI is surfaced once as a section header instead of per-row. The
            // native "(Default)" mode is neither HiDPI nor low-resolution, so it sits
            // alone at the top; everything else splits into HiDPI / Non-HiDPI.
            let defaults = groups.filter { $0.isDefault }
            let hiDPI = groups.filter { $0.isHiDPI }
            let lowRes = groups.filter { !$0.isHiDPI && !$0.isDefault }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(defaults) { resolutionRow($0, label: $0.menuLabel) }
                if !hiDPI.isEmpty {
                    resolutionSectionHeader("HiDPI")
                    ForEach(hiDPI) { resolutionRow($0, label: $0.resolutionString) }
                }
                if !lowRes.isEmpty {
                    // "Non-HiDPI" (not "Low Resolution"): accurate for both the
                    // external's soft 1x twins and the built-in's big 1x modes
                    // (e.g. 3024x1964, high pixel count but non-Retina).
                    resolutionSectionHeader("Non-HiDPI")
                    ForEach(lowRes) { resolutionRow($0, label: $0.resolutionString) }
                }
            }
        }
    }

    private func resolutionRow(_ group: ResolutionGroup, label: String) -> some View {
        CheckmarkRow(
            label: label,
            isSelected: group.id == currentGroup?.id,
            isPending: group.id == pendingResolutionID
        ) {
            selectResolution(group)
        }
    }

    private func resolutionSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundColor(.secondary)
            .padding(.leading, 24)
            .padding(.trailing, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    /// Refresh-rate label, matching System Settings: the built-in's 120Hz variable-refresh
    /// mode reads "ProMotion" rather than a fixed number; everything else is its Hz string.
    private func refreshLabel(_ mode: DisplayMode) -> String {
        if display.isBuiltin && Int(mode.refreshRate.rounded()) >= 120 { return "ProMotion" }
        return mode.refreshRateString
    }

    private func refreshList(_ group: ResolutionGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(group.modes) { mode in
                CheckmarkRow(
                    label: refreshLabel(mode),
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

    // MARK: - Smooth scaling

    /// The ladder the Resolution slider steps through. Built-in: the native-aspect HiDPI
    /// "looks like" stops macOS's own slider shows (no 1x "native" stop, since macOS caps
    /// More Space at the largest HiDPI mode). External: smoothModes (HiDPI ladder + native
    /// pixel-for-pixel as the More Space end), which the smooth-scaling toggle densifies.
    private var sliderModes: [DisplayMode] {
        display.isBuiltin ? builtinLooksLikeModes : smoothModes
    }

    /// Built-in "looks like" stops: the native-aspect HiDPI modes (e.g. 1024×665 …
    /// 1800×1169). The aspect test also excludes the 16:10 non-notch modes, matching
    /// the resolution list. One representative per size, ascending (left = Larger Text).
    private var builtinLooksLikeModes: [DisplayMode] {
        let (nativeW, nativeH) = display.nativeResolution
        let nativeAR = Double(nativeW) / Double(nativeH)
        var seen = Set<String>()
        return display.availableModes
            .filter { $0.isHiDPI && abs(Double($0.width) / Double($0.height) - nativeAR) / nativeAR < 0.02 }
            .sorted { $0.refreshRate > $1.refreshRate }
            .filter { seen.insert("\($0.width)x\($0.height)").inserted }
            .sorted { $0.width < $1.width }
    }

    /// The "looks like" ladder for the slider: every HiDPI logical size plus the native
    /// (max) resolution as the top "More Space" stop. On a standard panel the native mode
    /// is non-HiDPI, and the HiDPI ladder can't reach it (native-as-HiDPI needs a backing
    /// the panel/DCP won't enumerate), so without this the slider topped out below the
    /// display's real maximum. One representative per logical size (prefer HiDPI, then
    /// highest refresh), ascending: left = Larger Text, right = More Space.
    private var smoothModes: [DisplayMode] {
        let (nativeW, nativeH) = display.nativeResolution
        // Floor the slider at 50% of native (the 2× Retina point), matching the injected
        // ladder and BetterDisplay. Without this, small HiDPI modes macOS also enumerates
        // (e.g. 800×600 accessibility sizes) would drag the left stop far below anything usable.
        let minWidth = nativeW / 2
        var seen = Set<String>()
        return display.availableModes
            .filter { ($0.isHiDPI && $0.width >= minWidth) || ($0.width == nativeW && $0.height == nativeH) }
            .sorted {
                if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
                return $0.refreshRate > $1.refreshRate
            }
            .filter { seen.insert("\($0.width)x\($0.height)").inserted }
            .sorted { $0.width == $1.width ? $0.height < $1.height : $0.width < $1.width }
    }

    /// A one-way "Enable smooth scaling" row. The dense HiDPI ladder is a one-time install
    /// of extra resolutions that persist (macOS only drops them on a physical reconnect, so
    /// there is no working "off", and nobody wants fewer resolutions anyway). So this just
    /// installs on tap, then disappears once the modes are live; it shows only while they're
    /// missing or still enumerating after the reconnect.
    @ViewBuilder
    private var smoothScalingSection: some View {
        if !smoothModesPresent {
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "slider.horizontal.below.rectangle", color: .blue, active: false)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Smooth scaling")
                            .font(.body)
                        Text("Beta")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    }
                    if let hint = smoothHint {
                        Text(hint.text)
                            .font(.caption)
                            .foregroundColor(hint.warning ? .orange : .secondary)
                    }
                }
                Spacer()
                if smoothBusy {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } else if smoothWouldPrompt {
                    Text("Enable")
                        .font(.callout)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .menuRowHover(smoothRowHovered)
            .contentShape(Rectangle())
            .onTapGesture {
                guard PanelOpenGuard.allowsActivation, !smoothBusy, smoothWouldPrompt else { return }
                enableSmooth()
            }
            .onHover { smoothRowHovered = $0 }
            .onAppear { refreshSmoothWouldPrompt() }
        }
    }

    /// Sub-label for the enable row (only shown while the dense modes aren't live yet): the
    /// reconnect prompt once installed but not enumerated, else the enable pitch.
    private var smoothHint: (text: String, warning: Bool)? {
        if !smoothWouldPrompt {
            return (String(localized: "Reconnect the display to finish"), true)
        }
        return (String(localized: "First enable asks for an administrator password"), false)
    }

    /// Whether the dense smooth-scaling ladder is actually enumerated for this display (≥ half
    /// its sub-native sizes present among the modes). The real "is it on" signal, independent
    /// of any stored flag; it is exactly what the slider's density reflects. When true the
    /// enable row is hidden — there is nothing left to do.
    private var smoothModesPresent: Bool {
        let (w, h) = display.nativeResolution
        let injected = HiDPIService.shared.smoothScaledLogicalSizes(nativeWidth: w, nativeHeight: h)
            .filter { $0.width < w }  // native is a real mode, always present; ignore it
        guard !injected.isEmpty else { return false }
        let present = Set(display.availableModes.lazy.filter { $0.isHiDPI }.map { "\($0.width)x\($0.height)" })
        let hits = injected.filter { present.contains("\($0.width)x\($0.height)") }.count
        return Double(hits) / Double(injected.count) >= 0.5
    }

    /// Whether enabling smooth scaling would show the admin prompt (override not yet
    /// dense). Computed off the render path (on appear + after enable) to avoid a disk
    /// read on every redraw.
    private func refreshSmoothWouldPrompt() {
        let (w, h) = display.nativeResolution
        smoothWouldPrompt = HiDPIService.shared.smoothScalingWouldPrompt(
            vendor: display.vendorNumber, product: display.modelNumber, nativeWidth: w, nativeHeight: h)
    }

    @ViewBuilder
    private func modeSlider(_ modes: [DisplayMode]) -> some View {
        if modes.count >= 2 {
            let defaultIdx = defaultSliderIndex(modes)
            VStack(alignment: .leading, spacing: 2) {
                // Continuous slider (no native step, which would swap in a bar-style thumb)
                // so its knob matches the brightness slider above. Snapped to whole stops
                // live via onChange, so it still clicks tick-to-tick with the round knob.
                // The mode only switches on release; dragging just moves the knob/label.
                Slider(
                    value: $sliderIndex,
                    in: 0...Double(modes.count - 1),
                    onEditingChanged: { editing in
                        if !editing { applySmooth(modes) }
                    }
                )
                .controlSize(.small)
                .tint(Color.accentColor)
                .onChange(of: sliderIndex) { _, v in
                    let snapped = v.rounded()
                    if snapped != sliderIndex { sliderIndex = snapped }
                }

                stepMarks(count: modes.count, defaultIdx: defaultIdx)

                HStack(spacing: 0) {
                    Text("Larger Text")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(looksLikeLabel(modes))
                        .font(.caption2)
                    Spacer()
                    Text("More Space")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .onAppear { sliderIndex = currentSmoothIndex(modes) }
            .onChange(of: display.currentDisplayMode?.id) { _, _ in
                if !smoothBusy { sliderIndex = currentSmoothIndex(modes) }
            }
        }
    }

    /// A tick per stop, with the default stop drawn as a filled dot on top of its tick
    /// (the way BetterDisplay marks it). A dot rather than a "Default" label stays clean
    /// even when the default sits at the very edge. Positioned to track the slider thumb,
    /// which is inset from the track edges by ~half its width (see markX's thumbInset).
    private func stepMarks(count: Int, defaultIdx: Int?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.45))
                        .frame(width: 1, height: 4)
                        .position(x: markX(i, count: count, width: geo.size.width), y: 3)
                }
                if let di = defaultIdx, count > 1 {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: markX(di, count: count, width: geo.size.width), y: 3)
                }
            }
        }
        .frame(height: 8)
    }

    /// X of stop `index` along a slider of the given width, accounting for the thumb inset.
    private func markX(_ index: Int, count: Int, width: Double) -> Double {
        let thumbInset = 8.0
        let frac = count > 1 ? Double(index) / Double(count - 1) : 0
        return thumbInset + frac * max(width - thumbInset * 2, 1)
    }

    /// The stop the slider flags as "Default", i.e. macOS's recommended scaling: the 2×
    /// Retina point (native width / 2) on the high-PPI built-in, native pixel-for-pixel on
    /// an external. Returns nil when that stop isn't on the ladder.
    private func defaultSliderIndex(_ modes: [DisplayMode]) -> Int? {
        let nativeW = display.nativeResolution.width
        let targetW = display.isBuiltin ? nativeW / 2 : nativeW
        return modes.firstIndex { $0.width == targetW }
    }

    private func currentSmoothIndex(_ modes: [DisplayMode]) -> Double {
        guard let cur = currentMode,
              let idx = modes.firstIndex(where: { $0.width == cur.width && $0.height == cur.height })
        else { return Double(max(modes.count - 1, 0)) }
        return Double(idx)
    }

    private func looksLikeLabel(_ modes: [DisplayMode]) -> String {
        let i = Int(sliderIndex.rounded())
        guard modes.indices.contains(i) else { return "" }
        let m = modes[i]
        // Effective magnification vs native: how much larger everything looks. Native = 100%;
        // the 2x Retina point (half native, e.g. 1280×720 on a 2560×1440 panel) = 200%.
        let (nativeW, _) = display.nativeResolution
        guard nativeW > 0, m.width > 0 else { return "\(m.width) × \(m.height)" }
        let pct = Int((Double(nativeW) / Double(m.width) * 100).rounded())
        return "\(m.width) × \(m.height) · \(pct)%"
    }

    private func applySmooth(_ modes: [DisplayMode]) {
        let i = Int(sliderIndex.rounded())
        guard modes.indices.contains(i) else { return }
        let target = modes[i]
        // Keep the current refresh rate at that logical size and scaling kind when offered.
        let mode = display.availableModes.first {
            $0.isHiDPI == target.isHiDPI && $0.width == target.width && $0.height == target.height &&
            $0.refreshRate == currentMode?.refreshRate
        } ?? target
        guard mode.id != currentMode?.id else { return }
        switchTo(mode) { }
    }

    /// One-way install of the dense HiDPI ladder (admin prompt, then a reconnect enumerates
    /// the modes). There is no disable: the modes persist and the enable row hides once they
    /// are live. Re-invoking on an already-installed plist doesn't re-prompt.
    private func enableSmooth() {
        guard !smoothBusy else { return }
        let (nativeW, nativeH) = display.nativeResolution
        smoothBusy = true
        Task { @MainActor in
            let err = HiDPIService.shared.enableSmoothScaling(
                vendor: display.vendorNumber, product: display.modelNumber,
                nativeWidth: nativeW, nativeHeight: nativeH)
            if let err {
                withAnimation { errorMessage = err }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    withAnimation { errorMessage = nil }
                }
            } else {
                HiDPIService.shared.refreshModes(for: display)
                refreshSmoothWouldPrompt()
            }
            smoothBusy = false
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

/// A subordinate disclosure line (indented, chevron, hover) that reveals the full
/// "Show all resolutions" list beneath the Resolution slider. Lighter than
/// ExpandableRow (no leading icon chip) so it reads as a child of the slider.
private struct DisclosureSubRow: View {
    let label: LocalizedStringKey
    @Binding var isExpanded: Bool
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .regular))
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .accessibilityHidden(true)
        }
        .padding(.leading, 24)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            withAnimation(.panelResize) { isExpanded.toggle() }
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Data model

private struct ResolutionGroup: Identifiable {
    let width: Int
    let height: Int
    let isHiDPI: Bool
    let isDefault: Bool
    let isLowResolution: Bool
    let modes: [DisplayMode] // sorted by refresh rate descending

    var id: String { "\(width)x\(height)_\(isHiDPI)" }
    var resolutionString: String { "\(width) × \(height)" }
    /// Native System Settings wording: retina modes clean, the 1x twin "(low
    /// resolution)", the display's native mode "(Default)". Every unmarked row is
    /// therefore a HiDPI/retina mode; the "(low resolution)" tag flags the soft ones.
    var menuLabel: String {
        if isDefault { return "\(resolutionString) (Default)" }
        if isLowResolution { return "\(resolutionString) (low resolution)" }
        return resolutionString
    }
    var hasMultipleRates: Bool { modes.count > 1 }
    var bestMode: DisplayMode { modes[0] }
}
