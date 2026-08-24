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
}

public enum ControlErrorCode: String, Codable, CaseIterable, Sendable {
    case invalidArguments = "invalid_arguments"
    case appNotRunning = "app_not_running"
    case appLaunchFailed = "app_launch_failed"
    case appReadinessTimeout = "app_readiness_timeout"
    case unsupportedCapability = "unsupported_capability"
    case writeVerificationFailed = "write_verification_failed"
    case writeOutcomeIndeterminate = "write_outcome_indeterminate"
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
        case .unsupportedCapability: 4
        case .writeVerificationFailed, .writeOutcomeIndeterminate: 5
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
        guard request.command == "brightness.set" else {
            return .failure(
                requestID: request.requestID,
                code: .timeout,
                message: "Crisp control handler timed out"
            )
        }
        var details: [String: JSONValue] = [
            "retrySafe": .bool(false),
            "outcome": .string("unknown")
        ]
        if let selector = request.arguments["selector"] { details["selector"] = selector }
        if let percent = request.arguments["percent"] { details["targetPercent"] = percent }
        return .failure(
            requestID: request.requestID,
            code: .writeOutcomeIndeterminate,
            message: "brightness write timed out; the display may still reach the requested value",
            details: .object(details)
        )
    }
}
