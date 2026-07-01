# Site/cluster configuration for build_container scripts.
# Edit these values to match your environment before use.

# --- Edit before each build ---
# GITHUB_URL is the sole input to the pipeline: the tool/module name is
# always derived from it (see derive_tool_name below), never typed
# separately — this is what keeps tool identification unambiguous.
GITHUB_URL=""
DEPLOY=true   # set to false to skip container-mod module generation after build

# Derive the tool/module name from a GitHub repo URL: the repo's own name,
# taken verbatim (case preserved) as the last path segment, with a
# trailing ".git" or "/" stripped. This is the single source of truth for
# the name used everywhere downstream (tools/<name>/, <name>.sif,
# container-mod registration) — both apptainer_build.sh and
# create_def_file.sh call this so they can never derive different names
# for the same URL.
#
# Monorepo subdirectory URLs (.../tree/<branch>/<subdir>) derive the name
# from the subdir instead of the repo — that's the tool's real identity,
# e.g. .../RasmussenLab/vamb/tree/vamb_n2v_asy/workflow_PlasMAAG -> workflow_PlasMAAG.
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

# Apptainer cache/tmp dirs — MUST point at scratch, never $HOME.
# Home on Hazel has a 1GB quota; pulling Docker base images (miniconda3,
# tensorflow, etc.) into the default $HOME/.apptainer cache silently fills
# the quota mid-build and produces a generic "exit 255" that looks like a
# broken .def but isn't. This was the root cause of most v0 build failures.
APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"
APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"
