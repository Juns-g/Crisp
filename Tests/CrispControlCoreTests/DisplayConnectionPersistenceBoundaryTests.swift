// The persistence and quarantine safety matrix intentionally shares one stateful store fixture.
import XCTest
@testable import CrispControlCore

// swiftlint:disable:next type_body_length
final class ConnectionPersistenceBoundaryTests: XCTestCase {
    private let targetUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func testDestructiveWriteWithOldReadBackPreservesConsumedReservationEnvelope() throws {
        let old = envelope(capabilityState: .consumed, reservation: true)
        let proposed = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(
            initial: old,
            reads: [.envelope(old), .envelope(old)]
        )
        let boundary = store.makeBoundary()

        let result = try boundary.replace(
            oldState: old,
            proposedState: proposed,
            quarantiningUUIDs: [targetUUID]
        )

        XCTAssertEqual(result.disposition, .preservedOld)
        XCTAssertEqual(result.snapshot.envelope, old)
        XCTAssertEqual(result.snapshot.envelope.reconnectReservationSet, [targetUUID])
        XCTAssertEqual(
            result.snapshot.envelope.records.first?.recoveryCapability?.state,
            .consumed
        )
        XCTAssertEqual(try store.storedEnvelope(), old)
        XCTAssertEqual(store.writeCount, 1)
        try assertNextObservation(
            from: boundary,
            store: store,
            equals: old,
            expectedResolution: .unavailable
        )
    }

    func testDestructiveWriteWithProposedReadBackAdoptsProposedEnvelope() throws {
        let old = envelope(capabilityState: .consumed, reservation: true)
        let proposed = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(
            initial: old,
            reads: [.stored, .stored]
        )
        let boundary = store.makeBoundary()

        let result = try boundary.replace(
            oldState: old,
            proposedState: proposed,
            quarantiningUUIDs: [targetUUID]
        )

        XCTAssertEqual(result.disposition, .committedProposed)
        XCTAssertEqual(result.snapshot.envelope, proposed)
        XCTAssertEqual(try store.storedEnvelope(), proposed)
        XCTAssertEqual(store.writeCount, 1)
        try assertNextObservation(
            from: boundary,
            store: store,
            equals: proposed,
            expectedResolution: .oneShotRecovery(capability(state: .available))
        )
    }

    func testDestructiveWriteWithMissingReadBackPersistsFailClosedQuarantine() throws {
        _ = try assertAnomalousReadBackIsQuarantined(.missing)
    }

    func testDestructiveWriteWithCorruptReadBackPersistsFailClosedQuarantine() throws {
        _ = try assertAnomalousReadBackIsQuarantined(.corrupt)
    }

    func testDestructiveWriteWithUnexpectedValidReadBackPersistsFailClosedQuarantine() throws {
        let unexpected = DisplayConnectionPersistenceEnvelope(
            records: [
                record(capabilityState: .available),
                DisplayConnectionPersistedRecord(
                    uuid: otherUUID,
                    displayID: 3,
                    name: "Other",
                    width: 1920,
                    height: 1080
                )
            ],
            pendingUUIDs: [],
            reconnectReservationUUIDs: []
        )
        let result = try assertAnomalousReadBackIsQuarantined(.envelope(unexpected))

        XCTAssertEqual(
            Set(result.snapshot.envelope.records.map(\.uuid)),
            [targetUUID, otherUUID],
            "compensation must not discard another valid orphan from unexpected read-back"
        )
    }

