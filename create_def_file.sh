#!/bin/bash
# Generates an Apptainer .def file for a given tool by gathering real,
# verifiable evidence about how to install it, then synthesizing with Claude.
#
# Usage:   create_def_file.sh <ToolName> [--github-url <URL>]
# Creates: tools/<ToolName>/<ToolName>.def  (relative to CWD)
#
# Options:
#   --github-url <URL>   Skip GitHub search and use this URL directly.
#                        Useful when multiple repos share a similar name.
#
# Design notes (see CLAUDE.md "Lessons from empirical builds" for the full
# story — these rules were derived from real apptainer builds, not guessed):
#   - Prefer an upstream-shipped container def over writing one from scratch.
#   - Prefer bioconda + miniforge3/mamba over PyPI/pip when both exist,
#     but NEVER continuumio/miniconda3 + classic conda (solver can hang
#     indefinitely on the combined bioconda+conda-forge index).
#   - For GitHub-source repos with no setup.py/pyproject.toml/requirements.txt,
#     never guess dependencies from the README — grep the actual import
#     statements in the repo's .py files for the real list.

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
CLEANUP_FILES=()
cleanup() {
    for f in "${CLEANUP_FILES[@]:-}"; do
        [[ -n "$f" ]] && rm -rf "$f"
    done
}
trap cleanup EXIT

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
# the PyPI hit is an unrelated package — discard it to avoid wrong installs.
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

# --- Repo tree + default branch (single source of truth for everything below) ---
REPO_PATH=""
DEFAULT_BRANCH="main"
TREE_PATHS_FILE=""
if [[ -n "$GITHUB_URL" ]]; then
    REPO_PATH=$(echo "$GITHUB_URL" | sed 's|https://github.com/||')
    REPO_META=$(curl -sf "https://api.github.com/repos/$REPO_PATH" 2>/dev/null || true)
    if [[ -n "$REPO_META" ]]; then
        DEFAULT_BRANCH=$(echo "$REPO_META" | python3 -c "import json,sys; print(json.load(sys.stdin).get('default_branch') or 'main')" 2>/dev/null || echo "main")
    fi

    TREE_JSON=$(curl -sf "https://api.github.com/repos/$REPO_PATH/git/trees/$DEFAULT_BRANCH?recursive=1" 2>/dev/null || true)
    if [[ -n "$TREE_JSON" ]]; then
        TREE_PATHS_FILE=$(mktemp)
        CLEANUP_FILES+=("$TREE_PATHS_FILE")
        echo "$TREE_JSON" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for item in data.get('tree', []):
    if item.get('type') == 'blob':
        print(item['path'])
" 2>/dev/null > "$TREE_PATHS_FILE" || true
    fi
fi

# --- Fetch README ---
GITHUB_README=""
if [[ -n "$GITHUB_URL" ]]; then
    GITHUB_README=$(curl -sf \
        "https://raw.githubusercontent.com/$REPO_PATH/$DEFAULT_BRANCH/README.md" \
        2>/dev/null | head -c 4000 || true)
    [[ -n "$GITHUB_README" ]] && echo "  Fetched README ($DEFAULT_BRANCH)"
fi

# --- Check for an upstream-shipped container definition (Pattern 0) ---
# If the tool's own repo already ships a Dockerfile or Apptainer/Singularity
# def, adapting it beats re-deriving install steps from scratch — this is
# how jaeger's def was built and it's the one tool that never needed
# debugging.
UPSTREAM_DEF_PATH=""
UPSTREAM_DEF_CONTENT=""
if [[ -n "${TREE_PATHS_FILE:-}" && -s "$TREE_PATHS_FILE" ]]; then
    UPSTREAM_DEF_PATH=$(grep -iE '\.def$' "$TREE_PATHS_FILE" | grep -iE '(singularity|apptainer)' | head -1 || true)
    [[ -z "$UPSTREAM_DEF_PATH" ]] && UPSTREAM_DEF_PATH=$(grep -iE '\.def$' "$TREE_PATHS_FILE" | head -1 || true)
    [[ -z "$UPSTREAM_DEF_PATH" ]] && UPSTREAM_DEF_PATH=$(grep -iE '(^|/)Dockerfile$' "$TREE_PATHS_FILE" | head -1 || true)
    if [[ -n "$UPSTREAM_DEF_PATH" ]]; then
        echo "  Found upstream container definition: $UPSTREAM_DEF_PATH"
        UPSTREAM_DEF_CONTENT=$(curl -sf "https://raw.githubusercontent.com/$REPO_PATH/$DEFAULT_BRANCH/$UPSTREAM_DEF_PATH" 2>/dev/null | head -c 6000 || true)
    fi
fi

