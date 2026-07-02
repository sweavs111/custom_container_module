#!/bin/bash
# Runs apptainer_build.sh once per GitHub URL in a list (generate .def if missing -> review -> build -> deploy).
#
# Usage: ./batch_build.sh urls.txt
# urls.txt: one GitHub URL per line; '#' comments and blank lines skipped.
#
# DEPLOY is forced true for every URL. For a DEPLOY=false dry run, use apptainer_build.sh directly.

set -uo pipefail
cd "$(dirname "$0")"

URLS_FILE="${1:-}"
if [[ -z "$URLS_FILE" || ! -f "$URLS_FILE" ]]; then
    echo "Usage: $0 <urls_file>" >&2
    exit 1
fi

declare -a OK=() FAILED=()

while IFS= read -r URL || [[ -n "$URL" ]]; do
    URL="${URL%%#*}"                  # strip trailing comments
    URL="$(echo -n "$URL" | xargs)"   # trim whitespace
    [[ -z "$URL" ]] && continue

    echo ""
    echo "=================================================================="
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
done < "$URLS_FILE"

echo ""
echo "=================================================================="
echo "Batch summary: ${#OK[@]} succeeded, ${#FAILED[@]} failed"
for u in "${OK[@]}"; do echo "  OK   - $u"; done
for u in "${FAILED[@]}"; do echo "  FAIL - $u"; done

[[ ${#FAILED[@]} -eq 0 ]]
