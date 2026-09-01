---
description: Run /pr-fix in an autonomous loop — apply fixes, push, wait for the automated review workflow to post a new review, repeat until the review is clean or the round cap is hit
argument-hint: [PR number — optional, auto-detects from current branch]
---

# PR Fix Loop

Drive `/plan-lifecycle:pr-fix` rounds autonomously until the PR review is clean. This command only sets up the loop — do not run pr-fix directly from here.

Invoke the `loop` skill via the `Skill` tool now, with **no interval** (self-paced), passing exactly this prompt as its args (with `$ARGUMENTS` substituted):

```
/plan-lifecycle:pr-fix $ARGUMENTS — run autonomously:

- Don't wait for my approval on the plan table. Apply your recommended bucket for
  each item. Pushbacks and questions stay as drafted replies in the summary — never
  post anything to GitHub. All of pr-fix's hard rules still apply (no GitHub
  mutations, no force push, no auto-merge).
- After pushing, wait for the repo's automated review workflow (e.g. claude-review)
  to post NEW feedback before starting the next round. It may arrive as a plain PR
  comment, not a review — poll `gh pr view --json comments,reviews` and only proceed
  once the workflow has posted something with a timestamp later than your push.
  Never re-process feedback you already handled in an earlier round.
- Track the round number across iterations. Stop the loop and notify me when:
  - a round produces no actionable items (review is clean), or
  - 5 rounds have completed, or
  - no new review has appeared 30+ minutes after a push (workflow likely
    missing or stuck — report what you observed).
```

While waiting for the review workflow, pace wakeups to how long the workflow usually takes to run — don't poll every minute.
