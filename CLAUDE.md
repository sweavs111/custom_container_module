# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Purpose

This workspace is used by BRC admins to build [Apptainer](https://apptainer.org/) container images (`.sif` files) for tools deployed on the NC State Hazel HPC cluster. Built images are published to `/usr/local/usrapps/brc/brc_modules/images/` for use with the BRC module system.

## History: this is a rebuild, not the original design

An earlier version of this pipeline (deleted; see git history before this rewrite if needed) auto-generated `.def` files from a much larger, more speculative set of heuristics and had no build verification loop — most of its bioconda-based tools failed to build (`exit 255` in `container_build.log`), and it was rebuilt from scratch by actually running real `apptainer build`s against real tools (plasmidVerify, PlasClass, fastaaiv2, Phanta) until they passed, then generalizing only from what was empirically observed to work. The lessons below are load-bearing — they came from failures, not guesses.

## Lessons from empirical builds

1. **`APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` must never default to `$HOME`.** Home on Hazel has a 1GB quota. Apptainer's default cache lives at `$HOME/.apptainer`, so pulling any nontrivial Docker base image (`continuumio/miniconda3`, `tensorflow/tensorflow`, etc.) during a build silently fills the quota mid-pull and dies with a generic `exit 255` that looks like a broken `.def` but isn't. This was the root cause of most old build failures. `config.sh` and `apptainer_build.sh` now always point both at scratch — never build manually without doing the same (see "Manual Build" below).

2. **Bioconda tools: use `condaforge/miniforge3` + `mamba`, never `continuumio/miniconda3` + classic `conda`.** Tested head-to-head on the exact same install (`plasclass=0.1.1` from bioconda): classic conda's solver stalled for 20+ minutes and never finished (CPU usage near zero — genuinely stuck, not just slow) resolving against the combined bioconda+conda-forge index. Mamba solved, downloaded, installed, and passed `%test` for the same package in under 5 minutes. This holds even for heavy environments — a 303-package Snakemake/Kraken2/R stack (Phanta) resolved and built successfully with mamba.

3. **For GitHub-source repos with no `setup.py`/`pyproject.toml`/`requirements.txt`, never guess dependencies from the README.** `fastaaiv2` is a flat collection of scripts with zero packaging metadata; its README doesn't list Python dependencies at all. The only ground truth is the actual `import`/`from` statements in the source. `create_def_file.sh` handles this automatically: when no PyPI release, no bioconda package, and no packaging file are found, it downloads the repo's `.py` files and parses their imports with Python's `ast` module, filtering out stdlib and local-module names, and hands Claude that exact list as the authoritative dependency set.

4. **Check the upstream repo for a shipped container definition before writing one from scratch.** `jaeger`'s `.def` was copied directly from `Yasas1994/Jaeger`'s own `singularity/jaeger_singularity.def` — it's the one tool in this repo's history that never needed debugging. `create_def_file.sh` now checks the repo tree for a `Dockerfile` or `*.def` first and tells Claude to adapt it (keep the install logic, only add our Maintainer label / Hazel bind-mount line) rather than re-deriving install steps that upstream already solved. (`tools/jaeger/` still carries `create_container.sh`/`make_module.sh` — manual build/deploy scripts from before `apptainer_build.sh` existed as a generic wrapper. They predate the current workflow and aren't a pattern to follow for new tools; use `apptainer_build.sh` instead.)

5. **A `.def` that "looks right" is not verified until it actually builds.** Several old `.def`s were structurally reasonable but failed purely due to the environment issues above (lesson 1), not content bugs. Never trust a generated `.def` without running an actual `apptainer build` against it — this is why `apptainer_build.sh` pauses for review after auto-generating a `.def`, and why it should be the last step, not skipped.

## Adding a New Tool (Typical Workflow)

Builds and deployments must run from a **login node** — Apptainer needs internet access during `%post`.

The pipeline's sole input is a GitHub repo URL, never a bare tool name. A
name alone is ambiguous — many bioinformatics tools share a name with
unrelated projects — so requiring the exact URL up front removes that
ambiguity entirely. The tool/module name (`tools/<ToolName>/`, `.sif`
filename, container-mod registration name) is always derived from the URL
(`derive_tool_name` in `config.sh` — the repo's own name, case preserved)
and is never typed separately, so it can't drift from the URL it came from.

1. Edit the two variables at the top of `config.sh`:
   ```bash
   GITHUB_URL="https://github.com/Shamir-Lab/PlasClass"
   DEPLOY=true   # false to skip module registration
   ```
2. Run `./apptainer_build.sh` from this directory.

`apptainer_build.sh` handles all steps automatically:
- Sets `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` to scratch (see lesson 1 above) before doing anything else.
- Derives `TOOL` from `GITHUB_URL`. If `tools/<ToolName>/<ToolName>.def` is missing, calls `create_def_file.sh <GitHubURL>` to generate it via Claude (gathers real evidence first — see "How `.def` generation works" below), then pauses for you to review the generated file before continuing.
- Extracts `Version` from the `.def` labels and names the output `tools/<ToolName>/<ToolName>-<Version>.sif`.
- Appends the full build command trace to `container_build.log`.
- If `DEPLOY=true` and the container-mod repos metadata file is missing, calls `create_repos_entry.sh` to generate it by parsing the `.def` directly.
- Copies the SIF to `/usr/local/usrapps/brc/brc_modules/images/` and runs `container-mod pipe` to register the module, then removes the local `.sif`.

**If the auto-generated `.def` needs manual fixes**, edit `tools/<ToolName>/<ToolName>.def` before re-running `apptainer_build.sh`. The script will not overwrite an existing `.def`.

## How `.def` generation works

`create_def_file.sh <GitHubURL>` derives `TOOL` from the URL, then gathers evidence, in this order, before ever calling Claude:

1. **Repo tree fetch** — `git/trees/<default_branch>?recursive=1`, used for everything below.
2. **Upstream container def check** (Pattern 0) — searches the tree for `*.def` or `Dockerfile`.
3. **Bioconda check** (Pattern 4) — `api.anaconda.org/package/bioconda/<tool>`.
4. **Packaging file check** — `setup.py`/`pyproject.toml`/`requirements.txt`/`setup.cfg` anywhere in the tree.
5. **Import-based dependency discovery** (Pattern 3) — only runs if 3 and 4 both came up empty: downloads the repo's `.py` files and parses real imports via `ast`, filtering stdlib and local names.
6. **README fetch** — supplementary context, not authoritative when 2/3/5 found something.

Everything found in steps 2/3/5 is passed to Claude marked `AUTHORITATIVE`, with explicit instructions to prefer it over README-derived guesses. See `template.def` for the full 5-pattern decision tree (0: adapt upstream def, 1: PyPI, 2: GitHub source with packaging, 3: GitHub source without packaging — use discovered imports, 4: bioconda via miniforge3+mamba). Pattern 1 (PyPI) is no longer auto-detected — there's no name to search PyPI with — so Claude only picks it when the README itself explicitly confirms a PyPI release.

The script only writes the `.def` — it does not build. Review the output before running `apptainer_build.sh`.

## Manual Build (Without the Wrapper)

```bash
module load apptainer
export APPTAINER_BINDPATH=""
export APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"   # never $HOME — see lesson 1
export APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
apptainer build tools/<ToolName>/<ToolName>-<Version>.sif tools/<ToolName>/<ToolName>.def
```

`APPTAINER_BINDPATH=""` is required — Hazel's Apptainer config sets a bind path that breaks builds.

## `.def` File Conventions

Start from `template.def` — it documents all 5 install patterns with the decision rules above inline as comments. All sections are required unless noted.

- **`%labels`**: `Maintainer sdweave2@ncsu.edu`, `Source <upstream URL>`, `Version <version>` — the version here drives the output `.sif` filename.
- **`%help`**: Document usage and all flags; surfaced via `apptainer run-help <image>.sif`.
- **`%post`**: Always include `mkdir -p /rs1 /share /home /usr/local/usrapps` for Hazel bind-mount points.
- **`%runscript`**: `exec <command> "$@"` — the `exec` ensures signals propagate correctly.
- **`%test`**: A real invocation that exits 0. Prefer `<command> --help`; if the tool has no top-level `--help` (e.g. `fastaaiv2`'s `fastaai_main` prints usage and exits on a bare call), use a bare invocation instead of guessing a flag that doesn't exist.

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `create_def_file.sh <GitHubURL>` | Generates `tools/<ToolName>/<ToolName>.def` for the given repo (tool name derived from the URL) — see "How `.def` generation works" above. |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) by parsing the `.def` directly — no Claude required, was never implicated in the old failures. |

Both scripts require the `claude` CLI (`/home/sdweave2/.local/bin/claude`, or on `PATH`) and outbound internet access (login node only).

## Repo Layout

```
custom_container_module/
├── apptainer_build.sh        # main build/deploy wrapper
├── config.sh                 # site-specific paths, cache/tmp dirs (edit before use)
├── create_def_file.sh        # auto-generates .def via Claude + upstream-def/bioconda/import evidence
├── create_repos_entry.sh     # auto-generates container-mod metadata by parsing the .def
├── template.def              # canonical .def template with the 5 install patterns
├── container_build.log       # timestamped build+deploy audit trail (gitignored)
├── tests/
│   ├── run_tests.sh          # regression suite for the pipeline scripts themselves
│   └── fixtures/
│       └── smoketest.def     # tiny fixture used only by run_tests.sh
└── tools/
    └── <ToolName>/
        ├── <ToolName>.def        # Apptainer definition (source of truth)
        └── <ToolName>-<Version>.sif  # built image (not committed to git)
```

## Testing Changes to the Pipeline Itself

`tests/run_tests.sh` regression-tests `config.sh`, `apptainer_build.sh`, `create_def_file.sh`, and `create_repos_entry.sh` — run it after editing any of them:

```bash
./tests/run_tests.sh            # unit tests + a real smoke build via apptainer_build.sh
./tests/run_tests.sh --no-build # unit tests only — no apptainer, no network
```

The smoke build runs a real `apptainer build` against `tests/fixtures/smoketest.def` (debian-slim, `DEPLOY=false`) in an isolated temp directory — needs `module load apptainer` + internet (login node only), but never touches `container-mod`, this repo's `tools/`, or `container_build.log`. This is separate from validating a new tool's `.def` (lesson 5 above) — it verifies the wrapper script logic itself, not any one tool's install steps.
