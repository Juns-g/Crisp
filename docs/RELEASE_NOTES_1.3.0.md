# Crisp 1.3.0

Working notes for the 1.3.0 release. Updated as changes land; items still in
flight are marked `(pending)`. This file becomes the GitHub release body at
publish (`scripts/release.sh v1.3.0 docs/RELEASE_NOTES_1.3.0.md --publish`).

## Highlights

The big themes this cycle: display scaling, brightness control, and a build
that's now signed and notarized.

- **Sharper external displays, no password.** Crisp surfaces and applies the
  clean HiDPI ("Retina") scaled resolutions macOS hides on 2K+ external
  monitors. For panels that already carry them (the common case) this now needs
  no override file, no admin prompt, and no screen blank; the old
  password-gated override survives only as a fallback for panels that lack
  HiDPI entirely.
- **Smooth scaling.** A new opt-in, per-display toggle installs a dense HiDPI
  resolution ladder so the Resolution slider can fine-tune how large everything
  looks in small steps, well beyond the handful of default scaled sizes: the
  flexible scaling people install BetterDisplay for, built in. One admin prompt
  installs it, and it stays off by default (the in-between stops are
  fractionally scaled and look slightly soft).
- **Brightness keys drive your external monitors.** The Mac's brightness keys
  can now dim any DDC external, not just the built-in: target the display under
  the cursor, all displays, or a chosen subset. A first-run "Grant Access" step
  wires up Accessibility, and the keys start working the moment you grant it,
  with no restart.
- **Signed and notarized.** Crisp is now signed with a Developer ID and
  notarized by Apple, so it opens with a normal double-click: no Gatekeeper
  "unidentified developer" warning, no right-click-to-open, no "damaged and
  can't be opened" after downloading.

## Added

- Auto Brightness rework: the built-in slider tracks system brightness live,
  and external displays follow it. A "Keep display offsets" mode preserves the
  per-monitor difference you set instead of snapping every display to the same
  level.
