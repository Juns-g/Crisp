import XCTest
@testable import CrispControlCore

final class DisplayConnectionRecoveryTests: XCTestCase {
    private let targetUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func testMachSleepOffsetTokenParsesAndMatchesOnlyNarrowSamplingJitter() {
        let nanoseconds: UInt64 = 10_000_000_000
        let token = DisplayConnectionMachSleepOffsetToken.encode(nanoseconds: nanoseconds)
        let jittered = DisplayConnectionMachSleepOffsetToken.encode(
            nanoseconds: nanoseconds
                + DisplayConnectionMachSleepOffsetToken.matchingToleranceNanoseconds
        )

        XCTAssertEqual(token, "mach-sleep-offset-v1:10000000000")
        XCTAssertEqual(DisplayConnectionMachSleepOffsetToken.parse(token), nanoseconds)
        XCTAssertTrue(DisplayConnectionMachSleepOffsetToken.matches(
            persisted: token,
            current: token
        ))
        XCTAssertTrue(DisplayConnectionMachSleepOffsetToken.matches(
            persisted: token,
            current: jittered
        ))
    }

    func testMachSleepOffsetTokenRejectsLegacyAndMalformedValues() {
        let valid = DisplayConnectionMachSleepOffsetToken.encode(nanoseconds: 0)
        let malformed = [
            "0:0",
            "",
            "mach-sleep-offset-v1:",
            "mach-sleep-offset-v1:-1",
            "mach-sleep-offset-v1:+1",
            "mach-sleep-offset-v1:01",
            "mach-sleep-offset-v2:0"
        ]

        for token in malformed {
            XCTAssertNil(DisplayConnectionMachSleepOffsetToken.parse(token))
            XCTAssertFalse(DisplayConnectionMachSleepOffsetToken.matches(
                persisted: token,
                current: valid
            ))
        }
    }

    func testMachSleepOffsetTokenRejectsOffsetChangeBeyondSamplingTolerance() {
        let nanoseconds: UInt64 = 10_000_000_000
        let persisted = DisplayConnectionMachSleepOffsetToken.encode(nanoseconds: nanoseconds)
        let afterSleep = DisplayConnectionMachSleepOffsetToken.encode(
            nanoseconds: nanoseconds
                + DisplayConnectionMachSleepOffsetToken.matchingToleranceNanoseconds
                + 1
        )

        XCTAssertFalse(DisplayConnectionMachSleepOffsetToken.matches(
            persisted: persisted,
            current: afterSleep
        ))
    }

    func testMachSleepOffsetTokenUsesBoundedContinuousClockSandwich() throws {
        let awake = try XCTUnwrap(DisplayConnectionMachSleepOffsetToken.make(
            continuousBeforeTicks: 1_000,
            absoluteTicks: 1_001,
            continuousAfterTicks: 1_002,
            timebaseNumerator: 1,
            timebaseDenominator: 1
        ))
        let awakeWithOrderingJitter = try XCTUnwrap(DisplayConnectionMachSleepOffsetToken.make(
            continuousBeforeTicks: 1_000,
            absoluteTicks: 1_003,
            continuousAfterTicks: 1_002,
            timebaseNumerator: 1,
            timebaseDenominator: 1
        ))
        let afterOneSecondOfSleep = try XCTUnwrap(DisplayConnectionMachSleepOffsetToken.make(
            continuousBeforeTicks: 1_000_001_000,
            absoluteTicks: 1_001,
            continuousAfterTicks: 1_000_001_002,
            timebaseNumerator: 1,
            timebaseDenominator: 1
        ))

        XCTAssertEqual(DisplayConnectionMachSleepOffsetToken.parse(awake), 0)
        XCTAssertEqual(DisplayConnectionMachSleepOffsetToken.parse(awakeWithOrderingJitter), 0)
        XCTAssertEqual(
            DisplayConnectionMachSleepOffsetToken.parse(afterOneSecondOfSleep),
            1_000_000_000
        )
        XCTAssertNil(DisplayConnectionMachSleepOffsetToken.make(
            continuousBeforeTicks: 0,
            absoluteTicks: 0,
            continuousAfterTicks:
                DisplayConnectionMachSleepOffsetToken.maximumSamplingIntervalNanoseconds + 1,
            timebaseNumerator: 1,
            timebaseDenominator: 1
        ))
        XCTAssertNil(DisplayConnectionMachSleepOffsetToken.make(
            continuousBeforeTicks: 0,
            absoluteTicks: 0,
            continuousAfterTicks: 1,
            timebaseNumerator: 1,
            timebaseDenominator: 0
        ))
    }

