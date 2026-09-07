#!/bin/bash
# Functional smoke tests for the sandbox core, via the shared
# run_sandboxed_agent() entry point in ai_agent_universal_wrapper.bash.
# run_sandboxed_agent() dispatches on `uname -s` internally (bubblewrap on
# Linux, sandbox-exec on macOS), so this one file exercises real sandbox
# behavior — not just syntax — on whichever OS actually runs it.
#
# Requires: bubblewrap installed and unprivileged user namespaces enabled
# (Linux), or macOS's built-in sandbox-exec (macOS, no setup needed).
#
# Deliberately not `set -e`: several assertions here are about
# run_sandboxed_agent exiting non-zero on purpose (WORKDIR refusals,
# denied credential reads), and each call runs inside a `$(...)` command
# substitution — already its own subshell — so its internal `exit` calls
# never touch this script's own process.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"
# shellcheck source=../bin/ai_agent_universal_wrapper.bash
source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"

# Isolated fake HOME: never touches the real machine, and makes every
# "if [[ -d "${HOME_DIR}/X" ]]" optional bind in the wrapper a no-op unless
# a test below explicitly creates that path.
FAKE_HOME="$(mktemp -d)"
export HOME="${FAKE_HOME}"
mkdir -p "${FAKE_HOME}/project"

cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

echo "== sandbox smoke tests ($(uname -s)) =="

# Every real-launch assertion below prints its captured output
# unconditionally (not just on failure): a bare "expected [0], got [1]"
# with the actual bwrap/sandbox-exec stderr swallowed makes CI failures
# opaque — this was the exact gap that made two earlier real bugs on this
# sandbox path (a redundant, hard-failing bind mount; an unbound $USER
# under `set -u`) invisible in initial CI runs.

# --- a benign command actually runs inside the sandbox ---
out="$(cd "${FAKE_HOME}/project" && run_sandboxed_agent /bin/echo -- -- ci-smoke-test-ok 2>&1)"
rc=$?
echo "  (benign command output: ${out})"
assert_eq "${rc}" "0" "benign command exits 0"
assert_contains "${out}" "ci-smoke-test-ok" "benign command's stdout reaches the caller"

# --- WORKDIR is the write fence: refuse the obviously-sensitive spots ---
out="$(cd "${FAKE_HOME}" && run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
rc=$?
assert_eq "${rc}" "1" "launching from \$HOME itself is refused"

mkdir -p "${FAKE_HOME}/.dotproject"
out="$(cd "${FAKE_HOME}/.dotproject" && run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
rc=$?
assert_eq "${rc}" "1" "launching from a dotfile dir directly under \$HOME is refused"

# --- the refusal has an escape hatch, and it actually works ---
out="$(cd "${FAKE_HOME}" && AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 run_sandboxed_agent /bin/echo -- -- hi 2>&1)"
rc=$?
echo "  (override-launch output: ${out})"
assert_eq "${rc}" "0" "AI_SANDBOX_ALLOW_SENSITIVE_WORKDIR=1 overrides the \$HOME refusal"

# --- credentials are denied by default, and the matching PASS_* flag opts back in ---
mkdir -p "${FAKE_HOME}/.ssh"
echo "TOTALLY-SECRET-KEY-MATERIAL" >"${FAKE_HOME}/.ssh/id_rsa"

out="$(cd "${FAKE_HOME}/project" && run_sandboxed_agent /bin/cat -- -- "${FAKE_HOME}/.ssh/id_rsa" 2>&1)"
assert_not_contains "${out}" "TOTALLY-SECRET-KEY-MATERIAL" "~/.ssh is NOT readable by default"

out="$(cd "${FAKE_HOME}/project" && AI_SANDBOX_PASS_SSH_AGENT=1 run_sandboxed_agent /bin/cat -- -- "${FAKE_HOME}/.ssh/id_rsa" 2>&1)"
echo "  (PASS_SSH_AGENT launch output: ${out})"
assert_contains "${out}" "TOTALLY-SECRET-KEY-MATERIAL" "AI_SANDBOX_PASS_SSH_AGENT=1 grants ~/.ssh read access"

tests_summary_and_exit
