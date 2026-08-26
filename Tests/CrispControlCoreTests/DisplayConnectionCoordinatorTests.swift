// The connection-state safety matrix is kept in one fixture-backed suite.
// swiftlint:disable file_length
import XCTest
@testable import CrispControlCore

@MainActor
final class DisplayConnectionCoordinatorTests: XCTestCase {
    private let targetUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private let thirdUUID = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
    private let targetID: UInt32 = 2
    private let otherID: UInt32 = 1
    private let bootSessionID = "boot-A"
    private let loginSessionID = "login-A"
    private let wakeSessionID = "mach-sleep-offset-v1:10000000000"
    private let topologyFingerprint = "topology-A"
}

extension DisplayConnectionCoordinatorTests {
    func testDisconnectSucceedsOnlyAfterSameUUIDIsOfflineAndRecordIsRetained() async throws {
        let retained = recoveryCapability(state: .prepared)
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(online: [targetUUID, otherUUID], records: [targetUUID]),
                observation(online: [otherUUID], records: [targetUUID])
            ],
            dispatchOutcome: .completed,
            retainedCapability: retained
        )

        let result = try await coordinator(adapter).disconnect(target(targetUUID))

        XCTAssertEqual(result.displayUUID, targetUUID)
        XCTAssertEqual(result.requestedConnectionState, .disconnected)
        XCTAssertEqual(result.observedConnectionState, .disconnected)
        XCTAssertEqual(result.verification, .sameUUIDEnumeration)
        XCTAssertEqual(adapter.dispatched, [request(state: .disconnected)])
        XCTAssertEqual(adapter.retained, [targetUUID])
        XCTAssertEqual(adapter.confirmed, [targetUUID])
        XCTAssertTrue(adapter.removed.isEmpty)
    }

    func testDisconnectWithoutRetainedRecordTruthIsIndeterminate() async {
        let retained = recoveryCapability(state: .prepared)
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(online: [otherUUID], records: []),
                observation(online: [otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            retainedCapability: retained
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).disconnect(self.target(self.targetUUID)) },
            classification: .indeterminate,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.retained, [targetUUID])
    }
}

