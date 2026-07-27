#!/usr/bin/env bash
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
