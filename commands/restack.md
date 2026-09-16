---
description: Restack a stacked-PR chain — after a bottom PR squash-merges, or after a lower PR gained commits (e.g. from /pr-fix). Discovers the stack from GitHub's native stack object, cascade-rebases every branch whose parent moved, verifies the tip, then (after one confirmation) force-with-lease pushes and retargets the new bottom PR.
argument-hint: [stack number, PR number, or branch — optional anchor when the current branch is not part of the stack]
---

# Restack

Run whenever a stack (created by `/execute-plan` stacked mode) has a branch
whose parent moved. Two triggers:

- **Bottom merged** — one or more bottom PRs squash-merged to the default
  branch. GitHub retargets the next PR but does not rebase its branch.
- **Parent gained commits** — a lower PR was plain-pushed (typically by
  `/pr-fix`), so the branches above it no longer contain their parent's tip.

Either way: cascade-rebase every branch whose parent tip is not in its
history, verify the tip, and — after a single confirmation — force-with-lease
push the rebased branches and retarget the new bottom PR if needed.
`/pr-fix` invokes this command after pushing to a non-tip stack PR.

This command runs in the worktree holding the stack. It refuses to run in the
main checkout.

## Step 1 — Pre-flight checks

Run each check in order. On any failure, **stop**: print the message and end
the turn.

1. **Inside a git worktree?** `git rev-parse --is-inside-work-tree` — if not,
   stop: "Not inside a git working tree."
2. **Worktree, not main checkout?** `git rev-parse --git-dir` — if the output
   is `.git` (or an absolute path ending in `/.git`), stop: "This command
   refuses to run in the main checkout. Run it in the stack's worktree."
3. **Not on the default branch?** Resolve it once —
   `DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"`,
   falling back to `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`;
   every later mention of `$DEFAULT_BRANCH` means this value. Then
   `git rev-parse --abbrev-ref HEAD` — if it equals `$DEFAULT_BRANCH` (or
   `main`/`master`), stop: "Worktree is on a protected branch. Check out a
   stack branch first."
