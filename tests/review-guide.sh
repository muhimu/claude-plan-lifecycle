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
  '`plan-lifecycle:review-stack <top PR> <effort>`' 'Never pass `--comment`'; do
  check "(b) Review names $step" grep -qF -- "$step" <<<"$review"
done
check "(b) a checkout already at the tip needs no worktree" grep -qF 'already at the tip' <<<"$review"
check "(b) one PR goes through review-stack too" not grep -qE '`(code-review|plan-lifecycle:verify-findings)`' <<<"$review"
check "(b) a pinned slice gets no review" grep -qF 'pinned by `<head-sha>` gets no review' <<<"$review"
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
check "(m) MAIN comes from git-common-dir" grep -qF 'git rev-parse --path-format=absolute --git-common-dir' <<<"$review"
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
check "(g) history reads the log on R only" grep -qF -- "--follow --format='%h %s' <R> -- <file>" <<<"$spot"
check "(g) Spot brief takes the R-only lenses" grep -qF '<RUN>/lenses.md' <<<"$spot"
check "(g) default profile has Review lenses" grep -qx '### Review lenses' "$root/references/pr-triage-brief.md"
check "(g) Profile reads the default branch" grep -qF 'origin/<DEFAULT>:.claude/triage-profile.md' <<<"$(section Profile)"
order="$(grep -nE '^## (Fetch|Profile|Familiarity|Check rulings|Lenses|Filter)$' "$cmd" | cut -d: -f2 | tr '\n' ,)"
check "(g) Profile after Fetch; Lenses between Check rulings and Filter" [ "$order" = "## Fetch,## Profile,## Familiarity,## Check rulings,## Lenses,## Filter," ]
check "(g) a cross-repo lens with no org/repo is skipped" grep -qF 'names no `org/repo`' <<<"$(section Lenses)"
check "(g) lens checks are allow-listed" grep -qF 'git show`, `git grep`, `git log`, `git ls-tree`, `git diff` or `gh api` with no `-X`, `--method`, `-f`, `-F`, `--field`, `--raw-field` or `--input`' <<<"$(section Lenses)"
check "(g) diff text is quoted into a check" grep -qF 'single-quoted, every quote in it escaped' "$brief"
check "(g) a local path or placeholder repo is skipped" grep -qF 'a local path, `{owner}/{repo}` or a placeholder' <<<"$(section Lenses)"
check "(g) the rule test admits history and lens rules" grep -qF 'the commit that added the removed code, or a lens check' "$brief"
check "(g) a lens spot's Rule is not its output (Ruling 4)" not grep -qF 'its `Rule` is that' <<<"$(section Lenses)"
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

# (k) follow-ups: lens spots rank with the rest after Filter; history follows
# renames and ignores indentation; lens headings sit one level down
check "(k) the 5-stop cap applies after Filter, lens spots ranked in" grep -qF 'The cap applies after Filter' "$cmd"
check "(k) history follows renames" grep -qF "git log -S'<removed line, trimmed>' --follow" "$brief"
check "(k) lens heading is one level below Review lenses" grep -qF 'one heading level below `Review lenses`' "$root/references/pr-triage-brief.md"
# (h) a re-run opens with what changed since the last guide
prev="$(section 'Previous guide')"
order="$(grep -nE '^## (Fetch|Previous guide|Profile)$' "$cmd" | cut -d: -f2 | tr '\n' ,)"
check "(h) Previous guide sits right after Fetch" [ "$order" = "## Fetch,## Previous guide,## Profile," ]
for step in 'git merge-base --is-ancestor <old H> <H>' "git log --format='%h %s' <old H>..<H>" 'git range-diff <old B>..<old H> <B>..<H>' 'previous head no longer exists' 'never to the spot agent'; do
  check "(h) Previous guide names $step" grep -qF -- "$step" <<<"$prev"
done
check "(h) the section follows the summary line" grep -qx '## Since the last guide — <old head, 8 chars>' <<<"$(grep -A2 -F '> **<d> decisions · <k> judgement calls · <s> to skip' "$cmd")"
check "(h) the stack page has it too" grep -qx '## Since the last guide — <old head, 8 chars>' <<<"$(grep -A2 -F '> **<d> decisions · <k> judgement calls · <f> review' "$cmd")"
check "(h) Resolved only when the delta touches it" grep -qF 'Resolved only when the delta touches its file or ruling' "$cmd"
check "(h) an item pushed out of the top is no longer ranked" grep -qF -- '- No longer ranked: ' "$cmd"
check "(h) an item of a merged slice is merged" grep -qF 'Merged: <old stop or Decision> (#<N>)' "$cmd"
check "(h) stack page merges the slice deltas" grep -qF "merges the slices' own sections" "$cmd"
check "(h) Rules allow rev-parse and range-diff" grep -qF '`git rev-parse`, `git range-diff`' <<<"$(section Rules)"
check "(h) Reading order names Since the last guide" grep -qF 'Since the last guide' <<<"$(awk '/^## Reading order$/{on=1;next} on&&/^## /{exit} on' "$root/references/review-guide-help.md")"
check "(h) header says updated from" grep -qF 'updated from `<old head, 8 chars>`' "$cmd"
check "(h) Finish counts resolved, still open and new" grep -qF '<res> resolved, <open> still open, <new> new since the last guide' <<<"$(section Finish)"

