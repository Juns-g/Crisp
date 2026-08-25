public struct HardwareBackedPhysicalDisplayEvidence: Equatable, Sendable {
    public let isBuiltin: Bool
    public let isKnownVirtual: Bool
    public let hasIOServicePort: Bool
    public let ioServiceConformsToDisplayConnect: Bool

    public init(
        isBuiltin: Bool,
        isKnownVirtual: Bool,
        hasIOServicePort: Bool,
        ioServiceConformsToDisplayConnect: Bool
    ) {
        self.isBuiltin = isBuiltin
        self.isKnownVirtual = isKnownVirtual
        self.hasIOServicePort = hasIOServicePort
        self.ioServiceConformsToDisplayConnect = ioServiceConformsToDisplayConnect
    }
}

public enum HardwareBackedPhysicalDisplayClassifier {
    public static func isHardwareBacked(
        _ evidence: HardwareBackedPhysicalDisplayEvidence
    ) -> Bool {
        guard !evidence.isKnownVirtual else { return false }
        if evidence.isBuiltin { return true }
        return evidence.hasIOServicePort && evidence.ioServiceConformsToDisplayConnect
    }

    public static func unsupportedConnectionCapability(
        for evidence: HardwareBackedPhysicalDisplayEvidence,
        connected: Bool
    ) -> DisplayConnectionCapability? {
        guard !isHardwareBacked(evidence) else { return nil }
        return .unsupported(
            connected: connected,
            platformSupported: true,
            reason: "display cannot be positively proven as hardware-backed physical",
            remediation: "refresh after reconnecting a built-in or IOKit-backed physical display"
        )
    }
}
