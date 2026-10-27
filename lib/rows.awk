# rows.awk: hub rows from task markers, tmux panes and sessions. Runs no external command.
#
# Input lines (tab-separated, tagged by the first field):
#   M  marker file
#   P  session window window_id pane_id pane_index role status since note worktree path command title dead
#   S  session windows active_pane_path active_pane_id
# ENVIRON: AH_MODE (raw | hq | popup), AH_HQ (hub session), AH_GH (1: read the PR cache),
#   AH_GHDIR (cache dir), AH_STALE (file that receives repos whose cache is old), AH_TTL (seconds),
#   AH_VIEW (tree | flat: what goes to stdout), AH_ALSO (file that receives the other view),
#   AH_COLLAPSED (file listing collapsed groups; their tasks are left out of the tree),
#   AH_SUMMARY (file that receives the header line: agents per state).
# Output, hq/popup (fzf shows field 4):
#   kind id target display status since note repo branch worktree pr_num pr_state pr_checks pr_url title repo_path group
#   kinds: g group header (tree only) · t task (live or stopped) · p Claude started by hand ·
#          s plain session · n the "+ new session" row (last) · h the hub (popup only, first).
#          The "sessions" group is *sessions.
#   tree: headers with the group's tasks under them (├─ └─); flat: one line per item, group/task
#   (the dashboard shows the flat view while a query is typed: fzf only searches what is shown).
# Output, raw:
#   kind group task status since repo branch pane window worktree live pr_num pr_state pr_checks pr_url note

BEGIN {
  FS = "\t"
  mode = ENVIRON["AH_MODE"]; hq = ENVIRON["AH_HQ"]; gh = (ENVIRON["AH_GH"] == "1")
  ghdir = ENVIRON["AH_GHDIR"]; stalef = ENVIRON["AH_STALE"]; ttl = ENVIRON["AH_TTL"] + 0
  if (ttl <= 0) ttl = 60
  srand(); now = srand()
  split("waiting error done starting working idle stopped", order, " ")
  rank["waiting"] = 0; rank["error"] = 1; rank["done"] = 2; rank["starting"] = 3; rank["working"] = 3
  rank["idle"] = 4; rank["stopped"] = 5
  icon["waiting"] = "◐"; icon["error"] = "✗"; icon["done"] = "✓"; icon["starting"] = "⟳"
  icon["working"] = "●"; icon["idle"] = "○"; icon["stopped"] = "◌"
  E = "\033["; R = E "0m"; DIM = E "2m"; BOLD = E "1m"; GRAY = E "90m"; BLUE = E "34m"
  GROUP = E "1;35m"; SESS = E "1;34m"
  col["waiting"] = E "1;33m"; col["error"] = E "1;31m"; col["done"] = E "1;36m"; col["starting"] = E "32m"
  col["working"] = E "1;32m"; col["idle"] = E "37m"; col["stopped"] = GRAY
  f = ENVIRON["AH_COLLAPSED"]
  if (f != "") { while ((getline l < f) > 0) if (l != "") C[l] = 1; close(f) }
  why["permission_prompt"] = "permission"; why["elicitation_dialog"] = "input"; why["agent_needs_input"] = "input"
  why["AskUserQuestion"] = "question"; why["ExitPlanMode"] = "plan"
}

$1 == "M" { marker($2); next }
$1 == "P" {
  np++; ps[np] = $2; pw[np] = $3; pwid[np] = $4; pid[np] = $5; pidx[np] = $6 + 0; prole[np] = $7
  pst[np] = $8; psince[np] = $9; pnote[np] = $10; pwt[np] = $11; ppath[np] = $12; pcmd[np] = $13
  ptitle[np] = $14; pdead[np] = $15
  next
}
$1 == "S" { ns++; sn[ns] = $2; swin[ns] = $3; spath[ns] = $4; spane[ns] = $5; next }
END { build(); out() }

