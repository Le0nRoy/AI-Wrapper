# Cursor Agent Wrapper Help

This wrapper provides an interactive menu for starting Cursor Agent CLI sessions with
optional orchestration workflows.

## Menu Options

### 1) Start orchestration
Launches Cursor Agent with the `orchestrator-mode` skill pre-loaded as a system prompt.
Use for multi-phase development workflows: plan → implement → test → review → merge.

### 2) Start new conversation
Launches a plain Cursor Agent session with no additional system prompt.

### 3) Resume from list
Resumes a previous Cursor Agent session (shows a session picker).

### s) Settings
Opens the toggle-and-edit sub-menu for the `AI_SANDBOX_*` sandbox flags
(no "Account" section — account switching is Claude-only). Choices persist
per-workdir via the same auto-save/auto-load mechanism as `c) Clear` below.

### c) Clear saved settings for this workdir
Removes the auto-saved settings preset for the current directory, resetting
the menu to catalog defaults on the next open.

### h) Help
Shows this help document.

## Note on Orchestration Mode

System prompt injection requires `AI_SYSTEM_PROMPT_FLAG` to be set in
`cursor_wrapper_lib.bash`. Update it once the correct cursor-agent CLI flag is known.
