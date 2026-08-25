import Darwin
import Foundation
import CrispControlCore

private actor FixtureService: ControlCommandService {
    private var brightness = ["fixture-built-in": 42.0, "fixture-external": 48.0]
    private var boostEnabled = false
    private var hdrEnabled = true

    func displays() async throws -> [ControlDisplay] {
        let builtinMax = boostEnabled ? 150.0 : 100.0
        return [
            ControlDisplay(
                uuid: "fixture-built-in", name: "Fixture Built-in", isMain: true, isBuiltin: true,
                brightness: BrightnessCapability(
                    state: .writable, backend: .displayServices,
                    range: ControlRange(min: 0, max: builtinMax, precision: 0.1),
                    readback: .authoritative,
                    hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
                    logicalRange: ControlRange(min: 0, max: builtinMax, precision: 0.1)
                ),
                brightnessPercent: brightness["fixture-built-in"],
                extraBrightness: ExtraBrightnessCapability(
                    state: .writable, enabled: boostEnabled, persistedEnabled: boostEnabled,
                    maxBrightness: builtinMax,
                    headroom: EDRHeadroomSnapshot(potential: 1.6, current: 1.5)
                ),
                hdr: .unsupported(
                    reason: "built-in displays do not expose an HDR preference toggle",
                    remediation: "use Extra Brightness when eligible"
                )
            ),
            ControlDisplay(
                uuid: "fixture-external", name: "Fixture External", isMain: false, isBuiltin: false,
                brightness: BrightnessCapability(
                    state: .writable, backend: .software,
                    range: ControlRange(min: 0, max: 100, precision: 1), readback: .unavailable
                ),
                brightnessPercent: brightness["fixture-external"],
                extraBrightness: .unsupported(reason: "fixture external boost is unavailable"),
                hdr: HDRCapability(state: .writable, enabled: hdrEnabled)
            )
        ]
    }

    func readBrightness(displayUUID: String) async throws -> Double? { brightness[displayUUID] }

    func readBrightnessState(displayUUID: String) async throws -> BrightnessReadSnapshot? {
        guard let logical = brightness[displayUUID] else { return nil }
        let hardware = displayUUID == "fixture-external" ? nil : min(logical, 100)
        return BrightnessReadSnapshot(logicalPercent: logical, hardwareReadbackPercent: hardware)
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        brightness[displayUUID] = percent
        return percent
    }

    func setExtraBrightness(displayUUID: String, enabled: Bool) async throws -> ExtraBrightnessSetResult {
        guard displayUUID == "fixture-built-in" else {
            throw ControlServiceError.unsupported("fixture boost unsupported")
        }
        boostEnabled = enabled
        let maximum = enabled ? 150.0 : 100.0
        return ExtraBrightnessSetResult(
            capability: ExtraBrightnessCapability(
                state: .writable, enabled: enabled, persistedEnabled: enabled,
                maxBrightness: maximum,
                headroom: EDRHeadroomSnapshot(potential: 1.6, current: 1.5)
            ),
            verification: .appStateVerified
        )
    }

    func setHDR(displayUUID: String, enabled: Bool) async throws -> HDRSetResult {
        guard displayUUID == "fixture-external" else {
            throw ControlServiceError.unsupported("fixture HDR unsupported")
        }
        hdrEnabled = enabled
        return HDRSetResult(
            capability: HDRCapability(state: .writable, enabled: enabled),
            verification: .verified
        )
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: crisp-control-test-host <socket-path>\n".utf8))
    exit(2)
}

let dispatcher = ControlCommandDispatcher(service: FixtureService(), appVersion: "test-host")
let server = UnixSocketServer(path: CommandLine.arguments[1]) { request in await dispatcher.handle(request) }
do {
    try server.start()
} catch {
    FileHandle.standardError.write(Data("test host failed: \(error)\n".utf8))
    exit(1)
}

private enum FixtureSignalHandlers {
    static func make(for server: UnixSocketServer) -> [DispatchSourceSignal] {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let queue = DispatchQueue(label: "com.crisp.control.test-host.signals")
        let sources = [
            DispatchSource.makeSignalSource(signal: SIGINT, queue: queue),
            DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        ]
        for source in sources {
            source.setEventHandler {
                server.stop()
                exit(0)
            }
            source.resume()
        }
        return sources
    }
}

let signalSources = FixtureSignalHandlers.make(for: server)
withExtendedLifetime(signalSources) {
    dispatchMain()
}
