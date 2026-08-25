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
    /// The native/DDC hardware range. Values above this range are never sent to hardware.
    public let hardwareRange: ControlRange
    /// Crisp's current logical slider range, including live EDR headroom when usable.
    public let logicalRange: ControlRange
    public let reason: String?
    public let remediation: String?

    public init(
        state: CapabilityState,
        backend: BrightnessBackend,
        range: ControlRange,
        readback: ReadbackQuality,
        hardwareRange: ControlRange? = nil,
        logicalRange: ControlRange? = nil,
        reason: String? = nil,
        remediation: String? = nil
    ) {
        self.state = state
        self.backend = backend
        self.range = range
        self.readback = readback
        self.hardwareRange = hardwareRange ?? ControlRange(min: 0, max: 100, precision: range.precision)
        self.logicalRange = logicalRange ?? range
        self.reason = reason
        self.remediation = remediation
    }

    private enum CodingKeys: String, CodingKey {
        case state, backend, range, readback, hardwareRange, logicalRange, reason, remediation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        state = try values.decode(CapabilityState.self, forKey: .state)
        backend = try values.decode(BrightnessBackend.self, forKey: .backend)
        range = try values.decode(ControlRange.self, forKey: .range)
        readback = try values.decode(ReadbackQuality.self, forKey: .readback)
        hardwareRange = try values.decodeIfPresent(ControlRange.self, forKey: .hardwareRange)
            ?? ControlRange(min: 0, max: 100, precision: range.precision)
        logicalRange = try values.decodeIfPresent(ControlRange.self, forKey: .logicalRange) ?? range
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        remediation = try values.decodeIfPresent(String.self, forKey: .remediation)
    }

    public static func unsupported(reason: String, remediation: String? = nil) -> Self {
        Self(state: .unsupported, backend: .unavailable,
             range: ControlRange(min: 0, max: 100, precision: 1),
             readback: .unavailable, reason: reason, remediation: remediation)
    }
}

public struct EDRHeadroomSnapshot: Codable, Equatable, Sendable {
    /// Relative component-value headroom reported by NSScreen; this is not absolute nits.
    public let potential: Double
    public let current: Double
    public let source: String
    /// Factor most recently committed by Crisp's overlay/transfer-table path.
    /// This is app state, not an independent measurement of emitted light.
    public let appliedFactor: Double?
    public let factorVerification: String?

    public init(
        potential: Double,
        current: Double,
        source: String = "NSScreen_EDR_component_values",
        appliedFactor: Double? = nil,
        factorVerification: String? = nil
    ) {
        self.potential = potential
        self.current = current
        self.source = source
        self.appliedFactor = appliedFactor
        self.factorVerification = factorVerification
    }
}

public struct ExtraBrightnessCapability: Codable, Equatable, Sendable {
    public let state: CapabilityState
    public let enabled: Bool?
    public let persistedEnabled: Bool
    public let maxBrightness: Double
    public let headroom: EDRHeadroomSnapshot?
    public let reason: String?
    public let remediation: String?

    public init(
        state: CapabilityState,
        enabled: Bool?,
        persistedEnabled: Bool,
        maxBrightness: Double,
        headroom: EDRHeadroomSnapshot? = nil,
        reason: String? = nil,
        remediation: String? = nil
    ) {
        self.state = state
        self.enabled = enabled
        self.persistedEnabled = persistedEnabled
        self.maxBrightness = maxBrightness
        self.headroom = headroom
        self.reason = reason
        self.remediation = remediation
    }

    public static func unsupported(
        enabled: Bool? = nil,
        persistedEnabled: Bool = false,
        maxBrightness: Double = 100,
        headroom: EDRHeadroomSnapshot? = nil,
        reason: String,
        remediation: String? = nil
    ) -> Self {
        Self(state: .unsupported, enabled: enabled, persistedEnabled: persistedEnabled,
             maxBrightness: maxBrightness, headroom: headroom, reason: reason, remediation: remediation)
    }
}

public struct HDRCapability: Codable, Equatable, Sendable {
    public let state: CapabilityState
    public let enabled: Bool?
    public let reason: String?
    public let remediation: String?

    public init(
        state: CapabilityState,
        enabled: Bool?,
        reason: String? = nil,
        remediation: String? = nil
    ) {
        self.state = state
        self.enabled = enabled
        self.reason = reason
        self.remediation = remediation
    }

    public static func unsupported(
        enabled: Bool? = nil,
        reason: String,
        remediation: String? = nil
    ) -> Self {
        Self(state: .unsupported, enabled: enabled, reason: reason, remediation: remediation)
    }
}

public struct DisplayConnectionCapability: Codable, Equatable, Sendable {
    public let state: CapabilityState
    public let connected: Bool
    public let disconnectAllowed: Bool
    public let reconnectAllowed: Bool
    public let platformSupported: Bool
    public let reason: String?
    public let remediation: String?

