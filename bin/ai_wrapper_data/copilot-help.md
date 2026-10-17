# GitHub Copilot CLI Wrapper

Usage:

  copilot_wrapper [args...]

This wrapper runs GitHub Copilot inside the same sandbox model used by the
other AI wrappers. It binds the CLI runtime directory (`~/.copilot`) and any
present GitHub Copilot config dirs so the sandbox can use the same session and
settings without exposing unrelated system paths.

Typical use:

  copilot_wrapper --prompt "Summarize the current repo"
  copilot_wrapper --interactive "Review the failing test output"

The wrapper also supports the shared orchestrate / resume menu flow from the
ai-wrapper runtime.
