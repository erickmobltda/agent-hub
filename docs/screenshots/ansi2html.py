#!/usr/bin/env python3
"""ansi2html.py <capture.ans> <out.html> <title>: a tmux capture (capture-pane -p -e -N) drawn as a
terminal window (Catppuccin Mocha, as in Ghostty), one fixed-width cell per character."""
import html, re, sys

PAL = ["#45475a", "#f38ba8", "#a6e3a1", "#f9e2af", "#89b4fa", "#f5c2e7", "#94e2d5", "#a6adc8",
       "#585b70", "#f37799", "#89d88b", "#ebd391", "#74a8fc", "#f2aede", "#6bd7ca", "#bac2de"]
FG, BG = "#cdd6f4", "#1e1e2e"

def c256(n):
    if n < 16:
        return PAL[n]
    if n < 232:
        n -= 16
        v = lambda x: 0 if x == 0 else 55 + 40 * x
        return "#%02x%02x%02x" % (v(n // 36), v(n // 6 % 6), v(n % 6))
    g = 8 + 10 * (n - 232)
    return "#%02x%02x%02x" % (g, g, g)

def mix(a, b, t):  # a*(1-t) + b*t
    pa = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    pb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#%02x%02x%02x" % tuple(round(x * (1 - t) + y * t) for x, y in zip(pa, pb))

TOKEN = re.compile(r"\x1b\[([0-9;:]*)m|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[A-Za-z]|\x1b[()][0-9A-Za-z]|\x1b.")

def sgr(state, params):
    p = [int(x) if x else 0 for x in re.split(r"[;:]", params)] if params else [0]
    i = 0
    while i < len(p):
        n = p[i]
        if n == 0:
            state.clear()
        elif n == 1: state["b"] = 1
        elif n == 2: state["d"] = 1
        elif n == 3: state["i"] = 1
        elif n == 4: state["u"] = 1
        elif n == 7: state["r"] = 1
        elif n == 22: state.pop("b", None); state.pop("d", None)
        elif n == 23: state.pop("i", None)
        elif n == 24: state.pop("u", None)
        elif n == 27: state.pop("r", None)
        elif 30 <= n <= 37: state["fg"] = PAL[n - 30]
        elif 90 <= n <= 97: state["fg"] = PAL[n - 90 + 8]
        elif 40 <= n <= 47: state["bg"] = PAL[n - 40]
        elif 100 <= n <= 107: state["bg"] = PAL[n - 100 + 8]
        elif n == 39: state.pop("fg", None)
        elif n == 49: state.pop("bg", None)
        elif n in (38, 48) and i + 1 < len(p):
            key = "fg" if n == 38 else "bg"
            if p[i + 1] == 5 and i + 2 < len(p):
                state[key] = c256(p[i + 2]); i += 2
            elif p[i + 1] == 2 and i + 4 < len(p):
                state[key] = "#%02x%02x%02x" % tuple(p[i + 2:i + 5]); i += 4
        i += 1

def style(state):
    fg, bg = state.get("fg", FG), state.get("bg", BG)
    if state.get("r"):
        fg, bg = bg, fg
    if state.get("d"):
        fg = mix(fg, bg, 0.3)
    s = f"color:{fg};"
    if bg != BG:
        s += f"background:{bg};"
    if state.get("b"): s += "font-weight:700;"
    if state.get("i"): s += "font-style:italic;"
    if state.get("u"): s += "text-decoration:underline;"
    return s

def rows(text):
    state, out = {}, []
    for line in text.rstrip("\n").split("\n"):
        runs, pos = [], 0
        for m in TOKEN.finditer(line):
            if m.start() > pos:
                runs.append((style(state), line[pos:m.start()]))
            if m.group(0).endswith("m") and m.group(0).startswith("\x1b["):
                sgr(state, m.group(1))
            pos = m.end()
        if pos < len(line):
            runs.append((style(state), line[pos:]))
        out.append(runs)
    return out

def cell_html(st, text):
    parts, buf = [], ""
    for ch in text:
        if ord(ch) < 128:
            buf += ch
        else:
            if buf:
                parts.append(html.escape(buf)); buf = ""
            parts.append(f'<span class="w">{html.escape(ch)}</span>')
    if buf:
        parts.append(html.escape(buf))
    return f'<span style="{st}">{"".join(parts)}</span>'

src, dst, title = sys.argv[1], sys.argv[2], sys.argv[3]
body = "\n".join('<div class="row">' + "".join(cell_html(s, t) for s, t in r) + "</div>"
                 for r in rows(open(src, encoding="utf-8", errors="replace").read()))
open(dst, "w").write(f"""<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title><style>
html, body {{ margin: 0; background: transparent; }}
.frame {{ display: inline-block; padding: 28px; }}
.win {{ background: {BG}; border-radius: 12px; overflow: hidden; box-shadow: 0 0 0 1px #313244, 0 18px 50px rgba(0,0,0,.45); }}
.bar {{ height: 34px; background: #181825; position: relative; display: flex; align-items: center; padding-left: 14px; gap: 8px; }}
.dot {{ width: 12px; height: 12px; border-radius: 50%; }}
.title {{ position: absolute; left: 0; right: 0; text-align: center; color: #9399b2; font: 13px -apple-system, "Helvetica Neue", sans-serif; }}
.term {{ padding: 10px 12px 14px; font-family: "MesloLGS Nerd Font Mono", "MesloLGS NF", Menlo, monospace; font-size: 14px; color: {FG}; }}
.row {{ height: 18px; line-height: 18px; white-space: pre; }}
.row > span {{ display: inline-block; height: 18px; vertical-align: top; }}
.w {{ display: inline-block; width: 1ch; text-align: center; overflow: visible; }}
</style></head><body><div class="frame"><div class="win">
<div class="bar"><span class="dot" style="background:#ff5f57"></span><span class="dot" style="background:#febc2e"></span><span class="dot" style="background:#28c840"></span><div class="title">{html.escape(title)}</div></div>
<div class="term">{body}</div></div></div>
<script>const r = document.querySelector('.frame').getBoundingClientRect(); document.title = Math.ceil(r.width) + 'x' + Math.ceil(r.height);</script>
</body></html>""")
