#!/usr/bin/env bash
# Unit tests for _preset_clear.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/../lib/harness.bash"
. "${SCRIPT_DIR}/../lib/assert.bash"

PASS=0; FAIL=0; SKIP=0
trap clean_scratch EXIT

# UNIT-CLEAR-01: removes the preset file when it exists.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
# Create the preset file first
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
assert_file_exists "UNIT-CLEAR-01-pre" "${path}"
_preset_clear
if assert_file_absent "UNIT-CLEAR-01" "${path}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-CLEAR-01"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-CLEAR-02: unsets AI_WRAPPER_PRESET_AUTOLOADED_FROM.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
export AI_WRAPPER_PRESET_AUTOLOADED_FROM="${path}"
_preset_clear
if [[ -z "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]]; then
    PASS=$((PASS+1)); echo "PASS UNIT-CLEAR-02"
else
    FAIL=$((FAIL+1)); _fail "UNIT-CLEAR-02" "AI_WRAPPER_PRESET_AUTOLOADED_FROM still set" "(unset)" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}"
fi
clean_scratch

# UNIT-CLEAR-03: no-op when file does not exist (returns 0, no error).
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
tty_reset
set +e
_preset_clear
rc=$?
set -e
ok=1
(( rc == 0 )) || { _fail "UNIT-CLEAR-03" "expected rc=0, got ${rc}" "0" "${rc}"; ok=0; }
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-CLEAR-03"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-CLEAR-04: clear does not affect other workdir files.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
# Create preset for current workdir
path1="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path1}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path1}"
# Create a fake second preset file (simulate different workdir hash)
path2="$(dirname "${path1}")/aabbccddeeff.env"
printf '# workdir: /some/other/path\nAI_SANDBOX_DRYRUN=1\n' > "${path2}"
_preset_clear
ok=1
assert_file_absent "UNIT-CLEAR-04" "${path1}" || ok=0
assert_file_exists "UNIT-CLEAR-04-other" "${path2}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-CLEAR-04"; else FAIL=$((FAIL+1)); fi
clean_scratch

printf 'SUMMARY %s pass=%d fail=%d skip=%d\n' "$(basename "${BASH_SOURCE[0]}")" "${PASS}" "${FAIL}" "${SKIP}"
exit $(( FAIL == 0 ? 0 : 1 ))
