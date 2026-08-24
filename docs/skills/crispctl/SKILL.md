---
name: crispctl
description: Query and control displays through Crisp's supported crispctl JSON interface. Use for Crisp display discovery, capability checks, and brightness requests; do not use for unrelated display tools.
---

# Crisp display control

Use `crispctl --json` as the only machine interface. Do not call macOS display
APIs or third-party display CLIs directly.

## Workflow

1. Run `crispctl displays list --json` and select by UUID when possible.
2. Before a write, run `crispctl displays capabilities <selector> --json`.
3. Brightness is Tier 1: execute a user-requested in-range write without an
   extra confirmation, then require `ok: true` and inspect `verification`,
   `readbackPercent`, and `warnings`.
4. Stop on ambiguity and present candidate UUIDs. Never guess a display.
5. Use `--no-start` when the caller forbids launching Crisp. Otherwise the CLI's
   bounded bundle-ID launch/readiness policy applies.

Treat `unsupported_capability`, `permission_required`, unavailable read-back,
and remediation text as real constraints. Never turn them into success. Report
the response `requestID` when troubleshooting. If a write returns
`write_outcome_indeterminate`, do not retry automatically: first read the
selected display's current brightness, report that the timed-out write may
still complete, and require a fresh user decision before another write.

Only discovery and brightness are currently supported. Do not emulate modes,
HDR, arrangement, presets, disconnects, virtual displays, or other Tier 2/3
operations. There is no flag that bypasses future confirmation safeguards.

```sh
crispctl displays list --json
crispctl displays capabilities builtin --json
crispctl brightness get builtin --json
crispctl brightness set builtin 60 --json
crispctl status --json --no-start
```
