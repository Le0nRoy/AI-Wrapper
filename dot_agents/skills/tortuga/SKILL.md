---
name: tortuga
description: Use when managing GitHub work through Tortuga.
version: 0.1.0
---

# Tortuga from any project

Use the existing Tortuga runner for GitHub research, implementation and review. Hermes/Claude/Codex/OpenCode are conversational clients, not competing dispatchers. Works from any directory with an explicit target, or from a GitHub checkout using its origin. Arbitrary non-Git local-folder execution is not provided.

## Prerequisites
- Tortuga checkout: `$TORTUGA_HOME`, default `/Data/Everything/ProgrammingWorkspace/Tortuga-Infra/Tortuga-AI`.
- Running bridge/webhook and GitHub App installed on the target repository.
- Existing `make get-github-token REPO=OWNER/REPO`, `gh`, Git and Python 3. No persistent gh login required.
- A connected project's own verification config: default `make test-all`/FULL_TEST_TARGET, or verify.mode=gha with explicit VERIFY_JOBS. Never silently impose Tortuga's tests on another repo.

## Commands
Use the terminal/shell tool. Prefix below with `python3 <this-skill-directory>/scripts/gh.py`; on the host the stable path is `python3 ~/.agents/skills/tortuga/scripts/gh.py`. Use the native client copy inside a sandbox. The helper captures the existing App-token command internally and passes GH_TOKEN only to gh; it neither changes Git remotes nor stores credentials. The Tortuga checkout and its existing token issuer must be accessible: skill installation does not grant sandbox access to infrastructure or private keys. If access is blocked, use the authorized host-side Hermes session; do not weaken sandbox mounts or copy root credentials.

```text
--repo OWNER/REPO repo
--repo OWNER/REPO issue list --limit 20
--repo OWNER/REPO issue view NUMBER --comments
--repo OWNER/REPO pr view NUMBER --comments
--repo OWNER/REPO pr checks NUMBER
--repo OWNER/REPO run list --limit 10
```

Omit leading `--repo` only when the current Git origin is the intended target. In a non-Git directory it is mandatory. Show the resolved target before the first write. Never fall back to Tortuga's own source repository.

## Authorized task actions
Read requirements and current labels/state before writing. Only after the user authorizes that action:

```text
--repo OWNER/REPO issue create --title TITLE --body BODY
--repo OWNER/REPO issue edit NUMBER --add-label agent:research
--repo OWNER/REPO issue edit NUMBER --add-label agent:implement
--repo OWNER/REPO pr edit NUMBER --add-label agent:review
--repo OWNER/REPO issue comment NUMBER --body ANSWER
--repo OWNER/REPO pr comment NUMBER --body ANSWER
```

After a write, read back the exact Issue/PR. A visible label proves GitHub state, not delivery or runner startup. Verify actual webhook/run admission in bridge evidence before claiming execution. Do not remove/re-add a label blindly: it can duplicate work. `agent:review` targets PRs, not plain issues. Add `agent:loop` only for an actual active implement/review run and after explicit permission; verify loop activation. Questions/answers do not imply unsupported automatic resume.

## Status and controls
- GitHub: linked draft PR, comments, current head and its checks are the owner-visible results. Earlier green CI does not certify a later head.
- Existing admin read endpoints: GET /admin/runs, /admin/runs/{run_id}, /admin/queue; require X-Admin-Token from local Tortuga configuration. Keep credentials inside a process, never print/source all .env into chat or send them to worker agents.
- For infrastructure operations read Tortuga's AGENTS.md, docs/workflow.md and docs/operations.md. Existing `make stop-agent` is destructive and needs exact-run authority; inspect its current arguments first. Do not invent a generic pause/resume API.
- Keep queueing, quota waits and recovery in Tortuga. Do not create native Hermes Kanban jobs, Workflows graphs or a second task-state database.
- Do not deploy, merge, grant App access, change quotas/models or launch unrelated tasks as a side effect of status checks.

## Verification and limits
Resolve a different project's GitHub origin or use explicit --repo from a non-Git directory; successfully read that exact repository and an Issue/PR. Test writes only against a named user-authorized task, then verify GitHub state AND bridge admission. Existing App access is required; installing this skill does not grant repository access or prove webhook delivery. Shared discoverability is not proof every client's live conversation auto-reloaded its startup context.
