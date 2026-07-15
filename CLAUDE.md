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

6. **`%post` must start with `set -e` — Apptainer does not fail the build when a `%post` command fails.** `VirSorter`'s `.def` (adapted from upstream's own Dockerfile under lesson 4) bootstrapped its own conda via a decade-old `Miniconda-latest` installer whose bundled OpenSSL can no longer complete a TLS handshake with anaconda.org. The `conda install -c bioconda mcl muscle blast hmmer diamond perl-bioperl ...` line failed with `SSL: CERTIFICATE_VERIFY_FAILED` on every single build attempt — but because `%post` had no `set -e`, the script just continued past it, and `apptainer build` reported success with a `.sif` missing its entire bioconda toolchain. The bug went undetected for several debug cycles because later, unrelated symptoms (missing Perl modules) looked like the root cause. `template.def`'s `%post` now opens with `set -e` (add `set -o pipefail` too if any install line pipes through another command) so a failed install step fails the whole build immediately and visibly. **If you add `set -o pipefail`, the section header must be `%post -c /bin/bash`, not a `#!/bin/bash` line inside the body** — confirmed empirically (and in [Apptainer's own docs](https://apptainer.org/docs/user/latest/definition_files.html)) that `%post` does not honor shebang lines at all; without `-c /bin/bash` on the header, `%post` always runs under `/bin/sh` (dash), which doesn't support `-o pipefail` and fails immediately with `Illegal option -o pipefail`. An earlier version of this project's tooling enforced the shebang-in-body form instead, which is inert — it built for months without ever actually switching the interpreter, and every attempt to add `set -o pipefail` under it failed the same way (see `virmap`'s build history in `container_build.log`) until this was traced down and fixed.

7. **Pattern 0 ("adapt upstream's own container def") needs a staleness check before blind adoption.** It's the right call when upstream is actively maintained (`jaeger`'s def was copied verbatim and never needed debugging, per lesson 4). It has no defense when upstream's Dockerfile is abandoned. `VirSorter`'s upstream Dockerfile (`simroux/VirSorter`) is from ~2016: `FROM ubuntu:14.04`, using the exact `Miniconda-latest`/classic-`conda` pattern lesson 2 already bans. On top of the silent SSL failure in lesson 6, the old Ubuntu base's `dpkg` itself broke under Apptainer's rootless/SELinux-enabled build sandbox on Hazel (`cannot set security execution context for maintainer script`) — a failure mode real Docker never hits, only Apptainer's build sandbox. `create_def_file.sh` now greps a discovered upstream def/Dockerfile for staleness signals (EOL base tags, `continuumio/miniconda` + classic `conda`, bare `http://` installer URLs) and, when found, tells Claude to keep upstream's install *logic* (what to install, in what order) but swap in this project's own validated primitives — a current Ubuntu LTS base, or `condaforge/miniforge3` + `mamba` — instead of copying the literal rotted commands. (ubuntu:18.04 was empirically the cutoff on Hazel — 14.04 and 16.04 both hit the dpkg/SELinux failure, 18.04 did not — but `condaforge/miniforge3`'s own current Ubuntu base is the actual fix, not another old-Ubuntu guess.)

8. **A tool's own `--help`/`-h` doesn't always exit 0 — verify before picking it as `%test`.** `VirSorter`'s wrapper script calls Perl's `pod2usage()` on `-h`, which exits 2 by design (a `Pod::Usage` convention, not a failure). A build can be completely correct and still fail `%test` if the test blindly trusts `--help`'s exit code. Before relying on it, check how the tool's CLI framework actually terminates on `-h`/`--help` (this bit Perl `Getopt::Long`/`Pod::Usage` specifically, but the same risk applies to any custom arg parser); if it's nonzero by design, test on output content instead, e.g. `<command> --help 2>&1 | grep -q "<distinctive string>"`.

9. **Old pinned ML-stack recipes rot against today's package index, not just the OS.** `virSearcher`'s README-documented install (`tensorflow==1.14.0`, `keras==2.3.0`, Python 3.6) never pinned its transitive `protobuf` dependency; left unpinned, pip resolved the latest `protobuf` release (4.x), which requires Python >=3.7 and broke on the very Python version the rest of the pin set requires. The fix was pinning `protobuf` to the last release with a compatible wheel (`3.19.6`) — found by reading pip's own "available versions" error output, not guessed. Separately, any pinned dependency needing a from-source C/C++ build on an old Python (no modern wheel for that manylinux tag, e.g. `grpcio`) needs `build-essential` and `python3-dev` installed up front — don't wait for the build to fail on a missing `Python.h`.

