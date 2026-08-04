// Crisp/Utilities/BrightnessBoostMath.swift
import Foundation

/// Pure mapping logic for the Extra Brightness (EDR upscaling) feature.
/// Kept free of AppKit so scripts/check-boost-math.swift can compile it standalone.
enum BrightnessBoostMath {
    /// Built-in panel model identifiers with a 600-nit SDR ceiling; these get
    /// the lower (referenceEdr, bonus) constant pair below. Every other
    /// built-in model uses the higher pair. Both pairs are BrightIntosh's
    /// (the shipping open-source app this technique is adapted from).
    static let sixHundredNitModels: Set<String> = [
        "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
        "Mac16,1", "Mac16,6", "Mac16,8", "Mac16,7", "Mac16,5",
        "Mac17,2", "Mac17,6", "Mac17,8", "Mac17,7", "Mac17,9"
    ]

    /// currentEDR at or below this means the panel has not ramped EDR yet.
    static let hdrReadyThreshold = 1.05
    /// Applied instead of the target factor while not HDR-ready: slightly
    /// above 1.0 content is itself what prompts macOS to ramp EDR headroom.
    static let pendingHDRBrightnessFactor = 1.12

    /// The running Mac's model identifier (e.g. "Mac16,6"), read once and
    /// cached; used to pick which built-in panel constants apply below.
    static let currentModelIdentifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    /// (referenceEdr, bonus) for the built-in panel, from its model identifier.
    static func builtinConstants(model: String) -> (referenceEdr: Double, bonus: Double) {
        sixHundredNitModels.contains(model) ? (2.66, 0.50) : (3.2, 0.59)
    }

    /// Overlay multiplier ceiling available right now, from live EDR headroom.
    /// Built-in: scales `bonus` by how much of `referenceEdr` the panel is
    /// currently delivering, so the max possible ceiling is 1.50 or 1.59,
    /// never 2.0 (the panel cannot do a full-screen 2x). External: the
    /// current headroom itself, clamped to [1.0, 2.0].
    static func ceiling(isBuiltin: Bool, model: String, currentEDR: Double) -> Double {
        if isBuiltin {
            let (referenceEdr, bonus) = builtinConstants(model: model)
            return 1.0 + bonus * min(currentEDR / referenceEdr, 1.0)
        }
        return min(max(currentEDR, 1.0), 2.0)
    }

    /// UI slider ceiling for a display, from its potential EDR headroom.
    /// Headroom at or below 1.05 is noise, not a usable boost. Built-in uses
    /// the panel's own max ceiling (150 or 159); externals keep the
    /// potential-headroom scale, capped at 200%.
    static func sliderMax(isBuiltin: Bool, model: String, potentialHeadroom: Double) -> Double {
        guard potentialHeadroom > 1.05 else { return 100 }
        if isBuiltin {
            let (_, bonus) = builtinConstants(model: model)
            return (100 * (1.0 + bonus)).rounded()
        }
        return (100 * min(potentialHeadroom, 2.0)).rounded()
    }

    /// Overlay multiplier for a brightness value on the extended scale.
    /// 0...100 is the hardware range (factor 1.0). 100...sliderMax maps
    /// linearly onto 1.0...ceiling. Below hdrReadyThreshold the panel has not
    /// ramped EDR yet, so applying the full target would clip; apply a small
    /// pending nudge instead (capped at pendingHDRBrightnessFactor), which is
    /// itself what prompts macOS to ramp EDR. The caller's headroom poll
    /// re-syncs as currentEDR rises, converging on the real target.
    static func overlayFactor(
        brightness: Double, sliderMax: Double,
        isBuiltin: Bool, model: String, currentEDR: Double
    ) -> Double {
        guard brightness > 100, sliderMax > 100 else { return 1.0 }
        let t = min(1.0, (brightness - 100) / (sliderMax - 100))
        let target = 1.0 + t * (ceiling(isBuiltin: isBuiltin, model: model, currentEDR: currentEDR) - 1.0)
        guard currentEDR > hdrReadyThreshold else {
            return min(target, pendingHDRBrightnessFactor)
        }
        return target
    }
}
