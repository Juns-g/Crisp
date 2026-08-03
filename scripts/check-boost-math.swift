// scripts/check-boost-math.swift
// Runnable check for BrightnessBoostMath. Build and run:
//   swiftc -swift-version 5 Crisp/Utilities/BrightnessBoostMath.swift scripts/check-boost-math.swift -o /tmp/check-boost-math && /tmp/check-boost-math

// sliderMax: no meaningful headroom means the scale stays at 100.
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 1.0) == 100)
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 1.04) == 100)
// Modest HDR monitor: honest small extension.
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 1.3) == 130)
// XDR reports huge potential (16.0); the UI scale caps at 200%.
assert(BrightnessBoostMath.sliderMax(potentialHeadroom: 16.0) == 200)

// overlayFactor: at or below 100 there is no boost.
assert(BrightnessBoostMath.overlayFactor(brightness: 50, sliderMax: 200, currentHeadroom: 2.0) == 1.0)
assert(BrightnessBoostMath.overlayFactor(brightness: 100, sliderMax: 200, currentHeadroom: 2.0) == 1.0)
// Midpoint of the boost region maps to the midpoint of available headroom.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 200, currentHeadroom: 2.0) - 1.5) < 0.001)
// Top of the slider asks for exactly the current headroom, never more.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 200, sliderMax: 200, currentHeadroom: 1.6) - 1.6) < 0.001)
// Values past the slider max clamp to the headroom.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 400, sliderMax: 200, currentHeadroom: 1.6) - 1.6) < 0.001)
// Degenerate inputs never produce a boost.
assert(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 100, currentHeadroom: 2.0) == 1.0)
assert(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 200, currentHeadroom: 1.0) == 1.0)

print("check-boost-math: all assertions passed")
