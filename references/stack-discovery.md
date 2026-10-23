# Stack discovery

Shared by `/restack`, `/pr-fix`, `/review-stack`, `/pr-triage` and
`/verify-findings`. It turns the command's target into the ordered list of a
stack's slices. Live truth is GitHub's native stack object; a stack opened
without one (`/execute-plan` falls back to a `## Stack` table when
`gh stack link` is unavailable) is still found.

**Input:** `ANCHOR` — a bare number, a PR URL, `OWNER/REPO#N`, a branch
name, or empty (the current branch). `OWNER/REPO` is the repo a URL or
`OWNER/REPO#N` anchor names; otherwise resolve it once with
`gh repo view --json nameWithOwner -q .nameWithOwner`.

**Output:**

- `SLICES` — every PR of the stack, bottom first, each with `number`,
  `state` (`open` / `closed` / `merged`), `merged_at`, `title`, `head` (branch
  name), `base` (branch name) and `sha` (head commit).
- `STACKED` — true when `SLICES` has two or more PRs.
- `STACK_NUM` — the native stack number, or empty for a fallback stack.
- `ANCHOR_PR` — the PR the anchor named, when it named one; `POSITION/SIZE`
  — its position in `SLICES` and the length of `SLICES`.

Callers print `stack #<STACK_NUM>` for a native stack and `stack of #<bottom>`
for a fallback stack.

## 1. Anchor

- **Bare number** — try it as a stack first:
  `gh api repos/OWNER/REPO/stacks/<N>`. Stacks share the number sequence of
  issues and PRs, so a number is a stack or a PR, never both. 200 → native
  stack, `STACK_NUM = N`, go to step 3. 404 → it is a PR number. Any other
  status: stop and show the error — do not guess.
- **`OWNER/REPO#N`** → `N`, read as a bare number above (it may be a
  stack). **PR URL** → its number. **Branch name** → `gh pr list --head <branch>
  --state all --json number -q '.[0].number'`. **Empty** →
  `gh pr view --json number -q .number`. No PR → stop: "No PR for `<anchor>`."
  (`/pr-fix`, `/pr-fix-loop`, `/review-stack` and `/pr-triage` resolve an
  empty target with `${CLAUDE_PLUGIN_ROOT}/references/session-pr.md` first.)

## 2. Native stack of a PR

`gh api repos/OWNER/REPO/pulls/<ANCHOR_PR> --jq .stack` — `{number, position,
size, base}`. Non-null with `size > 1` → `STACK_NUM = .stack.number`, go to
step 3. Otherwise (`null` or `size == 1`) go to step 4.

## 3. Read a native stack

```bash
gh api repos/OWNER/REPO/stacks/<STACK_NUM> \
  --jq '.pull_requests[] | {number, state, merged_at, title, head: .head.ref, base: .base.ref, sha: .head.sha}'
```

The list is already bottom first: that is `SLICES`. Done.

## 4. Fallback stack (no native stack)

Try, in order, and take the first that yields two or more PRs containing
`ANCHOR_PR`:

1. **`## Stack` table** in the anchor PR's body (`gh pr view <ANCHOR_PR>
   --json body`): rows `| #<PR> | <title> | <base> |`, top to bottom, a
   merged row reading `#<PR> ✅ merged`. A body whose `## Stack` section has
   no table (a native stack's one-liner) yields nothing.
2. **Base-branch chain.** Walk down: the PR whose head is the anchor's base,
   repeatedly (`gh pr list --head <base> --state all`), until a base is the
   default branch or no PR matches. Walk up: the open PR whose base is the
   current head (`gh pr list --base <head> --state open`), repeatedly. More
   than one match at any step → stop: "Cannot reconstruct a linear stack for
   `<anchor>` — resolve manually."

For each PR found, read
`gh pr view <n> --json number,state,mergedAt,title,headRefName,baseRefName,headRefOid`
and map it onto the `SLICES` fields (`state` lower-cased). `STACK_NUM` stays
empty.

Nothing found → `SLICES` is the anchor PR alone (read the same way) and
`STACKED` is false.
