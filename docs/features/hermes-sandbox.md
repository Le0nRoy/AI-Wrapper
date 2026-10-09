# Hermes Sandbox

Hermes has a dedicated Linux bubblewrap policy alongside the existing Claude, Codex, and Cursor wrappers. The implementation targets upstream commit `19cb1cbfedeafaca099be6ff0141a28a6c516c0f`; incompatible or modified tracked runtime sources are refused before upstream imports.

This document describes the current source contracts. It does not certify deployment or a complete live session. Full runtime preparation, packaged Desktop launch, provider login, cross-interface session handoff, and real systemd worker recovery still require end-to-end acceptance checks. DesktopPTY, preview, shared state, and cron/Kanban execution remain core acceptance requirements.

## Entry Points and Deployment

| Source | Parent-repository installation |
|---|---|
| `bin/executable_hermes_wrapper.bash` | `~/ai-wrapper/bin/hermes_wrapper.bash` |
| `bin/executable_setup_hermes.bash` | `~/ai-wrapper/bin/setup_hermes.bash` |
| `bin/ai_wrapper_data/hermes_sandbox/` | `~/ai-wrapper/bin/ai_wrapper_data/hermes_sandbox/` |

The parent `chezmoi-dotfiles` hook applies this repository with `--destination "$HOME/ai-wrapper"` and a separate persistent-state file. A standalone deployment to the home directory uses `~/bin/` instead. The systemd units supplied by the parent expect the `~/ai-wrapper/bin/` paths.

Review `chezmoi diff` before any `chezmoi apply`. Applying the sources deploys launchers and unit files; runtime preparation, profile registration, credential setup, and service startup are separate actions. No service has been started or runtime installed as part of this documentation change.

## Prerequisites

- Linux with working unprivileged user/PID namespaces and bubblewrap. Preparation supports `x86_64` and `aarch64`.
- Host `/usr/bin/git`, `/usr/bin/bwrap`, and `/usr/bin/python3`. The current preparer requires system Python `3.14.7`, matching the reviewed upstream package lock; it refuses a transient managed interpreter.
- Native Python/Node/PTY package preparation may require `g++`, `make`, `pkg-config`, `cmake`, `cargo`, and `rustc` (Arch `base-devel`, `cmake`, and `rust`), plus dependency-specific system libraries. These tools are used inside the preparation namespace; host build hooks are not executed.
- `systemd-run` and a working systemd user manager for execution budgets. Interactive CLI, backend, gateway, and private Desktop server launches require a scope in `hermes.slice`; failure to establish it does not fall back to unbudgeted execution.
- An existing, approved workspace and private runtime/state parent directories. Use canonical absolute paths without symlink components.
- Desktop additionally needs Xpra, Xvfb, xauth, fonts, browser/Electron shared libraries, and the packaged Hermes Desktop. The launcher uses `desktop --skip-build`; it does not build Desktop on the host or install host packages.
- Provider and messaging credentials configured for the selected private profile when those integrations are used.

Before registration, inspect host prerequisites without installing anything:

```bash
python3 -I ~/ai-wrapper/bin/ai_wrapper_data/hermes_sandbox/provision.py doctor
python3 -I ~/ai-wrapper/bin/ai_wrapper_data/hermes_sandbox/provision.py doctor --desktop
python3 -I ~/ai-wrapper/bin/ai_wrapper_data/hermes_sandbox/frontends.py dependencies
```

The provisioning doctor reports package suggestions and availability; the frontend dependency check also includes xauth. These checks do not prove namespace creation or Desktop execution. Xpra/Xvfb were unavailable in the development environment, so live Desktop validation remains outstanding.

## Prepare or Register a Profile

The default profile is `default`. Names match `[a-z0-9][a-z0-9_-]{0,63}`: one to 64 lowercase letters, digits, underscores, or hyphens, starting with a letter or digit.

For a new pinned runtime, first create private parent directories and select an existing workspace:

```bash
mkdir -p -m 700 "$HOME/.local/share/hermes-runtimes" "$HOME/.local/share/hermes-sandbox/profiles"
~/ai-wrapper/bin/setup_hermes.bash prepare --profile work \
    --runtime "$HOME/.local/share/hermes-runtimes/19cb1cb" \
    --workspace "$HOME/projects/my-project" --dry-run
```

The runtime destination must not exist. Parent directories for the runtime and new state must already be owned and mode `0700`; existing directories are checked, not silently repaired. `--dry-run` validates the request and prints JSON without fetching, installing, registering, or starting services.

