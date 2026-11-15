---
name: tortuga-operations
description: "Use when deploying Tortuga-AI infrastructure."
version: 1.0.0
author: Hermes Agent
license: MIT
metadata:
  hermes:
    tags: [tortuga, deployment, docker-compose, ci-runner, tailscale]
    category: devops
---

# Tortuga-AI Operations

## When to Use

Use for Tortuga-AI stack deployments, webhook availability checks, model-routing verification, or self-hosted CI monitoring.

## Complete deployment

- Treat `make redeploy-all` as incomplete for webhook and CI availability: it starts monitoring, bridge, homepage, and telegram-bot, but omits Tailscale Funnel and the self-hosted CI runner.
- After rebuilding the bridge/homepage, run `make funnel-up` and verify `tailscale funnel status`; otherwise GitHub label webhooks cannot reach the bridge even when the bridge itself is healthy.
- Explicitly rebuild/recreate the self-hosted runner with `docker compose -f ci-runner/docker-compose.yml --env-file .env up -d --build --force-recreate` when the requested deployment includes CI.
- Verify the runner from logs: require `Docker daemon is ready`, `Connected to GitHub`, and `Listening for Jobs` before triggering PR checks.
- Verify bridge effective model routing through authenticated `/config/effective?repo=OWNER/REPO`; local YAML or runtime overrides can supersede defaults.
- Verify `/config/model-options` after bridge startup and inspect each tool's version, source, model count, and error.

## DinD test-environment recovery

- Treat a `DIND_UNAVAILABLE` comment as a terminal implement failure, not an active cycle. Confirm the target has no active run in `/admin/runs` and no queue entry in `/admin/queue` before retrying; GitHub labels and historical loop comments can outlive the failed run.
- Diagnose the test environment before re-adding labels. Check the bridge's run record and per-run log first, then probe the exact production runtime: launch `agent-dind:latest` with `--runtime=sysbox-runc`, `DOCKER_TLS_CERTDIR=` and the bridge's loopback dockerd arguments; require a running container and `API listen on 127.0.0.1:2375`, then remove the probe. A host Docker health check alone does not exercise sysbox or nested dockerd.
- Treat a passing exact DinD probe as evidence that the current runtime recovered; do not rebuild or change configuration solely because a historical run reported `DIND_UNAVAILABLE`. If a redeploy removed the old per-run log, state that the original cause is unavailable rather than inventing one, then use the current probe as the retry gate.
- After rebuilding or recreating the bridge, repeat the DinD probe and verify bridge startup reports the sysbox runtime guard as healthy. Only then restart the authorized cycle and verify a new accepted run ID in bridge evidence.

## Queue-lifecycle change gate

