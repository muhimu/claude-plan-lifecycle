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

dir="$tmp/fixture dir"
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

exit "$fail"