To prepare and then register explicitly:

```bash
~/ai-wrapper/bin/setup_hermes.bash prepare --profile work \
    --runtime "$HOME/.local/share/hermes-runtimes/19cb1cb" \
    --workspace "$HOME/projects/my-project"
```

Preparation fetches the fixed official revision with Git hooks and credential helpers disabled, verifies reviewed Python/Node/package-lock input digests, and runs dependency installation inside a staging bubblewrap namespace. It bootstraps pinned uv and uses the frozen Python lock, including its source artifact hashes and lock-derived build constraints. Source builds are allowed only for the reviewed `SOURCE_BUILDS` package allowlist; other locked packages receive `--no-build-package`. Build hooks run inside preparation, never through a host fallback. Preparation also seeds the upstream PM-pinned private browser. The preparer builds the packaged Electron Desktop and web UI inside a separate confined build phase, applies pinned attach-only compatibility overlays, validates the compiled artifacts, and restores tracked upstream source before publication. Native Node build hooks likewise run only within that preparation sandbox.

`--dry-run` and `hermes-provision.json` expose the selected extras and exclusions. The selected extras cover provider, messaging, web, browser, document, media/voice, PTY, and cron dependencies, including KittenTTS, DingTalk, Silk, and Matrix; dependency installation alone does not authorize remote terminal backends or configure accounts. Source-only dependencies remain core provisioning, not deferred features. MCP/computer-use extras and Android-only aliases are excluded intentionally. NeuTTS has an upstream Python 3.14 incompatibility constraint. The source-build gates are covered by fixture tests, not a claim that all these dependencies have been installed or exercised live.

Successful preparation validates the final interpreter paths and publishes a new runtime without overwriting an existing destination. The manifest records frontend artifacts/overlay hashes and the read-only PM seed plus intended private `state/tools` destination. The setup shell then registers the profile; it does not copy or install the tool seed on the host. Seed activation is implemented at the first confined launch, as described below. Full live dependency installation, GUI execution, and browser/provider workflows remain acceptance checks; neither a build report nor a registration alone proves them.

For an existing reviewed runtime produced by preparation, registration alone is available:

```bash
~/ai-wrapper/bin/setup_hermes.bash init --profile work \
    --runtime "$HOME/.local/share/hermes-runtimes/19cb1cb" \
    --workspace "$HOME/projects/my-project"
~/ai-wrapper/bin/setup_hermes.bash doctor --profile work
~/ai-wrapper/bin/hermes_wrapper.bash --profile work doctor
```

`register` is an alias for `init`; omitting the setup action also selects `init`. An explicit `--state DIR` selects another private state directory. The default is `~/.local/share/hermes-sandbox/profiles/NAME`. Neither registration action installs runtime dependencies nor overwrites an existing profile. Registration requires `.venv/pyvenv.cfg` and an executable `.venv/bin/python` resolving within the runtime or the system installation. Actual runtime entry also requires the reviewed `hermes-provision.json`, PM seed, and external install stamp; an arbitrary upstream venv alone is insufficient.

Profile policy is stored in `~/.config/hermes-sandbox/profiles/NAME.json` with exactly:

```json
{
  "version": 1,
  "runtime": "/home/example/.local/share/hermes-runtimes/19cb1cb",
  "state": "/home/example/.local/share/hermes-sandbox/profiles/work",
  "workspace": "/home/example/projects/my-project"
}
```

Registry directories are private `0700`; registration creates private policy files and a mode-`0600` `NAME.token` containing a generated 64-character lowercase hexadecimal broker capability. Keep that token outside version control. The registry, control directories, launchers, runtime, state, and workspace must not overlap in ways that grant writable policy access. Different profiles cannot share writable state/workspaces; a read-only runtime can be shared. Broad home/system directories, host credential trees, symlinked paths, and home dotfile workspaces are refused.

Managed profile creation, policy edits, and runtime pin upgrades are host-side operations. Native Hermes profile commands cannot create another registered sandbox authority or switch to an unmounted profile. Register separate state/workspace/capability pairs with host setup and run a separate CLI/gateway/backend instance for each registry profile. The broker must restart after host registry changes. For upgrades, review the new upstream pin/adapters and prepare a new versioned runtime before changing managed policy; do not run native `hermes update` against the read-only application checkout. The current preparer accepts only its reviewed fixed revision.

