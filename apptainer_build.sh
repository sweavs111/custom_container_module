#!/bin/bash

### --- Environment ---
source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/def_lib.sh"
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

# Runs "$@", appending a timestamp, a full xtrace of the command, AND the
# command's own combined stdout/stderr to container_build.log (while still
# showing that output live via tee), and returns its exit code. Capturing
# the real output (not just the xtrace of the command line) is required
# for the retry loop below — is_environment_failure and fix_def_file.sh
# both work from this log's tail, and a log with no actual error text in
# it is useless to both.
run_logged() {
    echo "$(date +"%Y-%m-%d %H:%M:%S")" >> container_build.log
    exec 3>> container_build.log
    BASH_XTRACEFD=3
    set -x
    "$@" 2>&1 | tee -a container_build.log
    local rc=${PIPESTATUS[0]}
    { set +x; } 2>/dev/null
    exec 3>&-
    unset BASH_XTRACEFD
    echo >> container_build.log
    return $rc
}

# Builds a --sandbox image from $1 (tool name $2, used only to namespace
# the scratch dir) and probes whether the intended command actually
# resolves and runs inside it — ground truth, independent of whatever
# %post claimed. Always removes the sandbox afterward: it is diagnostic
# scaffolding only, never the shipped artifact (see CLAUDE.md — the .def
# must stay the sole source of truth for the .sif). Writes its findings
# to stdout for the caller to capture, and tees them into
# container_build.log for the permanent audit trail.
run_sandbox_diagnostic() {
    local def="$1" tool="$2"
    local sandbox_dir
    sandbox_dir=$(mktemp -d "${APPTAINER_TMPDIR}/${tool}_diag.XXXXXX")

    if ! apptainer build --sandbox --force "$sandbox_dir" "$def" >> container_build.log 2>&1; then
        echo "Sandbox build itself also failed to complete — see container_build.log for its output." | tee -a container_build.log
        rm -rf "$sandbox_dir"
        return 0
    fi

    local cmd
    cmd=$(grep -m1 -E '^[[:space:]]*exec[[:space:]]' "$def" | awk '{print $2}')
    if [[ -n "$cmd" ]]; then
        if apptainer exec --writable "$sandbox_dir" command -v "$cmd" > /dev/null 2>&1; then
            echo "Probe: '$cmd' resolves via 'command -v' inside the sandbox." | tee -a container_build.log
        else
            echo "Probe: '$cmd' does NOT resolve via 'command -v' inside the sandbox — the install did not complete or PATH is wrong, even though %post may not have reported an error." | tee -a container_build.log
        fi
        {
            echo "Probe: running '$cmd --help' directly inside the sandbox:"
            apptainer exec --writable "$sandbox_dir" "$cmd" --help 2>&1 | head -c 2000 || true
        } | tee -a container_build.log
    else
        echo "Probe: could not extract a bare command from %runscript's 'exec' line to test." | tee -a container_build.log
    fi

    rm -rf "$sandbox_dir"
    return 0
}

### --- Edit before each build (in config.sh) ---
# GITHUB_URL and DEPLOY are set at the top of config.sh, not here.
if [[ -z "${GITHUB_URL:-}" ]]; then
    echo "ERROR: GITHUB_URL not set — edit it at the top of config.sh" >&2
    exit 1
fi
TOOL=$(derive_tool_name "$GITHUB_URL")

### --- Derived paths ---
TOOL_LOWER=$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')
REPOS_FILE="$(dirname "$CONTAINER_MOD")/repos/$TOOL_LOWER"

# .def filenames follow the same tools/<Tool>/<Tool>-<Version>.def
# convention as the .sif output below (create_def_file.sh names its output
# after the Version label it generates) — so the exact filename can't be
# known in advance of generation. find_tool_def (def_lib.sh) locates
# whatever's there, tolerating both that convention and the older bare
# tools/<Tool>/<Tool>.def some tools still carry.
locate_def() {
    local result rc=0
    result=$(find_tool_def "$TOOL") || rc=$?
    if [[ $rc -eq 2 ]]; then
        echo "ERROR: multiple .def files found for ${TOOL} — ambiguous, remove or rename all but one:" >&2
        local candidates=()
        mapfile -t candidates <<< "$result"
        printf '  %s\n' "${candidates[@]}" >&2
        exit 1
    fi
    DEF="$result"
}

DEF=""
locate_def

### --- Pre-flight: generate .def file if missing ---
if [[ -z "$DEF" ]]; then
    "$(dirname "$0")/create_def_file.sh" "$GITHUB_URL" || exit 1
    locate_def
    if [[ -z "$DEF" ]]; then
        echo "ERROR: create_def_file.sh reported success but no .def file was found for ${TOOL}" >&2
        exit 1
    fi
    echo ""
    echo "A .def file was generated but NOT reviewed. Re-run after checking"
    echo "$DEF, or Ctrl-C now to review first."
    read -r -p "Continue with build? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || exit 0
fi

### --- Extract version from .def ---
VERSION=$(extract_def_version "$DEF")
if [[ -z "$VERSION" ]]; then
    echo "ERROR: could not extract Version label from $DEF" >&2
    exit 1
fi
SIF="tools/${TOOL}/${TOOL}-${VERSION}"
SIF_FILE="${SIF}.sif"

