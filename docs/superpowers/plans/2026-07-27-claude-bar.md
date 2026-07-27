# claude-bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar indicator that shows which interactive Claude Code sessions need attention across several Ghostty windows, and raises the right window on click.

**Architecture:** A SketchyBar plugin polls `~/.claude/sessions/*.json` every two seconds, derives a display state per session from `status` and `statusUpdatedAt`, and reconciles SketchyBar items — a permanent counter plus one badge per session that wants attention. A `SessionStart` hook stamps each Ghostty window title with a marker derived from the session id, which the click handler uses to raise that window through the Accessibility API.

**Tech Stack:** Bash, `jq` (already at `/usr/bin/jq`), SketchyBar (to be installed), `osascript` / macOS Accessibility API.

## Global Constraints

- All code, comments, and commit messages in English. Commit subjects are prefixed with a gitmoji, and bodies explain the context behind the change, not just the diff.
- Bash with `#!/usr/bin/env bash` and `set -uo pipefail`. Not `set -e`: the reconciliation loop relies on non-zero exits from `kill -0` and `grep -q` as ordinary control flow.
- Colors are SketchyBar `0xAARRGGBB` literals taken from the user's gruvbox Ghostty palette: needs input `0xfffb4934`, just finished `0xfffabd2f`, working `0xff83a598`, dormant `0xff7c6f64`.
- State names used throughout: `needs_input`, `just_finished`, `working`, `dormant`.
- The just-finished window is 300000 ms (5 minutes).
- `SESSIONS_DIR` defaults to `$HOME/.claude/sessions` and is overridable via `CLAUDE_SESSIONS_DIR` so tests can point at fixtures.
- Timestamps are epoch milliseconds. BSD `date` on macOS has no `%3N`, so compute `now` as `$(( $(date +%s) * 1000 ))`.

## File Structure

| File | Responsibility |
| --- | --- |
| `plugins/claude_sessions.sh` | Everything the SketchyBar item runs: read session files, derive states, emit and apply SketchyBar arguments. Sourceable so tests can call its functions. |
| `plugins/claude_focus.sh` | Raise the Ghostty window whose title contains a given marker. Also lists window titles for diagnostics. |
| `hooks/claude_bar_title.sh` | `SessionStart` hook that stamps the window title with the session marker. |
| `sketchybarrc.example` | The item declaration to merge into the user's own SketchyBar config. |
| `test_states.sh` | Sources `claude_sessions.sh` and asserts state derivation, urgency ordering, and dry-run rendering against fixtures. |
| `tests/fixtures/` | Session JSON fixtures used by `test_states.sh`. |
| `README.md` | Install, wiring, and the Accessibility grant. |

---

### Task 1: State derivation

The pure logic: a session's `status` plus the age of `statusUpdatedAt` maps to one of four display states, states map to colors and icons, and a set of states collapses to the single most urgent one used to tint the counter. No I/O, no SketchyBar, no live sessions — this is the part worth testing and the only part with real branching.

**Files:**
- Create: `plugins/claude_sessions.sh`
- Create: `test_states.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `derive_state <status> <status_updated_at_ms> <now_ms>` → prints one of `needs_input`, `just_finished`, `working`, `dormant`.
  - `state_color <state>` → prints a `0xAARRGGBB` literal.
  - `state_icon <state>` → prints `●` for `needs_input`, `○` for `just_finished`, empty otherwise.
  - `most_urgent` → reads state names on stdin, prints the most urgent by the ordering `needs_input > just_finished > working > dormant`.
  - The file guards its entrypoint with `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`, so tests can source it without running it.

- [ ] **Step 1: Write the failing test**

Create `test_states.sh`:

```bash
#!/usr/bin/env bash
# Assertions for claude-bar. Run: ./test_states.sh
set -uo pipefail

cd "$(dirname "$0")" || exit 1
source ./plugins/claude_sessions.sh

failures=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n       expected: %s\n       actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$((failures + 1))
  fi
}

NOW=1785183600000
MINUTE=60000

check "waiting means the session needs input" \
  needs_input "$(derive_state waiting "$NOW" "$NOW")"

check "busy means the session is working" \
  working "$(derive_state busy "$NOW" "$NOW")"

check "idle 30s ago just finished" \
  just_finished "$(derive_state idle "$((NOW - 30000))" "$NOW")"

check "idle just under 5min still counts as just finished" \
  just_finished "$(derive_state idle "$((NOW - 299999))" "$NOW")"

check "idle at exactly 5min is dormant" \
  dormant "$(derive_state idle "$((NOW - 5 * MINUTE))" "$NOW")"

