# Security concerns & known followups

Captured 2026-05-23 from the post-T11 review against the
`Le0nRoy/my_linux_configs` upstream contract. Items here are either gaps
between the README threat model and observed runtime behavior, or
softenings that the current hardening pass deliberately left open. See
`docs/plans/2026-05-23-sandbox-migration.md` for the proposed disposition.

The U-* and S-* IDs continue the numbering from `reports/review-001.md`
through `reports/review-004.md`. Items already tracked there are not
restated here; this file collects only what survived those reviews or
came out of the upstream comparison pass.

## Resolved 2026-05-25 (WS7)

A follow-up review (audit pass against the Le0nRoy upstream and a second
read of the SBPL profile + wrapper) surfaced eight items that survived
WS1–WS6. WS7 lands all eight in one pass. See README §"Other grants
worth knowing about" and the env-vars table for the runtime surface;
this section records the disposition.

- **3.A → SBPL native `~/AGENTS.md` / `~/CLAUDE.md` reads.** Linux
  upstream auto-binds both RO; this repo had no equivalent path, so the
  default-deny read fence (post-T11) silently hid them. Resolved by
  appending two `(literal …)` reads to the base profile's HOME-anchored
  block (no `--ro-bind` from the caller required, no hard-fail on a
  missing file).
- **3.C → `WORKDIR=~/bin` policy.** Now documented as **S-ι**: running
  the wrapper from inside the wrapper repo intentionally grants RW on
  its own scripts. The user is presumed to know the consequence; cd one
  level deeper if you want wrapper-self-modification fenced.
- **3.E / 3.F → tightened `GIT_*` and `npm_config_*` deny-lists.**
  The prefix passthroughs still match those namespaces, but the
  wrapper now `continue`s past names that are code-exec vectors
  (`GIT_ASKPASS`, `GIT_SSH`, `GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`,
  `GIT_EDITOR`, `GIT_PAGER`, `GIT_SEQUENCE_EDITOR`,
  `GIT_EXTERNAL_DIFF`) or credential vehicles (`npm_config_email`,
  `npm_config_username`, `npm_config_password`, `npm_config_otp`,
  `npm_config__auth`, the `npm_config_//*` URL-prefixed namespace,
  and any `npm_config_*authToken*` / `*authtoken*` / `*_auth` name).
- **3.I → `AI_SANDBOX_ALLOW_DOCKER` env knob.** New **S-η** entry in
  the threat model. SBPL Docker / Colima / `~/.docker` rules are now
  wrapped in `(when (equal? (param "ALLOW_DOCKER") "1") …)`. Default
  remains `1` (preserves the working-out-of-the-box `docker` CLI);
  set `0` to omit the rules and close the host-root escape path when
  the daemon is up.
- **3.J → BLOCK_LOCALHOST scope clarified.** README now states
  explicitly that the flag is IP-only — it does not cover Unix-domain
  sockets or link-local addresses (AWS IMDS at `169.254.169.254`).
  No code change; documentation only.
- **3.K → strict profile sanity check.** The `(version 1)` /
  `(deny default)` check now also refuses a profile whose first 80
  non-comment lines contain `(allow default)`, which would otherwise
  silently neutralise the `(deny default)` baseline.
  `AI_SANDBOX_PROFILE_TRUST_ME=1` bypasses this check too — single
  bypass for the whole sanity-check block.
- **4.A → `_realpath` symlink cycle detection.** The file-branch walk
  now tracks visited `cur` paths in a `seen` array; revisiting a path
  fails the walk silently (matching the existing failure contract).
  `AI_SANDBOX_DEBUG=1` adds a DEBUG line naming the cycle.
- **4.D → defensive `AI_RESUME_ARGS=()` declare.** `claude_wrapper_lib`
  now declares the array empty so the shared lib's
  `${AI_RESUME_ARGS[@]:---resume}` fallback is bash-3.2 + set-u safe by
  contract rather than by empirical testing.
- **Settings menu (new).** `ai_wrapper_lib.bash` ships a unified
  catalog driving (a) a "Current settings:" table at the top of the
  menu, (b) a new `s) Settings` sub-menu that lets the user toggle
  bools or edit string/path values for the current shell session.
  Replaces the per-flag yellow/red banner stanzas with a single
  rendering.

End-to-end testing of the settings menu surfaced **B-η** and **B-θ**
(both fixed in `5fe7417`; details in "Local bugs / brittleness" below).
The initial WS7 commit (`b1bd9b0`) shipped the menu UI but the toggles
were a no-op end-to-end; the follow-up commit fixed that. Anyone reading
this should treat WS7 as the pair `b1bd9b0` + `5fe7417` rather than
either commit alone.

## Notes on the `--ro-bind` contract (clarification, not a change)

Three pieces sometimes blur together. Stating them explicitly:

1. **The two-arg `--ro-bind SRC DST` form was intentionally removed**
   (WS1 / U-F). macOS `sandbox-exec` cannot remap paths, so the second
   positional argument would have been misleading. The flag now takes a
   single `SRC` and emits `(allow file-read* (subpath|literal SRC))`.
2. **The `--ro-bind`-as-no-op semantics were intentionally removed**
   (T11 / S1 / U2). When reads were default-allow, `--ro-bind` was a
   no-op. Post-T11 reads are default-deny, so `--ro-bind` now emits a
   real rule. Missing sources are a hard failure (exit 1), symmetric
   with `--bind`.
3. **The `--ro-bind` flag itself was preserved** as the call-site
   vocabulary for "grant the agent read access to this path." It is
   the only way (other than `AI_SANDBOX_ALLOW_RO_HOMEDIR` /
   `AI_SANDBOX_ALLOW_RO_CREDENTIALS`) for a caller to widen the read
   allowlist on the fly.

Items 1 and 2 are the "drops" in the recent history; item 3 is the
preservation. README §"Linux merge" (R9) and §"Quirks" (U2) cover the
calling-convention side; this note exists so the *intent* of each
piece is not implied — it's stated.

## Undocumented behavior

### U-A — Environment passes through unfiltered (RESOLVED, 2026-05-24, Phase 1)

`ai_agent_universal_wrapper.bash:412` used to invoke `exec sandbox-exec
…` with the parent's full environment intact. Closed by env scrub:
`exec env -i KEY=VAL… sandbox-exec …` with a baseline allowlist +
opt-in `AI_SANDBOX_PASS_*` flags. The Linux upstream's
`--clearenv` + `--setenv` posture is now mirrored on macOS.

