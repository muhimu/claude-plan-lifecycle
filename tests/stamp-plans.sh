#!/usr/bin/env bash
# stamp-plans stamps every plan of one slug group inside its frontmatter,
# adds a missing pr: key, leaves other slugs alone, and ends with a hint when
# reap-plans' dry run finds plans to archive, moving nothing itself.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
# check DESC CMD... — run CMD; on failure print FAIL: DESC.
check() { local d="$1"; shift; if ! "$@"; then echo "FAIL: $d"; fail=1; fi; }
# is FILE TEXT — FILE holds exactly TEXT (backslash escapes expanded).
# shellcheck disable=SC2329  # runs through check
is() { [ "$(cat "$1")" = "$(printf '%b' "$2")" ]; }

plans="$tmp/plans"
mkdir "$plans"
printf -- '---\nslug: demo\npr:\n---\n# A\n' > "$plans/a.md"
printf -- '---\nslug: demo\npr:\n---\n# B\n' > "$plans/b.md"
printf -- '---\nslug: other\npr:\n---\n# C\n' > "$plans/c.md"
printf -- '---\nslug: demo\n---\n# D\n' > "$plans/d.md"
printf -- '---\nslug: old\nstatus: draft\npr: 7\n---\n# E\n' > "$plans/e.md"

# Fake gh for the reap hint: PR 7 is merged, PR 42 open.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
[ "$1 $2" = "api graphql" ] || exit 1
echo '{"data":{"repository":{"p7":{"state":"MERGED"},"p42":{"state":"OPEN"}}}}'
GH
chmod +x "$tmp/bin/gh"

PATH="$tmp/bin:$PATH" "$root/bin/stamp-plans" -d "$plans" -s demo 42 > "$tmp/out" 2>&1
rc=$?

check "exit code 0 (got $rc)" [ "$rc" -eq 0 ]
check "a.md stamped in its frontmatter" is "$plans/a.md" '---\nslug: demo\npr: 42\n---\n# A'
check "b.md stamped in its frontmatter" is "$plans/b.md" '---\nslug: demo\npr: 42\n---\n# B'
check "c.md unchanged" is "$plans/c.md" '---\nslug: other\npr:\n---\n# C'
check "d.md gets a pr: key before the closing ---" is "$plans/d.md" '---\nslug: demo\npr: 42\n---\n# D'
check "hint counts the reapable plan" grep -q '^hint: 1 plan file(s) .* run reap-plans$' "$tmp/out"
check "e.md left in place and unchanged" is "$plans/e.md" '---\nslug: old\nstatus: draft\npr: 7\n---\n# E'
check "no done/ dir created" [ ! -e "$plans/done" ]

# With e.md on the open PR nothing is reapable.
printf -- '---\nslug: old\nstatus: draft\npr: 42\n---\n# E\n' > "$plans/e.md"
PATH="$tmp/bin:$PATH" "$root/bin/stamp-plans" -d "$plans" -s other 43 > "$tmp/out2" 2>&1
check "no hint when nothing is reapable" [ "$(grep -c '^hint:' "$tmp/out2")" -eq 0 ]

[ "$fail" -eq 0 ] || { echo "stamp-plans output:"; cat "$tmp/out"; }
exit "$fail"
