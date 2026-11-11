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
status: draft            # draft until reap-plans sets merged (or you set abandoned)
pr:                      # stamped when the PR opens; the join key for reaping
---
```

`reap-plans` checks each plan group's `pr:` against GitHub: merged → stamp `status: merged`
and move the whole group to `<plans-dir>/done/`. Any member marked `status: abandoned` → the
group moves to `done/` as-is, with no PR check. No PR yet → never touched. So you can be
aggressive about writing plans without accumulating a graveyard. `stamp-plans` runs
every time a PR opens and ends with a hint when plans can be reaped.

## Components

| Piece | Type | What it does |
|---|---|---|
| `plan-frontmatter` | skill | Frontmatter spec, status ownership, and the stacked-PR slicing convention (`## PR N:` headings) |
| `reap-plans` | skill | Wraps `bin/reap-plans` with run order and conventions |
| `handoff-prompt` | skill | Generates a self-contained prompt to continue work in a fresh session |
| `/execute-plan` | command | Drives a plan end-to-end in a worktree: execution skill → test/lint verify → draft PR → stamp. Decisions made during the run — the execution skill's and yours, when it asks — land in the PR's Rulings section; a ruling that changes an ADR this plan writes amends it in the same PR, and one touching any other ADR is flagged as `ADR impact`. Minor review findings on the branch's code are fixed in the execution skill's final fix pass; what is left lands in the PR body's Follow-ups, grouped for you to read (needs a look, needs a live test, other repo, deferred by the plan), and in a `<date>-<slug>-followups.md` stub that carries the plan's slug, issue and PR, so it is reaped with the plan. Plans with `## PR N:` slice headings become a stacked-PR chain, linked as a GitHub native stack via `gh stack link` when available |
| `/execute-epic` | command | Takes an epic issue and groups its child issues into independent chains — issues that build on each other share a chain and become one stacked plan — reserving ADR, migration and proto numbers per chain so parallel chains cannot collide. After you approve the layout it creates a worktree per chain and writes every chain's plan in parallel; each plan comes to you as it lands, and once you approve it, that chain runs `/execute-plan` unattended (executors take the recommended default and record it as a ruling) while the other plans are still being written or read. Ends with one table of chains, PRs and test/lint results |
| `/restack` | command | After a stack's bottom PR squash-merges, after a lower slice gained commits, or when the bottom PR conflicts with or is behind trunk: cascade-rebase every branch whose parent moved, verify the tip, force-with-lease push (asking first only when the rebase was not clean or rebased the bottom onto a moved trunk), retarget the new bottom PR. Discovers the stack from GitHub's native stack object, falling back to the PRs' `## Stack` table or base-branch chain; accepts a stack number |
| `/backport` | command | Backport a merged PR, or a stack's merged slices (a stack number takes every merged slice; a PR inside a stack takes it and the slices below), to one release branch — the newest `release/<n>.<n>` by default. First checks the fix isn't there already: `-x` trailers, `(#N)` subjects, "backport #N" messages, `git cherry` and PRs based on the release branch. Picks with `-x` in a fresh worktree, running every command as `git -C <worktree>` and never writing to the checkout it started from. On a conflict it traces the conflicting lines: main PRs the fix needs become include-or-rewrite questions, and earlier backports of later main PRs become a revert-and-replay question, each with a recommendation. Regenerates and verifies with the release branch's own Makefiles, CLAUDE.md and pinned tool versions, leaves workflow-bumped pins alone, compares each file with the source, and opens a draft PR titled `<source title> (backport #N to release/X.Y)` |
| `/pr-fix` | command | Fetch PR review comments, verify the first comment of every open, current thread (anyone's, your own inline notes and `/review-stack` findings included) with `/verify-findings`' verifier before planning — a rejected claim becomes a drafted pushback with the evidence, a question or request is planned as before — then plan fixes, implement and push, with each new test shown failing without its fix; replies in bot and your own review threads, removes the Follow-ups entries it fixed from the PR body, corrects what a fix made stale in your own PR's description, lists the open follow-ups, flagging those in the PR's diff, and drafts replies to other reviewers for you to approve before it posts them. Takes a PR or stack number plus optional free-text guidance for the fixes; on a stacked PR each fix lands in the slice that owns the code, then `/restack` rebases the slices above |
| `/review-stack` | command | Run the built-in `/code-review` on every open PR of a stack, one review per slice (each scoped to that slice's diff against the slice below), launched together, from a checkout of the stack's top; as each review finishes, that slice's verifiers (one per group of findings) check each finding against the slice's code, the PR body, the ADRs, the slice's commit messages and review threads and the slices above, and rejected findings appear only in the summary, grouped by slice. Takes a stack or PR number; review flags such as the effort level pass through. The summary lists the findings that are not nits and gives the nits as one count per slice. `--comment` posts each slice's confirmed and plausible findings that are not nits as one review on its PR, plus a file-level comment for a finding outside every hunk; `--nits` lists and posts the nits too (prefixed `nit:`), every comment marked so `/pr-fix <stack>` verifies them as review findings rather than treating them as your own notes |
| `/verify-findings` | command | Verify the findings of the latest `/code-review` in the session (local changes, a PR or a stacked PR), or with a PR number that PR's open review comments, by anyone — with `/review-stack`'s verifier: verifier agents run in parallel (at most six per command, or one per target on stacks larger than six) and check each finding against the reviewed code, the PR body, the ADRs and CLAUDE.md files, the commit messages and review threads and, on a stacked PR, the slices above, then prints it as confirmed, plausible or rejected (with the reason), with nits collapsed to a count. A Follow-ups entry in the PR body never rejects a finding. Read-only; `/review-stack` reads its verifier prompt from this command, so the rules live in one place |
| `/pr-triage` | command | Re-prove a PR's claims locally, so you can trust a PR you cannot test yourself: re-runs the tests the PR names, runs its new tests with its code reverted to catch tests that pin nothing, checks that each fix's regression test fails with the fix reverted, runs the base-branch version of every existing test the PR changed, writes throwaway probe tests for commit claims no test covers, and, when the repo's profile names a mutation tool, mutation-tests the changed lines. On a lower slice of a stack, re-proves every finding at the stack's top and lists the ones a slice above already fixed under Checked. Writes one page per PR to `local/triage/<N>.md`, with an HTML view beside it — outcome, impact, risk and decisions, a claim ledger (reproduced, failed or not reproducible here), at most five proven findings, and what was and was not checked. With `--quiz`, it then asks you up to 3 questions per PR on its decisions and findings and records on the page what you understood and what to read. Takes a stack number (every open slice) or a PR number (that slice only); one detached worktree and one agent per slice, in parallel; asks before running a PR someone else wrote. Never writes to GitHub. Repo-specific rules come from a committed triage profile (below) |
| `/review-guide` | command | Read a colleague's PR or stack without running it and write a local guide that points at the decisions only a human can make: the PR's own rulings, what becomes permanent on merge, which deferred work may wait, and at most five spots where the change departs from the system's shape, each naming the ADR, doc or base evidence it rests on. Also lists what is safe to skim and the riskiest code to hand to `/review-stack`; with `--review [effort]` it runs `/review-stack` at the tip (in a temporary worktree when your checkout is elsewhere) and puts the verified findings on the page, never posting them. Unlike `/pr-triage` it is read-only and runs nothing from the PR: no build or test. Writes one page per PR to `local/review-guide/<N>.md`, plus `stack-<S>.md` for a stack |
| `/pr-fix-loop` | command | Loop `/pr-fix` autonomously: fix → push → wait for the automated review workflow's next review → repeat, until the review is clean or 5 rounds have run. A finding that restates a PR body Follow-ups entry is held, not fixed, and listed for you at the end |
| `/bug-hunt` | command | Autonomous red-green-refactor bug hunter with a reviewer-subagent gate |
| `bin/stamp-plans` | script | Stamps `pr: <N>` into every plan file sharing a slug, then prints a hint when `reap-plans -n` finds plans to archive |
| `bin/reap-plans` | script | Archives merged and abandoned plan groups into `<plans-dir>/done/`, naming each follow-ups stub it moves |
| `bin/link-plans` | script | Shares a gitignored plans dir into a worktree — run manually or as a post-worktree-creation hook |
| `bin/render-report` | script | Writes a styled, self-contained `.html` beside a report's `.md`, laid out for its reader: a triage page (verdict tiles, a ledger filter) or a review guide (stops, a Copy button on each question for the author). Each has a Help panel from `references/<type>-help.md`. Local only |
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
for n in reap-plans stamp-plans link-plans render-report; do install -m 755 /tmp/bin-wrapper ~/.local/bin/$n; done
```

Working on the plugin itself? Link a checkout instead: `ln -s "$PWD"/bin/* ~/.local/bin/`.
Run `make test` and `make lint` (needs shellcheck) before opening a PR.

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

`/review-guide` reads one more heading from the same file, Review lenses: a
repository's own review habits, each a trigger, one read-only check and a
question to ask the author (format: `### Review lenses` in the same default
profile). A check that reads another repository names it as `org/repo` and
uses `gh api`, never a local path. A lens whose check finds something
becomes a Route stop, under the same five-stop cap.

## Requirements & assumptions

- **`gh`** authenticated (PR creation, merge-state checks).
- **[`gh stack`](https://github.com/github/gh-stack)** extension (optional) — `/execute-plan` links stacked PRs into a GitHub native stack with `gh stack link`; without it (or without native stacks enabled) stacks fall back to hand-kept `## Stack` tables.
- **git ≥ 2.40** for `/backport`, which probes picks with `git merge-tree --write-tree --merge-base`.
- **bash ≥ 4** for `bin/reap-plans` (macOS ships 3.2 — `brew install bash`; the script exits with a
  clear message on older versions).
- **[superpowers](https://github.com/obra/superpowers)** plugin — `/execute-plan` drives plans via
  `superpowers:subagent-driven-development` (default when subagents are available) or
  `superpowers:executing-plans` (checked pre-flight); `/bug-hunt` needs
  `superpowers:requesting-code-review`'s reviewer template.
- **Built-in skills** — `/review-stack` and `/verify-findings` run on the built-in `/code-review`;
  `/pr-fix-loop` runs on the built-in `/loop`.
- **`Agent` tool** — `/execute-epic` runs one plan writer and one executor per chain as parallel subagents, and needs `link-plans` and `stamp-plans` on your PATH.
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
table when that isn't available. Only the tip PR carries `Closes` and gets stamped into the plan —
under squash-merge cascade, tip-merged ⇔ stack-merged. The exception is a stack whose slices finish
separate issues: the plan header declares them (`PR 2 closes: #13`) and each slice's PR closes its own. GitHub's native stack object (the `stack`
field on each PR, `repos/{owner}/{repo}/stacks/{N}`) is the source of truth for ordering; without
one, the commands read the table instead. After each bottom PR merges — or after `/pr-fix` pushes to a lower slice —
`/restack` rebases every branch whose parent moved and retargets the new bottom PR.

## License

MIT
