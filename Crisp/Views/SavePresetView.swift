import SwiftUI

// MARK: - SavePresetView

/// Section in MenuBarView that lets users save the current display state as a
/// named preset. Collapsed, it's a single "New Preset" row; expanded, the row
/// is replaced by a bounded card with its own Cancel / Save buttons.
struct SavePresetView: View {
    @State private var isShowingForm = false
    @State private var isHovered = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fade the row out / card in on the panel spring (no curtain wipe or
            // slide, so nothing ghosts through the glass mid-reveal).
            if isShowingForm {
                SavePresetForm(
                    onClose: { withAnimation(.panelResize) { isShowingForm = false } },
                    nameFocused: $nameFocused
                )
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                    .transition(.opacity)
            } else {
                Button(action: {
                    // Focus the name field the instant the reveal finishes —
                    // completion handler, not a timer.
                    withAnimation(.panelResize) {
                        isShowingForm = true
                    } completion: {
                        nameFocused = true
                    }
                }) {
                    HStack {
                        MenuItemIcon(systemName: "plus", color: .blue)
                        Text("New Preset")
                            .font(.body)
                        Spacer()
                    }
                    // Padding inside the button label so the tappable area
                    // matches the hover highlight (no dead padded margin).
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .menuRowHover(isHovered)
                .onHover { isHovered = $0 }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - SavePresetForm

/// Bounded card for naming and saving the current display state as a preset.
/// Icon + color are tucked behind the icon button so the common case (name it,
/// save) stays short.
struct SavePresetForm: View {
    /// nil = creating a new preset (captures current state on save); non-nil =
    /// editing an existing one (updates its identity + capture inclusions).
    var editing: DisplayPreset? = nil
    let onClose: () -> Void

    @State private var presetName: String = ""
    @State private var selectedIcon: String = "display"
    @State private var selectedColor: String = "indigo"
    @State private var includeResolution: Bool = true
    @State private var includeBrightness: Bool = true
    @State private var includeArrangement: Bool = true
    @State private var showIdentityPicker: Bool = false
    @State private var isSaving: Bool = false
    @State private var saveError: String?
    /// Owned by the parent so it can focus the field in the reveal animation's
    /// completion handler (focusing mid-reveal janks the transition).
    @FocusState.Binding var nameFocused: Bool

    init(editing: DisplayPreset? = nil,
         onClose: @escaping () -> Void,
         nameFocused: FocusState<Bool>.Binding) {
        self.editing = editing
        self.onClose = onClose
        self._nameFocused = nameFocused
        _presetName = State(initialValue: editing?.name ?? "")
        _selectedIcon = State(initialValue: editing?.icon ?? "display")
        _selectedColor = State(initialValue: editing?.colorName ?? "indigo")
        _includeResolution = State(initialValue: editing?.includesResolution ?? true)
        _includeBrightness = State(initialValue: editing?.includesBrightness ?? true)
        _includeArrangement = State(initialValue: editing?.includesArrangement ?? true)
    }

    private var nothingSelected: Bool {
        !includeResolution && !includeBrightness && !includeArrangement
    }

    /// The swatch currently picked in the Color picker; the icon button previews it live.
    private var selectedSwatch: Color {
        DisplayPreset.colorOptions.first(where: { $0.name == selectedColor })?.color ?? .indigo
    }

    private let iconOptions: [(symbol: String, label: String)] = [
        ("display", "Display"),
        ("sparkles.rectangle.stack", "HiDPI"),
        ("rectangle.on.rectangle", "Mirror"),
        ("moon.fill", "Night"),
        ("sun.max.fill", "Day"),
        ("gamecontroller.fill", "Gaming"),
        ("person.fill", "Personal"),
        ("briefcase.fill", "Work"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Identity line: icon button (opens icon+color) + name field
            HStack(spacing: 9) {
                PresetIconButton(symbol: selectedIcon, color: selectedSwatch, isOpen: showIdentityPicker) {
                    withAnimation(.panelResize) { showIdentityPicker.toggle() }
                }
                // Explicit placeholder: macOS drops a plain field's own
                // placeholder once it's focused, so draw our own while empty.
                ZStack(alignment: .leading) {
                    if presetName.isEmpty {
                        Text("Preset name")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $presetName)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .focused($nameFocused)
                        .onSubmit(save)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(nameFocused ? 0.10 : 0.07))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(nameFocused ? 0.85 : 0), lineWidth: 2)
                )
                .animation(.easeOut(duration: 0.12), value: nameFocused)
            }

            // Progressive icon + color picker (collapsed by default)
            if showIdentityPicker {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Icon")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        // Plain HStack, not LazyVGrid: lazy containers reposition
                        // their items mid-flight during animated panel resizes.
                        HStack(spacing: 4) {
                            ForEach(iconOptions, id: \.symbol) { option in
                                IconOptionButton(
                                    symbol: option.symbol,
                                    label: option.label,
                                    isSelected: selectedIcon == option.symbol,
                                    tint: selectedSwatch
                                ) {
                                    selectedIcon = option.symbol
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Color")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack(spacing: 7) {
                            ForEach(DisplayPreset.colorOptions, id: \.name) { option in
                                Button {
                                    selectedColor = option.name
                                } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 16, height: 16)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(.white.opacity(selectedColor == option.name ? 0.9 : 0), lineWidth: 2)
                                        )
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(option.name) color")
                                .accessibilityAddTraits(selectedColor == option.name ? [.isSelected] : [])
                            }
                        }
                    }
                }
                .padding(9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.18))
                )
                // Fade in place (no slide from behind the identity row, which
                // would ghost through the glass mid-reveal).
                .transition(.opacity)
            }

