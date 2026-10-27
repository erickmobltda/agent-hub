# shellcheck shell=bash
# Pull request status through the gh CLI. The dashboard only reads a local cache; a detached job
# refreshes it (at most once a minute per repo) and pokes the dashboards when it is done.

# Checks of a PR reduced to pass / fail / pending ("" when it has none).
GH_JQ='.[] | [.headRefName, (.number | tostring),
  (if .state == "OPEN" and .isDraft then "DRAFT" else .state end),
  ((.statusCheckRollup // []) as $r
    | if ($r | length) == 0 then ""
      elif any($r[]; (.conclusion // .state // "") | test("FAILURE|ERROR|TIMED_OUT|CANCELLED|ACTION_REQUIRED|STARTUP_FAILURE")) then "fail"
      elif any($r[]; ((.status // "COMPLETED") != "COMPLETED") or ((.state // "") | test("PENDING|EXPECTED"))) then "pending"
      else "pass" end),
  .url] | @tsv'

gh_enabled() { # github=auto and gh is logged in (a local check, cached for 10 minutes)
  [ "${cfg_github:-auto}" = off ] && return 1
  command -v gh >/dev/null 2>&1 || return 1
  local f
  f="$(runtime_dir gh)/auth"
  if [ -f "$f" ] && [ -z "$(find "$f" -mmin +10 2>/dev/null)" ]; then
    [ "$(cat "$f")" = ok ]
    return
  fi
  if gh auth token >/dev/null 2>&1; then echo ok > "$f"; return 0; fi
  echo no > "$f"
  return 1
}

gh_cache_file() { # gh_cache_file <repo path>
  printf '%s/%s.tsv\n' "$(runtime_dir gh)" "$(printf '%s' "$1" | tr '/' '_')"
}

gh_pr_lookup() { # gh_pr_lookup <repo> <branch>: sets pr_num pr_state pr_url from the cache
  pr_num="" pr_state="" pr_url=""
  local f line
  [ -n "$2" ] || return 0
  f=$(gh_cache_file "$1")
  [ -f "$f" ] || return 0
  line=$(awk -F'\t' -v b="$2" '$1 == b { print $2 "\t" $3 "\t" $5; exit }' "$f")
  [ -n "$line" ] || return 0
  IFS=$TAB read -r pr_num pr_state pr_url <<EOF
$line
EOF
}

gh_refresh_bg() { # repo paths on stdin; each refresh runs detached
  local repo bin
  bin=$(ah_bin)
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    ( "$bin" _gh-refresh "$repo" </dev/null >/dev/null 2>&1 & )
  done
}

cmd_gh_refresh() { # _gh-refresh <repo>: one gh call, newest PRs first
  local repo=${1:-} f lock json changed
  [ -d "$repo" ] || return 0
  config_load || true
  f=$(gh_cache_file "$repo")
  lock="gh-$(basename "$f" .tsv)"
  lock_take "$lock" 0 || return 0
  json=$(cd "$repo" && GH_PROMPT_DISABLED=1 gh pr list --author @me --state all --limit 30 \
    --json number,state,isDraft,headRefName,statusCheckRollup,url 2>/dev/null)
  # Written even when gh answers nothing (no GitHub remote, offline): the timestamp is what keeps
  # this repo from being asked again on every refresh.
  {
    printf '#ts %s\n' "$(date +%s)"
    if [ -n "$json" ]; then printf '%s' "$json" | jq -r "$GH_JQ" 2>/dev/null; fi
  } > "$f.tmp.$$"
  changed=1
  [ -f "$f" ] && [ "$(tail -n +2 "$f")" = "$(tail -n +2 "$f.tmp.$$")" ] && changed=0
  mv "$f.tmp.$$" "$f"
  lock_drop "$lock"
  [ "$changed" = 1 ] && dash_poke
  return 0
}

open_url() {
  if command -v open >/dev/null 2>&1; then open "$1"
  elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$1"
  else return 1; fi >/dev/null 2>&1
}