check "idle for hours is dormant" \
  dormant "$(derive_state idle "$((NOW - 180 * MINUTE))" "$NOW")"

check "an unrecognised status is treated as dormant" \
  dormant "$(derive_state something_new "$NOW" "$NOW")"

check "needs_input wins over everything else" \
  needs_input "$(printf '%s\n' working dormant needs_input just_finished | most_urgent)"

check "just_finished wins over working" \
  just_finished "$(printf '%s\n' working just_finished dormant | most_urgent)"

check "working wins over dormant" \
  working "$(printf '%s\n' dormant working dormant | most_urgent)"

check "all dormant collapses to dormant" \
  dormant "$(printf '%s\n' dormant dormant | most_urgent)"

check "no states at all collapses to dormant" \
  dormant "$(printf '' | most_urgent)"

check "needs_input is red" 0xfffb4934 "$(state_color needs_input)"
check "just_finished is yellow" 0xfffabd2f "$(state_color just_finished)"
check "working is blue" 0xff83a598 "$(state_color working)"
check "dormant is grey" 0xff7c6f64 "$(state_color dormant)"

check "needs_input shows a filled dot" "●" "$(state_icon needs_input)"
check "just_finished shows a hollow dot" "○" "$(state_icon just_finished)"

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
```

Make it executable: `chmod +x test_states.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `./test_states.sh`

Expected: FAIL — `./plugins/claude_sessions.sh: No such file or directory`.

- [ ] **Step 3: Write the minimal implementation**

Create `plugins/claude_sessions.sh`:

```bash
#!/usr/bin/env bash
# SketchyBar plugin: surface live interactive Claude Code sessions.
#
# Claude Code maintains one small JSON file per live session under
# ~/.claude/sessions. This script turns those into menu bar items: a permanent
# counter, plus one badge per session that wants the user's attention.
#
# Not `set -e`: the reconciliation loop uses non-zero exits from kill -0 and
# grep -q as ordinary control flow.
set -uo pipefail

# A session that went idle longer ago than this is forgotten rather than
# freshly finished, and no longer earns a badge.
JUST_FINISHED_WINDOW_MS=300000

# Map a session's reported status and the age of that status to a display
# state. `waiting` is Claude Code's own signal that the session is blocked on a
# permission prompt or a question, so it needs no interpretation.
derive_state() {
  local status=$1 updated_at=$2 now=$3

  case "$status" in
    waiting) printf 'needs_input\n' ;;
    busy)    printf 'working\n' ;;
    idle)
      if (( now - updated_at < JUST_FINISHED_WINDOW_MS )); then
        printf 'just_finished\n'
      else
        printf 'dormant\n'
      fi
      ;;
    *) printf 'dormant\n' ;;
  esac
}

# Gruvbox, matching the user's Ghostty palette.
state_color() {
  case "$1" in
    needs_input)   printf '0xfffb4934\n' ;;
    just_finished) printf '0xfffabd2f\n' ;;
    working)       printf '0xff83a598\n' ;;
    *)             printf '0xff7c6f64\n' ;;
  esac
}

# Only the two attention-worthy states get a badge, so only they need an icon.
state_icon() {
  case "$1" in
    needs_input)   printf '●\n' ;;
    just_finished) printf '○\n' ;;
    *)             printf '\n' ;;
  esac
}

# Collapse the states read from stdin into the single most urgent one, which
# tints the counter.
most_urgent() {
  local best=dormant state

  while read -r state; do
    case "$state" in
      needs_input)
        best=needs_input
        ;;
      just_finished)
        if [[ "$best" != needs_input ]]; then
          best=just_finished
        fi
        ;;
      working)
        if [[ "$best" == dormant ]]; then
          best=working
        fi
        ;;
    esac
  done

  printf '%s\n' "$best"
}

main() {
  printf 'not implemented yet\n' >&2
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
```

Make it executable: `chmod +x plugins/claude_sessions.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `./test_states.sh`

Expected: PASS — 18 `ok` lines and `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude_sessions.sh test_states.sh
git commit -F - <<'EOF'
✨ Derive display states from Claude Code session status

Claude Code reports three statuses for an interactive session: `busy`,
`waiting` (blocked on a permission prompt or a question), and `idle` (sitting
at the prompt). Only `waiting` is directly actionable; `idle` needs
interpretation, because a session that finished ten seconds ago and one that
was abandoned three hours ago both report it.

`statusUpdatedAt` closes that gap. Comparing it against now separates
"just finished" from "dormant" without persisting any seen/unseen state of our
own, which would otherwise have to be reconciled on every tick.

