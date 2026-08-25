public enum EDRHeadroomSettlementResult: Equatable, Sendable {
    case ready(potentialHeadroom: Double)
    case timedOut
    case invalidated
    case capabilityLost
}

/// Keeps preference verification separate from the later EDR readiness ramp.
/// The caller supplies identity/generation and capability checks so this Core
/// helper remains AppKit-free.
public enum EDRHeadroomSettlement {
    @MainActor
    public static func wait(
        maxSamples: Int,
        threshold: Double,
        isCurrent: () -> Bool,
        isCapable: () -> Bool,
        potentialHeadroom: () -> Double,
        pause: () async throws -> Void
    ) async rethrows -> EDRHeadroomSettlementResult {
        for sampleIndex in 0..<max(0, maxSamples) {
            guard isCurrent() else { return .invalidated }
            guard isCapable() else { return .capabilityLost }
            let potential = potentialHeadroom()
            if potential > threshold {
                return .ready(potentialHeadroom: potential)
            }
            if sampleIndex + 1 < maxSamples {
                try await pause()
            }
        }
        guard isCurrent() else { return .invalidated }
        guard isCapable() else { return .capabilityLost }
        return .timedOut
    }
}
