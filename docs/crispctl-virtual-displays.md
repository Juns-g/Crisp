# Virtual displays through crispctl

**Formal hardware acceptance has not been performed.** Compilation and model
checks do not prove a usable desktop without HDMI. This change follows the
current main branch's socket, JSON envelope, exit codes and bundled Skill;
it does not restore the archived control-plane package or software audio mode.

## Commands

Crisp must already be running for the same user. The CLI never launches it.
Use `--json` for scripts; without it the CLI prints the main branch's text output.

```sh
crispctl status --json
crispctl virtual list --json
crispctl virtual configure <config-id> <name> <width> <height> <hidpi> <auto-create> --json
crispctl virtual ensure <config-id> --json
crispctl virtual disable <config-id> --json
```

Choose a config UUID once (`uuidgen`) and retain it. It is separate from a
physical display's UUID and the numeric runtime display ID. Both toggles take
`on` or `off`, hiDPI first, then autoCreate. Width 320–8192 and height 200–8192
are integer pixels; names must be nonblank and at most 256 UTF-8 bytes.

Configure saves only; it verifies the exact UserDefaults value by read-back,
which is not a disk fsync guarantee. Active geometry changes require disable
first. AutoCreate restores on the next Crisp start in a logged-in desktop; it
does not enable launch at login, prevent sleep or run before login. Ensure
reuses the retained screen for the same configuration; concurrent creation is
refused. A same-size third-party screen cannot satisfy it. An unowned online
screen with the same vendor/product/serial identity is reported as a conflict,
not adopted or duplicated. Saved descriptor identity collisions are refused.

Disable releases only this configuration's Crisp-owned object, waits for its
runtime ID to leave online enumeration, and keeps its saved settings. Set
autoCreate off as well to prevent next-start restoration. Delete a saved test
configuration in the GUI if desired.

## State and failure

List returns `virtualDisplays`; a mutation returns `virtualDisplay`, including
on service failure when the configuration is known. Status adds `running:true`
and the same virtual-display list. The existing `{ok,error}` envelope and exit
codes remain: 0 success, 1 unreachable/lost reply, 2 arguments, 3 app refusal.

| Field | What it proves |
|---|---|
| `config` | Saved identity and requested name, dimensions, hiDPI and autoCreate choices |
| `saved` | Exact configuration read back from UserDefaults |
| `enableRequested` | Last enable/release request in this session; omitted before any request |
| `creating`, `retained` | Creation/apply in flight, and a strongly retained CGVirtualDisplay |
| `online` | Retained runtime ID and descriptor found in CoreGraphics; omitted on enumeration failure |
| `active`, `ready` | Active display; ready additionally requires saved config, readable mode and no creation in flight |
| `displayID` | Diagnostic runtime ID; never a configuration selector |
| `resolution` | Actual logical/pixel dimensions, refresh rate and HiDPI state; omitted if unavailable |
| `lastError` | Last creation failure or current enumeration failure; omitted when none is known |

An apply that outlives its timeout keeps the owned object and blocks further
writes for that config, including disable, until the worker completes. If it
never completes, arrange a controlled App restart. Creation may still settle
after an error; read list before deciding and never retry uncertain writes
automatically. A later successful state can coexist with a historical lastError.
Virtual writes wait up to 67 seconds for the existing bounded creation/mode
attempts; reads and physical command budgets are unchanged.

A read does not create, restore, remove or change modes. App startup itself can
restore saved autoCreate configs. Ready proves display/mode state, not native
resolution, screenshot/input permission, an unlocked session or sleep prevention.
Compare actual and configured dimensions when native resolution matters.
Keep Awake, lock/FileVault/login control and capture/input tools are outside scope.

## Controlled acceptance and recovery

Keep a real display connected. First arrange a controlled session, quit the
installed Crisp yourself, then open a separate test App built from this branch.
It shares Crisp's settings and single-instance lock. Preserve the installed
app as the recovery path; do not replace it for this test. macOS may move
windows or show its mirror/extend picker when a virtual screen is created.

Use a CLI built from the same source. Do not use commands from the archived
foundation branch; the current command group is `virtual`.

```sh
CLI=/path/to/test/Crisp.app/Contents/MacOS/crispctl
CONFIG_ID="$(uuidgen)"  # retain this value through App restarts
"$CLI" virtual configure "$CONFIG_ID" "Crisp CLI Test" 1920 1080 on off --json
"$CLI" virtual list --json
"$CLI" virtual ensure "$CONFIG_ID" --json
"$CLI" status --json
"$CLI" virtual ensure "$CONFIG_ID" --json
"$CLI" virtual list --json
```

Require saved-but-offline state after configure, then the same `config.id`,
online/active/ready true, readable actual resolution and the same displayID
across repeat ensure, with one test screen in macOS. To test startup recovery:

```sh
"$CLI" virtual configure "$CONFIG_ID" "Crisp CLI Test" 1920 1080 on on --json
# Quit and reopen the test App yourself, then read without ensure:
"$CLI" status --json
```

Require that same config restored online. The runtime displayID may change.
Cleanup and prevent restoration:

```sh
"$CLI" virtual configure "$CONFIG_ID" "Crisp CLI Test" 1920 1080 on off --json
"$CLI" virtual disable "$CONFIG_ID" --json
"$CLI" virtual list --json
```

Require saved true, autoCreate false, online false and retained false. Delete
the saved test config in the GUI if desired, quit the test App, and reopen the
original installed app.

When the Mac mini arrives, separately arrange launch at login and system sleep
settings, then repeat after disconnecting HDMI. Through the intended remote
tools, capture the desktop, click a visible harmless control, enter text in a
disposable document, then capture again to read back the changed control/text.
Reconnect HDMI for recovery. An online status, a fixture or exit 0 alone does
not pass this acceptance.