The profile doctor reports validated paths, expected revision, bubblewrap/systemd-run/adapter availability, and whether the broker socket/token exists. It does not authenticate a provider, exercise the broker or user manager, or prove that the registered checkout matches the pin; runtime entry performs source-integrity checks.

## CLI, Backend, and Desktop

Place `--profile NAME` before Hermes arguments:

```bash
~/ai-wrapper/bin/hermes_wrapper.bash --profile work
~/ai-wrapper/bin/hermes_wrapper.bash --profile work --resume SESSION_ID
~/ai-wrapper/bin/hermes_wrapper.bash --profile work serve --port 9119
~/ai-wrapper/bin/hermes_wrapper.bash --profile work desktop
~/ai-wrapper/bin/hermes_wrapper.bash --wrapper-help
```

Normal arguments are passed to the pinned Hermes CLI after sandbox initialization. The public `serve` wrapper accepts `--port`, `--host 127.0.0.1`, and `--isolated`; it always fixes the backend to authenticated loopback with isolation enabled. Its connection token/manifest is generated in protected control storage and mounted read-only. Default port `9119` must be free; use another port for simultaneous backends. `desktop` uses an existing protected backend connection or starts one for its lifetime. Protected connection data is loaded by the adapter for CLI/Desktop attachment, and authenticated readiness is checked before launching Electron. Actual session continuity still requires validation against the live pinned runtime.

The Desktop architecture is:

```text
Host Xpra renderer
       |
Private display socket
       |
Bubblewrap: Xpra server -> Xvfb -> complete Hermes Desktop
                                  | PTY / preview / private browser
                                  | authenticated sandbox backend
```

The Electron application, integrated terminal, preview scripts, and browser execute inside the profile sandbox on private display `:100`. Host `DISPLAY`, authentication cookies, display sockets, and browser profiles are not intentionally passed through or mounted. The supported GUI bridge is the private display transport to the host Xpra renderer. Shared networking can still expose host X11 abstract sockets, so this is not full host-GUI access isolation. Remote-backend configuration of an ordinary host-native Desktop alone does not confine its terminal or preview execution.

Both sides disable clipboard, file transfer, host file/URL opening, printing, webcam, audio, D-Bus integration, notifications, system tray, shared-memory transport, and remote logging. Closing the client terminates the private Desktop session; wrapper cleanup stops a backend it created. The launcher verifies that the packaged `app.asar` contains the protected attach-only backend compatibility gates before launch; an ordinary unadapted package is refused. That marker check is a compatibility check, not a new security boundary. Host convenience bridges are separate deferred options. Core PTY and preview support is retained and still needs a live acceptance test with the adapted packaged Desktop and required system libraries.

Profile identity creation, deletion, renaming, and import are refused at native API boundaries, including HTTP/RPC callers. Selected/default activation is a no-op; foreign root arguments are rejected. Profile-local configuration and export remain available. Use host-side sandbox setup for identity lifecycle changes.

## Shared Profile State

CLI, backend, gateway, and workers use the same registered `HERMES_HOME`. The adapter also pins native profile `ROOT` to that selected state rather than an unmounted host ancestor. Native profile-directory lookup accepts only the selected registry name or its `default` alias, profile listing/serve authority stays selected, and identity environment variables are pinned accordingly. There is no native cross-profile multiplexing within this authority; separate registered CLI/gateway instances are supported. A different profile requires host registration and its own state/workspace/broker capability. Separate service leases block duplicate backends or duplicate gateways, while allowing different service kinds and independent CLI sessions to coexist. Locks for service ownership stay in protected host control storage.

The adapter preserves the pinned upstream memory mutation locks, atomic writes, provider-auth transactions, skill mutation locks, and durable session/turn leases. Additional hooks serialize configuration operations across processes, merge changes from stale snapshots, reject conflicting changes to the same value, refresh admitted conversation history while holding the native turn lease, and invalidate changed skill caches. Helpers use the pinned `session.resume` and `session.activate` RPCs for attachment. Their presence and fixture tests do not establish complete cross-interface handoff or provider behavior; those remain core acceptance checks. These locks coordinate participating writers, not malicious commands with write access; direct arbitrary edits do not participate in the protocols.

