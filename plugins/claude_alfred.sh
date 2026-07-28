#!/usr/bin/env bash
# Alfred Script Filter: the menu bar dropdown, reachable from a hotkey.
#
# Prints an Alfred JSON feed on stdout — one item per live interactive session,
# the pid as its `arg` — so a Script Filter box wired to a Run Script box
# calling claude_focus.sh lands the cursor in the right Ghostty split without
# a trip to the mouse. The hotkey, the fuzzy filtering and the list UI are
# Alfred's; all that is missing is the feed.
#
# Wiring lives in the README. Nothing here is SwiftBar's, and nothing in
# claude_sessions.sh changes: this sources it for its state functions.
#
# Not `set -e`, for the same reason the plugin isn't: kill -0 exits non-zero as
# ordinary control flow.
set -uo pipefail

# Alfred runs workflow scripts with a GUI app's PATH, the same trap SwiftBar
# sets — jq is not in it. Unlike the plugin this script is free to pin PATH:
# the plugin cannot, because pinning would make its own jq warning unreachable,
# whereas the warning below stays reachable for a machine with no jq at all.
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin

# Sourced, not re-implemented: the BASH_SOURCE/$0 guard at the foot of the
# plugin keeps main from running, which is what makes its functions reachable —
# the same property test_states.sh relies on.
#
# Resolved from BASH_SOURCE rather than $0, and with `%/*` rather than dirname,
# the way the plugin resolves its own sibling: pointing Alfred at a symlink to
# this file must still find the plugin next to the real one.
PLUGIN="$(/usr/bin/readlink -f "${BASH_SOURCE[0]}")"
PLUGIN="${PLUGIN%/*}/claude_sessions.sh"
# shellcheck source=claude_sessions.sh
source "$PLUGIN"

# Sort key, not a display value. Mirrors most_urgent's precedence, so the list
# opens with the session that wants attention already selected.
state_rank() {
  case "$1" in
    needs_input)   printf '0\n' ;;
    just_finished) printf '1\n' ;;
    working)       printf '2\n' ;;
    *)             printf '3\n' ;;
  esac
}

# One TAB-separated row per live session: rank, age, title, subtitle, pid.
#
# The two guards are the plugin's, for the plugin's reasons: session files
# outlive a crashed claude, so trust the process; and a truncated file would
# abort derive_state's arithmetic on a non-number.
#
# The pid ends the subtitle because the title is only the last path segment —
# two sessions in the same directory would otherwise be two identical rows.
session_rows() {
  local now=$1
  local pid sid project status updated state age

  while IFS=$'\t' read -r pid sid project status updated; do
    [[ -n "$pid" ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    [[ "$updated" =~ ^[0-9]+$ ]] || continue

    age=$(( now - updated ))
    state=$(derive_state "$status" "$updated" "$now")

    printf '%s\t%s\t%s %s\t%s · %s · pid %s\t%s\n' \
      "$(state_rank "$state")" "$age" \
      "$(state_icon "$state")" "$project" \
      "$(state_label "$state")" "$(format_age "$age")" "$pid" \
      "$pid"
  done < <(read_sessions)
}

# Rank ascending, then age descending within a rank: among sessions in the same
# state, the one that has been waiting longest is the one you meant.
#
# jq builds the JSON rather than printf, because a project directory holding a
# quote or a backslash would otherwise emit a feed Alfred cannot parse. The
# plugin rewrites `|` for the same class of reason — escaping belongs to the
# output format.
#
# No `uid` on the items, deliberately: Alfred reorders results it has seen
# chosen before, which would quietly undo the ranking above.
feed() {
  session_rows "$1" \
    | sort -t$'\t' -k1,1n -k2,2nr \
    | cut -f3- \
    | jq -Rs '
        [ split("\n")[]
          | select(length > 0)
          | split("\t")
          | { title: .[0], subtitle: .[1], arg: .[2] } ]
        | if length == 0
          then [ { title: "No Claude Code sessions", valid: false } ]
          else . end
        | { items: . }
      '
}

main() {
  # An empty feed reads as "no sessions", so a jq missing even from the pinned
  # PATH has to say so on screen — the plugin's warning, in Alfred's shape.
  if ! command -v jq >/dev/null; then
    printf '{"items":[{"title":"jq not found in PATH","valid":false}]}\n'
    return 0
  fi

  # BSD date has no %3N, and second resolution is ample for a 5 minute window.
  feed "$(( $(date +%s) * 1000 ))"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