The accepted trade-off of the sliding window: after reading a result, its badge
lingers for the remainder of the five minutes.

Colors come from the user's gruvbox Ghostty palette so the menu bar matches the
terminals it reports on.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 2: Read sessions and render the bar

Turn the session files into SketchyBar commands. The script gains a `--dry-run` mode that prints the arguments it would pass to `sketchybar` instead of executing them, which is what makes rendering testable without SketchyBar installed and without live sessions.

Dead-process filtering matters: session files can outlive a crashed `claude`. The test covers this by using the test process's own pid as a live session and pid `999999` as a dead one.

**Files:**
- Modify: `plugins/claude_sessions.sh` (add `SESSIONS_DIR`, `read_sessions`, `build_args`, real `main`)
- Modify: `test_states.sh` (append the rendering checks)
- Create: `tests/fixtures/live_waiting.json`
- Create: `tests/fixtures/live_busy.json`
- Create: `tests/fixtures/live_dormant.json`
- Create: `tests/fixtures/dead.json`
- Create: `sketchybarrc.example`

**Interfaces:**
- Consumes: `derive_state`, `state_color`, `state_icon`, `most_urgent` from Task 1.
- Produces:
  - `read_sessions` → prints one TAB-separated record per interactive session: `pid`, `sessionId`, project name (basename of `cwd`), `status`, `statusUpdatedAt`.
  - `build_args <now_ms> <existing_items>` → prints the SketchyBar arguments, one per line. `existing_items` is a newline-separated list of the `claude.*` items currently on the bar.
  - `main [--dry-run]` → with `--dry-run`, reads the existing item list from stdin and prints the arguments; otherwise queries SketchyBar and executes them.
  - Item names: the counter is `claude`, badges are `claude.<pid>`.

- [ ] **Step 1: Write the failing test**

Create the fixtures. `tests/fixtures/live_waiting.json` — note `PID_PLACEHOLDER`, which the test rewrites to its own pid so `kill -0` succeeds:

```json
{"pid":PID_PLACEHOLDER,"sessionId":"aaaaaaaa-1111-2222-3333-444444444444","cwd":"/Volumes/sourcecode/arthur","kind":"interactive","name":"arthur-02","status":"waiting","statusUpdatedAt":1785183600000}
```

`tests/fixtures/live_busy.json`:

```json
{"pid":PID_PLACEHOLDER,"sessionId":"bbbbbbbb-1111-2222-3333-444444444444","cwd":"/Volumes/sourcecode/deltatom","kind":"interactive","name":"deltatom-8e","status":"busy","statusUpdatedAt":1785183600000}
```

`tests/fixtures/live_dormant.json`:

```json
{"pid":PID_PLACEHOLDER,"sessionId":"cccccccc-1111-2222-3333-444444444444","cwd":"/Volumes/sourcecode/exploratom","kind":"interactive","name":"exploratom-af","status":"idle","statusUpdatedAt":1785180000000}
```

`tests/fixtures/dead.json` — a pid that is not running, so this session must be skipped entirely:

```json
{"pid":999999,"sessionId":"dddddddd-1111-2222-3333-444444444444","cwd":"/Volumes/sourcecode/ghost","kind":"interactive","name":"ghost-99","status":"waiting","statusUpdatedAt":1785183600000}
```

Append to `test_states.sh`, immediately before the final `if (( failures ))` block:

```bash
# --- rendering -------------------------------------------------------------
# Fixtures carry PID_PLACEHOLDER so we can substitute a pid that is genuinely
# running (our own) and prove the dead-process filter drops the rest.

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
for f in tests/fixtures/*.json; do
  sed "s/PID_PLACEHOLDER/$$/" "$f" > "$fixture_dir/$(basename "$f")"
done

render() {
  local existing=$1
  printf '%s' "$existing" \
    | CLAUDE_SESSIONS_DIR="$fixture_dir" ./plugins/claude_sessions.sh --dry-run
}

out=$(render "")

check "the dead session is skipped" \
  "" "$(grep -F 'claude.999999' <<<"$out")"

check "the waiting session gets a badge" \
  "--add
item
claude.$$
right" "$(grep -A3 -m1 -x -- '--add' <<<"$out")"

check "three live sessions are counted" \
  "label=3" "$(grep -m1 -x 'label=3' <<<"$out")"

check "the counter is tinted by the most urgent state" \
  "icon.color=0xfffb4934" "$(grep -m1 -x 'icon.color=0xfffb4934' <<<"$out")"

check "the dormant session gets no badge" \
  "" "$(grep -F 'label=exploratom' <<<"$out")"

check "the busy session gets no badge" \
  "" "$(grep -F 'label=deltatom' <<<"$out")"

check "the waiting session is labelled with its project" \
  "label=arthur" "$(grep -m1 -x 'label=arthur' <<<"$out")"

stale=$(render 'claude.424242')

check "a badge with no matching session is removed" \
  "--remove
claude.424242" "$(grep -A1 -m1 -x -- '--remove' <<<"$stale")"
```

