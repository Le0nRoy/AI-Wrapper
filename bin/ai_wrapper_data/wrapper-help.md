# Claude Wrapper Help

This wrapper provides an interactive menu for starting Claude CLI sessions with
optional orchestration workflows. It sandboxes Claude to the working directory,
the agent config, and read-only system paths. Network is allowed (required for
the Anthropic API).

**Platform support:** Linux (bubblewrap) and macOS (sandbox-exec /
Seatbelt). `run_sandboxed_agent()` in `ai_agent_universal_wrapper.bash`
picks the backend automatically via `uname -s` — this wrapper is the
same entry point and the same script on both OSes. An unsupported OS
exits with code 78 (EX_CONFIG). Some `AI_SANDBOX_*` flags below and the
raw sandbox-profile mechanics (SBPL vs. bwrap args) are backend-specific;
where that matters it's called out inline.

## What the sandbox does NOT protect against

The sandbox bounds *writes* — it does not bound *reads* or *network*. Be aware:

- **Read + network = exfiltration.** The agent can read any user-readable file
  (`~/.ssh`, `~/.aws`, browser data, etc.) and POST it out. Use only with
  trusted agent versions.
- **Write + exec inside WORKDIR.** The agent can drop a binary anywhere under
  the working directory and execute it; the child inherits the sandbox, so this
  is not an escape, but "sandboxed" is not the same as "cannot run code".
- **WORKDIR is the write fence.** Launch from a project directory. The wrapper
  refuses `/`, `$HOME`, top-level system paths, dotfile dirs under HOME, and
  anything under `~/Library`. cd somewhere narrow before starting if you care
  about the blast radius.
- **`--dangerously-skip-permissions` is on by design** because the sandbox is
  the fence. If you loosen the sandbox profile, reconsider that flag.

## Environment variables

- `AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1` — override the refusal to launch from
  HOME dotfile dirs or `~/Library`. Use only when you're deliberately editing
  one of those locations and accept the wider write fence.
- `AI_SANDBOX_ALLOW_RO_HOMEDIR=1` — widen the read allowlist to `$HOME`
  except the credential exclusions in the SBPL profile (the 9 credential
  dotfiles, `~/Library/Keychains`, `~/Library/{Messages, Mail, Cookies}`,
  Chrome/Chromium/Brave/Arc/Edge/Firefox/Vivaldi profiles,
  `~/Library/Containers/com.apple.Safari`, Slack/Discord state,
  1Password/Bitwarden/KeePassXC sync caches). **The flag still exposes
  most of `$HOME`** — see the README's S10.2 entry for the complete
  exclusion list, and add any extra browser/chat vendor you care about
  to the `(require-not …)` chain in `ai_wrapper_data/claude_wrapper.sb`
  before relying on the flag.
- `AI_SANDBOX_ALLOW_RO_CREDENTIALS=1` — widen the read allowlist to the
  residual credential subdirs/files without a dedicated `PASS_*` flag
  (~/.config/gcloud, ~/.gnupg, ~/.netrc, ~/.npmrc, ~/.pypirc). The
  per-service cred dirs (~/.ssh, ~/.aws, ~/.kube, ~/.docker) are
  enabled by their matching `AI_SANDBOX_PASS_*` flag instead. Red banner.
