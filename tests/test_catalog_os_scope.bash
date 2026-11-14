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
    AI_SANDBOX_ALLOW_KEYCHAIN
)
# Linux bubblewrap host-path gates (#62); the macOS backend never binds
# these paths, so the controls are hidden there.
LINUX_ONLY_KEYS=(
    AI_SANDBOX_ALLOW_BIN_RW
    AI_SANDBOX_ALLOW_AGENTS_SKILLS_RW
    AI_SANDBOX_ALLOW_ANDROID
    AI_SANDBOX_PASS_TAILSCALE
    AI_SANDBOX_ALLOW_XDG_RUNTIME_RW
    AI_SANDBOX_ALLOW_NESTED_USERNS
    AI_SANDBOX_ALLOW_TIOCSTI
)
# A representative sample of settings implemented on both backends.
CROSS_PLATFORM_KEYS=(
    AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR
    AI_SANDBOX_PASS_GITLAB
    AI_SANDBOX_PASS_SSH_AGENT
    AI_SANDBOX_ALLOW_DOCKER
    AI_SANDBOX_ALLOW_UNRESTRICTED_NET
    AI_SANDBOX_ALLOW_SETTINGS
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
    if _setting_is_retired AI_SANDBOX_ALLOW_XDG_RUNTIME_RW; then echo retired; else echo preset; fi)"
assert_eq "${runtime_scope}" preset "runtime-dir override is an ordinary preset setting"
# Rootless container sockets are a Linux-only part of ALLOW_DOCKER.
assert_contains "$(grep '^AI_SANDBOX_ALLOW_DOCKER|' <<<"${linux_catalog}")" "podman/podman.sock" \
    "Linux ALLOW_DOCKER help names the rootless Podman socket"
assert_not_contains "$(grep '^AI_SANDBOX_ALLOW_DOCKER|' <<<"${darwin_catalog}")" "XDG_RUNTIME_DIR" \
    "macOS ALLOW_DOCKER help has no Linux runtime-dir wording"
# Keychain gate (#67): red, off by default, help names both access paths.
assert_contains "${darwin_catalog}" "AI_SANDBOX_ALLOW_KEYCHAIN|bool|0|red|" "Keychain control is red severity, default 0"
keychain_row="$(grep '^AI_SANDBOX_ALLOW_KEYCHAIN|' <<<"${darwin_catalog}")"
assert_contains "${keychain_row}" "/Library/Keychains" "Keychain help names the file path"
assert_contains "${keychain_row}" "securityd" "Keychain help names the daemon path"
assert_contains "${keychain_row}" "|credentials|darwin" "Keychain control sits in the credentials category"

# Process isolation opt-outs (#64): nested userns red, TIOCSTI yellow,
# both ordinary preset settings whose help names what turning them on costs.
assert_contains "${linux_catalog}" "AI_SANDBOX_ALLOW_NESTED_USERNS|bool|0|red|" "nested-userns opt-out is red severity"
assert_contains "${linux_catalog}" "AI_SANDBOX_ALLOW_TIOCSTI|bool|0|yellow|" "TIOCSTI opt-out is yellow severity"
nested_row="$(grep '^AI_SANDBOX_ALLOW_NESTED_USERNS|' <<<"${linux_catalog}")"
assert_contains "${nested_row}" "Chromium" "nested-userns help names the in-sandbox Chromium need"
assert_contains "${nested_row}" "shared host socket work without it" "nested-userns help: host-socket Docker/Podman unaffected"
tiocsti_row="$(grep '^AI_SANDBOX_ALLOW_TIOCSTI|' <<<"${linux_catalog}")"
assert_contains "${tiocsti_row}" "python3 + libseccomp" "TIOCSTI help names the prerequisite"
assert_contains "${tiocsti_row}" "launch is refused" "TIOCSTI help: missing support refuses, not skips"
for key in AI_SANDBOX_ALLOW_NESTED_USERNS AI_SANDBOX_ALLOW_TIOCSTI; do
    key_scope="$(source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash" >/dev/null 2>&1
        if _setting_is_retired "${key}"; then echo retired; else echo preset; fi)"
    assert_eq "${key_scope}" preset "${key} is an ordinary preset setting"
done

# Network isolation opt-out (#77 Linux, #78 macOS): red, networking on
# both OSes, ordinary preset setting
# (a restored preset triggers the risky-setting warning).
assert_contains "${linux_catalog}" "AI_SANDBOX_ALLOW_UNRESTRICTED_NET|bool|0|red|" "unrestricted-net opt-out is red severity"
net_row="$(grep '^AI_SANDBOX_ALLOW_UNRESTRICTED_NET|' <<<"${linux_catalog}")"
assert_eq "${net_row##*|}" "networking" "unrestricted-net control sits in the networking category, on every OS"
assert_contains "${net_row}" "Seatbelt" "unrestricted-net help covers the macOS backend"
assert_contains "${net_row}" "cloud metadata" "unrestricted-net help names what it exposes"
assert_contains "${net_row}" "egress proxy" "unrestricted-net help names the default path"

