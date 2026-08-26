import Foundation

public enum DisplayConnectionPersistenceError: Error, Equatable, Sendable {
    case missing
    case corrupt
    case invalidState
    case encodingFailed
}

public enum ConnectionPersistenceAuthority: Equatable, Sendable {
    case durable
    case syntheticQuarantine
}

public struct DisplayConnectionPersistenceSnapshot: Equatable, Sendable {
    public let envelope: DisplayConnectionPersistenceEnvelope
    public let authority: ConnectionPersistenceAuthority

    public init(
        envelope: DisplayConnectionPersistenceEnvelope,
        authority: ConnectionPersistenceAuthority
    ) {
        self.envelope = envelope
        self.authority = authority
    }

    public var authorizesConnectionMutation: Bool {
        authority == .durable && envelope.reconnectPersistenceUncertainSet.isEmpty
    }
}

public enum ConnectionPersistenceDisposition: Equatable, Sendable {
    case committedProposed
    case preservedOld
    case quarantined
}

public struct DisplayConnectionPersistenceWriteResult: Equatable, Sendable {
    public let disposition: ConnectionPersistenceDisposition
    public let snapshot: DisplayConnectionPersistenceSnapshot

    public init(
        disposition: ConnectionPersistenceDisposition,
        snapshot: DisplayConnectionPersistenceSnapshot
    ) {
        self.disposition = disposition
        self.snapshot = snapshot
    }
}

/// A single-value persistence boundary. Replacement and read-back are deliberately modeled as
/// separate operations: the backing store is not assumed to be transactional.
public final class DisplayConnectionPersistenceBoundary {
    public typealias Read = () -> Data?
    public typealias Write = (Data) -> Void

    private enum DecodedRead {
        case envelope(DisplayConnectionPersistenceEnvelope)
        case missing
        case corrupt
    }

    private struct RecoveryContext {
        let oldState: DisplayConnectionPersistenceEnvelope
        let proposedState: DisplayConnectionPersistenceEnvelope
        let quarantineState: DisplayConnectionPersistenceEnvelope
    }

    private let read: Read
    private let write: Write
    private var recoveryContext: RecoveryContext?
    public private(set) var publishedRecords: [DisplayConnectionPersistedRecord]

    public init(
        initialPublishedRecords: [DisplayConnectionPersistedRecord] = [],
        read: @escaping Read,
        write: @escaping Write
    ) {
        publishedRecords = initialPublishedRecords
        self.read = read
        self.write = write
    }

    public func adoptPublishedRecords(from snapshot: DisplayConnectionPersistenceSnapshot) {
        publishedRecords = snapshot.envelope.records
        if snapshot.authority == .durable, let recoveryContext,
           snapshot.envelope == recoveryContext.oldState
            || snapshot.envelope == recoveryContext.proposedState
            || snapshot.envelope == recoveryContext.quarantineState {
            self.recoveryContext = nil
        }
    }

    /// Reads the one authoritative value exactly once. If a prior compensation could not be
    /// verified, only a known old/proposed/quarantine value can replace the synthetic quarantine.
    public func snapshot() throws -> DisplayConnectionPersistenceSnapshot {
        let decoded = decodeOneRead()
        if let recoveryContext {
            switch decoded {
            case let .envelope(envelope) where envelope == recoveryContext.oldState
                    || envelope == recoveryContext.proposedState
                    || envelope == recoveryContext.quarantineState:
                return durableSnapshot(envelope)
            case .envelope, .missing, .corrupt:
                return DisplayConnectionPersistenceSnapshot(
                    envelope: recoveryContext.quarantineState,
                    authority: .syntheticQuarantine
                )
            }
        }
        switch decoded {
        case let .envelope(envelope):
            return durableSnapshot(envelope)
        case .missing:
            throw DisplayConnectionPersistenceError.missing
        case .corrupt:
            throw DisplayConnectionPersistenceError.corrupt
        }
    }

