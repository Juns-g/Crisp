import Foundation

public enum DisplayConnectionState: String, Codable, Equatable, Sendable {
    case connected
    case disconnected
}

public enum DisplayConnectionVerificationQuality: String, Codable, Equatable, Sendable {
    case sameUUIDEnumeration = "same_uuid_enumeration"
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
    public let name: String
    public let width: Int
    public let height: Int
    public let isHardwareBackedPhysical: Bool

    public init(
        uuid: String,
        name: String,
        width: Int,
        height: Int,
        isHardwareBackedPhysical: Bool
    ) {
        self.uuid = uuid
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
    public let virtualUUIDs: Set<String>
    public let activePhysicalViewableUUIDs: Set<String>

    public init(
        platformSupported: Bool,
        allUUIDs: Set<String>,
        onlineUUIDs: Set<String>,
        intentionalDisconnectedUUIDs: Set<String>,
        virtualUUIDs: Set<String>,
        activePhysicalViewableUUIDs: Set<String>
    ) {
        self.platformSupported = platformSupported
        self.allUUIDs = allUUIDs
        self.onlineUUIDs = onlineUUIDs
        self.intentionalDisconnectedUUIDs = intentionalDisconnectedUUIDs
        self.virtualUUIDs = virtualUUIDs
        self.activePhysicalViewableUUIDs = activePhysicalViewableUUIDs
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

public struct DisplayConnectionMutationError: Error, Equatable, Sendable {
    public let classification: DisplayConnectionFailureClassification
    public let displayUUID: String
    public let requestedConnectionState: DisplayConnectionState
    public let message: String

    public var retrySafe: Bool { classification != .indeterminate }

    public init(
        classification: DisplayConnectionFailureClassification,
        displayUUID: String,
        requestedConnectionState: DisplayConnectionState,
        message: String
    ) {
        self.classification = classification
        self.displayUUID = displayUUID
        self.requestedConnectionState = requestedConnectionState
        self.message = message
    }
}

@MainActor
public protocol DisplayConnectionMutationAdapter: AnyObject {
    func connectionObservation() throws -> DisplayConnectionObservation
    func retainDisconnectedRecord(_ target: DisplayConnectionTarget) throws
    func confirmDisconnectedRecord(uuid: String) throws
    func removeDisconnectedRecord(uuid: String) throws
    func dispatchConnectionChange(
        uuid: String,
        requestedState: DisplayConnectionState
    ) async -> DisplayConnectionDispatchOutcome
}

public extension DisplayConnectionMutationAdapter {
    func confirmDisconnectedRecord(uuid: String) throws {}
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
        try require(target.isHardwareBackedPhysical && !initial.virtualUUIDs.contains(target.uuid),
                    uuid: target.uuid, state: requestedState,
                    message: "target cannot be positively proven as a hardware-backed physical display")
        try require(initial.allUUIDs.contains(target.uuid) && initial.onlineUUIDs.contains(target.uuid),
                    uuid: target.uuid, state: requestedState,
                    message: "target UUID is no longer present in the fresh online inventory")
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

        do {
            try adapter.retainDisconnectedRecord(target)
        } catch {
            throw failure(
                .definiteFailure, uuid: target.uuid, state: requestedState,
                message: "could not retain UUID-scoped recovery state before mutation"
            )
        }

        switch await adapter.dispatchConnectionChange(uuid: target.uuid, requestedState: requestedState) {
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
            throw failure(.indeterminate, uuid: target.uuid, state: requestedState, message: message)
        case .timedOut:
            throw failure(
                .indeterminate, uuid: target.uuid, state: requestedState,
                message: "display configuration timed out after dispatch and may still complete"
            )
        case .cancelled:
            throw failure(
                .indeterminate, uuid: target.uuid, state: requestedState,
                message: "display configuration wait was cancelled after dispatch"
            )
        }

        for attempt in 0..<settlementAttempts {
            let observation = try postDispatchObservation(uuid: target.uuid, state: requestedState)
            if observation.allUUIDs.contains(target.uuid),
               !observation.onlineUUIDs.contains(target.uuid),
               observation.intentionalDisconnectedUUIDs.contains(target.uuid) {
                do {
                    try adapter.confirmDisconnectedRecord(uuid: target.uuid)
                } catch {
                    throw failure(
                        .indeterminate, uuid: target.uuid, state: requestedState,
                        message: "same-UUID offline truth was observed but recovery state could not be confirmed"
                    )
                }
                return success(uuid: target.uuid, state: requestedState)
            }
            try await pauseIfNeeded(after: attempt, uuid: target.uuid, state: requestedState)
        }
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
        try require(initial.allUUIDs.contains(uuid) && !initial.onlineUUIDs.contains(uuid),
                    uuid: uuid, state: requestedState,
                    message: "disconnected UUID cannot be re-resolved exactly before mutation")
        try require(!initial.virtualUUIDs.contains(uuid), uuid: uuid, state: requestedState,
                    message: "virtual displays cannot use physical reconnect")

        switch await adapter.dispatchConnectionChange(uuid: uuid, requestedState: requestedState) {
        case .completed:
            break
        case let .rejectedBeforeDispatch(message):
            throw failure(.definiteFailure, uuid: uuid, state: requestedState, message: message)
        case let .failedAfterDispatch(message):
            throw failure(.indeterminate, uuid: uuid, state: requestedState, message: message)
        case .timedOut:
            throw failure(
                .indeterminate, uuid: uuid, state: requestedState,
                message: "display configuration timed out after dispatch and may still complete"
            )
        case .cancelled:
            throw failure(
                .indeterminate, uuid: uuid, state: requestedState,
                message: "display configuration wait was cancelled after dispatch"
            )
        }

        for attempt in 0..<settlementAttempts {
            let observation = try postDispatchObservation(uuid: uuid, state: requestedState)
            if observation.allUUIDs.contains(uuid), observation.onlineUUIDs.contains(uuid) {
                if !observation.intentionalDisconnectedUUIDs.contains(uuid) {
                    return success(uuid: uuid, state: requestedState)
                }
                do {
                    try adapter.removeDisconnectedRecord(uuid: uuid)
                    let final = try postDispatchObservation(uuid: uuid, state: requestedState)
                    guard final.allUUIDs.contains(uuid), final.onlineUUIDs.contains(uuid),
                          !final.intentionalDisconnectedUUIDs.contains(uuid) else {
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
            try await pauseIfNeeded(after: attempt, uuid: uuid, state: requestedState)
        }
        throw failure(
            .indeterminate, uuid: uuid, state: requestedState,
            message: "same-UUID online truth did not settle in the bounded window"
        )
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
        state: DisplayConnectionState
    ) -> DisplayConnectionSetResult {
        DisplayConnectionSetResult(
            displayUUID: uuid,
            requestedConnectionState: state,
            observedConnectionState: state,
            verification: .sameUUIDEnumeration
        )
    }

    private func failure(
        _ classification: DisplayConnectionFailureClassification,
        uuid: String,
        state: DisplayConnectionState,
        message: String
    ) -> DisplayConnectionMutationError {
        DisplayConnectionMutationError(
            classification: classification,
            displayUUID: uuid,
            requestedConnectionState: state,
            message: message
        )
    }
}
