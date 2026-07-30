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
## Added

- Auto Brightness rework: the built-in slider tracks system brightness live,
  and external displays follow it. A "Keep display offsets" mode preserves the
  per-monitor difference you set instead of snapping every display to the same
  level.
- Brightness keys can target the display under the cursor, all connected
  displays, or a chosen subset. (#8)
- Color profile picker lists only display-safe profiles, scoped to each
  display, as a checkmarked list.

## Changed

- Combined brightness control restyled to match the per-display rows.
- Smoother reveal animation for the resolution, preset, and image sections.
- Spacing between stacked display sections in the menu.
- Arrangement name badge no longer overlaps the wallpaper.
- Removed the notch-height info row.
- DDC brightness writes paced to ~20/sec to prevent flicker on fast drags. (#13)
## Dev / build

- `dev.sh` signs with a stable identity so the Accessibility grant survives
  rebuilds.
- Added a `Makefile` wrapping the existing build scripts. (#13)
## Contributors

- @shaw-baobao: color profile subtitle sync (#11)
- @caicaiks: multi-display DDC matching and reply-frame hardening (#13)
