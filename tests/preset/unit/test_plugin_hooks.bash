#!/usr/bin/env bash
# Unit tests for the 7 plugin hook callbacks introduced by the
# AI_WRAPPER_EXTRA_PROFILE extension system.
#
# Covers:
#   _extra_settings_register  (fires at lib source time)
#   _extra_category_label     (_category_label fallback)
#   _extra_header_extras      (show_header)
#   _extra_menu_options       (show_main_menu render)
#   _extra_menu_dispatch      (show_main_menu unknown-choice handling)
#   AI_WRAPPER_EXTRA_PROFILE sourcing — silent when unset, WARN when missing

set -o pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${SCRIPT_DIR}/../lib/harness.bash"
. "${SCRIPT_DIR}/../lib/assert.bash"

PASS=0; FAIL=0; SKIP=0
trap clean_scratch EXIT

# ---------------------------------------------------------------------------
# _extra_settings_register
# ---------------------------------------------------------------------------

# HOOK-SETTINGS-REGISTER-01: no-op when absent — lib loads normally.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset -f _extra_settings_register 2>/dev/null || true
source_lib
ok=1
# _AI_SETTINGS_LIST must be non-empty (populated by the lib's catalog).
if [[ "${#_AI_SETTINGS_LIST[@]}" -eq 0 ]]; then
    _fail "HOOK-SETTINGS-REGISTER-01" "_AI_SETTINGS_LIST empty; lib may not have loaded" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-SETTINGS-REGISTER-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# HOOK-SETTINGS-REGISTER-02: hook fires when defined before source_lib.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
