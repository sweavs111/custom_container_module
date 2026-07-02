#!/bin/bash
# Generates an Apptainer .def file for a GitHub-hosted tool by gathering
# real, verifiable evidence about how to install it, then synthesizing
# with Claude.
#
# Usage:   create_def_file.sh <GitHubURL>
# Creates: tools/<ToolName>/<ToolName>.def  (relative to CWD)
#
# The GitHub URL is the sole input — nothing here ever searches by name to
# find or pick a repo. Requiring the exact repo URL up front removes the
# ambiguity of name-based search picking the wrong same-named repo. The
# tool/module name is always derived from the URL itself (see
# derive_tool_name in config.sh), never typed separately. The one place a
# name is used is a PyPI *fact* lookup (version/summary) on the
# already-derived name, cross-validated against this same repo URL — never
# used to discover or choose a repo, only to avoid Claude inventing a
# version number when a real PyPI release exists.
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

source "$(dirname "$0")/config.sh"

# --- Argument parsing ---
# The GitHub URL is always taken from the CLI argument here, never from
# config.sh's GITHUB_URL — that variable is apptainer_build.sh's per-build
# input, sourcing config.sh must not let its empty default clobber this.
if [[ $# -ne 1 || "$1" != https://github.com/*/* ]]; then
    echo "Usage: create_def_file.sh <GitHubURL>" >&2
    echo "  e.g. create_def_file.sh https://github.com/Shamir-Lab/PlasClass" >&2
    exit 1
fi
GITHUB_URL="${1%/}"
TOOL=$(derive_tool_name "$GITHUB_URL")
TOOL_LOWER=$(echo "$TOOL" | tr '[:upper:]' '[:lower:]')
DEF_DIR="./tools/$TOOL"
DEF_FILE="$DEF_DIR/$TOOL.def"
TEMPLATE="$(dirname "$0")/template.def"
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

echo "Using GitHub URL: $GITHUB_URL (tool name: $TOOL)"

# --- Repo tree + default branch (single source of truth for everything below) ---
# Supports both a plain repo-root URL and a monorepo subdirectory URL
# (.../tree/<branch>/<subdir>, e.g. PlasMAAG's actual source lives under
# RasmussenLab/vamb). When a subdir is present, evidence gathering below
# is scoped to that subtree only — checking the whole monorepo for e.g. a
# packaging file would find vamb's, not the tool's own.
REPO_PATH=""
DEFAULT_BRANCH="main"
SUBDIR=""
TREE_PATHS_FILE=""

if [[ "$GITHUB_URL" =~ ^https://github\.com/([^/]+/[^/]+)/tree/([^/]+)/(.+)$ ]]; then
    REPO_PATH="${BASH_REMATCH[1]}"
    DEFAULT_BRANCH="${BASH_REMATCH[2]}"
    SUBDIR="${BASH_REMATCH[3]%/}"
    echo "  Monorepo subdirectory detected: $SUBDIR (repo: $REPO_PATH, branch: $DEFAULT_BRANCH)"
else
    REPO_PATH=$(echo "$GITHUB_URL" | sed 's|https://github.com/||')
fi

REPO_META=$(curl -sf "https://api.github.com/repos/$REPO_PATH" 2>/dev/null || true)
if [[ -n "$REPO_META" ]]; then
    [[ -z "$SUBDIR" ]] && DEFAULT_BRANCH=$(echo "$REPO_META" | python3 -c "import json,sys; print(json.load(sys.stdin).get('default_branch') or 'main')" 2>/dev/null || echo "main")
else
    echo "ERROR: could not reach GitHub repo $GITHUB_URL — check the URL" >&2
    rmdir "$DEF_DIR" 2>/dev/null || true
    exit 1
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

    if [[ -n "$SUBDIR" && -s "$TREE_PATHS_FILE" ]]; then
        SCOPED_TREE_PATHS_FILE=$(mktemp)
        CLEANUP_FILES+=("$SCOPED_TREE_PATHS_FILE")
        grep "^${SUBDIR}/" "$TREE_PATHS_FILE" > "$SCOPED_TREE_PATHS_FILE" || true
        TREE_PATHS_FILE="$SCOPED_TREE_PATHS_FILE"
    fi
fi

# --- Fetch README (subdir's own if present, else fall back to repo root) ---
GITHUB_README=$(curl -sf \
    "https://raw.githubusercontent.com/$REPO_PATH/$DEFAULT_BRANCH/${SUBDIR:+$SUBDIR/}README.md" \
    2>/dev/null | head -c 4000 || true)
if [[ -z "$GITHUB_README" && -n "$SUBDIR" ]]; then
    GITHUB_README=$(curl -sf \
        "https://raw.githubusercontent.com/$REPO_PATH/$DEFAULT_BRANCH/README.md" \
        2>/dev/null | head -c 4000 || true)
fi
[[ -n "$GITHUB_README" ]] && echo "  Fetched README ($DEFAULT_BRANCH${SUBDIR:+/$SUBDIR})"

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

# --- Check PyPI (Pattern 1) ---
# Fact lookup only — never used to find or validate repo identity, since
# TOOL is already fixed from the GitHub URL. Rejected only if PyPI's own
# metadata explicitly points to a *different* GitHub repo — many small
# packages simply have no home_page/project_urls at all (verified on
# FastAAI's real PyPI listing), and TOOL is already the repo's own name,
# not a user-typed guess, so silence isn't treated as a mismatch.
# Without this check at all, Claude has no ground truth for the version
# number and has been observed to invent a plausible-looking but wrong
# one, e.g. "1.2.1" when the real latest release is "0.1.20".
PYPI_PACKAGE=""
PYPI_VERSION=""
PYPI_SUMMARY=""
for candidate in "$TOOL_LOWER" "$TOOL"; do
    PYPI_RESULT=$(curl -sf "https://pypi.org/pypi/$candidate/json" 2>/dev/null || true)
    [[ -z "$PYPI_RESULT" ]] && continue
    PYPI_MATCH=$(echo "$PYPI_RESULT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
info = data.get('info', {})
candidates = [info.get('home_page') or '', info.get('project_url') or '']
for v in (info.get('project_urls') or {}).values():
    candidates.append(v or '')
repo_root = 'https://github.com/$REPO_PATH'.rstrip('/')
gh_urls = [c for c in candidates if c and 'github.com' in c.lower()]
if not gh_urls:
    print('MATCH')
elif any(repo_root.lower() in c.lower() for c in gh_urls):
    print('MATCH')
else:
    print('MISMATCH')
" 2>/dev/null || echo "MISMATCH")
    if [[ "$PYPI_MATCH" == "MATCH" ]]; then
        PYPI_PACKAGE="$candidate"
        PYPI_VERSION=$(echo "$PYPI_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])" 2>/dev/null || true)
        PYPI_SUMMARY=$(echo "$PYPI_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin)['info'].get('summary') or '')" 2>/dev/null || true)
        echo "  Found on PyPI: $candidate==$PYPI_VERSION (confirmed via matching repo URL)"
        break
    fi
done

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
if [[ -z "$PYPI_PACKAGE" && -z "$CONDA_PACKAGE" && "$HAS_PACKAGING" == false && -n "${TREE_PATHS_FILE:-}" && -s "$TREE_PATHS_FILE" ]]; then
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
if [[ -n "$PYPI_PACKAGE" ]]; then
    CONTEXT+="## AUTHORITATIVE: PyPI release found (confirmed via matching repo URL)
Package: $PYPI_PACKAGE
Version: $PYPI_VERSION
Summary: $PYPI_SUMMARY
Use these values verbatim if Pattern 1 applies — do not guess or re-derive
a version number from the README.

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
CONTEXT+="## GitHub repository: $GITHUB_URL (default branch: $DEFAULT_BRANCH)

"
if [[ -n "$GITHUB_README" ]]; then
    CONTEXT+="## README (first 4000 chars):
$GITHUB_README

"
fi

# --- Generate def file with Claude ---
echo "Generating .def file with Claude..."

"$CLAUDE" --model "$CLAUDE_MODEL" -p "Generate a complete Apptainer .def file for the tool '$TOOL'.

Use the template below as a structural guide — it documents 5 install
patterns (0-4) with explicit decision rules refined from real builds.
Replace all <PLACEHOLDER> values with real content. Do not leave any
placeholders in the output.

Source hierarchy — when information conflicts, follow this order:
1. Any section above marked AUTHORITATIVE (upstream def, PyPI hit, bioconda
   hit, or source-derived dependency list) — these are verified facts, not
   inference.
2. GitHub README — for install method and tool entrypoints when nothing
   AUTHORITATIVE covers it. If no AUTHORITATIVE PyPI section is present
   above, do NOT use Pattern 1 or invent a version number — no matching
   PyPI release was found, so treat this as Pattern 2 or 3 instead.

Hard requirements (always apply):
- Bootstrap: docker
- Maintainer: sdweave2@ncsu.edu
- Version label in %labels must equal the installed version exactly
- %post must include: mkdir -p /rs1 /share /home /usr/local/usrapps
- Pin the version explicitly in the install command for reproducibility —
  use only a version number given to you above or found verbatim in the
  README/repo tree; never invent or guess one
- %runscript must be: exec <command> \"\$@\"
- %test must be a real invocation that exits 0 (prefer '<command> --help';
  if the tool has no top-level --help flag, use a bare invocation that
  prints usage and exits cleanly instead of guessing a flag that doesn't exist)
- Output ONLY the .def file content — no explanation, no markdown fences, no commentary

Pick exactly ONE pattern (0-4) per the template's decision rules. In short:
- Pattern 0 if an upstream def/Dockerfile was found above — adapt it.
- Pattern 4 if a bioconda package was found above — miniforge3 + mamba, never miniconda3 + conda.
- Pattern 1 if a PyPI release was found above — use that exact package name/version.
- Pattern 3 if source-derived dependencies were found above — use that exact list, not README guesses.
- Otherwise Pattern 2 (GitHub source with packaging file).

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

# Claude sometimes can't produce a valid .def (e.g. it needs a tool call —
# like looking up a version number or commit SHA — that isn't approved in
# a headless run) and responds with a clarifying question instead. Catch
# that here rather than reporting false success: real output always starts
# with "Bootstrap:" per the hard requirements above.
if [[ "$(head -1 "$DEF_FILE")" != Bootstrap:* ]]; then
    echo "ERROR: Claude did not produce a valid .def file — it responded instead of generating one:" >&2
    echo "---" >&2
    cat "$DEF_FILE" >&2
    echo "---" >&2
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
echo "  ./apptainer_build.sh   (with GITHUB_URL=\"$GITHUB_URL\" set in config.sh)"
