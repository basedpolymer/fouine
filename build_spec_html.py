#!/usr/bin/env python3
"""SPEC.md -> spec.html : convertisseur Markdown ciblé + habillage typographique hors ligne.

Outil local de rendu autonome ne nécessitant aucun accès réseau ni dépendance externe.
"""
import re, html, sys, pathlib

_ROOT = pathlib.Path(__file__).resolve().parent
SRC = _ROOT / "SPEC.md"
OUT = _ROOT / "spec.html"

_head = SRC.read_text(encoding="utf-8")[:400]
_m = re.search(r"\*\*Version\*\*\s*([\d.]+)\s*·\s*\*\*Date\*\*\s*([\d-]+)", _head)
VERSION, VDATE = (_m.group(1), _m.group(2)) if _m else ("?", "?")

def inline(s):
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == '`':
            j = s.find('`', i + 1)
            if j > 0:
                out.append('<code>' + html.escape(s[i+1:j]) + '</code>'); i = j + 1; continue
        if s.startswith('**', i):
            j = s.find('**', i + 2)
            if j > 0:
                out.append('<strong>' + inline(s[i+2:j]) + '</strong>'); i = j + 2; continue
        if c == '[':
            m = re.match(r'\[([^\]]+)\]\(([^)]+)\)', s[i:])
            if m:
                out.append(f'<a href="{html.escape(m.group(2))}">{inline(m.group(1))}</a>')
                i += m.end(); continue
        out.append(html.escape(c)); i += 1
    return ''.join(out)

def cells(line):
    return [c.strip() for c in line.strip().strip('|').split('|')]

def build(md):
    lines = md.split('\n')
    body, toc = [], []
    i, n = 0, len(lines)
    while i < n:
        L = lines[i]

        if L.startswith('```'):
            j = i + 1
            buf = []
            while j < n and not lines[j].startswith('```'):
                buf.append(lines[j]); j += 1
            body.append('<div class="wide"><pre><code>' +
                        html.escape('\n'.join(buf)) + '</code></pre></div>')
            i = j + 1; continue

        if L.strip() == '---':
            body.append('<hr>'); i += 1; continue

        m = re.match(r'^(#{1,4})\s+(.*)$', L)
        if m:
            lvl, txt = len(m.group(1)), m.group(2)
            if lvl == 1:
                body.append(f'<h1>{inline(txt)}</h1>')
            else:
                num = ''
                mm = re.match(r'^(\d+(?:\.\d+)*)(?:\s*·\s*|\s+)(.*)$', txt)
                label = txt
                if mm:
                    num, label = mm.group(1), mm.group(2)
                if lvl == 2:
                    sid = 's' + (num.replace('.', '-') if num else str(len(toc)))
                    toc.append((sid, num, label))
                    body.append(f'<section id="{sid}"><h2>'
                                f'<span class="gut">{html.escape(num)}</span>'
                                f'<span>{inline(label)}</span></h2>')
                else:
                    tag = 'h3' if lvl == 3 else 'h4'
                    body.append(f'<{tag}><span class="gut sub">{html.escape(num)}</span>'
                                f'<span>{inline(label)}</span></{tag}>')
            i += 1; continue

        if L.startswith('|') and i + 1 < n and re.match(r'^\|[\s:|-]+\|$', lines[i+1]):
            head = cells(L)
            align = ['right' if c.endswith(':') and not c.startswith(':')
                     else 'center' if c.startswith(':') and c.endswith(':')
                     else 'left' for c in cells(lines[i+1])]
            j = i + 2; rows = []
            while j < n and lines[j].startswith('|'):
                rows.append(cells(lines[j])); j += 1
            t = ['<div class="wide"><table><thead><tr>']
            for k, h in enumerate(head):
                t.append(f'<th style="text-align:{align[k]}">{inline(h)}</th>')
            t.append('</tr></thead><tbody>')
            for r in rows:
                t.append('<tr>')
                for k, c in enumerate(r):
                    a = align[k] if k < len(align) else 'left'
                    t.append(f'<td style="text-align:{a}">{inline(c)}</td>')
                t.append('</tr>')
            t.append('</tbody></table></div>')
            body.append(''.join(t)); i = j; continue

        if re.match(r'^\s*[-*]\s+', L) or re.match(r'^\s*\d+\.\s+', L):
            ordered = bool(re.match(r'^\s*\d+\.\s+', L))
            tag = 'ol' if ordered else 'ul'
            items, j = [], i
            pat = r'^\s*\d+\.\s+' if ordered else r'^\s*[-*]\s+'
            while j < n and (re.match(pat, lines[j]) or
                             (lines[j].startswith('   ') and items and lines[j].strip())):
                if re.match(pat, lines[j]):
                    items.append(re.sub(pat, '', lines[j]))
                else:
                    items[-1] += ' ' + lines[j].strip()
                j += 1
            body.append(f'<{tag}>' + ''.join(f'<li>{inline(x)}</li>' for x in items) + f'</{tag}>')
            i = j; continue

        if L.strip() == '':
            i += 1; continue

        buf, j = [L], i + 1
        while j < n and lines[j].strip() and not re.match(
                r'^(#{1,4}\s|\||```|---$|\s*[-*]\s|\s*\d+\.\s)', lines[j]):
            buf.append(lines[j]); j += 1
        body.append('<p>' + inline(' '.join(buf)) + '</p>')
        i = j

    # fermer les sections ouvertes
    out = []
    opened = False
    for b in body:
        if b.startswith('<section'):
            if opened: out.append('</section>')
            opened = True
        out.append(b)
    if opened: out.append('</section>')
    return '\n'.join(out), toc

