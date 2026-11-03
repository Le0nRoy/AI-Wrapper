#!/bin/bash
# Retires the installed Cursor Agent wrapper (#43). Its source entries are
# gone, but chezmoi never deletes a deployed file once its source entry is
# removed, so the launcher, its lib and its help file linger — in
# ~/ai-wrapper/bin/ and, on old standalone installs, in ~/bin/, which comes
# first on PATH and would keep shadowing the supported wrappers.
#
# Only those three artifacts are touched, in both layouts:
#   - a regular file whose SHA-256 matches a shipped version is removed;
#   - a modified or unrecognised file, or a symlink (moved as a link, its
#     target untouched), is archived under
#     ~/ai-wrapper/.retired-cursor-wrapper/<run>/<path relative to HOME>;
#   - anything else (e.g. a directory) is reported and left alone.
# Shared directories, Cursor's own state (~/.cursor, ~/.config/cursor,
# ~/.local/share/cursor-agent), saved presets and the cursor-agent package
# are never touched. Failures are reported and make the script exit 1, so
# chezmoi retries it on the next apply; a rerun after success is a no-op.
#
# Deliberately separate from run_once_remove_stale_pre_split_bin_files.bash:
# editing that one would re-run its `rm -rf ~/bin/ai_wrapper_data`.
#
# Usage:
#   bash run_once_retire_cursor_wrapper.bash          # retire
#   bash run_once_retire_cursor_wrapper.bash --dry    # preview, change nothing

set -uo pipefail

LAYOUT_ROOTS=(
    "${HOME}/ai-wrapper/bin"
    "${HOME}/bin"
)
ARTIFACTS=(
    cursor_agent_wrapper.bash
    ai_wrapper_data/cursor_wrapper_lib.bash
    ai_wrapper_data/cursor-help.md
)
ARCHIVE_ROOT="${HOME}/ai-wrapper/.retired-cursor-wrapper"

# SHA-256 of every version of ARTIFACT ever committed (git log --all).
canonical_hashes() {
    case "${1}" in
        cursor_agent_wrapper.bash)
            echo 3439a370d630c661a6ce72fe639a0b0bc07f171026988cbda52a938adac8d9a9  # e55b349
            echo 92b8b3efb5f42568e582a622c9997f18375e6cae716d2b4079f634698e286524  # 0f09896
            echo c8a0569cd26341f5d68bd7f6121486b757e9dcab6e0b236d5c93a455d9e36ef9  # 3b7cf94
            echo b85ca7a445d1bc7139cc9206d3666bcccb58e0c6aa0c58b9c3287faafb107196  # 9434872
            echo dcf11c2e0a3d9a0f37f1ec14472d6b86ef280ba09a064a764b018519385e3ea9  # 8c3e67b
            echo 4f11308deb2d3016d0ac4ea22f907970085b80417dcf558a2106ce77b0ac4531  # e25a325
            ;;
        ai_wrapper_data/cursor_wrapper_lib.bash)
            echo e45b40249a050429abc29614f6667762c473f1590ab6e6c01732bf7e43cd4ed6  # e55b349
            echo 4e0786df449b87557d3a3b617975bc56d6c74e3298111ced2e22cacbdc50b9f5  # 0f09896
            echo 12c92dc22f269ed8054dd665e84f8291d36a3abd0fd6988be0f31cd5aaa26577  # 8c3e67b
            ;;
        ai_wrapper_data/cursor-help.md)
            echo fc3967d92a2d0530e1c967b9da843294db7f3a5b4b9f616471cff70a0eb4fc66  # e55b349
            echo e7ccb274b2f24188c379d509dbf71bef351007eb58abcecedfb62b199a8425e8  # 0f09896
            echo b0c7067057b99cff0a7ee5ee0585786f868de11101730e376d78862d5dabc6ed  # 8c3e67b
            ;;
    esac
}

# Print the SHA-256 of FILE; empty when no hashing tool is available, which
# makes every file count as unrecognised (archived, never deleted).
file_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${1}" 2>/dev/null | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${1}" 2>/dev/null | cut -d' ' -f1
    fi
}

is_canonical() {
    local artifact="${1}" path="${2}" digest
    digest="$(file_sha256 "${path}")"
    [[ -n "${digest}" ]] || return 1
    canonical_hashes "${artifact}" | grep -qx "${digest}"
}

dry=0
for arg in "$@"; do
    case "${arg}" in
        --dry|--dry-run) dry=1 ;;
        -h|--help) sed -n '2,24s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "ERROR: unknown argument: ${arg}" >&2; exit 2 ;;
    esac
done

run_archive="${ARCHIVE_ROOT}/$(date -u +%Y%m%dT%H%M%SZ)-$$"
removed=0
archived=0
failed=0

remove_artifact() {
    local path="${1}"
    if [[ "${dry}" -eq 1 ]]; then
        echo "Would remove ${path}"
        return
    fi
    if rm -f "${path}" && [[ ! -e "${path}" ]]; then
        echo "Removed ${path}"
        removed=$((removed + 1))
    else
        echo "ERROR: failed to remove ${path}" >&2
        failed=$((failed + 1))
    fi
}

archive_artifact() {
    local path="${1}" dest="${run_archive}/${1#"${HOME}"/}"
    if [[ "${dry}" -eq 1 ]]; then
        echo "Would archive ${path} -> ${dest}"
        return
    fi
    if [[ ! -e "${dest}" && ! -L "${dest}" ]] \
        && mkdir -p "$(dirname "${dest}")" && mv "${path}" "${dest}"; then
        echo "Archived ${path} -> ${dest}"
        archived=$((archived + 1))
    else
        echo "ERROR: failed to archive ${path} to ${dest}; left in place" >&2
        failed=$((failed + 1))
    fi
}

for root in "${LAYOUT_ROOTS[@]}"; do
    for artifact in "${ARTIFACTS[@]}"; do
        path="${root}/${artifact}"
        if [[ -L "${path}" ]]; then
            archive_artifact "${path}"
        elif [[ -f "${path}" ]]; then
            if is_canonical "${artifact}" "${path}"; then
                remove_artifact "${path}"
            else
                archive_artifact "${path}"
            fi
        elif [[ -e "${path}" ]]; then
            echo "WARNING: ${path} is not a regular file or symlink; left in place" >&2
        fi
    done
done

if [[ $((removed + archived + failed)) -gt 0 ]]; then
    echo "Cursor wrapper retirement: ${removed} removed, ${archived} archived, ${failed} failed"
fi
[[ "${failed}" -eq 0 ]]
