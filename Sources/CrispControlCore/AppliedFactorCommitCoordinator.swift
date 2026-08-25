public struct AppliedFactorCommitToken: Equatable, Sendable {
    public let uuid: String
    public let identity: String
    public let generation: UInt64
    public let factor: Double
}

/// Publishes app-owned boost state only after the queued transfer-table write
/// confirms that it ran for the same stable display identity.
public struct AppliedFactorCommitCoordinator: Sendable {
    private struct Entry: Sendable {
        var identity: String
        var generation: UInt64
        var appliedFactor: Double?
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public mutating func begin(
        uuid: String,
        identity: String,
        factor: Double
    ) -> AppliedFactorCommitToken {
        let existing = entries[uuid]
        let generation = (existing?.generation ?? 0) &+ 1
        entries[uuid] = Entry(
            identity: identity,
            generation: generation,
            appliedFactor: existing?.identity == identity ? existing?.appliedFactor : nil
        )
        return AppliedFactorCommitToken(
            uuid: uuid,
            identity: identity,
            generation: generation,
            factor: factor
        )
    }

    @discardableResult
    public mutating func complete(
        _ token: AppliedFactorCommitToken,
        queueAccepted: Bool,
        currentUUID: String,
        currentIdentity: String
    ) -> Bool {
        guard queueAccepted,
              token.uuid == currentUUID,
              token.identity == currentIdentity,
              let entry = entries[token.uuid],
              entry.identity == token.identity,
              entry.generation == token.generation else { return false }
        entries[token.uuid]?.appliedFactor = token.factor
        return true
    }

    public func appliedFactor(uuid: String, identity: String) -> Double? {
        guard let entry = entries[uuid], entry.identity == identity else { return nil }
        return entry.appliedFactor
    }

    public func isCommitted(
        factor: Double,
        uuid: String,
        identity: String,
        tolerance: Double
    ) -> Bool {
        guard let applied = appliedFactor(uuid: uuid, identity: identity) else { return false }
        return abs(applied - factor) <= tolerance
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
