---
name: safe-destructive-scripts
description: >
  Repo-local (ai-wrapper) rules for any bash test or script that creates
  temp dirs (mktemp), cd's, or deletes files (rm -rf, trap cleanup). Use
  when writing or editing tests/*.bash, tests/lib_test_helpers.bash,
  run_*.bash or bin/ scripts with cleanup, and before running any bash
  test suite from inside an agent sandbox.
---

# Safe destructive scripts

## Incident (2026-11)
Inside the agent sandbox `FAKE_HOME="$(mktemp -d "$HOME/x.XXXXXX")"` was
denied, leaving `FAKE_HOME=""`. The next line, `cd "${FAKE_HOME}" && pwd -P`,
resolved to the current directory (the repo root), and the EXIT trap ran
`rm -rf "${FAKE_HOME}"`: the whole checkout, uncommitted work included,
was deleted.

## Rules
- Create test dirs with `DIR="$(_safe_mktemp_d TEMPLATE)" || exit 1` and
  remove them with `_safe_rm_rf "$DIR"` (both in `tests/lib_test_helpers.bash`,
  self-tested by `tests/test_safe_temp_helpers.bash`). Outside the test
  lib: check every `mktemp` (`|| exit 1`) and that the result is a
  non-empty directory.
- Any other `rm -rf` on a variable: `"${VAR:?}/sub"`, never a bare
  `"$VAR"` that could be empty, `/`, `.`, `$HOME` or the checkout.
- Never derive a delete target from the current directory (`pwd`, `.`,
  `cd "$x" && pwd` without checking `$x`).
- `cd -- "$dir" || exit 1`; never continue after a failed `cd`.
- Set the cleanup trap only after the dir was created successfully.
- Prefer `${TMPDIR:-/tmp}` for temp dirs; use `$HOME` only when the test
  needs a path under the home (sandbox path rules), and then guard it.

## Running suites
Do not run `tests/*.bash`, `tests/run_all.bash` or `tests/preset/*` from
inside the agent sandbox unless you have first read the suite and
confirmed every temp dir is created with a checked `mktemp` and removed
only through `_safe_rm_rf` (or an equivalent guard). Safe in the sandbox:
`bash -n`, `/bin/bash -n`, `shellcheck`, and Python suites whose temp dirs
come from `tempfile`. Otherwise hand the commands to the user to run.
