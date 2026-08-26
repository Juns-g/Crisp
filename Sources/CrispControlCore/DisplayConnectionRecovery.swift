import Foundation

public enum DisplayConnectionMachSleepOffsetToken {
    /// A tight clock sandwich should finish well below this bound. Longer samples fail closed
    /// because they may have crossed a suspend or scheduler stall.
    public static let maximumSamplingIntervalNanoseconds: UInt64 = 1_000_000
    /// Two milliseconds covers only the bounded call-order estimate error. A real sleep/wake
    /// cycle changes the continuous-minus-absolute offset by far more and invalidates fallback.
    public static let matchingToleranceNanoseconds: UInt64 = 2_000_000

    private static let prefix = "mach-sleep-offset-v1:"

    public static func make(
        continuousBeforeTicks: UInt64,
        absoluteTicks: UInt64,
        continuousAfterTicks: UInt64,
        timebaseNumerator: UInt32,
        timebaseDenominator: UInt32
    ) -> String? {
        guard continuousAfterTicks >= continuousBeforeTicks else { return nil }
        let samplingTicks = continuousAfterTicks - continuousBeforeTicks
        guard let samplingNanoseconds = nanoseconds(
            fromTicks: samplingTicks,
            numerator: timebaseNumerator,
            denominator: timebaseDenominator
        ), samplingNanoseconds <= maximumSamplingIntervalNanoseconds else { return nil }

        let continuousMidpoint = continuousBeforeTicks + samplingTicks / 2
        let offsetTicks: UInt64
        if continuousMidpoint >= absoluteTicks {
            offsetTicks = continuousMidpoint - absoluteTicks
        } else {
            let negativeJitterTicks = absoluteTicks - continuousMidpoint
            guard let negativeJitterNanoseconds = nanoseconds(
                fromTicks: negativeJitterTicks,
                numerator: timebaseNumerator,
                denominator: timebaseDenominator
            ), negativeJitterNanoseconds <= maximumSamplingIntervalNanoseconds else { return nil }
            offsetTicks = 0
        }
        guard let offsetNanoseconds = nanoseconds(
            fromTicks: offsetTicks,
            numerator: timebaseNumerator,
            denominator: timebaseDenominator
        ) else { return nil }
        return encode(nanoseconds: offsetNanoseconds)
    }

    public static func encode(nanoseconds: UInt64) -> String {
        "\(prefix)\(nanoseconds)"
    }

    public static func parse(_ token: String) -> UInt64? {
        guard token.hasPrefix(prefix) else { return nil }
        let encodedNanoseconds = token.dropFirst(prefix.count)
        guard !encodedNanoseconds.isEmpty,
              encodedNanoseconds.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let nanoseconds = UInt64(encodedNanoseconds),
              token == encode(nanoseconds: nanoseconds) else { return nil }
        return nanoseconds
    }

    public static func matches(persisted: String, current: String) -> Bool {
        guard let persistedNanoseconds = parse(persisted),
              let currentNanoseconds = parse(current) else { return false }
        let difference = persistedNanoseconds >= currentNanoseconds
            ? persistedNanoseconds - currentNanoseconds
            : currentNanoseconds - persistedNanoseconds
        return difference <= matchingToleranceNanoseconds
    }

    private static func nanoseconds(
        fromTicks ticks: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> UInt64? {
        guard numerator != 0, denominator != 0 else { return nil }
        let multiplier = UInt64(numerator)
        let divisor = UInt64(denominator)
        let quotient = ticks / divisor
        let remainder = ticks % divisor
        let (wholeNanoseconds, wholeOverflow) = quotient.multipliedReportingOverflow(
            by: multiplier
        )
        let (remainderProduct, remainderOverflow) = remainder.multipliedReportingOverflow(
            by: multiplier
        )
        guard !wholeOverflow, !remainderOverflow else { return nil }
        let fractionalNanoseconds = remainderProduct / divisor
        let (totalNanoseconds, totalOverflow) = wholeNanoseconds.addingReportingOverflow(
            fractionalNanoseconds
        )
        return totalOverflow ? nil : totalNanoseconds
    }
}

public struct DisplayConnectionRecoveryHardwareProof: Codable, Equatable, Sendable {
    public let isBuiltIn: Bool
    public let identity: HardwareDisplayIdentity?

