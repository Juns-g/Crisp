import Foundation

public let crispControlProtocolVersion = 1

public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(object) = self else { return nil }
        return object[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case let .array(array) = self, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

public enum ControlJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static var decoder: JSONDecoder { JSONDecoder() }
}

public struct ControlRequest: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let command: String
    public let arguments: [String: JSONValue]

    public init(
        protocolVersion: Int = crispControlProtocolVersion,
        requestID: String = UUID().uuidString,
        command: String,
        arguments: [String: JSONValue] = [:]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.command = command
        self.arguments = arguments
    }

    public var mutationKind: ControlMutationKind? {
        switch command {
        case "brightness.set": .brightness
        case "brightness.set-all": .brightnessBatch
        case "extra-brightness.set": .extraBrightness
        case "hdr.set": .hdr
        case "displays.disconnect", "displays.reconnect": .displayConnection
        default:
            command.hasSuffix(".set") || command.hasSuffix(".set-all") ? .unknown : nil
        }
    }

    public var isMutating: Bool { mutationKind != nil }

    public var exactDisplayConnectionUUID: String? {
        guard mutationKind == .displayConnection,
              case let .string(uuid)? = arguments["uuid"],
              Self.isExactDisplayUUID(uuid) else { return nil }
        return uuid
    }

    public static func isExactDisplayUUID(_ value: String) -> Bool {
        let characters = Array(value)
        return value.utf8.count == 36
            && UUID(uuidString: value) != nil
            && [8, 13, 18, 23].allSatisfy {
                characters.indices.contains($0) && characters[$0] == "-"
            }
    }
}

public enum ControlMutationKind: String, Codable, Equatable, Sendable {
    case brightness
    case brightnessBatch = "brightness_batch"
    case extraBrightness = "extra_brightness"
    case hdr
    case displayConnection = "display_connection"
    /// Conservative fallback for a future set-shaped command omitted from the
    /// explicit inventory: timeout safety must fail closed until CI classifies it.
    case unknown
}

public enum ControlCommandInventory {
    public static let dispatcherCommands: Set<String> = [
        "version", "status", "displays.list", "displays.get", "displays.capabilities",
        "displays.disconnected", "displays.disconnect", "displays.reconnect",
        "brightness.get", "brightness.set", "brightness.get-all", "brightness.set-all",
        "extra-brightness.get", "extra-brightness.set", "hdr.get", "hdr.set"
    ]
    public static let mutatingCommands: Set<String> = [
        "brightness.set", "brightness.set-all", "extra-brightness.set", "hdr.set",
        "displays.disconnect", "displays.reconnect"
    ]
}

public enum ControlErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidArguments = "invalid_arguments"
    case appNotRunning = "app_not_running"
    case appLaunchFailed = "app_launch_failed"
    case appReadinessTimeout = "app_readiness_timeout"
    case unsupportedCapability = "unsupported_capability"
    case writeVerificationFailed = "write_verification_failed"
    case writeOutcomeIndeterminate = "write_outcome_indeterminate"
    case batchPartialFailure = "batch_partial_failure"
    case batchPreflightFailed = "batch_preflight_failed"
    case emptyPhysicalInventory = "empty_physical_inventory"
    case selectorNotFound = "selector_not_found"
    case ambiguousSelector = "ambiguous_selector"
    case protocolMismatch = "protocol_mismatch"
    case malformedRequest = "malformed_request"
    case timeout
    case transportError = "transport_error"
    case internalError = "internal_error"

    public var exitCode: Int32 {
        switch self {
        case .invalidArguments: 2
        case .appNotRunning, .appLaunchFailed, .appReadinessTimeout: 3
        case .unsupportedCapability, .batchPreflightFailed, .emptyPhysicalInventory: 4
        case .writeVerificationFailed, .writeOutcomeIndeterminate, .batchPartialFailure: 5
        case .selectorNotFound, .ambiguousSelector: 6
        case .protocolMismatch, .malformedRequest: 7
        case .timeout, .transportError: 8
        case .internalError: 1
        }
    }
}

public struct ControlError: Codable, Equatable, Sendable {
    public let code: ControlErrorCode
    public let message: String
    public let details: JSONValue?

    public init(code: ControlErrorCode, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

public struct ControlResponse: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let requestID: String
    public let ok: Bool
    public let result: JSONValue?
    public let error: ControlError?

    public static func success(requestID: String, result: JSONValue) -> Self {
        Self(protocolVersion: crispControlProtocolVersion, requestID: requestID,
             ok: true, result: result, error: nil)
    }

    public static func failure(
        requestID: String,
        code: ControlErrorCode,
        message: String,
        details: JSONValue? = nil
    ) -> Self {
        Self(protocolVersion: crispControlProtocolVersion, requestID: requestID,
             ok: false, result: nil, error: ControlError(code: code, message: message, details: details))
    }

    public static func timeout(for request: ControlRequest) -> Self {
        guard request.isMutating else {
            return .failure(
                requestID: request.requestID,
                code: .timeout,
                message: "Crisp control handler timed out"
            )
        }
        var details: [String: JSONValue] = [
            "retrySafe": .bool(false),
            "outcome": .string("unknown"),
            "command": .string(request.command)
        ]
        if let selector = request.arguments["selector"] { details["selector"] = selector }
        if let percent = request.arguments["percent"] { details["targetPercent"] = percent }
        if let enabled = request.arguments["enabled"] { details["targetEnabled"] = enabled }
        if request.command == "brightness.set-all" {
            details["target"] = .string("all_physical_displays")
        }
        if request.mutationKind == .displayConnection {
            guard let uuid = request.exactDisplayConnectionUUID else {
                return invalidDisplayConnectionRequest(for: request)
            }
            let requestedState = request.command == "displays.reconnect" ? "connected" : "disconnected"
            details["requestedConnectionState"] = .string(requestedState)
            details["displayUUID"] = .string(uuid)
        }
        return .failure(
            requestID: request.requestID,
            code: .writeOutcomeIndeterminate,
            message: "control write timed out; one or more displays may still reach the requested state",
            details: .object(details)
        )
    }

    public static func invalidDisplayConnectionRequest(for request: ControlRequest) -> Self {
        .failure(
            requestID: request.requestID,
            code: .invalidArguments,
            message: "\(request.command) requires an exact UUID in the uuid argument",
            details: .object([
                "phase": .string("preflight"),
                "retrySafe": .bool(true),
                "mutationDispatched": .bool(false),
                "command": .string(request.command)
            ])
        )
    }
}
