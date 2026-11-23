#!/bin/bash
#SBATCH --job-name=beast2_gpu_verify_module
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --partition=gpu
#SBATCH --qos=gpu
#SBATCH --nodelist=gpu03
#SBATCH --gres=gpu:p100:1
#SBATCH --time=00:20:00
#SBATCH --output=logs/beast2_gpu_verify_module.%j.out
#SBATCH --error=logs/beast2_gpu_verify_module.%j.err

set -euo pipefail

# ---- Purpose ----------------------------------------------------------------
# Companion to beast2_gpu_verify_job.sh, which drives the .sif directly via
# `apptainer exec/run --nv`. This script instead exercises the real deployed
# module - `module load beast2/2.7.7` then the plain `beast` command, exactly
# as an actual user would invoke it - with NO bare `apptainer`/`module load
# apptainer`/explicit --nv anywhere. The GPU-selection logic here comes
# entirely from container-mod's generated wrapper script (which checks
# `nvidia-smi -L` itself and adds --nv automatically) and from
# /usr/local/usrapps/brc/brc_modules/env/modules.config (which prepends
# /rs1,/share/$GROUP,/rsstu to APPTAINER_BINDPATH) - not from anything in
# this script. The point is to confirm GPU acceleration is real through
# *both* paradigms (direct .sif vs. deployed module), not just the one this
# pipeline's own build/test tooling exercises directly.
XML_FIXTURE="/rs1/shares/brc/admin/containers/custom_container_module/tools/beast2/testHKY_gpu_smoke.xml"
# Deliberately the literal /share/$GROUP path (not resolved through
# readlink, unlike beast2_gpu_verify_job.sh's RUNDIR) - this is the actual
# documented Hazel scratch convention (global CLAUDE.md), and modules.config
# binds exactly this literal path via APPTAINER_BINDPATH, a different
# (explicit, resolved-at-mount-time) mechanism than the implicit cwd
# auto-bind that failed against it in the bare-container script. Testing
# whether that explicit bind handles the /share symlink correctly where
# implicit auto-bind did not.
RUNDIR="/share/${GROUP:-brc}/${USER}/beast2_module_verify_${SLURM_JOB_ID}"

[[ -f "$XML_FIXTURE" ]] || { echo "ERROR: xml fixture not found: $XML_FIXTURE"; exit 1; }
mkdir -p "$RUNDIR"
cp "$XML_FIXTURE" "$RUNDIR/"

# ---- Provenance -------------------------------------------------------------
echo "Job ID:    $SLURM_JOB_ID"
echo "Hostname:  $(hostname)"
echo "Date:      $(date)"
echo "RUNDIR:    $RUNDIR"
echo

echo "=== nvidia-smi (host) ==="
nvidia-smi || echo "WARNING: nvidia-smi not available on this node"
echo

# ---- Load the real deployed module - no apptainer/singularity module, no
# manual SIF path, no --nv anywhere in this script from here on -------------
module use /usr/local/usrapps/brc/brc_modules/modules
module load beast2/2.7.7

echo "=== which beast (confirms it resolved through the module, not a stray PATH entry) ==="
which beast
echo

echo "=== beast -beagle_info (via module - wrapper decides --nv on its own) ==="
beast -beagle_info
echo

# ---- Real GPU-accelerated BEAST2 run, through the module -------------------
cd "$RUNDIR"
echo "=== beast -overwrite -beagle_GPU (via module) ==="
beast -overwrite -beagle_GPU testHKY_gpu_smoke.xml
echo

echo "=== Output files ==="
ls -la "$RUNDIR"

module unload beast2

echo "=== module_loads.log tail (confirms the logging hook fired for this run) ==="
tail -3 /usr/local/usrapps/brc/logs/module_loads.log

echo "DONE"
