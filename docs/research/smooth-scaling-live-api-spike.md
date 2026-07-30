# Smooth scaling: live private-API spike (B1)

Decision record for issue #9 (smooth resolution scaling). Captures why 1.3.0
ships the override-plist ladder (Option A) and does not attempt a live,
blink-free private-API path (Option B).

## Question

Is there a private CoreDisplay / SkyLight API that changes an external
display's scaled resolution *live and blink-free* at arbitrary sizes, so a
slider could scale continuously without the modeset flash? If so, integrate it
behind the slider before releasing 1.3.0.

## Verdict: NO-GO for 1.3.0

Ship Option A (dense HiDPI override ladder + slider) alone. No private symbol
we found removes the blink for arbitrary sizes.

## Evidence

Ground truth was pulled by dumping exported symbols directly off the running
system (macOS 26.5.1, Apple Silicon arm64) with `dyld_info -exports` against
CoreDisplay, CoreGraphics, and SkyLight (on modern Apple Silicon the framework
binaries live only in the dyld shared cache, so `nm`/`otool` fail).

- The hypothesized symbols do not exist. `CoreDisplay_Display_SetUserResolution`
  and `CoreDisplay_Display_CreateOptimizedDisplayModes` are absent from
  CoreDisplay's ~140 exports. CoreDisplay's `CoreDisplay_Display_*` surface is
  brightness / HDR / preset / color only, zero resolution or scale functions.
- Every real candidate is the same path. `CGSConfigureDisplayMode` (already
  used in Crisp) is a re-export of `SLSConfigureDisplayMode`;
  `CGConfigureDisplayWithDisplayMode` (Crisp's primary path),
  `CGDisplaySetDisplayMode`, and the newer `CGSConfigureDisplayResolution` are
  all thin aliases into the same SkyLight code, which performs the same
  backing-store resize + DCP repipe transaction regardless of entry point. That
  transaction is what blinks.
- The path is list-validated by DCP firmware. An independent 2026 test
  (macOS 26.4, M2/M5) showed `SLConfigureDisplayWithDisplayMode` returns error
  1000 for any mode not already in the display's firmware-derived mode list;
  IOKit layers (`AppleDCPLinkService`, `DCPAVServiceProxy`, ...) return
  `kIOReturnUnsupported`. The constraint is baked into DCP firmware, below the
  OS, and differs by chip generation (M2/M3 vs M4/M5 pipe-width budgets) on the
  same macOS build.
- Prior art agrees. BetterDisplay's "smooth"/"flexible" scaling is oversampling
  (render larger, compositor downscales) over a persisted discrete mode set, not
  a live modeset. huberdf/FreeDisplay (same Services/ layout as Crisp)
  documents its scaled-mode generator as "requires display reconnect (or reboot)
  to apply" and falls back to the same `CGSConfigureDisplayMode`. RDM reports
  crashes from private-API framework drift.
- This family is already rotting on our target OS. Crisp's own
  `AutoBrightnessService` / `BrightnessService` document
  `CoreDisplay_Display_GetUserBrightness` pinned at 1.0 and
  `...SetUserBrightness` a no-op on macOS 26 / Apple Silicon, for a simpler
  feature than resolution.

## Alternative considered, out of scope

Fixed-resolution `CGVirtualDisplay` + hardware-mirror the physical panel avoids
the pipe-budget check (mirrored displays receive pre-composited frames), but it
fixes the physical output at one mode and is a much larger redesign (route the
physical output through mirroring permanently), not a private-API swap.

## Follow-up (Option A optimization, not Option B)

Check whether `IOServiceRequestProbe` runs on every resolution switch vs only on
first override registration; skipping it for already-registered modes would trim
per-step slider latency. It will not remove the blink (the modeset transaction
blinks regardless), but it is a cheap, low-risk win. Tracked in faz.

## Residual uncertainty

`CGSConfigureDisplayResolution`'s parameter layout is undocumented anywhere and
untested (no external display in the spike sandbox; calling display-mutating
private APIs with a guessed ABI risks crashing WindowServer, not just the app).
A throwaway CLI probe against a spare external display could close this
empirically, but given all of the above the expected result is "errors the same
way, confirming NO-GO," so it was not pursued for 1.3.0.
