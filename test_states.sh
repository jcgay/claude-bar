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
check "just_finished is yellow" "#b57614" "$(state_color just_finished)"
check "working is blue" "#458588" "$(state_color working)"
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
# live_busy.json carries TIMESTAMP_PLACEHOLDER instead of a static literal, so
# its age assertion can compare against a real "now" without calling
# format_age (the function under test) a second time from the test itself.
now_ms=$(( $(date +%s) * 1000 ))
for f in tests/fixtures/*.json; do
  sed -e "s/PID_PLACEHOLDER/$$/" -e "s/TIMESTAMP_PLACEHOLDER/$now_ms/" "$f" > "$fixture_dir/$(basename "$f")"
done

out=$(CLAUDE_SESSIONS_DIR="$fixture_dir" ./plugins/claude_sessions.sh)
title=$(printf '%s\n' "$out" | sed -n '1p')
menu=$(printf '%s\n' "$out" | sed -n '/^---$/,$p' | tail -n +2)

check "the title counts the five well-formed live sessions" \
  "1" "$(printf '%s' "$title" | grep -c '✦ 5')"

check "the title badges the waiting session" \
  "arthur" "$(printf '%s' "$title" | sed -n 's/.*● \([a-z]*\).*/\1/p')"

check "the title is tinted by the most urgent state" \
  "color=#fb4934" "$(printf '%s' "$title" | sed -n 's/.*| \(color=[^ ]*\).*/\1/p')"

check "the title does not badge the busy session" \
  "" "$(printf '%s' "$title" | grep -o 'deltatom')"

check "the title does not badge the dormant session" \
  "" "$(printf '%s' "$title" | grep -o 'exploratom')"


# A literal age here races the wall clock: the fixture stamps now_ms and the
# plugin samples date again moments later, so whenever a second boundary
# falls in that gap the age renders 1s instead of 0s and a literal assertion
# flakes (measured ~13%). Asserting the pattern instead pins icon, project,
# label, unit and color without depending on which second it lands in.
check "the dropdown lists the busy session" \
  "1" "$(printf '%s\n' "$menu" | grep -cE '^◐ deltatom — working [0-9]+s \| color=#458588 bash=')"

check "the dropdown lists the dormant session" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '· exploratom — idle')"

check "the dropdown lists the waiting session" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '● arthur — needs input')"

# The two halves of the label. Claude Code derives a name for every session
# whether or not one was asked for, so displaying it unconditionally would put
# `deltatom-8e` in the menu bar and call that an improvement — only a name the
# user chose is allowed to displace the directory.
check "a name the user set replaces the directory" \
  "1" "$(printf '%s\n' "$menu" | grep -cF '· bisect the flaky suite — idle')"

check "a name Claude Code derived never reaches the output" \
  "" "$(printf '%s\n' "$out" | grep -o 'deltatom-8e')"

check "the dead session appears nowhere" \
  "" "$(printf '%s\n' "$out" | grep -o 'ghost')"

check "the malformed timestamp is skipped rather than crashing" \
  "" "$(printf '%s\n' "$out" | grep -o 'broken')"

check "a pipe in the project name is escaped in the dropdown" \
  "1" "$(printf '%s\n' "$menu" | grep -cF 'pipe∣farm')"

check "a raw pipe in the project name never reaches the output" \
  "" "$(printf '%s\n' "$out" | grep -F 'pipe|farm')"

# Every live row hands its own pid to the focus script — the pid is the only
# thing tying a row back to a Ghostty split. All fixtures share this test's pid,
# so this pins the parameter's presence and shape, not per-row values.
check "every dropdown row is clickable" \
  "$(printf '%s\n' "$menu" | grep -c .)" \
  "$(printf '%s\n' "$menu" | grep -cF "bash=\"$PWD/plugins/claude_focus.sh\" param1=$$ terminal=false")"

# SwiftBar installs the plugin as a symlink in its own folder, so a focus path
# built from $0 rather than the resolved BASH_SOURCE would point at that folder,
# where no focus script exists. Only running through a link catches that.
link_dir=$(mktemp -d)
ln -s "$PWD/plugins/claude_sessions.sh" "$link_dir/claude-bar.2s.sh"
link_out=$(CLAUDE_SESSIONS_DIR="$fixture_dir" "$link_dir/claude-bar.2s.sh")
rm -rf "$link_dir"

check "run through a symlink the rows still point at the real focus script" \
  "5" "$(printf '%s\n' "$link_out" | grep -cF "bash=\"$PWD/plugins/claude_focus.sh\"")"

# The jq guard further down exists because SwiftBar launches plugins with its
# own PATH. Everything else the plugin shells out to has the same exposure, and
# a focus path is the worst place for it: readlink off PATH truncates it to
# /claude_focus.sh and every click does nothing, with nothing on screen to say
# so. This PATH carries jq and nothing else the plugin reaches for.
bare_dir=$(mktemp -d)
ln -s /usr/bin/jq "$bare_dir/jq"
bare_out=$(PATH="$bare_dir:/bin" CLAUDE_SESSIONS_DIR="$fixture_dir" "$PWD/plugins/claude_sessions.sh")
rm -rf "$bare_dir"

