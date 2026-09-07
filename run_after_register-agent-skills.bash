#!/bin/bash
# Deploys ~/ai-wrapper/.agents/skills into ~/.claude/skills (via
# setup_skills.bash) so Claude Code discovers agent skills. Runs on every
# chezmoi apply.
#
# Must be an `after_` script: scripts without before_/after_ interleave with
# file application in plain ASCII order of their (attribute-stripped) target
# name, and "always_register-agent-skills.bash" sorted before "bin/..." — so
# on a from-scratch apply this ran before bin/setup_skills.bash existed.
# `after_` scripts run in their own phase, strictly after every file,
# directory and symlink has been applied, so bin/setup_skills.bash is
# guaranteed to already be in place here regardless of name.

set -euo pipefail

if [[ -x "${HOME}/ai-wrapper/bin/setup_skills.bash" ]]; then
    "${HOME}/ai-wrapper/bin/setup_skills.bash"
else
    echo "WARNING: ${HOME}/ai-wrapper/bin/setup_skills.bash not found or not executable — skills not synced." >&2
fi
