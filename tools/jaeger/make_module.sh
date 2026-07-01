#!/bin/bash
# Run this script on an interactive node

# --- Environment ---
CONTAINER_MOD="/rs1/shares/brc/admin/tools/container-mod_v1/container-mod"
SIF="jaeger_v1.26.2.sif"
IMAGE_DIR="/usr/local/usrapps/brc/brc_modules/images"

# --- Move ---
mv $SIF $IMAGE_DIR/$SIF

# --- Execute ---
## Upon running, container-mod will ask for the application file and version
$CONTAINER_MOD pipe --tcl --profile brc --update $IMAGE_DIR/$SIF

# --- Exit ---
echo DONE
