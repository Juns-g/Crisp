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
perform an explicitly requested brightness read or write through Crisp's
versioned JSON interface. Do not substitute macOS display APIs or another
display CLI: Crisp must remain the owner of display state.

Only discovery and Tier 1 brightness operations are currently supported. Do
not emulate modes, HDR, arrangement, presets, disconnects, virtual displays,
or any other Tier 2/3 operation.

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
   requested brightness is supported and within the returned range.
3. Read with `"${CRISPCTL}" brightness get <uuid> --json`.
4. For an explicitly requested, supported in-range Tier 1 write, run
   `"${CRISPCTL}" brightness set <uuid> <percent> --json`. No extra
   confirmation is needed for that already-requested write.
5. If the user forbids launching Crisp, append `--no-start` to the command.
   Otherwise `crispctl` may use its bounded bundle-ID launch/readiness policy.

## Pitfalls

- Stop on an `ambiguous_selector` response and present candidate UUIDs. Never
  guess a display.
- Treat `unsupported_capability`, `permission_required`, unavailable read-back,
  warnings, and remediation text as real constraints rather than success.
- A `write_outcome_indeterminate` response means an in-flight hardware callback
  may still apply; do not retry the write. Read back the selected display,
  explain that the timed-out write may still complete, and require a fresh user
  decision before any later write.
- Do not infer success from exit status alone. Parse the single JSON value on
  stdout and require `ok: true`.

## Verification

For discovery and reads, verify `ok: true`, the expected selector/UUID, and the
returned capability or brightness fields. Report `requestID` when diagnosing a
failure.

For a successful brightness write, inspect `verification`, `readbackPercent`,
and `warnings` as well as `ok: true`. If the outcome is indeterminate, the only
safe verification is a separate read followed by a fresh user decision; an
automatic retry is forbidden.
