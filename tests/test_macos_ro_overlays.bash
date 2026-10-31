#!/bin/bash
# macOS (Seatbelt) enforcement of --ro-bind nested under an RW --bind or
# WORKDIR (issue #11). The backend renders --ro-bind as an allow-read plus
# a trailing (deny file-write* ...) rule; see _append_ro_deny_rules in
# bin/ai_wrapper_data/macos_sandbox_exec.bash.
#
# Three layers:
#   1. rule rendering (_append_ro_deny_rules), from the real worktree bind
#      list _wrapper_bind_git_common_dir builds for Darwin — any OS;
#   2. backend wiring via AI_SANDBOX_DRYRUN (--ro-bind, AI_SANDBOX_EXTRA_*,
#      _extra_sandbox_setup) — native on macOS; off macOS getconf and
#      sandbox-exec are stubbed, so it checks generated text only;
#   3. native sandbox-exec writes (ordering, extension hook, extra dirs) —
#      macOS only, and a missing sandbox-exec there is a failure.
# The full worktree probe (truncate, rename, unlink, links, git commit)
# through the codex wrapper lives in tests/test_bind_hardening.bash.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=./lib_test_helpers.bash
source "${REPO_ROOT}/tests/lib_test_helpers.bash"

# Under the real $HOME for the reason given in tests/test_sandbox_common.bash.
FAKE_HOME="$(mktemp -d "${HOME}/ai-wrapper-test.XXXXXX")"
FAKE_HOME="$(cd "${FAKE_HOME}" && pwd -P)"
isolate_test_env "${FAKE_HOME}"
cleanup() { rm -rf "${FAKE_HOME}"; }
trap cleanup EXIT

OS="$(uname -s)"
NL=$'\n'
DENY_OPS="file-write* file-link"

_load_backend() {
    # shellcheck source=../bin/ai_agent_universal_wrapper.bash
    source "${REPO_ROOT}/bin/ai_agent_universal_wrapper.bash"
    # shellcheck source=../bin/ai_wrapper_data/codex_wrapper_lib.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/codex_wrapper_lib.bash"
    # shellcheck source=../bin/ai_wrapper_data/macos_sandbox_exec.bash
    source "${REPO_ROOT}/bin/ai_wrapper_data/macos_sandbox_exec.bash"
}

echo "== macOS read-only overlay tests (${OS}) =="

if ! command -v git >/dev/null 2>&1; then
    _test_report 0 "git is installed (needed for the worktree fixture)"
    tests_summary_and_exit
fi
git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@t "$@" >/dev/null 2>&1; }
git_q init "${FAKE_HOME}/repos/main"
git_q -C "${FAKE_HOME}/repos/main" commit --allow-empty -m init
git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/wt" -b wt
git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/wt2" -b wt2
mg="${FAKE_HOME}/repos/main/.git"
wt_entry="${mg}/worktrees/wt"

# Darwin-shaped (single-arg) worktree flags from the real wrapper helper.
_worktree_flags() {
    ( cd "${FAKE_HOME}/repos/wt" && _load_backend && _wrapper_os=Darwin && WRAPPER_FLAGS=() \
        && _wrapper_bind_git_common_dir && printf '%s\n' "${WRAPPER_FLAGS[@]}" )
}
# Render deny rules for the flag list on stdin (one token per line).
_render_from_flags() {
    ( _load_backend
      local -a ro=() rw=()
      local flag path
      while IFS= read -r flag && IFS= read -r path; do
          case "${flag}" in
              --bind) rw+=("${path}") ;;
              --ro-bind) ro+=("${path}") ;;
          esac
      done
      _append_ro_deny_rules test "${FAKE_HOME}" "${ro[@]}" -- "${rw[@]+"${rw[@]}"}" )
}
_render() { ( _load_backend; _append_ro_deny_rules test "${FAKE_HOME}" "$@" ) 2>&1; }