4. **Clean tree (tracked files).** `git status --porcelain` — ignore `??`
   (untracked) lines: when `local/` is symlinked into the worktree, `?? local` is always present
   (the symlink isn't matched by the `local/` gitignore entry) and untracked
   files don't participate in a rebase. If any NON-`??` line exists, stop:
   "Worktree has uncommitted changes to tracked files. Commit or stash them
   first — restacking with a dirty tree is not supported."
5. **Fetch.** `git fetch origin --prune` (prune so branches GitHub
   auto-deleted after merge disappear from remote-tracking refs).

## Step 2 — Discover the stack

Live truth comes from GitHub's native stack object (`repos/{owner}/{repo}/stacks/{N}`);
the `## Stack` table in PR bodies is human-facing documentation and only a
fallback for ordering.

1. **Anchor.** If `$ARGUMENTS` is non-empty, treat the first token as the
   anchor. A bare number is tried as a **stack number** first
   (`gh api repos/{owner}/{repo}/stacks/<N>` — 200 means it is a stack), then
   as a PR number; anything else is a branch name. Otherwise the anchor is the
   current branch (`gh pr view --json number` gives its PR).
2. **Find the stack.** For a PR anchor, read
   `gh api repos/{owner}/{repo}/pulls/<PR> --jq .stack` — `{number, position,
   size, base}`. `null` or `size == 1` → stop: "PR #<N> is not part of a
   stack." Then fetch the stack:
   ```bash
   gh api repos/{owner}/{repo}/stacks/<STACK> \
     --jq '.pull_requests[] | {number, state, merged_at, head: .head.ref, base: .base.ref, sha: .head.sha}'
   ```
   The list is in stack order (bottom first). Record `STACK_NUM` for the report.
   **Fallback** (no `.stack` field — older GitHub, or a stack opened before
   native stacks): parse the `## Stack` table (`| #<PR> | <title> | <base> |`)
   from the anchor PR's body, or reconstruct the chain from `baseRefName`
   links among `gh pr list --author "@me" --state all`. If neither yields a
   single linear chain containing the anchor, stop: "Cannot reconstruct a
   linear stack for `<anchor>` — resolve manually."
3. **Partition.** Walk bottom-up: merged PRs form the bottom prefix;
   everything after the first non-merged PR must be open — if a merged PR
   appears *above* an open one, stop: "Stack merged out of order (#<N> merged
   above open #<M>) — resolve manually."
   - **Tip merged** (all merged): report "Stack complete — all PRs merged.
     Run `reap-plans` from the main checkout." and stop.
4. **Record SHAs and decide who needs a rebase.** Surviving branches are
   `B[1..S]` bottom-up. For each, record the pre-rebase remote head
   `OLD_HEAD[i] = $(git rev-parse "origin/B[i]")` (missing → stop: "Remote
   branch `B[i]` not found — was it deleted? Resolve manually."). Then:
   - `i = 1`: needs rebase iff the merged prefix is non-empty.
     `NEW_BASE[1] = origin/$DEFAULT_BRANCH`, `OLD_BASE[1]` = the newest merged
     slice's head SHA (works even though GitHub deleted the branch). Trunk
     drift alone (nothing merged) is not a reason to rebase — merging handles
     it.
   - `i > 1`: needs rebase iff
     `git merge-base --is-ancestor "$OLD_HEAD[i-1]" "$OLD_HEAD[i]"` fails
     **or** `B[i-1]` itself is being rebased (a rewritten parent always
     cascades). `NEW_BASE[i] = B[i-1]` (post-rebase, local),
     `OLD_BASE[i] = $(git merge-base "$OLD_HEAD[i-1]" "$OLD_HEAD[i]")` — this
     is the fork point whether the parent was rewritten (then it equals the
     old parent head) or merely gained commits.
   If no branch needs a rebase: if the bottom PR's base is already
   `$DEFAULT_BRANCH` and the `## Stack` tables are current, report "Stack
   already restacked — nothing to do." and stop; otherwise skip to Step 6.
5. **Print the plan of record** before touching anything:

   ```
   Stack #<STACK_NUM>: <plan/stack name if evident from titles>
   Merged:    #<n> <title> … (old base SHA <short OLD_BASE[1]>)   [or: none]
   Restack:   B[1] ← origin/$DEFAULT_BRANCH        (bottom merged)
              B[2] ← B[1]                         (parent gained 9 commits)
              B[3] ← B[2]                         (cascade)
   Skip:      …                                   (already contains parent tip)
   ```

## Step 3 — Cascade rebase (local only; remote untouched until Step 5)

For each surviving branch `B[i]`, i = 1..S, in order — skipping branches
Step 2.4 marked as not needing a rebase:

1. **Sync local to remote.** If `B[i]` exists locally and
   `git rev-list --count "origin/B[i]..B[i]"` is > 0, stop: "Local `B[i]`
   has commits not on origin — divergence is yours to resolve." Otherwise:
   ```bash
   git checkout -B "B[i]" "origin/B[i]"
   ```
2. **Rebase:**
   ```bash
   git rebase --onto "$NEW_BASE[i]" "$OLD_BASE[i]" "B[i]"
   ```
   with `NEW_BASE[i]` / `OLD_BASE[i]` from Step 2.4 (`B[i-1]` is the
   already-rebased local branch).
3. **On conflict, assess before resolving.** Inspect each conflicted file
   (`git status`, `git diff`). Two cases:
   - **Mechanical** — the conflict exists only because the new base already
     contains this slice's version of these lines (the squash commit on the
     default branch, or a `/pr-fix` commit on the parent that made the same
     change — incoming side and new base agree in content, only history
     differs), or a stack commit is now fully contained in the new base
     (`git diff` after resolving is empty → `git rebase --skip`). Resolve and
     `git rebase --continue`.
   - **Genuine** — the merged code and this slice's code changed the same
     lines differently, or you cannot confidently tell. Do NOT resolve, do
     NOT `git rebase --abort`. Stop: "Rebase of `B[i]` hit a genuine
     conflict in `<file>` (<one-line description of the two sides>). Rebase
     state preserved — resolve and `git rebase --continue`, then re-run
     `/restack` (already-rebased branches are re-detected), or
     `git rebase --abort` to back out."
4. Record the new head: `NEW_HEAD[i] = $(git rev-parse "B[i]")`.

**Re-run safety:** Step 2.4 tests `origin/` heads, so after a resolved
conflict (rebased locally, nothing pushed) every branch still reads as
needing a rebase. Before 3.1, check the *local* branch: if `B[i]` exists and
`git merge-base --is-ancestor "$NEW_BASE[i]" "B[i]"` succeeds, it has already
been rebased onto its new parent — record `NEW_HEAD[i]` and skip to the next
branch. The divergence check in 3.1 does not apply to such a branch: its
local-only commits *are* the rebase. (A conflict resolved with
`git rebase --skip` legitimately drops a commit, so no commit-count check is
used; Step 5's range-diff is where dropped or added commits get flagged.)

## Step 4 — Verify the tip (mandatory, halt-on-red)

`git checkout "B[S]"`, then resolve the verify commands per the verify
convention (CLAUDE.md-declared test/lint commands; default `make test` /
`make lint`):

1. Run `$TEST_CMD` — capture the last ~20 lines as `TEST_TAIL`. Non-zero → stop:
   "Tests failed on the rebased tip. Nothing pushed — the remote stack is
   untouched. Fix (or `git rebase --abort` equivalents via reflog) and
   re-run."
2. Run `$LINT_CMD` — same capture as `LINT_TAIL`, same stop on red.

If no verify commands resolve (no CLAUDE.md declaration, no make targets),
stop: "No verify commands found. Verify manually, then push by hand per the plan-frontmatter
recipe."

## Step 5 — Confirm, then push

1. **Summary.** For each `B[i]` print: `OLD_HEAD[i]` → `NEW_HEAD[i]` (short
   SHAs), commit count `git rev-list --count "<new-base>..B[i]"`, and a
   range-diff sanity check:
   ```bash
   git range-diff "$OLD_BASE[i]..$OLD_HEAD[i]" "$NEW_BASE[i]..B[i]"
   ```
   Every commit should map ≈unchanged (`=` or `!` with only context drift).
   Flag any commit that appears added/dropped in the summary.
2. **Gate.** Ask via `AskUserQuestion` (header "Push", multi-select
   disabled): "Force-with-lease push <S> rebased branch(es)?" Options:
   "Push all (Recommended)" / "Abort (keep local rebase)". Anything but
   "Push all" → stop: "Aborted — local branches keep the rebase; remote
   untouched."
3. **Push bottom-up:**
   ```bash
   git push --force-with-lease origin "B[i]"
   ```
   On lease failure at any branch, stop immediately: "Lease failure on
   `B[i]` — remote moved since fetch. Pushed: <list>. Not pushed: <list>.
   Re-run /restack after inspecting." Never retry with `--force`.

## Step 6 — Retarget and housekeeping

1. **Retarget the new bottom PR.** Check first:
   `gh pr view <PR of B[1]> --json baseRefName` — if already `$DEFAULT_BRANCH` (GitHub
   retargets when a stack PR merges, but does not rebase), skip; otherwise
   `gh pr edit <PR of B[1]> --base "$DEFAULT_BRANCH"`.
2. **Update `## Stack` tables.** The native stack object is authoritative;
   the table is documentation, so keep it truthful. For each surviving PR,
   edit ONLY its `## Stack` section (preserve Summary/Verification): annotate
   merged rows' PR column as `#<N> ✅ merged`, and set the first surviving
   row's Base to `$DEFAULT_BRANCH`. Same sanction boundary as `/execute-plan`
   S4 — bodies of this stack's PRs only.
3. **Report:**

   ```
   Restacked stack #<STACK_NUM> (<R> of <S> branches rebased):
   B[1]  <old-short> → <new-short>  pushed   PR #<n> base: $DEFAULT_BRANCH
   B[2]  <old-short> → <new-short>  pushed   PR #<n> base: B[1]
   B[3]  <short>                    skipped  PR #<n> base: B[2]  (already current)
   …
   test/lint on tip: passed
   Next: merge #<PR of B[1]> when green, then run /restack again.
   ```

## Hard rules

- **Worktree only; never on the default branch; clean tree required.**
- **`--force-with-lease` only** — never bare `--force`; only after the Step 5
  gate; only on the stack's own branches. A lease failure is a full
  stop, never a retry.
- **Nothing remote changes before Step 5.** Steps 1–4 are read-only towards
  origin and GitHub.
- **Halt-on-red / halt-on-divergence / halt-on-genuine-conflict /
  halt-on-lease-failure.** Stop means print the indicated message and end the
  turn.
- **GitHub mutations limited to:** `gh pr edit --base` on the new bottom PR,
  and `## Stack`-table body edits on the stack's own PRs. No merging, no
  comments, no closing.
- **No plan-file edits** — the plans dir is untouched by this command
  (stamping stays with `/execute-plan`, reaping with `reap-plans`).
