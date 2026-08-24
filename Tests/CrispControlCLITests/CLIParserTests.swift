import XCTest
@testable import CrispControlCLI
import CrispControlCore

final class CLIParserTests: XCTestCase {
    func testRequiredCommandsMapToProtocolCommands() throws {
        XCTAssertEqual(try parse(["version", "--json"]).request.command, "version")
        XCTAssertEqual(try parse(["status", "--json", "--no-start"]).request.command, "status")
        XCTAssertEqual(try parse(["displays", "list", "--json"]).request.command, "displays.list")
        XCTAssertEqual(try parse(["displays", "get", "main", "--json"]).request.command, "displays.get")
        XCTAssertEqual(
            try parse(["displays", "capabilities", "builtin", "--json"]).request.command,
            "displays.capabilities"
        )
        XCTAssertEqual(try parse(["brightness", "get", "uuid-a", "--json"]).request.command, "brightness.get")
        XCTAssertEqual(try parse(["brightness", "set", "uuid-a", "57.5", "--json"]).request.command, "brightness.set")
    }

    func testSelectorsPercentAndGlobalOptionsArePreserved() throws {
        let invocation = try parse([
            "brightness", "set", "main", "57.5", "--no-start", "--socket", "/tmp/test.sock", "--json"
        ])

        XCTAssertEqual(invocation.request.requestID, "fixed-request-id")
        XCTAssertEqual(invocation.request.arguments["selector"], .string("main"))
        XCTAssertEqual(invocation.request.arguments["percent"], .number(57.5))
        XCTAssertTrue(invocation.noStart)
        XCTAssertEqual(invocation.socketPath, "/tmp/test.sock")
    }

    func testMalformedCommandsFailBeforeTransport() {
        XCTAssertThrowsError(try parse(["brightness", "set", "main", "NaN", "--json"]))
        XCTAssertThrowsError(try parse(["displays", "get", "--json"]))
        XCTAssertThrowsError(try parse(["brightness", "delete", "main", "--json"]))
        XCTAssertThrowsError(try parse(["status", "--unknown"]))
    }

    private func parse(_ arguments: [String]) throws -> CLIInvocation {
        try CLIParser(requestID: { "fixed-request-id" }).parse(arguments)
    }
}
