import Foundation

public enum DisplayConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case disconnected
}

public enum DisplayConnectionVerificationQuality: String, Codable, Equatable, Sendable {
    case sameUUIDEnumeration = "same_uuid_enumeration"
    case retainedBindingHardwareContinuity = "retained_binding_hardware_continuity"
}

public struct DisplayConnectionSetResult: Codable, Equatable, Sendable {
    public let displayUUID: String
    public let requestedConnectionState: DisplayConnectionState
    public let observedConnectionState: DisplayConnectionState
    public let verification: DisplayConnectionVerificationQuality
    public let warnings: [String]

    public init(
        displayUUID: String,
        requestedConnectionState: DisplayConnectionState,
        observedConnectionState: DisplayConnectionState,
        verification: DisplayConnectionVerificationQuality,
        warnings: [String] = []
    ) {
        self.displayUUID = displayUUID
        self.requestedConnectionState = requestedConnectionState
        self.observedConnectionState = observedConnectionState
        self.verification = verification
        self.warnings = warnings
    }
}

public struct DisplayConnectionTarget: Equatable, Sendable {
    public let uuid: String
    public let displayID: UInt32?
    public let name: String
    public let width: Int
    public let height: Int
    public let isHardwareBackedPhysical: Bool

    public init(
        uuid: String,
        displayID: UInt32? = nil,
        name: String,
        width: Int,
        height: Int,
        isHardwareBackedPhysical: Bool
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.name = name
        self.width = width
        self.height = height
        self.isHardwareBackedPhysical = isHardwareBackedPhysical
    }
}

public struct DisplayConnectionObservation: Equatable, Sendable {
    public let platformSupported: Bool
    public let allUUIDs: Set<String>
    public let onlineUUIDs: Set<String>
    public let intentionalDisconnectedUUIDs: Set<String>
    public let pendingDisconnectUUIDs: Set<String>
    public let reconnectReservationUUIDs: Set<String>
    public let reconnectPersistenceUncertainUUIDs: Set<String>
    public let persistenceStateIsAuthoritative: Bool
    public let virtualUUIDs: Set<String>
    public let activePhysicalViewableUUIDs: Set<String>
    public let candidates: [DisplayConnectionCandidate]
    public let recoveryCapabilities: [DisplayConnectionRecoveryCapability]
    public let bootSessionID: String?
    public let loginSessionID: String?
    public let wakeSessionID: String?
    public let topologyFingerprint: String?

    public init(
        platformSupported: Bool,
        allUUIDs: Set<String>,
        onlineUUIDs: Set<String>,
        intentionalDisconnectedUUIDs: Set<String>,
        pendingDisconnectUUIDs: Set<String> = [],
        reconnectReservationUUIDs: Set<String> = [],
        reconnectPersistenceUncertainUUIDs: Set<String> = [],
        persistenceStateIsAuthoritative: Bool = true,
        virtualUUIDs: Set<String>,
        activePhysicalViewableUUIDs: Set<String>,
        candidates: [DisplayConnectionCandidate] = [],
        recoveryCapabilities: [DisplayConnectionRecoveryCapability] = [],
        bootSessionID: String? = nil,
        loginSessionID: String? = nil,
        wakeSessionID: String? = nil,
        topologyFingerprint: String? = nil
    ) {
        self.platformSupported = platformSupported
        self.allUUIDs = allUUIDs
        self.onlineUUIDs = onlineUUIDs
        self.intentionalDisconnectedUUIDs = intentionalDisconnectedUUIDs
        self.pendingDisconnectUUIDs = pendingDisconnectUUIDs
        self.reconnectReservationUUIDs = reconnectReservationUUIDs
        self.reconnectPersistenceUncertainUUIDs = reconnectPersistenceUncertainUUIDs
        self.persistenceStateIsAuthoritative = persistenceStateIsAuthoritative
        self.virtualUUIDs = virtualUUIDs
        self.activePhysicalViewableUUIDs = activePhysicalViewableUUIDs
        self.candidates = candidates
        self.recoveryCapabilities = recoveryCapabilities
        self.bootSessionID = bootSessionID
        self.loginSessionID = loginSessionID
        self.wakeSessionID = wakeSessionID
        self.topologyFingerprint = topologyFingerprint
    }

