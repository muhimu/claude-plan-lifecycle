This page points you at the parts of a colleague's PR that need a human's judgement, and tells you what you can skip. It does not hunt bugs: `/code-review` and `/plan-lifecycle:review-stack` do that. It is shared with the PR's author, so everything on it is phrased as a question they can answer.

## Reading order
- **First:** the summary line under the title, then Since the last guide when the page was written again, then Decisions, then Route, then Review findings when the guide ran the review.
- **Then:** Permanent after merge, Ship or block, Who must act after merge.
- **Last, or never:** Riskiest code (hand it to a bug-hunting tool) and Skip. Riskiest code appears only for a PR whose findings are not on the page: where they are, the tool already looked.

Sections with nothing in them are left out. Before you read appears only when you know little of this code (`new` mode); Hot files only when you know it well (`expert` mode). A stack page adds How the stack splits and Resolved across the stack.

## The header
- **You see:** the PR number (a link to it on GitHub) and title; author, head and base commits, date and mode; a summary line with the counts.
- **How to read it:** the mode says why the page is shaped as it is (`expert`: your commits on these paths this year; `new`: few or none). The summary's clause is the biggest decision on the page.
- **Why:** you know in one line whether there is anything to decide at all.

**Example**

> **2 decisions · 1 judgement call · 3 to skip.** Whether the new cache lives in the request path.

## Since the last guide
- **You see:** on a page written again for the same PR, what changed since the last guide: the new commits, or a line saying the PR was rebased, then the earlier stops and Decisions sorted into Resolved, Still open and New.
- **How to read it:** Resolved names the change that settled it; No longer ranked is still in the code but outranked by newer items; Merged (on a stack page) belongs to a slice that has merged since; Still open points at its new place on this page; New says which commit brought it. "Rebased onto" means the author moved the PR onto a newer base: what came from the base is not listed as theirs. "Previous head no longer exists" means the old commits are gone, so only the pages were compared.
- **Why:** the author's answers show up as code changes, so you read only what moved since your last pass.

**Example**

- 2 commits: move the cache call into the service; add an eviction test
- Resolved: `internal/cache/store.go:42` — the storage import is gone (`internal/service/orders.go:88` now calls it)
- Still open: Retries stay in the client (now Decision 1)

## How the stack splits
- **You see:** one line per slice of the stack, bottom first: what that slice adds.
- **How to read it:** later sections tag each item with its slice, like `(#12)`, or `(#12, used by #13)` when a higher slice depends on it.
- **Why:** you can review slice by slice, or read this one page for the whole stack.

## Before you read
- **You see:** the path a request or job takes through the changed code, the terms the diff relies on, the docs and ADRs that govern it, and whom to ask.
- **How to read it:** all of it comes from the base, before this PR. Ask is the people with the most commits on these paths, not the author, led by whoever the README's Contact section names.
- **Why:** the map you would otherwise build by reading the code.

## Decisions
- **You see:** up to three rulings the PR itself records, ranked by stakes, each with its stated cost if wrong.
- **How to read it:** 🔒 marks a ruling that sets something hard to undo after merge. The line under each ruling names the assumption it rests on: that is what to check. Checked says what the code shows about the ruling's stated reason: confirmed (the code does what the reason says), qualified (only in part, or only under a condition the PR does not state), contradicted (the code does otherwise), or not checkable here (only a live system or another team could answer; "check did not run" means the check itself failed, not that the ruling needs one). A contradicted or qualified ruling ranks first among rulings of the same stakes.
- **Why:** these are the calls only a human can make. Agree in a thread, or push back on the assumption.

**Example**

1. 🔒 **Retries stay in the client** — if wrong, every caller has to add its own. Agree, or push back on: callers never need a different retry budget.
   - **Checked:** qualified — `client/retry.go:31` caps every call at 3 tries, but `jobs/export.go:58` already wraps the client in its own retry loop.

