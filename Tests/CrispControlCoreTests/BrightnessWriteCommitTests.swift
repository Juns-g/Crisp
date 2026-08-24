import XCTest
@testable import CrispControlCore

final class BrightnessWriteCommitTests: XCTestCase {
    @MainActor
    func testFailedWriteDoesNotCommitManualAdjustmentSideEffects() async {
        var committed = false

        do {
            _ = try await BrightnessWriteCommit.perform(
                write: { throw TestWriteError.rejected },
                commit: { (_: Double) in committed = true }
            ) as Double
            XCTFail("expected backend rejection")
        } catch {
            XCTAssertEqual(error as? TestWriteError, .rejected)
        }

        XCTAssertFalse(committed)
    }

    @MainActor
    func testSuccessfulWriteCommitsExactlyOnce() async throws {
        var committedValues: [Double] = []

        let value = try await BrightnessWriteCommit.perform(
            write: { 42.0 },
            commit: { committedValues.append($0) }
        )

        XCTAssertEqual(value, 42)
        XCTAssertEqual(committedValues, [42])
    }

    @MainActor
    func testCancellationDuringWritePreventsCommit() async {
        var committed = false
        let task = Task {
            try await BrightnessWriteCommit.perform(
                write: {
                    try? await Task.sleep(for: .seconds(5))
                    return 42.0
                },
                commit: { _ in committed = true }
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: an in-flight backend may have changed hardware, but
            // no success-only model/preset side effects may be committed.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertFalse(committed)
    }
}

private enum TestWriteError: Error, Equatable {
    case rejected
}
