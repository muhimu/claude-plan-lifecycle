#!/usr/bin/env bash
# stamp-plans stamps every plan of one slug group and leaves other slugs alone.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0
# check DESC CMD... — run CMD; on failure print FAIL: DESC.
check() { local d="$1"; shift; if ! "$@"; then echo "FAIL: $d"; fail=1; fi; }

printf -- '---\nslug: demo\npr:\n---\n# A\n' > "$tmp/a.md"
printf -- '---\nslug: demo\npr:\n---\n# B\n' > "$tmp/b.md"
printf -- '---\nslug: other\npr:\n---\n# C\n' > "$tmp/c.md"

"$root/bin/stamp-plans" -d "$tmp" -s demo 42 > "$tmp/out" 2>&1
rc=$?

check "exit code 0 (got $rc)" [ "$rc" -eq 0 ]
check "a.md stamped pr: 42" grep -qx "pr: 42" "$tmp/a.md"
check "b.md stamped pr: 42" grep -qx "pr: 42" "$tmp/b.md"
check "c.md keeps empty pr:" grep -qx "pr:" "$tmp/c.md"

exit "$fail"
