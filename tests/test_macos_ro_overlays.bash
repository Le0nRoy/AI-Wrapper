#!/bin/bash
# macOS (Seatbelt) enforcement of --ro-bind nested under an RW --bind or
# WORKDIR (issue #11). The backend renders --ro-bind as an allow-read plus
# a trailing (deny file-write* ...) rule; see _append_ro_deny_rules in
# bin/ai_wrapper_data/macos_sandbox_exec.bash.
#
# Three layers:
#   1. rule rendering (_append_ro_deny_rules) for a nested bind list (an RO
#      tree with RW data dirs inside it and RO files inside an RW child) —
#      any OS; plus the real Darwin git bind list, which has no RO entries
#      (the git dir is fully writable, docs/security-concerns.md B-ρ) and
#      is an --under-bind: never an exception to an RO write deny, so an
#      RO overlay equal to, inside or holding the git dir stays read-only;
#   2. backend wiring via AI_SANDBOX_DRYRUN (--ro-bind, AI_SANDBOX_EXTRA_*,
#      _extra_sandbox_setup) — native on macOS; off macOS getconf and
#      sandbox-exec are stubbed, so it checks generated text only;
#   3. native sandbox-exec writes (ordering, extension hook, extra dirs,
#      git in a linked worktree with its shared .git writable, RO overlays
#      on top of an --under-bind) — macOS only, and a missing sandbox-exec
#      there is a failure.
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
git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/main/wt" -b wt
git_q -C "${FAKE_HOME}/repos/main" worktree add "${FAKE_HOME}/repos/main/wt2" -b wt2
mg="${FAKE_HOME}/repos/main/.git"
wt_entry="${mg}/worktrees/wt"

