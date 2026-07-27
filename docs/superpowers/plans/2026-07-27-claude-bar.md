# claude-bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu bar indicator that shows which interactive Claude Code sessions need attention across several Ghostty windows.

**Architecture:** A SwiftBar plugin reads `~/.claude/sessions/*.json` every two seconds, derives a display state per session from `status` and `statusUpdatedAt`, and prints a menu bar title — a counter plus a badge for whatever needs attention — followed by a dropdown listing every live session.

> **Revised twice mid-execution.** Read Tasks 1 through 3 as history: they were written for SketchyBar and their code has since been superseded.
>
> **First revision (Task 4).** The plan originally ended with click-to-focus: a `SessionStart` hook stamping a marker into each Ghostty window title, and a click handler raising the matching window through the Accessibility API. Task 3 built the window-raising half, then enumerating the live windows showed Claude Code writes those titles itself whenever it starts working — so the marker would be gone from exactly the sessions that earn a badge. The user chose to drop click-to-focus rather than carry a second hook to re-stamp on `Stop` and `Notification`. Original Tasks 4 and 5 became the revised Task 4. `plugins/claude_focus.sh` stands as a diagnostic.
>
> **Second revision (Tasks 5 and 6).** SketchyBar draws its own bar rather than adding an item to the native macOS menu bar, so adopting it means replacing the menu bar wholesale — not what the user intended when choosing it over SwiftBar on looks. SwiftBar adds an ordinary item to the menu bar already there. Task 5 ports the renderer; Task 6 swaps the installs and rewrites the docs. The state logic from Task 1 survives unchanged apart from the color format.

**Tech Stack:** Bash, `jq` (already at `/usr/bin/jq`), SwiftBar, `osascript` / macOS Accessibility API.

## Global Constraints

- All code, comments, and commit messages in English. Commit subjects are prefixed with a gitmoji, and bodies explain the context behind the change, not just the diff.
- Bash with `#!/usr/bin/env bash` and `set -uo pipefail`. Not `set -e`: the read loop relies on non-zero exits from `kill -0` as ordinary control flow.
- Colors come from the user's gruvbox Ghostty palette: needs input `#fb4934`, just finished `#fabd2f`, working `#83a598`, dormant `#7c6f64`. Tasks 1 through 4 wrote them as SketchyBar `0xAARRGGBB` literals; Task 5 moves them to CSS hex.
- Icons: `●` needs input, `○` just finished, `◐` working, `·` dormant.
- State names used throughout: `needs_input`, `just_finished`, `working`, `dormant`.
- The just-finished window is 300000 ms (5 minutes).
- `SESSIONS_DIR` defaults to `$HOME/.claude/sessions` and is overridable via `CLAUDE_SESSIONS_DIR` so tests can point at fixtures.
- Timestamps are epoch milliseconds. BSD `date` on macOS has no `%3N`, so compute `now` as `$(( $(date +%s) * 1000 ))`.

## File Structure

| File | Responsibility |
| --- | --- |
| `plugins/claude_sessions.sh` | The whole plugin: read session files, derive states, print the menu bar title and dropdown. Sourceable so tests can call its functions. Installed as `~/.config/swiftbar/claude-bar.2s.sh`. |
| `plugins/claude_focus.sh` | Diagnostic: list Ghostty window titles, or raise the window whose title contains a given marker. |
| `test_states.sh` | Sources `claude_sessions.sh` and asserts state derivation, urgency ordering, colors, icons, age formatting, and the rendered output against fixtures. |
| `tests/fixtures/` | Session JSON fixtures used by `test_states.sh`. |
| `README.md` | Install, how it works, and why clicking does nothing. |

`sketchybarrc.example` existed through Task 4 and is deleted by Task 5.

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


### Task 4: Drop the click scaffolding and document the setup

Click-to-focus is cancelled. Tasks 4 and 5 of the original plan — stamping the window title with a `SessionStart` hook, then wiring a `click_script` onto each badge — are replaced by this single task.

