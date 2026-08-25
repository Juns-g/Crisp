import XCTest
@testable import CrispControlCore

final class PhysicalDisplaySafetyPolicyTests: XCTestCase {
    private let duplicateUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let uniqueUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func testUnknownActivePhysicalEnumerationFailsClosedForDisconnectAndEmergencyRecovery() {
        XCTAssertTrue(
            PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect(
                targetIsActive: true,
                activePhysicalDisplayCount: nil
            )
        )
        XCTAssertTrue(
            PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect(
                targetIsActive: false,
                activePhysicalDisplayCount: nil
            )
        )
        XCTAssertFalse(
            PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
                activePhysicalDisplayCount: nil
            )
        )
        XCTAssertTrue(
            PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
                activePhysicalDisplayCount: 0
            )
        )
        XCTAssertFalse(
            PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
                activePhysicalDisplayCount: 1
            )
        )
    }

    func testUniqueExactUUIDSelectionDropsDuplicatesMissingAndLegacyIdentities() {
        let selected = PhysicalDisplaySafetyPolicy.uniqueExactUUIDDisplayIDs([
            (uuid: duplicateUUID, displayID: 10),
            (uuid: duplicateUUID, displayID: 11),
            (uuid: uniqueUUID, displayID: 12),
            (uuid: nil, displayID: 13),
            (uuid: "id-14", displayID: 14),
            (uuid: "Fixture External", displayID: 15)
        ])

        XCTAssertNil(selected[duplicateUUID])
        XCTAssertEqual(selected[uniqueUUID], 12)
        XCTAssertEqual(selected.count, 1)
    }

    func testKnownCountsPreserveLastDisplayProtectionWithoutInventingZero() {
        XCTAssertTrue(
            PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect(
                targetIsActive: true,
                activePhysicalDisplayCount: 1
            )
        )
        XCTAssertFalse(
            PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect(
                targetIsActive: true,
                activePhysicalDisplayCount: 2
            )
        )
        XCTAssertFalse(
            PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect(
                targetIsActive: false,
                activePhysicalDisplayCount: 1
            )
        )
    }

    func testExactStableUUIDValidationRejectsLegacyAndHumanReadableIdentities() {
        for invalid in ["id-123", "Fixture External", "main", "builtin", "not-a-uuid"] {
            XCTAssertFalse(ControlRequest.isExactDisplayUUID(invalid), invalid)
        }
        XCTAssertTrue(
            ControlRequest.isExactDisplayUUID("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        )
    }
}
