#!/usr/bin/env bash
# Copy the skills deployed to ~/ai-wrapper/.agents/skills/ into
# every wrapped client's native skill directory so the installed coding
# clients can discover them. Existing entries in the target
# directories are left untouched — this script never overwrites a
# non-managed directory, and only refreshes copies that carry our marker
# file (.setup_skills_managed).
#
# Why copies (not symlinks): the sandboxed wrappers bind ~/.claude or ~/.gemini
# RW, and macOS sandbox-exec resolves file rules against the canonical real
# path, so a symlink to ~/ai-wrapper/.agents/skills/foo is read-denied.
# Plain copies live inside the already-bound agent config tree and work
# regardless of sandboxing.
#
# Usage:
#   ./setup_skills.bash            # copy missing skills, refresh managed ones
#   ./setup_skills.bash --force    # also overwrite foreign symlinks / dirs
#   ./setup_skills.bash --dry      # show what would happen, change nothing

set -u -o pipefail

SKILLS_SRC="${HOME}/ai-wrapper/.agents/skills"
SKILLS_DSTS=(
    "${HOME}/.claude/skills"
    "${HOME}/.codex/skills"
    "${HOME}/.gemini/config/skills"
    "${HOME}/.cursor/skills"
    "${HOME}/.copilot/skills"
)

# Named account profiles replace the default client config directory inside
# the sandbox, so each existing profile needs its own managed skill copies.
for profile_dir in "${HOME}"/.claude-* "${HOME}"/.codex-*; do
    [[ -d "${profile_dir}" ]] && SKILLS_DSTS+=("${profile_dir}/skills")
done
for profile_dir in "${HOME}"/.gemini-*; do
    [[ -d "${profile_dir}" ]] && SKILLS_DSTS+=("${profile_dir}/config/skills")
done
MARKER=".setup_skills_managed"

# Skills dropped from the shared set. Chezmoi never deletes a deployed file
# once its source entry is gone, so on upgraded installs these linger in
# SKILLS_SRC (and would be re-copied to new clients). They are archived,
# together with their managed client copies, outside every discovery root.
# Unmanaged copies with the same name are user content and are left alone.
RETIRED_SKILLS=(
    executing-plans
    find-skills
    finishing-a-development-branch
    implementing-tasks
    planning-tests
    requesting-code-review
    subagent-driven-development
    updating-documentation
    using-git-worktrees
    writing-automated-tests
    writing-plans
)
RETIRED_ARCHIVE="${HOME}/ai-wrapper/.retired-skills"

