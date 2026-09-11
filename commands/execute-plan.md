---
description: "Execute a plan from the repo's plans dir in the current worktree — runs the chosen execution skill (subagent-driven-development or executing-plans), then verifies (test/lint), opens draft PR, stamps the plan's frontmatter pr: field. Plans with \"## PR N:\" slice headings execute as a stacked-PR chain (one draft PR per slice, each based on the previous; tip PR stamped)."
argument-hint: [plan-path — optional, auto-detected from branch name]
---

# Execute Plan

Drive one plan from the plans dir end-to-end in the current worktree: invoke the chosen execution skill (`superpowers:subagent-driven-development` or `superpowers:executing-plans`) against it, verify (test/lint per the verify convention), commit and push, open a draft PR, and stamp the plan file with the PR number.

This command runs in a dedicated git worktree (created by your worktree manager of choice or plain `git worktree add`). It refuses to run in the main checkout.

## Step 1 — Pre-flight checks

Run each check in order. On any failure, **stop**: print the message and end the turn.

1. **Inside a git worktree?**
   ```bash
   git rev-parse --is-inside-work-tree
   ```
   If not, stop: "Not inside a git working tree."

2. **Worktree, not main checkout?**
   ```bash
   git rev-parse --git-dir
   ```
   If output is `.git` (or an absolute path ending in `/.git`), this is the main checkout, not a worktree. Stop: "This command refuses to run in the main checkout. Create a worktree (`git worktree add` or your worktree manager) and run it there."

   If output contains `.git/worktrees/<name>`, you're in a worktree. Continue.

3. **Branch is not the default branch?** Resolve the repo's default branch once — every later mention of `$DEFAULT_BRANCH` in this command means this value:
   ```bash
   DEFAULT_BRANCH="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
   [ -n "$DEFAULT_BRANCH" ] || DEFAULT_BRANCH="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
   git rev-parse --abbrev-ref HEAD
   ```
   If the current branch is `$DEFAULT_BRANCH` (or `main`/`master`), stop: "Worktree is on a protected branch. Switch to a feature branch first."

4. **Tree state:**
   ```bash
   git status --porcelain
   ```
   If non-empty, warn ("Worktree has uncommitted changes — the execution skill's implementers will likely commit them as part of execution") but continue.

5. **Execution skills available?** This command drives plans via the superpowers plugin. If neither `superpowers:executing-plans` nor `superpowers:subagent-driven-development` appears in the available-skills list, stop: "The superpowers plugin is required (https://github.com/obra/superpowers). Install it and re-run."

## Step 2 — Resolve the plan

This command executes against an **implementation plan**, not a design spec (suffix `-design.md`). The two are paired: the design captures rationale and decisions; the implementation captures the TDD-shaped steps the execution skill needs to drive. Implementation plans carry no fixed suffix — in practice they end in `-plan.md`, `-implementation.md`, or have no suffix at all. The only reliable discriminator is: same slug, not `-design.md`.

If `$ARGUMENTS` is non-empty, treat the first token as the plan path (absolute or relative to cwd). Require it to end in `.md` and exist. Resolve to absolute via `realpath` and skip to Step 3. (No suffix check — the user passed it explicitly, trust them.)

Otherwise auto-detect from the current branch:

1. Get the current branch name from Step 1.3.
2. Strip the branch prefix segment (everything up to and including the first `/`) to produce a slug. Example: `alice/replica-drift` → `replica-drift`.
3. Resolve the plans dir (the plans-dir convention: `PLANS_DIR` env, else `git config plans.dir`, else `local/plans/`) through any symlink first. In shared-plans worktree setups `local/` is a **symlink** to the main repo's `local/`, and not every tool follows symlinks (`find` and a bare shell glob may both miss files under it). Compute the real directory once and glob inside the resolved path:
   ```bash
   PLANS_DIR="${PLANS_DIR:-$(git config --get plans.dir 2>/dev/null || echo local/plans)}"
   PLANS_DIR="$(realpath "$PLANS_DIR" 2>/dev/null)"
   ls -1 "$PLANS_DIR"/*"${slug}"*.md 2>/dev/null
   ```
   Always operate on `$PLANS_DIR` (the realpath), never the raw configured path, for every glob in this step.
