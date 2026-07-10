---
description: Restack a stacked-PR chain after squash-merges to main — discovers the stack from GitHub, cascade-rebases surviving branches, verifies the tip, then (after one confirmation) force-with-lease pushes and retargets the new bottom PR.
argument-hint: [branch or PR number — optional anchor when the current branch is not part of the stack]
---

# Restack

Run after one or more bottom PRs of a stack (created by `/execute-plan`
stacked mode) squash-merged to main. Rebases every surviving branch onto the
new main (cascade), verifies the tip, and — after a single confirmation —
force-with-lease pushes the rebased branches and retargets the new bottom PR
to main.

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
3. **Not on `main`/`master`?** `git rev-parse --abbrev-ref HEAD` — if `main`
   or `master`, stop: "Worktree is on a protected branch. Check out a stack
   branch first."
4. **Clean tree (tracked files).** `git status --porcelain` — ignore `??`
   (untracked) lines: when `local/` is symlinked into the worktree, `?? local` is always present
   (the symlink isn't matched by the `local/` gitignore entry) and untracked
   files don't participate in a rebase. If any NON-`??` line exists, stop:
   "Worktree has uncommitted changes to tracked files. Commit or stash them
   first — restacking with a dirty tree is not supported."
5. **Fetch.** `git fetch origin --prune` (prune so branches GitHub
   auto-deleted after merge disappear from remote-tracking refs).

## Step 2 — Discover the stack

Live truth comes from GitHub; the `## Stack` table in the PR bodies provides
the authoritative *ordering*.

1. **Anchor.** If `$ARGUMENTS` is non-empty, treat the first token as the
   anchor: a number is a PR number (`gh pr view <N> --json headRefName` gives
   its branch), anything else is a branch name. Otherwise the anchor is the
   current branch. If the anchor branch does not match `<ns>/<prefix>-<N>-…`
   (regex `^[^/]+/[a-z0-9-]+-[0-9]+-`), warn but continue — the Stack table is
   the real source.
2. **Find the stack's PRs.** Query open and merged PRs:
   ```bash
   gh pr list --author "@me" --state open --json number,headRefName,baseRefName,title,body --limit 100
   gh pr list --author "@me" --state merged --json number,headRefName,baseRefName,title,headRefOid --limit 50
   ```
   Locate the open PR whose `headRefName` equals the anchor branch (if the
   anchor has no open PR, look for any open PR whose body's `## Stack` table
   mentions the anchor). If none found, stop: "No open stack PR found for
   `<anchor>`. Pass a branch or PR number of the stack as an argument."
3. **Parse the ordering.** Read the `## Stack` table from that PR's body:
   rows `| #<PR> | <slice title> | <base> |` in stack order (bottom first).
   If the body has no `## Stack` table, fall back to reconstructing the chain
   from `baseRefName` links among the queried PRs (each PR's base is the
   previous PR's head; the bottom's base is `main`). If neither yields a
   single linear chain containing the anchor, stop: "Cannot reconstruct a
   linear stack for `<anchor>` — resolve manually."
4. **Partition.** Walk the ordered PR list bottom-up and classify each via
   the query results: `MERGED` slices form the bottom prefix; everything
   after the first non-merged PR must be open — if a merged PR appears
   *after* an open one, stop: "Stack merged out of order (#<N> merged above
   open #<M>) — resolve manually."
   - **Tip merged** (all merged): report "Stack complete — all PRs merged.
     Run `reap-plans` from the main checkout." and stop.
   - **Nothing merged**: report "Nothing to restack — no stack PR has merged
     since the last restack." and stop.
5. **Record SHAs.** From the merged partition, take the newest merged slice's
   `headRefOid` as `OLD_BASE_SHA` — the `<old-base>` for the first surviving
   branch's rebase (works even though GitHub deleted the branch). For every
   surviving branch `B[1..S]` (bottom-up), record its pre-rebase remote head:
   `OLD_HEAD[i] = $(git rev-parse "origin/B[i]")`. If any
   `origin/B[i]` is missing, stop: "Remote branch `B[i]` not found — was it
   deleted? Resolve manually."
6. **Print the plan of record** before touching anything:

   ```
   Stack: <plan/stack name if evident from titles>
   Merged:    #<n> <title> … (old base SHA <short OLD_BASE_SHA>)
   Restack:   B[1] ← origin/main
              B[2] ← B[1]
              …
   ```

## Step 3 — Cascade rebase (local only; remote untouched until Step 5)

For each surviving branch `B[i]`, i = 1..S, in order:

1. **Sync local to remote.** If `B[i]` exists locally and
   `git rev-list --count "origin/B[i]..B[i]"` is > 0, stop: "Local `B[i]`
   has commits not on origin — divergence is yours to resolve." Otherwise:
   ```bash
   git checkout -B "B[i]" "origin/B[i]"
   ```
2. **Rebase:**
   ```bash
   git rebase --onto "$NEW_BASE" "$OLD_BASE" "B[i]"
   ```
   where for i = 1: `NEW_BASE=origin/main`, `OLD_BASE=$OLD_BASE_SHA`; for
   i > 1: `NEW_BASE=B[i-1]` (already rebased locally), `OLD_BASE=$OLD_HEAD[i-1]`
   (the *pre-rebase* head recorded in Step 2.5).
3. **On conflict, assess before resolving.** Inspect each conflicted file
   (`git status`, `git diff`). Two cases:
   - **Mechanical** — the conflict exists only because the squash commit on
     main already contains the merged slice's version of these lines (the
     incoming side and the new base agree in content, only history differs),
     or a stack commit is now fully contained in main (`git diff` after
     resolving is empty → `git rebase --skip`). Resolve and
     `git rebase --continue`.
   - **Genuine** — the merged code and this slice's code changed the same
     lines differently, or you cannot confidently tell. Do NOT resolve, do
     NOT `git rebase --abort`. Stop: "Rebase of `B[i]` hit a genuine
     conflict in `<file>` (<one-line description of the two sides>). Rebase
     state preserved — resolve and `git rebase --continue`, then re-run
     `/restack` (already-rebased branches are re-detected), or
     `git rebase --abort` to back out."
