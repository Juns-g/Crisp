// scripts/check-boost-math.swift
// Runnable check for BrightnessBoostMath. Run:
//   cat Crisp/Utilities/BrightnessBoostMath.swift scripts/check-boost-math.swift | swift -

// sliderMax: no meaningful headroom means the scale stays at 100.
assert(BrightnessBoostMath.sliderMax(isBuiltin: true, model: "Mac15,3", potentialHeadroom: 1.0) == 100)
assert(BrightnessBoostMath.sliderMax(isBuiltin: true, model: "Mac15,3", potentialHeadroom: 1.04) == 100)

// Built-in, 600-nit model (in the SDR set): ceiling caps at 1.50, slider at 150.
assert(abs(BrightnessBoostMath.ceiling(isBuiltin: true, model: "Mac15,3", currentEDR: 2.66) - 1.5) < 0.001)
assert(abs(BrightnessBoostMath.ceiling(isBuiltin: true, model: "Mac15,3", currentEDR: 10.0) - 1.5) < 0.001)
assert(BrightnessBoostMath.sliderMax(isBuiltin: true, model: "Mac15,3", potentialHeadroom: 16.0) == 150)

// Built-in, other model (not in the SDR set): ceiling caps at 1.59, slider at 159.
assert(abs(BrightnessBoostMath.ceiling(isBuiltin: true, model: "Mac16,2", currentEDR: 3.2) - 1.59) < 0.001)
assert(BrightnessBoostMath.sliderMax(isBuiltin: true, model: "Mac16,2", potentialHeadroom: 16.0) == 159)

// External: ceiling clamps at 2.0; slider mirrors the (uncapped) potential scale.
assert(abs(BrightnessBoostMath.ceiling(isBuiltin: false, model: "", currentEDR: 16.0) - 2.0) < 0.001)
assert(BrightnessBoostMath.sliderMax(isBuiltin: false, model: "", potentialHeadroom: 16.0) == 200)
assert(BrightnessBoostMath.sliderMax(isBuiltin: false, model: "", potentialHeadroom: 1.3) == 130)

// overlayFactor: at or below 100 there is no boost.
assert(BrightnessBoostMath.overlayFactor(brightness: 50, sliderMax: 150, isBuiltin: true, model: "Mac15,3", currentEDR: 2.66) == 1.0)
assert(BrightnessBoostMath.overlayFactor(brightness: 100, sliderMax: 150, isBuiltin: true, model: "Mac15,3", currentEDR: 2.66) == 1.0)
// t=0 (bottom of the boost region) -> 1.0.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 100.001, sliderMax: 150, isBuiltin: true, model: "Mac15,3", currentEDR: 2.66) - 1.0) < 0.001)
// t=1 (top of the boost region) -> exactly the ceiling.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 150, isBuiltin: true, model: "Mac15,3", currentEDR: 2.66) - 1.5) < 0.001)
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 200, sliderMax: 200, isBuiltin: false, model: "", currentEDR: 16.0) - 2.0) < 0.001)

// HDR-not-ready gate (currentEDR <= 1.05): the applied factor is
// min(target, pendingHDRBrightnessFactor), not the full target.
// Here the un-gated target would be 1.188 (> 1.12), so it clips to 1.12.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 150, sliderMax: 150, isBuiltin: true, model: "Mac15,3", currentEDR: 1.0) - 1.12) < 0.001)
// A smaller un-gated target (1.094, < 1.12) passes through the gate unclipped.
assert(abs(BrightnessBoostMath.overlayFactor(brightness: 125, sliderMax: 150, isBuiltin: true, model: "Mac15,3", currentEDR: 1.0) - 1.094) < 0.001)

print("check-boost-math: all assertions passed")