    func testCorruptEnvelopeOnRelaunchFailsClosedWithoutInventingReconnect() throws {
        let store = ScriptedConnectionStore(
            initialData: Data("not-json".utf8),
            reads: [.stored]
        )
        let boundary = store.makeBoundary()

        XCTAssertThrowsError(try boundary.snapshot()) { error in
            XCTAssertEqual(error as? DisplayConnectionPersistenceError, .corrupt)
        }
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testUnverifiedCompensationStaysSyntheticUntilKnownDurableReadBack() throws {
        let old = envelope(capabilityState: .consumed, reservation: true)
        let proposed = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(
            initial: old,
            reads: [.missing, .corrupt, .missing, .stored]
        )
        let boundary = store.makeBoundary()

        let result = try boundary.replace(
            oldState: old,
            proposedState: proposed,
            quarantiningUUIDs: [targetUUID]
        )

        XCTAssertEqual(result.disposition, .quarantined)
        XCTAssertEqual(result.snapshot.authority, .syntheticQuarantine)
        XCTAssertFalse(result.snapshot.authorizesConnectionMutation)
        XCTAssertEqual(store.writeCount, 2)
        XCTAssertEqual(boundary.publishedRecords, result.snapshot.envelope.records)

        let stillUnknown = try boundary.snapshot()
        XCTAssertEqual(stillUnknown, result.snapshot)
        let observation = connectionObservation(snapshot: stillUnknown)
        XCTAssertEqual(
            DisplayConnectionRecoveryResolver.reconnectResolution(
                uuid: targetUUID,
                observation: observation
            ),
            .unavailable
        )
        XCTAssertFalse(DisplayConnectionRecoveryResolver.authorizesConsumedRecoveryDispatch(
            uuid: targetUUID,
            displayID: 2,
            observation: observation
        ))

        try store.simulateExternalDurableState(result.snapshot.envelope)
        let durable = try boundary.snapshot()
        XCTAssertEqual(durable.authority, .durable)
        XCTAssertEqual(durable.envelope, result.snapshot.envelope)
        XCTAssertFalse(durable.authorizesConnectionMutation)
    }

    func testConnectedCapabilityQueryDoesNotPersistOrChangePublishedRecords() throws {
        let stale = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(initial: stale, reads: [.stored])
        let boundary = store.makeBoundary(initialPublishedRecords: stale.records)
        let publishedBefore = boundary.publishedRecords
        let snapshot = try boundary.snapshot()

        let capability = DisplayConnectionReadOnlyQueries.connectedCapability(
            uuid: targetUUID,
            observation: connectedObservation(snapshot: snapshot)
        )

        XCTAssertEqual(capability.state, .unsupported)
        XCTAssertEqual(capability.connected, true)
        XCTAssertEqual(capability.disconnectAllowed, false)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, publishedBefore)
    }

