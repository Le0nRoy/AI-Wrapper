# Owner-accepted security exceptions

Deliberate exceptions to the general sandbox rules in `AGENTS.md`
(Section 3: "use `--ro-bind`", "never weaken bubblewrap or Seatbelt
restrictions"), plus residual risks the owner accepted. Each one is an
owner decision, not a gap to close: do not "fix" it without the owner
asking. The reasoning and test coverage live in
[`docs/security-concerns.md`](security-concerns.md); this file is the
short list of what stays as it is.

## Full git-dir write access (B-ρ)

**Allowed.** The agent has full read-write access to the repository's git
dir, including `config`, `hooks/`, `config.worktree`, `commondir`,
`info/`, `modules/` and `worktrees/`:

- plain repository: `WORKDIR/.git` through the WORKDIR bind;
- linked worktree: the whole common dir (`<repo>/.git` or a bare
  repository), bound by `_wrapper_bind_git_common_dir`
  (`bin/ai_wrapper_data/ai_wrapper_lib.bash`);
- submodule checkout: exactly `<super>/.git/modules/<name>`, never
  `<super>/.git` or sibling submodules.

The agent can plant hooks or config (`core.fsmonitor`, `core.hooksPath`,
aliases, filter drivers) that host git runs later. The owner accepts this
for usability.

**Do not reintroduce:**

- read-only overlays, pins or placeholders on git dirs or on their
  entries (`config`, `hooks/`, `commondir`, `config.worktree`, ...);
- location blocklists for git dirs (system or temp trees, dotfile dirs,
  credential or host-executed locations, AI agent profile/state
  directories: see the next entry);
- the retired settings `AI_SANDBOX_ALLOW_GIT_CONFIG`,
  `AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES` and
  `AI_SANDBOX_BLOCK_LINKED_GIT_DIRS`, or any other switch that turns git
  off or makes the git dir read-only.

**Keep:**

- the pointer checks (`_wrapper_git_common_dir_ok`): real directory, not
  `$HOME`, git-dir shape, module layout, forward and reverse links naming
  this checkout;
- the bind order: the git dir is an `--under-bind`, so every read-only
  overlay and pin stays on top of it;
- the descriptor bind on Linux (`--bind-fd`, bwrap 0.8 and newer), so a
  path swapped after the check is not mounted.

Details: [`docs/security-concerns.md`](security-concerns.md) → B-ρ
("Decision", "Pointer sanity", "No location blocklist", "Bind order").

## Git dirs inside AI agent profile/state directories are not refused (B-ρ)

**Allowed.** A git dir that is equal to, contains or is inside an AI
agent profile or state directory gets no special treatment: if it passes
the link checks (`_wrapper_git_common_dir_ok`) it is bound read-write as
a whole, like any other git dir. That covers `~/.claude`,
`~/.claude.json`, `~/.codex`, `~/.gemini`, `~/.copilot`,
`~/.config/github-copilot`, `~/.local/share/copilot` and the named
account profiles (`~/.claude-<name>/`, `~/.claude-<name>.json`,
`~/.codex-<name>/`, `~/.gemini-<name>/`), relocated profiles included.

**Accepted risk (cross-agent).** The link checks assume a pointer can
only reach a directory the agent could already write. That holds per
session, not across clients: each client can write its own profile.
Example: a Copilot session makes its own `~/.config/github-copilot`
git-shaped (`HEAD`, `config`, `objects/`, `refs/`) with a worktree entry
whose `gitdir` back-link names a project checkout, and writes that
checkout's `.git` gitfile pointing at the entry. Both links verify. A later Claude (or Codex,
Antigravity) session launched in that checkout gets Copilot's whole
profile, tokens and settings included, bound read-write. Similarly, an
agent that can write both its profile and a git dir can hard-link a
profile file (e.g. its token file) into that git dir; any later session
whose launch binds that git dir reads and writes the file through it.

**What still limits it:**

- the link checks: the planting agent must already be able to write both
  ends (the git dir with its back-link and the checkout's gitfile), so
  nothing outside what some sandboxed agent can write is reached;
- the bind order: the git dir is an `--under-bind`, so the launching
  client's own read-only controls (settings, skills, hooks, `~/bin`,
  credential overlays, `AI_SANDBOX_EXTRA_RO_DIRS`) stay read-only on top
  of it.

**Do not reintroduce** a refusal of git dirs in AI agent profile/state
directories (by path or by filesystem identity) without owner approval.
Details: [`docs/security-concerns.md`](security-concerns.md) → B-ρ,
"Agent profile and state directories".

## Stale worktree entries (B-ρ residual)

A worktree deleted without `git worktree remove` or `prune` leaves its
entry naming the old path. An agent that can write that path can recreate
the checkout there, and a later launch from it binds the repository's git
dir. Accepted; mitigation: run `git worktree prune` in sensitive
repositories. Details: [`docs/security-concerns.md`](security-concerns.md)
→ B-ρ, "Pointer sanity".

## Non-cooperating AGY title writers (B-μ residual)

The conversation rename lock is advisory. A writer that does not take it
(agy itself, or a sandboxed agent on the same profile) and writes
`.wrapper_title` between the final re-check and the rename loses that
write. The owner kept rename available under this limit. Details:
[`docs/security-concerns.md`](security-concerns.md) → B-μ, "Residual
limits".

## Saved presets keep relaxed settings (S-μ)

Ordinary settings, red and yellow ones included, persist in the
per-workdir preset by owner choice. Restoring one at a non-default value
WARNs, and a value set at launch always wins. Details:
[`docs/security-concerns.md`](security-concerns.md) → S-μ.

## No resource limits (S-ζ)

Rlimits are not enforced on either backend; the owner accepts unbounded
CPU, memory, file-descriptor and process use by the agent. Re-adding them
is a separate follow-up, not an ad hoc change. Details:
[`docs/security-concerns.md`](security-concerns.md) → S-ζ and
"Decisions / Non-goals".