    /// Writes the proposal once and classifies its single read-back. Missing, corrupt, or
    /// unexpected valid read-back triggers one explicit compensation write of a fail-closed
    /// quarantine envelope. The normal success path remains one write.
    public func replace(
        oldState: DisplayConnectionPersistenceEnvelope,
        proposedState: DisplayConnectionPersistenceEnvelope,
        quarantiningUUIDs: Set<String>
    ) throws -> DisplayConnectionPersistenceWriteResult {
        let baseQuarantineState = try makeQuarantine(
            oldState: oldState,
            proposedState: proposedState,
            uncertainUUIDs: quarantiningUUIDs
        )
        try writeEnvelope(proposedState)
        let quarantineState: DisplayConnectionPersistenceEnvelope
        switch decodeOneRead() {
        case let .envelope(readBack) where readBack == proposedState:
            recoveryContext = nil
            return result(.committedProposed, envelope: readBack)
        case let .envelope(readBack) where readBack == oldState:
            recoveryContext = nil
            return result(.preservedOld, envelope: readBack)
        case let .envelope(readBack):
            quarantineState = try makeQuarantine(
                oldState: oldState,
                proposedState: proposedState,
                observedState: readBack,
                uncertainUUIDs: quarantiningUUIDs
            )
        case .missing, .corrupt:
            quarantineState = baseQuarantineState
        }

        try writeEnvelope(quarantineState)
        switch decodeOneRead() {
        case let .envelope(readBack) where readBack == proposedState:
            recoveryContext = nil
            return result(.committedProposed, envelope: readBack)
        case let .envelope(readBack) where readBack == oldState:
            recoveryContext = nil
            return result(.preservedOld, envelope: readBack)
        case let .envelope(readBack) where readBack == quarantineState:
            recoveryContext = nil
            return result(.quarantined, envelope: readBack)
        case .envelope, .missing, .corrupt:
            recoveryContext = RecoveryContext(
                oldState: oldState,
                proposedState: proposedState,
                quarantineState: quarantineState
            )
            publishedRecords = quarantineState.records
            return DisplayConnectionPersistenceWriteResult(
                disposition: .quarantined,
                snapshot: DisplayConnectionPersistenceSnapshot(
                    envelope: quarantineState,
                    authority: .syntheticQuarantine
                )
            )
        }
    }

    public func reconcileTopologyMetadata(
        snapshot: DisplayConnectionPersistenceSnapshot,
        observation: DisplayConnectionObservation?
    ) throws -> DisplayConnectionPersistenceWriteResult? {
        guard let observation,
              let transition = ConnectionMetadataReconciler.transition(
                snapshot: snapshot,
                observation: observation
              ) else { return nil }
        return try replace(
            oldState: snapshot.envelope,
            proposedState: transition.proposedState,
            quarantiningUUIDs: transition.affectedUUIDs
        )
    }

    public func reconcileQuarantinedReconnect(
        uuid: String,
        snapshot: DisplayConnectionPersistenceSnapshot,
        observation: DisplayConnectionObservation
    ) throws -> QuarantineReconnectPersistenceResult? {
        guard let transition = DisplayReconnectQuarantineReconciler.transition(
            uuid: uuid,
            snapshot: snapshot,
            observation: observation
        ) else { return nil }
        let writeResult = try replace(
            oldState: snapshot.envelope,
            proposedState: transition.proposedState,
            quarantiningUUIDs: [uuid]
        )
        return QuarantineReconnectPersistenceResult(
            kind: transition.kind,
            writeResult: writeResult
        )
    }

    private func decodeOneRead() -> DecodedRead {
        guard let data = read() else { return .missing }
        guard let envelope = try? JSONDecoder().decode(
            DisplayConnectionPersistenceEnvelope.self,
            from: data
        ) else { return .corrupt }
        return .envelope(envelope)
    }

    private func writeEnvelope(_ envelope: DisplayConnectionPersistenceEnvelope) throws {
        guard let data = try? JSONEncoder().encode(envelope) else {
            throw DisplayConnectionPersistenceError.encodingFailed
        }
        write(data)
    }