    func testConnectedCapabilitiesBatchReadsOneSnapshotForEveryDisplay() throws {
        let empty = DisplayConnectionPersistenceEnvelope(
            records: [],
            pendingUUIDs: [],
            reconnectReservationUUIDs: []
        )
        let store = try ScriptedConnectionStore(
            initial: empty,
            reads: [.stored, .missing]
        )
        let boundary = store.makeBoundary(initialPublishedRecords: [record(capabilityState: .available)])
        let publishedBefore = boundary.publishedRecords
        var observationCount = 0

        let capabilities = DisplayConnectionReadOnlyQueries.connectedCapabilities(
            subjects: [
                DisplayConnectionCapabilitySubject(uuid: targetUUID),
                DisplayConnectionCapabilitySubject(uuid: otherUUID)
            ],
            loadSnapshot: { try boundary.snapshot() },
            buildObservation: { snapshot in
                observationCount += 1
                return connectedObservation(snapshot: snapshot)
            }
        )

        XCTAssertEqual(capabilities.count, 2)
        XCTAssertEqual(capabilities[targetUUID]?.state, .writable)
        XCTAssertEqual(capabilities[otherUUID]?.state, .writable)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(observationCount, 1)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, publishedBefore)
    }

    func testConnectedCapabilitiesBatchFailsClosedFromOneUnavailableBoundary() throws {
        let empty = DisplayConnectionPersistenceEnvelope(
            records: [],
            pendingUUIDs: [],
            reconnectReservationUUIDs: []
        )
        let staticUnsupported = DisplayConnectionCapability.unsupported(
            connected: true,
            reason: "static hardware proof is unavailable"
        )
        let subjects = [
            DisplayConnectionCapabilitySubject(uuid: targetUUID),
            DisplayConnectionCapabilitySubject(
                uuid: otherUUID,
                staticUnsupportedCapability: staticUnsupported
            )
        ]
        let store = try ScriptedConnectionStore(initial: empty, reads: [.stored])
        let boundary = store.makeBoundary()
        var observationCount = 0

        let enumerationFailure = DisplayConnectionReadOnlyQueries.connectedCapabilities(
            subjects: subjects,
            loadSnapshot: { try boundary.snapshot() },
            buildObservation: { _ in
                observationCount += 1
                throw DisplayConnectionPersistenceError.corrupt
            }
        )

        XCTAssertEqual(enumerationFailure[targetUUID]?.state, .unsupported)
        XCTAssertEqual(
            enumerationFailure[targetUUID]?.reason,
            "fresh WindowServer enumeration is unavailable"
        )
        XCTAssertEqual(enumerationFailure[otherUUID], staticUnsupported)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(observationCount, 1)
        XCTAssertEqual(store.writeCount, 0)

        var unavailableObservationCount = 0
        let missingStore = ScriptedConnectionStore(initialData: nil, reads: [.stored])
        let missingBoundary = missingStore.makeBoundary()
        let persistenceFailure = DisplayConnectionReadOnlyQueries.connectedCapabilities(
            subjects: subjects,
            loadSnapshot: { try missingBoundary.snapshot() },
            buildObservation: { snapshot in
                unavailableObservationCount += 1
                return connectedObservation(snapshot: snapshot)
            }
        )

        XCTAssertEqual(persistenceFailure[targetUUID]?.state, .unsupported)
        XCTAssertEqual(
            persistenceFailure[targetUUID]?.reason,
            "persisted connection recovery state is unavailable or corrupt"
        )
        XCTAssertEqual(persistenceFailure[otherUUID], staticUnsupported)
        XCTAssertEqual(missingStore.readCount, 1)
        XCTAssertEqual(unavailableObservationCount, 0)
        XCTAssertEqual(missingStore.writeCount, 0)
    }

    func testDisconnectedInventoryQueryDoesNotConfirmPendingOrChangePublishedRecords() throws {
        let pending = DisplayConnectionPersistenceEnvelope(
            records: [record(capabilityState: .prepared)],
            pendingUUIDs: [targetUUID],
            reconnectReservationUUIDs: []
        )
        let store = try ScriptedConnectionStore(initial: pending, reads: [.stored])
        let boundary = store.makeBoundary(initialPublishedRecords: pending.records)
        let publishedBefore = boundary.publishedRecords
        let snapshot = try boundary.snapshot()

        let inventory = DisplayConnectionReadOnlyQueries.disconnectedDisplays(
            persistenceSnapshot: snapshot,
            observation: connectionObservation(snapshot: snapshot)
        )

        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory.first?.uuid, targetUUID)
        XCTAssertEqual(inventory.first?.connection.state, .unsupported)
        XCTAssertEqual(inventory.first?.connection.reconnectAllowed, false)
        XCTAssertEqual(store.readCount, 1)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, publishedBefore)
    }

    func testRelaunchedDurableQuarantineReconcilesDirectOfflineProofAtomically() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared)
        let store = try ScriptedConnectionStore(
            initial: quarantined,
            reads: [.stored, .stored, .stored]
        )
        let relaunchedBoundary = store.makeBoundary(
            initialPublishedRecords: quarantined.records
        )
        let snapshot = try relaunchedBoundary.snapshot()

        let result = try XCTUnwrap(relaunchedBoundary.reconcileQuarantinedReconnect(
            uuid: targetUUID,
            snapshot: snapshot,
            observation: directOfflineObservation(snapshot: snapshot)
        ))

        XCTAssertEqual(result.kind, .reconciledOffline)
        XCTAssertEqual(result.writeResult.disposition, .committedProposed)
        XCTAssertEqual(result.writeResult.snapshot.envelope.pendingSet, [])
        XCTAssertEqual(result.writeResult.snapshot.envelope.reconnectReservationSet, [])
        XCTAssertEqual(
            result.writeResult.snapshot.envelope.reconnectPersistenceUncertainSet,
            []
        )
        XCTAssertEqual(
            result.writeResult.snapshot.envelope.records.first?.recoveryCapability?.state,
            .available
        )
        XCTAssertEqual(store.readCount, 2)
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(
            relaunchedBoundary.publishedRecords,
            result.writeResult.snapshot.envelope.records
        )

        let nextLaunch = store.makeBoundary()
        let recovered = try nextLaunch.snapshot()
        XCTAssertEqual(recovered.authority, .durable)
        XCTAssertTrue(recovered.authorizesConnectionMutation)
        XCTAssertEqual(
            DisplayConnectionRecoveryResolver.reconnectResolution(
                uuid: targetUUID,
                observation: directOfflineObservation(snapshot: recovered)
            ),
            .oneShotRecovery(capability(state: .available))
        )
    }

    func testQuarantineReconciliationAcceptsFreshExactOfflineProof() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared, reservation: true)
        let store = try ScriptedConnectionStore(initial: quarantined, reads: [.stored, .stored])
        let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)
        let snapshot = try boundary.snapshot()

        let result = try XCTUnwrap(boundary.reconcileQuarantinedReconnect(
            uuid: targetUUID,
            snapshot: snapshot,
            observation: exactOfflineObservation(snapshot: snapshot)
        ))

        XCTAssertEqual(result.kind, .reconciledOffline)
        XCTAssertEqual(result.writeResult.disposition, .committedProposed)
        XCTAssertEqual(result.writeResult.snapshot.envelope.pendingSet, [])
        XCTAssertEqual(result.writeResult.snapshot.envelope.reconnectReservationSet, [])
        XCTAssertEqual(
            result.writeResult.snapshot.envelope.reconnectPersistenceUncertainSet,
            []
        )
        XCTAssertEqual(store.writeCount, 1)
    }

    func testQuarantineReconciliationCleansFreshExactOnlineProofWithoutDisplayWrite() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared, reservation: true)
        let store = try ScriptedConnectionStore(initial: quarantined, reads: [.stored, .stored])
        let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)
        let snapshot = try boundary.snapshot()

        let result = try XCTUnwrap(boundary.reconcileQuarantinedReconnect(
            uuid: targetUUID,
            snapshot: snapshot,
            observation: connectedObservation(snapshot: snapshot)
        ))

        XCTAssertEqual(result.kind, .alreadyOnline)
        XCTAssertEqual(result.writeResult.disposition, .committedProposed)
        XCTAssertEqual(result.writeResult.snapshot.envelope.records, [])
        XCTAssertEqual(result.writeResult.snapshot.envelope.pendingSet, [])
        XCTAssertEqual(result.writeResult.snapshot.envelope.reconnectReservationSet, [])
        XCTAssertEqual(
            result.writeResult.snapshot.envelope.reconnectPersistenceUncertainSet,
            []
        )
        XCTAssertEqual(boundary.publishedRecords, [])
        XCTAssertEqual(store.writeCount, 1)
    }

    func testQuarantineReconciliationReadBackFailureRetainsDurableQuarantine() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared)
        let store = try ScriptedConnectionStore(
            initial: quarantined,
            reads: [.stored, .envelope(quarantined)]
        )
        let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)
        let snapshot = try boundary.snapshot()

        let result = try XCTUnwrap(boundary.reconcileQuarantinedReconnect(
            uuid: targetUUID,
            snapshot: snapshot,
            observation: directOfflineObservation(snapshot: snapshot)
        ))

        XCTAssertEqual(result.writeResult.disposition, .preservedOld)
        XCTAssertEqual(result.writeResult.snapshot.envelope, quarantined)
        XCTAssertEqual(
            result.writeResult.snapshot.envelope.reconnectPersistenceUncertainSet,
            [targetUUID]
        )
        XCTAssertEqual(result.writeResult.snapshot.envelope.pendingSet, [targetUUID])
        XCTAssertEqual(store.writeCount, 1)
    }

    func testQuarantineReconciliationCompensatesMissingReadBackToDurableQuarantine() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared)
        let store = try ScriptedConnectionStore(
            initial: quarantined,
            reads: [.stored, .missing, .stored]
        )
        let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)
        let snapshot = try boundary.snapshot()

        let result = try XCTUnwrap(boundary.reconcileQuarantinedReconnect(
            uuid: targetUUID,
            snapshot: snapshot,
            observation: directOfflineObservation(snapshot: snapshot)
        ))

        XCTAssertEqual(result.writeResult.disposition, .preservedOld)
        XCTAssertEqual(result.writeResult.snapshot.authority, .durable)
        XCTAssertEqual(
            result.writeResult.snapshot.envelope.reconnectPersistenceUncertainSet,
            [targetUUID]
        )
        XCTAssertFalse(result.writeResult.snapshot.authorizesConnectionMutation)
        XCTAssertEqual(store.writeCount, 2)
    }

    func testOrdinaryTopologyReconcileDoesNotClearOfflineQuarantine() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared)
        let store = try ScriptedConnectionStore(initial: quarantined, reads: [.stored])
        let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)
        let snapshot = try boundary.snapshot()

        let result = try boundary.reconcileTopologyMetadata(
            snapshot: snapshot,
            observation: exactOfflineObservation(snapshot: snapshot)
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, quarantined.records)
    }

    func testSyntheticQuarantineCannotReconcileOrAuthorizeMutation() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared)
        let synthetic = DisplayConnectionPersistenceSnapshot(
            envelope: quarantined,
            authority: .syntheticQuarantine
        )
        let store = try ScriptedConnectionStore(initial: quarantined, reads: [])
        let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)

        let result = try boundary.reconcileQuarantinedReconnect(
            uuid: targetUUID,
            snapshot: synthetic,
            observation: directOfflineObservation(snapshot: synthetic)
        )

        XCTAssertNil(result)
        XCTAssertFalse(synthetic.authorizesConnectionMutation)
        XCTAssertEqual(store.readCount, 0)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, quarantined.records)
    }

    func testQuarantineReconciliationRejectsInvalidDirectAndContinuityProofWithoutCleanup() throws {
        let quarantined = quarantineEnvelope(capabilityState: .prepared)
        let snapshot = DisplayConnectionPersistenceSnapshot(
            envelope: quarantined,
            authority: .durable
        )
        let duplicateProofCandidate = DisplayConnectionCandidate(
            displayID: 3,
            stableUUID: nil,
            isOnline: false,
            isHardwareBackedPhysical: false,
            recoveryHardwareProof: capability(state: .prepared).hardwareProof
        )
        let invalidObservations = [
            directOfflineObservation(snapshot: snapshot, includeTargetCandidate: false),
            directOfflineObservation(
                snapshot: snapshot,
                candidateHasProof: false
            ),
            directOfflineObservation(
                snapshot: snapshot,
                extraCandidates: [duplicateProofCandidate]
            ),
            directOfflineObservation(snapshot: snapshot, candidateDisplayID: 0),
            directOfflineObservation(
                snapshot: snapshot,
                candidateProof: otherHardwareProof
            ),
            directOfflineObservation(snapshot: snapshot, bootSessionID: "boot-B"),
            directOfflineObservation(snapshot: snapshot, loginSessionID: "login-B"),
            directOfflineObservation(
                snapshot: snapshot,
                wakeSessionID: "mach-sleep-offset-v1:10002000001"
            ),
            directOfflineObservation(
                snapshot: snapshot,
                topologyFingerprint: "topology-B"
            ),
            ambiguousObservation(snapshot: snapshot)
        ]

        for observation in invalidObservations {
            let store = try ScriptedConnectionStore(initial: quarantined, reads: [])
            let boundary = store.makeBoundary(initialPublishedRecords: quarantined.records)

            let result = try boundary.reconcileQuarantinedReconnect(
                uuid: targetUUID,
                snapshot: snapshot,
                observation: observation
            )

            XCTAssertNil(result)
            XCTAssertEqual(store.readCount, 0)
            XCTAssertEqual(store.writeCount, 0)
            XCTAssertEqual(boundary.publishedRecords, quarantined.records)
        }
    }

    func testTopologyReconcileRemovesFreshOnlineStaleRecordWithMetadataWriteOnly() throws {
        let stale = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(
            initial: stale,
            reads: [.stored, .stored]
        )
        let boundary = store.makeBoundary(initialPublishedRecords: stale.records)
        let snapshot = try boundary.snapshot()

        let result = try boundary.reconcileTopologyMetadata(
            snapshot: snapshot,
            observation: connectedObservation(snapshot: snapshot)
        )

        XCTAssertEqual(result?.disposition, .committedProposed)
        XCTAssertEqual(result?.snapshot.envelope.records, [])
        XCTAssertEqual(boundary.publishedRecords, [])
        XCTAssertEqual(store.readCount, 2)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testTopologyReconcileConfirmsFreshExactOfflinePendingRecord() throws {
        let pending = DisplayConnectionPersistenceEnvelope(
            records: [record(capabilityState: .prepared)],
            pendingUUIDs: [targetUUID],
            reconnectReservationUUIDs: []
        )
        let store = try ScriptedConnectionStore(
            initial: pending,
            reads: [.stored, .stored]
        )
        let boundary = store.makeBoundary(initialPublishedRecords: pending.records)
        let snapshot = try boundary.snapshot()

        let result = try boundary.reconcileTopologyMetadata(
            snapshot: snapshot,
            observation: exactOfflineObservation(snapshot: snapshot)
        )

        XCTAssertEqual(result?.disposition, .committedProposed)
        XCTAssertEqual(result?.snapshot.envelope.pendingSet, [])
        XCTAssertEqual(
            result?.snapshot.envelope.records.first?.recoveryCapability?.state,
            .available
        )
        XCTAssertEqual(store.readCount, 2)
        XCTAssertEqual(store.writeCount, 1)
    }

    func testTopologyReconcileAmbiguousEnumerationDoesNotWrite() throws {
        let pending = DisplayConnectionPersistenceEnvelope(
            records: [record(capabilityState: .prepared)],
            pendingUUIDs: [targetUUID],
            reconnectReservationUUIDs: []
        )
        let store = try ScriptedConnectionStore(initial: pending, reads: [.stored])
        let boundary = store.makeBoundary(initialPublishedRecords: pending.records)
        let snapshot = try boundary.snapshot()
        let publishedBefore = boundary.publishedRecords

        let result = try boundary.reconcileTopologyMetadata(
            snapshot: snapshot,
            observation: ambiguousObservation(snapshot: snapshot)
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, publishedBefore)
    }

    func testTopologyReconcileFailedEnumerationDoesNotWrite() throws {
        let stale = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(initial: stale, reads: [.stored])
        let boundary = store.makeBoundary(initialPublishedRecords: stale.records)
        let snapshot = try boundary.snapshot()
        let publishedBefore = boundary.publishedRecords

        let result = try boundary.reconcileTopologyMetadata(
            snapshot: snapshot,
            observation: nil
        )

        XCTAssertNil(result)
        XCTAssertEqual(store.writeCount, 0)
        XCTAssertEqual(boundary.publishedRecords, publishedBefore)
    }

    private func assertAnomalousReadBackIsQuarantined(
        _ firstRead: ScriptedConnectionStore.Read
    ) throws -> DisplayConnectionPersistenceWriteResult {
        let old = envelope(capabilityState: .consumed, reservation: true)
        let proposed = envelope(capabilityState: .available, reservation: false)
        let store = try ScriptedConnectionStore(
            initial: old,
            reads: [firstRead, .stored, .stored, .stored]
        )
        let boundary = store.makeBoundary()

        let result = try boundary.replace(
            oldState: old,
            proposedState: proposed,
            quarantiningUUIDs: [targetUUID]
        )

        XCTAssertEqual(result.disposition, .quarantined)
        XCTAssertEqual(result.snapshot.authority, .durable)
        XCTAssertEqual(result.snapshot.envelope.reconnectPersistenceUncertainSet, [targetUUID])
        XCTAssertEqual(result.snapshot.envelope.reconnectReservationSet, [targetUUID])
        XCTAssertEqual(
            result.snapshot.envelope.records.first?.recoveryCapability?.state,
            .consumed
        )
        XCTAssertFalse(result.snapshot.authorizesConnectionMutation)
        XCTAssertEqual(try store.storedEnvelope(), result.snapshot.envelope)
        XCTAssertEqual(store.writeCount, 2, "the second write is explicit quarantine compensation")
        try assertNextObservation(
            from: boundary,
            store: store,
            equals: result.snapshot.envelope,
            expectedResolution: .unavailable
        )

        let relaunched = store.makeBoundary()
        let relaunchedSnapshot = try relaunched.snapshot()
        XCTAssertEqual(relaunchedSnapshot, result.snapshot)
        XCTAssertFalse(relaunchedSnapshot.authorizesConnectionMutation)
        return result
    }

    private func assertNextObservation(
        from boundary: DisplayConnectionPersistenceBoundary,
        store: ScriptedConnectionStore,
        equals expected: DisplayConnectionPersistenceEnvelope,
        expectedResolution: DisplayConnectionReconnectResolution
    ) throws {
        let readsBefore = store.readCount
        let snapshot = try boundary.snapshot()
        let observation = connectionObservation(snapshot: snapshot)

        XCTAssertEqual(store.readCount, readsBefore + 1)
        XCTAssertEqual(Set(observation.intentionalDisconnectedUUIDs), Set(expected.records.map(\.uuid)))
        XCTAssertEqual(observation.pendingDisconnectUUIDs, expected.pendingSet)
        XCTAssertEqual(observation.reconnectReservationUUIDs, expected.reconnectReservationSet)
        XCTAssertEqual(
            observation.reconnectPersistenceUncertainUUIDs,
            expected.reconnectPersistenceUncertainSet
        )
        XCTAssertEqual(
            observation.recoveryCapabilities,
            expected.records.compactMap(\.recoveryCapability)
        )
        XCTAssertEqual(
            DisplayConnectionRecoveryResolver.reconnectResolution(
                uuid: targetUUID,
                observation: observation
            ),
            expectedResolution
        )
        if expected.reconnectPersistenceUncertainSet.contains(targetUUID) {
            XCTAssertFalse(DisplayConnectionRecoveryResolver.authorizesConsumedRecoveryDispatch(
                uuid: targetUUID,
                displayID: 2,
                observation: observation
            ))
        }
    }

    private func connectionObservation(
        snapshot: DisplayConnectionPersistenceSnapshot
    ) -> DisplayConnectionObservation {
        DisplayConnectionObservation(
            persistenceSnapshot: snapshot,
            platformSupported: true,
            allUUIDs: [otherUUID],
            onlineUUIDs: [otherUUID],
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: [otherUUID],
            candidates: [
                DisplayConnectionCandidate(
                    displayID: 1,
                    stableUUID: otherUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: nil
                ),
                DisplayConnectionCandidate(
                    displayID: 2,
                    stableUUID: nil,
                    isOnline: false,
                    isHardwareBackedPhysical: false,
                    recoveryHardwareProof: capability(state: .consumed).hardwareProof
                )
            ],
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A"
        )
    }

    private func directOfflineObservation(
        snapshot: DisplayConnectionPersistenceSnapshot,
        candidateDisplayID: UInt32 = 2,
        candidateProof: DisplayConnectionRecoveryHardwareProof? = nil,
        candidateHasProof: Bool = true,
        includeTargetCandidate: Bool = true,
        extraCandidates: [DisplayConnectionCandidate] = [],
        bootSessionID: String? = "boot-A",
        loginSessionID: String? = "login-A",
        wakeSessionID: String? = "mach-sleep-offset-v1:10000000000",
        topologyFingerprint: String? = "topology-A"
    ) -> DisplayConnectionObservation {
        DisplayConnectionObservation(
            persistenceSnapshot: snapshot,
            platformSupported: true,
            allUUIDs: [otherUUID],
            onlineUUIDs: [otherUUID],
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: [otherUUID],
            candidates: [
                DisplayConnectionCandidate(
                    displayID: 1,
                    stableUUID: otherUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: nil
                )
            ] + (includeTargetCandidate ? [DisplayConnectionCandidate(
                    displayID: candidateDisplayID,
                    stableUUID: nil,
                    isOnline: false,
                    isHardwareBackedPhysical: false,
                    recoveryHardwareProof: candidateHasProof
                        ? (candidateProof ?? capability(state: .prepared).hardwareProof)
                        : nil
                )] : []) + extraCandidates,
            bootSessionID: bootSessionID,
            loginSessionID: loginSessionID,
            wakeSessionID: wakeSessionID,
            topologyFingerprint: topologyFingerprint
        )
    }

    private func connectedObservation(
        snapshot: DisplayConnectionPersistenceSnapshot
    ) -> DisplayConnectionObservation {
        DisplayConnectionObservation(
            persistenceSnapshot: snapshot,
            platformSupported: true,
            allUUIDs: [targetUUID, otherUUID],
            onlineUUIDs: [targetUUID, otherUUID],
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: [targetUUID, otherUUID],
            candidates: [
                DisplayConnectionCandidate(
                    displayID: 1,
                    stableUUID: otherUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: nil
                ),
                DisplayConnectionCandidate(
                    displayID: 2,
                    stableUUID: targetUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: capability(state: .available).hardwareProof
                )
            ],
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A"
        )
    }

    private func exactOfflineObservation(
        snapshot: DisplayConnectionPersistenceSnapshot
    ) -> DisplayConnectionObservation {
        DisplayConnectionObservation(
            persistenceSnapshot: snapshot,
            platformSupported: true,
            allUUIDs: [targetUUID, otherUUID],
            onlineUUIDs: [otherUUID],
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: [otherUUID],
            candidates: [
                DisplayConnectionCandidate(
                    displayID: 1,
                    stableUUID: otherUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: nil
                ),
                DisplayConnectionCandidate(
                    displayID: 2,
                    stableUUID: targetUUID,
                    isOnline: false,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: capability(state: .prepared).hardwareProof
                )
            ],
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A"
        )
    }

    private func ambiguousObservation(
        snapshot: DisplayConnectionPersistenceSnapshot
    ) -> DisplayConnectionObservation {
        DisplayConnectionObservation(
            persistenceSnapshot: snapshot,
            platformSupported: true,
            allUUIDs: [targetUUID, otherUUID],
            onlineUUIDs: [otherUUID],
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: [otherUUID],
            candidates: [
                DisplayConnectionCandidate(
                    displayID: 1,
                    stableUUID: otherUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: nil
                ),
                DisplayConnectionCandidate(
                    displayID: 2,
                    stableUUID: targetUUID,
                    isOnline: false,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: capability(state: .prepared).hardwareProof
                ),
                DisplayConnectionCandidate(
                    displayID: 3,
                    stableUUID: targetUUID,
                    isOnline: false,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: capability(state: .prepared).hardwareProof
                )
            ],
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A"
        )
    }

    private func envelope(
        capabilityState: DisplayConnectionRecoveryCapabilityState,
        reservation: Bool
    ) -> DisplayConnectionPersistenceEnvelope {
        DisplayConnectionPersistenceEnvelope(
            records: [record(capabilityState: capabilityState)],
            pendingUUIDs: [],
            reconnectReservationUUIDs: reservation ? [targetUUID] : []
        )
    }

    private func quarantineEnvelope(
        capabilityState: DisplayConnectionRecoveryCapabilityState,
        reservation: Bool = false
    ) -> DisplayConnectionPersistenceEnvelope {
        DisplayConnectionPersistenceEnvelope(
            records: [record(capabilityState: capabilityState)],
            pendingUUIDs: [targetUUID],
            reconnectReservationUUIDs: reservation ? [targetUUID] : [],
            reconnectPersistenceUncertainUUIDs: [targetUUID]
        )
    }

    private func record(
        capabilityState: DisplayConnectionRecoveryCapabilityState
    ) -> DisplayConnectionPersistedRecord {
        DisplayConnectionPersistedRecord(
            uuid: targetUUID,
            displayID: 2,
            name: "Target",
            width: 2560,
            height: 1440,
            recoveryCapability: capability(state: capabilityState)
        )
    }

    private func capability(
        state: DisplayConnectionRecoveryCapabilityState
    ) -> DisplayConnectionRecoveryCapability {
        DisplayConnectionRecoveryCapability(
            uuid: targetUUID,
            displayID: 2,
            hardwareProof: DisplayConnectionRecoveryHardwareProof(
                isBuiltIn: false,
                identity: HardwareDisplayIdentity(
                    vendorID: 1715,
                    productID: 10068,
                    serialNumber: 16843009
                )
            ),
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A",
            state: state
        )
    }

    private var otherHardwareProof: DisplayConnectionRecoveryHardwareProof {
        DisplayConnectionRecoveryHardwareProof(
            isBuiltIn: false,
            identity: HardwareDisplayIdentity(
                vendorID: 1552,
                productID: 41202,
                serialNumber: 33624064
            )
        )
    }
}

