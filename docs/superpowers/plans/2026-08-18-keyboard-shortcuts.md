# Keyboard Shortcuts (preset shortcuts + Shortcuts section) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Global keyboard shortcuts for applying presets (recorded in the preset create/edit form) plus a Settings > Shortcuts section holding the one static "Toggle HiDPI" action, per `docs/superpowers/specs/2026-08-18-keyboard-shortcuts-design.md` and issue #61.

**Architecture:** Carbon `RegisterEventHotKey` (no Accessibility needed) behind one `HotkeyService` that rebuilds all registrations from current state (`syncRegistrations()`) and dispatches presses by `EventHotKeyID.id`. Preset shortcuts persist on `DisplayPreset.shortcut`; the static action persists in `crisp.hidpiShortcut`. One shared recorder row view serves both the preset form and the Shortcuts section. Conflicts steal (last save wins) through `PresetService`.

**Tech Stack:** Swift 5/6 dual build (swiftc dev loop + xcodebuild), SwiftUI panel, Carbon.HIToolbox, XCTest for `Models/` only.

**Starting state:** The working tree on branch `hidpi-keyboard-shortcuts` already contains a green single-hotkey implementation (KeyboardShortcut model + tests, single-registration HotkeyService with the HiDPI twin-toggle action, `HiDPIShortcutSection` settings row, 5 localized strings). Task 1 commits it as the foundation; later tasks transform it. Verification commands assume repo root. `make test` needs full Xcode; if `xcodebuild` complains about Command Line Tools, prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

---

### Task 1: Commit the existing foundation

**Files:** (all already modified/created in the working tree, no edits in this task)
- `Crisp/Models/KeyboardShortcut.swift`, `CrispTests/KeyboardShortcutTests.swift`, `project.yml`, `Crisp/Services/HotkeyService.swift`, `Crisp/Services/SettingsService.swift`, `Crisp/App/AppDelegate.swift`, `Crisp/Views/HiDPIShortcutView.swift`, `Crisp/Views/MenuBarView.swift`, `Crisp/Resources/Localizable.xcstrings`

- [ ] **Step 1: Verify the tree is green**

Run: `make compile && make lint`
Expected: `Done. ./Crisp-bin built` and silent lint (exit 0).

- [ ] **Step 2: Commit**

```bash
git add Crisp/Models/KeyboardShortcut.swift CrispTests/KeyboardShortcutTests.swift project.yml \
  Crisp/Services/HotkeyService.swift Crisp/Services/SettingsService.swift Crisp/App/AppDelegate.swift \
  Crisp/Views/HiDPIShortcutView.swift Crisp/Views/MenuBarView.swift Crisp/Resources/Localizable.xcstrings
git commit -m "feat: global HiDPI toggle shortcut (Carbon hotkey foundation, #61)"
```

---

### Task 2: `DisplayPreset.shortcut` field with decode-compat tests

