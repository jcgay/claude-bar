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
rewritten to `∣`, the `statusUpdatedAt` regex guard, the `nameSource` blacklist rather than a
whitelist, the visible warning when `jq` is absent from SwiftBar's PATH, no `set -e`, single colour
values rather than SwiftBar `light,dark` pairs, `/usr/bin/readlink` by absolute path with `%/*` in
place of `dirname`. What looks like an accident in there is usually one of those. Recolouring means
re-checking WCAG contrast against both a white and a dark menu bar — the figures live above
`state_color`.

SwiftBar's PATH is the recurring trap: it is a GUI app's, not a login shell's, and `/bin` alone has
neither `readlink` nor `dirname` nor `jq`. The plugin cannot simply pin `PATH`, because that would
render its own `jq` warning unreachable — hence the absolute path. `claude_focus.sh` has no such
guard and does pin it.

## plugins/claude_focus.sh

Click-to-focus, reached from every dropdown row. Two lines carry more weight than they look:
`character id 9` is bound outside the `tell` block because Ghostty's dictionary declares a class
named `tab` that shadows AppleScript's constant inside it, and `${pid}` is braced because the
closing `⟧` of the marker is multibyte and bash otherwise reads its leading bytes as part of the
name. Neither is covered by `test_states.sh`, which stops at the rendered `bash=` parameters —
exercise the script itself against a live pid.

## plugins/claude_alfred.sh

The same list as an Alfred Script Filter feed, for switching by hotkey. It holds no state
logic of its own: it sources `claude_sessions.sh` — which is only possible because of that
same `BASH_SOURCE`/`$0` guard — and adds a rank, a `sort`, and a `jq` that builds the JSON.
Two things it deliberately does differently from the plugin: it pins `PATH` (it has no jq
warning to keep reachable, and Alfred's PATH is a GUI app's too), and it leaves `|` alone,
since that is SwiftBar's parameter separator and means nothing to JSON. Items carry no `uid`,
or Alfred would re-sort them by past usage and undo the ranking.

## Tests

Fixtures carry `PID_PLACEHOLDER` and `TIMESTAMP_PLACEHOLDER`, which `test_states.sh` substitutes
with its own pid and a live `now`, so the dead-process filter and age formatting are exercised for
real. Assert rendered ages by pattern — a literal races the wall clock between the fixture stamp
and the plugin's own `date` call (~13% flake measured).

## Comments

The ones here explain why a line exists rather than what it does. Match that register.
