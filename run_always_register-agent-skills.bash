#!/bin/bash
# Deploys ~/.agents/skills into ~/.claude/skills (via setup_skills.bash) so
# Claude Code discovers agent skills. Runs on every chezmoi apply.

set -euo pipefail

if [[ -x "${HOME}/bin/setup_skills.bash" ]]; then
    "${HOME}/bin/setup_skills.bash"
else
    echo "WARNING: ${HOME}/bin/setup_skills.bash not found or not executable — skills not synced." >&2
fi

# Ensure bulletproof submodule is initialized after a fresh clone
CHEZMOI_SOURCE_DIR="${CHEZMOI_SOURCE_DIR:-${HOME}/.local/share/ai-wrapper}"
if [[ -f "${CHEZMOI_SOURCE_DIR}/.gitmodules" ]]; then
    git -C "${CHEZMOI_SOURCE_DIR}" submodule update --init --recursive --quiet 2>/dev/null || true
fi