Note: all three live fixtures share the test's pid, so they all produce the badge item name `claude.$$`. Only the `waiting` one earns a badge, so there is exactly one — which is what makes the "no badge for busy/dormant" checks meaningful.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./test_states.sh`

Expected: the Task 1 checks still pass, then the rendering checks FAIL because `main` prints `not implemented yet` and exits 1, so `$out` is empty.

- [ ] **Step 3: Write the minimal implementation**

In `plugins/claude_sessions.sh`, add these constants just below `set -uo pipefail`:

```bash
SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COUNTER_ITEM="claude"
BADGE_PREFIX="claude."
```

Then replace the placeholder `main` with:

```bash
# One TAB-separated record per interactive session:
#   pid  sessionId  project  status  statusUpdatedAt
#
# Read straight from the state files rather than calling `claude agents --json`,
# which spawns the CLI and costs roughly 200ms — far too much at a 2s refresh.
read_sessions() {
  local files

  shopt -s nullglob
  files=("$SESSIONS_DIR"/*.json)
  shopt -u nullglob

  (( ${#files[@]} )) || return 0

  jq -r '
    select(.kind == "interactive")
    | [ .pid,
        .sessionId,
        (.cwd | split("/") | map(select(. != "")) | last),
        .status,
        .statusUpdatedAt ]
    | @tsv
  ' "${files[@]}" 2>/dev/null
}

# Print the SketchyBar arguments for the current snapshot, one per line.
# `existing` is the newline-separated list of claude.* items already on the bar,
# so we can add what is new and remove what no longer belongs.
build_args() {
  local now=$1 existing=$2
  local -a states=() wanted=()
  local count=0
  local pid sid project status updated state item overall drawing

  while IFS=$'\t' read -r pid sid project status updated; do
    [[ -n "$pid" ]] || continue
    # Session files outlive a crashed claude, so trust the process, not the file.
    kill -0 "$pid" 2>/dev/null || continue

    count=$((count + 1))
    state=$(derive_state "$status" "$updated" "$now")
    states+=("$state")

    case "$state" in
      needs_input|just_finished) ;;
      *) continue ;;
    esac

    item="${BADGE_PREFIX}${pid}"
    wanted+=("$item")

    if ! grep -qxF "$item" <<<"$existing"; then
      printf '%s\n' --add item "$item" right --move "$item" after "$COUNTER_ITEM"
    fi

    printf '%s\n' --set "$item" \
      "icon=$(state_icon "$state")" \
      "icon.color=$(state_color "$state")" \
      "label=$project" \
      "label.color=$(state_color "$state")"
  done < <(read_sessions)

  overall=dormant
  if (( ${#states[@]} )); then
    overall=$(printf '%s\n' "${states[@]}" | most_urgent)
  fi

  if (( count )); then
    drawing=on
  else
    drawing=off
  fi

  printf '%s\n' --set "$COUNTER_ITEM" \
    "label=$count" \
    "icon.color=$(state_color "$overall")" \
    "label.color=$(state_color "$overall")" \
    "drawing=$drawing"

  while read -r item; do
    [[ -n "$item" ]] || continue
    if ! printf '%s\n' "${wanted[@]:-}" | grep -qxF "$item"; then
      printf '%s\n' --remove "$item"
    fi
  done <<<"$existing"
}

main() {
  local dry_run=0 now existing line
  local -a args=()

  [[ "${1:-}" == "--dry-run" ]] && dry_run=1

  # BSD date has no %3N, and second resolution is ample for a 5 minute window.
  now=$(( $(date +%s) * 1000 ))

  if (( dry_run )); then
    existing=$(cat)
  else
    existing=$(sketchybar --query bar | jq -r '.items[]' | grep "^${BADGE_PREFIX}" || true)
  fi

  while IFS= read -r line; do
    args+=("$line")
  done < <(build_args "$now" "$existing")

  (( ${#args[@]} )) || return 0

  if (( dry_run )); then
    printf '%s\n' "${args[@]}"
  else
    sketchybar "${args[@]}"
  fi
}
```

Create `sketchybarrc.example`:

