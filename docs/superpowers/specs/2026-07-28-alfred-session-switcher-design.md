# claude-bar — Alfred session switcher

**Date:** 2026-07-28
**Status:** Approved design

## Problem

The menu bar indicator answers "does a session need me, and which one?" and its dropdown
focuses the right Ghostty split on click. But reaching it costs a trip to the mouse: the menu
bar has to be found, clicked, and the row aimed at. Switching between three or four sessions
all day is a keyboard motion, not a pointing one.

The goal is to reach the same list from a hotkey and land in the right split without touching
the mouse.

## Host: an Alfred Script Filter

Alfred is already installed and licensed on this machine. A Script Filter gives the whole
feature — hotkey, fuzzy filtering, list UI, keyboard selection — for the price of one script
printing JSON. A standalone app would rebuild all of that to reach the same place.

Alfred points at the file in this repository rather than at a copy inside a workflow bundle, so
a `git pull` is the whole update path.

## What it adds

One file: `plugins/claude_alfred.sh`. It prints an Alfred Script Filter JSON feed on stdout,
one item per live interactive session. Neither `claude_sessions.sh` nor `claude_focus.sh`
changes.

## Reuse

The script sources `claude_sessions.sh`. The `BASH_SOURCE`/`$0` guard at the foot of the plugin
keeps `main` from running, which is what makes its functions reachable — the same property
`test_states.sh` relies on. That yields `read_sessions`, `derive_state`, `state_label`,
`state_icon`, `format_age` and `SESSIONS_DIR`, and also `FOCUS_SCRIPT`: the plugin resolves it
from `BASH_SOURCE[0]`, which under `source` is still `claude_sessions.sh`, so the sibling path
comes out right.

`claude_alfred.sh` finds its own sibling the same way the plugin does — `/usr/bin/readlink -f`
by absolute path, `%/*` in place of `dirname` — for the same reason: it runs under a GUI app's
PATH, where neither tool is guaranteed.

## The feed

One item per session:

```
◐ claude-bar                     title    — what Alfred filters on
  working · 2m · pid 41207       subtitle — state, age, and the disambiguator
                                 arg      — the pid, handed to claude_focus.sh
```

Order: rank `0..3` by state (needs input → just finished → working → idle), then by age,
descending within a rank. Implemented as a rank prefix, one `sort`, prefix stripped — so the
session that wants attention is already selected when the list opens, with nothing typed.

The JSON is assembled by `jq` from a TSV, not by string concatenation in bash: a project
directory containing a quote or a backslash must not produce a malformed feed. This mirrors why
the plugin rewrites `|` to `∣` for SwiftBar's line protocol — the escaping belongs to the
format, not to the caller.

No live sessions renders a single `No Claude Code sessions` item with `valid=false`, the
counterpart of the dropdown's own empty row.

## PATH

Alfred runs scripts with a GUI app's PATH, the same trap SwiftBar sets: `jq` is not in it.
Unlike the plugin, this script is free to pin `PATH` — the plugin cannot, because pinning would
make its own "jq not found" warning unreachable, and `claude_focus.sh` already pins for the same
reason this one may. So: `PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`.

If `jq` is still absent, the feed is a single visible `jq not found in PATH` item. An empty list
would read as "no sessions", which is a lie.

## Wiring (README)

`Hotkey` → `Script Filter` → `Run Script`.

- Script Filter: Language `/bin/bash`, script `"<repo>/plugins/claude_alfred.sh"`, "with input
  as {query}" left off — filtering is Alfred's job, over the item titles.
- Run Script: `"<repo>/plugins/claude_focus.sh" "$1"`.

Automation permission towards Ghostty has to be granted to Alfred, as it was to SwiftBar.

## Testing

One case in `test_states.sh`: run `claude_alfred.sh` against `tests/fixtures` and assert the
output parses as JSON and that the titles come out in urgency order. That covers the only new
logic — ranking and feed assembly. State derivation, the dead-process filter and age formatting
are already pinned by the existing cases, through the same functions.

Ages are asserted by pattern, never by literal, for the reason the existing suite does: the
fixture stamp and the script's own `date` call race the wall clock.

## Out of scope

- `⌘↵` to open the project directory. Would mean widening `read_sessions` to carry the full
  `cwd`, which today it truncates to the last segment.
- Managing sessions from the list (kill, copy session id, resume a dormant one).
- A committed `.alfredworkflow` bundle. A hand-written ~150-line `info.plist` to wire two boxes
  is more to maintain than the five README lines it replaces.
- Disambiguating two sessions in the same project by anything richer than the pid in the
  subtitle. Add it if two identical rows ever actually cause a mis-pick.
