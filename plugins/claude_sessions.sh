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

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COUNTER_ITEM="claude"
BADGE_PREFIX="claude."

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
    # A truncated or malformed session file can leave the timestamp non-numeric
    # or empty; derive_state's arithmetic would throw on that, so skip the
    # record rather than kill the whole refresh.
    [[ "$updated" =~ ^[0-9]+$ ]] || continue

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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
