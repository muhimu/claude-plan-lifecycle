# Session PR fallback

Shared by `/pr-fix`, `/pr-fix-loop`, `/review-stack`, `/pr-triage` and
`/restack`. Run it first, and only when the command got no target. It
yields the PR number `N` the command then runs with, exactly as if the user
had typed it — or stops. It never changes directory: subagents a command
launches start in the session's directory, so the command must run there.

## 1. Current branch

`gh pr view --json number,state`:

- **`state` is `OPEN`** → `N` = its number. Done.
- **Merged or closed, or an error saying no pull request was found for the
  branch** → step 2.
- **Any other error** (auth, network, not a repository) → stop and show it.
  Never read a failed lookup as "no PR" — that would pick an unrelated PR.

## 2. Candidates

The PRs this conversation opened or worked on, in any repo, written
`OWNER/REPO#N` (owner-qualified — `gh -R` needs it). Keep the ones
`gh pr view <N> -R OWNER/REPO --json state,author` shows `OPEN` and authored
by `gh api user -q .login` — a PR the session only reviewed or triaged is
someone else's, and the command may push to it.

- **None** → stop: "No PR for the current branch."
- **One** → pick it and print "No PR for the current branch — using
  `OWNER/REPO#N` from this session."
- **Two or more** → ask with `AskUserQuestion`: the four most recently
  touched as options, the first marked Recommended, and any others named in
  the question so the user can pick them via Other. Never pick one silently.

## 3. Same repo

`gh repo view --json nameWithOwner -q .nameWithOwner` equals the picked
PR's `OWNER/REPO` → `N` = its number. Done.

Otherwise stop: "`OWNER/REPO#N` is in another repo — re-run `/<command> <N>`
from a checkout of it", naming the worktree on its head branch when
`git -C <a checkout of that repo this session used> worktree list` shows one.
