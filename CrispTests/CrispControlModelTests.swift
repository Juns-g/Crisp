import XCTest

#if canImport(CrispPureModels)
@testable import CrispPureModels
#endif

final class CrispControlModelTests: XCTestCase {
    func testListReturnsEveryDisplay() {
        let displays = [
            CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false),
            CrispControlDisplay(id: 1, name: "Built-in Display", brightness: 42, isBuiltin: true)
        ]

        let result = CrispControlModel.handle(
            CrispControlRequest(command: .list),
            displays: displays
        )

        XCTAssertEqual(result.response, .success(displays: displays))
        XCTAssertNil(result.brightnessChange)
    }

    func testGetBrightnessReturnsOnlyRequestedDisplay() {
        let requested = CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false)
        let displays = [
            requested,
            CrispControlDisplay(id: 1, name: "Built-in Display", brightness: 42, isBuiltin: true)
        ]

        let result = CrispControlModel.handle(
            CrispControlRequest(command: .getBrightness, display: 7),
            displays: displays
        )

        XCTAssertEqual(result.response, .success(display: requested))
        XCTAssertNil(result.brightnessChange)
    }

    func testSetBrightnessReturnsAcceptedQueuedUnverifiedResponse() throws {
        let display = CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false)

        let result = CrispControlModel.handle(
            CrispControlRequest(command: .setBrightness, display: 7, brightness: 35),
            displays: [display]
        )

        XCTAssertEqual(result.response, .acceptedUnverified())
        XCTAssertEqual(
            result.brightnessChange,
            CrispControlBrightnessChange(displayID: 7, brightness: 35)
        )

        let data = CrispControlModel.encode(result.response)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["ok"] as? Bool, true)
        XCTAssertEqual(object["status"] as? String, "accepted")
        XCTAssertEqual(object["execution"] as? String, "queued")
        XCTAssertEqual(object["verification"] as? String, "unverified")
        XCTAssertNil(object["display"])
    }

    func testSetBrightnessRejectsExtraBrightness() {
        let display = CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false)

        let result = CrispControlModel.handle(
            CrispControlRequest(command: .setBrightness, display: 7, brightness: 101),
            displays: [display]
        )

        XCTAssertEqual(result.response, .failure("brightness must be between 0 and 100"))
        XCTAssertNil(result.brightnessChange)
    }

    func testSetBrightnessRejectsMissingFields() {
        let display = CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false)
        let requests = [
            CrispControlRequest(command: .setBrightness, brightness: 35),
            CrispControlRequest(command: .setBrightness, display: 7)
        ]

        for request in requests {
            let result = CrispControlModel.handle(request, displays: [display])

            XCTAssertEqual(result.response, .failure("display and brightness are required"))
            XCTAssertNil(result.brightnessChange)
        }
    }

    func testSetBrightnessAcceptsZeroAndHundredBoundaries() {
        let display = CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false)

        for brightness in [0.0, 100.0] {
            let result = CrispControlModel.handle(
                CrispControlRequest(command: .setBrightness, display: 7, brightness: brightness),
                displays: [display]
            )

            XCTAssertEqual(result.response, .acceptedUnverified())
            XCTAssertEqual(
                result.brightnessChange,
                CrispControlBrightnessChange(displayID: 7, brightness: brightness)
            )
        }
    }

    func testMalformedJSONIsInvalidRequest() {
        let result = CrispControlModel.handle(Data(#"{"command":"list""#.utf8), displays: [])

        XCTAssertEqual(result.response, .failure("invalid request"))
        XCTAssertNil(result.brightnessChange)
    }

    func testUnknownCommandIsInvalidRequest() {
        let request = Data(#"{"command":"setAllBrightness","brightness":50}"#.utf8)

        let result = CrispControlModel.handle(request, displays: [])

        XCTAssertEqual(result.response, .failure("invalid request"))
        XCTAssertNil(result.brightnessChange)
    }

    func testRequestFrameRejectsEOFBeforeNewline() {
        let data = Data(#"{"command":"list"}"#.utf8)

        XCTAssertEqual(
            CrispControlRequestFrame.parse(data, maximumBytes: 8_192, endOfStream: true),
            .failure("request must end with newline")
        )
    }

    func testClientLimiterRejectsExcessUntilSlotReleased() {
        let limiter = CrispControlClientLimiter(limit: 2)
        defer {
            limiter.release()
            limiter.release()
        }

        XCTAssertTrue(limiter.acquire())
        XCTAssertTrue(limiter.acquire())
        XCTAssertFalse(limiter.acquire())

        limiter.release()
        XCTAssertTrue(limiter.acquire())
    }

    func testResponseFrameIsUnversionedAndNewlineTerminated() throws {
        let display = CrispControlDisplay(id: 7, name: "Studio Display", brightness: 64, isBuiltin: false)

        let data = CrispControlModel.encode(.success(display: display))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(data.last, Character("\n").asciiValue)
        XCTAssertEqual(Set(object.keys), ["ok", "display"])
        XCTAssertEqual(object["ok"] as? Bool, true)
    }
}
