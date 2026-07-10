---
description: Address PR review feedback on the current branch — fetch comments, plan fixes, implement, push, then summarize for the user to post replies
argument-hint: [PR number — optional, auto-detects from current branch]
---

# PR Fix

Address review feedback on a pull request. You handle code changes and pushing commits; the user handles all GitHub replies and thread resolution.

## Resolving the PR

If `$ARGUMENTS` contains a PR number, use it. Otherwise:

```bash
gh pr view --json number,headRefName,baseRefName,url
```

This auto-detects the PR for the currently checked-out branch. If there is no PR, stop and tell the user — do not create one.

## Step 1 — Fetch review state

Get inline review comments with file/line anchors, top-level review comments, and the PR diff:

```bash
# Inline comments (the ones anchored to specific lines)
gh api "repos/{owner}/{repo}/pulls/<PR>/comments" --paginate > /tmp/pr-fix-inline.json

# Top-level reviews (overall approve/request-changes bodies)
gh pr view <PR> --json reviews,comments,headRefName,baseRefName,headRefOid

# Current diff for context
gh pr diff <PR>
```

Read all three. Filter out comments authored by the user themselves (`gh api user --jq '.login'`) and any comments that are obviously already resolved (the line they point to no longer exists in `HEAD`).

## Step 2 — Classify and plan

Sort each remaining comment into one bucket:

| Bucket | Meaning | Action |
|---|---|---|
| **Actionable** | Clear code change requested | Plan a code edit |
| **Question** | Reviewer asking for clarification, no code change | Draft a reply for the user |
| **Suggestion** | Reviewer's preference — requires judgment | Evaluate, then either Actionable or Pushback |
| **Nit** | Stylistic, low-stakes | Plan a code edit (cheap to address) |
| **Pushback** | Suggestion is wrong for this codebase | Draft a reply explaining why |
| **Stale** | Comment is on code that's since been changed | Skip, note it |

**Before classifying, invoke the `superpowers:receiving-code-review` skill via the `Skill` tool.** That skill owns the verify-before-implementing discipline, YAGNI checks, and pushback patterns — do not re-derive them here. If the skill is not available (superpowers plugin not installed), proceed without it and apply the same discipline yourself: verify each claim against the code before implementing, and push back with technical reasoning instead of performative agreement.

Present the full plan to the user as a table:

```
| # | File:Line | Reviewer | Bucket | Proposed action |
```

Wait for user approval before any code changes. The user may redirect individual rows ("don't do 3, push back instead", "skip 7, it's stale"). Apply their changes to the plan.

## Step 3 — Implement

Apply code changes for all approved Actionable + Nit items. Group commits by logical area, not one-commit-per-comment — if three nits are in the same file, that's one commit. If two actionable fixes touch unrelated subsystems, that's two commits.

**Rules during implementation:**

- Run the project's test/lint suite after each logical group. If something breaks, stop and report — don't paper over.
- Do not create branches. Commit to the currently checked-out PR branch.
- Commit messages should describe the change, not reference the comment ID — comment IDs rot, code messages don't.

## Step 4 — Push

```bash
git push
```

Plain `git push`. **Never `--force`**, never `--force-with-lease` — if the push is rejected, stop and ask the user. Don't rewrite published history without explicit instruction.

## Step 5 — Summarize for the user

This is the final output. Print a structured summary the user can use to write GitHub replies themselves. **Do not post any replies to GitHub.** Do not call `gh api POST` or any mutation endpoint on comments/threads.

Format:

```
## PR #<N> — fix summary

### Addressed (code pushed)
- <file:line> [<reviewer>]: <comment summary>
  → <what you changed, in one line>
  → Suggested reply: "<short factual reply text>"

### Pushed back
- <file:line> [<reviewer>]: <comment summary>
  → Suggested reply: "<technical reasoning for not making the change>"

### Questions for reviewer
- <file:line> [<reviewer>]: <comment summary>
  → Suggested reply: "<clarification question>"

### Stale (no action)
- <file:line> [<reviewer>]: <why it's stale>

### Commits pushed
- <sha> <subject>
- <sha> <subject>
```

The "Suggested reply" lines are drafts for the user to copy, edit, and post manually. Keep them factual and short — no "thanks", no "great catch", no performative agreement (`receiving-code-review` already covers this).

## Hard rules

- **No GitHub mutations.** No `gh api POST/PATCH/DELETE`, no `gh pr review`, no `gh pr comment`, no thread resolution, no `gh pr merge`. Read-only `gh` only.
- **No force push.** Plain `git push`. If rejected, stop.
- **No auto-merge.** Even if the PR is now green, do not merge it.
- **One-at-a-time verification.** After each logical commit, run relevant tests. Batching everything then running tests once at the end hides which change broke what.
- **Stop on disagreement.** If the user redirects a row in the plan, apply the redirect — don't argue past one push-back.
