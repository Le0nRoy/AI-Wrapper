#!/usr/bin/env bash
# Unit tests for _preset_autosave and _preset_autosave_path.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/../lib/harness.bash"
. "${SCRIPT_DIR}/../lib/assert.bash"

PASS=0; FAIL=0; SKIP=0
trap clean_scratch EXIT

# UNIT-AUTOSAVE-01: _preset_autosave_path returns expected path under XDG_CONFIG_HOME.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
clear_catalog_env
source_lib
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
workdir="$(pwd -P)"
hash="$(printf '%s' "${workdir}" | shasum -a 256 | cut -c1-12)"
expected="${TEST_SCRATCH}/config/ai-wrapper/last-preset/${hash}.env"
actual="$(_preset_autosave_path)"
if assert_eq "UNIT-AUTOSAVE-01" "${expected}" "${actual}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-01"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-AUTOSAVE-02: _preset_autosave_path falls back to $HOME/.config when XDG_CONFIG_HOME unset.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
clear_catalog_env
source_lib
workdir="$(pwd -P)"
hash="$(printf '%s' "${workdir}" | shasum -a 256 | cut -c1-12)"
expected="${HOME}/.config/ai-wrapper/last-preset/${hash}.env"
actual="$(_preset_autosave_path)"
if assert_eq "UNIT-AUTOSAVE-02" "${expected}" "${actual}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-02"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-AUTOSAVE-03: _preset_autosave writes every catalog key (including bool=0).
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
# Set one bool on, leave others at default (0)
export AI_SANDBOX_PASS_AWS=1
_preset_autosave
path="$(_preset_autosave_path)"
ok=1
assert_file_exists "UNIT-AUTOSAVE-03" "${path}" || ok=0
content="$(cat "${path}")"
# Must contain AI_SANDBOX_PASS_AWS=1
assert_match "UNIT-AUTOSAVE-03" "AI_SANDBOX_PASS_AWS=1" "${content}" || ok=0
# Must also contain bool=0 values (e.g., AI_SANDBOX_DRYRUN=0)
assert_match "UNIT-AUTOSAVE-03" "AI_SANDBOX_DRYRUN=0" "${content}" || ok=0
# str/path with empty value should also appear
assert_match "UNIT-AUTOSAVE-03" "AI_SANDBOX_PASS_ENV=" "${content}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-03"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOSAVE-04: _preset_autosave writes workdir: header comment.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
workdir="$(pwd -P)"
_preset_autosave
path="$(_preset_autosave_path)"
content="$(cat "${path}")"
if assert_match "UNIT-AUTOSAVE-04" "# workdir: ${workdir}" "${content}"; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-04"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# UNIT-AUTOSAVE-05: _preset_autosave writes mode 0644.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
_preset_autosave
path="$(_preset_autosave_path)"
mode="$(stat_mode "${path}")"
if [[ "${mode}" =~ ^0?644$ ]]; then
    PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-05"
else
    FAIL=$((FAIL+1)); _fail "UNIT-AUTOSAVE-05" "expected mode 644 (got '${mode}')" "0?644" "${mode}"
fi
clean_scratch

# UNIT-AUTOSAVE-06: _preset_autosave replaces on repeat (no append, no orphan tmp).
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
export AI_SANDBOX_PASS_AWS=1
_preset_autosave
path="$(_preset_autosave_path)"
# Insert sentinel into file to verify it gets replaced
printf '\n# SENTINEL\n' >> "${path}"
grep -q SENTINEL "${path}" || { _fail "UNIT-AUTOSAVE-06" "sentinel not in file"; FAIL=$((FAIL+1)); clean_scratch; }
# Second save with different state
unset AI_SANDBOX_PASS_AWS
export AI_SANDBOX_PASS_KUBE=1
_preset_autosave
content="$(cat "${path}")"
ok=1
assert_unmatch "UNIT-AUTOSAVE-06" "SENTINEL" "${content}" || ok=0
assert_match "UNIT-AUTOSAVE-06" "AI_SANDBOX_PASS_KUBE=1" "${content}" || ok=0
# No orphan tmp files
preset_dir="$(dirname "${path}")"
if compgen -G "${preset_dir}/*.tmp.*" > /dev/null 2>&1; then
    _fail "UNIT-AUTOSAVE-06" "orphan tmp file found"; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-06"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOSAVE-07: two different workdirs get distinct hash files.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
mkdir "${TEST_SCRATCH}/work2"
# Save from work (already cd'd there by mk_scratch)
_preset_autosave
path1="$(_preset_autosave_path)"
# Save from work2
cd "${TEST_SCRATCH}/work2"
_preset_autosave
path2="$(_preset_autosave_path)"
ok=1
if [[ "${path1}" == "${path2}" ]]; then
    _fail "UNIT-AUTOSAVE-07" "both workdirs got the same path" "${path1}" "${path2}"; ok=0
fi
assert_file_exists "UNIT-AUTOSAVE-07" "${path1}" || ok=0
assert_file_exists "UNIT-AUTOSAVE-07" "${path2}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOSAVE-07"; else FAIL=$((FAIL+1)); fi
# cd back so clean_scratch works
cd "${TEST_SCRATCH}/work"
clean_scratch

printf 'SUMMARY %s pass=%d fail=%d skip=%d\n' "$(basename "${BASH_SOURCE[0]}")" "${PASS}" "${FAIL}" "${SKIP}"
exit $(( FAIL == 0 ? 0 : 1 ))
