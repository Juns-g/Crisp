# Keyboard shortcuts (preset shortcuts + Shortcuts section)

Status: approved design, pre-implementation.
Date: 2026-08-18
Issue: #61

## Purpose

Let users trigger Crisp actions with global keyboard shortcuts. Two commenters
on #61 want this: the reporter (Red-Pumpkin20) wants a one-key HiDPI toggle,
and AminudinMurad wants shortcuts on presets ("Preset is available. The only
missing feature is Keyboard shortcuts."). BetterDisplay landed the same need as
per-favorite shortcuts (their #1585, v1.4.4); SwitchResX and QuickRes are built
on hotkey-to-resolution. Crisp's equivalent of favorites is presets, so presets
carry the general mechanism, and a small curated Shortcuts section carries
named one-off actions.

## Scope

- Per-preset shortcuts: each saved preset can have one global shortcut that
  applies it. Recorder lives in the create/edit form, so it works at creation
  time too.
- A "Shortcuts" section in Settings with exactly one action row for now:
  "Toggle HiDPI" (the under-cursor HiDPI twin toggle built and live-verified
  2026-08-18). The section is the durable home for future named actions.
- Carbon `RegisterEventHotKey` for everything: global, works in an LSUIElement
  app, needs no Accessibility permission.
- Not in v1 (recorded as future options, do not build now; the bar for adding
  an action is "someone asked", because every shortcut is a system-wide key
  grab and a permanent promise):
  - cycle presets (BetterDisplay has it; nobody asked here)
  - open the Crisp panel by key (likely first future ask, ~20 lines then)
  - step resolution up/down, notch toggle, HDR / Night Shift / True Tone
  - anything destructive or modal (display disconnect) stays off keys
- Brightness and volume need nothing: the existing media-key interception
  (BrightnessKeyService) already covers them.

## Model

`KeyboardShortcut` (exists, 11 unit tests): virtual key code + Carbon modifier
mask + key label captured at record time. Rejects combos without at least one
of cmd/option/control (shift alone still types). Codable.

`DisplayPreset` gains `var shortcut: KeyboardShortcut? = nil`. Old presets
decode as nil; presets already persist as JSON in Application Support, so no
migration. The static action's combo persists in UserDefaults under
`crisp.hidpiShortcut` (already fits a `crisp.shortcut.*` naming scheme for
future actions).

## HotkeyService

Generalizes the existing single-hotkey service to N registrations dispatched
by `EventHotKeyID.id` through one id-to-target map. A target is either a
preset UUID or the static HiDPI-toggle action. One public entry point,
`syncRegistrations()`, rebuilds all registrations from current state
(PresetService presets + the static action's stored combo). Called from:

- app launch (AppDelegate)
- `PresetService.savePresets()` (covers add, edit, delete, record, steal)
- the Shortcuts section on record/clear
- recorder start/stop (suspend all while recording so any combo is capturable)

On press:
- preset target: `PresetService.applyPreset`, the same path as tapping the row
- HiDPI toggle: flip the display under the pointer between the HiDPI and
  low-resolution variant of its current logical size, keeping refresh rate
  (tolerant match via `ResolutionService.refreshMatches`); beep when the size
  has no twin. Under-cursor targeting matches the brightness keys.

## UI

- SavePresetView (shared by New Preset and the row's edit accordion): one
  "Shortcut" row below Captures, above Cancel/Save. Click shows "Type
  shortcut… (Esc to cancel)"; a local keyDown monitor captures the combo; a
  clear affordance removes it. The combo sits in form @State and commits on
  Save, like name and icon.
- PresetRow: an assigned shortcut renders as right-aligned glyphs (e.g. ⌃⌥1),
  the native menu key-equivalent idiom. Nothing when unset.
- Settings > "Shortcuts": ExpandableRow (expand in place per DESIGN.md) whose
  subtitle shows the toggle's combo when set; inside, the recorder row idiom
  already built (record / type-to-capture / remove) plus the one-line caption
  explaining what Toggle HiDPI does.

## Conflicts

All shortcuts share one namespace (presets and static actions). Recording a
combo already in use steals it: last save wins, the previous holder's field
clears silently. Deterministic, no dialogs; re-recording takes it back.
Chosen over refuse-with-hint because stealing is the norm in comparable apps.

## Edge cases

- Combos without cmd/option/control: ignored by the recorder (model enforces).
- Esc cancels recording; panel close stops recording and re-syncs
  registrations.
- Preset whose displays are disconnected: `applyPreset` already applies what
  it can; no special handling.
- HiDPI toggle on a size with no twin (e.g. native 2560x1440 on a 1440p
  panel): beep, no mode change.
- Stealing is centralized in one helper that clears the combo from every
  other holder (presets and the static action) before `syncRegistrations()`.
  Preset recordings commit on form Save; the Shortcuts-section recording
  commits immediately (there is no form), both through that helper.

## Localization

Keep (already translated): "Record Shortcut", "Type shortcut… (Esc to
cancel)", "Remove Shortcut", and the toggle caption ("Switches the display
under the pointer between HiDPI and low resolution."). Add with zh-Hans:
"Shortcuts" (section label), "Shortcut" (form row label), "Toggle HiDPI"
(action row label). Drop from the catalog: "HiDPI Shortcut" (superseded
section name).

## Testing and verification

- Model tests exist (KeyboardShortcutTests). New pure logic, if any emerges
  (e.g. the conflict-steal helper), goes in Models/ with tests; UI and Carbon
  registration are verified live per project practice.
- Live check: record a shortcut in the New Preset form, in the edit form, and
  in the Shortcuts section; verify glyphs on the row; press each combo with
  the panel closed and another app frontmost; verify steal by recording the
  same combo on a second preset; verify Esc cancel and panel-close cleanup.
- The existing HiDPI toggle behavior was already live-verified 2026-08-18
  (mode flip both directions on hardware; beep case confirmed by inspection).

## Rollout

Ships as one feature in the next release; closes #61. The issue thread has a
comment (2026-08-18) telling both commenters this shape is coming; the
reporter confirmed preset shortcuts work for them and prefers the one-key
toggle, which this design now includes.
