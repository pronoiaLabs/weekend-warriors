#!/usr/bin/env python3
"""Render FIX-PLAN.md into a single self-contained FIX-PLAN.html.

FIX-PLAN.md is the source of truth. The .html is a build artifact: never hand-edit
it, run `make plan` instead.

The output is one file with the CSS and JS inlined, so it works over file:// with no
network. Nothing in here emits a timestamp, so two runs over an unchanged .md produce
byte-identical output.

Heading model
-------------
The .md is not a clean depth-based tree, so headings are classified by pattern:

    # Title                      document title; prose before the first ## is Overview
    ## Group A: ...              a sidebar group, if it has coded ### children
    ## Deferred: ...             a nav leaf in its own right, if it has none
    ### A1. Some title           a nav leaf, code "A1"
    ### Some title               NO code prefix, so folded into the preceding leaf
    #### Some title              in-page subsection, scroll-spy target

The "### with no code" case is real: `### Makefile changes that were not a straight
rename` is structurally a child of A1 but was written as its sibling.
"""

from __future__ import annotations

import hashlib
import html
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from markdown_it import MarkdownIt
from pygments import highlight
from pygments.formatters import HtmlFormatter
from pygments.lexers import get_lexer_by_name
from pygments.util import ClassNotFound

ROOT = Path(__file__).resolve().parent.parent
ASSETS = Path(__file__).resolve().parent / "plan_assets"
SOURCE = ROOT / "FIX-PLAN.md"
OUTPUT = ROOT / "FIX-PLAN.html"

# "A1. Rename the run targets" -> code A1. Also matches a hypothetical D1, so new
# groups do not need a code change here.
LEAF_CODE = re.compile(r"^([A-Z]\d+)\.\s*")
TASK_MARKER = re.compile(r"^\[([ xX])\]\s+")


# --------------------------------------------------------------------------- model


@dataclass
class Leaf:
    """One sidebar entry and the panel it opens."""

    ident: str
    code: str
    title_html: str
    title_text: str
    group: str | None
    tokens: list = field(default_factory=list)
    subs: list = field(default_factory=list)  # [(id, text)]
    body: str = ""
    text: str = ""
    tasks: int = 0
    done: int = 0


