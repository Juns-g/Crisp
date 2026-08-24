import XCTest
@testable import CrispControlCore

final class ProtocolTests: XCTestCase {
    func testSuccessEnvelopeRoundTripsWithoutError() throws {
        let response = ControlResponse.success(
            requestID: "req-1",
            result: .object(["version": .string("1.5.0")])
        )
        let data = try ControlJSON.encoder.encode(response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["protocolVersion"] as? Int, 1)
        XCTAssertEqual(object["requestID"] as? String, "req-1")
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertNotNil(object["result"])
        XCTAssertNil(object["error"])
        XCTAssertEqual(try ControlJSON.decoder.decode(ControlResponse.self, from: data), response)
    }

    func testFailureEnvelopePreservesRequestIDAndStructuredDetails() throws {
        let response = ControlResponse.failure(
            requestID: "req-2",
            code: .ambiguousSelector,
            message: "selector matches multiple displays",
            details: .object(["candidates": .array([.string("uuid-a"), .string("uuid-b")])])
        )
        let data = try ControlJSON.encoder.encode(response)
        let decoded = try ControlJSON.decoder.decode(ControlResponse.self, from: data)

        XCTAssertFalse(decoded.ok)
        XCTAssertNil(decoded.result)
        XCTAssertEqual(decoded.error?.code, .ambiguousSelector)
        XCTAssertEqual(decoded.error?.details?["candidates"], .array([.string("uuid-a"), .string("uuid-b")]))
        XCTAssertEqual(decoded.requestID, "req-2")
    }

    func testCapabilityCarriesOperationLevelTruth() throws {
        let capability = BrightnessCapability(
            state: .writable,
            backend: .displayServices,
            range: ControlRange(min: 0, max: 100, precision: 0.1),
            readback: .authoritative,
            reason: nil,
            remediation: nil
        )

        XCTAssertEqual(capability.state, .writable)
        XCTAssertEqual(capability.backend, .displayServices)
        XCTAssertEqual(capability.range.max, 100)
        XCTAssertEqual(capability.readback, .authoritative)
    }

    func testEveryErrorHasAStableExitCode() {
        XCTAssertEqual(ControlErrorCode.appNotRunning.exitCode, 3)
        XCTAssertEqual(ControlErrorCode.invalidArguments.exitCode, 2)
        XCTAssertEqual(ControlErrorCode.unsupportedCapability.exitCode, 4)
        XCTAssertEqual(ControlErrorCode.writeVerificationFailed.exitCode, 5)
        XCTAssertEqual(ControlErrorCode.writeOutcomeIndeterminate.exitCode, 5)
        XCTAssertEqual(ControlErrorCode.internalError.exitCode, 1)
    }
}
