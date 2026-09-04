---
name: session-retro
description: >
  Retro the current conversation from the user's perspective and turn
  the pain points into concrete skill / memory improvement proposals.
  Categorises interactions into what went well (no user clarifications
  needed), what didn't (user had to clarify, correct, redirect, or
  request additional analysis), and notable patterns. For each "didn't
  go well" item, proposes a concrete fix — new skill, update to an
  existing skill, or a memory to save. One-shot report; does not
  modify skills or memory itself. Trigger: /session-retro, "do a retro",
  "session retro", "retro this session", "retro the <topic> part".
---

# Session Retro

Analyse the conversation that just happened and report where the
assistant carried the load on its own vs. where the user had to
intervene. Turn every intervention into a concrete skill or memory
change the user can act on.

## When to Use This Skill

- User explicitly asks for a retro (`/session-retro`, "do a retro",
  "session retro", "how could we improve here").
- User names a slice ("retro the rebase part") — analyse only that
  slice.

Do **not** auto-invoke. The user decides when to retro.

## Perspective — the measurement

The retro measures the assistant's performance from the **user's**
perspective. The unit of analysis is how much the user had to
intervene to get the outcome they wanted.

- **Good** — user's prompt was sufficient, the assistant executed
  without asking for clarification, additional analysis, or a
  redirect. The user's role after the initial ask was
  approve / confirm / hand-off to the next task.
- **Bad** — the user had to clarify requirements, correct a wrong
  direction, ask for more analysis, redirect the approach, or repeat
  guidance the assistant already had (in this session, in a skill,
  or in memory).
- **Notable** — worth remembering but not cleanly good or bad:
  surprising successes, memory hits/misses, tool failures,
  environmental gotchas, validated non-obvious judgment calls.

An assistant clarifying question counts as a **bad turn** — the user
still had to intervene before the assistant could act. But attribute
the cause honestly:

- **Agent-side gap** — the missing info was inferable from the
  codebase, prior context, an existing skill, or a memory that should
  have fired. Actionable via §4 (new skill, skill update, or memory).
- **User-side prompt gap** — the prompt was genuinely ambiguous or
  missing context the assistant could not have inferred. No skill or
  memory fixes this; record it under §4 as "No action — user-side
  prompt hygiene" with a one-sentence note on what the prompt was
  missing, so the user can spot the pattern themselves.

## Retro Structure

### 1. What went well

Bullets. Each item names the topic (or the turn) and one sentence on
why it went well — what the assistant inferred correctly, executed
without a redirect, or scoped right. Confirming a pattern worth
repeating, not complimenting.

### 2. What didn't go well

Bullets. Each item is a **user intervention**. Format:

- **[topic]** — one sentence describing the intervention.
  **Signal:** what this reveals about a gap (missing skill, stale
  skill, missing memory, wrong default, weak trigger phrasing).

### 3. Notable

Bullets. Anything else worth remembering: memory that fired usefully,
memory that should have fired and didn't, a skill that misfired,
a tool the user had to run themselves because of the sandbox,
long unproductive tangents, validated non-obvious approaches.

### 4. Recommendations

One recommendation **per** §2 bullet. Exactly one of:

- **New skill** — `<name>` · one-line purpose · trigger phrasing it
  should match · specific gap it closes.
- **Update skill** — `<skill-name>` · what to add or change · which
  section of the SKILL.md.
- **Save memory** — type (user / feedback / project / reference) ·
  one-line content · why.
- **No action** — one-off that does not generalise, OR a user-side
  prompt hygiene issue (missing info was not inferable). State which
  and why.

Recommendations are proposals. This skill does not create or edit
skills or write memory — the user picks which recommendations to
execute and invokes the follow-up work separately.

## Analysis Approach

Read the whole session (or the named slice) before writing anything.

**Intervention signals** — feed §2:

- "no", "actually", "instead", "not that", "wait"
- "you missed", "you should have", "you forgot"
- "can you also X" arriving *after* an initial answer that should
  have covered X
- "let me clarify", "what I meant was"
- Same question re-asked
- User running the command themselves because the assistant proposed
  wrong syntax or a broken tool
- User saying "check X" for something the assistant should have
  checked

**Success signals** — feed §1:

- No follow-up clarification after a substantive request
- "perfect", "yes exactly", "proceed", "go ahead"
- A non-obvious approach the user accepted without pushback (also
  log under §3 — it's a validated judgment call)

**Notable signals** — feed §3:

- Tool errors the user had to fix themselves (permission / sandbox)
- Memory that fired usefully — a hit worth keeping
- Memory that should have fired and didn't — a miss worth fixing
- Skill invocations that misfired (wrong skill triggered, right
  skill missed)
- Long unproductive tangents

## Scope Rules

- **This session only** unless the user says otherwise. Do not pull
  in previous-session memory to inflate the report.
- If the user names a slice, stay in that slice.
- Every bullet earns its place — cite the topic / turn, don't
  paraphrase vaguely. Aim for ≤ 5 bullets per section unless the
  session genuinely warrants more.
- No gratuitous praise or blame.

## What This Skill Does Not Do

- No file edits, no commits, no memory writes.
- No further codebase investigation — works from the transcript.
- Does not chain into skill creation. The user does that afterward.
