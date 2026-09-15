#!/bin/bash
#SBATCH --job-name=beast2_gpu_verify
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --partition=gpu
#SBATCH --qos=gpu
#SBATCH --nodelist=gpu03
#SBATCH --gres=gpu:p100:1
#SBATCH --time=00:20:00
#SBATCH --output=logs/beast2_gpu_verify.%j.out
#SBATCH --error=logs/beast2_gpu_verify.%j.err

set -euo pipefail

# ---- Config ----------------------------------------------------------------
SIF="/rs1/shares/brc/admin/containers/custom_container_module/tools/beast2/beast2-2.7.7.sif"
# NOTE: deliberately resolved through readlink, not a literal /share/...
# path. On Hazel, /share is itself a symlink to /gpfs_common/share (real
# mountpoints: /rs1, /gpfs_common - confirmed via `readlink -f /share` and
# `stat`). Apptainer's cwd auto-bind does not follow that symlink correctly:
# a job cd'd into /share/brc/$USER/... builds/writes the file on the host
# fine, but the exact same path is invisible inside the container at run
# time (Java throws FileNotFoundException for a file that plainly exists on
# the host) - confirmed directly with `apptainer exec --bind /share:/share`
# too, which fails the same way, while the identical test through the real
# /gpfs_common path succeeds. Resolving the symlink once up front sidesteps
# the whole problem.
RUNDIR="$(readlink -f /share)/brc/${USER}/beast2_gpu_verify_${SLURM_JOB_ID}"

[[ -f "$SIF" ]] || { echo "ERROR: sif not found: $SIF"; exit 1; }
mkdir -p "$RUNDIR"

# ---- Provenance -------------------------------------------------------------
echo "Job ID:    $SLURM_JOB_ID"
echo "Hostname:  $(hostname)"
echo "Date:      $(date)"
echo "SIF:       $SIF"
echo "RUNDIR:    $RUNDIR"
echo

echo "=== nvidia-smi (host) ==="
nvidia-smi || echo "WARNING: nvidia-smi not available on this node"
echo

module load apptainer
# NOTE: deliberately NOT setting APPTAINER_BINDPATH="" here - that override is
# a build-time-only workaround (apptainer_build.sh / CLAUDE.md lesson 1) for a
# problem in Hazel's sitewide apptainer config that only bites during `build`.
# For normal `exec`/`run` (this script, and any real user invocation per the
# .def's own %help), leaving it unset lets Hazel's sitewide config bind /rs1,
# /share, /home, /usr/local/usrapps as intended - CLAUDE.md's own "use
# containers directly" section never sets it either. Setting it here was
# tried and empirically breaks RUNDIR paths under /share: with it set, only
# apptainer's own cwd/home auto-bind is active, and that auto-bind silently
# does not materialize for a not-yet-existing nested path under /share,
# producing a Java FileNotFoundException for a file that is plainly present
# on the host.

# ---- BEAGLE resource list as seen inside the container with --nv -----------
echo "=== apptainer exec --nv: beast -beagle_info ==="
apptainer exec --nv "$SIF" beast -beagle_info
echo

echo "=== apptainer exec --nv: nvidia-smi (inside container) ==="
apptainer exec --nv "$SIF" nvidia-smi
echo

# ---- Build a fast, real (TreeLikelihood-bearing) test XML on the fly -------
# Pulled from the container's own shipped examples/ dir rather than depending
# on any external file, so this script stays self-contained and re-runnable
# on its own. testHKY.xml is chosen because it has a real alignment/
# TreeLikelihood (bitflip.xml, by contrast, has no alignment at all and
# never touches BEAGLE) - chainLength/preBurnin/logEvery are cut way down
# from the shipped 5,000,000/50,000/10,000 so this finishes in well under
# the time limit while still exercising GPU-resident likelihood computation.
cd "$RUNDIR"
apptainer exec "$SIF" cat /usr/local/beast/examples/testHKY.xml > testHKY_gpu_smoke.xml
sed -i 's/chainLength="5000000" preBurnin="50000"/chainLength="20000" preBurnin="1000"/' testHKY_gpu_smoke.xml
sed -i 's/logEvery="10000"/logEvery="1000"/g' testHKY_gpu_smoke.xml

# ---- Real GPU-accelerated BEAST2 run ----------------------------------------
# -beagle_GPU alone is correct and sufficient here: this build has
# BUILD_OPENCL=OFF, so CUDA is the only GPU BEAGLE resource that could ever
# be offered - there is no separate -beagle_cuda flag in BEAST2's own CLI
# (verified against `beast -help`'s actual usage output; an earlier draft
# of this script and of the .def's own %help text both wrongly used one).
# The XML must be referenced by a path relative to $RUNDIR (the container's
# cwd) - apptainer with APPTAINER_BINDPATH="" does not auto-bind arbitrary
# absolute host paths outside cwd, only cwd itself; an absolute path here
# fails with a Java FileNotFoundException even though the file exists.
echo "=== apptainer run --nv: real BEAST2 analysis with -beagle_GPU ==="
# --bind /gpfs_common:/gpfs_common is required here, not optional: even after
# resolving the /share symlink above, apptainer's *implicit* cwd auto-bind
# still silently fails to make this path visible inside the container
# (verified directly - "No such file or directory" for a file that plainly
# exists on the host), apparently a GPFS-fileset-boundary quirk specific to
# this subtree. An *explicit* bind of the real top-level mountpoint reliably
# works where the implicit cwd auto-bind does not.
apptainer exec --bind /gpfs_common:/gpfs_common --nv "$SIF" \
    beast -overwrite -beagle_GPU "$PWD/testHKY_gpu_smoke.xml"
echo

echo "=== Output files ==="
ls -la "$RUNDIR"

echo "DONE"