            // Captures
            VStack(alignment: .leading, spacing: 6) {
                Text("Captures")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                CaptureToggleRow(icon: "rectangle.on.rectangle", color: .blue,
                                 label: "Resolution", isOn: $includeResolution)
                CaptureToggleRow(icon: "sun.max.fill", color: .orange,
                                 label: "Brightness", isOn: $includeBrightness)
                CaptureToggleRow(icon: "display.2", color: .indigo,
                                 label: "Arrangement", isOn: $includeArrangement)
            }

            if let err = saveError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Cancel / Save
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if isSaving {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                }
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || nothingSelected || presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: saveError)
    }

    private func save() {
        let name = presetName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !nothingSelected else { return }

        isSaving = true
        saveError = nil

        if let editing {
            // Edit: update identity + capture inclusions, preserving stored
            // values for captures left unchanged.
            PresetService.shared.editPreset(
                id: editing.id, name: name, icon: selectedIcon, colorName: selectedColor,
                includeResolution: includeResolution,
                includeBrightness: includeBrightness,
                includeArrangement: includeArrangement
            )
        } else {
            var preset = PresetService.shared.captureCurrentState(
                name: name, icon: selectedIcon,
                includeResolution: includeResolution,
                includeBrightness: includeBrightness,
                includeArrangement: includeArrangement
            )
            preset.colorName = selectedColor
            PresetService.shared.addPreset(preset)
        }

        isSaving = false
        onClose()
    }
}

// MARK: - PresetIconButton

/// The preset's icon shown in its color; tapping expands the icon + color
/// picker. A small chevron badge marks it as a disclosure.
struct PresetIconButton: View {
    let symbol: String
    let color: Color
    let isOpen: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 34, height: 34)
                .background(Circle().fill(color))
                .overlay(
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(isOpen ? 0.9 : (isHovered ? 0.3 : 0)), lineWidth: 2)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(Color(white: 0.16)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .offset(x: 1, y: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Icon & color")
        .accessibilityLabel("Choose icon and color")
    }
}

// MARK: - CaptureToggleRow

/// One "Captures" switch row: colored icon chip + label + native switch.
/// Mirrors the Settings toggle rows so it inherits the panel's look (and the
/// native Liquid Glass material on macOS 26).
struct CaptureToggleRow: View {
    let icon: String
    let color: Color
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                MenuItemIcon(systemName: icon, color: color)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(label))
                    .font(.body)
                Spacer()
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

// MARK: - IconOptionButton

struct IconOptionButton: View {
    let symbol: String
    let label: String
    let isSelected: Bool
    let tint: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isSelected ? tint : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                )
                // Without this the clear background doesn't hit-test, so hover
                // only fires over the glyph strokes, not the full highlight box.
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(label)
    }
}
