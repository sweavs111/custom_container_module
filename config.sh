# Site/cluster configuration for build_container scripts.

# Edit for a single manual build. Leave alone for batch runs (batch_build.sh sets GITHUB_URL per iteration).
# e.g. SINGLE_GITHUB_URL="https://github.com/Shamir-Lab/PlasClass"
SINGLE_GITHUB_URL="https://github.com/ChengPENG-wolf/ViraLM"
DEPLOY="${DEPLOY:-true}"   # false to skip container-mod module generation

# Do not edit directly — edit SINGLE_GITHUB_URL above instead.
GITHUB_URL="${GITHUB_URL:-$SINGLE_GITHUB_URL}"

# Derives the tool/module name from a GitHub URL (repo name, or subdir name for monorepo tree URLs).
# Single source of truth for tools/<name>/, <name>.sif, and container-mod registration.
derive_tool_name() {
    local url="${1%/}"
    if [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/tree/[^/]+/(.+)$ ]]; then
        basename "${BASH_REMATCH[1]}"
    else
        basename "${url%.git}"
    fi
}

# Path to the container-mod executable
CONTAINER_MOD="/rs1/shares/brc/admin/tools/container-mod_v1/container-mod"

# container-mod profile to use for deployment
CONTAINER_MOD_PROFILE="brc"

# Fallback path to the claude CLI (used if 'claude' is not on PATH)
CLAUDE_BIN="/home/sdweave2/.local/bin/claude"

# Model for .def generation — pinned for reproducibility, not left on the CLI's floating default.
CLAUDE_MODEL="claude-sonnet-5"

# Total apptainer_build.sh build attempts per tool, including the first —
# i.e. this many minus one automatic Claude retry-fixes on build failure.
DEF_FIX_MAX_ATTEMPTS=3

# Apptainer cache/tmp dirs — MUST point at scratch, never $HOME (1GB quota, silently fills mid-build).
APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"
APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"
