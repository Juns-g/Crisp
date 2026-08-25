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
            let boost = BrightnessBoostService.shared
            let isVirtual = VirtualDisplayService.shared.isVirtualDisplay(display.displayID)
            let extraBrightness = extraBrightnessCapability(for: display, isVirtual: isVirtual)
            let hdr = hdrCapability(for: display, isVirtual: isVirtual)
            let logicalMax = boost.isEnabled(for: display) && boost.isEligible(display)
                ? max(100, display.maxBrightness) : 100
            let capability: BrightnessCapability
            if display.isBuiltin {
                capability = BrightnessCapability(
                    state: .writable,
                    backend: BrightnessService.shared.hasDisplayServicesControl ? .displayServices : .ioKit,
                    range: ControlRange(min: 0, max: logicalMax, precision: 0.1),
                    readback: .authoritative,
                    hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
                    logicalRange: ControlRange(min: 0, max: logicalMax, precision: 0.1)
                )
            } else if BrightnessService.shared.isDDCAvailable(for: display.displayID) == true {
                let backend = BrightnessService.shared.controlBackend(for: display)
                let readback = BrightnessService.shared.controlReadbackQuality(for: display)
                capability = BrightnessCapability(
                    state: .writable,
                    backend: backend,
                    range: ControlRange(min: 0, max: logicalMax, precision: 1),
                    readback: readback,
                    hardwareRange: ControlRange(min: 0, max: 100, precision: 1),
                    logicalRange: ControlRange(min: 0, max: logicalMax, precision: 1),
                    reason: readback == .unavailable
                        ? "active backend does not provide independent read-back"
                        : "monitor DDC read-back may be quantized"
                )
            } else {
                capability = BrightnessCapability(
                    state: .writable,
                    backend: .software,
                    range: ControlRange(min: 0, max: logicalMax, precision: 1),
                    readback: .unavailable,
                    hardwareRange: ControlRange(min: 0, max: 100, precision: 1),
                    logicalRange: ControlRange(min: 0, max: logicalMax, precision: 1),
                    reason: "hardware DDC is unavailable or not yet established",
                    remediation: "open Crisp once after connecting the display to allow DDC discovery"
                )
            }
            return ControlDisplay(
                uuid: display.displayUUID,
                name: display.name,
                isMain: display.isMain,
                isBuiltin: display.isBuiltin,
                isVirtual: isVirtual,
                brightness: capability,
                brightnessPercent: display.brightness,
                extraBrightness: extraBrightness,
                hdr: hdr
            )
        }.sorted { $0.uuid < $1.uuid }
    }

    func readBrightness(displayUUID: String) async throws -> Double? {
        try await readBrightnessState(displayUUID: displayUUID)?.logicalPercent
    }

    func readBrightnessState(displayUUID: String) async throws -> BrightnessReadSnapshot? {
        guard let display = displayManager.displays.first(where: { $0.displayUUID == displayUUID }) else {
            throw ControlServiceError.readFailed("display disconnected before brightness read-back")
        }
        return await BrightnessService.shared.readBrightnessStateForControl(for: display)
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        guard let display = displayManager.displays.first(where: { $0.displayUUID == displayUUID }) else {
            throw ControlServiceError.writeFailed("display disconnected before brightness write")
        }
        return try await BrightnessService.shared.writeBrightnessForControl(percent, for: display)
    }

    func setExtraBrightness(displayUUID: String, enabled: Bool) async throws -> ExtraBrightnessSetResult {
        let display = try connectedDisplay(uuid: displayUUID, operation: "Extra Brightness write")
        let boost = BrightnessBoostService.shared
        let eligible = boost.isEligible(display)
        let cleanupNeeded = !enabled && boost.needsDisableCleanup(for: display)
        guard eligible || cleanupNeeded else {
            throw ControlServiceError.unsupported("Extra Brightness is not eligible for this display")
        }
        guard try await boost.setEnabled(enabled, for: display) else {
            throw ControlServiceError.writeFailed("Extra Brightness request was rejected by the live app service")
        }

        for _ in 0..<10 {
            let persisted = BrightnessBoostService.shared.isEnabled(for: display)
            let ceilingSettled = enabled ? display.maxBrightness > 100 : display.maxBrightness <= 100.5
            if persisted == enabled, ceilingSettled { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let capability = extraBrightnessCapability(
            for: display,
            isVirtual: VirtualDisplayService.shared.isVirtualDisplay(display.displayID)
        )
        let ceilingSettled = enabled ? capability.maxBrightness > 100 : capability.maxBrightness <= 100.5
        let verification: AppStateVerificationQuality = ceilingSettled ? .appStateVerified : .settling
        let warnings = ceilingSettled ? [] : [
            enabled
                ? "Extra Brightness was accepted but the dynamic EDR ceiling is still settling"
                : "Extra Brightness is off in persisted app state but the animated ceiling is still collapsing"
        ]
        return ExtraBrightnessSetResult(
            capability: capability, verification: verification, warnings: warnings
        )
    }

    func setHDR(displayUUID: String, enabled: Bool) async throws -> HDRSetResult {
        let display = try connectedDisplay(uuid: displayUUID, operation: "HDR write")
        guard BrightnessBoostService.shared.isEligibleForHDRToggle(display) else {
            throw ControlServiceError.unsupported(
                display.isBuiltin
                    ? "built-in displays do not expose an HDR preference toggle; use Extra Brightness when eligible"
                    : "Crisp does not expose a writable HDR toggle for this display"
            )
        }
        guard try await BrightnessBoostService.shared.setHDRPreference(enabled, for: display) else {
            throw ControlServiceError.writeFailed("HDR preference request was rejected by the live app service")
        }
        for _ in 0..<20 {
            if BrightnessBoostService.shared.isHDREnabled(for: display) == enabled { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let capability = hdrCapability(for: display, isVirtual: false)
        guard capability.enabled == enabled else {
            throw ControlServiceError.writeFailed("HDR preference did not match bounded live read-back")
        }
        return HDRSetResult(capability: capability, verification: .verified)
    }

    private func connectedDisplay(uuid: String, operation: String) throws -> DisplayInfo {
        guard let display = displayManager.displays.first(where: { $0.displayUUID == uuid }) else {
            throw ControlServiceError.writeFailed("display disconnected before \(operation)")
        }
        return display
    }

    private func extraBrightnessCapability(
        for display: DisplayInfo,
        isVirtual: Bool
    ) -> ExtraBrightnessCapability {
        let boost = BrightnessBoostService.shared
        let persisted = boost.isEnabled(for: display)
        let headroom = boost.controlHeadroomSnapshot(for: display)
        guard !isVirtual, boost.isEligible(display) else {
            return .unsupported(
                enabled: display.maxBrightness > 100,
                persistedEnabled: persisted,
                maxBrightness: display.maxBrightness,
                headroom: headroom,
                reason: isVirtual
                    ? "Extra Brightness is unavailable for virtual displays"
                    : "no usable live EDR headroom and no writable external HDR toggle",
                remediation: "use a built-in XDR panel or an external display with a Crisp-writable HDR toggle"
            )
        }
        let hasLiveHeadroom = headroom.potential > 1.05
        return ExtraBrightnessCapability(
            state: .writable,
            enabled: display.maxBrightness > 100,
            persistedEnabled: persisted,
            maxBrightness: display.maxBrightness,
            headroom: headroom,
            reason: hasLiveHeadroom
                ? "usable live EDR headroom is available"
                : "eligible through the external HDR toggle but not boost-ready until HDR headroom settles",
            remediation: hasLiveHeadroom ? nil : "enable Extra Brightness to request HDR and re-check live headroom"
        )
    }

    private func hdrCapability(for display: DisplayInfo, isVirtual: Bool) -> HDRCapability {
        let boost = BrightnessBoostService.shared
        if display.isBuiltin {
            return .unsupported(
                reason: "built-in displays do not expose an HDR preference toggle",
                remediation: "use Extra Brightness when eligible"
            )
        }
        guard !isVirtual else {
            return .unsupported(
                reason: "HDR preference is unavailable for virtual displays",
                remediation: "use the display or macOS settings if HDR is available there"
            )
        }
        if boost.isEligibleForHDRToggle(display) {
            return HDRCapability(
                state: .writable,
                enabled: boost.isHDREnabled(for: display)
            )
        }
        guard let liveState = boost.controlHDRState(for: display) else {
            return .unsupported(
                reason: "Crisp cannot read or write HDR preference for this display",
                remediation: "use the display or macOS settings if HDR is available there"
            )
        }
        return HDRCapability(
            state: .readable,
            enabled: liveState,
            reason: "HDR preference is readable, but Crisp does not expose a writable toggle for this display",
            remediation: "use the display or macOS settings to change HDR"
        )
    }
}
