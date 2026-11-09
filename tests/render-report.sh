#!/usr/bin/env bash
# render-report writes a self-contained HTML page beside a report's Markdown.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
# check DESC CMD... — run CMD; on failure print FAIL: DESC.
check() { local d="$1"; shift; if ! "$@"; then echo "FAIL: $d"; fail=1; fi; }
# shellcheck disable=SC2329  # helpers below run through check
not() { ! "$@"; }
# shellcheck disable=SC2329
last_line_is() { [ "$(tail -1 "$1")" = "$2" ]; }
# shellcheck disable=SC2329
is_base64() { printf %s "$1" | grep -Eq '^[A-Za-z0-9+/]+=*$'; }

dir="$tmp/fixture dir/triage"
mkdir -p "$dir"
md="$dir/12.md"
html="$dir/12.html"
cat > "$md" <<'MD'
Triage: needs-changes · impact medium · risk high · decisions none

## Claim ledger

| Claim | How re-proved | Result |
|---|---|---|
| tests pass (body) | make test | reproduced |
| fixes the crash (commit) | probe | failed: still crashes |

## Findings

1. **Must-fix: x.** `a.go:1`

<img src=x onerror=alert(1)></script>

⚑ 🔒 é
MD

out="$("$root/bin/render-report" "$md" 2>"$tmp/err")"
rc=$?

# (a) a path with spaces
check "(a) exit 0 (got $rc)" [ "$rc" -eq 0 ]
check "(a) prints the html path (got: $out)" [ "$out" = "$html" ]
check "(a) html file exists" [ -f "$html" ]

if [ -f "$html" ]; then
  # (b) raw HTML is in the page only as base64
  block="$(sed -n 's|.*<script type="text/plain" id="md">\([^<]*\)</script>.*|\1|p' "$html")"
  opens="$(grep -o '<script' "$html" | wc -l | tr -d ' ')"
  closes="$(grep -o '</script>' "$html" | wc -l | tr -d ' ')"
  check "(b) html has no onerror" not grep -q onerror "$html"
  check "(b) embedded block is base64 only" is_base64 "$block"
  check "(b) one </script> per <script ($opens vs $closes)" [ "$opens" = "$closes" ]

  # (c) the base64 round-trips byte for byte
  printf %s "$block" | base64 --decode > "$tmp/decoded" 2>/dev/null
  check "(c) decoded block equals the fixture" cmp -s "$md" "$tmp/decoded"

  # (d) title and the pinned marked URL
  check "(d) title is Triage #12" grep -qF '<title>Triage #12</title>' "$html"
  check "(d) loads pinned marked" grep -qF 'https://cdnjs.cloudflare.com/ajax/libs/marked/12.0.2/marked.min.js' "$html"
fi

# (e) a missing file
"$root/bin/render-report" /nonexistent.md 2>"$tmp/err"
rc=$?
check "(e) missing file exits 1 (got $rc)" [ "$rc" -eq 1 ]
check "(e) stderr names the path" grep -qF '/nonexistent.md: no such file' "$tmp/err"

# (f) not a .md file
"$root/bin/render-report" notes.txt 2>"$tmp/err"
rc=$?
check "(f) non-.md exits 1 (got $rc)" [ "$rc" -eq 1 ]
check "(f) stderr says not a .md file" grep -qF 'notes.txt: not a .md file' "$tmp/err"

# (g) no arguments: usage on stderr, non-zero exit
"$root/bin/render-report" >"$tmp/out" 2>"$tmp/err"
rc=$?
check "(g) no args exits 2 (got $rc)" [ "$rc" -eq 2 ]
check "(g) no args prints usage on stderr" grep -qF 'render-report <file.md>...' "$tmp/err"

# (h) -h prints the whole header comment and nothing after it
"$root/bin/render-report" -h >"$tmp/out" 2>&1
check "(h) -h starts with the name line" grep -q '^render-report — ' "$tmp/out"
check "(h) -h ends with the exit-code note" last_line_is "$tmp/out" 'file; the valid ones are still rendered.'

