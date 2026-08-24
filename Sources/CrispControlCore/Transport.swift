import Darwin
import Foundation

public enum IPCError: Error, Equatable, LocalizedError {
    case unavailable
    case timeout
    case unsafeSocketPath
    case socketPathTooLong
    case addressInUse
    case malformedResponse
    case responseProtocolMismatch
    case responseRequestMismatch
    case ioFailure

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Crisp control socket is unavailable"
        case .timeout: "Crisp control request timed out"
        case .unsafeSocketPath: "Refusing to replace a non-socket or foreign-owned path"
        case .socketPathTooLong: "Unix socket path is too long"
        case .addressInUse: "Crisp control socket is already in use"
        case .malformedResponse: "Crisp returned malformed JSON"
        case .responseProtocolMismatch: "Crisp returned an unsupported protocol version"
        case .responseRequestMismatch: "Crisp returned a response for a different request"
        case .ioFailure: "Unix socket I/O failed"
        }
    }
}

public enum ControlSocket {
    public static var defaultPath: String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.crisp.app", isDirectory: true)
            .appendingPathComponent("control.sock").path
    }
}

public struct UnixSocketClient: Sendable {
    public let path: String
    public let timeout: TimeInterval

    public init(path: String = ControlSocket.defaultPath, timeout: TimeInterval = 3) {
        self.path = path
        self.timeout = timeout
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        var data = try ControlJSON.encoder.encode(request)
        data.append(0x0A)
        return try sendRaw(data, expectedRequestID: request.requestID)
    }

    func sendRaw(_ data: Data, expectedRequestID: String? = nil) throws -> ControlResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw IPCError.ioFailure }
        defer { Darwin.close(descriptor) }
        setNoSigPipe(descriptor)
        let deadline = monotonicDeadline(after: timeout)

        let result = try withSocketAddress(path) { address, length in
            Darwin.connect(descriptor, address, length)
        }
        guard result == 0 else {
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw IPCError.timeout }
            throw IPCError.unavailable
        }
        try writeAll(data, to: descriptor, deadline: deadline)
        let responseData = try readLine(from: descriptor, deadline: deadline)
        guard let response = try? ControlJSON.decoder.decode(ControlResponse.self, from: responseData) else {
            throw IPCError.malformedResponse
        }
        guard response.protocolVersion == crispControlProtocolVersion else {
            throw IPCError.responseProtocolMismatch
        }
        if let expectedRequestID, response.requestID != expectedRequestID {
            throw IPCError.responseRequestMismatch
        }
        return response
    }
}

public final class UnixSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let path: String
    private let handler: Handler
    private let connectionTimeout: TimeInterval
    private let maximumConnections: Int
    private let queue = DispatchQueue(label: "com.crisp.control.socket")
    private let lock = NSLock()
    private let connectionLock = NSLock()
    private var descriptor: Int32 = -1
    private var activeConnections = 0

    public init(
        path: String = ControlSocket.defaultPath,
        connectionTimeout: TimeInterval = 2,
        maximumConnections: Int = 16,
        handler: @escaping Handler
    ) {
        self.path = path
        self.connectionTimeout = connectionTimeout
        self.maximumConnections = max(1, maximumConnections)
        self.handler = handler
    }

    deinit { stop() }

    public func start() throws {
        try lock.withLock {
            guard descriptor < 0 else { return }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            guard chmod(parent.path, 0o700) == 0 else { throw IPCError.ioFailure }
            try recoverStaleSocket()

            let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketDescriptor >= 0 else { throw IPCError.ioFailure }
            setNoSigPipe(socketDescriptor)
            do {
                let bindResult = try withSocketAddress(path) { address, length in
                    Darwin.bind(socketDescriptor, address, length)
                }
                guard bindResult == 0 else {
                    throw errno == EADDRINUSE ? IPCError.addressInUse : IPCError.ioFailure
                }
                guard chmod(path, 0o600) == 0, Darwin.listen(socketDescriptor, 16) == 0 else {
                    throw IPCError.ioFailure
                }
                descriptor = socketDescriptor
            } catch {
                Darwin.close(socketDescriptor)
                _ = unlink(path)
                throw error
            }
            queue.async { [weak self] in self?.acceptLoop(socketDescriptor) }
        }
    }

    public func stop() {
        let oldDescriptor = lock.withLock { () -> Int32 in
            let old = descriptor
            descriptor = -1
            return old
        }
        if oldDescriptor >= 0 {
            Darwin.shutdown(oldDescriptor, SHUT_RDWR)
            Darwin.close(oldDescriptor)
            _ = unlink(path)
        }
    }

    private func acceptLoop(_ listeningDescriptor: Int32) {
        while lock.withLock({ descriptor == listeningDescriptor }) {
            let client = Darwin.accept(listeningDescriptor, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            setNoSigPipe(client)
            let receiveDeadline = monotonicDeadline(after: connectionTimeout)
            let accepted = connectionLock.withLock { () -> Bool in
                guard activeConnections < maximumConnections else { return false }
                activeConnections += 1
                return true
            }
            guard accepted else {
                Darwin.close(client)
                continue
            }
            Task { [handler, connectionTimeout] in
                defer {
                    Darwin.close(client)
                    connectionLock.withLock { activeConnections -= 1 }
                }
                var peerUID: uid_t = 0
                var peerGID: gid_t = 0
                guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == getuid() else { return }
                var response: ControlResponse
                do {
                    let data = try readLine(from: client, deadline: receiveDeadline)
                    do {
                        let request = try ControlJSON.decoder.decode(ControlRequest.self, from: data)
                        guard request.protocolVersion == crispControlProtocolVersion else {
                            response = .failure(
                                requestID: request.requestID,
                                code: .protocolMismatch,
                                message: "unsupported protocol version",
                                details: .object([
                                    "received": .number(Double(request.protocolVersion)),
                                    "supported": .number(Double(crispControlProtocolVersion))
                                ])
                            )
                            try writeResponse(
                                response,
                                to: client,
                                deadline: monotonicDeadline(after: connectionTimeout)
                            )
                            return
                        }
                        response = await responseBeforeDeadline(
                            request: request,
                            timeout: connectionTimeout,
                            handler: handler
                        )
                    } catch {
                        response = .failure(
                            requestID: requestID(in: data) ?? UUID().uuidString,
                            code: .malformedRequest,
                            message: "request is not a valid Crisp control envelope"
                        )
                    }
                    try writeResponse(
                        response,
                        to: client,
                        deadline: monotonicDeadline(after: connectionTimeout)
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func recoverStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw IPCError.ioFailure
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw IPCError.unsafeSocketPath
        }
        if (try? socketIsReachable(path)) == true { throw IPCError.addressInUse }
        guard unlink(path) == 0 else { throw IPCError.ioFailure }
    }
}

private let maximumMessageBytes = 1_048_576

private final class ResponseRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ControlResponse, Never>?
    private var operation: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<ControlResponse, Never>) {
        self.continuation = continuation
    }

    func setOperation(_ operation: Task<Void, Never>) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard continuation != nil else { return true }
            self.operation = operation
            return false
        }
        if shouldCancel { operation.cancel() }
    }

    @discardableResult
    func resolve(_ response: ControlResponse, cancelOperation: Bool = false) -> Bool {
        let state = lock.withLock { () -> (CheckedContinuation<ControlResponse, Never>, Task<Void, Never>?)? in
            guard let continuation else { return nil }
            self.continuation = nil
            let operation = self.operation
            self.operation = nil
            return (continuation, operation)
        }
        guard let state else { return false }
        if cancelOperation { state.1?.cancel() }
        state.0.resume(returning: response)
        return true
    }
}