The application checkout is mounted read-only. Profile caches, skills, learned scripts, browser state, and later dependency/PM generations need writable private storage. On the first confined launch, the adapter validates the read-only `hermes-provision.json` revision, external install stamp, and browser/tool seed under `runtime/.provision/store`. The manifest environment must contain exactly `HERMES_RUNTIME_DIR`, `HERMES_INSTALL_ROOT`, `PLAYWRIGHT_BROWSERS_PATH`, and `AGENT_BROWSER_EXECUTABLE_PATH`.

Under a private `flock`, the adapter copies the seed to a fresh staging directory inside the selected profile's state and publishes `state/tools` atomically. An existing store is retained rather than overwritten; escaped seed/store symlinks are refused. It remaps PM/browser paths to the selected registered profile even when the shared runtime's manifest was prepared for another state directory. `HERMES_INSTALL_ROOT` still identifies the read-only external installation. Sharing a runtime therefore creates a separate mutable tool copy per profile, with corresponding disk use; setup performs no host-side seed installation/copy. Mutable tools remain less trusted than the pinned application. Bootstrap checks exercise this contract, while full browser/provider operation and later dependency installation remain unvalidated live workflows.

## Worker Broker and Services

The parent repository supplies these user units:

| Unit | Purpose |
|---|---|
| `hermes-control.service` | Trusted host worker broker |
| `hermes-serve@NAME.service` | Profile backend |
| `hermes-gateway@NAME.service` | Profile messaging gateway with external supervision |
| `hermes.slice` | Aggregate supervised process budget |
| `hermes-workers.slice` | Independent worker units within that budget |

The broker reads protected registry policy/capabilities at startup. After host-side profile changes, restart it to load the new registrations. Its spool must exist as a private owned directory. After deployment and profile setup, the host operator can initialize that spool and start supervision explicitly:

```bash
mkdir -p -m 700 "$HOME/.local/share/hermes-sandbox/control/spool"
systemctl --user daemon-reload
systemctl --user start hermes-control.service
systemctl --user start hermes-serve@work.service hermes-gateway@work.service
systemctl --user status hermes-control.service hermes-serve@work.service hermes-gateway@work.service
```

These are operator commands, not actions performed by the documentation updater. Service argument compatibility and real startup/restart behavior remain part of acceptance validation. Starting a supervised backend while a foreground backend already owns that profile is refused by its lease.

Inside the sandbox, the broker socket is `/run/hermes/control.sock` and only the selected capability is mounted read-only as `/run/hermes/control.token`. The host socket is `/run/user/UID/hermes-sandbox/control.sock`; Linux peer credentials must match the broker's UID and each request must carry the selected profile's capability. This restricts confined profiles; it does not isolate mutually trusted host processes running as that UID.

The closed request schema contains `action`, `profile`, `kind`, `task_id`, `attempt_id`, and `capability`. Actions are `launch`, `status`, and `cancel`; kinds are `cron` and `kanban`. Arbitrary host commands, environment variables, mounts, PIDs, and systemd options are not accepted. The host broker alone talks to systemd; host D-Bus is never mounted into workers.

The adapter publishes a typed worker snapshot in private state; the broker captures it in a protected immutable spool before launch. Worker entry is fixed to `hermes_wrapper.bash --profile NAME _worker KIND ATTEMPT_ID`, which executes the job only after entering bubblewrap. Durable identities replace cross-namespace PID authority. Attempt records progress through accepted/adopted/finished stages, with status and cancellation reconciled against independent transient service units.

Worker units use `Restart=no` and `RemainAfterExit=yes` so terminal status remains observable across broker restarts. Uncertain dispatch is not replayed, and externally removed units yield unknown outcomes. At recent-ledger capacity, the broker atomically archives the oldest persisted finished record in protected `control/spool/archive/KEY.json`. Direct archive lookup retains that attempt's identity, outcome, and audit hashes across restarts, so an old launch/status/cancel request cannot create another worker for the archived identity. Only after the archive is durable does cleanup attempt to prune its matching host snapshot and stop its confirmed terminal unit. Active or uncertain records are never archived; failed cleanup can leave retained artifacts for host maintenance. This is recovery machinery in source, not a live gateway/broker restart or exactly-once external-effects guarantee.

The broker bounds registrations, recent records, and active workers (currently 64 profiles, 1,024 recent records, and 32 active workers). The recent-record cap is not a lifetime completed-job limit: protected finished-identity archives are retained separately and grow with job history. Preserving idempotence therefore trades bounded normal ledger scans for ongoing archive disk use; removing durable identities would weaken replay protection. Archival remains core worker behavior, not a TODO deferral, and its live lifecycle still needs acceptance validation.