**Why it was cancelled.** The original design assumed a title stamped at `SessionStart` would persist for the session's lifetime. It does not: Claude Code writes the Ghostty window title itself whenever it starts working, showing a spinner and a summary of the current task. Enumerating the live windows made this plain:

```
⠐ Ajouter indicateur menubar pour sessions Claude Code
/V/s/arthur
/V/s/a/karadoc
⠂ Ajouter une palette de commande rapide à l'UI
/V/s/exploratom
```

A marker written at session start survives only until the user's next prompt, so it would be gone from precisely the sessions that earn a badge. Writing it instead on the `Stop` and `Notification` hooks — after Claude Code's own title write rather than before it — would have worked, but the user chose to drop click-to-focus rather than carry a second hook and its ordering assumption.

`plugins/claude_focus.sh` from Task 3 stays, as a diagnostic for inspecting Ghostty window titles. Two consequences follow, and this task cleans both up: its header comment currently justifies itself by pointing at a hook that will never exist, and `PLUGIN_DIR` in `plugins/claude_sessions.sh` was computed solely to build the `click_script` path, so it is now dead.

**Files:**
- Modify: `plugins/claude_sessions.sh` (remove the now-unused `PLUGIN_DIR`)
- Modify: `plugins/claude_focus.sh` (correct the header comment)
- Create: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1 through 3.
- Produces: nothing further depends on this task.

- [ ] **Step 1: Remove the dead constant**

In `plugins/claude_sessions.sh`, delete the `PLUGIN_DIR` assignment near the top of the file. It was introduced to build a `click_script` path that is no longer wired. Confirm nothing else references it:

Run: `grep -n PLUGIN_DIR plugins/claude_sessions.sh`
Expected: no output.

- [ ] **Step 2: Run the tests to verify nothing broke**

Run: `./test_states.sh`

Expected: PASS — all 26 checks, output pristine. `PLUGIN_DIR` had no readers, so removing it must not change behavior. If any check fails, the constant was load-bearing after all — stop and report rather than working around it.

- [ ] **Step 3: Correct the focus script's header comment**

`plugins/claude_focus.sh` opens with a comment ending in a sentence to the effect of "which is why the SessionStart hook stamps a marker into the title in the first place." No such hook exists. Replace the comment block with:

```bash
# Raise the Ghostty window whose title contains a marker, or list the titles.
#
# Ghostty is a single process for all its windows, so a session pid cannot be
# resolved to a window through the process tree. Matching on the window title
# via the Accessibility API is the only route.
#
# This is a diagnostic, not part of the menu bar indicator's normal operation.
# Wiring it to a badge click was tried and dropped: it needs a stable, unique
# marker in the window title, and Claude Code overwrites that title itself
# whenever it starts working.
#
# Requires Accessibility permission for whichever process runs it.
```

Leave the code below the comment untouched.

- [ ] **Step 4: Verify the script still runs**

Run: `./plugins/claude_focus.sh --list`

Expected: one line per open Ghostty window. A comment change cannot break it, but this confirms you did not disturb the heredoc.

Do not run the raise path — the user is working in those windows and stealing focus is disruptive.

- [ ] **Step 5: Write the README**

Create `README.md`:

````markdown
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
````

- [ ] **Step 6: Commit**

