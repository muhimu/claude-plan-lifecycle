---
description: Rebase a stacked-PR chain after a squash-merge, new commits on a lower PR, or drift from the default branch, then push and retarget — asking first only when the rebase was not clean or rebased the bottom onto a moved trunk.
argument-hint: [stack number, PR number, or branch — optional anchor when the current branch is not part of the stack] [--no-trunk]
---

# Restack

Run whenever a stack (created by `/execute-plan` stacked mode) has a branch
whose parent moved. Three triggers:

- **Bottom merged** — one or more bottom PRs squash-merged to the default
  branch. GitHub retargets the next PR but does not rebase its branch.
- **Parent gained commits** — a lower PR was plain-pushed (typically by
  `/pr-fix`), so the branches above it no longer contain their parent's tip.
- **Trunk moved under the bottom PR** — the bottom PR conflicts with, or is
  required-but-not up to date with, the default branch. Stacked PRs update
  by rebase, not by merging trunk in (GitHub's "Resolve conflicts" on a
  stack says so), so the bottom branch is rebased onto trunk and the rest
  cascades. `--no-trunk` turns this trigger off: `/pr-fix` passes it, because
  its restack only carries a fix upward and must not rewrite slices below
  the fix.

Either way: cascade-rebase every branch whose parent tip is not in its
history, verify the tip, force-with-lease push the rebased branches —
asking first only when the rebase was not clean or rebased the bottom onto a
moved trunk (Step 5.2) — and retarget the new bottom PR if needed.
`/pr-fix` invokes this command after pushing to a non-tip stack PR.

This command runs in the worktree holding the stack. It refuses to run in the
main checkout.

## Step 1 — Pre-flight checks

`$ARGUMENTS` without `--no-trunk` empty → run
`${CLAUDE_PLUGIN_ROOT}/references/session-pr.md` first. This command may
move, and `HOME` must be on the PR's head branch.

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
   (untracked) lines: `link-plans` makes `local` a symlink in the worktree,
   which a `local/` gitignore entry does not match, and untracked files don't
   participate in a rebase. If any NON-`??` line exists, stop:
   "Worktree has uncommitted changes to tracked files. Commit or stash them
   first — restacking with a dirty tree is not supported."
5. **Fetch.** `git fetch origin --prune` (prune so branches GitHub
   auto-deleted after merge disappear from remote-tracking refs).

## Step 2 — Discover the stack

1. **Anchor.** Take `--no-trunk` out of `$ARGUMENTS` first; what's left
   (possibly empty) is `ANCHOR`.