```bash
# claude-bar — live Claude Code sessions in the menu bar.
# Merge this into your own ~/.config/sketchybar/sketchybarrc.
#
# The counter item is permanent; the plugin creates and destroys the per-session
# badges beside it, so nothing else needs declaring here.

CLAUDE_BAR_DIR="$HOME/.config/sketchybar/claude-bar"

sketchybar --add item claude right \
           --set claude \
                 icon="✦" \
                 icon.font="SF Pro:Semibold:14.0" \
                 icon.color=0xff7c6f64 \
                 label.font="SF Pro:Semibold:13.0" \
                 label.color=0xff7c6f64 \
                 drawing=off \
                 update_freq=2 \
                 script="$CLAUDE_BAR_DIR/plugins/claude_sessions.sh"
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./test_states.sh`

Expected: PASS — all checks, including the eight rendering ones.

- [ ] **Step 5: Verify against the real bar**

Install SketchyBar and point it at this checkout:

```bash
brew install FelixKratz/formulae/sketchybar
mkdir -p ~/.config/sketchybar
ln -sfn "$PWD" ~/.config/sketchybar/claude-bar
cat sketchybarrc.example >> ~/.config/sketchybar/sketchybarrc
brew services start sketchybar
```

Expected: `✦ N` appears in the menu bar, N matching the number of Claude Code sessions you have open. Open a session and let it work — the counter turns blue. Let it come back to the prompt — it turns yellow and a badge with the project name appears next to it, then disappears after five minutes.

If nothing appears, run the plugin by hand to see the error: `./plugins/claude_sessions.sh </dev/null`

- [ ] **Step 6: Commit**

```bash
git add plugins/claude_sessions.sh test_states.sh tests/fixtures sketchybarrc.example
git commit -F - <<'EOF'
✨ Render live sessions as a counter plus attention badges

Reads ~/.claude/sessions/*.json directly instead of calling
`claude agents --json`, which spawns the CLI at roughly 200ms per invocation —
untenable at a two second refresh. The state files are the same data the CLI
reports, so nothing is lost.

The layout is deliberately hybrid. A permanent counter keeps the menu bar width
stable at rest, and only sessions that need input or just finished expand into a
named badge. Sessions quietly working stay folded into the counter, because
knowing one of them is busy rarely changes what you do next.

Two details worth recording:

- Session files outlive a crashed claude, so liveness comes from `kill -0` on
  the pid rather than from the file existing.
- `--dry-run` prints the SketchyBar arguments instead of executing them and
  takes the current item list on stdin. That makes reconciliation — including
  badge removal — testable with no SketchyBar installed and no live sessions.
  The fixtures carry a pid placeholder the test rewrites to its own pid, which
  exercises the liveness filter for real rather than mocking it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 3: Raise a Ghostty window by title

Ghostty runs as a single process for every window, so walking the process tree from a session's pid reaches the application, not the window. The only route to a specific window is the Accessibility API, matching on window title.

This task builds the tool and grants the permission. Its `--list` mode is what Task 4 uses to verify that titling works.

**Files:**
- Create: `plugins/claude_focus.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `plugins/claude_focus.sh <marker>` raises the first Ghostty window whose title contains `<marker>` and prints `raised`, or prints `no window matching: <marker>` and exits 1. `plugins/claude_focus.sh --list` prints every Ghostty window title, one per line.

- [ ] **Step 1: Write the script**

Create `plugins/claude_focus.sh`:

```bash
#!/usr/bin/env bash
# Raise the Ghostty window whose title contains a marker.
#
# Ghostty is a single process for all its windows, so a session pid cannot be
# resolved to a window through the process tree. Matching on the window title
# via the Accessibility API is the only route, which is why the SessionStart
# hook stamps a marker into the title in the first place.
#
# Requires Accessibility permission for whichever process runs this — SketchyBar
# in normal use, your terminal when testing by hand.
set -uo pipefail

usage() {
  printf 'usage: %s <marker>\n       %s --list\n' "$0" "$0" >&2
  exit 64
}

list_windows() {
  osascript -e '
    tell application "System Events" to tell process "ghostty"
      set out to ""
      repeat with w in windows
        set out to out & name of w & linefeed
      end repeat
      return out
    end tell'
}

raise_window() {
  osascript - "$1" <<'APPLESCRIPT'
on run argv
  set marker to item 1 of argv
  tell application "System Events"
    tell process "ghostty"
      repeat with w in windows
        if name of w contains marker then
          perform action "AXRaise" of w
          set frontmost to true
          return "raised"
        end if
      end repeat
    end tell
  end tell
  return "no window matching: " & marker
end run
APPLESCRIPT
}

case "${1:-}" in
  "")      usage ;;
  --list)  list_windows ;;
  *)
    result=$(raise_window "$1")
    printf '%s\n' "$result"
    [[ "$result" == "raised" ]] || exit 1
    ;;
esac
```