The original concern: the agent inherited every variable the parent
shell exported — `AWS_*`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
`GITHUB_TOKEN`, `GITLAB_TOKEN`, `SSH_AUTH_SOCK`, `DOCKER_*`,
`KUBECONFIG`, plus anything custom in the user's `~/.zshrc` —
making the documented "reads + network = exfiltration risk" framing
load-bearing for env vars too, without saying so.

**Resolution.** `_run_sandboxed_agent_macos` now builds `env_allowlist`
before the exec subshell and exec's with `env -i`. Confirmed via
`AI_SANDBOX_DRYRUN=1` that the child env contains only the baseline
allowlist by default; opt-in flags surface their additions verbatim.

### U-B — `SSH_AUTH_SOCK` reachable with default flags (RESOLVED, 2026-05-24, Phase 1)

The ssh-agent socket lives under `${TMPDIR}/com.apple.launchd.*/Listeners/`
which is inside `DARWIN_USER_TEMP_DIR` — and that whole subpath is
granted `file*` by the profile (T07/S8). Pre-Phase-1, the inherited
`SSH_AUTH_SOCK` env var (U-A) let the agent invoke any ssh-agent-loaded
identity without ever needing to read `~/.ssh/id_*`, bypassing
`AI_SANDBOX_ALLOW_RO_CREDENTIALS` for the practical GitLab/GitHub
push-as-user case.

**Resolution.** Closed by U-A: env scrub drops `SSH_AUTH_SOCK` by
default. The socket file still exists in the granted subpath, but the
agent has no way to discover its path. For users who genuinely need
ssh-agent forwarding (e.g. authenticated GitLab push from inside the
sandbox), opt in via `AI_SANDBOX_PASS_SSH_AGENT=1` — yellow banner at
menu launch.

### U-C — `AI_SANDBOX_PROFILE` is an unchecked profile override (RESOLVED, 2026-05-24, WS3)

`ai_agent_universal_wrapper.bash:171` used to accept any readable
regular file as a sandbox profile replacement. A trivially permissive
substitute (`(version 1)(allow default)`) silently nullified the
fence.

**Resolution.** WS3 sanity-checks the loaded profile body: scans the
first 80 non-comment lines for `(version 1)` and `(deny default)`. If
either is missing, refuses to launch unless
`AI_SANDBOX_PROFILE_TRUST_ME=1` is set (red banner). The check is
intentionally cheap string-grep — false positives can be overridden;
false negatives are caught by the kernel parser downstream.

### U-D — `ALLOW_RO_HOMEDIR=1` exposes more than "non-credential files" (RESOLVED, 2026-05-24, WS2)

The README and red banner used to describe the flag as widening reads
to "all of `$HOME` except known credential dirs" while in practice
allowing `~/Library/Messages/chat.db`, Mail bodies, browser cookie
DBs, Slack/Discord auth tokens, and 1Password sync cache.

**Resolution.** WS2 extends the SBPL `(require-not …)` chain with the
high-value attractant paths: `~/Library/{Messages, Mail, Cookies}`,
`~/Library/Application Support/{Google/Chrome, Chromium, BraveSoftware,
Arc, Microsoft Edge, Firefox, Vivaldi, Slack, discord, Discord,
Bitwarden, KeePassXC}`, the regex-matched `com.1password.*` and
`com.agilebits.*` families, and `~/Library/Containers/com.apple.Safari`.
Also rewrites the README S10.2 entry and `wrapper-help.md` flag
description to enumerate the exclusions explicitly, with a note that
novel browser/chat vendors not on the list will still be exposed.

### U-E — WORKDIR under `~/Documents`, `~/Downloads`, etc. is accepted (RESOLVED, 2026-05-24, WS3)

The wrapper refused `${HOME}/.*` and `${HOME}/Library*` but accepted
any other HOME subtree. Launching from `~/Documents` grants RW on
every file under it.

**Resolution.** WS3 adds `_check_workdir_breadth` to the universal
wrapper. When WORKDIR is a direct `$HOME` child outside the
project-dir allowlist (`Workspace`/`Projects`/`src`/`code`/`bin`/
`work`/`dev`/`repos` + lowercase variants), the wrapper logs a WARN
line and exports `AI_SANDBOX_WORKDIR_WARNING=<resolved-workdir>`.
`ai_wrapper_lib.bash` reads that env var and prints a yellow banner
at menu launch. Launch is not refused — the heuristic is
informational. Called pre-menu from `claude_wrapper.bash` so the
banner fires on first render.

### U-F — `--bind` / `--ro-bind` DST silently ignored on macOS (RESOLVED, 2026-05-24, WS1)

`ai_agent_universal_wrapper.bash:119-145` used to consume both SRC and
DST but honor only SRC. Closed by dropping bubblewrap compatibility
entirely (WS1): the flags now take a single positional SRC and the
two-arg form errors out with a migration hint. A future merge with
`Le0nRoy/my_linux_configs` will need to reconcile the calling-
convention divergence; tracked as R9 in the README "Linux merge"
section.

### U-G — `setup_skills.bash` exit status never reflects SKIPs

Documented as U7; the script always returns 0 even when it skipped
links. CI consumers can't fail on partial-failure.

**Disposition (2026-05-27).** ACCEPTED. Will be migrated to chezmoi
later with additional error handling. The previously-noted `--strict`
mode is not being built in this repo; the chezmoi migration is expected
to replace `setup_skills.bash` entirely with the upstream lifecycle
hooks (`run_always_register-agent-skills.bash` and friends), at which
point the exit-status contract is owned by chezmoi conventions rather
than this script. Entry kept for history.

### U-H — `mach-register (local-name-prefix "")` is everything-local (RESOLVED, 2026-05-24, WS2)

The SBPL comment used to claim this is "limited to local-name
(per-process names)" and the README S5 entry implied a narrowing.
Both technically correct (local names are per-process) but the empty
prefix matches *any* local name; the wording over-promised.

**Resolution.** WS2 rewrites both the SBPL comment and the README S5
entry to clarify: the narrowing is scope-only (local namespace vs.
user bootstrap namespace), not name-pattern. The agent can
bootstrap_register any per-process name; what it cannot do is publish
into the user bootstrap namespace where other processes could look
up its service.

## Undocumented behaviour (now documented)

Findings from the 2026-05-26 internal audit
(`reports/audit-internal-2026-05-26.md` §"Undocumented Behavior Found").
Each is intentional; the entries below exist so the next reader does
not re-derive them from the code.

### UD-1 — `~/.claude` and `~/.claude.json` writes happen on every launch

