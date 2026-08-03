// Crisp/Utilities/BrightnessBoostMath.swift
import Foundation

/// Pure mapping logic for the Extra Brightness (EDR upscaling) feature.
/// Kept free of AppKit so scripts/check-boost-math.swift can compile it standalone.
enum BrightnessBoostMath {
    /// UI slider ceiling for a display, from its potential EDR headroom.
    /// Headroom at or below 1.05 is noise, not a usable boost. XDR panels report
    /// very large potential values (16.0); the scale caps at 200% so the boost
    /// region stays a meaningful fraction of the slider.
    static func sliderMax(potentialHeadroom: Double) -> Double {
        guard potentialHeadroom > 1.05 else { return 100 }
        return (100 * min(potentialHeadroom, 2.0)).rounded()
    }

    /// Overlay multiplier for a brightness value on the extended scale.
    /// 0...100 is the hardware range (factor 1.0). 100...sliderMax maps linearly
    /// onto 1.0...currentHeadroom, clamped, so the top of the slider always asks
    /// for exactly what the display can give right now (headroom is dynamic:
    /// macOS shrinks it under thermal load and at low panel brightness).
    static func overlayFactor(brightness: Double, sliderMax: Double, currentHeadroom: Double) -> Double {
        guard brightness > 100, sliderMax > 100, currentHeadroom > 1.0 else { return 1.0 }
        let t = min(1.0, (brightness - 100) / (sliderMax - 100))
        return 1.0 + t * (currentHeadroom - 1.0)
    }
}
