---
description: Run /pr-fix in an autonomous loop — apply fixes, push, wait for the automated review workflow to post a new review, repeat until the review is clean or the round cap is hit. Accepts a PR or stack number.
argument-hint: [PR or stack number — optional, auto-detects from current branch] [free-text guidance, passed through to pr-fix]
---

# PR Fix Loop

Drive `/plan-lifecycle:pr-fix` rounds autonomously until the PR review is clean. This command only sets up the loop — do not run pr-fix directly from here.

Invoke the `loop` skill via the `Skill` tool now, with **no interval** (self-paced), passing exactly this prompt as its args (with `$ARGUMENTS` substituted):

```
/plan-lifecycle:pr-fix $ARGUMENTS — run autonomously:

- Don't wait for my approval on the plan table. Apply your recommended bucket for
  each item — my guidance in the arguments above takes precedence over your own
  classification and holds for every round. Pushbacks and questions stay as drafted replies in the summary — never
  post anything to GitHub. All of pr-fix's hard rules still apply (no GitHub
  mutations, no force push, no auto-merge).
- Stacked PRs: when pr-fix hands off to /restack, answer its push gate with
  "Push all" only if the range-diff shows every commit mapping unchanged (no
  added or dropped commits). Otherwise choose Abort, stop the loop, and report.
  Any other /restack stop (genuine conflict, red tip, lease failure) also ends
  the loop.
- After pushing, wait for the repo's automated review workflow (e.g. claude-review)
  to post NEW feedback before starting the next round. It may arrive as a plain PR
  comment, not a review — poll `gh pr view <PR> --json comments,reviews` and only
  proceed once the workflow has posted something with a timestamp later than your
  push. In stack mode, wait on EVERY PR whose branch was pushed or restacked this
  round — a restack retriggers CI and review on the slices above. Never re-process
  feedback you already handled in an earlier round.
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
