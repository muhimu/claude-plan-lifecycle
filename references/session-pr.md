# Session PR fallback

Shared by `/pr-fix`, `/pr-fix-loop`, `/review-stack` and `/pr-triage` — not
`/restack`, which anchors on the current branch's merged PR. Run steps 1–3
first when the command got no target, and step 3 alone for any other target
(a bare number's `OWNER/REPO` is the current checkout's). It yields the PR
`OWNER/REPO#N` the command then runs with — its target from here on, in
place of anything parsed from `$ARGUMENTS` — and where to run it, or stops.

Each caller says whether it **pushes** (`/pr-fix`, `/pr-fix-loop`), whether
it may **move**, and which branch it **needs** checked out: the **head**
(for a stacked target, any branch of the stack), the **top** (a stack's top
branch; for an unstacked PR, its head), or **any** checkout of the repo.

## 1. Current branch

`gh pr view --json number,state,url`:

- **`state` is `OPEN`** → that PR, in the current checkout; `OWNER/REPO`
  comes from its `url` (on a fork checkout that is the upstream repo). Go
  to step 3.
- **Merged or closed, or an error saying no pull request was found for the
  branch, that HEAD is not on a branch, or that this is not a git
  repository** → step 2.
- **Any other error** (auth, network) → stop and show it. Never read a
  failed lookup as "no PR" — that would pick an unrelated PR.

## 2. Candidates

The PRs this conversation opened or worked on, in any repo, written
`OWNER/REPO#N` (owner-qualified — `gh -R` needs it). Keep the ones
`gh pr view <N> -R OWNER/REPO --json state,author` shows `OPEN`; for a
caller that pushes, also only those authored by `gh api user -q .login` — a
PR the session only reviewed or triaged is someone else's.

- **None** → stop: "No PR for the current branch", naming each dropped
  candidate and why (merged, closed, not yours).
- **One** → pick it and print "No PR for the current branch — using
  `OWNER/REPO#N` from this session."
- **Two or more** → ask with `AskUserQuestion`: the four most recently
  touched as options, the first marked Recommended, and any others named in
  the question so the user can pick them via Other. Never pick one silently.
  Match an Other answer against the candidates — a short `REPO#N` or `#N`
  by repo name and number; no match, or more than one → ask again.

## 3. Checkout

First, is the target **stacked**? `gh api repos/OWNER/REPO/stacks/<N>`
answers 200 → `N` is a stack, `S = N`. Otherwise (404)
`gh api repos/OWNER/REPO/pulls/<N> --jq .stack` → `{number, size}` with
`size` above 1 → stacked, `S = .stack.number`. Anything else → not stacked.

The **wanted branches**: for an unstacked target, the PR's `headRefName`
(`gh pr view <N> -R OWNER/REPO --json headRefName`); for a stacked one, the
stack's `gh api repos/OWNER/REPO/stacks/<S> --jq '.pull_requests[].head.ref'`
— all of them for **head**, the last open one (the top) for **top**. `/restack`
leaves the top checked out between `/pr-fix-loop` rounds, so a stack round
keeps working.

The current checkout is **usable** when it is a checkout of the PR's
`OWNER/REPO` (`gh repo view --json nameWithOwner -q .nameWithOwner`) and,
unless the caller takes **any**, `git branch --show-current` is a wanted
branch. Usable → done.

Otherwise list the repo's worktrees: `git -C <a checkout of that repo — the
current one, or one this session used> worktree list --porcelain` gives each
worktree's path and `branch refs/heads/<name>`. `DIR` is one on a wanted
branch, or, for **any**, the first listed.

- **The caller never moves** → stop: "Re-run
  `/plan-lifecycle:<command> OWNER/REPO#N <the rest of its arguments>` from
  `<DIR>`", or, with no `DIR`, "from a checkout of `OWNER/REPO`", adding
  "on `<wanted branch>`" unless the caller takes **any**.
- **No `DIR`** → stop with that second hint.
- **Found** → print "Working in `<DIR>` (`OWNER/REPO#N`)."

For the rest of the command — including a command it hands off to, such as
`/restack` — run every shell command as `cd <DIR> && …`, and start every
subagent prompt it writes with "Work in `<DIR>`: run every shell command as
`cd <DIR> && …`." A bare `cd` does not stick outside the session's
directory, and subagents start in the session's directory.
