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
status: draft            # draft → in-progress → merged (or abandoned)
pr:                      # stamped when the PR opens; the join key for reaping
---
```

`reap-plans` checks each plan group's `pr:` against GitHub: merged → stamp `status: merged`
and move the whole group to `<plans-dir>/done/`. No PR yet → never touched. So you can be
aggressive about writing plans without accumulating a graveyard.

## Components

| Piece | Type | What it does |
|---|---|---|
| `plan-frontmatter` | skill | Frontmatter spec, status ownership, and the stacked-PR slicing convention (`## PR N:` headings) |
| `reap-plans` | skill | Wraps `bin/reap-plans` with run order and conventions |
| `handoff-prompt` | skill | Generates a self-contained prompt to continue work in a fresh session |
| `/execute-plan` | command | Drives a plan end-to-end in a worktree: execution skill → test/lint verify → draft PR → stamp. Plans with `## PR N:` slice headings become a stacked-PR chain |
| `/restack` | command | After a stack's bottom PR squash-merges, or after a lower slice gained commits: cascade-rebase every branch whose parent moved, verify the tip, force-with-lease push behind a confirmation gate, retarget the new bottom PR. Discovers the stack from GitHub's native stack object; accepts a stack number |
| `/pr-fix` | command | Fetch PR review comments, plan fixes, implement and push; drafts replies for you to post (never posts to GitHub itself). Takes a PR or stack number plus optional free-text guidance for the fixes; on a stacked PR each fix lands in the slice that owns the code, then `/restack` rebases the slices above |
| `/pr-fix-loop` | command | Loop `/pr-fix` autonomously: fix → push → wait for the automated review workflow's next review → repeat, until the review is clean or 5 rounds have run |
| `/bug-hunt` | command | Autonomous red-green-refactor bug hunter with a reviewer-subagent gate |
| `bin/stamp-plans` | script | Stamps `pr: <N>` into every plan file sharing a slug |
| `bin/reap-plans` | script | Archives merged plan groups into `<plans-dir>/done/` |
| `bin/link-plans` | script | Shares a gitignored plans dir into a worktree — run manually or as a post-worktree-creation hook |

## Install

```bash
# in Claude Code
/plugin marketplace add muhimu/claude-plan-lifecycle
/plugin install plan-lifecycle@claude-plan-lifecycle
```

Put the scripts on your PATH:

```bash
cp bin/* ~/.local/bin/
```

## Where plans live — the plans-dir convention

Every component (scripts, commands, skills) resolves the plans directory the same way;
first match wins:

1. an explicit flag — `stamp-plans -d`/`-f`, `reap-plans -d`
2. the `PLANS_DIR` environment variable
3. `git config plans.dir` — per-clone and persistent; set it once per repo
4. the default: `local/plans/`

The default is a personal scratch area: put `local/` in the repo's `.gitignore` and plans
never hit the remote.

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
- **Stamp on PR open:** as soon as a PR is opened, run `stamp-plans <pr-number>`.
  `/execute-plan` does this itself.
- **Durable record lives elsewhere.** A plan is scaffolding — intent and decisions
  belong in the PR description or a committed ADR, never the plans dir.
- **Reap after merge:** invoke the `reap-plans` skill.
- **Worktrees:** after creating a worktree by hand, run `link-plans <worktree-path>` so the
  gitignored `local/` is shared into it (unnecessary if your worktree tool runs it as a
  post-creation hook, e.g. ccmanager). Never `git clean -fdx` a worktree mid-plan — it
  deletes the execution skill's progress ledger. <!-- committed variant: drop this bullet -->
```

## Requirements & assumptions

- **`gh`** authenticated (PR creation, merge-state checks).
- **bash ≥ 4** for `bin/reap-plans` (macOS ships 3.2 — `brew install bash`; the script exits with a
  clear message on older versions).
- **[superpowers](https://github.com/obra/superpowers)** plugin — `/execute-plan` drives plans via
  `superpowers:subagent-driven-development` (default when subagents are available) or
  `superpowers:executing-plans` (checked pre-flight); `/pr-fix` uses
  `superpowers:receiving-code-review` when present and degrades gracefully without it.
- **Test and lint verify commands** — declare them in the repo's CLAUDE.md, or provide `make test`
  / `make lint` targets (the default). `/execute-plan` and `/restack` refuse to open/push anything
  unverified.
- **Worktrees** — `/execute-plan` and `/restack` refuse to run in the main checkout. If you use a
  gitignored plans dir with worktrees, share it with `link-plans`: run it inside a new worktree
  (`link-plans` or `link-plans <worktree-path>`), or wire it as a post-worktree-creation hook —
  ccmanager is supported out of the box (config snippet in the script header). Tracked plans dirs
  need nothing; the scripts resolve symlinks via `realpath`.
- Branch names use a `<namespace>/<slug>` shape (e.g. `alice/split-state-enum`); stacked branches
  become `<namespace>/<prefix>-<N>-<slice>`.

## Stacked PRs in one paragraph

Slice a big plan at *writing* time by grouping tasks under `## PR N: <conventional-commits title>`
headings (the `plan-frontmatter` skill says when and where to cut — size, not layer count).
`/execute-plan` then opens one draft PR per slice, each based on the previous, each independently
green, and cross-links them with a `## Stack` table. Only the tip PR gets stamped into the plan —
under squash-merge cascade, tip-merged ⇔ stack-merged. GitHub's native stack object (the `stack`
field on each PR, `repos/{owner}/{repo}/stacks/{N}`) is the source of truth for ordering; the
table is documentation. After each bottom PR merges — or after `/pr-fix` pushes to a lower slice —
`/restack` rebases every branch whose parent moved and retargets the new bottom PR.

## License

MIT