# ---------------------------------------------------------------------------
echo "-- rule rendering for the worktree bind list"
flags="$(_worktree_flags 2>&1)"
assert_not_contains "${flags}" "WARN" "worktree bind on Darwin: no 'hooks and config are writable' WARN"
rules="$(printf '%s\n' "${flags}" | _render_from_flags 2>&1)"
echo "  (rendered rules:${rules})"
assert_contains "${rules}" "(deny ${DENY_OPS} (literal \"${mg}/config\"))" "config: literal write deny"
assert_contains "${rules}" "(deny ${DENY_OPS} (subpath \"${mg}/hooks\"))" "hooks/: subpath write deny without exceptions (broader RW common dir is no exception)"
wt_re="$( _load_backend; _regex_escape "${wt_entry}" )"
assert_contains "${rules}" "(deny ${DENY_OPS} (require-all (subpath \"${mg}/worktrees\") (require-not (regex #\"^${wt_re}/\"))))" \
    "worktrees/: denied except below this worktree's own entry"
assert_contains "${rules}" "(deny ${DENY_OPS} (literal \"${wt_entry}/commondir\"))" "own commondir: literal write deny"
assert_contains "${rules}" "(deny ${DENY_OPS} (literal \"${wt_entry}/gitdir\"))" "own gitdir: literal write deny"
assert_not_contains "${rules}" "(subpath \"${mg}\")" "the RW common dir itself is not write-denied as a subpath"
pins="$(printf '%s\n' "${rules}" | grep '^(deny file-write\* (literal' || true)"
assert_contains "${pins}" "(literal \"${wt_entry}\")" "own entry dir pinned (cannot be renamed away and back)"
assert_contains "${pins}" "(literal \"${mg}\")" "common dir pinned"
assert_contains "${pins}" "(literal \"${mg}/worktrees\")" "worktrees/ pinned"
assert_eq "$(printf '%s\n' "${rules}" | grep -c '^(deny file-write\* (literal')" "1" "ancestor pins rendered once, de-duplicated"
assert_contains "${pins}" "(literal \"${FAKE_HOME}/repos\")" "ancestor below \$HOME pinned"
assert_not_contains "${pins}" "(literal \"${FAKE_HOME}\")" "\$HOME itself is not pinned"
assert_not_contains "${pins}" "(literal \"${FAKE_HOME%/*}\")" "\$HOME's parent is not pinned"

# Reversed and duplicated bind lists render the same rules: the
# precedence does not depend on flag order.
reversed="$(printf '%s\n' "${flags}" | paste - - | tail -r 2>/dev/null || printf '%s\n' "${flags}" | paste - - | tac)"
rules_rev="$(printf '%s\n' "${reversed}" | tr '\t' '\n' | _render_from_flags 2>&1)"
assert_eq "$(printf '%s\n' "${rules_rev}" | grep -v '^(deny file-write\* (literal' | sort)" \
    "$(printf '%s\n' "${rules}" | grep -v '^(deny file-write\* (literal' | sort)" "reversed bind order renders the same deny rules"
rules_dup="$(printf '%s\n%s\n%s\n' "${flags}" --bind "${mg}" | _render_from_flags 2>&1)"
assert_contains "${rules_dup}" "(deny ${DENY_OPS} (literal \"${mg}/config\"))" "trailing duplicate RW common dir does not reopen config"

