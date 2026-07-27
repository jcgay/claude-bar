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

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
