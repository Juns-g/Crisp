import SwiftUI

/// Per-display manual volume enable (issue #57). Some monitors (LG 27UP850N
/// over USB-C) accept DDC volume writes but never answer the 0x62 probe read,
/// so volumeSupported can never turn on by itself and the whole volume
/// feature stays hidden. This row appears only for externals in that state
/// and forces write-only volume for the display (persisted by UUID in
/// VolumeService). Probe-confirmed monitors never show it.
struct VolumeOverrideView: View {
    @ObservedObject var display: DisplayInfo
    @State private var isHovered = false

    var body: some View {
        if !display.isBuiltin,
           !display.volumeSupported || VolumeService.shared.isForced(display) {
            HStack {
                MenuItemIcon(systemName: "speaker.wave.2.fill", color: .blue, active: display.volumeSupported)
                Text("Volume Control")
                    .font(.body)
                Spacer()
                Toggle("", isOn: Binding(
                    get: { VolumeService.shared.isForced(display) },
                    set: { VolumeService.shared.setForced($0, for: display) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .menuRowHover(isHovered)
            .onHover { isHovered = $0 }
            .help("Force volume control for a monitor that doesn't report it. Crisp can set the volume but not read the current level.")
        }
    }
}
