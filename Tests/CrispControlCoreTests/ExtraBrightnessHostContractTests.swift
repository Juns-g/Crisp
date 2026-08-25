import Foundation
import XCTest
@testable import CrispControlCore

final class ExtraBrightnessHostContractTests: XCTestCase {
    func testSettlingDisableSerializesNonfailureEnvelope() async throws {
        let service = HostMappedExtraBrightnessControlService(outcome: .settling)
        let response = await dispatch(using: service)
        let envelope = try encodedObject(response)
        let result = try XCTUnwrap(envelope["result"] as? [String: Any])

        XCTAssertEqual(envelope["ok"] as? Bool, true)
        XCTAssertEqual(result["verification"] as? String, "settling")
        XCTAssertEqual(result["persistedEnabled"] as? Bool, false)
        XCTAssertEqual(result["enabled"] as? Bool, true)
        XCTAssertEqual(result["maxBrightness"] as? Double, 150)
        XCTAssertFalse(try XCTUnwrap(result["warnings"] as? [String]).isEmpty)
        let mutationCount = await service.mutationCount
        XCTAssertEqual(mutationCount, 1)
    }

    func testIndeterminateDisableSerializesFailClosedEnvelope() async throws {
        let service = HostMappedExtraBrightnessControlService(outcome: .indeterminate)
        let response = await dispatch(using: service)
        let envelope = try encodedObject(response)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        let details = try XCTUnwrap(error["details"] as? [String: Any])

        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "write_outcome_indeterminate")
        XCTAssertEqual(details["retrySafe"] as? Bool, false)
        XCTAssertEqual(response.error?.code.exitCode, 5)
        let mutationCount = await service.mutationCount
        XCTAssertEqual(mutationCount, 1)
    }

    func testNonOwnedStaleLiveDisableSerializesIndeterminateEnvelope() async throws {
        let outcome = ExtraBrightnessControlMutationOutcome.classify(
            mutationAccepted: true,
            operationCompleted: false,
            identityMatches: true,
            persistedEnabled: false,
            liveEnabled: true,
            maxBrightness: 150,
            cleanupInProgress: false
        )
        let service = HostMappedExtraBrightnessControlService(outcome: outcome)
        let response = await dispatch(using: service)
        let envelope = try encodedObject(response)
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        let details = try XCTUnwrap(error["details"] as? [String: Any])

        XCTAssertEqual(envelope["ok"] as? Bool, false)
        XCTAssertEqual(error["code"] as? String, "write_outcome_indeterminate")
        XCTAssertEqual(details["retrySafe"] as? Bool, false)
        XCTAssertEqual(response.error?.code.exitCode, 5)
        let mutationCount = await service.mutationCount
        XCTAssertEqual(mutationCount, 1)
    }

    private func dispatch(
        using service: HostMappedExtraBrightnessControlService
    ) async -> ControlResponse {
        await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(
                requestID: "req-host-mapping",
                command: "extra-brightness.set",
                arguments: [
                    "selector": .string("uuid-settling-boost"),
                    "enabled": .bool(false)
                ]
            )
        )
    }

    private func encodedObject(_ response: ControlResponse) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        )
    }
}

private actor HostMappedExtraBrightnessControlService: ControlCommandService {
    let outcome: ExtraBrightnessControlMutationOutcome
    private(set) var mutationCount = 0

    init(outcome: ExtraBrightnessControlMutationOutcome) {
        self.outcome = outcome
    }

    func displays() async throws -> [ControlDisplay] { [.settlingExtraBrightness] }
    func readBrightness(displayUUID: String) async throws -> Double? { 120 }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double { percent }

    func setExtraBrightness(
        displayUUID: String,
        enabled: Bool
    ) async throws -> ExtraBrightnessSetResult {
        mutationCount += 1
        guard let result = try outcome.resolvedControlResult(
            capability: ControlDisplay.settlingExtraBrightness.extraBrightness
        ) else {
            throw ControlServiceError.writeFailed("test fixture expected a resolved outcome")
        }
        return result
    }
}

private extension ControlDisplay {
    static let settlingExtraBrightness = ControlDisplay(
        uuid: "uuid-settling-boost",
        name: "Settling Boost",
        isMain: true,
        isBuiltin: true,
        brightness: BrightnessCapability(
            state: .writable,
            backend: .displayServices,
            range: ControlRange(min: 0, max: 150, precision: 0.1),
            readback: .authoritative,
            hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
            logicalRange: ControlRange(min: 0, max: 150, precision: 0.1)
        ),
        brightnessPercent: 120,
        extraBrightness: ExtraBrightnessCapability(
            state: .writable,
            enabled: true,
            persistedEnabled: false,
            maxBrightness: 150
        )
    )
}
