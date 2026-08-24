import XCTest
@testable import CrispControlCore

final class BrightnessHeartbeatControllerTests: XCTestCase {
    @MainActor
    func testControllerRunsProductionHeartbeatAndRejectsOverlap() async {
        final class Model {
            let isBuiltin = true
            var brightness = 80.0
        }
        let model = Model()
        let gate = AsyncGate()
        let controller = BrightnessHeartbeatController()
        let started = expectation(description: "refresh entered single-flight pass")

        XCTAssertTrue(controller.schedule(
            displays: [model], panelVisible: true, autoBrightnessEnabled: false,
            lastManualAdjustment: nil, isBuiltin: { $0.isBuiltin }, prepare: {}
        ) { display in
            started.fulfill()
            await gate.wait()
            display.brightness = 50
        })
        await fulfillment(of: [started], timeout: 1)
        XCTAssertTrue(controller.isRefreshing)
        XCTAssertFalse(controller.schedule(
            displays: [model], panelVisible: true, autoBrightnessEnabled: false,
            lastManualAdjustment: nil, isBuiltin: { $0.isBuiltin }, prepare: {}
        ) { _ in XCTFail("overlapping pass must not start") })

        await gate.open()
        await controller.waitUntilIdle()
        XCTAssertEqual(model.brightness, 50)
        XCTAssertFalse(controller.isRefreshing)
    }

    @MainActor
    func testImmediateCancelBeforeTaskStartsSkipsPrepareAndRefresh() async {
        final class Counters {
            var prepared = 0
            var refreshed = 0
        }
        let counters = Counters()
        let controller = BrightnessHeartbeatController()

        XCTAssertTrue(controller.schedule(
            displays: [true], panelVisible: true, autoBrightnessEnabled: false,
            lastManualAdjustment: nil, isBuiltin: { $0 }
        ) {
            counters.prepared += 1
        } refresh: { _ in
            counters.refreshed += 1
        })
        controller.cancel()
        await controller.waitUntilIdle()

        XCTAssertEqual(counters.prepared, 0)
        XCTAssertEqual(counters.refreshed, 0)
    }

    @MainActor
    func testCancelKeepsSingleFlightOccupiedUntilUncancellableRefreshReturns() async {
        let gate = AsyncGate()
        let controller = BrightnessHeartbeatController()
        let started = expectation(description: "refresh entered callback-backed operation")

        XCTAssertTrue(controller.schedule(
            displays: [true], panelVisible: true, autoBrightnessEnabled: false,
            lastManualAdjustment: nil, isBuiltin: { $0 }, prepare: {}
        ) { _ in
            started.fulfill()
            await gate.wait()
        })
        await fulfillment(of: [started], timeout: 1)
        controller.cancel()

        XCTAssertFalse(controller.schedule(
            displays: [true], panelVisible: true, autoBrightnessEnabled: false,
            lastManualAdjustment: nil, isBuiltin: { $0 }, prepare: {}
        ) { _ in XCTFail("a reopened panel must not overlap the cancelled pass") })

        await gate.open()
        await controller.waitUntilIdle()
        XCTAssertFalse(controller.isRefreshing)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