# --- Check bioconda (Pattern 4) ---
# Independent of PyPI — many bioinformatics tools are bioconda-only or
# bioconda-preferred even when a (stale/harder-to-build) PyPI release exists.
CONDA_PACKAGE=""
CONDA_VERSION=""
for candidate in "$TOOL_LOWER" "$TOOL"; do
    CONDA_JSON=$(curl -sf "https://api.anaconda.org/package/bioconda/$candidate" 2>/dev/null || true)
    if [[ -n "$CONDA_JSON" ]]; then
        CONDA_PACKAGE="$candidate"
        CONDA_VERSION=$(echo "$CONDA_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('latest_version') or '')" 2>/dev/null || true)
        echo "  Found on bioconda: $candidate=$CONDA_VERSION"
        break
    fi
done

# --- Check for a packaging file (setup.py/pyproject.toml/requirements.txt) ---
HAS_PACKAGING=false
if [[ -n "${TREE_PATHS_FILE:-}" ]] && grep -qiE '(^|/)(setup\.py|pyproject\.toml|requirements\.txt|setup\.cfg)$' "$TREE_PATHS_FILE" 2>/dev/null; then
    HAS_PACKAGING=true
fi

# --- Import-based dependency discovery (Pattern 3) ---
# Only when there's no PyPI release, no bioconda package, and no packaging
# file — i.e. a "flat script" repo where the README's stated requirements
# can't be cross-checked against anything authoritative. Ground truth is
# the actual import statements in the source.
DISCOVERED_DEPS=""
if [[ -z "$PYPI_JSON" && -z "$CONDA_PACKAGE" && "$HAS_PACKAGING" == false && -n "${TREE_PATHS_FILE:-}" && -s "$TREE_PATHS_FILE" ]]; then
    echo "No PyPI/bioconda package or packaging file found — scanning source imports for real dependencies..."
    IMPORT_TMPDIR=$(mktemp -d)
    CLEANUP_FILES+=("$IMPORT_TMPDIR")

    grep -E '\.py$' "$TREE_PATHS_FILE" \
        | grep -viE '(^|/)(test|tests|docs|examples?)(/|$)' \
        | head -60 > "$IMPORT_TMPDIR/py_files.txt" || true

    while IFS= read -r relpath; do
        [[ -z "$relpath" ]] && continue
        outfile="$IMPORT_TMPDIR/$(echo "$relpath" | tr '/' '_')"
        curl -sf --max-filesize 65536 "https://raw.githubusercontent.com/$REPO_PATH/$DEFAULT_BRANCH/$relpath" -o "$outfile" 2>/dev/null || true
    done < "$IMPORT_TMPDIR/py_files.txt"

    DISCOVERED_DEPS=$(python3 - "$TREE_PATHS_FILE" "$IMPORT_TMPDIR" <<'PYEOF'
import sys, os, ast

tree_file, tmpdir = sys.argv[1], sys.argv[2]
paths = [l.strip() for l in open(tree_file) if l.strip().endswith('.py')]

local_names = set()
for p in paths:
    local_names.add(os.path.basename(p)[:-3])
    parts = p.split('/')
    if len(parts) > 1:
        local_names.add(parts[0])

STDLIB = {
    'os', 'sys', 're', 'json', 'argparse', 'collections', 'itertools', 'functools', 'math',
    'random', 'time', 'datetime', 'subprocess', 'shutil', 'glob', 'csv', 'io', 'gzip', 'bz2',
    'zipfile', 'tarfile', 'sqlite3', 'logging', 'multiprocessing', 'threading', 'queue',
    'socket', 'struct', 'copy', 'pickle', 'typing', 'dataclasses', 'enum', 'abc', 'contextlib',
    'pathlib', 'tempfile', 'warnings', 'traceback', 'unittest', 'string', 'textwrap', 'operator',
    'heapq', 'bisect', 'array', 'ctypes', 'platform', 'getpass', 'hashlib', 'hmac', 'base64',
    'uuid', 'urllib', 'http', 'xml', 'html', 'configparser', 'shlex', 'signal', 'errno', 'stat',
    'fnmatch', 'decimal', 'fractions', 'statistics', 'importlib', 'inspect', 'ast', 'dis', 'gc',
    'weakref', 'asyncio', 'concurrent', 'select', 'selectors', 'ssl', 'email', 'mimetypes',
    'webbrowser', 'cProfile', 'profile', 'pstats', 'timeit', 'doctest', 'pdb', 'venv',
    'ensurepip', 'distutils', 'sysconfig', 'code', 'codeop', 'pkgutil', 'runpy', '__future__',
    'builtins', 'copyreg', 'numbers', 'cmath',
}

found = set()
for p in paths:
    fname = os.path.join(tmpdir, p.replace('/', '_'))
    if not os.path.isfile(fname):
        continue
    try:
        tree = ast.parse(open(fname, encoding='utf-8', errors='ignore').read())
    except SyntaxError:
        continue
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                found.add(alias.name.split('.')[0])
        elif isinstance(node, ast.ImportFrom):
            if node.level and node.level > 0:
                continue
            if node.module:
                found.add(node.module.split('.')[0])

for name in sorted(found - local_names - STDLIB):
    print(name)
PYEOF
)
    if [[ -n "$DISCOVERED_DEPS" ]]; then
        echo "  Discovered external imports: $(echo "$DISCOVERED_DEPS" | tr '\n' ' ')"
    else
        echo "  No external imports detected"
    fi
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
if [[ -n "$UPSTREAM_DEF_CONTENT" ]]; then
    CONTEXT+="## AUTHORITATIVE: upstream already ships a container definition at $UPSTREAM_DEF_PATH
