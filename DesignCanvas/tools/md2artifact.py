#!/usr/bin/env python3
"""Render a spec markdown file as the HTML page published to its Claude artifact.

    python3 DesignCanvas/tools/md2artifact.py prd  out/design-canvas-prd.html
    python3 DesignCanvas/tools/md2artifact.py tech out/design-canvas-tech-spec.html

The page's shared styles live in artifact-head.html beside this script; the PRD and the
technical spec use the same head so the two pages look alike. Publish the output to the
artifact URL recorded for the doc in DesignCanvas/context-graph.json.

Handles the markdown these two docs actually use: `#`/`##`/`###` headings (numbered `##`
become the sidebar contents), paragraphs, `-` and `1.` lists with one level of `  - `
nesting, `[ ]` task boxes, pipe tables, fenced code, inline code, links, bold and
underscore italics, and the `**Status/Owner/Sources:**` lines before the first `##`,
which become the header. Anything else passes through as a paragraph.
"""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
DOCS = {
    "prd": ("DesignCanvas/spec/PRD-DesignCanvas.md", "Design Canvas PRD", "Product requirements"),
    "tech": ("DesignCanvas/spec/technical_doc.md", "Design Canvas Technical Spec", "Technical specification"),
    "mac-ia": ("DesignCanvas/spec/mac-app-ia.md", "Design Canvas Mac App IA", "Mac app information architecture"),
}


def inline(t):
    t = html.escape(t, quote=False)
    codes = []

    def stash(m):
        codes.append(m.group(1))
        return f"\x00{len(codes) - 1}\x00"

    t = re.sub(r"`([^`]+)`", stash, t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    t = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<!\w)_(.+?)_(?!\w)", r"<em>\1</em>", t)
    return re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{codes[int(m.group(1))]}</code>", t)


def cells(line):
    return [c.strip() for c in line.strip().strip("|").split("|")]


def render(lines):
    body, toc, meta = [], [], []
    i, n, seen_h2 = 0, len(lines), False
    while i < n:
        l = lines[i]
        if not l.strip() or l.startswith("# "):
            i += 1
            continue
        m = re.match(r"\*\*(Status|Owner|Sources):\*\*\s*(.*)", l)
        if m and not seen_h2:
            meta.append((m.group(1), m.group(2)))
            i += 1
            continue
        if l.startswith("```"):
            i += 1
            buf = []
            while not lines[i].startswith("```"):
                buf.append(lines[i])
                i += 1
            i += 1
            body.append("<pre>" + html.escape("\n".join(buf), quote=False) + "</pre>")
            continue
        if l.startswith("## "):
            seen_h2 = True
            t = l[3:].strip()
            m = re.match(r"(\d+)\.\s+(.*)", t)
            if m:
                num, txt, hid = m.group(1), m.group(2), "s" + m.group(1)
            else:
                num, txt, hid = "R", t.title().replace("Gstack", "gstack"), "review-report"
            toc.append((hid, num, txt))
            body.append(f'<h2 id="{hid}"><span class="n">{num}</span>{inline(txt)}</h2>')
            i += 1
            continue
        if l.startswith("### "):
            body.append(f"<h3>{inline(l[4:].strip())}</h3>")
            i += 1
            continue
        if l.lstrip().startswith("|"):
            rows = []
            while i < n and lines[i].lstrip().startswith("|"):
                rows.append(cells(lines[i]))
                i += 1
            hdr, data = rows[0], rows[2:]
            h = '<div class="table-wrap"><table><thead><tr>' + "".join(f"<th>{inline(c)}</th>" for c in hdr) + "</tr></thead><tbody>"
            for r in data:
                h += "<tr>" + "".join(
                    (f'<td class="id">{inline(c)}</td>' if k == 0 and re.fullmatch(r"[A-Z]\d+", c) else f"<td>{inline(c)}</td>")
                    for k, c in enumerate(r)
                ) + "</tr>"
            body.append(h + "</tbody></table></div>")
            continue
        if re.match(r"(- |\d+\. )", l):
            ordered = bool(re.match(r"\d+\. ", l))
            items = []
            while i < n and lines[i].strip():
                x = lines[i]
                if re.match(r"(- |\d+\. )", x):
                    items.append([re.sub(r"^(- |\d+\. )", "", x), []])
                elif re.match(r"\s+- ", x):
                    items[-1][1].append(x.strip()[2:])
                elif x.startswith(" "):
                    items[-1][0] += " " + x.strip()
                else:
                    break
                i += 1
            tag = 'ol class="flow"' if ordered else "ul"
            h = f"<{tag}>"
            for t, sub in items:
                t = re.sub(r"^\[ \] ", '<span class="box" aria-hidden="true"></span>', inline(t)) if t.startswith("[ ] ") else inline(t)
                inner = f"<div>{t}</div>" if ordered else t
                if sub:
                    inner += "<ul>" + "".join(f"<li>{inline(s)}</li>" for s in sub) + "</ul>"
                h += f"<li>{inner}</li>"
            body.append(h + f"</{tag.split()[0]}>")
            continue
        buf = []
        while i < n and lines[i].strip() and not re.match(r"(#|```|\||- |\d+\. )", lines[i]):
            buf.append(lines[i].strip())
            i += 1
        body.append("<p>" + inline(" ".join(buf)) + "</p>")
    return body, toc, meta


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in DOCS:
        sys.exit(__doc__)
    src, title, kind = DOCS[sys.argv[1]]
    out = sys.argv[2]
    head = open(os.path.join(HERE, "artifact-head.html")).read().rstrip("\n")
    lines = open(os.path.join(REPO, src)).read().split("\n")
    body, toc, meta = render(lines)

    status = dict(meta).get("Status", "")
    v = re.search(r"Draft (v[\d.]+), (\d{4}-\d\d-\d\d)", status)
    eyebrow = f"{kind} · Draft {v.group(1)} · {v.group(2)}" if v else kind
    dl = "".join(f"<dt>{k}</dt><dd>{inline(val)}</dd>" for k, val in meta)
    tochtml = "".join(f'<li><a href="#{h}"><span class="n">{num}</span>{html.escape(t, quote=False)}</a></li>' for h, num, t in toc)
    page = (
        f"<title>{title}</title>\n{head}\n"
        '<div class="wrap">\n'
        f'<nav class="toc" aria-label="Sections"><div class="eyebrow">Contents</div><ol>{tochtml}</ol></nav>\n'
        "<main>\n"
        f'<header class="doc"><div class="eyebrow">{eyebrow}</div><h1>Design Canvas</h1><dl class="meta">{dl}</dl></header>\n'
        + "\n".join(body)
        + "\n</main>\n</div>\n"
    )
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    open(out, "w").write(page)
    print(f"{out}: {len(page)} bytes, {len(toc)} sections, {len(body)} blocks")


if __name__ == "__main__":
    main()