**What the wrapper actually does.** `mkdir -p "${HOME}/.claude"` and
`touch "${HOME}/.claude.json"` run on every invocation, before the
interactive-vs-non-interactive branch. They run even when the wrapper
is launched non-interactively, when `AI_SANDBOX_DRYRUN=1` is set, and
in script-style harnesses with no controlling tty.

**Where.** `claude_wrapper.bash` lines ~62 (`mkdir -p`) and ~82
(`touch`), inside the same prelude that builds `WRAPPER_FLAGS`. The
interactive guard at the bottom of the file
(`if [[ $# -eq 0 && -t 0 && -t 1 ]]`) gates only the menu render, not
these filesystem touches.

**Why it surprised the audit.** The README's quirks section (U4 / U5)
acknowledges the touches but does not call out that they happen on
DRYRUN and non-interactive paths too. A reviewer might assume DRYRUN
is side-effect-free; it is not on the host filesystem, only on the
sandbox-exec invocation.

**Disposition.** Intentional. The writes are idempotent and required
for the bind targets to exist (Claude's atomic-write pattern needs
`~/.claude.json` present to rename into; the universal wrapper hard-
fails on missing `--bind` sources). The host-mtime bump on
`~/.claude.json` is harmless. README wording clarified to make the
unconditional path explicit.

### UD-2 — downstream-plugin binds are silently WARN-and-continue when the source is missing

**What the wrapper actually does.** Downstream plugins loaded via
`AI_WRAPPER_EXTRA_PROFILE` add their binds through the plugin hook
contract, which checks for the source's presence and — when it is
missing — logs a WARN line to stderr and continues rather than
hard-failing. The universal wrapper's general policy is that missing
`--bind` sources are a hard error (exit 1); the plugin hook path is
an exception so plugins can degrade gracefully on first-run / not-
yet-installed state.

**Why it surprised the audit.** The generic write-fence description
does not enumerate plugin binds, so a reader might expect the
fail-loud contract to apply everywhere. The silent-WARN-and-continue
path means a user can launch the wrapper without a plugin's grant in
place; the next plugin call then fails opaquely. The reviewer
expected a hard fail consistent with the universal wrapper's
missing-source policy.

**Disposition.** Accept. Hard-failing here would break first launch
on a fresh machine before a plugin is installed. The WARN line is
the documented "you forgot to install / initialise the plugin"
signal; the plugin's own docs enumerate what to `mkdir -p` to
silence it. README quirks U1 already names this pattern.

### UD-3 — `GIT_*` and `npm_config_*` deny-lists are vector-specific, not prefix-blanket

**What the wrapper actually does.** The env-scrub loop's
prefix-matched pass-through (`GIT_*`, `npm_config_*`, `CLAUDE_*`, plus
any prefixes a loaded plugin registers) lets a var through unless its
name matches one of a small set of *specific* code-exec or
credential-vehicle names. The
deny-list is the set the README lists explicitly: `GIT_ASKPASS`,
`GIT_SSH`, `GIT_SSH_COMMAND`, `GIT_PROXY_COMMAND`, `GIT_EDITOR`,
`GIT_PAGER`, `GIT_SEQUENCE_EDITOR`, `GIT_EXTERNAL_DIFF` on the GIT
side; `npm_config_email`, `npm_config_username`, `npm_config_password`,
`npm_config_otp`, `npm_config__auth`, the `npm_config_//*` URL-prefix
namespace, and any `npm_config_*authToken*` / `*authtoken*` / `*_auth`
on the npm side. Anything else under those prefixes — including future
git env-vars that grow new code-exec surface — passes through.

**Where.** `ai_agent_universal_wrapper.bash` lines ~405–438, inside
the `while IFS= read -r _e_var; do … done < <(compgen -e …)` loop.

**Why it surprised the audit.** The phrase "deny-list" can read as
"block everything matching this pattern". The deny is in fact only
on the *enumerated* names; the rest of the prefix is allow-listed.
The audit's recommendation 5 calls out this wording risk.

**Disposition.** Intentional. Most `GIT_*` and `npm_config_*` vars are
passive config and the agent legitimately needs them. README
clarified to state explicitly that the deny-list is pattern-specific,
not a blanket block on the prefix. If a future git/npm release adds
a new code-exec env var, the deny-list must be widened by hand — that
is the maintenance cost of the allow-prefix model.

## Security gaps (defaults too wide)

### S-α — Localhost and link-local fully reachable (RESOLVED, 2026-05-24, WS4)

`(allow network*)` covered all outbound, including localhost-bound
services: local Postgres/Redis, `kubectl proxy`, Spotlight IPC, dev
servers on `localhost:*`, AWS instance metadata via VPN, etc.

**Resolution.** WS4 adds opt-in `AI_SANDBOX_BLOCK_LOCALHOST=1`. The
wrapper passes `-D BLOCK_LOCALHOST=…` and the SBPL profile gates a
`(deny network-outbound (remote ip "localhost:*"))` / symmetric
inbound rule on the param. Off by default — dev DBs and other
localhost workflows keep working without the flag.

The "localhost" string is the only host form sandbox-exec accepts
besides "*" in `(remote ip "...")` — literal IPs are rejected at
parse time. SBPL resolves "localhost" to both IPv4 (`127.0.0.1`) and
IPv6 (`::1`), so a single rule covers both loopback families.

### S-β — downstream plugins may extend authority beyond the sandbox

Downstream plugins loaded via `AI_WRAPPER_EXTRA_PROFILE` can register
MCP servers, extra binds, and extra env-scrub passthrough that widen
the agent's reach beyond what the base sandbox fences. MCP tool
traffic in particular leaves over the network and uses the user's
credentials, which the sandbox cannot inspect. See the plugin repo's
own security notes for the concrete authority any given plugin adds
and its per-tool allow/deny options.

### S-γ — `/private/tmp` shared with the host (RESOLVED, 2026-05-24, WS5)

`(allow file* (subpath "/private/tmp"))` is unconditional RW.
World-writable tmp; other processes write there too. The write fence
list in the README mentioned `/private/tmp` but didn't call out the
cross-process leakage.

**Resolution.** WS5 extends the write-fence threat-model bullet with
an explicit sentence: "`/private/tmp` is shared with every other
macOS process — the agent can read and write other processes'
world-writable tmp files (cross-process visibility on that path
specifically)."

### S-δ — `process-info*` and `signal` are unrestricted (RESOLVED, 2026-05-24, WS5)

