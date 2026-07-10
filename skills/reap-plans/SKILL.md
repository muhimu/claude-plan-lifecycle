---
name: reap-plans
description: Use when asked to reap plans, clean up merged/finished implementation plans in the plans dir, or archive plans whose PRs have merged into <plans-dir>/done/.
---

# Reap Plans

Archive implementation plans whose PRs have merged. The logic lives in the
`reap-plans` bash script (shipped in this plugin's `bin/`; it must be on PATH) — this skill wraps it with
the run order and the conventions the script relies on.

## What the script does

Groups the plans dir's `*.md` by frontmatter `slug:` (a design + its impl plan reap
as one group), checks each group's `pr:` merge state via `gh`, and for MERGED
groups stamps `status: merged` into every member and moves them to
`<plans-dir>/done/`. Groups with no resolvable PR, or any `status: abandoned`
member, are left untouched.

## How to run

Always dry-run first, then the real run:

```bash
reap-plans -n      # show what would move, change nothing
reap-plans         # stamp status: merged and move merged groups to done/
```

Run from the repo root. The script resolves the plans dir itself
(`-d` flag, else `PLANS_DIR` env, else `git config plans.dir`, else default
`local/plans`). Requires an authenticated `gh`. If the plans dir is tracked
in git, commit the moves it makes.

Read the dry-run output before the real run. Flag anything odd to the user:
`UNKNOWN` states (a PR number the script couldn't resolve), conflicting-PR
warnings, or a plan you expected to reap sitting in "no PR".

## Conventions the script depends on

The frontmatter rules the script reads (`slug`, `pr`, `status`) are defined in
the `plan-frontmatter` skill — **REQUIRED BACKGROUND:** read it for the full
field spec. What matters for reaping:

- **`pr:`** must resolve to a real PR. Empty (`pr:`) = no PR yet = work-in-progress, never reaped.
- **`status: merged` is script-owned.** Never hand-write it — the script sets it from GitHub merge state so it can't drift. You set `draft`/`in-progress`/`abandoned` only.
- **`slug:`** groups a design + its impl plan so they reap together.
- **Legacy plans without frontmatter** fall back to a body `PR: #<N>` line (hand-stamped; `stamp-plans` ignores them).

## Do not

- Do not move plans to `done/` by hand — run the script so `status:` is stamped.
- Do not reap a group whose PR merge state you haven't confirmed in the dry run.
