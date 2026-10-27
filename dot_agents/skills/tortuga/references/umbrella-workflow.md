# Sequential umbrella workflow

Use this recipe when one umbrella tracks several child issues and the user authorizes research, implementation loops and merges.

## 1. Establish scope and protect local state

1. Read the umbrella body and preserve its child order.
2. Run `git status --short --branch` in the intended checkout before any write.
3. Record pre-existing dirty files. Do not stash, reset, fold into agent work, or deploy them early.
4. Read each child's `state`, `labels`, `comments`, `closedByPullRequestsReferences`, and URL before deciding its next step.

Skip a closed child. Do not re-run research or implementation merely because the umbrella checkbox is stale.

## 2. Research gate

A child is research-ready only when comments contain a substantive report with:

- root cause or current-state evidence;
- scope disposition;
- proposed implementation and tests;
- explicit open questions with resolved/unresolved status.

Welcome text, emoji reactions, dispatch notices, and removed labels are not research output.

If no report exists, add `agent:research`, read the issue back, then verify a matching record in `GET /admin/runs`. Do not remove and re-add the label while an admitted run is queued or running.

When the report lands:

1. Resolve code-level questions from repository evidence.
2. Comment the resolution on the issue so the implement agent receives it.
3. Ask the user only about unresolved product or architecture intent. State the child, the decision it controls, evidence, and a recommended answer.

## 3. Implement-loop gate

After all questions are resolved, add `agent:implement` and `agent:loop` together when the user's authorization includes looping. Read the issue back and verify both labels. Then verify the implement run appears in bridge state.

The bridge record is the authoritative admission signal. Filter output to non-secret fields such as:

- `id`
- `task_type`
- `issue_number`
- `pr_number`
- `branch`
- `status`
- `created_at`
- `updated_at`
- `completed_at`
- `error`

Read `BRIDGE_ADMIN_TOKEN` inside the monitoring process and send it only as `X-Admin-Token`. Never print the token or source the whole `.env` into command output.

## 4. Monitor without creating another scheduler

Track the initial implement run in `/admin/runs`. Allow a short grace period after it finishes because PR creation and loop transfer lag behind the run result. As soon as the PR exists, switch the primary watcher to the PR itself: track `headRefOid`, labels, latest-head checks, reviews and comments.

Do not end monitoring merely because `/admin/runs` has no follow-up record. Review dispatch can wait for CI before a runner container starts or before the run appears in the admin list. Treat `agent:review` plus bridge evidence that it is waiting for CI as active work. Use `/admin/runs` again when the review or re-implementation run becomes visible.

For a long wait, run one bounded background watcher with completion notification. The watcher should:

1. query `/admin/runs` until the initial implement run reveals its PR and branch;
2. print only changed, filtered records;
3. then query the PR for current head, active loop labels, `statusCheckRollup`, reviews and comments;
4. reset its staleness clock on any head, label, check or review transition;
5. suspend staleness classification while any latest-head check is `QUEUED` or `IN_PROGRESS`, or bridge evidence shows an active run or CI wait; long tests can remain unchanged for many minutes;
6. treat a trigger label alone as insufficient proof of activity after checks settle; if no active run or CI-wait evidence exists, start the bounded staleness clock so a stuck label cannot block the batch forever;
7. exit only on merged/closed state, a verified loop approval, an explicitly classified stale state, or a bounded timeout;
8. after any watcher exit or completion notification, perform a fresh one-shot PR and bridge read before merging because asynchronous notifications can arrive after state has changed.

The GitHub App often cannot formally approve its own PR and can fall back to a COMMENT review. Request `headRefOid,reviews` together; `reviews[].commit.oid` supplies the review commit identity. Detect loop approval from the structured `AGENT_LOOP_META` signal in the latest review body, not from GitHub `reviewDecision` alone. Match the review's commit OID to the current `headRefOid`; do not let metadata from an older head supply approval or open questions for a newer head. Always pair the current-head signal with latest-head CI and absence of active `agent:review`, `agent:implement` or `agent:queued` labels.

Do not infer success from container lifetime alone. A live container proves activity, while GitHub comments, reviews and the final bridge record prove the result.

### Recover a publish-blocked dependency fix

When a restricted implementation runner produces valid dependency commits but cannot push:

1. Stop cycling the unchanged parent; another review cannot inspect unpublished objects.
2. Recover exact commits from the retained worktree when available. Otherwise extract the complete `git format-patch` block from the implementation comment and verify its digest before applying it.
3. Fast-forward the local dependency branch to the published PR head, apply the recovered commits with `git am`, and run the dependency's full verification plus focused regressions.
4. Under existing user authorization, publish with the repository-scoped App token from the owner-side session. Read back the remote branch SHA; never rewrite remotes with a persistent token.
5. Repin the parent only after the dependency SHA is remotely fetchable. Commit and publish the parent, then verify its remote head and exact gitlink.
6. Comment the resolved SHAs and verification on the parent PR. Request a fresh dependency review first; after its latest head is approved, request or accept the parent review.

Do not grant the runner broader push permission as a shortcut. Preserve the security boundary and use the already authorized owner-side publication path.

## 5. Approval, stale-loop and merge gate

Before merging, read the exact PR and verify:

1. current head SHA;
2. latest-head checks, not checks from an earlier revision;
3. latest review result and unresolved change requests;
4. open questions or failed verification comments;
5. intended base branch, especially for integration-branch children.

If the loop approved, merge under the user's standing authorization. If the loop merely went stale, merge only when that stale-loop behavior was explicitly authorized and the checks above show no material blocker.

Before choosing `--merge`, `--squash`, or `--rebase`, query the repository's enabled merge methods; do not assume the default. Mark an approved draft ready before merging when required. A successful merge command is not enough: read the PR and child back afterward, and require visible merged/closed state as the completion signal.

## 6. Finish the integration PR

After every child is closed and no child PR remains open:

1. switch to the integration branch without discarding the initial dirty configuration;
2. inspect the configuration diff and ensure it belongs to the umbrella outcome;
3. commit only that intended diff;
4. push/update the integration PR;
5. verify latest-head CI and review state before merging;
6. read back the umbrella and integration PR to confirm closure.
