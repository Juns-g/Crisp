import XCTest
@testable import CrispControlCore

final class CommandDispatcherTests: XCTestCase {
    func testReadOnlyCommandsReturnDeterministicDisplayData() async throws {
        let service = MockControlService(displays: [.builtin])
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: "1.5.0")

        let version = await dispatcher.handle(ControlRequest(requestID: "v", command: "version"))
        let status = await dispatcher.handle(ControlRequest(requestID: "s", command: "status"))
        let list = await dispatcher.handle(ControlRequest(requestID: "l", command: "displays.list"))
        let get = await dispatcher.handle(request("displays.get", selector: "main"))
        let capabilities = await dispatcher.handle(request("displays.capabilities", selector: "builtin"))
        let brightness = await dispatcher.handle(request("brightness.get", selector: "uuid-built-in"))

        XCTAssertEqual(version.result?["appVersion"], .string("1.5.0"))
        XCTAssertEqual(status.result?["running"], .bool(true))
        XCTAssertEqual(list.result?["displays"]?[0]?["uuid"], .string("uuid-built-in"))
        XCTAssertEqual(get.result?["display"]?["name"], .string("Built-in Display"))
        XCTAssertEqual(capabilities.result?["brightness"]?["backend"], .string("DisplayServices"))
        XCTAssertEqual(brightness.result?["percent"], .number(42))
    }

    func testBrightnessSetWritesThenReadsBackBeforeSuccess() async throws {
        let service = MockControlService(displays: [.builtin], readValues: [42, 50.04])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 50)
        )

        XCTAssertTrue(response.ok)
        let writes = await service.writes
        XCTAssertEqual(writes, [50])
        XCTAssertEqual(response.result?["requestedPercent"], .number(50))
        XCTAssertEqual(response.result?["appliedPercent"], .number(50))
        XCTAssertEqual(response.result?["readbackPercent"], .number(50.04))
        XCTAssertEqual(response.result?["verification"], .string("verified"))
        XCTAssertEqual(response.result?["backend"], .string("DisplayServices"))
    }

    func testBrightnessSetRejectsOutOfCapabilityRangeWithoutWriting() async throws {
        let service = MockControlService(displays: [.builtin])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 101)
        )

        XCTAssertEqual(response.error?.code, .invalidArguments)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testUnsupportedBrightnessIsAnError() async throws {
        let service = MockControlService(displays: [.unsupportedExternal])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.get", selector: "uuid-external")
        )

        XCTAssertEqual(response.error?.code, .unsupportedCapability)
        XCTAssertEqual(response.error?.details?["reason"], .string("No controllable backend"))
    }

    func testReadOnlyCapabilityRejectsSetWithoutWriting() async throws {
        let service = MockControlService(displays: [.readOnlyExternal])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "uuid-read-only", percent: 30)
        )

        XCTAssertEqual(response.error?.code, .unsupportedCapability)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testAmbiguousSelectorReturnsCandidates() async throws {
        let service = MockControlService(displays: [.deskA, .deskB])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("displays.get", selector: "Desk")
        )

        XCTAssertEqual(response.error?.code, .ambiguousSelector)
        XCTAssertEqual(response.error?.details?["candidates"]?[0]?["uuid"], .string("uuid-a"))
        XCTAssertEqual(response.error?.details?["candidates"]?[1]?["uuid"], .string("uuid-b"))
    }

    func testWriteVerificationFailureNeverReturnsSuccess() async throws {
        let service = MockControlService(displays: [.builtin], readValues: [42, 43])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 50)
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .writeVerificationFailed)
        XCTAssertEqual(response.error?.details?["requestedPercent"], .number(50))
        XCTAssertEqual(response.error?.details?["readbackPercent"], .number(43))
    }

    func testUnavailableReadbackIsReportedWithoutFalsePrecision() async throws {
        let service = MockControlService(displays: [.softwareExternal], readValues: [nil])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "uuid-software", percent: 30)
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["verification"], .string("unavailable"))
        XCTAssertEqual(response.result?["readbackPercent"], .null)
        XCTAssertNotNil(response.result?["warnings"])
    }

    private func request(_ command: String, selector: String, percent: Double? = nil) -> ControlRequest {
        var arguments: [String: JSONValue] = ["selector": .string(selector)]
        if let percent { arguments["percent"] = .number(percent) }
        return ControlRequest(requestID: "req", command: command, arguments: arguments)
    }
}

private actor MockControlService: ControlCommandService {
    let inventory: [ControlDisplay]
    var queuedReads: [Double?]
    var writes: [Double] = []

    init(displays: [ControlDisplay], readValues: [Double?] = [42]) {
        inventory = displays
        queuedReads = readValues
    }

    func displays() async throws -> [ControlDisplay] { inventory }

    func readBrightness(displayUUID: String) async throws -> Double? {
        queuedReads.isEmpty ? inventory.first(where: { $0.uuid == displayUUID })?.brightnessPercent
            : queuedReads.removeFirst()
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(percent)
        return percent
    }
}

private extension ControlDisplay {
    static let builtin = ControlDisplay(
        uuid: "uuid-built-in", name: "Built-in Display", isMain: true, isBuiltin: true,
        brightness: BrightnessCapability(
            state: .writable, backend: .displayServices,
            range: ControlRange(min: 0, max: 100, precision: 0.1), readback: .authoritative
        ), brightnessPercent: 42
    )
    static let unsupportedExternal = ControlDisplay(
        uuid: "uuid-external", name: "External", isMain: false, isBuiltin: false,
        brightness: .unsupported(reason: "No controllable backend")
    )
    static let softwareExternal = ControlDisplay(
        uuid: "uuid-software", name: "Software", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .software,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .unavailable
        ), brightnessPercent: 42
    )
    static let readOnlyExternal = ControlDisplay(
        uuid: "uuid-read-only", name: "Read only", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .readable, backend: .ddc,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
        ), brightnessPercent: 42
    )
    static let deskA = ControlDisplay(
        uuid: "uuid-a", name: "Desk", isMain: false, isBuiltin: false,
        brightness: .unsupported(reason: "none")
    )
    static let deskB = ControlDisplay(
        uuid: "uuid-b", name: "Desk", isMain: false, isBuiltin: false,
        brightness: .unsupported(reason: "none")
    )
}
