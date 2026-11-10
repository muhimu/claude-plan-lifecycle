---
description: Backport a merged PR, or a stack's merged slices, to one release branch — check it isn't there already, pick with -x in a fresh worktree, ask include-or-rewrite for each missing prerequisite, regenerate and verify with the release branch's own tooling, compare with the source, and open a draft PR.
argument-hint: "[PR or stack number — optional, defaults to the current branch's PR] [release/X.Y — optional, defaults to the newest release/<n>.<n>]"
---

# Backport

Backport one merged PR, or a stack's merged slices, to one release branch,
and open a draft PR. Run it from any checkout of the repo, the main
checkout included: it only fetches, reads, and adds a worktree there. All
writes happen in a new worktree. For a second release line, run it again.

The default branch is assumed to squash-merge: each source PR is one
commit there. Release branches merge by rebase, so every commit this
command makes lands on the release branch as it is.

## Step 0 — Resolve

1. **Repo.** `ROOT="$(git rev-parse --show-toplevel)"`; `OWNER/REPO` and
   `DEFAULT` from
   `gh repo view --json nameWithOwner,defaultBranchRef -q '.nameWithOwner + " " + .defaultBranchRef.name'`.
   Then `git -C "$ROOT" fetch -q --prune origin`.
2. **Arguments.** The argument starting `release/` is `TARGET`; the other,
   possibly empty, is `ANCHOR`. With no `TARGET`, take the newest version
   line and print it ("Target: `release/X.Y` (newest; pass one to choose)"):
   ```bash
   git -C "$ROOT" for-each-ref --format='%(refname:lstrip=3)' 'refs/remotes/origin/release/*' \
     | grep -E '^release/[0-9]+\.[0-9]+$' | sort -V | tail -1
   ```
   No match → stop: "No `release/<n>.<n>` branch on origin. Pass the
   target." `git -C "$ROOT" rev-parse -q --verify "refs/remotes/origin/${TARGET}"`
   fails → stop: "`<TARGET>` does not exist on origin." `X.Y` is `TARGET`
   without `release/`.
3. **Sources.** Resolve `ANCHOR` per
   `${CLAUDE_PLUGIN_ROOT}/references/stack-discovery.md`, then pick:
   - **Stack number** (`ANCHOR_PR` empty): every merged slice. Print the
     others as "#M not merged — left out."
   - **PR inside a stack:** that slice and every slice below it
     (`SLICES[1..POSITION]`). Slices above it are left out.
   - **Single PR:** that PR.

   For each, read
   ```bash
   gh pr view <n> -R OWNER/REPO --json number,title,state,baseRefName,mergedAt,mergeCommit,closingIssuesReferences \
     --jq '{n: .number, title, state, base: .baseRefName, mergedAt, sha: .mergeCommit.oid, issues: [.closingIssuesReferences[].number]}'
   ```
   `state` not `MERGED` or `base` not `DEFAULT` → stop: "#<n> is not merged
   into `<DEFAULT>`. Backport merged PRs of the default branch only."
   `SOURCES` is the list sorted by `mergedAt`, oldest first. `A` is the
   number the user passed: `ANCHOR_PR`, or `STACK_NUM` for a stack number.

## Step 1 — Already on the release branch?

`git cherry` alone misses backports that conflicted or were squashed. For
each source `N`/`SHA`, with `R="origin/${TARGET}"`, run all five:

```bash
git -C "$ROOT" log --format='%h %s' -F --grep="cherry picked from commit $SHA" "$R"    # -x trailer
git -C "$ROOT" log --format='%h %s' "$R" | grep -F "(#$N)"                             # subject only
git -C "$ROOT" log --format='%h %s' -i -E --grep="backport (of )?#$N([^0-9]|$)" "$R"   # squashed or by hand
git -C "$ROOT" cherry "$R" "$SHA" "$SHA^"                                              # "-" = same patch
gh pr list -R OWNER/REPO --base "$TARGET" --state all --search "$N" --json number,title,state,url
```

