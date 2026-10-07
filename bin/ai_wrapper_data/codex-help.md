Codex Wrapper Help

This wrapper provides an interactive menu for starting Codex CLI sessions with
optional orchestration workflows, inside the same sandbox as the Claude
wrapper (bubblewrap on Linux, sandbox-exec on macOS).

## Menu Options

### 1) Start orchestration
Launches Codex with the orchestrator prompt (`orchestrator-prompt.md`)
injected as developer instructions, i.e.
`codex --dangerously-bypass-approvals-and-sandbox -c developer_instructions="<prompt>"`.
The prompt is encoded as a TOML basic string (quotes, backslashes and
control characters escaped) because Codex parses `-c` values as TOML.
Use for multi-phase development workflows: plan → implement → test → review → merge.

Note: this overrides any `developer_instructions` set in the profile's
`config.toml` for this session.

### 2) Start new conversation
Launches a plain Codex session with no additional system prompt.

### 3) Resume from list
Runs `codex resume --dangerously-bypass-approvals-and-sandbox`, which shows
Codex's session picker. `resume` is a Codex subcommand, so the wrapper puts
it before the autonomy flag.

### s) Settings
Opens the toggle-and-edit sub-menu for the `AI_SANDBOX_*` sandbox flags and
the **Account profile** (`CODEX_ACCOUNT`) under the "Account" header.
Choices persist per-workdir via the same auto-save/auto-load mechanism as
`c) Clear` below.

### c) Clear saved settings for this workdir
Removes the auto-saved settings preset for the current directory, resetting
the menu to catalog defaults on the next open. The preset file is shared
with the Claude wrapper for the same directory; each wrapper keeps the
other's account choice when it saves.

### h) Help
Shows this help document.

## Account switching

Multi-account credential profiles let you keep separate `~/.codex-<name>/`
directories (each with its own `auth.json` / `config.toml`) and switch
between them without logging in again.

- Press `s) Settings`, find **Account profile**, and type a profile name,
  or `private` to reset to the default (unsuffixed `~/.codex`).
- A profile name may contain only letters, digits, `-` and `_`, and must
  match an existing `~/.codex-<name>/` directory — the wrapper does not
  create named profiles. An unknown name fails with an error listing the
  profiles it found. Create one with e.g. `mkdir ~/.codex-work`, then log
  in once from a wrapper session using that profile.
- For the default account the wrapper creates `~/.codex` if missing, and
  refuses to launch if `~/.codex` is a non-directory. Any profile dir that
  is a symlink must resolve inside `$HOME` and outside credential dirs
  (`~/.ssh`, `~/.gnupg`, `~/.aws`, ...), or the launch is refused.
- Non-interactive launches respect `CODEX_ACCOUNT=<name>` from the
  environment, or fall back to the workdir's saved preset.

The wrapper makes `~/.codex-<name>` appear as `~/.codex` inside the sandbox
(bubblewrap `--bind SRC DST`), so Codex sees its usual config path.
<!-- os:darwin -->

**macOS limitation:** sandbox-exec has no bind-mount remapping, so a named
profile is granted at its real path (`~/.codex-<name>`) while Codex still
reads `~/.codex`, which is then not granted. Account switching is fully
functional on Linux only (same limitation as the Claude wrapper).
<!-- os:end -->

## Also shared with the Claude wrapper

- Git worktrees: when the working directory is a `git worktree`, the main
  repository's shared `.git` is bound read-write so git works — only if it
  passes validation (under `$HOME`, not in a dotfile dir, a real `.git` /
  `<name>.git` dir that lists this worktree). Otherwise a WARN is printed
  and git won't work in the worktree; bind the `.git` via
  `AI_SANDBOX_EXTRA_RW_DIRS` if you trust it.
- `AI_SANDBOX_PASS_GITLAB=1` also binds the glab config read-only.
- `AI_WRAPPER_EXTRA_PROFILE` plugins (see the Claude wrapper help,
  "Extensions via AI_WRAPPER_EXTRA_PROFILE") are loaded, including the
  `_extra_post_menu_setup` hook.