4. Partition the matches: files ending in `-design.md` are **designs**; every other match is an **implementation candidate** (whatever its suffix — `-plan.md`, `-implementation.md`, or none). Then decide:
   - **Exactly one implementation candidate** → use it.
   - **Multiple implementation candidates** → list them via `AskUserQuestion` (header "Plan", multi-select disabled). If the user picks nothing, stop.
   - **No implementation candidate, but ≥1 design** → stop with: "Found design for `<slug>` but no implementation plan. Run brainstorming → writing-plans to create one first."
   - **No match at all** → fall back to a generic picker over all `"$PLANS_DIR"/*.md`. This is the escape hatch for plans whose filename doesn't contain the branch slug.

Resolve the chosen path to absolute. Call it `PLAN_PATH`.

Read the plan file's first heading (the `# ` line) to extract a short title — call it `PLAN_TITLE` for use in commit messages and the PR body.

Also read the frontmatter `issue:` field (per the `plan-frontmatter` skill)
and normalize it to `ISSUE_REF`: a bare number `3178` becomes `#3178`; an
`org/repo#N` value is used as-is. If the field is absent or empty, fall back
to the plan body's header block (e.g. a "Root issue:" line); if a root issue
is found there, use it as `ISSUE_REF` and mention in the final report that
the frontmatter should have carried it. If none is found anywhere,
`ISSUE_REF` is empty.

Then scan the plan body for **slice headings** matching the regex
`^## PR ([0-9]+): (.+)$`. Collect matches in file order as `SLICES` — a list
of `(N, SLICE_TITLE)` pairs. (The slicing convention — when to slice, heading
format, cascade recipe — is defined in the `plan-frontmatter` skill.)

**Normalize each `SLICE_TITLE` to a strict Conventional-Commits title** —
it becomes the PR title verbatim, and semantic-PR-title CI (e.g.
amannn/action-semantic-pull-request) rejects titles without a parseable
release type. If the title matches `^<type>(<scope>)? — <desc>` (em-dash
after the type/scope — the legacy heading style), rewrite it to
`<type>(<scope>): <desc>`. Use the normalized form everywhere downstream
(PR titles, commit messages, Stack tables).

- **No matches** → single-PR mode. Continue with Steps 3–8 exactly as
  written below.
- **Matches** → stacked mode. Validate: slice numbers must be consecutive
  starting at 1 (`1..M`, no gaps, no duplicates). If malformed, stop:
  "Malformed slice headings in plan: expected consecutive `## PR 1:` ..
  `## PR M:`." Otherwise continue with Step 3 (the execution-skill choice is
  shared and decided once), then jump to the **Stacked execution** section —
  Steps 4–7 do not run in stacked mode.

## Step 3 — Choose the execution skill, then hand off

Two skills can drive a plan task-by-task:

- **`superpowers:subagent-driven-development`** (SDD) — dispatches each task to a fresh subagent (sequentially — it never runs implementers in parallel), reviews each task, then runs a whole-branch review. Higher quality, more tokens.
- **`superpowers:executing-plans`** — drives every task inline in this session. Simpler, lower token cost.

Do **not** ask the user. Decide:

1. If the plan pins a skill (a `REQUIRED SUB-SKILL:` line naming exactly one of the two), use that.
2. Otherwise use SDD when the `Agent` tool is available in this environment, else `executing-plans`. (This is SDD's own decision graph: plan exists, tasks mostly independent, staying in this session.)

Print one line naming the choice. Then **invoke the chosen skill** via the `Skill` tool, passing `PLAN_PATH` as the plan to execute plus this scope instruction — call it `FINISH_INSTRUCTION`:

> Stop after the final whole-branch review (and its single fix wave, if any). Do NOT invoke `superpowers:finishing-a-development-branch` — `/execute-plan` opens the PR. Return your "Rulings I made" list verbatim in your final message; if you made no rulings, say so.

Both skills end by invoking `finishing-a-development-branch`, which presents merge/PR/keep options that collide with Steps 5–7. The instruction above pre-empts that. Capture the returned rulings list as `RULINGS` (empty if none — `executing-plans` keeps no ledger and normally returns none).

**Stacked mode exception:** do NOT invoke here — record the choice and jump to the Stacked execution section; the skill is invoked once per slice in S3 with a slice-scoped instruction.

Whichever skill runs owns TDD discipline, per-task review checkpoints, and intra-plan verification. Do not duplicate its work — let it run.

When it returns control, proceed to Step 4. If the skill aborts (user cancels, blocking question, etc.), stop with whatever message the skill produced.

## Step 4 — Verification (mandatory, halt-on-red)

Resolve the verify commands once (the verify convention): if the repo's CLAUDE.md declares test and lint commands, use those as `TEST_CMD` / `LINT_CMD`; otherwise default to `TEST_CMD="make test"`, `LINT_CMD="make lint"`. Both checks must pass before the PR is opened.

1. **Tests:** run `$TEST_CMD`. Capture exit code and the last ~20 lines of output as `TEST_TAIL`. If non-zero, **stop**: "Tests failed. Worktree preserved. Fix and re-run when ready." Do not attempt to fix forward — that's the user's call.

2. **Lint:** run `$LINT_CMD`. Capture exit code and the last ~20 lines of output as `LINT_TAIL`. If non-zero, stop: "Lint failed. Worktree preserved. Fix and re-run when ready." Do not fix forward.

If a resolved command does not exist (e.g. `make: *** No rule to make target` on the defaults), stop with: "No verify commands found. Declare the repo's test and lint commands in CLAUDE.md, or provide `make test` / `make lint` targets."

## Step 5 — Commit anything still staged

If `git status --porcelain` is empty, skip this step — the execution skill already committed everything.

Otherwise stage and commit pending changes with a message derived from `PLAN_TITLE`:

```bash
git add -A
git commit -m "<PLAN_TITLE>"
```

Use plain `git commit` — no `--no-verify`. Follow the repo's commit-message conventions.

## Step 6 — Push and open draft PR

1. **Push:**
   ```bash
   git push -u origin "$(git rev-parse --abbrev-ref HEAD)"
   ```
   No `--force`, no `--force-with-lease`. If the push is rejected, stop and ask the user — do not rewrite history.

2. **Open draft PR.** Body is constructed from `ISSUE_REF`, `PLAN_TITLE`, `TEST_TAIL`, `LINT_TAIL`. When `ISSUE_REF` is non-empty, the FIRST line of the body is `Closes <ISSUE_REF>` (followed by a blank line) so the merge auto-closes the root issue. When empty, omit that line entirely — never emit a bare "Closes".

   The PR title must be a strict Conventional-Commits title (`type(scope): description`). `PLAN_TITLE` usually isn't one ("Replica Drift Implementation Plan") — derive the title from the plan's dominant change type and scope (e.g. `feat(deployer): replica drift detection`); never pass a bare prose `PLAN_TITLE` as the title when the repo enforces semantic PR titles.

   ```bash
   gh pr create --draft --title "<PR_TITLE — the Conventional-Commits title derived above>" --body "$(cat <<'EOF'
   Closes <ISSUE_REF>

   ## Summary

   <2–4 sentences describing what the change does and why, written from the
   actual diff — public-facing, no plans-dir or personal-config references>

   ## Rulings

   <one bullet per entry in RULINGS — what was decided, why, and what it
   costs if wrong. These are decisions the execution skill made on the
   author's behalf; the PR is where they become reviewable. Omit the whole
   section when RULINGS is empty.>

   ## Verification

   ### Tests (`$TEST_CMD`)
   ```
   <TEST_TAIL>
   ```

   ### Lint (`$LINT_CMD`)
   ```
   <LINT_TAIL>
   ```
   EOF
   )"
   ```

   Follow the repo's PR-description conventions.

3. **Capture the PR number** from `gh`'s output (it prints the URL on the last line). Extract the number from `https://github.com/<owner>/<repo>/pull/<N>`. Call it `PR_NUM`.

## Step 7 — Stamp the plan group with the PR number

Per the plan-lifecycle convention: every plans file of the effort must carry the PR number so `reap-plans` can archive the group after merge. Stamping is **per slug group** — the design doc and the implementation plan share a `slug` and BOTH get `pr: <N>`. Use the dedicated `stamp-plans` script (this plugin ships it in `bin/`; it must be on PATH):

1. **Has frontmatter** (first line is exactly `---`, closed by a later `---`) — run:
   ```bash
   stamp-plans -f "$PLAN_PATH" <PR_NUM>
   ```
   It reads the slug from `PLAN_PATH`, finds every sibling file with that slug, and sets `pr: <PR_NUM>` (bare YAML integer — no quotes, no `#`) in each one's frontmatter. It reports each stamped file; a non-zero exit means nothing was stamped — surface the error, don't hand-edit around it. Do **not** touch `status` — it stays `in-progress` (this command opens a *draft* PR; `merged` is owned by `reap-plans`). Do not add a body `PR: #<N>` line — frontmatter is authoritative.
2. **No frontmatter** — stop: "Plan has no frontmatter — add it per the `plan-frontmatter` skill, then stamp with `stamp-plans -f <plan> <PR_NUM>`."
3. If the plans dir is gitignored (the default `local/` convention), the stamp needs no commit — `reap-plans` reads it from the filesystem in any worktree. If your plans dir is tracked in git, commit the stamped file(s) to the branch instead.

## Step 8 — Report

Print one final message to chat:

```
Plan executed: <basename of PLAN_PATH>
PR: <PR URL> (#<PR_NUM>, draft)
$TEST_CMD: passed
$LINT_CMD: passed
Plan stamped with PR number.
```

That's the entire output. No JSON sidecar, no aggregation.

## Stacked execution (replaces Steps 4–7 when SLICES is non-empty)

Execute the plan slice-by-slice: one draft PR per slice, each based on the
previous slice's branch, each independently green. The execution skill chosen
in Step 3 is reused for every slice.

### S1 — Derive branch names

1. **Stack prefix.** Default: the first letter of each word of the plan slug,
   capped at 3 letters (`on-demand-mode` → `odm`, `replica-drift` → `rd`).
   Confirm via `AskUserQuestion` (header "Stack prefix", multi-select
   disabled): offer the default first with "(Recommended)", plus one shorter
   variant if the default has 3 letters. The user can type their own via
   Other. Call the result `PREFIX`.
2. **Slice slugs.** For each slice, take the Conventional-Commits scope from
   `SLICE_TITLE` (`feat(api) — …` or `feat(api): …` → `api`). If the title
   has no scope, kebab-case the first two descriptive words after the colon.
   If two slices produce the same slug, append a disambiguating word from the
   title (`api` → `api-db`).
3. **Branch names:** `BRANCH[N] = <ns>/<PREFIX>-<N>-<slice-slug>`, where
   `<ns>` is the namespace segment of the worktree's current branch
   (`alice/on-demand-mode` -> `alice`); if the branch has no `/`, omit the
   namespace (`BRANCH[N] = <PREFIX>-<N>-<slice-slug>`). Print the
   full table (N, branch, PR title, base) before executing anything — this is
   the plan of record for the loop. Base of slice 1 is `$DEFAULT_BRANCH`; base of slice
   N>1 is `BRANCH[N-1]`.

### S2 — Resume check

For each slice N = 1..M in order, the slice is **already done** iff both:

- `git ls-remote --heads origin "BRANCH[N]"` returns a ref, and
- `gh pr list --head "BRANCH[N]" --state open --json number` returns a PR —
  record its number as `PR_NUM[N]`.

Let `R` be the first slice that is not already done (R = M+1 if all are done;
skip straight to S5). If R > 1, run `git checkout "BRANCH[R-1]"` so slice R
branches off the right base. Never re-execute, rebase, or push a slice that
is already done.

### S3 — Per-slice loop (N = R..M)

1. **Branch** — created by the main session only, never by a subagent:
   - If `BRANCH[N]` already exists locally (this is a resume of a slice that
     failed mid-way), just `git checkout "BRANCH[N]"` — partial work from the
     failed run is preserved on it.
   - Otherwise: `git checkout -b "BRANCH[N]"` — from the worktree's current
     branch for N = 1 (the placeholder the worktree was created with; any
     pre-work on it carries over), or on top of BRANCH[N-1] for N > 1
     (checked out at this point).
   - After creating `BRANCH[1]`, tidy the placeholder: if it has no upstream
     (`git rev-parse --abbrev-ref "<placeholder>@{u}"` fails), run
     `git branch -d "<placeholder>"` — lowercase `-d` refuses unmerged work,
     so it only removes a placeholder fully contained in BRANCH[1]. If it
     has an upstream or `-d` refuses, leave it alone silently and continue.
2. **Execute the slice.** Invoke the Step 3 execution skill with `PLAN_PATH`
   and this scope instruction: "Execute ONLY the tasks under the heading
   `## PR <N>: <SLICE_TITLE>`. Tasks of earlier slices are already
   implemented on this branch. Do not implement anything from later slices.
   The branch may already contain partial work for this slice from an
   earlier failed run — verify per-task state before redoing steps. The
   whole-branch review range is `<DEFAULT_BRANCH or BRANCH[N-1]>..HEAD` —
   use that as the review base, not `git merge-base`. Keep the plan's
   workspace (`.superpowers/sdd/<plan>/`) after the final review unless
   this is slice <M> of <M>; earlier slices' parked findings live there."
   followed by `FINISH_INSTRUCTION`. Capture the returned rulings as
   `RULINGS[N]` — only the rulings made during this invocation; earlier
   slices' rulings already sit in their own PR bodies.
3. **Verify** — identical to Step 4 (`$TEST_CMD`, `$LINT_CMD`, halt-on-red),
   capturing `TEST_TAIL[N]` / `LINT_TAIL[N]`. On red, stop: "Slice <N>
   failed <check>. Slices 1..<N-1> are pushed and green; worktree preserved
   on <BRANCH[N]>. Fix and re-run /execute-plan — the resume check will skip
   completed slices."
4. **Commit leftovers** — identical to Step 5, commit message from
   `SLICE_TITLE`.
5. **Push and open draft PR.** The `Closes` line goes on the **tip slice
   only** (N = M) and only when `ISSUE_REF` is non-empty: under the squash
   cascade the tip merges last, so tip-merged ⇔ effort done — an earlier
   slice closing the root issue would close it prematurely. Slices N < M
   never carry a `Closes` line.

   ```bash
   git push -u origin "BRANCH[N]"
   gh pr create --draft --title "<SLICE_TITLE>" --base "<DEFAULT_BRANCH or BRANCH[N-1]>" --body "$(cat <<'EOF'
   Closes <ISSUE_REF>   # ← tip slice (N = M) only, omit otherwise

   ## Summary

   <2–4 sentences describing what THIS slice changes and why it is
   independently shippable (e.g. "dark: no caller yet" / "behind flag") —
   written from the slice's actual diff; public-facing, no plans-dir
   references>

   ## Rulings

   <one bullet per entry in RULINGS[N], as in Step 6; omit the section
   when empty>

   ## Stack

   (filled in after the last slice)

   ## Verification

   ### Tests (`$TEST_CMD`)
   ```
   <TEST_TAIL[N]>
   ```

   ### Lint (`$LINT_CMD`)
   ```
   <LINT_TAIL[N]>
   ```
   EOF
   )"
   ```

   Capture `PR_NUM[N]` from the printed URL. Same rules as Step 6: no
   force-push; a rejected push stops the command.

### S4 — Cross-link the stack

After the last slice's PR exists, update every stack PR body via
`gh pr edit <PR_NUM[N]> --body <updated>`: replace each body's `## Stack`
section with the full table, preserving its Summary, Rulings, and
Verification sections untouched:

```markdown
## Stack (part <N> of <M>)

| PR | Slice | Base |
|----|-------|------|
| #<PR_NUM[1]> | <slice 1 title> | <DEFAULT_BRANCH> |
| #<PR_NUM[2]> | <slice 2 title> | <BRANCH[1]> |
| ... | ... | ... |
```

This is the one sanctioned `gh pr edit` in this command, limited to bodies
of PRs this run (or a resumed run of the same stack) created.

### S5 — Stamp and report

Stamp the **tip PR only**, exactly per Step 7's procedure, with
`<PR_NUM[M]>` as the number (tip merges last under the squash cascade, so
tip-merged ⇔ whole stack merged; `reap-plans` unchanged).

Final report:

```
Stack opened (<M> draft PRs):
#<PR_NUM[1]>  <slice 1 title>   base: <DEFAULT_BRANCH>  test/lint: passed
#<PR_NUM[2]>  <slice 2 title>   base: <BRANCH[1]>   test/lint: passed
...
Plan stamped with tip PR #<PR_NUM[M]>.
Merging is a cascade: after each squash-merge, run /restack in this
worktree — it rebases the surviving branches, verifies the tip, and
retargets the next PR to `$DEFAULT_BRANCH`.
```

## Hard rules

- **Worktree only.** Refuse to run in the main checkout.
- **Never run on the default branch.** Pre-flight stops this.
- **Never push to the default branch.** Only pushes the current feature branch via `git push -u`.
- **No `--force` push, no `--force-with-lease`, no `--no-verify`.** Plain commits, plain pushes; the repo's conventions govern message format.
- **Halt-on-red.** Tests or lint red means stop. Do not fix forward, do not retry.
- **No GitHub mutations beyond `gh pr create --draft`, `gh pr view`/`gh pr list` (read-only), and — stacked mode only — the S4 `gh pr edit` on bodies of PRs this stack created.** No auto-merge, no comment posting, no thread resolution.
- **Plan file is read for execution but never rewritten except to stamp the PR number** (frontmatter `pr:` field). No content edits.
- **Stop semantics:** print the indicated message and end the turn. Do not advance to subsequent steps.
- **Stacked mode:** slice branches are created only by the main
  session, never by subagents. Slice N's PR always bases on slice N−1's
  branch (slice 1 on `$DEFAULT_BRANCH`). Never open a PR for an unverified slice —
  halt-on-red halts the whole loop. Resume never rewrites already-pushed
  slices: no force-push, including on re-run.
- **PR bodies are public-facing** in both modes: no plans-dir paths,
  no personal-config references.