echo "-- rule rendering edge cases"
mkdir -p "${FAKE_HOME}/area/rw/deeper" "${FAKE_HOME}/area/other"
: >"${FAKE_HOME}/area/file"
out="$(_render "${FAKE_HOME}/area" -- "${FAKE_HOME}/area")"
assert_contains "${out}" "(deny ${DENY_OPS} (subpath \"${FAKE_HOME}/area\"))" "equal RO and RW bind: RO wins"
out="$(_render "${FAKE_HOME}/area/rw" -- "${FAKE_HOME}")"
assert_contains "${out}" "(deny ${DENY_OPS} (subpath \"${FAKE_HOME}/area/rw\"))" "broader RW bind: RO wins"
out="$(_render "${FAKE_HOME}/area" -- "${FAKE_HOME}/area/file")"
assert_contains "${out}" "(require-not (literal \"${FAKE_HOME}/area/file\"))" "nested RW file: literal exception"
out="$(_render "${FAKE_HOME}/area" -- "${FAKE_HOME}/area/missing/deeper" 2>&1)"; rc=$?
assert_eq "${rc}" "1" "unresolvable RW path fails closed (rc)"
assert_contains "${out}" "Could not resolve --bind path" "... with the resolve error"
out="$(_render "${FAKE_HOME}/area/missing/deeper")"; rc=$?
assert_eq "${rc}" "1" "unresolvable RO path fails closed (rc)"
assert_contains "${out}" "Could not resolve --ro-bind path" "... with the resolve error"
mkdir -p "${FAKE_HOME}/area/bad(dir"
out="$(_render "${FAKE_HOME}/area/bad(dir")"; rc=$?
assert_eq "${rc}" "1" "SBPL-unsafe RO path is rejected"
mkdir -p "${FAKE_HOME}/area/dot.dir/x"
out="$(_render "${FAKE_HOME}/area" -- "${FAKE_HOME}/area/dot.dir")"
assert_contains "${out}" "#\"^${FAKE_HOME//./\\.}/area/dot\\.dir/\"" "regex exception escapes '.' in the path"
out="$( _load_backend; _append_ro_deny_rules test "" "${FAKE_HOME}/area/rw" 2>&1 )"
assert_contains "${out}" "(literal \"${FAKE_HOME}/area\")" "empty HOME: ancestors still pinned"
ln -s "${FAKE_HOME}/area/other" "${FAKE_HOME}/area-link"
out="$(_render "${FAKE_HOME}/area-link")"
assert_contains "${out}" "(subpath \"${FAKE_HOME}/area/other\")" "symlinked RO path is denied at its canonical target"

echo "-- --pin rendering (_append_pin_rules)"
out="$( _load_backend; _append_pin_rules test "${FAKE_HOME}" "${FAKE_HOME}/area/rw" 2>&1 )"
assert_eq "${out}" "${NL}(deny file-write* (literal \"${FAKE_HOME}/area/rw\") (literal \"${FAKE_HOME}/area\"))" \
    "pin: literal write deny on the path and its ancestors below \$HOME only"
out="$( _load_backend; _append_pin_rules test "${FAKE_HOME}" "${FAKE_HOME}/area/missing/deeper" 2>&1 )"; rc=$?
assert_eq "${rc}" "1" "pin: unresolvable path fails closed"
assert_contains "${out}" "Could not resolve --pin path" "... with the resolve error"

# ---------------------------------------------------------------------------
echo "-- backend wiring (AI_SANDBOX_DRYRUN)"
STUB_BIN="${FAKE_HOME}/stub-bin"
mkdir -p "${STUB_BIN}" "${FAKE_HOME}/project/ro-sub" "${FAKE_HOME}/extra-rw" "${FAKE_HOME}/ext-ro" "${FAKE_HOME}/ext-rw"
dry_path="${PATH}"
if [[ "${OS}" != "Darwin" ]]; then
    # Mocked: off macOS the backend only renders; nothing is enforced.
    mkdir -p "${FAKE_HOME}/darwin/T" "${FAKE_HOME}/darwin/C"
    printf '#!/bin/sh\necho "stub sandbox-exec must not run" >&2\nexit 99\n' >"${STUB_BIN}/sandbox-exec"
    printf '#!/bin/sh\ncase "$1" in DARWIN_USER_TEMP_DIR) echo "%s/darwin/T/";; DARWIN_USER_CACHE_DIR) echo "%s/darwin/C/";; *) exit 1;; esac\n' \
        "${FAKE_HOME}" "${FAKE_HOME}" >"${STUB_BIN}/getconf"
    chmod +x "${STUB_BIN}/sandbox-exec" "${STUB_BIN}/getconf"
    dry_path="${STUB_BIN}:${PATH}"
    echo "  (mocked: getconf and sandbox-exec stubbed on ${OS}; generated profile only)"
fi
_dryrun() {
    ( cd "${FAKE_HOME}/project" && PATH="${dry_path}" && _load_backend \
        && AI_SANDBOX_DRYRUN=1 _run_sandboxed_agent_impl /bin/echo "$@" ) 2>&1
}
out="$(AI_SANDBOX_EXTRA_RO_DIRS="${FAKE_HOME}/project/ro-sub" AI_SANDBOX_EXTRA_RW_DIRS="${FAKE_HOME}/extra-rw" \
    _dryrun -- --bind "${mg}" --ro-bind "${mg}/config" -- hi)"
rc=$?
assert_eq "${rc}" "0" "dry-run with RO binds renders"
profile="${out#*=== Rendered SBPL profile ===}"
# git/realpath lstat() every component of a path; a HOME below
# /Users/<name> (like this FAKE_HOME) needs stat on its own ancestors.
assert_contains "${profile}" "(allow file-read-metadata (literal \"${FAKE_HOME%/*}\"))" "HOME's parent gets a stat-only grant"
assert_not_contains "${profile}" "(deny file-write* (literal \"${FAKE_HOME%/*}\"" "HOME's parent is not write-pinned"
assert_contains "${profile}" "(allow file-read* (literal \"${mg}/config\"))" "--ro-bind keeps its read allow"
assert_contains "${profile}" "(deny ${DENY_OPS} (literal \"${mg}/config\"))" "--ro-bind under an RW --bind is write-denied"
assert_contains "${profile}" "(deny ${DENY_OPS} (subpath \"${FAKE_HOME}/project/ro-sub\"))" "AI_SANDBOX_EXTRA_RO_DIRS inside WORKDIR is write-denied"
assert_not_contains "$(printf '%s\n' "${profile}" | grep '^(deny' || true)" "${FAKE_HOME}/extra-rw" "AI_SANDBOX_EXTRA_RW_DIRS gets no deny rule"
last_allow="$(printf '%s\n' "${profile}" | grep -n '^(allow' | tail -1 | cut -d: -f1)"
first_deny="$(printf '%s\n' "${profile}" | grep -nF "(deny ${DENY_OPS}" | head -1 | cut -d: -f1)"
order_ok=0; [[ -n "${last_allow}" && -n "${first_deny}" && "${first_deny}" -gt "${last_allow}" ]] && order_ok=1
assert_eq "${order_ok}" "1" "write-deny rules are rendered after every allow rule"
out="$(_dryrun -- --bind "${mg}" -- hi)"
profile="${out#*=== Rendered SBPL profile ===}"
assert_not_contains "${profile}" "(deny ${DENY_OPS}" "no --ro-bind: no write-deny rules"
assert_not_contains "${profile}" "(deny file-write*" "no --ro-bind / --pin: no pin rules"
# --pin alone (relaxed WORKDIR git metadata: no RO child to derive a pin).
out="$(_dryrun -- --pin "${FAKE_HOME}/project/ro-sub" -- hi)"; rc=$?
assert_eq "${rc}" "0" "dry-run with --pin renders"
profile="${out#*=== Rendered SBPL profile ===}"
assert_contains "${profile}" "(deny file-write* (literal \"${FAKE_HOME}/project/ro-sub\") (literal \"${FAKE_HOME}/project\"))" "--pin renders a literal write deny on the path and WORKDIR"
assert_not_contains "${profile}" "(allow file-read* (literal \"${FAKE_HOME}/project/ro-sub\"))" "--pin grants nothing"
last_allow="$(printf '%s\n' "${profile}" | grep -n '^(allow' | tail -1 | cut -d: -f1)"
first_pin="$(printf '%s\n' "${profile}" | grep -nF "(deny file-write* (literal \"${FAKE_HOME}/project/ro-sub\")" | head -1 | cut -d: -f1)"
order_ok=0; [[ -n "${last_allow}" && -n "${first_pin}" && "${first_pin}" -gt "${last_allow}" ]] && order_ok=1
assert_eq "${order_ok}" "1" "--pin rule rendered after every allow rule"
out="$(_dryrun -- --pin "${FAKE_HOME}/nope" -- hi)"; rc=$?
assert_eq "${rc}" "1" "missing --pin source fails"
assert_contains "${out}" "--pin source missing" "... with the source-missing message"

# _extra_sandbox_setup (AI_WRAPPER_EXTRA_PROFILE callback) keeps appending
# to binds_ro / binds_rw, and its RO entries are enforced too.
_ext_dryrun() {
    ( cd "${FAKE_HOME}/project" && PATH="${dry_path}" && _load_backend
      # shellcheck disable=SC2317,SC2329  # invoked by the backend
      _extra_sandbox_setup() { binds_ro+=("${FAKE_HOME}/project/ro-sub"); binds_rw+=("${FAKE_HOME}/ext-rw"); binds_pin+=("${FAKE_HOME}/ext-rw"); }
      AI_SANDBOX_DRYRUN=1 _run_sandboxed_agent_impl /bin/echo -- -- hi ) 2>&1
}
out="$(_ext_dryrun)"
profile="${out#*=== Rendered SBPL profile ===}"
assert_contains "${profile}" "(deny file-write* (literal \"${FAKE_HOME}/ext-rw\"))" "extension hook: binds_pin rendered"
assert_contains "${profile}" "(allow file* (subpath \"${FAKE_HOME}/ext-rw\"))" "extension hook: binds_rw still rendered"
assert_contains "${profile}" "(deny ${DENY_OPS} (subpath \"${FAKE_HOME}/project/ro-sub\"))" "extension hook: binds_ro write-denied"

# Flag parsing and validation are unchanged.
out="$(_dryrun -- --ro-bind "${FAKE_HOME}/nope" -- hi)"; rc=$?
assert_eq "${rc}" "1" "missing --ro-bind source still fails"
assert_contains "${out}" "--ro-bind source missing" "... with the same message"
out="$(_dryrun -- --ro-bind -- hi)"; rc=$?
assert_eq "${rc}" "2" "--ro-bind without SRC still rejected"

# ---------------------------------------------------------------------------
echo "-- native sandbox-exec enforcement"
if [[ "${OS}" != "Darwin" ]]; then
    echo "  skip - native Seatbelt checks need macOS (Linux enforcement: tests/test_bind_hardening.bash)"
elif ! command -v sandbox-exec >/dev/null 2>&1; then
    _test_report 0 "sandbox-exec available on macOS (native enforcement cannot be certified)"
else
    # Writes run inside the sandbox; results are judged by host-side bytes.
    _native() {
        ( cd "${FAKE_HOME}/repos/wt" && _load_backend && _run_sandboxed_agent_impl /bin/sh "$@" ) 2>&1
    }
    _write_probe() { printf 'for f in "$@"; do (echo probe >>"$f") 2>/dev/null && echo "WROTE:$f" || echo "DENIED:$f"; done'; }
    config_before="$(cksum <"${mg}/config")"
    # Worktree flags exactly as the wrapper builds them, then reversed, then
    # with a trailing RW grant on the whole common dir.
    flag_list=()
    while IFS= read -r line; do flag_list+=("${line}"); done < <(printf '%s\n' "${flags}" | grep -v WARN)
    rev_list=()
    while IFS=$'\t' read -r f p; do rev_list+=("${f}" "${p}"); done < <(printf '%s\n' "${reversed}")
    for variant in wrapper reversed dup-rw; do
        case "${variant}" in
            wrapper)  vflags=("${flag_list[@]}") ;;
            reversed) vflags=("${rev_list[@]}") ;;
            dup-rw)   vflags=("${flag_list[@]}" --bind "${mg}") ;;
        esac
        out="$(_native -- "${vflags[@]}" -- -c "$(_write_probe)" _ \
            "${mg}/config" "${mg}/worktrees/wt2/commondir" "${wt_entry}/gitdir" "${wt_entry}/probe-file" "${mg}/objects/probe-file")"
        echo "  (native ${variant} output: ${out})"
        for f in "${mg}/config" "${mg}/worktrees/wt2/commondir" "${wt_entry}/gitdir"; do
            assert_contains "${out}" "DENIED:${f}" "native ${variant}: write to ${f#"${mg}"/} denied"
        done
        for f in "${wt_entry}/probe-file" "${mg}/objects/probe-file"; do
            assert_contains "${out}" "WROTE:${f}" "native ${variant}: write to ${f#"${mg}"/} allowed"
        done
        rm -f "${wt_entry}/probe-file" "${mg}/objects/probe-file"
    done
    assert_eq "$(cksum <"${mg}/config")" "${config_before}" "native: config bytes unchanged on the host"

    # Path discovery works inside the sandbox with the RO denies in place:
    # git lstat()s every component from / down (CI once failed here with
    # "Invalid path '<HOME parent>': Operation not permitted").
    out="$(_native -- "${flag_list[@]}" -- -c 'git rev-parse --git-common-dir --absolute-git-dir && stat "$1" >/dev/null && echo STAT_OK' _ "${FAKE_HOME%/*}")"
    echo "  (native discovery output: ${out})"
    assert_contains "${out}" "${mg}${NL}${wt_entry}" "native: git rev-parse resolves the common dir and own entry"
    assert_contains "${out}" "STAT_OK" "native: stat on HOME's parent works"
    assert_not_contains "${out}" "Invalid path" "native: no realpath EPERM"

    # Synthetic probe of the ancestor pin alone: RW area, RO area/sub/ro.
    # area/sub is pinned (literal write deny). It must stay stat-able and
    # listable, its other children writable, and only the dir itself
    # immovable.
    pin_area="${FAKE_HOME}/pin-area"
    mkdir -p "${pin_area}/sub/ro"
    out="$(_native -- --bind "${pin_area}" --ro-bind "${pin_area}/sub/ro" -- -c '
        stat "$1/sub" >/dev/null && echo PIN_STAT_OK
        ls "$1/sub" >/dev/null && echo PIN_LS_OK
        (echo x >"$1/sub/sibling") 2>/dev/null && echo PIN_CHILD_WROTE
        mkdir "$1/sub/newdir" 2>/dev/null && echo PIN_MKDIR_OK
        mv "$1/sub" "$1/moved" 2>/dev/null && echo PIN_MOVED
        (echo x >"$1/sub/ro/x") 2>/dev/null && echo RO_WROTE
        echo PIN_PROBE_DONE' _ "${pin_area}")"
    echo "  (native pin probe output: ${out})"
    for ok in PIN_STAT_OK PIN_LS_OK PIN_CHILD_WROTE PIN_MKDIR_OK PIN_PROBE_DONE; do
        assert_contains "${out}" "${ok}" "native pin probe: ${ok}"
    done
    assert_not_contains "${out}" "PIN_MOVED" "native pin probe: pinned ancestor cannot be renamed"
    assert_not_contains "${out}" "RO_WROTE" "native pin probe: RO subtree write denied"
    pin_ok=0; [[ -d "${pin_area}/sub/ro" && ! -e "${pin_area}/sub/ro/x" && -f "${pin_area}/sub/sibling" ]] && pin_ok=1
    assert_eq "${pin_ok}" "1" "native pin probe: host state matches (RO dir untouched, sibling written)"

    # --pin alone (no RO child): the directory cannot be moved or removed,
    # its children stay writable.
    pin_only="${FAKE_HOME}/pin-only"
    mkdir -p "${pin_only}/root"
    out="$(_native -- --bind "${pin_only}" --pin "${pin_only}/root" -- -c '
        (echo x >"$1/root/child") 2>/dev/null && echo PINONLY_CHILD_WROTE
        mkdir "$1/root/sub" 2>/dev/null && echo PINONLY_MKDIR_OK
        mv "$1/root" "$1/moved" 2>/dev/null && echo PINONLY_MOVED
        rm -rf "$1/root" 2>/dev/null; [ -d "$1/root" ] || echo PINONLY_REMOVED
        echo PINONLY_DONE' _ "${pin_only}")"
    echo "  (native --pin probe output: ${out})"
    for ok in PINONLY_CHILD_WROTE PINONLY_MKDIR_OK PINONLY_DONE; do
        assert_contains "${out}" "${ok}" "native --pin probe: ${ok}"
    done
    assert_not_contains "${out}" "PINONLY_MOVED" "native --pin probe: pinned dir cannot be renamed"
    assert_not_contains "${out}" "PINONLY_REMOVED" "native --pin probe: pinned dir cannot be removed"
    pin_ok=0; [[ -d "${pin_only}/root" && ! -e "${pin_only}/moved" ]] && pin_ok=1
    assert_eq "${pin_ok}" "1" "native --pin probe: pinned dir still in place on the host"

    # AI_SANDBOX_EXTRA_RO_DIRS inside WORKDIR, and an RW extra dir equal to
    # the common dir, are enforced.
    mkdir -p "${FAKE_HOME}/repos/wt/ro-sub"
    out="$(AI_SANDBOX_EXTRA_RO_DIRS="${FAKE_HOME}/repos/wt/ro-sub" AI_SANDBOX_EXTRA_RW_DIRS="${mg}" \
        _native -- "${flag_list[@]}" -- -c "$(_write_probe)" _ \
        "${FAKE_HOME}/repos/wt/ro-sub/x" "${FAKE_HOME}/repos/wt/rw-file" "${mg}/config")"
    echo "  (native extra-dirs output: ${out})"
    assert_contains "${out}" "DENIED:${FAKE_HOME}/repos/wt/ro-sub/x" "native: AI_SANDBOX_EXTRA_RO_DIRS inside WORKDIR is read-only"
    assert_contains "${out}" "WROTE:${FAKE_HOME}/repos/wt/rw-file" "native: rest of WORKDIR stays writable"
    assert_contains "${out}" "DENIED:${mg}/config" "native: AI_SANDBOX_EXTRA_RW_DIRS=<common dir> does not reopen config"
    rm -f "${FAKE_HOME}/repos/wt/rw-file"

    # _extra_sandbox_setup binds are enforced natively.
    out="$( cd "${FAKE_HOME}/repos/wt" && _load_backend
        # shellcheck disable=SC2317,SC2329  # invoked by the backend
        _extra_sandbox_setup() { binds_ro+=("${FAKE_HOME}/repos/wt/ro-sub"); binds_rw+=("${FAKE_HOME}/ext-rw"); }
        _run_sandboxed_agent_impl /bin/sh -- -- -c "$(_write_probe)" _ \
            "${FAKE_HOME}/repos/wt/ro-sub/y" "${FAKE_HOME}/ext-rw/z" 2>&1 )"
    echo "  (native extension-hook output: ${out})"
    assert_contains "${out}" "DENIED:${FAKE_HOME}/repos/wt/ro-sub/y" "native extension hook: binds_ro is read-only"
    assert_contains "${out}" "WROTE:${FAKE_HOME}/ext-rw/z" "native extension hook: binds_rw is writable"
fi

assert_no_live_client_reached
tests_summary_and_exit
