---
name: plan-frontmatter
description: Use when writing any implementation plan or design doc to the repo's plans dir — defines the YAML frontmatter (title/slug/status/pr) every plan must carry and the rule that a design and its implementation plan share one slug.
---

# Plan Frontmatter

Every plan or design doc written to the plans dir (resolved per the plans-dir
convention: `PLANS_DIR` env, else `git config plans.dir`, else default
`local/plans/`) starts with YAML frontmatter:

```yaml
---
title: <human-readable name of the effort>
slug: <kebab-case key, SHARED across all files of one effort>
status: draft
pr:
---
```

## Fields

- **title** — human-readable name. Informational only; no tooling reads it.
- **slug** — the grouping key. A design doc and its implementation plan (and any
  follow-up docs) for the SAME unit of work carry the SAME slug. `reap-plans`
  groups files by slug and reaps a whole group together. Pick the slug once
  (kebab-case, e.g. `split-state-enum`) and reuse it verbatim on every related
  file.
- **status** — one of `draft` | `in-progress` | `merged` | `abandoned`. A bare
  plain scalar — no quotes (`status: draft`, not `status: "draft"`).
- **pr** — the PR number once a PR is opened, as a bare number (`pr: 2297`) — it
  is a YAML integer, so no quotes and no `#`. Leave empty (`pr:`, parses as null)
  until then. (`reap-plans` tolerates a stray quote or leading `#`, but the clean
  form is the bare number.)

## Status ownership

| Value | You (Claude) set it | When |
|---|---|---|
| `draft` | yes | at plan creation |
| `in-progress` | yes | when you start executing the plan |
| `merged` | **NO — never write this** | `reap-plans` owns it; it stamps `merged` just before archiving |
| `abandoned` | yes | only when the user says the work is dropped or superseded |

Never write `status: merged` yourself. That value is owned solely by
`reap-plans`, which sets it from GitHub merge state so it cannot drift.

## When to fill `pr`

Stamp `pr: <N>` as soon as the PR is opened (the PR is created at the end of
implementation, so the number does not exist until then). Stamping is **per
slug group**: every file sharing the slug — the design doc AND the
implementation plan — gets the number, so the whole group carries the join key
`reap-plans` uses to check merge state.

Don't hand-edit the frontmatter — run the dedicated `stamp-plans` script
(this plugin ships it in `bin/`; it must be on PATH):

```bash
stamp-plans -f <any-file-of-the-group.md> <pr-number>   # slug read from the file
stamp-plans <pr-number>                                 # slug derived from current branch
stamp-plans -n ...                                      # dry run
```

It stamps `pr: <N>` as a bare YAML integer into every frontmatter-bearing
member of the slug group and errors if it finds none.

## PR slicing (stacked PRs)

Large plans ship as a stack of small PRs, not one big one. Slicing is decided
when WRITING the implementation plan — never carved post-hoc from a finished
branch. Reviewability is the goal: AI-generated code lives or dies by whether
a human can hold each diff in their head.

**Whether to slice — size only.** Slice into `## PR N:` groups when the plan
exceeds ~6 tasks or the estimated non-generated diff exceeds ~500 lines
(i.e. a single PR would be too big to review well). Layer count alone is
NEVER a reason to slice — in a layered backend almost any persisted field
touches api + db + service; a thin change touching many layers stays one PR.

**Where to cut — layer boundaries.** Once slicing is warranted, cut so each
slice is independently green and shippable, ordered dark → wire → activate:
dark api/db first, then service (API live, runtime-inert), then wiring, then
activation (behind a flag). Example stack: `feat(api)` dark schema/DAO →
`feat(service)` handling (API live, runtime-inert) → `feat(integration)`
wiring → `feat(routing)` activation behind a flag.

**Declaration format.** Group the implementation plan's tasks under slice
headings:

    ## PR 1: feat(api) — proto, migration, entity, DAO (dark)
    ### Task 1.1 ...
    ### Task 1.2 ...
    ## PR 2: feat(deployer) — service wiring (API live, runtime-inert)
    ### Task 2.1 ...

- Detection regex (used by `/execute-plan`): `^## PR ([0-9]+): (.+)$` —
  numbers consecutive from 1.
- The text after the colon is the PR title **verbatim**, so write it
  Conventional-Commits-shaped.
- Slices execute in heading order; each must leave `make test` + `make lint`
  green standalone on top of the previous slices.
- No task in slice N may depend on code written in slice N+1.
- No `## PR N:` headings ⇒ `/execute-plan` runs its normal single-PR flow.
- Branches are named `<ns>/<prefix>-<N>-<slice-slug>` (`<ns>` = your branch
  namespace, prefix derived from the
  plan slug, slice slug from the heading's Conventional-Commits scope).

**Stamping a stack.** Stamp ONLY the tip (last) PR number into `pr:` — under
the squash-merge cascade the tip merges last, so tip-merged ⇔ whole stack
merged, and `reap-plans` needs no changes.

**Merge cascade — run `/restack`.** After PR K squash-merges to main, run
`/restack` in the stack's worktree: it discovers the stack from GitHub,
cascade-rebases the surviving branches, verifies the tip with `make test` +
`make lint`, and — after one confirmation — force-with-lease pushes and
retargets the new bottom PR to main. Force-with-lease is sanctioned only
inside `/restack` after its confirmation gate, or by hand via the manual
recipe below.

Manual recipe (reference — what `/restack` automates). After PR K
squash-merges to main:

1. `git fetch origin`
2. `git rebase --onto origin/main <old-base-branch> <branch-K+1>`
3. `gh pr edit <K+1> --base main`
4. Push the rebased branch with `--force-with-lease`.
5. Repeat up the stack in order.

## Relationship to writing-plans

This skill does not replace `superpowers:writing-plans` — it adds the
frontmatter block above the standard plan header. Apply it whenever a plan or
design doc is written, after the plan body is drafted.
