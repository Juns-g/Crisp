---
name: crispctl
description: Use when controlling displays through Crisp's JSON CLI.
version: 0.1.0
author: Juns (Juns-g), Hermes Agent
license: MIT
platforms:
  - macos
metadata:
  hermes:
    tags:
      - crisp
      - display-control
      - automation
    related_skills: []
---

# crispctl

## When to Use

Use this Skill to discover displays, inspect Crisp-supported capabilities, or
perform an explicitly requested P0 brightness, Extra Brightness, or external
HDR read/write through Crisp's
versioned JSON interface. Do not substitute macOS display APIs or another
display CLI: Crisp must remain the owner of display state.

Only discovery and P0 brightness/Extra Brightness/external-HDR operations are
supported. Do not emulate modes, arrangement, presets, disconnects, virtual
displays, or any P1/P2 operation.
These remain Tier 2/3 operations outside this Skill.
The HDR toggle is for eligible external displays only. Built-in HDR is not a
write surface; use Extra Brightness when its live capability is writable.

## Prerequisites

- Run on macOS 14 or later with a Crisp release that includes `crispctl`.
- Public installs gain `crispctl` only with the first Crisp release that
  contains this distribution change. Crisp 1.5.0 does not contain the bundled
  CLI. Source checkout users can build it.
- Prefer a Homebrew cask installation for a release that includes `crispctl`;
  the cask exposes it on `PATH`.
- A manual DMG installation can use the executable embedded inside Crisp.app;
  no system-wide symlink or `sudo` is required.

### Install the Skill

Install the Skill from the canonical
[repository source](https://github.com/didriksg/Crisp/tree/main/skills/crispctl)
for all agent types supported by the conventional installer:

```sh
npx skills add didriksg/Crisp --skill crispctl -g --agent '*' -y
```

The quotes around `'*'` prevent shell expansion. Skill discovery is normally
evaluated when an agent session starts. Installing the Skill does not hot-load
it; a fresh agent session may be required.

## How to Run

### Preflight

Use the agent's terminal tool. Resolve the executable and run the desired
command in the same shell call. Prefer `command -v crispctl`, then check the
standard system and current-user Applications locations. Stop if none is
executable; never guess or fall back to another display CLI.

```sh
resolve_crispctl() {
  candidate="$(command -v crispctl 2>/dev/null || true)"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  for candidate in \
    /Applications/Crisp.app/Contents/MacOS/crispctl \
    "$HOME/Applications/Crisp.app/Contents/MacOS/crispctl"
  do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

CRISPCTL="$(resolve_crispctl)" || {
  echo "crispctl is not installed; install a Crisp release that ships it" >&2
  exit 127
}

"${CRISPCTL}" version --json
"${CRISPCTL}" displays list --json
```

Use only `--json` responses for automation. Follow this procedure:

1. Run `"${CRISPCTL}" displays list --json` and select a display by UUID when
   possible. `main` and `builtin` are explicit conveniences; names can be
   ambiguous.
2. Before every write, run
   `"${CRISPCTL}" displays capabilities <uuid> --json` and verify that the
   requested operation is normally `state: writable` and its value is within
   the returned live range. Fresh discovery and the exact same UUID are
   mandatory; UUID selectors are required when available.
   The sole exception is `extra-brightness set <same-uuid> off` when the fresh
   same-UUID response has `state: unsupported` but proves cleanup is needed with
   `persistedEnabled: true`, `enabled: true`, or `maxBrightness > 100`.
   This exception never permits `on`, never permits unsupported HDR or
   brightness writes, and never permits unsupported `off` without a cleanup
   indicator. For every other missing capability, capability collapse,
   stale display UUID, or read-back mismatch, stop and re-discover before
   seeking a fresh user decision; never change targets or ranges.
3. Read with `"${CRISPCTL}" brightness get <uuid> --json`.
4. Obtain explicit user authorization for the exact UUID(s), command, and
   target before every write. For an explicitly requested supported write, run
   `"${CRISPCTL}" brightness set <uuid> <percent> --json`. No extra
   confirmation is needed for that already-requested write. The cleanup-only
   exception also requires explicit user authorization for the exact
   `extra-brightness set <same-uuid> off` command.
5. Extra Brightness uses `"${CRISPCTL}" extra-brightness get <uuid> --json`
   and `"${CRISPCTL}" extra-brightness set <uuid> on|off --json`. External HDR
   uses `"${CRISPCTL}" hdr get <uuid> --json` and
   `"${CRISPCTL}" hdr set <uuid> on|off --json`; built-in displays direct the
   user to Extra Brightness instead of exposing a fake HDR toggle.
6. Batch reads/writes use `"${CRISPCTL}" brightness get-all --json` and
   `"${CRISPCTL}" brightness set-all <percent> --json`. The percent is the same
   logical value per display, not a normalized fraction.
   Batch writes are non-atomic: hardware members cannot be rolled back safely.
7. If the user forbids launching Crisp, append `--no-start` to the command.
   Otherwise `crispctl` may use its bounded bundle-ID launch/readiness policy.

## Pitfalls

- Stop on an `ambiguous_selector` response and present candidate UUIDs. Never
  guess a display.
- Treat `unsupported_capability`, `permission_required`, unavailable read-back,
  warnings, and remediation text as real constraints rather than success.
- A `write_outcome_indeterminate` response means an in-flight hardware callback
  may still apply; do not retry it automatically. There is no automatic retry.
  Read back the selected display,
  explain that the timed-out write may still complete, and require a fresh user
  decision before any later write.
- Apply that same `write_outcome_indeterminate`, `retrySafe:false`, read-back,
  and fresh-user-decision rule to brightness, Extra Brightness, external HDR,
  and batch mutations. The cleanup-only exception does not change
  `write_outcome_indeterminate`, `retrySafe: false`, separate read-back, fresh
  user decision, or no automatic retry rules.
- If Extra Brightness disable returns `ok: true` with
  `verification: settling`, it was accepted and persisted off, but terminal
  cleanup is still in progress. Treat the returned state and warning as
  transitional, read back before another write, and make no automatic retry.
- A `batch_partial_failure` contains applied, failed, and possibly indeterminate
  UUIDs. This is a partial failure: do not retry the whole batch or any
  successful/indeterminate member.
  Read every affected UUID. Only `retrySafe:true` members may be reconsidered,
  and only after reconciliation plus a fresh user decision; never retry them
  automatically.
- Do not infer success from exit status alone. Parse the single JSON value on
  stdout and require `ok: true`; for batch responses also parse item results,
  verification, warnings, and each member's retry safety.

## Verification

For discovery and reads, verify `ok: true`, the expected selector/UUID, and the
returned capability or brightness fields. In the Extra Brightness headroom
snapshot, `appliedFactor` with `factorVerification: app_state` records the last
factor Crisp committed; it is not independent EDR or hardware read-back, and
`null` means no committed factor is known. Report `requestID` when diagnosing
a failure.

For a successful brightness write, inspect `verification`, `readbackPercent`,
`logicalPercent`, `hardwareReadbackPercent`, and `warnings` as well as
`ok: true`. `app_state_verified` and `settling` are app/overlay truth, not
hardware-authoritative proof of EDR output. If the outcome is indeterminate, the only
safe verification is a separate read followed by a fresh user decision; an
automatic retry is forbidden.
