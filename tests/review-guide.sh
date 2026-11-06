#!/usr/bin/env bash
# shellcheck disable=SC2016  # the strings below are Markdown, backticks and all
# review-guide's command text keeps the contract its callers rely on.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
cmd="$root/commands/review-guide.md"
fail=0
# check DESC CMD... — run CMD; on failure print FAIL: DESC.
check() { local d="$1"; shift; if ! "$@"; then echo "FAIL: $d"; fail=1; fi; }
# shellcheck disable=SC2329  # runs through check
not() { ! "$@"; }
# section HEADING — the lines of "## HEADING" up to the next "## " heading.
section() { awk -v h="## $1" '$0 == h { on = 1; next } on && /^## / { exit } on' "$cmd"; }

# (a) --review shows in the slash-command tooltip and in the arguments
check "(a) argument-hint lists --review [effort]" grep -qE '^argument-hint: .*\[--review \[effort\]\]' "$cmd"
check "(a) \$ARGUMENTS names --review" grep -qF '`$ARGUMENTS` is `<N> [<head-sha>] [--expert | --new] [--review [<effort>]]`' "$cmd"

# (b) the Review section runs the tools in a tip worktree and never posts
review="$(section Review)"
check "(b) a ## Review section exists" [ -n "$review" ]
for step in 'git worktree add --detach' 'EnterWorktree' 'ExitWorktree' 'git worktree remove' \
  '`code-review`' '`plan-lifecycle:verify-findings`' '`plan-lifecycle:review-stack <S> <effort>`' 'Never pass `--comment`'; do
  check "(b) Review names $step" grep -qF -- "$step" <<<"$review"
done
check "(b) no review call passes --comment" not grep -qE '(code-review|review-stack)[^`]*--comment' "$cmd"

# (c) the page has a Review findings section in the template
check "(c) template has Review findings" grep -qF '## Review findings — <tool> (<effort>), verified' "$cmd"

exit "$fail"
