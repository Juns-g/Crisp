import Foundation

public struct DisplayConnectionCapabilitySubject: Equatable, Sendable {
    public let uuid: String
    public let staticUnsupportedCapability: DisplayConnectionCapability?

    public init(
        uuid: String,
        staticUnsupportedCapability: DisplayConnectionCapability? = nil
    ) {
        self.uuid = uuid
        self.staticUnsupportedCapability = staticUnsupportedCapability
    }
}

public enum DisplayConnectionReadOnlyQueries {
    public static func connectedCapabilities(
        subjects: [DisplayConnectionCapabilitySubject],
        loadSnapshot: () throws -> DisplayConnectionPersistenceSnapshot,
        buildObservation: (
            DisplayConnectionPersistenceSnapshot
        ) throws -> DisplayConnectionObservation
    ) -> [String: DisplayConnectionCapability] {
        let snapshot: DisplayConnectionPersistenceSnapshot
        do {
            snapshot = try loadSnapshot()
        } catch {
            return connectedCapabilities(
                subjects: subjects,
                observation: nil,
                unavailableReason: "persisted connection recovery state is unavailable or corrupt",
                unavailableRemediation: "repair persistence before making a connection change"
            )
        }

        let observation: DisplayConnectionObservation
        do {
            observation = try buildObservation(snapshot)
        } catch {
            return connectedCapabilities(
                subjects: subjects,
                observation: nil,
                unavailableReason: "fresh WindowServer enumeration is unavailable",
                unavailableRemediation:
                    "refresh displays and retry only after capability becomes writable"
            )
        }

        return connectedCapabilities(
            subjects: subjects,
            observation: observation,
            unavailableReason: "",
            unavailableRemediation: ""
        )
    }

    public static func connectedCapability(
        uuid: String,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionCapability {
        let connected = observation.onlineUUIDs.contains(uuid)
        guard observation.persistenceStateIsAuthoritative else {
            return .unsupported(
                connected: connected,
                platformSupported: observation.platformSupported,
                reason: "persisted connection recovery state is unavailable or corrupt",
                remediation: "repair persistence before making a connection change"
            )
        }
        guard observation.platformSupported else {
            return .unsupported(
                connected: connected,
                reason: "physical display disconnect requires Apple Silicon and macOS 13 or later",
                remediation: "use a supported Apple Silicon Mac or leave connection changes to the GUI"
            )
        }
        if observation.reconnectPersistenceUncertainUUIDs.contains(uuid) {
            return .unsupported(
                connected: connected,
                platformSupported: true,
                reason: "connection recovery persistence is quarantined after an unverified write",
                remediation: "wait for a topology event or make a fresh explicit recovery decision"
            )
        }
        if observation.pendingDisconnectUUIDs.contains(uuid) {
            return .unsupported(
                connected: connected,
                platformSupported: true,
                reason: "the disconnect outcome is indeterminate and may still change",
                remediation: "wait for topology reconciliation; never retry the write automatically"
            )
        }
        if observation.reconnectReservationUUIDs.contains(uuid) {
            return .unsupported(
                connected: connected,
                platformSupported: true,
                reason: "a prior reconnect attempt still requires explicit reconciliation",
                remediation: "use an explicit reconnect request; inventory queries do not reconcile"
            )
        }
        if observation.intentionalDisconnectedUUIDs.contains(uuid) {
            return .unsupported(
                connected: connected,
                platformSupported: true,
                reason: "stale recovery metadata awaits topology-event reconciliation",
                remediation: "refresh the display topology before making a connection change"
            )
        }
        guard DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
            uuid: uuid,
            observation: observation
        ) != nil else {
            return .unsupported(
                connected: connected,
                platformSupported: true,
                reason: "the exact UUID is absent from the fresh online inventory",
                remediation: "run displays list again and make a fresh decision"
            )
        }
        guard observation.activePhysicalViewableUUIDs.contains(uuid),
              observation.activePhysicalViewableUUIDs.count > 1 else {
            return .unsupported(
                connected: true,
                platformSupported: true,
                reason: "disconnect would leave no active physical viewable display",
                remediation: "connect another physical display before disconnecting this one"
            )
        }
        return DisplayConnectionCapability(
            state: .writable,
            connected: true,
            disconnectAllowed: true,
            reconnectAllowed: false,
            platformSupported: true,
            reason: "another active physical viewable display remains"
        )
    }