2. **Find the stack** per `${CLAUDE_PLUGIN_ROOT}/references/stack-discovery.md`.
   `STACKED` false → stop: "PR #<N> is not part of a stack." `SLICES` is the
   stack, bottom first; record `STACK_NUM` for the report.
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
   - `i = 1`, merged prefix non-empty, and `B[1]` still contains the newest
     merged slice's head `M`
     (`git merge-base --is-ancestor "$M" "$OLD_HEAD[1]"` succeeds): needs
     rebase. `NEW_BASE[1] = origin/$DEFAULT_BRANCH`, `OLD_BASE[1] = M` (works
     even though GitHub deleted the branch). This rule ignores `--no-trunk`:
     dropping a merged parent is never optional.
   - `i = 1`, merged prefix non-empty but `B[1]` no longer contains `M`: it
     was already restacked after that merge — apply the next rule as if
     nothing had merged.
   - `i = 1`, nothing merged, no `--no-trunk`: read its PR's
     `gh pr view <PR> --json mergeable,mergeStateStatus`. It needs a rebase iff
     `mergeable == CONFLICTING`, or it is behind trunk
     (`git merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "$OLD_HEAD[1]"`
     fails) and trunk requires branches to be up to date. Trunk requires it
     when `mergeStateStatus == BEHIND`, or when either of these prints `true`
     (an error counts as no — classic protection is not always readable):
     ```bash
     gh api repos/{owner}/{repo}/rules/branches/$DEFAULT_BRANCH \
       --jq 'any(.[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy)'
     gh api repos/{owner}/{repo}/branches/$DEFAULT_BRANCH/protection/required_status_checks --jq .strict
     ```
     `mergeStateStatus` alone is not enough: it holds a single state, so
     another one (e.g. `BLOCKED`) can stand in place of `BEHIND`.
     `mergeable == UNKNOWN` means GitHub is still computing — re-query up to
     3 times, 5 seconds apart; still `UNKNOWN` → treat it as no conflict and
     note it for the report below.
     `NEW_BASE[1] = origin/$DEFAULT_BRANCH`,
     `OLD_BASE[1] = $(git merge-base "origin/$DEFAULT_BRANCH" "$OLD_HEAD[1]")`.
     Trunk merely moving ahead, with the PR still clean and not required to
     be up to date, is not a reason to rebase. When this rule rebases `B[1]`,
     set `TRUNK_REBASE`.
   - `i > 1`: needs rebase iff
     `git merge-base --is-ancestor "$OLD_HEAD[i-1]" "$OLD_HEAD[i]"` fails
     **or** `B[i-1]` itself is being rebased (a rewritten parent always
     cascades). `NEW_BASE[i] = B[i-1]` (post-rebase, local),
     `OLD_BASE[i] = $(git merge-base "$OLD_HEAD[i-1]" "$OLD_HEAD[i]")` — this
     is the fork point whether the parent was rewritten (then it equals the
     old parent head) or merely gained commits.
   If no branch needs a rebase and the bottom PR's `mergeable` stayed
   `UNKNOWN`, report "Can't tell yet whether #<PR> conflicts with
   `$DEFAULT_BRANCH` — GitHub is still computing it. Re-run `/restack` in a
   minute." and stop. Otherwise, if the bottom PR's base is already
   `$DEFAULT_BRANCH` and the `## Stack` tables are current, report "Stack
   already restacked — nothing to do." and stop; otherwise skip to Step 6.
5. **Print the plan of record** before touching anything:

   ```
   Stack #<STACK_NUM> (or "stack of #<bottom>"): <plan/stack name if evident from titles>
   Merged:    #<n> <title> … (old base SHA <short OLD_BASE[1]>)   [or: none]
   Restack:   B[1] ← origin/$DEFAULT_BRANCH        (bottom merged | conflicts with trunk | behind trunk)
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
     `git rebase --continue`, and add `B[i]` to `RESOLVED`.
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
been rebased onto its new parent — record `NEW_HEAD[i]`, add `B[i]` to
`RESOLVED` (an earlier run rebased it, likely through a conflict), and skip to
the next branch. The divergence check in 3.1 does not apply to such a branch: its
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

1. **Summary.** For each rebased `B[i]` print: `OLD_HEAD[i]` → `NEW_HEAD[i]` (short
   SHAs), commit count `git rev-list --count "<new-base>..B[i]"`, and a
   range-diff sanity check:
   ```bash
   git range-diff "$OLD_BASE[i]..$OLD_HEAD[i]" "$NEW_BASE[i]..B[i]"
   ```
   Flag any commit that appears added/dropped in the summary.
2. **Gate.** Push without asking unless one of these holds:
   - `TRUNK_REBASE` is set — the bottom was rebased onto a moved trunk, not
     after a merge;
   - `RESOLVED` is not empty — a conflict was resolved or a commit skipped;
   - a range-diff shows an added or dropped commit, or could not be run.

   A clean replay leaves each lower branch's patches as they were; Step 4
   tested only the tip. When one holds, ask via `AskUserQuestion` (header
   "Push", multi-select disabled): "Force-with-lease push <S> rebased
   branch(es)? <which of the above, and the branches or commits concerned>"
   Options: "Push all (Recommended)" / "Abort (keep local rebase)". Anything
   but "Push all" → stop: "Aborted — local branches keep the rebase; remote
   untouched." Under `/pr-fix-loop` nobody can answer: abort instead of
   asking.
3. **Push the rebased branches, bottom-up:**
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
2. **Update `## Stack` tables.** Skip PRs whose `## Stack` section has no
   table (`/execute-plan` writes only a "Part N of M in stack #S" line on
   native stacks — nothing there drifts). The native stack object is
   authoritative; a table is documentation, so keep it truthful. For each surviving PR,
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
  stop, never a retry. Step 5.2 says when the gate asks.
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
