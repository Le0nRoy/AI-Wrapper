#!/usr/bin/env bash
# Verify every wrapped client and existing named profile receives each shared skill.

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

echo "${checks} skill destination checks passed"