# (o) review round 2: the allow-list covers long flags, write options and
# chaining; git log on B or H stays with the orchestrator; an H-only check
# takes its rule from R; diff text has a slot; another branch of this repo
# is a rule; history reads the old path and the newest adding commit
lenses="$(section Lenses)"
check "(o) the allow-list rejects --field and --raw-field" grep -qF -- '`--field`, `--raw-field`' <<<"$lenses"
check "(o) the allow-list rejects write options" grep -qF -- '`--output`, `--ext-diff`, `--open-files-in-pager`, `-c`' <<<"$lenses"
check "(o) the allow-list rejects chaining" grep -qF -- '`;`, `&&`, `|`, `>`, `<`, `$(` or a backtick' <<<"$lenses"
check "(o) git log on B or H waits for Lenses" grep -qF '`git log` on `<R>`' <<<"$(section Profile)"
check "(o) the spot brief takes git log on R only for lenses" grep -qF 'or `git log` on R' "$brief"
check "(o) an H-only check takes its rule from R" grep -qF 'the same check with R in place of H' "$brief"
check "(o) the diff-text slot is defined" grep -qF 'Write the place diff text goes as `<…>`' "$root/references/pr-triage-brief.md"
check "(o) another branch of this repo can be a Rule" grep -qF '`<OWNER/REPO>@<branch>:<path>:<line>`' <<<"$lenses"
check "(o) history reads the old path on R" grep -qF "the old path when the PR renames it" "$brief"
check "(o) history takes the newest adding commit" grep -qF -- "--format='%h %s' <R> -- <file> | head -1" "$brief"
check "(o) a lens spot's Rule is the evidence it rests on" grep -qF 'its `Rule` is the evidence it rests on' <<<"$lenses"

# (l) follow-ups: the old head is fetched from GitHub when it is gone locally;
# a missing base and a guide older than the last are handled; the section has
# a cap; the stack header says updated from
check "(l) old head expanded and fetched from GitHub" grep -qF 'gh api repos/<OWNER/REPO>/commits/<8> -q .sha' <<<"$prev"
check "(l) an old page without a base field" grep -qF 'no `base` field' <<<"$prev"
check "(l) a guide older than the last one" grep -qF 'git merge-base --is-ancestor <H> <old H>' <<<"$prev"
check "(l) plain new commits only after the ancestor test" grep -qF '**Plain new commits:**' <<<"$prev"
check "(l) Since the last guide has a cap" grep -qF 'at most 8 items' "$cmd"
check "(l) stack header says updated from" grep -qF '<date> · <MODE>: <why> · updated from `<old head, 8 chars>`' <<<"$(grep -F '#<N> head `<8>` on' "$cmd")"

# (p) review round 2: the heading's head renders as a hint; a new top slice,
# the page-only outcomes, a same head and a closed slice are handled; Finish
# has its own placeholders; Previous guide runs per target; the delta order
check "(p) the heading's head has no backticks" grep -qxF '## Since the last guide — <old head, 8 chars>' "$cmd"
check "(p) no backticked head in a heading" not grep -qF '## Since the last guide — `' "$cmd"
check "(p) a new top slice takes the old stack page's head" grep -qF "the old stack page's top head" "$cmd"
check "(p) the page-only outcomes have a slot" grep -qF 'or: previous head no longer exists' "$cmd"
check "(p) a same-head re-run leaves the section out" grep -qF '**Same head:**' <<<"$prev"
check "(p) a closed slice's items follow its commits" grep -qF 'a slice closed since' "$cmd"
check "(p) Finish has its own placeholders" grep -qF '<res> resolved, <open> still open, <new> new since the last guide' "$cmd"
check "(p) Previous guide runs per target" grep -qF 'Resolve, Fetch, Previous guide, Dispatch' "$cmd"
# shellcheck disable=SC2329  # runs through check
order() { awk -v a="$1" -v b="$2" 'index($0,a)&&!x{x=NR} index($0,b)&&!y{y=NR} END{exit !(x&&y&&x<y)}' <<<"$prev"; }
check "(p) the older-head branch precedes plain new commits" order '**This guide is older than the last one**' '**Plain new commits:**'
check "(p) a same head precedes plain new commits" order '**Same head:**' '**Plain new commits:**'

# (c) the page has a Review findings section in the template
check "(c) template has Review findings" grep -qF '## Review findings — /review-stack (<effort>), verified' "$cmd"

# (q) live-run fixes: the session's repo, an emoji Contact heading
check "(q) Resolve sets no session requirement" not grep -qF 'EnterWorktree' <<<"$(section Resolve)"
check "(q) an EnterWorktree refusal removes WT and skips the review" grep -qF '`EnterWorktree` refuses' <<<"$review"
check "(q) Finish names the checkout to start the session in" grep -qF 'start the session in a checkout of' "$cmd"
check "(q) a Contact heading may carry an emoji, in any case" grep -qF 'a heading that contains "Contact" in any case' <<<"$(section Familiarity)"
check "(q) the Contact rule no longer needs the heading to start with it" not grep -qF 'a heading that starts with' <<<"$(section Familiarity)"
check "(q) WT goes where the instructions put worktrees, one name per PR" grep -qF 'named `review-guide-<N>` with any prefix they use' <<<"$review"
check "(q) the .claude/worktrees default must be gitignored" grep -qF 'check-ignore -q` passes on it' <<<"$review"

exit "$fail"
