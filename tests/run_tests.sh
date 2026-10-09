#!/bin/bash
# Minimal regression suite for the container-build pipeline. Run this after
# any change to config.sh / apptainer_build.sh / create_def_file.sh /
# create_repos_entry.sh, before trusting the change against a real build.
#
# Usage:
#   ./tests/run_tests.sh            # unit tests + real smoke build
#   ./tests/run_tests.sh --no-build # unit tests only (no apptainer/network)
#
# The unit tests are pure bash/text-parsing checks — no network, no
# apptainer. The smoke build actually runs apptainer_build.sh against a
# tiny fixture image (tests/fixtures/smoketest.def, debian-slim-based) with
# DEPLOY=false, so it needs `module load apptainer` + outbound internet
# (login node only) but never touches container-mod or the repo's own
# tools/ directory or container_build.log. The same non-no-build branch also
# runs a real (dry-run only) conda solve to empirically verify the
# CONDA_OVERRIDE_CUDA=12 Pattern-4 GPU rule (CLAUDE.md lesson 11) actually
# flips the resolved tensorflow build variant, not just that a GPU-shaped
# .def builds (see tests/fixtures/gpu_smoketest.def's own note on why it
# deliberately doesn't install a real GPU framework).

set -uo pipefail
# apptainer_build.sh prefers $SLURM_SUBMIT_DIR over $(dirname "$0") to find
# its sibling scripts. If these tests run inside a Slurm job (e.g. sbatch on
# xfer), that would point the scripts under test at the real repo — bypassing
# the stubbed fix_def_file.sh/create_def_file.sh and calling the real claude CLI.
unset SLURM_SUBMIT_DIR
cd "$(dirname "$0")/.."
REPO_ROOT="$PWD"

PASS=0
FAIL=0