- `AI_SANDBOX_PROFILE=<path>` — point at an alternative SBPL profile (absolute
  path, or relative to the universal wrapper's directory). Replaces the base
  profile entirely; per-call `--bind` rules are still appended. The wrapper
  refuses to load a profile that lacks `(version 1)` and `(deny default)` in
  its first 80 non-comment lines (post-WS3 sanity check; closes U-C). Set
  `AI_SANDBOX_PROFILE_TRUST_ME=1` to bypass the check — required only for
  legitimately permissive profiles, red banner.
- `AI_SANDBOX_DRYRUN=1` — print the resolved sandbox-exec argv, the post-scrub
  child environment, and the rendered SBPL profile, then exit. Nothing
  launches.
- `AI_SANDBOX_BLOCK_LOCALHOST=1` — emit SBPL `(deny network-outbound (remote
  ip "localhost:*"))` and the symmetric inbound rule. Blocks IPv4 + IPv6
  loopback (sandbox-exec resolves "localhost" to both). Off by default so
  dev workflows on `127.0.0.1` keep working; set this when you want the
  agent unable to reach dev DBs / kubectl proxy on loopback. **Scope
  caveat:** the flag is IP-only. Unix-domain sockets
  (`/var/run/docker.sock`, `~/.colima/*.sock`) and link-local addresses
  (AWS IMDS at `169.254.169.254`) are **not** covered — fence those at
  the network or firewall layer if they matter.
- `AI_SANDBOX_ALLOW_DOCKER=1` — emit RW rules for
  `/var/run/docker.sock`, `~/.colima`, `~/.docker`. **Off by default.**
  **WARNING:** when on and the Docker / Colima daemon is running, the
  agent can `docker run -v /:/host --privileged` to obtain root on the
  host filesystem — a full sandbox escape. Set to `1` only when the
  session legitimately needs `docker` from inside the sandbox.
- `--ro-bind SRC` adds a read-allowlist rule for SRC (single positional
  argument post-WS1; no DST — sandbox-exec cannot remap paths). The source
  path must exist at launch — a missing source is a hard error (exit 1),
  not a silent skip. This matches `--bind` strictness and prevents
  typo-induced silent failures.

### Env scrubbing (Phase 1, 2026-05-24)

The wrapper `env -i`'s the parent environment before exec. The child sees
only a curated allowlist (locale, terminal, PATH, language-toolchain
pointers, `GIT_*`, `npm_config_*`, `CLAUDE_*`). Everything else —
including `SSH_AUTH_SOCK`, `AWS_*`, `GITHUB_TOKEN`, `GITLAB_TOKEN`,
`ANTHROPIC_API_KEY`, `OPENAI_*` — is dropped unless the matching
`AI_SANDBOX_PASS_*` flag is set.

Yellow-banner opt-ins (scope widening; the agent still needs further auth
to weaponize — daemons gate on identity):

(none — see red list below; the SSH/Docker/Kube flags are red since
they now grant RO on the matching on-disk cred dir.)

Red-banner opt-ins (raw credential material):

- `AI_SANDBOX_PASS_SSH_AGENT=1` — pass `SSH_AUTH_SOCK` AND RO-grant
  `~/.ssh` so the agent reads private keys / `known_hosts` directly.
- `AI_SANDBOX_PASS_DOCKER=1` — pass `DOCKER_HOST`, `DOCKER_CONFIG`,
  `DOCKER_CERT_PATH`, `DOCKER_BUILDKIT` AND RO-grant `~/.docker`
  (registry auth tokens).
- `AI_SANDBOX_PASS_KUBE=1` — pass `KUBECONFIG`, `KUBE_EDITOR` AND
  RO-grant `~/.kube` (cluster certs / tokens).
- `AI_SANDBOX_PASS_AWS=1` — pass all `AWS_*` env vars AND RO-grant
  `~/.aws` (shared credentials file).
- `AI_SANDBOX_PASS_GH=1` — pass `GITHUB_TOKEN`, `GH_TOKEN`.
- `AI_SANDBOX_PASS_GITLAB=1` — pass `GITLAB_TOKEN`, `CI_JOB_TOKEN`, AND
  RO-bind glab's on-disk config dirs (`~/Library/Application Support/glab-cli`
  on macOS; XDG `~/.config/glab-cli` and `~/.local/share/glab-cli` as
  fallbacks) so `glab` works even when the env vars are unset.
