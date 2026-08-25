import Foundation

public enum BoostTransitionPhase: String, Equatable, Sendable {
    case enabling
    case enabled
    case collapsing
    case disabled
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
