#!/bin/bash
# Verifies _render_os_conditional_doc() in ai_wrapper_lib.bash correctly
# filters wrapper-help.md's <!-- os:darwin/linux --> blocks, under both the
# real OS and a shadowed uname for the other one.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

# $1: darwin|linux
_help_dump() {
    (
        if [[ "${1}" == "darwin" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Darwin; else command uname "$@"; fi; }
        elif [[ "${1}" == "linux" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Linux; else command uname "$@"; fi; }
        fi
        # shellcheck source=../bin/ai_wrapper_data/ai_wrapper_lib.bash
        source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash"
        _render_os_conditional_doc "${REPO_ROOT}/bin/ai_wrapper_data/wrapper-help.md"
    )
}

echo "== wrapper-help.md OS-conditional rendering =="

linux_help="$(_help_dump linux)"
darwin_help="$(_help_dump darwin)"

# Darwin-only content absent from the Linux render.
assert_not_contains "${linux_help}" 'AI_SANDBOX_PROFILE=<path>' "PROFILE bullet absent on Linux"
assert_not_contains "${linux_help}" 'Seatbelt has no bind-mount remapping' "macOS account-switching limitation absent on Linux"
assert_not_contains "${linux_help}" 'no-op on macOS' "macOS-only --ro-bind history note absent on Linux"

# ...but present on the macOS render.
assert_contains "${darwin_help}" 'AI_SANDBOX_PROFILE=<path>' "PROFILE bullet present on macOS"
assert_contains "${darwin_help}" 'Seatbelt has no bind-mount remapping' "macOS account-switching limitation present on macOS"

# Linux-only content is the mirror image.
assert_contains "${linux_help}" 'bubblewrap can remap' "Linux-only --bind bullet present on Linux"
assert_not_contains "${darwin_help}" 'bubblewrap can remap' "Linux-only --bind bullet absent on macOS"

# Network isolation (#77 Linux, #78 macOS): each OS documents its own
# mechanism; the egress-proxy exfiltration note applies to both.
assert_contains "${darwin_help}" 'Seatbelt denies IP networking' "macOS network policy present on macOS"
assert_not_contains "${linux_help}" 'Seatbelt denies IP networking' "macOS network policy absent on Linux"
assert_contains "${linux_help}" '`--unshare-net`' "Linux network namespace present on Linux"
assert_not_contains "${darwin_help}" '`--unshare-net`' "Linux network namespace absent on macOS"
for help in "${linux_help}" "${darwin_help}"; do
    assert_contains "${help}" 'The egress proxy (below) keeps the agent off' "egress-proxy exfiltration note on both OSes"
    assert_contains "${help}" 'AI_SANDBOX_ALLOW_UNRESTRICTED_NET=1' "unrestricted-network opt-out documented on both OSes"
done

# s) Settings use cases are mirrored from the catalog: every setting shown
# on an OS has its "Use when" line in that OS's help, OS-only ones only there.
_catalog_names() {
    (
        if [[ "${1}" == "darwin" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Darwin; else command uname "$@"; fi; }
        else
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Linux; else command uname "$@"; fi; }
        fi
        # shellcheck source=../bin/ai_wrapper_data/ai_wrapper_lib.bash
        source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash"
        for e in "${_AI_SETTINGS_LIST[@]}"; do printf '%s\n' "${e%%|*}"; done
    )
}
for os in linux darwin; do
    if [[ "${os}" == linux ]]; then help="${linux_help}"; other="${darwin_help}"; else help="${darwin_help}"; other="${linux_help}"; fi
    while IFS= read -r name; do
        assert_contains "${help}" "(\`${name}\`): " "${os} help: use cases for ${name}"
    done < <(_catalog_names "${os}")
done
assert_contains "${linux_help}" '(`AI_SANDBOX_ALLOW_TIOCSTI`): ' "TIOCSTI use cases in the Linux help"
assert_not_contains "${darwin_help}" '(`AI_SANDBOX_ALLOW_TIOCSTI`): ' "TIOCSTI use cases not in the macOS help"
assert_contains "${darwin_help}" '(`AI_SANDBOX_ALLOW_KEYCHAIN`): ' "Keychain use cases in the macOS help"
assert_not_contains "${linux_help}" '(`AI_SANDBOX_ALLOW_KEYCHAIN`): ' "Keychain use cases not in the Linux help"
for help in "${linux_help}" "${darwin_help}"; do
    assert_contains "${help}" '(`CLAUDE_ACCOUNT`, `CODEX_ACCOUNT`, `AGY_ACCOUNT`): ' "account profile use cases on both OSes"
    assert_contains "${help}" 'type `?N`' "s) Settings help documents ?N"
done

# Marker syntax itself must never leak into either rendering.
assert_not_contains "${linux_help}" '<!-- os:' "no leaked marker syntax in the Linux render"
assert_not_contains "${darwin_help}" '<!-- os:' "no leaked marker syntax in the macOS render"

tests_summary_and_exit