    func testFallbackRequiresConfirmedPendingFreeIntentionalRecordAtEveryResolverBoundary() {
        let available = capability(state: .available)
        let pending = observation(
            records: [targetUUID],
            pending: [targetUUID],
            capability: available
        )
        XCTAssertEqual(
            DisplayConnectionRecoveryResolver.reconnectResolution(
                uuid: targetUUID,
                observation: pending
            ),
            .unavailable
        )

        let missingRecord = observation(records: [], capability: available)
        XCTAssertEqual(
            DisplayConnectionRecoveryResolver.reconnectResolution(
                uuid: targetUUID,
                observation: missingRecord
            ),
            .unavailable
        )
        XCTAssertFalse(
            DisplayConnectionRecoveryResolver.authorizesConsumedRecoveryDispatch(
                uuid: targetUUID,
                displayID: 2,
                observation: observation(
                    records: [],
                    capability: capability(state: .consumed)
                )
            )
        )
    }

    func testTopologyFingerprintIsOrderIndependentAndRejectsIncompleteEnumeration() {
        let first = framebuffer(
            registryEntryID: 20,
            vendor: 1715,
            product: 10068,
            serial: 16843009
        )
        let second = framebuffer(
            registryEntryID: 10,
            vendor: 1552,
            product: 41202,
            serial: 33624064
        )
        XCTAssertEqual(
            DisplayConnectionTopologyFingerprint.make(
                displayIDs: [2, 1],
                framebufferSnapshot: [first, second]
            ),
            DisplayConnectionTopologyFingerprint.make(
                displayIDs: [1, 2],
                framebufferSnapshot: [second, first]
            )
        )
        XCTAssertNil(DisplayConnectionTopologyFingerprint.make(
            displayIDs: [1, 1],
            framebufferSnapshot: [first]
        ))
        XCTAssertNil(DisplayConnectionTopologyFingerprint.make(
            displayIDs: [1],
            framebufferSnapshot: [framebuffer(
                registryEntryID: nil,
                vendor: 1715,
                product: 10068,
                serial: 16843009
            )]
        ))
        XCTAssertNil(DisplayConnectionTopologyFingerprint.make(
            displayIDs: [1, 2],
            framebufferSnapshot: [first, framebuffer(
                registryEntryID: 20,
                vendor: 1552,
                product: 41202,
                serial: 33624064
            )]
        ))
    }

    func testRetainedProofRequiresDirectSavedIDIdentityAndUniqueFramebufferBinding() {
        let retained = hardwareProof(vendor: 1715, product: 10068, serial: 16843009)
        let exactIdentity = retained.identity
        let exactFramebuffer = framebuffer(
            registryEntryID: 20,
            vendor: 1715,
            product: 10068,
            serial: 16843009
        )

        XCTAssertTrue(DisplayConnectionRecoveryProofBinder.isDirectlyBound(
            retainedProof: retained,
            currentIsBuiltIn: false,
            currentIdentity: exactIdentity,
            framebufferSnapshot: [exactFramebuffer]
        ))

        let unsafeCurrentIdentities: [HardwareDisplayIdentity?] = [
            nil,
            HardwareDisplayIdentity(vendorID: 0, productID: 0, serialNumber: 0),
            HardwareDisplayIdentity(vendorID: 1715, productID: nil, serialNumber: 16843009),
            HardwareDisplayIdentity(vendorID: 1715, productID: 10068, serialNumber: 99)
        ]
        for currentIdentity in unsafeCurrentIdentities {
            XCTAssertFalse(DisplayConnectionRecoveryProofBinder.isDirectlyBound(
                retainedProof: retained,
                currentIsBuiltIn: false,
                currentIdentity: currentIdentity,
                framebufferSnapshot: [exactFramebuffer]
            ))
        }

        XCTAssertFalse(DisplayConnectionRecoveryProofBinder.isDirectlyBound(
            retainedProof: retained,
            currentIsBuiltIn: false,
            currentIdentity: exactIdentity,
            framebufferSnapshot: [exactFramebuffer, exactFramebuffer]
        ))
    }

