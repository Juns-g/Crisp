import XCTest
@testable import CrispControlCore

final class BrightnessPollPolicyTests: XCTestCase {
    func testBuiltinIsAlwaysPolledWhilePanelHeartbeatRuns() {
        XCTAssertTrue(BrightnessPollPolicy.shouldRefresh(isBuiltin: true, autoBrightnessEnabled: false))
        XCTAssertTrue(BrightnessPollPolicy.shouldRefresh(isBuiltin: true, autoBrightnessEnabled: true))
    }

    func testExternalPollingStillYieldsToAutoBrightness() {
        XCTAssertTrue(BrightnessPollPolicy.shouldRefresh(isBuiltin: false, autoBrightnessEnabled: false))
        XCTAssertFalse(BrightnessPollPolicy.shouldRefresh(isBuiltin: false, autoBrightnessEnabled: true))
    }

    @MainActor
    func testHeartbeatRefreshesBuiltinAndUpdatesUIFacingModel() async {
        final class Model {
            let isBuiltin: Bool
            var brightness: Double
            init(isBuiltin: Bool, brightness: Double) {
                self.isBuiltin = isBuiltin
                self.brightness = brightness
            }
        }
        let builtin = Model(isBuiltin: true, brightness: 80)
        let external = Model(isBuiltin: false, brightness: 40)

        var prepareCount = 0
        await BrightnessHeartbeat.refresh(
            displays: [builtin, external],
            panelVisible: true,
            autoBrightnessEnabled: true,
            lastManualAdjustment: nil,
            now: Date(),
            isBuiltin: { $0.isBuiltin },
            prepare: { prepareCount += 1 },
            refresh: { display in display.brightness = display.isBuiltin ? 50 : 10 }
        )

        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(builtin.brightness, 50)
        XCTAssertEqual(external.brightness, 40)
    }

    @MainActor
    func testHeartbeatSuppressesRefreshWhileHiddenOrDuringManualAdjustmentWindow() async {
        var refreshCount = 0
        let now = Date()

        await BrightnessHeartbeat.refresh(
            displays: [true], panelVisible: false, autoBrightnessEnabled: false,
            lastManualAdjustment: nil, now: now,
            isBuiltin: { $0 }, refresh: { _ in refreshCount += 1 }
        )
        await BrightnessHeartbeat.refresh(
            displays: [true], panelVisible: true, autoBrightnessEnabled: false,
            lastManualAdjustment: now.addingTimeInterval(-2.9), now: now,
            isBuiltin: { $0 }, refresh: { _ in refreshCount += 1 }
        )

        XCTAssertEqual(refreshCount, 0)
    }
}
