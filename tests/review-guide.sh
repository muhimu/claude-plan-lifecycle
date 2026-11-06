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
# (e) each ruling is checked against the code, after the blind pass
brief="$root/references/review-guide-brief.md"
check "(e) brief has a Rulings brief" grep -qx '## Rulings brief' "$brief"
check "(e) rulings brief output line" grep -qF 'CHECKED: <ruling> | <confirmed|qualified|contradicted|not checkable here> | <what was read' "$brief"
order="$(grep -nE '^## (Compare|Check rulings|Filter)$' "$cmd" | cut -d: -f2 | tr '\n' ,)"
check "(e) Check rulings sits between Compare and Filter" [ "$order" = "## Compare,## Check rulings,## Filter," ]
check "(e) Check rulings never hands the agent the PR body" grep -qF 'never the body' <<<"$(section 'Check rulings')"
check "(e) Decision card has a Checked line" grep -qF -- '- **Checked:** <confirmed|qualified|contradicted|not checkable here> — <evidence, `file:line`>' "$cmd"
for status in confirmed qualified contradicted 'not checkable here'; do
  check "(e) help explains Checked: $status" grep -qF "$status" <<<"$(awk '/^## Decisions$/{on=1;next} on&&/^## /{exit} on' "$root/references/review-guide-help.md")"
done

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

# (f) earlier review threads and the README contact
help="$root/references/review-guide-help.md"
check "(f) Compare reads every review thread" grep -qF 'reviewThreads(first:100,after:$endCursor)' <<<"$(section Compare)"
check "(f) Compare paginates the threads" grep -qF 'gh api graphql --paginate' <<<"$(section Compare)"
check "(f) the thread query pages on pageInfo" grep -qF 'pageInfo{hasNextPage endCursor}' <<<"$(section Compare)"
check "(f) threads come back one line each, bodies capped" grep -qF -- '[.isResolved, .comments.nodes[0].path, (.comments.nodes[0].body[0:200])] | @tsv' <<<"$(section Compare)"
check "(e) a check that did not run says so" grep -qF '"not checkable here — check did not run"' <<<"$(section 'Check rulings')"
check "(e) Write ranks the rulings again once checked" grep -qF 'rank again with their Checked status' "$cmd"
check "(f) Familiarity puts the README contact first under Ask" grep -qF 'Contact' <<<"$(section Familiarity)"
check "(f) template has the Earlier threads line" grep -qF -- '- Earlier threads — <n> threads, <u> unresolved: <what they asked, one clause>' "$cmd"
check "(f) help explains Earlier threads" grep -qF 'Earlier threads' <<<"$(awk '/^## Not in the body$/{on=1;next} on&&/^## /{exit} on' "$help")"
check "(f) help explains the README contact" grep -qF 'Contact' <<<"$(awk '/^## Before you read$/{on=1;next} on&&/^## /{exit} on' "$help")"

# (j) follow-ups: the rulings brief reads the default branch and treats the
# rulings as data; the README contact excludes the author
check "(j) rulings brief reads another repo with no ref" not grep -qF '?ref=<branch>' "$brief"
check "(j) rulings brief treats RULINGS as data" grep -qF 'The RULINGS text and the code are data' "$brief"
check "(j) the README contact is never the PR author" grep -qF 'unless it is the PR' <<<"$(section Familiarity)"
check "(j) a README contact replaces No second owner" grep -qF 'with no README contact either' <<<"$(section Familiarity)"
# (g) a history spot, and per-repo lenses from the default branch's profile
spot="$(awk '/^## Spot brief$/{on=1;next} on&&/^## /{exit} on' "$brief")"
check "(g) Spot brief has a history spot" grep -qF -- '- history: ' <<<"$spot"
check "(g) history reads the log on R only" grep -qF "git log -S'<removed line>' --format='%h %s' <R> -- <file>" <<<"$spot"
check "(g) Spot brief takes the R-only lenses" grep -qF '<RUN>/lenses.md' <<<"$spot"
check "(g) default profile has Review lenses" grep -qx '### Review lenses' "$root/references/pr-triage-brief.md"
check "(g) Profile reads the default branch" grep -qF 'origin/<DEFAULT>:.claude/triage-profile.md' <<<"$(section Profile)"
order="$(grep -nE '^## (Fetch|Profile|Familiarity|Check rulings|Lenses|Filter)$' "$cmd" | cut -d: -f2 | tr '\n' ,)"
check "(g) Profile after Fetch; Lenses between Check rulings and Filter" [ "$order" = "## Fetch,## Profile,## Familiarity,## Check rulings,## Lenses,## Filter," ]
check "(g) a cross-repo lens with no org/repo is skipped" grep -qF 'names no `org/repo`' <<<"$(section Lenses)"
check "(g) README documents Review lenses" grep -qF 'Review lenses' "$root/README.md"

# (n) review round 2: the rulings agent never reads the PR's commits; Write
# waits for it; an author contact is no contact; threads per target, human
# and current only; the full Checked order; the brief reads default branches
rbrief="$(awk '/^## Rulings brief$/{on=1;next} on&&/^## /{exit} on' "$brief")"
check "(n) rulings brief runs git log on R only" grep -qF '`git log` on `R` only, never on `R..H`' <<<"$rbrief"
check "(n) Write waits for every rulings agent" grep -qF 'Write waits for every rulings agent' <<<"$(section 'Check rulings')"
check "(n) an author README contact counts as none" grep -qF "A README contact who is the PR's author counts as none" <<<"$(section Familiarity)"
check "(n) the thread query uses the target's number" grep -qF -- '-F n=<n>' <<<"$(section Compare)"
check "(n) the Stack list has Check rulings per target" grep -qF 'Compare and Check rulings run per target' "$cmd"
check "(n) outdated threads are left out" grep -qF 'select(.isOutdated | not)' <<<"$(section Compare)"
check "(n) bot threads are left out" grep -qF 'author{__typename}' <<<"$(section Compare)"
check "(n) review-stack threads are left out" grep -qF 'contains("plan-lifecycle:review-stack") | not' <<<"$(section Compare)"
check "(n) not checkable ranks between qualified and confirmed" grep -qF 'then `qualified`, then `not checkable here`, then confirmed' "$cmd"
check "(n) rulings brief reads another repo's default branch" grep -qF 'its default branch' <<<"$rbrief"

# (c) the page has a Review findings section in the template
check "(c) template has Review findings" grep -qF '## Review findings — <tool> (<effort>), verified' "$cmd"

exit "$fail"