check() {
    local desc="$1" actual="$2" expected="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  ok   - $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL - $desc"
        echo "         expected: $expected"
        echo "         actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "== derive_tool_name (config.sh) =="
source config.sh
source def_lib.sh
check "plain repo"      "$(derive_tool_name 'https://github.com/Shamir-Lab/PlasClass')"     "PlasClass"
check "trailing slash"  "$(derive_tool_name 'https://github.com/Shamir-Lab/PlasClass/')"    "PlasClass"
check ".git suffix"     "$(derive_tool_name 'https://github.com/Shamir-Lab/PlasClass.git')" "PlasClass"
check "monorepo subdir" "$(derive_tool_name 'https://github.com/RasmussenLab/vamb/tree/vamb_n2v_asy/workflow_PlasMAAG')" "workflow_PlasMAAG"
check "monorepo subdir, trailing slash" "$(derive_tool_name 'https://github.com/RasmussenLab/vamb/tree/main/subdir/')" "subdir"

echo
echo "== Version-label extraction (apptainer_build.sh's grep|awk) =="
VERSION_TMP=$(mktemp)
cat > "$VERSION_TMP" <<'EOF'
%labels
    Maintainer sdweave2@ncsu.edu
    Source https://github.com/example/tool
    Version 1.2.3
EOF
EXTRACTED=$(grep -m1 -iE '^\s+Version\s+' "$VERSION_TMP" | awk '{print $NF}')
check "version label extracted" "$EXTRACTED" "1.2.3"
rm -f "$VERSION_TMP"

echo
echo "== create_repos_entry.sh parsing =="
PARSE_TMP=$(mktemp -d)
cat > "$PARSE_TMP/fixture.def" <<'EOF'
Bootstrap: docker
From: ubuntu:22.04

%labels
    Maintainer sdweave2@ncsu.edu
    Source https://github.com/example/tool
    Version 1.2.3

%help
    tool — a fixture tool for testing repos-entry parsing

%runscript
    exec tool "$@"
EOF
./create_repos_entry.sh "$PARSE_TMP/fixture.def" "$PARSE_TMP/repos_out" > /dev/null
check "description" "$(grep '^Description:' "$PARSE_TMP/repos_out")" "Description: a fixture tool for testing repos-entry parsing"
check "home page"   "$(grep '^Home Page:' "$PARSE_TMP/repos_out")"  "Home Page: https://github.com/example/tool"
check "programs"    "$(grep '^Programs:' "$PARSE_TMP/repos_out")"  "Programs: tool"
rm -rf "$PARSE_TMP"

echo
echo "== patch_log_hook.sh =="
HOOK_TMP=$(mktemp -d)
mkdir -p "$HOOK_TMP/fixturetool"
cat > "$HOOK_TMP/fixturetool/1.0" <<'EOF'
#%Module1.0#####################################################################
module-whatis "Name:        fixturetool"
EOF

MOD_DIR="$HOOK_TMP" ./patch_log_hook.sh "fixturetool" "1.0" > /dev/null
check "hook appended"      "$(grep -c 'Log module load' "$HOOK_TMP/fixturetool/1.0")" "1"
check "sources the shared hook" "$(grep -cxF 'source "/usr/local/usrapps/brc/env/module_log.tcl"' "$HOOK_TMP/fixturetool/1.0")" "1"
check "no inline logging code"  "$(grep -c 'module_loads.log' "$HOOK_TMP/fixturetool/1.0")" "0"

MOD_DIR="$HOOK_TMP" ./patch_log_hook.sh "fixturetool" "1.0" > /dev/null
check "idempotent — no duplicate hook on second run" "$(grep -c 'Log module load' "$HOOK_TMP/fixturetool/1.0")" "1"

check "missing module file warns but does not fail" \
    "$(MOD_DIR="$HOOK_TMP" ./patch_log_hook.sh "nonexistent" "9.9" 2>&1 1>/dev/null; echo "exit=$?")" \
    "[WARN] patch_log_hook: module file not found: $HOOK_TMP/nonexistent/9.9
exit=0"

rm -rf "$HOOK_TMP"

echo
echo "== check_def_invariants (def_lib.sh) =="
INVARIANT_TMP=$(mktemp -d)

cat > "$INVARIANT_TMP/valid.def" <<'EOF'
Bootstrap: docker
From: ubuntu:22.04

%labels
    Maintainer sdweave2@ncsu.edu
    Source https://github.com/example/tool
    Version 1.2.3

%post -c /bin/bash
    set -e
    echo "installing"

%runscript
    exec tool "$@"

%test
    tool --help
EOF

cat > "$INVARIANT_TMP/no_set_e.def" <<'EOF'
Bootstrap: docker
From: ubuntu:22.04

%labels
    Version 1.2.3

%post -c /bin/bash
    echo "installing"

%runscript
    exec tool "$@"

%test
    tool --help
EOF

cat > "$INVARIANT_TMP/trivial_test.def" <<'EOF'
Bootstrap: docker
From: ubuntu:22.04

%labels
    Version 1.2.3

%post -c /bin/bash
    set -e
    echo "installing"

%runscript
    exec tool "$@"

%test
    exit 0
EOF

cat > "$INVARIANT_TMP/multiword_runscript.def" <<'EOF'
Bootstrap: docker
From: ubuntu:22.04

%labels
    Version 1.2.3

%post -c /bin/bash
    set -e
    echo "installing"

%runscript
    exec python3 /opt/tool/tool.py "$@"

%test
    tool --help
EOF

check_invariant_result() {
    local desc="$1" file="$2" expect="$3" actual
    if check_def_invariants "$file" >/dev/null 2>&1; then
        actual="pass"
    else
        actual="fail"
    fi
    check "$desc" "$actual" "$expect"
}

check_invariant_result "valid def passes"                    "$INVARIANT_TMP/valid.def"                "pass"
check_invariant_result "missing set -e fails"                 "$INVARIANT_TMP/no_set_e.def"             "fail"
check_invariant_result "trivial %test fails"                  "$INVARIANT_TMP/trivial_test.def"         "fail"
check_invariant_result "multi-word %runscript fails"          "$INVARIANT_TMP/multiword_runscript.def"  "fail"

rm -rf "$INVARIANT_TMP"

echo
echo "== is_environment_failure (def_lib.sh) =="

check_env_failure_result() {
    local desc="$1" text="$2" expect="$3" actual
    if is_environment_failure "$text" >/dev/null 2>&1; then
        actual="env"
    else
        actual="not-env"
    fi
    check "$desc" "$actual" "$expect"
}

check_env_failure_result "disk full classified as environment" \
    "apptainer: error: No space left on device" "env"
check_env_failure_result "DNS failure classified as environment" \
    "curl: (6) Could not resolve host: github.com" "env"
check_env_failure_result "rate limit classified as environment" \
    "HTTP/1.1 429 Too Many Requests" "env"
check_env_failure_result "SSL cert error NOT classified as environment" \
    "SSL: CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate" "not-env"

echo
echo "== detect_gpu_signals (def_lib.sh) =="

check_gpu_signal_result() {
    local desc="$1" text="$2" expect="$3" actual
    if detect_gpu_signals "$text" >/dev/null 2>&1; then
        actual="detected"
    else
        actual="not-detected"
    fi
    check "$desc" "$actual" "$expect"
}

check_gpu_signal_result "torch pin detected" \
    "torch==2.1.0
numpy==1.24.4" "detected"
check_gpu_signal_result "tensorflow-gpu detected" \
    "tensorflow-gpu==2.15.0" "detected"
check_gpu_signal_result "plain CPU deps not detected" \
    "numpy==1.24.4
pandas==2.1.0" "not-detected"
check_gpu_signal_result "word-boundary false positive avoided (torchlight)" \
    "torchlight==0.3.2" "not-detected"

echo
echo "== retry loop (apptainer_build.sh) — mocked apptainer + fix_def_file.sh =="
if ./tests/run_retry_loop_tests.sh; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi

echo
if [[ "${1:-}" == "--no-build" ]]; then
    echo "== smoke build == skipped (--no-build)"
else
    CONFIG_BACKUP=$(mktemp)
    cp config.sh "$CONFIG_BACKUP"
    restore_config() { cp "$CONFIG_BACKUP" config.sh; rm -f "$CONFIG_BACKUP"; }
    trap restore_config EXIT

    # Runs apptainer_build.sh for real against a tiny fixture (isolated CWD
    # so tools/, container_build.log, etc. land in a temp dir, never the
    # real repo — but invoked via the real script's absolute path so it
    # still sources the temporarily-patched real config.sh via its own
    # dirname). Shared by the plain smoketest and the GPU-addendum-shaped
    # gpu_smoketest fixture below — same build/verify shape, different def.
    run_smoke_build() {
        local tool="$1" fixture="$2" version="$3"
        echo "== smoke build ($tool, real apptainer build via apptainer_build.sh, DEPLOY=false) =="

        sed -i "s|^GITHUB_URL=.*|GITHUB_URL=\"https://github.com/brc-smoketest/$tool\"|" config.sh
        sed -i 's|^DEPLOY=.*|DEPLOY=false|' config.sh

        local build_tmp
        build_tmp=$(mktemp -d)
        mkdir -p "$build_tmp/tools/$tool"
        cp "$fixture" "$build_tmp/tools/$tool/$tool.def"

        ( cd "$build_tmp" && "$REPO_ROOT/apptainer_build.sh" )
        local status=$?

        if [[ $status -eq 0 && -f "$build_tmp/tools/$tool/$tool-$version.sif" ]]; then
            echo "  ok   - apptainer_build.sh built $tool-$version.sif and exited 0"
            PASS=$((PASS + 1))
        else
            echo "  FAIL - apptainer_build.sh smoke build for $tool (exit $status)"
            FAIL=$((FAIL + 1))
        fi

        rm -rf "$build_tmp"
    }

    run_smoke_build "smoketest" "tests/fixtures/smoketest.def" "0.0.1"
    run_smoke_build "gpu-smoketest" "tests/fixtures/gpu_smoketest.def" "0.0.1"

    # Empirically verifies the Pattern-4 GPU rule in template.def / CLAUDE.md
    # lesson 11 — not just that a GPU-flavored .def *builds* (gpu_smoketest
    # above deliberately skips installing a real GPU framework so that stays
    # fast), but that CONDA_OVERRIDE_CUDA=12 actually flips which tensorflow
    # BUILD conda-forge/pkgs-main's solver picks on this GPU-less host.
    # Dry-run only (--dry-run): resolves metadata, doesn't download the
    # ~200-600MB packages themselves, so this stays fast despite needing a
    # real solve against the real channels. Network + apptainer required,
    # same as the smoke builds above.
    #
    # Fragile by nature: depends on conda-forge/pkgs-main's current build
    # tags (cpu_* vs cuda<major><minor>*) for tensorflow-base at this
    # version constraint. If this starts failing, don't assume the rule
    # itself is wrong — re-verify with a manual dry-run solve first (see
    # CLAUDE.md lesson 11 for the exact commands used to establish it) and
    # update the version pin/expected tag here if conda-forge's own
    # packaging convention has moved on.
    echo "== CONDA_OVERRIDE_CUDA=12 flips a Pattern-4 GPU-package solve (CLAUDE.md lesson 11) =="

    export APPTAINER_BINDPATH=""
    export APPTAINER_CACHEDIR APPTAINER_TMPDIR
    mkdir -p "$APPTAINER_CACHEDIR" "$APPTAINER_TMPDIR"

    solve_tensorflow_build_tag() {
        local override="$1" extra_env=()
        [[ -n "$override" ]] && extra_env=(--env "CONDA_OVERRIDE_CUDA=$override")
        apptainer exec --cleanenv --writable-tmpfs \
            --env TMPDIR=/tmp --env CONDA_PKGS_DIRS=/tmp/pkgs \
            "${extra_env[@]}" \
            docker://condaforge/miniforge3:24.3.0-0 bash -c '
                mkdir -p /tmp/pkgs
                mamba create -n test -c conda-forge -c bioconda "python>=3.11,<3.14" "tensorflow>=2.21" --dry-run -y
            ' 2>/dev/null | grep -m1 -E '^\s*\+\s*tensorflow-base\s'
    }

    classify_build_tag() {
        local line="$1"
        if echo "$line" | grep -qiE '\bcuda[0-9]'; then
            echo "cuda-build"
        elif echo "$line" | grep -qiE '\bcpu_'; then
            echo "cpu-build"
        else
            echo "unknown ($line)"
        fi
    }

    NO_OVERRIDE_LINE=$(solve_tensorflow_build_tag "")
    check "no override — solves to CPU-only build on this GPU-less host" \
        "$(classify_build_tag "$NO_OVERRIDE_LINE")" "cpu-build"

    OVERRIDE_LINE=$(solve_tensorflow_build_tag "12")
    check "CONDA_OVERRIDE_CUDA=12 — solves to CUDA-enabled build" \
        "$(classify_build_tag "$OVERRIDE_LINE")" "cuda-build"

    restore_config
    trap - EXIT
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
