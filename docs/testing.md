# Testing

Plain-bash tests under `tests/`, Python `unittest` files for the
`bin/ai_wrapper_data` helpers, and one `unittest` file shipped inside a
skill. No test framework; bash 3.2 (macOS) and bash 5 (Linux)
must both work.

## Safe commands

Run from the repository root. None of these deploy anything, touch the real
`~/.claude`, `~/.codex`, `~/.gemini`, `~/.copilot`, or launch an installed
AI client.

```bash
bash tests/test_live_client_isolation.bash   # isolation canaries (run first)
bash tests/test_<name>.bash                   # one file
python3 -B dot_agents/skills/tortuga/scripts/test_gh.py
bash tests/run-preset-tests.sh                # macOS only
bash tests/run_all.bash                       # everything for this OS
```

Never run `chezmoi apply` as part of testing. Lint with
`shellcheck -x -S warning <file>` and `bash -n <file>`.

## Isolation contract

Every test that sources wrapper code or launches a wrapper calls
`isolate_test_env FAKE_HOME` (`tests/lib_test_helpers.bash`) first:

- `HOME` and `XDG_{CONFIG,DATA,STATE,CACHE}_HOME` point into a fresh fake
  home. `FAKE_HOME` sits under the real `$HOME` on purpose (see the comment
  in `tests/test_sandbox_common.bash`); it is removed on exit.
- Inherited wrapper settings (`AI_SANDBOX_*`, `AI_WRAPPER_*`, `*_ACCOUNT`),
  client state and credential variables (`CODEX_*`, `CLAUDE_*`, `GH_*`,
  `GITHUB_*`, `*TOKEN*`, `*API_KEY*`, ...), the host session's
  `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` and `CONTAINER_HOST`,
  `GIT_DIR`-style redirections,
  `BASH_ENV`/`ENV` and exported shell functions are cleared.
- `PATH` becomes `FAKE_HOME/bin` plus the host `PATH` without empty,
  relative, or real-`$HOME` entries. Toolchains in `/usr/local`, Homebrew,
  or `/usr/bin` stay available.
- `FAKE_HOME/bin` holds a fail-closed trap for each of `claude codex agy
  copilot cursor-agent gemini`. A trap prints `LIVE_CLIENT_TRAP`, records
  the hit when it can, and exits 97. A test that needs a client overwrites
  that one trap with its stub. Because `FAKE_HOME/bin` is also first on the
  bwrap sandbox `PATH`, an un-stubbed client resolves to the trap both on
  the host and inside the sandbox, even when a real client lives in
  `/usr/bin` or `/usr/local/bin`.

Inside bwrap the sandbox `PATH` is `~/bin:/usr/bin:/usr/sbin:/bin:/sbin:~/.local/bin`.
The agy e2e test, which checks `~/.local/bin` resolution, keeps the `~/bin`
trap and reports that case as skipped when an `agy` exists in a system dir.

This is environment hygiene, not confinement. It does not make host files
unreadable to a test process. Sandbox claims come only from the e2e tests
that launch a real sandbox.

## Suites, side effects, scope