    private func makeQuarantine(
        oldState: DisplayConnectionPersistenceEnvelope,
        proposedState: DisplayConnectionPersistenceEnvelope,
        observedState: DisplayConnectionPersistenceEnvelope? = nil,
        uncertainUUIDs: Set<String>
    ) throws -> DisplayConnectionPersistenceEnvelope {
        var records = oldState.records
        var recordUUIDs = Set(records.map(\.uuid))
        for state in [proposedState, observedState].compactMap({ $0 }) {
            for record in state.records where !recordUUIDs.contains(record.uuid) {
                records.append(record)
                recordUUIDs.insert(record.uuid)
            }
        }
        guard uncertainUUIDs.isSubset(of: recordUUIDs) else {
            throw DisplayConnectionPersistenceError.invalidState
        }
        let observedPending = observedState?.pendingSet ?? []
        let observedReservations = observedState?.reconnectReservationSet ?? []
        let observedUncertain = observedState?.reconnectPersistenceUncertainSet ?? []
        return DisplayConnectionPersistenceEnvelope(
            records: records,
            pendingUUIDs: oldState.pendingSet
                .union(proposedState.pendingSet)
                .union(observedPending),
            reconnectReservationUUIDs: oldState.reconnectReservationSet.union(
                proposedState.reconnectReservationSet
            ).union(observedReservations),
            reconnectPersistenceUncertainUUIDs: oldState.reconnectPersistenceUncertainSet
                .union(proposedState.reconnectPersistenceUncertainSet)
                .union(observedUncertain)
                .union(uncertainUUIDs)
        )
    }

    private func durableSnapshot(
        _ envelope: DisplayConnectionPersistenceEnvelope
    ) -> DisplayConnectionPersistenceSnapshot {
        DisplayConnectionPersistenceSnapshot(envelope: envelope, authority: .durable)
    }

    private func result(
        _ disposition: ConnectionPersistenceDisposition,
        envelope: DisplayConnectionPersistenceEnvelope
    ) -> DisplayConnectionPersistenceWriteResult {
        publishedRecords = envelope.records
        return DisplayConnectionPersistenceWriteResult(
            disposition: disposition,
            snapshot: durableSnapshot(envelope)
        )
    }
}

public enum DisplayReconnectQuarantineTransitionKind: Equatable, Sendable {
    case reconciledOffline
    case alreadyOnline
}

public struct DisplayReconnectQuarantineTransition: Equatable, Sendable {
    public let kind: DisplayReconnectQuarantineTransitionKind
    public let proposedState: DisplayConnectionPersistenceEnvelope

    public init(
        kind: DisplayReconnectQuarantineTransitionKind,
        proposedState: DisplayConnectionPersistenceEnvelope
    ) {
        self.kind = kind
        self.proposedState = proposedState
    }
}

public struct QuarantineReconnectPersistenceResult: Equatable, Sendable {
    public let kind: DisplayReconnectQuarantineTransitionKind
    public let writeResult: DisplayConnectionPersistenceWriteResult

    public init(
        kind: DisplayReconnectQuarantineTransitionKind,
        writeResult: DisplayConnectionPersistenceWriteResult
    ) {
        self.kind = kind
        self.writeResult = writeResult
    }
}

public enum DisplayReconnectQuarantineReconciler {
    public static func transition(
        uuid: String,
        snapshot: DisplayConnectionPersistenceSnapshot,
        observation: DisplayConnectionObservation
    ) -> DisplayReconnectQuarantineTransition? {
        let current = snapshot.envelope
        let matches = current.records.indices.filter { current.records[$0].uuid == uuid }
        guard matches.count == 1, let recordIndex = matches.first,
              current.reconnectPersistenceUncertainSet.contains(uuid),
              DisplayConnectionRecoveryResolver.persistenceProjectionMatches(
                snapshot: snapshot,
                observation: observation
              ),
              DisplayConnectionRecoveryResolver.inventoryIsConsistent(observation) else {
            return nil
        }

        var records = current.records
        let kind: DisplayReconnectQuarantineTransitionKind
        switch DisplayConnectionRecoveryResolver.quarantinedReconnectResolution(
            uuid: uuid,
            observation: observation
        ) {
        case .alreadyOnline:
            records.remove(at: recordIndex)
            kind = .alreadyOnline
        case let .exactUUID(displayID):
            records[recordIndex].displayID = displayID
            if let restorable = DisplayConnectionRecoveryResolver
                .restorableRecoveryCapabilityForExactQuarantine(
                    uuid: uuid,
                    observation: observation
                ) {
                records[recordIndex].recoveryCapability = restorable.changingState(to: .available)
            } else {
                records[recordIndex].recoveryCapability = nil
            }
            kind = .reconciledOffline
        case let .oneShotRecovery(capability):
            guard records[recordIndex].recoveryCapability == capability else { return nil }
            records[recordIndex].recoveryCapability = capability.changingState(to: .available)
            kind = .reconciledOffline
        case .unavailable:
            return nil
        }

        var pending = current.pendingSet
        pending.remove(uuid)
        var reservations = current.reconnectReservationSet
        reservations.remove(uuid)
        var uncertain = current.reconnectPersistenceUncertainSet
        uncertain.remove(uuid)
        return DisplayReconnectQuarantineTransition(
            kind: kind,
            proposedState: DisplayConnectionPersistenceEnvelope(
                records: records,
                pendingUUIDs: pending,
                reconnectReservationUUIDs: reservations,
                reconnectPersistenceUncertainUUIDs: uncertain
            )
        )
    }
}

