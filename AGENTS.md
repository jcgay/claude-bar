# AGENTS.md

claude-bar: a SwiftBar plugin (Bash + `jq`) showing which interactive Claude Code sessions need
attention in the macOS menu bar.

## Commands

```bash
./test_states.sh                                                 # full suite, runs in milliseconds
./plugins/claude_sessions.sh                                     # render live, exactly as SwiftBar sees it
CLAUDE_SESSIONS_DIR=tests/fixtures ./plugins/claude_sessions.sh  # render against fixtures
```

No single-test runner. To exercise one function, `source ./plugins/claude_sessions.sh` and call it
— that is what `test_states.sh` does, and what the `BASH_SOURCE`/`$0` guard at the foot of the
plugin is for. Logic lives in small pure functions taking arguments and printing to stdout;
anything folded into `render` stops being reachable that way. The `CLAUDE_SESSIONS_DIR` override on
`SESSIONS_DIR` is what lets the tests point at fixtures.

## Before editing plugins/claude_sessions.sh

Read it end to end first. Nearly every surprising line carries a comment saying why, and most are
pinned by a test: one `jq` per file rather than one batched call, `kill -0` for liveness, `|`
rewritten to `∣`, the `statusUpdatedAt` regex guard, the visible warning when `jq` is absent from
SwiftBar's PATH, no `set -e`, single colour values rather than SwiftBar `light,dark` pairs. What
looks like an accident in there is usually one of those. Recolouring means re-checking WCAG
contrast against both a white and a dark menu bar — the figures live above `state_color`.

`plugins/claude_focus.sh` is a diagnostic, not part of the indicator: click-to-focus was tried and
dropped, for reasons the README records.

## Tests

Fixtures carry `PID_PLACEHOLDER` and `TIMESTAMP_PLACEHOLDER`, which `test_states.sh` substitutes
with its own pid and a live `now`, so the dead-process filter and age formatting are exercised for
real. Assert rendered ages by pattern — a literal races the wall clock between the fixture stamp
and the plugin's own `date` call (~13% flake measured).

## Comments

The ones here explain why a line exists rather than what it does. Match that register.