function base(p) { sub(/\/+$/, "", p); sub(/.*\//, "", p); return p }

# First line of a file, or "\001" when it can't be read. Never call it on a directory.
function first(f,   l, r) { r = ((getline l < f) > 0) ? l : "\001"; close(f); return r }

function branchof(head) {
  if (head ~ /^ref: refs\/heads\//) return substr(head, 17)
  if (head == "\001" || head == "") return ""
  return substr(head, 1, 7)
}

function marker(f,   l, g, tk, wt, dir, repo, n) {
  g = tk = wt = ""
  while ((getline l < f) > 0) {
    if (l ~ /^group=/) g = substr(l, 7)
    else if (l ~ /^task=/) tk = substr(l, 6)
    else if (l ~ /^worktree=/) wt = substr(l, 10)
  }
  close(f)
  if (g == "" || tk == "" || ((g "/" tk) in T)) return
  n = ++nt; T[g "/" tk] = n; tg[n] = g; tt[n] = tk; twt[n] = wt
  dir = f; sub(/\/agent-hub$/, "", dir)
  repo = dir; sub(/\/\.git\/worktrees\/[^\/]+$/, "", repo)
  trepo[n] = repo; tbranch[n] = branchof(first(dir "/HEAD"))
  if (wt != "") WT[wt] = n
}

# Repo and branch of a directory, walking up to its repo (Claude panes started by hand).
function gitinfo(p,   h, l, gd, d, n) {
  G_repo = G_branch = ""
  for (n = 0; n < 16 && p != ""; n++) {
    h = first(p "/.git/HEAD")
    if (h != "\001") { G_repo = p; G_branch = branchof(h); return 1 }
    l = first(p "/.git")
    if (l ~ /^gitdir: /) {
      gd = substr(l, 9); if (gd !~ /^\//) gd = p "/" gd
      d = gd
      G_repo = sub(/\/\.git\/worktrees\/[^\/]+$/, "", d) ? d : p
      G_branch = branchof(first(gd "/HEAD"))
      return 1
    }
    if (p == "/") break
    sub(/\/[^\/]*$/, "", p); if (p == "") p = "/"
  }
  return 0
}

function ghload(repo,   f, l, a, ts, k) {
  if (!gh || repo == "" || (repo in GHL)) return
  GHL[repo] = 1
  k = repo; gsub(/\//, "_", k)
  f = ghdir "/" k ".tsv"
  ts = -1
  while ((getline l < f) > 0) {
    if (l ~ /^#ts /) { ts = substr(l, 5) + 0; continue }
    split(l, a, "\t")
    if ((repo, a[1]) in PRN) continue # gh lists the newest PR of a branch first
    PRN[repo, a[1]] = a[2]; PRS[repo, a[1]] = a[3]; PRC[repo, a[1]] = a[4]; PRU[repo, a[1]] = a[5]
  }
  close(f)
  if (ts < 0 || now - ts > ttl) STALE[repo] = 1
}

# add(kind, id, target, group, name, state, since, note, repo_path, branch, worktree, pane, window, title, extra)
function add(kind, id, target, group, name, st, since, note, repo, br, wt, pane, win, title, extra,   n) {
  n = ++nr
  rk[n] = kind; rid[n] = id; rtg[n] = target; rgrp[n] = group; rname[n] = name; rst[n] = st
  rsince[n] = since; rnote[n] = note; rrepo[n] = repo; rbr[n] = br; rwt[n] = wt; rpane[n] = pane
  rwin[n] = win; rtitle[n] = title; rextra[n] = extra
  rprn[n] = rprs[n] = rprc[n] = rpru[n] = ""
  if (kind == "t" || kind == "p") {
    ghload(repo)
    if ((repo, br) in PRN) { rprn[n] = PRN[repo, br]; rprs[n] = PRS[repo, br]; rprc[n] = PRC[repo, br]; rpru[n] = PRU[repo, br] }
    if (!(group in grank) || rank[st] < grank[group]) grank[group] = rank[st]
  }
  return n
}

function build(   i, n, sc, best, k, st, used, usedsess) {
  # Live panes of each task: the pane that carries its worktree, else the window named after it.
  for (i = 1; i <= np; i++) {
    if (ps[i] == hq) continue
    n = 0
    if (pwt[i] != "" && (pwt[i] in WT)) n = WT[pwt[i]]
    else if ((ps[i] "/" pw[i]) in T) n = T[ps[i] "/" pw[i]]
    if (!n) continue
    sc = (prole[i] == "claude") ? 3 : (pst[i] != "" ? 2 : 1)
    if (sc > tsc[n] || (sc == tsc[n] && pidx[i] < pidx[tp[n]])) { tsc[n] = sc; tp[n] = i }
    used[i] = 1; usedsess[ps[i]] = 1
  }
  for (n = 1; n <= nt; n++) {
    i = tp[n]
    if (i) {
      st = (pst[i] == "") ? "stopped" : pst[i]
      add("t", "t:" tg[n] "/" tt[n], pid[i], tg[n], tg[n] "/" tt[n], st, psince[i], pnote[i], trepo[n], tbranch[n], twt[n], pid[i], pwid[i], ptitle[i], "")
    } else {
      add("t", "t:" tg[n] "/" tt[n], "-", tg[n], tg[n] "/" tt[n], "stopped", "", "", trepo[n], tbranch[n], twt[n], "", "", "", "")
    }
  }
  # Claude started by hand anywhere else (it has a status but no task).
  for (i = 1; i <= np; i++) {
    if (used[i] || ps[i] == hq || pst[i] == "") continue
    gitinfo(ppath[i])
    add("p", "p:" pid[i], pid[i], ps[i], ps[i] "/" pw[i], pst[i], psince[i], pnote[i], G_repo, G_branch, ppath[i], pid[i], pwid[i], ptitle[i], "")
    usedsess[ps[i]] = 1
  }
  if (mode == "raw") return
  for (i = 1; i <= ns; i++) {
    if (sn[i] == hq || (sn[i] in usedsess)) continue
    add("s", "s:" sn[i], sn[i], "*sessions", sn[i], "", "", "", "", "", spath[i], spane[i], "", "", swin[i])
  }
}

function sortkey(n,   g, s) {
  if (rk[n] == "s") return "9 " rname[n]
  g = rgrp[n]; s = (rsince[n] == "") ? 9999999999 : rsince[n] + 0
  return sprintf("1 %d %s %d %010d %s", grank[g], g, rank[rst[n]], s, rname[n])
}

function age(s,   d) {
  if (s == "") return ""
  d = now - s; if (d < 0) d = 0
  if (d < 60) return "now" # minutes at most: an idle list changes once a minute, not every refresh
  if (d < 3600) return int(d / 60) "m"
  if (d < 86400) return int(d / 3600) "h"
  return int(d / 86400) "d"
}

function vlen(s,   i, c, n, len) {
  n = 0; len = length(s)
  for (i = 1; i <= len; i++) { c = substr(s, i, 1); if (c < "\200" || c > "\277") n++ }
  return n
}

function pad(s, w,   n) { n = vlen(s); while (n++ < w) s = s " "; return s }

function prplain(n) {
  if (rprn[n] == "") return ""
  if (rprs[n] == "MERGED") return "#" rprn[n] " merged"
  if (rprs[n] == "CLOSED") return "#" rprn[n] " closed"
  return "#" rprn[n] (rprc[n] == "" ? "" : " x")
}

function prcolor(n,   c, s) {
  if (rprn[n] == "") return ""
  c = (rprs[n] == "OPEN") ? E "32m" : (rprs[n] == "DRAFT") ? DIM : (rprs[n] == "MERGED") ? E "35m" : E "31m"
  s = c "#" rprn[n] R
  if (rprs[n] == "MERGED") return s " " E "35m" "merged" R
  if (rprs[n] == "CLOSED") return s " " E "31m" "closed" R
  if (rprc[n] == "pass") return s " " E "32m" "✓" R
  if (rprc[n] == "fail") return s " " E "31m" "✗" R
  if (rprc[n] == "pending") return s " " E "33m" "●" R
  return s
}

function tilde(p) {
  if (ENVIRON["HOME"] != "" && index(p, ENVIRON["HOME"]) == 1) return "~" substr(p, length(ENVIRON["HOME"]) + 1)
  return p
}

function spaces(n) { return n > 0 ? substr(sprintf("%" n "s", ""), 1, n) : "" }

function tail(n,   rest) { # "<state> <age> · <why>", the end of a task line in the tree
  rest = ago(n)
  return col[rst[n]] rst[n] R (rest == "" ? "" : " " GRAY rest R)
}

# Flat view: one line per item, group/task (what the search shows).
function display(n,   st, nm, g, task, w) {
  st = rst[n]
  if (rk[n] == "s") {
    w = rextra[n] (rextra[n] == "1" ? " window" : " windows")
    return BLUE "▪" R " " GRAY pad("session", 8) R " " BOLD pad(rname[n], wname) R "  " GRAY pad(w, wrepo) R "  " GRAY tilde(rwt[n]) R
  }
  nm = rname[n]; g = nm; sub(/\/.*/, "", g); task = substr(nm, length(g) + 2)
  return col[st] icon[st] R " " col[st] pad(st, 8) R " " GRAY g "/" R (st == "stopped" ? "" : BOLD) task R spaces(wname - vlen(nm)) \
    "  " BLUE pad(base(rrepo[n]), wrepo) R "  " prcolor(n) spaces(wpr - vlen(prplain(n))) "  " GRAY ago(n) R
}

function ago(n,   rest) { # "<age> · <why it waits>"
  rest = age(rsince[n])
  if (rst[n] == "waiting" && rnote[n] != "") rest = rest " · " ((rnote[n] in why) ? why[rnote[n]] : rnote[n])
  if (rk[n] == "p") rest = rest (rest == "" ? "" : " · ") "started by hand"
  return rest
}

# Tree view: a task (or session) under its group header.
function display_tree(n, last,   st, nm, w, conn) {
  conn = "  " GRAY (last ? "└─" : "├─") R " "
  if (rk[n] == "s") {
    w = rextra[n] (rextra[n] == "1" ? " window" : " windows")
    return conn BLUE "▪" R " " BOLD pad(rname[n], wtask) R "  " GRAY pad(w, wrepo) R "  " GRAY tilde(rwt[n]) R
  }
  st = rst[n]
  nm = substr(rname[n], index(rname[n], "/") + 1)
  return conn col[st] icon[st] R " " (st == "stopped" ? GRAY : BOLD) pad(nm, wtask) R "  " BLUE pad(base(rrepo[n]), wrepo) R \
    "  " prcolor(n) spaces(wpr - vlen(prplain(n))) "  " tail(n)
}

function header(g,   k, s, sum, nm, c) {
  if (g == "*sessions") { nm = "sessions"; c = SESS } else { nm = g; c = GROUP }
  sum = ""
  for (k = 1; k <= 7; k++) { s = order[k]; if (gst[g, s] > 0) sum = sum " " col[s] icon[s] gst[g, s] R }
  return c ((g in C) ? "▸" : "▾") " " nm R " " GRAY "(" gcount[g] ")" R sum
}

function line(n, disp) {
  return rk[n] "\t" rid[n] "\t" rtg[n] "\t" disp "\t" rst[n] "\t" rsince[n] "\t" rnote[n] "\t" base(rrepo[n]) "\t" rbr[n] \
    "\t" rwt[n] "\t" rprn[n] "\t" rprs[n] "\t" rprc[n] "\t" rpru[n] "\t" rtitle[n] "\t" rrepo[n] "\t" rgrp[n]
}

function put(s, file) { if (file == "") print s; else print s > file }

function emit(view, file,   i, n, g, cur, last) {
  if (mode == "popup") put("h\th:\t-\t" GROUP "⌂" R " " BOLD "hub" R "  " GRAY "back to the full-screen dashboard" R "\t\t\t\t\t\t\t\t\t\t\t\t\t", file)
  cur = "\001"
  for (i = 1; i <= nr; i++) {
    n = idx[i]
    if (view != "tree") { put(line(n, display(n)), file); continue }
    g = rgrp[n]
    if (g != cur) {
      cur = g
      put("g\tg:" g "\t" g "\t" header(g) "\t\t\t\t\t\t\t\t\t\t\t\t\t" g, file)
    }
    if (g in C) continue
    last = (i == nr || rgrp[idx[i + 1]] != g)
    put(line(n, display_tree(n, last)), file)
  }
  put("n\tn:\t-\t" GROUP "+" R " " BOLD "new session" R "  " GRAY "category → repo → name" R "\t\t\t\t\t\t\t\t\t\t\t\t\t", file)
}

function summary(   k, s, out, total) { # the header: "agent-hub  ◐ 1 waiting  ● 2 working ..."
  out = GROUP "agent-hub" R
  for (k = 1; k <= 7; k++) {
    s = order[k]
    if (allst[s] > 0) { out = out "   " col[s] icon[s] " " allst[s] " " s R; total += allst[s] }
  }
  if (!total) out = out "   " GRAY "no agents yet · n: new session" R
  return out
}

function out(   i, j, n, k, tmp, task, view, also) {
  for (i = 1; i <= nr; i++) { idx[i] = i; key[i] = sortkey(i) }
  for (i = 2; i <= nr; i++) {
    tmp = idx[i]; k = key[tmp]; j = i - 1
    while (j > 0 && key[idx[j]] > k) { idx[j + 1] = idx[j]; j-- }
    idx[j + 1] = tmp
  }
  if (mode == "raw") {
    for (i = 1; i <= nr; i++) {
      n = idx[i]
      task = rname[n]; sub(/^[^\/]*\//, "", task)
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", rk[n], rgrp[n], task, rst[n], rsince[n], \
        base(rrepo[n]), rbr[n], rpane[n], rwin[n], rwt[n], (rpane[n] != "" ? "1" : "0"), rprn[n], rprs[n], rprc[n], rpru[n], rnote[n]
    }
  } else {
    wname = wtask = wrepo = wpr = 0
    for (i = 1; i <= nr; i++) {
      if (vlen(rname[i]) > wname) wname = vlen(rname[i])
      task = (rk[i] == "s") ? rname[i] : substr(rname[i], index(rname[i], "/") + 1)
      if (vlen(task) > wtask) wtask = vlen(task)
      if (rk[i] == "t" || rk[i] == "p") {
        if (vlen(base(rrepo[i])) > wrepo) wrepo = vlen(base(rrepo[i]))
        if (vlen(prplain(i)) > wpr) wpr = vlen(prplain(i))
        gcount[rgrp[i]]++; gst[rgrp[i], rst[i]]++; allst[rst[i]]++
      } else if (rk[i] == "s") gcount["*sessions"]++
    }
    if (ENVIRON["AH_SUMMARY"] != "") { print summary() > ENVIRON["AH_SUMMARY"]; close(ENVIRON["AH_SUMMARY"]) }
    view = (ENVIRON["AH_VIEW"] == "flat") ? "flat" : "tree"
    emit(view, "")
    also = ENVIRON["AH_ALSO"]
    if (also != "") { emit(view == "tree" ? "flat" : "tree", also); close(also) }
  }
  if (stalef != "") {
    for (k in STALE) print k > stalef
    close(stalef)
  }
}
