#!/bin/bash
# Removes the stale ~/bin/claude_wrapper_data/ directory left over from before
# the rename to ai_wrapper_data/. Chezmoi never deletes unmanaged files, so
# this one-time script cleans it up on the next `chezmoi apply`.

OLD_DIR="${HOME}/bin/claude_wrapper_data"
[[ -d "${OLD_DIR}" ]] && rm -rf "${OLD_DIR}"