Grep subjects only for `(#N)`: bodies mention PRs they do not contain. A
PR from the search counts only when its title or body says it backports
`#N`; read each one. A merged one means present, an open one stops, a
closed one is ignored.

- **Revert:** when the newest hit is `Revert "…(#N)"`, the source is missing.
- **An open PR backports it** → stop: "#N is already being backported in
  #P (<url>)."
- **All present** → stop with a table `| Source | On <TARGET> as |` and
  "Nothing to backport."
- **Some present** → drop them, print "#N is already on `<TARGET>` as
  <sha> — dropped.", and continue.

`ANCHOR_N`, which names the PR, is the newest source left.

## Step 2 — Worktree

- **Names.** `BRANCH` = `<ns>/backport-<A>-<X.Y>`, `<ns>` being the
  branch namespace the user's CLAUDE.md prescribes, else
  `backport-<A>-<X.Y>`. A re-run derives the same name, so the check
  below catches it. `WT`: where the user's CLAUDE.md puts
  worktrees, else `<parent of the main worktree>/worktrees/<repo name>/<BRANCH with / as ->`.
  The main worktree is the first `worktree` line of
  `git -C "$ROOT" worktree list --porcelain`.
- **Nothing may exist yet.**
  ```bash
  git -C "$ROOT" rev-parse -q --verify "refs/heads/${BRANCH}"
  git -C "$ROOT" ls-remote --exit-code --heads origin "$BRANCH"
  test -e "$WT"
  ```
  Any succeeds → stop, naming each that exists ("branch `<BRANCH>` exists",
  "`<BRANCH>` exists on origin", "`<WT>` exists"): "Finish or remove the
  earlier backport first." Never `cd` into an existing `WT`.
- **Create.** Read the path back from git, never retype it:
  ```bash
  git -C "$ROOT" worktree add --no-track -b "$BRANCH" "$WT" "origin/${TARGET}" \
    && WT="$(git -C "$ROOT" worktree list --porcelain \
      | awk -v b="branch refs/heads/$BRANCH" '/^worktree /{p=substr($0,10)} $0==b{print p}')" \
    && test "$(git -C "$WT" branch --show-current)" = "$BRANCH" \
    && printf 'WT=%s\n' "$WT" \
    && { ! command -v link-plans >/dev/null || link-plans "$WT"; }
  ```
  The first command fails → stop with its error. Shell variables die with
  each call: copy the printed `WT` into every later command, never retype it.

From here on, every command follows the directory rules under Rules.

## Step 3 — Pick

For each source in `SOURCES` order, assert the branch, then pick:

```bash
test "$(git -C "$WT" branch --show-current)" = "$BRANCH" && git -C "$WT" cherry-pick -x "$SHA"
```

Add `-m 1` when `SHA` is a merge commit (`git -C "$WT" rev-list --parents -n1 "$SHA"`
prints three or more SHAs). Every pick that commits, clean or after
`--continue`, may have added generated files the release branch ignores;
`.gitignore` doesn't stop a pick. Drop them:

```bash
git -C "$WT" diff --name-only --diff-filter=A HEAD^ HEAD | git -C "$WT" check-ignore --no-index --stdin
```

For any hits, run `git -C "$WT" rm -q -- <hits>` and
`git -C "$WT" commit -q --amend --no-edit`, and record them as dropped
generated paths. On a conflict, take each file of
`git -C "$WT" diff --name-only --diff-filter=U`:

- **Generated on the target:** ignored there
  (`git -C "$WT" check-ignore -q --no-index -- "$F"` succeeds) and not
  tracked there (`git -C "$WT" cat-file -e "HEAD:${F}"` fails): the default
  branch commits it, the release branch generates it. A file the release
  branch tracks is merged even when a pattern matches it.
  `git -C "$WT" rm -q -- "$F"`, recorded as a dropped generated path.
