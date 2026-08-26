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

    func testP0CapabilitiesRoundTripDynamicRangeAndDistinctToggleTruth() throws {
        let display = ControlDisplay(
            uuid: "xdr", name: "Built-in XDR", isMain: true, isBuiltin: true,
            brightness: BrightnessCapability(
                state: .writable, backend: .displayServices,
                range: ControlRange(min: 0, max: 162.5, precision: 0.1), readback: .authoritative,
                hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
                logicalRange: ControlRange(min: 0, max: 162.5, precision: 0.1)
            ),
            brightnessPercent: 120,
            extraBrightness: ExtraBrightnessCapability(
                state: .writable, enabled: true, persistedEnabled: true, maxBrightness: 162.5,
                headroom: EDRHeadroomSnapshot(
                    potential: 1.8, current: 1.62,
                    appliedFactor: 1.4, factorVerification: "app_state"
                )
            ),
            hdr: HDRCapability.unsupported(
                enabled: nil,
                reason: "built-in displays do not expose an HDR preference toggle",
                remediation: "use Extra Brightness when eligible"
            )
        )

        let data = try ControlJSON.encoder.encode(display)
        let decoded = try ControlJSON.decoder.decode(ControlDisplay.self, from: data)

        XCTAssertEqual(decoded.brightness.hardwareRange.max, 100)
        XCTAssertEqual(decoded.brightness.logicalRange.max, 162.5)
        XCTAssertEqual(decoded.extraBrightness.state, .writable)
        XCTAssertEqual(decoded.extraBrightness.enabled, true)
        XCTAssertEqual(decoded.extraBrightness.persistedEnabled, true)
        XCTAssertEqual(decoded.extraBrightness.maxBrightness, 162.5)
        XCTAssertEqual(decoded.extraBrightness.headroom?.potential, 1.8)
        XCTAssertEqual(decoded.extraBrightness.headroom?.current, 1.62)
        XCTAssertEqual(decoded.extraBrightness.headroom?.appliedFactor, 1.4)
        XCTAssertEqual(decoded.extraBrightness.headroom?.factorVerification, "app_state")
        XCTAssertEqual(decoded.hdr.state, .unsupported)
        XCTAssertTrue(decoded.hdr.remediation?.contains("Extra Brightness") == true)
    }

    func testIneligibleCapabilitiesCarryReasonsWithoutPretendingHDRMeansBoostReady() throws {
        let boost = ExtraBrightnessCapability.unsupported(
            enabled: true,
            persistedEnabled: false,
            maxBrightness: 100,
            headroom: EDRHeadroomSnapshot(potential: 1, current: 1),
            reason: "no usable EDR headroom and no writable external HDR toggle",
            remediation: "enable HDR in the display or macOS settings if available"
        )
        let hdr = HDRCapability(
            state: .readable, enabled: true,
            reason: "HDR is live but Crisp does not expose a writable toggle for this display"
        )

        XCTAssertEqual(boost.state, .unsupported)
        XCTAssertEqual(boost.enabled, true)
        XCTAssertEqual(boost.maxBrightness, 100)
        XCTAssertEqual(hdr.state, .readable)
        XCTAssertEqual(hdr.enabled, true)
    }

    func testDisplayConnectionCapabilityCarriesFailClosedPlatformAndActionTruth() throws {
        let capability = DisplayConnectionCapability(
            state: .writable,
            connected: true,
            disconnectAllowed: true,
            reconnectAllowed: false,
            platformSupported: true,
            reason: "another physical display remains viewable",
            remediation: nil
        )

        let data = try ControlJSON.encoder.encode(capability)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["state"] as? String, "writable")
        XCTAssertEqual(object["connected"] as? Bool, true)
        XCTAssertEqual(object["disconnectAllowed"] as? Bool, true)
        XCTAssertEqual(object["reconnectAllowed"] as? Bool, false)
        XCTAssertEqual(object["platformSupported"] as? Bool, true)
        XCTAssertEqual(
            try ControlJSON.decoder.decode(DisplayConnectionCapability.self, from: data),
            capability
        )
    }

    func testEveryErrorHasAStableExitCode() {
        XCTAssertEqual(ControlErrorCode.appNotRunning.exitCode, 3)
        XCTAssertEqual(ControlErrorCode.invalidArguments.exitCode, 2)
        XCTAssertEqual(ControlErrorCode.unsupportedCapability.exitCode, 4)
        XCTAssertEqual(ControlErrorCode.writeVerificationFailed.exitCode, 5)
        XCTAssertEqual(ControlErrorCode.writeOutcomeIndeterminate.exitCode, 5)
        XCTAssertEqual(ControlErrorCode.batchPartialFailure.exitCode, 5)
        XCTAssertEqual(ControlErrorCode.batchPreflightFailed.exitCode, 4)
        XCTAssertEqual(ControlErrorCode.emptyPhysicalInventory.exitCode, 4)
        XCTAssertEqual(ControlErrorCode.internalError.exitCode, 1)
    }

    func testUnknownFutureSetCommandDefaultsToIndeterminateMutationSafety() {
        let request = ControlRequest(
            requestID: "future", command: "future-display.set",
            arguments: ["selector": .string("uuid-a")]
        )

        XCTAssertEqual(request.mutationKind, .unknown)
        let response = ControlResponse.timeout(for: request)
        XCTAssertEqual(response.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(response.error?.details?["command"], .string("future-display.set"))
    }

    func testBrightnessBatchRestoreOverrideIsAnAdditiveV1RequestOption() throws {
        let strict = ControlRequest(
            requestID: "strict",
            command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        )
        let override = ControlRequest(
            requestID: "override",
            command: "brightness.set-all",
            arguments: ["percent": .number(50), "allowUnrestorable": .bool(true)]
        )
        let invalid = ControlRequest(
            requestID: "invalid",
            command: "brightness.set-all",
            arguments: ["percent": .number(50), "allowUnrestorable": .string("true")]
        )

        XCTAssertEqual(strict.brightnessBatchRestoreMode, .strict)
        XCTAssertEqual(override.brightnessBatchRestoreMode, .allowUnrestorable)
        XCTAssertNil(invalid.brightnessBatchRestoreMode)
        let data = try ControlJSON.encoder.encode(override)
        let decoded = try ControlJSON.decoder.decode(ControlRequest.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, 1)
        XCTAssertEqual(decoded.brightnessBatchRestoreMode, .allowUnrestorable)
        XCTAssertEqual(crispControlProtocolVersion, 1)
    }

    func testDisplayConnectionTimeoutsCarryExactUUIDCommandStateAndNoRetryTruth() {
        let uuid = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
        let cases: [(String, [String: JSONValue], String)] = [
            ("displays.disconnect", ["uuid": .string(uuid)], "disconnected"),
            ("displays.reconnect", ["uuid": .string(uuid)], "connected")
        ]

        for (command, arguments, requestedState) in cases {
            let response = ControlResponse.timeout(for: ControlRequest(
                requestID: command,
                command: command,
                arguments: arguments
            ))

            XCTAssertEqual(response.error?.code, .writeOutcomeIndeterminate, command)
            XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false), command)
            XCTAssertEqual(response.error?.details?["command"], .string(command), command)
            XCTAssertEqual(response.error?.details?["displayUUID"], .string(uuid), command)
            XCTAssertNil(response.error?.details?["selector"], command)
            XCTAssertEqual(
                response.error?.details?["requestedConnectionState"],
                .string(requestedState),
                command
            )
            XCTAssertEqual(response.error?.code.exitCode, 5, command)
        }
    }

    func testOldV1DisplayResponseDecodesWithAdditiveDefaults() throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/old-v1-display.json")
        let oldV1 = try Data(contentsOf: fixture)

        let decoded = try ControlJSON.decoder.decode(ControlDisplay.self, from: oldV1)

        XCTAssertEqual(decoded.uuid, "old-uuid")
        XCTAssertEqual(decoded.brightnessPercent, 42)
        XCTAssertEqual(decoded.brightness.range.max, 100)
        XCTAssertEqual(decoded.brightness.hardwareRange.max, 100)
        XCTAssertEqual(decoded.brightness.logicalRange.max, 100)
        XCTAssertFalse(decoded.isVirtual)
        XCTAssertEqual(decoded.extraBrightness.state, .unsupported)
        XCTAssertEqual(decoded.hdr.state, .unsupported)
        XCTAssertEqual(decoded.connection.state, .unsupported)
        XCTAssertTrue(decoded.connection.connected)
        XCTAssertFalse(decoded.connection.disconnectAllowed)
        XCTAssertFalse(decoded.connection.reconnectAllowed)
        XCTAssertFalse(decoded.connection.platformSupported)
        XCTAssertEqual(crispControlProtocolVersion, 1)
    }
}
