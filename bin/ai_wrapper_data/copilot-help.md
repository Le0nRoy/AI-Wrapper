# GitHub Copilot CLI Wrapper

Usage:

  copilot_wrapper [args...]

This wrapper runs GitHub Copilot inside the same sandbox model used by the
other AI wrappers. It binds the CLI runtime directory (`~/.copilot`) and any
present GitHub Copilot config dirs so the sandbox can use the same session and
settings without exposing unrelated system paths.

The wrapper auto-approves tools, paths, and URLs inside the OS sandbox, disables
Copilot's assisted-approval judge, and enables workspace trust so permission
and trust prompts do not interrupt the session. Copilot may load project-local
skills, plugins, MCP servers, and hooks as trusted configuration; these still
run inside the OS sandbox.

Typical use:

  copilot_wrapper --prompt "Summarize the current repo"
  copilot_wrapper --interactive "Review the failing test output"

The wrapper also supports the shared orchestrate / resume menu flow from the
ai-wrapper runtime. Choosing "Resume from list" opens Copilot's session picker
via `copilot --resume`.
