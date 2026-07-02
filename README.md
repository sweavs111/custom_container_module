# BRC Custom Container Module Builder

Scripts for building and deploying [Apptainer](https://apptainer.org/) container images for tools on the NC State Hazel HPC cluster. Built images are published to the BRC module system and made available to users via `module load`.

## Requirements

- Run from a **login node** — Apptainer needs outbound internet access during `%post`
- `module load apptainer` (handled automatically by `apptainer_build.sh`)
- `claude` CLI available on PATH or set as `CLAUDE_BIN` in `config.sh` (required by `create_def_file.sh` only)

## Configuration

Before first use, edit `config.sh` to match your environment:

```bash
# --- Edit before a single manual build ---
SINGLE_GITHUB_URL=""  # e.g. "https://github.com/Shamir-Lab/PlasClass"
DEPLOY=true            # false to skip module registration

# Path to the container-mod executable
CONTAINER_MOD="/path/to/container-mod"

# container-mod profile to use for deployment
CONTAINER_MOD_PROFILE="brc"

# Fallback path to the claude CLI (used if 'claude' is not on PATH)
CLAUDE_BIN="/home/you/.local/bin/claude"

# Apptainer cache/tmp dirs — MUST be off $HOME (1GB quota on Hazel).
# See "Why cache/tmp dirs matter" below.
APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"
APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"
```

`apptainer_build.sh` and `create_def_file.sh` source `config.sh` automatically.

## Why cache/tmp dirs matter

Apptainer's default image cache lives at `$HOME/.apptainer`. Home on Hazel has a 1GB quota, and pulling a Docker base image (`continuumio/miniconda3`, `tensorflow/tensorflow`, etc.) easily exceeds that — the build then dies mid-pull with a generic `exit 255` that looks like a broken `.def` but isn't. This was the cause of most build failures in an earlier version of this repo. `apptainer_build.sh` always exports `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` from `config.sh` before building — do the same if you ever build manually (see below).

## Adding a New Tool

1. Edit the two variables at the top of `config.sh`:
   ```bash
   SINGLE_GITHUB_URL="https://github.com/Shamir-Lab/PlasClass"
   DEPLOY=true   # false to skip module registration
   ```
   The GitHub URL is the sole identifier — the tool/module name (`tools/<ToolName>/`, `.sif` filename, container-mod registration name) is always derived from it automatically, never typed separately. This removes the ambiguity of matching a plain tool name to the right repo when several same-named projects exist.

2. Run the build wrapper:
   ```bash
   ./apptainer_build.sh
   ```

The script handles everything automatically:

- Sets `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` to scratch before doing anything else
- If `tools/<ToolName>/<ToolName>.def` is missing, calls `create_def_file.sh` to generate one via Claude, then pauses for you to review the generated file before continuing
- Extracts the version from the `.def` labels and names the output `tools/<ToolName>/<ToolName>-<Version>.sif`
- Appends a full build command trace to `container_build.log`
- If `DEPLOY=true`, calls `create_repos_entry.sh` to generate container-mod metadata (if missing), copies the SIF to the shared images directory, registers the module via `container-mod pipe`, then removes the local `.sif`

If the auto-generated `.def` needs manual fixes, edit `tools/<ToolName>/<ToolName>.def` before re-running — the script will not overwrite an existing `.def`.

## Manual Build

```bash
module load apptainer
export APPTAINER_BINDPATH=""
export APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"   # never $HOME
export APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
apptainer build tools/<ToolName>/<ToolName>-<Version>.sif tools/<ToolName>/<ToolName>.def
```

`APPTAINER_BINDPATH=""` is required — Hazel's Apptainer config sets a bind path that breaks builds.

## Repo Layout

```
custom_container_module/
├── apptainer_build.sh        # main build/deploy wrapper
├── config.sh                 # site-specific paths, cache/tmp dirs (edit before use)
├── create_def_file.sh        # auto-generates .def via Claude + upstream-def/bioconda/import evidence
├── create_repos_entry.sh     # auto-generates container-mod metadata by parsing the .def
├── template.def              # canonical .def template — documents 5 install patterns
├── tests/
│   ├── run_tests.sh          # regression suite for the pipeline scripts themselves
│   └── fixtures/
│       └── smoketest.def     # tiny fixture used only by run_tests.sh
└── tools/
    └── <ToolName>/
        └── <ToolName>.def    # Apptainer definition (source of truth)
```

`.sif` binaries and `container_build.log` are excluded from version control.

## Testing

`tests/run_tests.sh` is a regression suite for the pipeline scripts themselves (`config.sh`, `apptainer_build.sh`, `create_def_file.sh`, `create_repos_entry.sh`) — run it after changing any of them, before trusting the change against a real tool build:

```bash
./tests/run_tests.sh            # unit tests + a real smoke build via apptainer_build.sh
./tests/run_tests.sh --no-build # unit tests only — no apptainer, no network
```

The unit tests are pure bash/text-parsing checks. The smoke build actually invokes `apptainer_build.sh` against `tests/fixtures/smoketest.def` (a tiny debian-slim image, `DEPLOY=false`) in an isolated temp directory, so it needs `module load apptainer` and outbound internet (login node only) but never touches `container-mod`, this repo's `tools/`, or `container_build.log`.

## `.def` File Conventions

Start from `template.def`. All sections are required unless noted.

| Section | Notes |
|---------|-------|
| `%labels` | `Maintainer`, `Source` (upstream URL), `Version` — version drives the `.sif` filename |
| `%help` | Document usage and flags; surfaced via `apptainer run-help <image>.sif` |
| `%post` | Always include `mkdir -p /rs1 /share /home /usr/local/usrapps` for Hazel bind mounts |
| `%runscript` | `exec <command> "$@"` — `exec` ensures signals propagate correctly |
| `%test` | A real invocation that exits 0 — prefer `--help`, fall back to a bare call if the tool has no top-level help flag |

Five install patterns, in preference order (`template.def` has the full decision rules as inline comments):

```bash
# Pattern 0 — upstream repo ships its own container def (Dockerfile / *.def):
# adapt it directly rather than re-deriving install steps from scratch.

# Pattern 1 — PyPI release with a modern wheel (From: ubuntu:22.04). Only
# used when the README explicitly confirms a PyPI release — this is no
# longer checked automatically since input is a GitHub URL, not a name:
pip3 install --no-cache-dir <Tool>==<Version>

# Pattern 2 — GitHub source with setup.py/pyproject.toml, no PyPI release:
pip3 install --no-cache-dir git+<URL>@<tag>

# Pattern 3 — GitHub source with NO packaging file at all: don't guess deps
# from the README — use the actual imports discovered from the source
# (create_def_file.sh does this automatically):
pip3 install --no-cache-dir <deps discovered from grepping imports>
git clone --depth 1 --branch <tag> <URL> /opt/<Tool>

# Pattern 4 — bioconda/conda-forge distribution:
# From: condaforge/miniforge3:24.3.0-0  (NOT continuumio/miniconda3 — its
# classic solver can hang indefinitely on the combined bioconda+conda-forge
# index; miniforge3 ships mamba, which solves the same request in minutes)
mamba create -n <tool> -y -c conda-forge -c bioconda <pkg>=<ver>
```

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `create_def_file.sh <GitHubURL>` | Generates `tools/<ToolName>/<ToolName>.def` for the given repo (the tool name is derived from the URL). Gathers real evidence first — checks for an upstream container def, checks bioconda, and for unpackaged GitHub-source repos, parses actual `import` statements in the source rather than trusting the README — then hands all of that to Claude marked as authoritative. See `CLAUDE.md` for the full evidence-gathering order. |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) by parsing the `.def` directly — no Claude required |

`create_def_file.sh` only writes the `.def` — it does not build. Always review the generated file, then build with `apptainer_build.sh` (or manually) to verify it actually works before deploying.
