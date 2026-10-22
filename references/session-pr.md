# Session PR fallback

Shared by `/pr-fix`, `/pr-fix-loop`, `/review-stack`, `/pr-triage` and
`/restack`. Run it first — before the command resolves `OWNER/REPO`, runs a
pre-flight or reads anything else from the checkout — and only when the
command got no target. It either lets the command go on unchanged, or picks
a PR this session worked on and starts the command over where that PR lives.

## 1. Current branch

`gh pr view --json number -q .number`:

- **A number** → go on with no target; stack discovery finds the same PR.
- **An error saying no pull request was found for the branch** → step 2.
- **Any other error** (auth, network, not a repository) → stop and show it.
  Never read a failed lookup as "no PR" — that would pick an unrelated PR.

## 2. Candidates

The PRs this conversation opened or worked on, in any repo, written
`<repo>#<N>`. Keep the ones still open:
`gh pr view <N> -R <repo> --json state,headRefName` → `state` is `OPEN`.

- **None** → stop: "No PR for the current branch."
- **One** → pick it and print "No PR for the current branch — using
  `<repo>#<N>` from this session."
- **Two or more** → ask with `AskUserQuestion`: the four most recently
  touched as options, the first marked Recommended, and any others named in
  the question so the user can pick them via Other. Never pick one silently
  — the command may push to it.

## 3. Where it lives

`git -C <checkout> worktree list --porcelain`, run from a checkout of the
picked PR's repo this session used, gives each worktree's path and
`branch refs/heads/<name>`. `HOME` = the worktree on the PR's `headRefName`;
for a caller that takes any checkout of the repo, the current directory when
it is one, else the first worktree listed.

- **`HOME` is the current directory** → go on with the target `<N>`.
- **The caller may move and `HOME` exists** → `cd` into `HOME` and start the
  command over from its top as `/<command> <N> <the rest of the arguments>`,
  so its setup and pre-flight run against that checkout.
- **Otherwise** (the caller may not move, or no worktree is on that branch,
  or the session used no checkout of that repo) → stop: "Re-run
  `/<command> <N>` from `<HOME>`", or "from a checkout of `<repo>` on
  `<headRefName>`" when there is no `HOME`.

The caller says whether it may move and whether `HOME` must be on the head
branch or can be any checkout of the repo.