4. Record the new head: `NEW_HEAD[i] = $(git rev-parse "B[i]")`.

**Re-run safety:** if a re-run finds `B[i]` already rebased (its merge-base
with `origin/main` equals `origin/main`'s head and `git rev-list --count
"$NEW_BASE..B[i]"` matches the expected slice commits), skip its rebase and
keep going up the stack.

**Already-restacked exit:** if EVERY surviving branch was skipped as already
rebased and `origin/B[i]` already matches its local `B[i]` for all i (nothing
to push), skip Steps 4–5 and go straight to Step 6 housekeeping; if the
bottom PR's base and the `## Stack` tables are also already current, report
"Stack already restacked — nothing to do." and stop.

## Step 4 — Verify the tip (mandatory, halt-on-red)

`git checkout "B[S]"`, then:

1. `make test` — capture the last ~20 lines as `TEST_TAIL`. Non-zero → stop:
   "Tests failed on the rebased tip. Nothing pushed — the remote stack is
   untouched. Fix (or `git rebase --abort` equivalents via reflog) and
   re-run."
2. `make lint` — same capture as `LINT_TAIL`, same stop on red.

If a `make` target is missing, stop: "Repo does not expose `make test` /
`make lint`. Verify manually, then push by hand per the plan-frontmatter
recipe."

## Step 5 — Confirm, then push

1. **Summary.** For each `B[i]` print: `OLD_HEAD[i]` → `NEW_HEAD[i]` (short
   SHAs), commit count `git rev-list --count "<new-base>..B[i]"`, and a
   range-diff sanity check:
   ```bash
   git range-diff "$OLD_BASE..$OLD_HEAD_i" "$NEW_BASE..B[i]"
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
   `gh pr view <PR of B[1]> --json baseRefName` — if already `main` (GitHub
   auto-retargets when the merged branch is auto-deleted), skip; otherwise
   `gh pr edit <PR of B[1]> --base main`.
2. **Update `## Stack` tables.** For each surviving PR, edit ONLY its
   `## Stack` section (preserve Summary/Verification): annotate merged rows'
   PR column as `#<N> ✅ merged`, and set the first surviving row's Base to
   `main`. Same sanction boundary as `/execute-plan` S4 — bodies of this
   stack's PRs only.
3. **Report:**

   ```
   Restacked <S> branch(es) onto origin/main:
   B[1]  <old-short> → <new-short>  pushed  PR #<n> base: main
   B[2]  <old-short> → <new-short>  pushed  PR #<n> base: B[1]
   …
   make test/lint on tip: passed
   Next: merge #<PR of B[1]> when green, then run /restack again.
   ```

## Hard rules

- **Worktree only; never on `main`/`master`; clean tree required.**
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
