public struct HardwareDisplayIdentity: Equatable, Sendable {
    public let vendorID: UInt32?
    public let productID: UInt32?
    public let serialNumber: UInt32?

    public init(vendorID: UInt32?, productID: UInt32?, serialNumber: UInt32?) {
        self.vendorID = vendorID
        self.productID = productID
        self.serialNumber = serialNumber
    }

    fileprivate var isComplete: Bool {
        guard let vendorID, let productID, let serialNumber else { return false }
        return vendorID != 0 && productID != 0 && serialNumber != 0
    }
}

public struct HardwareFramebufferIdentityEvidence: Equatable, Sendable {
    public let hasEDIDUUID: Bool
    public let identity: HardwareDisplayIdentity?

    public init(hasEDIDUUID: Bool, identity: HardwareDisplayIdentity?) {
        self.hasEDIDUUID = hasEDIDUUID
        self.identity = identity
    }
}

public enum HardwareFramebufferIdentityMatcher {
    public static func hasUniqueExactMatch(
        target: HardwareDisplayIdentity,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?
    ) -> Bool {
        guard target.isComplete, let framebufferSnapshot else { return false }
        let candidates = framebufferSnapshot.filter(\.hasEDIDUUID)
        guard candidates.allSatisfy({ $0.identity?.isComplete == true }) else { return false }
        return candidates.filter { $0.identity == target }.count == 1
    }
}

public struct HardwareBackedPhysicalDisplayEvidence: Equatable, Sendable {
    public let isBuiltin: Bool
    public let isKnownVirtual: Bool
    public let hasIOServicePort: Bool
    public let ioServiceConformsToDisplayConnect: Bool
    public let coreGraphicsIdentity: HardwareDisplayIdentity?
    public let framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?

    public init(
        isBuiltin: Bool,
        isKnownVirtual: Bool,
        hasIOServicePort: Bool,
        ioServiceConformsToDisplayConnect: Bool,
        coreGraphicsIdentity: HardwareDisplayIdentity? = nil,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]? = nil
    ) {
        self.isBuiltin = isBuiltin
        self.isKnownVirtual = isKnownVirtual
        self.hasIOServicePort = hasIOServicePort
        self.ioServiceConformsToDisplayConnect = ioServiceConformsToDisplayConnect
        self.coreGraphicsIdentity = coreGraphicsIdentity
        self.framebufferSnapshot = framebufferSnapshot
    }
}

public enum HardwareBackedPhysicalDisplayClassifier {
    public static func isHardwareBacked(
        _ evidence: HardwareBackedPhysicalDisplayEvidence
    ) -> Bool {
        guard !evidence.isKnownVirtual else { return false }
        if evidence.isBuiltin { return true }
        if evidence.hasIOServicePort && evidence.ioServiceConformsToDisplayConnect {
            return true
        }
        guard let target = evidence.coreGraphicsIdentity else { return false }
        return HardwareFramebufferIdentityMatcher.hasUniqueExactMatch(
            target: target,
            framebufferSnapshot: evidence.framebufferSnapshot
        )
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
