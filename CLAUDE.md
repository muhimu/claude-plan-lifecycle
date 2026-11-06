# claude-plan-lifecycle

## Public repo: no private references

This repo is public. Never mention private repositories, their PR or issue numbers, branch names, or internal details in PR descriptions, commit messages, or any other committed text. The motivating cases usually come from private company repos; describe them generically ("observed on a real stack") instead.

Before `gh pr create` or `gh pr edit`, grep the body for private org names and PR numbers. Generic descriptions of the behavior are fine; identifiers are not.

## Report skills: local first, Markdown as source of truth

Reports from skills such as `pr-triage` and `review-guide` are read first as a local rendered HTML view. They are published as an Artifact only when the user asks to share one.

- Don't add auto-publish or `--publish` flags to report skills. `pr-triage` promises to stay local.
- Keep the Markdown report as the source of truth: `pr-triage`'s handed-up deferral step parses it. HTML is a rendering of it.