### --- Pre-flight: generate container-mod metadata if missing ---
if [[ "$DEPLOY" == true && ! -f "$REPOS_FILE" ]]; then
    "$(dirname "$0")/create_repos_entry.sh" "$DEF" "$REPOS_FILE" || exit 1
fi

### --- Update log file ---
touch container_build.log

### --- Build (bounded automatic retry-fix on failure) ---
cp "$DEF" "$DEF.orig.tmp"
cleanup_retry_artifacts() {
    rm -f "$DEF.orig.tmp" "$DEF".attempt*
}
trap cleanup_retry_artifacts EXIT

ATTEMPT=1
while true; do
    echo "--- Build attempt $ATTEMPT/$DEF_FIX_MAX_ATTEMPTS ---" | tee -a container_build.log
    run_logged apptainer build "$SIF_FILE" "$DEF"
    BUILD_EXIT=$?
    [[ $BUILD_EXIT -eq 0 ]] && break

    LOG_TAIL=$(tail -n 150 container_build.log)

    if is_environment_failure "$LOG_TAIL"; then
        echo "ERROR: build failure looks environment/infra-related, not a .def bug — not retrying (exit $BUILD_EXIT)" | tee -a container_build.log
        exit $BUILD_EXIT
    fi
    if (( ATTEMPT >= DEF_FIX_MAX_ATTEMPTS )); then
        echo "ERROR: apptainer build failed after $DEF_FIX_MAX_ATTEMPTS attempts — giving up (exit $BUILD_EXIT)" | tee -a container_build.log
        exit $BUILD_EXIT
    fi

    SANDBOX_DIAG_FILE=""
    if [[ $ATTEMPT -eq 1 ]]; then
        echo "Running a --sandbox diagnostic build to gather ground-truth evidence before asking Claude to fix this..." | tee -a container_build.log
        SANDBOX_DIAG_FILE=$(mktemp)
        run_sandbox_diagnostic "$DEF" "$TOOL" > "$SANDBOX_DIAG_FILE"
    fi

    cp "$DEF" "${DEF}.attempt${ATTEMPT}"
    LOG_TAIL_FILE=$(mktemp)
    echo "$LOG_TAIL" > "$LOG_TAIL_FILE"

    echo "Asking Claude to fix the .def (attempt $ATTEMPT failure)..." | tee -a container_build.log
    if ! "$(dirname "$0")/fix_def_file.sh" "$DEF" "$LOG_TAIL_FILE" "$SANDBOX_DIAG_FILE"; then
        echo "ERROR: fix_def_file.sh failed to produce a fix — giving up" | tee -a container_build.log
        rm -f "$LOG_TAIL_FILE" "$SANDBOX_DIAG_FILE"
        exit 1
    fi
    rm -f "$LOG_TAIL_FILE" "$SANDBOX_DIAG_FILE"

    if ! check_def_invariants "$DEF"; then
        echo "Diff between attempt $ATTEMPT and the REJECTED fix Claude produced (never built — it failed invariant checks first):" | tee -a container_build.log
        diff -u "${DEF}.attempt${ATTEMPT}" "$DEF" | tee -a container_build.log || true
        echo "ERROR: regenerated .def failed invariant checks — aborting. Restoring $DEF to the originally reviewed version." | tee -a container_build.log
        cp "$DEF.orig.tmp" "$DEF"
        exit 1
    fi

    echo "Diff between attempt $ATTEMPT and the fix Claude produced:" | tee -a container_build.log
    diff -u "${DEF}.attempt${ATTEMPT}" "$DEF" | tee -a container_build.log || true

    ATTEMPT=$((ATTEMPT + 1))
done

# A build passing is necessary but not sufficient evidence the .def is
# correct (see CLAUDE.md lesson 6) — if the retry loop modified the file
# at all, a human should see exactly what changed before it's deployed,
# even though it already passed a real build.
if (( ATTEMPT > 1 )); then
    echo ""
    echo "The .def file was modified by the automatic retry loop before this build succeeded."
    echo "Diff from the version already reviewed:"
    diff -u "$DEF.orig.tmp" "$DEF" || true
    echo ""
    read -r -p "Continue with this build (and deploy, if enabled)? [y/N] " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] || { echo "Stopping — local .sif retained at $SIF_FILE, not deployed."; exit 0; }
fi

### --- Deploy module ---
if [[ "$DEPLOY" == true ]]; then
    source "$(dirname "$CONTAINER_MOD")/profiles/$CONTAINER_MOD_PROFILE"
    SIF_DEST="${PUBLIC_IMAGEDIR}/$(basename "$SIF_FILE")"

    # cp and container-mod are chained with && so a failed cp short-circuits
    # (and is reflected in $?) instead of silently registering a module for
    # a .sif that was never copied.
    do_deploy() {
        cp "$SIF_FILE" "$SIF_DEST" && \
            "$CONTAINER_MOD" pipe -t --profile "$CONTAINER_MOD_PROFILE" --update "$SIF_DEST" \
                < <(printf '%s\n%s\n' "$TOOL_LOWER" "$VERSION")
    }
    run_logged do_deploy
    DEPLOY_EXIT=$?

    if [[ $DEPLOY_EXIT -ne 0 ]]; then
        echo "ERROR: container-mod failed (exit $DEPLOY_EXIT) — local .sif kept at $SIF_FILE" | tee -a container_build.log
        exit $DEPLOY_EXIT
    fi

    rm "$SIF_FILE"
    echo "Removed local copy: $SIF_FILE"
fi

### --- Exit ---
echo DONE
