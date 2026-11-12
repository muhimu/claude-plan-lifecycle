This page proves what a PR claims by running it, so you can trust a PR you cannot test yourself. Each claim from the description and the commits was re-proved in a throwaway worktree: tests run, the fix reverted to see its test fail, probes against the built code. Nothing was posted to GitHub.

## Reading order
- **First:** the verdict tiles, then Findings.
- **Then:** For a human, if it is there, and Not checked under Checked / Not checked.
- **Last:** the Claim ledger, when you want the evidence behind a verdict.

## The header
- **You see:** tiles for the outcome, impact, risk and decisions, then the PR (its number links to it on GitHub), its place in a stack, and the head and base commits.
- **How to read it:** the outcome is `needs-changes` (a finding is open), `needs-human` (nothing for the author, but a decision is yours) or `ready`. Impact is what it costs if the change is wrong after merge; risk is the chance it breaks. Both are low, medium or high, by the repository's triage profile when it has one. A stack's page opens on a Stack tab: the worst outcome of its slices (`incomplete` when a slice has no report, or one for an older head), their highest impact and risk and their findings count, a row per slice (its number opens that slice's tab), issues that span slices, facts true of the whole stack (a CI gap, a flake) said once, and checks a slice handed up to another. The slice tabs still repeat those facts.
- **Why:** one line tells you whether to merge, decide or send it back.

**Example**

Triage: needs-changes · impact medium · risk high · decisions none

## Summary
- **You see:** what the change does and how, then why it got that impact and that risk.
- **How to read it:** a high impact always comes with a decision under For a human.
- **Why:** the change in a paragraph, without retelling the diff.

## Claim ledger
- **You see:** one row per claim: the claim and where it was made, how it was re-proved, and the result.
- **How to read it:** green is reproduced, red is failed, a hollow dot is not reproducible here (it needs something this machine lacks). A qualifier after "reproduced" says what held only partly. Totals sit under the table. On this page you can show only the failed and not-reproducible rows.
- **Why:** every verdict on the page traces back to a row here.

**Example**

| Claim | How re-proved | Result |
|---|---|---|
| fixes the crash on empty input (commit) | reverted the fix: its test fails | reproduced |
| works with the old config (body) | ran with the old config | failed: rejects the file |

## Findings
- **You see:** at most five proven problems. Must-fix means merging breaks something real; Should-fix is a real problem short of breakage.
- **How to read it:** each has a trigger (the input or state), an effect (what a user or operator sees), evidence (the command and its result) and a fix. Every finding comes from proving a claim: a claim that failed, a test that passes without the fix, a stale fact in the description. It is not a general bug hunt.
- **Why:** these are what the author must change before merge.

**Example**

1. **Must-fix: an empty config file crashes the server.** `config/load.go:31`
   - Trigger: start with an empty `config.yaml`
   - Effect: the server exits with a nil pointer panic
   - Evidence: a probe with an empty file panics at `load.go:31`
   - Fix: return the defaults when the file is empty

## For a human
- **You see:** the decisions a person has to make, by area: api, database, security, architecture or other, each with the options and a recommendation.
- **How to read it:** a decision is a choice that is expensive to undo, not every change in that area.
- **Why:** the tool proves claims; it does not make these calls for you.

## Owner check
- **You see:** only after a run with `--quiz`: the questions you were asked about this PR, each marked Understood or Gap, with your answer in a line.
- **How to read it:** the questions come from the decisions, the findings and the weakest claims above. A gap names the `file:line` to read; an answer handed back ("you decide") counts as a gap. It changes nothing else on the page.
- **Why:** you stand behind a PR you could not test; this shows where your own picture of it is thin.

**Example**

1. **Understood:** What happens when the retry budget runs out?
   - Answer: the job fails and the error is returned to the caller
2. **Gap:** Why is the lock released before the event is sent?
   - Answer: handed back
   - Read: `queue/worker.go:88` — the send can block on a slow listener

## Checked / Not checked
- **You see:** Checked lists what was verified and produced no finding, such as earlier review threads, problems that are also on the base, and findings fixed higher in a stack. Not checked lists what could not be proven here, each with the next step to prove it.
- **How to read it:** Not checked is as important as the findings: it is what nobody has proven yet.
- **Why:** you see exactly where the evidence stops.
