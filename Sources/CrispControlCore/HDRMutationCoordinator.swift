import Foundation

public struct HDRMutationToken: Equatable, Sendable {
    public let uuid: String
    public let identity: String
    public let generation: UInt64
    public let requested: Bool
}

/// Tracks an HDR setter invocation separately from verified live read-back.
/// Brightness routing is exposed only after a matching, current-generation read.
public struct HDRMutationCoordinator: Sendable {
    private struct Entry: Sendable {
        let token: HDRMutationToken
        var setterInvoked: Bool
        var verified: Bool
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func begin(uuid: String, identity: String, requested: Bool) -> HDRMutationToken {
        let token = HDRMutationToken(
            uuid: uuid,
            identity: identity,
            generation: (entries[uuid]?.token.generation ?? 0) &+ 1,
            requested: requested
        )
        entries[uuid] = Entry(token: token, setterInvoked: false, verified: false)
        return token
    }

    public mutating func recordSetterInvocation(_ token: HDRMutationToken) -> Bool {
        guard entries[token.uuid]?.token == token else { return false }
        entries[token.uuid]?.setterInvoked = true
        return true
    }

    public mutating func observe(
        _ token: HDRMutationToken,
        currentUUID: String,
        currentIdentity: String,
        readback: Bool
    ) -> Bool {
        guard token.uuid == currentUUID, token.identity == currentIdentity,
              var entry = entries[token.uuid], entry.token == token, entry.setterInvoked,
              readback == token.requested else { return false }
        entry.verified = true
        entries[token.uuid] = entry
        return true
    }

    public func verifiedRoutingState(for token: HDRMutationToken) -> Bool? {
        guard let entry = entries[token.uuid], entry.token == token, entry.verified else { return nil }
        return token.requested
    }

    public mutating func invalidate(uuid: String, identity: String) {
        guard entries[uuid]?.token.identity == identity else { return }
        entries.removeValue(forKey: uuid)
    }
}
