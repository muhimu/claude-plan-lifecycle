---
description: Review every open PR of a stack (or one PR) with /code-review, verify each finding, and print one summary by slice; --comment posts them for /pr-fix.
argument-hint: [stack or PR number — optional, auto-detects from the current branch or this session's PRs] [/code-review flags, e.g. high --comment]
---

# Review Stack

Run `/code-review` on each open PR of a stack, verify its findings, and report
them slice by slice. This command reviews only — it never edits, commits or
pushes. With `--comment`, it posts each slice's confirmed and plausible
findings on that slice's PR, marked so `/plan-lifecycle:pr-fix <stack>` treats
them as review findings to verify (not your own notes) and fixes each in the
slice that owns it.

Run every command in the session's working directory, with no `cd`: the
reviews and the verifiers start there, so it must be the checkout the
pre-flight below checks.

## Resolving the stack

Split `$ARGUMENTS`: if the first token is a number it is the target (a PR URL or `OWNER/REPO#N` counts as its number, and its `OWNER/REPO` is used below);
everything after it (or all of `$ARGUMENTS` when the first token is not a
number) is `REVIEW_ARGS`, passed verbatim to every review (an effort level,
`--max-findings <n>`). `--comment` is taken out of `REVIEW_ARGS` and sets
`POST`: the reviews do not post, Step 3 does. `--fix` stops the command: each
review would apply its findings to the same checkout. Tell the user to post
with `--comment` and fix with `/plan-lifecycle:pr-fix` instead.

No number → take one from `${CLAUDE_PLUGIN_ROOT}/references/session-pr.md`
first. This command never moves (see above): a target in another repo →
stop: "Re-run `/<command> OWNER/REPO#N` from a checkout of `OWNER/REPO`."

Resolve `OWNER/REPO` once, unless the target named it: `gh repo view --json nameWithOwner -q .nameWithOwner`.

Resolve the target per `${CLAUDE_PLUGIN_ROOT}/references/stack-discovery.md`,
with `ANCHOR` = the number.

- **`STACKED` false** → the PR is its own one-slice stack: `TARGET_PRS` is
  that PR alone, `SIZE = 1`. Wherever `slice <P>/<SIZE> of stack #<S>` or
  `Stack #<S>` appears below, write `PR #<N>` instead.
- **Otherwise** `TARGET_PRS` = every open PR in `SLICES`, bottom first;
  merged slices are skipped. Record each one's position in `SLICES` as
  `P/SIZE`. If none is open, stop. The last PR in `TARGET_PRS` is the
  **top**. A stack with no native number is written `stack of #<bottom>`
  wherever `stack #<S>` appears below.

**Pre-flight:**

- `git status --porcelain` must have no non-`??` lines. A review can pull
  uncommitted changes into its scope, which would put them in all `<K>`
  reviews.
- `git rev-parse HEAD` must equal the top's `sha`. The reviews and the
  verifiers read the code around each diff from this checkout, and only the
  top has every slice's code — a checkout of the default branch has none of
  it. Otherwise stop: "Check out `<top head>` at its PR head first
  (`git switch <top head> && git pull --ff-only`), then run this from that
  checkout."

Print the header: `Stack #<S> — reviewing <K> open PRs: #<a>, #<b>, …` (or
`PR #<N> (not stacked)`).

## Step 1 — Launch one review per slice

In a single message, invoke the `code-review` skill through the `Skill` tool
once per PR in `TARGET_PRS`, with arguments
`REVIEW_ARGS https://github.com/OWNER/REPO/pull/<N>` — flags first: an effort
level placed after the target is not read, and the review silently reuses the
last level instead. Pass the PR URL, not the bare number, so each review
resolves the repository regardless of the working directory.

A review of a PR diffs it against its base branch, which in a stack is the
slice below it — so each review's findings are about that slice's changes. The
code around the diff that a review reads (callers, enclosing functions) comes
from this checkout, the top of the stack, so a finding may rest on a higher
slice's version of that code; Step 2 checks each one against the slice's own
code. Do not review the code yourself and do not launch a second review of a
PR whose review is still running.

Each `Skill` call either returns its review's result at once ("completed
(forked execution). Result: …") or starts the review as a background agent
("launched … running in the background") that reports with a task notification
when it finishes — one run can get both. A review is done when its result is
in, whichever way it came. Do not wait for the others: take each slice
through Step 2 (and Step 3 under `POST`) as soon as its own review is done,
so a slow review holds up only its own slice. If one fails, report it as
failed in its slice's block rather than retrying.

Each result ends with the review's findings as a JSON array — `file`, `line`,
`summary`, `failure_scenario`, most severe first. Step 2 reads them from there.

## Step 2 — Verify the findings

`/code-review` runs no verification at these levels and takes no context
beyond its target, so it cannot know what the PR body, the ADRs, the PR's
commits and review threads or the slices above already settle. Read the
verifier prompt in the `## Verifier prompt` section of
`${CLAUDE_PLUGIN_ROOT}/commands/verify-findings.md` — the one
`/plan-lifecycle:verify-findings` uses for a single review. For each slice
with findings, launch its verifiers — one `general-purpose` agent per group
of findings, split as that file's `## Verify` says — as soon as its review is
done (reviews that finish together go in one message), with that prompt
filled in from its **Stacked PR** row (the
**PR** row when `SIZE = 1`): `<sha>` is the slice's head, `<top sha>` the
top's, `<base sha>` the head of the open slice below it in `TARGET_PRS` (for
the first one, `git merge-base <sha> origin/<its base>`), and the findings are
the review's JSON array. Every sha is in this checkout, so nothing needs
fetching.

