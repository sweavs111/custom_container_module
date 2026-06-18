#!/bin/bash
# Generates an Apptainer .def file for a given tool by fetching installation
# info from PyPI and/or GitHub and synthesizing with Claude.
#
# Usage:   create_def_file.sh <ToolName>
# Creates: <ToolName>/<ToolName>.def  (relative to CWD)

set -euo pipefail

TOOL="$1"
TOOL_LOWER=$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')
DEF_DIR="./$TOOL"
DEF_FILE="$DEF_DIR/$TOOL.def"
TEMPLATE="$(dirname "$0")/template.def"
source "$(dirname "$0")/config.sh"
CLAUDE=$(command -v claude 2>/dev/null || echo "$CLAUDE_BIN")

# --- Validation ---
if [[ ! -f "$TEMPLATE" ]]; then
    echo "ERROR: template.def not found at $TEMPLATE" >&2
    exit 1
fi
if [[ ! -x "$CLAUDE" ]]; then
    echo "ERROR: claude CLI not found" >&2
    exit 1
fi
if [[ -f "$DEF_FILE" ]]; then
    echo "ERROR: $DEF_FILE already exists — remove it to regenerate" >&2
    exit 1
fi

mkdir -p "$DEF_DIR"

# --- Search PyPI ---
echo "Searching PyPI for '$TOOL'..."
PYPI_JSON=""
for name in "$TOOL" "$TOOL_LOWER"; do
    result=$(curl -sf "https://pypi.org/pypi/$name/json" 2>/dev/null || true)
    if [[ -n "$result" ]]; then
        PYPI_JSON="$result"
        echo "  Found: pypi.org/project/$name"
        break
    fi
done

# --- Pre-extract key fields from PyPI metadata ---
PYPI_VERSION=""
PYPI_SUMMARY=""
if [[ -n "$PYPI_JSON" ]]; then
    PYPI_VERSION=$(echo "$PYPI_JSON" | python3 -c "
import json, sys
print(json.load(sys.stdin)['info']['version'])
" 2>/dev/null || true)
    PYPI_SUMMARY=$(echo "$PYPI_JSON" | python3 -c "
import json, sys
print(json.load(sys.stdin)['info'].get('summary') or '')
" 2>/dev/null || true)
fi

# --- Extract GitHub URL from PyPI metadata ---
GITHUB_URL=""
if [[ -n "$PYPI_JSON" ]]; then
    GITHUB_URL=$(echo "$PYPI_JSON" | python3 -c "
import json, re, sys
data = json.load(sys.stdin)
info = data.get('info', {})
candidates = [info.get('home_page') or '', info.get('project_url') or '']
for v in (info.get('project_urls') or {}).values():
    candidates.append(v or '')
for url in candidates:
    m = re.match(r'https://github\.com/[^/]+/[^/#? ]+', url)
    if m:
        print(m.group(0).rstrip('/'))
        break
" 2>/dev/null || true)
fi

# --- Fallback: GitHub search ---
if [[ -z "$GITHUB_URL" ]]; then
    echo "Not found on PyPI — searching GitHub..."
    SEARCH_JSON=$(curl -sf \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/search/repositories?q=${TOOL_LOWER}&sort=stars&per_page=5" \
        2>/dev/null || true)
    if [[ -n "$SEARCH_JSON" ]]; then
        GITHUB_URL=$(echo "$SEARCH_JSON" | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
if items:
    print(items[0].get('html_url', ''))
" 2>/dev/null || true)
        [[ -n "$GITHUB_URL" ]] && echo "  Found: $GITHUB_URL"
    fi
fi

if [[ -z "$PYPI_JSON" && -z "$GITHUB_URL" ]]; then
    echo "ERROR: '$TOOL' not found on PyPI or GitHub — set DEF manually" >&2
    rmdir "$DEF_DIR" 2>/dev/null || true
    exit 1
fi

# --- Fetch README from GitHub ---
GITHUB_README=""
if [[ -n "$GITHUB_URL" ]]; then
    REPO_PATH=$(echo "$GITHUB_URL" | sed 's|https://github.com/||')
    for branch in main master; do
        readme=$(curl -sf \
            "https://raw.githubusercontent.com/$REPO_PATH/$branch/README.md" \
            2>/dev/null || true)
        if [[ -n "$readme" ]]; then
            GITHUB_README=$(echo "$readme" | head -c 4000)
            echo "  Fetched README ($branch)"
            break
        fi
    done
fi

# --- Assemble context ---
CONTEXT=""
if [[ -n "$PYPI_JSON" ]]; then
    CONTEXT+="## PyPI key facts (use these verbatim — do not re-derive from JSON):
Version: ${PYPI_VERSION}
Summary: ${PYPI_SUMMARY}

## PyPI full metadata (JSON, truncated):
$(echo "$PYPI_JSON" | head -c 3000)

"
fi
if [[ -n "$GITHUB_URL" ]]; then
    CONTEXT+="## GitHub repository: $GITHUB_URL

"
fi
if [[ -n "$GITHUB_README" ]]; then
    CONTEXT+="## README (first 4000 chars):
$GITHUB_README

"
fi

# --- Generate def file with Claude ---
echo "Generating .def file with Claude..."

"$CLAUDE" -p "Generate a complete Apptainer .def file for the tool '$TOOL'.

Follow the template below EXACTLY. Replace all <PLACEHOLDER> values with real content derived from the tool information provided. Do not leave any placeholders in the output.

Hard requirements:
- Bootstrap: docker
- From: ubuntu:22.04
- Maintainer: sdweave2@ncsu.edu
- Version to install: ${PYPI_VERSION:-extract from tool information above}
- Version label in %labels must equal the installed version exactly
- %post must include: mkdir -p /rs1 /share /home /usr/local/usrapps
- %post must install python3, python3-pip, build-essential, git via apt-get with the standard cleanup pattern from the template
- Pin the version explicitly in the install command for reproducibility
- %runscript must be: exec <command> \"\$@\"
- %test must be: <command> --help
- Output ONLY the .def file content — no explanation, no markdown fences, no commentary

## Template:
$(cat "$TEMPLATE")

## Tool information:
$CONTEXT" > "$DEF_FILE"

if [[ ! -s "$DEF_FILE" ]]; then
    echo "ERROR: Claude produced no output — aborting" >&2
    rm -f "$DEF_FILE"
    rmdir "$DEF_DIR" 2>/dev/null || true
    exit 1
fi

echo ""
echo "Created: $DEF_FILE"
echo "---"
cat "$DEF_FILE"
echo "---"