private func responseBeforeDeadline(
    request: ControlRequest,
    timeout: TimeInterval,
    handler: @escaping UnixSocketServer.Handler
) async -> ControlResponse {
    await withCheckedContinuation { continuation in
        let race = ResponseRace(continuation)
        let operation = Task {
            _ = race.resolve(await handler(request))
        }
        race.setOperation(operation)
        Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            race.resolve(
                .timeout(for: request),
                cancelOperation: true
            )
        }
    }
}

private func withSocketAddress<T>(
    _ path: String,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) throws -> T {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw IPCError.socketPathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
    }
    return try withUnsafePointer(to: &address) {
        try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func setNoSigPipe(_ descriptor: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
}

private func monotonicDeadline(after seconds: TimeInterval) -> UInt64 {
    let interval = UInt64(max(0, seconds) * 1_000_000_000)
    let now = DispatchTime.now().uptimeNanoseconds
    let (deadline, overflow) = now.addingReportingOverflow(interval)
    return overflow ? UInt64.max : deadline
}

private func setTimeout(_ descriptor: Int32, deadline: UInt64) throws {
    let now = DispatchTime.now().uptimeNanoseconds
    guard now < deadline else { throw IPCError.timeout }
    let remaining = deadline - now
    let seconds = remaining / 1_000_000_000
    let microseconds = max(1, (remaining % 1_000_000_000) / 1_000)
    var timeout = timeval(tv_sec: Int(seconds), tv_usec: Int32(microseconds))
    let size = socklen_t(MemoryLayout.size(ofValue: timeout))
    guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
        throw IPCError.ioFailure
    }
}

private func writeAll(_ data: Data, to descriptor: Int32, deadline: UInt64) throws {
    try data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            try setTimeout(descriptor, deadline: deadline)
            let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
            guard count > 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT { throw IPCError.timeout }
                throw IPCError.ioFailure
            }
            sent += count
        }
    }
}

private func readLine(from descriptor: Int32, deadline: UInt64) throws -> Data {
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        try setTimeout(descriptor, deadline: deadline)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            result.append(buffer, count: count)
            if let newline = result.firstIndex(of: 0x0A) {
                guard newline <= maximumMessageBytes else { throw IPCError.ioFailure }
                return result.prefix(upTo: newline)
            }
            guard result.count <= maximumMessageBytes else { throw IPCError.ioFailure }
        } else if count == 0 {
            if !result.isEmpty { return result }
            throw IPCError.ioFailure
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
            throw IPCError.timeout
        } else {
            throw IPCError.ioFailure
        }
    }
}

private func writeResponse(_ response: ControlResponse, to descriptor: Int32, deadline: UInt64) throws {
    var data = try ControlJSON.encoder.encode(response)
    data.append(0x0A)
    try writeAll(data, to: descriptor, deadline: deadline)
}

private func requestID(in data: Data) -> String? {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["requestID"] as? String
}

private func socketIsReachable(_ path: String) throws -> Bool {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw IPCError.ioFailure }
    defer { Darwin.close(descriptor) }
    let result = try withSocketAddress(path) { address, length in
        Darwin.connect(descriptor, address, length)
    }
    return result == 0
}
