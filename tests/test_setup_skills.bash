#!/usr/bin/env bash
# Verify every wrapped client and existing named profile receives each shared
# skill, that retired skills from a previous deployment leave discovery roots
# on upgrade, that managed copies refresh while unmanaged ones survive, and
# that copy failures keep old content, fail the run, and recover on retry.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"
FAKE_HOME="$(_safe_mktemp_d "${TMPDIR:-/tmp}/ai-wrapper-skills-test.XXXXXX")" || exit 1
trap '_safe_rm_rf "${FAKE_HOME}"' EXIT
isolate_test_env "${FAKE_HOME}"

mkdir -p \
    "${FAKE_HOME}/ai-wrapper/.agents" \
    "${FAKE_HOME}/.claude-work" \
    "${FAKE_HOME}/.codex-work" \
    "${FAKE_HOME}/.gemini-work"
cp -a "${REPO_ROOT}/dot_agents/skills" "${FAKE_HOME}/ai-wrapper/.agents/skills"

fail() {
    echo "FAIL: $*"
    exit 1
}

# Upgrade fixture: a retired skill left behind by chezmoi in the source root,
# a managed client copy of it, an unmanaged copy with the same name, and an
# unrelated user skill.
SRC="${FAKE_HOME}/ai-wrapper/.agents/skills"
ARCHIVE="${FAKE_HOME}/ai-wrapper/.retired-skills"
mkdir -p "${SRC}/writing-plans" \
    "${FAKE_HOME}/.claude/skills/writing-plans" \
    "${FAKE_HOME}/.codex/skills/writing-plans" \
    "${FAKE_HOME}/.claude/skills/user-skill"
echo old > "${SRC}/writing-plans/SKILL.md"
echo old > "${FAKE_HOME}/.claude/skills/writing-plans/SKILL.md"
printf '%s\n' "${SRC}/writing-plans" > "${FAKE_HOME}/.claude/skills/writing-plans/.setup_skills_managed"
echo mine > "${FAKE_HOME}/.codex/skills/writing-plans/SKILL.md"
echo mine > "${FAKE_HOME}/.claude/skills/user-skill/SKILL.md"

if ! HOME="${FAKE_HOME}" bash "${REPO_ROOT}/bin/executable_setup_skills.bash" >/dev/null; then
    echo "FAIL: setup_skills.bash returned nonzero"
    exit 1
fi

skills=(caveman orchestrator-mode ponytail retro-aggregate session-retro skill-sync tortuga)
destinations=(
    ".claude/skills"
    ".codex/skills"
    ".gemini/config/skills"
    ".copilot/skills"
    ".claude-work/skills"
    ".codex-work/skills"
    ".gemini-work/config/skills"
)

checks=0
for destination in "${destinations[@]}"; do
    for skill in "${skills[@]}"; do
        skill_dir="${FAKE_HOME}/${destination}/${skill}"
        if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
            echo "FAIL: missing ${skill_dir}/SKILL.md"
            exit 1
        fi
        if [[ ! -f "${skill_dir}/.setup_skills_managed" ]]; then
            echo "FAIL: missing managed marker in ${skill_dir}"
            exit 1
        fi
        checks=$((checks + 1))
    done
done

[[ -e "${SRC}/writing-plans" ]] && fail "retired skill still in source discovery root"
[[ -f "${ARCHIVE}/source/writing-plans/SKILL.md" ]] || fail "retired source skill not archived"
[[ -e "${FAKE_HOME}/.claude/skills/writing-plans" ]] && fail "retired managed copy still discoverable"
[[ -f "${ARCHIVE}/.claude_skills/writing-plans/SKILL.md" ]] || fail "retired managed copy not archived"
[[ "$(cat "${FAKE_HOME}/.codex/skills/writing-plans/SKILL.md")" == mine ]] || fail "unmanaged same-name skill touched"
[[ "$(cat "${FAKE_HOME}/.claude/skills/user-skill/SKILL.md")" == mine ]] || fail "unrelated user skill touched"
# Cursor support is retired (#43): a fresh setup must not create ~/.cursor.
[[ -e "${FAKE_HOME}/.cursor" ]] && fail "setup created retired Cursor client directory"
checks=$((checks + 7))

# Obstructed archive: a regular file where the source bucket should be makes
# retirement fail; setup must exit nonzero, keep the source intact, and not
# count the failed move as retired.
mkdir -p "${SRC}/executing-plans"
echo old > "${SRC}/executing-plans/SKILL.md"
mv "${ARCHIVE}/source" "${ARCHIVE}/source.saved"
touch "${ARCHIVE}/source"
if output="$(HOME="${FAKE_HOME}" bash "${REPO_ROOT}/bin/executable_setup_skills.bash" 2>&1)"; then
    fail "setup succeeded despite an obstructed archive"