- **Manifest** (lock files, `go.mod`, `go.sum`, `pyproject.toml`, image
  tags): not traced, since every dependency bump would become a question.
  Keep the release branch's pins (Step 5); a fix that needs the newer
  dependency stops there.
- **Otherwise trace both sides, on the conflicting lines only.** A whole-file
  history would ask about unrelated PRs.
  - **Source side (prerequisites).** Take each `-a,b` range of
    `git -C "$WT" diff -U0 "$SHA^" "$SHA" -- "$F"` (no `,b` means 1;
    `-0,0` is a new file: skip) and blame it in the source's parent:
    `git -C "$WT" blame -s -L "a,+b" "$SHA^" -- "$F"`. For a pure
    insertion (`b` = 0, after line `a`), blame the two lines around it,
    `a` and `a+1`, those that exist. No context lines: their commits are
    unrelated to the fix. Keep each commit
    `c` for which `git -C "$WT" merge-base --is-ancestor "$c" HEAD` fails.
    Map it to its PR by the `(#M)` at the end of its subject, and drop
    every `#M` that Step 1's signals find on `HEAD`. A commit with no
    `(#M)` (pushed to the default branch directly) stays as itself,
    `<sha> <subject>`. The remaining PRs and commits are the
    **prerequisites** → Step 4a.
  - **Release side (later backports).** Take each hunk of
    `git -C "$WT" diff -U0 "$SHA^" HEAD -- "$F"` whose `-a,b` range
    overlaps a source hunk's, and blame its `+c,d` lines on the release
    branch: `git -C "$WT" blame -s -L "c,+d" HEAD -- "$F"` (`d` = 0: skip).
    Don't blame the conflicted file itself: when the fix moves code, both
    halves of a conflict share lines and blame credits release's lines to
    the wrong half. A commit whose `cherry picked from commit <C>` trailer
    names a `C` with `git -C "$WT" merge-base --is-ancestor "$SHA" "$C"`
    true is a backport of a main PR that merged **after** the source →
    Step 4b.
  - **Neither:** resolve the hunk. Keep the release behaviour unless the
    fix is about it. Record one line per hunk: `file:line` — what release
    has, what the fix changes, what was kept.

Resolved → `git -C "$WT" add -- <files>` and
`git -C "$WT" cherry-pick --continue --no-edit`. Prerequisites or later
backports found → Step 4 before continuing.

## Step 4 — Ask

Ask every question this conflict raised in one `AskUserQuestion` call,
the recommended option first and labelled "(Recommended)". More than four
→ a second call for the rest. Record every answer for the PR body.

**4a. One question per prerequisite #M.** State #M's title, its size
(`gh pr view <M> -R OWNER/REPO --json title,files,additions,deletions,mergeCommit`;
`MSHA` = `.mergeCommit.oid`; for a bare commit, the commit itself and
`git -C "$WT" show --stat`),
whether it applies cleanly
(`git -C "$WT" merge-tree --write-tree --name-only --merge-base "$MSHA^" HEAD "$MSHA"`
exits 0, else the files it lists) and what it brings beyond the lines the
fix needs.

- **Include #M.** Recommended when #M is a refactor or a fix the release
  line should have anyway, applies cleanly, and adds no feature, API,
  config or schema change. #M joins `SOURCES` in `mergedAt` order; a
  stack slice joins with its missing slices below it.
- **Rewrite on release.** Recommended when #M brings a feature, API,
  config or schema change, has missing prerequisites of its own, or is
  large next to the fix. Resolve the source's hunks by hand with the
  smallest change that works on the release branch. When the source can't
  be picked at all, write it as a new commit with the source's title and
  the body ``Backport of #N to `release/X.Y`, applied by hand: <reason>.``

**4b. One question per pick whose conflicted files hold backports of later
main PRs.** A revert undoes a whole commit, so ask per pick, not per file.
Name the backports across all its files, and their main PRs.

