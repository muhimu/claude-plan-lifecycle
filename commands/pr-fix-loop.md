---
description: Run /pr-fix in an autonomous loop — apply fixes, push, wait for the automated review workflow to post a new review, repeat until the review is clean or the round cap is hit. Accepts a PR or stack number.
argument-hint: [PR or stack number — optional, auto-detects from the current branch or this session's PRs] [free-text guidance, passed through to pr-fix]
---

# PR Fix Loop

Drive `/plan-lifecycle:pr-fix` rounds autonomously until the PR review is clean. This command only sets up the loop — do not run pr-fix directly from here.

If the first token of `$ARGUMENTS` is not a PR target (a number, PR URL or `OWNER/REPO#N`), take one from `${CLAUDE_PLUGIN_ROOT}/references/session-pr.md` now, as `/plan-lifecycle:pr-fix` would (it pushes, needs the **head**, and may move), and put it in front of `$ARGUMENTS` as `OWNER/REPO#N` — whether it came from the current branch or the session — so every round targets the same PR: a stack round can leave a different branch checked out, and later rounds never ask again.

Invoke the `loop` skill via the `Skill` tool now, with **no interval** (self-paced), passing exactly this prompt as its args (with `$ARGUMENTS` substituted):

```
/plan-lifecycle:pr-fix $ARGUMENTS — run autonomously:

- Don't wait for my approval on the plan table. Apply your recommended bucket for
  each item — my guidance in the arguments above takes precedence over your own
  classification and holds for every round. A self-note the verifier
  rejected stays a Self-note and is fixed; list it with its `rejected:`
  evidence in the summary so I can revert it. Pushbacks and questions stay as drafted replies in the summary — never
  post anything to GitHub. All of pr-fix's hard rules still apply (no GitHub
  mutations, no force push, no auto-merge).
- Stacked PRs: under this loop /restack aborts where its push gate would
  ask (its Step 5.2). That, or any other /restack stop (genuine conflict,
  red tip, lease failure), ends the loop; report it.
- After pushing, wait for the repo's automated review workflow (e.g. claude-review)
  to post NEW feedback before starting the next round. It may arrive as a plain PR
  comment, not a review — poll `gh pr view <N> -R OWNER/REPO --json comments,reviews` (the pinned PR's repo) and only
  proceed once the workflow has posted something with a timestamp later than your
  push. In stack mode, wait on EVERY PR whose branch was pushed or restacked this
  round — a restack retriggers CI and review on the slices above. Never re-process
  feedback you already handled in an earlier round. Feedback on a PR other than
  the pinned one is not this loop's to fix: list it in the round summary as
  `#<M>: new feedback — run /plan-lifecycle:pr-fix <M>` and leave it out of the
  clean/stop judgment.
- Automated reviewers almost always find *something* — before classifying, judge
  whether the new feedback is substantive at all. Raise the bar each round: by
  round 3+, only clear correctness, security, or data-loss issues count as
  actionable; taste-level nits, restatements of earlier feedback, and
  churn-for-churn's-sake get a drafted pushback reply instead of a code change.
- Track the round number across iterations. Stop the loop and notify me when:
  - a round produces no substantive actionable items (review is effectively
    clean — nit-only rounds count as clean), or
  - 5 rounds have completed, or
  - no new review has appeared 30+ minutes after a push (workflow likely
    missing or stuck — report what you observed).
```

While waiting for the review workflow, pace wakeups to how long the workflow usually takes to run — don't poll every minute.
