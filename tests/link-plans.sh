#!/usr/bin/env bash
# link-plans symlinks the main checkout's gitignored local/ into a worktree,
# and does nothing in the main checkout itself.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
fail=0
# check DESC CMD... — run CMD; on failure print FAIL: DESC.
check() { local d="$1"; shift; if ! "$@"; then echo "FAIL: $d"; fail=1; fi; }

# Keep the caller's plans-dir and hook settings out of the test.
unset PLANS_DIR CCMANAGER_GIT_ROOT CCMANAGER_WORKTREE_PATH
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

main="$tmp/main"
wt="$tmp/wt"
{
  git init -q "$main" &&
    git -C "$main" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init &&
    git -C "$main" worktree add -q "$wt" -b side
} > "$tmp/setup" 2>&1 || { echo "FAIL: git setup"; cat "$tmp/setup"; exit 1; }

"$root/bin/link-plans" "$wt" > "$tmp/out" 2>&1
rc=$?
check "exit code 0 (got $rc)" [ "$rc" -eq 0 ]
check "plans dir created in the main checkout" [ -d "$main/local/plans" ]
check "worktree local is a symlink" [ -L "$wt/local" ]
check "symlink points at the main checkout's local" [ "$(readlink "$wt/local")" = "$main/local" ]

"$root/bin/link-plans" "$wt" >> "$tmp/out" 2>&1
check "second run succeeds" [ "$?" -eq 0 ]
check "second run does not nest a link inside local/" [ ! -e "$main/local/local" ]

"$root/bin/link-plans" "$main" >> "$tmp/out" 2>&1
check "main checkout: exit code 0" [ "$?" -eq 0 ]
check "main checkout: local stays a directory" [ ! -L "$main/local" ]

[ "$fail" -eq 0 ] || { echo "link-plans output:"; cat "$tmp/out"; }
exit "$fail"