Make it executable: `chmod +x plugins/claude_focus.sh`

- [ ] **Step 2: Run it and expect the permission error**

Run: `./plugins/claude_focus.sh --list`

Expected: FAIL with `execution error: ... osascript is not allowed assistive access. (-1728)` — or the same message in your system language. This confirms the script reaches the Accessibility API and that the grant is the only thing missing.

- [ ] **Step 3: Grant Accessibility**

Open System Settings → Privacy & Security → Accessibility. Add the process that will run the script:

- For testing by hand: Ghostty (the terminal running the script).
- For normal use: `/opt/homebrew/opt/sketchybar/bin/sketchybar`.

Add both — the plugin runs under SketchyBar, but you will want to debug from a terminal.

- [ ] **Step 4: Run it again to verify it works**

Run: `./plugins/claude_focus.sh --list`

Expected: one line per open Ghostty window, showing the current titles. Note what they look like — Task 4 replaces them with something matchable.

Then check the not-found path: `./plugins/claude_focus.sh definitely-not-a-window; echo "exit=$?"`

Expected: `no window matching: definitely-not-a-window` and `exit=1`.

Finally check the happy path against a title you just saw. If one window is titled `fish /Volumes/sourcecode/arthur`, run `./plugins/claude_focus.sh arthur`.

Expected: `raised`, and that window comes to the front.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude_focus.sh
git commit -F - <<'EOF'
✨ Raise a Ghostty window by title through the Accessibility API

Ghostty runs one process for every window, so walking up from a Claude session
pid reaches the application and stops there — there is no per-window pid to find.
That rules out the obvious approach and leaves the Accessibility API, which can
enumerate windows but identifies them only by title.

Hence matching on a marker substring, and hence the SessionStart hook that will
put a known marker in the title.

The --list mode exists because title matching is only debuggable if you can see
the titles. It is also how the next task verifies its own work.

Accessibility must be granted to whichever process invokes this: SketchyBar in
normal use, the terminal when testing by hand. Homebrew upgrades replace the
SketchyBar binary and revoke the grant, so this will need redoing occasionally.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 4: Stamp the window title

Give every Claude session's window a title containing a marker derived from its session id, so Task 3's matcher has something reliable to find.

A hook runs as a child of `claude` and inherits its controlling terminal, so it can write the OSC 2 title sequence straight to `/dev/tty`. Claude Code also offers a `terminalSequence` field on hook output whose allowlist covers OSC 0/1/2, but writing to the tty needs no undocumented schema and is trivially verifiable, so that is what this uses.

The marker is `claude:` plus the first eight characters of the session id. The hook gets `session_id` in its own JSON input, so there is no cross-lookup into the session files and no startup race.

**Files:**
- Create: `hooks/claude_bar_title.sh`
- Modify: `~/.claude/settings.json` (user config, not in this repo)

**Interfaces:**
- Consumes: `plugins/claude_focus.sh --list` from Task 3, for verification.
- Produces: Ghostty window titles of the form `claude:<first 8 of sessionId> <project>`, for example `claude:128508e7 claude-bar`. Task 5 builds the same marker from the `sessionId` that `read_sessions` already emits.

- [ ] **Step 1: Write the hook**

Create `hooks/claude_bar_title.sh`:

```bash
#!/usr/bin/env bash
# SessionStart hook: stamp the terminal window title with a marker claude-bar
# can match on.
#
# Hooks run as a child of claude and inherit its controlling terminal, so the
# OSC 2 sequence can go straight to /dev/tty. Claude Code also accepts a
# `terminalSequence` field on hook output that permits OSC 0/1/2, but writing to
# the tty depends on nothing undocumented and is easy to check by hand.
#
# fish rewrites the title on its next prompt, so the marker disappears on its own
# when claude exits — stale titles are not a problem.
set -uo pipefail

input=$(cat)
session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')

[[ -n "$session_id" ]] || exit 0

printf '\033]2;claude:%s %s\007' "${session_id:0:8}" "$(basename "${cwd:-$PWD}")" \
  > /dev/tty 2>/dev/null || true
```

Make it executable: `chmod +x hooks/claude_bar_title.sh`

- [ ] **Step 2: Test the hook standalone**

Run it directly with a synthetic payload, from a Ghostty window:

```bash
echo '{"session_id":"abcdef12-3456-7890-abcd-ef1234567890","cwd":"/Volumes/sourcecode/claude-bar"}' \
  | ./hooks/claude_bar_title.sh
```