- `AI_SANDBOX_PASS_OPENAI=1` — pass all `OPENAI_*` env vars.
- `AI_SANDBOX_PASS_ENV="VAR1,VAR2"` — generic escape hatch for any other
  vars (e.g. `PASS_ENV=ANTHROPIC_API_KEY` to forward an Anthropic key
  when Claude is not authenticated via `~/.claude.json`). Names must
  match `[A-Za-z_][A-Za-z0-9_]*`; whitespace ignored.

Use `AI_SANDBOX_DRYRUN=1` to inspect the exact child env without launching.

  **Behavior change (since v0):** pre-T11, `--ro-bind` was a no-op on macOS
  because the base profile granted `file-read*` everywhere. Post-T11, reads
  are default-deny + allowlist, and `--ro-bind` emits a real
  `(allow file-read* ...)` rule per path. The old silent-no-op semantics are
  gone — we chose hard-fail symmetric with `--bind` to catch typos. Callers
  that want best-effort optional reads must gate the flag at the call site
  (e.g. `[[ -e X ]] && WRAPPER_FLAGS+=(--ro-bind X X)`).

## Menu Options

### 1) Start orchestration
Launches Claude with the `orchestrator-mode` skill pre-loaded as a system prompt.
Use for multi-phase development workflows: plan → implement → test → review → merge.

**Phases:**
- Phase 0: Project verification
- Phase 1: Planning (produces `docs/plans/YYYY-MM-DD-<feature>.md`)
- Phase 2: Implementation (TDD, per-task subagents)
- Phase 3: Testing (test plan + automated tests)
- Phase 4: Code review
- Phase 5: Documentation
- Phase 6: Finalization (merge options)

### 2) Start new conversation
Launches a plain Claude session with no additional system prompt.

### 3) Resume from list
Resumes a previous Claude session (Claude will show a session picker).

### s) Settings
Opens the toggle-and-edit sub-menu. Lists every `AI_SANDBOX_*` knob the
wrapper honours, grouped into categories (Debug, Additional settings,
Sensitive directories, Credentials, Networking) in that order from top
to bottom — the most frequently used groups sit closest to the input
prompt so they don't require scrolling.

Pick a number to flip a bool or edit a string/path value. Multiple
numbers can be supplied at once as a comma-separated list (e.g.
`1,4,7` — whitespace is ignored) to toggle several bools in one pass;
any string/path entries in the batch prompt for a new value in turn.
A single invalid or out-of-range token aborts the whole batch without
toggling anything.

Mutations are `export`ed into the wrapper's current shell, so they
apply to subsequent launches from the same menu session. To persist
across menu invocations, set the variable in `~/.zshrc` (or wherever
you invoke `claude_wrapper` from) instead. `b` / Enter returns to the
main menu.

### Account switching

Claude wrapper only. Multi-account credential profiles let you keep
separate `~/.claude-<name>/` directories (e.g. work vs. personal) and
switch between them without re-authenticating each time.

- Press `s) Settings`, find **Account profile** under the "Account"
  header, and type a profile name, or `private` to reset to the
  default (unsuffixed `~/.claude`).
- A profile name must match an existing `~/.claude-<name>/` directory —
  the wrapper does **not** create new named profiles for you. Launching
  with an unknown name fails with a clear error listing the profiles it
  found.
- If `~/.claude-<name>.json` also exists it's used for that profile's
  session/account metadata; otherwise the shared `~/.claude.json` is
  used.
- The choice persists per-workdir via the same auto-save/auto-load
  mechanism as every other setting (see `c) Clear` below) — pick an
  account once per project and it's remembered on the next launch from
  that directory.
- Non-interactive launches respect `CLAUDE_ACCOUNT=<name>` set in the
  environment, or fall back to the workdir's saved preset.

