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
    if ! result=$(raise_window "$1"); then
      printf 'could not query Ghostty windows\n' >&2
      exit 1
    fi
    printf '%s\n' "$result"
    [[ "$result" == "raised" ]] || exit 1
    ;;
esac
