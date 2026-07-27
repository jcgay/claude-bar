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
set -uo pipefail

SESSIONS_DIR="${CLAUDE_SESSIONS_DIR:-$HOME/.claude/sessions}"

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
    needs_input)   printf '#fb4934\n' ;;
    just_finished) printf '#fabd2f\n' ;;
    working)       printf '#83a598\n' ;;
    *)             printf '#7c6f64\n' ;;
  esac
}

state_icon() {
  case "$1" in
    needs_input)   printf '●\n' ;;
    just_finished) printf '○\n' ;;
    working)       printf '◐\n' ;;
    *)             printf '·\n' ;;
  esac
}

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

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
