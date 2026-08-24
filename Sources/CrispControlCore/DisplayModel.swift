import Foundation

public enum CapabilityState: String, Codable, Equatable, Sendable {
    case readable
    case writable
    case unsupported
    case permissionRequired = "permission_required"
}

public enum BrightnessBackend: String, Codable, Equatable, Sendable {
    case displayServices = "DisplayServices"
    case ioKit = "IOKit"
    case ddc = "DDC"
    case software = "software_gamma"
    case unavailable
}

public enum ReadbackQuality: String, Codable, Equatable, Sendable {
    case authoritative
    case approximate
    case unavailable
}

public struct ControlRange: Codable, Equatable, Sendable {
    public let min: Double
    public let max: Double
    public let precision: Double

    public init(min: Double, max: Double, precision: Double) {
        self.min = min
        self.max = max
        self.precision = precision
    }
}

public struct BrightnessCapability: Codable, Equatable, Sendable {
    public let state: CapabilityState
    public let backend: BrightnessBackend
    public let range: ControlRange
    public let readback: ReadbackQuality
    public let reason: String?
    public let remediation: String?

    public init(
        state: CapabilityState,
        backend: BrightnessBackend,
        range: ControlRange,
        readback: ReadbackQuality,
        reason: String? = nil,
        remediation: String? = nil
    ) {
        self.state = state
        self.backend = backend
        self.range = range
        self.readback = readback
        self.reason = reason
        self.remediation = remediation
    }

    public static func unsupported(reason: String, remediation: String? = nil) -> Self {
        Self(state: .unsupported, backend: .unavailable,
             range: ControlRange(min: 0, max: 100, precision: 1),
             readback: .unavailable, reason: reason, remediation: remediation)
    }
}

public struct ControlDisplay: Codable, Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let isMain: Bool
    public let isBuiltin: Bool
    public let brightness: BrightnessCapability
    public let brightnessPercent: Double?

    public init(
        uuid: String,
        name: String,
        isMain: Bool,
        isBuiltin: Bool,
        brightness: BrightnessCapability,
        brightnessPercent: Double? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.brightness = brightness
        self.brightnessPercent = brightnessPercent
    }
}

public enum SelectorError: Error, Equatable {
    case notFound(String)
    case ambiguous([ControlDisplay])
}

public enum DisplaySelector {
    public static func resolve(_ selector: String, in displays: [ControlDisplay]) throws -> ControlDisplay {
        let matches: [ControlDisplay]
        switch selector.lowercased() {
        case "main": matches = displays.filter(\.isMain)
        case "builtin": matches = displays.filter(\.isBuiltin)
        default:
            matches = displays.filter {
                $0.uuid.caseInsensitiveCompare(selector) == .orderedSame
                    || $0.name.caseInsensitiveCompare(selector) == .orderedSame
            }
        }
        let ordered = matches.sorted { $0.uuid < $1.uuid }
        guard !ordered.isEmpty else { throw SelectorError.notFound(selector) }
        guard ordered.count == 1 else { throw SelectorError.ambiguous(ordered) }
        return ordered[0]
    }
}