Expected: the Ghostty window title becomes `claude:abcdef12 claude-bar`. Confirm from another window:

```bash
./plugins/claude_focus.sh --list
```

Expected: `claude:abcdef12 claude-bar` appears in the list.

If the title does not change, the tty write is being swallowed. Fall back to emitting the sequence as hook output instead — replace the final `printf` with:

```bash
jq -n --arg marker "claude:${session_id:0:8} $(basename "${cwd:-$PWD}")" '{
  hookSpecificOutput: {
    hookEventName: "SessionStart",
    terminalSequence: ("\u001b]2;" + $marker + "\u0007")
  }
}'
```

- [ ] **Step 3: Wire it into settings**

The user's `~/.claude/settings.json` already has a `SessionStart` array with four entries, matching `startup`, `resume`, `clear` and `compact`, each running `~/.claude/hooks/cbm-session-reminder`. Add this hook alongside the existing one in each of the four matchers — re-stamping after a compact or a clear is what keeps the title correct for the whole session.

Symlink the hook so the repo stays the source of truth:

```bash
ln -sfn "$PWD/hooks/claude_bar_title.sh" ~/.claude/hooks/claude_bar_title.sh
```

Then in each of the four `SessionStart` matcher blocks, the `hooks` array becomes:

```json
"hooks": [
  {
    "type": "command",
    "command": "~/.claude/hooks/cbm-session-reminder"
  },
  {
    "type": "command",
    "command": "~/.claude/hooks/claude_bar_title.sh"
  }
]
```

Validate the edit before relying on it: `jq empty ~/.claude/settings.json && echo "settings.json is valid"`

- [ ] **Step 4: Verify end to end**

Open a fresh Claude Code session in a new Ghostty window, then from another window:

```bash
./plugins/claude_focus.sh --list
```

Expected: a line of the form `claude:<8 hex chars> <project name>`, matching the new session.

Cross-check the marker against what the session file reports, so Task 5 will build the same string:

```bash
jq -r '"claude:" + .sessionId[0:8] + " " + (.cwd | split("/") | last)' ~/.claude/sessions/*.json
```

Expected: the listed window titles are a subset of these lines.

Then raise it: `./plugins/claude_focus.sh claude:<those 8 chars>`

Expected: `raised`, and the correct window comes forward.

- [ ] **Step 5: Commit**

```bash
git add hooks/claude_bar_title.sh
git commit -F - <<'EOF'
✨ Stamp Ghostty window titles with a session marker

Title matching is the only way to reach a specific Ghostty window, so the titles
have to be something we control. The default title is whatever fish last set,
which is abbreviated and not reliably unique across sessions.

A hook runs as a child of claude and inherits its controlling terminal, so it
can write the OSC 2 sequence straight to /dev/tty. Claude Code also exposes a
`terminalSequence` field on hook output whose allowlist covers OSC 0/1/2, and
that is the documented route — but it depends on schema details that are not
published, whereas the tty write can be checked in one command. The hook keeps
the field as a documented fallback.

The marker is `claude:` plus the first eight characters of the session id. The
hook receives `session_id` in its own input, so there is no lookup into the
session files and therefore no race against them being written at startup.

Registered on all four SessionStart matchers, not just startup: re-stamping
after a compact or a clear keeps the title correct for the whole session. Stale
titles clean themselves up, since fish rewrites the title on its next prompt
once claude exits.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 5: Wire the click and document the setup

Connect the two halves: each badge gets a `click_script` that raises its window. Then write the README, since the project is only usable by someone who knows about the Accessibility grant.

**Files:**
- Modify: `plugins/claude_sessions.sh` (add `click_script` to the badge `--set`)
- Modify: `test_states.sh` (assert the click_script)
- Create: `README.md`

**Interfaces:**
- Consumes: `sid` from `read_sessions` (Task 2), the marker format from Task 4, `plugins/claude_focus.sh` from Task 3.
- Produces: the finished plugin. No further tasks depend on it.

- [ ] **Step 1: Write the failing test**

In `test_states.sh`, in the rendering section, add after the `label=arthur` check:

```bash
check "the badge raises its own window on click" \
  "click_script=$PWD/plugins/claude_focus.sh claude:aaaaaaaa" \
  "$(grep -m1 -F 'click_script=' <<<"$out")"
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./test_states.sh`

Expected: FAIL — `expected: click_script=... / actual:` (empty), because no argument carries `click_script=` yet.

- [ ] **Step 3: Write the minimal implementation**

In `plugins/claude_sessions.sh`, inside `build_args`, extend the badge `--set` block with a final argument. It becomes:

```bash
    printf '%s\n' --set "$item" \
      "icon=$(state_icon "$state")" \
      "icon.color=$(state_color "$state")" \
      "label=$project" \
      "label.color=$(state_color "$state")" \
      "click_script=$PLUGIN_DIR/claude_focus.sh claude:${sid:0:8}"