    public init(isBuiltIn: Bool, identity: HardwareDisplayIdentity?) {
        self.isBuiltIn = isBuiltIn
        self.identity = identity
    }

    var isComplete: Bool {
        isBuiltIn || identity?.isComplete == true
    }
}

public enum DisplayConnectionRecoveryProofBinder {
    public static func isDirectlyBound(
        retainedProof: DisplayConnectionRecoveryHardwareProof,
        currentIsBuiltIn: Bool,
        currentIdentity: HardwareDisplayIdentity?,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?
    ) -> Bool {
        if retainedProof.isBuiltIn {
            return currentIsBuiltIn && retainedProof.identity == nil
        }
        guard !currentIsBuiltIn,
              let retainedIdentity = retainedProof.identity,
              retainedIdentity.isComplete,
              currentIdentity == retainedIdentity else { return false }
        return HardwareFramebufferIdentityMatcher.hasUniqueExactMatch(
            target: retainedIdentity,
            framebufferSnapshot: framebufferSnapshot
        )
    }
}

public enum DisplayConnectionTopologyFingerprint {
    public static func make(
        displayIDs: [UInt32],
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?
    ) -> String? {
        guard !displayIDs.isEmpty,
              !displayIDs.contains(0),
              Set(displayIDs).count == displayIDs.count,
              let framebufferSnapshot,
              !framebufferSnapshot.isEmpty else { return nil }
        let registryEntryIDs = framebufferSnapshot.compactMap(\.registryEntryID)
        guard registryEntryIDs.count == framebufferSnapshot.count,
              Set(registryEntryIDs).count == registryEntryIDs.count else { return nil }
        let displayComponent = displayIDs.sorted().map(String.init).joined(separator: ",")
        let framebufferComponent = framebufferSnapshot.sorted {
            ($0.registryEntryID ?? 0) < ($1.registryEntryID ?? 0)
        }.map { evidence in
            let identity = evidence.identity
            return [
                String(evidence.registryEntryID ?? 0),
                evidence.hasEDIDUUID ? "1" : "0",
                String(identity?.vendorID ?? 0),
                String(identity?.productID ?? 0),
                String(identity?.serialNumber ?? 0)
            ].joined(separator: ":")
        }.joined(separator: ",")
        return "sls:\(displayComponent)|framebuffers:\(framebufferComponent)"
    }
}

public struct DisplayConnectionCandidate: Equatable, Sendable {
    public let displayID: UInt32
    public let stableUUID: String?
    public let isOnline: Bool
    public let isHardwareBackedPhysical: Bool
    public let recoveryHardwareProof: DisplayConnectionRecoveryHardwareProof?

    public init(
        displayID: UInt32,
        stableUUID: String?,
        isOnline: Bool,
        isHardwareBackedPhysical: Bool,
        recoveryHardwareProof: DisplayConnectionRecoveryHardwareProof?
    ) {
        self.displayID = displayID
        self.stableUUID = stableUUID
        self.isOnline = isOnline
        self.isHardwareBackedPhysical = isHardwareBackedPhysical
        self.recoveryHardwareProof = recoveryHardwareProof
    }
}

public enum DisplayConnectionRecoveryCapabilityState: String, Codable, Equatable, Sendable {
    case prepared
    case available
    case invalidatedByWake = "invalidated_by_wake"
    case consumed
    case indeterminate
}

public struct DisplayConnectionRecoveryCapability: Codable, Equatable, Sendable {
    public let uuid: String
    public let displayID: UInt32
    public let hardwareProof: DisplayConnectionRecoveryHardwareProof
    public let bootSessionID: String
    public let loginSessionID: String
    public let wakeSessionID: String
    public let topologyFingerprint: String
    public let state: DisplayConnectionRecoveryCapabilityState

