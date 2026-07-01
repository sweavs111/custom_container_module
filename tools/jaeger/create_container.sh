#!/bin/bash
module load apptainer
unset APPTAINER_BINDPATH
apptainer build --fakeroot jaeger_v1.26.2.sif jaeger_v1.26.2.def

echo DONE