## Route
- **You see:** at most five numbered stops, ⚑ each, where the change departs from how the rest of the system works.
- **How to read it:** each stop has Look for (what you will see there), Why (what is at stake), Precedent (how the repo does it elsewhere, in `new` mode), Rule (the doc line or base evidence it is read against) and Ask the author (a question to post as is). A stop on a doc the PR edits means the PR changes the rules it is read against.
- **Why:** every stop rests on a rule, never on taste. No stop is a good result.

**Example**

### 1. ⚑ `internal/cache/store.go:42`
- **Look for:** the cache imports the storage client.
- **Why:** on the base the cache knows nothing of storage; now it does.
- **Rule:** base: `internal/cache` imports no storage package.
- **Ask the author:** Keep the storage call in the cache? If so, why there and not in the service?

## Review findings
- **You see:** with `--review`, the bugs `/plan-lifecycle:review-stack` found, each checked by a verifier: where it is, its verdict and a one-line summary. Below the table, the findings the verifiers rejected, each with the reason.
- **How to read it:** confirmed means the verifier reproduced the reasoning against the code; plausible means it could not rule it out. A finding rejected because the PR records it as a decision also shows under that Decision: the review and the author disagree, and that is yours to settle. A stack page has one block per slice. "Findings left out" means the PR moved after the review: run the guide again.
- **Why:** the bugs and the design calls on one page, so nothing found is lost. Nothing is posted to the PR.

**Example**

| # | Where | Verdict | Finding |
|---|-------|---------|---------|
| 1 | `internal/cache/store.go:58` | confirmed | an expired entry is returned once before eviction |

Rejected:
- `internal/cache/store.go:90` lock held across the network call — the body records this as a decision

## Resolved across the stack
- **You see:** stops in a lower slice that a slice above fixes.
- **How to read it:** the stop stays on its own slice's page, with "fixed in #M".
- **Why:** you do not raise in review what the stack already fixes.

## Permanent after merge
- **You see:** what becomes hard to undo once this ships and no Decision covers: a proto field, a DB column or migration, a new ADR, a default callers will rely on.
- **How to read it:** each line points at the file and line that sets it.
- **Why:** ordinary code can change in the next PR; these cannot.

## Ship or block
- **You see:** what the PR defers or leaves unverified, and dependencies in other repos, each with a call and what decides it.
- **How to read it:** Block: the PR fails at launch without it. Ship unless: it breaks something after merge, but there is time to fix it. After merge: only a live run can check it. Ship: a check confirmed it, so you need not.
- **Why:** deferred work is a decision too; this makes it explicit.

**Example**

- **Block:** the job's role lacks the new grant (`deploy/role.yaml:12`) — the job fails at start without it.
- **Ship:** "tests cover the timeout path" — `make test` ran it.

## Who must act after merge
- **You see:** people, repos or environments that must do something once this merges.
- **How to read it:** each line names who and what, such as a client to update or a database to recreate.
- **Why:** a merge that needs a follow-up nobody owns is how things break later.

## Hot files
- **You see:** changed files with fix or revert commits in the last 90 days, with the latest subject.
- **How to read it:** a hot file had recent trouble: read its changes more closely.
- **Why:** past fixes are the best predictor of the next one.

## Riskiest code
- **You see:** the changed code in neither a stop nor Skip, in up to five groups, riskiest first, each with the question to answer while reading it.
- **How to read it:** these are not findings, just where a bug-hunting tool such as `/plan-lifecycle:review-stack` should look hardest.
- **Why:** correctness is that tool's job; this page tells it where to start.

## Not in the body
- **You see:** what the code does that the PR's description does not say: behaviour it leaves out, claims the code does not carry out, scope beyond what it states.
- **How to read it:** a difference tied to a stop sits in that stop's Why instead. Earlier threads counts the review threads people opened on the current code (not outdated ones, nor a bot's), how many are unresolved, and what they asked: check that the code answers them before you raise the same point.
- **Why:** the description is what reviewers and later readers trust.

## Skip
- **You see:** files that need no reading: generated code, renames, fixtures, lockfiles, vendored code.
- **How to read it:** when the tool was unsure, it left the file out of this list.
- **Why:** less to read, with a reason for each.
