# claude-plan-lifecycle

A [Claude Code](https://claude.com/claude-code) plugin for plan-driven development with a full lifecycle:
write implementation plans with structured frontmatter, execute them as single or **stacked draft PRs**,
stamp PR numbers back into the plans, restack after squash-merges, and reap plans automatically once
their PRs merge.

```
write plan ──▶ execute ──▶ stamp ──▶ [restack] ──▶ merge ──▶ reap
 frontmatter   /execute-plan  pr: N     /restack               plans/done/
```

## The idea

Plans are scaffolding, not documentation. They live in a scratch directory, drive the implementation,
and get archived the moment their PR merges — the durable record (intent, decisions, trade-offs)
belongs in the PR description and, for significant decisions, a committed ADR.

To make that safe, every plan carries YAML frontmatter that links it to its PR:

```yaml
---
title: Split state enum
slug: split-state-enum   # shared by a design doc and its implementation plan
issue: 3178              # root issue; the PR that ships the plan carries `Closes #3178`
status: draft            # draft → in-progress → merged (or abandoned)
pr:                      # stamped when the PR opens; the join key for reaping
---
```

`reap-plans` checks each plan group's `pr:` against GitHub: merged → stamp `status: merged`
and move the whole group to `<plans-dir>/done/`. Any member marked `status: abandoned` → the
group moves to `done/` as-is, with no PR check. No PR yet → never touched. So you can be
aggressive about writing plans without accumulating a graveyard.

## Components

| Piece | Type | What it does |
|---|---|---|
| `plan-frontmatter` | skill | Frontmatter spec, status ownership, and the stacked-PR slicing convention (`## PR N:` headings) |
| `reap-plans` | skill | Wraps `bin/reap-plans` with run order and conventions |
| `handoff-prompt` | skill | Generates a self-contained prompt to continue work in a fresh session |
| `/execute-plan` | command | Drives a plan end-to-end in a worktree: execution skill → test/lint verify → draft PR → stamp. Decisions made during the run — the execution skill's and yours, when it asks — land in the PR's Rulings section; a ruling that changes an ADR this plan writes amends it in the same PR, and one touching any other ADR is flagged as `ADR impact`. Discovered-but-deferred work lands in the PR body and a `<date>-<slug>-followups.md` stub. Plans with `## PR N:` slice headings become a stacked-PR chain, linked as a GitHub native stack via `gh stack link` when available |
| `/restack` | command | After a stack's bottom PR squash-merges, after a lower slice gained commits, or when the bottom PR conflicts with or is behind trunk: cascade-rebase every branch whose parent moved, verify the tip, force-with-lease push behind a confirmation gate, retarget the new bottom PR. Discovers the stack from GitHub's native stack object, falling back to the PRs' `## Stack` table or base-branch chain; accepts a stack number |
| `/pr-fix` | command | Fetch PR review comments, verify the first comment of every open, current thread (anyone's, your own inline notes and `/review-stack` findings included) with `/verify-findings`' verifier before planning — a rejected claim becomes a drafted pushback with the evidence, a question or request is planned as before — then plan fixes, implement and push; drafts replies for you to post (never posts to GitHub itself). Takes a PR or stack number plus optional free-text guidance for the fixes; on a stacked PR each fix lands in the slice that owns the code, then `/restack` rebases the slices above |
| `/review-stack` | command | Run the built-in `/code-review` on every open PR of a stack, one review per slice (each scoped to that slice's diff against the slice below), launched together, from a checkout of the stack's top; as each review finishes, one verifier for that slice checks each finding against the slice's code, the PR body, the ADRs, the slice's commit messages and review threads and the slices above, and rejected findings appear only in the summary, grouped by slice. Takes a stack or PR number; review flags such as the effort level pass through. `--comment` posts each slice's confirmed and plausible findings as one review on its PR, plus a file-level comment for a finding outside every hunk (nits prefixed `nit:`), every comment marked so `/pr-fix <stack>` verifies them as review findings rather than treating them as your own notes |
| `/verify-findings` | command | Verify the findings of the latest `/code-review` in the session (local changes, a PR or a stacked PR), or with a PR number that PR's open review comments, by anyone — with `/review-stack`'s verifier: one agent checks each finding against the reviewed code, the PR body, the ADRs and CLAUDE.md files, the commit messages and review threads and, on a stacked PR, the slices above, then prints it as confirmed, plausible or rejected (with the reason). Read-only; `/review-stack` reads its verifier prompt from this command, so the rules live in one place |
| `/pr-triage` | command | Re-prove a PR's claims locally, so you can trust a PR you cannot test yourself: re-runs the tests the PR names, runs its new tests with its code reverted to catch tests that pin nothing, checks that each fix's regression test fails with the fix reverted, runs the base-branch version of every existing test the PR changed, writes throwaway probe tests for commit claims no test covers, and, when the repo's profile names a mutation tool, mutation-tests the changed lines. Writes one page per PR to `local/triage/<N>.md` — outcome, impact, risk and decisions, a claim ledger (reproduced, failed or not reproducible here), at most five proven findings, and what was and was not checked. Takes a stack number (every open slice) or a PR number (that slice only); one detached worktree and one agent per slice, in parallel; asks before running a PR someone else wrote. Never writes to GitHub. Repo-specific rules come from a committed triage profile (below) |
| `/pr-fix-loop` | command | Loop `/pr-fix` autonomously: fix → push → wait for the automated review workflow's next review → repeat, until the review is clean or 5 rounds have run |
| `/bug-hunt` | command | Autonomous red-green-refactor bug hunter with a reviewer-subagent gate |
| `bin/stamp-plans` | script | Stamps `pr: <N>` into every plan file sharing a slug |
| `bin/reap-plans` | script | Archives merged and abandoned plan groups into `<plans-dir>/done/` |
| `bin/link-plans` | script | Shares a gitignored plans dir into a worktree — run manually or as a post-worktree-creation hook |
| `extras/bin-wrapper` | script | Installed under each script's name on your PATH; runs the installed plugin's copy, so updates need no reinstall |

## Install

```bash
# in Claude Code
/plugin marketplace add muhimu/claude-plan-lifecycle
/plugin install plan-lifecycle@claude-plan-lifecycle
```

Put the scripts on your PATH with `extras/bin-wrapper`, which runs the installed plugin's
copy and follows `/plugin` updates without reinstalling. Install one copy
per script name:

```bash
curl -fsSL https://raw.githubusercontent.com/muhimu/claude-plan-lifecycle/main/extras/bin-wrapper -o /tmp/bin-wrapper
for n in reap-plans stamp-plans link-plans; do install -m 755 /tmp/bin-wrapper ~/.local/bin/$n; done
```

Working on the plugin itself? Link a checkout instead: `ln -s "$PWD"/bin/* ~/.local/bin/`.

## Where plans live — the plans-dir convention

Every component (scripts, commands, skills) resolves the plans directory the same way;
first match wins:

1. an explicit flag — `stamp-plans -d`/`-f`, `reap-plans -d`
2. the `PLANS_DIR` environment variable
3. `git config plans.dir` — per-clone and persistent; set it once per repo
4. the default: `local/plans/`

The default is a personal scratch area: put `local` in the repo's `.gitignore` and plans
never hit the remote. Write it without the trailing slash: `local/` matches only a
directory, and in a worktree `link-plans` makes `local` a symlink, which `local/` does not
ignore.

Prefer plans **committed to git**? Point the convention at a tracked directory:

```bash
git config plans.dir docs/plans
```

then declare it in the repo's CLAUDE.md (so new plans get *written* there too — see the
snippet below) and commit what stamping and reaping change. Everything else — frontmatter,
stamping, reaping into `<plans-dir>/done/` — works identically.

## Suggested CLAUDE.md snippet

```markdown
### Plan Lifecycle

- Plans live in `local/plans/` (gitignored scratch). <!-- committed variant: `docs/plans/` + `git config plans.dir docs/plans` -->
- **Frontmatter:** every plan/design doc carries YAML frontmatter — invoke the
  `plan-frontmatter` skill whenever writing one.
- **Stamp on PR open:** as soon as a PR is opened, run
  `stamp-plans -f <plan-file> <pr-number>`. `/execute-plan` does this itself.
- **Durable record lives elsewhere.** A plan is scaffolding — intent and decisions
  belong in the PR description or a committed ADR, never the plans dir.
- **Reap after merge:** invoke the `reap-plans` skill.
- **Worktrees:** after creating a worktree by hand, run `link-plans <worktree-path>` so the
  gitignored `local/` is shared into it (unnecessary if your worktree tool runs it as a
  post-creation hook, e.g. ccmanager). Never `git clean -fdx` a worktree mid-plan — it
  deletes the execution skill's progress ledger. <!-- committed variant: drop this bullet -->
```

## Triage profile

`/pr-triage` grades impact, risk and decisions, and decides what it may run,
from a profile. Without one it uses the generic defaults in the `## Default
profile` section of `references/pr-triage-brief.md`. To tailor it, commit
`.claude/triage-profile.md` with any of the same names as `##` headings —
Impact, Risk, CI never runs, Decisions, Test files, Setup, Commands, Do not
run, Mutation, Accepted here — and each replaces its default. Mutation is off
by default; its `### Mutation` default describes how to declare the tool and
list one entry per directory. Surviving mutants that change behaviour on
changed lines become findings, after every other kind of finding. The profile is read from
the default branch, never from the PR under triage. List shared or heavy
resources (say, an end-to-end suite on a shared VM) under Do not run: triage
then reads the script to judge what a reported run covers instead of running
it.

## Requirements & assumptions

- **`gh`** authenticated (PR creation, merge-state checks).
- **[`gh stack`](https://github.com/github/gh-stack)** extension (optional) — `/execute-plan` links stacked PRs into a GitHub native stack with `gh stack link`; without it (or without native stacks enabled) stacks fall back to hand-kept `## Stack` tables.
- **bash ≥ 4** for `bin/reap-plans` (macOS ships 3.2 — `brew install bash`; the script exits with a
  clear message on older versions).
- **[superpowers](https://github.com/obra/superpowers)** plugin — `/execute-plan` drives plans via
  `superpowers:subagent-driven-development` (default when subagents are available) or
  `superpowers:executing-plans` (checked pre-flight); `/bug-hunt` needs
  `superpowers:requesting-code-review`'s reviewer template; `/pr-fix` uses
  `superpowers:receiving-code-review` when present and degrades gracefully without it.
- **Built-in skills** — `/review-stack` and `/verify-findings` run on the built-in `/code-review`;
  `/pr-fix-loop` runs on the built-in `/loop`.
- **Test and lint verify commands** — declare them in the repo's CLAUDE.md, or provide `make test`
  / `make lint` targets (the default). `/execute-plan` and `/restack` refuse to open/push anything
  unverified.
- **Worktrees** — `/execute-plan` and `/restack` refuse to run in the main checkout. If you use a
  gitignored plans dir with worktrees, share it with `link-plans`: run it inside a new worktree
  (`link-plans` or `link-plans <worktree-path>`), or wire it as a post-worktree-creation hook —
  ccmanager is supported out of the box (config snippet in the script header). Tracked plans dirs
  need nothing.
- Branch names use a `<namespace>/<slug>` shape (e.g. `alice/split-state-enum`); stacked branches
  become `<namespace>/<prefix>-<N>-<slice>`.

## Stacked PRs in one paragraph

Slice a big plan at *writing* time by grouping tasks under `## PR N: <conventional-commits title>`
headings (the `plan-frontmatter` skill says when and where to cut — size, not layer count).
`/execute-plan` then opens one draft PR per slice, each based on the previous, each independently
green, and links them as a GitHub native stack (`gh stack link`), falling back to a `## Stack`
table when that isn't available. Only the tip PR gets stamped into the plan —
under squash-merge cascade, tip-merged ⇔ stack-merged. GitHub's native stack object (the `stack`
field on each PR, `repos/{owner}/{repo}/stacks/{N}`) is the source of truth for ordering; without
one, the commands read the table instead. After each bottom PR merges — or after `/pr-fix` pushes to a lower slice —
`/restack` rebases every branch whose parent moved and retargets the new bottom PR.

## License

MIT