    public init(
        uuid: String,
        displayID: UInt32,
        hardwareProof: DisplayConnectionRecoveryHardwareProof,
        bootSessionID: String,
        loginSessionID: String,
        wakeSessionID: String,
        topologyFingerprint: String,
        state: DisplayConnectionRecoveryCapabilityState
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.hardwareProof = hardwareProof
        self.bootSessionID = bootSessionID
        self.loginSessionID = loginSessionID
        self.wakeSessionID = wakeSessionID
        self.topologyFingerprint = topologyFingerprint
        self.state = state
    }

    public func changingState(
        to state: DisplayConnectionRecoveryCapabilityState
    ) -> DisplayConnectionRecoveryCapability {
        DisplayConnectionRecoveryCapability(
            uuid: uuid,
            displayID: displayID,
            hardwareProof: hardwareProof,
            bootSessionID: bootSessionID,
            loginSessionID: loginSessionID,
            wakeSessionID: wakeSessionID,
            topologyFingerprint: topologyFingerprint,
            state: state
        )
    }
}

public struct DisplayConnectionPersistedRecord: Identifiable, Codable, Equatable, Sendable {
    public let uuid: String
    public var displayID: UInt32
    public var name: String
    public var width: Int
    public var height: Int
    public var recoveryCapability: DisplayConnectionRecoveryCapability?
    public var id: String { uuid }

    public init(
        uuid: String,
        displayID: UInt32,
        name: String,
        width: Int,
        height: Int,
        recoveryCapability: DisplayConnectionRecoveryCapability? = nil
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.name = name
        self.width = width
        self.height = height
        self.recoveryCapability = recoveryCapability
    }
}

public struct DisplayConnectionPersistenceEnvelope: Codable, Equatable, Sendable {
    public let records: [DisplayConnectionPersistedRecord]
    public let pendingUUIDs: [String]
    public let reconnectReservationUUIDs: [String]
    public let reconnectPersistenceUncertainUUIDs: [String]

    public init(
        records: [DisplayConnectionPersistedRecord],
        pendingUUIDs: Set<String>,
        reconnectReservationUUIDs: Set<String>,
        reconnectPersistenceUncertainUUIDs: Set<String> = []
    ) {
        self.records = records
        self.pendingUUIDs = pendingUUIDs.sorted()
        self.reconnectReservationUUIDs = reconnectReservationUUIDs.sorted()
        self.reconnectPersistenceUncertainUUIDs = reconnectPersistenceUncertainUUIDs.sorted()
    }

    public var pendingSet: Set<String> { Set(pendingUUIDs) }
    public var reconnectReservationSet: Set<String> { Set(reconnectReservationUUIDs) }
    public var reconnectPersistenceUncertainSet: Set<String> {
        Set(reconnectPersistenceUncertainUUIDs)
    }