- Preserve `agent:queued`, the queue hash, and the dedup lock through every fallible setup step. Transition to the active trigger only at handoff; an early label swap makes capacity or branch-lock requeue entries invisible to the next worker.
- Treat every queued subprocess, network, label-transition, and thread-start failure as a bounded transient retry. Release attempt-scoped semaphores and branch locks, but retain the queue-owned dedup lock until requeue is durable, successful handoff transfers ownership, or terminal drop completes; a generic exception cleanup must not expose a still-live entry without dedup ownership.
- Claim a queued entry for handoff with one Redis script that verifies or atomically reacquires the expected dedup owner, confirms the sorted-set member and full hash, observes the stop flag, renews the dedup TTL, writes the handoff/hash state, and removes the sorted-set member. Never split handoff marker creation from `ZREM`: a crash or ownership change between commands creates an unowned or duplicate dispatch window.
- Release dedup ownership and all run-specific handoff/recovery metadata with one Redis operation against the expected run ID. When a newer run owns the dedup key, preserve that owner but atomically delete only the stale run's hash, companion, handoff, and stop keys; retaining stale terminal metadata makes restart cleanup loop forever.
- Recover a handoff-marked queued run when startup finds its saved run record but no container in any state. Saving the run before `thread.start()` does not prove a worker survived the process crash, while checking only running containers misses created or exited ownership. If the saved run is terminal, retry atomic retirement instead of skipping it; the prior retirement may have failed while Redis was unavailable.
- Make popped entries cancellable across the `ZREM` handoff window. Keep an explicit in-flight marker, record a durable stop request when queue storage is no longer visible, check it before handoff, and check again immediately after container registration so a not-found stop cannot race a late create. Require the full queue hash before deriving owner/task cancellation data: if the sorted-set member still exists but its hash is missing, classify it as a race and make no GitHub or ownership mutation; the companion repo key alone cannot authorize cancellation safely.
- Route every terminal queue exit through one cleanup-before-release helper: cancellation, closed-target discard, state-check exhaustion, successful artifact replay, exhausted retry, deterministic rejection, queued async setup failure, and unexpected dispatch failure. Delete or durably terminalize the queue hash before atomically releasing the expected-owner dedup/handoff keys; if terminalization fails, retain ownership and restore a stop flag so restart recovery retries cleanup instead of resurrecting work. Test cleanup failure at each caller because a happy-path helper test does not prove every terminal branch uses it.
- Complete public terminal cleanup before successful queue retirement. Remove `agent:queued` on cancellation, closed-target discard, artifact replay, handled deterministic rejection, and queued DinD/worktree/prompt startup failure; queued async helpers must return through queue retirement rather than directly releasing dedup ownership. Keep public failure text generic while preserving diagnostic detail in admin logs.
- Ignore bot-generated removal of `agent:queued` before user-cancellation handling. The bridge removes that label during a successful transition, and treating its own webhook as user intent makes a dispatch cancel itself.
- Persist the exact dedup key acquired at ingress in every queue entry and saved run record, then use that stored key for claim, cancellation, retirement, and restart recovery. Do not reconstruct ownership from mutable target fields: issue→PR redirects change the visible issue number without moving the original lock, so derivation strands ownership until TTL expiry. Keep a derivation fallback only for legacy records.
- Renew the expected-owner dedup lease atomically immediately before artifact replay or any persisted external side effect; a prior `GET` is insufficient because an almost-expired lock can change owners before the GitHub write. Make replay idempotent across a crash after the remote write but before local cleanup: verify the exact rendered body already exists on GitHub before posting, paginate the lookup, and fail closed/requeue when the remote state is uncertain rather than risking a duplicate comment or review.
- Keep queue run IDs, Redis details, exception classes, prompt-file paths, worktree races, model names, provider names, API-key/auth mechanisms, routing details, and configuration values in admin logs only. Public cancellation, pause/recovery, retry, dispatch, and startup-failure comments must use generic service wording and direct service-side remediation to the app owner.
- Gate deployment on focused queue/cancellation tests, the owning test module, the full bridge suite, the Docker queue E2E, and an independent race/security review. Bind every result to the exact final diff: any reviewer-driven production or test edit invalidates prior full-suite, lint, E2E, and review evidence. A locally green happy-path E2E alone does not validate lock and rollback ownership.

## Triggering agent labels

- After applying an `agent:*` label, require evidence in bridge logs that the webhook arrived before assuming dispatch began. A label visible on GitHub proves repository state, not webhook delivery.
- If no delivery arrives, first verify the bridge health and Funnel route. When the owner explicitly requested the dispatch and the external delivery still does not arrive, send a local HMAC-signed `/webhook` event using the live PR JSON fetched from GitHub and the configured webhook secret; use the trusted internal sender `agent-bridge`, preserve fetched PR fields exactly, and verify the accepted run ID in bridge logs.
- Add `agent:loop` only after the initial implement/review run has an active run ID, then verify the loop activation response. Adding it before a run exists is intentionally ignored.

## Provider-limit classification and canary activation

1. Reconcile the target's run, queue and PR before intervening. Inspect the exact run's exit reason and a bounded log excerpt; a provider session-limit failure with skipped verification is not a code-test failure.
2. Compare the actual provider message with the deployed classifier and resolve the provider key through the deployed tool/provider mapping. Inspect the matching pause, probe-model and canary state; missing keys alone do not prove restored capacity. Session-limit wording can differ from rate-limit wording.
3. If a confirmed quota failure missed classification, inspect the deployed pause handler and its callers before using the existing operational recovery path under authorized recovery scope. Preserve the exact configured model selector, including effort. Do not substitute raw Redis writes, a reset-time scheduler, a duplicate dispatch or an unapproved provider/model change.
4. Read back pause activation, its TTL and the probe-model selector after invoking recovery. Report this as recovery activation only: it does not prove a successful canary, task readmission or provider restoration. Verify those transitions separately while keeping observation active.
5. Treat a classifier correction as a separate code change requiring normal authorization and regression coverage for the observed message variant. Operational activation does not repair detection for the next failure.

