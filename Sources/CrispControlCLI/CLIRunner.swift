import Foundation
import CrispControlCore

public protocol ControlTransport: Sendable {
    func send(_ request: ControlRequest) throws -> ControlResponse
}

extension UnixSocketClient: ControlTransport {}

public protocol AppLaunching: Sendable {
    func launch() throws
}

public enum LauncherError: Error, Equatable {
    case notFound
    case untrustedBundle
    case launchFailed
}

public struct CLIRunResult: Sendable {
    public let response: ControlResponse
    public let exitCode: Int32

    public init(response: ControlResponse) {
        self.response = response
        self.exitCode = response.ok ? 0 : response.error?.code.exitCode ?? 1
    }
}

public struct CLIRunner: Sendable {
    private let transport: any ControlTransport
    private let launcher: any AppLaunching
    private let readinessTimeout: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        transport: any ControlTransport,
        launcher: any AppLaunching,
        readinessTimeout: TimeInterval = 5,
        pollInterval: TimeInterval = 0.05
    ) {
        self.transport = transport
        self.launcher = launcher
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
    }

    public func run(_ invocation: CLIInvocation) -> CLIRunResult {
        do {
            return CLIRunResult(response: try transport.send(invocation.request))
        } catch let error as IPCError where error == .unavailable {
            if invocation.noStart {
                return failure(invocation, .appNotRunning, "Crisp is not running")
            }
        } catch {
            return transportFailure(invocation, error)
        }

        do {
            try launcher.launch()
        } catch {
            return failure(
                invocation,
                .appLaunchFailed,
                "Crisp could not be launched by bundle identity",
                details: .object(["bundleIdentifier": .string("com.crisp.app")])
            )
        }

        let deadline = Date().addingTimeInterval(readinessTimeout)
        while Date() < deadline {
            if pollInterval > 0 { Thread.sleep(forTimeInterval: pollInterval) }
            do {
                return CLIRunResult(response: try transport.send(invocation.request))
            } catch let error as IPCError where error == .unavailable {
                continue
            } catch {
                return transportFailure(invocation, error)
            }
        }
        return failure(
            invocation,
            .appReadinessTimeout,
            "Crisp launched but its control socket did not become ready",
            details: .object(["timeoutSeconds": .number(readinessTimeout)])
        )
    }

    private func transportFailure(_ invocation: CLIInvocation, _ error: Error) -> CLIRunResult {
        if let ipcError = error as? IPCError, ipcError == .timeout {
            if invocation.request.command == "brightness.set" {
                return CLIRunResult(response: .timeout(for: invocation.request))
            }
            return failure(invocation, .timeout, "Crisp control request timed out")
        }
        if let ipcError = error as? IPCError,
           ipcError == .responseProtocolMismatch || ipcError == .responseRequestMismatch {
            return failure(invocation, .protocolMismatch, ipcError.localizedDescription)
        }
        return failure(invocation, .transportError, "Crisp control transport failed")
    }

    private func failure(
        _ invocation: CLIInvocation,
        _ code: ControlErrorCode,
        _ message: String,
        details: JSONValue? = nil
    ) -> CLIRunResult {
        CLIRunResult(response: .failure(requestID: invocation.request.requestID,
                                        code: code, message: message, details: details))
    }
}

public enum CLIOutput {
    public static func jsonLine(_ response: ControlResponse) throws -> String {
        let data = try ControlJSON.encoder.encode(response)
        guard let output = String(data: data, encoding: .utf8) else { throw CLIOutputError.invalidUTF8 }
        return output + "\n"
    }
}

public enum CLIOutputError: Error {
    case invalidUTF8
}
