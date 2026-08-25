import XCTest
@testable import CrispControlCore

final class HDRMutationCoordinatorTests: XCTestCase {
    func testHDRSetWaitsForMatchingReadbackAndRoutesOnlyAfterVerification() {
        var coordinator = HDRMutationCoordinator()
        let token = coordinator.begin(uuid: "uuid-a", identity: "object-a", requested: true)
        XCTAssertTrue(coordinator.recordSetterInvocation(token))

        XCTAssertFalse(coordinator.observe(
            token, currentUUID: "uuid-a", currentIdentity: "object-a", readback: false
        ))
        XCTAssertNil(coordinator.verifiedRoutingState(for: token))
        XCTAssertTrue(coordinator.observe(
            token, currentUUID: "uuid-a", currentIdentity: "object-a", readback: true
        ))
        XCTAssertEqual(coordinator.verifiedRoutingState(for: token), true)
    }

    func testDisplayReassignmentDuringHDRSetFailsClosed() {
        var coordinator = HDRMutationCoordinator()
        let token = coordinator.begin(uuid: "uuid-a", identity: "object-a", requested: true)
        XCTAssertFalse(coordinator.observe(
            token, currentUUID: "uuid-b", currentIdentity: "object-b", readback: true
        ))
        XCTAssertNil(coordinator.verifiedRoutingState(for: token))
    }

    func testNewerHDRRequestInvalidatesStaleReadback() {
        var coordinator = HDRMutationCoordinator()
        let stale = coordinator.begin(uuid: "uuid-a", identity: "object-a", requested: false)
        let newest = coordinator.begin(uuid: "uuid-a", identity: "object-a", requested: true)
        XCTAssertTrue(coordinator.recordSetterInvocation(newest))

        XCTAssertFalse(coordinator.observe(
            stale, currentUUID: "uuid-a", currentIdentity: "object-a", readback: false
        ))
        XCTAssertTrue(coordinator.observe(
            newest, currentUUID: "uuid-a", currentIdentity: "object-a", readback: true
        ))
    }
}
