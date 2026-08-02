import SwiftUI

/// Sun step icon flanking a brightness slider: brightens while pressed, steps
/// once on click, and keeps stepping while held (initial delay, then repeat),
/// like holding a hardware brightness key.
struct BrightnessStepButton: View {
    let systemName: String
    let action: () -> Void

    var body: some View {
        // A Button, not a raw DragGesture: these live inside the panel's
        // ScrollView, which steals a DragGesture so its onEnded never fires and
        // the "pressed" highlight sticks on. ButtonStyle.isPressed is managed by
        // the framework and always resets on release (and on scroll-steal).
        Button(action: {}) {
            Image(systemName: systemName)
                .font(.system(size: 15))
        }
        .buttonStyle(HoldRepeatButtonStyle(action: action))
        .accessibilityHidden(true)
    }
}

/// Lights the glyph only while physically held, and repeats the step action
/// (initial delay, then steady repeat) for as long as it stays held.
private struct HoldRepeatButtonStyle: ButtonStyle {
    let action: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        HoldRepeatLabel(configuration: configuration, action: action)
    }

    private struct HoldRepeatLabel: View {
        let configuration: ButtonStyleConfiguration
        let action: () -> Void
        @State private var repeatTask: Task<Void, Never>? = nil

        var body: some View {
            configuration.label
                .foregroundColor(configuration.isPressed ? .primary : .secondary)
                .contentShape(Rectangle())
                .onChange(of: configuration.isPressed) { _, pressed in
                    if pressed {
                        action()
                        repeatTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            while !Task.isCancelled {
                                action()
                                try? await Task.sleep(nanoseconds: 150_000_000)
                            }
                        }
                    } else {
                        repeatTask?.cancel()
                        repeatTask = nil
                    }
                }
        }
    }
}

