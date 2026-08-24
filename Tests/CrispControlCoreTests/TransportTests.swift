import Darwin
import XCTest
@testable import CrispControlCore

final class TransportTests: XCTestCase {
    private var directory: URL!
    private var socketPath: String { directory.appendingPathComponent("control.sock").path }

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("crisp-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripPreservesRequestIDAndSocketIsOwnerOnly() async throws {
        let server = UnixSocketServer(path: socketPath) { request in
            .success(requestID: request.requestID, result: .object(["command": .string(request.command)]))
        }
        try server.start()
        defer { server.stop() }

        let request = ControlRequest(requestID: "round-trip", command: "status")
        let response = try UnixSocketClient(path: socketPath, timeout: 1).send(request)
        let attributes = try FileManager.default.attributesOfItem(atPath: socketPath)

        XCTAssertEqual(response.requestID, "round-trip")
        XCTAssertEqual(response.result?["command"], .string("status"))
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMalformedRequestReturnsStructuredFailure() throws {
        let server = UnixSocketServer(path: socketPath) { request in
            .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let response = try UnixSocketClient(path: socketPath, timeout: 1)
            .sendRaw(Data("not json\n".utf8))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .malformedRequest)
        XCTAssertFalse(response.requestID.isEmpty)
    }

    func testProtocolMismatchNeverReachesHandler() throws {
        let handled = LockedFlag()
        let server = UnixSocketServer(path: socketPath) { request in
            handled.set()
            return .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let response = try UnixSocketClient(path: socketPath, timeout: 1).send(
            ControlRequest(protocolVersion: 999, requestID: "wrong-version", command: "status")
        )

        XCTAssertEqual(response.requestID, "wrong-version")
        XCTAssertEqual(response.error?.code, .protocolMismatch)
        XCTAssertFalse(handled.value)
    }

    func testClientTimeoutIsObservable() throws {
        let server = UnixSocketServer(path: socketPath) { request in
            try? await Task.sleep(for: .milliseconds(200))
            return .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(
            try UnixSocketClient(path: socketPath, timeout: 0.02)
                .send(ControlRequest(command: "slow"))
        ) { error in
            XCTAssertEqual(error as? IPCError, .timeout)
        }
    }

    func testClientRejectsMismatchedResponseRequestID() throws {
        let server = UnixSocketServer(path: socketPath) { _ in
            .success(requestID: "wrong-request", result: .null)
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(
            try UnixSocketClient(path: socketPath, timeout: 1)
                .send(ControlRequest(requestID: "expected-request", command: "status"))
        ) { error in
            XCTAssertEqual(error as? IPCError, .responseRequestMismatch)
        }
    }

    func testClientRejectsUnsupportedResponseProtocolVersion() throws {
        let server = UnixSocketServer(path: socketPath) { request in
            ControlResponse(protocolVersion: 999, requestID: request.requestID,
                            ok: true, result: .null, error: nil)
        }
        try server.start()
        defer { server.stop() }

        XCTAssertThrowsError(
            try UnixSocketClient(path: socketPath, timeout: 1)
                .send(ControlRequest(requestID: "version-check", command: "status"))
        ) { error in
            XCTAssertEqual(error as? IPCError, .responseProtocolMismatch)
        }
    }

    func testSilentAndPartialFrameClientsAreDisconnectedAfterServerTimeout() throws {
        let server = UnixSocketServer(path: socketPath, connectionTimeout: 0.05) { request in
            .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        for payload in [Data(), Data("{\"protocolVersion\":1".utf8)] {
            let client = try connectRawClient(to: socketPath)
            if !payload.isEmpty {
                XCTAssertEqual(payload.withUnsafeBytes {
                    Darwin.write(client, $0.baseAddress, payload.count)
                }, payload.count)
            }
            var byte: UInt8 = 0
            XCTAssertEqual(Darwin.read(client, &byte, 1), 0)
            Darwin.close(client)
        }
    }

    func testServerRejectsConnectionsAboveConfiguredBound() throws {
        let server = UnixSocketServer(
            path: socketPath, connectionTimeout: 1, maximumConnections: 1
        ) { request in
            .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let heldClient = try connectRawClient(to: socketPath)
        defer { Darwin.close(heldClient) }
        let excessClient = try connectRawClient(to: socketPath)
        defer { Darwin.close(excessClient) }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.read(excessClient, &byte, 1), 0)
    }

    func testTrickleClientCannotExtendAbsoluteReceiveDeadline() throws {
        let server = UnixSocketServer(path: socketPath, connectionTimeout: 0.08) { request in
            .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let client = try connectRawClient(to: socketPath)
        defer { Darwin.close(client) }
        let started = ContinuousClock.now
        var closed = false
        for _ in 0..<20 {
            usleep(20_000)
            var byte: UInt8 = 0x20
            if Darwin.write(client, &byte, 1) <= 0 {
                closed = true
                break
            }
        }

        XCTAssertTrue(closed)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(250))
    }

    func testHandlerDeadlineReturnsStructuredTimeout() throws {
        let server = UnixSocketServer(path: socketPath, connectionTimeout: 0.05) { request in
            try? await Task.sleep(for: .seconds(5))
            return .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let response = try UnixSocketClient(path: socketPath, timeout: 1)
            .send(ControlRequest(requestID: "handler-timeout", command: "slow"))

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.requestID, "handler-timeout")
        XCTAssertEqual(response.error?.code, .timeout)
    }

    func testBrightnessWriteTimeoutReportsIndeterminateOutcomeBeforeLateCallback() throws {
        let lateMutation = LockedFlag()
        let server = UnixSocketServer(path: socketPath, connectionTimeout: 0.05) { request in
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    lateMutation.set()
                    continuation.resume()
                }
            }
            return .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let response = try UnixSocketClient(path: socketPath, timeout: 1).send(
            ControlRequest(
                requestID: "late-write",
                command: "brightness.set",
                arguments: ["selector": .string("builtin"), "percent": .number(55)]
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(response.error?.details?["selector"], .string("builtin"))
        XCTAssertEqual(response.error?.details?["targetPercent"], .number(55))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertTrue(lateMutation.value)
    }

    func testProductionDefaultTimeoutsDeliverStructuredIndeterminateBrightnessResult() throws {
        let server = UnixSocketServer(path: socketPath) { request in
            try? await Task.sleep(for: .seconds(5))
            return .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        let response = try UnixSocketClient(path: socketPath).send(
            ControlRequest(
                requestID: "production-default-timeout",
                command: "brightness.set",
                arguments: ["selector": .string("builtin"), "percent": .number(55)]
            )
        )

        XCTAssertEqual(response.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
    }

    func testOversizedFrameIsRejectedEvenWhenTerminatedInSameChunk() throws {
        let server = UnixSocketServer(path: socketPath) { request in
            .success(requestID: request.requestID, result: .null)
        }
        try server.start()
        defer { server.stop() }

        var data = Data(repeating: 0x20, count: 1_048_577)
        data.append(0x0A)
        XCTAssertThrowsError(try UnixSocketClient(path: socketPath, timeout: 1).sendRaw(data))
    }

    func testStaleSocketIsRecoveredButRegularFileIsNeverDeleted() throws {
        try makeStaleSocket(at: socketPath)
        let server = UnixSocketServer(path: socketPath) { request in
            .success(requestID: request.requestID, result: .null)
        }
        XCTAssertNoThrow(try server.start())
        server.stop()

        try Data("keep".utf8).write(to: URL(fileURLWithPath: socketPath))
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? IPCError, .unsafeSocketPath)
        }
        XCTAssertEqual(try String(contentsOfFile: socketPath, encoding: .utf8), "keep")
    }

    private func makeStaleSocket(at path: String) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
    }

    private func connectRawClient(to path: String) throws -> Int32 {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.ioFailure }
        var noSigPipe: Int32 = 1
        _ = setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE,
            &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe))
        )
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            path.utf8CString.withUnsafeBytes { source in bytes.copyBytes(from: source) }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw IPCError.unavailable
        }
        return descriptor
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool { lock.withLock { stored } }
    func set() { lock.withLock { stored = true } }
}
