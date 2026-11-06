#!/usr/bin/env bash
# stamp-plans stamps every plan of one slug group inside its frontmatter,
# adds a missing pr: key, and leaves other slugs alone.
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

"$root/bin/stamp-plans" -d "$plans" -s demo 42 > "$tmp/out" 2>&1
rc=$?

check "exit code 0 (got $rc)" [ "$rc" -eq 0 ]
check "a.md stamped in its frontmatter" is "$plans/a.md" '---\nslug: demo\npr: 42\n---\n# A'
check "b.md stamped in its frontmatter" is "$plans/b.md" '---\nslug: demo\npr: 42\n---\n# B'
check "c.md unchanged" is "$plans/c.md" '---\nslug: other\npr:\n---\n# C'
check "d.md gets a pr: key before the closing ---" is "$plans/d.md" '---\nslug: demo\npr: 42\n---\n# D'

[ "$fail" -eq 0 ] || { echo "stamp-plans output:"; cat "$tmp/out"; }
exit "$fail"