Adapt this directly — keep its install logic intact. Only add/change: our
Maintainer label, the Hazel bind-mount mkdir line in %post, and %labels
Source/Version to match our conventions. Do not re-derive install steps.

$UPSTREAM_DEF_CONTENT

"
fi
if [[ -n "$CONDA_PACKAGE" ]]; then
    CONTEXT+="## AUTHORITATIVE: bioconda package found
Package: $CONDA_PACKAGE
Version: $CONDA_VERSION
Use Pattern 4 (miniforge3 + mamba) from the template — do NOT use
continuumio/miniconda3 + classic conda, its solver can hang indefinitely
on this channel combination.

"
fi
if [[ -n "$DISCOVERED_DEPS" ]]; then
    CONTEXT+="## AUTHORITATIVE: real dependencies discovered from source imports
This repo has no setup.py/pyproject.toml/requirements.txt, so these were
extracted by parsing actual import statements in the repo's .py files —
use this list, not whatever the README implies:
$DISCOVERED_DEPS

"
fi
if [[ -n "$PYPI_JSON" ]]; then
    CONTEXT+="## PyPI key facts (use these verbatim — do not re-derive from JSON):
Version: ${PYPI_VERSION}
Summary: ${PYPI_SUMMARY}

## PyPI full metadata (JSON, truncated):
$(echo "$PYPI_JSON" | head -c 3000)

"
fi
if [[ -n "$GITHUB_URL" ]]; then
    CONTEXT+="## GitHub repository: $GITHUB_URL (default branch: $DEFAULT_BRANCH)

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

Use the template below as a structural guide — it documents 5 install
patterns (0-4) with explicit decision rules refined from real builds.
Replace all <PLACEHOLDER> values with real content. Do not leave any
placeholders in the output.

Source hierarchy — when information conflicts, follow this order:
1. Any section above marked AUTHORITATIVE (upstream def, bioconda hit, or
   source-derived dependency list) — these are verified facts, not inference.
2. GitHub README — for install method and tool entrypoints when nothing
   AUTHORITATIVE covers it.
3. PyPI metadata — supplementary only; if it conflicts with the README or
   an AUTHORITATIVE section, trust those instead.

PyPI package identity rule: If the PyPI home_page or project_urls do not
reference the GitHub URL provided above, the PyPI entry is for a different,
unrelated package. Discard its version, install instructions, and
dependencies. Derive everything from the GitHub README and URL instead.

Hard requirements (always apply):
- Bootstrap: docker
- Maintainer: sdweave2@ncsu.edu
- Version label in %labels must equal the installed version exactly
- %post must include: mkdir -p /rs1 /share /home /usr/local/usrapps
- Pin the version explicitly in the install command for reproducibility
- %runscript must be: exec <command> \"\$@\"
- %test must be a real invocation that exits 0 (prefer '<command> --help';
  if the tool has no top-level --help flag, use a bare invocation that
  prints usage and exits cleanly instead of guessing a flag that doesn't exist)
- Output ONLY the .def file content — no explanation, no markdown fences, no commentary

Pick exactly ONE pattern (0-4) per the template's decision rules. In short:
- Pattern 0 if an upstream def/Dockerfile was found above — adapt it.
- Pattern 4 if a bioconda package was found above — miniforge3 + mamba, never miniconda3 + conda.
- Pattern 3 if source-derived dependencies were found above — use that exact list, not README guesses.
- Otherwise Pattern 1 (PyPI) or Pattern 2 (GitHub source with packaging file), whichever applies.

## Template:
$(cat "$TEMPLATE")

## Tool information:
$CONTEXT" > "$DEF_FILE"

# Strip markdown fences and any preamble/explanation Claude may have added.
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
echo ""
echo "This was generated, not built. Review it, then build with:"
echo "  ./apptainer_build.sh   (after setting TOOL=\"$TOOL\" at the top)"
