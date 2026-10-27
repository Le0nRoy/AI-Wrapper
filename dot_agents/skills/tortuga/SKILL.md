---
name: tortuga
description: Use when managing GitHub work through Tortuga.
version: 0.2.4
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

For automation, prefer explicit JSON fields, for example `issue view NUMBER --json number,title,body,state,labels,comments,closedByPullRequestsReferences,url`. Treat empty stdout from a formatted `--comments` read as inconclusive even when exit status is zero; retry with `--json` before deciding that an Issue or its comments are absent.

For loop monitoring, use `pr view NUMBER --json state,isDraft,mergeStateStatus,headRefOid,headRefName,labels,statusCheckRollup,reviews,comments,url`. Compare each `reviews[].commit.oid` with `headRefOid` before accepting its `AGENT_LOOP_META`; this gets commit-scoped review evidence through the helper's supported `pr` path without separate API authentication.

Omit leading `--repo` only when the current Git origin is the intended target. In a non-Git directory it is mandatory. Show the resolved target before the first write. Never fall back to Tortuga's own source repository.

Prefer numeric selectors. URL selectors must name the same github.com repository; the helper rejects others before requesting a token. Override subprocess deadlines with `TORTUGA_GIT_TIMEOUT` (default 10s) and `TORTUGA_TOKEN_TIMEOUT` (default 45s).

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
- Treat a run as admitted only when bridge evidence shows dispatch acceptance. Normally use its queued/running admin record. Review dispatch can wait for CI before its runner container or `/admin/runs` record is visible; in that phase, a bridge `waiting for CI checks` log plus the PR trigger label proves admission.
- Poll boundedly and report only state transitions. During long batches, use one background watcher with completion notification instead of repeated manual sleeps or a second task database. Monitor loops by repository plus PR number, current head, labels, reviews, and head checks; branch names and issue numbers can collide across repositories, and a watcher keyed only to the issue run or implement branch can settle before the review run is registered.
- Treat trigger labels as events, not durable run history: automation may consume `agent:review` or `agent:implement`, so their later absence does not prove they were never applied. Use dispatch comments/admin evidence to prove admission, and do not re-add a consumed label after a completed loop unless fresh work is authorized.
- Scope every `AGENT_LOOP_META` result to the review's commit SHA. Ignore an approval, rejection or open question attached to an older head and wait for a current-head review; otherwise a stale question can stop a repaired loop or a stale approval can certify new code.
- When a loop finishes with open questions, answer each question in the PR from verified code, CI, or documented intent. Then follow the loop's explicit continuation instruction—normally retain/add `agent:loop` and add `agent:implement`—and verify both a new dispatch and a later completion comment. Posting an answer alone does not resume the loop.
- Remote automation may advance the branch while the local checkout and its remote-tracking ref remain stale. Before validating, repinning a dependency, or reporting exact SHAs, fetch the affected repository, compare the PR head with local HEAD, and fast-forward a clean checkout; otherwise local success can certify an obsolete revision.
- For dependent submodule and superproject PRs, finish the submodule loop first. If its head changes, update and verify the parent gitlink before starting or accepting the parent review; parallel approval can certify a stale dependency pointer. After the dependency merges, fetch its default branch and repin the parent to the actual merge commit before the parent merges: squash/rebase creates a new canonical SHA even when the tree is identical. Push that repin and require fresh parent checks at the new head.
- When an implementation runner cannot publish, do not repeat the same blocked cycle. If the user already authorized publication and the host has scoped App access, recover the runner's exact commits or `git format-patch`, apply and verify them owner-side, publish the dependency, repin the parent, post the resolution, then request fresh reviews. Never loosen the runner's push policy merely to finish one loop.
- For infrastructure operations read Tortuga's AGENTS.md, docs/workflow.md and docs/operations.md. Existing `make stop-agent` is destructive and needs exact-run authority; inspect its current arguments first. Do not invent a generic pause/resume API.
- Keep queueing, quota waits and recovery in Tortuga. Do not create native Hermes Kanban jobs, Workflows graphs or a second task-state database.
- Do not deploy, merge, grant App access, change quotas/models or launch unrelated tasks as a side effect of status checks.

## Umbrellas and sequential sub-issues
Process children in the umbrella's stated order. Before each action, read the child's state, labels, comments and linked PRs; skip already-closed work. A welcome comment, reactions or a prior label do not count as a research report: require a substantive findings comment with scope and open-question disposition.

Resolve implementation-detail questions from code, docs and existing architecture. Post the resolution where the next agent will read it. Ask the user only when product or architecture intent remains ambiguous; include the child context, what the answer controls, evidence, and a short selectable option list with the recommended choice first.

When research is ready and the batch authorization includes looping, add `agent:implement` and `agent:loop`, read back both labels, then verify bridge admission. Do not start the next child until the current PR is merged/closed and the child closure is visible. Never classify a loop as stale while a latest-head check is queued or running; lack of a status transition is not inactivity. A stale loop is not automatically safe to merge: when the user's runbook explicitly authorizes stale-loop merges, still inspect the latest head, CI, review requests and unresolved questions first.

Record the local checkout's initial branch and dirty files before the batch. Preserve unrelated or intentionally deferred configuration edits throughout child work. Apply and commit those edits to the integration branch only after every child is closed and only the integration PR remains.

For the concrete command sequence, safe admin polling and completion gates, read [references/umbrella-workflow.md](references/umbrella-workflow.md).

## Verification and limits
Resolve a different project's GitHub origin or use explicit --repo from a non-Git directory; successfully read that exact repository and an Issue/PR. Test writes only against a named user-authorized task, then verify GitHub state AND bridge admission. Existing App access is required; installing this skill does not grant repository access or prove webhook delivery. Shared discoverability is not proof every client's live conversation auto-reloaded its startup context.
