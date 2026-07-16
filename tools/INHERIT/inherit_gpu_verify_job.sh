#!/bin/bash
#SBATCH --job-name=inherit_gpu_verify
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=16G
#SBATCH --partition=gpu_partners
#SBATCH --qos=short_gpu
#SBATCH --gres=gpu:a10:1
#SBATCH --time=00:15:00
#SBATCH --output=logs/inherit_gpu_verify.%j.out
#SBATCH --error=logs/inherit_gpu_verify.%j.err

set -euo pipefail

# ---- Config -------------------------------------------------------------
SIF="/rs1/shares/brc/admin/containers/custom_container_module/tools/INHERIT/INHERIT-5ea758c0.sif"

[[ -f "$SIF" ]] || { echo "ERROR: sif not found: $SIF"; exit 1; }

# ---- Provenance -----------------------------------------------------------
echo "Job ID:    $SLURM_JOB_ID"
echo "Hostname:  $(hostname)"
echo "Date:      $(date)"
echo "SIF:       $SIF"
echo

echo "=== nvidia-smi (host) ==="
nvidia-smi || echo "WARNING: nvidia-smi not available on this node"
echo

module load apptainer
export APPTAINER_BINDPATH=""

# ---- Verify the GPU is actually visible *inside* the container -----------
echo "=== apptainer exec --nv: torch.cuda.is_available() ==="
apptainer exec --nv "$SIF" python3 -c "
import torch
print('torch version:', torch.__version__)
print('CUDA available:', torch.cuda.is_available())
if torch.cuda.is_available():
    print('device name:', torch.cuda.get_device_name(0))
    x = torch.randn(1024, 1024, device='cuda')
    y = x @ x
    torch.cuda.synchronize()
    print('matmul on GPU OK, result sum:', float(y.sum()))
"
echo

echo "=== apptainer exec --nv: tensorflow GPU device list ==="
apptainer exec --nv "$SIF" python3 -c "
import tensorflow as tf
print('tensorflow version:', tf.__version__)
print('GPUs visible to tensorflow:', tf.config.list_physical_devices('GPU'))
"
echo

echo "=== apptainer run --nv: real INHERIT entrypoint (--help, no pretrained models needed) ==="
apptainer run --nv "$SIF" --help
echo

echo "DONE"
