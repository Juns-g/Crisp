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
        let options = try parseOptions(arguments)
        let parsed = try parseCommand(options.positional)
        return CLIInvocation(
            request: ControlRequest(
                requestID: requestID(),
                command: parsed.command,
                arguments: parsed.arguments
            ),
            noStart: options.noStart,
            socketPath: options.socketPath
        )
    }

    private func parseOptions(_ arguments: [String]) throws -> ParsedOptions {
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
        return ParsedOptions(positional: positional, noStart: noStart, socketPath: socketPath)
    }

    private func parseCommand(_ positional: [String]) throws -> ParsedCommand {
        if positional == ["version"] {
            return ParsedCommand(command: "version")
        } else if positional == ["status"] {
            return ParsedCommand(command: "status")
        } else if positional == ["displays", "list"] {
            return ParsedCommand(command: "displays.list")
        }
        if let display = parseDisplayCommand(positional) { return display }
        if let brightness = try parseBrightnessCommand(positional) { return brightness }
        if let toggle = try parseToggleCommand(positional) { return toggle }
        throw CLIParseError.invalid("invalid command; run crispctl --help for usage")
    }

    private func parseDisplayCommand(_ positional: [String]) -> ParsedCommand? {
        if positional == ["displays", "disconnected"] {
            return ParsedCommand(command: "displays.disconnected")
        }
        guard positional.count == 3, positional[0] == "displays" else { return nil }
        if positional[1] == "disconnect" || positional[1] == "reconnect" {
            guard ControlRequest.isExactDisplayUUID(positional[2]) else { return nil }
            return ParsedCommand(
                command: "displays.\(positional[1])",
                arguments: ["uuid": .string(positional[2])]
            )
        }
        guard positional[1] == "get" || positional[1] == "capabilities" else { return nil }
        return ParsedCommand(
            command: "displays.\(positional[1])",
            arguments: ["selector": .string(positional[2])]
        )
    }

    private func parseBrightnessCommand(_ positional: [String]) throws -> ParsedCommand? {
        guard positional.first == "brightness", positional.count >= 2 else { return nil }
        if positional == ["brightness", "get-all"] {
            return ParsedCommand(command: "brightness.get-all")
        }
        if positional.count == 3, positional[1] == "get" {
            return ParsedCommand(
                command: "brightness.get",
                arguments: ["selector": .string(positional[2])]
            )
        }
        if positional.count == 4, positional[1] == "set" {
            let percent = try parsePercent(positional[3])
            return ParsedCommand(
                command: "brightness.set",
                arguments: ["selector": .string(positional[2]), "percent": .number(percent)]
            )
        }
        if positional.count == 3, positional[1] == "set-all" {
            return ParsedCommand(
                command: "brightness.set-all",
                arguments: ["percent": .number(try parsePercent(positional[2]))]
            )
        }
        return nil
    }

    private func parseToggleCommand(_ positional: [String]) throws -> ParsedCommand? {
        guard positional.count == 3 || positional.count == 4,
              positional[0] == "extra-brightness" || positional[0] == "hdr" else { return nil }
        if positional.count == 3, positional[1] == "get" {
            return ParsedCommand(
                command: "\(positional[0]).get",
                arguments: ["selector": .string(positional[2])]
            )
        }
        guard positional.count == 4, positional[1] == "set",
              let enabled = Self.parseOnOff(positional[3]) else { return nil }
        return ParsedCommand(
            command: "\(positional[0]).set",
            arguments: ["selector": .string(positional[2]), "enabled": .bool(enabled)]
        )
    }

    private func parsePercent(_ value: String) throws -> Double {
        guard let percent = Double(value), percent.isFinite else {
            throw CLIParseError.invalid("brightness percent must be a finite number")
        }
        return percent
    }

    private static func parseOnOff(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on": true
        case "off": false
        default: nil
        }
    }
}

private struct ParsedOptions {
    let positional: [String]
    let noStart: Bool
    let socketPath: String
}

private struct ParsedCommand {
    let command: String
    let arguments: [String: JSONValue]

    init(command: String, arguments: [String: JSONValue] = [:]) {
        self.command = command
        self.arguments = arguments
    }
}

public let crispctlHelp = """
Usage:
  crispctl version --json
  crispctl status --json [--no-start]
  crispctl displays list --json [--no-start]
  crispctl displays get <uuid|main|builtin|name> --json [--no-start]
  crispctl displays capabilities <selector> --json [--no-start]
  crispctl displays disconnected --json [--no-start]
  crispctl displays disconnect <uuid> --json [--no-start]
  crispctl displays reconnect <uuid> --json [--no-start]
  crispctl brightness get <selector> --json [--no-start]
  crispctl brightness set <selector> <percent> --json [--no-start]
  crispctl brightness get-all --json [--no-start]
  crispctl brightness set-all <percent> --json [--no-start]
  crispctl extra-brightness get <selector> --json [--no-start]
  crispctl extra-brightness set <selector> on|off --json [--no-start]
  crispctl hdr get <selector> --json [--no-start]
  crispctl hdr set <selector> on|off --json [--no-start]
"""
