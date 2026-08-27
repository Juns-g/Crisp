import Darwin
import Foundation

/// Local, one-request-per-connection JSON control surface for crispctl.
/// The socket lives in macOS's per-user temporary directory and accepts only
/// clients running as the same user. Requests and responses are newline terminated.
@MainActor
final class CrispControlServer {
    static let socketURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("crispctl.sock")

    private nonisolated static let maximumRequestBytes = 8 * 1_024
    private nonisolated static let maximumActiveClients = 4
    private let displayManager: DisplayManager
    private let acceptQueue = DispatchQueue(label: "com.crisp.app.control", qos: .utility)
    private nonisolated let clientLimiter = CrispControlClientLimiter(limit: maximumActiveClients)
    private var listenerFD: Int32 = -1

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func start() throws {
        guard listenerFD == -1 else { return }
        let path = Self.socketURL.path
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw ServerError.socketPathTooLong
        }

        try Self.removeOwnedSocket(at: path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.systemCall("socket", errno) }

        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { bytes in
                path.withCString { source in
                    bytes.baseAddress?.copyMemory(from: source, byteCount: path.utf8.count + 1)
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else { throw ServerError.systemCall("bind", errno) }
            guard Darwin.chmod(path, S_IRUSR | S_IWUSR) == 0 else {
                throw ServerError.systemCall("chmod", errno)
            }
            guard Darwin.listen(fd, 8) == 0 else { throw ServerError.systemCall("listen", errno) }
        } catch {
            Darwin.close(fd)
            try? Self.removeOwnedSocket(at: path)
            throw error
        }

        listenerFD = fd
        acceptQueue.async { [weak self] in
            self?.acceptConnections(on: fd)
        }
    }

    func stop() {
        guard listenerFD >= 0 else { return }
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        listenerFD = -1
        try? Self.removeOwnedSocket(at: Self.socketURL.path)
    }

    private nonisolated func acceptConnections(on listener: Int32) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Self.configure(client: client)
            guard Self.isCurrentUser(client: client), clientLimiter.acquire() else {
                Darwin.close(client)
                continue
            }
            let limiter = clientLimiter
            Task.detached { [weak self] in
                defer {
                    limiter.release()
                    Darwin.close(client)
                }

                let response: Data
                switch Self.readRequest(from: client) {
                case let .request(data):
                    response = await self?.response(to: data)
                        ?? CrispControlModel.encode(.failure("server unavailable"))
                case let .failure(message):
                    response = CrispControlModel.encode(.failure(message))
                case .incomplete:
                    response = CrispControlModel.encode(.failure("request read failed"))
                }
                Self.write(response, to: client)
            }
        }
    }

    private func response(to data: Data) async -> Data {
        let displays = displayManager.displays.map {
            CrispControlDisplay(
                id: $0.displayID,
                name: $0.name,
                brightness: min($0.brightness, 100),
                isBuiltin: $0.isBuiltin
            )
        }
        let result = CrispControlModel.handle(data, displays: displays)

        if let change = result.brightnessChange {
            guard let display = displayManager.displays.first(where: { $0.displayID == change.displayID }) else {
                return CrispControlModel.encode(.failure("display not found"))
            }
            await BrightnessService.shared.setBrightness(change.brightness, for: display)
        }
        return CrispControlModel.encode(result.response)
    }

    private nonisolated static func readRequest(from client: Int32) -> CrispControlRequestFrame.Result {
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)

        while true {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count > 0 {
                request.append(contentsOf: buffer.prefix(Int(count)))
                let result = CrispControlRequestFrame.parse(
                    request,
                    maximumBytes: maximumRequestBytes,
                    endOfStream: false
                )
                if result != .incomplete {
                    return result
                }
            } else if count == 0 {
                return CrispControlRequestFrame.parse(
                    request,
                    maximumBytes: maximumRequestBytes,
                    endOfStream: true
                )
            } else if errno != EINTR {
                return .failure("request read failed")
            }
        }
    }

    private nonisolated static func write(_ data: Data, to client: Int32) {
        data.withUnsafeBytes { bytes in
            guard var base = bytes.baseAddress else { return }
            var remaining = bytes.count
            while remaining > 0 {
                let count = Darwin.send(client, base, remaining, 0)
                if count > 0 {
                    remaining -= count
                    base = base.advanced(by: count)
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private nonisolated static func configure(client: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize)
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize)
        var enabled: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    private nonisolated static func isCurrentUser(client: Int32) -> Bool {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        return getpeereid(client, &userID, &groupID) == 0 && userID == geteuid()
    }

    private nonisolated static func removeOwnedSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ServerError.systemCall("lstat", errno)
        }
        guard info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFSOCK else {
            throw ServerError.socketPathOccupied
        }
        guard Darwin.unlink(path) == 0 else { throw ServerError.systemCall("unlink", errno) }
    }

    private enum ServerError: LocalizedError {
        case socketPathTooLong
        case socketPathOccupied
        case systemCall(String, Int32)

        var errorDescription: String? {
            switch self {
            case .socketPathTooLong:
                return "control socket path is too long"
            case .socketPathOccupied:
                return "control socket path is occupied by another file"
            case let .systemCall(name, code):
                return "control socket \(name) failed: \(String(cString: strerror(code)))"
            }
        }
    }
}