    func testFallbackRejectsInternallyContradictoryEnumeration() {
        let available = capability(state: .available)
        let contradictory = observation(
            records: [targetUUID],
            capability: available,
            activePhysicalViewableUUIDs: [targetUUID]
        )
        XCTAssertEqual(
            DisplayConnectionRecoveryResolver.reconnectResolution(
                uuid: targetUUID,
                observation: contradictory
            ),
            .unavailable
        )
    }

    func testRejectedFallbackRollbackPersistsOneEnvelopeAndRestoresOnlyExactConsumedCapability() throws {
        let consumed = capability(state: .consumed)
        let current = persistenceEnvelope(
            capability: consumed,
            reconnectReservations: [targetUUID]
        )
        var persisted: [DisplayConnectionPersistenceEnvelope] = []

        let rolledBack = try RejectedReconnectRollback.persistAndVerify(
            uuid: targetUUID,
            consumedRecoveryCapability: consumed,
            currentState: current
        ) { proposed in
            persisted.append(proposed)
            return try JSONDecoder().decode(
                DisplayConnectionPersistenceEnvelope.self,
                from: JSONEncoder().encode(proposed)
            )
        }

        XCTAssertEqual(persisted.count, 1)
        XCTAssertEqual(persisted, [rolledBack])
        XCTAssertFalse(rolledBack.reconnectReservationSet.contains(targetUUID))
        XCTAssertEqual(rolledBack.records.first?.recoveryCapability?.state, .available)
    }

    func testRejectedExactRollbackPreservesCapabilityWhileClearingReservation() throws {
        let invalidated = capability(state: .invalidatedByWake)
        let current = persistenceEnvelope(
            capability: invalidated,
            reconnectReservations: [targetUUID]
        )
        var persistenceWriteCount = 0

        let rolledBack = try RejectedReconnectRollback.persistAndVerify(
            uuid: targetUUID,
            consumedRecoveryCapability: nil,
            currentState: current
        ) { proposed in
            persistenceWriteCount += 1
            return proposed
        }

        XCTAssertEqual(persistenceWriteCount, 1)
        XCTAssertFalse(rolledBack.reconnectReservationSet.contains(targetUUID))
        XCTAssertEqual(rolledBack.records.first?.recoveryCapability, invalidated)
    }

    func testRejectedFallbackRollbackRejectsInvalidStateBeforePersistence() {
        let unsafeStates: [DisplayConnectionRecoveryCapabilityState] = [
            .prepared, .available, .invalidatedByWake, .indeterminate
        ]
        for state in unsafeStates {
            let invalid = capability(state: state)
            let current = persistenceEnvelope(
                capability: invalid,
                reconnectReservations: [targetUUID]
            )
            var persistenceWriteCount = 0

            XCTAssertThrowsError(try RejectedReconnectRollback.persistAndVerify(
                uuid: targetUUID,
                consumedRecoveryCapability: invalid,
                currentState: current
            ) { proposed in
                persistenceWriteCount += 1
                return proposed
            })
            XCTAssertEqual(persistenceWriteCount, 0)
            XCTAssertEqual(current.reconnectReservationSet, [targetUUID])
            XCTAssertEqual(current.records.first?.recoveryCapability?.state, state)
        }
    }

