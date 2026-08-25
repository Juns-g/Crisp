import XCTest
@testable import CrispControlCore

final class BoostTransitionCoordinatorTests: XCTestCase {
    func testControlDisableOutcomeSeparatesRejectionSettlingAndUnknown() {
        XCTAssertEqual(
            ExtraBrightnessControlMutationOutcome.classify(
                mutationAccepted: false,
                operationCompleted: false,
                identityMatches: true,
                persistedEnabled: false,
                liveEnabled: false,
                maxBrightness: 100,
                cleanupInProgress: false
            ),
            .rejectedBeforeAcceptance
        )
        XCTAssertEqual(
            ExtraBrightnessControlMutationOutcome.classify(
                mutationAccepted: true,
                operationCompleted: false,
                identityMatches: true,
                persistedEnabled: false,
                liveEnabled: true,
                maxBrightness: 150,
                cleanupInProgress: true
            ),
            .settling
        )
        XCTAssertEqual(
            ExtraBrightnessControlMutationOutcome.classify(
                mutationAccepted: true,
                operationCompleted: false,
                identityMatches: false,
                persistedEnabled: false,
                liveEnabled: true,
                maxBrightness: 150,
                cleanupInProgress: true
            ),
            .indeterminate
        )
    }

    func testControlDisableOutcomeRequiresTerminalCompletionForAcceptedResult() {
        XCTAssertEqual(
            ExtraBrightnessControlMutationOutcome.classify(
                mutationAccepted: true,
                operationCompleted: true,
                identityMatches: true,
                persistedEnabled: false,
                liveEnabled: false,
                maxBrightness: 100,
                cleanupInProgress: false
            ),
            .accepted
        )
        XCTAssertEqual(
            ExtraBrightnessControlMutationOutcome.classify(
                mutationAccepted: true,
                operationCompleted: false,
                identityMatches: true,
                persistedEnabled: false,
                liveEnabled: false,
                maxBrightness: 100,
                cleanupInProgress: false
            ),
            .indeterminate
        )
    }

    func testIncompleteDisableWithoutCleanupOwnershipIsIndeterminate() {
        XCTAssertEqual(
            ExtraBrightnessControlMutationOutcome.classify(
                mutationAccepted: true,
                operationCompleted: false,
                identityMatches: true,
                persistedEnabled: false,
                liveEnabled: true,
                maxBrightness: 150,
                cleanupInProgress: false
            ),
            .indeterminate
        )
    }

    func testDisableDoesNotCompleteBeforeCollapseReachesIdentity() {
        var coordinator = BoostTransitionCoordinator()
        let token = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: false)

        XCTAssertEqual(coordinator.phase(uuid: "uuid-a", identity: "object-a"), .collapsing)
        XCTAssertFalse(coordinator.completeDisable(token, atIdentity: false))
        XCTAssertEqual(coordinator.phase(uuid: "uuid-a", identity: "object-a"), .collapsing)
        XCTAssertTrue(coordinator.completeDisable(token, atIdentity: true))
        XCTAssertEqual(coordinator.phase(uuid: "uuid-a", identity: "object-a"), .disabled)
    }

    func testRapidDisableThenEnableCannotRunStaleFinishDisable() {
        var coordinator = BoostTransitionCoordinator()
        let staleDisable = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: false)
        let enable = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: true)

        XCTAssertFalse(coordinator.completeDisable(staleDisable, atIdentity: true))
        XCTAssertTrue(coordinator.completeEnable(enable))
        XCTAssertEqual(coordinator.phase(uuid: "uuid-a", identity: "object-a"), .enabled)
    }

    func testRapidEnableThenDisableEndsDisabled() {
        var coordinator = BoostTransitionCoordinator()
        let staleEnable = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: true)
        let disable = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: false)

        XCTAssertFalse(coordinator.completeEnable(staleEnable))
        XCTAssertTrue(coordinator.completeDisable(disable, atIdentity: true))
        XCTAssertEqual(coordinator.phase(uuid: "uuid-a", identity: "object-a"), .disabled)
    }

    func testDisconnectDuringCollapseCannotMutateReusedDisplayIdentity() {
        var coordinator = BoostTransitionCoordinator()
        let stale = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: false)
        coordinator.invalidate(uuid: "uuid-a", identity: "object-a")
        _ = coordinator.begin(uuid: "uuid-b", identity: "object-b", enabled: true)

        XCTAssertFalse(coordinator.accepts(stale, currentUUID: "uuid-b", currentIdentity: "object-b"))
        XCTAssertFalse(coordinator.completeDisable(stale, atIdentity: true))
    }

    func testHeadroomPollCannotOverrideCollapse() {
        var coordinator = BoostTransitionCoordinator()
        _ = coordinator.begin(uuid: "uuid-a", identity: "object-a", enabled: false)
        XCTAssertFalse(coordinator.headroomMaySync(uuid: "uuid-a", identity: "object-a"))
    }
}