    public static func disconnectedDisplays(
        persistenceSnapshot: DisplayConnectionPersistenceSnapshot,
        observation: DisplayConnectionObservation
    ) -> [ControlDisconnectedDisplay] {
        let envelope = persistenceSnapshot.envelope
        let snapshotMatchesObservation =
            Set(envelope.records.map(\.uuid)) == observation.intentionalDisconnectedUUIDs
            && envelope.pendingSet == observation.pendingDisconnectUUIDs
            && envelope.reconnectReservationSet == observation.reconnectReservationUUIDs
            && envelope.reconnectPersistenceUncertainSet
                == observation.reconnectPersistenceUncertainUUIDs
            && envelope.records.compactMap(\.recoveryCapability)
                == observation.recoveryCapabilities

        return envelope.records.compactMap { record in
            guard ControlRequest.isExactDisplayUUID(record.uuid) else { return nil }
            let connected = observation.onlineUUIDs.contains(record.uuid)
            let capability: DisplayConnectionCapability
            if !snapshotMatchesObservation || !observation.persistenceStateIsAuthoritative {
                capability = .unsupported(
                    connected: connected,
                    platformSupported: observation.platformSupported,
                    reason: "one authoritative recovery snapshot is unavailable",
                    remediation: "refresh after persistence becomes readable"
                )
            } else if envelope.reconnectPersistenceUncertainSet.contains(record.uuid) {
                capability = .unsupported(
                    connected: connected,
                    platformSupported: observation.platformSupported,
                    reason: "connection recovery persistence is quarantined after an unverified write",
                    remediation: "use topology reconciliation or a fresh explicit recovery decision"
                )
            } else if envelope.pendingSet.contains(record.uuid) {
                capability = .unsupported(
                    connected: connected,
                    platformSupported: observation.platformSupported,
                    reason: "the disconnect outcome is indeterminate and may still change",
                    remediation: "wait for topology reconciliation; never retry the write automatically"
                )
            } else if envelope.reconnectReservationSet.contains(record.uuid) {
                capability = .unsupported(
                    connected: connected,
                    platformSupported: observation.platformSupported,
                    reason: "a prior reconnect attempt still requires explicit reconciliation",
                    remediation: "use an explicit reconnect request; inventory queries do not reconcile"
                )
            } else if !observation.platformSupported {
                capability = .unsupported(
                    connected: connected,
                    reason: "physical display reconnect requires Apple Silicon and macOS 13 or later",
                    remediation: "use a supported Apple Silicon Mac"
                )
            } else {
                capability = reconnectCapability(record: record, observation: observation)
            }
            return ControlDisconnectedDisplay(
                uuid: record.uuid,
                name: record.name,
                width: record.width,
                height: record.height,
                connection: capability
            )
        }.sorted { $0.uuid < $1.uuid }
    }

    private static func connectedCapabilities(
        subjects: [DisplayConnectionCapabilitySubject],
        observation: DisplayConnectionObservation?,
        unavailableReason: String,
        unavailableRemediation: String
    ) -> [String: DisplayConnectionCapability] {
        let duplicateUUIDs = Set(
            Dictionary(grouping: subjects, by: \.uuid).compactMap { uuid, matches in
                matches.count > 1 ? uuid : nil
            }
        )
        var capabilities: [String: DisplayConnectionCapability] = [:]
        for subject in subjects {
            let capability: DisplayConnectionCapability
            if duplicateUUIDs.contains(subject.uuid) {
                capability = .unsupported(
                    connected: true,
                    platformSupported: observation?.platformSupported ?? true,
                    reason: "the connected display UUID is not unique",
                    remediation: "refresh displays after reconnecting the physical cable"
                )
            } else if let staticUnsupported = subject.staticUnsupportedCapability {
                capability = staticUnsupported
            } else if let observation {
                capability = connectedCapability(uuid: subject.uuid, observation: observation)
            } else {
                capability = .unsupported(
                    connected: true,
                    platformSupported: true,
                    reason: unavailableReason,
                    remediation: unavailableRemediation
                )
            }
            capabilities[subject.uuid] = capability
        }
        return capabilities
    }

    private static func reconnectCapability(
        record: DisplayConnectionPersistedRecord,
        observation: DisplayConnectionObservation
    ) -> DisplayConnectionCapability {
        switch DisplayConnectionRecoveryResolver.reconnectResolution(
            uuid: record.uuid,
            observation: observation
        ) {
        case .exactUUID:
            return DisplayConnectionCapability(
                state: .writable,
                connected: false,
                disconnectAllowed: false,
                reconnectAllowed: true,
                platformSupported: true,
                reason: "exact UUID is uniquely resolved and hardware-backed"
            )
        case .oneShotRecovery:
            return DisplayConnectionCapability(
                state: .writable,
                connected: false,
                disconnectAllowed: false,
                reconnectAllowed: true,
                platformSupported: true,
                reason: "same-session one-shot recovery capability is available"
            )
        case .alreadyOnline:
            return .unsupported(
                connected: true,
                platformSupported: true,
                reason: "stale online recovery metadata awaits topology-event reconciliation",
                remediation: "refresh the display topology"
            )
        case .unavailable:
            return .unsupported(
                connected: false,
                platformSupported: true,
                reason: "the disconnected display cannot be resolved without ambiguity",
                remediation: "check session, wake, and topology continuity, then refresh"
            )
        }
    }
}