## CI behavior

- The self-hosted runner is a single runner, so PR jobs queue serially. A large uncached `agent-runner` image build can take over 30 minutes without being stalled.
- Distinguish queued/pending GitHub presentation from the live runner state using runner logs (`Running job:` / `Job ... completed`) and, when needed, active processes and inner Docker events.
- Installation tokens minted by `make get-github-token` expire during long serial CI runs. If `gh pr checks --watch` ends with HTTP 401, treat it as a watcher-auth failure rather than a CI failure, mint a fresh token, resume the watcher, and read the PR checks again before reporting status.
- Do not call CI green until every applicable check, including dynamically unlocked E2E, has completed successfully.
- Diagnose lifecycle-test failures from the complete event timeline before increasing waits or repeating a resource trial. Read successful diagnostic steps as well as failed steps: `--log-failed` can omit the service dump that explains the assertion. For a missing checkout during startup, correlate the exact task across every bridge instance, orphan cleanup, Docker create and Docker start; a second bridge sharing storage can remove a live task's checkout before its container becomes visible. Distinguish this race from memory pressure, late labels, expired pause keys and client deadlines. Keep unrelated lifecycle repairs outside a behavior-preserving refactor until approved. A passing isolated class does not certify the full suite.
- Measure resource pressure on the CI runner's own daemon and cgroup, not only the host or an isolated agent sidecar. Compare memory.events counter deltas and peak/current usage with the live limit; no OOM kill does not rule out reclaim stalls. Treat cumulative counters and fast idle probes as evidence to investigate, not proof of a particular failed job's cause. Do not prune storage, raise limits or weaken tests without the applicable authorization.
- Treat an approved resource increase as a bounded experiment, not a permanent fix. Record baseline memory/swap limits, target container identity, exact CI head/run IDs and rollback condition; change only the approved live limit, verify it, and arrange restoration before starting the trial. Restore the baseline only if the trial still owns the override, leaving independent operator changes untouched. Report measured results and verified rollback separately; never claim a trial fixed CI before its checks finish.

## Agent review loops

- Determine live cycle state from bridge evidence, not label presence or an earlier “loop complete” comment. Require a target-matching active run or queue entry; a terminal `ERROR`, `OPEN_QUESTIONS`, or failed-environment report means the cycle is not running and needs an authorized restart.
- When the user suspects a cycle failed, pause unrelated local work and immediately read the latest PR loop report plus target-filtered `/admin/runs` and `/admin/queue`. Report the observed terminal state before continuing; a healthy bridge or another task's active run does not prove this target is running.
- Treat green CI as a gate, not loop completion. A review can request an implement cycle after CI passes; that cycle can push a new head, which invalidates the earlier checks and starts another CI/review round.
- After each agent container exits, read bridge logs and the PR again. Verify the exit classification, remote head SHA, active `agent:review`/`agent:implement`/`agent:loop` labels, latest review signal, and checks attached to the latest head before deciding what is next. Treat older “loop complete” comments as historical evidence only because a later review cycle may already have superseded them.
- When an implement cycle pushes, refresh the expiring App credential before `git fetch`, compare the local and remote head, and monitor the newly created checks rather than relying on the prior green run. If verified local fixes are dirty while the remote advanced, inspect the remote delta, stash with untracked files, fast-forward only, reapply the stash, then rerun every focused/full/lint/E2E/review gate on the merged snapshot; a clean auto-merge still invalidates evidence from the old base.
- If the requested work included deploying the branch, redeploy after the loop’s final pushed commit and repeat service, Funnel, runner, routing, and model-catalog verification; the pre-review deployment is stale once an implement cycle changes the head.
- Monitor a known active cycle efficiently with `docker wait <agent-container>`; on exit, re-discover any successor container because loop cycles use new run IDs and container names.
- Call the loop finished only when the latest head has all applicable checks green, no review or implement run is active, trigger labels have converged to the terminal state, and the final review/loop report contains no unresolved change request.
