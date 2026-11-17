# Site/cluster configuration for build_container scripts.

# Edit for a single manual build. Leave alone for batch runs (batch_build.sh sets GITHUB_URL per iteration).
# e.g. SINGLE_GITHUB_URL="https://github.com/Shamir-Lab/PlasClass"
SINGLE_GITHUB_URL="https://github.com/ZhaoXM-Lab/VirRep"
DEPLOY="${DEPLOY:-true}"   # false to skip container-mod module generation
FORCE="${FORCE:-false}"    # true (or --force) skips review of a newly generated .def — for unattended xfer/sbatch runs only
PUSH="${PUSH:-false}"      # true to also publish the built .sif to ghcr.io (see push_sif.sh) — independent of DEPLOY
GHCR_OVERWRITE="${GHCR_OVERWRITE:-false}"   # true (or --force_ghcr_overwrite) allows replacing an existing ghcr tag

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

# GitHub Container Registry namespace for PUSH=true / push_sif.sh.
# Images land at oras://ghcr.io/<GHCR_NAMESPACE>/<tool, lowercased>:<version>.
# Auth comes from a prior `apptainer registry login --username <user> oras://ghcr.io`.
GHCR_NAMESPACE="sweavs111"

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
