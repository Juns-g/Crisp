# crispctl automation interface

`crispctl` is Crisp's versioned, JSON-first automation interface. The CLI never
talks to display APIs itself: it sends one request over a local Unix-domain
socket to the running Crisp app, which reuses `DisplayManager` and
the existing app services. Physical connection writes specifically reuse
`PhysicalDisplayToggleService`; neither the CLI nor the protocol layer calls
SkyLight/CoreGraphics display-write APIs.

## Installation and agent discovery

Public installs gain `crispctl` only with the first Crisp release that contains
this distribution change. Crisp 1.5.0 does not contain the bundled CLI. Source
checkout users can build it. In a release that includes it, the Homebrew cask
exposes `crispctl` on `PATH`:

```sh
brew install --cask didriksg/tap/crisp
crispctl version --json
```

A manual DMG install can invoke the embedded executable without changing
`PATH`:

```sh
/Applications/Crisp.app/Contents/MacOS/crispctl version --json
```

Users who prefer a short command may create a symlink in a user-owned directory
such as `~/.local/bin`; `sudo` is not required and the app-internal path remains
the deterministic fallback.

The standard AI-agent Skill is
[../skills/crispctl/SKILL.md](../skills/crispctl/SKILL.md). Install it globally
for all agent types supported by the conventional installer:

```sh
npx skills add didriksg/Crisp --skill crispctl -g --agent '*' -y
```

The quotes around `'*'` prevent shell expansion. Skill discovery is evaluated
at startup in many agents, so a fresh agent session may be required;
installation does not promise hot-loading into the current session.

## Commands

```sh
crispctl version --json
crispctl status --json [--no-start]
crispctl displays list --json [--no-start]
crispctl displays get <uuid|main|builtin|name> --json [--no-start]
crispctl displays capabilities <selector> --json [--no-start]
crispctl displays disconnected --json [--no-start]
crispctl displays disconnect <uuid> --json [--no-start]
crispctl displays reconnect <uuid> --json [--no-start]
crispctl brightness get <selector> --json [--no-start]
crispctl brightness set <selector> <percent> --json [--no-start]
crispctl brightness get-all --json [--no-start]
crispctl brightness set-all <percent> --json [--no-start]
crispctl extra-brightness get <selector> --json [--no-start]
crispctl extra-brightness set <selector> on|off --json [--no-start]
crispctl hdr get <selector> --json [--no-start]
crispctl hdr set <selector> on|off --json [--no-start]
```

Display UUID is the stable canonical selector. Read commands and unrelated P0
writes retain the existing `main`, `builtin`, and case-insensitive name
conveniences; an ambiguous name fails with candidate UUIDs. Physical connection
writes accept only the exact UUID form documented below.

## Physical display connection state

This additive P1 source slice is not a claim that Crisp 1.5.0 contains
`crispctl`, and its headless tests do not perform a real display write. On a
release/source build that contains the slice, each online display includes a
`connection` capability with `state`, current `connected` truth,
`disconnectAllowed`, `reconnectAllowed`, `platformSupported`, and optional
`reason`/`remediation`. `displays capabilities` includes the same connection
object.

`displays disconnected` returns only stable automation identities that Crisp
intentionally disconnected, deterministically sorted by UUID. Each item has
`uuid`, `name`, `width`, `height`, and its connection capability. A last-known
`CGDirectDisplayID` is retained privately for the existing recovery machinery
but is never exposed or accepted as an automation identity.

The safe per-write sequence is:

1. Obtain explicit user authorization for the exact connection write.
2. For disconnect, read fresh `displays list` and `displays capabilities`, copy
   the exact `uuid` without normalization, then run `displays disconnect <uuid>`.
   Names, `main`, `builtin`, legacy `selector` arguments, and non-UUID values
   fail before inventory work or mutation. The app re-resolves that exact UUID
   immediately before dispatch and never switches targets.
3. For reconnect, read a fresh `displays disconnected` inventory and copy the
   exact `uuid` without normalization into `displays reconnect <uuid>`. Names,
   `main`, `builtin`, missing/collapsed records, stale IDs, and UUIDs absent from
   that fresh response fail before mutation.

