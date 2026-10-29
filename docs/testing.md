# Testing

Plain-bash tests under `tests/`, plus one Python `unittest` file shipped
inside a skill. No test framework; bash 3.2 (macOS) and bash 5 (Linux)
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
  `GITHUB_*`, `*TOKEN*`, `*API_KEY*`, ...), `GIT_DIR`-style redirections,
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
| `test_agy_host_boundary.bash` | fake home under `$HOME`, temp dir, sqlite dbs, symlinks | bash, python3 | full | full |
| `test_setup_skills.bash` | fake home under `$TMPDIR` | bash, coreutils | full | full |
| `dot_agents/skills/tortuga/scripts/test_gh.py` | none (mocked `subprocess`) | python3 | full | full |
| `test_sandbox_common.bash`, `test_extra_bind_dirs.bash` | launches the real sandbox, fake home | bwrap + userns / sandbox-exec | fails without bwrap/sysctl | full |
| `test_sandbox_macos_only.bash` | sandbox-exec dry-run | sandbox-exec | exits 0 with a skip line | full |
| `test_codex_wrapper.bash`, `test_agy_wrapper.bash`, `test_copilot_wrapper.bash`, `test_bind_hardening.bash` | git repos, sqlite db, stub clients in fake home; bwrap e2e | git, python3 (sqlite3, tomllib optional), bwrap for e2e | full with bwrap; e2e skipped without | argv/unit parts; bwrap e2e skipped |
| `run-preset-tests.sh` | rewritten lib copy and scratch dirs under `$TMPDIR` (fallback `tests/preset/_scratch/`, git-ignored), removed on exit | BSD `stat -f` | exits 2 (not run) | full |

## CI mapping

`.github/workflows/ci.yml` runs files as separate steps; `tests/run_all.bash`
is the local equivalent. Keep both in sync when adding a test file.

- `lint` (Linux, macOS): `bash -n` on every script; ShellCheck on Linux.
- `logic-tests` (Linux, macOS): catalog, help-doc, setup-skills, Tortuga
  helper, live-client isolation canaries, agy host-side boundary.
- `smoke-linux`: bubblewrap installed; sandbox, extra-binds, isolation
  canaries (with e2e), codex, bind-hardening, agy, copilot.
- `smoke-macos`: sandbox, macOS-only, extra-binds, preset suite.

## Reading results

- A `skip - ...` line is not a pass. It names what was not checked and why.
- A failing sandbox test on a host without bwrap/sysctl or sandbox-exec is
  environmental; it fails the same way on `main`. Report it as such.
- Real-CLI flag acceptance (does an installed `codex`/`agy`/`copilot`
  accept the argv the wrapper builds?) is a manual gate. Tests check argv
  construction against stubs only and never launch an installed client.

## Native-OS limits

- Wrapper e2e tests (account remap, worktree common-dir write denial,
  credential-dir write denial) run on Linux bwrap only. On macOS they are
  skipped; argv snapshots that contain `--bind` do not prove macOS
  enforcement.
- Native macOS write-denial, profile selection and account-switching
  coverage is tracked in #51 after the related hardening issues land.