    public init(
        persistenceSnapshot: DisplayConnectionPersistenceSnapshot,
        platformSupported: Bool,
        allUUIDs: Set<String>,
        onlineUUIDs: Set<String>,
        virtualUUIDs: Set<String>,
        activePhysicalViewableUUIDs: Set<String>,
        candidates: [DisplayConnectionCandidate] = [],
        bootSessionID: String? = nil,
        loginSessionID: String? = nil,
        wakeSessionID: String? = nil,
        topologyFingerprint: String? = nil
    ) {
        let envelope = persistenceSnapshot.envelope
        self.init(
            platformSupported: platformSupported,
            allUUIDs: allUUIDs,
            onlineUUIDs: onlineUUIDs,
            intentionalDisconnectedUUIDs: Set(envelope.records.map(\.uuid)),
            pendingDisconnectUUIDs: envelope.pendingSet,
            reconnectReservationUUIDs: envelope.reconnectReservationSet,
            reconnectPersistenceUncertainUUIDs: envelope.reconnectPersistenceUncertainSet,
            persistenceStateIsAuthoritative: persistenceSnapshot.authority == .durable,
            virtualUUIDs: virtualUUIDs,
            activePhysicalViewableUUIDs: activePhysicalViewableUUIDs,
            candidates: candidates,
            recoveryCapabilities: envelope.records.compactMap(\.recoveryCapability),
            bootSessionID: bootSessionID,
            loginSessionID: loginSessionID,
            wakeSessionID: wakeSessionID,
            topologyFingerprint: topologyFingerprint
        )
    }
}

public enum DisplayConnectionDispatchOutcome: Equatable, Sendable {
    case completed
    case rejectedBeforeDispatch(String)
    case failedAfterDispatch(String)
    case timedOut
    case cancelled
}

public enum DisplayConnectionFailureClassification: String, Equatable, Sendable {
    case preflightRejected = "preflight_rejected"
    case definiteFailure = "definite_failure"
    case indeterminate
}

public enum DisplayReconnectOrphanReconciliation: Equatable, Sendable {
    case reconciled
    case alreadyOnline
    case liveAttempt
    case unavailable
}

public enum DisplayReconnectQuarantineReconciliation: Equatable, Sendable {
    case reconciled
    case alreadyOnline
    case liveAttempt
    case unavailable
}

public struct DisplayConnectionMutationError: Error, Equatable, Sendable {
    public let classification: DisplayConnectionFailureClassification
    public let displayUUID: String
    public let requestedConnectionState: DisplayConnectionState
    public let mutationDispatched: Bool
    public let message: String

    public var retrySafe: Bool { classification != .indeterminate }

    public init(
        classification: DisplayConnectionFailureClassification,
        displayUUID: String,
        requestedConnectionState: DisplayConnectionState,
        mutationDispatched: Bool? = nil,
        message: String
    ) {
        self.classification = classification
        self.displayUUID = displayUUID
        self.requestedConnectionState = requestedConnectionState
        self.mutationDispatched = mutationDispatched ?? (classification == .indeterminate)
        self.message = message
    }
}

@MainActor
public protocol DisplayConnectionMutationAdapter: AnyObject {
    func connectionObservation() throws -> DisplayConnectionObservation
    func retainDisconnectedRecord(
        _ target: DisplayConnectionTarget
    ) throws -> DisplayConnectionRecoveryCapability?
    func confirmDisconnectedRecord(uuid: String) throws
    func removeDisconnectedRecord(uuid: String) throws
    func consumeRecoveryCapability(
        _ capability: DisplayConnectionRecoveryCapability
    ) throws -> DisplayConnectionRecoveryCapability
    func reserveReconnect(uuid: String) throws
    func releaseReconnectReservation(uuid: String) throws
    func rollbackRejectedReconnectBeforeDispatch(
        uuid: String,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
    ) throws
    func reconcileOrphanedReconnectAttempt(
        uuid: String
    ) throws -> DisplayReconnectOrphanReconciliation
    func reconcileQuarantinedReconnectAttempt(
        uuid: String
    ) async throws -> DisplayReconnectQuarantineReconciliation
    func finishQuarantinedReconnectAttempt(uuid: String)
    func markReconnectAttemptIndeterminate(uuid: String) throws
    func markRecoveryCapabilityIndeterminate(uuid: String) throws
    func dispatchConnectionChange(
        _ request: DisplayConnectionDispatchRequest
    ) async -> DisplayConnectionDispatchOutcome
}

