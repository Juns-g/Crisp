// Crisp/Utilities/BrightnessBoostMath.swift
import Foundation

/// Pure mapping logic for the Extra Brightness (EDR upscaling) feature.
/// Kept free of AppKit so scripts/check-boost-math.swift can compile it standalone.
enum BrightnessBoostMath {
    /// currentEDR at or below this means the panel has not ramped EDR yet.
    static let hdrReadyThreshold = 1.05
    /// Applied instead of the target factor while not HDR-ready: slightly
    /// above 1.0 content is itself what prompts macOS to ramp EDR headroom.
    static let pendingHDRBrightnessFactor = 1.12

    /// UI slider ceiling for a display, from its potential EDR headroom.
    /// Headroom at or below 1.05 is noise, not a usable boost. Capped at
    /// 200%: the boost region gets the same track length as the native range,
    /// and the exponential factor mapping below spends it perceptually evenly
    /// however much real headroom the panel has.
    static func sliderMax(potentialHeadroom: Double) -> Double {
        guard potentialHeadroom > 1.05 else { return 100 }
        return (100 * min(potentialHeadroom, 2.0)).rounded()
    }

    /// Overlay multiplier for a brightness value on the extended scale.
    /// 0...100 is the hardware range (factor 1.0). 100...sliderMax maps
    /// EXPONENTIALLY onto 1.0...currentEDR (factor = headroom^t): luminance is
    /// perceived roughly logarithmically, so equal slider steps give equal
    /// brightness ratios, exposure-stop style. Calibrated on hardware: the
    /// panel renders the full reported headroom (about 4x here) clean, so the
    /// live currentEDR itself is the honest ceiling; macOS lowers it under
    /// ABL/thermals and the caller's headroom poll re-syncs, easing the
    /// factor down with it.
    /// Below hdrReadyThreshold the panel has not ramped EDR yet, so the full
    /// target would clip; apply a small pending nudge instead, which is
    /// itself what prompts macOS to ramp EDR.
    static func overlayFactor(brightness: Double, sliderMax: Double, currentEDR: Double) -> Double {
        guard brightness > 100, sliderMax > 100 else { return 1.0 }
        guard currentEDR > hdrReadyThreshold else { return pendingHDRBrightnessFactor }
        let t = min(1.0, (brightness - 100) / (sliderMax - 100))
        return pow(currentEDR, t)
    }
}