struct BrightnessSliderView: View {
    @ObservedObject var display: DisplayInfo
    var compact: Bool = false  // Compact mode: hides the mode label row (used for top-level inline sliders)
    @State private var localBrightness: Double = 50
    @State private var isDragging: Bool = false
    @State private var ddcStatus: Bool? = nil  // nil=unknown, true=DDC, false=Software
    // Track-click vs drag: defer the first value change of an editing session. A click
    // produces a single change (glide it on release); a drag produces a stream (write live).
    @State private var dragConfirmed: Bool = false
    @State private var deferredFirstChange: Bool = false
    // While a click's fade runs, hold the thumb at the target instead of letting the
    // display->slider sync pull it back down through the fade.
    @State private var clickGliding: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            // Mode indicator row
            if !compact {
            HStack(spacing: 4) {
                Spacer()
                if display.isBuiltin {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text("System")
                        .font(.caption2)
                        .foregroundColor(.blue)
                } else if let status = ddcStatus {
                    Circle()
                        .fill(status ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(status ? "DDC" : "Software")
                        .font(.caption2)
                        .foregroundColor(status ? .green : .orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .accessibilityLabel(display.isBuiltin ? "Brightness control mode: System" : "Brightness control mode: \(ddcStatus == true ? "DDC hardware" : "Software emulation")")
            }

            HStack(spacing: 8) {
                BrightnessStepButton(systemName: "sun.min.fill") { step(-brightnessStep) }

                // Native macOS slider, exactly as in the system Display panel.
                Slider(value: $localBrightness, in: 0...100) { editing in
                    if editing {
                        isDragging = true
                        dragConfirmed = false
                        deferredFirstChange = false
                    } else {
                        isDragging = false
                        if !dragConfirmed {
                            // It was a click, not a drag. DDC external monitors physically flash
                            // on every brightness write, so a multi-step fade just multiplies the
                            // flicker, write those once, instantly. Built-in and software (gamma)
                            // brightness fade smoothly with no flash, so glide those to the target
                            // (the thumb is already there; hold it until the fade lands).
                            if ddcStatus == true {
                                display.brightness = localBrightness
                                Task { @MainActor in
                                    await BrightnessService.shared.setBrightness(localBrightness, for: display)
                                    updateDDCStatus()
                                }
                            } else {
                                clickGliding = true
                                BrightnessService.shared.setBrightnessSmooth(localBrightness, for: display, duration: 0.2)
                                Task { @MainActor in
                                    try? await Task.sleep(nanoseconds: 600_000_000)  // fallback release
                                    clickGliding = false
                                    updateDDCStatus()
                                }
                            }
                        } else {
                            Task { @MainActor in
                                // Flush the final value; the coalescing writer already tracked the drag.
                                await BrightnessService.shared.setBrightness(localBrightness, for: display)
                                updateDDCStatus()
                            }
                        }
                    }
                }
                .tint(Color.accentColor)
                .controlSize(.small)
                .accessibilityLabel("Display brightness")
                .accessibilityValue("\(Int(localBrightness))%")
                .onChange(of: localBrightness) { _, newValue in
                    guard isDragging else { return }
                    if dragConfirmed {
                        // Apply immediately, the service chooses software or DDC internally,
                        // and its coalescing writer keeps the I2C bus from flooding.
                        display.brightness = newValue
                        Task { @MainActor in
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    } else if !deferredFirstChange {
                        // First change: could be a click or the start of a drag. Defer the
                        // write so a click can glide from the old value instead of jumping.
                        deferredFirstChange = true
                    } else {
                        // Second change: it's a real drag. Go live from here.
                        dragConfirmed = true
                        display.brightness = newValue
                        Task { @MainActor in
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    }
                }

                BrightnessStepButton(systemName: "sun.max.fill") { step(brightnessStep) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .task(id: display.displayID) {
            localBrightness = display.brightness
            updateDDCStatus()
        }
        .onChange(of: display.brightness) { _, newValue in
            // While a click-glide runs, hold the thumb at the target the click set and
            // release once the fade reaches it, so the thumb never snaps back down through
            // the fade (and the release timing tracks the actual DDC fade, not a guess).
            if clickGliding {
                if abs(newValue - localBrightness) < 0.75 { clickGliding = false }
                return
            }
            // External change (preset fade, brightness keys, another app).
            // NSSlider renders value changes discretely (withAnimation does not
            // interpolate control values), so smoothness comes from the 60Hz
            // fade steps; track every one of them with a low threshold.
            if !isDragging && abs(newValue - localBrightness) >= 0.1 {
                localBrightness = newValue
            }
        }
    }

    private func updateDDCStatus() {
        ddcStatus = BrightnessService.shared.isDDCAvailable(for: display.displayID)
    }

    /// Brightness change per tap (and per hold-repeat) of the sun buttons.
    private var brightnessStep: Double { 10.0 }

    private func step(_ delta: Double) {
        let target = max(0, min(100, display.brightness + delta))
        // The smooth fade updates display.brightness per frame; localBrightness
        // follows through the existing onChange sync.
        BrightnessService.shared.setBrightnessSmooth(target, for: display)
    }
}

struct CombinedBrightnessView: View {
    let displays: [DisplayInfo]
    @State private var combinedBrightness: Double = 50
    @State private var isDragging: Bool = false

    private var averageBrightness: Double {
        guard !displays.isEmpty else { return 50 }
        return displays.map(\.brightness).reduce(0, +) / Double(displays.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Bold title matching the per-display name rows (DisplayRowView), so the
            // combined control reads as another titled row rather than a separate
            // widget. Aligned to the display titles' 14pt inset; the slider below
            // keeps the sliders' 12pt inset.
            Text("Combined")
                .fontWeight(.semibold)
                .lineLimit(1)
                .padding(.horizontal, 14)

            HStack(spacing: 8) {
                BrightnessStepButton(systemName: "sun.min.fill") { stepAll(-10.0) }

                Slider(value: $combinedBrightness, in: 0...100) { editing in
                    isDragging = editing
                    if !editing {
                        // Drag ended, flush final value to all displays.
                        Task { @MainActor in
                            for display in displays {
                                await BrightnessService.shared.setBrightness(combinedBrightness, for: display)
                            }
                        }
                    }
                }
                .tint(Color.accentColor)
                .controlSize(.small)
                .accessibilityLabel("Combined brightness")
                .accessibilityValue("\(Int(combinedBrightness))%")
                .onChange(of: combinedBrightness) { _, newValue in
                    guard isDragging else { return }
                    Task { @MainActor in
                        for display in displays {
                            display.brightness = newValue
                            await BrightnessService.shared.setBrightness(newValue, for: display)
                        }
                    }
                }

                BrightnessStepButton(systemName: "sun.max.fill") { stepAll(10.0) }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background {
            // Track the displays' real brightness so the combined handle glides in
            // exact sync with the per-display handles (they read the same source
            // that setBrightnessSmooth updates per-frame). Invisible; skipped while
            // dragging, when the drag itself is driving the displays.
            ForEach(displays) { display in
                BrightnessProbe(display: display) {
                    if !isDragging { combinedBrightness = averageBrightness }
                }
            }
        }
        .onAppear {
            combinedBrightness = averageBrightness
        }
    }

    private func stepAll(_ delta: Double) {
        let target = max(0, min(100, combinedBrightness + delta))
        // Fade every display with the tuned smooth transition (paces DDC/gamma,
        // re-targets any in-flight fade). The handle is NOT moved here: it follows
        // the displays' real brightness via BrightnessProbe, so it glides in exact
        // sync with the per-display handles instead of lagging a separate ramp.
        for display in displays {
            BrightnessService.shared.setBrightnessSmooth(target, for: display)
        }
    }
}

/// Invisible observer of one display's brightness. Lets an aggregate control (the
/// combined slider) react to the displays' real per-frame fade without owning a
/// separate animation. Zero-sized, so it adds nothing to layout.
private struct BrightnessProbe: View {
    @ObservedObject var display: DisplayInfo
    let onChange: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: display.brightness) { _, _ in onChange() }
    }
}
