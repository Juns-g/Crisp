import SwiftUI

/// "Auto Brightness" section — follows builtin screen brightness and adjusts external display brightness automatically.
struct AutoBrightnessView: View {
    @StateObject private var service = AutoBrightnessService.shared

    /// True only after the service has polled at least once and found no builtin display.
    private var builtinUnavailable: Bool {
        service.hasPolled && service.builtinBrightness <= 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main toggle
            HStack(spacing: 6) {
                MenuItemIcon(systemName: "sun.and.horizon.fill", color: .orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Brightness")
                        .font(.body)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Toggle("", isOn: $service.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(builtinUnavailable)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
    }

    private var statusText: String {
        builtinUnavailable
            ? String(localized: "No built-in display detected")
            : String(localized: "External displays follow the built-in display's brightness")
    }
}
