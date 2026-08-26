import XCTest
@testable import CrispControlCore

final class HardwareProofClassifierTests: XCTestCase {
    private let targetIdentity = HardwareDisplayIdentity(
        vendorID: 1715,
        productID: 10068,
        serialNumber: 16843009
    )

    func testRealFramebufferTopologyAcceptsSingleEDIDBackedExactIdentity() {
        let completeFramebufferSnapshot = [
            HardwareFramebufferIdentityEvidence(
                hasEDIDUUID: false,
                identity: HardwareDisplayIdentity(
                    vendorID: 1552,
                    productID: nil,
                    serialNumber: nil
                )
            ),
            HardwareFramebufferIdentityEvidence(
                hasEDIDUUID: true,
                identity: targetIdentity
            ),
            HardwareFramebufferIdentityEvidence(
                hasEDIDUUID: false,
                identity: nil
            )
        ]

        XCTAssertTrue(
            isHardwareBacked(framebufferSnapshot: completeFramebufferSnapshot),
            "non-EDID built-in and placeholder entries must not hide one exact EDID-backed match"
        )
    }

    func testExternalWithUniqueExactFramebufferIdentityIsAccepted() {
        XCTAssertTrue(isHardwareBacked(framebufferSnapshot: [
            candidate(
                HardwareDisplayIdentity(
                    vendorID: 1552,
                    productID: 41202,
                    serialNumber: 33624064
                )
            ),
            candidate(targetIdentity)
        ]))
    }

    func testNoEDIDBackedExactFramebufferMatchIsRejected() {
        XCTAssertFalse(isHardwareBacked(framebufferSnapshot: [
            candidate(
                HardwareDisplayIdentity(
                    vendorID: 1715,
                    productID: 10069,
                    serialNumber: 16843009
                )
            )
        ]))
        XCTAssertFalse(isHardwareBacked(framebufferSnapshot: [
            HardwareFramebufferIdentityEvidence(
                hasEDIDUUID: false,
                identity: targetIdentity
            )
        ]))
    }

    func testDuplicateEDIDBackedExactFramebufferIdentitiesAreRejected() {
        XCTAssertFalse(isHardwareBacked(framebufferSnapshot: [
            candidate(targetIdentity),
            candidate(targetIdentity)
        ]))
    }

    func testNonEDIDCompleteDuplicateDoesNotCreateAmbiguity() {
        XCTAssertTrue(isHardwareBacked(framebufferSnapshot: [
            candidate(targetIdentity),
            HardwareFramebufferIdentityEvidence(
                hasEDIDUUID: false,
                identity: targetIdentity
            )
        ]))
    }

    func testZeroOrMissingTargetIdentityFieldsAreRejected() {
        let incompleteIdentities = [
            HardwareDisplayIdentity(vendorID: 0, productID: 10068, serialNumber: 16843009),
            HardwareDisplayIdentity(vendorID: 1715, productID: 0, serialNumber: 16843009),
            HardwareDisplayIdentity(vendorID: 1715, productID: 10068, serialNumber: 0),
            HardwareDisplayIdentity(vendorID: nil, productID: 10068, serialNumber: 16843009),
            HardwareDisplayIdentity(vendorID: 1715, productID: nil, serialNumber: 16843009),
            HardwareDisplayIdentity(vendorID: 1715, productID: 10068, serialNumber: nil)
        ]

        for identity in incompleteIdentities {
            XCTAssertFalse(isHardwareBacked(
                target: identity,
                framebufferSnapshot: [candidate(identity)]
            ))
        }
    }

    func testEDIDBackedIncompleteIdentityRejectsAll() {
        let incompleteCandidates = [
            HardwareDisplayIdentity(vendorID: 0, productID: 10068, serialNumber: 16843009),
            HardwareDisplayIdentity(vendorID: 1715, productID: nil, serialNumber: 16843009),
            nil
        ]

        for incompleteCandidate in incompleteCandidates {
            XCTAssertFalse(isHardwareBacked(framebufferSnapshot: [
                candidate(targetIdentity),
                HardwareFramebufferIdentityEvidence(
                    hasEDIDUUID: true,
                    identity: incompleteCandidate
                )
            ]))
        }
    }

    func testVendorAndProductOnlyMatchIsRejected() {
        XCTAssertFalse(isHardwareBacked(framebufferSnapshot: [
            candidate(
                HardwareDisplayIdentity(
                    vendorID: 1715,
                    productID: 10068,
                    serialNumber: 16843010
                )
            )
        ]))
    }

    func testEnumerationFailureFailsClosed() {
        XCTAssertFalse(isHardwareBacked(framebufferSnapshot: nil))
    }

    func testKnownVirtualIsRejectedEvenWithUniqueExactFramebufferMatch() {
        XCTAssertFalse(isHardwareBacked(
            isKnownVirtual: true,
            framebufferSnapshot: [candidate(targetIdentity)]
        ))
    }

    func testBuiltInAndDisplayConnectProofRemainAccepted() {
        XCTAssertTrue(isHardwareBacked(isBuiltin: true, framebufferSnapshot: nil))

        let displayConnectEvidence = HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: false,
            isKnownVirtual: false,
            hasIOServicePort: true,
            ioServiceConformsToDisplayConnect: true
        )
        XCTAssertTrue(
            HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(displayConnectEvidence)
        )
    }

    private func candidate(
        _ identity: HardwareDisplayIdentity
    ) -> HardwareFramebufferIdentityEvidence {
        HardwareFramebufferIdentityEvidence(hasEDIDUUID: true, identity: identity)
    }

    private func isHardwareBacked(
        target: HardwareDisplayIdentity? = nil,
        isBuiltin: Bool = false,
        isKnownVirtual: Bool = false,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?
    ) -> Bool {
        let evidence = HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: isBuiltin,
            isKnownVirtual: isKnownVirtual,
            hasIOServicePort: false,
            ioServiceConformsToDisplayConnect: false,
            coreGraphicsIdentity: target ?? targetIdentity,
            framebufferSnapshot: framebufferSnapshot
        )
        return HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(evidence)
    }
}