# Retired git settings (git dirs are always writable, docs/security-concerns.md B-ρ): gone from
# the catalog on both OSes, listed as retired for preset loading.
RETIRED_GIT_KEYS="AI_SANDBOX_ALLOW_GIT_CONFIG AI_SANDBOX_ALLOW_EXTERNAL_WORKTREES AI_SANDBOX_BLOCK_LINKED_GIT_DIRS"
for key in ${RETIRED_GIT_KEYS}; do
    assert_not_contains "${linux_catalog}" "${key}|" "${key} retired: not in the Linux catalog"
    assert_not_contains "${darwin_catalog}" "${key}|" "${key} retired: not in the macOS catalog"
    retired="$(source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash" >/dev/null 2>&1
        if _setting_is_retired "${key}"; then echo retired; else echo active; fi)"
    assert_eq "${retired}" retired "${key} is listed in _AI_RETIRED_SETTINGS"
done
retired="$(source "${REPO_ROOT}/bin/ai_wrapper_data/ai_wrapper_lib.bash" >/dev/null 2>&1
    if _setting_is_retired AI_SANDBOX_ALLOW_UNRESTRICTED_NET; then echo retired; else echo active; fi)"
assert_eq "${retired}" active "AI_SANDBOX_ALLOW_UNRESTRICTED_NET is an active setting"
assert_not_contains "$(grep '^AI_SANDBOX_EXTRA_RW_DIRS|' <<<"${linux_catalog}")" "git metadata protection" \
    "extra RW dirs help no longer claims a git metadata protection"

for key in "${CROSS_PLATFORM_KEYS[@]}"; do
    assert_contains "${linux_catalog}" "${key}|" "${key} shown on Linux"
    assert_contains "${darwin_catalog}" "${key}|" "${key} shown on macOS"
done

# Every menu entry says when to turn it on (#menu-use-cases), on both OSes
# and for the account rows the agent libs append. Help text never holds
# '|' (the field separator) or backticks.
_agent_catalog() {
    (
        if [[ "${1}" == "darwin" ]]; then
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Darwin; else command uname "$@"; fi; }
        else
            uname() { if [[ "${1:-}" == "-s" ]]; then echo Linux; else command uname "$@"; fi; }
        fi
        # shellcheck source=../bin/ai_agent_universal_wrapper.bash
        source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" >/dev/null 2>&1
        # shellcheck disable=SC1090
        source "${REPO_ROOT}/bin/ai_wrapper_data/${2}_wrapper_lib.bash" >/dev/null 2>&1
        printf '%s\n' "${_AI_SETTINGS_LIST[@]}"
    )
}
for os in linux darwin; do
    for agent in claude codex agy copilot; do
        while IFS= read -r row; do
            [[ -n "${row}" ]] || continue
            IFS='|' read -r name _ _ _ _ detail _ _ extra <<<"${row}"
            assert_contains "${detail}" "Use when:" "${os}/${agent}: ${name} help says when to use it"
            assert_eq "${extra:-}" "" "${os}/${agent}: ${name} has no stray '|' field"
            assert_not_contains "${row}" '`' "${os}/${agent}: ${name} has no backticks"
        done < <(_agent_catalog "${os}" "${agent}")
    done
done
_row() { grep "^${1}|" <<<"${2}"; }
row="$(_row AI_SANDBOX_ALLOW_TIOCSTI "${linux_catalog}")"
for needle in "libseccomp" "--add-seccomp-fd" "unsupported CPU architecture" "kernel rejects the filter" "dev.tty.legacy_tiocsti=0"; do
    assert_contains "${row}" "${needle}" "TIOCSTI use cases name: ${needle}"
done
for catalog in "${linux_catalog}" "${darwin_catalog}"; do
    row="$(_row AI_SANDBOX_ALLOW_UNRESTRICTED_NET "${catalog}")"
    for needle in "SSH git remotes" "rsync" "ignore http_proxy" "localhost dev servers" "Tailscale" "raw TCP/UDP" \
            "RFC 1918" "100.64.0.0/10" "169.254.169.254" "IPv6 ULA" "multicast"; do
        assert_contains "${row}" "${needle}" "unrestricted-net help names: ${needle}"
    done
done

# Cross-platform entries must not leak the other OS's wording into their
# DETAIL text (the exact bug fixed by hand earlier — regression-guard it).
assert_not_contains "${linux_catalog}" "~/Library" "no ~/Library wording anywhere in the Linux catalog"
assert_contains "${darwin_catalog}" "~/Library" "~/Library wording present in the macOS catalog"