extension DisplayConnectionCoordinatorTests {
    func testDisconnectWithoutRetainedRecoveryCapabilityRejectsBeforeDispatchAndCleansRecord() async {
        let adapter = FakeConnectionAdapter(
            observations: [observation(online: [targetUUID, otherUUID], records: [])],
            dispatchOutcome: .completed,
            retainedCapability: nil
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).disconnect(self.target(self.targetUUID)) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.retained, [targetUUID])
        XCTAssertEqual(adapter.removed, [targetUUID])
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertTrue(adapter.confirmed.isEmpty)
        XCTAssertTrue(adapter.indeterminate.isEmpty)
    }

    func testDisconnectConfirmsRetainedExactBindingWhenUUIDDisappearsAfterDisable() async throws {
        let retained = recoveryCapability(state: .prepared)
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(
                    all: [otherUUID],
                    online: [otherUUID],
                    records: [targetUUID],
                    pending: [targetUUID],
                    candidates: [
                        candidate(displayID: otherID, uuid: otherUUID, online: true),
                        candidate(
                            displayID: targetID,
                            uuid: nil,
                            online: false,
                            hardwareBacked: false,
                            recoveryProof: recoveryHardwareProof
                        )
                    ],
                    recoveryCapabilities: [retained]
                )
            ],
            dispatchOutcome: .completed,
            retainedCapability: retained
        )

        let result = try await coordinator(adapter).disconnect(target(targetUUID))

        XCTAssertEqual(result.observedConnectionState, .disconnected)
        XCTAssertEqual(result.verification, .retainedBindingHardwareContinuity)
        XCTAssertEqual(adapter.dispatched, [request(state: .disconnected)])
        XCTAssertEqual(adapter.confirmed, [targetUUID])
        XCTAssertTrue(adapter.removed.isEmpty)
    }

    func testReconnectRemovesRecordOnlyAfterSameUUIDIsOnline() async throws {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [otherUUID], records: [targetUUID]),
                observation(online: [otherUUID], records: [targetUUID]),
                observation(online: [targetUUID, otherUUID], records: [targetUUID]),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.requestedConnectionState, .connected)
        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(result.verification, .sameUUIDEnumeration)
        XCTAssertEqual(adapter.dispatched, [request(state: .connected)])
        XCTAssertEqual(adapter.removed, [targetUUID])
    }

    func testReconnectAcceptsSameUUIDOnlineAndRecordAbsentAfterAppReconcile() async throws {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [otherUUID], records: [targetUUID]),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.displayUUID, targetUUID)
        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertTrue(adapter.removed.isEmpty)
    }

    func testReconnectAlreadyOnlineClearsRecoveryStateWithoutDispatch() async throws {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    pending: [targetUUID]
                ),
                observation(online: [targetUUID, otherUUID], records: [], pending: [])
            ],
            dispatchOutcome: .completed
        )

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.removed, [targetUUID])
        XCTAssertTrue(adapter.dispatched.isEmpty)
    }

    func testReconnectFallbackDispatchesOneEnableAndRequiresFinalExactOnlineProof() async throws {
        let available = recoveryCapability(state: .available)
        let adapter = FakeConnectionAdapter(
            observations: [
                fallbackObservation(
                    recoveryCapabilities: [available],
                    wakeSessionID: "mach-sleep-offset-v1:10002000000"
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .consumed)]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            retainedCapability: available
        )

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.dispatched, [request(
            state: .connected,
            authorization: .oneShotRecovery
        )])
        XCTAssertEqual(adapter.consumed, [targetUUID])
        XCTAssertEqual(adapter.removed, [targetUUID])
    }

    func testLiveShapedFallbackScopesAmbiguityToCandidatesClaimingRetainedProof() async throws {
        let available = recoveryCapability(state: .available)
        let unrelatedNilCandidate = candidate(
            displayID: 3,
            uuid: nil,
            online: false,
            hardwareBacked: false,
            hasRecoveryProof: false
        )
        let liveShaped = FakeConnectionAdapter(
            observations: [
                fallbackObservation(
                    extraCandidates: [unrelatedNilCandidate],
                    recoveryCapabilities: [available]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .consumed)]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            retainedCapability: available
        )

        _ = try await coordinator(liveShaped).reconnect(uuid: targetUUID)

        XCTAssertEqual(liveShaped.dispatched, [request(
            state: .connected,
            authorization: .oneShotRecovery
        )])

        let duplicateProof = FakeConnectionAdapter(
            observations: [fallbackObservation(
                extraCandidates: [candidate(displayID: 3, uuid: nil, online: false)],
                recoveryCapabilities: [available]
            )],
            dispatchOutcome: .completed,
            retainedCapability: available
        )
        await assertFailure(
            from: { try await self.coordinator(duplicateProof).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(duplicateProof.dispatched.isEmpty)
    }

    func testFallbackEnableWithoutFinalUUIDTruthIsIndeterminateAndCannotRetry() async {
        let available = recoveryCapability(state: .available)
        let stillUnresolved = fallbackObservation(
            recoveryCapabilities: [recoveryCapability(state: .consumed)]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                fallbackObservation(recoveryCapabilities: [available]),
                stillUnresolved,
                stillUnresolved
            ],
            dispatchOutcome: .completed,
            retainedCapability: available
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
            classification: .indeterminate,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.dispatched.count, 1)
        XCTAssertEqual(adapter.consumed, [targetUUID])
        XCTAssertEqual(adapter.indeterminate, [targetUUID])
        XCTAssertTrue(adapter.removed.isEmpty)

        await assertFailure(
            from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.dispatched.count, 1, "a consumed capability must never retry")
    }

    func testFreshExactUUIDResolutionTakesPriorityOverFallback() async throws {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(
                    online: [otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .available)]
                ),
                observation(online: [targetUUID, otherUUID], records: [targetUUID]),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        _ = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(adapter.dispatched, [request(state: .connected)])
        XCTAssertTrue(adapter.consumed.isEmpty)
    }

    func testOverlappingExactReconnectsAreSingleFlightAcrossActorReentrancy() async throws {
        let offline = observation(online: [otherUUID], records: [targetUUID])
        let reservedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            reconnectReservations: [targetUUID]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                offline,
                reservedOnline,
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            suspendFirstDispatch: true
        )
        let first = Task { @MainActor in
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }
        for _ in 0..<100 where adapter.dispatched.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(adapter.dispatched.count, 1, "the first reconnect never reached dispatch")

        let overlapError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }
        XCTAssertEqual(overlapError?.classification, .preflightRejected)
        XCTAssertTrue(overlapError?.message.contains("still owns") == true)
        XCTAssertEqual(adapter.dispatched.count, 1)
        XCTAssertTrue(adapter.hasReconnectReservation(targetUUID))
        XCTAssertTrue(adapter.reconciledOrphans.isEmpty)

        adapter.resumeFirstDispatch()
        _ = try await first.value
        XCTAssertEqual(adapter.dispatched.count, 1)
    }

    func testQuarantinedFallbackFirstRequestReconcilesThenSecondRequestDispatches() async throws {
        let prepared = recoveryCapability(state: .prepared)
        let available = recoveryCapability(state: .available)
        let quarantined = fallbackObservation(
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [prepared]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantined,
                quarantined,
                fallbackObservation(recoveryCapabilities: [available]),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .consumed)]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID]
        )

        let error = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(error?.classification, .indeterminate)
        XCTAssertEqual(error?.retrySafe, false)
        XCTAssertEqual(error?.mutationDispatched, false)
        XCTAssertTrue(error?.message.contains("fresh explicit user decision") == true)
        XCTAssertEqual(adapter.quarantineReconciliationCount, 1)
        XCTAssertFalse(adapter.hasPendingDisconnect(targetUUID))
        XCTAssertFalse(adapter.hasReconnectPersistenceUncertain(targetUUID))
        XCTAssertEqual(adapter.restoredRecoveryCapabilityStates[targetUUID], .available)
        XCTAssertTrue(adapter.dispatched.isEmpty)

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.dispatched, [request(
            state: .connected,
            authorization: .oneShotRecovery
        )])
        XCTAssertEqual(adapter.consumed, [targetUUID])
    }

    func testQuarantinedExactOfflineFirstRequestReconcilesThenSecondRequestDispatches() async throws {
        let prepared = recoveryCapability(state: .prepared)
        let quarantined = observation(
            online: [otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [prepared]
        )
        let exactOffline = observation(
            online: [otherUUID],
            records: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .available)]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantined,
                quarantined,
                exactOffline,
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .available)]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID]
        )

        let firstError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(firstError?.classification, .indeterminate)
        XCTAssertEqual(firstError?.retrySafe, false)
        XCTAssertEqual(firstError?.mutationDispatched, false)
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertFalse(adapter.hasPendingDisconnect(targetUUID))
        XCTAssertFalse(adapter.hasReconnectPersistenceUncertain(targetUUID))

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.dispatched, [request(state: .connected)])
        XCTAssertTrue(adapter.consumed.isEmpty)
    }

    func testQuarantinedExactOnlineRequiresFreshPostCleanupProofWithoutDispatch() async throws {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantinedOnline,
                quarantinedOnline,
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID]
        )

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.quarantineReconciliationCount, 1)
        XCTAssertEqual(adapter.removed, [targetUUID])
        XCTAssertFalse(adapter.hasPendingDisconnect(targetUUID))
        XCTAssertFalse(adapter.hasReconnectPersistenceUncertain(targetUUID))
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertEqual(adapter.observationCallCount, 3)
        XCTAssertEqual(adapter.quarantineFinishCount, 1)
        XCTAssertFalse(adapter.hasLiveQuarantineReconciliation(targetUUID))
    }

    func testQuarantinedAlreadyOnlinePostCleanupOfflineIsIndeterminateWithoutDispatch() async {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantinedOnline,
                quarantinedOnline,
                observation(online: [otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID]
        )

        let error = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        assertPostCleanupProofFailure(error, adapter: adapter)
    }

    func testQuarantinedAlreadyOnlinePostCleanupOnlineWithoutUniqueHardwareProofIsIndeterminate()
        async {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )
        let ambiguousCandidates = [
            candidate(displayID: targetID, uuid: targetUUID, online: true),
            candidate(displayID: targetID + 1, uuid: targetUUID, online: true),
            candidate(displayID: otherID, uuid: otherUUID, online: true)
        ]
        let noHardwareProofCandidates = [
            candidate(
                displayID: targetID,
                uuid: targetUUID,
                online: true,
                hardwareBacked: false,
                hasRecoveryProof: false
            ),
            candidate(displayID: otherID, uuid: otherUUID, online: true)
        ]

        for finalCandidates in [ambiguousCandidates, noHardwareProofCandidates] {
            let final = observation(
                online: [targetUUID, otherUUID],
                records: [],
                candidates: finalCandidates
            )
            let adapter = FakeConnectionAdapter(
                observations: [quarantinedOnline, quarantinedOnline, final],
                dispatchOutcome: .completed,
                pendingDisconnectUUIDs: [targetUUID],
                reconnectPersistenceUncertainUUIDs: [targetUUID]
            )

            let error = await mutationFailure {
                try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
            }

            assertPostCleanupProofFailure(error, adapter: adapter)
        }
    }

    func testQuarantinedAlreadyOnlinePostCleanupRecoveryStateMustBeCompletelyAbsent() async {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )
        let residualStates = [
            observation(online: [targetUUID, otherUUID], records: [targetUUID]),
            observation(
                online: [targetUUID, otherUUID], records: [], pending: [targetUUID]
            ),
            observation(
                online: [targetUUID, otherUUID], records: [],
                reconnectReservations: [targetUUID]
            ),
            observation(
                online: [targetUUID, otherUUID], records: [],
                reconnectPersistenceUncertain: [targetUUID]
            ),
            observation(
                online: [targetUUID, otherUUID], records: [],
                recoveryCapabilities: [recoveryCapability(state: .available)]
            )
        ]

        for final in residualStates {
            let adapter = FakeConnectionAdapter(
                observations: [quarantinedOnline, quarantinedOnline, final],
                dispatchOutcome: .completed,
                pendingDisconnectUUIDs: [targetUUID],
                reconnectPersistenceUncertainUUIDs: [targetUUID]
            )

            let error = await mutationFailure {
                try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
            }

            assertPostCleanupProofFailure(error, adapter: adapter)
        }
    }

    func testQuarantinedAlreadyOnlinePostCleanupObservationFailureReleasesOwner() async {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )

        for cancellation in [false, true] {
            let adapter = FakeConnectionAdapter(
                observations: [quarantinedOnline, quarantinedOnline],
                dispatchOutcome: .completed,
                pendingDisconnectUUIDs: [targetUUID],
                reconnectPersistenceUncertainUUIDs: [targetUUID],
                observationFailureCalls: cancellation ? [] : [3],
                observationCancellationCalls: cancellation ? [3] : []
            )

            let error = await mutationFailure {
                try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
            }

            if cancellation {
                XCTAssertEqual(error?.classification, .indeterminate)
                XCTAssertEqual(error?.retrySafe, false)
                XCTAssertEqual(error?.mutationDispatched, false)
                XCTAssertTrue(
                    error?.message.contains(
                        "metadata cleanup occurred but the final exact-online proof or decision "
                            + "was cancelled"
                    ) == true
                )
                XCTAssertTrue(error?.message.contains("no display write was issued") == true)
                XCTAssertEqual(adapter.observationCallCount, 3)
                XCTAssertEqual(adapter.quarantineFinishCount, 1)
                XCTAssertFalse(adapter.hasLiveQuarantineReconciliation(targetUUID))
                XCTAssertTrue(adapter.dispatched.isEmpty)
            } else {
                assertPostCleanupProofFailure(error, adapter: adapter)
            }
        }
    }

    func testCancelledQuarantineOwnerCannotAcceptAlreadyOnlineAfterResume() async {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantinedOnline,
                quarantinedOnline,
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID],
            suspendFirstQuarantineReconciliation: true
        )
        let owner = Task { @MainActor in
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }
        for _ in 0..<100 where !adapter.isQuarantineReconciliationSuspended {
            await Task.yield()
        }
        XCTAssertTrue(adapter.isQuarantineReconciliationSuspended)
        XCTAssertTrue(adapter.hasLiveQuarantineReconciliation(targetUUID))

        owner.cancel()
        adapter.resumeFirstQuarantineReconciliation()
        let error = await mutationFailure { try await owner.value }

        XCTAssertEqual(error?.classification, .indeterminate)
        XCTAssertEqual(error?.retrySafe, false)
        XCTAssertEqual(error?.mutationDispatched, false)
        XCTAssertTrue(
            error?.message.contains(
                "metadata cleanup occurred but the final exact-online proof or decision was cancelled"
            ) == true
        )
        XCTAssertTrue(error?.message.contains("no display write was issued") == true)
        XCTAssertEqual(adapter.quarantineReconciliationCount, 1)
        XCTAssertEqual(adapter.quarantineFinishCount, 1)
        XCTAssertFalse(adapter.hasLiveQuarantineReconciliation(targetUUID))
        XCTAssertTrue(adapter.dispatched.isEmpty)
    }

    func testConcurrentQuarantinedAlreadyOnlineReconciliationRemainsSingleFlight() async throws {
        let quarantinedOnline = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [recoveryCapability(state: .prepared)]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantinedOnline,
                quarantinedOnline,
                quarantinedOnline,
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID],
            suspendFirstQuarantineReconciliation: true
        )
        let owner = Task { @MainActor in
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }
        for _ in 0..<100 where !adapter.isQuarantineReconciliationSuspended {
            await Task.yield()
        }
        XCTAssertTrue(adapter.isQuarantineReconciliationSuspended)

        let overlapError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(overlapError?.classification, .indeterminate)
        XCTAssertEqual(overlapError?.retrySafe, false)
        XCTAssertEqual(overlapError?.mutationDispatched, false)
        XCTAssertEqual(adapter.quarantineReconciliationAttemptCount, 1)
        XCTAssertEqual(adapter.quarantineFinishCount, 0)
        XCTAssertTrue(adapter.hasLiveQuarantineReconciliation(targetUUID))
        XCTAssertTrue(adapter.dispatched.isEmpty)

        adapter.resumeFirstQuarantineReconciliation()
        let result = try await owner.value

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.observationCallCount, 4)
        XCTAssertEqual(adapter.quarantineFinishCount, 1)
        XCTAssertFalse(adapter.hasLiveQuarantineReconciliation(targetUUID))
        XCTAssertTrue(adapter.dispatched.isEmpty)
    }

    func testQuarantineProofOrPersistenceFailureRetainsStateWithoutDispatch() async {
        let prepared = recoveryCapability(state: .prepared)
        let invalidProof = fallbackObservation(
            candidateHasRecoveryProof: false,
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [prepared]
        )
        let validProof = fallbackObservation(
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [prepared]
        )
        let cases = [
            FakeConnectionAdapter(
                observations: [invalidProof, invalidProof],
                dispatchOutcome: .completed,
                pendingDisconnectUUIDs: [targetUUID],
                reconnectPersistenceUncertainUUIDs: [targetUUID]
            ),
            FakeConnectionAdapter(
                observations: [validProof, validProof],
                dispatchOutcome: .completed,
                pendingDisconnectUUIDs: [targetUUID],
                reconnectPersistenceUncertainUUIDs: [targetUUID],
                quarantineReconciliationFailure: true
            )
        ]

        for adapter in cases {
            let error = await mutationFailure {
                try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
            }

            XCTAssertEqual(error?.classification, .indeterminate)
            XCTAssertEqual(error?.retrySafe, false)
            XCTAssertEqual(error?.mutationDispatched, false)
            XCTAssertTrue(adapter.hasPendingDisconnect(targetUUID))
            XCTAssertTrue(adapter.hasReconnectPersistenceUncertain(targetUUID))
            XCTAssertTrue(adapter.restoredRecoveryCapabilityStates.isEmpty)
            XCTAssertTrue(adapter.dispatched.isEmpty)
        }
    }

    func testConcurrentQuarantineReconciliationIsSingleFlightBeforeFreshRequest() async throws {
        let prepared = recoveryCapability(state: .prepared)
        let available = recoveryCapability(state: .available)
        let quarantined = fallbackObservation(
            pending: [targetUUID],
            reconnectPersistenceUncertain: [targetUUID],
            recoveryCapabilities: [prepared]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                quarantined,
                quarantined,
                quarantined,
                fallbackObservation(recoveryCapabilities: [available]),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .consumed)]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            pendingDisconnectUUIDs: [targetUUID],
            reconnectPersistenceUncertainUUIDs: [targetUUID],
            suspendFirstQuarantineReconciliation: true
        )
        let first = Task { @MainActor in
            await self.mutationFailure {
                try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
            }
        }
        for _ in 0..<100 where !adapter.isQuarantineReconciliationSuspended {
            await Task.yield()
        }
        XCTAssertTrue(adapter.isQuarantineReconciliationSuspended)

        let overlapError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(overlapError?.classification, .indeterminate)
        XCTAssertEqual(overlapError?.retrySafe, false)
        XCTAssertEqual(overlapError?.mutationDispatched, false)
        XCTAssertEqual(adapter.quarantineReconciliationAttemptCount, 1)
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertTrue(adapter.hasReconnectPersistenceUncertain(targetUUID))

        adapter.resumeFirstQuarantineReconciliation()
        let firstError = await first.value
        XCTAssertEqual(firstError?.classification, .indeterminate)
        XCTAssertEqual(firstError?.retrySafe, false)
        XCTAssertTrue(adapter.dispatched.isEmpty)

        _ = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(adapter.dispatched, [request(
            state: .connected,
            authorization: .oneShotRecovery
        )])
    }

    func testPersistedReconnectOrphanRequiresReadBackOnlyRequestBeforeFreshReconnect() async throws {
        let indeterminate = recoveryCapability(state: .indeterminate)
        let available = recoveryCapability(state: .available)
        let persisted = DisplayConnectionPersistenceEnvelope(
            records: [DisplayConnectionPersistedRecord(
                uuid: targetUUID,
                displayID: targetID,
                name: "Target",
                width: 2560,
                height: 1440,
                recoveryCapability: indeterminate
            )],
            pendingUUIDs: [],
            reconnectReservationUUIDs: [targetUUID]
        )
        let relaunchedState = try JSONDecoder().decode(
            DisplayConnectionPersistenceEnvelope.self,
            from: JSONEncoder().encode(persisted)
        )
        XCTAssertEqual(relaunchedState.reconnectReservationSet, [targetUUID])
        let reservedOffline = observation(
            online: [otherUUID],
            records: Set(relaunchedState.records.map(\.uuid)),
            reconnectReservations: relaunchedState.reconnectReservationSet,
            recoveryCapabilities: [indeterminate]
        )
        let relaunched = FakeConnectionAdapter(
            observations: [
                reservedOffline,
                reservedOffline,
                observation(
                    online: [otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [available]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID],
                    recoveryCapabilities: [available]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            reconnectReservations: [targetUUID]
        )

        let firstError = await mutationFailure {
            try await self.coordinator(relaunched).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(firstError?.classification, .indeterminate)
        XCTAssertEqual(firstError?.retrySafe, false)
        XCTAssertEqual(firstError?.mutationDispatched, false)
        XCTAssertTrue(firstError?.message.contains("prior reconnect attempt") == true)
        XCTAssertTrue(firstError?.message.contains("fresh read-back") == true)
        XCTAssertTrue(firstError?.message.contains("fresh explicit user decision") == true)
        XCTAssertTrue(relaunched.dispatched.isEmpty)
        XCTAssertFalse(relaunched.hasReconnectReservation(targetUUID))
        XCTAssertEqual(relaunched.restoredRecoveryCapabilityStates[targetUUID], .available)
        XCTAssertTrue(relaunched.removed.isEmpty)

        let result = try await coordinator(relaunched).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(relaunched.dispatched, [request(state: .connected)])
        XCTAssertEqual(relaunched.removed, [targetUUID])
    }

    func testPersistedFallbackOrphanRestoresValidatedCapabilityBeforeFreshRequestDispatches() async {
        let indeterminate = recoveryCapability(state: .indeterminate)
        let available = recoveryCapability(state: .available)
        let unrelatedNilCandidate = candidate(
            displayID: 3,
            uuid: nil,
            online: false,
            hardwareBacked: false,
            hasRecoveryProof: false
        )
        let orphan = fallbackObservation(
            extraCandidates: [unrelatedNilCandidate],
            reconnectReservations: [targetUUID],
            recoveryCapabilities: [indeterminate]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                orphan,
                orphan,
                fallbackObservation(
                    extraCandidates: [unrelatedNilCandidate],
                    recoveryCapabilities: [available]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID],
                    recoveryCapabilities: [recoveryCapability(state: .consumed)]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            reconnectReservations: [targetUUID]
        )

        let firstError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(firstError?.classification, .indeterminate)
        XCTAssertEqual(firstError?.retrySafe, false)
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertFalse(adapter.hasReconnectReservation(targetUUID))
        XCTAssertEqual(adapter.restoredRecoveryCapabilityStates[targetUUID], .available)

        let result = try? await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result?.observedConnectionState, .connected)
        XCTAssertEqual(adapter.dispatched, [request(
            state: .connected,
            authorization: .oneShotRecovery
        )])
        XCTAssertEqual(adapter.consumed, [targetUUID])
    }

    func testPersistedFallbackOrphanRejectsAmbiguousOrDiscontinuousProofWithoutCleanup() async {
        let consumed = recoveryCapability(state: .consumed)
        let cases: [DisplayConnectionObservation] = [
            fallbackObservation(
                extraCandidates: [candidate(displayID: 3, uuid: nil, online: false)],
                reconnectReservations: [targetUUID],
                recoveryCapabilities: [consumed]
            ),
            fallbackObservation(
                reconnectReservations: [targetUUID],
                recoveryCapabilities: [consumed],
                topologyFingerprint: "topology-B"
            ),
            fallbackObservation(
                reconnectReservations: [targetUUID],
                recoveryCapabilities: [recoveryCapability(state: .invalidatedByWake)]
            ),
            fallbackObservation(
                reconnectReservations: [targetUUID],
                recoveryCapabilities: [recoveryCapability(
                    wakeSessionID: "0:0",
                    state: .consumed
                )]
            ),
            fallbackObservation(
                candidateUUID: thirdUUID,
                reconnectReservations: [targetUUID],
                recoveryCapabilities: [consumed]
            ),
            fallbackObservation(
                reconnectReservations: [targetUUID],
                recoveryCapabilities: [recoveryCapability(state: .prepared)]
            )
        ]

        for orphan in cases {
            let adapter = FakeConnectionAdapter(
                observations: [orphan, orphan],
                dispatchOutcome: .completed,
                reconnectReservations: [targetUUID]
            )

            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
                classification: .indeterminate,
                uuid: targetUUID
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
            XCTAssertTrue(adapter.hasReconnectReservation(targetUUID))
            XCTAssertTrue(adapter.restoredRecoveryCapabilityStates.isEmpty)
        }
    }

    func testPersistedReconnectOrphanAlreadyOnlineCleansUpWithoutDispatch() async throws {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            reconnectReservations: [targetUUID]
        )

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertEqual(adapter.removed, [targetUUID])
        XCTAssertFalse(adapter.hasReconnectReservation(targetUUID))
        XCTAssertTrue(adapter.reconciledOrphans.isEmpty)
    }

    func testExactOrphanIgnoresInvalidatedFallbackAfterReadBackOnlyReconciliation() async throws {
        let invalidated = recoveryCapability(state: .invalidatedByWake)
        let reservedOffline = observation(
            online: [otherUUID],
            records: [targetUUID],
            reconnectReservations: [targetUUID],
            recoveryCapabilities: [invalidated]
        )
        let adapter = FakeConnectionAdapter(
            observations: [
                reservedOffline,
                reservedOffline,
                observation(
                    online: [otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [invalidated]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    reconnectReservations: [targetUUID],
                    recoveryCapabilities: [invalidated]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed,
            reconnectReservations: [targetUUID]
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
            classification: .indeterminate,
            uuid: targetUUID
        )
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertFalse(adapter.hasReconnectReservation(targetUUID))
        XCTAssertTrue(adapter.restoredRecoveryCapabilityStates.isEmpty)

        _ = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(adapter.dispatched, [request(state: .connected)])
        XCTAssertTrue(adapter.consumed.isEmpty)
    }

    func testPersistedReconnectOrphanPersistenceFailureRemainsFailClosed() async {
        let consumed = recoveryCapability(state: .consumed)
        let orphan = fallbackObservation(
            reconnectReservations: [targetUUID],
            recoveryCapabilities: [consumed]
        )
        let adapter = FakeConnectionAdapter(
            observations: [orphan, orphan],
            dispatchOutcome: .completed,
            reconnectReservations: [targetUUID],
            orphanReconciliationFailure: true
        )

        let error = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(error?.classification, .indeterminate)
        XCTAssertEqual(error?.retrySafe, false)
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertTrue(adapter.hasReconnectReservation(targetUUID))
        XCTAssertTrue(adapter.restoredRecoveryCapabilityStates.isEmpty)
    }

    func testWakeInvalidatesFallbackWithoutBlockingFreshExactReconnect() async throws {
        let invalidated = recoveryCapability(state: .invalidatedByWake)
        let fallback = FakeConnectionAdapter(
            observations: [fallbackObservation(recoveryCapabilities: [invalidated])],
            dispatchOutcome: .completed,
            retainedCapability: invalidated
        )

        await assertFailure(
            from: { try await self.coordinator(fallback).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(fallback.dispatched.isEmpty)

        let exact = FakeConnectionAdapter(
            observations: [
                observation(
                    online: [otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [invalidated]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [invalidated]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        _ = try await coordinator(exact).reconnect(uuid: targetUUID)

        XCTAssertEqual(exact.dispatched, [request(state: .connected)])
        XCTAssertTrue(exact.consumed.isEmpty)
    }

    func testMalformedWakeTokenBlocksOnlyFallbackAndFreshExactUUIDStillReconnects() async throws {
        let legacy = recoveryCapability(wakeSessionID: "0:0", state: .available)
        let fallback = FakeConnectionAdapter(
            observations: [fallbackObservation(recoveryCapabilities: [legacy])],
            dispatchOutcome: .completed
        )

        await assertFailure(
            from: { try await self.coordinator(fallback).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(fallback.dispatched.isEmpty)

        let exact = FakeConnectionAdapter(
            observations: [
                observation(
                    online: [otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [legacy]
                ),
                observation(
                    online: [targetUUID, otherUUID],
                    records: [targetUUID],
                    recoveryCapabilities: [legacy]
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        _ = try await coordinator(exact).reconnect(uuid: targetUUID)

        XCTAssertEqual(exact.dispatched, [request(state: .connected)])
        XCTAssertEqual(exact.removed, [targetUUID])
    }

    func testLegacyPersistenceEnvelopeDecodesWithoutFallbackOrReservationAndOnlineCleans() async throws {
        let legacy = Data(#"""
        {
          "records": [{
            "uuid": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            "displayID": 2,
            "name": "Target",
            "width": 2560,
            "height": 1440
          }],
          "pendingUUIDs": []
        }
        """#.utf8)
        let state = try JSONDecoder().decode(
            DisplayConnectionPersistenceEnvelope.self,
            from: legacy
        )
        let record = try XCTUnwrap(state.records.first)
        XCTAssertNil(record.recoveryCapability)
        XCTAssertTrue(state.reconnectReservationUUIDs.isEmpty)

        let adapter = FakeConnectionAdapter(
            observations: [
                observation(
                    online: [targetUUID, otherUUID],
                    records: Set(state.records.map(\.uuid)),
                    pending: state.pendingSet,
                    reconnectReservations: state.reconnectReservationSet,
                    recoveryCapabilities: state.records.compactMap(\.recoveryCapability)
                ),
                observation(online: [targetUUID, otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        _ = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertEqual(adapter.removed, [targetUUID])
    }

    func testPersistenceEnvelopeRejectsDuplicateRecordUUIDs() throws {
        let duplicate = Data(#"""
        {
          "records": [
            {"uuid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","displayID":2,
             "name":"First","width":2560,"height":1440},
            {"uuid":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","displayID":3,
             "name":"Second","width":1920,"height":1080}
          ],
          "pendingUUIDs": [],
          "reconnectReservationUUIDs": []
        }
        """#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(
            DisplayConnectionPersistenceEnvelope.self,
            from: duplicate
        ))
    }

    func testReconnectFallbackRejectsReusedAmbiguousOrMissingCandidatesWithoutDispatch() async {
        let available = recoveryCapability(state: .available)
        let unsafeObservations = [
            fallbackObservation(candidateUUID: thirdUUID, recoveryCapabilities: [available]),
            fallbackObservation(candidateOnline: true, recoveryCapabilities: [available]),
            fallbackObservation(
                extraCandidates: [candidate(displayID: 3, uuid: nil, online: false)],
                recoveryCapabilities: [available]
            ),
            fallbackObservation(
                extraCandidates: [candidate(displayID: targetID, uuid: nil, online: false)],
                recoveryCapabilities: [available]
            ),
            fallbackObservation(
                candidateDisplayID: 0,
                recoveryCapabilities: [recoveryCapability(displayID: 0, state: .available)]
            ),
            fallbackObservation(includeTargetCandidate: false, recoveryCapabilities: [available]),
            fallbackObservation(
                records: [targetUUID, thirdUUID],
                recoveryCapabilities: [
                    available,
                    recoveryCapability(uuid: thirdUUID, state: .available)
                ]
            )
        ]

        for unsafe in unsafeObservations {
            let adapter = FakeConnectionAdapter(
                observations: [unsafe],
                dispatchOutcome: .completed,
                retainedCapability: available
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
                classification: .preflightRejected,
                uuid: targetUUID
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
            XCTAssertTrue(adapter.consumed.isEmpty)
        }
    }

    func testReconnectFallbackRejectsMissingIncompleteOrNonuniqueHardwareProof() async {
        let available = recoveryCapability(state: .available)
        let incompleteProof = DisplayConnectionRecoveryHardwareProof(
            isBuiltIn: false,
            identity: HardwareDisplayIdentity(vendorID: 1715, productID: 10068, serialNumber: nil)
        )
        let unsafeObservations = [
            fallbackObservation(
                candidateHasRecoveryProof: false,
                recoveryCapabilities: [available]
            ),
            fallbackObservation(
                candidateProof: incompleteProof,
                recoveryCapabilities: [recoveryCapability(
                    hardwareProof: incompleteProof,
                    state: .available
                )]
            ),
            fallbackObservation(
                extraCandidates: [candidate(
                    displayID: 3,
                    uuid: thirdUUID,
                    online: false,
                    recoveryProof: recoveryHardwareProof
                )],
                recoveryCapabilities: [available]
            )
        ]

        for unsafe in unsafeObservations {
            let adapter = FakeConnectionAdapter(
                observations: [unsafe],
                dispatchOutcome: .completed,
                retainedCapability: available
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
                classification: .preflightRejected,
                uuid: targetUUID
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
        }
    }

    func testReconnectFallbackRejectsChangedMissingOrLegacyContinuity() async {
        let available = recoveryCapability(state: .available)
        let continuityChanges = [
            fallbackObservation(recoveryCapabilities: [available], bootSessionID: "boot-B"),
            fallbackObservation(recoveryCapabilities: [available], loginSessionID: "login-B"),
            fallbackObservation(
                recoveryCapabilities: [available],
                wakeSessionID: "mach-sleep-offset-v1:10002000001"
            ),
            fallbackObservation(recoveryCapabilities: [available], wakeSessionID: "0:0"),
            fallbackObservation(
                recoveryCapabilities: [available],
                topologyFingerprint: "topology-B"
            ),
            fallbackObservation(recoveryCapabilities: [available], bootSessionID: nil),
            fallbackObservation(recoveryCapabilities: [available], wakeSessionID: nil),
            fallbackObservation(recoveryCapabilities: [available], topologyFingerprint: nil)
        ]

        for changed in continuityChanges {
            let adapter = FakeConnectionAdapter(
                observations: [changed],
                dispatchOutcome: .completed,
                retainedCapability: available
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
                classification: .preflightRejected,
                uuid: targetUUID
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
        }
    }

    func testReconnectFallbackRejectsOldConsumedAndIndeterminateRecords() async {
        let unavailableCapabilities: [[DisplayConnectionRecoveryCapability]] = [
            [],
            [recoveryCapability(state: .prepared)],
            [recoveryCapability(state: .consumed)],
            [recoveryCapability(state: .indeterminate)]
        ]

        for capabilities in unavailableCapabilities {
            let adapter = FakeConnectionAdapter(
                observations: [fallbackObservation(recoveryCapabilities: capabilities)],
                dispatchOutcome: .completed
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
                classification: .preflightRejected,
                uuid: targetUUID
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
        }
    }

    func testReconnectFallbackEnumerationOrPersistenceFailureNeverDispatches() async {
        let available = recoveryCapability(state: .available)
        let enumerationFailure = FakeConnectionAdapter(
            observations: [fallbackObservation(recoveryCapabilities: [available])],
            dispatchOutcome: .completed,
            observationFailure: true
        )
        await assertFailure(
            from: { try await self.coordinator(enumerationFailure).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(enumerationFailure.dispatched.isEmpty)

        let persistenceFailure = FakeConnectionAdapter(
            observations: [fallbackObservation(recoveryCapabilities: [available])],
            dispatchOutcome: .completed,
            retainedCapability: available,
            consumeFailure: true
        )
        await assertFailure(
            from: { try await self.coordinator(persistenceFailure).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(persistenceFailure.dispatched.isEmpty)
    }

    func testReconnectThatNeverSettlesKeepsRecordAndIsIndeterminate() async {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [otherUUID], records: [targetUUID]),
                observation(online: [otherUUID], records: [targetUUID]),
                observation(online: [otherUUID], records: [targetUUID])
            ],
            dispatchOutcome: .completed
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
            classification: .indeterminate,
            uuid: targetUUID
        )
        XCTAssertTrue(adapter.removed.isEmpty)
    }
}

extension DisplayConnectionCoordinatorTests {
    func testFinalExactDisconnectAuthorizationRequiresFreshPreparedRecoveryContinuity() {
        let prepared = recoveryCapability(state: .prepared)
        let authorized = observation(
            online: [targetUUID, otherUUID],
            records: [targetUUID],
            pending: [targetUUID],
            recoveryCapabilities: [prepared]
        )
        XCTAssertTrue(DisplayConnectionRecoveryResolver.authorizesExactDisconnect(
            uuid: targetUUID,
            displayID: targetID,
            observation: authorized
        ))

        let unsafe = [
            observation(
                online: [targetUUID, otherUUID],
                records: [targetUUID],
                pending: [targetUUID]
            ),
            observation(
                online: [targetUUID, otherUUID],
                records: [targetUUID],
                recoveryCapabilities: [prepared]
            ),
            observation(
                online: [targetUUID, otherUUID],
                records: [targetUUID],
                pending: [targetUUID],
                recoveryCapabilities: [prepared],
                wakeSessionID: "mach-sleep-offset-v1:10002000001"
            ),
            observation(
                online: [targetUUID, otherUUID],
                records: [targetUUID],
                pending: [targetUUID],
                recoveryCapabilities: [recoveryCapability(
                    wakeSessionID: "0:0",
                    state: .prepared
                )]
            )
        ]
        for observation in unsafe {
            XCTAssertFalse(DisplayConnectionRecoveryResolver.authorizesExactDisconnect(
                uuid: targetUUID,
                displayID: targetID,
                observation: observation
            ))
        }
    }

    func testDisconnectPreflightGatesNeverDispatchMutation() async {
        let cases: [(DisplayConnectionTarget, DisplayConnectionObservation)] = [
            (target(targetUUID), observation(
                platformSupported: false, online: [targetUUID, otherUUID], records: []
            )),
            (target(targetUUID, isHardwareBackedPhysical: false), observation(
                online: [targetUUID, otherUUID], records: [], virtual: [targetUUID]
            )),
            (target(targetUUID), observation(
                online: [targetUUID], records: [], activePhysical: [targetUUID]
            )),
            (target(targetUUID), observation(
                all: [otherUUID], online: [otherUUID], records: []
            ))
        ]

        for (target, firstObservation) in cases {
            let adapter = FakeConnectionAdapter(
                observations: [firstObservation], dispatchOutcome: .completed
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).disconnect(target) },
                classification: .preflightRejected,
                uuid: target.uuid
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
            XCTAssertTrue(adapter.retained.isEmpty)
        }
    }

    func testThirdPartyVirtualWithoutHardwareBackingIsUnsupportedExcludedAndNeverDispatched() async throws {
        let thirdPartyVendorID: UInt32 = 0x1234
        XCTAssertNotEqual(thirdPartyVendorID, 0xEEEE)
        let unbackedEvidence = HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: false,
            isKnownVirtual: false,
            hasIOServicePort: false,
            ioServiceConformsToDisplayConnect: false
        )

        XCTAssertFalse(HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(unbackedEvidence))
        let capability = try XCTUnwrap(
            HardwareBackedPhysicalDisplayClassifier.unsupportedConnectionCapability(
                for: unbackedEvidence,
                connected: true
            )
        )
        XCTAssertEqual(capability.state, .unsupported)
        XCTAssertFalse(capability.disconnectAllowed)
        XCTAssertTrue(capability.reason?.contains("hardware-backed physical") == true)

        let activeCandidates = [
            (targetUUID, unbackedEvidence),
            (otherUUID, HardwareBackedPhysicalDisplayEvidence(
                isBuiltin: false,
                isKnownVirtual: false,
                hasIOServicePort: true,
                ioServiceConformsToDisplayConnect: true
            ))
        ]
        let activePhysical = Set(activeCandidates.compactMap { uuid, evidence in
            HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(evidence) ? uuid : nil
        })
        XCTAssertEqual(activePhysical, [otherUUID])

        let adapter = FakeConnectionAdapter(
            observations: [observation(
                online: [targetUUID, otherUUID],
                records: [],
                virtual: [targetUUID],
                activePhysical: activePhysical
            )],
            dispatchOutcome: .completed
        )
        await assertFailure(
            from: {
                try await self.coordinator(adapter).disconnect(
                    self.target(self.targetUUID, isHardwareBackedPhysical: false)
                )
            },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(adapter.dispatched.isEmpty)
        XCTAssertTrue(adapter.retained.isEmpty)
    }

    func testPositiveHardwareBackingProofAcceptsBuiltInAndIODisplayConnectExternal() {
        let builtIn = HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: true,
            isKnownVirtual: false,
            hasIOServicePort: false,
            ioServiceConformsToDisplayConnect: false
        )
        let external = HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: false,
            isKnownVirtual: false,
            hasIOServicePort: true,
            ioServiceConformsToDisplayConnect: true
        )
        let unprovenExternal = HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: false,
            isKnownVirtual: false,
            hasIOServicePort: true,
            ioServiceConformsToDisplayConnect: false
        )

        XCTAssertTrue(HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(builtIn))
        XCTAssertTrue(HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(external))
        XCTAssertFalse(HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(unprovenExternal))
        XCTAssertNil(
            HardwareBackedPhysicalDisplayClassifier.unsupportedConnectionCapability(
                for: builtIn,
                connected: true
            )
        )
        XCTAssertNil(
            HardwareBackedPhysicalDisplayClassifier.unsupportedConnectionCapability(
                for: external,
                connected: true
            )
        )
    }

    func testReconnectRequiresFreshExactRecordAndResolvableUUIDBeforeDispatch() async {
        for uuid in ["main", "Fixture Display", targetUUID] {
            let records: Set<String> = uuid == targetUUID ? [] : [uuid]
            let adapter = FakeConnectionAdapter(
                observations: [observation(online: [otherUUID], records: records)],
                dispatchOutcome: .completed
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: uuid) },
                classification: .preflightRejected,
                uuid: uuid
            )
            XCTAssertTrue(adapter.dispatched.isEmpty)
        }

        let stale = FakeConnectionAdapter(
            observations: [observation(
                all: [otherUUID], online: [otherUUID], records: [targetUUID]
            )],
            dispatchOutcome: .completed
        )
        await assertFailure(
            from: { try await self.coordinator(stale).reconnect(uuid: self.targetUUID) },
            classification: .preflightRejected,
            uuid: targetUUID
        )
        XCTAssertTrue(stale.dispatched.isEmpty)
    }

    func testPreDispatchRejectionIsDefiniteAndCleansNewDisconnectRecord() async {
        let retained = recoveryCapability(state: .prepared)
        let adapter = FakeConnectionAdapter(
            observations: [observation(online: [targetUUID, otherUUID], records: [])],
            dispatchOutcome: .rejectedBeforeDispatch("target disappeared during re-resolution"),
            retainedCapability: retained
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).disconnect(self.target(self.targetUUID)) },
            classification: .definiteFailure,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.retained, [targetUUID])
        XCTAssertEqual(adapter.removed, [targetUUID])
    }

    func testEveryPostDispatchNoncompletionIsIndeterminateAndRetainsRecoveryState() async {
        let outcomes: [DisplayConnectionDispatchOutcome] = [
            .failedAfterDispatch("configuration completion failed"),
            .timedOut,
            .cancelled
        ]
        for outcome in outcomes {
            let retained = recoveryCapability(state: .prepared)
            let adapter = FakeConnectionAdapter(
                observations: [observation(online: [targetUUID, otherUUID], records: [])],
                dispatchOutcome: outcome,
                retainedCapability: retained
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).disconnect(self.target(self.targetUUID)) },
                classification: .indeterminate,
                uuid: targetUUID
            )
            XCTAssertEqual(adapter.retained, [targetUUID])
            XCTAssertTrue(adapter.confirmed.isEmpty)
            XCTAssertTrue(adapter.removed.isEmpty)
        }
    }

    func testEveryPostDispatchConsumedFallbackNoncompletionIsIndeterminateAndNeverRetries() async {
        let outcomes: [DisplayConnectionDispatchOutcome] = [
            .failedAfterDispatch("configuration completion failed"),
            .timedOut,
            .cancelled
        ]
        for outcome in outcomes {
            let available = recoveryCapability(state: .available)
            let adapter = FakeConnectionAdapter(
                observations: [fallbackObservation(recoveryCapabilities: [available])],
                dispatchOutcome: outcome,
                retainedCapability: available
            )
            await assertFailure(
                from: { try await self.coordinator(adapter).reconnect(uuid: self.targetUUID) },
                classification: .indeterminate,
                uuid: targetUUID
            )
            XCTAssertEqual(adapter.dispatched.count, 1)
            XCTAssertEqual(adapter.consumed, [targetUUID])
            XCTAssertEqual(adapter.indeterminate, [targetUUID])
            XCTAssertTrue(adapter.removed.isEmpty)
        }
    }

    func testFallbackRejectedBeforeDispatchAtomicallyRestoresCapabilityForFreshRetry() async throws {
        let adapter = ProductionShapedReconnectAdapter(
            uuid: targetUUID,
            displayID: targetID,
            otherUUID: otherUUID,
            recoveryCapability: recoveryCapability(state: .available),
            resolution: .fallback,
            dispatchOutcomes: [
                .rejectedBeforeDispatch("final continuity check failed"),
                .completed
            ]
        )

        let error = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(error?.classification, .definiteFailure)
        XCTAssertEqual(error?.retrySafe, true)
        XCTAssertEqual(error?.mutationDispatched, false)
        XCTAssertFalse(adapter.hasReconnectReservation)
        XCTAssertFalse(adapter.hasLiveReconnectOwner)
        XCTAssertEqual(adapter.recoveryCapabilityState, .available)
        XCTAssertEqual(adapter.rollbackPersistenceWriteCount, 1)
        XCTAssertEqual(adapter.osDisplayCallCount, 0)

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.dispatched.count, 2)
        XCTAssertEqual(adapter.consumeCount, 2)
        XCTAssertEqual(adapter.osDisplayCallCount, 1)
    }

    func testRejectedBeforeDispatchRollbackFailureRetainsOrphanProtocolState() async throws {
        let adapter = ProductionShapedReconnectAdapter(
            uuid: targetUUID,
            displayID: targetID,
            otherUUID: otherUUID,
            recoveryCapability: recoveryCapability(state: .available),
            resolution: .fallback,
            dispatchOutcomes: [
                .rejectedBeforeDispatch("final continuity check failed"),
                .completed
            ],
            rollbackFailures: 1
        )

        let rollbackError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(rollbackError?.classification, .indeterminate)
        XCTAssertEqual(rollbackError?.retrySafe, false)
        XCTAssertEqual(rollbackError?.mutationDispatched, false)
        XCTAssertTrue(adapter.hasReconnectReservation)
        XCTAssertFalse(adapter.hasLiveReconnectOwner)
        XCTAssertEqual(adapter.recoveryCapabilityState, .consumed)
        XCTAssertEqual(adapter.rollbackPersistenceWriteCount, 0)
        XCTAssertEqual(adapter.osDisplayCallCount, 0)

        let orphanError = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(orphanError?.classification, .indeterminate)
        XCTAssertEqual(orphanError?.retrySafe, false)
        XCTAssertEqual(orphanError?.mutationDispatched, false)
        XCTAssertEqual(adapter.orphanReconciliationCount, 1)
        XCTAssertFalse(adapter.hasReconnectReservation)
        XCTAssertEqual(adapter.recoveryCapabilityState, .available)
        XCTAssertEqual(adapter.dispatched.count, 1)

        let result = try await coordinator(adapter).reconnect(uuid: targetUUID)

        XCTAssertEqual(result.observedConnectionState, .connected)
        XCTAssertEqual(adapter.dispatched.count, 2)
        XCTAssertEqual(adapter.osDisplayCallCount, 1)
    }

    func testExactRejectedBeforeDispatchClearsReservationWithoutCapabilityCorruption() async {
        let adapter = ProductionShapedReconnectAdapter(
            uuid: targetUUID,
            displayID: targetID,
            otherUUID: otherUUID,
            recoveryCapability: recoveryCapability(state: .invalidatedByWake),
            resolution: .exactUUID,
            dispatchOutcomes: [.rejectedBeforeDispatch("exact UUID continuity changed")]
        )

        let error = await mutationFailure {
            try await self.coordinator(adapter).reconnect(uuid: self.targetUUID)
        }

        XCTAssertEqual(error?.classification, .definiteFailure)
        XCTAssertEqual(error?.retrySafe, true)
        XCTAssertEqual(error?.mutationDispatched, false)
        XCTAssertFalse(adapter.hasReconnectReservation)
        XCTAssertFalse(adapter.hasLiveReconnectOwner)
        XCTAssertEqual(adapter.recoveryCapabilityState, .invalidatedByWake)
        XCTAssertEqual(adapter.rollbackPersistenceWriteCount, 1)
        XCTAssertEqual(adapter.osDisplayCallCount, 0)
    }

    func testCancellationDuringSettlementIsIndeterminateWithoutAutomaticRetry() async {
        let retained = recoveryCapability(state: .prepared)
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(online: [targetUUID, otherUUID], records: [targetUUID])
            ],
            dispatchOutcome: .completed,
            retainedCapability: retained
        )
        let coordinator = DisplayConnectionMutationCoordinator(
            adapter: adapter,
            settlementAttempts: 3,
            settlementInterval: .milliseconds(1),
            sleep: { _ in throw CancellationError() }
        )

        await assertFailure(
            from: { try await coordinator.disconnect(self.target(self.targetUUID)) },
            classification: .indeterminate,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.dispatched.count, 1)
    }
}

extension DisplayConnectionCoordinatorTests {
    private func coordinator(
        _ adapter: any DisplayConnectionMutationAdapter
    ) -> DisplayConnectionMutationCoordinator {
        DisplayConnectionMutationCoordinator(
            adapter: adapter,
            settlementAttempts: 2,
            settlementInterval: .zero,
            sleep: { _ in }
        )
    }

    private func target(
        _ uuid: String,
        isHardwareBackedPhysical: Bool = true
    ) -> DisplayConnectionTarget {
        DisplayConnectionTarget(
            uuid: uuid,
            displayID: targetID,
            name: "Target",
            width: 2560,
            height: 1440,
            isHardwareBackedPhysical: isHardwareBackedPhysical
        )
    }

    private func observation(
        platformSupported: Bool = true,
        all: Set<String>? = nil,
        online: Set<String>,
        records: Set<String>,
        pending: Set<String> = [],
        reconnectReservations: Set<String> = [],
        reconnectPersistenceUncertain: Set<String> = [],
        virtual: Set<String> = [],
        activePhysical: Set<String>? = nil,
        candidates: [DisplayConnectionCandidate]? = nil,
        recoveryCapabilities: [DisplayConnectionRecoveryCapability] = [],
        bootSessionID: String? = "boot-A",
        loginSessionID: String? = "login-A",
        wakeSessionID: String? = "mach-sleep-offset-v1:10000000000",
        topologyFingerprint: String? = "topology-A"
    ) -> DisplayConnectionObservation {
        let allUUIDs = all ?? online.union(records)
        let resolvedCandidates = candidates ?? allUUIDs.sorted().map { uuid in
            candidate(
                displayID: uuid == targetUUID ? targetID : otherID,
                uuid: uuid,
                online: online.contains(uuid),
                hardwareBacked: !virtual.contains(uuid)
            )
        }
        return DisplayConnectionObservation(
            platformSupported: platformSupported,
            allUUIDs: allUUIDs,
            onlineUUIDs: online,
            intentionalDisconnectedUUIDs: records,
            pendingDisconnectUUIDs: pending,
            reconnectReservationUUIDs: reconnectReservations,
            reconnectPersistenceUncertainUUIDs: reconnectPersistenceUncertain,
            virtualUUIDs: virtual,
            activePhysicalViewableUUIDs: activePhysical ?? online.subtracting(virtual),
            candidates: resolvedCandidates,
            recoveryCapabilities: recoveryCapabilities,
            bootSessionID: bootSessionID,
            loginSessionID: loginSessionID,
            wakeSessionID: wakeSessionID,
            topologyFingerprint: topologyFingerprint
        )
    }

    private func fallbackObservation(
        candidateDisplayID: UInt32? = nil,
        candidateUUID: String? = nil,
        candidateOnline: Bool = false,
        candidateHasRecoveryProof: Bool = true,
        candidateProof: DisplayConnectionRecoveryHardwareProof? = nil,
        includeTargetCandidate: Bool = true,
        extraCandidates: [DisplayConnectionCandidate] = [],
        records: Set<String>? = nil,
        pending: Set<String> = [],
        reconnectReservations: Set<String> = [],
        reconnectPersistenceUncertain: Set<String> = [],
        recoveryCapabilities: [DisplayConnectionRecoveryCapability],
        bootSessionID: String? = "boot-A",
        loginSessionID: String? = "login-A",
        wakeSessionID: String? = "mach-sleep-offset-v1:10000000000",
        topologyFingerprint: String? = "topology-A"
    ) -> DisplayConnectionObservation {
        let resolvedDisplayID = candidateDisplayID ?? targetID
        let targetCandidate = candidate(
            displayID: resolvedDisplayID,
            uuid: candidateUUID,
            online: candidateOnline,
            hardwareBacked: false,
            recoveryProof: candidateProof ?? recoveryHardwareProof,
            hasRecoveryProof: candidateHasRecoveryProof
        )
        let candidates = [candidate(displayID: otherID, uuid: otherUUID, online: true)]
            + (includeTargetCandidate ? [targetCandidate] : [])
            + extraCandidates
        let onlineUUIDs = Set(candidates.compactMap { candidate in
            candidate.isOnline ? candidate.stableUUID : nil
        })
        return observation(
            all: Set(candidates.compactMap(\.stableUUID)),
            online: onlineUUIDs,
            records: records ?? [targetUUID],
            pending: pending,
            reconnectReservations: reconnectReservations,
            reconnectPersistenceUncertain: reconnectPersistenceUncertain,
            candidates: candidates,
            recoveryCapabilities: recoveryCapabilities,
            bootSessionID: bootSessionID,
            loginSessionID: loginSessionID,
            wakeSessionID: wakeSessionID,
            topologyFingerprint: topologyFingerprint
        )
    }

    private func candidate(
        displayID: UInt32,
        uuid: String?,
        online: Bool,
        hardwareBacked: Bool = true,
        recoveryProof: DisplayConnectionRecoveryHardwareProof? = nil,
        hasRecoveryProof: Bool = true
    ) -> DisplayConnectionCandidate {
        let defaultProof = displayID == otherID ? otherRecoveryHardwareProof : recoveryHardwareProof
        return DisplayConnectionCandidate(
            displayID: displayID,
            stableUUID: uuid,
            isOnline: online,
            isHardwareBackedPhysical: hardwareBacked,
            recoveryHardwareProof: hasRecoveryProof ? (recoveryProof ?? defaultProof) : nil
        )
    }

    private func recoveryCapability(
        uuid: String? = nil,
        displayID: UInt32? = nil,
        hardwareProof: DisplayConnectionRecoveryHardwareProof? = nil,
        wakeSessionID: String? = nil,
        state: DisplayConnectionRecoveryCapabilityState
    ) -> DisplayConnectionRecoveryCapability {
        DisplayConnectionRecoveryCapability(
            uuid: uuid ?? targetUUID,
            displayID: displayID ?? targetID,
            hardwareProof: hardwareProof ?? recoveryHardwareProof,
            bootSessionID: bootSessionID,
            loginSessionID: loginSessionID,
            wakeSessionID: wakeSessionID ?? self.wakeSessionID,
            topologyFingerprint: topologyFingerprint,
            state: state
        )
    }

    private func request(
        state: DisplayConnectionState,
        authorization: DisplayConnectionDispatchAuthorization = .exactUUID
    ) -> DisplayConnectionDispatchRequest {
        DisplayConnectionDispatchRequest(
            uuid: targetUUID,
            displayID: targetID,
            requestedState: state,
            authorization: authorization
        )
    }

    private var recoveryHardwareProof: DisplayConnectionRecoveryHardwareProof {
        DisplayConnectionRecoveryHardwareProof(
            isBuiltIn: false,
            identity: HardwareDisplayIdentity(
                vendorID: 1715,
                productID: 10068,
                serialNumber: 16843009
            )
        )
    }

    private var otherRecoveryHardwareProof: DisplayConnectionRecoveryHardwareProof {
        DisplayConnectionRecoveryHardwareProof(
            isBuiltIn: false,
            identity: HardwareDisplayIdentity(
                vendorID: 1552,
                productID: 41202,
                serialNumber: 33624064
            )
        )
    }

    private func assertFailure(
        from operation: () async throws -> DisplayConnectionSetResult,
        classification: DisplayConnectionFailureClassification,
        uuid: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("expected display connection failure", file: file, line: line)
        } catch let error as DisplayConnectionMutationError {
            XCTAssertEqual(error.classification, classification, file: file, line: line)
            XCTAssertEqual(error.displayUUID, uuid, file: file, line: line)
            XCTAssertEqual(
                error.retrySafe,
                classification != .indeterminate,
                file: file,
                line: line
            )
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }

    private func mutationFailure(
        from operation: () async throws -> DisplayConnectionSetResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> DisplayConnectionMutationError? {
        do {
            _ = try await operation()
            XCTFail("expected display connection failure", file: file, line: line)
            return nil
        } catch let error as DisplayConnectionMutationError {
            return error
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }

    private func assertPostCleanupProofFailure(
        _ error: DisplayConnectionMutationError?,
        adapter: FakeConnectionAdapter,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(error?.classification, .indeterminate, file: file, line: line)
        XCTAssertEqual(error?.retrySafe, false, file: file, line: line)
        XCTAssertEqual(error?.mutationDispatched, false, file: file, line: line)
        XCTAssertTrue(
            error?.message.contains(
                "metadata cleanup occurred but final exact-online proof could not be verified"
            ) == true,
            file: file,
            line: line
        )
        XCTAssertTrue(error?.message.contains("no display write was issued") == true,
                      file: file, line: line)
        XCTAssertEqual(adapter.observationCallCount, 3, file: file, line: line)
        XCTAssertEqual(adapter.quarantineFinishCount, 1, file: file, line: line)
        XCTAssertFalse(adapter.hasLiveQuarantineReconciliation(targetUUID), file: file, line: line)
        XCTAssertTrue(adapter.dispatched.isEmpty, file: file, line: line)
    }
}

@MainActor
private final class FakeConnectionAdapter: DisplayConnectionMutationAdapter {
    private var observations: [DisplayConnectionObservation]
    private let dispatchOutcome: DisplayConnectionDispatchOutcome
    private let retainedCapability: DisplayConnectionRecoveryCapability?
    private let observationFailure: Bool
    private let consumeFailure: Bool
    private let suspendFirstDispatch: Bool
    private let orphanReconciliationFailure: Bool
    private let quarantineReconciliationFailure: Bool
    private let suspendFirstQuarantineReconciliation: Bool
    private let observationFailureCalls: Set<Int>
    private let observationCancellationCalls: Set<Int>
    private var firstDispatchContinuation: CheckedContinuation<Void, Never>?
    private var firstQuarantineContinuation: CheckedContinuation<Void, Never>?
    private var reconnectReservations: Set<String>
    private var pendingDisconnectUUIDs: Set<String>
    private var reconnectPersistenceUncertainUUIDs: Set<String>
    private var liveReconnectReservations: Set<String> = []
    private var liveQuarantineReconciliations: Set<String> = []
    private var didSuspendQuarantineReconciliation = false
    private(set) var dispatched: [DisplayConnectionDispatchRequest] = []
    private(set) var retained: [String] = []
    private(set) var confirmed: [String] = []
    private(set) var removed: [String] = []
    private(set) var consumed: [String] = []
    private(set) var indeterminate: [String] = []
    private(set) var reconciledOrphans: [String] = []
    private(set) var quarantineReconciliationCount = 0
    private(set) var quarantineReconciliationAttemptCount = 0
    private(set) var quarantineFinishCount = 0
    private(set) var observationCallCount = 0
    private(set) var restoredRecoveryCapabilityStates: [
        String: DisplayConnectionRecoveryCapabilityState
    ] = [:]

    init(
        observations: [DisplayConnectionObservation],
        dispatchOutcome: DisplayConnectionDispatchOutcome,
        retainedCapability: DisplayConnectionRecoveryCapability? = nil,
        observationFailure: Bool = false,
        consumeFailure: Bool = false,
        suspendFirstDispatch: Bool = false,
        reconnectReservations: Set<String> = [],
        pendingDisconnectUUIDs: Set<String> = [],
        reconnectPersistenceUncertainUUIDs: Set<String> = [],
        orphanReconciliationFailure: Bool = false,
        quarantineReconciliationFailure: Bool = false,
        suspendFirstQuarantineReconciliation: Bool = false,
        observationFailureCalls: Set<Int> = [],
        observationCancellationCalls: Set<Int> = []
    ) {
        self.observations = observations
        self.dispatchOutcome = dispatchOutcome
        self.retainedCapability = retainedCapability
        self.observationFailure = observationFailure
        self.consumeFailure = consumeFailure
        self.suspendFirstDispatch = suspendFirstDispatch
        self.reconnectReservations = reconnectReservations
        self.pendingDisconnectUUIDs = pendingDisconnectUUIDs
        self.reconnectPersistenceUncertainUUIDs = reconnectPersistenceUncertainUUIDs
        self.orphanReconciliationFailure = orphanReconciliationFailure
        self.quarantineReconciliationFailure = quarantineReconciliationFailure
        self.suspendFirstQuarantineReconciliation = suspendFirstQuarantineReconciliation
        self.observationFailureCalls = observationFailureCalls
        self.observationCancellationCalls = observationCancellationCalls
    }

    func connectionObservation() throws -> DisplayConnectionObservation {
        observationCallCount += 1
        if observationCancellationCalls.contains(observationCallCount) {
            throw CancellationError()
        }
        if observationFailureCalls.contains(observationCallCount) {
            throw FakeError.enumerationFailed
        }
        guard !observationFailure else { throw FakeError.enumerationFailed }
        guard !observations.isEmpty else { throw FakeError.noObservation }
        if observations.count == 1 { return observations[0] }
        return observations.removeFirst()
    }

    func retainDisconnectedRecord(
        _ target: DisplayConnectionTarget
    ) throws -> DisplayConnectionRecoveryCapability? {
        retained.append(target.uuid)
        return retainedCapability
    }

    func removeDisconnectedRecord(uuid: String) throws {
        removed.append(uuid)
        reconnectReservations.remove(uuid)
        liveReconnectReservations.remove(uuid)
    }

    func confirmDisconnectedRecord(uuid: String) throws {
        confirmed.append(uuid)
    }

    func consumeRecoveryCapability(
        _ capability: DisplayConnectionRecoveryCapability
    ) throws -> DisplayConnectionRecoveryCapability {
        guard !consumeFailure else { throw FakeError.persistenceFailed }
        consumed.append(capability.uuid)
        return DisplayConnectionRecoveryCapability(
            uuid: capability.uuid,
            displayID: capability.displayID,
            hardwareProof: capability.hardwareProof,
            bootSessionID: capability.bootSessionID,
            loginSessionID: capability.loginSessionID,
            wakeSessionID: capability.wakeSessionID,
            topologyFingerprint: capability.topologyFingerprint,
            state: .consumed
        )
    }

    func reserveReconnect(uuid: String) throws {
        guard !liveReconnectReservations.contains(uuid),
              reconnectReservations.insert(uuid).inserted else {
            throw FakeError.persistenceFailed
        }
        liveReconnectReservations.insert(uuid)
    }

    func releaseReconnectReservation(uuid: String) throws {
        guard liveReconnectReservations.contains(uuid),
              reconnectReservations.remove(uuid) != nil else {
            throw FakeError.persistenceFailed
        }
        liveReconnectReservations.remove(uuid)
    }

    func rollbackRejectedReconnectBeforeDispatch(
        uuid: String,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
    ) throws {
        guard liveReconnectReservations.contains(uuid),
              reconnectReservations.contains(uuid) else {
            throw FakeError.persistenceFailed
        }
        if let consumedRecoveryCapability {
            guard consumedRecoveryCapability.uuid == uuid,
                  consumedRecoveryCapability.state == .consumed else {
                throw FakeError.persistenceFailed
            }
            restoredRecoveryCapabilityStates[uuid] = .available
        }
        reconnectReservations.remove(uuid)
        liveReconnectReservations.remove(uuid)
    }

    func reconcileOrphanedReconnectAttempt(
        uuid: String
    ) throws -> DisplayReconnectOrphanReconciliation {
        guard reconnectReservations.contains(uuid) else { return .unavailable }
        guard !liveReconnectReservations.contains(uuid) else { return .liveAttempt }
        let observation = try connectionObservation()
        if case .alreadyOnline = DisplayConnectionRecoveryResolver.reconnectResolution(
            uuid: uuid,
            observation: observation
        ) {
            return .alreadyOnline
        }
        let resolution = DisplayConnectionRecoveryResolver.orphanedReconnectResolution(
            uuid: uuid,
            observation: observation
        )
        var restoredState: DisplayConnectionRecoveryCapabilityState?
        switch resolution {
        case .exactUUID:
            if let capability = DisplayConnectionRecoveryResolver
                .restorableRecoveryCapabilityForExactOrphan(
                    uuid: uuid,
                    observation: observation
                ), [.consumed, .indeterminate].contains(capability.state) {
                restoredState = .available
            }
        case let .oneShotRecovery(capability):
            restoredState = capability.changingState(to: .available).state
        case .alreadyOnline, .unavailable:
            return .unavailable
        }
        guard !orphanReconciliationFailure else { throw FakeError.persistenceFailed }
        if let restoredState {
            restoredRecoveryCapabilityStates[uuid] = restoredState
        }
        reconnectReservations.remove(uuid)
        reconciledOrphans.append(uuid)
        return .reconciled
    }

    func reconcileQuarantinedReconnectAttempt(
        uuid: String
    ) async throws -> DisplayReconnectQuarantineReconciliation {
        guard reconnectPersistenceUncertainUUIDs.contains(uuid) else { return .unavailable }
        guard liveQuarantineReconciliations.insert(uuid).inserted else { return .liveAttempt }
        quarantineReconciliationAttemptCount += 1
        let observation = try connectionObservation()
        if suspendFirstQuarantineReconciliation,
           !didSuspendQuarantineReconciliation {
            didSuspendQuarantineReconciliation = true
            await withCheckedContinuation { continuation in
                firstQuarantineContinuation = continuation
            }
        }
        guard !quarantineReconciliationFailure else { throw FakeError.persistenceFailed }
        switch DisplayConnectionRecoveryResolver.quarantinedReconnectResolution(
            uuid: uuid,
            observation: observation
        ) {
        case .alreadyOnline:
            removed.append(uuid)
        case .exactUUID:
            if DisplayConnectionRecoveryResolver.restorableRecoveryCapabilityForExactQuarantine(
                uuid: uuid,
                observation: observation
            ) != nil {
                restoredRecoveryCapabilityStates[uuid] = .available
            }
        case .oneShotRecovery:
            restoredRecoveryCapabilityStates[uuid] = .available
        case .unavailable:
            return .unavailable
        }
        reconnectPersistenceUncertainUUIDs.remove(uuid)
        pendingDisconnectUUIDs.remove(uuid)
        reconnectReservations.remove(uuid)
        quarantineReconciliationCount += 1
        return removed.last == uuid ? .alreadyOnline : .reconciled
    }

    func finishQuarantinedReconnectAttempt(uuid: String) {
        quarantineFinishCount += 1
        liveQuarantineReconciliations.remove(uuid)
    }

    func markReconnectAttemptIndeterminate(uuid: String) throws {
        liveReconnectReservations.remove(uuid)
        indeterminate.append(uuid)
    }

    func markRecoveryCapabilityIndeterminate(uuid: String) throws {
        indeterminate.append(uuid)
    }

    func dispatchConnectionChange(
        _ request: DisplayConnectionDispatchRequest
    ) async -> DisplayConnectionDispatchOutcome {
        let shouldSuspend = suspendFirstDispatch && dispatched.isEmpty
        dispatched.append(request)
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                firstDispatchContinuation = continuation
            }
        }
        return dispatchOutcome
    }

    func resumeFirstDispatch() {
        firstDispatchContinuation?.resume()
        firstDispatchContinuation = nil
    }

    var isQuarantineReconciliationSuspended: Bool {
        firstQuarantineContinuation != nil
    }

    func resumeFirstQuarantineReconciliation() {
        firstQuarantineContinuation?.resume()
        firstQuarantineContinuation = nil
    }

    func hasReconnectReservation(_ uuid: String) -> Bool {
        reconnectReservations.contains(uuid)
    }

    func hasPendingDisconnect(_ uuid: String) -> Bool {
        pendingDisconnectUUIDs.contains(uuid)
    }

    func hasReconnectPersistenceUncertain(_ uuid: String) -> Bool {
        reconnectPersistenceUncertainUUIDs.contains(uuid)
    }

    func hasLiveQuarantineReconciliation(_ uuid: String) -> Bool {
        liveQuarantineReconciliations.contains(uuid)
    }

    private enum FakeError: Error {
        case noObservation
        case enumerationFailed
        case persistenceFailed
    }
}

@MainActor
private final class ProductionShapedReconnectAdapter: DisplayConnectionMutationAdapter {
    enum Resolution: Equatable {
        case exactUUID
        case fallback
    }

    private let uuid: String
    private let displayID: UInt32
    private let otherUUID: String
    private let resolution: Resolution
    private var recoveryCapability: DisplayConnectionRecoveryCapability?
    private var dispatchOutcomes: [DisplayConnectionDispatchOutcome]
    private var rollbackFailures: Int
    private var recordExists = true
    private var targetIsOnline = false
    private var reconnectReservation = false
    private var liveReconnectOwner = false

    private(set) var dispatched: [DisplayConnectionDispatchRequest] = []
    private(set) var consumeCount = 0
    private(set) var osDisplayCallCount = 0
    private(set) var orphanReconciliationCount = 0
    private(set) var rollbackPersistenceWriteCount = 0

    init(
        uuid: String,
        displayID: UInt32,
        otherUUID: String,
        recoveryCapability: DisplayConnectionRecoveryCapability?,
        resolution: Resolution,
        dispatchOutcomes: [DisplayConnectionDispatchOutcome],
        rollbackFailures: Int = 0
    ) {
        self.uuid = uuid
        self.displayID = displayID
        self.otherUUID = otherUUID
        self.recoveryCapability = recoveryCapability
        self.resolution = resolution
        self.dispatchOutcomes = dispatchOutcomes
        self.rollbackFailures = rollbackFailures
    }

    var hasReconnectReservation: Bool { reconnectReservation }
    var hasLiveReconnectOwner: Bool { liveReconnectOwner }
    var recoveryCapabilityState: DisplayConnectionRecoveryCapabilityState? {
        recoveryCapability?.state
    }

    func connectionObservation() throws -> DisplayConnectionObservation {
        let otherCandidate = DisplayConnectionCandidate(
            displayID: 1,
            stableUUID: otherUUID,
            isOnline: true,
            isHardwareBackedPhysical: true,
            recoveryHardwareProof: otherHardwareProof
        )
        let targetCandidate = DisplayConnectionCandidate(
            displayID: displayID,
            stableUUID: targetIsOnline || resolution == .exactUUID ? uuid : nil,
            isOnline: targetIsOnline,
            isHardwareBackedPhysical: targetIsOnline || resolution == .exactUUID,
            recoveryHardwareProof: recoveryCapability?.hardwareProof
        )
        let candidates = [otherCandidate, targetCandidate]
        let allUUIDs = Set(candidates.compactMap(\.stableUUID))
        let onlineUUIDs = Set(candidates.compactMap { candidate in
            candidate.isOnline ? candidate.stableUUID : nil
        })
        let sessionCapability = recoveryCapability
        return DisplayConnectionObservation(
            platformSupported: true,
            allUUIDs: allUUIDs,
            onlineUUIDs: onlineUUIDs,
            intentionalDisconnectedUUIDs: recordExists ? [uuid] : [],
            reconnectReservationUUIDs: recordExists && reconnectReservation ? [uuid] : [],
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: onlineUUIDs,
            candidates: candidates,
            recoveryCapabilities: recordExists ? [recoveryCapability].compactMap { $0 } : [],
            bootSessionID: sessionCapability?.bootSessionID,
            loginSessionID: sessionCapability?.loginSessionID,
            wakeSessionID: sessionCapability?.wakeSessionID,
            topologyFingerprint: sessionCapability?.topologyFingerprint
        )
    }

    func retainDisconnectedRecord(
        _ target: DisplayConnectionTarget
    ) throws -> DisplayConnectionRecoveryCapability? {
        throw StateError.unsupportedOperation
    }

    func confirmDisconnectedRecord(uuid: String) throws {
        throw StateError.unsupportedOperation
    }

    func removeDisconnectedRecord(uuid: String) throws {
        guard uuid == self.uuid else { throw StateError.invalidState }
        recordExists = false
        recoveryCapability = nil
        reconnectReservation = false
        liveReconnectOwner = false
    }

    func consumeRecoveryCapability(
        _ capability: DisplayConnectionRecoveryCapability
    ) throws -> DisplayConnectionRecoveryCapability {
        guard reconnectReservation,
              capability.uuid == uuid,
              capability.state == .available,
              recoveryCapability == capability else {
            throw StateError.invalidState
        }
        let consumed = capability.changingState(to: .consumed)
        recoveryCapability = consumed
        consumeCount += 1
        return consumed
    }

    func reserveReconnect(uuid: String) throws {
        guard uuid == self.uuid, recordExists,
              !reconnectReservation, !liveReconnectOwner else {
            throw StateError.invalidState
        }
        reconnectReservation = true
        liveReconnectOwner = true
    }

    func releaseReconnectReservation(uuid: String) throws {
        guard uuid == self.uuid, reconnectReservation, liveReconnectOwner else {
            throw StateError.invalidState
        }
        if rollbackFailures > 0 {
            rollbackFailures -= 1
            throw StateError.persistenceFailed
        }
        reconnectReservation = false
        liveReconnectOwner = false
    }

    func rollbackRejectedReconnectBeforeDispatch(
        uuid: String,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
    ) throws {
        guard uuid == self.uuid, recordExists,
              reconnectReservation, liveReconnectOwner else {
            throw StateError.invalidState
        }
        defer { liveReconnectOwner = false }
        if let consumedRecoveryCapability {
            guard consumedRecoveryCapability.uuid == uuid,
                  consumedRecoveryCapability.state == .consumed,
                  recoveryCapability == consumedRecoveryCapability else {
                throw StateError.invalidState
            }
        } else if let capability = recoveryCapability {
            guard ![.consumed, .indeterminate].contains(capability.state) else {
                throw StateError.invalidState
            }
        }
        if rollbackFailures > 0 {
            rollbackFailures -= 1
            throw StateError.persistenceFailed
        }
        if let consumedRecoveryCapability {
            recoveryCapability = consumedRecoveryCapability.changingState(to: .available)
        }
        reconnectReservation = false
        rollbackPersistenceWriteCount += 1
    }

    func reconcileOrphanedReconnectAttempt(
        uuid: String
    ) throws -> DisplayReconnectOrphanReconciliation {
        guard uuid == self.uuid, reconnectReservation else { return .unavailable }
        guard !liveReconnectOwner else { return .liveAttempt }
        let observation = try connectionObservation()
        let reconnectResolution = DisplayConnectionRecoveryResolver.orphanedReconnectResolution(
            uuid: uuid,
            observation: observation
        )
        switch reconnectResolution {
        case .exactUUID:
            if let capability = recoveryCapability,
               [.consumed, .indeterminate].contains(capability.state) {
                recoveryCapability = capability.changingState(to: .available)
            }
        case let .oneShotRecovery(capability):
            guard recoveryCapability == capability else { return .unavailable }
            recoveryCapability = capability.changingState(to: .available)
        case .alreadyOnline:
            return .alreadyOnline
        case .unavailable:
            return .unavailable
        }
        reconnectReservation = false
        orphanReconciliationCount += 1
        return .reconciled
    }

    func reconcileQuarantinedReconnectAttempt(
        uuid: String
    ) async throws -> DisplayReconnectQuarantineReconciliation {
        .unavailable
    }

    func finishQuarantinedReconnectAttempt(uuid: String) {}

    func markReconnectAttemptIndeterminate(uuid: String) throws {
        guard uuid == self.uuid else { throw StateError.invalidState }
        liveReconnectOwner = false
        if let capability = recoveryCapability,
           capability.state != .indeterminate {
            recoveryCapability = capability.changingState(to: .indeterminate)
        }
    }

    func markRecoveryCapabilityIndeterminate(uuid: String) throws {
        try markReconnectAttemptIndeterminate(uuid: uuid)
    }

    func dispatchConnectionChange(
        _ request: DisplayConnectionDispatchRequest
    ) async -> DisplayConnectionDispatchOutcome {
        dispatched.append(request)
        guard !dispatchOutcomes.isEmpty else {
            return .rejectedBeforeDispatch("missing test dispatch outcome")
        }
        let outcome = dispatchOutcomes.removeFirst()
        switch outcome {
        case .completed:
            osDisplayCallCount += 1
            targetIsOnline = true
        case .failedAfterDispatch, .timedOut, .cancelled:
            osDisplayCallCount += 1
        case .rejectedBeforeDispatch:
            break
        }
        return outcome
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

    private enum StateError: Error {
        case invalidState
        case persistenceFailed
        case unsupportedOperation
    }
}