md = SRC.read_text(encoding='utf-8')
content, toc = build(md)
nav = '\n'.join(
    f'<a href="#{sid}"><span class="n">{html.escape(num)}</span>{html.escape(label)}</a>'
    for sid, num, label in toc)

CSS = """
<style>
:root{
  --ground:#f5f6f3; --surface:#fffffe; --sunk:#eceee8;
  --ink:#14181a; --muted:#5f6b6a; --faint:#8a938f;
  --rule:#dcdfd9; --rule-soft:#e6e8e2;
  --accent:#1f5d5a; --accent-soft:#e3ece9;
  --mark:rgba(236,217,106,.55); --warn:#9c4a1c;
  --measure:68ch;
  --f-display:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  --f-body:-apple-system-ui-serif,Georgia,"Times New Roman",serif;
  --f-mono:ui-monospace,"SF Mono",Menlo,Monaco,Consolas,monospace;
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --ground:#0f1213; --surface:#151a1b; --sunk:#191f20;
    --ink:#e6e9e5; --muted:#9aa5a2; --faint:#727c79;
    --rule:#262c2d; --rule-soft:#1f2526;
    --accent:#5fb8ae; --accent-soft:#17302e;
    --mark:rgba(214,190,74,.28); --warn:#d8865a;
  }
}
:root[data-theme="dark"]{
  --ground:#0f1213; --surface:#151a1b; --sunk:#191f20;
  --ink:#e6e9e5; --muted:#9aa5a2; --faint:#727c79;
  --rule:#262c2d; --rule-soft:#1f2526;
  --accent:#5fb8ae; --accent-soft:#17302e;
  --mark:rgba(214,190,74,.28); --warn:#d8865a;
}
*{box-sizing:border-box}
body{
  background:var(--ground); color:var(--ink);
  font-family:var(--f-body); font-size:16.5px; line-height:1.62;
  -webkit-font-smoothing:antialiased; margin:0;
}
.bar{
  position:sticky; top:0; z-index:20;
  display:flex; align-items:center; gap:.9rem;
  padding:.55rem clamp(1rem,4vw,3rem);
  background:color-mix(in srgb,var(--ground) 88%,transparent);
  backdrop-filter:blur(10px);
  border-bottom:1px solid var(--rule);
  font-family:var(--f-display); font-size:.8rem; letter-spacing:.02em;
}
.bar b{font-weight:700; letter-spacing:.06em; text-transform:uppercase; color:var(--accent)}
.bar span{color:var(--faint)}
.bar .sp{flex:1}
.bar button{
  font:inherit; font-size:.72rem; letter-spacing:.06em; text-transform:uppercase;
  background:none; border:1px solid var(--rule); color:var(--muted);
  border-radius:2px; padding:.25rem .6rem; cursor:pointer;
}
.bar button:hover{color:var(--accent); border-color:var(--accent)}
.bar button:focus-visible,a:focus-visible{outline:2px solid var(--accent); outline-offset:2px}

.shell{display:grid; grid-template-columns:15rem minmax(0,1fr); gap:clamp(1.5rem,4vw,4rem);
  max-width:78rem; margin:0 auto; padding:0 clamp(1rem,4vw,3rem) 6rem}
nav{position:sticky; top:3.2rem; align-self:start; max-height:calc(100vh - 5rem);
  overflow-y:auto; padding:2.4rem 0 2rem; font-family:var(--f-display); font-size:.79rem}
nav a{display:flex; gap:.6rem; padding:.28rem 0; color:var(--muted);
  text-decoration:none; line-height:1.35; border-left:2px solid transparent; padding-left:.7rem}
nav a:hover{color:var(--ink)}
nav a.on{color:var(--accent); border-left-color:var(--accent)}
nav .n{font-variant-numeric:tabular-nums; color:var(--faint); min-width:1.1rem}

main{padding-top:2.4rem; min-width:0; max-width:var(--measure)}
h1{font-family:var(--f-display); font-weight:700; font-size:clamp(2.1rem,5vw,3rem);
  line-height:1.05; letter-spacing:-.025em; margin:.4rem 0 1.2rem; text-wrap:balance}
h2{font-family:var(--f-display); font-weight:600; font-size:1.45rem; letter-spacing:-.015em;
  line-height:1.2; margin:0 0 1rem; display:flex; gap:.9rem; align-items:baseline; text-wrap:balance}
h3{font-family:var(--f-display); font-weight:600; font-size:1.03rem; letter-spacing:-.005em;
  margin:2.2rem 0 .7rem; display:flex; gap:.9rem; align-items:baseline; text-wrap:balance}
h4{font-family:var(--f-display); font-weight:600; font-size:.83rem; letter-spacing:.06em;
  text-transform:uppercase; color:var(--muted); margin:1.9rem 0 .6rem;
  display:flex; gap:.9rem; align-items:baseline}
h4 .gut{color:var(--accent); font-size:.78rem; letter-spacing:0}
.gut{font-family:var(--f-mono); font-size:.82rem; font-weight:500; color:var(--accent);
  font-variant-numeric:tabular-nums; flex:none; min-width:1.6rem}
.gut.sub{font-size:.72rem; color:var(--faint); min-width:2.1rem}
section{padding:2.6rem 0 .6rem; border-top:1px solid var(--rule-soft)}
section:first-of-type{border-top:none}
p{margin:0 0 1rem}
main>p:first-of-type{color:var(--muted)}
strong{font-weight:600; background:linear-gradient(to top,var(--mark) 0,var(--mark) .42em,transparent .42em);
  padding:0 .06em}
table strong,th strong,li strong{background:none; padding:0}
a{color:var(--accent); text-decoration-thickness:1px; text-underline-offset:2px}
hr{border:none; border-top:1px solid var(--rule); margin:2.4rem 0}
ul,ol{margin:0 0 1.1rem; padding-left:1.3rem}
li{margin:.34rem 0}
li::marker{color:var(--faint); font-family:var(--f-mono); font-size:.85em}
code{font-family:var(--f-mono); font-size:.855em; background:var(--sunk);
  border:1px solid var(--rule-soft); border-radius:2px; padding:.06em .3em}
.wide{max-width:min(52rem,calc(100vw - 2rem)); overflow-x:auto; margin:0 0 1.4rem}
pre{margin:0; background:var(--surface); border:1px solid var(--rule);
  border-left:2px solid var(--accent); border-radius:2px;
  padding:1rem 1.1rem; overflow-x:auto; line-height:1.5}
pre code{background:none; border:none; padding:0; font-size:.79rem; white-space:pre}
table{border-collapse:collapse; width:100%; font-size:.86rem; font-family:var(--f-display);
  font-weight:500; font-variant-numeric:tabular-nums}
th{font-weight:600; font-size:.71rem; letter-spacing:.07em; text-transform:uppercase;
  color:var(--muted); border-bottom:1px solid var(--ink); padding:.5rem .7rem; white-space:nowrap}
td{border-bottom:1px solid var(--rule-soft); padding:.5rem .7rem; vertical-align:top}
tbody tr:hover{background:var(--accent-soft)}
td code{font-size:.8em}
#s7 li::marker{color:var(--warn)}
@media (max-width:900px){
  .shell{grid-template-columns:1fr}
  nav{position:static; max-height:none; padding:1.4rem 0 0; display:flex; flex-wrap:wrap;
    gap:.1rem .4rem; border-bottom:1px solid var(--rule); padding-bottom:1rem}
  nav a{border-left:none; padding-left:0}
  nav a.on{border-left:none; text-decoration:underline}
  main{max-width:none}
}
@media (prefers-reduced-motion:reduce){*{animation:none!important; transition:none!important}}
</style>
"""

