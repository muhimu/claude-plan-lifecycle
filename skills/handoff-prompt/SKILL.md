---
name: handoff-prompt
description: Use when the user asks for a prompt to continue work in a new session, a handoff prompt, a clean context prompt, or wants to hand off an implementation plan to a fresh session. Also use when brainstorming or planning is complete and the user wants to start execution in a new session.
---

# Handoff Prompt

Generate a self-contained prompt for a new Claude Code session to execute work from the current conversation.

## When to Use

- User says "give me a prompt for a new session"
- User says "handoff prompt" or "clean context prompt"
- Planning/brainstorming is done, user wants fresh context for implementation
- User wants to continue work after `/clear`

## Process

1. **Gather** from current conversation:
   - Plan file path and design spec path (if any)
   - 2-3 sentence summary of what to implement
   - Starting point (which task, what to do first). If a
     `subagent-driven-development` ledger exists for the plan
     (`<repo-root>/.superpowers/sdd/<plan-basename>/progress.md`), the
     starting point IS the ledger: the first task without a
     `Task <N>: complete` line
   - Key decisions and caveats the new session must know
   - Build/test/lint commands

2. **Write** a prompt with these sections:
   - **What to do** (1-2 sentences)
   - **Files to read first** (plan, spec — with full paths)
   - **Summary** (what the plan does, in brief)
   - **Start by** (first concrete action)
   - **Key context** (bullet list of decisions, caveats, gotchas that aren't in the plan files)

3. **Output** the prompt in a fenced block so the user can copy-paste it.

## Template

```
Implement [feature/change] for [project context].

- **Design spec:** `[path]`
- **Implementation plan:** `[path]`

**Summary:** [2-3 sentences of what the plan does]

**Start by:** [First concrete action — e.g., "Read both files, then execute Task 1 (revert commit X). Create a feature branch first." If a ledger exists: "Read `<ledger path>` and resume from the first task without a `complete` line — do not redo completed tasks."]

**Key context:**
- [Decision or caveat not obvious from the plan]
- [Another one]
- [Build/test commands if non-standard]
```

## Rules

- The prompt must be **self-contained** — the new session has zero context from this conversation
- Reference file paths, not conversation content — the new session can read files but can't see our chat
- Include only context that ISN'T already in the plan/spec files — don't duplicate
- **Do NOT restate rules already in global/project CLAUDE.md, AGENTS.md, or GEMINI.md.** The new session loads these automatically. Examples to omit: branch naming conventions, commit message rules (no Co-Authored-By, no Claude footer), worktree locations, plan file locations, "never commit to main", subagent rules. If you're tempted to write a "Conventions" or "Ground rules" section that just echoes global preferences, delete it.
- **If an SDD ledger exists for the plan, the prompt must name its path and say to resume from the first task without a `complete` line.** A fresh session that skips the ledger re-dispatches finished tasks — the most expensive failure the skill's authors have observed.
- Keep it under 300 words — long prompts waste the new session's context
- Don't include implementation details — that's what the plan file is for