# (i) --help and -h print usage, exit 0 and write nothing
for flag in --help -h; do
  out="$(cd "$tmp" && "$root/bin/render-report" "$flag" 2>&1)"
  rc=$?
  check "(i) $flag writes no file" [ ! -e "$tmp/$flag.html" ]
  check "(i) $flag exits 0 (got $rc)" [ "$rc" -eq 0 ]
  check "(i) $flag prints usage" grep -qF 'render-report <file.md>' <<<"$out"
done

# (j) the report's folder picks the page type and its help
help_block() { sed -n 's|.*<script type="text/plain" id="help">\([^<]*\)</script>.*|\1|p' "$1"; }
if [ -f "$html" ]; then
  check "(j) triage/ is a triage page" grep -qF '<body data-kind="pr-triage">' "$html"
  help_block "$html" | base64 --decode > "$tmp/help" 2>/dev/null
  check "(j) triage page embeds the triage help" cmp -s "$root/references/pr-triage-help.md" "$tmp/help"
fi
mkdir -p "$tmp/review-guide"
printf '# #7 x\n' > "$tmp/review-guide/7.md"
"$root/bin/render-report" "$tmp/review-guide/7.md" >/dev/null
check "(j) review-guide/ is a review-guide page" grep -qF '<body data-kind="review-guide">' "$tmp/review-guide/7.html"
help_block "$tmp/review-guide/7.html" | base64 --decode > "$tmp/help" 2>/dev/null
check "(j) review-guide page embeds its help" cmp -s "$root/references/review-guide-help.md" "$tmp/help"
for other in notes 12; do
  printf '# notes\n' > "$tmp/$other.md"
  "$root/bin/render-report" "$tmp/$other.md" >/dev/null
  check "(j) $other.md outside triage/ has no type" grep -qF '<body>' "$tmp/$other.html"
  check "(j) $other.md outside triage/ has no help" not grep -qF 'id="help"' "$tmp/$other.html"
done
check "(j) 12.md outside triage/ is not titled Triage" not grep -qF '<title>Triage #12</title>' "$tmp/12.html"

# (k) a symlinked script still finds the help
ln -s "$root/bin/render-report" "$tmp/linked-render-report"
"$tmp/linked-render-report" "$tmp/review-guide/7.md" >/dev/null
check "(k) linked script embeds the help" grep -qF 'id="help"' "$tmp/review-guide/7.html"

