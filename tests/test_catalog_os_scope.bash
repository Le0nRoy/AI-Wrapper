#!/bin/bash
# Verifies _AI_SETTINGS_LIST's OS_SCOPE filtering in bin/ai_wrapper_data/
# ai_wrapper_lib.bash. Renders the catalog under both the real OS AND a
# shadowed `uname -s` for the other OS, so this one file exercises both
# branches regardless of which platform it actually runs on.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

# Settings with no backend at all on the non-listed OS (see
# ai_wrapper_lib.bash's _AI_SETTINGS_LIST comment for the OS_SCOPE contract).
DARWIN_ONLY_KEYS=(
    AI_SANDBOX_PROFILE
    AI_SANDBOX_PROFILE_TRUST_ME
    AI_SANDBOX_DRYRUN
    AI_SANDBOX_ALLOW_RO_HOMEDIR
    AI_SANDBOX_BLOCK_LOCALHOST
)
# Linux bubblewrap host-path gates (#62); the macOS backend never binds
# these paths, so the controls are hidden there.
LINUX_ONLY_KEYS=(
    AI_SANDBOX_ALLOW_BIN_RW
    AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW
    AI_SANDBOX_ALLOW_ANDROID
    AI_SANDBOX_PASS_TAILSCALE
    AI_SANDBOX_ALLOW_XDG_RUNTIME_RW
)
# A representative sample of settings implemented on both backends.
CROSS_PLATFORM_KEYS=(
    AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR
    AI_SANDBOX_PASS_GITLAB
    AI_SANDBOX_PASS_SSH_AGENT
    AI_SANDBOX_ALLOW_DOCKER
)

# $1: darwin|linux -- dump the catalog as it would render on that OS, one
# entry per line, in an isolated subshell so the shadowed `uname` never
# leaks into the rest of this script.
_catalog_dump() {
    (
        if [[ "${1}" == "darwin" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Darwin; else command uname "$@"; fi; }
        elif [[ "${1}" == "linux" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Linux; else command uname "$@"; fi; }
        fi
        # shellcheck source=../bin/ai_wrapper_data/ai_wrapper_lib.bash
        source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash"
        printf '%s\n' "${_AI_SETTINGS_LIST[@]}"
    )
}

echo "== catalog OS-scope filtering =="

linux_catalog="$(_catalog_dump linux)"
darwin_catalog="$(_catalog_dump darwin)"

for key in "${DARWIN_ONLY_KEYS[@]}"; do
    assert_not_contains "${linux_catalog}" "${key}|" "${key} hidden on Linux (no backend there)"
    assert_contains "${darwin_catalog}" "${key}|" "${key} shown on macOS"
done

for key in "${LINUX_ONLY_KEYS[@]}"; do
    assert_contains "${linux_catalog}" "${key}|bool|0|" "${key} shown on Linux, default 0"
    assert_not_contains "${darwin_catalog}" "${key}|" "${key} hidden on macOS (no backend there)"
done

# Kind support was removed (#62): no Kind-specific setting or wording.
assert_not_contains "${linux_catalog}" "ALLOW_KIND" "no Kind setting on Linux"
assert_not_contains "${linux_catalog}" "kind_dot_kube" "no kind_dot_kube wording on Linux"
# The combined kind + kubectl installer is gone too, with its README row.
assert_eq "$([[ -e "${REPO_ROOT}/bin/executable_setup_kind.bash" ]] && echo present || echo absent)" absent \
    "Kind installer source removed"
assert_not_contains "$(cat "${REPO_ROOT}/README.md")" "setup_kind" "README does not list the Kind installer"
assert_contains "${linux_catalog}" "AI_SANDBOX_PASS_TAILSCALE|bool|0|red|" "Tailscale control is red severity"
tailscale_row="$(grep '^AI_SANDBOX_PASS_TAILSCALE|' <<<"${linux_catalog}")"
assert_contains "${tailscale_row}" "does not make the Tailscale API read-only" "Tailscale help disclaims a read-only API"

# Broad runtime-dir override (#63): red, and its help names what it exposes.
assert_contains "${linux_catalog}" "AI_SANDBOX_ALLOW_XDG_RUNTIME_RW|bool|0|red|" "runtime-dir override is red severity"
runtime_row="$(grep '^AI_SANDBOX_ALLOW_XDG_RUNTIME_RW|' <<<"${linux_catalog}")"
assert_contains "${runtime_row}" "D-Bus session bus" "runtime-dir help names the session bus"
assert_contains "${runtime_row}" "Off: the sandbox gets a private, empty runtime dir" "runtime-dir help describes the default"
runtime_scope="$(source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash" >/dev/null 2>&1
    if _setting_is_session_only AI_SANDBOX_ALLOW_XDG_RUNTIME_RW; then echo session; else echo preset; fi)"
assert_eq "${runtime_scope}" preset "runtime-dir override is an ordinary preset setting"
# Rootless container sockets are a Linux-only part of ALLOW_DOCKER.
assert_contains "$(grep '^AI_SANDBOX_ALLOW_DOCKER|' <<<"${linux_catalog}")" "podman/podman.sock" \
    "Linux ALLOW_DOCKER help names the rootless Podman socket"
assert_not_contains "$(grep '^AI_SANDBOX_ALLOW_DOCKER|' <<<"${darwin_catalog}")" "XDG_RUNTIME_DIR" \
    "macOS ALLOW_DOCKER help has no Linux runtime-dir wording"

for key in "${CROSS_PLATFORM_KEYS[@]}"; do
    assert_contains "${linux_catalog}" "${key}|" "${key} shown on Linux"
    assert_contains "${darwin_catalog}" "${key}|" "${key} shown on macOS"
done

# Cross-platform entries must not leak the other OS's wording into their
# DETAIL text (the exact bug fixed by hand earlier — regression-guard it).
assert_not_contains "${linux_catalog}" "~/Library" "no ~/Library wording anywhere in the Linux catalog"
assert_contains "${darwin_catalog}" "~/Library" "~/Library wording present in the macOS catalog"

tests_summary_and_exit
