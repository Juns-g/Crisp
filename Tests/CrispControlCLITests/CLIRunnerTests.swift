import XCTest
@testable import CrispControlCLI
import CrispControlCore

final class CLIRunnerTests: XCTestCase {
    func testNoStartReturnsAppNotRunningWithoutLaunching() {
        let transport = MockTransport([.failure(IPCError.unavailable)])
        let launcher = MockLauncher()
        let result = CLIRunner(transport: transport, launcher: launcher).run(invocation(noStart: true))

        XCTAssertEqual(result.response.error?.code, .appNotRunning)
        XCTAssertEqual(result.exitCode, ControlErrorCode.appNotRunning.exitCode)
        XCTAssertEqual(launcher.launchCount, 0)
    }

    func testDefaultPolicyLaunchesThenPollsUntilReady() {
        let success = ControlResponse.success(requestID: "req", result: .object(["running": .bool(true)]))
        let transport = MockTransport([.failure(IPCError.unavailable), .failure(IPCError.unavailable), .success(success)])
        let launcher = MockLauncher()
        let result = CLIRunner(
            transport: transport,
            launcher: launcher,
            readinessTimeout: 0.1,
            pollInterval: 0
        ).run(invocation())

        XCTAssertTrue(result.response.ok)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(launcher.launchCount, 1)
        XCTAssertEqual(transport.sendCount, 3)
    }

    func testLaunchFailureAndReadinessTimeoutAreStructured() {
        let failedLauncher = MockLauncher(error: LauncherError.notFound)
        let launchFailure = CLIRunner(
            transport: MockTransport([.failure(IPCError.unavailable)]), launcher: failedLauncher
        ).run(invocation())
        XCTAssertEqual(launchFailure.response.error?.code, .appLaunchFailed)

        let timeout = CLIRunner(
            transport: MockTransport(Array(repeating: .failure(IPCError.unavailable), count: 100)),
            launcher: MockLauncher(),
            readinessTimeout: 0,
            pollInterval: 0
        ).run(invocation())
        XCTAssertEqual(timeout.response.error?.code, .appReadinessTimeout)
    }

    func testServerErrorControlsProcessExitCode() {
        let response = ControlResponse.failure(
            requestID: "req", code: .ambiguousSelector, message: "ambiguous"
        )
        let result = CLIRunner(
            transport: MockTransport([.success(response)]), launcher: MockLauncher()
        ).run(invocation())

        XCTAssertEqual(result.exitCode, ControlErrorCode.ambiguousSelector.exitCode)
    }

    func testResponseIdentityFailuresAreStructuredProtocolErrors() {
        for error in [IPCError.responseProtocolMismatch, IPCError.responseRequestMismatch] {
            let result = CLIRunner(
                transport: MockTransport([.failure(error)]), launcher: MockLauncher()
            ).run(invocation())

            XCTAssertEqual(result.response.error?.code, .protocolMismatch)
            XCTAssertEqual(result.exitCode, ControlErrorCode.protocolMismatch.exitCode)
        }
    }