check "a PATH without readlink still resolves the focus script" \
  "5" "$(printf '%s\n' "$bare_out" | grep -cF "bash=\"$PWD/plugins/claude_focus.sh\"")"

# Regression for Finding 1: a jq *parse* error aborts that jq process
# immediately, so a single batched `jq ... file1 file2 ...` call loses every
# file ordered after the bad one — the shared fixture_dir above can't prove
# this either way, because `unparseable.json` happens to glob-sort last, so
# nothing follows it for a batched call to lose. This directory names the
# bad file first on purpose, so a regression back to batched jq would abort
# before ever reading the healthy file after it and this check would fail.
poison_dir=$(mktemp -d)
cp tests/fixtures/unparseable.json "$poison_dir/0-unparseable.json"
sed "s/PID_PLACEHOLDER/$$/" tests/fixtures/live_waiting.json > "$poison_dir/1-healthy.json"
poison_out=$(CLAUDE_SESSIONS_DIR="$poison_dir" ./plugins/claude_sessions.sh)
rm -rf "$poison_dir"

check "a healthy session sorted after an unparseable file still renders" \
  "1" "$(printf '%s\n' "$poison_out" | grep -c '● arthur — needs input')"

empty_dir=$(mktemp -d)
trap 'rm -rf "$fixture_dir" "$empty_dir"' EXIT
empty_out=$(CLAUDE_SESSIONS_DIR="$empty_dir" ./plugins/claude_sessions.sh)

check "with no sessions the title counts zero" \
  "✦ 0 | color=#7c6f64" "$(printf '%s\n' "$empty_out" | sed -n '1p')"

check "with no sessions the dropdown says so" \
  "No Claude Code sessions | color=#7c6f64" \
  "$(printf '%s\n' "$empty_out" | sed -n '/^---$/,$p' | tail -n +2)"

# SwiftBar launches plugins from a GUI app with its own PATH, so a jq that is
# merely absent from *that* PATH must say so rather than rendering the same
# output as "no sessions". /bin has bash but never jq on this machine.
no_jq_out=$(PATH=/bin "$PWD/plugins/claude_sessions.sh")

check "with jq missing the title warns instead of lying about zero" \
  "✦ ⚠ | color=#fb4934" "$(printf '%s\n' "$no_jq_out" | sed -n '1p')"

check "with jq missing the dropdown says why" \
  "jq not found in PATH | color=#fb4934" \
  "$(printf '%s\n' "$no_jq_out" | sed -n '/^---$/,$p' | tail -n +2)"

# --- alfred feed -----------------------------------------------------------
# claude_alfred.sh reuses the plugin's state functions wholesale, so the only
# new logic is the ranking and the JSON assembly. Everything below pins one of
# those two.
#
# Not covered: the "jq not found" item. Unlike the plugin, that script pins its
# own PATH, and macOS ships /usr/bin/jq — so there is no PATH this suite can
# hand it that reaches the guard.

alfred_out=$(CLAUDE_SESSIONS_DIR="$fixture_dir" ./plugins/claude_alfred.sh)

check "the feed is valid JSON" \
  "ok" "$(printf '%s\n' "$alfred_out" | jq -e . >/dev/null 2>&1 && echo ok)"

# The fixtures pin the ordering end to end: arthur is waiting, so it outranks
# both busy sessions whatever their age, and pipe|farm's stale timestamp puts it
# above deltatom's fresh one — within a rank, the longest wait comes first.
check "the feed is ordered by urgency, then by longest wait" \
  "● arthur ◐ pipe|farm ◐ deltatom · exploratom · bisect the flaky suite" \
  "$(printf '%s\n' "$alfred_out" | jq -r '[.items[].title] | join(" ")')"

check "every item carries its pid as the focus argument" \
  "$$ $$ $$ $$ $$" "$(printf '%s\n' "$alfred_out" | jq -r '[.items[].arg] | join(" ")')"

check "the subtitle carries state, age and pid" \
  "1" "$(printf '%s\n' "$alfred_out" | jq -r '.items[0].subtitle' | grep -cE "^needs input · [0-9]+[smh] · pid $$\$")"

# The dropdown has to rewrite `|`, which is SwiftBar's parameter separator. JSON
# has no such rule, and jq quotes what needs quoting — so a project name that
# the menu bar mangles on purpose must arrive here intact.
check "a pipe in the project name survives the feed unescaped" \
  "1" "$(printf '%s\n' "$alfred_out" | jq -r '[.items[].title] | join(" ")' | grep -cF 'pipe|farm')"

alfred_empty=$(CLAUDE_SESSIONS_DIR="$empty_dir" ./plugins/claude_alfred.sh)

# valid=false so Enter on the placeholder does nothing rather than handing an
# empty arg to the focus script.
check "with no sessions the feed says so, unactionably" \
  "No Claude Code sessions false" \
  "$(printf '%s\n' "$alfred_empty" | jq -r '.items[0] | "\(.title) \(.valid)"')"

if (( failures )); then
  printf '\n%d failure(s)\n' "$failures"
  exit 1
fi
printf '\nall checks passed\n'