Connection writes fail closed unless the existing platform gate proves Apple
Silicon and macOS 13 or later and the target has positive hardware-backed
physical proof: a built-in panel or an external display with an IOKit
`IODisplayConnect` service. Crisp virtual displays, third-party virtual
displays, placeholders, and unknown or unprovable targets are excluded and
cannot count as the other viewable display. Disconnect must leave another
positively proven active physical viewable display. This does not equate DDC
support with physicality. A transaction return alone is not proof. Success
requires bounded same-UUID enumeration:
disconnect proves the UUID offline while its intentional record remains;
reconnect proves it online and then proves the intentional record absent.
Success reports `displayUUID`, `requestedConnectionState`,
`observedConnectionState`, `verification: same_uuid_enumeration`, and
`warnings`.

After dispatch, a service/transport timeout, cancellation, configuration
failure, identity loss, or late/non-settling enumeration returns
`write_outcome_indeterminate`, exit code 5, and `retrySafe: false`. The
response includes the exact `displayUUID`, requested connection state, and
command. WindowServer may still finish. Never automatically retry. Read a
fresh `displays list` and `displays disconnected`, let same-UUID reconciliation
finish, explain the observed state, and obtain a fresh user decision before any
later write.

If Crisp is unavailable, the CLI normally resolves and launches the registered
`com.crisp.app` bundle, verifies that bundle identity, and polls socket readiness
for a bounded interval. `--no-start` returns `app_not_running` immediately.
Tests inject a launcher and never open the GUI.

Brightness values are logical percentages within the selected display's current
`brightness.logicalRange` (also retained as the compatible `brightness.range`).
`brightness.hardwareRange` is always the native/DDC range, normally 0...100.
When Extra Brightness is enabled and usable, the logical maximum is the live
`DisplayInfo.maxBrightness`; it is never hardcoded to 200 and does not represent
absolute nits. `headroom.potential` and `headroom.current` are relative NSScreen
EDR component values. `headroom.appliedFactor` is the most recent factor Crisp
committed through its overlay or transfer-table path. Its
`factorVerification` is `app_state`; a missing value is `null`. Neither field is
an independent measurement of EDR output or emitted light.

A read returns compatible `percent` plus unambiguous `logicalPercent` and
`hardwareReadbackPercent`. A logical value above 100 can therefore coexist with
a hardware read-back of 100. A set response includes requested, original,
applied, and read-back values, backend, verification quality, and warnings. At
or below 100, authoritative/approximate/unavailable retain their existing
meaning. Above 100, `app_state_verified` means Crisp committed the logical state
and synchronized its existing EDR/boost path; it is not hardware-authoritative
EDR verification. An unavailable independent EDR read-back is stated in
`warnings`.

`extra-brightness get/set` reports `state`, live `enabled`,
`persistedEnabled`, `maxBrightness`, relative `headroom`, reasons, and
remediation. A verified disable has reached its generation-guarded terminal
state: logical brightness is at most 100, the ceiling and boost factor are at
identity, and the overlay is removed. If disable was accepted and persisted off
but fresh same-UUID state still positively shows terminal cleanup in progress,
the command is non-failing with `verification: settling` and a warning. That is
transitional app state, not terminal verification; read back before another
write and do not retry automatically. Identity loss or another unknown
post-mutation result remains `write_outcome_indeterminate`, with no automatic
retry. An accepted enable can also return `settling` while its animated ceiling
grows. `hdr get/set` is distinct and writable only for an external display
where Crisp's GUI exposes the explicit HDR toggle. A built-in display returns
`unsupported_capability` with remediation to use Extra Brightness when
eligible. HDR set is verified only after bounded live read-back.

Normally every write requires a fresh discovery response with `state: writable`
and the exact same UUID. The sole exception is
`extra-brightness set <same-uuid> off`: a freshly returned same-UUID Extra
Brightness state may have `state: unsupported` while positively proving cleanup
is needed through `persistedEnabled: true`, `enabled: true`, or
`maxBrightness > 100`. This exception never permits `on`, never permits
unsupported HDR or brightness writes, and never permits unsupported `off`
without a cleanup indicator. Obtain explicit user authorization for that exact
cleanup command. For every other capability collapse, unsupported state, or
stale UUID, stop and re-discover before a fresh user decision. The cleanup path
retains `write_outcome_indeterminate`, `retrySafe: false`, separate read-back,
and no automatic retry rules.