public struct ConnectionMetadataTransition: Equatable, Sendable {
    public let proposedState: DisplayConnectionPersistenceEnvelope
    public let affectedUUIDs: Set<String>

    public init(
        proposedState: DisplayConnectionPersistenceEnvelope,
        affectedUUIDs: Set<String>
    ) {
        self.proposedState = proposedState
        self.affectedUUIDs = affectedUUIDs
    }
}

public enum ConnectionMetadataReconciler {
    public static func transition(
        snapshot: DisplayConnectionPersistenceSnapshot,
        observation: DisplayConnectionObservation
    ) -> ConnectionMetadataTransition? {
        let current = snapshot.envelope
        guard snapshot.authority == .durable,
              observation.persistenceStateIsAuthoritative,
              persistenceProjectionMatches(current, observation: observation),
              DisplayConnectionRecoveryResolver.inventoryIsConsistent(observation) else {
            return nil
        }

        var records = current.records
        var pending = current.pendingSet
        var reservations = current.reconnectReservationSet
        var uncertain = current.reconnectPersistenceUncertainSet
        var removedUUIDs: Set<String> = []
        var confirmedUUIDs: Set<String> = []

        for record in current.records {
            if DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
                uuid: record.uuid,
                observation: observation
            ) != nil {
                removedUUIDs.insert(record.uuid)
                continue
            }
            guard pending.contains(record.uuid),
                  !uncertain.contains(record.uuid) else { continue }
            let exactCandidates = observation.candidates.filter {
                $0.stableUUID == record.uuid
            }
            let exactOffline = exactCandidates.count == 1
                && exactCandidates[0].isHardwareBackedPhysical
                && !exactCandidates[0].isOnline
            let retainedOffline = record.recoveryCapability.map {
                DisplayConnectionRecoveryResolver.authorizesOfflineConfirmation(
                    $0,
                    observation: observation
                )
            } ?? false
            if exactOffline || retainedOffline {
                confirmedUUIDs.insert(record.uuid)
            }
        }

        guard !removedUUIDs.isEmpty || !confirmedUUIDs.isEmpty else { return nil }
        records.removeAll { removedUUIDs.contains($0.uuid) }
        pending.subtract(removedUUIDs)
        reservations.subtract(removedUUIDs)
        uncertain.subtract(removedUUIDs)

        for index in records.indices where confirmedUUIDs.contains(records[index].uuid) {
            pending.remove(records[index].uuid)
            if let capability = records[index].recoveryCapability,
               capability.state == .prepared {
                records[index].recoveryCapability = capability.changingState(to: .available)
            }
        }
        return ConnectionMetadataTransition(
            proposedState: DisplayConnectionPersistenceEnvelope(
                records: records,
                pendingUUIDs: pending,
                reconnectReservationUUIDs: reservations,
                reconnectPersistenceUncertainUUIDs: uncertain
            ),
            affectedUUIDs: removedUUIDs.union(confirmedUUIDs)
        )
    }

    private static func persistenceProjectionMatches(
        _ envelope: DisplayConnectionPersistenceEnvelope,
        observation: DisplayConnectionObservation
    ) -> Bool {
        Set(envelope.records.map(\.uuid)) == observation.intentionalDisconnectedUUIDs
            && envelope.pendingSet == observation.pendingDisconnectUUIDs
            && envelope.reconnectReservationSet == observation.reconnectReservationUUIDs
            && envelope.reconnectPersistenceUncertainSet
                == observation.reconnectPersistenceUncertainUUIDs
            && envelope.records.compactMap(\.recoveryCapability)
                == observation.recoveryCapabilities
    }
}
