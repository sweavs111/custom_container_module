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

# Total build attempts per tool, including the first — i.e. this many
# minus one automatic Claude retry-fixes on a failed build.
DEF_FIX_MAX_ATTEMPTS=3
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
- Builds, retrying automatically on failure — see "Automatic Retry on Build Failure" below
- Appends a full build command trace (including retry attempts) to `container_build.log`
- If the retry loop modified the `.def`, prints a diff against the originally-reviewed version and pauses for confirmation before deploying
- If `DEPLOY=true`, calls `create_repos_entry.sh` to generate container-mod metadata (if missing), copies the SIF to the shared images directory, registers the module via `container-mod pipe`, then removes the local `.sif`

If the auto-generated `.def` needs manual fixes, edit `tools/<ToolName>/<ToolName>.def` before re-running — the script will not overwrite an existing `.def`.

## Automatic Retry on Build Failure

A Claude-generated `.def` failing its first real build is common enough that `apptainer_build.sh` retries automatically instead of stopping at the first failure:

1. **Classify the failure first.** Infra/environment signatures in the build log (disk full, DNS failure, rate limiting) hard-stop immediately — no `.def` edit can fix those, so they're never retried.
2. **Gather ground truth once**, on the first failure only: a `--sandbox` build of the same `.def` is probed directly (does the intended command actually resolve and run?) since a normal failed build leaves nothing on disk to inspect. The sandbox is always deleted right after — it's diagnostic only, never the shipped artifact.
3. **Fix with the same evidence the `.def` was built from** — `fix_def_file.sh` gives Claude the build log, the sandbox probe, and the original verified evidence saved during generation, so a retry doesn't re-guess a version number or package name it already had a confirmed answer for.
4. **Never trust a fix without checking it first** — every regenerated `.def` must keep `set -e`, a real `%test`, a bareword `%runscript`, and its `Version` label before another build is even attempted. A "fix" that satisfies the build by weakening any of those is rejected outright.
5. **A passing retried build still gets a human diff review** before deploying — the build succeeding proves the `.def` runs, not that the retry's edit was the right one.

Bounded by `DEF_FIX_MAX_ATTEMPTS` in `config.sh` (default 3 total attempts, i.e. 2 automatic fixes).

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
├── apptainer_build.sh        # main build/deploy wrapper, including the retry loop
├── config.sh                 # site-specific paths, cache/tmp dirs (edit before use)
├── create_def_file.sh        # auto-generates .def via Claude + upstream-def/bioconda/import evidence
├── fix_def_file.sh           # regenerates a .def from real build-failure evidence (called by the retry loop)
├── def_lib.sh                # shared prompt/postprocessing/invariant-check helpers
├── create_repos_entry.sh     # auto-generates container-mod metadata by parsing the .def
├── template.def              # canonical .def template — documents 5 install patterns
├── tests/
│   ├── run_tests.sh              # regression suite for the pipeline scripts themselves
│   ├── run_retry_loop_tests.sh   # exercises the retry loop with a mocked apptainer + fix_def_file.sh
│   └── fixtures/
│       └── smoketest.def     # tiny fixture used only by run_tests.sh
└── tools/
    └── <ToolName>/
        └── <ToolName>.def    # Apptainer definition (source of truth)
```

`.sif` binaries and `container_build.log` are excluded from version control.

## Testing

`tests/run_tests.sh` is a regression suite for the pipeline scripts themselves (`config.sh`, `apptainer_build.sh`, `create_def_file.sh`, `create_repos_entry.sh`, `def_lib.sh`) — run it after changing any of them, before trusting the change against a real tool build:

```bash
./tests/run_tests.sh            # unit tests + a real smoke build via apptainer_build.sh
./tests/run_tests.sh --no-build # unit tests only — no apptainer, no network
```

The unit tests are pure bash/text-parsing checks. The smoke build actually invokes `apptainer_build.sh` against `tests/fixtures/smoketest.def` (a tiny debian-slim image, `DEPLOY=false`) in an isolated temp directory, so it needs `module load apptainer` and outbound internet (login node only) but never touches `container-mod`, this repo's `tools/`, or `container_build.log`.

`tests/run_retry_loop_tests.sh` (run automatically as part of the above, in both modes) exercises the retry loop's actual control flow — attempt counting, environment-failure short-circuiting, the sandbox diagnostic, invariant rejection/restore, and the pre-deploy confirmation gate — against the real `apptainer_build.sh`/`def_lib.sh` code, but with `apptainer` replaced by a bash function and `fix_def_file.sh` replaced by a stub, so it never runs a real build or calls the real `claude` CLI. Run it directly when iterating on the retry loop itself.

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
| `fix_def_file.sh <DefPath> <LogTailFile> [SandboxDiagFile]` | Regenerates a `.def` that failed a real build, using the actual failure evidence — called automatically by the retry loop in `apptainer_build.sh`, not normally invoked directly. |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) by parsing the `.def` directly — no Claude required |

`def_lib.sh` isn't invoked directly — it's a shared library sourced by `create_def_file.sh`, `fix_def_file.sh`, and `apptainer_build.sh` holding the logic that has to stay identical across initial generation and retry-fixing (prompt requirements, output postprocessing, the invariant check, and the environment-failure classifier).

`create_def_file.sh` only writes the `.def` — it does not build. Always review the generated file, then build with `apptainer_build.sh` (or manually) to verify it actually works before deploying.