```bash
git add plugins/claude_sessions.sh plugins/claude_focus.sh README.md
git commit -F - <<'EOF'
📝 Document the indicator and drop the click scaffolding

Click-to-focus is cancelled, so the two constructs that existed only to serve it
go with it: PLUGIN_DIR in the session plugin, computed solely to build a
click_script path, and the claude_focus.sh header comment that justified the
script by pointing at a SessionStart hook now never being written.

The reason it was cancelled is worth recording, because the idea is tempting
enough that someone will try it again. Ghostty runs one process for every
window, so a session pid cannot be resolved to a window through the process
tree, and the Accessibility API identifies windows only by title. The plan was
to stamp a unique marker into the title at SessionStart — but Claude Code writes
that title itself whenever it starts working, so the marker would be gone from
exactly the sessions that earn a badge. Writing it on the Stop and Notification
hooks instead would have worked, at the cost of a second hook and an ordering
assumption against Claude Code's own title writes. Not worth it for the payoff.

claude_focus.sh stays as a diagnostic for inspecting window titles, with its
comment corrected to say so.

The README leads with what the indicator does and states plainly that clicking a
badge does nothing, since a menu bar item that looks clickable and isn't will
otherwise be read as broken.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 5: Port the renderer to SwiftBar

SketchyBar is out — it draws its own bar rather than adding an item to the native macOS menu bar, which the user did not intend to adopt. SwiftBar puts a normal item in the existing menu bar. See the spec's "Revision: SwiftBar replaces SketchyBar" section for the full reasoning.

This task is pure code: swap the rendering layer, leave the machine alone. Task 6 handles installs and docs.

A SwiftBar plugin's stdout *is* its output. Lines before a `---` line are the menu bar title; lines after it are the dropdown. Per-line parameters follow a `|`. So the entire item-reconciliation layer goes away — no `--add`/`--set`/`--remove`, no querying the bar, no `--dry-run` reading the current item list from stdin. The script prints and exits, which also makes the tests simpler: assert on stdout.

Three of the deferred minor findings dissolve with the code that carried them: the `BADGE_PREFIX` regex-dot, the unreachable `(( ${#args[@]} ))` guard, and `state_icon`'s untested `*` branch — all four states need an icon now, because the dropdown shows every session.

**Files:**
- Modify: `plugins/claude_sessions.sh` (replace `build_args` and `main`; change `state_color`'s format; add `state_label`, `format_age`; extend `state_icon`)
- Modify: `test_states.sh` (rewrite the rendering section, update the color assertions, add icon and age assertions)
- Create: `tests/fixtures/malformed.json`
- Delete: `sketchybarrc.example`

**Interfaces:**
- Consumes: `derive_state`, `most_urgent`, `read_sessions` — all unchanged.
- Produces: the finished plugin. Task 6 installs it as `claude-bar.2s.sh` and documents it.

- [ ] **Step 1: Write the failing tests**

In `test_states.sh`, change the four color assertions to CSS hex:

```bash
check "needs_input is red" "#fb4934" "$(state_color needs_input)"
check "just_finished is yellow" "#fabd2f" "$(state_color just_finished)"
check "working is blue" "#83a598" "$(state_color working)"
check "dormant is grey" "#7c6f64" "$(state_color dormant)"
```

Add icon assertions for the two states that previously had none, beside the two existing ones:

```bash
check "working shows a half dot" "◐" "$(state_icon working)"
check "dormant shows a middot" "·" "$(state_icon dormant)"
```

Add age formatting assertions:

```bash
check "seconds under a minute" "12s" "$(format_age 12000)"
check "zero is zero seconds" "0s" "$(format_age 0)"
check "59s stays in seconds" "59s" "$(format_age 59999)"
check "a minute is minutes" "1m" "$(format_age 60000)"
check "59m stays in minutes" "59m" "$(format_age 3599999)"
check "an hour is hours" "1h" "$(format_age 3600000)"
check "three hours" "3h" "$(format_age 10800000)"
```

Create `tests/fixtures/malformed.json` — a live pid whose timestamp is not a number, which must be skipped rather than crashing the arithmetic:

```json
{"pid":PID_PLACEHOLDER,"sessionId":"eeeeeeee-1111-2222-3333-444444444444","cwd":"/Volumes/sourcecode/broken","kind":"interactive","name":"broken-77","status":"waiting","statusUpdatedAt":"not-a-number"}
```

Then replace the whole `# --- rendering ---` section from Task 2 with this one. The fixture setup at the top is unchanged; only the assertions differ.

```bash
# --- rendering -------------------------------------------------------------
# Fixtures carry PID_PLACEHOLDER so we can substitute a pid that is genuinely
# running (our own) and prove the dead-process filter drops the rest.

fixture_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir"' EXIT
for f in tests/fixtures/*.json; do
  sed "s/PID_PLACEHOLDER/$$/" "$f" > "$fixture_dir/$(basename "$f")"
done

out=$(CLAUDE_SESSIONS_DIR="$fixture_dir" ./plugins/claude_sessions.sh)
title=$(printf '%s\n' "$out" | sed -n '1p')
menu=$(printf '%s\n' "$out" | sed -n '/^---$/,$p' | tail -n +2)

check "the title counts the four well-formed live sessions" \
  "1" "$(printf '%s' "$title" | grep -c '✦ 4')"

check "the title badges the waiting session" \
  "arthur" "$(printf '%s' "$title" | sed -n 's/.*● \([a-z]*\).*/\1/p')"

check "the title is tinted by the most urgent state" \
  "color=#fb4934" "$(printf '%s' "$title" | sed -n 's/.*| \(color=[^ ]*\).*/\1/p')"

check "the title does not badge the busy session" \
  "" "$(printf '%s' "$title" | grep -o 'deltatom')"

check "the title does not badge the dormant session" \
  "" "$(printf '%s' "$title" | grep -o 'exploratom')"

check "the dropdown lists the busy session" \
  "◐ deltatom — working 0s | color=#83a598" \
  "$(printf '%s\n' "$menu" | grep -F 'deltatom')"

check "the dropdown lists the dormant session" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '· exploratom — idle')"

check "the dropdown lists the waiting session" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '● arthur — needs input')"

check "the dead session appears nowhere" \
  "" "$(printf '%s\n' "$out" | grep -o 'ghost')"

check "the malformed timestamp is skipped rather than crashing" \
  "" "$(printf '%s\n' "$out" | grep -o 'broken')"

empty_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir" "$empty_dir"' EXIT
empty_out=$(CLAUDE_SESSIONS_DIR="$empty_dir" ./plugins/claude_sessions.sh)

check "with no sessions the title counts zero" \
  "✦ 0 | color=#7c6f64" "$(printf '%s\n' "$empty_out" | sed -n '1p')"

check "with no sessions the dropdown says so" \
  "No Claude Code sessions | color=#7c6f64" \
  "$(printf '%s\n' "$empty_out" | sed -n '/^---$/,$p' | tail -n +2)"
```

Note that all live fixtures share the test's pid, so the dropdown will contain several rows whose project names differ — that is what makes the per-project assertions meaningful.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./test_states.sh`

Expected: FAIL. The color, icon and age assertions fail because `state_color` still emits `0xAARRGGBB`, `state_icon` returns empty for working and dormant, and `format_age` does not exist. The rendering assertions fail because the script still expects a `--dry-run` flag and stdin.

- [ ] **Step 3: Write the implementation**

In `plugins/claude_sessions.sh`, replace the header comment with:

```bash
#!/usr/bin/env bash
# SwiftBar plugin: surface live interactive Claude Code sessions.
#
# Claude Code maintains one small JSON file per live session under
# ~/.claude/sessions. This prints a menu bar title summarising them, plus a
# dropdown listing every one with its state and age.
#
# SwiftBar reads this script's stdout: lines before the `---` line are the menu
# bar title, lines after it are the dropdown, and per-line parameters follow a
# `|`. The refresh interval lives in the installed filename — claude-bar.2s.sh —
# not in here.
#
# Not `set -e`: the read loop uses non-zero exits from kill -0 as ordinary
# control flow.
```

Change `state_color` to CSS hex:

```bash
# Gruvbox, matching the user's Ghostty palette.
state_color() {
  case "$1" in
    needs_input)   printf '#fb4934\n' ;;
    just_finished) printf '#fabd2f\n' ;;
    working)       printf '#83a598\n' ;;
    *)             printf '#7c6f64\n' ;;
  esac
}
```

Extend `state_icon` so every state has one — the dropdown shows them all, not just the two that earn a badge:

```bash
state_icon() {
  case "$1" in
    needs_input)   printf '●\n' ;;
    just_finished) printf '○\n' ;;
    working)       printf '◐\n' ;;
    *)             printf '·\n' ;;
  esac
}
```

Add, after `state_icon`:

```bash
# Wording for the dropdown. The icon alone reads as decoration; the word is what
# makes a row scannable.
state_label() {
  case "$1" in
    needs_input)   printf 'needs input\n' ;;
    just_finished) printf 'just finished\n' ;;
    working)       printf 'working\n' ;;
    *)             printf 'idle\n' ;;
  esac
}

# Coarse human-readable age. Precision past the unit is noise in a menu that
# redraws every two seconds.
format_age() {
  local seconds=$(( $1 / 1000 ))

  if (( seconds < 60 )); then
    printf '%ds\n' "$seconds"
  elif (( seconds < 3600 )); then
    printf '%dm\n' "$(( seconds / 60 ))"
  else
    printf '%dh\n' "$(( seconds / 3600 ))"
  fi
}
```

Delete `build_args` entirely and replace it, plus `main`, with:

```bash
# Print the SwiftBar output for the current snapshot: one title line, the `---`
# separator, then one dropdown row per live session.
render() {
  local now=$1
  local -a states=() rows=()
  local count=0 badges=""
  local pid sid project status updated state

  while IFS=$'\t' read -r pid sid project status updated; do
    [[ -n "$pid" ]] || continue
    # Session files outlive a crashed claude, so trust the process, not the file.
    kill -0 "$pid" 2>/dev/null || continue
    # A truncated or malformed file must not take down a refresh that runs every
    # two seconds, and derive_state's arithmetic would abort on a non-number.
    [[ "$updated" =~ ^[0-9]+$ ]] || continue

    count=$(( count + 1 ))
    state=$(derive_state "$status" "$updated" "$now")
    states+=("$state")

    rows+=("$(state_icon "$state") $project — $(state_label "$state") $(format_age "$(( now - updated ))") | color=$(state_color "$state")")

    case "$state" in
      needs_input|just_finished) badges+="  $(state_icon "$state") $project" ;;
    esac
  done < <(read_sessions)

  local overall=dormant
  if (( ${#states[@]} )); then
    overall=$(printf '%s\n' "${states[@]}" | most_urgent)
  fi

  printf '✦ %d%s | color=%s\n' "$count" "$badges" "$(state_color "$overall")"
  printf -- '---\n'

  if (( ${#rows[@]} )); then
    printf '%s\n' "${rows[@]}"
  else
    printf 'No Claude Code sessions | color=%s\n' "$(state_color dormant)"
  fi
}

main() {
  # BSD date has no %3N, and second resolution is ample for a 5 minute window.
  render "$(( $(date +%s) * 1000 ))"
}
```

Leave `derive_state`, `most_urgent`, `read_sessions`, `SESSIONS_DIR`, `JUST_FINISHED_WINDOW_MS` and the sourcing guard exactly as they are. Delete the now-unused `COUNTER_ITEM` and `BADGE_PREFIX` constants.

Then delete the SketchyBar config: `git rm sketchybarrc.example`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./test_states.sh`

Expected: PASS, output pristine.

Then look at the real output by eye, since a menu is a visual thing:

Run: `./plugins/claude_sessions.sh`

Expected: a title line like `✦ 4  ○ claude-bar | color=#fabd2f`, then `---`, then one row per live session on this machine. Sanity-check that the project names and states match what you would expect from `ls ~/.claude/sessions`.

- [ ] **Step 5: Commit**

```bash
git add -A plugins/claude_sessions.sh test_states.sh tests/fixtures/malformed.json sketchybarrc.example
git commit -F - <<'EOF'
♻️ Port the renderer from SketchyBar to SwiftBar

SketchyBar draws its own bar instead of adding an item to the native macOS menu
bar, so adopting it means replacing the menu bar wholesale. That was not
understood when it was picked over SwiftBar on looks, and it is far more
commitment than a session indicator warrants. SwiftBar adds an ordinary item to
the menu bar already there.

The rewrite is mostly subtraction. A SwiftBar plugin's stdout is its output —
lines before `---` are the menu bar title, lines after it are the dropdown — so
the entire item-reconciliation layer goes: no add/set/remove, no querying the bar
for what already exists, no --dry-run mode taking the current item list on stdin.
The script prints and exits. The tests get simpler with it, asserting on stdout
rather than on a synthetic argument list.

The state logic is untouched. derive_state, most_urgent and read_sessions carry
over verbatim; only the color format changes, from SketchyBar's 0xAARRGGBB to CSS
hex.

Having a dropdown changes one design trade-off. The hybrid title existed because
menu bar width was scarce, forcing quietly-working sessions to stay folded into
the counter. The title keeps that shape, but the dropdown now lists every live
session with its state and age — so the information the title omits is one click
away rather than lost. That is why all four states need an icon now, where
previously only the two that earn a badge did.

Three deferred findings dissolve with the code that carried them: the badge-prefix
regex whose dot was an unescaped wildcard, the unreachable empty-argument guard in
main, and state_icon's untested fallback branch. The fourth — a malformed
statusUpdatedAt verified only by hand — now has a committed fixture.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```

---

### Task 6: Swap the installs and rewrite the docs

Take SketchyBar off the machine, put SwiftBar on it, and make the README describe what actually ships.

**Files:**
- Modify: `README.md`
- Modify: `plugins/claude_focus.sh` (one wording fix)

**Interfaces:**
- Consumes: everything from Tasks 1 through 5.
- Produces: nothing further depends on this task.

- [ ] **Step 1: Remove SketchyBar**

The user has approved removing it entirely. Nothing here predates this project — `~/.config/sketchybar` was created by Task 2 and contained no prior configuration.

```bash
brew services stop sketchybar
rm -rf ~/.config/sketchybar
brew uninstall sketchybar
```

Verify: `brew services list | grep sketchybar` returns nothing, and `ls ~/.config/sketchybar` reports no such directory.

- [ ] **Step 2: Install SwiftBar**

```bash
brew install --cask swiftbar
```

SwiftBar asks for a plugin folder on first launch, through a GUI dialog with no CLI equivalent. **Do not try to script around it.** Create the folder and report that the user must launch SwiftBar once and point it there:

```bash
mkdir -p ~/.config/swiftbar
```

- [ ] **Step 3: Install the plugin**

The refresh interval lives in the filename, and the file must be executable:

```bash
ln -sfn "$PWD/plugins/claude_sessions.sh" ~/.config/swiftbar/claude-bar.2s.sh
ls -l ~/.config/swiftbar/
```

Expected: the symlink exists and resolves to the checkout.

- [ ] **Step 4: Fix the imprecise wording**

`plugins/claude_focus.sh`'s header says Ghostty is "a single process for all its windows", which is correct. The README will reuse that phrasing rather than the looser "one process for every window", which reads distributively and contradicts the reason given alongside it. Nothing to change in `claude_focus.sh` itself — confirm with `grep -n 'single process' plugins/claude_focus.sh` that the precise phrasing is the one already there, and use it in the README.

- [ ] **Step 5: Rewrite the README**

Replace `README.md` entirely:

````markdown
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
````

- [ ] **Step 6: Verify the plugin runs from where SwiftBar will call it**

Run: `~/.config/swiftbar/claude-bar.2s.sh`

Expected: the same title-and-dropdown output as running it from the checkout. This confirms the symlink resolves and the script does not depend on its working directory.

- [ ] **Step 7: Commit**

```bash
git add README.md
git commit -F - <<'EOF'
📝 Document the SwiftBar install and retire SketchyBar

SketchyBar is off the machine: service stopped, ~/.config/sketchybar removed —
it held nothing predating this project — and the Homebrew package uninstalled.
SwiftBar replaces it.

The README now describes what ships. Two things it states plainly because both
would otherwise read as bugs: the refresh interval lives in the installed
filename rather than any config file, which is surprising the first time you see
it; and clicking the menu bar item does nothing, with the reason, because an item
that looks clickable and isn't invites a bug report.

It also documents that running the plugin by hand prints exactly what the menu
bar will show. That falls out of SwiftBar's design and makes the thing far easier
to debug than the previous reconciliation-based renderer, so it is worth saying
out loud.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
```
