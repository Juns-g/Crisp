public enum PhysicalDisplaySafetyPolicy {
    public static func shouldRefuseDisconnect(
        targetIsActive: Bool,
        activePhysicalDisplayCount: Int?
    ) -> Bool {
        guard let activePhysicalDisplayCount else { return true }
        return targetIsActive && activePhysicalDisplayCount <= 1
    }

    public static func authorizesEmergencyRecovery(
        activePhysicalDisplayCount: Int?
    ) -> Bool {
        activePhysicalDisplayCount == 0
    }

    public static func uniqueExactUUIDDisplayIDs(
        _ candidates: [(uuid: String?, displayID: UInt32)]
    ) -> [String: UInt32] {
        var grouped: [String: [UInt32]] = [:]
        for candidate in candidates {
            guard let uuid = candidate.uuid,
                  ControlRequest.isExactDisplayUUID(uuid) else { continue }
            grouped[uuid, default: []].append(candidate.displayID)
        }

        var unique: [String: UInt32] = [:]
        for (uuid, displayIDs) in grouped where displayIDs.count == 1 {
            unique[uuid] = displayIDs[0]
        }
        return unique
    }
}
