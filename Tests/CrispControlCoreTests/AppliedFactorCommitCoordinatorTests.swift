import XCTest
@testable import CrispControlCore

final class AppliedFactorCommitCoordinatorTests: XCTestCase {
    func testDelayedExternalWriteIsUnknownUntilQueueReportsCommit() {
        var coordinator = AppliedFactorCommitCoordinator()
        let token = coordinator.begin(uuid: "uuid-a", identity: "object-a", factor: 1.4)

        XCTAssertNil(coordinator.appliedFactor(uuid: "uuid-a", identity: "object-a"))
        XCTAssertTrue(coordinator.complete(
            token,
            queueAccepted: true,
            currentUUID: "uuid-a",
            currentIdentity: "object-a"
        ))
        XCTAssertEqual(coordinator.appliedFactor(uuid: "uuid-a", identity: "object-a"), 1.4)
    }

    func testUUIDRejectedQueuedWriteDoesNotPublishFactorOrSatisfyIdentityBarrier() {
        var coordinator = AppliedFactorCommitCoordinator()
        let token = coordinator.begin(uuid: "uuid-a", identity: "object-a", factor: 1)

        XCTAssertFalse(coordinator.complete(
            token,
            queueAccepted: false,
            currentUUID: "uuid-b",
            currentIdentity: "object-b"
        ))
        XCTAssertNil(coordinator.appliedFactor(uuid: "uuid-a", identity: "object-a"))
        XCTAssertFalse(coordinator.isCommitted(
            factor: 1,
            uuid: "uuid-a",
            identity: "object-a",
            tolerance: 0.001
        ))
    }

    func testNewerCollapseOrReapplyWriteRejectsDelayedOlderCompletion() {
        var coordinator = AppliedFactorCommitCoordinator()
        let collapse = coordinator.begin(uuid: "uuid-a", identity: "object-a", factor: 1.2)
        let reapply = coordinator.begin(uuid: "uuid-a", identity: "object-a", factor: 1)

        XCTAssertFalse(coordinator.complete(
            collapse,
            queueAccepted: true,
            currentUUID: "uuid-a",
            currentIdentity: "object-a"
        ))
        XCTAssertNil(coordinator.appliedFactor(uuid: "uuid-a", identity: "object-a"))
        XCTAssertTrue(coordinator.complete(
            reapply,
            queueAccepted: true,
            currentUUID: "uuid-a",
            currentIdentity: "object-a"
        ))
        XCTAssertTrue(coordinator.isCommitted(
            factor: 1,
            uuid: "uuid-a",
            identity: "object-a",
            tolerance: 0.001
        ))
    }
}