- Brightness keys can target the display under the cursor, all connected
  displays, or a chosen subset. (#8)
- Color profile picker lists only display-safe profiles, scoped to each
  display, as a checkmarked list.
- Smooth scaling (opt-in per external display): a toggle that installs a dense
  HiDPI resolution ladder so the Resolution slider can fine-tune how large
  everything looks, beyond the handful of default scaled steps. Turning it off
  restores the standard set. Most stops are fractionally scaled and look
  slightly soft, so it stays off by default. (#9)
- Keep Awake (in Tools): holds a power assertion so the display and system
  don't idle-sleep. Session-only; it starts off each launch and releases
  automatically when you quit.
- macOS "Automatically adjust brightness" (ambient light) is now a toggle under
  the built-in display, shown only on panels that have a light sensor.
- Brightness Keys onboarding: when Accessibility isn't granted, the section
  shows an inline explainer with a "Grant Access" button that opens the right
  Privacy pane; the keys start working right after you grant it, with no
  restart.

## Fixed

- Multiple external displays no longer cross-talk: adjusting one monitor's
  brightness could randomly drive a different monitor. The Apple Silicon
  DDC-to-display matching was rewritten to pair each DDC channel with the
  correct display (identity first, proximity fallback). (#14, #13)
- Built-in brightness keys respond immediately after leaving clamshell mode,
  instead of going dead for ~30 seconds. (#12)
- The color profile name updates immediately when you switch profiles. (#11)
- Brightness sliders behave correctly on monitors that answer DDC reads with
  stale or garbage data; a bogus reported maximum used to compress the usable
  range. (#13)
- "Invert Colors" now works. At the default quality it was silently dropped
  because the underlying gamma call ignores an inverted range; it is now
  applied as a lookup table. (#17)
- Image Adjustment: the Gain and Contrast sliders now take effect above 0.
  An internal clamp was pinning the bright end, so positive values did nothing.
- Turning off "Keep display offsets" now snaps the external displays to the
  built-in level right away, instead of waiting for the next built-in
  brightness change.
- Auto Brightness no longer flips external displays bright when the built-in is
  dimmed to its minimum. A dark-panel reading (0%) was being rejected and read
  back as full brightness, driving the externals the wrong way.
- HiDPI resolutions that share a size with a low-refresh timing (e.g. 1920×1080
  HiDPI on a 1440p/144Hz panel) now run at the panel's full refresh instead of
  dropping to 50Hz. macOS hides the full-refresh variant of such modes; Crisp
  now surfaces it and applies it directly.
- After sleep/wake, a display no longer lands on a wrong (often stretched,
  60Hz) resolution. Crisp re-applied the saved mode by a raw ID that macOS
  reassigns when the mode list is rebuilt; it now matches by resolution
  attributes and re-applies only on an exact match.
- Brightness keys start working the moment you grant Accessibility, instead of
  staying dead until you restart Crisp.
- Scaling an external display up to its native resolution now lands on the crisp
  1:1 mode instead of a same-size HiDPI variant that looked slightly soft.
- The panel no longer twitches on open: Dark Mode / Night Shift / True Tone,
  external brightness, and Launch at Login now read correctly on the first frame
  instead of flipping a beat later.

## Changed

- Resolution list now mirrors macOS System Settings: native-style labels
  ("Default", "low resolution"), off-spec external modes (odd aspect ratios and
  stray 1x sizes) hidden, and modes grouped under HiDPI / Non-HiDPI headers.
- Combined brightness control restyled to match the per-display rows.
- Smoother reveal animation for the resolution, preset, image, and combined
  brightness sections. Enabling "Show Combined Brightness" now glides the control
  open instead of popping it in at full height.
- Spacing between stacked display sections in the menu.
- Arrangement name badge no longer overlaps the wallpaper.
- Removed the notch-height info row.
- DDC brightness writes paced to ~20/sec to prevent flicker on fast drags. (#13)
- Menu icons follow the native state rule: an icon carries its color only while
  its feature is active (the way Wi-Fi and Battery do), and sits as a faint gray
  chip otherwise.
- Update checks now run automatically; the "Check for Updates at Launch" toggle
  was removed (checks still self-throttle to once an hour).
- Clicking a brightness slider's track glides to the value instead of jumping.
  Built-in and software-dimmed displays fade; DDC externals still step in one
  write, since each DDC write flashes the panel.
- The resolution picker is now a slider matching System Settings (step ticks,
  snap-to-tick, a dot on the default), with the full exact-mode list moved
  behind a "Show all resolutions" disclosure. The built-in display drops the
  16:10 "non-notch" modes macOS never actually offers.
- Refresh-rate rows keep two decimals on NTSC timings (59.94 / 47.95) so they
  no longer collapse into duplicate rows; the built-in's 120Hz reads
  "ProMotion".
- HiDPI scaled resolutions now appear on capable 2K+ external displays with no
  admin prompt and no screen blank. The override plist and password step is now
  only a fallback for a panel that genuinely lacks HiDPI.
- Support menu: added a GitHub Sponsors link beside Ko-fi, localized the Afdian
  row for Chinese, and the submenu now glides open with the panel.

## Dev / build

- `dev.sh` signs with a stable identity so the Accessibility grant survives
  rebuilds.
- Added a `Makefile` wrapping the existing build scripts. (#13)
- Release DMGs are signed with a Developer ID and notarized by Apple (hardened
  runtime, stapled ticket) via `release.sh`. With no signing cert configured it
  still builds ad-hoc as before, so local and dry-run builds are unaffected.

## Supporting Crisp

Starting with 1.3.0, Crisp is signed with a Developer ID and notarized by Apple.
That clears the security warning you hit on 1.2.0 and earlier (the one that sent
you into System Settings to open it anyway): Apple now scans each release and
macOS verifies it on launch, so Crisp opens with a normal double-click.

This runs on an Apple Developer membership ($99/year). Crisp is free and will
stay free, every feature, but if you've found it useful and would like to chip
in toward that membership, I've set up
[GitHub Sponsors](https://github.com/sponsors/didriksg),
[Ko-fi](https://ko-fi.com/didriksg), and
[Afdian (爱发电)](https://ifdian.net/a/didriksg), also in the app under Settings,
"Support Crisp". Completely optional, but you'll have my heartfelt thanks.

## Contributors

- @shaw-baobao: color profile subtitle sync (#11)
- @caicaiks: multi-display DDC matching and reply-frame hardening (#13)
