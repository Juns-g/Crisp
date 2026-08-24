# crispctl automation interface

`crispctl` is Crisp's versioned, JSON-first automation interface. The CLI never
talks to display APIs itself: it sends one request over a local Unix-domain
socket to the running Crisp app, which reuses `DisplayManager` and
`BrightnessService`.

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
crispctl brightness get <selector> --json [--no-start]
crispctl brightness set <selector> <percent> --json [--no-start]
```

Display UUID is the stable canonical selector. `main` and `builtin` are
explicit aliases. Names are case-insensitive conveniences; an ambiguous name
fails with candidate UUIDs instead of selecting one.

If Crisp is unavailable, the CLI normally resolves and launches the registered
`com.crisp.app` bundle, verifies that bundle identity, and polls socket readiness
for a bounded interval. `--no-start` returns `app_not_running` immediately.
Tests inject a launcher and never open the GUI.

Brightness values are percentages within the selected display's reported
capability range. A set response includes requested, original, applied, and
read-back values, the active backend, verification quality, and warnings. An
authoritative or approximate backend does not return success until read-back is
within its declared precision. Software/gamma fallback reports unavailable
read-back instead of inventing precision.

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
transport/timeout. `write_outcome_indeterminate` includes `retrySafe: false`
and the requested selector/target: an in-flight macOS or DDC callback may still
apply after the CLI times out, so callers must read current state and must not
automatically repeat the write.

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
status, brightness get/set and verified read-back through the real socket, then
removes the process and socket. It contains the only hardcoded display fixture;
production discovery always comes from Crisp's live `DisplayManager`.

External DDC hardware, real app launch/readiness, and real brightness writes
require separately authorized host validation and are not exercised by the
headless suite.
