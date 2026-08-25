import XCTest
@testable import CrispControlCore

@MainActor
final class DisplayConnectionCoordinatorTests: XCTestCase {
    private let targetUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func testDisconnectSucceedsOnlyAfterSameUUIDIsOfflineAndRecordIsRetained() async throws {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(online: [targetUUID, otherUUID], records: [targetUUID]),
                observation(online: [otherUUID], records: [targetUUID])
            ],
            dispatchOutcome: .completed
        )

        let result = try await coordinator(adapter).disconnect(target(targetUUID))

        XCTAssertEqual(result.displayUUID, targetUUID)
        XCTAssertEqual(result.requestedConnectionState, .disconnected)
        XCTAssertEqual(result.observedConnectionState, .disconnected)
        XCTAssertEqual(result.verification, .sameUUIDEnumeration)
        XCTAssertEqual(adapter.dispatched, [.init(uuid: targetUUID, state: .disconnected)])
        XCTAssertEqual(adapter.retained, [targetUUID])
        XCTAssertEqual(adapter.confirmed, [targetUUID])
        XCTAssertTrue(adapter.removed.isEmpty)
    }

    func testDisconnectWithoutRetainedRecordTruthIsIndeterminate() async {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(online: [otherUUID], records: []),
                observation(online: [otherUUID], records: [])
            ],
            dispatchOutcome: .completed
        )

        await assertFailure(
            from: { try await self.coordinator(adapter).disconnect(self.target(self.targetUUID)) },
            classification: .indeterminate,
            uuid: targetUUID
        )
        XCTAssertEqual(adapter.retained, [targetUUID])
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
        XCTAssertEqual(adapter.dispatched, [.init(uuid: targetUUID, state: .connected)])
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
        let adapter = FakeConnectionAdapter(
            observations: [observation(online: [targetUUID, otherUUID], records: [])],
            dispatchOutcome: .rejectedBeforeDispatch("target disappeared during re-resolution")
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
            let adapter = FakeConnectionAdapter(
                observations: [observation(online: [targetUUID, otherUUID], records: [])],
                dispatchOutcome: outcome
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

    func testCancellationDuringSettlementIsIndeterminateWithoutAutomaticRetry() async {
        let adapter = FakeConnectionAdapter(
            observations: [
                observation(online: [targetUUID, otherUUID], records: []),
                observation(online: [targetUUID, otherUUID], records: [targetUUID])
            ],
            dispatchOutcome: .completed
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

    private func coordinator(_ adapter: FakeConnectionAdapter) -> DisplayConnectionMutationCoordinator {
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
        virtual: Set<String> = [],
        activePhysical: Set<String>? = nil
    ) -> DisplayConnectionObservation {
        DisplayConnectionObservation(
            platformSupported: platformSupported,
            allUUIDs: all ?? online.union(records),
            onlineUUIDs: online,
            intentionalDisconnectedUUIDs: records,
            virtualUUIDs: virtual,
            activePhysicalViewableUUIDs: activePhysical ?? online.subtracting(virtual)
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
}

@MainActor
private final class FakeConnectionAdapter: DisplayConnectionMutationAdapter {
    struct Dispatch: Equatable {
        let uuid: String
        let state: DisplayConnectionState
    }

    private var observations: [DisplayConnectionObservation]
    private let dispatchOutcome: DisplayConnectionDispatchOutcome
    private(set) var dispatched: [Dispatch] = []
    private(set) var retained: [String] = []
    private(set) var confirmed: [String] = []
    private(set) var removed: [String] = []

    init(
        observations: [DisplayConnectionObservation],
        dispatchOutcome: DisplayConnectionDispatchOutcome
    ) {
        self.observations = observations
        self.dispatchOutcome = dispatchOutcome
    }

    func connectionObservation() throws -> DisplayConnectionObservation {
        guard !observations.isEmpty else { throw FakeError.noObservation }
        if observations.count == 1 { return observations[0] }
        return observations.removeFirst()
    }

    func retainDisconnectedRecord(_ target: DisplayConnectionTarget) throws {
        retained.append(target.uuid)
    }

    func removeDisconnectedRecord(uuid: String) throws {
        removed.append(uuid)
    }

    func confirmDisconnectedRecord(uuid: String) throws {
        confirmed.append(uuid)
    }

    func dispatchConnectionChange(
        uuid: String,
        requestedState: DisplayConnectionState
    ) async -> DisplayConnectionDispatchOutcome {
        dispatched.append(.init(uuid: uuid, state: requestedState))
        return dispatchOutcome
    }

    private enum FakeError: Error { case noObservation }
}
