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
  check "(m) help explains $call" grep -qF "$call:" "$root/references/review-guide-help.md"
  check "(m) page knows the $call call" grep -qF "'$call': '" "$tmp/review-guide/7.html"
done
check "(m) template line offers the four calls" grep -qF -- '- **<Block|Ship unless|After merge|Ship>:** ' "$root/commands/review-guide.md"
check "(m) stack rule puts the slice tag after the call" grep -qF "**Block:** <item> (#<N>) — …" "$root/commands/review-guide.md"
check "(m) page has a green pill" grep -qF '.pill.green {' "$tmp/review-guide/7.html"

exit "$fail"
