# Session PR fallback

Shared by `/pr-fix`, `/pr-fix-loop`, `/review-stack` and `/pr-triage` — not
`/restack`, which anchors on the current branch's merged PR. Run steps 1–3
first when the command got no target, and step 3 alone for any other target
(a bare number's `OWNER/REPO` is the current checkout's). It yields the PR
`OWNER/REPO#N` the command then runs with, and where to run it — or stops.

Each caller says two things: whether it **pushes** (`/pr-fix`,
`/pr-fix-loop`) and what checkout it **needs** — the PR's head checked out,
or any checkout of the PR's repo.

## 1. Current branch

`gh pr view --json number,state,url`:

- **`state` is `OPEN`** → that PR, in the current checkout; `OWNER/REPO`
  comes from its `url` (on a fork checkout that is the upstream repo). Done.
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

## 3. Checkout

The current checkout is **usable** when it is a checkout of the PR's
`OWNER/REPO` (`gh repo view --json nameWithOwner -q .nameWithOwner`) and,
for a caller that needs the head, `git branch --show-current` is the PR's
`headRefName` (`gh pr view <N> -R OWNER/REPO --json headRefName`). A stacked
target — `N` is a stack (`gh api repos/OWNER/REPO/stacks/<N>` answers 200)
or a PR whose `gh api repos/OWNER/REPO/pulls/<N> --jq .stack.size` is above
1 — needs only the repo: the caller's stack pre-flight checks the branch,
and `/restack` leaves the top checked out between `/pr-fix-loop` rounds.
Usable → done.

A caller that never moves stops here: "Re-run `/<command> OWNER/REPO#N`
from a checkout of `OWNER/REPO` on `<branch>`" — the PR's head, or for a
stack its top.

Otherwise find `DIR`: `git -C <a checkout of that repo — the current one,
or one this session used> worktree list --porcelain` lists each worktree's
path and `branch refs/heads/<name>`. `DIR` is the one on `headRefName` —
for a stacked target, on any branch of the stack
(`gh api repos/OWNER/REPO/stacks/<S> --jq '.pull_requests[].head.ref'`) —
or, for a caller that takes any checkout, the first listed. None → stop with
the same re-run hint.

For the rest of the command — including a command it hands off to, such as
`/restack` — run every shell command as `cd <DIR> && …`, and start every
subagent prompt it writes with "Work in `<DIR>`: run every shell command as
`cd <DIR> && …`." A bare `cd` does not stick outside the session's
directory, and subagents start in the session's directory.