**macOS limitation:** Account switching relies on bind-mount remapping —
the wrapper makes `~/.claude-<name>` appear as `~/.claude` inside the
sandbox so the Claude CLI sees its expected config path. On Linux
(bubblewrap) this works via `--bind SRC DST`. On macOS (sandbox-exec /
Seatbelt) there is no bind-mount remapping; the path grant is a
single-argument ACL, so a named account directory is accessible at its
real path (`~/.claude-<name>`) but cannot be remapped to appear as
`~/.claude`. As a result, setting `CLAUDE_ACCOUNT=work` on macOS will
grant read/write access to `~/.claude-work` in the sandbox but Claude
reads `~/.claude` — the session will silently use the default account
directory instead of the named one. Account switching is fully
functional on Linux only.

### c) Clear saved settings for this workdir

The wrapper automatically saves your current settings when you pick a
launch option (1/2/3) and restores them the next time you open the
menu from the same directory. This is a silent, per-workdir operation
— no naming, no confirmation, no sub-menu required.

**How it works:**

- **Auto-save** — fires after you choose a launch mode, before the
  session starts. Writes every catalog setting (including explicit
  `bool=0` values) to
  `${XDG_CONFIG_HOME:-$HOME/.config}/ai-wrapper/last-preset/<hash>.env`
  where `<hash>` is the first 12 hex chars of the SHA-256 of the
  resolved working directory path. One file per workdir, no clobber
  across directories.
- **Auto-load** — fires when the menu opens. Restores all settings
  silently on a match; if the file does not exist (first run or after
  a clear) the menu starts with catalog defaults. A dim
  `(restored from <path>)` line appears in the header when settings
  are in effect.
- **`c) Clear`** — removes the preset file for the current workdir and
  unsets the restored-from marker so the header line disappears on the
  next render. No confirmation. Use this as the escape hatch to start
  fresh from catalog defaults.

The preset file is plain `KEY=VALUE` per line with a comment header;
you can `grep -r workdir: ~/.config/ai-wrapper/last-preset/` to
find a file by its workdir path.

**Known limitation — cross-OS preset portability:** The preset file
stores every catalog key, including OS-specific ones (e.g.
`AI_SANDBOX_ALLOW_RO_HOMEDIR`, which is macOS-only, and
`AI_SANDBOX_BLOCK_LOCALHOST`, also macOS-only). If you save a preset on
macOS with `ALLOW_RO_HOMEDIR=1` and then load it on Linux, the key is
restored into the environment but silently has no effect — Linux has no
backend for it. The setting will still appear as `1` in the preset file
and in the env, which can be misleading. Clear the preset (`c)`) after
switching OS if you rely on macOS-only settings.

### h) Help
Shows this help document.

## Skills

Skills live in `~/.agents/skills/`. The setup script `setup_skills.bash`
copies each one into `~/.claude/skills/<name>` so Claude Code discovers
them (copies, not symlinks — sandbox-exec on macOS resolves file rules
against the canonical real path, and the sandbox binds `~/.claude` RW but
not `~/.agents`, so a symlink there would be read-denied). Each managed
copy carries a `.setup_skills_managed` marker file recording its source
path, so reruns refresh the copy in place; non-managed entries already in
`~/.claude/skills/` are left untouched.

Run setup with:
```sh
~/bin/setup_skills.bash
```

Key skills:
- `orchestrator-mode` — Full feature delivery orchestration
- `writing-plans` — Implementation plan creation
- `implementing-tasks` — TDD task execution with file ownership and self-review
- `planning-tests` — Test strategy design (produces test plan for automation-tester)
- `writing-automated-tests` — AAA-structured test writing with isolation and control cases
- `updating-documentation` — Post-review doc updates (README, env vars, changelog)
- `subagent-driven-development` — Same-session plan execution with reviews
- `executing-plans` — Parallel session plan execution
- `requesting-code-review` — Code review dispatch
- `using-git-worktrees` — Isolated workspace creation
- `finishing-a-development-branch` — Branch completion and merge options
- `find-skills` — Discover installable skills

## Keyboard Shortcuts

In Claude CLI:
- `Ctrl+C`: Cancel current operation
- `Ctrl+D`: Exit session
- `/help`: Show Claude CLI help