Agent can `ps -ef`, `ps aux`, see every process's command line
(routinely contains `mysql -p<pwd>`, `kubectl --token=…`, transient
`curl -u user:pass …`), and can `kill(2)` any process the user's uid
can signal. Parity with the Linux upstream (bwrap shares the host
PID namespace by default).

**Resolution.** WS5 adds a §"Other grants worth knowing about" block
in the README with explicit notes on `process-info*` and `signal`.
A future tightening via `(deny process-info* (target others))` on
macOS and `--unshare-pid` on Linux is plausible but out of scope
for this pass — neither side has demand for it today.

### S-ε — `iokit-open` and `sysctl-read` are wide (RESOLVED, 2026-05-24, WS5)

Both grants are unfiltered. Low blast radius (no credentials surface
through these on macOS), but the README threat model didn't list them
anywhere.

**Resolution.** WS5 adds them to the §"Other grants worth knowing
about" block alongside `process-info*` / `signal`. Documented as
low-blast-radius but reachable.

### S-ζ — Resource limits (rlimits) not enforced (RESOLVED-BY-DROP, 2026-05-27)

The wrapper used to apply `RLIMIT_CPU`, `RLIMIT_NOFILE`, `RLIMIT_NPROC`,
and `RLIMIT_AS` to the sandboxed child via a `ulimit` subshell. As of
2026-05-27 it applies none of them.

**Resolution (2026-05-27).** RESOLVED-BY-DROP. `RLIMIT_NPROC` (`ulimit
-u`) and `RLIMIT_AS` (`ulimit -v`) were dropped earlier in the day for
being documented no-ops on Darwin (`-u` is per-user, not per-process;
`-v` is unenforced). `RLIMIT_CPU` and `RLIMIT_NOFILE` were then dropped
together with the `_apply_ulimit` helper, the `AI_SANDBOX_STRICT_RLIMIT`
knob, and the 137-exit interpretation in favour of wrapper
simplification. The user explicitly accepts the risk of unbounded CPU /
memory / file-descriptor / process consumption by the sandboxed agent
in exchange for the simpler code path. Re-evaluate if a runaway agent
causes operational pain; a real per-process fork limit on macOS would
need launchd integration, which remains out of scope. OS-level OOM
kills can still happen but the wrapper no longer claims to interpret
them as rlimit-induced.

## Local bugs / brittleness

### B-α — `mkdir -p ~/.claude` follows symlinks (RESOLVED, 2026-05-24, WS3)

`claude_wrapper.bash:39` used to do an unconditional `mkdir -p
~/.claude`. If `~/.claude` was a symlink to an unexpected target, the
bind happened on the *target*.

**Resolution.** WS3 adds the symmetric guard: refuses if `~/.claude`
exists as a non-directory, or as a symlink whose target resolves
outside `$HOME`. `~/.claude.json` has had this check since T11; WS3
closes the asymmetry.

**Codex wrapper (2026-10, codex parity).** `codex_wrapper.bash` had the
same unguarded `mkdir -p ~/.codex` + RW bind. `_bind_codex_account`
(`codex_wrapper_lib.bash`) now applies the identical guard to the default
`~/.codex`. The same change gives the Codex wrapper the Claude wrapper's
other binds — so its sandbox surface now matches Claude's rather than
widening past it: a named `~/.codex-<name>/` profile (RW, bound at
`~/.codex`, replacing — not added to — the default dir), a `git worktree`'s
shared `.git` (RW, only when it lies outside WORKDIR), and glab config
(RO, only with `AI_SANDBOX_PASS_GITLAB=1`). The worktree/glab logic now
lives once in `ai_wrapper_lib.bash` and is shared by both wrappers.

### B-ι — git worktree common dir is attacker-controlled (RESOLVED, 2026-10)

The worktree bind (`_wrapper_bind_git_common_dir`, originally inline in
`claude_wrapper.bash`) RW-bound whatever `git rev-parse --git-common-dir`
returned. That value comes from WORKDIR's `.git` file and the `commondir`
file it points to — both controlled by an untrusted checkout. A crafted
repo could name any git-shaped directory (another private repo's `.git`,
whose `hooks/` then run on the host; `$HOME` or a dotfile dir that
happens to contain `HEAD`/`objects`/`refs`) and get it bound RW.
Pre-existing in the Claude wrapper; inherited by Codex when the logic
moved to `ai_wrapper_lib.bash`.

**Resolution.** `_wrapper_git_common_dir_ok` validates the resolved
path first: a real directory strictly under `$HOME`; not sensitive per
`_sandbox_sensitive_dir_kind` (the classifier the Linux backend now uses
for WORKDIR / `AI_SANDBOX_EXTRA_*_DIRS`); basename `.git` or
`<name>.git` with `HEAD`, `objects/`, `refs/`; and WORKDIR's own gitdir
must resolve to `<common>/worktrees/<name>` (an attacker who can only
write inside WORKDIR cannot create that back-link). Failure WARNs and
skips the bind; the launch continues. `AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR`
does not relax it. **Behaviour change:** worktrees of repos outside
`$HOME` (or under a `$HOME` dotfile dir) no longer get the shared `.git`
bound automatically — grant it explicitly with `AI_SANDBOX_EXTRA_RW_DIRS`.

### B-λ — worktree common dir: borrowed entries and host code execution (RESOLVED, 2026-10)

Two gaps left by B-ι's first fix:

1. **Borrowed worktree entry.** A checkout's `.git` file could point at
   an *existing* `<victim>/.git/worktrees/<name>` of any repo; the
   forward-link check passed. Now `<common>/worktrees/<name>/gitdir`
   (written by git, not writable from the checkout) must resolve to
   exactly `<worktree toplevel>/.git` (both sides realpath'd; relative
   `gitdir` entries are resolved against the entry dir).