    private enum CodingKeys: String, CodingKey {
        case records
        case pendingUUIDs
        case reconnectReservationUUIDs
        case reconnectPersistenceUncertainUUIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        records = try container.decode(
            [DisplayConnectionPersistedRecord].self,
            forKey: .records
        )
        pendingUUIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .pendingUUIDs
        ) ?? []
        reconnectReservationUUIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .reconnectReservationUUIDs
        ) ?? []
        reconnectPersistenceUncertainUUIDs = try container.decodeIfPresent(
            [String].self,
            forKey: .reconnectPersistenceUncertainUUIDs
        ) ?? []
        let recordUUIDs = records.map(\.uuid)
        let recordSet = Set(recordUUIDs)
        guard recordSet.count == recordUUIDs.count else {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: "persisted display UUIDs must be unique"
            )
        }
        guard Set(pendingUUIDs).count == pendingUUIDs.count,
              Set(pendingUUIDs).isSubset(of: recordSet) else {
            throw DecodingError.dataCorruptedError(
                forKey: .pendingUUIDs,
                in: container,
                debugDescription: "pending UUIDs must be unique persisted records"
            )
        }
        guard Set(reconnectReservationUUIDs).count == reconnectReservationUUIDs.count,
              Set(reconnectReservationUUIDs).isSubset(of: recordSet) else {
            throw DecodingError.dataCorruptedError(
                forKey: .reconnectReservationUUIDs,
                in: container,
                debugDescription: "reconnect reservations must be unique persisted records"
            )
        }
        guard Set(reconnectPersistenceUncertainUUIDs).count
                == reconnectPersistenceUncertainUUIDs.count,
              Set(reconnectPersistenceUncertainUUIDs).isSubset(of: recordSet) else {
            throw DecodingError.dataCorruptedError(
                forKey: .reconnectPersistenceUncertainUUIDs,
                in: container,
                debugDescription: "persistence-uncertain UUIDs must be unique persisted records"
            )
        }
        guard records.allSatisfy({ record in
            guard let capability = record.recoveryCapability else { return true }
            return capability.uuid == record.uuid && capability.displayID == record.displayID
        }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .records,
                in: container,
                debugDescription: "recovery capabilities must match their persisted records"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(records, forKey: .records)
        try container.encode(pendingUUIDs, forKey: .pendingUUIDs)
        try container.encode(reconnectReservationUUIDs, forKey: .reconnectReservationUUIDs)
        try container.encode(
            reconnectPersistenceUncertainUUIDs,
            forKey: .reconnectPersistenceUncertainUUIDs
        )
    }
}

public enum RejectedReconnectRollbackError: Error, Equatable, Sendable {
    case invalidState
    case verificationFailed
}

public enum RejectedReconnectRollback {
    public static func proposedState(
        uuid: String,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?,
        currentState: DisplayConnectionPersistenceEnvelope
    ) throws -> DisplayConnectionPersistenceEnvelope {
        let matches = currentState.records.indices.filter {
            currentState.records[$0].uuid == uuid
        }
        guard matches.count == 1, let index = matches.first,
              currentState.reconnectReservationSet.contains(uuid),
              !currentState.pendingSet.contains(uuid) else {
            throw RejectedReconnectRollbackError.invalidState
        }

        var nextRecords = currentState.records
        if let consumedRecoveryCapability {
            guard consumedRecoveryCapability.uuid == uuid,
                  consumedRecoveryCapability.state == .consumed,
                  nextRecords[index].recoveryCapability == consumedRecoveryCapability else {
                throw RejectedReconnectRollbackError.invalidState
            }
            nextRecords[index].recoveryCapability = consumedRecoveryCapability.changingState(
                to: .available
            )
        } else if let capability = nextRecords[index].recoveryCapability {
            guard ![.consumed, .indeterminate].contains(capability.state) else {
                throw RejectedReconnectRollbackError.invalidState
            }
        }

        var nextReservations = currentState.reconnectReservationSet
        guard nextReservations.remove(uuid) != nil else {
            throw RejectedReconnectRollbackError.invalidState
        }
        let proposed = DisplayConnectionPersistenceEnvelope(
            records: nextRecords,
            pendingUUIDs: currentState.pendingSet,
            reconnectReservationUUIDs: nextReservations,
            reconnectPersistenceUncertainUUIDs:
                currentState.reconnectPersistenceUncertainSet.subtracting([uuid])
        )
        return proposed
    }

    public static func persistAndVerify(
        uuid: String,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?,
        currentState: DisplayConnectionPersistenceEnvelope,
        persist: (DisplayConnectionPersistenceEnvelope) throws
            -> DisplayConnectionPersistenceEnvelope
    ) throws -> DisplayConnectionPersistenceEnvelope {
        let proposed = try proposedState(
            uuid: uuid,
            consumedRecoveryCapability: consumedRecoveryCapability,
            currentState: currentState
        )
        let readBack = try persist(proposed)
        guard readBack == proposed else {
            throw RejectedReconnectRollbackError.verificationFailed
        }
        return readBack
    }
}

