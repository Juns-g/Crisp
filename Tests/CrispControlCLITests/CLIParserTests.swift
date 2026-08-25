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
        XCTAssertEqual(try parse(["extra-brightness", "get", "uuid-a", "--json"]).request.command,
                       "extra-brightness.get")
        XCTAssertEqual(try parse(["extra-brightness", "set", "uuid-a", "on", "--json"]).request.command,
                       "extra-brightness.set")
        XCTAssertEqual(try parse(["hdr", "get", "uuid-a", "--json"]).request.command, "hdr.get")
        XCTAssertEqual(try parse(["hdr", "set", "uuid-a", "off", "--json"]).request.command, "hdr.set")
        XCTAssertEqual(try parse(["brightness", "get-all", "--json"]).request.command, "brightness.get-all")
        XCTAssertEqual(try parse(["brightness", "set-all", "125", "--json"]).request.command,
                       "brightness.set-all")
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
        XCTAssertThrowsError(try parse(["extra-brightness", "set", "main", "yes", "--json"]))
        XCTAssertThrowsError(try parse(["extra-brightness", "set", "main", "--json"]))
        XCTAssertThrowsError(try parse(["hdr", "set", "main", "1", "--json"]))
        XCTAssertThrowsError(try parse(["brightness", "set-all", "NaN", "--json"]))
        XCTAssertThrowsError(try parse(["brightness", "get-all", "main", "--json"]))
    }

    func testToggleArgumentsAndHelpAreExplicit() throws {
        let boost = try parse(["extra-brightness", "set", "uuid-a", "on", "--no-start", "--json"])
        let hdr = try parse(["hdr", "set", "uuid-b", "off", "--json"])

        XCTAssertEqual(boost.request.arguments["selector"], .string("uuid-a"))
        XCTAssertEqual(boost.request.arguments["enabled"], .bool(true))
        XCTAssertTrue(boost.noStart)
        XCTAssertEqual(hdr.request.arguments["selector"], .string("uuid-b"))
        XCTAssertEqual(hdr.request.arguments["enabled"], .bool(false))
        for usage in [
            "extra-brightness get <selector>", "extra-brightness set <selector> on|off",
            "hdr get <selector>", "hdr set <selector> on|off",
            "brightness get-all", "brightness set-all <percent>"
        ] {
            XCTAssertTrue(crispctlHelp.contains(usage), "missing help: \(usage)")
        }
    }

    func testParserDispatcherAndMutationClassifierInventoriesStaySynchronized() throws {
        let forms = [
            ["version"], ["status"], ["displays", "list"],
            ["displays", "get", "uuid-a"], ["displays", "capabilities", "uuid-a"],
            ["brightness", "get", "uuid-a"], ["brightness", "set", "uuid-a", "50"],
            ["brightness", "get-all"], ["brightness", "set-all", "50"],
            ["extra-brightness", "get", "uuid-a"], ["extra-brightness", "set", "uuid-a", "on"],
            ["hdr", "get", "uuid-a"], ["hdr", "set", "uuid-a", "off"]
        ]
        let requests = try forms.map(parse)
        let parserCommands = Set(requests.map(\.request.command))
        let parserMutations = Set(requests.compactMap { request in
            request.request.mutationKind == nil ? nil : request.request.command
        })

        XCTAssertEqual(parserCommands, ControlCommandInventory.dispatcherCommands)
        XCTAssertEqual(parserMutations, ControlCommandInventory.mutatingCommands)
    }

    private func parse(_ arguments: [String]) throws -> CLIInvocation {
        try CLIParser(requestID: { "fixed-request-id" }).parse(arguments)
    }
}
