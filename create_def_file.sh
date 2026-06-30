#!/bin/bash
# Generates an Apptainer .def file for a given tool by fetching installation
# info from PyPI and/or GitHub and synthesizing with Claude.
#
# Usage:   create_def_file.sh <ToolName> [--github-url <URL>]
# Creates: tools/<ToolName>/<ToolName>.def  (relative to CWD)
#
# Options:
#   --github-url <URL>   Skip GitHub search and use this URL directly.
#                        Useful when multiple repos share a similar name.

set -euo pipefail

# --- Argument parsing ---
TOOL=""
GITHUB_URL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --github-url)
            GITHUB_URL_OVERRIDE="$2"
            shift 2
            ;;
        --github-url=*)
            GITHUB_URL_OVERRIDE="${1#*=}"
            shift
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            echo "Usage: create_def_file.sh <ToolName> [--github-url <URL>]" >&2
            exit 1
            ;;
        *)
            TOOL="$1"
            shift
            ;;
    esac
done

if [[ -z "$TOOL" ]]; then
    echo "Usage: create_def_file.sh <ToolName> [--github-url <URL>]" >&2
    exit 1
fi

TOOL_LOWER=$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')
DEF_DIR="./tools/$TOOL"
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

# --- Cross-validate PyPI result against provided GitHub URL ---
# If --github-url was given but the PyPI package's listed URLs don't reference it,
# the PyPI hit is an unrelated package — discard it to avoid wrong installs (e.g. Phanta).
if [[ -n "$GITHUB_URL_OVERRIDE" && -n "$PYPI_JSON" ]]; then
    URL_MATCH=$(echo "$PYPI_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
info = data.get('info', {})
candidates = [info.get('home_page') or '', info.get('project_url') or '']
for v in (info.get('project_urls') or {}).values():
    candidates.append(v or '')
override = '$GITHUB_URL_OVERRIDE'.rstrip('/')
print('MATCH' if any(override.lower() in c.lower() for c in candidates if c) else 'MISMATCH')
" 2>/dev/null || echo "MATCH")
    if [[ "$URL_MATCH" == "MISMATCH" ]]; then
        echo "  WARNING: PyPI URLs don't reference --github-url — discarding PyPI data (unrelated package)"
        PYPI_JSON=""
    fi
fi

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

# --- Determine GitHub URL ---
GITHUB_URL=""

if [[ -n "$GITHUB_URL_OVERRIDE" ]]; then
    GITHUB_URL="${GITHUB_URL_OVERRIDE%/}"   # strip trailing slash
    echo "Using provided GitHub URL: $GITHUB_URL"
elif [[ -n "$PYPI_JSON" ]]; then
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

# --- Fallback: GitHub search with name-match ranking ---
if [[ -z "$GITHUB_URL" ]]; then
    echo "Not found on PyPI or no GitHub URL in metadata — searching GitHub..."
    SEARCH_JSON=$(curl -sf \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/search/repositories?q=${TOOL_LOWER}&sort=stars&per_page=10" \
        2>/dev/null || true)
    if [[ -n "$SEARCH_JSON" ]]; then
        # Rank by name similarity: exact > prefix/suffix > contains > other.
        # Within each tier, prefer higher star count.
        # Outputs two lines: a status line (OK: or WARN:<msg>), then the URL.
        SEARCH_RESULT=$(echo "$SEARCH_JSON" | python3 -c "
import json, sys
items = json.load(sys.stdin).get('items', [])
tool_lower = '$TOOL_LOWER'

def rank(item):
    name = item.get('name', '').lower()
    if name == tool_lower:
        return 0
    if name.startswith(tool_lower) or tool_lower.startswith(name):
        return 1
    if tool_lower in name:
        return 2
    return 3

ranked = sorted(items, key=lambda x: (rank(x), -x.get('stargazers_count', 0)))
if ranked:
    best = ranked[0]
    r = rank(best)
    if r > 0:
        print('WARN:no exact name match; using \"{}\" (closest to \"{}\") -- verify or re-run with --github-url'.format(best['name'], tool_lower))
    else:
        print('OK:')
    print(best.get('html_url', ''))
" 2>/dev/null || true)
        if [[ -n "$SEARCH_RESULT" ]]; then
            MATCH_STATUS=$(echo "$SEARCH_RESULT" | head -1)
            GITHUB_URL=$(echo "$SEARCH_RESULT" | sed -n '2p')
            if [[ "$MATCH_STATUS" == WARN:* ]]; then
                echo "  WARNING: ${MATCH_STATUS#WARN:}" >&2
            fi
            [[ -n "$GITHUB_URL" ]] && echo "  Found: $GITHUB_URL"
        fi
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

# --- Bioinformatics relevance check ---
# Aborts early if the discovered tool is clearly not life-sciences related.
# Fails open (proceeds) if Claude is unreachable or returns an unexpected response.
if [[ -n "$GITHUB_URL" && -z "$GITHUB_README" ]]; then
    echo "  README fetch failed — skipping bio check (proceeding)"
elif [[ -n "$PYPI_SUMMARY" || -n "$GITHUB_README" ]]; then
    echo "Checking bioinformatics relevance..."
    BIO_CONTEXT="Tool: $TOOL"
    [[ -n "$PYPI_SUMMARY" ]] && BIO_CONTEXT+="
PyPI summary: $PYPI_SUMMARY"
    [[ -n "$GITHUB_README" ]] && BIO_CONTEXT+="
README excerpt:
$(echo "$GITHUB_README" | head -c 1000)"

    BIO_RESPONSE=$("$CLAUDE" -p "Is the following tool relevant to bioinformatics, genomics, proteomics, metagenomics, transcriptomics, structural biology, computational biology, or life sciences research? Respond with a single word: YES or NO.

$BIO_CONTEXT" 2>/dev/null || true)

    # Fail open: if Claude is unreachable or returns empty, proceed without blocking.
    if [[ -n "$BIO_RESPONSE" ]] && echo "$BIO_RESPONSE" | grep -qiE '^\s*no\b'; then
        echo "ERROR: '$TOOL' does not appear to be a bioinformatics tool — discarding." >&2
        echo "       If the wrong repo was selected, re-run with --github-url <correct-url>." >&2
        rmdir "$DEF_DIR" 2>/dev/null || true
        exit 1
    fi
    echo "  Confirmed bioinformatics relevance."
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

Use the template below as a structural guide. Replace all <PLACEHOLDER> values with real content. Do not leave any placeholders in the output.

Source hierarchy — when information conflicts, follow this order:
1. GitHub README — authoritative for install method, tool entrypoints, and conda/pip preference.
2. PyPI metadata — supplementary only; if it conflicts with the README, trust the README.
3. GitHub URL — use to confirm you have the correct package when the PyPI name is ambiguous.

PyPI package identity rule: If the PyPI home_page or project_urls do not reference the GitHub URL provided above, the PyPI entry is for a different, unrelated package. Discard its version, install instructions, and dependencies. Derive everything from the GitHub README and URL instead.

Hard requirements (always apply):
- Bootstrap: docker
- Maintainer: sdweave2@ncsu.edu
- Version to install: ${PYPI_VERSION:-extract from tool information above}
- Version label in %labels must equal the installed version exactly
- %post must include: mkdir -p /rs1 /share /home /usr/local/usrapps
- Pin the version explicitly in the install command for reproducibility
- %runscript must be: exec <command> \"\$@\"
- %test must be: <command> --help (omit %test if the tool has no --help flag)
- Output ONLY the .def file content — no explanation, no markdown fences, no commentary

Choose the install workflow that best matches what the tool's README or PyPI metadata recommends.

IMPORTANT decision rule — follow in order:
- If the README contains 'conda install', '-c bioconda', a Bioconda badge, or any conda-based install example: use Pattern 5. This is the authoritative signal that conda is the intended distribution path.
- If the PyPI dependencies pin very old versions (numpy<1.20, numpy<=1.17, scipy<1.5, scipy<=1.4, or similar): the PyPI wheel will fail to build on Ubuntu 22.04. Use Pattern 5 (conda) or Pattern 2/3 (GitHub source) instead.
- If a git clone is needed inside %post on ubuntu:22.04, always include ca-certificates in the apt install AND call \`update-ca-certificates\` immediately after the apt-get block, before any git clone command.
- Whenever %post uses pip install from source inside a conda environment (pip install git+URL, pip install /opt/..., or pip install .), always add c-compiler and cxx-compiler from conda-forge to the conda create call — do not try to infer whether C extensions are present.

1. PyPI release (From: ubuntu:22.04) — when a recent PyPI wheel exists with no ancient pinned deps:
   apt-get install python3 python3-dev python3-pip build-essential git ca-certificates + pip3 install --no-cache-dir <Tool>==<Version>

2. GitHub source via pip (From: ubuntu:22.04) — when no PyPI release exists but a setup.py/pyproject.toml does:
   apt-get install python3 python3-dev python3-pip build-essential git ca-certificates + pip3 install --no-cache-dir git+<URL>@<tag>

3. Clone + local pip install (From: ubuntu:22.04) — when the repo must be present at runtime (e.g., bundled models/data):
   apt-get install python3 python3-dev python3-pip build-essential git ca-certificates + git clone --depth 1 --branch <tag> <URL> /opt/<Tool> + pip3 install --no-cache-dir /opt/<Tool>

4. Bare git clone (From: ubuntu:22.04 or other minimal base) — when the tool is a script or binary with no Python packaging:
   apt-get install any runtime deps (always include ca-certificates) + git clone --depth 1 --branch <tag> <URL> /opt/<Tool> + chmod/PATH in %environment

5. Conda install (From: continuumio/miniconda3:23.5.2-0) — PREFERRED for bioinformatics tools on bioconda, or when deps are too old to compile from source:
   conda install -n base -y -c conda-forge -c bioconda <pkg>=<ver> + conda clean -afy
   OR for tools needing an isolated env: conda create -n <env> -y -c conda-forge -c bioconda <pkg>=<ver> ... + conda clean -afy
   Activate in %environment by prepending /opt/conda/bin or /opt/conda/envs/<env>/bin to PATH

For any workflow using apt-get, always follow the standard cleanup pattern:
   apt-get update -qq && apt-get install -y --no-install-recommends ... && apt-get clean && rm -rf /var/lib/apt/lists/*

## Template:
$(cat "$TEMPLATE")

## Tool information:
$CONTEXT" > "$DEF_FILE"

# Strip markdown fences and any preamble/explanation Claude may have added.
# Looks for content between ``` fences first; falls back to first Bootstrap: line.
python3 - "$DEF_FILE" <<'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
m = re.search(r'```[^\n]*\n(.*?)```', content, re.DOTALL)
if m:
    content = m.group(1)
else:
    idx = content.find('Bootstrap:')
    if idx != -1:
        content = content[idx:]
with open(path, 'w') as f:
    f.write(content.rstrip() + '\n')
PYEOF

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
