import Foundation

public protocol ControlCommandService: Sendable {
    func displays() async throws -> [ControlDisplay]
    func readBrightness(displayUUID: String) async throws -> Double?
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double
}

public enum ControlServiceError: Error, Sendable {
    case unsupported(String)
    case readFailed(String)
    case writeFailed(String)
}

public struct ControlCommandDispatcher: Sendable {
    private let service: any ControlCommandService
    private let appVersion: String

    public init(service: any ControlCommandService, appVersion: String) {
        self.service = service
        self.appVersion = appVersion
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            let result = try await execute(request)
            return .success(requestID: request.requestID, result: result)
        } catch let failure as CommandFailure {
            return .failure(requestID: request.requestID, code: failure.code,
                            message: failure.message, details: failure.details)
        } catch let error as ControlServiceError {
            switch error {
            case let .unsupported(message):
                return .failure(requestID: request.requestID, code: .unsupportedCapability, message: message)
            case let .readFailed(message):
                return .failure(requestID: request.requestID, code: .internalError, message: message)
            case let .writeFailed(message):
                return .failure(requestID: request.requestID, code: .writeVerificationFailed, message: message)
            }
        } catch {
            return .failure(requestID: request.requestID, code: .internalError,
                            message: "Crisp could not complete the command")
        }
    }

    private func execute(_ request: ControlRequest) async throws -> JSONValue {
        switch request.command {
        case "version":
            return .object([
                "appVersion": .string(appVersion),
                "protocolVersion": .number(Double(crispControlProtocolVersion))
            ])
        case "status":
            return .object(["running": .bool(true), "appVersion": .string(appVersion)])
        case "displays.list":
            return .object(["displays": try jsonValue(await service.displays())])
        case "displays.get":
            return .object(["display": try jsonValue(await selectedDisplay(for: request))])
        case "displays.capabilities":
            let display = try await selectedDisplay(for: request)
            return .object([
                "displayUUID": .string(display.uuid),
                "brightness": try jsonValue(display.brightness)
            ])
        case "brightness.get":
            let display = try await selectedDisplay(for: request)
            try requireSupported(display.brightness)
            guard let percent = try await service.readBrightness(displayUUID: display.uuid) else {
                throw CommandFailure(code: .unsupportedCapability,
                                     message: "brightness read-back is unavailable",
                                     details: .object(["displayUUID": .string(display.uuid)]))
            }
            return .object([
                "displayUUID": .string(display.uuid),
                "percent": .number(percent),
                "backend": .string(display.brightness.backend.rawValue),
                "readback": .string(display.brightness.readback.rawValue)
            ])
        case "brightness.set":
            return try await setBrightness(request)
        default:
            throw CommandFailure(code: .invalidArguments, message: "unknown command: \(request.command)")
        }
    }

    private func selectedDisplay(for request: ControlRequest) async throws -> ControlDisplay {
        guard case let .string(selector)? = request.arguments["selector"], !selector.isEmpty else {
            throw CommandFailure(code: .invalidArguments, message: "a display selector is required")
        }
        do {
            return try DisplaySelector.resolve(selector, in: await service.displays())
        } catch let error as SelectorError {
            switch error {
            case .notFound:
                throw CommandFailure(code: .selectorNotFound, message: "display selector did not match",
                                     details: .object(["selector": .string(selector)]))
            case let .ambiguous(candidates):
                throw CommandFailure(code: .ambiguousSelector, message: "display selector is ambiguous",
                                     details: .object(["candidates": try jsonValue(candidates)]))
            }
        }
    }

    private func setBrightness(_ request: ControlRequest) async throws -> JSONValue {
        let display = try await selectedDisplay(for: request)
        let capability = display.brightness
        guard capability.state == .writable else {
            var details: [String: JSONValue] = ["state": .string(capability.state.rawValue)]
            if let reason = capability.reason { details["reason"] = .string(reason) }
            if let remediation = capability.remediation { details["remediation"] = .string(remediation) }
            throw CommandFailure(code: .unsupportedCapability,
                                 message: "brightness is not writable",
                                 details: .object(details))
        }
        guard case let .number(requested)? = request.arguments["percent"], requested.isFinite else {
            throw CommandFailure(code: .invalidArguments, message: "brightness percent must be a number")
        }
        guard requested >= capability.range.min, requested <= capability.range.max else {
            throw CommandFailure(
                code: .invalidArguments,
                message: "brightness percent is outside the supported range",
                details: .object([
                    "min": .number(capability.range.min),
                    "max": .number(capability.range.max),
                    "received": .number(requested)
                ])
            )
        }

        let original = try await service.readBrightness(displayUUID: display.uuid)
        let applied = try await service.writeBrightness(displayUUID: display.uuid, percent: requested)
        let readback: Double?
        let verification: String
        var warnings: [JSONValue] = []

        if capability.readback == .unavailable {
            readback = nil
            verification = "unavailable"
            warnings.append(.string("backend does not provide read-back; applied value is not independently verified"))
        } else {
            readback = try await service.readBrightness(displayUUID: display.uuid)
            guard let readback else {
                throw CommandFailure(code: .writeVerificationFailed,
                                     message: "brightness write completed but read-back failed")
            }
            let tolerance = max(capability.range.precision * 2, 0.25)
            guard abs(readback - applied) <= tolerance else {
                throw CommandFailure(
                    code: .writeVerificationFailed,
                    message: "brightness read-back did not match the applied value",
                    details: .object([
                        "requestedPercent": .number(requested),
                        "appliedPercent": .number(applied),
                        "readbackPercent": .number(readback),
                        "tolerance": .number(tolerance)
                    ])
                )
            }
            verification = capability.readback == .authoritative ? "verified" : "approximate"
        }

        return .object([
            "displayUUID": .string(display.uuid),
            "requestedPercent": .number(requested),
            "originalPercent": original.map(JSONValue.number) ?? .null,
            "appliedPercent": .number(applied),
            "readbackPercent": readback.map(JSONValue.number) ?? .null,
            "verification": .string(verification),
            "backend": .string(capability.backend.rawValue),
            "warnings": .array(warnings)
        ])
    }

    private func requireSupported(_ capability: BrightnessCapability) throws {
        guard capability.state == .readable || capability.state == .writable else {
            var details: [String: JSONValue] = ["state": .string(capability.state.rawValue)]
            if let reason = capability.reason { details["reason"] = .string(reason) }
            if let remediation = capability.remediation { details["remediation"] = .string(remediation) }
            throw CommandFailure(code: .unsupportedCapability,
                                 message: capability.reason ?? "brightness is unsupported",
                                 details: .object(details))
        }
    }
}

private struct CommandFailure: Error {
    let code: ControlErrorCode
    let message: String
    let details: JSONValue?

    init(code: ControlErrorCode, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try ControlJSON.decoder.decode(JSONValue.self, from: ControlJSON.encoder.encode(value))
}
