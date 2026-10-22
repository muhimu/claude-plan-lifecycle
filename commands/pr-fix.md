---
description: Address PR review feedback — fetch comments, plan fixes, implement, push, then summarize for the user to post replies. Accepts a PR number or a GitHub stack number; on a stacked PR it fixes each comment in the slice that owns the code and restacks the branches above.
argument-hint: [PR or stack number — optional, auto-detects from the current branch or this session's PRs] [free-text guidance for the fixes]
---

# PR Fix

Address review feedback on a pull request, or on every open PR of a stack.
You handle code changes and pushing commits; the user handles all GitHub
replies and thread resolution.

## Resolving the target

Split `$ARGUMENTS`: if the first token is a number it is the target; everything
after it (or all of `$ARGUMENTS` when the first token is not a number) is
`GUIDANCE` — the user's pre-brief, e.g. "skip the getattr nit; fix the
absorb() indexing with a positional map". It is applied in Step 2.

No number → take one from `${CLAUDE_PLUGIN_ROOT}/references/session-pr.md`
first.

Resolve `OWNER/REPO` once: `gh repo view --json nameWithOwner -q .nameWithOwner`.

Resolve the target per `${CLAUDE_PLUGIN_ROOT}/references/stack-discovery.md`,
with `ANCHOR` = the number (never create a PR):

- **The number was a stack** → **stack mode over the whole stack**:
  `TARGET_PRS` = every open PR in `SLICES`, bottom first.
- **`STACKED` false** → **single mode**. `TARGET_PRS = [ANCHOR_PR]`. Fixes
  are committed to the checked-out branch, so it must be the PR's head;
  otherwise stop: "Check out `<head>` (or run from its worktree) first."
- **Otherwise** → **stack mode over one PR**. `TARGET_PRS = [ANCHOR_PR]`;
  `SLICES` and `POSITION/SIZE` are needed to attribute comments to the slice
  that introduced the code, and to know whether a restack is due.

Print the header: `PR #<N>` or `PR #<N> (stack #<S>, slice <POSITION>/<SIZE>)`
or `Stack #<S> (<K> open PRs)`.

**Stack-mode pre-flight** (both variants — the command may check out other
slice branches): `git status --porcelain` must have no non-`??` lines (the
`?? local` symlink line is expected), the current branch must not be the
default branch, and this must be a worktree, not the main checkout
(`git rev-parse --git-dir` ends in `.git/worktrees/<name>`) — `/restack`,
which Step 4b hands off to after a push, refuses the main checkout, so
checking only then would leave the stack half-updated. Otherwise stop:
"Stack mode needs a clean worktree on a stack branch." Then
`git fetch origin`, so the `origin/<branch>` refs that blame, the tip check
and the checkouts read are current.

## Step 1 — Fetch review state

For each PR in `TARGET_PRS`:

```bash
# Inline comments (anchored to specific lines)
gh api "repos/OWNER/REPO/pulls/<PR>/comments" --paginate > <scratchpad>/pr-fix-inline-<PR>.json

# Top-level reviews and issue comments (automated reviewers often post their
# summary as a plain comment, not a review)
gh pr view <PR> --json reviews,comments,headRefName,baseRefName,headRefOid

# Thread state — resolved and outdated threads are skipped, not re-litigated
gh api graphql --paginate -F o=OWNER -F r=REPO -F n=<PR> -f query='query($o:String!,$r:String!,$n:Int!,$endCursor:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved isOutdated comments(first:1){nodes{databaseId}}}}}}}'

# Current diff for context
gh pr diff <PR>
```

Read everything. Drop inline comments whose thread `isResolved` is true.
Mark `isOutdated` threads as candidates for the **Stale** bucket (confirm
against the current code before skipping — outdated only means the line
moved).

**Do not drop the user's own comments.** Self-review notes left inline
("this re-implements X", "extract this block") are work items — bucket them
as **Self-note** (treated like Actionable, no reply drafted). Only skip the
user's *replies* inside threads started by someone else.

**Comments containing `<!-- plan-lifecycle:review-stack -->` are not
self-notes**, though they sit under the user's account: `/review-stack
--comment` posted them from an automated review. Treat each like an external
reviewer's comment, with `review-stack` as the reviewer. The marked
review's body holds the findings on files outside the diff; each of those is
a comment too.

## Step 2 — Classify and plan

**Verify the comments first.** Pick the comments to verify by the rules
`/plan-lifecycle:verify-findings` uses for a PR number (its `## The
findings`), from what Step 1 fetched: the first comment of each open, current
thread, by anyone. In a pr-fix-loop round after the first, take only comments
created after the previous round's push. Leave out a comment `GUIDANCE`
already decides (see **Apply `GUIDANCE` first** below): a guidance pre-ruling
always wins over a verdict. Fetch each PR's head and base so the verifier can
read them without a checkout:
`git fetch origin <baseRefName> pull/<PR>/head`. Then, in a single message,
launch the verifiers for every PR in `TARGET_PRS` that has any — one
`general-purpose` agent per group of its comments, split as that file's
`## Verify` says — with the prompt in the `## Verifier prompt`
section of `${CLAUDE_PLUGIN_ROOT}/commands/verify-findings.md`, filled in
from that PR's **PR** or **Stacked PR** row, with its `(comments)` lines. The
verdicts seed the buckets:

| Verdict | Bucket |
|---|---|
| CONFIRMED / PLAUSIBLE | Actionable — Self-note for the user's own comment; Nit when the kind is `nit` |
| REJECTED, a slice above fixed it | Stale, `fixed in #<M>` |
| REJECTED, any other reason | Pushback, with the verifier's quoted evidence as the drafted reply. For the user's own comment: Self-note marked `rejected: <evidence>`, no reply — the user decides at approval |
| NOT_A_CLAIM | Classify it as below |

A verdict overrides a reviewer's `**blocking**:` prefix; a `nit:` prefix
still makes the item a Nit. Comments of a group that is unverified by that
file's `## Verify` rule are classified as below, their rows marked
`unverified`.

Sort each remaining comment into one bucket:

| Bucket | Meaning | Action |
|---|---|---|
| **Actionable** | Clear code change requested | Plan a code edit |
| **Self-note** | The user's own inline note to self (no review-stack marker) | Plan a code edit, no reply |
| **Question** | Reviewer asking for clarification, no code change | Draft a reply for the user |
| **Suggestion** | Reviewer's preference — requires judgment | Evaluate, then either Actionable or Pushback |
| **Nit** | Stylistic, low-stakes | Plan a code edit (cheap to address) |
| **Pushback** | Suggestion is wrong for this codebase | Draft a reply explaining why |
| **Stale** | Comment is on code that's since been changed — in stack mode, also code a higher slice already fixed | Skip, note it |

Severity prefixes from automated reviewers (`**blocking**:`, `nit:`,
`suggestion:`) seed the bucket of a comment the verifier did not judge —
`blocking` is Actionable unless you find it wrong (then Pushback, with the
evidence); `nit` is Nit.

**Before classifying, invoke the `superpowers:receiving-code-review` skill via the `Skill` tool.** The verifier's verdict is the verification of each claim it judged; the skill owns YAGNI checks, pushback patterns, and the verify-before-implementing discipline for the comments the verifier did not judge (NOT_A_CLAIM, `unverified`) — do not re-derive them here. Posting is governed by the hard rules below, not by that skill's "GitHub Thread Replies" section. If the skill is not available (superpowers plugin not installed), proceed without it and apply the same discipline yourself: verify each claim against the code before implementing, and push back with technical reasoning instead of performative agreement.

**Stack mode — which slice owns the fix.** Default: the PR the comment sits
on. Move a code change *down* the stack when the commented code was
introduced by a lower slice: `git blame -L <line>,<line> origin/<head> -- <file>`
gives the commit; the owning slice is the one whose range
`<its base>..<its head>` contains it (`git merge-base --is-ancestor`). A fix
never moves *up*. Comments on PRs outside `TARGET_PRS` are not fetched, but a
fix attributed to a lower slice still lands there — that slice's branch gets
checked out for it.

**Stack mode — check the tip.** Before planning a fix, read the commented code
at the tip of the stack (`git show origin/<tip branch>:<file>`). If a higher
slice already fixed it, bucket it **Stale** with `fixed in #<M>`, `#<M>` being
the slice whose diff changed that code. The user can still ask for the fix in
the lower slice at the approval step, since each slice merges into the default branch on
its own. When two comments describe the same defect in the same code, plan one fix
and mark the other row `same as #<row>`.

**Apply `GUIDANCE` first.** Before classifying, turn each instruction in
`GUIDANCE` into a pre-ruling: a bucket for a named comment, an approach for a
fix, a reply the user wants drafted. Rows it decided carry `(brief)` in the
Bucket column so the user can see it took. Guidance shapes fixes and drafted
replies only — it never overrides the hard rules and is never posted to GitHub.

Present the full plan to the user as a table (the PR column appears only in
stack mode):

```
| # | PR | File:Line | Reviewer | Verdict | Bucket | Proposed action |
```

Wait for user approval before any code changes. The user may redirect individual rows ("don't do 3, push back instead", "skip 7, it's stale", "keep 5 in #3643"). Apply their changes to the plan.

## Step 3 — Implement

Apply code changes for all approved Actionable + Self-note + Nit items. Group commits by logical area, not one-commit-per-comment — if three nits are in the same file, that's one commit. If two actionable fixes touch unrelated subsystems, that's two commits.

**Rules during implementation:**

- Run the test command (the verify convention: test and lint commands declared in the repo's CLAUDE.md, else `make test` / `make lint`) after each logical group, and the lint command once, after the last group on a branch and before pushing it. If something breaks, stop and report — don't paper over.
- Do not create branches. Commit to the currently checked-out PR branch.
- Commit messages should describe the change, not reference the comment ID — comment IDs rot, code messages don't.

**Stack mode — bottom-up, one slice at a time.** Order the slices that have
fixes bottom-up. For each:

1. `git checkout <slice branch>` (`git checkout -B <branch> origin/<branch>`
   if it has no local copy; if the local copy is ahead of origin, stop —
   divergence is the user's to resolve).
2. Apply that slice's fixes, test, commit.
3. Step 4 push for this slice, then Step 4b restack — the slices above now
   contain this fix before their own fixes are applied, so their tests run
   against the real code. Then continue with the next slice.

## Step 4 — Push

```bash
git push
```

Plain `git push` on the branch you committed to. **Never `--force`**, never
`--force-with-lease` from this command — if the push is rejected, stop and
ask the user.

### Step 4b — Restack (stack mode, non-tip slice only)

If the branch just pushed is not the tip of the stack (`POSITION < SIZE`, or
any lower slice in the bottom-up loop), the branches above no longer contain
their parent's tip. Invoke the `plan-lifecycle:restack` command via the
`Skill` tool with `<STACK_NUM> --no-trunk` as its argument (a stack with no
native number: the fixed PR's number instead of `<STACK_NUM>`) — `--no-trunk`
keeps it from rebasing the bottom slice onto trunk, which would rewrite a
slice below the fix. It owns the cascade rebase, the
tip verification, the force-with-lease push gate, and the `## Stack` table
housekeeping — do not reimplement any of it here. If it stops (genuine
conflict, red tip, lease failure), stop too and relay its message; do not
continue to the next slice.

Pushing to the tip needs no restack.

## Step 5 — Summarize for the user

This is the final output. Print a structured summary the user can use to write GitHub replies themselves. **Do not post any replies to GitHub.** Do not call `gh api POST` or any mutation endpoint on comments/threads.

Format (one block per PR in stack mode, bottom-up):

```
## PR #<N> — fix summary        (stack #<S>, slice <P>/<SIZE> when stacked)

### Addressed (code pushed)
- <file:line> [<reviewer>]: <comment summary>
  → <what you changed, in one line>   (in #<M> when it landed in a lower slice)
  → Suggested reply: "<short factual reply text>"
  → Verifier rejected it: <evidence>   (only for your own note fixed despite a REJECTED verdict)

### Pushed back
- <file:line> [<reviewer>]: <comment summary>
  → Suggested reply: "<technical reasoning for not making the change>"

### Questions for reviewer
- <file:line> [<reviewer>]: <comment summary>
  → Suggested reply: "<clarification question>"

### Stale (no action)
- <file:line> [<reviewer>]: <why it's stale>

### Commits pushed
- <sha> <subject>
- <sha> <subject>

### Restack
- <branch> <old-short> → <new-short>  (or: not needed — tip)
```

The "Suggested reply" lines are drafts for the user to copy, edit, and post manually. Keep them factual and short — no "thanks", no "great catch", no performative agreement (`receiving-code-review` already covers this).

## Hard rules

- **No GitHub mutations from this command.** No mutating `gh api` calls (read-only calls are fine, including Step 1's GraphQL query), no `gh pr review`, no `gh pr comment`, no thread resolution, no `gh pr merge`. The only sanctioned mutations happen inside `/restack` (its own gated lease-push and `## Stack` table edits), never here.
- **Posting replies only on request, after the run.** If the user asks afterwards to post the drafted replies, post each inside its comment's thread (`gh api repos/OWNER/REPO/pulls/<PR>/comments/<id>/replies -f body=…`), never as a top-level PR comment.
- **No force push from this command.** Plain `git push` on the fixed branch. If rejected, stop. Rewriting branches *above* the fixed one is `/restack`'s job, behind its gate.
- **Never touch branches below the fixed slice.** A fix moves down only by being committed on the owning slice's branch in the bottom-up loop.
- **No auto-merge.** Even if the PR is now green, do not merge it.
- **One-at-a-time verification.** After each logical commit, run relevant tests. Batching everything then running tests once at the end hides which change broke what. Lint is the exception: it runs once per branch, before the push (Step 3).
- **Stop on disagreement.** If the user redirects a row in the plan, apply the redirect — don't argue past one push-back.
