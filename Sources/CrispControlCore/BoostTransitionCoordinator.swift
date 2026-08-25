import Foundation

public enum BoostTransitionPhase: String, Equatable, Sendable {
    case enabling
    case enabled
    case collapsing
    case disabled
}

/// App-control outcome at the boundary where a legacy Boolean completion is
/// reconciled with fresh same-display state. Cancellation is intentionally not
/// represented here: it continues to throw so the dispatcher reports an
/// indeterminate write.
public enum ExtraBrightnessControlMutationOutcome: Equatable, Sendable {
    case rejectedBeforeAcceptance
    case accepted
    case settling
    case indeterminate

    public static func classify(
        mutationAccepted: Bool,
        operationCompleted: Bool,
        identityMatches: Bool,
        persistedEnabled: Bool,
        liveEnabled: Bool,
        maxBrightness: Double,
        cleanupInProgress: Bool
    ) -> Self {
        guard mutationAccepted else { return .rejectedBeforeAcceptance }
        guard identityMatches else { return .indeterminate }
        if operationCompleted { return .accepted }
        guard !persistedEnabled else { return .indeterminate }
        guard cleanupInProgress else { return .indeterminate }
        return .settling
    }

    public func resolvedControlResult(
        capability: @autoclosure () -> ExtraBrightnessCapability
    ) throws -> ExtraBrightnessSetResult? {
        switch self {
        case .rejectedBeforeAcceptance:
            throw ControlServiceError.writeFailed(
                "Extra Brightness request was rejected by the live app service"
            )
        case .indeterminate:
            throw ControlServiceError.writeIndeterminate(
                "Extra Brightness was accepted but terminal app state is unknown; "
                    + "read back before another write"
            )
        case .settling:
            return ExtraBrightnessSetResult(
                capability: capability(),
                verification: .settling,
                warnings: [
                    "Extra Brightness disable was accepted and persisted off, "
                        + "but terminal app/overlay cleanup is still settling"
                ]
            )
        case .accepted:
            return nil
        }
    }
}

public struct BoostTransitionToken: Equatable, Sendable {
    public let uuid: String
    public let identity: String
    public let generation: UInt64
}

/// Generation guard shared by GUI and automation boost transitions. An opaque
/// object identity prevents a re-used display ID from accepting stale callbacks.
public struct BoostTransitionCoordinator: Sendable {
    private struct Entry: Sendable {
        var identity: String
        var generation: UInt64
        var phase: BoostTransitionPhase
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func begin(uuid: String, identity: String, enabled: Bool) -> BoostTransitionToken {
        let generation = (entries[uuid]?.generation ?? 0) &+ 1
        entries[uuid] = Entry(
            identity: identity,
            generation: generation,
            phase: enabled ? .enabling : .collapsing
        )
        return BoostTransitionToken(uuid: uuid, identity: identity, generation: generation)
    }

    public func accepts(
        _ token: BoostTransitionToken,
        currentUUID: String,
        currentIdentity: String
    ) -> Bool {
        guard token.uuid == currentUUID, token.identity == currentIdentity,
              let entry = entries[token.uuid] else { return false }
        return entry.identity == token.identity && entry.generation == token.generation
    }

    public mutating func completeEnable(_ token: BoostTransitionToken) -> Bool {
        guard accepts(token, currentUUID: token.uuid, currentIdentity: token.identity) else { return false }
        entries[token.uuid]?.phase = .enabled
        return true
    }

    public mutating func completeDisable(_ token: BoostTransitionToken, atIdentity: Bool) -> Bool {
        guard atIdentity,
              accepts(token, currentUUID: token.uuid, currentIdentity: token.identity) else { return false }
        entries[token.uuid]?.phase = .disabled
        return true
    }

    public func phase(uuid: String, identity: String) -> BoostTransitionPhase? {
        guard let entry = entries[uuid], entry.identity == identity else { return nil }
        return entry.phase
    }

    public func headroomMaySync(uuid: String, identity: String) -> Bool {
        phase(uuid: uuid, identity: identity) != .collapsing
    }

    public mutating func invalidate(uuid: String, identity: String) {
        guard entries[uuid]?.identity == identity else { return }
        entries.removeValue(forKey: uuid)
    }
}
