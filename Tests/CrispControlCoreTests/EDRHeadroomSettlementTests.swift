import XCTest
@testable import CrispControlCore

@MainActor
final class EDRHeadroomSettlementTests: XCTestCase {
    func testDelayedHeadroomBecomesReadyWithinBoundedSamples() async {
        var samples = [1.0, 1.03, 1.2]
        let result = await EDRHeadroomSettlement.wait(
            maxSamples: 3,
            threshold: 1.05,
            isCurrent: { true },
            isCapable: { true },
            potentialHeadroom: { samples.removeFirst() },
            pause: {}
        )

        XCTAssertEqual(result, .ready(potentialHeadroom: 1.2))
        XCTAssertTrue(samples.isEmpty)
    }

    func testHeadroomTimeoutIsDistinctFromPreferenceVerification() async {
        var sampleCount = 0
        let result = await EDRHeadroomSettlement.wait(
            maxSamples: 3,
            threshold: 1.05,
            isCurrent: { true },
            isCapable: { true },
            potentialHeadroom: {
                sampleCount += 1
                return 1.0
            },
            pause: {}
        )

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(sampleCount, 3)
    }

    func testDisconnectOrDisplayReassignmentInvalidatesSettlement() async {
        var current = true
        let result = await EDRHeadroomSettlement.wait(
            maxSamples: 4,
            threshold: 1.05,
            isCurrent: { current },
            isCapable: { true },
            potentialHeadroom: { 1.0 },
            pause: { current = false }
        )

        XCTAssertEqual(result, .invalidated)
    }

    func testNewerToggleSupersedesOlderSettlement() async {
        var generationIsCurrent = true
        let result = await EDRHeadroomSettlement.wait(
            maxSamples: 4,
            threshold: 1.05,
            isCurrent: { generationIsCurrent },
            isCapable: { true },
            potentialHeadroom: { 1.0 },
            pause: { generationIsCurrent = false }
        )

        XCTAssertEqual(result, .invalidated)
    }

    func testCancellationFromCommandOwnedPausePropagates() async {
        do {
            _ = try await EDRHeadroomSettlement.wait(
                maxSamples: 3,
                threshold: 1.05,
                isCurrent: { true },
                isCapable: { true },
                potentialHeadroom: { 1.0 },
                pause: { throw CancellationError() }
            )
            XCTFail("cancellation must escape the settlement helper")
        } catch is CancellationError {
            // Expected: the dispatcher classifies a post-mutation cancellation.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