public enum DisplayConnectionDispatchAuthorization: Equatable, Sendable {
    case exactUUID
    case oneShotRecovery
}

public struct DisplayConnectionDispatchRequest: Equatable, Sendable {
    public let uuid: String
    public let displayID: UInt32
    public let requestedState: DisplayConnectionState
    public let authorization: DisplayConnectionDispatchAuthorization

    public init(
        uuid: String,
        displayID: UInt32,
        requestedState: DisplayConnectionState,
        authorization: DisplayConnectionDispatchAuthorization
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.requestedState = requestedState
        self.authorization = authorization
    }
}

public enum DisplayConnectionReconnectResolution: Equatable, Sendable {
    case alreadyOnline(displayID: UInt32)
    case exactUUID(displayID: UInt32)
    case oneShotRecovery(DisplayConnectionRecoveryCapability)
    case unavailable
}

public enum DisplayConnectionRecoveryResolver {
    public static func authorizesPreparedDisconnectCapability(
        _ capability: DisplayConnectionRecoveryCapability,
        uuid: String,
        displayID: UInt32,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard capability.uuid == uuid,
              capability.displayID == displayID,
              capability.state == .prepared,
              capability.hardwareProof.isComplete,
              continuityMatches(capability, observation: observation) else { return false }
        let candidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard candidates.count == 1, let candidate = candidates.first else { return false }
        return candidate.displayID == displayID
            && candidate.isOnline
            && candidate.isHardwareBackedPhysical
            && candidate.recoveryHardwareProof == capability.hardwareProof
    }

    public static func authorizesExactDisconnect(
        uuid: String,
        displayID: UInt32,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard inventoryIsConsistent(observation),
              observation.intentionalDisconnectedUUIDs.contains(uuid),
              observation.pendingDisconnectUUIDs.contains(uuid),
              observation.activePhysicalViewableUUIDs.contains(uuid),
              observation.activePhysicalViewableUUIDs.count > 1,
              !observation.virtualUUIDs.contains(uuid) else { return false }
        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        guard capabilities.count == 1, let capability = capabilities.first else { return false }
        return authorizesPreparedDisconnectCapability(
            capability,
            uuid: uuid,
            displayID: displayID,
            observation: observation
        )
    }