# (l) every section of a report template has a help entry
# headings FILE START — the "## " headings of the markdown fences after START,
# up to the next heading of START's level, without a " — hint".
headings() {
  awk -v start="$2" '
    index($0, start) == 1 { on = 1; lvl = index($0, " "); next }
    on && /^#+ / && index($0, " ") <= lvl && !fence { exit }
    on && /^```/ { fence = !fence; next }
    on && fence && /^## / { sub(/^## /, ""); sub(/ — .*/, ""); print }
  ' "$1" | sort -u
}
for pair in "commands/review-guide.md:## Write:review-guide" "references/pr-triage-brief.md:### 6. Write the report:pr-triage"; do
  file="${pair%%:*}"; rest="${pair#*:}"; start="${rest%:*}"; kind="${rest##*:}"
  want="$(headings "$root/$file" "$start")"
  check "(l) $file has template headings" [ -n "$want" ]
  while IFS= read -r h; do
    [ -n "$h" ] || continue
    check "(l) $kind help explains \"$h\"" grep -qxF "## $h" "$root/references/$kind-help.md"
  done <<<"$want"
done

# (m) Ship or block calls: the template, the help and the page name the same four
for call in "Block" "Ship unless" "After merge" "Ship"; do
  check "(m) template rules define $call" grep -qF -- "- **$call:** " "$root/commands/review-guide.md"
  check "(m) help explains $call" grep -qE "How to read it:.* $call: " "$root/references/review-guide-help.md"
  check "(m) page knows the $call call" grep -qF "'$call': '" "$tmp/review-guide/7.html"
done
check "(m) template line offers the four calls" grep -qF -- '- **<Block|Ship unless|After merge|Ship>:** ' "$root/commands/review-guide.md"
check "(m) stack rule puts the slice tag after the call" grep -qF "**Block:** <item> (#<N>) — …" "$root/commands/review-guide.md"
check "(m) page has a green pill" grep -qF '.pill.green {' "$tmp/review-guide/7.html"

# (n) bash writes a here-document into a pipe; macOS pipes may hold only 16 KB,
# and a larger document can hang render-report. Keep each one under 16 KB.
while read -r start size; do
  check "(n) heredoc at line $start is under 16 KB ($size bytes)" [ "$size" -lt 16384 ]
done < <(LC_ALL=C awk "/<<'HTML'\$/ { on = 1; n = 0; start = NR; next } on && /^HTML\$/ { print start, n; on = 0 } on { n += length(\$0) + 1 }" "$root/bin/render-report")

# (o) Ship or block pills in a real browser, when Chrome is there to run the page
chrome="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ -x "$chrome" ]; then
  cat > "$tmp/review-guide/8.md" <<'MD'
# #8 x

## Ship or block — 4 items
- **Block:** a — b

- **Ship unless:** c — d
- **After merge:** e — f
- **Ship:** g — h

## Who must act after merge
- **Block:** not a call here
MD
  "$root/bin/render-report" "$tmp/review-guide/8.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/8.html" > "$tmp/dom" 2>/dev/null
  for pill in 'red">Block</span>a' 'amber">Ship unless</span>c' 'amber">After merge</span>e' 'green">Ship</span>g'; do
    check "(o) DOM has pill $pill" grep -qF "<span class=\"pill $pill" "$tmp/dom"
  done
  check "(o) Who must act keeps its label" grep -qF '<dt>Block</dt>' "$tmp/dom"
else
  echo "skip: (o) needs Chrome at \$CHROME"
fi

# (p) each help section has a picture, drawn in the page's colours, and the
# page carries one template per picture
slug() { printf %s "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g'; }
for pair in "pr-triage:$html" "review-guide:$tmp/review-guide/7.html"; do
  kind="${pair%%:*}"; page="${pair#*:}"; pics="$root/references/$kind-help"
  slugs="$(sed -n 's/^## //p' "$root/references/$kind-help.md" | while IFS= read -r h; do slug "$h"; echo; done)"
  while IFS= read -r s; do
    check "(p) $kind help \"$s\" has a picture" [ -f "$pics/$s.svg" ]
  done <<<"$slugs"
  n=0
  for f in "$pics"/*.svg; do
    [ -f "$f" ] || continue
    n=$((n + 1)); s="$(basename "$f" .svg)"
    check "(p) $kind/$s.svg names a help section" grep -qxF "$s" <<<"$slugs"
    check "(p) $kind/$s.svg is an image" grep -qF 'role="img"' "$f"
    check "(p) $kind/$s.svg has a label" grep -qE 'aria-label="[^"]+"' "$f"
    check "(p) $kind/$s.svg is 240x140" grep -qF 'viewBox="0 0 240 140"' "$f"
    check "(p) $kind/$s.svg uses only the page colours" not grep -qE '<style|style=' "$f"
    check "(p) $kind/$s.svg colours are tokens" not grep -qEv '="(none|currentColor|var\(--[a-z-]+\))"' < <(grep -oE '(fill|stroke|stop-color|color)="[^"]*"' "$f")
    check "(p) $kind/$s.svg fonts are tokens" not grep -qEv '="var\(--mono\)"' < <(grep -oE 'font-family="[^"]*"' "$f")
    check "(p) $kind page carries $s" grep -qF "<template id=\"help-pic-$s\">" "$page"
  done
  check "(p) $kind has pictures" [ "$n" -gt 0 ]
done
# In a real browser: every Help heading gets its picture, even when a report
# heading's id is a picture's template id.
if [ -x "$chrome" ]; then
  printf '# #9 x\n\n## Help pic ship or block\n\ntext\n' > "$tmp/review-guide/9.md"
  "$root/bin/render-report" "$tmp/review-guide/9.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/9.html" > "$tmp/dom" 2>/dev/null
  want="$(grep -c '^## ' "$root/references/review-guide-help.md")"
  check "(p) DOM has the Help panel" grep -qF 'id="help-panel"' "$tmp/dom"
  # Route's flag: once in its template, once in the placed picture.
  check "(p) DOM leaves the pictures' text alone" [ "$(grep -oF '>⚑ <tspan' "$tmp/dom" | wc -l | tr -d ' ')" = 2 ]
  check "(p) DOM has a picture after each of $want Help headings" [ "$(grep -o '</h2><svg' "$tmp/dom" | wc -l | tr -d ' ')" = "$want" ]
else
  echo "skip: (p) DOM checks need Chrome at \$CHROME"
fi
check "(p) a page with no type has no pictures" not grep -qF '<template id="help-pic-' "$tmp/notes.html"

# (q) header quote, Findings pill and heading ids in a real browser
if [ -x "$chrome" ]; then
  printf '# #10 x\n\nauthor · base\n\n> **1 decision.** Summary.\n\n## Notes\n\ntext\n' > "$tmp/review-guide/10.md"
  "$root/bin/render-report" "$tmp/review-guide/10.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/10.html" > "$tmp/dom" 2>/dev/null
  check "(q) the summary quote is a card" grep -qF '<blockquote class="card">' "$tmp/dom"
  printf '# #11 x\n\n## Notes\n\n> a quote far down\n' > "$tmp/review-guide/11.md"
  "$root/bin/render-report" "$tmp/review-guide/11.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/11.html" > "$tmp/dom" 2>/dev/null
  check "(q) a quote further down is not a card" not grep -qF 'class="card"' "$tmp/dom"

  printf '# #12 x\n\n## Findings\n\n1. **Must-fix:** text\n2. **Must-fix: x.** y\n' > "$tmp/review-guide/12.md"
  "$root/bin/render-report" "$tmp/review-guide/12.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/12.html" > "$tmp/dom" 2>/dev/null
  check "(q) Must-fix gets the red pill" [ "$(sed -n '/<main id="page"/,$p' "$tmp/dom" | grep -oF 'pill red">Must-fix</span>' | wc -l | tr -d ' ')" = 2 ]
  check "(q) a bare Must-fix leaves no empty strong" not grep -qF '<strong></strong>' "$tmp/dom"
  check "(q) a Must-fix with a bold lead keeps it" grep -qF '<strong>x.</strong>' "$tmp/dom"

  printf '# #14 x\n\n## Findings\n\n1. **Must-fix:** a\n2. **Should-fix:** b\n' > "$tmp/review-guide/14.md"
  "$root/bin/render-report" "$tmp/review-guide/14.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/14.html" > "$tmp/dom" 2>/dev/null
  check "(q) bare Must-fix and Should-fix items stay cards" [ -n "$(grep -A1 -xF '<ol class="cards">' "$tmp/dom" | grep -F 'class="must"')" ]
  check "(q) Should-fix gets the amber pill" grep -qF 'pill amber">Should-fix</span>' "$tmp/dom"

  printf '# #13 x\n\n## Notes\n\na\n\n## Notes\n\nb\n\n## 🔒\n\nc\n\n## Page\n\nd\n' > "$tmp/review-guide/13.md"
  "$root/bin/render-report" "$tmp/review-guide/13.md" >/dev/null
  "$chrome" --headless=new --disable-gpu --virtual-time-budget=5000 --dump-dom "file://$tmp/review-guide/13.html" > "$tmp/dom" 2>/dev/null
  check "(q) the first Notes id is notes" grep -qF '<h2 id="notes">' "$tmp/dom"
  check "(q) the second Notes id is notes-2" grep -qF '<h2 id="notes-2">' "$tmp/dom"
  check "(q) the toc links to both" grep -qF 'href="#notes-2"' "$tmp/dom"
  check "(q) an emoji-only heading gets id section" grep -qF '<h2 id="section">' "$tmp/dom"
  check "(q) no toc link is href=#" not grep -qF 'href="#"' "$tmp/dom"
  check "(q) a Page heading does not reuse the page id" grep -qF '<h2 id="page-2">' "$tmp/dom"
else
  echo "skip: (q) needs Chrome at \$CHROME"
fi

exit "$fail"