10. **GPU support was never designed in, and the two places it showed up prove why that's a problem.** `jaeger`'s `.def` inherited a `tensorflow/tensorflow:*-gpu` base image purely as a side effect of Pattern 0 (adapting upstream's own Dockerfile verbatim, lesson 4) — no GPU-specific reasoning happened anywhere in the pipeline. `ViraLM` is a genuinely GPU-capable torch/transformers model built via Pattern 3, and came out plain CPU (`ubuntu:22.04`, no GPU env vars) because nothing in `create_def_file.sh`'s evidence-gathering or `template.def`'s patterns ever checked for GPU-capable dependencies; GPU execution was bolted on afterward by hand in a separate `viralm_gpu_job.sh` Slurm script. The fix is *not* a 6th install pattern that asks Claude to judge "should this use GPU" from README tone — that's exactly the kind of open-ended, un-grounded heuristic this project's history (see above) already burned itself on once. Instead, `create_def_file.sh` mechanically greps every piece of evidence it already gathers (discovered imports, fetched packaging-file content, README, PyPI summary, upstream def content) for known GPU-framework package names (`detect_gpu_signals`, `def_lib.sh`: torch, tensorflow, jax, cupy, onnxruntime-gpu, mxnet, paddlepaddle) and, on a hit, tells Claude to apply `template.def`'s **GPU addendum** on top of whichever pattern (0-4) it already picked. Two things the addendum encodes that are easy to get wrong: (1) Hazel only exposes GPUs via `apptainer run --nv` at *run* time binding the host driver in — a pip-installed CUDA-enabled wheel already bundles its own CUDA runtime, so detecting GPU deps must NOT trigger switching to an `nvidia/cuda` base image (that's only ever needed if upstream's own def/Dockerfile already used one, i.e. still Pattern 0); (2) `%test` must stay CPU-safe (`--help`, not real inference) because the build always runs on a login node with no GPU attached, the same build-time-vs-runtime distinction lesson 1's cache/tmp fix and lesson 5's "a passing build isn't proof" both already rest on.

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
   SINGLE_GITHUB_URL="https://github.com/Shamir-Lab/PlasClass"
   DEPLOY=true   # false to skip module registration
   ```
2. Run `./apptainer_build.sh` from this directory.

`apptainer_build.sh` handles all steps automatically:
- Sets `APPTAINER_CACHEDIR`/`APPTAINER_TMPDIR` to scratch (see lesson 1 above) before doing anything else.
- Derives `TOOL` from `GITHUB_URL`. If `tools/<ToolName>/<ToolName>.def` is missing, calls `create_def_file.sh <GitHubURL>` to generate it via Claude (gathers real evidence first — see "How `.def` generation works" below), then pauses for you to review the generated file before continuing.
- Extracts `Version` from the `.def` labels and names the output `tools/<ToolName>/<ToolName>-<Version>.sif`.
- Builds, retrying automatically on failure up to `DEF_FIX_MAX_ATTEMPTS` times (config.sh) — see "Automatic Retry on Build Failure" below.
- Appends the full build command trace (including retry attempts) to `container_build.log`.
- If the retry loop modified the `.def` at all, prints a diff against the originally-reviewed version and pauses for confirmation before deploying — a build passing isn't sufficient evidence the fix was legitimate (lesson 6), so this is a second, narrower review gate than the one after initial generation.
- If `DEPLOY=true` and the container-mod repos metadata file is missing, calls `create_repos_entry.sh` to generate it by parsing the `.def` directly.
- Copies the SIF to `/usr/local/usrapps/brc/brc_modules/images/` and runs `container-mod pipe` to register the module, then removes the local `.sif`.

**If the auto-generated `.def` needs manual fixes**, edit `tools/<ToolName>/<ToolName>.def` before re-running `apptainer_build.sh`. The script will not overwrite an existing `.def`.

## Committing Changes

Whenever a commit is made to this repo for any reason (pipeline script
changes, doc updates, etc.), also commit any new or updated tool `.def`
files under `tools/` sitting uncommitted at the time — don't leave them
behind just because the commit at hand was about something else. `.def`
files are the source of truth for a tool's build and are cheap/safe to
commit (unlike `.sif` binaries, which stay gitignored); there's no reason
for a working `.def` to linger unversioned once other work is being
pushed anyway.

## Batch Builds

To run the pipeline for a list of GitHub URLs instead of editing `config.sh` and re-running `apptainer_build.sh` by hand for each one, use `batch_build.sh`:

```bash
./batch_build.sh urls.txt   # one GitHub URL per line; '#' comments and blank lines skipped
```

This loops `GITHUB_URL=<url> DEPLOY=true ./apptainer_build.sh` over the list — one pass per URL (generate `.def` if missing → pause for review → build → deploy), same as the manual workflow, just without re-editing `config.sh` each time. The review pause in `apptainer_build.sh` (lesson 5) still fires per URL whenever a new `.def` is generated, so a batch run is not fully unattended the first time through a given tool list — you still review each generated `.def` before its build proceeds. A tool whose `.def` already exists builds straight through with no prompt. A failed build/deploy for one URL doesn't stop the rest; failures are collected and reported in a summary at the end.

`config.sh` derives `GITHUB_URL="${GITHUB_URL:-$SINGLE_GITHUB_URL}"` — an environment `GITHUB_URL`, if set, always wins over `SINGLE_GITHUB_URL`. `batch_build.sh` sets `GITHUB_URL` per iteration via the environment, so it always takes priority automatically. This means switching between single and batch runs never requires touching or reverting anything in `config.sh` beyond `SINGLE_GITHUB_URL` itself — there's no default-variable syntax to remember or restore.

## How `.def` generation works

`create_def_file.sh <GitHubURL>` derives `TOOL` from the URL, then gathers evidence, in this order, before ever calling Claude:

1. **Repo tree fetch** — `git/trees/<default_branch>?recursive=1`, used for everything below.
2. **Upstream container def check** (Pattern 0) — searches the tree for `*.def` or `Dockerfile`.
3. **Bioconda check** (Pattern 4) — `api.anaconda.org/package/bioconda/<tool>`.
4. **Packaging file check** — `setup.py`/`pyproject.toml`/`requirements.txt`/`setup.cfg` anywhere in the tree; if one is found, its raw content is also fetched (capped at 4000 chars, same as the README fetch) — the existence check alone doesn't see what's actually pinned inside, which the GPU check below needs.
5. **Import-based dependency discovery** (Pattern 3) — only runs if 3 and 4 both came up empty: downloads the repo's `.py` files and parses real imports via `ast`, filtering stdlib and local names.
6. **GPU-framework signal check** — greps everything gathered in steps 3-5 above, plus the README and PyPI summary, for known GPU-framework package names (`detect_gpu_signals`, `def_lib.sh`: torch, tensorflow, jax, cupy, onnxruntime-gpu, mxnet, paddlepaddle). See lesson 10.
7. **README fetch** — supplementary context, not authoritative when 2/3/5 found something.

Everything found in steps 2/3/5/6 is passed to Claude marked `AUTHORITATIVE`, with explicit instructions to prefer it over README-derived guesses. See `template.def` for the full 5-pattern decision tree (0: adapt upstream def, 1: PyPI, 2: GitHub source with packaging, 3: GitHub source without packaging — use discovered imports, 4: bioconda via miniforge3+mamba) plus its GPU addendum, applied on top of whichever pattern is chosen whenever step 6 finds a hit. Pattern 1 (PyPI) is no longer auto-detected — there's no name to search PyPI with — so Claude only picks it when the README itself explicitly confirms a PyPI release.

The script only writes the `.def` — it does not build. Review the output before running `apptainer_build.sh`.

## Automatic Retry on Build Failure

A Claude-generated `.def` failing its first real build is common enough
(see the empirical lessons above) that `apptainer_build.sh` retries
automatically instead of stopping at the first failure:

1. **Classify the failure first.** `is_environment_failure` (`def_lib.sh`)
   greps the build log tail for infra signatures — disk full, DNS
   failure, rate limiting — that no `.def` edit can fix. These hard-stop
   immediately; only genuinely content-shaped failures get retried.
2. **Gather ground truth once.** On the first failure only,
   `run_sandbox_diagnostic` (`apptainer_build.sh`) builds the same `.def`
   with `--sandbox` and probes it directly — `command -v
   <runscript-command>` and a manual `--help` run inside the live
   filesystem — since a normal failed build leaves nothing on disk to
   inspect, while a sandbox build does. The sandbox is always deleted
   immediately after probing; it is never the shipped artifact.
3. **Fix with the same evidence the `.def` was built from.**
   `fix_def_file.sh` feeds Claude the current `.def`, the build log tail,
   the sandbox probe (if gathered), and the original AUTHORITATIVE
   evidence saved by `create_def_file.sh` to
   `tools/<ToolName>/.def_context` — so a retry doesn't re-guess a
   version number or bioconda package name it was already given a
   verified answer for.
4. **Never trust a fix without checking it first.**
   `check_def_invariants` (`def_lib.sh`) rejects any regenerated `.def`
   that dropped `set -e` from `%post`, hollowed out `%test` into a no-op,
   used a non-bareword `%runscript`, or lost its `Version` label — before
   another build is even attempted. This is the direct guard against a
   model "fixing" a failing build by weakening it instead of the real bug
   (lesson 6, self-inflicted).
5. **A passing retried build still gets a human diff review** before
   `DEPLOY` — the build succeeding proves the `.def` runs, not that the
   retry loop's edit was the right one.

Bounded by `DEF_FIX_MAX_ATTEMPTS` in `config.sh` (default 3 total
attempts, i.e. 2 automatic fixes). `.def.attempt<N>` snapshots and the
`.def_context` sidecar are scratch/audit only — gitignored, cleaned up at
the end of each run; the durable record is the diffs already appended to
`container_build.log`.

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
| `fix_def_file.sh <DefPath> <LogTailFile> [SandboxDiagFile]` | Regenerates a `.def` that failed a real build, using the actual failure evidence — called automatically by `apptainer_build.sh`'s retry loop, not normally invoked directly. See "Automatic Retry on Build Failure" above. |
| `create_repos_entry.sh <def_file> <output_path>` | Generates the container-mod metadata file (Description, Home Page, Programs) by parsing the `.def` directly — no Claude required, was never implicated in the old failures. |
| `batch_build.sh <urls_file>` | Runs `apptainer_build.sh` once per GitHub URL in a list — see "Batch Builds" above. |

`def_lib.sh` is not invoked directly — it's a shared library sourced by
`create_def_file.sh`, `fix_def_file.sh`, and `apptainer_build.sh` holding
the logic that must stay identical across initial generation and
retry-fixing (the prompt's hard requirements, output postprocessing, the
invariant check, and the environment-failure classifier).

`create_def_file.sh` and `fix_def_file.sh` require the `claude` CLI
(`/home/sdweave2/.local/bin/claude`, or on `PATH`) and outbound internet
access (login node only).

## Repo Layout

```
custom_container_module/
├── apptainer_build.sh        # main build/deploy wrapper
├── batch_build.sh            # loops apptainer_build.sh over a file of GitHub URLs
├── config.sh                 # site-specific paths, cache/tmp dirs (edit before use)
├── create_def_file.sh        # auto-generates .def via Claude + upstream-def/bioconda/import evidence
├── fix_def_file.sh           # regenerates a .def from real build-failure evidence (called by apptainer_build.sh's retry loop)
├── def_lib.sh                # shared prompt/postprocessing/invariant-check helpers, sourced by the three scripts above
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

`tests/run_tests.sh` regression-tests `config.sh`, `apptainer_build.sh`, `create_def_file.sh`, `create_repos_entry.sh`, and `def_lib.sh` (`check_def_invariants`, `is_environment_failure`) — run it after editing any of them:

```bash
./tests/run_tests.sh            # unit tests + a real smoke build via apptainer_build.sh
./tests/run_tests.sh --no-build # unit tests only — no apptainer, no network
```

`tests/run_retry_loop_tests.sh` (run automatically as part of the above,
in both modes) exercises the retry loop's actual control flow — attempt
counting, `is_environment_failure` short-circuiting, the sandbox
diagnostic firing only on the first failure, `check_def_invariants`
rejecting and reverting an unsafe fix, and the pre-`DEPLOY` confirmation
gate — against real `apptainer_build.sh`/`def_lib.sh` code, but with
`apptainer` replaced by an exported bash function and `fix_def_file.sh`
replaced by a stub (so it never runs a real build or calls the real
`claude` CLI). Run it directly (`./tests/run_retry_loop_tests.sh`) when
iterating on the retry loop itself.

The smoke build runs a real `apptainer build` against `tests/fixtures/smoketest.def` (debian-slim, `DEPLOY=false`) in an isolated temp directory — needs `module load apptainer` + internet (login node only), but never touches `container-mod`, this repo's `tools/`, or `container_build.log`. This is separate from validating a new tool's `.def` (lesson 5 above) — it verifies the wrapper script logic itself, not any one tool's install steps.
