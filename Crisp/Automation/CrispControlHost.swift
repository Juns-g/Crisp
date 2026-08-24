import Foundation
#if canImport(CrispControlCore)
import CrispControlCore
#endif

@MainActor
final class CrispControlHost {
    private let server: UnixSocketServer

    init(displayManager: DisplayManager) {
        let service = CrispControlAppService(displayManager: displayManager)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: version)
        server = UnixSocketServer { request in await dispatcher.handle(request) }
    }

    func start() throws { try server.start() }
    func stop() { server.stop() }
}

@MainActor
private final class CrispControlAppService: ControlCommandService, @unchecked Sendable {
    private let displayManager: DisplayManager

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func displays() async throws -> [ControlDisplay] {
        displayManager.displays.map { display in
            let capability: BrightnessCapability
            if display.isBuiltin {
                capability = BrightnessCapability(
                    state: .writable,
                    backend: BrightnessService.shared.hasDisplayServicesControl ? .displayServices : .ioKit,
                    range: ControlRange(min: 0, max: 100, precision: 0.1),
                    readback: .authoritative
                )
            } else if BrightnessService.shared.isDDCAvailable(for: display.displayID) == true {
                let backend = BrightnessService.shared.controlBackend(for: display)
                let readback = BrightnessService.shared.controlReadbackQuality(for: display)
                capability = BrightnessCapability(
                    state: .writable,
                    backend: backend,
                    range: ControlRange(min: 0, max: 100, precision: 1),
                    readback: readback,
                    reason: readback == .unavailable
                        ? "active backend does not provide independent read-back"
                        : "monitor DDC read-back may be quantized"
                )
            } else {
                capability = BrightnessCapability(
                    state: .writable,
                    backend: .software,
                    range: ControlRange(min: 0, max: 100, precision: 1),
                    readback: .unavailable,
                    reason: "hardware DDC is unavailable or not yet established",
                    remediation: "open Crisp once after connecting the display to allow DDC discovery"
                )
            }
            return ControlDisplay(
                uuid: display.displayUUID,
                name: display.name,
                isMain: display.isMain,
                isBuiltin: display.isBuiltin,
                brightness: capability,
                brightnessPercent: display.brightness
            )
        }.sorted { $0.uuid < $1.uuid }
    }

    func readBrightness(displayUUID: String) async throws -> Double? {
        guard let display = displayManager.displays.first(where: { $0.displayUUID == displayUUID }) else {
            throw ControlServiceError.readFailed("display disconnected before brightness read-back")
        }
        return await BrightnessService.shared.readBrightnessForControl(for: display)
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        guard let display = displayManager.displays.first(where: { $0.displayUUID == displayUUID }) else {
            throw ControlServiceError.writeFailed("display disconnected before brightness write")
        }
        return try await BrightnessService.shared.writeBrightnessForControl(percent, for: display)
    }
}
