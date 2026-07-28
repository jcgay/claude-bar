#!/usr/bin/env bash
# Bring the Ghostty surface running a given Claude Code session to the front.
#
# Ghostty is a single process for all its windows, so a session pid cannot be
# resolved to a window through the process tree. Ghostty 1.3 ships an
# AppleScript dictionary that sidesteps the whole problem: a `terminal` there is
# one split, and `focus` raises its window *and* puts the cursor in that split —
# even when it is neither the frontmost window nor the focused split within it.
# That is strictly more than the Accessibility API could do, which saw windows
# only, identified by title.
#
# What remains is tying a pid to a surface. AppleScript exposes a surface's id,
# title and working directory, none of which the session file knows. So we make
# the link ourselves: writing OSC 2 to the session's own tty sets a title on
# that surface alone, whatever has focus. Claude Code overwrites titles as it
# works — the reason an earlier attempt at click-to-focus was abandoned — but
# the marker now only has to outlive the single osascript call that reads it.
#
# Ghostty-only, by construction: the marker is written before we know whether a
# Ghostty surface will claim it, so pointing this at a session in another
# terminal leaves that terminal's title overwritten.
#
# Requires Automation permission towards Ghostty for whichever process runs it.
set -uo pipefail

# SwiftBar runs this on click with the PATH of a GUI app, not of a login shell —
# the same PATH that makes the sibling plugin guard against a missing jq. Every
# tool used below is in /usr/bin or /bin, so pinning PATH is enough here; the
# plugin cannot do the same without rendering its own jq warning unreachable.
PATH=/usr/bin:/bin

usage() {
  printf 'usage: %s <pid>\n       %s --list\n' "$0" "$0" >&2
  exit 64
}

# One TAB-separated record per open surface: id, working directory, title.
#
# The separator is bound before the tell block on purpose: Ghostty's dictionary
# declares a class named `tab`, which shadows AppleScript's own `tab` constant
# inside the block and coerces to the literal string "tab".
list_terminals() {
  osascript -e 'set sep to character id 9
  tell application "Ghostty"
    set out to ""
    repeat with t in terminals
      set out to out & (id of t) & sep & (working directory of t) & sep & (name of t) & linefeed
    end repeat
    if out is "" then return ""
    return text 1 thru -2 of out
  end tell'
}

set_title() {
  printf '\033]2;%s\007' "$2" > "/dev/$1"
}

# Print the id of the surface now carrying the marker, having focused it.
focus_marked() {
  osascript - "$1" <<'APPLESCRIPT'
on run argv
  tell application "Ghostty"
    set marked to (every terminal whose name is (item 1 of argv))
    if marked is {} then error "no surface carries the marker"
    focus (item 1 of marked)
    return id of (item 1 of marked)
  end tell
end run
APPLESCRIPT
}

focus_session() {
  local pid=$1 tty marker before id previous

  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [[ -z "$tty" || "$tty" == '??' ]]; then
    printf 'pid %s has no controlling terminal\n' "$pid" >&2
    return 1
  fi

  # Read the titles before one of them is overwritten, so the surface the
  # marker ends up identifying can be put back to what it said.
  before=$(list_terminals) || return 1

  # Braces are load-bearing: the closing bracket is multibyte, and bash reads
  # the leading bytes of it as part of an unbraced variable name.
  marker="⟦claude-bar:${pid}⟧"
  set_title "$tty" "$marker"

  if ! id=$(focus_marked "$marker"); then
    printf 'no Ghostty surface for pid %s\n' "$pid" >&2
    return 1
  fi

  # An empty result — a surface opened since `before` was read — clears the
  # title, which Ghostty renders as its own default. Better than leaving the
  # marker on screen.
  previous=$(printf '%s\n' "$before" | awk -F'\t' -v id="$id" '$1 == id { print $3 }')
  set_title "$tty" "$previous"
}

case "${1:-}" in
  "")       usage ;;
  --list)   list_terminals ;;
  *[!0-9]*) usage ;;
  *)        focus_session "$1" ;;
esac
