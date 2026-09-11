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

6. **Independent review.** Write the review package to a file so the diff never enters this session's context. `git diff` skips untracked files, so register new files (the reproducer test, any new module) with intent-to-add first — that stages nothing and commits nothing:
   ```bash
   git add -N .
   { echo "## Files changed"; git diff --stat HEAD; echo; echo "## Diff"; git diff -U10 HEAD; } > "$SCRATCH/bug-hunt-review-$ROUND.diff"
   ```
   `$SCRATCH` is the session scratchpad directory, `$ROUND` the review round (1 on the first pass). Diff against `HEAD`, not a commit range — nothing is committed until step 8. Spawn a `general-purpose` reviewer via the `Agent` tool using the prompt template at `superpowers:requesting-code-review`'s `code-reviewer.md`, replacing its git-range section with the package path. **Always set `model` explicitly** — a mid-tier model for a small diff, the most capable for anything touching concurrency, security, or multiple subsystems; never let it inherit the session model. Give it:
   - the original symptom (verbatim from `$ARGUMENTS`)
   - the review package path
   - the new test's path
   - an explicit instruction to check for regressions in adjacent code paths (callers of the changed function, sibling cases in the same switch/if-chain, related tests that were not run)

   The reviewer must answer two questions: *Does this fix the reported symptom?* and *What does this fix break?*

7. **Iterate on review — 5 rounds maximum.** If the reviewer flags any high-confidence issue, go back to step 4 (or step 2 if the root cause was wrong), addressing the whole findings list in one pass. Re-run the full verification. Write a fresh package and re-spawn the reviewer. From round 4 on, dispatch the reviewer on the most capable available model (if it is not already there) — after three rounds the same reviewer tier is not seeing the problem. When round 5 still leaves findings open, stop looping: adjudicate each residual yourself (wrong reviewer / real-but-deferrable / real-and-blocking) and carry the adjudications into the step 8 *Reviewer notes* — a residual you judge blocking means the hand-off states the fix is incomplete.

8. **Hand off.** Only when both you and the reviewer agree the fix is correct and complete, or the round-5 cap tripped and every residual is adjudicated per step 7:
   - Mark the hypothesis task complete.
   - Present a commit-ready diff (do not commit yet — wait for user approval).
   - Draft a PR description with: *Symptom*, *Root cause*, *Fix*, *Test*, *Reviewer notes*.

## Hard rules

- **Evidence before assertions.** Never claim "fixed" without showing the test output that proves it. The reviewer's verdict is also evidence — quote it.
- **Hypothesis discipline.** If the test fails for a reason you didn't predict, your hypothesis is wrong. Update the task list and re-rank before writing more code.
- **No silent scope creep.** If you find a second bug while fixing the first, write it as a new hypothesis task and stop — do not fix two things in one diff.
- **Branch discipline.** Work on the currently checked-out branch. Do not create branches inside this command (the user handles branching via worktree or manually).
- **Commit policy.** Do not run `git commit` until the user explicitly approves the diff. The handoff in step 8 is a presentation, not a commit trigger.