    func testBrightnessSetClientTimeoutIsIndeterminateAndNotRetrySafe() {
        let request = ControlRequest(
            requestID: "timed-out-write",
            command: "brightness.set",
            arguments: ["selector": .string("builtin"), "percent": .number(55)]
        )
        let invocation = CLIInvocation(request: request, noStart: true, socketPath: "/tmp/test.sock")

        let result = CLIRunner(
            transport: MockTransport([.failure(IPCError.timeout)]), launcher: MockLauncher()
        ).run(invocation)

        XCTAssertEqual(result.response.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(result.response.error?.details?["selector"], .string("builtin"))
        XCTAssertEqual(result.response.error?.details?["targetPercent"], .number(55))
        XCTAssertEqual(result.response.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(result.exitCode, ControlErrorCode.writeOutcomeIndeterminate.exitCode)
    }

    func testEveryP0MutationTimeoutIsIndeterminateWithTargetAndNoRetry() {
        let cases: [MutationTimeoutCase] = [
            MutationTimeoutCase(
                command: "displays.disconnect",
                arguments: [
                    "uuid": .string("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
                ],
                targetKey: "requestedConnectionState",
                targetValue: .string("disconnected")
            ),
            MutationTimeoutCase(
                command: "displays.reconnect",
                arguments: [
                    "uuid": .string("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")
                ],
                targetKey: "requestedConnectionState",
                targetValue: .string("connected")
            ),
            MutationTimeoutCase(
                command: "extra-brightness.set",
                arguments: ["selector": .string("uuid-a"), "enabled": .bool(true)],
                targetKey: "targetEnabled",
                targetValue: .bool(true)
            ),
            MutationTimeoutCase(
                command: "hdr.set",
                arguments: ["selector": .string("uuid-b"), "enabled": .bool(false)],
                targetKey: "targetEnabled",
                targetValue: .bool(false)
            ),
            MutationTimeoutCase(
                command: "brightness.set-all",
                arguments: ["percent": .number(125)],
                targetKey: "targetPercent",
                targetValue: .number(125)
            )
        ]

        for testCase in cases {
            let request = ControlRequest(
                requestID: testCase.command,
                command: testCase.command,
                arguments: testCase.arguments
            )
            let invocation = CLIInvocation(request: request, noStart: true, socketPath: "/tmp/test.sock")
            let result = CLIRunner(
                transport: MockTransport([.failure(IPCError.timeout)]), launcher: MockLauncher()
            ).run(invocation)

            XCTAssertEqual(result.response.error?.code, .writeOutcomeIndeterminate, testCase.command)
            XCTAssertEqual(result.response.error?.details?["retrySafe"], .bool(false), testCase.command)
            XCTAssertEqual(
                result.response.error?.details?[testCase.targetKey],
                testCase.targetValue,
                testCase.command
            )
            if testCase.command == "brightness.set-all" {
                XCTAssertEqual(result.response.error?.details?["target"], .string("all_physical_displays"))
            } else if testCase.command.hasPrefix("displays.") {
                XCTAssertNotNil(result.response.error?.details?["displayUUID"])
            } else {
                XCTAssertNotNil(result.response.error?.details?["selector"])
            }
            XCTAssertEqual(result.exitCode, 5)
        }
    }

    func testReadTimeoutRemainsOrdinaryTimeout() {
        let request = ControlRequest(requestID: "read-timeout", command: "brightness.get-all")
        let result = CLIRunner(
            transport: MockTransport([.failure(IPCError.timeout)]), launcher: MockLauncher()
        ).run(CLIInvocation(request: request, noStart: true, socketPath: "/tmp/test.sock"))

        XCTAssertEqual(result.response.error?.code, .timeout)
        XCTAssertEqual(result.exitCode, ControlErrorCode.timeout.exitCode)
    }

    func testJSONOutputIsOneValueWithTrailingNewline() throws {
        let response = ControlResponse.success(requestID: "req", result: .object(["b": .number(2), "a": .number(1)]))
        let output = try CLIOutput.jsonLine(response)

        XCTAssertTrue(output.hasSuffix("\n"))
        XCTAssertEqual(output.filter { $0 == "\n" }.count, 1)
        XCTAssertTrue(output.contains("\"a\":1,\"b\":2"))
    }

    private func invocation(noStart: Bool = false) -> CLIInvocation {
        CLIInvocation(request: ControlRequest(requestID: "req", command: "status"),
                      noStart: noStart, socketPath: "/tmp/test.sock")
    }
}

private struct MutationTimeoutCase {
    let command: String
    let arguments: [String: JSONValue]
    let targetKey: String
    let targetValue: JSONValue
}

private final class MockTransport: ControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<ControlResponse, Error>]
    private(set) var sendCount = 0

    init(_ results: [Result<ControlResponse, Error>]) { self.results = results }

    func send(_ request: ControlRequest) throws -> ControlResponse {
        try lock.withLock {
            sendCount += 1
            guard !results.isEmpty else { throw IPCError.unavailable }
            return try results.removeFirst().get()
        }
    }
}

private final class MockLauncher: AppLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error?
    private(set) var launchCount = 0

    init(error: Error? = nil) { self.error = error }

    func launch() throws {
        try lock.withLock {
            launchCount += 1
            if let error { throw error }
        }
    }
}
