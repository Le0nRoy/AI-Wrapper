#!/usr/bin/env bash
# Copy the skills deployed to ~/.agents/skills/ into ~/.claude/skills/ so
# Claude Code can discover them. Existing entries in ~/.claude/skills/ are
# left untouched — this script never overwrites a non-managed directory, and
# only refreshes copies that carry our marker file (.setup_skills_managed).
#
# Why copies (not symlinks): the sandboxed wrapper binds ~/.claude RW but not
# ~/.agents. macOS sandbox-exec resolves file rules against the canonical
# real path, so a symlink at ~/.claude/skills/foo -> ~/.agents/skills/foo is
# read-denied. Plain copies live inside the already-bound ~/.claude tree and
# work regardless of sandboxing.
#
# Usage:
#   ./setup_skills.bash            # copy missing skills, refresh managed ones
#   ./setup_skills.bash --force    # also overwrite foreign symlinks / dirs
#   ./setup_skills.bash --dry      # show what would happen, change nothing

set -u -o pipefail

SKILLS_SRC="${HOME}/.agents/skills"
SKILLS_DST="${HOME}/.claude/skills"
MARKER=".setup_skills_managed"

print_help() {
    cat <<'EOF'
Copy the skills deployed to ~/.agents/skills/ into ~/.claude/skills/ so
Claude Code can discover them. A marker file (.setup_skills_managed) inside
each copy records its source path so future runs can refresh the copy in
place without clobbering user-managed directories.

Usage:
  ./setup_skills.bash            # copy missing skills, refresh managed ones
  ./setup_skills.bash --force    # also overwrite foreign symlinks / dirs
  ./setup_skills.bash --dry      # show what would happen, change nothing
EOF
}

force=0
dry=0
for arg in "$@"; do
    case "${arg}" in
        --force) force=1 ;;
        --dry|--dry-run) dry=1 ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            exit 2
            ;;
    esac
done

if [[ ! -d "${SKILLS_SRC}" ]]; then
    echo "ERROR: skills source dir not found: ${SKILLS_SRC}" >&2
    exit 1
fi

# A stale top-level symlink (from a prior symlink-based setup) would make
# every ${SKILLS_DST}/<name> below resolve through to the very same
# directory as ${SKILLS_SRC}/<name> — indistinguishable from a real copy,
# but a --force REPLACE would then `rm -rf` the actual source skill dir.
# Removing just the symlink (never its target) before mkdir -p prevents this.
if [[ -L "${SKILLS_DST}" ]]; then
    echo "MIGRATE ${SKILLS_DST} (removing stale top-level symlink)"
    [[ "${dry}" -eq 1 ]] || rm -f "${SKILLS_DST}"
fi

mkdir -p "${SKILLS_DST}"

# Prefer rsync — it makes refresh-in-place idempotent (files removed from the
# source disappear from the copy via --delete, and the marker is protected
# from deletion via --exclude). Fall back to a cp-based swap when rsync is
# missing (uncommon on macOS but cheap to support).
have_rsync=0
command -v rsync >/dev/null 2>&1 && have_rsync=1

# do_copy <src> <dest> — make <dest> a fresh copy of <src>'s contents and
# stamp the marker. Caller is responsible for ensuring <dest> is safe to
# clobber (legacy symlinks / unmanaged dirs are handled in the main loop).
# Honours the outer `dry` flag — no-op in dry mode.
do_copy() {
    local src="$1" dest="$2"
    if [[ "${dry}" -eq 1 ]]; then
        return 0
    fi
    if [[ "${have_rsync}" -eq 1 ]]; then
        # Trailing slash on src copies *contents* into dest. --exclude=MARKER
        # both keeps the marker from being copied from source (it's not there
        # anyway) AND, because rsync exclude rules also apply to --delete,
        # protects an existing marker in dest from being wiped.
        mkdir -p "${dest}"
        rsync -a --delete --exclude="${MARKER}" "${src}/" "${dest}/"
    else
        # No rsync — copy to a sibling, then atomic-ish rename-over. Doesn't
        # survive concurrent runs, but neither did the symlink-based setup.
        rm -rf "${dest}.new"
        cp -a "${src}" "${dest}.new"
        rm -rf "${dest}"
        mv "${dest}.new" "${dest}"
    fi
    printf '%s\n' "${src}" > "${dest}/${MARKER}"
}

copied=0
updated=0
replaced=0
skipped=0

for skill_path in "${SKILLS_SRC}"/*/; do
    [[ -d "${skill_path}" ]] || continue
    name="$(basename "${skill_path}")"
    src="${skill_path%/}"
    dest="${SKILLS_DST}/${name}"

    if [[ -L "${dest}" ]]; then
        # Legacy symlink from the pre-copy setup. If it points at our own
        # source, the user is migrating intentionally — auto-replace. If it
        # points elsewhere, treat as user-managed and require --force.
        current="$(readlink "${dest}")"
        if [[ "${current}" == "${src}" ]]; then
            echo "MIGRATE ${name} (replacing symlink with copy)"
            [[ "${dry}" -eq 1 ]] || rm -f "${dest}"
            do_copy "${src}" "${dest}"
            replaced=$((replaced + 1))
        elif [[ "${force}" -eq 1 ]]; then
            echo "REPLACE ${name} (overwriting symlink to ${current})"
            [[ "${dry}" -eq 1 ]] || rm -f "${dest}"
            do_copy "${src}" "${dest}"
            replaced=$((replaced + 1))
        else
            echo "SKIP    ${name} (symlink to ${current}; use --force to replace with copy)"
            skipped=$((skipped + 1))
        fi
    elif [[ -d "${dest}" ]]; then
        # A directory at dest is either a managed copy from a previous run
        # (refresh it) or user content (don't touch without --force). The
        # marker file + matching source path is what distinguishes them.
        if [[ -f "${dest}/${MARKER}" ]] && [[ "$(cat "${dest}/${MARKER}" 2>/dev/null)" == "${src}" ]]; then
            echo "UPDATE  ${name}"
            do_copy "${src}" "${dest}"
            updated=$((updated + 1))
        elif [[ "${force}" -eq 1 ]]; then
            echo "REPLACE ${name} (overwriting unmanaged directory)"
            [[ "${dry}" -eq 1 ]] || rm -rf "${dest}"
            do_copy "${src}" "${dest}"
            replaced=$((replaced + 1))
        else
            echo "SKIP    ${name} (unmanaged directory at ${dest}; use --force to replace)"
            skipped=$((skipped + 1))
        fi
    elif [[ -e "${dest}" ]]; then
        # A regular file (or anything else not a dir/symlink). Always require
        # --force — replacing arbitrary user content silently is too risky.
        if [[ "${force}" -eq 1 ]]; then
            echo "REPLACE ${name} (overwriting file at ${dest})"
            [[ "${dry}" -eq 1 ]] || rm -f "${dest}"
            do_copy "${src}" "${dest}"
            replaced=$((replaced + 1))
        else
            echo "SKIP    ${name} (non-directory at ${dest}; use --force to replace)"
            skipped=$((skipped + 1))
        fi
    else
        echo "COPY    ${name}: ${src} -> ${dest}"
        do_copy "${src}" "${dest}"
        copied=$((copied + 1))
    fi
done

echo ""
echo "Copied: ${copied}, Updated: ${updated}, Replaced: ${replaced}, Skipped: ${skipped}"

[[ "${dry}" -eq 1 ]] && echo "(dry run — no changes made)"