print_help() {
    cat <<'EOF'
Copy the skills deployed to ~/ai-wrapper/.agents/skills/ into
the native skill directories for Claude Code, Codex, Antigravity CLI,
Cursor Agent, and GitHub Copilot CLI. Existing named account profiles are
included. A marker file (.setup_skills_managed)
inside each copy records its source path so future runs can refresh the copy
in place without clobbering user-managed directories. Retired shared skills
and their managed copies are moved to ~/ai-wrapper/.retired-skills/.

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

# archive_skill <path> <bucket> — move <path> to RETIRED_ARCHIVE/<bucket>/,
# never overwriting an earlier archive. Honours the outer `dry` flag. Counts
# only completed moves; a failure is recorded so setup exits nonzero.
archive_skill() {
    local path="$1" bucket="$2" target
    target="${RETIRED_ARCHIVE}/${bucket}/$(basename "${path}")"
    [[ -e "${target}" ]] && target="${target}.$(date +%Y%m%d%H%M%S).$$"
    echo "RETIRE  ${path} -> ${target}"
    if [[ "${dry}" -eq 1 ]]; then
        retired=$((retired + 1))
        return 0
    fi
    if mkdir -p "$(dirname "${target}")" && mv "${path}" "${target}"; then
        retired=$((retired + 1))
    else
        echo "ERROR   failed to archive ${path}; it remains discoverable" >&2
        retire_failed=$((retire_failed + 1))
    fi
}

copied=0
updated=0
replaced=0
skipped=0
retired=0
retire_failed=0

# Managed copies record the source path, so check them before the source
# itself is moved away.
for skills_dst in "${SKILLS_DSTS[@]}"; do
    [[ -d "${skills_dst}" && ! -L "${skills_dst}" ]] || continue
    for name in "${RETIRED_SKILLS[@]}"; do
        dest="${skills_dst}/${name}"
        if [[ -d "${dest}" && ! -L "${dest}" && -f "${dest}/${MARKER}" ]] \
            && [[ "$(cat "${dest}/${MARKER}" 2>/dev/null)" == "${SKILLS_SRC}/${name}" ]]; then
            bucket="${skills_dst#"${HOME}"/}"
            archive_skill "${dest}" "${bucket//\//_}"
        fi
    done
done
for name in "${RETIRED_SKILLS[@]}"; do
    [[ -d "${SKILLS_SRC}/${name}" && ! -L "${SKILLS_SRC}/${name}" ]] && archive_skill "${SKILLS_SRC}/${name}" source
done

for skills_dst in "${SKILLS_DSTS[@]}"; do
    # A stale top-level symlink (from a prior symlink-based setup) would make
    # every ${skills_dst}/<name> below resolve through to the very same
    # directory as ${SKILLS_SRC}/<name> — indistinguishable from a real copy,
    # but a --force REPLACE would then `rm -rf` the actual source skill dir.
    # Removing just the symlink (never its target) before mkdir -p prevents this.
    if [[ -L "${skills_dst}" ]]; then
        echo "MIGRATE ${skills_dst} (removing stale top-level symlink)"
        [[ "${dry}" -eq 1 ]] || rm -f "${skills_dst}"
    fi

    mkdir -p "${skills_dst}"

    for skill_path in "${SKILLS_SRC}"/*/; do
        [[ -d "${skill_path}" ]] || continue
        name="$(basename "${skill_path}")"
        # Reachable in dry mode or after a failed archive; never redeploy.
        [[ " ${RETIRED_SKILLS[*]} " == *" ${name} "* ]] && continue
        src="${skill_path%/}"
        dest="${skills_dst}/${name}"

        if [[ -L "${dest}" ]]; then
            # Legacy symlink from the pre-copy setup. If it points at our own
            # source, the user is migrating intentionally — auto-replace. If it
            # points elsewhere, treat as user-managed and require --force.
            current="$(readlink "${dest}")"
            if [[ "${current}" == "${src}" ]]; then
                echo "MIGRATE ${name} (replacing symlink with copy in ${skills_dst})"
                [[ "${dry}" -eq 1 ]] || rm -f "${dest}"
                do_copy "${src}" "${dest}"
                replaced=$((replaced + 1))
            elif [[ "${force}" -eq 1 ]]; then
                echo "REPLACE ${name} (overwriting symlink to ${current} in ${skills_dst})"
                [[ "${dry}" -eq 1 ]] || rm -f "${dest}"
                do_copy "${src}" "${dest}"
                replaced=$((replaced + 1))
            else
                echo "SKIP    ${name} (symlink to ${current} in ${skills_dst}; use --force to replace with copy)"
                skipped=$((skipped + 1))
            fi
        elif [[ -d "${dest}" ]]; then
            # A directory at dest is either a managed copy from a previous run
            # (refresh it) or user content (don't touch without --force). The
            # marker file + matching source path is what distinguishes them.
            if [[ -f "${dest}/${MARKER}" ]] && [[ "$(cat "${dest}/${MARKER}" 2>/dev/null)" == "${src}" ]]; then
                echo "UPDATE  ${name} (${skills_dst})"
                do_copy "${src}" "${dest}"
                updated=$((updated + 1))
            elif [[ "${force}" -eq 1 ]]; then
                echo "REPLACE ${name} (overwriting unmanaged directory at ${dest})"
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
done

echo ""
echo "Copied: ${copied}, Updated: ${updated}, Replaced: ${replaced}, Skipped: ${skipped}, Retired: ${retired}"

if [[ "${dry}" -eq 1 ]]; then
    echo "(dry run — no changes made)"
fi

if [[ "${retire_failed}" -gt 0 ]]; then
    echo "ERROR: ${retire_failed} retired skill(s) could not be archived" >&2
    exit 1
fi
