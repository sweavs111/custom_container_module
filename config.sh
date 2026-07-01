# Site/cluster configuration for build_container scripts.
# Edit these values to match your environment before use.

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