```

The marker must match what `hooks/claude_bar_title.sh` writes into the title: `claude:` plus the first eight characters of the session id.

- [ ] **Step 4: Run the test to verify it passes**

Run: `./test_states.sh`

Expected: PASS — every check, including the new one.

- [ ] **Step 5: Verify by clicking**

Reload SketchyBar so the new plugin output takes effect: `sketchybar --reload`

Then get a real session into an attention state — start something long in another Ghostty window and let it finish, or trigger a permission prompt — and click its badge.

Expected: the correct Ghostty window comes to the front.

If nothing happens, check that Accessibility is granted to `/opt/homebrew/opt/sketchybar/bin/sketchybar` and not only to your terminal.

- [ ] **Step 6: Write the README**

Create `README.md`:

````markdown
# claude-bar

A SketchyBar indicator for Claude Code sessions running in several terminal
windows at once. It answers, without switching apps, "does a session need me,
and which one?" — and brings that window forward when you click it.

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

mkdir -p ~/.config/sketchybar ~/.claude/hooks
ln -sfn "$PWD" ~/.config/sketchybar/claude-bar
ln -sfn "$PWD/hooks/claude_bar_title.sh" ~/.claude/hooks/claude_bar_title.sh
cat sketchybarrc.example >> ~/.config/sketchybar/sketchybarrc

brew services start sketchybar
```

Symlinking rather than copying keeps the checkout as the source of truth, so
`git pull` is all an update takes.

`jq` is required and ships with macOS at `/usr/bin/jq`.

## Register the title hook

Click-to-focus needs each Ghostty window to carry a marker in its title. Add the
hook to every `SessionStart` matcher in `~/.claude/settings.json`:

```json
"SessionStart": [
  {
    "matcher": "startup",
    "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude_bar_title.sh" }]
  },
  {
    "matcher": "resume",
    "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude_bar_title.sh" }]
  },
  {
    "matcher": "clear",
    "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude_bar_title.sh" }]
  },
  {
    "matcher": "compact",
    "hooks": [{ "type": "command", "command": "~/.claude/hooks/claude_bar_title.sh" }]
  }
]
```

If you already have hooks on those matchers, append to the existing `hooks`
arrays rather than replacing them. Check the result with
`jq empty ~/.claude/settings.json`.

## Grant Accessibility

Raising a specific window goes through the macOS Accessibility API. In System
Settings → Privacy & Security → Accessibility, add:

- `/opt/homebrew/opt/sketchybar/bin/sketchybar` — for the badges to work.
- Your terminal — for debugging with `plugins/claude_focus.sh --list`.

Homebrew upgrades replace the SketchyBar binary and revoke the grant. If clicks
stop working after an update, re-add it.

## Limitations

**Splits.** If two sessions share one Ghostty window as splits, the window title
reflects only the focused split. Clicking raises the right window but not the
right split. The Accessibility API exposes nothing below window level, so there
is no workaround.

**Same project twice.** The title marker is derived from the session id, so two
sessions in the same directory are distinguished correctly — but their badges
carry the same project label and are told apart only by position.

## How it works

Claude Code writes one JSON file per live session to `~/.claude/sessions/<pid>.json`,
carrying `status` (`busy`, `waiting`, `idle`), `statusUpdatedAt`, `cwd` and
`sessionId`. The plugin reads those files directly every two seconds. Calling
`claude agents --json` would return the same data but spawns the CLI at roughly
200 ms per invocation, which is far too slow for this refresh rate.

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
````

- [ ] **Step 7: Commit**

```bash
git add plugins/claude_sessions.sh test_states.sh README.md
git commit -F - <<'EOF'
✨ Raise the matching window when a badge is clicked

Joins the two halves already built: badges now carry a click_script pointing at
claude_focus.sh with the marker the SessionStart hook writes into the window
title. The marker is built from the sessionId the session file already reports,
so both sides derive it from the same source and cannot drift.

The README documents the two pieces of setup that are not discoverable from the
code: registering the title hook on all four SessionStart matchers, and granting
Accessibility to the SketchyBar binary. It also records the split limitation,
since someone will otherwise file it as a bug — a Ghostty window title reflects
only the focused split, and the Accessibility API exposes nothing finer.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```