# ---------------------------------------------------------------------------
# The menus as rendered on a terminal (through a pty): the s) Settings list
# shows each entry's help, and ?N opens the full help of entry N even when
# the list is longer than the screen.
echo "-- settings menu rendering (pty)"
if command -v python3 >/dev/null 2>&1; then
    MENU_TMP="$(mktemp -d)"
    trap 'rm -rf "${MENU_TMP}"' EXIT
    cat >"${MENU_TMP}/menu.bash" <<'MENU'
#!/bin/bash
export HOME="${1}/home"; export XDG_CONFIG_HOME="${HOME}/.config"; mkdir -p "${HOME}"
cd "${HOME}" || exit 1
source "${2}/bin/ai_agent_universal_wrapper.bash"
source "${2}/bin/ai_wrapper_data/codex_wrapper_lib.bash"
clear() { :; }
case "${3}" in
    header) show_header ;;
    settings) toggle_settings_menu; echo "MENU_RC=$?" ;;
esac
MENU
    cat >"${MENU_TMP}/drive.py" <<'PY'
import os, pty, select, sys, time
script, root, mode, *answers = sys.argv[1:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", script, os.path.dirname(script), root, mode])
buf, pos, deadline = b"", 0, time.time() + 60
steps = [(b"Choose setting", a.encode() + b"\n") if not a.startswith("ENTER") else (b"Press Enter", b"\n") for a in answers]
while time.time() < deadline:
    ready, _, _ = select.select([fd], [], [], 0.3)
    if ready:
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        buf += data
    if steps:
        hit = buf.find(steps[0][0], pos)
        if hit >= 0:
            pos = hit + len(steps[0][0])
            os.write(fd, steps[0][1])
            steps.pop(0)
os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
sys.stdout.write("\nSTEPS_LEFT=%d\n" % len(steps))
PY
    # Colour codes and CRs stripped, soft-wrapped lines joined (fold breaks
    # phrases across indented continuation lines).
    _menu() { python3 -I "${MENU_TMP}/drive.py" "${MENU_TMP}/menu.bash" "${REPO_ROOT}" "$@" 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '\r' | tr '\n' ' ' | tr -s ' '; }
    nested_idx="$( source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" >/dev/null 2>&1
        source "${REPO_ROOT}/bin/ai_wrapper_data/codex_wrapper_lib.bash" >/dev/null 2>&1
        i=1; for e in "${_AI_SETTINGS_LIST[@]}"; do [[ "${e%%|*}" == AI_SANDBOX_ALLOW_SETTINGS ]] && { echo "${i}"; break; }; i=$((i + 1)); done )"
    out="$(_menu header)"
    assert_contains "${out}" "All settings at default" "start menu: compact table when everything is default"
    assert_contains "${out}" "?N" "start menu: points to the per-setting help"
    out="$(_menu settings b)"
    assert_contains "${out}" "STEPS_LEFT=0" "settings menu: driven"
    assert_contains "${out}" "Use when: you edit the client's own settings" "settings menu: inline help shows the use cases"
    assert_contains "${out}" "?N" "settings menu: prompt offers ?N"
    out="$(_menu settings "?${nested_idx}" ENTER b)"
    assert_contains "${out}" "STEPS_LEFT=0" "?N: driven (details, Enter, back)"
    details="${out##*"?${nested_idx}"}"
    assert_contains "${details}" "AI_SANDBOX_ALLOW_SETTINGS" "?N: details name the variable"
    assert_contains "${details}" "Use when: you edit the client's own settings" "?N: details show the use cases after the prompt"
    assert_contains "${details}" "Press Enter" "?N: details wait for Enter"
    assert_contains "${out}" "MENU_RC=0" "?N: back returns normally"
    out="$(_menu settings "?999" ENTER b)"
    assert_contains "${out}" "Invalid choice" "?N out of range: rejected"
    assert_contains "${out}" "MENU_RC=0" "?N out of range: menu still returns"
    if [[ "$(uname -s)" == "Linux" ]]; then
        userns_idx="$( source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash" >/dev/null 2>&1
            source "${REPO_ROOT}/bin/ai_wrapper_data/codex_wrapper_lib.bash" >/dev/null 2>&1
            i=1; for e in "${_AI_SETTINGS_LIST[@]}"; do [[ "${e%%|*}" == AI_SANDBOX_ALLOW_NESTED_USERNS ]] && { echo "${i}"; break; }; i=$((i + 1)); done )"
        out="$(_menu settings "?${userns_idx}" ENTER b)"
        details="${out##*"?${userns_idx}"}"
        assert_contains "${details}" "Needs it: npx playwright test" "?N (Linux): nested-userns details show the examples"
    fi
else
    echo "  skip - settings menu rendering: python3 not installed"
fi

tests_summary_and_exit
