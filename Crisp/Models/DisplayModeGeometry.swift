struct DisplayModeGeometry: Equatable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int

    static func nativeAspect(from modes: [DisplayModeGeometry]) -> Double {
        let unscaled = modes.filter {
            $0.pixelWidth == $0.width && $0.pixelHeight == $0.height
        }
        let candidates = unscaled.isEmpty ? modes : unscaled
        guard let largest = candidates.max(by: {
            $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight
        }), largest.height > 0 else { return 0 }
        return Double(largest.width) / Double(largest.height)
    }

    static func isResolutionMenuEligible(width: Int, height: Int) -> Bool {
        min(width, height) >= 720 && max(width, height) >= 1280
    }

    static func hasSameOrientation(width: Int, height: Int,
                                   as referenceWidth: Int, _ referenceHeight: Int) -> Bool {
        if width == height || referenceWidth == referenceHeight { return true }
        return (width > height) == (referenceWidth > referenceHeight)
    }

    /// Whether a built-in panel with this native aspect has a notch. Notched
    /// panels are 16:10 plus the menu-bar strip beside the camera housing, so
    /// their native aspect (~1.54) sits well below 16:10; every non-notched Mac
    /// panel is 16:10 or wider (16:9 on the 11" Air). Same 2% tolerance the
    /// resolution list uses to split the families. The lower bound drops
    /// portrait aspects: a rotated panel reports rotated dims, and the notch
    /// toggle has no sensible meaning there.
    static func isNotchedPanelAspect(_ nativeAspect: Double) -> Bool {
        let sixteenTen = 16.0 / 10.0
        return nativeAspect > 1 && (sixteenTen - nativeAspect) / sixteenTen >= 0.02
    }

    /// Whether a mode size belongs to the panel's native-aspect family: on a
    /// notched panel these are the notch-including sizes (1512×982, ...), as
    /// opposed to the 16:10 letterboxed twins (1512×945, ...) that hide it.
    static func matchesNativeAspect(width: Int, height: Int, nativeAspect: Double) -> Bool {
        guard height > 0, nativeAspect > 0 else { return false }
        return abs(Double(width) / Double(height) - nativeAspect) / nativeAspect < 0.02
    }
}