Findings of a group that is **unverified** by that file's `## Verify` rule
are listed in their slice's block, and Step 3 does not post them. Step 4 runs
once every slice is through Steps 2 and 3.

## Step 3 — Post the findings (`POST` only)

Posting here, not in the reviews, is what lets every comment carry the marker
`<!-- plan-lifecycle:review-stack -->` that `/pr-fix` keys on. Post only
CONFIRMED and PLAUSIBLE findings — REJECTED and unverified ones stay in the
summary. For each slice with at least one finding to post, post one review:

- **Where each finding goes.** In `gh pr diff <N>`, a hunk header
  `@@ -a,b +c,d @@` covers lines `c` to `c+d-1` of the new file (no `,d`
  means one line; `,0` covers none).
  - `file:line` inside a hunk → an inline comment in the review.
  - `file` in the diff, line outside every hunk → a file-level comment, posted
    after the review. GitHub rejects a whole review if one of its line
    comments is off the diff, and the review call can't carry file-level
    comments; posted on its own, one is a thread that can be resolved like
    any other.
  - `file` not in the diff → the review body.
- **Comment text.** `**<summary>**`, the failure scenario, then the marker,
  separated by blank lines. A `nit` starts with `nit: ` (which `/pr-fix` reads
  as a Nit). A PLAUSIBLE finding adds `_Plausible, not confirmed:_ <evidence>`
  before the marker.
- **Post the review** with `gh api repos/OWNER/REPO/pulls/<N>/reviews --method POST --input <file>`:

  ```json
  {
    "commit_id": "<the slice's sha>",
    "event": "COMMENT",
    "body": "Automated review (`/review-stack <REVIEW_ARGS>`), slice <P>/<SIZE> of stack #<S>: <n> findings.\n\n<one entry per finding whose file is not in the diff: **`path:line`**, then its comment text without the marker>\n\n<!-- plan-lifecycle:review-stack -->",
    "comments": [
      { "path": "<file>", "line": <line>, "side": "RIGHT", "body": "<comment text>" }
    ]
  }
  ```

- **Post each file-level comment** with `gh api repos/OWNER/REPO/pulls/<N>/comments --method POST -f commit_id=<the slice's sha> -f path=<file> -f subject_type=file -f body=<body>`,
  the body being `` **`path:line`** `` and a blank line, then the comment text.

`commit_id` is the head recorded before the reviews ran. Before posting a
slice, check `gh pr view <N> --json headRefOid` still matches it; if the
branch moved, the review and the diff no longer describe the same code, so do
not post that slice — say so in its block.

Post each slice once. If a post fails, show the error in that slice's block
and carry on with the others.

## Step 4 — Summary

One block per slice, bottom-up:

```
## Slice <P>/<SIZE> — PR #<N> <title>
<base> ← <head>
Posted: <the review's html_url>        (POST only)

| # | Where | Verdict | Finding |
|---|-------|---------|---------|
| 1 | `path/to/file.go:123` | confirmed | <one-line summary> |
| 2 | `path/to/file.go:140` | plausible, nit | <one-line summary> |

Rejected:
- `path/to/file.go:88` <one-line summary> — <the verifier's reason, e.g. fixed in #M, or the ADR that records it>

Unverified:
- `path/to/file.go:61` <one-line summary> — <its verifier failed | its verifier's answer did not match its findings>
```

`No findings.` for a clean slice; leave out `Rejected:` and `Unverified:`
when empty. Keep
each review's own ranking (most severe first) and its one-line summaries; the
full failure scenarios and evidence stay in the results, so do not repeat them
unless the user asks.

End with one line: `Stack #<S>: <X> findings across <K> PRs (#<a>: <n>, #<b>: <m>, …), <R> rejected by verification`,
counting confirmed and plausible findings in `<X>`; when any are
unverified add `, <U> unverified`.

With `POST`, add: "Each comment carries the review-stack marker, so
`/plan-lifecycle:pr-fix <S>` verifies each finding like a reviewer's comment
rather than treating it as your own note."

When `REVIEW_ARGS` set an effort level or `--max-findings`, add: "`/code-review`
keeps <those settings> for later runs too; type another level, or
`--max-findings default`, to change them."
