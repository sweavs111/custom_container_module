# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This workspace is used by BRC admins to build [Apptainer](https://apptainer.org/) container images (`.sif` files) for tools deployed on the NC State Hazel HPC cluster. Built images are published to `/usr/local/usrapps/brc/brc_modules/images/` for use with the BRC module system.

## Adding a New Tool (Typical Workflow)

Builds and deployments must run from a **login node** — Apptainer needs internet access during `%post`.

1. Edit the two variables at the top of `apptainer_build.sh`:
   ```bash
   TOOL="ToolName"
   DEPLOY=true   # false to skip module registration
   ```
2. Run `./apptainer_build.sh` from this directory.

`apptainer_build.sh` handles all steps automatically:
- If `<ToolName>/<ToolName>.def` is missing, calls `create_def_file.sh <ToolName>` to generate it via Claude (fetches PyPI/GitHub info first).
- Extracts `Version` from the `.def` labels and names the output `<ToolName>/<ToolName>-<Version>.sif`.
- Appends the full build command trace to `container_build.log`.
- If `DEPLOY=true` and the container-mod repos metadata file is missing, calls `create_repos_entry.sh` to generate it via Claude.
- Copies the SIF to `/usr/local/usrapps/brc/brc_modules/images/` and runs `container-mod pipe` to register the module, then removes the local `.sif`.

**If the auto-generated `.def` needs manual fixes**, edit `<ToolName>/<ToolName>.def` before re-running `apptainer_build.sh`. The script will not overwrite an existing `.def`.

## Manual Build (Without the Wrapper)

```bash
module load apptainer
APPTAINER_BINDPATH="" apptainer build <ToolName>/<ToolName>-<Version>.sif <ToolName>/<ToolName>.def
```

`APPTAINER_BINDPATH=""` is required — Hazel's Apptainer config sets a bind path that breaks builds.

## `.def` File Conventions

Start from `template.def`. All sections are required unless noted.

- **`%labels`**: `Maintainer sdweave2@ncsu.edu`, `Source <upstream URL>`, `Version <version>` — the version here drives the output `.sif` filename.
- **`%help`**: Document usage and all flags; surfaced via `apptainer run-help <image>.sif`.
- **`%post`**:
  - Always include `mkdir -p /rs1 /share /home /usr/local/usrapps` for Hazel bind-mount points.
  - Standard apt-get pattern: `apt-get update -qq && apt-get install -y --no-install-recommends ... && apt-get clean && rm -rf /var/lib/apt/lists/*`
  - Three install patterns (pick one):
    - PyPI release (preferred): `pip3 install --no-cache-dir <Tool>==<Version>`
    - GitHub source: `pip3 install --no-cache-dir git+<URL>@<tag>`
    - Clone + local install: `git clone --branch <tag> --depth 1 <URL> /opt/<Tool> && pip3 install --no-cache-dir /opt/<Tool>`
  - Pin versions explicitly when tool compatibility is fragile (see the Theano/Keras pins in `DeepVirFinder.def`).
- **`%runscript`**: `exec <command> "$@"` — the `exec` ensures signals propagate correctly.
- **`%test`**: Minimal sanity check; `apptainer test` runs this during the build.

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `create_def_file.sh <ToolName>` | Generates `<ToolName>/<ToolName>.def` by querying PyPI/GitHub then prompting Claude. |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) from a `.def` by prompting Claude. |

Both scripts require the `claude` CLI (`/home/sdweave2/.local/bin/claude`) and outbound internet access (login node only).

## Repo Layout

```
build_container/
├── apptainer_build.sh        # main build/deploy wrapper
├── create_def_file.sh        # auto-generates .def via Claude + PyPI/GitHub
├── create_repos_entry.sh     # auto-generates container-mod metadata via Claude
├── template.def              # canonical .def template
├── container_build.log       # timestamped build+deploy audit trail
├── <ToolName>/
│   ├── <ToolName>.def        # Apptainer definition (source of truth)
│   └── <ToolName>-<Version>.sif  # built image (not committed to git)
└── test_container/           # minimal working example
    ├── test.def
    └── scripts/              # files injected into image via %files
```