    func testRejectedFallbackRollbackReadBackFailureLeavesOriginalUncertainEnvelope() {
        let consumed = capability(state: .consumed)
        let current = persistenceEnvelope(
            capability: consumed,
            reconnectReservations: [targetUUID]
        )
        var persistenceWriteCount = 0

        XCTAssertThrowsError(try RejectedReconnectRollback.persistAndVerify(
            uuid: targetUUID,
            consumedRecoveryCapability: consumed,
            currentState: current
        ) { _ in
            persistenceWriteCount += 1
            return current
        })
        XCTAssertEqual(persistenceWriteCount, 1)
        XCTAssertEqual(current.reconnectReservationSet, [targetUUID])
        XCTAssertEqual(current.records.first?.recoveryCapability?.state, .consumed)
    }

    private func observation(
        records: Set<String>,
        pending: Set<String> = [],
        capability: DisplayConnectionRecoveryCapability,
        activePhysicalViewableUUIDs: Set<String>? = nil
    ) -> DisplayConnectionObservation {
        let targetProof = hardwareProof(vendor: 1715, product: 10068, serial: 16843009)
        return DisplayConnectionObservation(
            platformSupported: true,
            allUUIDs: [otherUUID],
            onlineUUIDs: [otherUUID],
            intentionalDisconnectedUUIDs: records,
            pendingDisconnectUUIDs: pending,
            virtualUUIDs: [],
            activePhysicalViewableUUIDs: activePhysicalViewableUUIDs ?? [otherUUID],
            candidates: [
                DisplayConnectionCandidate(
                    displayID: 1,
                    stableUUID: otherUUID,
                    isOnline: true,
                    isHardwareBackedPhysical: true,
                    recoveryHardwareProof: hardwareProof(vendor: 1552, product: 41202, serial: 33624064)
                ),
                DisplayConnectionCandidate(
                    displayID: 2,
                    stableUUID: nil,
                    isOnline: false,
                    isHardwareBackedPhysical: false,
                    recoveryHardwareProof: targetProof
                )
            ],
            recoveryCapabilities: [capability],
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A"
        )
    }

    private func capability(
        state: DisplayConnectionRecoveryCapabilityState
    ) -> DisplayConnectionRecoveryCapability {
        DisplayConnectionRecoveryCapability(
            uuid: targetUUID,
            displayID: 2,
            hardwareProof: hardwareProof(vendor: 1715, product: 10068, serial: 16843009),
            bootSessionID: "boot-A",
            loginSessionID: "login-A",
            wakeSessionID: "mach-sleep-offset-v1:10000000000",
            topologyFingerprint: "topology-A",
            state: state
        )
    }

    private func persistenceEnvelope(
        capability: DisplayConnectionRecoveryCapability?,
        reconnectReservations: Set<String>
    ) -> DisplayConnectionPersistenceEnvelope {
        DisplayConnectionPersistenceEnvelope(
            records: [DisplayConnectionPersistedRecord(
                uuid: targetUUID,
                displayID: 2,
                name: "Target",
                width: 2560,
                height: 1440,
                recoveryCapability: capability
            )],
            pendingUUIDs: [],
            reconnectReservationUUIDs: reconnectReservations
        )
    }

    private func hardwareProof(
        vendor: UInt32,
        product: UInt32,
        serial: UInt32
    ) -> DisplayConnectionRecoveryHardwareProof {
        DisplayConnectionRecoveryHardwareProof(
            isBuiltIn: false,
            identity: HardwareDisplayIdentity(
                vendorID: vendor,
                productID: product,
                serialNumber: serial
            )
        )
    }

    private func framebuffer(
        registryEntryID: UInt64?,
        vendor: UInt32,
        product: UInt32,
        serial: UInt32
    ) -> HardwareFramebufferIdentityEvidence {
        HardwareFramebufferIdentityEvidence(
            registryEntryID: registryEntryID,
            hasEDIDUUID: true,
            identity: HardwareDisplayIdentity(
                vendorID: vendor,
                productID: product,
                serialNumber: serial
            )
        )
    }
}
