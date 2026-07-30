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

## Correction: Option A (override-plist ladder) works, but needs a display reconnect

An earlier revision of this doc claimed Option A "cannot build a dense ladder on
Apple Silicon" because a test on the AOC Q27G3XMN (2560x1440) injected 13
backings but enumerated only 3 (the standard 720p/900p/1080p HiDPI sizes). That
conclusion was WRONG. The enumeration ran after IOServiceRequestProbe but before
the display had actually re-read the override plist, so only macOS's default
HiDPI sizes were present at that moment. "The same probe surfaced the 3
immediately, so it's not a timing issue" was a bad inference: those 3 are macOS
defaults, not our injected modes.

After a physical display reconnect (unplug/replug or sleep/wake), all 12
injectable dense sizes enumerate correctly on the same hardware, confirmed via
CGDisplayCopyAllDisplayModes:
1280x720, 1386x780, 1492x840, 1600x900, 1706x960, 1812x1020, 1920x1080,
2026x1140, 2132x1200, 2240x1260, 2346x1320, 2452x1380 (the 13th, native-as-HiDPI
at 5120x2880 backing, is correctly rejected because the panel can't do it). So
the dense ladder is real on Apple Silicon; IOServiceRequestProbe alone is just
insufficient to surface newly injected modes, exactly the reconnect caveat the
HiDPI enable path (HiDPIView.reconnectNeeded) already documents.

Two real caveats remain, both inherent, not fixable by a different injection
mechanism:
- First enable needs a display reconnect for the injected sizes to appear.
- Every dense stop except 1280x720 is fractionally downscaled (backing not an
  integer multiple of the panel), so it is soft. On a 2560x1440 panel only
  1280x720 HiDPI (2560x1440 backing) is pixel-perfect, and native 2560x1440
  (non-HiDPI) is the sharpest overall. Smooth scaling is therefore a size-
  granularity feature, not a sharpness feature; sharp AND high-density needs a
  4K/5K panel where the "looks like" size is an integer 2x of the panel.
- Each switch is still a real modeset (blinks); that is the B1 limitation.

Outcome: Option A (dense ladder + slider) is restored and ships in 1.3.0. The
virtual-display path (B2 below) remains the future 1.4.0 upgrade for continuous,
blink-free scaling.

Planned 1.4.0 cleanup (reduce UI bloat): retire the global "HiDPI" on/off toggle
in Settings and fold HiDPI enablement into a single per-display "Scaling"
control (HiDPI on/off + optional slider), once smooth scaling graduates from
beta. Today they overlap: the global toggle is the simple bulk coarse-ladder
enable, smooth scaling is the per-display dense-ladder enable. Two entry points
for the same override plist is the bloat to remove; the blocker is not making a
beta feature load-bearing for basic HiDPI before it is stable.

## Spike B2: virtual-display + hardware-mirror (oversampling) — CONDITIONAL GO

The only remaining path: create a `CGVirtualDisplay` we control, hardware-mirror
the physical panel from it, and scale the virtual's render size (oversampling).
Spike verdict: architecturally sound and the mechanism already half-exists in
Crisp, but it is NOT a clean win and should not be a default.

Mechanism (all symbols present on macOS 26.5.1; most already used by Crisp):
- Create virtual: `VirtualDisplayService.create` (already ships, accepts
  arbitrary 640..8192 sizes, which is itself proof the DCP whitelist that blocks
  Option A does not gate virtual displays).
- Mirror physical from virtual: `MirrorService.enableMirror` (already written,
  wraps `CGConfigureDisplayMirrorOfDisplay`; currently dead code, never
  exercised).
- Resize live: `CGConfigureDisplayWithDisplayMode` on the virtual's displayID
  (`ResolutionService.applyModeSync`, already generic).
- Size the virtual's `maxPixelsWide/High` cap generously up front to avoid
  destroy/recreate on resize. `_CGVirtualDisplaySettingsRefreshDeadlineNone`
  exists, hinting the API supports in-place live reconfiguration.

Why blink-free is plausible: the physical's own `CGDisplayMode` is never
touched by the mirror relationship, and the hardware-mirror path receives
pre-composited frames, bypassing the DCP `verify_downscaling` pipe-budget gate
that caused B1's blink (corroborated by smcleod.net's M4/M5 writeup). Arbitrary
non-standard sizes should enumerate on the virtual (no EDID whitelist).

The decisive caveat: the closest mature prior art (BetterDisplay) treats
virtual-mirror as an inferior FALLBACK, not its flagship smooth-scaling path,
specifically due to unresolved, field-reported flicker/fragility tied to
wake-from-sleep, virtual disconnect, and color-profile mismatch between the
virtual and physical (discussions #2318, #2129; their wiki advises "use flexible
scaling instead"). So steady-state and transition flicker are real, separate
risks from the live-resize blink, and are the reason to gate on empirical proof.

Integration collisions with Crisp (medium scope, not free):
- DDC brightness: LOW risk (EDID-based AVService matching; physical stays online
  as a mirror target with unchanged identity).
- Color profiles: REAL regression risk (pixels are pre-composited by the
  virtual's pass; the physical's assigned ICC may be bypassed while mirroring).
- Arrangement / set-as-main: REAL work; `ArrangementService` has no
  mirror-awareness and needs the `resolvedTargetDisplayID` redirect that
  `ResolutionService` already has.
- displayUUID/persistence: LOW risk if consistently keyed on the physical, but
  the UI now enumerates an extra virtual "display" per monitor that every
  per-display surface must hide/repurpose. System Settings shows the extra
  display unavoidably.

Fragility/cleanup (hard requirement: never strand the user mirrored):
- Teardown order: unmirror BEFORE releasing the virtual.
- Crash safety GAP: no evidence the physical self-recovers if Crisp is SIGKILLed
  mid-mirror. Mandatory mitigation: a launch-time self-healing check that detects
  a stale mirror of a `0xEEEE` virtual and unmirrors it (same shape as
  `VirtualDisplayService.virtualDisplayAlreadyExists` / `PhysicalDisplayToggleService.reconcile`).

Top 3 risks: (1) production-observed flicker in the closest prior art in this
exact mechanism; (2) color-management regression for ICC-profiled panels; (3)
crash-safety gap vs the never-strand requirement.

Recommendation: if pursued, ship as an explicit opt-in "Advanced/Experimental"
per-display toggle, NOT a default, gated on running the throwaway probe first
(scratchpad/mirror-probe/probe.swift: tests non-standard-size enumeration,
per-switch blink, ~15s steady-state flicker, and DDC/color correctness while
mirrored; SIGINT/TERM handler always unmirrors + tears down; refuses the main
display). This is a separate, sizeable effort, not a 1.3.0 change.

## Residual uncertainty

`CGSConfigureDisplayResolution`'s parameter layout is undocumented anywhere and
untested (no external display in the spike sandbox; calling display-mutating
private APIs with a guessed ABI risks crashing WindowServer, not just the app).
A throwaway CLI probe against a spare external display could close this
empirically, but given all of the above the expected result is "errors the same
way, confirming NO-GO," so it was not pursued for 1.3.0.