2. **RW on a genuine common dir = host code execution.** The agent could
   write `hooks/`, `config` (`core.hooksPath`, `core.fsmonitor`, aliases,
   filter drivers), other worktrees' entries (`commondir`,
   `config.worktree`) or submodule git dirs, all of which run on the
   user's next git command outside the sandbox. After the RW bind the
   wrapper now over-mounts read-only: `config`, `hooks/` (created if
   missing), all of `worktrees/` except this worktree's own entry, that
   entry's `commondir` / `gitdir` / `config.worktree` (pre-created when
   `extensions.worktreeConfig` is on), and the submodule git dirs below
   `modules/` at any depth (see "Submodule git dirs" under B-ν): their
   `config`, `hooks/`, `config.worktree`, `commondir` and `worktrees/`
   are RO in both modes and every directory on the chain to them is
   pinned. A symlink among the root-level targets aborts the bind
   (WARN); a symlink, wrong type or exceeded limit in the submodule tree
   refuses the launch (#12). This worktree's own submodule git dirs
   (`<common>/worktrees/<name>/modules`, where git keeps them for a
   linked worktree) are protected after the menu and follow
   `AI_SANDBOX_ALLOW_GIT_CONFIG` like WORKDIR's own submodules; the
   shared ones never do. Missing submodule `hooks/` are no longer
   created on the host (WARNed instead). Commit, branch, checkout, fetch
   keep working; `git config`, `remote add`, `push -u`,
   `branch --set-upstream-to`, `worktree add/prune` and submodule
   updates fail inside the sandbox. Applies to the Claude wrapper too.

**TOCTOU.** Validation and binds use the same realpath-resolved paths;
the over-mount targets are checked for symlinks immediately before the
flags are built. A residual window remains between this check and
bwrap's mount for a *concurrent* host process that can write the
victim repo; sandboxed sessions can no longer rename the RO mount
points.

**macOS (#11).** Seatbelt has no mounts, so the backend renders every
`--ro-bind` as a read allow plus a `(deny file-write* file-link …)`
rule appended after all allows (`_append_ro_deny_rules`). Precedence is
"most specific bind wins", independent of flag order: an RO path is
denied except below an RW `--bind` nested strictly inside it (so
`worktrees/` stays RO except this worktree's own entry, whose
`commondir`/`gitdir` are RO again). An equal or broader RW grant —
WORKDIR, `AI_SANDBOX_EXTRA_RW_DIRS`, a duplicate `--bind` — never
reopens an RO path. Because Seatbelt matches paths rather than inodes,
every ancestor directory of an RO path below `$HOME` (and the root of
each nested RW exception) is also write-denied as a literal: renaming a
writable parent away, editing the file under its new name and renaming
it back fails. `$HOME` and its ancestors have no write grant, so they
are not pinned; they get stat-only (`file-read-metadata`) grants instead
so git/realpath can walk a `$HOME` that is not directly under `/Users`.
`file-link` blocks hard-linking a protected file into a writable
directory. The same rules apply to `AI_SANDBOX_EXTRA_RO_DIRS`, the
glab config bind and `_extra_sandbox_setup` entries. Native coverage:
`tests/test_bind_hardening.bash` (worktree e2e through the codex
wrapper) and `tests/test_macos_ro_overlays.bash`, both in CI
`smoke-macos`.

Linux used to differ in one case: bwrap applies binds in order, and
`AI_SANDBOX_EXTRA_RW_DIRS` entries were appended after the wrapper's RO
over-mounts, so an entry covering the common dir hid them. Since #10 the
backend mounts user RW extra dirs before the wrapper's own binds (user
RO extra dirs stay after them, so the wrapper's RW binds cannot reopen
them), so the RO layers win on both OSes (`_extra_sandbox_setup` binds
still come last).

The WORKDIR's own `.git` is covered by B-ν.

### B-ν — WORKDIR's own git metadata (MITIGATED, 2026-10, #10)

WORKDIR is RW, and with it the repository's `.git/hooks/*` and
`.git/config` (`core.hooksPath`, `core.fsmonitor`, `core.sshCommand`,
aliases, filter/diff drivers, credential helpers), a linked worktree's
`.git` file (repointable), `.git/commondir` (git takes config and hooks
from the dir it names, even in a normal repo) and other checkouts'
`worktrees/*` pointers. All of them run commands on the host,
unsandboxed, on the user's next git command there.

**Mitigation.** `_wrapper_protect_workdir_git` (`ai_wrapper_lib.bash`),
called from `_apply_post_menu_binds` after the preset and menu in the
claude, codex, agy and copilot wrappers (and directly in the
cursor-agent wrapper). A refusal exits the wrapper before the client
starts. It protects only entries that exist at launch:

| WORKDIR | Always | Protected mode only |
|---|---|---|
| normal repo (`.git` dir) | `.git` and the chain to every submodule git dir pinned; `commondir`, `worktrees/` RO (also in submodule git dirs) | `config`, `hooks/`, `config.worktree` RO, also in submodule git dirs at any depth |
| linked worktree / submodule checkout (`.git` file) | `.git` file RO | — (shared `.git`: B-λ) |
| bare repo, or WORKDIR is a git dir | `commondir`, `worktrees/` RO | same entries directly under WORKDIR |
| repository subdirectory | nothing to do: the git dir is outside WORKDIR and not writable | |
| not a repository | WARN: metadata created in the session (`git init`, clone, nested repos) needs host review | |

- **Pin (root integrity).** On Linux a self-bind makes `.git` a mount
  point, so `rename(2)`/`rmdir(2)` fail with `EBUSY`. On macOS the new
  backend flag `--pin` renders a literal write deny on `.git` and its
  ancestors below `$HOME` (`_append_pin_rules`); RO entries alone pin it
  only when one exists, which is not the case in relaxed mode or when
  every protected entry is absent. Children stay writable, so the index,
  objects, refs, logs, `HEAD` and lock files work as before.
- **Setting.** `AI_SANDBOX_ALLOW_GIT_CONFIG=1` (menu: Sensitive, "Allow
  editing git config and hooks"; default 0) drops the RO layers on
  `config`, `hooks/`, `config.worktree` and submodule config/hooks only
  (WORKDIR's submodules and a linked worktree's own submodules). The
  pins, pointer files, `commondir`, `worktrees/` and all validation and
  limits stay. A value given explicitly at launch (even `=0`) wins over
  the per-workdir preset; restoring `1` from a preset WARNs. It does not
  relax the worktree common dir or its shared submodules (B-λ).
- **Submodule git dirs (#12).** `_wrapper_git_scan_modules` walks
  `modules/` (WORKDIR's git dir, a worktree's shared common dir and its
  own `worktrees/<name>/modules`; one shared helper). A directory whose
  `HEAD` or `config` is a regular file is a module git dir (a missing
  `config` alone does not demote it); any other directory is a namespace
  parent of a slash-containing name (`modules/libs/foo`) and is searched
  further; git refuses to nest module git dirs inside another one's
  namespace. Below a module git dir only its own `modules/` is searched
  (`modules/a/modules/b`), never `objects/` or `refs/`. Every module git
  dir gets the root's entry set (above) and every directory from
  `modules/` down to it (namespace parents, nested `modules/`) is pinned,
  in both modes: read-only children alone do not stop `rename(2)` of a
  parent on Linux, and a moved parent would let the agent plant a fresh
  tree in its place. On Linux all pins are mounted before the read-only
  layers below them.
  Limits: at most 16 directory levels below a `modules/` root (every
  component counts: `modules/a/modules/b` is 3, `modules/x/y/z` is 3) and
  at most 256 module git dirs per scan (a linked worktree's shared and
  own trees count together). Exceeding either refuses the launch with an
  ERROR naming the path; nothing is skipped or truncated.
- **Validation (both modes).** A symlinked `.git`, `config`, `hooks`,
  `config.worktree`, `commondir`, `worktrees`, `modules`, any symlink in
  the searched submodule tree (namespace parents, module git dirs, their
  `HEAD`, `config`, `hooks`, `commondir`, `worktrees`, `modules`), or one
  of those with the wrong file type, refuses the launch. The common-dir
  binder propagates such a refusal too (all wrappers exit 1). So does a WORKDIR strictly inside a git
  dir. Failure to resolve WORKDIR or its git dir fails closed. Host-side
  detection runs `git rev-parse` / `git config --file` only (no hooks or
  configured commands), with inherited `GIT_DIR` / `GIT_WORK_TREE` /
  `GIT_COMMON_DIR` dropped.
- **No host mutation.** Nothing is created or truncated, unlike the
  common-dir helper (B-λ), and there is no post-session step.

**Usability impact (protected mode).** Commit, new local branches,
checkout of local branches, merge/rebase, fetch and plain push keep
working and persist. Anything that writes config fails with "could not
lock/rename config" or EROFS: `git config`, `git remote add`, `git
branch --set-upstream-to`, hook installers (`pre-commit install`,
husky), `git submodule init/update`. Some commands fail half-way:

- `git push -u` can update the remote and then fail to record the local
  tracking config: the push lands, the upstream is not set
  (`tests/test_workdir_git_protection.bash` checks both);
- creating a branch that tracks a remote (`git checkout <remote-only
  branch>`, `checkout -b x origin/x`, `switch`, `branch x origin/y`)
  creates the ref, fails to write the tracking config and exits non-zero
  (checkout leaves HEAD where it was);
- `git branch -m` renames the ref, then fails to update config.

When linked worktrees exist, `worktrees/` is read-only from the main
checkout too, so `git worktree add/prune`, `git gc`'s worktree pruning
and renaming a branch checked out in another worktree fail.

**Residual (accepted by the owner).**

- *Absent entries.* bwrap needs an existing mount point and Seatbelt
  rules are only rendered for existing sources; creating them would
  mutate the host. A missing `config`, `hooks/`, `commondir` (absent in
  almost every repo, so this WARN appears on most normal-repo launches)
  or `config.worktree` (with `extensions.worktreeConfig`), in the root or
  in any submodule git dir, stays creatable and is listed in a WARN.
  Created ones are not protected until the next launch. The same holds
  for submodule git dirs created in the session (`modules/` stays
  writable so `git submodule update --init` works).
- *Indirection.* WARNs (detection only) for `core.hooksPath`,
  `core.fsmonitor` and `include.path` / `includeIf.*.path` resolving into
  WORKDIR, hook symlinks into WORKDIR, a `.git` file pointing at a git dir
  inside WORKDIR, and submodule checkouts (their `.git` pointer files
  below WORKDIR stay writable). Other commands in config (filter drivers,
  `sshCommand`, aliases) that run scripts from WORKDIR, and existing hooks
  that read WORKDIR content (pre-commit's `.pre-commit-config.yaml`,
  husky scripts, Makefiles), are not audited.
- *Operation state.* `.git/rebase-merge/` and `.git/rebase-apply/` must
  stay writable. The agent can leave a rebase in progress whose todo list
  contains `exec <cmd>`; `git rebase --continue` on the host then runs it.
  Check `git status` and the todo before continuing a rebase you did not
  start.
- *Not sanitized.* RO protection freezes what is there; it does not
  clean commands or hook symlinks already present, or metadata written by
  an earlier unprotected session.
- *Nested metadata.* Repos and `.git` dirs created anywhere below
  WORKDIR (outside `modules/`) are writable. Submodule git dirs below
  `modules/` are covered at any depth (#12).
- *Plugins.* `_extra_sandbox_setup` binds are applied last and can
  re-grant RW (trusted code, S-β).

### B-κ — symlinked account paths (RESOLVED, 2026-10)

Named profiles (`~/.claude-<name>`, `~/.claude-<name>.json`,
`~/.codex-<name>`) and `~/.claude.json` were bound RW without checking
whether they were symlinks, and `~/.claude` / `~/.codex` only refused
targets outside `$HOME`. `_wrapper_check_config_symlink`
(`ai_wrapper_lib.bash`) now refuses any of these that is a symlink
resolving outside `$HOME` or into a credential location (`~/.ssh`,
`~/.gnupg`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.colima`, `~/.netrc`,
`~/.npmrc`, `~/.pypirc`, gcloud and glab config). The `~/.claude.json`
check runs before `touch`, so a dangling symlink target is never
created. The Codex wrapper binds the resolved path.

### B-μ — AGY host-side Python and profile file operations (MITIGATED, 2026-10, #44)

Before launch, the agy wrapper lists/renames/deletes conversations and
rewrote `antigravity-cli/settings.json` on the host. It ran `python3 -`
(CWD first on `sys.path`, so a checkout `json.py` ran on the host), followed
symlinked `antigravity-cli/`, `brain/`, `conversations/`, database and
`.wrapper_title` paths, and wrote `settings.json.tmp.$$` (predictable,
followed if pre-created as a symlink).

**Mitigation.** One embedded helper (`_agy_host_py`, run as `python3 -I -`)
does all of it. By owner decision, `settings.json` is no longer written at
all: the wrapper reads it and fails the launch, listing what to change,
when a required key or the current workspace's trust is missing. It opens the resolved profile component by component with
`O_NOFOLLOW` and `*at` calls, refuses symlinked directories, database,
SQLite sidecars and title files before changing anything, unlinks symlinked
artifact leaves without traversal, opens SQLite with `mode=rw|ro` (never
creates a database) and checks that SQLite's descriptor is the inode it
verified. Without `python3`, or without dir-fd/`O_NOFOLLOW`/`flock`
support, these operations fail closed; the old `jq`/`sqlite3` fallbacks
are gone.

- **SQLite sidecars.** SQLite opens `-journal`/`-wal`/`-shm` itself, by
  path, so the helper cannot open them for it. It relies on two SQLite
  behaviours instead: sidecars are opened with `O_NOFOLLOW`, and a write is
  refused once the database path no longer names the open file
  (`SQLITE_READONLY_DBMOVED`). Before any profile database is opened, the
  helper proves both on the running library in a private temp dir (a
  symlinked sidecar per kind, and a directory swapped mid-transaction) and
  refuses the operation if either fails. Tests swap each sidecar for a
  symlink at open and at write time, and swap `antigravity-cli/` for a
  directory holding same-named sidecars; the external bytes stay unchanged.
- **Settings are read-only.** The wrapper never creates, rewrites, chmods
  or replaces `settings.json` or an approved symlink target, and never
  creates `antigravity-cli/`. Tests check that file, target and parent
  directories keep their content, inode, mode and mtime on success and on
  every failure.
- **Title writes (rename).** `.wrapper_title` is replaced by an `O_EXCL`
  temp file + `renameat` in the held directory, after re-checking the file
  (inode, size, mtime) and re-walking the parent; a changed file fails the
  rename (nothing is reported as renamed) instead of being overwritten.
  Every wrapper instance holds an exclusive advisory `flock` on the
  conversation directory from the read to the rename, so two wrappers never
  interleave; a lock held for more than 10 s fails the rename. The lock is
  taken and the temp file written before the database title changes, so a
  lock or permission failure leaves the database untouched. Failures name
  the path and tell the user to retry.
- **Trusted settings target.** A symlinked `settings.json` is read only
  through the target approved by `AGY_SETTINGS_TRUSTED_PROFILE` +
  `AGY_SETTINGS_TRUSTED_TARGET` (exact resolved profile and canonical
  existing file under `$HOME`, outside credential dirs). The approval is
  refused when the preset dir is writable inside the sandbox (WORKDIR, the
  profile, the wrapper's fixed RW binds, `AI_SANDBOX_EXTRA_RW_DIRS`,
  `WRAPPER_FLAGS` binds, macOS temp dirs), and also whenever an
  `AI_WRAPPER_EXTRA_PROFILE` plugin defines `_extra_post_menu_setup` or
  `_extra_sandbox_setup`: those run after the check and can add binds, so
  writability cannot be determined.

**Residual limits.**

- **Non-cooperating title writers (accepted by the owner).** The `flock`
  is advisory and a re-check followed by `rename` is not a compare-and-swap.
  A process that does not take the lock (agy itself, or a sandboxed agent
  still running on the same profile) and writes `.wrapper_title` exactly
  between the final re-check and the rename loses that write, and the
  wrapper cannot detect it. No portable POSIX call closes this. The owner
  kept rename available under this limit (concurrent renames are
  unlikely); it no longer affects `settings.json`, which is never written.
  A test pins the behaviour so this section stays accurate.
- A title change detected after the database title was updated (the final
  re-check) fails the rename and says the database already holds the new
  title while the picker still shows the old `.wrapper_title`; retrying the
  rename resolves it.
- SQLite's two guards are library behaviours, verified per run rather
  than enforced by the helper. On macOS the probe dir is in `$TMPDIR`,
  which the sandbox can write; a running agent could make the probe fail
  (a refusal) but cannot change how the library behaves.
- `~/bin` (which holds the deployed wrapper itself) is bound RW into the
  sandbox. That shared-sandbox gap is tracked separately (#17).

### B-β — `_realpath` fallback chain has multiple silent branches (RESOLVED, 2026-05-24, WS6)

Three resolvers tried in order: `realpath`, `perl -MCwd=abs_path`,
and a hand-rolled `cd $dir && pwd -P` walker (with two sub-branches
for files vs. directories). Each could fail for slightly different
reasons. The caller only saw pass/fail.

**Resolution.** WS6 adds `AI_SANDBOX_DEBUG=1` opt-in. Each
successful branch of `_realpath` emits one `echo_log "DEBUG"` line
naming which resolver succeeded (`realpath`, `perl-abs_path`,
`cd-pwd-dir`, `cd-pwd-symlink-walk-dir`, or
`cd-pwd-symlink-walk-file`) and the input path. Off by default; the
success path is otherwise unchanged. README documents the new flag.

### B-γ — Profile size has no upper bound (DEFERRED, 2026-05-24, post-WS1)

Each `--bind` / `--ro-bind` appends to the profile string passed to
`sandbox-exec -p`. With hundreds of binds the arg-list can hit
`ARG_MAX` (~256 KiB on macOS) silently.

**Disposition.** Deferred. The bind-array growth pattern this
concerned was largely a Linux-side artifact (the upstream bwrap
wrapper auto-binds `~/.kube`, `~/.kind`, `~/Android`, `~/bin`,
`~/.agents`, etc., growing the array fast). Post-WS1 the macOS flag
surface is single-arg and the wrapper only adds three to four binds
in practice. Revisit if a future caller ever needs hundreds of binds
or if the auto-bind set grows substantially.

### B-δ — `darwin_user_signpost` rule references unbound param on the fallback path (RESOLVED, 2026-05-24, WS2)

On the B7 fallback (DARWIN_USER_TEMP_DIR not ending in `/T`), the
`-D DARWIN_USER_SIGNPOST_DIR=…` was omitted but the SBPL `(allow
file* (subpath (param "DARWIN_USER_SIGNPOST_DIR")))` rule stayed in
the profile. Today sandbox-exec resolves unbound params to empty
string; future macOS may get stricter.

**Resolution.** WS2 adds a new `ENABLE_SIGNPOST` `-D` param that the
wrapper always sets to `0` or `1`. The signpost rule is now wrapped
in `(when (equal? (param "ENABLE_SIGNPOST") "1") …)` so it renders
only when the corresponding path was successfully derived. The
profile no longer references any potentially-unbound param.

### B-ε — `~/.gitignore`'d `reports/` still on disk

`.gitignore` excludes `reports/` (intentional — local-only scratch).
But `reports/clarifications-001.md` and the review-XXX files contain
the full threat-model derivation, including which softenings were
considered and rejected. If `~/bin` is ever tarred for backup, shared,
or used as a chezmoi source directory, the threat-model archive bleeds
with it.

**Fix.** Move `reports/` outside the repo (e.g. `~/Documents/bin-reports/`)
or accept the leak risk and add an explicit comment in `.gitignore`.

### B-ζ — `bash 3.2` reliance is implicit (RESOLVED, 2026-05-24, WS5)

`#!/usr/bin/env bash` picks whatever's first in `PATH`. On default
macOS this is `/bin/bash` 3.2; Homebrew installs bash 5 ahead of it.
Code worked on both, but the supported range wasn't pinned.

**Resolution.** WS5 adds a §"Compatibility" section to the README
naming the tested range: bash 3.2.57 (macOS default) and bash 5.x
(Homebrew). bash 4.x is plausibly OK but not regularly smoke-tested.
The section also lists the cross-version constructs the wrapper
relies on (`compgen -e`, indirect expansion, `${arr[@]:-default}`)
and the rule that any future bash 4+ syntax should be called out at
the call site.

### B-η — Settings-menu toggles lost in `$()` subshell (RESOLVED, 2026-05-25, post-WS7)

The original WS7 menu (`b1bd9b0`) shipped a settings sub-menu where the
user could toggle bools and edit string/path values via `export
NAME=value`. The catch: `claude_wrapper.bash` invoked the main menu as
`action=$(show_main_menu)`, which runs the entire menu loop —
including `toggle_settings_menu` — in a subshell. Every `export` made
inside that subshell died when the subshell exited, so the toggles
never reached `run_sandboxed_agent`'s env-scrub / SBPL profile
plumbing. End-to-end the menu looked like it worked (the table
re-rendered with `[x]` after a flip, because `_setting_current_value`
reads the same subshell's env) but the wrapper itself launched with
the old values.

**How it slipped past WS7 review.** The unit-level tests in the agent
brief exercised the catalog helpers (`_parse_setting_entry`,
`_setting_current_value`, `_render_settings_table`) in isolation; they
passed because those functions were correct. The bug was in the
*calling convention* between `claude_wrapper.bash` and the menu, not
in the menu itself. A post-merge end-to-end test (drive `show_main_menu`
via heredoc input, observe parent-shell env after return) is what
caught it.

**Resolution.** `show_main_menu` no longer echoes its chosen action to
stdout. It sets a global `WRAPPER_MENU_CHOICE` instead and returns;
`claude_wrapper.bash` calls it directly (no `$()`) and reads the
global. The menu now runs in the parent shell so `export`s
propagate.

**Implications for future menu additions.** Anything in
`ai_wrapper_lib.bash` that needs to mutate the parent shell's env
must be reached through `show_main_menu`'s direct-call contract.
Never re-introduce a stdout-capture pattern at the call site.

### B-θ — Menu read loops could spin forever on EOF (RESOLVED, 2026-05-25, post-WS7)

Found alongside B-η during end-to-end testing. The menu's `read -r
choice </dev/tty` paths returned non-zero on EOF (closed tty,
exhausted stdin in a non-interactive harness, etc.) but the
case-default branch ("Invalid choice. Press Enter to continue…") had
no handling for that — it printed the message, called `read -r
</dev/tty` again, got EOF again, and looped tight enough to peg a
CPU.

Production impact is small (`/dev/tty` doesn't normally EOF), but
any future change that opens stdin to the menu — or any operational
fault that closes the controlling tty mid-session — would spin the
shell forever.

**Resolution.** Every `read -r` in `show_main_menu` and
`toggle_settings_menu` is now guarded: on EOF, the menu aborts
gracefully (`show_main_menu` returns 1 with `WRAPPER_MENU_CHOICE=""`;
`toggle_settings_menu` treats EOF as "back"; the str/path edit
branch treats EOF as "empty input" which matches the documented
"empty to unset" contract).

## Plugin threat-model entries

Downstream plugins loaded via `AI_WRAPPER_EXTRA_PROFILE` may introduce
their own threat-model entries (e.g. workflow backends, extra MCP
channels, extra machine-wide policy files). Those live in the plugin
repo's own security notes rather than here, because they only apply
when that plugin is loaded.

## Carry-overs from earlier reviews (still open by design)

- **S2** — `(allow network*)`. Required for the Anthropic API. Documented.
- **S4** — `~/Library/Keychains` RW. Required for go-keyring
  atomic-replace path. Documented.
- **S7** — `~/Library/Caches/claude-cli-nodejs` RW. Today log-only, no
  write→exec gadget. Documented.
- **S9** — `--dangerously-skip-permissions`. By design; sandbox is the
  fence. Documented.
- **S11** — Symlink bypass: if a user *symlinks* a credential dir's
  target outside HOME, the `(require-not (subpath ...))` rule matches
  on the kernel's canonical path. Theoretical; flag for documentation.

## Decisions / Non-goals

Explicit decisions not to pursue an item the audit considered or that
upstream `Le0nRoy/my_linux_configs` ships. Recorded so a future reader
does not re-open the question.

- **Multi-account profile picker** (upstream `850462f`, the
  `CLAUDE_ACCOUNT` env var + `~/.claude-<name>/` directory layout) —
  not needed. Single-account workflow is sufficient for current needs.
  Re-evaluate if a second account is required. (Was tracked as R2 in
  the README "Linux merge" section; both the env-var row and the R2
  paragraph have been removed; this entry is the breadcrumb.)
- **Tailscale integration** — not needed. No reachability to
  Tailscale-bound services required from the sandbox. Upstream
  `cb4aaa5` (unconditional Tailscale socket bind) explicitly NOT
  pulled. Historical references to Tailscale inside
  `docs/plans/2026-05-23-sandbox-migration.md` and
  `docs/plans/2026-05-23-sandbox-hardening-context.md` stay as
  upstream-example context — they are not active grants.
- **`gh` CLI** — not needed in this sandbox. GitHub remote access
  (when required) is via `git` with HTTPS; no GitHub API calls
  planned from the sandbox. `gh` is not installed and is not part of
  the wrapper's tool requirements.
- **Resource limits (rlimits)** — not enforced. User accepts risk of
  unbounded CPU / memory / file-descriptor / process consumption by
  the sandboxed agent. Re-evaluate if a runaway agent causes
  operational pain. (Decision date 2026-05-27; see S-ζ
  RESOLVED-BY-DROP above for the full history.)

## Items NOT included here

The following were considered and rejected as "not really concerns":

- `(allow ipc-posix-shm)` — required for notification center / Foundation.
- `(allow pseudo-tty)` — required for interactive Claude CLI (`setRawMode`).
- `(literal "/")` read — needed for `realpath` ancestor stat walks. No
  subpath grant; the root inode itself is harmless.
- `(allow process-fork)` + `(allow process-exec)` — agents routinely
  run `git`, `npm`, `node`. Subprocess inheritance keeps them in the
  sandbox. Documented as the write→exec gadget caveat.
