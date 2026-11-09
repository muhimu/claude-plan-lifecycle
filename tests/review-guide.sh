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
  '`code-review`' '`plan-lifecycle:verify-findings`' '`plan-lifecycle:review-stack <top PR> <effort>`' 'Never pass `--comment`'; do
  check "(b) Review names $step" grep -qF -- "$step" <<<"$review"
done
check "(b) a checkout already at the tip needs no worktree" grep -qF 'already at the tip' <<<"$review"
check "(b) no review call passes --comment" not grep -qE '(code-review|review-stack)[^`]*--comment' "$cmd"

# (b) the stack call names a PR (a fallback stack's S is "of-<N>", which
# /review-stack does not take); one pinned slice is one target, not a stack
check "(b) review-stack is never given S" not grep -qF 'review-stack <S>' "$cmd"
check "(b) Review branches on targets, not STACKED" not grep -qF 'STACKED' <<<"$review"
check "(b) Review reads each head just before the review" grep -qF 'gh pr view <n> -R <OWNER/REPO> --json headRefOid -q .headRefOid' <<<"$review"
check "(b) template keeps unverified findings" grep -qF -- '- `<file:line>` <summary> — not verified: <why>' "$cmd"

# (d) /review-stack accepts the detached worktree the guide makes at the top
check "(d) session-pr accepts a detached HEAD at a wanted branch's head" grep -qF 'HEAD is detached at the head of a wanted branch' "$root/references/session-pr.md"
check "(d) only for a caller that does not push" grep -qF 'for a caller that does not push, HEAD is detached' "$root/references/session-pr.md"

# (i) follow-ups: findings left out keep Riskiest code; the table has a cap;
# <f> is defined; the sticky effort is said
check "(i) Riskiest code stays for a target without findings" grep -qF 'Leave it out for a target whose findings are on the page' "$cmd"
check "(i) the findings table has a cap" grep -qF 'more than 8 findings' "$cmd"
check "(i) <f> counts confirmed and plausible" grep -qF '`<f>` counts confirmed and plausible findings' "$cmd"
check "(i) Finish says the effort is sticky" grep -qF 'keeps that effort level for later runs' <<<"$(section Finish)"

# (m) review round 2: the tip is the top's current head; the default effort
# sticks too; a background review is waited for; WT lives under the main
# checkout and survives a lock; the stack summary and the help agree
check "(m) the worktree is at the top's current head" grep -qF "the last target's current head" <<<"$review"
check "(m) Finish notes the sticky effort whenever the review ran" grep -qF 'review ran, add (the default `high` sticks too)' <<<"$(section Finish)"
check "(m) Finish says when every PR moved" grep -qF -- '--review skipped: every PR moved since Fetch' <<<"$(section Finish)"
check "(m) a background review is waited for" grep -qF 'by task notification' <<<"$review"
check "(m) WT is under the main checkout" grep -qF 'git rev-parse --path-format=absolute --git-common-dir' <<<"$review"
check "(m) a locked WT is unlocked and pruned" grep -qF 'git worktree unlock <WT>' <<<"$review"
check "(m) a removed WT is pruned" grep -qF 'git worktree prune' <<<"$review"
check "(m) the stack summary counts findings" grep -qF '> **<d> decisions · <k> judgement calls · <f> review findings (<c> confirmed).**' "$cmd"
check "(m) help allows Riskiest code beside findings" grep -qF 'Riskiest code appears only for a PR whose findings are not on the page' "$root/references/review-guide-help.md"

# (c) the page has a Review findings section in the template
check "(c) template has Review findings" grep -qF '## Review findings — <tool> (<effort>), verified' "$cmd"

exit "$fail"
