# claude-bar

A SketchyBar indicator for Claude Code sessions running in several terminal
windows at once. It answers, without switching apps, "does a session need me,
and which one?"

```
── nothing to report ──        ── arthur is blocked ──
┌───────────┐                  ┌──────────────────────┐
│  ✦ 3      │                  │  ✦ 3    ● arthur     │
└───────────┘                  └──────────────────────┘
```

The counter shows how many interactive sessions are alive and is tinted by the
most urgent one. Sessions that want attention expand into a named badge beside
it; sessions quietly working stay folded into the counter.

| Badge | Meaning | Color |
| --- | --- | --- |
| `●` | Blocked on a permission prompt or a question | red |
| `○` | Finished within the last five minutes | yellow |
| — | Working, or idle for over five minutes | counter only |

"Finished" uses a sliding five-minute window. Claude Code's session files record
when a session last changed state but not whether you have read the result, so a
badge you have already dealt with lingers until the window closes.

## Install

From your checkout of this repository:

```bash
brew install FelixKratz/formulae/sketchybar

mkdir -p ~/.config/sketchybar
ln -sfn "$PWD" ~/.config/sketchybar/claude-bar
cat sketchybarrc.example >> ~/.config/sketchybar/sketchybarrc

brew services start sketchybar
```

`jq` is required and ships with macOS at `/usr/bin/jq`.

Symlinking rather than copying keeps the checkout as the source of truth, so
`git pull` is all an update takes.

## How it works

Claude Code writes one JSON file per live session to `~/.claude/sessions/<pid>.json`,
carrying `status` (`busy`, `waiting`, `idle`), `statusUpdatedAt`, `cwd` and
`sessionId`. The plugin reads those files directly every two seconds. Calling
`claude agents --json` would return the same data but spawns the CLI at roughly
200 ms per invocation, which is far too slow for this refresh rate.

Session files outlive a crashed `claude`, so liveness comes from `kill -0` on the
pid rather than from the file existing.

## Clicking a badge does nothing

This was tried and dropped. Ghostty runs one process for every window, so a
session pid cannot be resolved to a window through the process tree — the only
route is the macOS Accessibility API, which identifies windows solely by title.
That needs a stable, unique marker in each title, and Claude Code writes the
window title itself whenever it starts working, overwriting anything we put
there. The badge tells you which project wants you; finding the window is
manual.

`plugins/claude_focus.sh` survives as a diagnostic:

```bash
./plugins/claude_focus.sh --list       # print every Ghostty window title
./plugins/claude_focus.sh some-marker  # raise the first window whose title matches
```

Both need Accessibility permission for the process running them — add your
terminal in System Settings → Privacy & Security → Accessibility. Homebrew
upgrades replace binaries and revoke such grants, so this may need redoing.

## Development

```bash
./test_states.sh
```

Covers state derivation, urgency ordering, colors, and rendering against
fixtures in `tests/fixtures/`. The fixtures carry a pid placeholder that the test
rewrites to its own pid, so the dead-process filter is exercised for real.

To see what the plugin would tell SketchyBar without touching the bar:

```bash
./plugins/claude_sessions.sh --dry-run </dev/null
```

It reads the current item list on stdin, so feeding it `/dev/null` means "no
badges on the bar yet".
