# BRC Custom Container Module Builder

Scripts for building and deploying [Apptainer](https://apptainer.org/) container images for tools on the NC State Hazel HPC cluster. Built images are published to the BRC module system and made available to users via `module load`.

## Requirements

- Run from a **login node** — Apptainer needs outbound internet access during `%post`
- `module load apptainer` (handled automatically by `apptainer_build.sh`)
- `claude` CLI available on PATH or set as `CLAUDE_BIN` in `config.sh` (required by `create_def_file.sh` only)

## Configuration

Before first use, edit `config.sh` to match your environment:

```bash
# Path to the container-mod executable
CONTAINER_MOD="/path/to/container-mod"

# container-mod profile to use for deployment
CONTAINER_MOD_PROFILE="brc"

# Fallback path to the claude CLI (used if 'claude' is not on PATH)
CLAUDE_BIN="/home/you/.local/bin/claude"
```

`apptainer_build.sh` and `create_def_file.sh` source `config.sh` automatically.

## Adding a New Tool

1. Edit the two variables at the top of `apptainer_build.sh`:
   ```bash
   TOOL="ToolName"
   DEPLOY=true   # false to skip module registration
   ```

2. Run the build wrapper:
   ```bash
   ./apptainer_build.sh
   ```

The script handles everything automatically:

- If `tools/<ToolName>/<ToolName>.def` is missing, calls `create_def_file.sh` to generate one via Claude (queries PyPI/GitHub for install info first)
- Extracts the version from the `.def` labels and names the output `tools/<ToolName>/<ToolName>-<Version>.sif`
- Appends a full build command trace to `container_build.log`
- If `DEPLOY=true`, calls `create_repos_entry.sh` to generate container-mod metadata (if missing), copies the SIF to the shared images directory, registers the module via `container-mod pipe`, then removes the local `.sif`

If the auto-generated `.def` needs manual fixes, edit `tools/<ToolName>/<ToolName>.def` before re-running — the script will not overwrite an existing `.def`.

## Manual Build

```bash
module load apptainer
APPTAINER_BINDPATH="" apptainer build tools/<ToolName>/<ToolName>-<Version>.sif tools/<ToolName>/<ToolName>.def
```

`APPTAINER_BINDPATH=""` is required — Hazel's Apptainer config sets a bind path that breaks builds.

## Repo Layout

```
custom_container_module/
├── apptainer_build.sh        # main build/deploy wrapper
├── config.sh                 # site-specific paths and settings (edit before use)
├── create_def_file.sh        # auto-generates .def via Claude + PyPI/GitHub
├── create_repos_entry.sh     # auto-generates container-mod metadata by parsing the .def
├── template.def              # canonical .def template
├── tools/
│   └── <ToolName>/
│       └── <ToolName>.def    # Apptainer definition (source of truth)
└── test_container/           # minimal working example
    ├── test.def
    └── scripts/              # files injected into image via %files
```

`.sif` binaries and `container_build.log` are excluded from version control.

## `.def` File Conventions

Start from `template.def`. All sections are required unless noted.

| Section | Notes |
|---------|-------|
| `%labels` | `Maintainer`, `Source` (upstream URL), `Version` — version drives the `.sif` filename |
| `%help` | Document usage and flags; surfaced via `apptainer run-help <image>.sif` |
| `%post` | Always include `mkdir -p /rs1 /share /home /usr/local/usrapps` for Hazel bind mounts |
| `%runscript` | `exec <command> "$@"` — `exec` ensures signals propagate correctly |
| `%test` | Minimal sanity check run during `apptainer build` |

Three install patterns for `%post` (pick one):

```bash
# PyPI release (preferred for reproducibility)
pip3 install --no-cache-dir <Tool>==<Version>

# GitHub source (when no PyPI release exists)
pip3 install --no-cache-dir git+<URL>@<tag>

# Clone + local install (when setup.py/pyproject.toml is present)
git clone --branch <tag> --depth 1 <URL> /opt/<Tool>
pip3 install --no-cache-dir /opt/<Tool>
```

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `create_def_file.sh <ToolName>` | Generates `tools/<ToolName>/<ToolName>.def` by querying PyPI/GitHub then prompting Claude |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) by parsing the `.def` directly — no Claude required |