def slugify(text: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")
    return s or "section"


# ------------------------------------------------------------------------- parsing


def classify(tokens: list) -> tuple[str, list[Leaf]]:
    """Split the token stream into leaves, resolving the heading irregularities."""
    heads = []  # (index, tag, inline_token)
    for i, tok in enumerate(tokens):
        if tok.type == "heading_open" and tok.tag in ("h1", "h2", "h3"):
            heads.append((i, tok.tag, tokens[i + 1]))

    # An h2 is a group when a coded h3 appears before the next h2/h1.
    is_group = {}
    for n, (idx, tag, _) in enumerate(heads):
        if tag != "h2":
            continue
        grouped = False
        for idx2, tag2, inline2 in heads[n + 1 :]:
            if tag2 in ("h1", "h2"):
                break
            if tag2 == "h3" and LEAF_CODE.match(inline2.content):
                grouped = True
                break
        is_group[idx] = grouped

    # Boundaries: h1, every h2, and every coded h3. Uncoded h3s stay as content.
    bounds = []
    for idx, tag, inline in heads:
        if tag in ("h1", "h2") or LEAF_CODE.match(inline.content):
            bounds.append((idx, tag, inline))

    doc_title = ""
    leaves: list[Leaf] = []
    group_label: str | None = None
    pending_intro: list = []

    for n, (idx, tag, inline) in enumerate(bounds):
        stop = bounds[n + 1][0] if n + 1 < len(bounds) else len(tokens)
        body = trim_rules(tokens[idx + 3 : stop])

        if tag == "h1":
            doc_title = inline.content
            leaves.append(
                Leaf(
                    ident="overview",
                    code="Doc",
                    title_html="Overview",
                    title_text="Overview",
                    group=None,
                    tokens=body,
                )
            )
            continue

        if tag == "h2" and is_group[idx]:
            group_label = inline.content
            pending_intro = body
            continue

        code = ""
        title_html = render_inline(inline)
        title_text = inline.content
        if tag == "h3":
            m = LEAF_CODE.match(inline.content)
            code = m.group(1)
            title_text = inline.content[m.end() :]
            title_html = strip_code_prefix(inline, m.end())
            ident = code.lower()
            group = group_label
        else:
            # A leaf-level h2 such as "Deferred: first deploy". It has no code of
            # its own, and inventing one from the title only ever truncates badly.
            ident = slugify(inline.content)
            code = ""
            group = None

        leaves.append(
            Leaf(
                ident=ident,
                code=code,
                title_html=title_html,
                title_text=title_text,
                group=group,
                tokens=pending_intro + body,
            )
        )
        pending_intro = []

    return doc_title, leaves


def trim_rules(toks: list) -> list:
    """Drop `---` separators stranded at the edges of a slice."""
    out = list(toks)
    while out and out[0].type == "hr":
        out.pop(0)
    while out and out[-1].type == "hr":
        out.pop()
    return out


def strip_code_prefix(inline, cut: int) -> str:
    """Render a heading inline with its `A1.` prefix removed."""
    children = [t for t in inline.children or []]
    if children and children[0].type == "text":
        clone = children[0].copy()
        clone.content = children[0].content[cut:]
        children = [clone] + children[1:]
    return MD.renderer.renderInline(children, MD.options, {}).strip()


def render_inline(inline) -> str:
    return MD.renderer.renderInline(inline.children or [], MD.options, {}).strip()


# ------------------------------------------------------------------- token rewrite


def prepare(leaf: Leaf) -> None:
    """Annotate a leaf's tokens: subsection ids, task checkboxes."""
    seen: dict[str, int] = {}
    i = 0
    toks = leaf.tokens

    while i < len(toks):
        tok = toks[i]

        # Any h3/h4 left inside a leaf is a subsection heading.
        if tok.type == "heading_open" and tok.tag in ("h3", "h4"):
            text = toks[i + 1].content
            base = f"{leaf.ident}-{slugify(text)}"
            seen[base] = seen.get(base, 0) + 1
            ident = base if seen[base] == 1 else f"{base}-{seen[base]}"
            tok.tag = "h3"
            toks[i + 2].tag = "h3"
            tok.attrSet("id", ident)
            tok.attrSet("class", "sub")
            leaf.subs.append((ident, text))

        elif tok.type == "list_item_open":
            j = i + 1
            while j < len(toks) and toks[j].type == "paragraph_open":
                j += 1
            if j < len(toks) and toks[j].type == "inline":
                m = TASK_MARKER.match(toks[j].content)
                if m:
                    make_task(leaf, toks, i, j, m)

        i += 1


def make_task(leaf: Leaf, toks: list, open_idx: int, inline_idx: int, m) -> None:
    """Turn `- [x] text` into a real checkbox, and mark the matching </li>."""
    inline = toks[inline_idx]
    checked = m.group(1).lower() == "x"

    inline.content = inline.content[m.end() :]
    if inline.children and inline.children[0].type == "text":
        inline.children[0].content = TASK_MARKER.sub("", inline.children[0].content, count=1)

    leaf.tasks += 1
    leaf.done += int(checked)
    ident = f"{leaf.ident}-{leaf.tasks}"
    # Signature over the task text. If the wording changes in the .md, saved
    # browser state for this id is discarded rather than shown as stale.
    sig = hashlib.sha1(inline.content.strip().encode()).hexdigest()[:8]
    meta = {"task": True, "id": ident, "sig": sig, "checked": checked}
    toks[open_idx].meta.update(meta)

    # A <p> inside a <label> is invalid, so force loose-list paragraphs hidden.
    nest = 0
    for k in range(open_idx + 1, len(toks)):
        t = toks[k]
        if t.type == "list_item_open":
            nest += 1
        elif t.type == "list_item_close":
            if nest == 0:
                t.meta.update(meta)
                break
            nest -= 1
        elif nest == 0 and t.type in ("paragraph_open", "paragraph_close"):
            t.hidden = True


# ------------------------------------------------------------------------ renderer


def render_diff(raw: str) -> str:
    rows = []
    for line in raw.rstrip("\n").split("\n"):
        if line.startswith(("+++", "---", "@@")):
            cls = "meta"
        elif line.startswith("+"):
            cls = "add"
        elif line.startswith("-"):
            cls = "del"
        else:
            cls = "ctx"
        rows.append(f'<span class="l {cls}">{html.escape(line)}</span>')
    return "".join(rows)


def rule_fence(tokens, idx, options, env):
    tok = tokens[idx]
    info = (tok.info or "").strip()
    lang = info.split()[0] if info else ""
    raw = tok.content

    if lang == "diff":
        body = render_diff(raw)
    elif lang:
        try:
            lexer = get_lexer_by_name(lang)
        except ClassNotFound:
            lexer = None
        body = (
            highlight(raw, lexer, HtmlFormatter(nowrap=True)).rstrip("\n")
            if lexer
            else html.escape(raw.rstrip("\n"))
        )
    else:
        body = html.escape(raw.rstrip("\n"))

    label = f'<span class="codelang">{html.escape(lang)}</span>' if lang else ""
    cls = "code diff" if lang == "diff" else "code"
    return (
        f'<div class="{cls}">{label}'
        f'<button class="copy" type="button" aria-label="Copy code">Copy</button>'
        f"<pre><code>{body}</code></pre></div>\n"
    )


def rule_table_open(tokens, idx, options, env):
    return '<div class="tablewrap"><table>\n'


def rule_table_close(tokens, idx, options, env):
    return "</table></div>\n"


def rule_item_open(tokens, idx, options, env):
    meta = tokens[idx].meta
    if not meta.get("task"):
        return "<li>"
    checked = " checked" if meta["checked"] else ""
    return (
        f'<li class="task"><input type="checkbox" class="tbox" id="{meta["id"]}" '
        f'data-sig="{meta["sig"]}"{checked}>'
        f'<label class="tbody" for="{meta["id"]}">'
    )


def rule_item_close(tokens, idx, options, env):
    return "</label></li>\n" if tokens[idx].meta.get("task") else "</li>\n"


# commonmark plus the two GFM rules the doc actually uses. The full "gfm-like"
# preset would also turn on linkify, which needs linkify-it-py; the doc writes its
# links explicitly, so that is a dependency for nothing.
#
# "code" is the indented-code-block rule, and it is disabled deliberately. Every one
# of the doc's 53 real code blocks is fenced, while continuation prose under a task
# item is routinely indented past the 4-space threshold (FIX-PLAN.md:658 is a
# paragraph plus a table written that way). Leaving the rule on renders that prose
# as code.
MD = MarkdownIt("commonmark").enable(["table", "strikethrough"]).disable(["code"])
MD.renderer.rules["fence"] = rule_fence
MD.renderer.rules["table_open"] = rule_table_open
MD.renderer.rules["table_close"] = rule_table_close
MD.renderer.rules["list_item_open"] = rule_item_open
MD.renderer.rules["list_item_close"] = rule_item_close


# --------------------------------------------------------------------------- build


TAGS = re.compile(r"<[^>]+>")
WS = re.compile(r"\s+")


def plain(markup: str) -> str:
    """Searchable text for a panel, code included."""
    return WS.sub(" ", html.unescape(TAGS.sub(" ", markup))).strip()


def pygments_css() -> str:
    """Light + dark highlight rules, scoped to the theme selectors."""

    def defs(style: str, selector: str) -> str:
        raw = HtmlFormatter(style=style).get_style_defs(selector)
        # Drop the container rule; the code card supplies its own background.
        keep = [ln for ln in raw.split("\n") if "background" not in ln or " ." in ln.split("{")[0]]
        return "\n".join(keep)

    light = defs("default", ".code pre code")
    dark_explicit = defs("native", ':root[data-theme="dark"] .code pre code')
    dark_system = defs("native", ":root:not([data-theme]) .code pre code")
    return (
        f"{light}\n{dark_explicit}\n"
        f"@media (prefers-color-scheme: dark){{\n{dark_system}\n}}\n"
    )


def sidebar(leaves: list[Leaf]) -> str:
    out = ['<nav class="side" id="side">']
    current: str | None = "\x00"
    for leaf in leaves:
        if leaf.group != current:
            if current != "\x00":
                out.append("</div>")
            current = leaf.group
            if leaf.group:
                out.append('<div class="navgroup">')
                out.append(
                    f'<div class="grouphead"><span class="groupname">'
                    f"{html.escape(leaf.group)}</span>"
                    f'<span class="groupcount" data-group="{html.escape(leaf.group)}"></span>'
                    f"</div>"
                )
            else:
                out.append('<div class="navgroup">')
        subs = "".join(
            f'<a class="subitem" href="#{sid}" data-sub="{sid}">{html.escape(stext)}</a>'
            for sid, stext in leaf.subs
        )
        out.append(
            f'<div class="navrow" data-leaf="{leaf.ident}">'
            f'<button class="navitem" type="button" data-target="{leaf.ident}">'
            f'<span class="navcode">{html.escape(leaf.code)}</span>'
            f'<span class="navlabel">{leaf.title_html}</span>'
            f'<span class="dot" data-dot="{leaf.ident}"></span>'
            f"</button>"
            f'<div class="subitems">{subs}</div>'
            f"</div>"
        )
    out.append("</div></nav>")
    return "\n".join(out)


def sections(leaves: list[Leaf]) -> str:
    out = []
    for leaf in leaves:
        counter = (
            f'<span class="counts" data-count="{leaf.ident}"></span>' if leaf.tasks else ""
        )
        badge = f'<span class="hcode">{html.escape(leaf.code)}</span> ' if leaf.code else ""
        out.append(
            f'<section class="section" id="{leaf.ident}" data-tasks="{leaf.tasks}">'
            f'<header class="sechead">'
            f'<div class="eyebrow">{html.escape(leaf.group or "")}</div>'
            f"<h1>{badge}{leaf.title_html}</h1>"
            f"{counter}</header>"
            f'<div class="body">{leaf.body}</div>'
            f"</section>"
        )
    return "\n".join(out)


def build() -> None:
    if not SOURCE.exists():
        sys.exit(f"missing {SOURCE}")

    text = SOURCE.read_text(encoding="utf-8")
    doc_title, leaves = classify(MD.parse(text))

    for leaf in leaves:
        prepare(leaf)
        leaf.body = MD.renderer.render(leaf.tokens, MD.options, {})
        leaf.text = plain(f"{leaf.title_text} {leaf.body}")

    index = [
        {
            "id": lf.ident,
            "code": lf.code,
            "title": lf.title_text or "Overview",
            "group": lf.group or "",
            "text": lf.text.lower(),
        }
        for lf in leaves
    ]

    css = (ASSETS / "plan.css").read_text(encoding="utf-8")
    js = (ASSETS / "plan.js").read_text(encoding="utf-8")
    total = sum(lf.tasks for lf in leaves)

    page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(doc_title)}</title>
<style>
{css}
{pygments_css()}</style>
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<header class="rail">
  <div class="brand">
    <span class="brandname">{html.escape(doc_title)}</span>
    <span class="brandmeta"><span id="progtext"></span></span>
  </div>
  <div class="bar"><div class="barfill" id="barfill"></div></div>
  <div class="tools">
    <input type="search" id="search" placeholder="Search the plan" aria-label="Search the plan"
           autocomplete="off" spellcheck="false">
    <button type="button" id="theme" class="iconbtn" aria-label="Toggle theme"></button>
  </div>
  <div class="hint" id="hint"></div>
{sidebar(leaves)}
  <div class="railfoot">
    <button type="button" id="reset" class="linkbtn">Reset to file state</button>
  </div>
</header>
<main id="main">
{sections(leaves)}
</main>
<script>
var PLAN_INDEX = {json.dumps(index, separators=(",", ":"))};
var PLAN_TOTAL = {total};
{js}</script>
</body>
</html>
"""
    OUTPUT.write_text(page, encoding="utf-8")
    print(
        f"{OUTPUT.name}: {len(leaves)} sections, {total} tasks, {len(page) // 1024}KB",
        file=sys.stderr,
    )


if __name__ == "__main__":
    build()