    public init(
        state: CapabilityState,
        connected: Bool,
        disconnectAllowed: Bool,
        reconnectAllowed: Bool,
        platformSupported: Bool,
        reason: String? = nil,
        remediation: String? = nil
    ) {
        self.state = state
        self.connected = connected
        self.disconnectAllowed = disconnectAllowed
        self.reconnectAllowed = reconnectAllowed
        self.platformSupported = platformSupported
        self.reason = reason
        self.remediation = remediation
    }

    public static func unsupported(
        connected: Bool,
        platformSupported: Bool = false,
        reason: String,
        remediation: String? = nil
    ) -> Self {
        Self(
            state: .unsupported,
            connected: connected,
            disconnectAllowed: false,
            reconnectAllowed: false,
            platformSupported: platformSupported,
            reason: reason,
            remediation: remediation
        )
    }
}

public struct ControlDisconnectedDisplay: Codable, Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let width: Int
    public let height: Int
    public let connection: DisplayConnectionCapability

    public init(
        uuid: String,
        name: String,
        width: Int,
        height: Int,
        connection: DisplayConnectionCapability
    ) {
        self.uuid = uuid
        self.name = name
        self.width = width
        self.height = height
        self.connection = connection
    }
}

public struct BrightnessReadSnapshot: Codable, Equatable, Sendable {
    public let logicalPercent: Double
    public let hardwareReadbackPercent: Double?

    public init(logicalPercent: Double, hardwareReadbackPercent: Double?) {
        self.logicalPercent = logicalPercent
        self.hardwareReadbackPercent = hardwareReadbackPercent
    }
}

public enum AppStateVerificationQuality: String, Codable, Equatable, Sendable {
    case verified
    case appStateVerified = "app_state_verified"
    case settling
}

public struct ExtraBrightnessSetResult: Codable, Equatable, Sendable {
    public let capability: ExtraBrightnessCapability
    public let verification: AppStateVerificationQuality
    public let warnings: [String]

    public init(
        capability: ExtraBrightnessCapability,
        verification: AppStateVerificationQuality,
        warnings: [String] = []
    ) {
        self.capability = capability
        self.verification = verification
        self.warnings = warnings
    }
}

public struct HDRSetResult: Codable, Equatable, Sendable {
    public let capability: HDRCapability
    public let verification: AppStateVerificationQuality
    public let warnings: [String]

    public init(
        capability: HDRCapability,
        verification: AppStateVerificationQuality,
        warnings: [String] = []
    ) {
        self.capability = capability
        self.verification = verification
        self.warnings = warnings
    }
}

public struct ControlDisplay: Codable, Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let isMain: Bool
    public let isBuiltin: Bool
    public let isVirtual: Bool
    public let brightness: BrightnessCapability
    public let brightnessPercent: Double?
    public let extraBrightness: ExtraBrightnessCapability
    public let hdr: HDRCapability
    public let connection: DisplayConnectionCapability

    public init(
        uuid: String,
        name: String,
        isMain: Bool,
        isBuiltin: Bool,
        isVirtual: Bool = false,
        brightness: BrightnessCapability,
        brightnessPercent: Double? = nil,
        extraBrightness: ExtraBrightnessCapability = .unsupported(reason: "Extra Brightness capability is unavailable"),
        hdr: HDRCapability = .unsupported(reason: "HDR capability is unavailable"),
        connection: DisplayConnectionCapability = .unsupported(
            connected: true,
            reason: "display connection capability is unavailable in this response"
        )
    ) {
        self.uuid = uuid
        self.name = name
        self.isMain = isMain
        self.isBuiltin = isBuiltin
        self.isVirtual = isVirtual
        self.brightness = brightness
        self.brightnessPercent = brightnessPercent
        self.extraBrightness = extraBrightness
        self.hdr = hdr
        self.connection = connection
    }
    private enum CodingKeys: String, CodingKey {
        case uuid, name, isMain, isBuiltin, isVirtual, brightness, brightnessPercent
        case extraBrightness, hdr, connection
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try values.decode(String.self, forKey: .uuid)
        name = try values.decode(String.self, forKey: .name)
        isMain = try values.decode(Bool.self, forKey: .isMain)
        isBuiltin = try values.decode(Bool.self, forKey: .isBuiltin)
        isVirtual = try values.decodeIfPresent(Bool.self, forKey: .isVirtual) ?? false
        brightness = try values.decode(BrightnessCapability.self, forKey: .brightness)
        brightnessPercent = try values.decodeIfPresent(Double.self, forKey: .brightnessPercent)
        extraBrightness = try values.decodeIfPresent(ExtraBrightnessCapability.self, forKey: .extraBrightness)
            ?? .unsupported(reason: "Extra Brightness capability is unavailable")
        hdr = try values.decodeIfPresent(HDRCapability.self, forKey: .hdr)
            ?? .unsupported(reason: "HDR capability is unavailable")
        connection = try values.decodeIfPresent(DisplayConnectionCapability.self, forKey: .connection)
            ?? .unsupported(
                connected: true,
                reason: "display connection capability is unavailable in this response"
            )
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