| File | Side effects | Needs | Linux | macOS |
|------|--------------|-------|-------|-------|
| `test_live_client_isolation.bash` | fake home under `$HOME`, temp dir | bash | full; bwrap e2e if available | host checks; e2e skipped |
| `test_catalog_os_scope.bash`, `test_help_doc_os_scope.bash` | none | bash | full | full |
| `test_agy_host_boundary.bash` | fake home under `$HOME`, temp dir, sqlite dbs, symlinks, stub `bwrap`; checks wrapper runs (parallel, killed mid-launch) never touch settings.json | bash, python3 | full | conversation/helper parts; wrapper runs skipped |
| `test_preset_identity.bash` | fake home under `$HOME`, stub `sha256sum`/`shasum` dirs, preset files | bash, python3 | full | full |
| `test_setup_skills.bash` | fake home under `$TMPDIR` | bash, coreutils | full | full |
| `test_cursor_retirement.bash` | fake homes under `$TMPDIR` with fixture copies of the retired Cursor files, symlinks, a read-only dir (permission case skipped as root) | bash, coreutils | full | full |
| `dot_agents/skills/tortuga/scripts/test_gh.py` | none (mocked `subprocess`) | python3 | full | full |
| `test_suite_inventory.bash` | none (reads `ci.yml`, `run_all.bash`, this file) | bash, awk | full | full |
| `test_network_proxy.py` | loopback mock upstreams and proxies on ephemeral ports, UNIX sockets under a temp dir in `/tmp`, proxy subprocesses (stopped by signal); fake resolver, no DNS or internet | python3 | full | full |
| `test_sandbox_common.bash`, `test_extra_bind_dirs.bash` | launches the real sandbox, fake home | bwrap + userns, python3 + libseccomp / sandbox-exec | fails without bwrap, user namespaces or the filter prerequisites | full |
| `test_sandbox_macos_only.bash` | sandbox-exec dry-run | sandbox-exec | exits 0 with a skip line | full |
| `test_macos_credential_policy.bash` | fake home under `$HOME` with synthetic git credential files and a fake `*.keychain-db`; stub `getconf`/`sandbox-exec` off macOS; on CI or with `AI_WRAPPER_TEST_SYNTHETIC_KEYCHAIN=1` a throwaway keychain in the fake home (added to and removed from the user keychain search list) | bash; sandbox-exec and `security` for native probes | profile-check unit tests + rendered profile; native part skipped | full: native git-credential and Keychain denial (missing sandbox-exec fails) |
| `test_macos_ro_overlays.bash` | git repos in fake home; stub `getconf`/`sandbox-exec` off macOS | git; sandbox-exec for native checks | rule rendering + mocked dry-run; native part skipped | full, native write denial (missing sandbox-exec fails) |
| `test_claude_wrapper.bash` | fake home under `$HOME`, stub `claude`/`copilot` and stub `bwrap`/`sysctl` in temp dirs; bwrap e2e with a stub claude | bash; bwrap for e2e | full: Claude UI env allowlist, bwrap argv (claude vs copilot), e2e with bwrap | allowlist logic only; argv and e2e skipped |
| `test_codex_wrapper.bash`, `test_agy_wrapper.bash`, `test_copilot_wrapper.bash` | git repos, sqlite db, stub clients in fake home; bwrap e2e | git, python3 (sqlite3, tomllib optional), bwrap for e2e | full with bwrap; e2e skipped without | argv/unit parts, native named-account refusal (#46); bwrap e2e skipped |
| `test_bind_hardening.bash` | git repos (incl. a worktree with nested submodules via local file:// clones), stub codex/claude in fake home, symlinks into the fake home's `.ssh`/`.config`/`.bashrc` and to `/etc` (never followed by a write), stub `bwrap`/`sysctl` dir (Linux argv), temp alias dir under `/tmp` (macOS) | git, perl; bwrap or sandbox-exec for e2e | full with bwrap (path-resolution argv and config-symlink policy run without it); e2e skipped without | full: native worktree write-denial e2e (missing sandbox-exec fails) |
| `test_client_persistent_controls.bash` | fake home under `$HOME` with synthetic Claude / Codex / Copilot / AGY profiles (controls, auth and session files, a symlinked skills dir), work dir in the fake home | bash, perl; bwrap or sandbox-exec for native probes | full: per-client flag generation, refusal, `AI_SANDBOX_ALLOW_SETTINGS`, WORKDIR exception; native write/replace/rename denial and auth/session/WORKDIR writes (skipped without bwrap) | full: plus native Seatbelt probes (skipped without sandbox-exec) |
| `test_linux_host_binds.bash` | fake home under `$HOME` (synthetic `~/bin`, skills, Android, Kind and kube dirs), stub `bwrap`/`sysctl` dir, a synthetic UNIX socket served by python3 | bash, python3; bwrap for native probes | full: argv gates, native denial/persistence (missing bwrap fails) | skipped |
| `test_linux_runtime_dir.bash` | fake home under `$HOME`, synthetic runtime dirs under `/tmp`, stub `bwrap`/`sysctl` dir, synthetic UNIX socket servers (bus, systemd, Docker, Podman, SSH agent) served by python3 | bash, python3; bwrap for native probes | full: argv, native socket denial/grants, private dir mode/owner, broad-override persistence (missing bwrap fails) | skipped |
| `test_linux_process_isolation.bash` | fake home under `$HOME`, fake `/proc/sys` knobs, stub `bwrap`/`sysctl` and helper scripts in a temp dir, a private pty (never the caller's terminal), one child user namespace for the denial check | bash, python3 + libseccomp; bwrap, `unshare` for native probes | full: filter helper unit tests (real filters in forked children), knob/probe/filter failure handling and argv, native nested-userns denial and relaxed success, ioctl EPERM vs unfiltered control, filter-descriptor leaks (by pipe identity, caller-held descriptors pass through), combined caller filter, real knob/probe denial, PTY launch (/dev/tty, raw input, resize, Ctrl+C, cleanup) (missing bwrap fails) | skipped (Linux-only) |
| `test_linux_tty_seccomp.py` | forked children with private ptys; no caller terminal touched | python3 + libseccomp | full (also run by `test_linux_process_isolation.bash`) | Linux-only cases skipped |
| `test_sandbox_net_forwarder.py` | loopback listeners on ephemeral ports | python3 | full (also run by `test_linux_network_isolation.bash`) | runs via `run_all.bash` only; the forwarder is used on Linux only |
| `test_linux_network_isolation.bash` | fake home under `$HOME`, fake `/proc/sys` knobs, stub `bwrap` and failing/hanging proxy stand-ins in a temp dir; real `ai_network_proxy.py` subprocesses on UNIX sockets in private dirs under `/tmp` (stopped after each launch); a host test server on an abstract UNIX socket and a `127.0.0.1` ephemeral port; forwarder tests on ephemeral loopback ports; no DNS or internet (the one public-address connect is expected to be unroutable) | bash, python3 (+ libseccomp for the launch); bwrap for native probes | full: forwarder unit tests (`test_sandbox_net_forwarder.py`), `--unshare-net` / `--share-net` argv, proxy variables, socket and forwarder binds, proxy lifecycle (own session, cleanup after success and failure, caller EXIT trap kept), fail-closed startup, native host abstract-socket / loopback / direct-egress denial and the proxy path, with `AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1` as control (missing bwrap fails) | skipped (Linux-only) |
| `test_macos_network_isolation.bash` | fake home under `$HOME`; stub `sandbox-exec` (records argv/env, runs the client unsandboxed) and failing/hanging proxy stand-ins in a temp dir; stub `getconf` off macOS; real `ai_network_proxy.py` subprocesses on ephemeral `127.0.0.1` ports with private dirs under the (fake) `DARWIN_USER_TEMP_DIR`; a host test server on a `127.0.0.1` ephemeral port (macOS); no DNS or internet (the one public-address connect is expected to be denied by Seatbelt) | bash, python3; sandbox-exec and system perl for native probes | profile text, `-D ALLOW_UNRESTRICTED_NET`/`PROXY_PORT`, proxy variables (last, passthrough-proof), proxy lifecycle (cleanup after success, failure, dry run and a killed wrapper; caller EXIT trap kept; a parent's EXIT trap not run by a subshell or command substitution, with and without `BASHPID` and under macOS `/bin/bash`), fail-closed startup; native part skipped | full: plus native host-loopback / direct-egress denial and the proxy path, with `AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1` as control (missing sandbox-exec fails) |
| `test_sensitive_path_parity.bash` | fake home under `$HOME`; stub `getconf`/`sandbox-exec` off macOS; refusals from `/etc` (never granted to a client) | bash; bwrap or sandbox-exec for native refusals | classifier tables + mocked macOS backend; native Linux refusals need bwrap (missing bwrap fails) | full, native refusals incl. `/private/etc` |
| `test_external_worktree.bash` | git repos in fake home and in a sibling dir outside it (real `$HOME` or the checkout's `tests/`), one in the system temp dir, preset files, stub codex; drives the interactive menu through a pty | git, perl, python3; bwrap or sandbox-exec for e2e | full with bwrap; e2e skipped without | full: native external-worktree write/read denial (missing sandbox-exec fails) |
| `test_workdir_git_protection.bash` | git repos (normal, worktree, bare, scaffold, nested submodules via local file:// clones) and stub clients in fake home | git, perl, python3; bwrap or sandbox-exec for e2e | full with bwrap; missing bwrap fails | full: native WORKDIR git metadata write denial (missing sandbox-exec fails) |
| `run-preset-tests.sh` | rewritten lib copy and scratch dirs under `$TMPDIR` (fallback `tests/preset/_scratch/`, git-ignored), removed on exit | BSD `stat -f` | exits 2 (not run) | full |

## CI mapping

`.github/workflows/ci.yml` runs files as separate steps; `tests/run_all.bash`
is the local equivalent. Keep both in sync when adding a test file;
`test_suite_inventory.bash` fails when a suite has no CI path, misses an
OS job it covers (only `test_linux_*` may skip macOS, only
`test_sandbox_macos_only` may skip Linux), is not reached by `run_all.bash`
or is not listed above.

- `lint` (Linux, macOS): `bash -n` on every script; ShellCheck on Linux.
- `logic-tests` (Linux, macOS): catalog, help-doc, setup-skills, Tortuga
  helper, live-client isolation canaries, agy host-side boundary, preset
  identity, suite inventory, network proxy engine.
- `smoke-linux`: bubblewrap installed; sandbox, extra-binds, isolation
  canaries (with e2e), codex, bind-hardening, external worktrees,
  WORKDIR git metadata, macOS RO-overlay and credential-policy rendering, agy, copilot, Linux
  host-path gates (native ~/bin / skills / Android / Tailscale / Kind probes),
  user runtime dir (native socket denial and named grants), process
  isolation (nested user namespaces, terminal-injection filter and its
  `test_linux_tty_seccomp.py` unit tests, launch preflight; installs
  `python3` and `libseccomp2`), network isolation (`--unshare-net`, egress
  proxy wiring, host abstract-socket and loopback denial, and the
  `test_sandbox_net_forwarder.py` unit tests), macOS network isolation (profile text, proxy wiring with a stub
  `sandbox-exec`).
- `smoke-macos`: sandbox, macOS-only, extra-binds, bind-hardening,
  external worktrees, WORKDIR git metadata and RO overlays (native write denial),
  credential policy (native git-credential and Keychain denial, synthetic
  keychain probe), network isolation (native Seatbelt egress and loopback
  denial through the egress proxy), client persistent controls (native
  Seatbelt denial for all four clients), codex/agy/copilot wrapper suites
  (argv, settings, native named-account refusal; bwrap e2e skipped),
  preset suite.

## Reading results

- A `skip - ...` line is not a pass. It names what was not checked and why.
- A failing sandbox test on a host without bwrap or user namespaces
  (Linux; python3 + libseccomp too since #64) or without sandbox-exec
  (macOS) is environmental. Report it as such.
- Real-CLI flag acceptance (does an installed `codex`/`agy`/`copilot`
  accept the argv the wrapper builds?) is a manual gate. Tests check argv
  construction against stubs only and never launch an installed client.

## Native-OS limits

- Worktree common-dir (inside and, with the opt-in, outside `$HOME`)
  and WORKDIR git metadata write denial run natively on both OSes
  (`test_bind_hardening.bash`, `test_external_worktree.bash`,
  `test_workdir_git_protection.bash`, `test_macos_ro_overlays.bash`). Other
  wrapper e2e tests (account remap, credential-dir write denial) run on
  Linux bwrap only; on macOS argv snapshots that contain `--bind` do not
  prove enforcement.
- Native macOS evidence, all in `smoke-macos`: named-account refusal
  before launch for claude/codex/agy, default profile still launches (#46;
  `test_codex_wrapper.bash`, `test_agy_wrapper.bash`); persistent-control
  write/replace/rename denial with auth, session and WORKDIR still writable
  (#48; `test_client_persistent_controls.bash`); git credential, Keychain
  and glab-cli denial under `AI_SANDBOX_ALLOW_RO_HOMEDIR`, granted only by
  `AI_SANDBOX_PASS_GITLAB=1` (#47; `test_macos_credential_policy.bash`).
  All use synthetic fixtures in a fake home, never real credentials.
- Settings, presets and warnings are covered as logic, not by a real
  client: explicit-env precedence over saved presets, session-only
  settings never persisted, and restored-risky-setting warnings
  (`run-preset-tests.sh`, macOS only; `test_external_worktree.bash`,
  `test_catalog_os_scope.bash`, `test_agy_wrapper.bash`).

## Manual gates

Not proven by any automated suite; owner acceptance before the integration
PR (#52) merges:

- Real-CLI flag acceptance and supported-client authentication (OAuth
  refresh, Keychain tokens, cloud credentials) with installed `claude`,
  `codex`, `agy` and `copilot`. Tests use stubs and fake homes only.
- Menu usability, defaults and risky-setting warning wording and colors.
- Linux bwrap e2e inside the wrapper suites needs bwrap and user
  namespaces; the preset suite needs macOS. Each reports a visible skip
  line elsewhere — a skip is not a pass.
