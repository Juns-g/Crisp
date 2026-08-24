import Foundation
import CrispControlCore

public struct CLIInvocation: Equatable, Sendable {
    public let request: ControlRequest
    public let noStart: Bool
    public let socketPath: String

    public init(request: ControlRequest, noStart: Bool, socketPath: String) {
        self.request = request
        self.noStart = noStart
        self.socketPath = socketPath
    }
}

public enum CLIParseError: Error, Equatable, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        guard case let .invalid(message) = self else { return nil }
        return message
    }
}

public struct CLIParser: Sendable {
    private let requestID: @Sendable () -> String

    public init(requestID: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.requestID = requestID
    }

    public func parse(_ arguments: [String]) throws -> CLIInvocation {
        var positional: [String] = []
        var noStart = false
        var socketPath = ControlSocket.defaultPath
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": break
            case "--no-start": noStart = true
            case "--socket":
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw CLIParseError.invalid("--socket requires a path")
                }
                socketPath = arguments[index]
            case let option where option.hasPrefix("--"):
                throw CLIParseError.invalid("unknown option: \(option)")
            default: positional.append(arguments[index])
            }
            index += 1
        }

        let command: String
        var requestArguments: [String: JSONValue] = [:]
        if positional == ["version"] {
            command = "version"
        } else if positional == ["status"] {
            command = "status"
        } else if positional == ["displays", "list"] {
            command = "displays.list"
        } else if positional.count == 3, positional[0...1] == ["displays", "get"] {
            let selector = positional[2]
            command = "displays.get"
            requestArguments["selector"] = .string(selector)
        } else if positional.count == 3, positional[0...1] == ["displays", "capabilities"] {
            let selector = positional[2]
            command = "displays.capabilities"
            requestArguments["selector"] = .string(selector)
        } else if positional.count == 3, positional[0...1] == ["brightness", "get"] {
            let selector = positional[2]
            command = "brightness.get"
            requestArguments["selector"] = .string(selector)
        } else if positional.count == 4, positional[0...1] == ["brightness", "set"] {
            let selector = positional[2]
            let rawPercent = positional[3]
            guard let percent = Double(rawPercent), percent.isFinite else {
                throw CLIParseError.invalid("brightness percent must be a finite number")
            }
            command = "brightness.set"
            requestArguments["selector"] = .string(selector)
            requestArguments["percent"] = .number(percent)
        } else {
            throw CLIParseError.invalid("invalid command; run crispctl --help for usage")
        }
        return CLIInvocation(
            request: ControlRequest(requestID: requestID(), command: command, arguments: requestArguments),
            noStart: noStart,
            socketPath: socketPath
        )
    }
}

public let crispctlHelp = """
Usage:
  crispctl version --json
  crispctl status --json [--no-start]
  crispctl displays list --json [--no-start]
  crispctl displays get <uuid|main|builtin|name> --json [--no-start]
  crispctl displays capabilities <selector> --json [--no-start]
  crispctl brightness get <selector> --json [--no-start]
  crispctl brightness set <selector> <percent> --json [--no-start]
"""
