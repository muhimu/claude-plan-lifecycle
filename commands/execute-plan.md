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
   If non-empty, warn ("Worktree has uncommitted changes — `executing-plans` will likely commit them as part of execution") but continue.

5. **Execution skills available?** This command drives plans via the superpowers plugin. If neither `superpowers:executing-plans` nor `superpowers:subagent-driven-development` appears in the available-skills list, stop: "The superpowers plugin is required (https://github.com/obra/superpowers). Install it and re-run."

## Step 2 — Resolve the plan

This command executes against an **implementation plan**, not a design spec (suffix `-design.md`). The two are paired: the design captures rationale and decisions; the implementation captures the TDD-shaped steps `superpowers:executing-plans` needs to drive. Implementation plans carry no fixed suffix — in practice they end in `-plan.md`, `-implementation.md`, or have no suffix at all. The only reliable discriminator is: same slug, not `-design.md`.

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

Then scan the plan body for **slice headings** matching the regex
`^## PR ([0-9]+): (.+)$`. Collect matches in file order as `SLICES` — a list
of `(N, SLICE_TITLE)` pairs. (The slicing convention — when to slice, heading
format, cascade recipe — is defined in the `plan-frontmatter` skill.)

- **No matches** → single-PR mode. Continue with Steps 3–8 exactly as
  written below.
- **Matches** → stacked mode. Validate: slice numbers must be consecutive
  starting at 1 (`1..M`, no gaps, no duplicates). If malformed, stop:
  "Malformed slice headings in plan: expected consecutive `## PR 1:` ..
  `## PR M:`." Otherwise continue with Step 3 (the execution-skill choice is
  shared and asked once), then jump to the **Stacked execution** section —
  Steps 4–7 do not run in stacked mode.

## Step 3 — Choose the execution skill, then hand off

Two skills can drive a plan task-by-task:

- **`superpowers:subagent-driven-development`** — dispatches each task to a fresh subagent. Higher quality on platforms with subagent support (parallelism, clean per-task context), but uses more tokens. This is the better default when subagents are available.
- **`superpowers:executing-plans`** — drives every task inline in this session. Simpler, lower token cost, no subagent fan-out.

Do **not** hardcode the choice. Decide as follows:

1. **Read the plan's recommendation.** Plans often name a preferred skill (e.g. a `REQUIRED SUB-SKILL:` line near the top). Note which skill(s) it mentions.
2. **Ask the user** via `AskUserQuestion` (header "Exec skill", multi-select disabled) which skill to use. Offer both options. Put the recommended one first and append "(Recommended)" to its label — recommend `subagent-driven-development` if subagents are available in this environment, otherwise `executing-plans`. If the plan explicitly pins one skill, surface that in the option description.
   - If the user picks nothing / cancels, stop: "No execution skill selected."
3. **Invoke the chosen skill** via the `Skill` tool, passing `PLAN_PATH` as the plan to execute. **Stacked mode exception:** do NOT invoke here — record the choice and jump to the Stacked execution section; the skill is invoked once per slice in S3 with a slice-scoped instruction.

Whichever skill runs owns TDD discipline, per-task review checkpoints, and intra-plan verification. Do not duplicate its work — let it run.

When it returns control, proceed to Step 4. If the skill aborts (user cancels, blocking question, etc.), stop with whatever message the skill produced.

## Step 4 — Verification (mandatory, halt-on-red)

Resolve the verify commands once (the verify convention): if the repo's CLAUDE.md declares test and lint commands, use those as `TEST_CMD` / `LINT_CMD`; otherwise default to `TEST_CMD="make test"`, `LINT_CMD="make lint"`. Both checks must pass before the PR is opened.

1. **Tests:** run `$TEST_CMD`. Capture exit code and the last ~20 lines of output as `TEST_TAIL`. If non-zero, **stop**: "Tests failed. Worktree preserved. Fix and re-run when ready." Do not attempt to fix forward — that's the user's call.

2. **Lint:** run `$LINT_CMD`. Capture exit code and the last ~20 lines of output as `LINT_TAIL`. If non-zero, stop: "Lint failed. Worktree preserved. Fix and re-run when ready." Do not fix forward.

If a resolved command does not exist (e.g. `make: *** No rule to make target` on the defaults), stop with: "No verify commands found. Declare the repo's test and lint commands in CLAUDE.md, or provide `make test` / `make lint` targets."

## Step 5 — Commit anything still staged

If `git status --porcelain` is empty, skip this step — `executing-plans` already committed everything.

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

2. **Open draft PR.** Body is constructed from `PLAN_TITLE`, `TEST_TAIL`, `LINT_TAIL`:

   ```bash
   gh pr create --draft --title "<PLAN_TITLE>" --body "$(cat <<'EOF'
   ## Summary

   <2–4 sentences describing what the change does and why, written from the
   actual diff — public-facing, no plans-dir or personal-config references>

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
   - Otherwise, N = 1: the worktree's current branch is a placeholder —
     rename it: `git branch -m "BRANCH[1]"`. Exception: if the current
     branch already has an upstream (`git rev-parse --abbrev-ref @{u}`
     succeeds), do NOT rename; stop and ask the user how to proceed.
   - Otherwise, N > 1: `git checkout -b "BRANCH[N]"` (creates on top of
     BRANCH[N-1], which is checked out at this point).
2. **Execute the slice.** Invoke the Step 3 execution skill with `PLAN_PATH`
   and this scope instruction: "Execute ONLY the tasks under the heading
   `## PR <N>: <SLICE_TITLE>`. Tasks of earlier slices are already
   implemented on this branch. Do not implement anything from later slices.
   The branch may already contain partial work for this slice from an
   earlier failed run — verify per-task state before redoing steps."
3. **Verify** — identical to Step 4 (`$TEST_CMD`, `$LINT_CMD`, halt-on-red),
   capturing `TEST_TAIL[N]` / `LINT_TAIL[N]`. On red, stop: "Slice <N>
   failed <check>. Slices 1..<N-1> are pushed and green; worktree preserved
   on <BRANCH[N]>. Fix and re-run /execute-plan — the resume check will skip
   completed slices."
4. **Commit leftovers** — identical to Step 5, commit message from
   `SLICE_TITLE`.
5. **Push and open draft PR:**

   ```bash
   git push -u origin "BRANCH[N]"
   gh pr create --draft --title "<SLICE_TITLE>" --base "<DEFAULT_BRANCH or BRANCH[N-1]>" --body "$(cat <<'EOF'
   ## Summary

   <2–4 sentences describing what THIS slice changes and why it is
   independently shippable (e.g. "dark: no caller yet" / "behind flag") —
   written from the slice's actual diff; public-facing, no plans-dir
   references>

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
section with the full table, preserving its Summary and Verification
sections untouched:

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
- **Stacked mode:** slice branches are created/renamed only by the main
  session, never by subagents. Slice N's PR always bases on slice N−1's
  branch (slice 1 on `$DEFAULT_BRANCH`). Never open a PR for an unverified slice —
  halt-on-red halts the whole loop. Resume never rewrites already-pushed
  slices: no force-push, including on re-run.
- **PR bodies are public-facing** in both modes: no plans-dir paths,
  no personal-config references.