@MainActor
public struct DisplayConnectionMutationCoordinator {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let adapter: any DisplayConnectionMutationAdapter
    private let settlementAttempts: Int
    private let settlementInterval: Duration
    private let sleep: Sleep

    public init(
        adapter: any DisplayConnectionMutationAdapter,
        settlementAttempts: Int = 20,
        settlementInterval: Duration = .milliseconds(100),
        sleep: @escaping Sleep = { duration in try await Task.sleep(for: duration) }
    ) {
        self.adapter = adapter
        self.settlementAttempts = max(1, settlementAttempts)
        self.settlementInterval = settlementInterval
        self.sleep = sleep
    }

    public func disconnect(_ target: DisplayConnectionTarget) async throws -> DisplayConnectionSetResult {
        let requestedState = DisplayConnectionState.disconnected
        let initial = try preflightObservation(uuid: target.uuid, requestedState: requestedState)
        try requireStableUUID(target.uuid, requestedState: requestedState)
        try require(initial.platformSupported, uuid: target.uuid, state: requestedState,
                    message: "physical display disconnect requires Apple Silicon and macOS 13 or later")
        let exactCandidates = initial.candidates.filter { $0.stableUUID == target.uuid }
        try require(exactCandidates.count == 1, uuid: target.uuid, state: requestedState,
                    message: "target UUID did not resolve to exactly one display")
        guard let exactCandidate = exactCandidates.first else {
            throw failure(
                .preflightRejected, uuid: target.uuid, state: requestedState,
                message: "target UUID did not resolve to exactly one display"
            )
        }
        try require(
            target.displayID == nil || target.displayID == exactCandidate.displayID,
            uuid: target.uuid,
            state: requestedState,
            message: "target display ID changed before disconnect"
        )
        try require(
            target.isHardwareBackedPhysical
                && exactCandidate.isHardwareBackedPhysical
                && !initial.virtualUUIDs.contains(target.uuid),
                    uuid: target.uuid, state: requestedState,
                    message: "target cannot be positively proven as a hardware-backed physical display"
        )
        try require(
            exactCandidate.isOnline
                && initial.allUUIDs.contains(target.uuid)
                && initial.onlineUUIDs.contains(target.uuid),
                    uuid: target.uuid, state: requestedState,
                    message: "target UUID is no longer present in the fresh online inventory"
        )
        try require(!initial.intentionalDisconnectedUUIDs.contains(target.uuid),
                    uuid: target.uuid, state: requestedState,
                    message: "target UUID already has an intentional-disconnected record")
        try require(
            initial.activePhysicalViewableUUIDs.contains(target.uuid)
                && initial.activePhysicalViewableUUIDs.count > 1,
            uuid: target.uuid,
            state: requestedState,
            message: "refusing to disconnect the last active physical viewable display"
        )

        let retainedCapabilityCandidate: DisplayConnectionRecoveryCapability?
        do {
            retainedCapabilityCandidate = try adapter.retainDisconnectedRecord(target)
        } catch {
            do {
                try adapter.removeDisconnectedRecord(uuid: target.uuid)
            } catch {
                throw failure(
                    .definiteFailure, uuid: target.uuid, state: requestedState,
                    message: "recovery state retention failed and partial state could not be cleaned up"
                )
            }
            throw failure(
                .definiteFailure, uuid: target.uuid, state: requestedState,
                message: "could not retain UUID-scoped recovery state before mutation"
            )
        }
        guard let retainedCapability = retainedCapabilityCandidate,
              DisplayConnectionRecoveryResolver.authorizesPreparedDisconnectCapability(
                retainedCapability,
                uuid: target.uuid,
                displayID: exactCandidate.displayID,
                observation: initial
              ) else {
            do {
                try adapter.removeDisconnectedRecord(uuid: target.uuid)
            } catch {
                throw failure(
                    .definiteFailure, uuid: target.uuid, state: requestedState,
                    message: "incomplete recovery capability could not be cleaned up before mutation"
                )
            }
            throw failure(
                .preflightRejected, uuid: target.uuid, state: requestedState,
                message: "disconnect requires a complete persisted recovery capability"
            )
        }

        let request = DisplayConnectionDispatchRequest(
            uuid: target.uuid,
            displayID: exactCandidate.displayID,
            requestedState: requestedState,
            authorization: .exactUUID
        )
        switch await adapter.dispatchConnectionChange(request) {
        case .completed:
            break
        case let .rejectedBeforeDispatch(message):
            do {
                try adapter.removeDisconnectedRecord(uuid: target.uuid)
            } catch {
                throw failure(
                    .definiteFailure, uuid: target.uuid, state: requestedState,
                    message: "\(message); the recovery record could not be cleaned up"
                )
            }
            throw failure(.definiteFailure, uuid: target.uuid, state: requestedState, message: message)
        case let .failedAfterDispatch(message):
            markRecoveryIndeterminate(uuid: target.uuid)
            throw failure(.indeterminate, uuid: target.uuid, state: requestedState, message: message)
        case .timedOut:
            markRecoveryIndeterminate(uuid: target.uuid)
            throw failure(
                .indeterminate, uuid: target.uuid, state: requestedState,
                message: "display configuration timed out after dispatch and may still complete"
            )
        case .cancelled:
            markRecoveryIndeterminate(uuid: target.uuid)
            throw failure(
                .indeterminate, uuid: target.uuid, state: requestedState,
                message: "display configuration wait was cancelled after dispatch"
            )
        }

        for attempt in 0..<settlementAttempts {
            let observation = try postDispatchObservation(uuid: target.uuid, state: requestedState)
            let exactOffline = observation.candidates.filter {
                $0.stableUUID == target.uuid
            }
            let hasExactOfflineTruth = exactOffline.count == 1
                && exactOffline[0].isHardwareBackedPhysical
                && !exactOffline[0].isOnline
                && observation.intentionalDisconnectedUUIDs.contains(target.uuid)
            let hasRetainedOfflineTruth = DisplayConnectionRecoveryResolver
                .authorizesOfflineConfirmation(retainedCapability, observation: observation)
            if hasExactOfflineTruth || hasRetainedOfflineTruth {
                do {
                    try adapter.confirmDisconnectedRecord(uuid: target.uuid)
                } catch {
                    throw failure(
                        .indeterminate, uuid: target.uuid, state: requestedState,
                        message: "same-UUID offline truth was observed but recovery state could not be confirmed"
                    )
                }
                return success(
                    uuid: target.uuid,
                    state: requestedState,
                    verification: hasExactOfflineTruth
                        ? .sameUUIDEnumeration
                        : .retainedBindingHardwareContinuity
                )
            }
            try await pauseIfNeeded(after: attempt, uuid: target.uuid, state: requestedState)
        }
        markRecoveryIndeterminate(uuid: target.uuid)
        throw failure(
            .indeterminate, uuid: target.uuid, state: requestedState,
            message: "same-UUID offline and retained-record truth did not settle in the bounded window"
        )
    }

