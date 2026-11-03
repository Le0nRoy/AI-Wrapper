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
and GitHub Copilot CLI. Existing named account profiles are
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

# Prefer rsync to fill the staging copy; fall back to cp when rsync is
# missing (uncommon on macOS but cheap to support).
have_rsync=0
command -v rsync >/dev/null 2>&1 && have_rsync=1

# do_copy <src> <dest> — replace whatever is at <dest> (nothing, a managed
# copy, a legacy symlink, or content the caller has cleared for --force)
# with a marked copy of <src>. The copy and marker are built in a hidden
# sibling first; the old entry is moved aside and only deleted once the new
# copy is in place, and is moved back if the swap fails. Returns nonzero,
# with <dest> unchanged or restored, on any failure. Never called in dry mode.
do_copy() {
    local src="$1" dest="$2" stage backup staged=0
    stage="$(dirname "${dest}")/.$(basename "${dest}").setup-new.$$"
    backup="$(dirname "${dest}")/.$(basename "${dest}").setup-old.$$"
    rm -rf "${stage}" "${backup}" || return 1

    if [[ "${have_rsync}" -eq 1 ]]; then
        rsync -a "${src}/" "${stage}/" && staged=1
    else
        cp -a "${src}" "${stage}" && staged=1
    fi
    if [[ "${staged}" -eq 0 ]] || ! printf '%s\n' "${src}" > "${stage}/${MARKER}"; then
        echo "ERROR   failed to stage ${src} for ${dest}; existing entry kept" >&2
        rm -rf "${stage}"
        return 1
    fi

    if [[ -e "${dest}" || -L "${dest}" ]] && ! mv "${dest}" "${backup}"; then
        echo "ERROR   failed to move ${dest} aside; existing entry kept" >&2
        rm -rf "${stage}"
        return 1
    fi
    if ! mv "${stage}" "${dest}"; then
        echo "ERROR   failed to install ${dest}" >&2
        if [[ -e "${backup}" || -L "${backup}" ]] && ! mv "${backup}" "${dest}"; then
            echo "ERROR   previous ${dest} left at ${backup}" >&2
        fi
        rm -rf "${stage}"
        return 1
    fi
    if [[ -e "${backup}" || -L "${backup}" ]] && ! rm -rf "${backup}"; then
        echo "ERROR   installed ${dest} but could not remove ${backup}" >&2
        return 1
    fi
}

# deploy <counter> <src> <dest> — run do_copy (skipped in dry mode) and
# bump the <counter> variable only when it succeeded; failures are tallied
# for the exit status.
deploy() {
    local counter="$1" src="$2" dest="$3"
    if [[ "${dry}" -eq 0 ]] && ! do_copy "${src}" "${dest}"; then
        copy_failed=$((copy_failed + 1))
        return 1
    fi
    printf -v "${counter}" '%d' "$((${!counter} + 1))"
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
copy_failed=0

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
        if [[ "${dry}" -eq 0 ]] && ! rm -f "${skills_dst}"; then
            echo "ERROR   failed to remove symlink ${skills_dst}; skipping it" >&2
            copy_failed=$((copy_failed + 1))
            continue
        fi
    fi

    if [[ "${dry}" -eq 0 ]] && ! mkdir -p "${skills_dst}"; then
        echo "ERROR   failed to create ${skills_dst}; skipping it" >&2
        copy_failed=$((copy_failed + 1))
        continue
    fi

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
                deploy replaced "${src}" "${dest}"
            elif [[ "${force}" -eq 1 ]]; then
                echo "REPLACE ${name} (overwriting symlink to ${current} in ${skills_dst})"
                deploy replaced "${src}" "${dest}"
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
                deploy updated "${src}" "${dest}"
            elif [[ "${force}" -eq 1 ]]; then
                echo "REPLACE ${name} (overwriting unmanaged directory at ${dest})"
                deploy replaced "${src}" "${dest}"
            else
                echo "SKIP    ${name} (unmanaged directory at ${dest}; use --force to replace)"
                skipped=$((skipped + 1))
            fi
        elif [[ -e "${dest}" ]]; then
            # A regular file (or anything else not a dir/symlink). Always require
            # --force — replacing arbitrary user content silently is too risky.
            if [[ "${force}" -eq 1 ]]; then
                echo "REPLACE ${name} (overwriting file at ${dest})"
                deploy replaced "${src}" "${dest}"
            else
                echo "SKIP    ${name} (non-directory at ${dest}; use --force to replace)"
                skipped=$((skipped + 1))
            fi
        else
            echo "COPY    ${name}: ${src} -> ${dest}"
            deploy copied "${src}" "${dest}"
        fi
    done
done

echo ""
echo "Copied: ${copied}, Updated: ${updated}, Replaced: ${replaced}, Skipped: ${skipped}, Retired: ${retired}, Failed: ${copy_failed}"

if [[ "${dry}" -eq 1 ]]; then
    echo "(dry run — no changes made)"
fi

if [[ "${retire_failed}" -gt 0 ]]; then
    echo "ERROR: ${retire_failed} retired skill(s) could not be archived" >&2
fi
if [[ "${copy_failed}" -gt 0 ]]; then
    echo "ERROR: ${copy_failed} skill copy operation(s) failed; rerun after fixing the cause" >&2
fi
if [[ "${retire_failed}" -gt 0 || "${copy_failed}" -gt 0 ]]; then
    exit 1
fi
