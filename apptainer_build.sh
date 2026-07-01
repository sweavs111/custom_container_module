#!/bin/bash

### --- Environment ---
source "$(dirname "$0")/config.sh"
if [[ -z "${CONTAINER_MOD:-}" || ! -x "$CONTAINER_MOD" ]]; then
    echo "ERROR: CONTAINER_MOD not set or not executable — check config.sh" >&2
    exit 1
fi
module load apptainer
export APPTAINER_BINDPATH=""   # required — Hazel's apptainer config sets a bind path that breaks builds

# Cache/tmp dirs MUST be off $HOME (1GB quota) — see config.sh comment.
# This was the root cause of most v0 "exit 255" failures: pulling Docker
# base images into the default $HOME/.apptainer cache silently filled the
# quota mid-build.
export APPTAINER_CACHEDIR="$APPTAINER_CACHEDIR"
export APPTAINER_TMPDIR="$APPTAINER_TMPDIR"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

### --- Edit this section ---
TOOL="ToolName"
DEPLOY=true   # set to false to skip container-mod module generation after build
GITHUB_URL=""  # optional: set to the exact GitHub URL if auto-search picks the wrong repo

### --- Derived paths ---
DEF="tools/${TOOL}/${TOOL}.def"
TOOL_LOWER=$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')
REPOS_FILE="$(dirname "$CONTAINER_MOD")/repos/$TOOL_LOWER"

### --- Pre-flight: generate .def file if missing ---
if [[ ! -f "$DEF" ]]; then
    create_args=("$TOOL")
    [[ -n "${GITHUB_URL:-}" ]] && create_args+=(--github-url "$GITHUB_URL")
    "$(dirname "$0")/create_def_file.sh" "${create_args[@]}" || exit 1
    echo ""
    echo "A .def file was generated but NOT reviewed. Re-run after checking"
    echo "tools/${TOOL}/${TOOL}.def, or Ctrl-C now to review first."
    read -r -p "Continue with build? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 0
fi

### --- Extract version from .def ---
VERSION=$(grep -m1 -iE '^\s+Version\s+' "$DEF" | awk '{print $NF}')
if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not extract Version label from $DEF" >&2
    exit 1
fi
SIF="tools/${TOOL}/${TOOL}-${VERSION}"

### --- Pre-flight: generate container-mod metadata if missing ---
if [[ "$DEPLOY" == true && ! -f "$REPOS_FILE" ]]; then
    "$(dirname "$0")/create_repos_entry.sh" "$DEF" "$REPOS_FILE" || exit 1
fi

### --- Update log file ---
touch container_build.log
echo "$(date +"%Y-%m-%d %H:%M:%S")" >> container_build.log

### --- Build ---
exec 3>> container_build.log
BASH_XTRACEFD=3
set -x
apptainer build "$SIF.sif" "$DEF"
BUILD_EXIT=$?
{ set +x; } 2>/dev/null
exec 3>&-
unset BASH_XTRACEFD
echo >> container_build.log

if [[ $BUILD_EXIT -ne 0 ]]; then
    echo "ERROR: apptainer build failed (exit $BUILD_EXIT) — skipping container-mod" | tee -a container_build.log
    exit $BUILD_EXIT
fi

### --- Deploy module ---
if [[ "$DEPLOY" == true ]]; then
    source "$(dirname "$CONTAINER_MOD")/profiles/$CONTAINER_MOD_PROFILE"
    SIF_DEST="${PUBLIC_IMAGEDIR}/$(basename "${SIF}.sif")"

    echo "$(date +"%Y-%m-%d %H:%M:%S")" >> container_build.log
    exec 3>> container_build.log
    BASH_XTRACEFD=3
    set -x
    cp "${SIF}.sif" "$SIF_DEST"
    printf '%s\n%s\n' "$TOOL_LOWER" "$VERSION" | "$CONTAINER_MOD" pipe -t --profile "$CONTAINER_MOD_PROFILE" --update "$SIF_DEST"
    DEPLOY_EXIT=${PIPESTATUS[1]}
    { set +x; } 2>/dev/null
    exec 3>&-
    unset BASH_XTRACEFD
    echo >> container_build.log

    if [[ $DEPLOY_EXIT -ne 0 ]]; then
        echo "ERROR: container-mod failed (exit $DEPLOY_EXIT) — local .sif kept at ${SIF}.sif" | tee -a container_build.log
        exit $DEPLOY_EXIT
    fi

    rm "${SIF}.sif"
    echo "Removed local copy: ${SIF}.sif"
fi

### --- Exit ---
echo DONE