fi
[[ "$(cat "${SRC}/executing-plans/SKILL.md")" == old ]] || fail "retired source lost after failed archive"
[[ "${output}" == *"Retired: 0"* ]] || fail "failed archive counted as retired"
rm -f "${ARCHIVE}/source"
mv "${ARCHIVE}/source.saved" "${ARCHIVE}/source"
HOME="${FAKE_HOME}" bash "${REPO_ROOT}/bin/executable_setup_skills.bash" >/dev/null || fail "retry after clearing obstruction failed"
[[ -e "${SRC}/executing-plans" ]] && fail "retired source not archived on retry"
checks=$((checks + 4))

# Managed refresh: a source change reaches every managed copy on rerun.
echo refreshed >> "${SRC}/caveman/SKILL.md"
HOME="${FAKE_HOME}" bash "${REPO_ROOT}/bin/executable_setup_skills.bash" >/dev/null || fail "rerun returned nonzero"
for destination in "${destinations[@]}"; do
    cmp -s "${SRC}/caveman/SKILL.md" "${FAKE_HOME}/${destination}/caveman/SKILL.md" \
        || fail "managed copy not refreshed in ${destination}"
    checks=$((checks + 1))
done
[[ "$(cat "${FAKE_HOME}/.codex/skills/writing-plans/SKILL.md")" == mine ]] || fail "unmanaged skill touched on rerun"

# --- Copy safety (#49) ------------------------------------------------------
# Each case gets its own fake HOME under FAKE_HOME so injected failures
# never leak into the fixture above. PATH-only tool dirs make the rsync and
# cp-fallback branches deterministic whether or not the host has rsync.
SETUP="${REPO_ROOT}/bin/executable_setup_skills.bash"
SETUP_TOOLS=(env bash mkdir cp rm mv cat basename dirname date readlink)

# new_case <name> — print a fresh HOME holding only the shared skill source.
new_case() {
    local case_home="${FAKE_HOME}/cases/$1"
    mkdir -p "${case_home}/ai-wrapper/.agents"
    cp -a "${REPO_ROOT}/dot_agents/skills" "${case_home}/ai-wrapper/.agents/skills"
    printf '%s\n' "${case_home}"
}

# tool_dir <dir> <rsync|norsync> — PATH dir with the coreutils setup uses.
# "rsync" adds a shim that stages like `rsync -a src/ dst/` (real rsync when
# the host has one), so the rsync branch runs even on hosts without it.
tool_dir() {
    local dir="$1" mode="$2" tool real_rsync
    mkdir -p "${dir}"
    for tool in "${SETUP_TOOLS[@]}"; do
        ln -sf "$(command -v "${tool}")" "${dir}/${tool}"
    done
    [[ "${mode}" == rsync ]] || return 0
    real_rsync="$(command -v rsync 2>/dev/null || true)"
    if [[ -n "${real_rsync}" ]]; then
        ln -sf "${real_rsync}" "${dir}/rsync"
        return 0
    fi
    cat >"${dir}/rsync" <<'SHIM'
#!/bin/sh
# Minimal stand-in for `rsync -a SRC/ DST/`.
for arg in "$@"; do case "${arg}" in -*) ;; *) set -- "$@" "${arg}" ;; esac; done
eval "dst=\${$#}"; eval "src=\${$(($# - 1))}"
mkdir -p "${dst}" && cp -a "${src}." "${dst}"
SHIM
    chmod +x "${dir}/rsync"
}

# fail_tool <dir> <tool> [pattern] — replace <tool> with a stub that fails
# when any argument matches the glob <pattern> (default: always) and runs
# the real tool otherwise.
fail_tool() {
    local dir="$1" tool="$2" pattern="${3:-*}" real
    real="$(readlink "${dir}/${tool}" 2>/dev/null || command -v "${tool}")"
    rm -f "${dir}/${tool}"
    cat >"${dir}/${tool}" <<STUB
#!/bin/sh
for arg in "\$@"; do
    case "\${arg}" in ${pattern}) echo "injected ${tool} failure" >&2; exit 1 ;; esac
done
exec "${real}" "\$@"
STUB
    chmod +x "${dir}/${tool}"
}

