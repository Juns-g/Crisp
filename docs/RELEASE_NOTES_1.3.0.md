# Crisp 1.3.0

Working notes for the 1.3.0 release. Updated as changes land; items still in
flight are marked `(pending)`. This file becomes the GitHub release body at
publish (`scripts/release.sh v1.3.0 docs/RELEASE_NOTES_1.3.0.md --publish`).

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
## Added

- Auto Brightness rework: the built-in slider tracks system brightness live,
  and external displays follow it. A "Keep display offsets" mode preserves the
  per-monitor difference you set instead of snapping every display to the same
  level.
- Brightness keys can target the display under the cursor, all connected
  displays, or a chosen subset. (#8)
- Color profile picker lists only display-safe profiles, scoped to each
  display, as a checkmarked list.
- Smooth scaling (opt-in, per external display): a slider spanning a dense
  HiDPI resolution ladder to fine-tune how large everything looks, beyond the
  handful of default scaled steps. (#9)

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
- Clicking a brightness slider's track glides to the value instead of jumping.
  Built-in and software-dimmed displays fade; DDC externals still step in one
  write, since each DDC write flashes the panel.
## Dev / build

- `dev.sh` signs with a stable identity so the Accessibility grant survives
  rebuilds.
- Added a `Makefile` wrapping the existing build scripts. (#13)
## Contributors

- @shaw-baobao: color profile subtitle sync (#11)
- @caicaiks: multi-display DDC matching and reply-frame hardening (#13)
