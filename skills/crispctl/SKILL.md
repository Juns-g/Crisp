---
name: crispctl
description: Use when controlling displays through Crisp's JSON CLI.
version: 0.1.0
author: Juns (Juns-g), Hermes Agent
license: MIT
platforms: [macos]
metadata:
  hermes:
    tags:
      - crisp
      - display-control
      - automation
    related_skills: []
---

# crispctl

Use Crisp's minimal JSON CLI to discover displays, read brightness, and request a brightness change. Run every command with the `terminal` tool.

## When to Use

- List displays that the running Crisp app currently exposes.
- Read one display's brightness.
- Request one display's brightness as a percentage.
- Do not invent other commands, flags, selectors, or lifecycle behavior.

## Prerequisites

- Run on macOS with a source build that provides the `crispctl` target. Do not assume the public Crisp release includes the CLI.
- Crisp must already be running. The CLI does not launch it.
- Obtain the target display's runtime numeric `UInt32` ID from a fresh list.

## How to Run

1. Use `terminal` to list the current displays:

   ```sh
   crispctl displays list
   ```

   Parse the JSON output and select the intended display's numeric ID.

2. To read brightness, use that ID:

   ```sh
   crispctl brightness get <display-id>
   ```

3. Before a write, validate that `<percent>` is finite and within `0...100`, inclusive. Run `displays list` again immediately before the write and rediscover the intended display's current ID.

4. Submit the write once:

   ```sh
   crispctl brightness set <display-id> <percent>
   ```

   JSON is the default output for all three commands. Do not add `--json`.
   Never retry a write automatically, including after an error or ambiguous result.

5. A successful set response is exactly:

   ```json
   {"ok":true,"status":"accepted","execution":"queued","verification":"unverified"}
   ```

6. After a successful or uncertain set attempt, issue a separate `brightness get` for app/model read-back. Report it separately from the set response. After an uncertain attempt, require a fresh human decision before any later write.

## Pitfalls

- A display ID is a runtime numeric value, not a persistent identifier, name, or display-role selector. It may change after topology or app changes.
- `accepted` and `queued` do not mean synchronous hardware application, read-back, or independent verification.
- A separate get reads Crisp's app/model state; it is not independent hardware proof.
- A nonzero exit means the command failed. After a set attempt, however, a transport or read timeout does not prove that a queued write did not apply. Never retry automatically; perform a separate get and require a fresh human decision before any later write. Server-declared failures use JSON on stdout and exit `3`; usage failures exit `2`, and transport or untrusted socket failures exit `1`.

## Verification

Keep these evidence layers distinct:

1. **Set contract:** the exact accepted/queued/unverified JSON response.
2. **App/model read-back:** the result of a separate `brightness get`.
3. **Human observation:** visual or Crisp GUI evidence can confirm an observed physical effect, but it is not independent DDC hardware read-back or a protocol acknowledgement.

Do not claim that human evidence alone verifies the DDC transaction. Never convert a failed or uncertain result into an automatic retry.