    public func reconnect(uuid: String) async throws -> DisplayConnectionSetResult {
        let requestedState = DisplayConnectionState.connected
        try requireStableUUID(uuid, requestedState: requestedState)
        let initial = try preflightObservation(uuid: uuid, requestedState: requestedState)
        try require(initial.platformSupported, uuid: uuid, state: requestedState,
                    message: "physical display reconnect requires Apple Silicon and macOS 13 or later")
        try require(initial.intentionalDisconnectedUUIDs.contains(uuid),
                    uuid: uuid, state: requestedState,
                    message: "UUID is absent from the fresh intentional-disconnected inventory")

        if let result = try await reconcileQuarantineIfNeeded(
            uuid: uuid,
            state: requestedState,
            initial: initial
        ) {
            return result
        }

        return try await reconnectAfterQuarantinePreflight(
            uuid: uuid,
            state: requestedState,
            initial: initial
        )
    }

    private func reconnectAfterQuarantinePreflight(
        uuid: String,
        state requestedState: DisplayConnectionState,
        initial: DisplayConnectionObservation
    ) async throws -> DisplayConnectionSetResult {
        let resolution = DisplayConnectionRecoveryResolver.reconnectResolution(
            uuid: uuid,
            observation: initial
        )
        if initial.reconnectReservationUUIDs.contains(uuid) {
            let reconciliation: DisplayReconnectOrphanReconciliation
            do {
                reconciliation = try adapter.reconcileOrphanedReconnectAttempt(uuid: uuid)
            } catch {
                throw failure(
                    .indeterminate, uuid: uuid, state: requestedState,
                    mutationDispatched: false,
                    message: "the prior reconnect attempt's display-write outcome is unknown; "
                        + "fresh read-back and persisted recovery reconciliation could not be "
                        + "verified, so no display write was issued"
                )
            }
            switch reconciliation {
            case .reconciled:
                throw failure(
                    .indeterminate, uuid: uuid, state: requestedState,
                    mutationDispatched: false,
                    message: "the prior reconnect attempt's display-write outcome is unknown; "
                        + "fresh read-back still proves this display offline, so no display write "
                        + "was issued and a fresh explicit user decision is required before "
                        + "another reconnect"
                )
            case .alreadyOnline:
                return try cleanAlreadyOnlineRecoveryState(uuid: uuid, state: requestedState)
            case .liveAttempt:
                throw failure(
                    .preflightRejected, uuid: uuid, state: requestedState,
                    message: "another reconnect attempt still owns the persisted reservation"
                )
            case .unavailable:
                throw failure(
                    .indeterminate, uuid: uuid, state: requestedState,
                    mutationDispatched: false,
                    message: "the prior reconnect attempt's display-write outcome remains unknown; "
                        + "fresh exact-UUID or recovery-continuity proof was insufficient, so "
                        + "the reservation was retained and no display write was issued"
                )
            }
        }
        if case .alreadyOnline = resolution {
            return try cleanAlreadyOnlineRecoveryState(uuid: uuid, state: requestedState)
        }

        do {
            try adapter.reserveReconnect(uuid: uuid)
        } catch {
            throw failure(
                .preflightRejected, uuid: uuid, state: requestedState,
                message: "another reconnect attempt is already reserved or reservation could not persist"
            )
        }

        let dispatchPlan: (
            request: DisplayConnectionDispatchRequest,
            consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
        )
        do {
            dispatchPlan = try reconnectDispatchPlan(
                uuid: uuid,
                state: requestedState,
                resolution: resolution
            )
        } catch {
            try releaseReconnectReservationAndVerify(uuid: uuid, state: requestedState)
            throw error
        }
        try requireReconnectDispatchCompletion(
            await adapter.dispatchConnectionChange(dispatchPlan.request),
            uuid: uuid,
            state: requestedState,
            consumedRecoveryCapability: dispatchPlan.consumedRecoveryCapability
        )

        for attempt in 0..<settlementAttempts {
            let observation = try postReconnectObservation(uuid: uuid, state: requestedState)
            if DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
                uuid: uuid,
                observation: observation
            ) != nil {
                if recoveryStateIsAbsent(uuid: uuid, observation: observation) {
                    return success(uuid: uuid, state: requestedState)
                }
                do {
                    try adapter.removeDisconnectedRecord(uuid: uuid)
                    let final = try postReconnectObservation(uuid: uuid, state: requestedState)
                    guard DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
                        uuid: uuid,
                        observation: final
                    ) != nil, recoveryStateIsAbsent(uuid: uuid, observation: final) else {
                        throw failure(
                            .indeterminate, uuid: uuid, state: requestedState,
                            message: "online UUID was observed but record removal could not be verified"
                        )
                    }
                    return success(uuid: uuid, state: requestedState)
                } catch let error as DisplayConnectionMutationError {
                    throw error
                } catch {
                    throw failure(
                        .indeterminate, uuid: uuid, state: requestedState,
                        message: "online UUID was observed but its recovery record could not be removed"
                    )
                }
            }
            try await pauseAfterReconnectIfNeeded(
                after: attempt,
                uuid: uuid,
                state: requestedState
            )
        }
        markReconnectIndeterminate(uuid: uuid)
        throw failure(
            .indeterminate, uuid: uuid, state: requestedState,
            message: "same-UUID online truth did not settle in the bounded window"
        )
    }

    private func reconcileQuarantineIfNeeded(
        uuid: String,
        state: DisplayConnectionState,
        initial: DisplayConnectionObservation
    ) async throws -> DisplayConnectionSetResult? {
        guard initial.reconnectPersistenceUncertainUUIDs.contains(uuid) else { return nil }
        let reconciliation: DisplayReconnectQuarantineReconciliation
        do {
            reconciliation = try await adapter.reconcileQuarantinedReconnectAttempt(uuid: uuid)
        } catch {
            adapter.finishQuarantinedReconnectAttempt(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                mutationDispatched: false,
                message: "quarantined reconnect recovery could not be atomically persisted "
                    + "and verified, so no display write was issued"
            )
        }
        switch reconciliation {
        case .reconciled:
            adapter.finishQuarantinedReconnectAttempt(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                mutationDispatched: false,
                message: "fresh read-back still proves this quarantined display offline; "
                    + "recovery metadata was reconciled with zero display writes, and a fresh "
                    + "explicit user decision is required before another reconnect"
            )
        case .alreadyOnline:
            defer { adapter.finishQuarantinedReconnectAttempt(uuid: uuid) }
            let final: DisplayConnectionObservation
            do {
                try Task.checkCancellation()
                final = try adapter.connectionObservation()
            } catch is CancellationError {
                throw failure(
                    .indeterminate, uuid: uuid, state: state,
                    mutationDispatched: false,
                    message: "metadata cleanup occurred but the final exact-online proof or "
                        + "decision was cancelled, so no display write was issued"
                )
            } catch {
                throw failure(
                    .indeterminate, uuid: uuid, state: state,
                    mutationDispatched: false,
                    message: "metadata cleanup occurred but final exact-online proof could not "
                        + "be verified, so no display write was issued"
                )
            }
            guard DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
                uuid: uuid,
                observation: final
            ) != nil, recoveryStateIsAbsent(uuid: uuid, observation: final) else {
                throw failure(
                    .indeterminate, uuid: uuid, state: state,
                    mutationDispatched: false,
                    message: "metadata cleanup occurred but final exact-online proof could not "
                        + "be verified, so no display write was issued"
                )
            }
            do {
                try Task.checkCancellation()
            } catch {
                throw failure(
                    .indeterminate, uuid: uuid, state: state,
                    mutationDispatched: false,
                    message: "metadata cleanup occurred but the final exact-online proof or "
                        + "decision was cancelled, so no display write was issued"
                )
            }
            return success(uuid: uuid, state: state)
        case .liveAttempt:
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                mutationDispatched: false,
                message: "another explicit request is reconciling this quarantined reconnect; "
                    + "no display write was issued"
            )
        case .unavailable:
            adapter.finishQuarantinedReconnectAttempt(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                mutationDispatched: false,
                message: "quarantined reconnect recovery lacks fresh exact-UUID or strict "
                    + "same-session hardware proof; quarantine was retained and no display "
                    + "write was issued"
            )
        }
    }

    private func reconnectDispatchPlan(
        uuid: String,
        state: DisplayConnectionState,
        resolution: DisplayConnectionReconnectResolution
    ) throws -> (
        request: DisplayConnectionDispatchRequest,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
    ) {
        switch resolution {
        case .alreadyOnline:
            preconditionFailure("already-online recovery should have returned")
        case let .exactUUID(displayID):
            return (
                DisplayConnectionDispatchRequest(
                    uuid: uuid,
                    displayID: displayID,
                    requestedState: state,
                    authorization: .exactUUID
                ),
                nil
            )
        case let .oneShotRecovery(capability):
            let consumed: DisplayConnectionRecoveryCapability
            do {
                consumed = try adapter.consumeRecoveryCapability(capability)
            } catch {
                throw failure(
                    .preflightRejected, uuid: uuid, state: state,
                    message: "one-shot recovery capability could not be consumed and verified"
                )
            }
            try require(
                consumed == capability.changingState(to: .consumed),
                uuid: uuid,
                state: state,
                message: "one-shot recovery capability consumption did not persist exactly"
            )
            return (
                DisplayConnectionDispatchRequest(
                    uuid: uuid,
                    displayID: capability.displayID,
                    requestedState: state,
                    authorization: .oneShotRecovery
                ),
                consumed
            )
        case .unavailable:
            throw failure(
                .preflightRejected, uuid: uuid, state: state,
                message: "disconnected UUID has no unique safe reconnect resolution"
            )
        }
    }

    private func requireReconnectDispatchCompletion(
        _ outcome: DisplayConnectionDispatchOutcome,
        uuid: String,
        state: DisplayConnectionState,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
    ) throws {
        switch outcome {
        case .completed:
            return
        case let .rejectedBeforeDispatch(message):
            do {
                try adapter.rollbackRejectedReconnectBeforeDispatch(
                    uuid: uuid,
                    consumedRecoveryCapability: consumedRecoveryCapability
                )
            } catch {
                throw failure(
                    .indeterminate,
                    uuid: uuid,
                    state: state,
                    mutationDispatched: false,
                    message: "\(message); zero display dispatch is known but the reconnect "
                        + "reservation rollback could not be atomically persisted and verified"
                )
            }
            throw failure(.definiteFailure, uuid: uuid, state: state, message: message)
        case let .failedAfterDispatch(message):
            markReconnectIndeterminate(uuid: uuid)
            throw failure(.indeterminate, uuid: uuid, state: state, message: message)
        case .timedOut:
            markReconnectIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                message: "display configuration timed out after dispatch and may still complete"
            )
        case .cancelled:
            markReconnectIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                message: "display configuration wait was cancelled after dispatch"
            )
        }
    }

    private func cleanAlreadyOnlineRecoveryState(
        uuid: String,
        state: DisplayConnectionState
    ) throws -> DisplayConnectionSetResult {
        do {
            try adapter.removeDisconnectedRecord(uuid: uuid)
            let final = try adapter.connectionObservation()
            guard DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
                uuid: uuid,
                observation: final
            ) != nil, recoveryStateIsAbsent(uuid: uuid, observation: final) else {
                throw failure(
                    .definiteFailure, uuid: uuid, state: state,
                    message: "online UUID recovery-state cleanup could not be verified"
                )
            }
            return success(uuid: uuid, state: state)
        } catch let error as DisplayConnectionMutationError {
            throw error
        } catch {
            throw failure(
                .definiteFailure, uuid: uuid, state: state,
                message: "online UUID recovery state could not be removed"
            )
        }
    }

    private func recoveryStateIsAbsent(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> Bool {
        !observation.intentionalDisconnectedUUIDs.contains(uuid)
            && !observation.pendingDisconnectUUIDs.contains(uuid)
            && !observation.reconnectReservationUUIDs.contains(uuid)
            && !observation.reconnectPersistenceUncertainUUIDs.contains(uuid)
            && !observation.recoveryCapabilities.contains { $0.uuid == uuid }
    }

    private func releaseReconnectReservationAndVerify(
        uuid: String,
        state: DisplayConnectionState
    ) throws {
        let observation: DisplayConnectionObservation
        do {
            try adapter.releaseReconnectReservation(uuid: uuid)
            observation = try adapter.connectionObservation()
        } catch {
            markReconnectIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                mutationDispatched: false,
                message: "zero display dispatch is known but reconnect reservation release could not be verified"
            )
        }
        guard !observation.reconnectReservationUUIDs.contains(uuid) else {
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                mutationDispatched: false,
                message: "zero display dispatch is known but reconnect reservation remained persisted"
            )
        }
    }

    private func preflightObservation(
        uuid: String,
        requestedState: DisplayConnectionState
    ) throws -> DisplayConnectionObservation {
        do {
            try Task.checkCancellation()
            return try adapter.connectionObservation()
        } catch {
            throw failure(
                .preflightRejected, uuid: uuid, state: requestedState,
                message: "fresh display enumeration failed before mutation"
            )
        }
    }

    private func postDispatchObservation(
        uuid: String,
        state: DisplayConnectionState
    ) throws -> DisplayConnectionObservation {
        do {
            try Task.checkCancellation()
            return try adapter.connectionObservation()
        } catch {
            markRecoveryIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                message: "fresh display enumeration could not prove the post-mutation state"
            )
        }
    }

    private func postReconnectObservation(
        uuid: String,
        state: DisplayConnectionState
    ) throws -> DisplayConnectionObservation {
        do {
            try Task.checkCancellation()
            return try adapter.connectionObservation()
        } catch {
            markReconnectIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                message: "fresh display enumeration could not prove the post-mutation state"
            )
        }
    }

    private func pauseIfNeeded(
        after attempt: Int,
        uuid: String,
        state: DisplayConnectionState
    ) async throws {
        guard attempt + 1 < settlementAttempts else { return }
        do {
            try await sleep(settlementInterval)
        } catch {
            markRecoveryIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                message: "post-mutation settlement wait was cancelled"
            )
        }
    }

    private func pauseAfterReconnectIfNeeded(
        after attempt: Int,
        uuid: String,
        state: DisplayConnectionState
    ) async throws {
        guard attempt + 1 < settlementAttempts else { return }
        do {
            try await sleep(settlementInterval)
        } catch {
            markReconnectIndeterminate(uuid: uuid)
            throw failure(
                .indeterminate, uuid: uuid, state: state,
                message: "post-mutation settlement wait was cancelled"
            )
        }
    }

    private func requireStableUUID(
        _ uuid: String,
        requestedState: DisplayConnectionState
    ) throws {
        let characters = Array(uuid)
        let exactShape = uuid.utf8.count == 36
            && UUID(uuidString: uuid) != nil
            && [8, 13, 18, 23].allSatisfy { characters.indices.contains($0) && characters[$0] == "-" }
        try require(
            exactShape,
            uuid: uuid,
            state: requestedState,
            message: "an exact stable UUID from a fresh inventory is required"
        )
    }

    private func require(
        _ condition: @autoclosure () -> Bool,
        uuid: String,
        state: DisplayConnectionState,
        message: String
    ) throws {
        guard condition() else {
            throw failure(.preflightRejected, uuid: uuid, state: state, message: message)
        }
    }

    private func success(
        uuid: String,
        state: DisplayConnectionState,
        verification: DisplayConnectionVerificationQuality = .sameUUIDEnumeration
    ) -> DisplayConnectionSetResult {
        DisplayConnectionSetResult(
            displayUUID: uuid,
            requestedConnectionState: state,
            observedConnectionState: state,
            verification: verification
        )
    }

    private func markRecoveryIndeterminate(uuid: String) {
        try? adapter.markRecoveryCapabilityIndeterminate(uuid: uuid)
    }

    private func markReconnectIndeterminate(uuid: String) {
        try? adapter.markReconnectAttemptIndeterminate(uuid: uuid)
    }

    private func failure(
        _ classification: DisplayConnectionFailureClassification,
        uuid: String,
        state: DisplayConnectionState,
        mutationDispatched: Bool? = nil,
        message: String
    ) -> DisplayConnectionMutationError {
        DisplayConnectionMutationError(
            classification: classification,
            displayUUID: uuid,
            requestedConnectionState: state,
            mutationDispatched: mutationDispatched,
            message: message
        )
    }
}
