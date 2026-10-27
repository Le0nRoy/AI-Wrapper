#!/usr/bin/env bash
# Verify every wrapped client and existing named profile receives each shared
# skill, that retired skills from a previous deployment leave discovery roots
# on upgrade, and that managed copies refresh while unmanaged ones survive.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAKE_HOME="$(mktemp -d "${TMPDIR:-${HOME}}/ai-wrapper-skills-test.XXXXXX")"
trap 'rm -rf "${FAKE_HOME}"' EXIT

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

skills=(caveman orchestrator-mode ponytail session-retro tortuga)
destinations=(
    ".claude/skills"
    ".codex/skills"
    ".gemini/config/skills"
    ".cursor/skills"
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
[[ -e "${FAKE_HOME}/.cursor/skills/writing-plans" ]] && fail "retired skill copied to a new client"
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