private final class ScriptedConnectionStore {
    enum Read {
        case stored
        case missing
        case corrupt
        case envelope(DisplayConnectionPersistenceEnvelope)
    }

    private var storedData: Data?
    private var reads: [Read]
    private(set) var readCount = 0
    private(set) var writeCount = 0

    convenience init(
        initial: DisplayConnectionPersistenceEnvelope,
        reads: [Read]
    ) throws {
        try self.init(initialData: JSONEncoder().encode(initial), reads: reads)
    }

    init(initialData: Data?, reads: [Read]) {
        storedData = initialData
        self.reads = reads
    }

    func makeBoundary(
        initialPublishedRecords: [DisplayConnectionPersistedRecord] = []
    ) -> DisplayConnectionPersistenceBoundary {
        DisplayConnectionPersistenceBoundary(
            initialPublishedRecords: initialPublishedRecords,
            read: { [unowned self] in read() },
            write: { [unowned self] data in write(data) }
        )
    }

    private func read() -> Data? {
        readCount += 1
        let behavior = reads.isEmpty ? .stored : reads.removeFirst()
        switch behavior {
        case .stored:
            return storedData
        case .missing:
            storedData = nil
            return nil
        case .corrupt:
            let corrupt = Data("not-json".utf8)
            storedData = corrupt
            return corrupt
        case let .envelope(envelope):
            storedData = try? JSONEncoder().encode(envelope)
            return storedData
        }
    }

    private func write(_ data: Data) {
        writeCount += 1
        storedData = data
    }

    func storedEnvelope() throws -> DisplayConnectionPersistenceEnvelope {
        try JSONDecoder().decode(
            DisplayConnectionPersistenceEnvelope.self,
            from: XCTUnwrap(storedData)
        )
    }

    func simulateExternalDurableState(
        _ envelope: DisplayConnectionPersistenceEnvelope
    ) throws {
        storedData = try JSONEncoder().encode(envelope)
    }
}