The parent aggregate slice sets `CPUQuota=200%`, `MemoryHigh=3G`, `MemoryMax=4G`, and `TasksMax=512`. Interactive CLI/backend/gateway and private Desktop server execution also enters a mandatory systemd user scope in that slice, with per-scope `MemoryMax=6G`, `CPUQuota=200%`, and `TasksMax=512`; the tighter aggregate limit still applies when the parent slice is installed. The host Xpra rendering client is outside the sandbox scope. The general wrapper's former `prlimit` enforcement remains removed. Active limits require a working user manager and deployed unit configuration.

Interrupted interactive launches explicitly stop their unique systemd scope before releasing a service lease. This matters because scopes can outlive the invoking service cgroup. Cleanup failures report the exact scope for host diagnosis; broker-owned cron/Kanban services remain independent.

Kanban adoption validates the current claim and registers its broker handle under one immediate SQLite write transaction. In-place retry proof keeps the native task/run/claim/expiry checks but compares the durable broker handle rather than a PID from another namespace.

## Privacy and Security Boundaries

The sandbox has a private home (`/home/hermes`), private temporary/runtime directories, isolated process/user namespaces, selected read-only system files, a read-only application/adapter, and only the approved workspace plus profile state mounted read-write. The strict policy does not inherit the ordinary wrappers' optional credential mounts or additional bind settings, and it has no unsandboxed fallback.

Profile state contains user sessions, conversation history, memory, generated skills, browser login state, and provider/messaging keys. Mode `0700` protects the directory from other host users, but commands inside that profile can read and write its contents. Provision credentials specifically for that profile through Hermes setup/login or private profile files; host shell secrets, other agent homes, host browser cookies, SSH-agent, Docker, and host D-Bus sockets are not passed through. Keep secrets and personal signed artifact URLs out of Git and documentation.

Networking uses `--share-net` and remains unrestricted. The profile can reach permitted-by-host Internet, host loopback, LAN services, and Linux abstract AF_UNIX sockets; files or credentials visible inside it can be exfiltrated. Filesystem path restrictions do not hide abstract sockets in the shared network namespace. A host X11 server trusting local clients (`xhost +local`) or the local UID may therefore admit the sandbox agent through its abstract socket even without a mounted display socket or cookie. Use cookie-authenticated host X11 without local `xhost` grants. Loopback binding plus authentication reduces accidental exposure of the backend but does not create full network/GUI access isolation. Restricted egress is deferred. Namespace confinement is not a guarantee of zero host harm: writable project/state data, accessible host services, and kernel/runtime defects remain relevant boundaries.

Managed runtime entry points disable MCP discovery/tool dispatch and computer-use in Hermes, and force terminal tools to the local backend inside confinement. Arbitrary terminal Python/scripts can bypass those application-level exclusions and call network APIs; bubblewrap's filesystem/process boundary still applies. They are not arbitrary-code or network restrictions. The confined Desktop browser preview remains in core scope. Unsupported host Docker/SSH-agent access, arbitrary unreviewed host-native Desktop plugins, and optional host convenience bridges are tracked in the parent `TODO.md`.

## Optional Add-ons

Nothing is installed automatically. The manifest `bin/ai_wrapper_data/hermes_sandbox/addons.json` fixes the catalog and supported modes:

| Name | Current mode |
|---|---|
| `start-second-brain` | Pinned GitHub skill/templates/checker |
| `models-table` | Pinned GitHub reference only; no model/pricing/config imports |
| `customer-problem-researcher` | Local archive, export analysis only |
| `financial-manager` | Local archive, normalized local records only |
| `make-feature` | Local archive, approved workspace only; delegation/reviewer behavior needs validation |
| `competitive-intelligence` | Local archive, public-web use only |
| `codex-limits` | Deferred pending safe backend polling/credential/update adapter |
| `codex-pool` | Entire proxy/credential/account-rotation subsystem deferred |

Use explicit host opt-in through the wrapper:

```bash
~/ai-wrapper/bin/hermes_wrapper.bash --profile work addons list
~/ai-wrapper/bin/hermes_wrapper.bash --profile work addons install start-second-brain
~/ai-wrapper/bin/hermes_wrapper.bash --profile work addons install models-table
~/ai-wrapper/bin/hermes_wrapper.bash --profile work addons install customer-problem-researcher \
    --archive "$HOME/projects/my-project/customer-problem-researcher.tar.gz"
```