# Darwin-shaped (single-arg) git flags from the real wrapper helper.
_git_flags() {
    ( cd "${FAKE_HOME}/repos/main/wt" && _load_backend && _wrapper_os=Darwin && WRAPPER_FLAGS=() \
        && _wrapper_bind_git_common_dir && printf '%s\n' "${WRAPPER_FLAGS[@]}" )
}
# Nested RO/RW bind list over the worktree fixture: the common dir RO, its
# data dirs and one worktree entry RW, the entry's link files RO again.
_nested_flags() {
    printf '%s\n' --ro-bind "${mg}" --bind "${mg}/objects" --bind "${mg}/refs" --bind "${mg}/logs" \
        --bind "${wt_entry}" --ro-bind "${wt_entry}/commondir" --ro-bind "${wt_entry}/gitdir"
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
echo "-- git bind list on Darwin: the shared .git is fully writable"
git_flags="$(_git_flags 2>&1)"
assert_not_contains "${git_flags}" "WARN" "worktree git bind on Darwin: no WARN"
assert_contains "${git_flags}" "--under-bind${NL}${mg}${NL}" "worktree git bind on Darwin: shared .git bound RW (--under-bind)"
assert_not_contains "${git_flags}" "--ro-bind" "worktree git bind on Darwin: no read-only overlay"
assert_not_contains "${git_flags}" "--pin" "worktree git bind on Darwin: no pin"
assert_eq "$(printf '%s\n' "${git_flags}" | _render_from_flags 2>&1)" "" "worktree git bind on Darwin: no deny rules rendered"

echo "-- rule rendering for a nested RO/RW bind list"
flags="$(_nested_flags)"
rules="$(printf '%s\n' "${flags}" | _render_from_flags 2>&1)"
echo "  (rendered rules:${rules})"
# The RO root is denied as a whole with exceptions only for the RW
# children nested strictly inside it.
_re() { ( _load_backend; _regex_escape "${1}" ); }
mg_rule="(deny ${DENY_OPS} (require-all (subpath \"${mg}\")"
for rw in "${mg}/objects" "${mg}/refs" "${mg}/logs" "${wt_entry}"; do
    mg_rule+=" (require-not (regex #\"^$(_re "${rw}")/\"))"
done
mg_rule+="))"
assert_contains "${rules}" "${mg_rule}" "RO root: subpath write deny except the nested RW dirs"
assert_eq "$(printf '%s\n' "${rules}" | grep -c "(subpath \"${mg}\")")" "1" "RO root: exactly one subpath rule"
assert_contains "${rules}" "(deny ${DENY_OPS} (literal \"${wt_entry}/commondir\"))" "RO file inside an RW child: literal write deny"
assert_contains "${rules}" "(deny ${DENY_OPS} (literal \"${wt_entry}/gitdir\"))" "second RO file inside an RW child: literal write deny"
pins="$(printf '%s\n' "${rules}" | grep '^(deny file-write\* (literal' || true)"
assert_contains "${pins}" "(literal \"${wt_entry}\")" "RW child holding RO files pinned (cannot be renamed away and back)"
assert_contains "${pins}" "(literal \"${mg}/objects\")" "nested RW dir pinned"
assert_contains "${pins}" "(literal \"${mg}\")" "RO root pinned"
assert_contains "${pins}" "(literal \"${mg}/worktrees\")" "intermediate dir pinned"
assert_eq "$(printf '%s\n' "${rules}" | grep -c '^(deny file-write\* (literal')" "1" "ancestor pins rendered once, de-duplicated"
assert_contains "${pins}" "(literal \"${FAKE_HOME}/repos\")" "ancestor below \$HOME pinned"
assert_not_contains "${pins}" "(literal \"${FAKE_HOME}\")" "\$HOME itself is not pinned"
assert_not_contains "${pins}" "(literal \"${FAKE_HOME%/*}\")" "\$HOME's parent is not pinned"

# Reversed and duplicated bind lists render the same rules: the
# precedence does not depend on flag order.
reversed="$(printf '%s\n' "${flags}" | paste - - | tail -r 2>/dev/null || printf '%s\n' "${flags}" | paste - - | tac)"
rules_rev="$(printf '%s\n' "${reversed}" | tr '\t' '\n' | _render_from_flags 2>&1)"
# Exceptions inside one rule follow the RW flag order; compare them as a
# set (Seatbelt's require-all does not depend on their order).
_norm_rules() { grep -v '^(deny file-write\* (literal' | sed 's/ (require-not/\n&/g' | sed 's/)*$//' | sort; }
assert_eq "$(printf '%s\n' "${rules_rev}" | _norm_rules)" \
    "$(printf '%s\n' "${rules}" | _norm_rules)" "reversed bind order renders the same deny rules"
rules_dup="$(printf '%s\n%s\n%s\n' "${flags}" --bind "${mg}" | _render_from_flags 2>&1)"
assert_contains "${rules_dup}" "${mg_rule}" "trailing duplicate RW grant on the RO root does not reopen it"

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

echo "-- client persistent controls rendering (_wrapper_protect_client_controls, #86)"
CC="${FAKE_HOME}/.cc-client"
mkdir -p "${CC}/skills/s1" "${CC}/plugins" "${CC}/sessions" "${FAKE_HOME}/repos/cc-wd"
echo '{}' >"${CC}/settings.json"
echo x >"${CC}/plugins/config.json"
# Darwin flags from the real helper, rendered as the backend would: RO
# denies (base RW bind as the only RW path) plus pin rules.
_cc_rules() {
    ( cd "${FAKE_HOME}/repos/cc-wd" && _load_backend && _wrapper_os=Darwin && WRAPPER_FLAGS=() || exit 99
      _wrapper_protect_client_controls t "${CC}" "" settings.json skills plugins/config.json hooks || exit 98
      local -a ro=() pin=()
      set -- "${WRAPPER_FLAGS[@]+"${WRAPPER_FLAGS[@]}"}"
      while [[ $# -gt 0 ]]; do
          case "${1}" in
              --ro-bind) ro+=("${2}") ;;
              --pin) pin+=("${2}") ;;
          esac
          shift 2
      done
      [[ ${#ro[@]} -gt 0 ]] && _append_ro_deny_rules test "${FAKE_HOME}" "${ro[@]}" -- "${CC}"
      [[ ${#pin[@]} -gt 0 ]] && _append_pin_rules test "${FAKE_HOME}" "${pin[@]}"
      true ) 2>&1
}
out="$(_cc_rules)"
assert_contains "${out}" "(deny ${DENY_OPS} (literal \"${CC}/settings.json\"))" "controls: settings.json write-denied as a literal"
assert_contains "${out}" "(deny ${DENY_OPS} (subpath \"${CC}/skills\"))" "controls: skills/ write-denied as a subpath"
assert_contains "${out}" "(deny ${DENY_OPS} (literal \"${CC}/plugins/config.json\"))" "controls: nested plugins/config.json write-denied"
assert_contains "${out}" "(deny file-write* (literal \"${CC}\")" "controls: profile base pinned"
assert_contains "${out}" "(literal \"${CC}/plugins\")" "controls: intermediate plugins/ pinned"
assert_not_contains "${out}" "${CC}/sessions" "controls: session state not denied"
assert_not_contains "${out}" "${CC}/hooks" "controls: absent hooks/ not rendered"
assert_not_contains "${out}" "(literal \"${FAKE_HOME}\")" "controls: pins stop below \$HOME"
out="$(AI_SANDBOX_ALLOW_SETTINGS=1 _cc_rules)"
assert_not_contains "${out}" "(deny" "AI_SANDBOX_ALLOW_SETTINGS=1: no deny rules for client controls"
assert_contains "${out}" "AI_SANDBOX_ALLOW_SETTINGS=1" "AI_SANDBOX_ALLOW_SETTINGS=1: WARN banner"
rm -rf "${CC}" "${FAKE_HOME}/repos/cc-wd"

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
# --pin alone (a directory with no RO child to derive a pin from).
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

# --under-bind (the git dir): an RW allow that never becomes an exception
# to an --ro-bind write deny, whether the RO path holds it, equals it or
# sits inside it. A plain --bind nested in an RO dir still carves one.
mkdir -p "${FAKE_HOME}/project/ctl/repo/.git/hooks"
ug="${FAKE_HOME}/project/ctl/repo/.git"
out="$(_dryrun -- --under-bind "${ug}" --ro-bind "${FAKE_HOME}/project/ctl" --ro-bind "${ug}/hooks" -- hi)"; rc=$?
assert_eq "${rc}" "0" "dry-run with --under-bind renders"
profile="${out#*=== Rendered SBPL profile ===}"
assert_contains "${profile}" "(allow file* (subpath \"${ug}\"))" "--under-bind: read-write allow on the git dir"
assert_contains "${profile}" "(deny ${DENY_OPS} (subpath \"${FAKE_HOME}/project/ctl\"))" "--under-bind inside an RO dir: plain subpath deny, no exception"
assert_contains "${profile}" "(deny ${DENY_OPS} (subpath \"${ug}/hooks\"))" "RO dir inside an --under-bind: write-denied"
assert_not_contains "$(printf '%s\n' "${profile}" | grep -F "(deny ${DENY_OPS}" || true)" "require-not" "--under-bind: no RO exception in any write deny"
last_allow="$(printf '%s\n' "${profile}" | grep -n '^(allow' | tail -1 | cut -d: -f1)"
first_deny="$(printf '%s\n' "${profile}" | grep -nF "(deny ${DENY_OPS}" | head -1 | cut -d: -f1)"
order_ok=0; [[ -n "${last_allow}" && -n "${first_deny}" && "${first_deny}" -gt "${last_allow}" ]] && order_ok=1
assert_eq "${order_ok}" "1" "--under-bind: write-deny rules rendered after its allow"
out="$(_dryrun -- --under-bind "${ug}" --ro-bind "${ug}" -- hi)"
profile="${out#*=== Rendered SBPL profile ===}"
assert_contains "${profile}" "(deny ${DENY_OPS} (subpath \"${ug}\"))" "--under-bind equal to an RO dir: RO wins"
out="$(_dryrun -- --bind "${ug}" --ro-bind "${FAKE_HOME}/project/ctl" -- hi)"
profile="${out#*=== Rendered SBPL profile ===}"
assert_contains "${profile}" "(require-not (regex #\"^$(_re "${ug}")/\"))" "contrast: a plain --bind inside an RO dir is carved out"
out="$(_dryrun -- --under-bind "${FAKE_HOME}/nope" -- hi)"; rc=$?
assert_eq "${rc}" "1" "missing --under-bind source fails"
assert_contains "${out}" "--under-bind source missing" "... with the source-missing message"
rm -rf "${FAKE_HOME}/project/ctl"

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
        ( cd "${FAKE_HOME}/repos/main/wt" && _load_backend && _run_sandboxed_agent_impl /bin/sh "$@" ) 2>&1
    }
    _write_probe() { printf 'for f in "$@"; do (echo probe >>"$f") 2>/dev/null && echo "WROTE:$f" || echo "DENIED:$f"; done'; }
    config_before="$(cksum <"${mg}/config")"
    # The nested bind list, then reversed, then with a trailing RW grant on
    # the whole RO root.
    flag_list=()
    while IFS= read -r line; do flag_list+=("${line}"); done < <(printf '%s\n' "${flags}" | grep -v WARN)
    rev_list=()
    while IFS=$'\t' read -r f p; do rev_list+=("${f}" "${p}"); done < <(printf '%s\n' "${reversed}")
    for variant in nested reversed dup-rw; do
        case "${variant}" in
            nested)   vflags=("${flag_list[@]}") ;;
            reversed) vflags=("${rev_list[@]}") ;;
            dup-rw)   vflags=("${flag_list[@]}" --bind "${mg}") ;;
        esac
        out="$(_native -- "${vflags[@]}" -- -c "$(_write_probe)" _ \
            "${mg}/config" "${mg}/worktrees/wt2/commondir" "${wt_entry}/gitdir" "${wt_entry}/probe-file" "${mg}/objects/probe-file" \
            "${mg}/commondir" "${mg}/config.worktree")"
        echo "  (native ${variant} output: ${out})"
        for f in "${mg}/config" "${mg}/worktrees/wt2/commondir" "${wt_entry}/gitdir" "${mg}/commondir" "${mg}/config.worktree"; do
            assert_contains "${out}" "DENIED:${f}" "native ${variant}: write to ${f#"${mg}"/} denied"
        done
        for f in "${wt_entry}/probe-file" "${mg}/objects/probe-file"; do
            assert_contains "${out}" "WROTE:${f}" "native ${variant}: write to ${f#"${mg}"/} allowed"
        done
        rm -f "${wt_entry}/probe-file" "${mg}/objects/probe-file"
    done
    planted=0; [[ -e "${mg}/commondir" || -e "${mg}/config.worktree" ]] && planted=1
    assert_eq "${planted}" "0" "native: no commondir or config.worktree created in the common dir on the host"
    assert_eq "$(cksum <"${mg}/config")" "${config_before}" "native: config bytes unchanged on the host"

    # The wrapper's git flags: path discovery works (git lstat()s every
    # component from / down; CI once failed here with "Invalid path '<HOME
    # parent>': Operation not permitted"), and the shared .git is writable
    # as a whole, config and hooks/ included.
    git_flag_list=()
    while IFS= read -r line; do git_flag_list+=("${line}"); done < <(printf '%s\n' "${git_flags}")
    out="$(_native -- "${git_flag_list[@]}" -- -c 'git rev-parse --git-common-dir --absolute-git-dir && stat "$1" >/dev/null && echo STAT_OK
        git -c user.name=t -c user.email=t@t commit -q --allow-empty -m native-rw && echo COMMIT_OK
        git config --local aiw.probe yes && echo CONFIG_OK
        (echo "#!/bin/sh" >"$2/hooks/post-checkout") 2>/dev/null && echo HOOK_OK' _ "${FAKE_HOME%/*}" "${mg}")"
    echo "  (native git output: ${out})"
    assert_contains "${out}" "${mg}${NL}${wt_entry}" "native: git rev-parse resolves the common dir and own entry"
    assert_contains "${out}" "STAT_OK" "native: stat on HOME's parent works"
    assert_not_contains "${out}" "Invalid path" "native: no realpath EPERM"
    for ok in COMMIT_OK CONFIG_OK HOOK_OK; do
        assert_contains "${out}" "${ok}" "native: shared .git writable (${ok})"
    done
    assert_eq "$(git -C "${FAKE_HOME}/repos/main" config --get aiw.probe)" "yes" "native: config change persisted on the host"
    git -C "${FAKE_HOME}/repos/main" config --unset aiw.probe
    rm -f "${mg}/hooks/post-checkout"

    # --under-bind under RO overlays: an RO dir holding the git dir and an
    # RO dir inside it stay read-only; the rest of the git dir is writable.
    ctl="${FAKE_HOME}/ctl-area"
    mkdir -p "${ctl}/repo/.git/hooks" "${ctl}/repo/.git/objects" "${ctl}/other"
    out="$(_native -- --bind "${ctl}/other" --under-bind "${ctl}/repo/.git" --ro-bind "${ctl}/repo/.git/hooks" -- -c "$(_write_probe)" _ \
        "${ctl}/repo/.git/hooks/x" "${ctl}/repo/.git/objects/x")"
    echo "  (native --under-bind output: ${out})"
    assert_contains "${out}" "DENIED:${ctl}/repo/.git/hooks/x" "native --under-bind: RO dir inside it stays read-only"
    assert_contains "${out}" "WROTE:${ctl}/repo/.git/objects/x" "native --under-bind: rest of the git dir writable"
    out="$(_native -- --under-bind "${ctl}/repo/.git" --ro-bind "${ctl}" -- -c "$(_write_probe)" _ "${ctl}/repo/.git/objects/y")"
    assert_contains "${out}" "DENIED:${ctl}/repo/.git/objects/y" "native --under-bind: an RO dir holding it keeps it read-only"
    ok=0; [[ ! -e "${ctl}/repo/.git/hooks/x" && ! -e "${ctl}/repo/.git/objects/y" ]] && ok=1
    assert_eq "${ok}" "1" "native --under-bind: denied files absent on the host"
    rm -rf "${ctl}"

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
    # the RO root of the nested list, are enforced.
    mkdir -p "${FAKE_HOME}/repos/main/wt/ro-sub"
    out="$(AI_SANDBOX_EXTRA_RO_DIRS="${FAKE_HOME}/repos/main/wt/ro-sub" AI_SANDBOX_EXTRA_RW_DIRS="${mg}" \
        _native -- "${flag_list[@]}" -- -c "$(_write_probe)" _ \
        "${FAKE_HOME}/repos/main/wt/ro-sub/x" "${FAKE_HOME}/repos/main/wt/rw-file" "${mg}/config")"
    echo "  (native extra-dirs output: ${out})"
    assert_contains "${out}" "DENIED:${FAKE_HOME}/repos/main/wt/ro-sub/x" "native: AI_SANDBOX_EXTRA_RO_DIRS inside WORKDIR is read-only"
    assert_contains "${out}" "WROTE:${FAKE_HOME}/repos/main/wt/rw-file" "native: rest of WORKDIR stays writable"
    assert_contains "${out}" "DENIED:${mg}/config" "native: AI_SANDBOX_EXTRA_RW_DIRS equal to an RO-bound dir does not reopen it"
    rm -f "${FAKE_HOME}/repos/main/wt/rw-file"

    # _extra_sandbox_setup binds are enforced natively.
    out="$( cd "${FAKE_HOME}/repos/main/wt" && _load_backend
        # shellcheck disable=SC2317,SC2329  # invoked by the backend
        _extra_sandbox_setup() { binds_ro+=("${FAKE_HOME}/repos/main/wt/ro-sub"); binds_rw+=("${FAKE_HOME}/ext-rw"); }
        _run_sandboxed_agent_impl /bin/sh -- -- -c "$(_write_probe)" _ \
            "${FAKE_HOME}/repos/main/wt/ro-sub/y" "${FAKE_HOME}/ext-rw/z" 2>&1 )"
    echo "  (native extension-hook output: ${out})"
    assert_contains "${out}" "DENIED:${FAKE_HOME}/repos/main/wt/ro-sub/y" "native extension hook: binds_ro is read-only"
    assert_contains "${out}" "WROTE:${FAKE_HOME}/ext-rw/z" "native extension hook: binds_rw is writable"
fi

assert_no_live_client_reached
tests_summary_and_exit
