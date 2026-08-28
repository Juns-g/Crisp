import XCTest

final class CrispControlModelTests: XCTestCase {
    private let display = CrispControlDisplay(
        id: 7,
        name: "Studio Display",
        brightness: 64,
        isBuiltin: false
    )

    func testParserSupportsExactlyThreeCommands() {
        let cases: [([String], CrispControlRequest)] = [
            (["displays", "list"], .init(command: .list)),
            (["brightness", "get", "42"], .init(command: .getBrightness, display: 42)),
            (
                ["brightness", "set", "42", "37.5"],
                .init(command: .setBrightness, display: 42, brightness: 37.5)
            )
        ]
        for (arguments, request) in cases {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .request(request))
        }
    }

    func testParserReturnsHelpForNoArgumentsAndHelpFlags() {
        for arguments in [[], ["help"], ["--help"], ["-h"]] {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .help, "\(arguments)")
        }
        // The reference must name every command it documents, and the usage line must
        // point at it, so a wrong invocation still leads to the full text.
        for command in ["displays list", "brightness get", "brightness set", "crispctl help"] {
            XCTAssertTrue(CrispControlCLIModel.help.contains(command), command)
        }
        XCTAssertTrue(CrispControlCLIModel.usage.contains("crispctl help"))
    }

    func testParserRejectsInvalidArityIDsOptionsAndPercent() {
        let cases = [
            ["help", "me"], ["displays"], ["displays", "list", "--json"],
            ["brightness", "get"], ["brightness", "get", "x"],
            ["brightness", "get", "4294967296"], ["brightness", "set", "42"],
            ["brightness", "set", "42", "nan"], ["brightness", "set", "42", "inf"],
            ["brightness", "set", "42", "-0.1"], ["brightness", "set", "42", "100.1"]
        ]
        for arguments in cases {
            XCTAssertEqual(CrispControlCLIModel.parse(arguments: arguments), .failure)
        }
        for value in ["0", "100"] {
            guard case let .request(request) = CrispControlCLIModel.parse(
                arguments: ["brightness", "set", "42", value]
            ) else { return XCTFail("expected boundary \(value)") }
            XCTAssertEqual(request.brightness, Double(value))
        }
    }

    func testSharedFrameReturnsOneBoundedLFFrame() {
        let frame = Data(#"{"command":"list"}"#.utf8) + Data([0x0A])
        XCTAssertEqual(
            CrispControlFrame.parse(frame + Data("ignored".utf8), maximumBytes: 64, endOfStream: false),
            .frame(frame)
        )
        XCTAssertEqual(
            CrispControlFrame.parse(Data(frame.dropLast()), maximumBytes: 64, endOfStream: false),
            .incomplete
        )
        XCTAssertEqual(
            CrispControlFrame.parse(Data(frame.dropLast()), maximumBytes: 64, endOfStream: true),
            .failure("frame must end with newline")
        )
        XCTAssertEqual(
            CrispControlFrame.parse(Data(repeating: 0x20, count: 4), maximumBytes: 4, endOfStream: false),
            .failure("frame too large")
        )
    }

    func testModelHandlesListAndGet() throws {
        let list = CrispControlModel.handle(Data(#"{"command":"list"}"#.utf8), displays: [display])
        XCTAssertEqual(list.response, .success(displays: [display]))
        XCTAssertNil(list.brightnessChange)

        let get = CrispControlModel.handle(
            Data(#"{"command":"getBrightness","display":7}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(get.response, .success(display: display))
        XCTAssertNil(get.brightnessChange)
    }

    func testSetEncodesOnlyOKAndCreatesRequestedBrightnessChange() {
        let result = CrispControlModel.handle(
            Data(#"{"command":"setBrightness","display":7,"brightness":35}"#.utf8),
            displays: [display]
        )
        XCTAssertEqual(result.response, .success())
        XCTAssertEqual(result.brightnessChange, .init(displayID: 7, brightness: 35))
        XCTAssertEqual(
            CrispControlModel.encode(result.response),
            Data(#"{"ok":true}"#.utf8) + Data([0x0A])
        )
    }

    func testModelRejectsMalformedMissingUnknownAndOutOfRangeRequests() {
        let requests = [
            #"{"command":"list""#,
            #"{"command":"getBrightness"}"#,
            #"{"command":"getBrightness","display":8}"#,
            #"{"command":"setBrightness","display":7}"#,
            #"{"command":"setBrightness","display":7,"brightness":101}"#,
            #"{"command":"unknown"}"#
        ]
        for request in requests {
            let result = CrispControlModel.handle(Data(request.utf8), displays: [display])
            XCTAssertFalse(result.response.ok, request)
            XCTAssertNil(result.brightnessChange, request)
        }
    }

    func testBareSuccessIsAcceptedForEveryCommand() {
        for command in commands {
            XCTAssertEqual(classify(#"{"ok":true}"#, command), .success)
        }
    }

    func testSuccessfulResponseWithUnknownFutureFieldIsAcceptedForEveryCommand() {
        let response = #"{"ok":true,"future":{"state":"applied"}}"#
        for command in commands {
            XCTAssertEqual(classify(response, command), .success)
        }
    }

    func testFailedMalformedAndInsufficientResponseClassification() {
        for command in commands {
            XCTAssertEqual(classify(#"{"ok":false,"error":"display not found"}"#, command), .serverFailure)
            XCTAssertEqual(
                classify(#"{"ok":false,"error":"display not found","future":true}"#, command),
                .serverFailure
            )
            XCTAssertEqual(classify(#"{"ok":false}"#, command), .invalid)
            XCTAssertEqual(classify(#"{}"#, command), .invalid)
            XCTAssertEqual(classify(#"{"ok":true"#, command), .invalid)
        }
    }

    private var commands: [CrispControlRequest.Command] {
        [.list, .getBrightness, .setBrightness]
    }

    private func classify(
        _ json: String,
        _ command: CrispControlRequest.Command
    ) -> CrispControlCLIModel.ResponseResult {
        CrispControlCLIModel.classify(Data(json.utf8), for: command)
    }
}