JS = """
<script>
(function(){
  var root=document.documentElement, b=document.getElementById('theme');
  b.addEventListener('click',function(){
    var d=getComputedStyle(root).getPropertyValue('--ground').trim().indexOf('#0f')===0;
    root.setAttribute('data-theme', d?'light':'dark');
  });
  var links=[].slice.call(document.querySelectorAll('nav a')),
      secs=links.map(function(a){return document.querySelector(a.getAttribute('href'));});
  var io=new IntersectionObserver(function(es){
    es.forEach(function(e){
      if(!e.isIntersecting) return;
      var i=secs.indexOf(e.target);
      links.forEach(function(a,k){a.classList.toggle('on',k===i);});
    });
  },{rootMargin:'-12% 0px -80% 0px'});
  secs.forEach(function(s){if(s) io.observe(s);});
})();
</script>
"""

OUT.write_text(
    "<title>Fouine</title>\n" + CSS +
    f'<div class="bar"><b>Fouine</b><span>spécifications d\'implémentation · v{VERSION} · {VDATE}</span>'
    '<span class="sp"></span><button id="theme">thème</button></div>\n'
    '<div class="shell">\n<nav>' + nav + '</nav>\n<main>' + content + '</main>\n</div>\n' + JS,
    encoding='utf-8')
print(f"écrit {OUT} — {OUT.stat().st_size/1024:.0f} Ko, {len(toc)} sections")
