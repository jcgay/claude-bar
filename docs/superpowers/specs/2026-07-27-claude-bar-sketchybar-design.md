# claude-bar — SketchyBar indicator for interactive Claude Code sessions

**Date:** 2026-07-27
**Status:** Approved design

## Problem

Three to four Claude Code sessions run in parallel in separate Ghostty windows. macOS
notifications alone do not make it clear *which* session finished, which one is blocked on a
permission prompt, and which one is still working. The windows are separate, so tab titles are
not visible, and `claude agents` (agent view) only presents background sessions as a browsable
list — it does not surface sessions attached to a terminal.

The goal is a macOS menu bar indicator, always visible regardless of which app has focus, that
answers "does a session need me, and which one?" at a glance, and brings the right Ghostty
window forward on click.

## Data source

Claude Code writes one small JSON file per live session to `~/.claude/sessions/<pid>.json`:

```json
{
  "pid": 2343,
  "sessionId": "128508e7-1b19-4453-9f11-fc21022bfeac",
  "cwd": "/Volumes/sourcecode/claude-bar",
  "kind": "interactive",
  "name": "claude-bar-3f",
  "status": "busy",
  "statusUpdatedAt": 1785183612143
}
```

These files back `claude agents --json`. We read them directly rather than shelling out to the
CLI, which costs roughly 200 ms per invocation — unacceptable at a 2-second refresh rate.

Two filters apply:

- `kind == "interactive"` — background sessions are already covered by agent view.
- `kill -0 <pid>` succeeds — session files can outlive a crashed process.

### Verified status values

Sampling a live session's own file at 2 Hz while it was blocked on a user question produced:

```
39 "status":"busy"
81 "status":"waiting"
```

So interactive sessions report three statuses: `busy`, `waiting` (blocked on a permission prompt
or a question), and `idle` (sitting at the prompt). `waiting` natively covers "this session needs
you right now", which removes the need for `Notification` hooks to detect that case.

`statusUpdatedAt` gives the timestamp of the last transition, which lets us distinguish "just
finished" from "forgotten hours ago" without persisting any state of our own.

## Derived display states

