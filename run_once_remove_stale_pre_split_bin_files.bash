#!/bin/bash
# Removes ai-wrapper's own files left behind directly under ~/bin/ from
# before ai-wrapper became a separate chezmoi source deploying to
# ~/ai-wrapper/bin/ instead. Chezmoi never deletes files once their source
# entry moves, so these were sitting there stale and untouched — and since
# ~/bin comes before ~/ai-wrapper/bin on PATH, they silently shadowed the
# real, current wrapper scripts (e.g. running `claude_wrapper.bash` picked
# up a build that predates the account-selection menu's removal in 45da427).

set -euo pipefail

STALE_FILES=(
    ai_agent_universal_wrapper.bash
    claude_wrapper.bash
    codex_wrapper.bash
    cursor_agent_wrapper.bash
    setup_ai_kube_access.bash
    setup_kind.bash
    setup_skills.bash
)

for name in "${STALE_FILES[@]}"; do
    path="${HOME}/bin/${name}"
    if [[ -e "${path}" ]]; then
        rm -f "${path}"
        echo "Removed stale ${path}"
    fi
done

if [[ -d "${HOME}/bin/ai_wrapper_data" ]]; then
    rm -rf "${HOME}/bin/ai_wrapper_data"
    echo "Removed stale ${HOME}/bin/ai_wrapper_data"
fi
