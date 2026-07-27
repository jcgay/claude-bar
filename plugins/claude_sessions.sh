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
