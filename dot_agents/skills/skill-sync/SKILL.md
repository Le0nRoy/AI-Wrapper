---
name: skill-sync
description: >
  Keep installed agent skills (~/.claude/skills, ~/.claude/commands,
  ~/.claude/plugins/cache, ~/.codex/skills) in sync with the git repos
  they are committed in. Status mode compares every installed skill with
  origin/<default> of its source repo; sync mode commits installed-ahead
  edits on a branch, offers reinstall for outdated copies, and routes
  untracked skills to the right repo. First run onboards a registry.
  Trigger: /skill-sync, "sync my skills", "skill status", "are my skills
  committed", "commit skill changes", "skills differ from repo", "which
  skills are outdated", "update installed skills", "where does skill X
  live"; also after editing a skill under ~/.claude/skills or after
  session-retro applied skill edits. When triggered implicitly, asks one
  yes/no confirmation before running.
---

# Skill Sync

Installed skills drift: edits land in the installed copy, fixes land in
the repo, new skills never get committed. This skill finds the drift and
moves each change to where it belongs. It never pushes unless asked and
never commits to a default branch.

## Confirm first

Explicit invocation (`/skill-sync`, "run skill-sync") → skip this step.
Otherwise (triggered from natural chat or after a skill edit) ask one
yes/no question — `Run skill-sync <status|sync> now?` — via
AskUserQuestion or plain text, and do nothing else until the user
approves. "No" → drop it for this conversation unless asked again.

## Registry

`<agent home>/skill-sync/sources.json`, where `<agent home>` is the client's
own config dir (`~/.claude`, `~/.codex`, …; sandboxed agents cannot write a
shared `~/.agents`). On first run, copy another client's registry if one
exists instead of re-onboarding:

```json
{
  "repos": [{"path": "", "remote": "", "default_branch": "main",
             "visibility": "public|private|company",
             "layout": "skills|plugin-marketplace|chezmoi",
             "skills_root": "dot_agents/skills",
             "install_mechanism": "copy-script|symlink|chezmoi|plugin",
             "notes": "hazards: e.g. install script replaces managed copies"}],
  "skills": {"<installed name>": ["<repo path>", "..."]},
  "routing": ["generic → <public repo>", "company-specific → <company repo>",
              "mixed → generic base in public repo, full override in company repo"],
  "ignore": ["synced/*", "<vendor-installed skill>"]
}
```

No registry → **Onboarding** first.

## Onboarding

1. **Discover repos.** Search likely roots (`~/Workspace`, `~/src`,
   `~/projects`, `~/code`, the chezmoi source dir and its submodules,
   `installLocation`s in `~/.claude/plugins/known_marketplaces.json`)
   for `SKILL.md`, `.claude-plugin/marketplace.json`, or `skills/` dirs.
   Skip `node_modules`, `.git`, caches.
2. **Map** each installed skill to its source(s) by name, then by
   content (`diff -rq`). Several sources = an override chain; record all.
3. **Detect layout** per repo: plain `skills/<name>/`; plugin
   marketplace `plugins/<name>/` with `.claude-plugin/plugin.json` and a
   `marketplace.json` entry; chezmoi-prefixed dirs (`dot_`,
   `executable_`, `private_`, `.tmpl`).
4. **Detect install mechanism and hazards**: copy script (read it — does
   it `rm -rf` installed copies? does it use a marker file like
   `.setup_skills_managed`?), symlinks, `chezmoi apply`, plugin
   marketplace (version-gated updates).
5. **Ask the user** to confirm: the repo list, each repo's visibility,
   routing rules (which skills go where, how to split mixed ones), and
   the ignore list (third-party / vendor skills, claude.ai-synced
   skills under `~/.claude/skills/synced`). One question at a time.
6. Write the registry. Show it.

## Status mode (default)

1. `git -C <repo> fetch origin` for every repo. On failure, say so
   explicitly with the unblock command (`! git -C <repo> fetch origin`)
   and the age of the ref being compared
   (`git log -1 --format=%cr origin/<default>`). Never compare silently
   against stale refs.
2. Compare each installed skill with the repo copy at
   `origin/<default>` (`git archive origin/<default> <skill path> | tar
   -x -C <tmp>` then `diff -r`, or `git show origin/<default>:<file>`).
   Ignore marker files and chezmoi prefixes.
3. Classify:
   - **identical**
   - **installed-ahead** — installed has edits the repo lacks
   - **repo-ahead** — install is outdated
   - **diverged** — both changed
   - **untracked** — installed skill with no source
   - **version not bumped** — plugin content changed, `plugin.json`
     version did not
4. Also list unpushed local branches touching the skill
   (`git log --branches --not --remotes --oneline -- <skill path>`).
5. Output one table: `skill | repo | state | unpushed branch | note`.

## Sync mode

**installed-ahead / diverged** — per repo:

1. Record the current branch; require a clean tree (stop and ask if not).
2. If an unpushed local branch already edits the skill, review it and
   ask whether to commit there instead.
3. Otherwise `git switch -c skills/sync-<YYYY-MM-DD> origin/<default>`
   and `git branch --unset-upstream`.
4. Copy the installed changes into the repo layout (re-add chezmoi
   prefixes; bump `plugin.json` version for plugins). For diverged
   skills, merge by hand and show the result before committing.
5. Commit (conventional message), do not push unless asked, switch back
   to the recorded branch.

**repo-ahead** — offer reinstall via the repo's install mechanism. Warn
first if it is destructive (deletes or overwrites installed copies) and
name what would be lost.

**untracked** — list them; for each, propose a target from the routing
rules and ask. Mixed generic/company skills: generic base in the public
repo, full override in the company repo. Update the registry.

## Rules

- Never commit to a default branch; never push unless asked.
- Never strip company-specific content into a public repo — route it.
- Report every fetch / clone / permission failure with the exact
  command to unblock it.

## Integration

`session-retro` aggregate → apply open items to installed skills →
`skill-sync` sync mode commits them to their source repos.