    public static func reconnectResolution(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionReconnectResolution {
        guard inventoryIsConsistent(observation),
              observation.intentionalDisconnectedUUIDs.contains(uuid),
              !observation.reconnectPersistenceUncertainUUIDs.contains(uuid) else {
            return .unavailable
        }
        let exactCandidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard exactCandidates.count <= 1 else { return .unavailable }
        if let exact = exactCandidates.first {
            guard exact.isHardwareBackedPhysical else { return .unavailable }
            if exact.isOnline { return .alreadyOnline(displayID: exact.displayID) }
            let unsafeStates: Set<DisplayConnectionRecoveryCapabilityState> = [
                .consumed, .indeterminate
            ]
            guard !observation.pendingDisconnectUUIDs.contains(uuid),
                  !observation.reconnectReservationUUIDs.contains(uuid),
                  !observation.recoveryCapabilities.contains(where: {
                      $0.uuid == uuid && unsafeStates.contains($0.state)
                  }) else { return .unavailable }
            return .exactUUID(displayID: exact.displayID)
        }

        guard !observation.reconnectReservationUUIDs.contains(uuid) else {
            return .unavailable
        }
        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        guard capabilities.count == 1, let capability = capabilities.first,
              validRecoveryCandidate(
                capability,
                requiredState: .available,
                observation: observation
              ) else { return .unavailable }
        return .oneShotRecovery(capability)
    }

    public static func quarantinedReconnectResolution(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionReconnectResolution {
        guard inventoryIsConsistent(observation),
              observation.intentionalDisconnectedUUIDs.contains(uuid),
              observation.reconnectPersistenceUncertainUUIDs.contains(uuid) else {
            return .unavailable
        }
        let exactCandidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard exactCandidates.count <= 1 else { return .unavailable }
        if let exact = exactCandidates.first {
            guard exact.isHardwareBackedPhysical else { return .unavailable }
            return exact.isOnline
                ? .alreadyOnline(displayID: exact.displayID)
                : .exactUUID(displayID: exact.displayID)
        }

        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        let restorableStates: Set<DisplayConnectionRecoveryCapabilityState> = [
            .prepared, .available, .consumed, .indeterminate
        ]
        guard capabilities.count == 1, let capability = capabilities.first,
              restorableStates.contains(capability.state),
              validDirectOfflineRecoveryCandidate(
                capability,
                observation: observation
              ) else { return .unavailable }
        return .oneShotRecovery(capability)
    }

    public static func orphanedReconnectResolution(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionReconnectResolution {
        guard inventoryIsConsistent(observation),
              observation.intentionalDisconnectedUUIDs.contains(uuid),
              observation.reconnectReservationUUIDs.contains(uuid),
              !observation.pendingDisconnectUUIDs.contains(uuid) else { return .unavailable }
        let exactCandidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard exactCandidates.count <= 1 else { return .unavailable }
        if let exact = exactCandidates.first {
            guard !exact.isOnline,
                  exact.isHardwareBackedPhysical else { return .unavailable }
            let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
            guard capabilities.count <= 1,
                  capabilities.first?.state != .prepared else { return .unavailable }
            return .exactUUID(displayID: exact.displayID)
        }
        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        let restorableStates: Set<DisplayConnectionRecoveryCapabilityState> = [
            .available, .consumed, .indeterminate
        ]
        guard capabilities.count == 1, let capability = capabilities.first,
              restorableStates.contains(capability.state),
              validOrphanedRecoveryCandidate(capability, observation: observation) else {
            return .unavailable
        }
        return .oneShotRecovery(capability)
    }

    public static func restorableRecoveryCapabilityForExactOrphan(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionRecoveryCapability? {
        guard case let .exactUUID(displayID) = orphanedReconnectResolution(
            uuid: uuid,
            observation: observation
        ) else { return nil }
        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        let restorableStates: Set<DisplayConnectionRecoveryCapabilityState> = [
            .available, .consumed, .indeterminate
        ]
        guard capabilities.count == 1, let capability = capabilities.first,
              restorableStates.contains(capability.state),
              capability.displayID == displayID,
              capability.hardwareProof.isComplete,
              continuityMatches(capability, observation: observation) else { return nil }
        let candidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return candidate.recoveryHardwareProof == capability.hardwareProof ? capability : nil
    }

    public static func restorableRecoveryCapabilityForExactQuarantine(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionRecoveryCapability? {
        guard case let .exactUUID(displayID) = quarantinedReconnectResolution(
            uuid: uuid,
            observation: observation
        ) else { return nil }
        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        let restorableStates: Set<DisplayConnectionRecoveryCapabilityState> = [
            .prepared, .available, .consumed, .indeterminate
        ]
        guard capabilities.count == 1, let capability = capabilities.first,
              restorableStates.contains(capability.state),
              capability.displayID == displayID,
              capability.hardwareProof.isComplete,
              continuityMatches(capability, observation: observation) else { return nil }
        let candidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return candidate.recoveryHardwareProof == capability.hardwareProof ? capability : nil
    }

    public static func authorizesOfflineConfirmation(
        _ capability: DisplayConnectionRecoveryCapability,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard observation.intentionalDisconnectedUUIDs.contains(capability.uuid),
              inventoryIsConsistent(observation) else { return false }
        let persisted = observation.recoveryCapabilities.filter { $0.uuid == capability.uuid }
        guard persisted == [capability] else { return false }
        return validRecoveryCandidate(
            capability,
            requiredState: .prepared,
            observation: observation
        )
    }

    public static func authorizesConsumedRecoveryDispatch(
        uuid: String,
        displayID: UInt32,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard inventoryIsConsistent(observation),
              observation.reconnectReservationUUIDs.contains(uuid) else { return false }
        let capabilities = observation.recoveryCapabilities.filter { $0.uuid == uuid }
        guard capabilities.count == 1, let capability = capabilities.first,
              capability.displayID == displayID else { return false }
        return validRecoveryCandidate(
            capability,
            requiredState: .consumed,
            observation: observation
        )
    }

    public static func authorizesReservedExactReconnect(
        uuid: String,
        displayID: UInt32,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard inventoryIsConsistent(observation),
              observation.intentionalDisconnectedUUIDs.contains(uuid),
              observation.reconnectReservationUUIDs.contains(uuid),
              !observation.reconnectPersistenceUncertainUUIDs.contains(uuid),
              !observation.pendingDisconnectUUIDs.contains(uuid) else { return false }
        let candidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard candidates.count == 1, let candidate = candidates.first else { return false }
        let unsafeStates: Set<DisplayConnectionRecoveryCapabilityState> = [
            .consumed, .indeterminate
        ]
        return candidate.displayID == displayID
            && !candidate.isOnline
            && candidate.isHardwareBackedPhysical
            && !observation.recoveryCapabilities.contains {
                $0.uuid == uuid && unsafeStates.contains($0.state)
            }
    }

    public static func uniqueOnlineHardwareCandidate(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionCandidate? {
        guard inventoryIsConsistent(observation) else { return nil }
        let candidates = observation.candidates.filter { $0.stableUUID == uuid }
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.isOnline,
              candidate.isHardwareBackedPhysical else { return nil }
        return candidate
    }

    private static func validRecoveryCandidate(
        _ capability: DisplayConnectionRecoveryCapability,
        requiredState: DisplayConnectionRecoveryCapabilityState,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard capability.state == requiredState,
              capability.displayID != 0,
              capability.hardwareProof.isComplete,
              observation.intentionalDisconnectedUUIDs.contains(capability.uuid),
              !observation.reconnectPersistenceUncertainUUIDs.contains(capability.uuid),
              continuityMatches(capability, observation: observation) else { return false }
        switch requiredState {
        case .prepared:
            guard observation.pendingDisconnectUUIDs.contains(capability.uuid) else { return false }
        case .available, .consumed:
            guard !observation.pendingDisconnectUUIDs.contains(capability.uuid) else { return false }
        case .invalidatedByWake, .indeterminate:
            return false
        }
        let claims = observation.recoveryCapabilities.filter {
            $0.displayID == capability.displayID
        }
        guard claims.count == 1 else { return false }
        let candidates = observation.candidates.filter { $0.displayID == capability.displayID }
        guard candidates.count == 1, let candidate = candidates.first,
              !candidate.isOnline,
              candidate.stableUUID == nil,
              candidate.recoveryHardwareProof == capability.hardwareProof else { return false }
        return observation.candidates.filter {
            $0.recoveryHardwareProof == capability.hardwareProof
        }.count == 1
    }

    private static func validOrphanedRecoveryCandidate(
        _ capability: DisplayConnectionRecoveryCapability,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard !observation.pendingDisconnectUUIDs.contains(capability.uuid) else { return false }
        return validDirectOfflineRecoveryCandidate(capability, observation: observation)
    }

    private static func validDirectOfflineRecoveryCandidate(
        _ capability: DisplayConnectionRecoveryCapability,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard capability.displayID != 0,
              capability.hardwareProof.isComplete,
              observation.intentionalDisconnectedUUIDs.contains(capability.uuid),
              continuityMatches(capability, observation: observation) else { return false }
        let claims = observation.recoveryCapabilities.filter {
            $0.displayID == capability.displayID
        }
        guard claims == [capability] else { return false }
        let candidates = observation.candidates.filter { $0.displayID == capability.displayID }
        guard candidates.count == 1, let candidate = candidates.first,
              !candidate.isOnline,
              candidate.stableUUID == nil,
              candidate.recoveryHardwareProof == capability.hardwareProof else { return false }
        return observation.candidates.filter {
            $0.recoveryHardwareProof == capability.hardwareProof
        }.count == 1
    }

    private static func continuityMatches(
        _ capability: DisplayConnectionRecoveryCapability,
        observation: DisplayConnectionObservation
    ) -> Bool {
        guard !capability.bootSessionID.isEmpty,
              !capability.loginSessionID.isEmpty,
              !capability.topologyFingerprint.isEmpty,
              let currentWakeSessionID = observation.wakeSessionID else { return false }
        return observation.bootSessionID == capability.bootSessionID
            && observation.loginSessionID == capability.loginSessionID
            && DisplayConnectionMachSleepOffsetToken.matches(
                persisted: capability.wakeSessionID,
                current: currentWakeSessionID
            )
            && observation.topologyFingerprint == capability.topologyFingerprint
    }

    public static func persistenceProjectionMatches(
        snapshot: DisplayConnectionPersistenceSnapshot,
        observation: DisplayConnectionObservation
    ) -> Bool {
        let envelope = snapshot.envelope
        return snapshot.authority == .durable
            && observation.persistenceStateIsAuthoritative
            && Set(envelope.records.map(\.uuid)) == observation.intentionalDisconnectedUUIDs
            && envelope.pendingSet == observation.pendingDisconnectUUIDs
            && envelope.reconnectReservationSet == observation.reconnectReservationUUIDs
            && envelope.reconnectPersistenceUncertainSet
                == observation.reconnectPersistenceUncertainUUIDs
            && envelope.records.compactMap(\.recoveryCapability)
                == observation.recoveryCapabilities
    }

    public static func inventoryIsConsistent(
        _ observation: DisplayConnectionObservation
    ) -> Bool {
        guard observation.persistenceStateIsAuthoritative,
              observation.onlineUUIDs.isSubset(of: observation.allUUIDs),
              observation.virtualUUIDs.isSubset(of: observation.allUUIDs),
              observation.activePhysicalViewableUUIDs.isSubset(of: observation.onlineUUIDs),
              observation.pendingDisconnectUUIDs.isSubset(
                of: observation.intentionalDisconnectedUUIDs
              ),
              observation.reconnectReservationUUIDs.isSubset(
                  of: observation.intentionalDisconnectedUUIDs
              ),
              observation.reconnectPersistenceUncertainUUIDs.isSubset(
                  of: observation.intentionalDisconnectedUUIDs
              ) else { return false }
        let capabilityUUIDs = observation.recoveryCapabilities.map(\.uuid)
        let capabilityDisplayIDs = observation.recoveryCapabilities.map(\.displayID)
        guard Set(capabilityUUIDs).count == capabilityUUIDs.count,
              Set(capabilityDisplayIDs).count == capabilityDisplayIDs.count,
              Set(capabilityUUIDs).isSubset(of: observation.intentionalDisconnectedUUIDs),
              capabilityDisplayIDs.allSatisfy({ $0 != 0 }) else { return false }
        let ids = observation.candidates.map(\.displayID)
        guard ids.allSatisfy({ $0 != 0 }), Set(ids).count == ids.count else { return false }
        let identified = observation.candidates.compactMap(\.stableUUID)
        guard Set(identified).count == identified.count,
              Set(identified) == observation.allUUIDs else { return false }
        let online = observation.candidates.compactMap { candidate in
            candidate.isOnline ? candidate.stableUUID : nil
        }
        return online.count == observation.candidates.filter(\.isOnline).count
            && Set(online) == observation.onlineUUIDs
    }
}
