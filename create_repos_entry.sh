#!/bin/bash
# Generates a container-mod repos metadata file from an Apptainer .def file
# using Claude to extract description, homepage, and programs.
#
# Usage: create_repos_entry.sh <def_file> <repos_output_path>

set -euo pipefail

DEF="$1"
REPOS_FILE="$2"

if [[ ! -f "$DEF" ]]; then
    echo "ERROR: .def file not found: $DEF" >&2
    exit 1
fi

source "$(dirname "$0")/config.sh"
CLAUDE=$(command -v claude 2>/dev/null || echo "$CLAUDE_BIN")

if [[ ! -x "$CLAUDE" ]]; then
    echo "ERROR: claude CLI not found — cannot auto-generate repos entry" >&2
    exit 1
fi

TOOL=$(basename "$REPOS_FILE")
echo "Generating container-mod metadata for '$TOOL' from $(basename "$DEF")..."

"$CLAUDE" -p "Generate a container-mod app metadata file from this Apptainer definition file.

Output ONLY these three lines with no extra text, explanation, markdown, or code fences:
Description: <one concise sentence describing what the tool does>
Home Page: <exact URL from the %labels Source field>
Programs: <comma-separated executable names from %runscript — the command before \"\$@\", without the leading 'exec '>

Apptainer definition file:
$(cat "$DEF")" > "$REPOS_FILE"

if [[ ! -s "$REPOS_FILE" ]]; then
    echo "ERROR: Claude produced no output — repos file not created" >&2
    rm -f "$REPOS_FILE"
    exit 1
fi

echo "Created: $REPOS_FILE"
echo "---"
cat "$REPOS_FILE"
echo "---"
