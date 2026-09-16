---
description: Address PR review feedback — fetch comments, plan fixes, implement, push, then summarize for the user to post replies. Accepts a PR number or a GitHub stack number; on a stacked PR it fixes each comment in the slice that owns the code and restacks the branches above.
argument-hint: [PR number or stack number — optional, auto-detects from current branch]
model: sonnet
---

# PR Fix

Address review feedback on a pull request, or on every open PR of a stack.
You handle code changes and pushing commits; the user handles all GitHub
replies and thread resolution.

## Resolving the target

Resolve `OWNER/REPO` once: `gh repo view --json nameWithOwner -q .nameWithOwner`.

- **`$ARGUMENTS` is a bare number** — try it as a **stack number** first:
  `gh api repos/OWNER/REPO/stacks/<N>`. A 200 means **stack mode over the whole
  stack**: `TARGET_PRS` = every PR in `.pull_requests[]` with `state == open`,
  in stack order (bottom first). A 404 means it is a PR number; continue below.
- **PR number** (given, or auto-detected via
  `gh pr view --json number,headRefName,baseRefName,url` for the current
  branch). If there is no PR, stop and tell the user — do not create one.
  Read `gh api repos/OWNER/REPO/pulls/<PR> --jq .stack`:
  - `null` or `size == 1` → **single mode**. `TARGET_PRS = [PR]`.
  - otherwise → **stack mode over one PR**. `TARGET_PRS = [PR]`, but record
    `STACK_NUM`, `POSITION`, `SIZE`, and fetch the ordered slice list from
    `repos/OWNER/REPO/stacks/<STACK_NUM>` (needed to attribute comments to
    the slice that introduced the code, and to know whether a restack is due).

Print the header: `PR #<N>` or `PR #<N> (stack #<S>, slice <POSITION>/<SIZE>)`
or `Stack #<S> (<K> open PRs)`.

**Stack-mode pre-flight** (both variants — the command may check out other
slice branches): `git status --porcelain` must have no non-`??` lines (the
`?? local` symlink line is expected), and the current branch must not be the
default branch. Otherwise stop: "Stack mode needs a clean tree on a stack
branch."

## Step 1 — Fetch review state

For each PR in `TARGET_PRS`:

```bash
# Inline comments (anchored to specific lines)
gh api "repos/OWNER/REPO/pulls/<PR>/comments" --paginate > <scratchpad>/pr-fix-inline-<PR>.json

# Top-level reviews and issue comments (automated reviewers often post their
# summary as a plain comment, not a review)
gh pr view <PR> --json reviews,comments,headRefName,baseRefName,headRefOid

# Thread state — resolved and outdated threads are skipped, not re-litigated
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved isOutdated comments(first:1){nodes{databaseId}}}}}}}' -F o=OWNER -F r=REPO -F n=<PR>

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

## Step 2 — Classify and plan

Sort each remaining comment into one bucket:

| Bucket | Meaning | Action |
|---|---|---|
| **Actionable** | Clear code change requested | Plan a code edit |
| **Self-note** | The user's own inline note to self | Plan a code edit, no reply |
| **Question** | Reviewer asking for clarification, no code change | Draft a reply for the user |
| **Suggestion** | Reviewer's preference — requires judgment | Evaluate, then either Actionable or Pushback |
| **Nit** | Stylistic, low-stakes | Plan a code edit (cheap to address) |
| **Pushback** | Suggestion is wrong for this codebase | Draft a reply explaining why |
| **Stale** | Comment is on code that's since been changed | Skip, note it |

Severity prefixes from automated reviewers (`**blocking**:`, `nit:`,
`suggestion:`) seed the bucket — `blocking` is Actionable unless verification
shows it wrong (then Pushback, with the evidence); `nit` is Nit.

**Before classifying, invoke the `superpowers:receiving-code-review` skill via the `Skill` tool.** That skill owns the verify-before-implementing discipline, YAGNI checks, and pushback patterns — do not re-derive them here. If the skill is not available (superpowers plugin not installed), proceed without it and apply the same discipline yourself: verify each claim against the code before implementing, and push back with technical reasoning instead of performative agreement.

**Stack mode — which slice owns the fix.** Default: the PR the comment sits
on. Move a code change *down* the stack when the commented code was
introduced by a lower slice: `git blame -L <line>,<line> origin/<head> -- <file>`
gives the commit; the owning slice is the one whose range
`<its base>..<its head>` contains it (`git merge-base --is-ancestor`). A fix
never moves *up*. Comments on PRs outside `TARGET_PRS` are not fetched, but a
fix attributed to a lower slice still lands there — that slice's branch gets
checked out for it.

Present the full plan to the user as a table (the PR column appears only in
stack mode):

```
| # | PR | File:Line | Reviewer | Bucket | Proposed action |
```

Wait for user approval before any code changes. The user may redirect individual rows ("don't do 3, push back instead", "skip 7, it's stale", "keep 5 in #3643"). Apply their changes to the plan.

## Step 3 — Implement

Apply code changes for all approved Actionable + Self-note + Nit items. Group commits by logical area, not one-commit-per-comment — if three nits are in the same file, that's one commit. If two actionable fixes touch unrelated subsystems, that's two commits.

**Rules during implementation:**

- Run the project's test/lint suite after each logical group. If something breaks, stop and report — don't paper over.
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
`Skill` tool with `STACK_NUM` as its argument. It owns the cascade rebase, the
tip verification, the single force-with-lease gate, and the `## Stack` table
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

- **No GitHub mutations from this command.** No `gh api POST/PATCH/DELETE`, no `gh pr review`, no `gh pr comment`, no thread resolution, no `gh pr merge`. Read-only `gh` only. The only sanctioned mutations happen inside `/restack` (its own gated lease-push and `## Stack` table edits), never here.
- **No force push from this command.** Plain `git push` on the fixed branch. If rejected, stop. Rewriting branches *above* the fixed one is `/restack`'s job, behind its gate.
- **Never touch branches below the fixed slice.** A fix moves down only by being committed on the owning slice's branch in the bottom-up loop.
- **No auto-merge.** Even if the PR is now green, do not merge it.
- **One-at-a-time verification.** After each logical commit, run relevant tests. Batching everything then running tests once at the end hides which change broke what.
- **Stop on disagreement.** If the user redirects a row in the plan, apply the redirect — don't argue past one push-back.