`brightness get-all` and `brightness set-all` target every connected
non-virtual physical display in UUID order. Their semantics are
`same_logical_percent_per_display`: 125 means logical 125 on each display, not a
normalized fraction, so preflight fails without any write if even one target's
dynamic maximum is lower. Hardware writes are not atomic and are never rolled
back. A partial execution returns `batch_partial_failure`, ordered per-display
outcomes, `appliedUUIDs`, `failedUUIDs`, `indeterminateUUIDs`, and
`notAttemptedUUIDs`. Each outcome says whether it was attempted and carries its
own `attempted`, `outcome`, `verification`, `code`, and `retrySafe` fields; a
successful member uses `code: null`, while a member that was not attempted is
explicitly classified. The aggregate is `retrySafe: false`. The batch's
internal deadline returns accumulated results before the server deadline, so
only the in-flight member is indeterminate and later members are not attempted.
Do not retry successful or indeterminate members. Only a `retrySafe: true`
member may be reconsidered after reconciliation and a fresh authorized
decision; there is no automatic retry. Empty
physical inventory returns `empty_physical_inventory`.

## Response contract

Every stdout response in JSON mode is one JSON value followed by a newline:

```json
{
  "protocolVersion": 1,
  "requestID": "...",
  "ok": false,
  "error": {
    "code": "ambiguous_selector",
    "message": "display selector is ambiguous",
    "details": {"candidates": []}
  }
}
```

Success uses `result` instead of `error`. Exit codes are stable by category:
1 internal, 2 arguments, 3 app lifecycle, 4 unsupported capability, 5 write
verification or indeterminate write outcome, 6 selector, 7 protocol, and 8
transport/timeout. Batch preflight/empty inventory use capability category 4;
`batch_partial_failure` uses write category 5. `write_outcome_indeterminate`
includes `retrySafe: false`
and the requested selector/target: an in-flight macOS or DDC callback may still
apply after the CLI times out, so callers must read current state and must not
automatically repeat the write.

These fields and commands are additive protocol-v1 extensions. Older v1
display payloads decode with defaults for the new capability fields; existing
field names, types, and exit categories remain unchanged.

All mutating commands (`brightness set`, `brightness set-all`,
`extra-brightness set`, `hdr set`, `displays disconnect`, and
`displays reconnect`) use this indeterminate contract. Batch
timeouts identify `all_physical_displays`; selector writes include the selector
and target. Read current state before seeking a new user-authorized decision.

## Security and lifecycle

- The socket lives below the current user's temporary directory. Its parent is
  mode `0700` and the socket is mode `0600`.
- The server rejects peers whose `getpeereid` UID differs from Crisp's UID.
- Startup removes only a stale, same-owner socket. It never replaces a regular
  file, a foreign-owned socket, or a reachable active server.
- The socket is removed on orderly app termination. Abrupt termination is
  recovered on the next start.
- The trust boundary is the local user account: another process running as the
  same UID can issue commands. There is intentionally no network listener.
- Request and response size is strictly bounded to 1 MiB. Client waits, accepted
  socket I/O, and command handlers use bounded timeouts; the server also caps
  concurrent accepted connections at 16. A timed-out hardware write reports an
  unknown outcome, not a rollback guarantee, because an in-flight macOS/DDC call
  may not support cancellation.

## Development verification

The dependency-free control plane can be checked without launching Crisp:

```sh
swift test --disable-sandbox
swift build --disable-sandbox --product crispctl
./scripts/test-crispctl-roundtrip.sh
```

The round-trip script starts a separate fixture host process, exercises list,
status, all P0 get/set commands, >100 logical state, batch behavior, plus
disconnected list -> fixture disconnect -> retained record -> exact-UUID
reconnect -> empty list through the real socket, then
removes the process and socket. It contains the only hardcoded display fixture;
production discovery always comes from Crisp's live `DisplayManager`.

External DDC hardware, real app launch/readiness, real brightness writes, and
real physical display disconnect/reconnect require separately authorized host
validation and are not exercised by the headless suite.
