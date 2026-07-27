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

check "needs_input is red" "#fb4934" "$(state_color needs_input)"
check "just_finished is yellow" "#fabd2f" "$(state_color just_finished)"
check "working is blue" "#83a598" "$(state_color working)"
check "dormant is grey" "#7c6f64" "$(state_color dormant)"

check "needs_input shows a filled dot" "●" "$(state_icon needs_input)"
check "just_finished shows a hollow dot" "○" "$(state_icon just_finished)"
check "working shows a half dot" "◐" "$(state_icon working)"
check "dormant shows a middot" "·" "$(state_icon dormant)"

check "seconds under a minute" "12s" "$(format_age 12000)"
check "zero is zero seconds" "0s" "$(format_age 0)"
check "59s stays in seconds" "59s" "$(format_age 59999)"
check "a minute is minutes" "1m" "$(format_age 60000)"
check "59m stays in minutes" "59m" "$(format_age 3599999)"
check "an hour is hours" "1h" "$(format_age 3600000)"
check "three hours" "3h" "$(format_age 10800000)"

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

check "the title counts the three well-formed live sessions" \
  "1" "$(printf '%s' "$title" | grep -c '✦ 3')"

check "the title badges the waiting session" \
  "arthur" "$(printf '%s' "$title" | sed -n 's/.*● \([a-z]*\).*/\1/p')"

check "the title is tinted by the most urgent state" \
  "color=#fb4934" "$(printf '%s' "$title" | sed -n 's/.*| \(color=[^ ]*\).*/\1/p')"

check "the title does not badge the busy session" \
  "" "$(printf '%s' "$title" | grep -o 'deltatom')"

check "the title does not badge the dormant session" \
  "" "$(printf '%s' "$title" | grep -o 'exploratom')"


# The fixture's statusUpdatedAt is a fixed literal, not regenerated per run, so
# its age against the real wall clock grows with however long it has been since
# the fixture was authored. Compute the expected age the same way render() does
# rather than hardcoding it, or this assertion goes stale and flakes.
busy_updated=1785183600000
busy_age=$(format_age "$(( $(date +%s) * 1000 - busy_updated ))")

check "the dropdown lists the busy session" \
  "◐ deltatom — working ${busy_age} | color=#83a598" \
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

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
