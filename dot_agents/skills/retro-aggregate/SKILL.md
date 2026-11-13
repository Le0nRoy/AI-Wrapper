---
name: retro-aggregate
description: >
  Merge session retros from many sessions into one ranked, decidable
  backlog of skill / memory changes, then apply the approved ones.
  Finds each session's retro (saved file or transcript), gets a
  missing retro run in a live session, dedupes and scores proposals,
  verifies their status against current skill and memory files, and
  renders one table with a problem column for decisions. After
  approval, applies changes on fresh branches and hands off to
  skill-sync. Trigger: /retro-aggregate, "aggregate retros", "batched
  retro", "weekly retro", "retro sessions with <prefix>", "sessions
  pending retro", "merge retro proposals".
---

# Retro Aggregate

Turn many per-session retros into one backlog the user can decide on
row by row, then carry out those decisions. The per-session report and
its file format belong to `session-retro`; this skill only reads that
contract (`<agent home>/retros/*.md`, frontmatter `proposals[]`,
`aggregated:`).

Do **not** auto-invoke. The user decides when to aggregate.

## 1. Collect

Input, first match wins:

- Named files → those.
- `since <date>` → saved retros with `date` ≥ it.
- Session titles or a title prefix (e.g. `[retro]`) → one entry per
  session. List live sessions with the client's session list, then
  match titles in transcripts (Claude Code:
  `~/.claude/projects/*/*.jsonl`, `custom-title` entries).
- Default → saved retros without an `aggregated:` field.

For every session, report one status **before** proposing anything:

| Status | Meaning | Action |
|---|---|---|
| saved | retro file exists | read it |
| in transcript | retro output in transcript, no file | extract it; save it later (step 6) |
| missing, live | no retro, session still running | ask that session to run and save `session-retro`, then wait for its reply |
| missing, closed | no retro, session gone | report it; skip |

Never offer to re-run a retro that already ran. A transcript contains
the `session-retro` skill text itself, so detect the retro by the
assistant's own output (its "What went well" heading), not by the
heading text anywhere in the file.

## 2. Merge and score

1. Collect every proposal, deduping items that ask for the same change
   in different words.
2. Per item: stable row id, target (skill / memory / new skill),
   concrete change, **problem** (the user intervention that caused it,
   in one line), sessions that raised it, severity H/M/L,
   score = count × weight (H=3, M=2, L=1).
3. Choose the target with the `session-retro` rule: process rules go to
   skills, personal or environment facts go to memory. Retarget a
   proposal when its retro picked memory for a process rule.

## 3. Verify status

Grep each target SKILL.md / memory for the proposed text. Status is
one of `open`, `partial` (e.g. in memory but not in the skill),
`applied`, or `cannot verify`.

- Never trust an `applied` claim without the text being present.
- If the target skill is not found locally (it may live in a repo
  only the originating session can reach), ask the originating live
  session to locate and verify it. Use `cannot verify` only when no
  such session exists.
- Flag conflicts: proposals that contradict each other, and memories
  that contradict a skill. The later user rule wins, but ask the user
  when the conflict touches a rule they set.

## 4. Render

One table sorted by score:

`# | score | sev | change | problem | target | sessions | status`

Then:

- **Conflicts**, each with the options.
- **Cannot verify**, with what is needed.
- Ask for a decision per row id: approve / decline / modify / need
  details.

For "need details", answer per row: what happened in the source
session (quote the intervention), the current skill text if any, the
proposed change, and a recommendation (approve, decline, or retarget).

## 5. Apply (only approved rows)

- **Where.** Edit the skill's source repo, not only the installed
  copy. Fetch first, then branch from the latest `origin/<default>`
  (use a worktree inside the repo if the user's checkout is dirty).
  Never build on a stale local clone. Install the result afterwards.
- **Repo visibility.** Never put organisation-specific rules into a
  public repo. Retarget them, or ask.
- **Repos you can't reach.** Send the change to the originating
  session, or to the session the user names. Include the problem, the
  exact change, and "branch from latest origin, wait for the user's
  approval before any write".
- **Subagent briefs.** One brief per skill / file set. Before
  dispatching, map **every** approved row id to a brief, and after
  dispatch check that each row id comes back as landed.
- **Review.** Review subagent results against the user's exact
  wording. A subagent may read a rule more broadly than the user
  meant (e.g. turn a target rule into an approval exception).
- **Shared-repo hygiene.** No personal paths or memory-file
  references. Follow the file's character set convention. Bump plugin
  versions where installs depend on them.
- **Blocked writes** (sandbox / permissions): stage the edits in the
  scratchpad and give the user one copy command. Don't try other
  routes around the block.
- **Memory.** When a rule moves into a skill, delete or slim the
  memories that held it, and repoint links to them.

Then hand off to `skill-sync` (commit / MR) when the user asks. Never
commit, push, or open an MR without the user's explicit request.

## 6. Close

- Save each retro that existed only in a transcript as a file, using
  the `session-retro` format.
- Set each proposal's `status` from the user's decisions.
- Add `aggregated: <YYYY-MM-DD>` to every input file.
- Report what remains: unapplied rows, uncommitted branches, and
  pending replies from other sessions.

## What This Skill Does Not Do

- Does not write the per-session retro; `session-retro` does.
- Never applies, commits, or pushes without the user's decision.
- Never asks another session to do something this session was
  denied permission to do.