| Condition | State | Color (user's gruvbox palette) |
| --- | --- | --- |
| `status == "waiting"` | needs input now | `#fb4934` red |
| `status == "idle"` and age < 5 min | just finished | `#fabd2f` yellow |
| `status == "busy"` | working | `#83a598` blue |
| `status == "idle"` and age >= 5 min | dormant — counted, no badge | `#7c6f64` grey |

Urgency ordering, used to tint the counter, is: needs input > just finished > working > dormant.
A dormant session gets no badge of its own, but grey is still the counter's color when every live
session is dormant.

"Just finished" uses a sliding 5-minute window rather than a seen/unseen marker. The session file
cannot tell whether the user has read the result, and a persistent state file would have to be
reconciled on every tick. The accepted trade-off: after reading a result, its badge lingers for up
to the remainder of the window.

This mapping is the only non-trivial logic in the project and is the thing the test covers.

## Rendering — hybrid layout

A permanent item named `claude` shows `✦ N` where N is the number of live interactive sessions,
tinted with the most urgent state currently present. Alongside it, one item per session named
`claude.<pid>` appears **only** for sessions in *needs input* or *just finished*, labelled with the
project name. Sessions that are quietly working stay folded into the counter.

```
── nothing to report ──        ── arthur is blocked ──
┌───────────┐                  ┌──────────────────────┐
│  ✦ 3      │                  │  ✦ 3    ● arthur     │
└───────────┘                  └──────────────────────┘
```

The bar stays calm at rest and expands only when something needs attention, which keeps menu bar
width stable in the common case while still naming the project without requiring a hover.

Refresh is `update_freq=2`. On each tick the script reads the session files, queries SketchyBar for
existing `claude.*` items, then adds items for newly-attention-worthy sessions, removes items for
sessions that are gone or no longer attention-worthy, and updates the rest.

No `fswatch` daemon and no event-driven trigger: the "just finished" state expires with wall-clock
time, so periodic evaluation is required regardless. Adding a file watcher would not remove the
poll, only duplicate it.

## Click to focus

Ghostty runs as a single process for all windows, so walking the process tree from a session's pid
reaches the application, not the window. Window resolution has to go through the macOS
Accessibility API, matching on window title. That requires each window to carry a title we control.

**Titling.** Claude Code hooks accept a `terminalSequence` field whose allowlist explicitly permits
OSC 0/1/2 (window and tab title). A `SessionStart` hook emits OSC 2 to stamp the window with the
session name, for example `claude-bar-3f`. Because fish does not redraw its prompt while `claude`
is in the foreground, the title persists for the lifetime of the session.

**Raising.** The item's `click_script` runs an `osascript` that performs `AXRaise` on the window of
process `ghostty` whose title contains that session name.

One-time setup: grant Accessibility access to SketchyBar in System Settings → Privacy & Security.

## Risks

- **`terminalSequence` support on `SessionStart` is unconfirmed.** The field and its OSC allowlist
  were found in the Claude Code binary, but not verified on this specific event. This is the first
  implementation step. Fallback if unsupported: emit the OSC from `fish_title`, detecting a running
  `claude` in the foreground.
- **Splits.** The user's Ghostty config binds `ctrl+d` to `new_split:right`. Two sessions sharing a
  window means the Accessibility window title reflects only the focused split, so a click raises the
  correct window but not the correct split. There is no workaround through the Accessibility API.
- **Accessibility permission resets.** Homebrew upgrades of SketchyBar replace the binary, which
  revokes the grant. Documented in the README as a known re-setup step.

## Components

Each unit has one job and can be exercised on its own.

| File | Responsibility |
| --- | --- |
| `plugins/claude_sessions.sh` | Read session files, derive states, reconcile SketchyBar items. ~50 lines of shell + `jq`. |
| `plugins/claude_focus.sh` | Given a session name, raise the matching Ghostty window. ~10 lines of `osascript`. |
| `sketchybarrc` | Item declaration, to be merged into the user's own config. |
| `hooks/settings-snippet.json` | The `SessionStart` hook to paste into `~/.claude/settings.json`. |
| `test_states.sh` | Feeds fixture session JSON to the state derivation and asserts the resulting states. |
| `README.md` | Install and setup, including the Accessibility grant. |

Shell plus `jq` rather than a Go binary: the work is reading four 300-byte JSON files and emitting
`sketchybar` commands, which is exactly the shape of a SketchyBar plugin. A compiled binary would
add a build step without removing any code.

State derivation lives in a function that takes `(status, statusUpdatedAt, now)` and returns a
state name, so `test_states.sh` can drive it with fixed timestamps and no live sessions.

## Prerequisites

- `brew install FelixKratz/formulae/sketchybar` — not currently installed on this machine.
- `jq` — already present at `/usr/bin/jq`.
- Accessibility permission for SketchyBar.

---

## Revision: SwiftBar replaces SketchyBar

Everything above was written for SketchyBar and is superseded on two points. The
data source, the derived states, the five-minute window and the colors are
unchanged.

**Why.** SketchyBar draws its own bar rather than adding an item to the native
macOS menu bar, which means adopting it as a whole-menu-bar replacement. That was
not understood when it was chosen over SwiftBar on looks, and it is far more
commitment than this indicator warrants. SwiftBar puts a normal item in the
existing menu bar.

**What changes.**

A SwiftBar plugin is an executable named `{name}.{interval}.{ext}` — here
`claude-bar.2s.sh` — whose stdout is the output. Lines before a `---` line are the
menu bar title; lines after it are the dropdown. Per-line parameters follow a `|`,
for example `| color=#fb4934`.

This removes the entire item-reconciliation layer: no `--add`/`--set`/`--remove`,
no querying the bar for existing items, no `--dry-run` mode taking the current
item list on stdin. The script prints its state and exits. Testing gets simpler
too — stdout is the whole result, so assertions read it directly.

Colors move from SketchyBar's `0xAARRGGBB` to CSS hex `#RRGGBB`.

**The dropdown changes the layout trade-off.** The hybrid title existed because
menu bar width was scarce, so quietly-working sessions had to stay folded into the
counter. With a dropdown available for free, the title keeps that hybrid form —
counter plus a badge for whatever needs attention — and the dropdown lists *every*
live session with its state and age, including the working and dormant ones the
title omits.

All four states therefore need an icon now, not just the two that earn a badge:
`●` needs input, `◐` working, `○` just finished, `·` dormant.

**Click-to-focus stays cancelled.** SwiftBar would make the click plumbing trivial
via `| bash=... terminal=false`, but the blocker was never the plumbing: Claude
Code overwrites Ghostty window titles whenever it starts working, so no stable
marker survives for the Accessibility API to match on. `plugins/claude_focus.sh`
remains a diagnostic.

**The Components table above is also superseded.** `sketchybarrc` was deleted
along with the rest of the SketchyBar item-reconciliation layer, and
`hooks/settings-snippet.json` was never written — SwiftBar needs no
`SessionStart` hook. Neither exists in this repository.

---

## Revision: click-to-focus, through Ghostty's AppleScript dictionary

**Date:** 2026-07-28

Click-to-focus was cancelled twice above, on a blocker that no longer holds. It
ships. Everything else in this document stands.

**Why it was blocked.** Window resolution had to go through the Accessibility
API, which exposes windows only, identified by title — so it needed a stable,
unique marker in each window title, and Claude Code overwrites that title
whenever it starts working. The Splits risk noted under *Click to focus* made it
worse still: the user runs one window per project holding two splits, the Claude
session and a plain shell that is usually `cd`-ed into a subdirectory. The
Accessibility window title reflects only the focused split, so even a surviving
marker on the Claude split would not have been visible when the shell had focus.
Both were verified again before being discarded: writing OSC 2 to an unfocused
split leaves the window title showing the *other* split's.

**What changed.** Ghostty 1.3 ships an AppleScript dictionary
(`Ghostty.app/Contents/Resources/Ghostty.sdef`, `NSAppleScriptEnabled`). Its
`terminal` class is an individual *surface* — one split — carrying `id`, `name`
and `working directory`, and its `focus` command raises the surface's window and
moves the cursor into that surface. A split that is neither in the frontmost
window nor focused within its own window comes forward correctly; verified.

The Accessibility API is no longer used, and neither is the process tree.

**Tying a pid to a surface.** The dictionary offers no pid and no tty, and the
session file knows no surface id, so the link is made rather than looked up:

1. `ps -o tty= -p <pid>` gives the session's tty.
2. `printf '\033]2;⟦claude-bar:<pid>⟧\007' > /dev/<tty>` titles that surface.
   Unlike a window title, a *surface* title updates regardless of focus.
3. `focus (first terminal whose name is <marker>)`.
4. The surface's previous title, read before step 2, is written back.

Claude Code still overwrites titles — a busy session animates a spinner in
its own — but the marker now only has to outlive step 3. Measured: it survives
well past 500 ms on a busy session.

Step 4 was a deliberate choice over two cheaper alternatives. Matching on
`working directory` instead of a marker needs no title write at all, but picks
the wrong split whenever both sit at the project root. Leaving a human-readable
marker in place skips the restore, at the cost of the conversation summary
Claude Code puts there. Restoring keeps the click free of visible traces.

**Rendering.** Every dropdown row gains
`bash="<dir>/claude_focus.sh" param1=<pid> terminal=false`. `terminal=false`
matters: launching Terminal to run the script would steal the focus being handed
to Ghostty.

**PATH.** SwiftBar launches plugins with a GUI app's PATH — the reason the `jq`
warning exists. The focus path is the worst place for that exposure, since
`readlink` and `dirname` are absent from `/bin` and a truncated path leaves every
click doing nothing with no visible symptom. The plugin therefore calls
`/usr/bin/readlink` by absolute path and uses `%/*` rather than `dirname`; it
cannot simply pin `PATH`, which would make its own `jq` warning unreachable.
`claude_focus.sh` has no such guard and pins `PATH=/usr/bin:/bin`.

**Limits.** Ghostty 1.3+ only, and Ghostty only: the marker is written before we
know whether a Ghostty surface will claim it, so aiming this at a session in
another terminal leaves that terminal's title overwritten. Automation permission
for SwiftBar towards Ghostty is requested by macOS on the first click.

**Testing.** `test_states.sh` covers the rendered parameters — that every row is
clickable, that the pid is passed, that the path survives both a symlinked
install and a PATH without `readlink`. The AppleScript half is not unit-testable
and stays out of the suite, as `claude_focus.sh` always has.