_SENTINEL_FILE="${TEST_SCRATCH}/settings_register_fired"
# Must be defined before source_lib — the call is at module-init level.
_extra_settings_register() { touch "${_SENTINEL_FILE}"; }
source_lib
ok=1
if [[ ! -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-SETTINGS-REGISTER-02" "_extra_settings_register was not called" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-SETTINGS-REGISTER-02"; else FAIL=$((FAIL+1)); fi
unset -f _extra_settings_register
clean_scratch

# ---------------------------------------------------------------------------
# _extra_category_label
# ---------------------------------------------------------------------------

# HOOK-CATEGORY-LABEL-01: absent → raw key returned as-is.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset -f _extra_category_label 2>/dev/null || true
source_lib
result="$(_category_label "CUSTOM_PLUGIN_CAT")"
if assert_eq "HOOK-CATEGORY-LABEL-01" "CUSTOM_PLUGIN_CAT" "${result}"; then
    PASS=$((PASS+1)); echo "PASS HOOK-CATEGORY-LABEL-01"
else
    FAIL=$((FAIL+1))
fi
clean_scratch

# HOOK-CATEGORY-LABEL-02: hook fires and returns custom label.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
_extra_category_label() {
    [[ "${1}" == "CUSTOM_PLUGIN_CAT" ]] || return 1
    printf 'My Plugin Category'
}
result="$(_category_label "CUSTOM_PLUGIN_CAT")"
if assert_eq "HOOK-CATEGORY-LABEL-02" "My Plugin Category" "${result}"; then
    PASS=$((PASS+1)); echo "PASS HOOK-CATEGORY-LABEL-02"
else
    FAIL=$((FAIL+1))
fi
unset -f _extra_category_label
clean_scratch

# ---------------------------------------------------------------------------
# _extra_header_extras
# ---------------------------------------------------------------------------

# HOOK-HEADER-EXTRAS-01: absent → sentinel file never created.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset -f _extra_header_extras 2>/dev/null || true
source_lib
_SENTINEL_FILE="${TEST_SCRATCH}/header_extras_fired"
tty_reset
set +e; show_header; set -e
ok=1
if [[ -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-HEADER-EXTRAS-01" "_extra_header_extras should not have fired" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-HEADER-EXTRAS-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# HOOK-HEADER-EXTRAS-02: hook fires inside show_header.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
_SENTINEL_FILE="${TEST_SCRATCH}/header_extras_fired"
_extra_header_extras() { touch "${_SENTINEL_FILE}"; }
tty_reset
set +e; show_header; set -e
ok=1
if [[ ! -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-HEADER-EXTRAS-02" "_extra_header_extras was not called by show_header" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-HEADER-EXTRAS-02"; else FAIL=$((FAIL+1)); fi
unset -f _extra_header_extras
clean_scratch

# ---------------------------------------------------------------------------
# _extra_menu_options
# ---------------------------------------------------------------------------

# HOOK-MENU-OPTIONS-01: absent → sentinel file never created by menu render.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset -f _extra_menu_options 2>/dev/null || true
source_lib
_SENTINEL_FILE="${TEST_SCRATCH}/menu_options_fired"
tty_in "1"  # choose option 1 → exit cleanly after first render
set +e; show_main_menu; set -e
ok=1
if [[ -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-MENU-OPTIONS-01" "_extra_menu_options should not have fired" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-MENU-OPTIONS-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# HOOK-MENU-OPTIONS-02: hook fires during show_main_menu render.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
_SENTINEL_FILE="${TEST_SCRATCH}/menu_options_fired"
_extra_menu_options() { touch "${_SENTINEL_FILE}"; }
tty_in "1"  # choose option 1 → exit cleanly after first render
set +e; show_main_menu; set -e
ok=1
if [[ ! -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-MENU-OPTIONS-02" "_extra_menu_options was not called during menu render" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-MENU-OPTIONS-02"; else FAIL=$((FAIL+1)); fi
unset -f _extra_menu_options
clean_scratch

# ---------------------------------------------------------------------------
# _extra_menu_dispatch
# ---------------------------------------------------------------------------

# HOOK-MENU-DISPATCH-01: absent → invalid choice falls through to re-render.
# Feed: unknown char "z", Enter (press-enter-to-continue), then "1" to exit.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset -f _extra_menu_dispatch 2>/dev/null || true
source_lib
_SENTINEL_FILE="${TEST_SCRATCH}/dispatch_fired"
tty_in "z" "" "1"
set +e; show_main_menu; set -e
ok=1
if [[ -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-MENU-DISPATCH-01" "_extra_menu_dispatch should not have fired" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-MENU-DISPATCH-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# HOOK-MENU-DISPATCH-02: hook fires on unknown choice; returning 0 re-renders.
# Feed: "z" (hook handles it, returns 0 → menu re-loops), then "1" to exit.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
_SENTINEL_FILE="${TEST_SCRATCH}/dispatch_fired"
_extra_menu_dispatch() {
    [[ "${1}" == "z" ]] || return 1
    touch "${_SENTINEL_FILE}"
    return 0  # 0 = handled; menu will re-render
}
tty_in "z" "1"
set +e; show_main_menu; set -e
ok=1
if [[ ! -f "${_SENTINEL_FILE}" ]]; then
    _fail "HOOK-MENU-DISPATCH-02" "_extra_menu_dispatch was not called for unknown choice" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-MENU-DISPATCH-02"; else FAIL=$((FAIL+1)); fi
unset -f _extra_menu_dispatch
clean_scratch

# ---------------------------------------------------------------------------
# AI_WRAPPER_EXTRA_PROFILE sourcing guards
# Tests call _load_extra_profile (defined in ai_wrapper_lib.bash) directly
# so regressions in the production guard are caught immediately.
# ---------------------------------------------------------------------------

# HOOK-EXTRA-PROFILE-01: silent (no stderr) when variable is unset.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
unset AI_WRAPPER_EXTRA_PROFILE
source_lib
err_out="$(_load_extra_profile 2>&1)"
ok=1
if [[ -n "${err_out}" ]]; then
    _fail "HOOK-EXTRA-PROFILE-01" "expected silence when unset, got: ${err_out}" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-EXTRA-PROFILE-01"; else FAIL=$((FAIL+1)); fi
clean_scratch

# HOOK-EXTRA-PROFILE-02: emits WARN on stderr when file does not exist.
mk_scratch; guard_home
export XDG_CONFIG_HOME="${TEST_SCRATCH}/config"
clear_catalog_env
source_lib
export AI_WRAPPER_EXTRA_PROFILE="${TEST_SCRATCH}/nonexistent_plugin.bash"
err_out="$(_load_extra_profile 2>&1)"
ok=1
if [[ "${err_out}" != *"WARN"* ]]; then
    _fail "HOOK-EXTRA-PROFILE-02" "expected WARN in stderr, got: ${err_out}" "" ""; ok=0
fi
if (( ok == 1 )); then PASS=$((PASS+1)); echo "PASS HOOK-EXTRA-PROFILE-02"; else FAIL=$((FAIL+1)); fi
unset AI_WRAPPER_EXTRA_PROFILE
clean_scratch

printf 'SUMMARY %s pass=%d fail=%d skip=%d\n' "$(basename "${BASH_SOURCE[0]}")" "${PASS}" "${FAIL}" "${SKIP}"
exit $(( FAIL == 0 ? 0 : 1 ))