Local archives must be visible inside the approved workspace or private state, because wrapper installation runs inside bubblewrap. Paid/personal artifacts are acquired and reviewed separately; only a user-provided local tar/ZIP archive is accepted, never a personal signed download URL. A local skill requires `SKILL.md` at the archive root or inside one package folder. The Python API is `install_addon(name, state, archive=None, *, update=False)`; its caller must validate the private state path.

The two GitHub sources have fixed commits and archive SHA-256 digests. Extraction checks even excluded paths, rejects traversal, links/special files and collisions, and bounds archive size/expansion. Installation runs no package scripts, creates reviewed-content allowlists and receipts in private staging, locks publication, and publishes complete directories atomically. Explicit `--update` is required to replace an installed add-on. Files are initially read-only, but writable profile ownership is not a security seal against commands in the same profile. Manifest modes describe the accepted scope; inert archive metadata alone does not enforce public-web-only operation or egress policy.

Live customer connectors, universal CRM/1C/Excel importers, funnel/email/Telegram-account automation, provenance review for local artifacts and future updates, and model-reference verification remain unchecked parent TODO tasks. Reference inclusion is not verification of model IDs, prices, or subscriptions.

## Validation

From the `ai-wrapper` source checkout:

```bash
bash -n bin/executable_hermes_wrapper.bash bin/executable_setup_hermes.bash bin/ai_wrapper_data/hermes_wrapper_lib.bash
PYTHONPATH=bin/ai_wrapper_data python3 -m unittest discover -s tests -p 'test_hermes_*.py' -v
bash tests/test_hermes_wrapper.bash
bash tests/run_all.bash
```

Python suites cover registry validation, capability transport, broker lifecycle/recovery with injected systemd results, provisioning controls with fake executables, frontend command/lease behavior, state transactions, protected child hooks, native profile authority, private PM seeding/remapping, and optional archive safety. Socket tests use actual local Unix sockets. Some tests use a separate pinned upstream fixture; native frontend tests require `HERMES_TEST_UPSTREAM` pointing to that checkout. Live bubblewrap tests skip when namespace creation is unavailable, and those skips must be reported.

A passing mocked/fixture suite is not a live provider, GUI, or systemd test. Before declaring the full feature target accepted, validate runtime provisioning and imports, browser login persistence, Desktop PTY/preview confinement, shared memory/skills/history and session handoff, provider credential refresh, dependency-generation routing, and cron/Kanban completion/cancellation/recovery with real supervised units. Final code review and live prerequisites may expose further integration work.

The earlier unrestricted development run passed the full runner, including 248 Python tests and real bubblewrap checks. After the latest fixes, targeted adapter/bootstrap/recovery tests and scope-shutdown regressions pass. The current outer sandbox denies Unix socket binds and network sockets, preventing a clean full-suite rerun; the resulting socket-test errors are environmental, not acceptance evidence. Full preparation previously failed without publishing a runtime; the pinned uv `sync` build-constraint argument was corrected to project configuration and remains to be verified with a complete live build. Xpra/Xvfb and real user-manager acceptance remain unavailable here. Do not treat this source implementation as a ready-to-use installed Hermes runtime.

## Troubleshooting

- Missing/unsafe profile: check the registered absolute paths and private permissions; registration will not overwrite or repair an existing policy.
- Wrong runtime pin or changed tracked files: use the reviewed runtime rather than weakening adapter verification. A new revision requires adapter/pin review.
- Missing broker: create the private spool and start `hermes-control.service` on the host. The sandbox does not receive systemd/D-Bus access to do this itself.
- Duplicate service owner or occupied port: stop the corresponding foreground/supervised owner or choose a free backend port; separate CLI sessions remain possible.
- Missing Desktop prerequisites: inspect `frontends.py dependencies`; provide Xpra/Xvfb/xauth and the packaged Desktop before retrying. Do not bind host display sockets as a workaround.
- Missing provider credentials: configure them in the selected private profile. Host credential passthrough settings for the other wrappers do not apply.
- Local add-on archive unavailable: place the approved archive in a mounted workspace/state path. Deferred add-on names are refused by the catalog.

See the parent [AI agent sandboxing architecture](../../../docs/ai-agent-sandboxing.md) and [deferred Hermes options](../../../TODO.md#15-hermes-sandbox-deferred-options).
