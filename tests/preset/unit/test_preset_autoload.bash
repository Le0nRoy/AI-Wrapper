#!/usr/bin/env bash
# Unit tests for _preset_autoload.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/../lib/harness.bash"
. "${SCRIPT_DIR}/../lib/assert.bash"

PASS=0; FAIL=0; SKIP=0
trap clean_scratch EXIT

# UNIT-AUTOLOAD-01: no-op silently when no file exists (first run).
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
tty_reset
set +e
_preset_autoload
rc=$?
set -e
tty_content="$(cat "${TEST_TTY_OUT}")"
ok=1
(( rc == 0 )) || { _fail "UNIT-AUTOLOAD-01" "expected rc=0, got ${rc}" "0" "${rc}"; ok=0; }
# TTY should remain empty (no banner on first run)
if [[ -n "${tty_content}" ]]; then
    _fail "UNIT-AUTOLOAD-01" "expected silent no-op, got TTY output" "(empty)" "${tty_content}"; ok=0
fi
# AI_WRAPPER_PRESET_AUTOLOADED_FROM should NOT be set
if [[ -n "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]]; then
    _fail "UNIT-AUTOLOAD-01" "AI_WRAPPER_PRESET_AUTOLOADED_FROM set on first run" "(unset)" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}"; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-02: restores bool=1 value.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
# Create a preset file manually
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
# Unset so we can verify autoload restores it
unset AI_SANDBOX_PASS_AWS
_preset_autoload
if assert_eq "UNIT-AUTOLOAD-02" "1" "${AI_SANDBOX_PASS_AWS:-}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-02"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-AUTOLOAD-03: restores bool=0 explicitly (not unsets).
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_DRYRUN=0\n' "$(pwd -P)" > "${path}"
# Pre-set to 1 so we can verify autoload sets it back to 0
export AI_SANDBOX_DRYRUN=1
_preset_autoload
if assert_eq "UNIT-AUTOLOAD-03" "0" "${AI_SANDBOX_DRYRUN:-}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-03"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-AUTOLOAD-04: rejects unknown keys with WARN, does not abort.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nUNKNOWN_KEY_XYZ=1\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
unset AI_SANDBOX_PASS_AWS
tty_reset
_preset_autoload
tty_content="$(cat "${TEST_TTY_OUT}")"
ok=1
assert_match "UNIT-AUTOLOAD-04" "WARN" "${tty_content}" || ok=0
assert_match "UNIT-AUTOLOAD-04" "UNKNOWN_KEY_XYZ" "${tty_content}" || ok=0
# Known key should still be applied
assert_eq "UNIT-AUTOLOAD-04" "1" "${AI_SANDBOX_PASS_AWS:-}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-04"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-05: rejects non-0/1 bool values with WARN, does not abort.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_DRYRUN=yes\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
unset AI_SANDBOX_DRYRUN AI_SANDBOX_PASS_AWS
tty_reset
_preset_autoload
tty_content="$(cat "${TEST_TTY_OUT}")"
ok=1
assert_match "UNIT-AUTOLOAD-05" "WARN" "${tty_content}" || ok=0
# The bad bool key should NOT have been set
if [[ "${AI_SANDBOX_DRYRUN:-}" == "yes" ]]; then
    _fail "UNIT-AUTOLOAD-05" "bad bool value was applied" "(not 'yes')" "yes"; ok=0
fi
# Good value should still apply
assert_eq "UNIT-AUTOLOAD-05" "1" "${AI_SANDBOX_PASS_AWS:-}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-05"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-06: sets AI_WRAPPER_PRESET_AUTOLOADED_FROM when >=1 setting applied.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
_preset_autoload
if assert_eq "UNIT-AUTOLOAD-06" "${path}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-06"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-AUTOLOAD-07: does NOT set AI_WRAPPER_PRESET_AUTOLOADED_FROM when zero settings applied.
# (file exists but only has unknown keys)
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nUNKNOWN_KEY_1=foo\nUNKNOWN_KEY_2=bar\n' "$(pwd -P)" > "${path}"
unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
_preset_autoload
if [[ -z "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]]; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-07"
else
    FAIL=$((FAIL+1)); _fail "UNIT-AUTOLOAD-07" "AI_WRAPPER_PRESET_AUTOLOADED_FROM set despite zero applied" "(unset)" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}"
fi
clean_scratch

# UNIT-AUTOLOAD-08: restores str value verbatim.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_ENV=FOO,BAR,BAZ\n' "$(pwd -P)" > "${path}"
unset AI_SANDBOX_PASS_ENV
_preset_autoload
if assert_eq "UNIT-AUTOLOAD-08" "FOO,BAR,BAZ" "${AI_SANDBOX_PASS_ENV:-}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-08"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

printf 'SUMMARY %s pass=%d fail=%d skip=%d\n' "$(basename "${BASH_SOURCE[0]}")" "${PASS}" "${FAIL}" "${SKIP}"
exit $(( FAIL == 0 ? 0 : 1 ))
