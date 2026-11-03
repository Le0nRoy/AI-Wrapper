#!/usr/bin/env bash
# Cursor wrapper retirement (#43): run_once_retire_cursor_wrapper.bash
# against a fake HOME. Covers both installed layouts (~/ai-wrapper/bin and
# legacy ~/bin), canonical vs modified/unmanaged copies, symlinks, legacy
# PATH shadowing, dry run, repeated runs, failures, and that Cursor user
# state and maintained wrappers stay intact. Never touches the real HOME.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SCRIPT="${REPO_ROOT}/run_once_retire_cursor_wrapper.bash"
FIXTURES="${REPO_ROOT}/tests/fixtures/cursor-retirement"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-wrapper-cursor-retire-test.XXXXXX")"
cleanup() {
    chmod -R u+w "${TEST_ROOT}" 2>/dev/null
    rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

ARTIFACTS=(
    cursor_agent_wrapper.bash
    ai_wrapper_data/cursor_wrapper_lib.bash
    ai_wrapper_data/cursor-help.md
)

# new_home NAME — fresh isolated fake HOME (with maintained siblings in
# both layouts) for one scenario; sets FAKE_HOME and exports HOME.
new_home() {
    FAKE_HOME="${TEST_ROOT}/${1}-$(od -An -N4 -tx4 /dev/urandom | tr -d ' ')"
    mkdir -p "${FAKE_HOME}"
    isolate_test_env "${FAKE_HOME}"
    local root
    for root in "${FAKE_HOME}/ai-wrapper/bin" "${FAKE_HOME}/bin"; do
        mkdir -p "${root}/ai_wrapper_data"
        echo "maintained" > "${root}/claude_wrapper.bash"
        chmod +x "${root}/claude_wrapper.bash"
        echo "maintained" > "${root}/ai_wrapper_data/ai_wrapper_lib.bash"
    done
}

# install_canonical ROOT — copy the last shipped artifacts into ROOT.
install_canonical() {
    local root="${1}" artifact
    for artifact in "${ARTIFACTS[@]}"; do
        mkdir -p "$(dirname "${root}/${artifact}")"
        cp "${FIXTURES}/${artifact}.orig" "${root}/${artifact}"
    done
    chmod +x "${root}/cursor_agent_wrapper.bash"
}

run_retire() {
    OUT="$(bash "${SCRIPT}" "$@" 2>&1)"
    RC=$?
}

assert_absent() {
    if [[ -e "${1}" || -L "${1}" ]]; then
        _test_report 0 "${2} (${1} still present)"
    else
        _test_report 1 "${2}"
    fi
}

assert_content() {
    assert_eq "$(cat "${1}" 2>/dev/null)" "${2}" "${3}"
}

# archived_copy REL — path of REL (relative to HOME) in the archive, if any.
archived_copy() {
    find "${FAKE_HOME}/ai-wrapper/.retired-cursor-wrapper" -path "*/${1}" 2>/dev/null | head -1
}

assert_maintained_intact() {
    local root
    for root in "${FAKE_HOME}/ai-wrapper/bin" "${FAKE_HOME}/bin"; do
        assert_content "${root}/claude_wrapper.bash" maintained "${1}: ${root#"${FAKE_HOME}"/} maintained wrapper intact"
        assert_content "${root}/ai_wrapper_data/ai_wrapper_lib.bash" maintained "${1}: ${root#"${FAKE_HOME}"/} shared data dir intact"
    done
}

echo "-- fresh install: nothing to retire"
new_home fresh
run_retire
assert_eq "${RC}" "0" "fresh: exits 0"
assert_absent "${FAKE_HOME}/.cursor" "fresh: no ~/.cursor created"
assert_absent "${FAKE_HOME}/ai-wrapper/.retired-cursor-wrapper" "fresh: no archive dir created"
assert_maintained_intact fresh

echo "-- secondary layout (~/ai-wrapper/bin): canonical artifacts removed"
new_home secondary
install_canonical "${FAKE_HOME}/ai-wrapper/bin"
echo mine > "${FAKE_HOME}/ai-wrapper/bin/ai_wrapper_data/cursor-notes.md"
run_retire
assert_eq "${RC}" "0" "secondary: exits 0"
for artifact in "${ARTIFACTS[@]}"; do
    assert_absent "${FAKE_HOME}/ai-wrapper/bin/${artifact}" "secondary: ${artifact} removed"
done
assert_contains "${OUT}" "Removed ${FAKE_HOME}/ai-wrapper/bin/cursor_agent_wrapper.bash" "secondary: removal logged"
assert_content "${FAKE_HOME}/ai-wrapper/bin/ai_wrapper_data/cursor-notes.md" mine "secondary: unrelated file in data dir untouched"
assert_absent "${FAKE_HOME}/ai-wrapper/.retired-cursor-wrapper" "secondary: canonical copies are not archived"
assert_maintained_intact secondary

echo "-- legacy layout (~/bin): canonical artifacts removed"
new_home legacy
install_canonical "${FAKE_HOME}/bin"
run_retire
assert_eq "${RC}" "0" "legacy: exits 0"
for artifact in "${ARTIFACTS[@]}"; do
    assert_absent "${FAKE_HOME}/bin/${artifact}" "legacy: ${artifact} removed"
done
assert_maintained_intact legacy
for client in ${TEST_AI_CLIENTS}; do
    [[ -x "${FAKE_HOME}/bin/${client}" ]] || _test_report 0 "legacy: ~/bin/${client} survives"
done

echo "-- modified and unmanaged copies are archived, not deleted"
new_home modified
install_canonical "${FAKE_HOME}/ai-wrapper/bin"
echo "# local tweak" >> "${FAKE_HOME}/ai-wrapper/bin/ai_wrapper_data/cursor_wrapper_lib.bash"
modified_content="$(cat "${FAKE_HOME}/ai-wrapper/bin/ai_wrapper_data/cursor_wrapper_lib.bash")"
printf '#!/bin/sh\necho my own launcher\n' > "${FAKE_HOME}/bin/cursor_agent_wrapper.bash"
chmod +x "${FAKE_HOME}/bin/cursor_agent_wrapper.bash"
run_retire
assert_eq "${RC}" "0" "modified: exits 0"
assert_absent "${FAKE_HOME}/ai-wrapper/bin/ai_wrapper_data/cursor_wrapper_lib.bash" "modified: lib leaves the data dir"
archived="$(archived_copy ai-wrapper/bin/ai_wrapper_data/cursor_wrapper_lib.bash)"
assert_eq "$(cat "${archived}" 2>/dev/null)" "${modified_content}" "modified: lib archived with the local change"
archived="$(archived_copy bin/cursor_agent_wrapper.bash)"
assert_contains "$(cat "${archived}" 2>/dev/null)" "my own launcher" "unmanaged: ~/bin launcher archived intact"
assert_eq "$([[ -x "${archived}" ]] && echo yes)" yes "unmanaged: archived copy keeps its mode"
assert_contains "${OUT}" "Archived ${FAKE_HOME}/bin/cursor_agent_wrapper.bash" "modified: archive logged"
assert_absent "${FAKE_HOME}/ai-wrapper/bin/cursor_agent_wrapper.bash" "modified: canonical sibling still removed"
assert_maintained_intact modified

echo "-- symlinks: the link is archived, its target is never touched"
new_home symlink
mkdir -p "${FAKE_HOME}/elsewhere"
cp "${FIXTURES}/cursor_agent_wrapper.bash.orig" "${FAKE_HOME}/elsewhere/target.bash"
target_before="$(cat "${FAKE_HOME}/elsewhere/target.bash")"
ln -s "${FAKE_HOME}/elsewhere/target.bash" "${FAKE_HOME}/bin/cursor_agent_wrapper.bash"
ln -s "${FAKE_HOME}/missing" "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md"
run_retire
assert_eq "${RC}" "0" "symlink: exits 0"
assert_absent "${FAKE_HOME}/bin/cursor_agent_wrapper.bash" "symlink: link removed from ~/bin"
assert_absent "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md" "symlink: dangling link removed"
assert_eq "$(cat "${FAKE_HOME}/elsewhere/target.bash")" "${target_before}" "symlink: target content untouched"
archived="$(archived_copy bin/cursor_agent_wrapper.bash)"
assert_eq "$(readlink "${archived}" 2>/dev/null)" "${FAKE_HOME}/elsewhere/target.bash" "symlink: link preserved in archive"

echo "-- both layouts: legacy ~/bin copy no longer shadows on PATH"
new_home shadow
install_canonical "${FAKE_HOME}/bin"
install_canonical "${FAKE_HOME}/ai-wrapper/bin"
PATH="${FAKE_HOME}/bin:${FAKE_HOME}/ai-wrapper/bin:${PATH}"
hash -r
assert_eq "$(command -v cursor_agent_wrapper.bash)" "${FAKE_HOME}/bin/cursor_agent_wrapper.bash" "shadow: fixture shadows before retirement"
run_retire
hash -r
assert_eq "${RC}" "0" "shadow: exits 0"
assert_eq "$(command -v cursor_agent_wrapper.bash)" "" "shadow: no Cursor launcher left on PATH"
rm "${FAKE_HOME}/bin/claude_wrapper.bash"
hash -r
assert_eq "$(command -v claude_wrapper.bash)" "${FAKE_HOME}/ai-wrapper/bin/claude_wrapper.bash" "shadow: maintained wrapper still resolves"

echo "-- repeated retirement is a safe no-op"
new_home rerun
install_canonical "${FAKE_HOME}/ai-wrapper/bin"
echo tweak >> "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md"
run_retire
assert_eq "${RC}" "0" "rerun: first run exits 0"
archive_listing="$(cd "${FAKE_HOME}/ai-wrapper/.retired-cursor-wrapper" && find . | sort)"
run_retire
assert_eq "${RC}" "0" "rerun: second run exits 0"
assert_not_contains "${OUT}" "Removed" "rerun: second run removes nothing"
assert_not_contains "${OUT}" "Archived" "rerun: second run archives nothing"
assert_eq "$(cd "${FAKE_HOME}/ai-wrapper/.retired-cursor-wrapper" && find . | sort)" "${archive_listing}" "rerun: archive unchanged"
assert_maintained_intact rerun

echo "-- dry run previews without changing anything"
new_home dry
install_canonical "${FAKE_HOME}/ai-wrapper/bin"
echo tweak >> "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md"
listing_before="$(cd "${FAKE_HOME}" && find . | sort)"
run_retire --dry
assert_eq "${RC}" "0" "dry: exits 0"
assert_contains "${OUT}" "Would remove ${FAKE_HOME}/ai-wrapper/bin/cursor_agent_wrapper.bash" "dry: removal previewed"
assert_contains "${OUT}" "Would archive ${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md" "dry: archive previewed"
assert_eq "$(cd "${FAKE_HOME}" && find . | sort)" "${listing_before}" "dry: filesystem unchanged"

echo "-- non-file entries at an artifact path are left alone"
new_home dir
mkdir -p "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md"
echo keep > "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md/inner"
run_retire
assert_eq "${RC}" "0" "dir: exits 0"
assert_contains "${OUT}" "WARNING" "dir: unexpected type reported"
assert_content "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md/inner" keep "dir: directory contents untouched"

echo "-- Cursor user state is preserved"
new_home state
install_canonical "${FAKE_HOME}/ai-wrapper/bin"
mkdir -p "${FAKE_HOME}/.cursor/skills/user-skill" "${FAKE_HOME}/.config/cursor" \
    "${FAKE_HOME}/.local/share/cursor-agent" "${FAKE_HOME}/.config/ai-wrapper/last-preset"
echo auth > "${FAKE_HOME}/.config/cursor/auth.json"
echo convo > "${FAKE_HOME}/.local/share/cursor-agent/chat.db"
echo skill > "${FAKE_HOME}/.cursor/skills/user-skill/SKILL.md"
echo preset > "${FAKE_HOME}/.config/ai-wrapper/last-preset/0123456789ab-cursor.env"
run_retire
assert_eq "${RC}" "0" "state: exits 0"
assert_content "${FAKE_HOME}/.config/cursor/auth.json" auth "state: ~/.config/cursor intact"
assert_content "${FAKE_HOME}/.local/share/cursor-agent/chat.db" convo "state: cursor-agent data intact"
assert_content "${FAKE_HOME}/.cursor/skills/user-skill/SKILL.md" skill "state: ~/.cursor user skills intact"
assert_content "${FAKE_HOME}/.config/ai-wrapper/last-preset/0123456789ab-cursor.env" preset "state: saved cursor preset intact"

echo "-- failures: exit 1, report, keep going, leave files in place"
new_home failure
if [[ "$(id -u)" == "0" ]]; then
    echo "  skip - running as root: permission failures cannot be simulated"
else
    install_canonical "${FAKE_HOME}/bin"
    install_canonical "${FAKE_HOME}/ai-wrapper/bin"
    chmod a-w "${FAKE_HOME}/bin/ai_wrapper_data"
    run_retire
    chmod u+w "${FAKE_HOME}/bin/ai_wrapper_data"
    assert_eq "${RC}" "1" "failure: unremovable file exits 1"
    assert_contains "${OUT}" "ERROR" "failure: error reported"
    assert_eq "$([[ -f "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md" ]] && echo yes)" yes "failure: file left in place"
    assert_absent "${FAKE_HOME}/ai-wrapper/bin/cursor_agent_wrapper.bash" "failure: other artifacts still processed"
    run_retire
    assert_eq "${RC}" "0" "failure: retry after fixing permissions succeeds"
    assert_absent "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md" "failure: retry removes the leftover"
fi

new_home obstructed
echo tweak >> "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md"
touch "${FAKE_HOME}/ai-wrapper/.retired-cursor-wrapper"
run_retire
assert_eq "${RC}" "1" "obstructed archive: exits 1"
assert_contains "${OUT}" "ERROR" "obstructed archive: error reported"
assert_content "${FAKE_HOME}/bin/ai_wrapper_data/cursor-help.md" tweak "obstructed archive: modified file kept in place"

new_home badarg
run_retire --bogus
assert_eq "${RC}" "2" "unknown argument exits 2"

tests_summary_and_exit
