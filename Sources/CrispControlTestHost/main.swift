import Darwin
import Foundation
import CrispControlCore

private actor FixtureService: ControlCommandService {
    private var brightness = 42.0
    private let capability = BrightnessCapability(
        state: .writable,
        backend: .displayServices,
        range: ControlRange(min: 0, max: 100, precision: 0.1),
        readback: .authoritative
    )

    func displays() async throws -> [ControlDisplay] {
        [ControlDisplay(
            uuid: "fixture-built-in", name: "Fixture Display", isMain: true, isBuiltin: true,
            brightness: capability, brightnessPercent: brightness
        )]
    }

    func readBrightness(displayUUID: String) async throws -> Double? { brightness }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        brightness = percent
        return percent
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
