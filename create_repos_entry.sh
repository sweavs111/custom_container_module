#!/bin/bash
# Generates a container-mod repos metadata file from an Apptainer .def file
# by parsing the structured fields directly — no external dependencies required.
#
# Usage: create_repos_entry.sh <def_file> <repos_output_path>

set -euo pipefail

DEF="$1"
REPOS_FILE="$2"

if [[ ! -f "$DEF" ]]; then
    echo "ERROR: .def file not found: $DEF" >&2
    exit 1
fi

TOOL=$(basename "$REPOS_FILE")
echo "Extracting container-mod metadata for '$TOOL' from $(basename "$DEF")..."

# Description: first content line of %help, text after the em-dash separator
DESCRIPTION=$(awk '/^%help/{found=1; next} found && NF{print; exit}' "$DEF" \
    | sed 's/^[[:space:]]*//' \
    | sed 's/^[^—]*—[[:space:]]*//')

# Home Page: Source label value
HOMEPAGE=$(awk '/Source/{print $NF; exit}' "$DEF")

# Programs: exec target in %runscript, strip leading 'exec ' and trailing ' "$@"'
PROGRAMS=$(awk '/^%runscript/{found=1; next} found && /exec /{
    sub(/^[[:space:]]+exec[[:space:]]+/, "")
    sub(/[[:space:]]*"\$@".*/, "")
    print; exit
}' "$DEF")

if [[ -z "$DESCRIPTION" || -z "$HOMEPAGE" || -z "$PROGRAMS" ]]; then
    echo "ERROR: could not extract one or more fields from $DEF" >&2
    echo "  Description: '${DESCRIPTION:-<empty>}'" >&2
    echo "  Home Page:   '${HOMEPAGE:-<empty>}'" >&2
    echo "  Programs:    '${PROGRAMS:-<empty>}'" >&2
    exit 1
fi

printf 'Description: %s\nHome Page: %s\nPrograms: %s\n' \
    "$DESCRIPTION" "$HOMEPAGE" "$PROGRAMS" > "$REPOS_FILE"

echo "Created: $REPOS_FILE"
echo "---"
cat "$REPOS_FILE"
echo "---"
