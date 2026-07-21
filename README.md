# BRC Custom Container Module Builder

Scripts for building and deploying [Apptainer](https://apptainer.org/) container images for tools on the NC State Hazel HPC cluster. Built images are published to the BRC module system and made available to users via `module load`.

## Requirements

- Run from a **login node** — Apptainer needs outbound internet access during `%post`
- `module load apptainer` (handled automatically by `apptainer_build.sh`)
- `claude` CLI available on PATH or set as `CLAUDE_BIN` in `config.sh` (required by `create_def_file.sh` and `fix_def_file.sh` only)

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

# Model for .def generation — pinned for reproducibility, not left on the
# CLI's floating default
CLAUDE_MODEL="claude-sonnet-5"

# Apptainer cache/tmp dirs — MUST be off $HOME (1GB quota on Hazel).
# See "Why cache/tmp dirs matter" below.
APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"
APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"

# Total build attempts per tool, including the first — i.e. this many
# minus one automatic Claude retry-fixes on a failed build.
DEF_FIX_MAX_ATTEMPTS=3
```

`apptainer_build.sh`, `create_def_file.sh`, and `batch_build.sh` source `config.sh` automatically.

## Why cache/tmp dirs matter

Apptainer's default image cache lives at `$HOME/.apptainer`. Home on Hazel has a 1GB quota, and pulling a Docker base image (`continuumio/miniconda3`, `tensorflow/tensorflow`, etc.) easily exceeds that — the build then dies mid-pull with a generic `exit 255` that looks like a broken `.def` but isn't. This was the cause of most build failures in an earlier version of this repo. `apptainer_build.sh` always exports `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` from `config.sh` before building — do the same if you ever build manually (see below).

## Adding a New Tool

1. Edit the two variables at the top of `config.sh`:
   ```bash
   SINGLE_GITHUB_URL="https://github.com/Shamir-Lab/PlasClass"
   DEPLOY=true   # false to skip module registration
   ```
   The GitHub URL is the sole identifier — the tool/module name (`tools/<ToolName>/`, `.sif`/`.def` filenames, container-mod registration name) is always derived from it automatically, never typed separately. This removes the ambiguity of matching a plain tool name to the right repo when several same-named projects exist.

2. Run the build wrapper:
   ```bash
   ./apptainer_build.sh
   ```

The script handles everything automatically:

- Sets `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` to scratch before doing anything else
- Looks up the tool's `.def` (`tools/<ToolName>/<ToolName>-<Version>.def`, tolerating the older bare `<ToolName>.def` too). If none exists, calls `create_def_file.sh` to generate one via Claude — gathering real evidence first, including a check for GPU-capable dependencies (torch, tensorflow, jax, ...) that layers a GPU-specific addendum on top of the normal install pattern when detected — then pauses for you to review the generated file before continuing
- Extracts the version from the `.def` labels and names the output `tools/<ToolName>/<ToolName>-<Version>.sif`
- Builds, retrying automatically on failure — see "Automatic Retry on Build Failure" below
- Appends a full build command trace (including retry attempts) to `container_build.log`
- If the retry loop modified the `.def`, prints a diff against the originally-reviewed version and pauses for confirmation before deploying
- If `DEPLOY=true`, calls `create_repos_entry.sh` to generate container-mod metadata (if missing), copies the SIF to the shared images directory, registers the module via `container-mod pipe`, patches the module-load logging hook via `patch_log_hook.sh`, then removes the local `.sif`

If the auto-generated `.def` needs manual fixes, edit the file `create_def_file.sh` reported (`tools/<ToolName>/<ToolName>-<Version>.def`) before re-running — the script will not overwrite an existing `.def` for that tool.

Whenever you commit other changes to this repo, also commit any new or updated tool `.def` files sitting uncommitted under `tools/` rather than leaving them behind — they're the source of truth for a tool's build and are cheap/safe to version (unlike `.sif` binaries, which stay gitignored).

## Batch Builds

To run the pipeline for a list of GitHub URLs instead of editing `config.sh` and re-running `apptainer_build.sh` by hand for each one:

```bash
./batch_build.sh urls.txt   # one GitHub URL per line; '#' comments and blank lines skipped
```

This loops `GITHUB_URL=<url> DEPLOY=true ./apptainer_build.sh` over the list — the same generate → review → build → deploy workflow as a manual run, just without touching `config.sh` per tool. A tool whose `.def` already exists builds straight through with no prompt; a tool that's already built *and* deployed (a matching `.sif` already sits in the public image dir) is skipped entirely. A failed build/deploy for one URL doesn't stop the rest — failures are collected and reported in a summary at the end.

## Automatic Retry on Build Failure

A Claude-generated `.def` failing its first real build is common enough that `apptainer_build.sh` retries automatically instead of stopping at the first failure:

1. **Classify the failure first.** Infra/environment signatures in the build log (disk full, DNS failure, rate limiting) hard-stop immediately — no `.def` edit can fix those, so they're never retried.
2. **Gather ground truth once**, on the first failure only: a `--sandbox` build of the same `.def` is probed directly (does the intended command actually resolve and run?) since a normal failed build leaves nothing on disk to inspect. The sandbox is always deleted right after — it's diagnostic only, never the shipped artifact.
3. **Fix with the same evidence the `.def` was built from** — `fix_def_file.sh` gives Claude the build log, the sandbox probe, and the original verified evidence saved during generation, so a retry doesn't re-guess a version number or package name it already had a confirmed answer for.
4. **Never trust a fix without checking it first** — every regenerated `.def` must keep the `%post -c /bin/bash` header with `set -e` as its first line, a real `%test`, a bareword `%runscript`, and its `Version` label before another build is even attempted. A "fix" that satisfies the build by weakening any of those is rejected outright.
5. **A passing retried build still gets a human diff review** before deploying — the build succeeding proves the `.def` runs, not that the retry's edit was the right one.

Bounded by `DEF_FIX_MAX_ATTEMPTS` in `config.sh` (default 3 total attempts, i.e. 2 automatic fixes).

## Manual Build

```bash
module load apptainer
export APPTAINER_BINDPATH=""
export APPTAINER_CACHEDIR="/share/brc/$USER/.apptainer/cache"   # never $HOME
export APPTAINER_TMPDIR="/share/brc/$USER/.apptainer/tmp"
mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"
apptainer build tools/<ToolName>/<ToolName>-<Version>.sif tools/<ToolName>/<ToolName>-<Version>.def
```

`APPTAINER_BINDPATH=""` is required — Hazel's Apptainer config sets a bind path that breaks builds.

## Repo Layout

```
custom_container_module/
├── apptainer_build.sh        # main build/deploy wrapper, including the retry loop
├── batch_build.sh            # loops apptainer_build.sh over a file of GitHub URLs
├── config.sh                 # site-specific paths, cache/tmp dirs (edit before use)
├── create_def_file.sh        # auto-generates .def via Claude + upstream-def/bioconda/import evidence
├── fix_def_file.sh           # regenerates a .def from real build-failure evidence (called by the retry loop)
├── def_lib.sh                # shared prompt/postprocessing/invariant-check/naming helpers
├── create_repos_entry.sh     # auto-generates container-mod metadata by parsing the .def
├── patch_log_hook.sh         # appends the module-load logging TCL hook after deploy
├── template.def              # canonical .def template — documents 5 install patterns + GPU addendum
├── tests/
│   ├── run_tests.sh              # regression suite for the pipeline scripts themselves
│   ├── run_retry_loop_tests.sh   # exercises the retry loop with a mocked apptainer + fix_def_file.sh
│   └── fixtures/
│       ├── smoketest.def         # tiny fixture used only by run_tests.sh
│       └── gpu_smoketest.def     # GPU-addendum-shaped fixture, same purpose
└── tools/
    └── <ToolName>/
        └── <ToolName>-<Version>.def  # Apptainer definition (source of truth)
```

`.sif` binaries and `container_build.log` are excluded from version control.

## Testing

`tests/run_tests.sh` is a regression suite for the pipeline scripts themselves (`config.sh`, `apptainer_build.sh`, `create_def_file.sh`, `create_repos_entry.sh`, `patch_log_hook.sh`, `def_lib.sh`) — run it after changing any of them, before trusting the change against a real tool build:

```bash
./tests/run_tests.sh            # unit tests + two real smoke builds via apptainer_build.sh
./tests/run_tests.sh --no-build # unit tests only — no apptainer, no network
```

The unit tests are pure bash/text-parsing checks. The smoke builds actually invoke `apptainer_build.sh` against two tiny fixtures — `tests/fixtures/smoketest.def` (plain) and `tests/fixtures/gpu_smoketest.def` (GPU-addendum-shaped) — each in an isolated temp directory, so they need `module load apptainer` and outbound internet (login node only) but never touch `container-mod`, this repo's `tools/`, or `container_build.log`.

`tests/run_retry_loop_tests.sh` (run automatically as part of the above, in both modes) exercises the retry loop's actual control flow — attempt counting, environment-failure short-circuiting, the sandbox diagnostic, invariant rejection/restore, and the pre-deploy confirmation gate — against the real `apptainer_build.sh`/`def_lib.sh` code, but with `apptainer` replaced by a bash function and `fix_def_file.sh` replaced by a stub, so it never runs a real build or calls the real `claude` CLI. Run it directly when iterating on the retry loop itself.

## `.def` File Conventions

Start from `template.def`. All sections are required unless noted.

| Section | Notes |
|---------|-------|
| `%labels` | `Maintainer`, `Source` (upstream URL), `Version` — version drives both the `.sif` and `.def` filenames |
| `%help` | Document usage and flags; surfaced via `apptainer run-help <image>.sif`. GPU-capable tools must document the `apptainer run --nv` requirement here |
| `%post` | Header must be exactly `%post -c /bin/bash`, with `set -e` as its first line — Apptainer's `%post` doesn't honor shebang lines and otherwise runs under `/bin/sh`, and without `set -e` a failed install step is silently ignored and the build reports success anyway. Always include `mkdir -p /rs1 /share /home /usr/local/usrapps` for Hazel bind mounts |
| `%runscript` | `exec <command> "$@"` — `<command>` must be a single bare executable name (no spaces/paths/interpreter prefix), resolvable via `command -v`; `exec` ensures signals propagate correctly |
| `%test` | A real invocation that exits 0 — prefer `--help`, fall back to a bare call or an output grep if the tool's CLI framework doesn't exit 0 on `--help`/`-h`. Must stay CPU-safe even for GPU-capable tools — the build host has no GPU attached |

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

### GPU-Capable Tools

Applies on top of whichever pattern (0-4) was picked above, whenever `create_def_file.sh` detects a GPU-framework dependency (torch, tensorflow, jax, cupy, onnxruntime-gpu, mxnet, paddlepaddle) in the repo's source, packaging file, or README:

- Do **not** switch to an `nvidia/cuda` base image just because GPU deps were detected. Hazel only exposes GPUs to a container via `apptainer run --nv` at *run* time (binding the host driver in) — a pip-installed CUDA-enabled wheel already bundles its own CUDA runtime. Only use a GPU base image if upstream's own def/Dockerfile already uses one (Pattern 0).
- `%help` must document that the container requires a GPU node, invoked with `apptainer run --nv <image>.sif`.
- `%test` must stay CPU-safe (`--help`, not real inference) — builds always run on a login node with no GPU attached.
- If a CUDA-specific package pin appears verbatim in the gathered evidence (e.g. `torch==2.1.0+cu121`, or a custom `--index-url`), use that exact pin — a plain `pip install torch` can silently resolve to a CPU-only wheel.

## `.def` File Naming

A tool's `.def` filename carries its version or pinned commit, matching the `.sif` output: `tools/<ToolName>/<ToolName>-<Version>.def` (e.g. `jaeger_v1.26.2.def`, `ViraLM-git-b7a6f4e.def`). `create_def_file.sh` names its output this way automatically — the exact filename isn't known until Claude generates the `Version` label, so it writes to a temp file first and renames once that label is read back out.

Every script that needs to find a tool's `.def` (`apptainer_build.sh`, `batch_build.sh`) does so via `find_tool_def` (`def_lib.sh`) rather than assuming a fixed path. `find_tool_def` also tolerates the older bare `tools/<ToolName>/<ToolName>.def` some earlier tools still carry — those weren't renamed retroactively. If more than one `.def` exists for a tool, it refuses to guess which is current — the caller errors out and lists the candidates.

## Helper Scripts

| Script | Purpose |
|--------|---------|
| `create_def_file.sh <GitHubURL>` | Generates `tools/<ToolName>/<ToolName>-<Version>.def` for the given repo (tool name from the URL, version from the generated `Version` label). Gathers real evidence first — checks for an upstream container def, checks bioconda, checks for GPU-framework dependencies, and for unpackaged GitHub-source repos, parses actual `import` statements in the source rather than trusting the README — then hands all of that to Claude marked as authoritative. See `CLAUDE.md` for the full evidence-gathering order. |
| `fix_def_file.sh <DefPath> <LogTailFile> [SandboxDiagFile]` | Regenerates a `.def` that failed a real build, using the actual failure evidence — called automatically by the retry loop in `apptainer_build.sh`, not normally invoked directly. |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) by parsing the `.def` directly — no Claude required |
| `patch_log_hook.sh <tool_lower> <version>` | Appends a TCL block to the module file that logs each `module load` event (timestamp, user, group, tool, version) to `/usr/local/usrapps/brc/brc_modules/logs/module_loads.log`; idempotent. Called automatically by `apptainer_build.sh` right after a successful `container-mod pipe` deploy — the same hook `container-mod_nf`'s `PATCH_LOG_HOOK` stage stamps onto modules built by that pipeline. |
| `batch_build.sh <urls_file>` | Runs `apptainer_build.sh` once per GitHub URL in a list — see "Batch Builds" above |

`def_lib.sh` isn't invoked directly — it's a shared library sourced by `create_def_file.sh`, `fix_def_file.sh`, `apptainer_build.sh`, and `batch_build.sh` holding the logic that has to stay identical across all of them (prompt requirements, output postprocessing, the invariant check, the environment-failure classifier, and `.def` lookup/naming).

`create_def_file.sh` only writes the `.def` — it does not build. Always review the generated file, then build with `apptainer_build.sh` (or manually) to verify it actually works before deploying.
