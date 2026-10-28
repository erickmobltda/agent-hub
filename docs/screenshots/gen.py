#!/usr/bin/env python3
"""gen.py <dir>: the fake data of the screenshot demo. Each task's Claude screen (<dir>/screens/
<group>__<task>.ans, ANSI) and terminal title (.title), and each repo's pull requests as
`gh pr list --json` returns them (<dir>/prs/<repo>.json)."""
import json
import os
import re
import sys

out = sys.argv[1]
os.makedirs(f"{out}/screens", exist_ok=True)
os.makedirs(f"{out}/prs", exist_ok=True)

E = "\x1b["
R = E + "0m"
GRAY, BOLD = E + "38;5;245m", E + "1m"
ORANGE, GREEN, RED, BLUE = E + "38;5;173m", E + "32m", E + "31m", E + "38;5;111m"


def you(text):  # the user's prompt
    return [f"{GRAY}>{R} {text}", ""]


def say(first, *rest):  # Claude's text
    return [f"⏺ {first}"] + [f"  {line}" for line in rest] + [""]


def tool(name, arg, result=None):
    lines = [f"{GREEN}⏺{R} {BOLD}{name}{R}({arg})"]
    if result:
        lines.append(f"  {GRAY}⎿  {result}{R}")
    return lines + [""]


def spinner(verb, elapsed, tokens):
    return [f"{ORANGE}✻ {verb}…{R} {GRAY}({elapsed} · ↓ {tokens} tokens · esc to interrupt){R}", ""]


def prompt_box(mode=None):
    bar = GRAY + "─" * 84 + R
    lines = [bar, f"{ORANGE}❯{R} ", bar]
    return lines + ([f"  {GRAY}{mode}{R}"] if mode else [])


def boxed(rows, width=76):  # Claude's permission dialog
    plain = lambda s: re.sub(r"\x1b\[[0-9;]*m", "", s)
    lines = [f"{ORANGE}╭{'─' * width}╮{R}"]
    for row in rows:
        lines.append(f"{ORANGE}│{R} {row}{' ' * (width - 1 - len(plain(row)))}{ORANGE}│{R}")
    return lines + [f"{ORANGE}╰{'─' * width}╯{R}"]


screens = {
    "payments/PAY-412-refund-webhook": (
        "✳ Refund webhook idempotency",
        you("The refund webhook double-refunds when Stripe retries an event. Make it idempotent.")
        + say("I'll look at how refund events are processed first.")
        + tool("Read", "src/webhooks/refund.ts", "Read 142 lines")
        + say("The handler refunds before it records the event id, so a retry runs it again.",
              "I'll store the event id first and skip events that were already seen.")
        + tool("Update", "src/webhooks/refund.ts", "Updated src/webhooks/refund.ts with 14 additions and 3 removals")
        + tool("Bash", "npm test -- webhooks/refund")
        + boxed([f"{BOLD}Bash command{R}", "",
                 "  npm test -- webhooks/refund", f"  {GRAY}Run the refund webhook tests{R}", "",
                 "Do you want to proceed?",
                 f"{ORANGE}❯{R} {ORANGE}1. Yes{R}",
                 "  2. Yes, and don't ask again for npm test commands in this project",
                 f"  3. No, and tell Claude what to do differently {GRAY}(esc){R}"]),
    ),
    "payments/PAY-398-retry-queue": (
        "⠂ Payout retry queue",
        you("Failed payouts should be retried with exponential backoff, at most 5 attempts.")
        + say("I'll add a retry queue with backoff on top of the existing job runner.")
        + tool("Write", "src/queue/retry.ts", "Wrote 86 lines to src/queue/retry.ts")
        + tool("Update", "src/payouts/worker.ts", "Updated src/payouts/worker.ts with 9 additions and 2 removals")
        + tool("Bash", "npm test -- queue", "Running…")
        + spinner("Running tests", "1m 12s", "3.1k")
        + prompt_box("⏵⏵ accept edits on (shift+tab to cycle)"),
    ),
    "payments/PAY-377-currency-rounding": (
        "✳ Currency rounding",
        you("Amounts in JPY get rounded to cents. Fix the rounding for every currency.")
        + say("Fixed: zero-decimal currencies (JPY, KRW, CLP) now round to their own minor unit.",
              "",
              f"• {BOLD}src/money/round.ts{R}: the minor unit comes from ISO 4217, not a fixed 2",
              f"• {BOLD}src/money/round.test.ts{R}: 18 new cases, every 0- and 3-decimal currency",
              f"• {GREEN}npm test: 412 passed{R}",
              "",
              f"Opened PR #121: {BLUE}Round by each currency's minor unit{R}")
        + prompt_box(),
    ),
    "mobile/MOB-88-dark-mode": (
        "⠐ Dark mode toggle",
        you("Add a dark mode toggle to Settings. It should follow the system by default.")
        + say("I'll add a theme preference with three options: System, Light and Dark.")
        + tool("Update", "src/settings/SettingsScreen.tsx", "Updated with 31 additions and 4 removals")
        + tool("Write", "src/theme/useThemePreference.ts", "Wrote 44 lines")
        + spinner("Updating screens to use the theme", "3m 41s", "8.7k")
        + prompt_box(),
    ),
    "mobile/MOB-91-crash-on-logout": (
        "✳ Crash on logout",
        you("The app crashes on logout on Android 14. Stack trace is in crash.log.")
        + say("The crash comes from a push-token request that finishes after the session is gone.")
        + tool("Update", "src/auth/logout.ts", "Updated with 6 additions and 1 removal")
        + [f"  {RED}⎿  API Error: 529 {{\"type\":\"error\",\"error\":{{\"type\":\"overloaded_error\"}}}}{R}", ""]
        + prompt_box(),
    ),
    "platform/upgrade-node-22": (
        "✳ Node 22 upgrade",
        you("Upgrade the CI images and the Dockerfiles to Node 22.")
        + say("Done. CI, the three Dockerfiles and .nvmrc now use Node 22; PR #54 is merged.")
        + prompt_box(),
    ),
}

for name, (title, lines) in screens.items():
    base = f"{out}/screens/{name.replace('/', '__')}"
    with open(base + ".ans", "w") as f:
        f.write("\n".join(lines) + "\n")
    with open(base + ".title", "w") as f:
        f.write(title)


def pr(branch, number, state, checks, repo, draft=False):
    rollup = {"pass": [{"status": "COMPLETED", "conclusion": "SUCCESS"}],
              "fail": [{"status": "COMPLETED", "conclusion": "FAILURE"}],
              "pending": [{"status": "IN_PROGRESS", "conclusion": None}], "": []}[checks]
    return {"headRefName": f"feat/{branch}", "number": number, "state": state, "isDraft": draft,
            "statusCheckRollup": rollup, "url": f"https://github.com/acme/{repo}/pull/{number}"}


prs = {
    "payments-api": [pr("PAY-398-retry-queue", 127, "OPEN", "pending", "payments-api"),
                     pr("PAY-377-currency-rounding", 121, "OPEN", "pass", "payments-api")],
    "mobile-app": [pr("MOB-91-crash-on-logout", 64, "OPEN", "fail", "mobile-app")],
    "infra": [pr("upgrade-node-22", 54, "MERGED", "pass", "infra"),
              pr("terraform-drift", 57, "OPEN", "", "infra", draft=True)],
}
for repo, items in prs.items():
    with open(f"{out}/prs/{repo}.json", "w") as f:
        json.dump(items, f)