**Files:**
- Modify: `project.yml:63` (CrispTests sources list)
- Test: `CrispTests/DisplayPresetShortcutTests.swift` (create)
- Modify: `Crisp/Models/DisplayPreset.swift:24` (after the `resolutionLabel` computed property's closing brace, i.e. inside `DisplayPreset`, see step 3)

- [ ] **Step 1: Add DisplayPreset.swift to the test target and write the failing test**

In `project.yml`, under `CrispTests: sources:`, after the line `- path: Crisp/Models/KeyboardShortcut.swift`, add:

```yaml
      - path: Crisp/Models/DisplayPreset.swift
```

Create `CrispTests/DisplayPresetShortcutTests.swift`:

```swift
import XCTest

/// Headless tests for the preset shortcut field. `DisplayPreset` and
/// `KeyboardShortcut` are compiled directly into this test target (see
/// `project.yml` sources), so no `@testable import Crisp` is needed.
final class DisplayPresetShortcutTests: XCTestCase {

    /// Presets saved before the shortcut feature have no "shortcut" key in their
    /// JSON; they must decode with shortcut nil, not fail.
    func testLegacyPresetJSONDecodesWithNilShortcut() throws {
        let legacy = """
        {"id":"11111111-2222-3333-4444-555555555555","name":"Work","icon":"display",
         "displays":[{"id":"99999999-8888-7777-6666-555555555555",
         "displayUUID":"ABC","width":1920,"height":1080,"isHiDPI":true}]}
        """.data(using: .utf8)!
        let preset = try JSONDecoder().decode(DisplayPreset.self, from: legacy)
        XCTAssertNil(preset.shortcut)
        XCTAssertEqual(preset.name, "Work")
    }

    /// A preset with a shortcut round-trips through the JSON persistence layer.
    func testShortcutRoundTrips() throws {
        var preset = DisplayPreset(name: "Gaming", icon: "gamecontroller.fill", displays: [])
        preset.shortcut = KeyboardShortcut(keyCode: 18, nsModifierFlags: 1 << 20, keyLabel: "1")
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(DisplayPreset.self, from: data)
        XCTAssertEqual(decoded.shortcut, preset.shortcut)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL to compile CrispTests with `value of type 'DisplayPreset' has no member 'shortcut'`.

- [ ] **Step 3: Add the field**

In `Crisp/Models/DisplayPreset.swift`, inside `struct DisplayPreset`, after the line `var displays: [DisplayPresetEntry]`, add:

```swift
    /// Global shortcut that applies this preset; nil when not set. Old presets
    /// decode as nil (issue #61).
    var shortcut: KeyboardShortcut? = nil
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, including the two new tests.

- [ ] **Step 5: Commit**

```bash
git add project.yml Crisp/Models/DisplayPreset.swift CrispTests/DisplayPresetShortcutTests.swift
git commit -m "feat: preset model carries an optional keyboard shortcut (#61)"
```

---

### Task 3: Generalize HotkeyService to N registrations

**Files:**
- Modify: `Crisp/Services/HotkeyService.swift` (replace the registration half; keep the action half)
- Modify: `Crisp/App/AppDelegate.swift:111` (the `HotkeyService.shared.apply(...)` call)
- Modify: `Crisp/Views/HiDPIShortcutView.swift` (three `apply(...)` call sites; full rework comes in Task 5)

- [ ] **Step 1: Replace the top of HotkeyService**

In `Crisp/Services/HotkeyService.swift`, replace everything from `private var hotKeyRef: EventHotKeyRef?` down to and including the closing brace of `installHandlerIfNeeded()` with:

```swift
    /// What a registered hotkey triggers.
    private enum Target {
        case preset(UUID)
        case hidpiToggle
    }

    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: (ref: EventHotKeyRef, target: Target)] = [:]
    /// Monotonic id source for EventHotKeyID.id; presses look the id up in
    /// `registrations`, so stale ids from a previous sync simply miss.
    private var nextID: UInt32 = 1
    /// While true, syncRegistrations() registers nothing, so a recorder can
    /// capture any combo, including ones currently bound.
    var suspended = false {
        didSet { syncRegistrations() }
    }

    /// Rebuilds every registration from current state: one hotkey per preset
    /// with a shortcut, plus the static Toggle HiDPI action. Idempotent; called
    /// from launch, PresetService.savePresets(), and the recorder.
    func syncRegistrations() {
        for reg in registrations.values { UnregisterEventHotKey(reg.ref) }
        registrations = [:]
        guard !suspended else { return }
        for preset in PresetService.shared.presets {
            if let shortcut = preset.shortcut { register(shortcut, for: .preset(preset.id)) }
        }
        if let shortcut = SettingsService.shared.hidpiShortcut {
            register(shortcut, for: .hidpiToggle)
        }
    }

    private func register(_ shortcut: KeyboardShortcut, for target: Target) {
        installHandlerIfNeeded()
        let id = nextID
        nextID &+= 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4372_7370), id: id)  // "Crsp"
        RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID,
                            GetEventDispatcherTarget(), 0, &ref)
        if let ref { registrations[id] = (ref, target) }
    }

    /// One process-wide handler; presses carry the EventHotKeyID that fired.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            // C-function callback, no captures; read which hotkey fired, then
            // hop to the main actor for the action.
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            Task { @MainActor in HotkeyService.shared.fire(id: id) }
            return noErr
        }, 1, &eventType, nil, &handlerRef)
    }

    private func fire(id: UInt32) {
        switch registrations[id]?.target {
        case .preset(let presetID):
            guard let preset = PresetService.shared.presets.first(where: { $0.id == presetID })
            else { return }
            Task { await PresetService.shared.applyPreset(preset) }
        case .hidpiToggle:
            toggleHiDPIUnderCursor()
        case nil:
            break
        }
    }
```

Keep `toggleHiDPIUnderCursor()` and `hiDPITwin(of:in:)` unchanged below this. Update the class doc comment's first line to: `/// Registers all of Crisp's global shortcuts via Carbon RegisterEventHotKey and dispatches presses to their actions (issue #61).`

- [ ] **Step 2: Update the call sites so the tree still compiles**

In `Crisp/App/AppDelegate.swift`, replace:

```swift
        HotkeyService.shared.apply(SettingsService.shared.hidpiShortcut)
```

with:

```swift
        HotkeyService.shared.syncRegistrations()
```

and change the comment line above it from `if one is recorded (issue` to `(preset shortcuts + Toggle HiDPI, issue`.

In `Crisp/Views/HiDPIShortcutView.swift`:
- In `startRecording()`, replace `HotkeyService.shared.apply(nil)` with `HotkeyService.shared.suspended = true`.
- In `stopRecording()`, replace `HotkeyService.shared.apply(settings.hidpiShortcut)` with `HotkeyService.shared.suspended = false`.
- In the "Remove Shortcut" row action, replace `HotkeyService.shared.apply(nil)` with `HotkeyService.shared.syncRegistrations()`.

- [ ] **Step 3: Verify both build modes**

Run: `make compile && make lint`
Expected: build succeeds, lint silent.

- [ ] **Step 4: Commit**

```bash
git add Crisp/Services/HotkeyService.swift Crisp/App/AppDelegate.swift Crisp/Views/HiDPIShortcutView.swift
git commit -m "feat: HotkeyService handles N registrations with id dispatch (#61)"
```

---

### Task 4: Steal-on-record and PresetService wiring

**Files:**
- Test: `CrispTests/KeyboardShortcutTests.swift` (append one test)
- Modify: `Crisp/Models/KeyboardShortcut.swift` (add `sameKeys(as:)`)
- Modify: `Crisp/Services/PresetService.swift:35-37` (savePresets) and after `deletePreset` (new methods)

- [ ] **Step 1: Write the failing test for key-equality**

Steal must compare by keys, not full equality: the stored `keyLabel` can differ across keyboard layouts for the same physical combo. Append to `CrispTests/KeyboardShortcutTests.swift` (inside the class):

```swift
    /// Steal-on-record compares by key code + modifiers only; the captured label
    /// may differ across keyboard layouts for the same physical combo.
    func testSameKeysIgnoresLabel() throws {
        let a = try XCTUnwrap(KeyboardShortcut(keyCode: 4, nsModifierFlags: command, keyLabel: "H"))
        let b = try XCTUnwrap(KeyboardShortcut(keyCode: 4, nsModifierFlags: command, keyLabel: "И"))
        let c = try XCTUnwrap(KeyboardShortcut(keyCode: 4, nsModifierFlags: option, keyLabel: "H"))
        XCTAssertTrue(a.sameKeys(as: b))
        XCTAssertFalse(a.sameKeys(as: c))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `make test`
Expected: FAIL to compile with `has no member 'sameKeys'`.

- [ ] **Step 3: Implement `sameKeys(as:)`**

In `Crisp/Models/KeyboardShortcut.swift`, after the `display` computed property, add:

```swift
    /// Same physical combo regardless of the captured label (layouts differ).
    func sameKeys(as other: KeyboardShortcut) -> Bool {
        keyCode == other.keyCode && carbonModifiers == other.carbonModifiers
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: PASS.

- [ ] **Step 5: Wire PresetService**

In `Crisp/Services/PresetService.swift`, replace `savePresets()` with:

```swift
    func savePresets() {
        SettingsService.shared.save(presets, filename: filename)
        // Shortcuts live on presets, so any preset change may add/remove/steal one.
        HotkeyService.shared.syncRegistrations()
    }
```

After `deletePreset(id:)`, add:

```swift
    // MARK: - Shortcuts (issue #61)

    /// Sets a preset's shortcut, stealing the combo from every other holder
    /// (other presets and the static Toggle HiDPI action): last save wins.
    func commitShortcut(_ shortcut: KeyboardShortcut?, forPresetID id: UUID) {
        guard let index = presets.firstIndex(where: { $0.id == id }) else { return }
        if let shortcut {
            for i in presets.indices where presets[i].id != id
                && presets[i].shortcut?.sameKeys(as: shortcut) == true {
                presets[i].shortcut = nil
            }
            if SettingsService.shared.hidpiShortcut?.sameKeys(as: shortcut) == true {
                SettingsService.shared.hidpiShortcut = nil
            }
        }
        presets[index].shortcut = shortcut
        savePresets()
    }

    /// The static Toggle HiDPI action recorded a combo: steal it from any preset
    /// holding it, then re-register. Call after storing the new static combo.
    func stealShortcutFromPresets(_ shortcut: KeyboardShortcut) {
        var changed = false
        for i in presets.indices where presets[i].shortcut?.sameKeys(as: shortcut) == true {
            presets[i].shortcut = nil
            changed = true
        }
        if changed {
            savePresets()  // persists and syncs
        } else {
            HotkeyService.shared.syncRegistrations()  // still need the new static hotkey
        }
    }
```

- [ ] **Step 6: Verify and commit**

Run: `make compile && make lint && make test`
Expected: all green.

```bash
git add Crisp/Models/KeyboardShortcut.swift CrispTests/KeyboardShortcutTests.swift Crisp/Services/PresetService.swift
git commit -m "feat: shortcut commit + steal-on-record in PresetService (#61)"
```

---

### Task 5: Shared recorder row + rename the section to "Shortcuts"

**Files:**
- Create: `Crisp/Views/ShortcutRecorderRow.swift`
- Rename+rewrite: `Crisp/Views/HiDPIShortcutView.swift` → `Crisp/Views/ShortcutsSectionView.swift`
- Modify: `Crisp/Views/MenuBarView.swift` (mount point and comment)
- Modify: `Crisp/Resources/Localizable.xcstrings` (add 3 keys, drop 1)

- [ ] **Step 1: Create the shared recorder row**

Create `Crisp/Views/ShortcutRecorderRow.swift`:

```swift
import SwiftUI

/// One record-in-place shortcut row, shared by the Settings > Shortcuts section
/// and the preset form (issue #61): action label leading, then the combo glyphs
/// (or "Record Shortcut"), with an × to clear. Tapping toggles recording; a local
/// keyDown monitor captures the next valid combo, Esc cancels. All registered
/// hotkeys are suspended while recording so bound combos can be re-captured.
/// Commit semantics live in the binding: Settings commits immediately, the preset
/// form holds the value in @State until Save.
struct ShortcutRecorderRow: View {
    let label: String
    @Binding var shortcut: KeyboardShortcut?
    /// Extra leading inset so the row aligns under a section's icon chip.
    var leadingInset: CGFloat = 0
    @State private var isRecording = false
    @State private var monitor: Any? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(LocalizedStringKey(label))
                .font(.body)
            Spacer()
            if isRecording {
                Text("Type shortcut… (Esc to cancel)")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            } else if let shortcut {
                Text(verbatim: shortcut.display)
                    .font(.callout)
                    .foregroundColor(.secondaryReadable)
                Button {
                    self.shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove Shortcut")
            } else {
                Text("Record Shortcut")
                    .font(.caption)
                    .foregroundColor(.secondaryReadable)
            }
        }
        .padding(.horizontal, 12)
        .padding(.leading, leadingInset)
        .padding(.vertical, 5)
        .menuRowHover(isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            guard PanelOpenGuard.allowsActivation else { return }
            if isRecording { stopRecording() } else { startRecording() }
        }
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
        .onReceive(NotificationCenter.default.publisher(for: .crispPanelDidClose)) { _ in
            // The panel resigns key on close; an in-flight recording can't finish.
            stopRecording()
        }
        // The preset form unmounts on Save/Cancel; don't leak the monitor.
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        // Free every bound combo so any of them can be re-recorded here.
        HotkeyService.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {  // kVK_Escape cancels
                stopRecording()
                return nil
            }
            let label = KeyboardShortcut.keyLabel(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers)
            // nil = no ⌘⌥⌃ anchor yet (typing, not a shortcut): swallow, keep listening.
            if let recorded = KeyboardShortcut(
                keyCode: event.keyCode, nsModifierFlags: event.modifierFlags.rawValue,
                keyLabel: label) {
                shortcut = recorded
                stopRecording()
            }
            return nil
        }
    }

    private func stopRecording() {
        guard monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        HotkeyService.shared.suspended = false
    }
}
```

- [ ] **Step 2: Rename and rewrite the section**

```bash
git mv Crisp/Views/HiDPIShortcutView.swift Crisp/Views/ShortcutsSectionView.swift
```

Replace the entire content of `Crisp/Views/ShortcutsSectionView.swift` with:

```swift
import SwiftUI

/// Settings > Shortcuts: the curated list of named global-shortcut actions
/// (issue #61). One action today, Toggle HiDPI; the bar for adding another is
/// "someone asked" (see the 2026-08-18 spec). Per-preset shortcuts live on the
/// presets themselves, not here. Expands in place per DESIGN.md.
struct ShortcutsSection: View {
    @ObservedObject private var settings = SettingsService.shared
    // Owned by SettingsView so its panel-close reset collapses this section
    // like every other.
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ExpandableRow(
                icon: "command",
                iconActive: settings.hidpiShortcut != nil,
                label: "Shortcuts",
                subtitle: settings.hidpiShortcut?.display,
                isExpanded: $expanded
            )
            if expanded {
                ShortcutRecorderRow(
                    label: "Toggle HiDPI",
                    shortcut: Binding(
                        get: { settings.hidpiShortcut },
                        set: { newValue in
                            // Commits immediately (no form): store, steal the
                            // combo from any preset holding it, re-register.
                            settings.hidpiShortcut = newValue
                            if let newValue {
                                PresetService.shared.stealShortcutFromPresets(newValue)
                            } else {
                                HotkeyService.shared.syncRegistrations()
                            }
                        }
                    ),
                    leadingInset: 34
                )
                Text("Switches the display under the pointer between HiDPI and low resolution.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.leading, 34)
                    .padding(.bottom, 4)
            }
        }
    }
}
```

- [ ] **Step 3: Update the mount point**

In `Crisp/Views/MenuBarView.swift`, replace:

```swift
            // Global HiDPI-toggle shortcut (issue #61).
            HiDPIShortcutSection(expanded: $showHiDPIShortcut)
```

with:

```swift
            // Global shortcuts: the curated action list (issue #61).
            ShortcutsSection(expanded: $showHiDPIShortcut)
```

(The `showHiDPIShortcut` state name stays; renaming it would churn three more lines for nothing.)

- [ ] **Step 4: Localization catalog**

Run this script (same splice technique as the foundation commit; anchors are existing keys, insertion keeps Xcode's sort):

```bash
python3 - <<'EOF'
import json, re

path = 'Crisp/Resources/Localizable.xcstrings'
src = open(path).read()

def entry(key, zh):
    return (
        f'    "{key}" : {{\n'
        f'      "localizations" : {{\n'
        f'        "zh-Hans" : {{\n'
        f'          "stringUnit" : {{\n'
        f'            "state" : "translated",\n'
        f'            "value" : "{zh}"\n'
        f'          }}\n'
        f'        }}\n'
        f'      }}\n'
        f'    }},\n'
    )

inserts = [
    ("Show all resolutions", "Shortcut", "快捷键"),
    ("Show all resolutions", "Shortcuts", "快捷键"),
    ("Tools", "Toggle HiDPI", "切换 HiDPI"),
]
for anchor, key, zh in inserts:
    marker = f'    "{anchor}" : {{'
    assert src.count(marker) == 1, (anchor, src.count(marker))
    src = src.replace(marker, entry(key, zh) + marker)

# Drop the superseded section-name key.
gone = re.sub(
    r'    "HiDPI Shortcut" : \{.*?\n    \},\n', '', src, count=1, flags=re.S)
assert gone != src, "HiDPI Shortcut entry not found"
open(path, 'w').write(gone)
json.load(open(path))  # validate
print("ok")
EOF
```

Note: "Shortcut" is inserted for Task 6's form row; it is unused until then, which the loc-check tolerates (it checks code keys exist in the catalog, not the reverse).

- [ ] **Step 5: Verify**

Run: `make compile && make lint && make loc-check`
Expected: all green (loc-check must not report a missing key; "HiDPI Shortcut" is no longer referenced anywhere).

- [ ] **Step 6: Commit**

```bash
git add Crisp/Views/ShortcutRecorderRow.swift Crisp/Views/ShortcutsSectionView.swift \
  Crisp/Views/MenuBarView.swift Crisp/Resources/Localizable.xcstrings
git commit -m "feat: Shortcuts section with shared recorder row (#61)"
```

---

### Task 6: Shortcut row in the preset create/edit form

**Files:**
- Modify: `Crisp/Views/SavePresetView.swift` (SavePresetForm: state ~line 82, init ~line 101, body after the Captures block ~line 258, `save()` ~line 314)

- [ ] **Step 1: Add form state**

In `SavePresetForm`, after the `@State private var recaptureValues: Bool = false` declaration, add:

```swift
    /// Global shortcut for this preset, held here until Save like name and icon
    /// (issue #61). Recording works at creation time because this form is also
    /// the New Preset form.
    @State private var recordedShortcut: KeyboardShortcut? = nil
```

In `init`, after `_includeArrangement = State(...)`, add:

```swift
        _recordedShortcut = State(initialValue: editing?.shortcut)
```

- [ ] **Step 2: Add the row to the body**

After the Captures `VStack`'s closing brace (the one ending with the `PresetArrangementThumbnail` conditional, directly before the `// Edit mode only:` comment), add:

```swift
            ShortcutRecorderRow(label: "Shortcut", shortcut: $recordedShortcut)
                .padding(.horizontal, -12)  // recorder row pads itself; cancel the form's inset
```

- [ ] **Step 3: Commit the shortcut on Save**

In `save()`, add `PresetService.shared.commitShortcut(recordedShortcut, forPresetID: editing.id)` at the end of the `if let editing` branch (after the `recaptureValues` block), and in the else branch add the same call after `addPreset`:

```swift
        if let editing {
            PresetService.shared.editPreset(
                id: editing.id, name: name, icon: selectedIcon, colorName: selectedColor,
                includeResolution: includeResolution,
                includeBrightness: includeBrightness,
                includeArrangement: includeArrangement
            )
            if recaptureValues {
                PresetService.shared.updatePreset(id: editing.id)
            }
            PresetService.shared.commitShortcut(recordedShortcut, forPresetID: editing.id)
        } else {
            var preset = PresetService.shared.captureCurrentState(
                name: name, icon: selectedIcon,
                includeResolution: includeResolution,
                includeBrightness: includeBrightness,
                includeArrangement: includeArrangement
            )
            preset.colorName = selectedColor
            PresetService.shared.addPreset(preset)
            PresetService.shared.commitShortcut(recordedShortcut, forPresetID: preset.id)
        }
```

- [ ] **Step 4: Verify and commit**

Run: `make compile && make lint`
Expected: green.

```bash
git add Crisp/Views/SavePresetView.swift
git commit -m "feat: record a preset shortcut in the create/edit form (#61)"
```

---

### Task 7: Shortcut glyphs on the preset row

**Files:**
- Modify: `Crisp/Views/PresetListView.swift:134` (rowContent, after `Spacer()`)

- [ ] **Step 1: Add the trailing glyphs**

In `PresetRow.rowContent`, between `Spacer()` and the `if isCurrentMatch` checkmark, add:

```swift
            // Assigned global shortcut, right-aligned like a native menu key
            // equivalent (issue #61).
            if let combo = preset.shortcut?.display {
                Text(verbatim: combo)
                    .font(.callout)
                    .foregroundColor(.secondaryReadable)
            }
```

- [ ] **Step 2: Verify and commit**

Run: `make compile && make lint`
Expected: green.

```bash
git add Crisp/Views/PresetListView.swift
git commit -m "feat: show a preset's shortcut on its row (#61)"
```

---

### Task 8: Full gates and live verification

**Files:** none planned; fix-up commits only if verification finds issues.

- [ ] **Step 1: Everything CI enforces**

Run: `make check`
Expected: `check passed: lint clean, tests green, localization keys complete`.

- [ ] **Step 2: Deploy the dev build**

Run: `make dev`
Expected: `Done. Crisp <version> running.`
Note: the machine already has `crisp.hidpiShortcut` seeded with ⌃⌥⌘H from the foundation's live test; it now drives the Toggle HiDPI action and should appear in Settings > Shortcuts immediately.

- [ ] **Step 3: Live checklist (needs a human keypress; the harness cannot post keyboard events)**

Ask Didrik to verify, in order:
1. Settings > Shortcuts shows "Toggle HiDPI ⌃⌥⌘H"; pressing ⌃⌥⌘H with the cursor on a display showing a twin-capable mode flips HiDPI (beep at native 2560x1440, correct).
2. New Preset form shows the Shortcut row; record a combo (e.g. ⌃⌥1), Save; the preset row shows ⌃⌥1 right-aligned.
3. Press ⌃⌥1 with another app frontmost and the panel closed; the preset applies.
4. Edit a second preset, record the SAME combo ⌃⌥1, Save; the first preset's glyphs disappear (steal), and ⌃⌥1 now applies the second preset.
5. Record ⌃⌥⌘H on a preset; the Shortcuts section's Toggle HiDPI clears (steal across namespaces).
6. In the recorder, press Esc; recording stops without change. Close the panel mid-recording; reopen; no stuck "Type shortcut…" state, and shortcuts still fire.
7. × on the preset form's shortcut row, Save; the row's glyphs disappear and the combo no longer fires.

- [ ] **Step 4: Final commit if fixes were needed, then stop**

The branch is NOT pushed and no PR is opened without Didrik's explicit approval (project rule). Release-notes text, the #61 closing comment, and the roadmap-board move are separate approval items.

---

## Self-review notes

- Spec coverage: model field (T2), N-registration service + suspend (T3), steal in one namespace with both commit paths (T4, T5 binding, T6 save), recorder in create AND edit (T6 via shared form), row glyphs (T7), Settings section rename with caption (T5), localization add/drop (T5), launch registration (T3), savePresets sync (T4), live checklist incl. steal/Esc/panel-close edge cases (T8). Not-in-v1 items have no tasks, by design.
- Type consistency: `commitShortcut(_:forPresetID:)`, `stealShortcutFromPresets(_:)`, `syncRegistrations()`, `suspended`, `sameKeys(as:)` are each defined once and used with those exact names in later tasks.
- The `keyboardShortcut(.defaultAction)` on the form's Save button is SwiftUI-local (panel focus) and does not collide with Carbon global hotkeys.
