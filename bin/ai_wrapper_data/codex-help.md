# Codex Wrapper Help

This wrapper provides an interactive menu for starting Codex CLI sessions with
optional orchestration workflows.

## Menu Options

### 1) Start orchestration
Launches Codex with the `orchestrator-mode` skill pre-loaded as a system prompt.
Use for multi-phase development workflows: plan → implement → test → review → merge.

### 2) Start bulletproof
Launches Codex with the `bulletproof` skill pre-loaded as a system prompt.
Use for the 12-stage adaptive development workflow (research → spec → plan →
implement → verify → review → deploy).

### 3) Start new conversation
Launches a plain Codex session with no additional system prompt.

### 4) Resume from list
Resumes a previous Codex session (shows a session picker).

### h) Help
Shows this help document.

## Note on Orchestration Mode

System prompt injection requires `AI_SYSTEM_PROMPT_FLAG` to be set in
`codex_wrapper_lib.bash`. Update it once the correct Codex CLI flag is known.
