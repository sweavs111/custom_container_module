#!/bin/bash
#SBATCH --job-name=viralm_gpu
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=4
#SBATCH --mem=32G
#SBATCH --partition=gpu           # CONFIRM: Hazel's actual GPU partition name (check `sinfo` / OIT docs)
#SBATCH --gres=gpu:1              # CONFIRM: Hazel's gres syntax for requesting 1 GPU
#SBATCH --time=4:00:00
#SBATCH --output=logs/viralm_gpu.%j.out
#SBATCH --error=logs/viralm_gpu.%j.err
#SBATCH --mail-user=sdweave2@ncsu.edu
#SBATCH --mail-type=ALL

set -euo pipefail

# ---- Config -----------------------------------------------------------
SIF="/usr/local/usrapps/brc/brc_modules/images/ViraLM-b7a6f4e.sif"
INPUT_FA="/rs1/path/to/input.fasta"
OUTPUT_DIR="/rs1/path/to/output"
DATABASE_DIR="/rs1/path/to/viralm_database"   # downloaded per upstream README (gdown + tar -xzvf)

[[ -f "$SIF" ]] || { echo "ERROR: sif not found: $SIF"; exit 1; }
[[ -f "$INPUT_FA" ]] || { echo "ERROR: input fasta not found: $INPUT_FA"; exit 1; }
[[ -d "$DATABASE_DIR" ]] || { echo "ERROR: database dir not found: $DATABASE_DIR"; exit 1; }

mkdir -p "$OUTPUT_DIR" logs

# ---- Provenance ---------------------------------------------------------
echo "Job ID:    $SLURM_JOB_ID"
echo "Hostname:  $(hostname)"
echo "Date:      $(date)"
echo "SIF:       $SIF"
nvidia-smi || echo "WARNING: nvidia-smi not available on this node"

# ---- Run ------------------------------------------------------------
module load apptainer

apptainer run --nv "$SIF" \
    --input "$INPUT_FA" \
    --output "$OUTPUT_DIR" \
    --database "$DATABASE_DIR" \
    --len 500 \
    --threshold 0.5
