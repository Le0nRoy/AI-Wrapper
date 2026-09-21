#!/usr/bin/env bash
# Integration test: autosave → clear catalog env → re-source lib → autoload → verify.

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/../lib/harness.bash"
. "${SCRIPT_DIR}/../lib/assert.bash"

PASS=0; FAIL=0; SKIP=0
trap clean_scratch EXIT

# INT-AUTOPERSIST-01: full roundtrip — autosave mixed vars, re-source, autoload, all restored.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
# Set mixed catalog vars
export AI_SANDBOX_PASS_AWS=1          # bool=1
export AI_SANDBOX_DRYRUN=0            # bool=0 (explicit, must persist)
export AI_SANDBOX_PASS_ENV="FOO,BAR"  # str
export AI_SANDBOX_PROFILE="/tmp/x.sb" # path
_preset_autosave
preset_path="$(_preset_autosave_path)"
assert_file_exists "INT-AUTOPERSIST-01-file" "${preset_path}"
# Wipe catalog env to simulate a fresh menu session
clear_catalog_env
unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
# Re-source the lib (simulates new wrapper invocation with same test lib file)
source_lib
_preset_autoload
ok=1
assert_eq "INT-AUTOPERSIST-01-bool1" "1" "${AI_SANDBOX_PASS_AWS:-}" || ok=0
assert_eq "INT-AUTOPERSIST-01-bool0" "0" "${AI_SANDBOX_DRYRUN:-}" || ok=0
assert_eq "INT-AUTOPERSIST-01-str"   "FOO,BAR" "${AI_SANDBOX_PASS_ENV:-}" || ok=0
assert_eq "INT-AUTOPERSIST-01-path"  "/tmp/x.sb" "${AI_SANDBOX_PROFILE:-}" || ok=0
# AI_WRAPPER_PRESET_AUTOLOADED_FROM must be set to the file path
assert_eq "INT-AUTOPERSIST-01-from"  "${preset_path}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" || ok=0
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS INT-AUTOPERSIST-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# INT-AUTOPERSIST-02: show_header renders dim "restored from" line when AI_WRAPPER_PRESET_AUTOLOADED_FROM is set.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
path="$(_preset_autosave_path)"
mkdir -p "$(dirname "${path}")"
printf '# workdir: %s\nAI_SANDBOX_PASS_AWS=1\n' "$(pwd -P)" > "${path}"
_preset_autoload
# Override show_header stub from harness to call the real one that checks AI_WRAPPER_PRESET_AUTOLOADED_FROM.
# The real show_header in the lib calls _render_settings_table and also renders the restored-from line.
# Since harness stubs show_header, we test the underlying helper _render_preset_banner_line directly.
tty_reset
_render_preset_banner_line
tty_content="$(cat "${TEST_TTY_OUT}")"
if assert_match "INT-AUTOPERSIST-02" "restored from" "${tty_content}"; then
    PASS=$((PASS+1)); echo "PASS INT-AUTOPERSIST-02"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# INT-AUTOPERSIST-03: show_header does NOT render restored-from when AI_WRAPPER_PRESET_AUTOLOADED_FROM unset.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
unset AI_WRAPPER_PRESET_AUTOLOADED_FROM
tty_reset
_render_preset_banner_line
tty_content="$(cat "${TEST_TTY_OUT}")"
if assert_unmatch "INT-AUTOPERSIST-03" "restored from" "${tty_content}"; then
    PASS=$((PASS+1)); echo "PASS INT-AUTOPERSIST-03"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# INT-AUTOPERSIST-04: _preset_clear removes file and banner disappears.
mk_scratch; guard_home
unset XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
export AI_SANDBOX_PASS_AWS=1
_preset_autosave
path="$(_preset_autosave_path)"
unset AI_SANDBOX_PASS_AWS
_preset_autoload
assert_eq "INT-AUTOPERSIST-04-pre" "${path}" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}"
_preset_clear
ok=1
assert_file_absent "INT-AUTOPERSIST-04-file" "${path}" || ok=0
if [[ -n "${AI_WRAPPER_PRESET_AUTOLOADED_FROM:-}" ]]; then
    _fail "INT-AUTOPERSIST-04-from" "AI_WRAPPER_PRESET_AUTOLOADED_FROM still set after clear" "(unset)" "${AI_WRAPPER_PRESET_AUTOLOADED_FROM}"; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS INT-AUTOPERSIST-04"; else FAIL=$((FAIL+1)); fi
clean_scratch

printf 'SUMMARY %s pass=%d fail=%d skip=%d\n' "$(basename "${BASH_SOURCE[0]}")" "${PASS}" "${FAIL}" "${SKIP}"
exit $(( FAIL == 0 ? 0 : 1 ))
