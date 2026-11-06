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

# (f) earlier review threads and the README contact
help="$root/references/review-guide-help.md"
check "(f) Compare reads every review thread" grep -qF 'reviewThreads(first:100,after:$endCursor)' <<<"$(section Compare)"
check "(f) Compare paginates the threads" grep -qF 'gh api graphql --paginate' <<<"$(section Compare)"
check "(f) the thread query pages on pageInfo" grep -qF 'pageInfo{hasNextPage endCursor}' <<<"$(section Compare)"
check "(f) threads come back one line each, bodies capped" grep -qF -- "--jq '.data.repository.pullRequest.reviewThreads.nodes[] | [.isResolved, .comments.nodes[0].path, (.comments.nodes[0].body[0:200])] | @tsv'" <<<"$(section Compare)"
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
check "(g) lens checks are allow-listed" grep -qF 'git show`, `git grep`, `git log`, `git ls-tree`, `git diff` or `gh api` with no `-X`, `--method`, `-f`, `-F` or `--input`' <<<"$(section Lenses)"
check "(g) diff text is quoted into a check" grep -qF 'single-quoted, every quote in it escaped' "$brief"
check "(g) a local path or placeholder repo is skipped" grep -qF 'a local path, `{owner}/{repo}` or a placeholder' <<<"$(section Lenses)"
check "(g) the rule test admits history and lens rules" grep -qF 'the commit that added the removed code, or a lens check' "$brief"
check "(g) a lens spot's Rule is not its output (Ruling 4)" not grep -qF 'its `Rule` is that' <<<"$(section Lenses)"
check "(g) README documents Review lenses" grep -qF 'Review lenses' "$root/README.md"

# (k) follow-ups: lens spots rank with the rest after Filter; history follows
# renames and ignores indentation; lens headings sit one level down
check "(k) the 5-stop cap applies after Filter, lens spots ranked in" grep -qF 'The cap applies after Filter' "$cmd"
check "(k) history follows renames" grep -qF "git log -S'<removed line, trimmed>' --follow" "$brief"
check "(k) lens heading is one level below Review lenses" grep -qF 'one heading level below `Review lenses`' "$root/references/pr-triage-brief.md"

# (c) the page has a Review findings section in the template
check "(c) template has Review findings" grep -qF '## Review findings — <tool> (<effort>), verified' "$cmd"

exit "$fail"
