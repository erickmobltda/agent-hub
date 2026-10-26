#!/bin/bash
. "$(dirname "$0")/lib.sh"
start_tmux
make_repo "$TMP/repos" svc-a >/dev/null 2>&1
write_config "repos_roots=$TMP/repos" "branch_prefix=feat/" "worktree_location=sibling" "github=auto"
"$AH" new --group dev --repo svc-a --task api >/dev/null 2>&1
"$AH" new --group dev --repo svc-a --task docs >/dev/null 2>&1
cat > "$TMP/prs.json" <<'JSON'
[
 {"number": 12, "state": "OPEN", "isDraft": false, "headRefName": "feat/api", "url": "https://gh/pr/12",
  "statusCheckRollup": [{"status": "COMPLETED", "conclusion": "SUCCESS"}, {"state": "SUCCESS"}]},
 {"number": 7, "state": "MERGED", "isDraft": false, "headRefName": "feat/docs", "url": "https://gh/pr/7", "statusCheckRollup": []},
 {"number": 3, "state": "CLOSED", "isDraft": false, "headRefName": "feat/docs", "url": "https://gh/pr/3", "statusCheckRollup": []},
 {"number": 9, "state": "OPEN", "isDraft": true, "headRefName": "feat/other", "url": "https://gh/pr/9",
  "statusCheckRollup": [{"status": "IN_PROGRESS", "conclusion": ""}]}
]
JSON
export GH_STUB_JSON="$TMP/prs.json"
tm set-environment -g GH_STUB_JSON "$GH_STUB_JSON"
cache="$AGENT_HUB_RUNTIME/gh/$(printf '%s' "$TMP/repos/svc-a" | tr '/' '_').tsv"

# The list never waits for GitHub: the first one starts a refresh in the background.
"$AH" list >/dev/null
wait_for 5 test -s "$cache"
check "gh: cache written by the background refresh" grep -q '^feat/api	12	OPEN	pass	https://gh/pr/12$' "$cache"
check "gh: only my PRs, newest first" grep -q 'gh pr list --author @me --state all' "$GH_STUB_LOG"
assert_eq "pending" "$(awk -F'\t' '$1 == "feat/other" { print $4 }' "$cache")" "gh: running checks -> pending"
assert_eq "DRAFT" "$(awk -F'\t' '$1 == "feat/other" { print $3 }' "$cache")" "gh: draft PR"
json=$("$AH" list --format json)
assert_eq "12 OPEN pass" "$(printf '%s' "$json" | jq -r '.[] | select(.task=="api") | "\(.pr.number) \(.pr.state) \(.pr.checks)"')" "gh: PR in list --format json"
assert_eq "7 MERGED" "$(printf '%s' "$json" | jq -r '.[] | select(.task=="docs") | "\(.pr.number) \(.pr.state)"')" "gh: the newest PR of a branch wins"
lines=$(AGENT_HUB_DASH_MODE=hq "$AH" dash --lines | strip_ansi)
assert_contains "$(printf '%s\n' "$lines" | grep 'dev/api')" "#12 ✓" "gh: dashboard badge"
assert_contains "$(printf '%s\n' "$lines" | grep 'dev/docs')" "#7 merged" "gh: merged badge"

# A fresh cache is not refreshed again; github=off and a logged-out gh never call it.
: > "$GH_STUB_LOG"
"$AH" list >/dev/null; sleep 0.5
check "gh: fresh cache, no new call" sh -c "! grep -q 'pr list' '$GH_STUB_LOG'"
rm -f "$cache"; "$AH" config set github off >/dev/null
"$AH" list >/dev/null; sleep 0.5
check "gh: github=off makes no calls" sh -c "! grep -q 'pr list' '$GH_STUB_LOG'"
"$AH" config set github auto >/dev/null
rm -f "$AGENT_HUB_RUNTIME/gh/auth"
GH_STUB_AUTH=0 "$AH" list >/dev/null; sleep 0.5
check "gh: not logged in -> no calls" sh -c "! grep -q 'pr list' '$GH_STUB_LOG'"
rm -f "$AGENT_HUB_RUNTIME/gh/auth"
"$AH" list >/dev/null; wait_for 5 test -s "$cache"

# Ctrl+O: the cached URL opens directly; otherwise gh is asked; otherwise the footer says so.
export AGENT_HUB_DASH_INST=4242
out=$("$AH" dash --do pr t t:dev/api - feat/api "$TMP/repos/svc-a--api" "https://gh/pr/12" "$TMP/repos/svc-a")
assert_eq "trigger(ctrl-r)" "$out" "ctrl-o: refreshes (the footer shows the result)"
assert_eq "https://gh/pr/12" "$(tail -1 "$OPEN_STUB_LOG")" "ctrl-o: opens the cached PR"
GH_STUB_URL="https://gh/pr/99" "$AH" dash --do pr t t:dev/x - feat/x "$TMP/repos/svc-a" "" "$TMP/repos/svc-a" >/dev/null
assert_eq "https://gh/pr/99" "$(tail -1 "$OPEN_STUB_LOG")" "ctrl-o: asks gh when the cache has no PR"
"$AH" dash --do pr t t:dev/y - feat/y "$TMP/repos/svc-a" "" "$TMP/repos/svc-a" >/dev/null
assert_contains "$("$AH" dash --footer)" "no pull request found for feat/y" "ctrl-o: no PR -> footer message"

# close: the PR state is part of what it reports.
wt="$TMP/repos/svc-a--docs"
(cd "$wt" && echo x > x && git add x && git -c user.email=t@t -c user.name=t commit -qm squashed-already)
out=$("$AH" close dev/docs 2>&1); rc=$?
assert_eq 3 "$rc" "close: unpushed commits block it"
assert_contains "$out" "PR #7 is MERGED" "close: says the PR was merged (squash merges look unpushed)"

finish
