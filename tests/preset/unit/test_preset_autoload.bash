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

# UNIT-AUTOLOAD-03: restores bool=0 explicitly when the caller left it unset,
# and keeps an explicit launch value over the saved one (CC-6 precedence).
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\n%s=0\n' "$(pwd -P)" "${CANARY_BOOL}" > "${path}"
ok=1
unset "${CANARY_BOOL}"
_preset_autoload
assert_eq "UNIT-AUTOLOAD-03-restore" "0" "${!CANARY_BOOL-unset}" || ok=0
export "${CANARY_BOOL}=1"
_preset_autoload
assert_eq "UNIT-AUTOLOAD-03-launch" "1" "${!CANARY_BOOL:-}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-03"; else FAIL=$((FAIL+1)); fi
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

# UNIT-AUTOLOAD-09: falls back to the legacy shared <hash>.env when the
# per-agent file is absent; other agents' keys there are skipped silently.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
legacy="$(_preset_legacy_path)"
mkdir -p "$(dirname "${legacy}")"
printf '# workdir: %s\nCODEX_ACCOUNT=alt\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${legacy}"
unset AI_SANDBOX_PASS_AWS CODEX_ACCOUNT AI_WRAPPER_PRESET_AUTOLOADED_FROM
tty_reset
_preset_autoload
ok=1
assert_eq "UNIT-AUTOLOAD-09" "1" "${AI_SANDBOX_PASS_AWS:-}" || ok=0
assert_eq "UNIT-AUTOLOAD-09-from" "${legacy}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" || ok=0
assert_eq "UNIT-AUTOLOAD-09-foreign" "" "${CODEX_ACCOUNT:-}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-09-warn" "unknown setting" "$(cat "${TEST_TTY_OUT}")" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-09"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-10: per-agent file takes precedence over the legacy file.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
legacy="$(_preset_legacy_path)"
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf 'AI_SANDBOX_PASS_AWS=1\n' > "${legacy}"
printf 'AI_SANDBOX_PASS_AWS=0\n' > "${path}"
unset AI_SANDBOX_PASS_AWS AI_WRAPPER_PRESET_AUTOLOADED_FROM
_preset_autoload
ok=1
assert_eq "UNIT-AUTOLOAD-10" "0" "${AI_SANDBOX_PASS_AWS:-}" || ok=0
assert_eq "UNIT-AUTOLOAD-10-from" "${path}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-10"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-11: unset AI_WRAPPER_AGENT_ID returns rc=1, no side effects.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
unset AI_WRAPPER_AGENT_ID
unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
set +e
err="$( _preset_autoload 2>&1 )"
rc=$?
set -e
ok=1
(( rc == 1 )) || { _fail "UNIT-AUTOLOAD-11" "expected rc=1" "1" "${rc}"; ok=0; }
assert_match "UNIT-AUTOLOAD-11" "AI_WRAPPER_AGENT_ID" "${err}" || ok=0
if [[ -n "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]]; then
    _fail "UNIT-AUTOLOAD-11" "AI_WRAPPER_PRESET_AUTOLOADED_FROM set despite invalid agent id" "(unset)" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}"; ok=0
fi
if [[ -d "${XDG_CONFIG_HOME}/ai-wrapper" ]]; then
    _fail "UNIT-AUTOLOAD-11" "preset dir created despite invalid agent id"; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-11"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-12: caller environment wins over the preset for bool, str
# (including a set-but-empty value) and leaves no restore WARN for those keys.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '%s=1\n%s=SAVED_VAR\nAI_SANDBOX_EXTRA_RW_DIRS=/tmp\n' "${CANARY_BOOL}" "${CANARY_STR}" > "${path}"
export "${CANARY_BOOL}=0" "${CANARY_STR}=" AI_SANDBOX_EXTRA_RW_DIRS=/opt
unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
err_file="${TEST_SCRATCH}/stderr"
_preset_autoload 2>"${err_file}"
err="$(cat "${err_file}")"
ok=1
assert_eq "UNIT-AUTOLOAD-12-bool" "0" "${!CANARY_BOOL}" || ok=0
assert_eq "UNIT-AUTOLOAD-12-empty-str" "" "${!CANARY_STR-unset}" || ok=0
assert_eq "UNIT-AUTOLOAD-12-str" "/opt" "${AI_SANDBOX_EXTRA_RW_DIRS}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-12-warn" "Restored" "${err}" || ok=0
assert_eq "UNIT-AUTOLOAD-12-from" "" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-12"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-13: restoring a non-default red or yellow setting WARNs on
# stderr (visible to scripted launches); default values and info settings
# restore silently.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '%s=1\n%s=0\nAI_SANDBOX_ALLOW_DOCKER=1\nAI_SANDBOX_EXTRA_RW_DIRS=/tmp\nAI_SANDBOX_EXTRA_RO_DIRS=\nAI_SANDBOX_DEBUG=1\n' \
    "${CANARY_BOOL}" "${CANARY_BOOL_2}" > "${path}"
err_file="${TEST_SCRATCH}/stderr"
_preset_autoload 2>"${err_file}"
err="$(cat "${err_file}")"
ok=1
assert_eq "UNIT-AUTOLOAD-13-applied" "1" "${!CANARY_BOOL:-}" || ok=0
assert_match "UNIT-AUTOLOAD-13-red" "Restored ${CANARY_BOOL}=1 from the saved preset" "${err}" || ok=0
assert_match "UNIT-AUTOLOAD-13-red-2" "Restored AI_SANDBOX_ALLOW_DOCKER=1 from the saved preset" "${err}" || ok=0
assert_match "UNIT-AUTOLOAD-13-yellow" "Restored AI_SANDBOX_EXTRA_RW_DIRS=/tmp from the saved preset" "${err}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-13-default-bool" "${CANARY_BOOL_2}" "${err}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-13-default-str" "AI_SANDBOX_EXTRA_RO_DIRS" "${err}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-13-info" "AI_SANDBOX_DEBUG" "${err}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-13"; else FAIL=$((FAIL+1)); fi
clean_scratch

# UNIT-AUTOLOAD-14: retired git settings (_AI_RETIRED_SETTINGS) in an old
# preset are skipped: never exported, no unknown-setting WARN; a saved
# non-default value prints one NOTE, a saved 0 nothing; other keys load.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset AI_SANDBOX_ALLOW_GIT_CONFIG AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES AI_SANDBOX_BLOCK_LINKED_GIT_DIRS
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf 'AI_SANDBOX_ALLOW_GIT_CONFIG=0\nAI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1\nAI_SANDBOX_BLOCK_LINKED_GIT_DIRS=1\nAI_SANDBOX_DEBUG=1\n' > "${path}"
err_file="${TEST_SCRATCH}/stderr"
_preset_autoload 2>"${err_file}" >"${TEST_SCRATCH}/stdout"
err="$(cat "${err_file}" "${TEST_SCRATCH}/stdout")"
ok=1
assert_eq "UNIT-AUTOLOAD-14-git-config" "unset" "${AI_SANDBOX_ALLOW_GIT_CONFIG-unset}" || ok=0
assert_eq "UNIT-AUTOLOAD-14-worktrees" "unset" "${AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES-unset}" || ok=0
assert_eq "UNIT-AUTOLOAD-14-block" "unset" "${AI_SANDBOX_BLOCK_LINKED_GIT_DIRS-unset}" || ok=0
assert_eq "UNIT-AUTOLOAD-14-other" "1" "${AI_SANDBOX_DEBUG-unset}" || ok=0
assert_match "UNIT-AUTOLOAD-14-note-worktrees" "Ignoring retired setting AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES=1" "${err}" || ok=0
assert_match "UNIT-AUTOLOAD-14-note-block" "Ignoring retired setting AI_SANDBOX_BLOCK_LINKED_GIT_DIRS=1" "${err}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-14-default-silent" "AI_SANDBOX_ALLOW_GIT_CONFIG" "${err}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-14-no-unknown" "unknown setting" "${err}" || ok=0
assert_unmatch "UNIT-AUTOLOAD-14-restored" "Restored" "${err}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS UNIT-AUTOLOAD-14"; else FAIL=$((FAIL+1)); fi
clean_scratch

printf 'SUMMARY %s pass=%d fail=%d skip=%d\n' "$(basename "${BASH_SOURCE[0]}")" "${PASS}" "${FAIL}" "${SKIP}"
exit $(( FAIL == 0 ? 0 : 1 ))
