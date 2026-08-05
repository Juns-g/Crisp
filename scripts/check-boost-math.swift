// scripts/check-boost-math.swift
// Runnable check for BrightnessBoostMath. Run:
//   cat Crisp/Utilities/BrightnessBoostMath.swift scripts/check-boost-math.swift | swift -

// sliderMax: no meaningful headroom means the scale stays at 100.
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 1.0) == 100)
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 1.04) == 100)
// Capped at 200 however large the potential headroom is.
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 16.0) == 200)
// Small honest headroom scales the boost region down.
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 1.3) == 130)

// overlayFactor: at or below 100 there is no boost.
assert(BrightnessBoostMath.overlayFactor(brightness: 50, sliderMax: 200, currentEDR: 4.0) == 1.0)
assert(BrightnessBoostMath.overlayFactor(brightness: 100, sliderMax: 200, currentEDR: 4.0) == 1.0)
// t=0 (bottom of the boost region) -> 1.0.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 100.001, sliderMax: 200, currentEDR: 4.0) - 1.0) < 0.001)
// Exponential mapping: t=0.5 -> sqrt(headroom), t=1 -> the full live headroom.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 200, currentEDR: 4.0) - 2.0) < 0.001)
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 200, sliderMax: 200, currentEDR: 4.0) - 4.0) < 0.001)
// The factor never exceeds the live headroom, whatever the slider says.
assert(BrightnessBoostMath.overlayFactor(brightness: 200, sliderMax: 200, currentEDR: 1.3) <= 1.3 + 0.001)
// Headroom sagging (ABL/thermals) eases the same slider position down.
assert(BrightnessBoostMath.overlayFactor(brightness: 200, sliderMax: 200, currentEDR: 2.5) <
       BrightnessBoostMath.overlayFactor(brightness: 200, sliderMax: 200, currentEDR: 4.0))

// HDR-not-ready gate (currentEDR <= 1.05): a flat pending nudge, never the
// target computed from unramped headroom.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 200, currentEDR: 1.0) - 1.12) < 0.001)
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 101, sliderMax: 200, currentEDR: 1.0) - 1.12) < 0.001)

print("check-boost-math: all assertions passed")
