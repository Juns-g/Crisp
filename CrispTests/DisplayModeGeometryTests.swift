import XCTest

final class DisplayModeGeometryTests: XCTestCase {
    func testPortraitNativeAspectIgnoresLargerLandscapeHiDPIBacking() {
        let modes = [
            DisplayModeGeometry(
                width: 1440, height: 2560,
                pixelWidth: 1440, pixelHeight: 2560
            ),
            DisplayModeGeometry(
                width: 2560, height: 1440,
                pixelWidth: 5120, pixelHeight: 2880
            )
        ]

        XCTAssertEqual(
            DisplayModeGeometry.nativeAspect(from: modes),
            1440.0 / 2560.0,
            accuracy: 0.001
        )
    }

    func testPortraitRetinaPointIsEligibleForResolutionMenu() {
        XCTAssertTrue(
            DisplayModeGeometry.isResolutionMenuEligible(width: 720, height: 1280)
        )
    }

    func testPortraitMenuRejectsLandscapeModes() {
        XCTAssertFalse(
            DisplayModeGeometry.hasSameOrientation(
                width: 1920, height: 1080, as: 1440, 2560
            )
        )
        XCTAssertTrue(
            DisplayModeGeometry.hasSameOrientation(
                width: 1080, height: 1920, as: 1440, 2560
            )
        )
    }

    // MARK: - Notch detection (issue #63)

    func testNotchedPanelAspects() {
        // 14" MBP 3024x1964, 16" MBP 3456x2234, 13.6" Air 2560x1664, 15" Air 2880x1864
        XCTAssertTrue(DisplayModeGeometry.isNotchedPanelAspect(3024.0 / 1964.0))
        XCTAssertTrue(DisplayModeGeometry.isNotchedPanelAspect(3456.0 / 2234.0))
        XCTAssertTrue(DisplayModeGeometry.isNotchedPanelAspect(2560.0 / 1664.0))
        XCTAssertTrue(DisplayModeGeometry.isNotchedPanelAspect(2880.0 / 1864.0))
    }

    func testNonNotchedPanelAspects() {
        // 16:10 Retina MBP, 16:9 11" Air, degenerate zero, rotated (portrait) notched panel
        XCTAssertFalse(DisplayModeGeometry.isNotchedPanelAspect(2560.0 / 1600.0))
        XCTAssertFalse(DisplayModeGeometry.isNotchedPanelAspect(1366.0 / 768.0))
        XCTAssertFalse(DisplayModeGeometry.isNotchedPanelAspect(0))
        XCTAssertFalse(DisplayModeGeometry.isNotchedPanelAspect(1964.0 / 3024.0))
    }

    func testNativeAspectFamilySplitsNotchedFromLetterboxed() {
        let native = 3024.0 / 1964.0
        // Notch-including sizes on the 14" panel
        XCTAssertTrue(DisplayModeGeometry.matchesNativeAspect(width: 1512, height: 982, nativeAspect: native))
        XCTAssertTrue(DisplayModeGeometry.matchesNativeAspect(width: 2294, height: 1490, nativeAspect: native))
        XCTAssertTrue(DisplayModeGeometry.matchesNativeAspect(width: 3024, height: 1964, nativeAspect: native))
        // Their 16:10 letterboxed twins, plus the 16:10-only sizes
        XCTAssertFalse(DisplayModeGeometry.matchesNativeAspect(width: 1512, height: 945, nativeAspect: native))
        XCTAssertFalse(DisplayModeGeometry.matchesNativeAspect(width: 3024, height: 1890, nativeAspect: native))
        XCTAssertFalse(DisplayModeGeometry.matchesNativeAspect(width: 1280, height: 800, nativeAspect: native))
        XCTAssertFalse(DisplayModeGeometry.matchesNativeAspect(width: 1512, height: 0, nativeAspect: native))
    }
}
