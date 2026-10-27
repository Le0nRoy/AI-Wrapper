Antigravity CLI (`agy`) Wrapper Help

This wrapper provides an interactive menu for starting Antigravity CLI (`agy`)
sessions with optional orchestration workflows, inside the same sandbox as the
Claude and Codex wrappers (bubblewrap on Linux, sandbox-exec on macOS).

## Menu Options

### 1) Start orchestration
Launches Antigravity CLI with the orchestrator prompt (`orchestrator-prompt.md`)
injected into the interactive session, i.e.
`agy --dangerously-skip-permissions --prompt-interactive "<prompt>"`.
Managed skills from `~/ai-wrapper/.agents/skills/` (including
`orchestrator-mode`) are synced into the active profile's `config/skills/`
directory so Antigravity discovers them automatically.
Use for multi-phase development workflows: plan → implement → test → review → merge.

### 2) Start new conversation
Launches a plain Antigravity CLI session with no initial prompt.

### 3) Resume from list
Lists saved top-level conversations from the active profile's
`antigravity-cli/conversation_summaries.db` (and `brain/` transcripts),
prioritizing the current working directory. From the picker you can:
- Select a conversation by number (`1`-`N`, `Enter` for `1`) or UUID prefix to
  launch `agy --dangerously-skip-permissions --conversation=<id>`.
- Press `r` (or `r <num> [new title]`) to rename a saved conversation in place.
- Press `d` (or `d <num>[,<num>...]`, e.g. `d 1,3`) to delete one or more saved
  conversations (and their `brain/` artifacts and child subagent entries) with
  confirmation. A single invalid token aborts the batch without deleting
  anything.
  If `conversation_summaries.db` is locked, the delete waits up to
  `AGY_DB_BUSY_TIMEOUT_MS` (default 1000 ms) and then fails without touching
  any artifacts.
- Press `c` to resume the most recent conversation via `--continue`, or `q` to
  cancel.

### s) Settings
Opens the toggle-and-edit sub-menu for the `AI_SANDBOX_*` sandbox flags and
the **Account profile** (`AGY_ACCOUNT`) under the "Account" header.
Choices persist per-workdir via the same auto-save/auto-load mechanism as
`c) Clear` below.

### c) Clear saved settings for this workdir
Removes the Antigravity wrapper's auto-saved settings preset for the current
directory (`<hash>-agy.env`; see the Claude wrapper help for the file
layout), resetting the menu to catalog defaults on the next open. Each
wrapper keeps its own per-workdir file, so the Claude and Codex wrappers'
settings for the same directory are not affected.

### h) Help
Shows this help document.

## Permissions inside the sandbox

Because the OS sandbox (bubblewrap on Linux, Seatbelt on macOS) already
confines filesystem writes to `WORKDIR`, `~/.gemini`, and `/tmp`, the wrapper
grants `agy` full autonomy inside the sandbox boundary:

- Passes `--dangerously-skip-permissions` on the command line.
- Ensures `<profile>/antigravity-cli/settings.json` has
  `toolPermission: "always-proceed"`, `artifactReviewPolicy: "always-proceed"`,
  `allowNonWorkspaceAccess: true`, `enableTerminalSandbox: false` (avoiding
  nested-sandbox conflicts inside the outer `ai-wrapper` sandbox), and adds
  the resolved working directory to `trustedWorkspaces`. Existing user
  preferences in `settings.json` (theme, vim mode, etc.) are preserved.

## Account switching

Multi-account credential profiles let you keep separate `~/.gemini-<name>/`
directories (each with its own OAuth token, conversation history, and
settings) and switch between them without logging in again.

- Press `s) Settings`, find **Account profile**, and type a profile name,
  or `private` to reset to the default (unsuffixed `~/.gemini`).
- A profile name may contain only letters, digits, `-` and `_`, and must
  match an existing `~/.gemini-<name>/` directory — the wrapper does not
  create named profiles. An unknown name fails with an error listing the
  profiles it found. Create one with e.g. `mkdir ~/.gemini-work`, then log
  in once from a wrapper session using that profile.
- For the default account the wrapper creates `~/.gemini` if missing, and
  refuses to launch if `~/.gemini` is a non-directory. Any profile dir that
  is a symlink must resolve inside `$HOME` and outside credential dirs
  (`~/.ssh`, `~/.gnupg`, `~/.aws`, ...), or the launch is refused.
- Non-interactive launches respect `AGY_ACCOUNT=<name>` from the
  environment, or fall back to the workdir's saved preset.

The wrapper makes `~/.gemini-<name>` appear as `~/.gemini` inside the sandbox
(bubblewrap `--bind SRC DST`), so Antigravity sees its usual config path.
<!-- os:darwin -->

**macOS limitation:** sandbox-exec has no bind-mount remapping, so a named
profile is granted at its real path (`~/.gemini-<name>`) while Antigravity
still reads `~/.gemini`, which is then not granted. Account switching is fully
functional on Linux only (same limitation as the Claude and Codex wrappers).
<!-- os:end -->

## Also shared with the Claude and Codex wrappers

- Git worktrees: when the working directory is a `git worktree`, the main
  repository's shared `.git` is bound read-write so git works — only if it
  passes validation (under `$HOME`, not in a dotfile dir except verified
  submodule gitdirs under `~/.local/share/<repo>/.git/modules/<name>`, a real
  git dir whose worktree entry links back to this checkout).
  Its `config`, `hooks/` and other worktrees' entries stay read-only, so
  `git config`, `git remote add`, `push -u`, `git worktree add` and
  submodule updates fail inside the sandbox. Otherwise a WARN is printed
  and git won't work in the worktree; bind the `.git` via
  `AI_SANDBOX_EXTRA_RW_DIRS` if you trust it.
- `AI_SANDBOX_PASS_GITLAB=1` also binds the glab config read-only.
- `AI_WRAPPER_EXTRA_PROFILE` plugins (see the Claude wrapper help,
  "Extensions via AI_WRAPPER_EXTRA_PROFILE") are loaded, including the
  `_extra_post_menu_setup` hook.
