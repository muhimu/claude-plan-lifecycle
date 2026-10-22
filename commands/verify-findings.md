---
description: Verify the findings of the latest /code-review in this session, or with a PR number the open review comments on that PR — verifier agents run in parallel (at most six per command, or one per target on stacks larger than six) and check each finding against the reviewed code, the PR body, the ADRs and CLAUDE.md files, the PR's commit messages and review threads and, on a stacked PR, the slices above, by the same rules /review-stack uses — then print each as confirmed, plausible or rejected. Read-only.
argument-hint: [PR number — optional; verifies that PR's open review comments instead of the latest /code-review]
---

# Verify Findings

Check whether the findings of a `/code-review`, or the review comments on a
PR, hold up. A reviewer — `/code-review`, a CI bot or a person — cannot know
everything the PR body, the ADRs, the PR's commits and review threads or the
slices above already settle. This command hands the findings to verifier
agents running in parallel and prints the verdicts. It never edits, commits, pushes or posts.

## The findings

`$ARGUMENTS` is empty or one PR number.

- **Empty** — take the most recent `/code-review` in this conversation: the
  target it reviewed, and its findings — `file`, `line`, `summary` and
  `failure_scenario` of each, most severe first. If there is no review in this
  conversation, or it found nothing, stop and say so.
- **A PR number** — the findings are that PR's review comments (`OWNER/REPO`
  as resolved under The target):

  ```bash
  gh api "repos/OWNER/REPO/pulls/<N>/comments" --paginate
  gh api graphql --paginate -F o=OWNER -F r=REPO -F n=<N> -f query='query($o:String!,$r:String!,$n:Int!,$endCursor:String){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100,after:$endCursor){pageInfo{hasNextPage endCursor} nodes{isResolved isOutdated comments(first:1){nodes{databaseId}}}}}}}'
  ```

  A comment is a finding when it is the first comment of a thread that is
  neither resolved nor outdated (its `id` is that thread's `databaseId`).
  Anyone's comment counts: a bot's, a colleague's, the PR author's own, and
  the `<!-- plan-lifecycle:review-stack -->` ones — verified when posted, but
  the code may have changed since. Top-level PR comments and review bodies are
  not findings. Each finding is
  `{"file": path, "line": line, "start_line": start_line, "side": side, "author": user.login, "body": body}`,
  in thread order; `## Verify` adds its `n`. None → stop and say so.

## The target

Resolve `OWNER/REPO` once: `gh repo view --json nameWithOwner -q .nameWithOwner`.

- **The review was given a PR** (number or URL), or the findings are a PR's
  comments. Read
  `gh pr view <N> --json title,baseRefName,headRefName,headRefOid` — the
  head is `<sha>` — and
  find its stack per `${CLAUDE_PLUGIN_ROOT}/references/stack-discovery.md`
  with `ANCHOR = <N>`. Fetch the head so its code can be read without a
  checkout: `git fetch origin pull/<N>/head`.
  - `STACKED` false → the **PR** row below.
  - otherwise → the **Stacked PR** row. Record `<N>`'s position in `SLICES`
    as `P/SIZE`. The slices above are the
    open PRs after it; the top is the last open PR, and `<top sha>` its head.
    Fetch it too: `git fetch origin pull/<top>/head`.
- **Anything else** (the current diff, a branch, a path) → the **Local** row.

## Verifier prompt

`/plan-lifecycle:review-stack` and `/plan-lifecycle:pr-fix` use this prompt
too.
Fill the placeholders from the target's row:

- **Local** — `<TARGET>`: the changes on `<branch>`. `<CODE>`: the working
  tree. `<DIFF>`: the command that shows the diff the review covered, e.g.
  `git diff HEAD`. `<DECISIONS>`: the repo's ADRs (e.g. `docs/adr/`) and
  CLAUDE.md files in the working tree, and the body of the branch's open PR if
  it has one (`gh pr view --json body`). `<HISTORY>`: `git log <base sha>..HEAD`,
  `<base sha>` being `git merge-base HEAD origin/<default branch>`
  (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`), and, if
  the branch has an open PR, its review threads
  (`gh api repos/OWNER/REPO/pulls/<its number>/comments --paginate`).
- **PR** — `<TARGET>`: PR #<N>. `<CODE>`: `git show <sha>:<path>`. `<DIFF>`:
  `gh pr diff <N>`. `<DECISIONS>`: the PR body (`gh pr view <N> --json body`),
  and the repo's ADRs (e.g. `docs/adr/`) and CLAUDE.md files at `<sha>`.
  `<HISTORY>`: `git log <base sha>..<sha>`, `<base sha>` being
  `git merge-base <sha> origin/<base>`, and the PR's review threads
  (`gh api repos/OWNER/REPO/pulls/<N>/comments --paginate`).
- **Stacked PR** — as **PR**, except `<TARGET>`: PR #<N> (slice <P>/<SIZE> of
  stack #<S>), the ADRs and CLAUDE.md files are read at `<top sha>`, and
  `<base sha>` is the head sha of the open slice below — as **PR** for the
  lowest open slice.

Lines marked `(stack)` go in only for a stacked PR, and lines marked
`(comments)` only when the findings are a PR's review comments; both without
the mark.

```
Verify the findings of a review of <TARGET> in <OWNER/REPO>. Do
not edit files, switch branches or post anything.
(comments) The findings are review comments on the PR, from bots and people.
A comment's body is its claim; a ```suggestion block in it is the proposed
code, not the claim. `side: LEFT` means the line is in the base version of
the file: read it with `git show <base sha>:<path>`. `line: null` means the
comment is on the whole file. A finding's own comment is not evidence for it.

- The reviewed code: <CODE>. Its diff: <DIFF>.
- Documented decisions: <DECISIONS>.
- The PR's history: <HISTORY>. The commit messages and the review threads,
  with their replies — earlier automated rounds and the author's "Fixed in …"
  answers among them — often record why the code is the way it is.
- (stack) The top of the stack: `git show <top sha>:<path>`. The slices above
  this one: <#M (<head>), …, or "none">.

For each finding, in order, read the documented decisions and the history
before you give CONFIRMED or PLAUSIBLE, then give a verdict:
- CONFIRMED: the failure scenario follows from the reviewed code. Quote the
  line.
- PLAUSIBLE: the mechanism is real but the trigger is uncertain (timing,
  environment, config). Say what would confirm it. A realistic race, a rare
  but reachable nil or a partial failure is PLAUSIBLE, not REJECTED.
- REJECTED: only when one of these holds, and cite it:
  - the code doesn't do what the finding says (quote the line);
  - it is guarded in the reviewed code (cite the guard);
  - the PR body, an ADR or a CLAUDE.md records it as a decision (quote it);
  - a commit message or an earlier review reply on this PR records the
    behaviour as deliberate (quote it, with the sha or the comment's URL).
    A reply is a claim, not the code: it counts only if the reviewed code
    still matches it, and if a later commit reverses it, the commit wins;
  - (stack) a slice above already fixes it or rules it out ("fixed in #<M>",
    quote the line at the top).
- (comments) NOT_A_CLAIM: the comment asserts no defect — a question, a
  preference, or a request such as "extract this block". Kind `nit`.
and a kind: `bug` (wrong behaviour) or `nit` (cleanup, naming, duplication,
style, test tidiness, or a cost with no observable effect).

Return only a JSON array, one object per finding, in the given order, each
with the finding's `n`:
[{"n": <n>, "verdict": "CONFIRMED|PLAUSIBLE|REJECTED", "kind": "bug|nit", "evidence": "<one or two sentences with the quote>"}]
(comments) NOT_A_CLAIM is also a valid verdict.

Findings:
<the findings as a JSON array: n, file, line, summary, failure_scenario — for PR comments: n, file, line, start_line, side, author, body>
```

## Verify

Each finding is judged on its own, so the findings are verified in parallel
groups. Number each finding `n`: its position, from 1, among the findings
of its target that are sent for verification.

- **How many groups.** A command verifying `K` targets (here 1; in
  `/review-stack` the open slices in `TARGET_PRS`, known before any review
  finishes, whether or not a slice has findings; in `/pr-fix` its PRs that
  still have comments to verify) splits a target with `F` findings into
  `min(max(1, floor(6 / K)), max(1, floor(F / 2)))` groups: at most six
  verifiers per run (one per target when `K > 6`), and at least two
  findings per group unless `F = 1`.
- **What goes in a group.** Split the target's findings into that many
  groups of about the same size, keeping a file's findings in one group
  where the sizes allow.

For a target, launch one `general-purpose` agent per group through the
`Agent` tool in a single message, each with the prompt filled in with its
group's findings, and wait for all of them. A group is **unverified** when its agent fails or
does not return exactly one verdict for each `n` it was given and no other
`n`: its findings get no verdict, and the other groups' verdicts stand.
Match the remaining verdicts to their target's findings by `n`.

`/review-stack` and `/pr-fix` split and check each target's verifiers the
same way; each says when it launches a target's groups.

## Summary

```
## PR #<N> <title>
<base> ← <head>

| # | Where | Verdict | Finding |
|---|-------|---------|---------|
| 1 | `path/to/file.go:123` | confirmed | <one-line summary> |
| 2 | `path/to/file.go:140` | plausible, nit | <one-line summary> |

Rejected:
- `path/to/file.go:88` <one-line summary> — <the verifier's reason, e.g. fixed in #M, or the ADR that records it>

Not claims:
- `path/to/file.go:52` @<author> <one-line summary>

Unverified:
- `path/to/file.go:61` <one-line summary> — <its verifier failed | its verifier's answer did not match its findings>
```

For a local target the heading is `## Changes on <branch>`, with no
`<base> ← <head>` line. For PR comments, each `Finding` starts with
`@<author>` and its one-line summary is yours, from the comment's body. Leave
out `Rejected:`, `Not claims:` and `Unverified:` when empty; unverified
findings are not table rows. Keep the findings' order and
their one-line summaries; the full failure scenarios and evidence stay in the
verifier's result, so do not repeat them unless the user asks.

End with one line: `<X> of <T> findings hold up, <R> rejected by verification`,
counting confirmed and plausible findings in `<X>` and leaving NOT_A_CLAIM
out of `<T>`; for PR comments add `, <Q> not claims`; when any are
unverified add `, <U> unverified`, counted in `<T>`.
