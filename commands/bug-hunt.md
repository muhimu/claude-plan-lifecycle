---
description: Autonomous red-green-refactor bug hunter with reviewer subagent gate
argument-hint: <issue text, Slack thread, or bug report>
---

# Autonomous Bug Hunter

Act as an autonomous bug hunter for this issue:

$ARGUMENTS

## Workflow — do not ask permission between steps

1. **Hypothesize.** Investigate the codebase with `Grep`/`Read` to form 2–3 root-cause hypotheses. Write them as a `TaskCreate` list (one task per hypothesis), ranked by likelihood with a one-line rationale each.

2. **Write the failing test.** For the top hypothesis, write a test that reproduces the bug at the correct abstraction layer (unit if the bug is in a pure function, integration if it crosses package boundaries, end-to-end only if the bug is wiring/config). Prefer the smallest layer that can fail for the real reason.

3. **Confirm red for the right reason.** Run the test via `Bash`. Read the failure output and verify it fails because of the hypothesized cause — not a compile error, missing import, wrong assertion, or unrelated panic. If the failure mode doesn't match the hypothesis, fix the test before touching production code. Mark the hypothesis task in-progress.

4. **Minimum fix.** Implement the smallest change that turns the test green. No drive-by refactors, no extra error handling for cases the test doesn't cover, no speculative abstractions.

5. **Verify green and clean.** Run:
   - the project's full test suite scoped to the affected module (e.g. `go test ./...`, `pytest`)
   - the project's linter on the touched files
   Both must pass. If they don't, iterate — do not proceed.

6. **Independent review.** Spawn a reviewer subagent via the `Agent` tool with a code-review subagent type if one is available (e.g. `feature-dev:code-reviewer`), else `general-purpose`. Give it:
   - the original symptom (verbatim from `$ARGUMENTS`)
   - the diff (`git diff`)
   - the new test
   - an explicit instruction to check for regressions in adjacent code paths (callers of the changed function, sibling cases in the same switch/if-chain, related tests that were not run)

   The reviewer must answer two questions: *Does this fix the reported symptom?* and *What does this fix break?*

7. **Iterate on review.** If the reviewer flags any high-confidence issue, go back to step 4 (or step 2 if the root cause was wrong). Re-run the full verification. Re-spawn the reviewer with the updated diff. Repeat until the reviewer returns clean.

8. **Hand off.** Only when both you and the reviewer agree the fix is correct and complete:
   - Mark the hypothesis task complete.
   - Present a commit-ready diff (do not commit yet — wait for user approval).
   - Draft a PR description with: *Symptom*, *Root cause*, *Fix*, *Test*, *Reviewer notes*.

## Hard rules

- **Evidence before assertions.** Never claim "fixed" without showing the test output that proves it. The reviewer's verdict is also evidence — quote it.
- **Hypothesis discipline.** If the test fails for a reason you didn't predict, your hypothesis is wrong. Update the task list and re-rank before writing more code.
- **No silent scope creep.** If you find a second bug while fixing the first, write it as a new hypothesis task and stop — do not fix two things in one diff.
- **Branch discipline.** Work on the currently checked-out branch. Do not create branches inside this command (the user handles branching via worktree or manually).
- **Commit policy.** Do not run `git commit` until the user explicitly approves the diff. The handoff in step 8 is a presentation, not a commit trigger.