- **Revert and replay.** Recommended when those backports account for
  most of the conflict's release-side lines. Lines of PRs not being
  backported are dropped while resolving.
- **Resolve by hand.** Recommended otherwise: Step 3's "Neither" path.

**When any answer is Include or Revert and replay**, rebuild in this
order:

1. `git -C "$WT" cherry-pick --abort`. Picks already made stay.
2. Revert the chosen backports, newest first: `git -C "$WT" revert --no-edit <backport>`.
   A revert that conflicts is resolved like Step 3's "Neither" path, then
   `git -C "$WT" revert --continue --no-edit`, and listed under Applied by
   hand.
3. Pick the remaining `SOURCES`, included prerequisites among them, in
   `mergedAt` order (Step 3).
4. Replay the reverted backports' main originals in `mergedAt` order:
   `git -C "$WT" cherry-pick -x <C>`, with Step 3's handling.

**Otherwise** (every answer Rewrite or Resolve by hand) don't abort:
resolve the live conflict in place and continue the pick (Step 3).

A prerequisite or backport already answered is never asked again: when a
later pick's trace finds it, apply the earlier answer.

## Step 5 — Pins

- **Manifest conflicts** (lock files, `go.mod`, `pyproject.toml`, image
  tags): keep the release branch's pins.
- **The fix needs a newer dependency on this line:** stop, naming it. That
  dependency needs its own backport and release first.
- **Never bump by hand a pin a workflow bumps.** For each pin the fix
  touches, read the hits of
  `git -C "$ROOT" grep -l -i -E 'repository_dispatch|workflow_dispatch|bump' "${REF}" -- .github/workflows`
  for `REF` = `origin/${DEFAULT}` and `origin/${TARGET}`. Name the
  workflow that bumps it on release branches under Pins, and leave the pin
  to it.

Pins come before verification, so the tree that is verified is the tree that is pushed.

## Step 6 — Regenerate and verify with the release branch's tooling

- **Where:** each directory whose Makefile owns files changed in
  `git -C "$WT" diff --name-only "origin/${TARGET}" HEAD`.
- **What:** the commands the release branch's CLAUDE.md files declare,
  else `make test` and `make lint`. None found → stop: "No verify commands
  found. Declare the repo's test and lint commands in CLAUDE.md, or
  provide `make test` / `make lint` targets."
- **Generate first:** the targets that CLAUDE.md or the Makefile names
  for generated code (`generate`, `gen`, `mocks`, `generate-proto`, …):
  `cd "$WT/<dir>" && make <target>`.
- **Tool versions:** a tool from PATH whose version the release branch
  pins (`go.mod`, `tools/go.mod`, Makefile, CI workflow) differently is
  installed at the pinned version into a temp dir that goes first on PATH
  for this run (e.g. `GOBIN=<tmp>/bin go install <module>@<version>`).
  The PR body names the version used.
- **Regenerated tracked files:** commit them as
  `chore: regenerate <what> for release/X.Y`.
- **Skipped tests:** list them for the Test plan.
- **Red run:** re-run only the failing command on the untouched release
  tip, in a throwaway worktree outside `ROOT`:
  `TMP="$(mktemp -d)/release" && printf 'TMP=%s\n' "$TMP"` (copy the
  printed path, as with `WT`),
  `git -C "$ROOT" worktree add --detach "$TMP" "origin/${TARGET}"`, then
  generate and run with `cd "$TMP/<dir>" && …`, then
  `git -C "$ROOT" worktree remove --force "$TMP"`.
  - **Red there too:** pre-existing. List it under Test plan; carry on.
  - **Red only here, on a missing symbol:** find the commit that brought
    it, `git -C "$WT" log -S<symbol> --format='%h %s' "HEAD..origin/${DEFAULT}"`, and
    ask as in Step 4a. No pick is in progress, so nothing is aborted:
    Include → pick #M on top (Step 3), then redo Steps 5 and 6; Rewrite →
    add the missing code by hand, recorded under Applied by hand.
  - **Red only here, in code a resolution or rewrite touched** (lint
    included): fix it and record it under Applied by hand.
  - **Anything else:** stop before pushing, with the failure and `WT`. No
    PR is opened unverified.

