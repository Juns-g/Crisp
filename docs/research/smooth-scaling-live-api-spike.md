# Smooth scaling: research + decision record (issue #9)

Decision record for issue #9 (smooth resolution scaling), covering three spikes.

## Outcome / status

**Smooth scaling was cut from 1.3.0.** On Apple Silicon / macOS 26 neither
viable-looking path works: no private API scales live and blink-free (B1), and
the override-plist ladder (Option A) can't be made dense because macOS only
enumerates standard scaled sizes. The one approach that could deliver it,
virtual-display + hardware-mirror oversampling (B2), is a separate medium-scope
feature with real color-management, flicker, and crash-safety risks.

**Planned for 1.4.0 as an opt-in beta/experimental feature**, built on the B2
approach, and only after running the throwaway probe
(`scratchpad/mirror-probe/probe.swift`, not in-repo) on a spare display to
confirm it's blink-free and doesn't regress color/DDC. See the B2 section for
the full mechanism, collision matrix, and cleanup design.

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

## Update: Option A (override-plist ladder) is also insufficient on Apple Silicon

Empirical test on the real target hardware (M4 Max, macOS 26, external AOC
Q27G3XMN 2560x1440, vendor 0x5e3 / product 0xb326) overturns the assumption
that Option A at least yields a *denser discrete* ladder:

We injected 13 backing resolutions into the display's override plist. macOS
enumerated only 3 of them:

- 2560x1440 backing -> looks like 1280x720  (kept)
- 3200x1800 backing -> looks like 1600x900  (kept)
- 3840x2160 backing -> looks like 1920x1080 (kept)
- 2772x1560, 2984x1680, 3412x1920, 3624x2040, 4052x2280, 4264x2400,
  4480x2520, 4692x2640, 4904x2760 -> all silently dropped
- 5120x2880 (native as HiDPI) -> dropped (panel can't)

The three survivors are exactly 2x standard 16:9 resolutions (720p/900p/1080p).
Every non-standard backing was rejected. Verified by decoding the on-disk plist
(13 entries present) against a CGDisplayCopyAllDisplayModes enumeration (only
the 3 standard sizes appear as HiDPI). The same probe surfaced the 3 standard
ones immediately, so this is selective rejection, not a reconnect/probe timing
issue.

Conclusion: macOS on Apple Silicon whitelists standard scaled HiDPI sizes and
rejects arbitrary injected backings, so the override-plist mechanism cannot
build a dense/smooth ladder on this hardware at all, only ~4 usable stops. This
is why the "smooth scaling" slider was no smoother than the existing resolution
picker, and why increasing the injected step count changes nothing. Genuine
smooth scaling requires owning the framebuffer (virtual display + mirror /
oversampling), tracked as the next spike.

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
