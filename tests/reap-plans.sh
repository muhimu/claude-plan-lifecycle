#!/usr/bin/env bash
# reap-plans moves a group whose PR merged into done/ and sets status: merged,
# takes a follow-ups stub along with its parent and names it, skips open and
# PR-less groups, moves an abandoned group as it is, and changes nothing
# with -n. Runs once with gh's batched state lookup and once with only
# `gh pr view` answering.
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
# says TEXT — the last run's output has a line containing TEXT.
# shellcheck disable=SC2329  # runs through check
says() { grep -qF -- "$1" "$tmp/out"; }

# Fake gh: PR 7 is merged, PR 8 open, anything else unknown. GH_NO_BATCH=1
# fails the batched GraphQL lookup so reap-plans asks per PR. Calls are logged.
mkdir "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1 $2" in
  "api graphql")
    [ -z "${GH_NO_BATCH:-}" ] || exit 1
    echo '{"data":{"repository":{"p7":{"state":"MERGED"},"p8":{"state":"OPEN"}}}}' ;;
  "pr view")
    case "$3" in 7) echo MERGED ;; 8) echo OPEN ;; *) exit 1 ;; esac ;;
  *) exit 1 ;;
esac
GH
chmod +x "$tmp/bin/gh"
export GH_LOG="$tmp/gh.log"

# plans DIR — a fresh plans dir with one group of each kind.
plans() {
  mkdir "$1"
  printf -- '---\nslug: done\nstatus: draft\npr: 7\n---\n# Design\n' > "$1/done-design.md"
  printf -- '---\nslug: done\nstatus: draft\npr: "#7"\n---\n# Plan\n' > "$1/done-plan.md"
  printf -- '---\nslug: done\nissue: 3\nstatus: draft\npr: 7\n---\n# Follow-ups\n' > "$1/done-followups.md"
  printf -- '---\nslug: open\nstatus: draft\npr: 8\n---\n# Open\n' > "$1/open.md"
  printf -- '---\nslug: new\nstatus: draft\npr:\n---\n# New\n' > "$1/new.md"
  printf -- '---\nslug: dropped\nstatus: abandoned\npr:\n---\n# Dropped\n' > "$1/dropped.md"
  printf -- '# No frontmatter\npr: 7\n' > "$1/bare.md"
}

# snapshot DIR — every file under DIR with its content.
snapshot() { (cd "$1" && find . -type f | sort | while read -r f; do echo "== $f"; cat "$f"; done); }

for mode in batch per-pr; do
  if [ "$mode" = batch ]; then unset GH_NO_BATCH; else export GH_NO_BATCH=1; fi
  p="$tmp/$mode"
  plans "$p"
  : > "$GH_LOG"

  snapshot "$p" > "$tmp/before"
  PATH="$tmp/bin:$PATH" "$root/bin/reap-plans" -n -d "$p" > "$tmp/out" 2>&1
  rc=$?
  snapshot "$p" > "$tmp/after"
  check "$mode -n: exit code 0 (got $rc)" [ "$rc" -eq 0 ]
  check "$mode -n: nothing changed" cmp -s "$tmp/before" "$tmp/after"
  check "$mode -n: reports the merged group" says "would move (PR #7 merged)"
  check "$mode -n: names the follow-ups stub" says "follow-ups (triage"
  check "$mode -n: counts" says "dry run: 4 would move, 1 open/unknown, 2 without PR"
  [ "$fail" -eq 0 ] || { echo "reap-plans -n output ($mode):"; cat "$tmp/out"; }

  : > "$GH_LOG"
  PATH="$tmp/bin:$PATH" "$root/bin/reap-plans" -d "$p" > "$tmp/out" 2>&1
  rc=$?
  check "$mode: exit code 0 (got $rc)" [ "$rc" -eq 0 ]
  check "$mode: merged design moved, status set" is "$p/done/done-design.md" '---\nslug: done\nstatus: merged\npr: 7\n---\n# Design'
  check "$mode: merged plan moved, status set" is "$p/done/done-plan.md" '---\nslug: done\nstatus: merged\npr: "#7"\n---\n# Plan'
  check "$mode: follow-ups stub moved with its parent" is "$p/done/done-followups.md" '---\nslug: done\nissue: 3\nstatus: merged\npr: 7\n---\n# Follow-ups'
  check "$mode: output names the follow-ups stub" says "follow-ups (triage what is still open; the PR body's Follow-ups section is current): done-followups.md"
  check "$mode: abandoned plan moved as it is" is "$p/done/dropped.md" '---\nslug: dropped\nstatus: abandoned\npr:\n---\n# Dropped'
  check "$mode: open PR skipped" is "$p/open.md" '---\nslug: open\nstatus: draft\npr: 8\n---\n# Open'
  check "$mode: open PR reported" says "skip (PR #8 OPEN) : open.md"
  check "$mode: no PR skipped" is "$p/new.md" '---\nslug: new\nstatus: draft\npr:\n---\n# New'
  check "$mode: no frontmatter skipped" is "$p/bare.md" '# No frontmatter\npr: 7'
  check "$mode: nothing else in done/" [ "$(find "$p/done" -type f | wc -l)" -eq 4 ]
  check "$mode: counts" says "done: 4 moved, 1 open/unknown, 2 without PR"
  if [ "$mode" = batch ]; then
    check "batch: one gh call for all PRs" [ "$(wc -l < "$GH_LOG")" -eq 1 ]
  else
    check "per-pr: falls back to gh pr view" grep -q '^pr view 7 ' "$GH_LOG"
  fi
  [ "$fail" -eq 0 ] || { echo "reap-plans output ($mode):"; cat "$tmp/out"; }
done

exit "$fail"