## Step 7 — Compare with the source

For each source `S`, find its pick `P` by trailer
(`git -C "$WT" log --format=%H -F --grep="cherry picked from commit $S" "origin/${TARGET}..HEAD"`)
and compare file by file, over the union of both commits' files:

```bash
git -C "$WT" diff "$S^" "$S" -- "$F" | git patch-id --stable
git -C "$WT" diff "$P^" "$P" -- "$F" | git patch-id --stable
```

Each file is **same** (equal ids), **differs**, **dropped** (in `S`
only) or **added** (in `P` only). Rewrite, revert and regenerate commits
are listed as by hand. A replay `R` of main's `C` is compared twice: with
`C`, as above, and with the release backport `B` it replaced (`B^ B`
against `R^ R`). Otherwise a hunk the old backport left out on purpose
could come back unnoticed. Every file that differs needs a reason.

## Step 8 — Push and open a draft PR

```bash
test "$(git -C "$WT" branch --show-current)" = "$BRANCH" && git -C "$WT" push -u origin "$BRANCH"
cd "$WT" && gh pr create -R OWNER/REPO --draft --base "$TARGET" --head "$BRANCH" \
  --title "$(gh pr view "$ANCHOR_N" -R OWNER/REPO --json title -q .title) (backport #$ANCHOR_N to release/X.Y)" \
  --body-file "$BODY"
```

The title is fetched, never pasted: a title with backticks or `$` would
run inside double quotes. It keeps the source's conventional prefix, so
it passes a semantic PR-title check; a `[release/X.Y]` prefix fails it.
Create the body file with `BODY="$(mktemp)" && printf 'BODY=%s\n' "$BODY"`
and copy the printed path, as with `WT`. Write the body to it with the Write
tool or a quoted `<<'EOF'` heredoc, leaving out empty sections. In the
block above, every variable is written out as its value: shell variables
don't survive between calls.

```markdown
Backport of #N1, #N2 and #N3 to `release/X.Y`.

Refs #I

## Backported
| Source | Commit | Files same / differs / dropped / added |

## Applied by hand
- `file:line` — release has …, the fix changes …, kept … (one per hunk; rewrites, reverts, replays, fixes)

## Not backported
- #M <title> — left out: <slice above the anchor / not merged / rewritten instead>
- Already on `release/X.Y`: #N as <sha>

## Pins
- <pin kept, or the workflow that bumps it>

## Test plan
- `<command>` in `<dir>`: <result> (<n> skipped: <which>)
- Generated with <tool>@<version>
- Pre-existing on `release/X.Y`: <failing command>
```

`Backport of` lists every source, oldest first; `Refs` has one line per
issue the sources close, and is left out when they close none. Final
report: the PR URL, `WT`, the compare table, and anything left out.

## Rules

- **Directories.** Every git command is `git -C "$WT" …` (or
  `git -C "$ROOT" …` for reads and worktree adds). Every other command is
  `cd "$WT" && …` (Step 6's throwaway: `cd "$TMP" && …`) in the same call:
  never a bare `cd`, never `;` after one. Every
  subagent prompt starts with "Work in `<WT>`: run every shell command as
  `cd <WT> && …`."
- **Assert the branch** before every pick, commit and push.
- **Never write to `ROOT`'s working tree.** Never `cherry-pick -n` (it
  can't be aborted) and never a bare `git stash` (the stash is shared
  across worktrees).
- **Brace refs before a colon:** `"${REF}:path"`. zsh reads `$REF:a` as a
  modifier.
- **No force push. The only GitHub write is `gh pr create --draft`.**