# run_setup <home> <tooldir> [args...] — run setup; output in setup_out.
run_setup() {
    local case_home="$1" tools="$2"
    shift 2
    setup_out="$(HOME="${case_home}" PATH="${tools}" "${BASH}" "${SETUP}" "$@" 2>&1)"
}

# snapshot <dir> — paths, types, link targets and file checksums.
snapshot() {
    (cd "$1" && find . -print | LC_ALL=C sort \
        && find . -type f -exec cksum {} + | LC_ALL=C sort \
        && find . -type l -exec readlink {} \; | LC_ALL=C sort)
}

# no_leftovers <skills_dir> — staging/backup siblings must not linger.
no_leftovers() {
    local leftovers
    leftovers="$(cd "$1" && find . -maxdepth 1 -name '.*.setup-*' -print)"
    [[ -z "${leftovers}" ]] || fail "staging leftovers in $1: ${leftovers}"
}

for mode in rsync norsync; do
    tools="${FAKE_HOME}/tools-${mode}"
    tool_dir "${tools}" "${mode}"

    # Dry run: every branch (stale top-level symlink, legacy symlink,
    # managed refresh, --force replacement, retirement, missing destination
    # roots) must leave the filesystem untouched.
    home="$(new_case "dry-${mode}")"
    src="${home}/ai-wrapper/.agents/skills"
    mkdir -p "${home}/.claude-work" "${home}/.codex/skills/caveman" "${home}/elsewhere" \
        "${home}/.copilot/skills/ponytail" "${src}/writing-plans"
    ln -s "${home}/elsewhere" "${home}/.gemini"
    ln -s "${src}/tortuga" "${home}/.codex/skills/tortuga"
    printf '%s\n' "${src}/caveman" > "${home}/.codex/skills/caveman/.setup_skills_managed"
    echo mine > "${home}/.copilot/skills/ponytail/SKILL.md"
    echo old > "${src}/writing-plans/SKILL.md"
    before="$(snapshot "${home}")"
    run_setup "${home}" "${tools}" --dry --force || fail "[${mode}] dry run returned nonzero: ${setup_out}"
    [[ "$(snapshot "${home}")" == "${before}" ]] || fail "[${mode}] dry run changed the filesystem"
    [[ -e "${home}/.claude/skills" ]] && fail "[${mode}] dry run created a destination dir"
    [[ "${setup_out}" == *"no changes made"* ]] || fail "[${mode}] dry run summary missing"
    checks=$((checks + 3))

    # mkdir failure: a regular file blocks one destination root. Other
    # roots still deploy; the run fails and the blocked root counts nothing.
    home="$(new_case "mkdir-${mode}")"
    mkdir -p "${home}/.copilot"
    echo mine > "${home}/.copilot/skills"
    run_setup "${home}" "${tools}" && fail "[${mode}] setup succeeded despite blocked mkdir"
    [[ "$(cat "${home}/.copilot/skills")" == mine ]] || fail "[${mode}] blocking file touched"
    [[ "${setup_out}" == *"Copied: $(( 3 * ${#skills[@]} )),"* ]] || fail "[${mode}] blocked root counted: ${setup_out}"
    [[ -f "${home}/.claude/skills/caveman/.setup_skills_managed" ]] || fail "[${mode}] healthy root not deployed"
    rm -f "${home}/.copilot/skills"
    run_setup "${home}" "${tools}" || fail "[${mode}] retry after mkdir failure: ${setup_out}"
    [[ -f "${home}/.copilot/skills/caveman/.setup_skills_managed" ]] || fail "[${mode}] retry did not deploy"
    checks=$((checks + 5))

    # Copy-tool failure while refreshing a managed copy: old content and
    # marker survive, nothing counts as updated, retry refreshes it.
    copier="cp"
    [[ "${mode}" == rsync ]] && copier="rsync"
    home="$(new_case "copy-${mode}")"
    run_setup "${home}" "${tools}" || fail "[${mode}] initial deploy: ${setup_out}"
    echo stale > "${home}/.claude/skills/caveman/SKILL.md"
    broken="${FAKE_HOME}/tools-copy-${mode}"
    cp -R "${tools}" "${broken}"
    fail_tool "${broken}" "${copier}"
    run_setup "${home}" "${broken}" && fail "[${mode}] setup succeeded despite ${copier} failure"
    [[ "$(cat "${home}/.claude/skills/caveman/SKILL.md")" == stale ]] || fail "[${mode}] old content lost on ${copier} failure"
    [[ -f "${home}/.claude/skills/caveman/.setup_skills_managed" ]] || fail "[${mode}] marker lost on ${copier} failure"
    [[ "${setup_out}" == *"Updated: 0,"* ]] || fail "[${mode}] failed ${copier} counted: ${setup_out}"
    no_leftovers "${home}/.claude/skills"
    run_setup "${home}" "${tools}" || fail "[${mode}] retry after ${copier} failure: ${setup_out}"
    cmp -s "${home}/ai-wrapper/.agents/skills/caveman/SKILL.md" "${home}/.claude/skills/caveman/SKILL.md" \
        || fail "[${mode}] retry did not refresh"
    checks=$((checks + 6))

    # Replacement failure: moving the staged copy into place fails; the
    # previous copy is rolled back. --force on an unmanaged dir must also
    # keep the user content when replacement fails.
    home="$(new_case "replace-${mode}")"
    run_setup "${home}" "${tools}" || fail "[${mode}] initial deploy: ${setup_out}"
    echo stale > "${home}/.claude/skills/caveman/SKILL.md"
    mkdir -p "${home}/.codex/skills/user-only"
    rm -rf "${home}/.codex/skills/ponytail"
    mkdir -p "${home}/.codex/skills/ponytail"
    echo mine > "${home}/.codex/skills/ponytail/SKILL.md"
    broken="${FAKE_HOME}/tools-replace-${mode}"
    cp -R "${tools}" "${broken}"
    fail_tool "${broken}" mv '*.setup-new.*'
    run_setup "${home}" "${broken}" --force && fail "[${mode}] setup succeeded despite failed replacement"
    [[ "$(cat "${home}/.claude/skills/caveman/SKILL.md")" == stale ]] || fail "[${mode}] managed copy not rolled back"
    [[ "$(cat "${home}/.codex/skills/ponytail/SKILL.md")" == mine ]] || fail "[${mode}] unmanaged dir lost on failed --force"
    [[ "${setup_out}" == *"Updated: 0, Replaced: 0,"* ]] || fail "[${mode}] failed replacement counted: ${setup_out}"
    no_leftovers "${home}/.claude/skills"
    no_leftovers "${home}/.codex/skills"
    run_setup "${home}" "${tools}" --force || fail "[${mode}] retry after replacement failure: ${setup_out}"
    [[ "$(cat "${home}/.codex/skills/ponytail/.setup_skills_managed")" == "${home}/ai-wrapper/.agents/skills/ponytail" ]] \
        || fail "[${mode}] retry did not replace"
    checks=$((checks + 6))

    # Marker failure: a source entry named like the marker (a directory)
    # makes the marker write fail. Nothing is claimed as managed.
    home="$(new_case "marker-${mode}")"
    mkdir -p "${home}/ai-wrapper/.agents/skills/caveman/.setup_skills_managed" "${home}/.claude/skills"
    run_setup "${home}" "${tools}" && fail "[${mode}] setup succeeded despite marker failure"
    [[ -e "${home}/.claude/skills/caveman" ]] && fail "[${mode}] unmarked copy left in place"
    [[ "${setup_out}" == *"Copied: $(( 4 * (${#skills[@]} - 1) )),"* ]] || fail "[${mode}] failed marker counted: ${setup_out}"
    no_leftovers "${home}/.claude/skills"
    rmdir "${home}/ai-wrapper/.agents/skills/caveman/.setup_skills_managed"
    run_setup "${home}" "${tools}" || fail "[${mode}] retry after marker failure: ${setup_out}"
    [[ -f "${home}/.claude/skills/caveman/.setup_skills_managed" ]] || fail "[${mode}] retry did not mark"
    checks=$((checks + 5))
done

# Relative links: every local Markdown link in a shared skill must resolve to a
# committed file, and that companion file must reach each managed copy.
link_re='\]\(([^)#[:space:]]+)'
while IFS= read -r -d '' doc; do
    rel_doc="${doc#"${REPO_ROOT}/dot_agents/skills/"}"
    while IFS= read -r target; do
        [[ "${target}" =~ ^[a-z][a-z0-9+.-]*: ]] && continue
        [[ -e "$(dirname "${doc}")/${target}" ]] \
            || fail "${rel_doc} links to missing ${target}"
        for destination in "${destinations[@]}"; do
            [[ -e "${FAKE_HOME}/${destination}/$(dirname "${rel_doc}")/${target}" ]] \
                || fail "${destination}/${rel_doc} link target ${target} not deployed"
        done
        checks=$((checks + 1))
    done < <(grep -oE "${link_re}" "${doc}" | sed -E 's/^\]\(//')
done < <(find "${REPO_ROOT}/dot_agents/skills" -name '*.md' -print0)

echo "${checks} skill destination checks passed"
