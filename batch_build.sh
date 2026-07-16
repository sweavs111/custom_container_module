#!/bin/bash
# Runs apptainer_build.sh once per GitHub URL in a list (generate .def if missing -> review -> build -> deploy).
#
# Usage: ./batch_build.sh urls.txt
# urls.txt: one GitHub URL per line; '#' comments and blank lines skipped.
#
# DEPLOY is forced true for every URL. For a DEPLOY=false dry run, use apptainer_build.sh directly.

set -uo pipefail
cd "$(dirname "$0")"

source ./config.sh
source ./def_lib.sh
if [[ -z "${CONTAINER_MOD:-}" || ! -x "$CONTAINER_MOD" ]]; then
    echo "ERROR: CONTAINER_MOD not set or not executable — check config.sh" >&2
    exit 1
fi
source "$(dirname "$CONTAINER_MOD")/profiles/$CONTAINER_MOD_PROFILE"

URLS_FILE="${1:-}"
if [[ -z "$URLS_FILE" || ! -f "$URLS_FILE" ]]; then
    echo "Usage: $0 <urls_file>" >&2
    exit 1
fi

declare -a OK=() FAILED=() SKIPPED=()

# A URL counts as already done only if its .def exists AND a .sif matching
# that .def's Version is already sitting in the public image dir — i.e. a
# prior run completed build+deploy for it. A .def with no matching deployed
# image (generated-but-not-built, or built-but-not-deployed) is NOT
# considered done and still goes through apptainer_build.sh normally.
already_deployed() {
    local url="$1" tool def version
    tool=$(derive_tool_name "$url")
    def=$(find_tool_def "$tool") || return 1
    version=$(extract_def_version "$def")
    [[ -n "$version" ]] || return 1
    [[ -f "${PUBLIC_IMAGEDIR}/${tool}-${version}.sif" ]]
}

# Read the URL list from fd 3, not stdin (fd 0). apptainer_build.sh's
# review/confirm prompts use `read -r -p` on stdin — if the URL list were
# fed via `done < "$URLS_FILE"` as before, that redirection shadows stdin
# for the whole loop body, so nested prompts would read the *next URL
# line* as their answer instead of the terminal, silently both declining
# the build and consuming that URL out of the list. Using fd 3 here keeps
# stdin free for those nested prompts.
while IFS= read -r -u 3 URL || [[ -n "$URL" ]]; do
    URL="${URL%%#*}"                  # strip trailing comments
    URL="$(echo -n "$URL" | xargs)"   # trim whitespace
    [[ -z "$URL" ]] && continue

    echo ""
    echo "=================================================================="
    if already_deployed "$URL"; then
        echo "Skipping (already built & deployed): $URL"
        echo "=================================================================="
        SKIPPED+=("$URL")
        continue
    fi
    echo "Building: $URL"
    echo "=================================================================="

    GITHUB_URL="$URL" DEPLOY=true ./apptainer_build.sh
    STATUS=$?

    if [[ $STATUS -eq 0 ]]; then
        OK+=("$URL")
    else
        echo "ERROR: build/deploy failed for $URL (exit $STATUS) — continuing with next URL" >&2
        FAILED+=("$URL")
    fi
done 3< "$URLS_FILE"

echo ""
echo "=================================================================="
echo "Batch summary: ${#OK[@]} succeeded, ${#SKIPPED[@]} skipped (already deployed), ${#FAILED[@]} failed"
for u in "${OK[@]}"; do echo "  OK      - $u"; done
for u in "${SKIPPED[@]}"; do echo "  SKIPPED - $u"; done
for u in "${FAILED[@]}"; do echo "  FAIL    - $u"; done

[[ ${#FAILED[@]} -eq 0 ]]
