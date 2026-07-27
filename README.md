# claude-bar

A SwiftBar plugin that shows, in the macOS menu bar, which of your running Claude
Code sessions need attention. Built for keeping three or four of them open in
separate terminal windows, where OS notifications don't say which one fired.

```
menu bar:  ✦ 3  ● arthur

── dropdown ──────────────────
 ● arthur      needs input 8s
 ◐ deltatom    working 1m
 ○ exploratom  just finished 2m
 · claude-bar  idle 3h
```

The title shows how many interactive sessions are alive, tinted by the most
urgent one, and names any that want you. The dropdown lists them all.

| Icon | State | Color |
| --- | --- | --- |
| `●` | Blocked on a permission prompt or a question | red |
| `○` | Finished within the last five minutes | yellow |
| `◐` | Working | blue |
| `·` | Idle for over five minutes | grey |

Only the first two earn a place in the title; the other two live in the dropdown
so the menu bar stays quiet.

"Finished" uses a sliding five-minute window. Claude Code's session files record
when a session last changed state but not whether you have read the result, so a
row you have already dealt with keeps its yellow for the rest of the window.

## Install

```bash
brew install --cask swiftbar
mkdir -p ~/.config/swiftbar
```

Launch SwiftBar once and point it at `~/.config/swiftbar` when it asks for a
plugin folder. Then, from your checkout of this repository:

```bash
ln -sfn "$PWD/plugins/claude_sessions.sh" ~/.config/swiftbar/claude-bar.2s.sh
```

The `2s` in that filename is the refresh interval — SwiftBar reads it from the
name, so there is no configuration file. Symlinking rather than copying keeps the
checkout as the source of truth, so `git pull` is all an update takes.

`jq` is required and ships with macOS at `/usr/bin/jq`.

## How it works

Claude Code writes one JSON file per live session to `~/.claude/sessions/<pid>.json`,
carrying `status` (`busy`, `waiting`, `idle`), `statusUpdatedAt`, `cwd` and
`sessionId`. The plugin reads those files directly. Calling `claude agents --json`
would return the same data but spawns the CLI at roughly 200 ms per invocation,
far too slow at this refresh rate.

Session files outlive a crashed `claude`, so liveness comes from `kill -0` on the
pid rather than from the file existing.

A SwiftBar plugin's stdout is its output: lines before `---` are the menu bar
title, lines after it are the dropdown, and per-line parameters follow a `|`. So
the whole plugin is one script that prints and exits — you can see exactly what
the menu bar will show by running it:

```bash
./plugins/claude_sessions.sh
```

## Clicking does nothing

This was tried and dropped. Ghostty is a single process for all its windows, so a
session pid cannot be resolved to a window through the process tree — the only
route is the macOS Accessibility API, which identifies windows solely by title.
That needs a stable, unique marker in each title, and Claude Code writes the
window title itself whenever it starts working, overwriting anything we put
there. The dropdown tells you which project wants you; finding the window is
manual.

`plugins/claude_focus.sh` survives as a diagnostic:

```bash
./plugins/claude_focus.sh --list       # print every Ghostty window title
./plugins/claude_focus.sh some-marker  # raise the first window whose title matches
```

Both need Accessibility permission for the process running them — add your
terminal in System Settings → Privacy & Security → Accessibility.

## Development

```bash
./test_states.sh
```

Covers state derivation, urgency ordering, colors, icons, age formatting, and the
rendered output against fixtures in `tests/fixtures/`. The fixtures carry a pid
placeholder that the test rewrites to its own pid, so the dead-process filter and
the malformed-timestamp guard are exercised for real.
