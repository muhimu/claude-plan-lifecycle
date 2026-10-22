# Session PR fallback

Shared by `/pr-fix`, `/pr-fix-loop`, `/review-stack` and `/pr-triage` — not
`/restack`, which anchors on the current branch's merged PR. Run it first,
and only when the command got no target. It yields the PR number `N` the
command then runs with, exactly as if the user had typed it — or stops. Step
3 moves the command to a PR in another repo.

## 1. Current branch

`gh pr view --json number,state`:

- **`state` is `OPEN`** → `N` = its number. Done.
- **Merged or closed, or an error saying no pull request was found for the
  branch or that HEAD is not on a branch** → step 2.
- **Any other error** (auth, network, not a repository) → stop and show it.
  Never read a failed lookup as "no PR" — that would pick an unrelated PR.

## 2. Candidates

The PRs this conversation opened or worked on, in any repo, written
`OWNER/REPO#N` (owner-qualified — `gh -R` needs it). Keep the ones
`gh pr view <N> -R OWNER/REPO --json state,author` shows `OPEN` and authored
by `gh api user -q .login` — a PR the session only reviewed or triaged is
someone else's, and the command may push to it.

- **None** → stop: "No PR for the current branch."
- **One** → pick it.
- **Two or more** → ask with `AskUserQuestion`: the four most recently
  touched as options, the first marked Recommended, and any others named in
  the question so the user can pick them via Other. Never pick one silently.

`N` = the picked number; when it was the only candidate, print "No PR for
the current branch — using `OWNER/REPO#N` from this session." Then step 3.

## 3. Another repo

Also run by callers whose explicit target (a PR URL or `OWNER/REPO#N`) names
a repo. `gh repo view --json nameWithOwner -q .nameWithOwner` equals the
PR's `OWNER/REPO` → nothing to do.

Otherwise find `DIR`: `git -C <a checkout of that repo this session used>
worktree list --porcelain` lists each worktree's path and
`branch refs/heads/<name>`. `DIR` is the one on the PR's `headRefName`; for
a stacked PR, failing that, one on another branch of its stack (the
command's pre-flight checks it); for a caller that takes any checkout, the
first listed. None, or the session used no checkout of that repo → stop:
"Re-run `/<command> OWNER/REPO#N` from a checkout of `OWNER/REPO`."

Then `cd <DIR>` before the command resolves `OWNER/REPO` or runs any
pre-flight, and start every subagent prompt the command writes with "Work in
`<DIR>`: run every shell command as `cd <DIR> && …`." — subagents start in
the session's directory, not the one the command moved to.
