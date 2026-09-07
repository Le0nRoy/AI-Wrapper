#!/bin/bash
# Deploys ~/ai-wrapper/.agents/skills into ~/.claude/skills (via
# setup_skills.bash) so Claude Code discovers agent skills. Runs on every
# chezmoi apply.

set -euo pipefail

if [[ -x "${HOME}/ai-wrapper/bin/setup_skills.bash" ]]; then
    "${HOME}/ai-wrapper/bin/setup_skills.bash"
else
    echo "WARNING: ${HOME}/ai-wrapper/bin/setup_skills.bash not found or not executable — skills not synced." >&2
fi
