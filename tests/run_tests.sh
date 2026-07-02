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
# tools/ directory or container_build.log.

set -uo pipefail
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
if [[ "${1:-}" == "--no-build" ]]; then
    echo "== smoke build == skipped (--no-build)"
else
    echo "== smoke build (real apptainer build via apptainer_build.sh, DEPLOY=false) =="

    CONFIG_BACKUP=$(mktemp)
    cp config.sh "$CONFIG_BACKUP"
    restore_config() { cp "$CONFIG_BACKUP" config.sh; rm -f "$CONFIG_BACKUP"; }
    trap restore_config EXIT

    sed -i 's|^GITHUB_URL=.*|GITHUB_URL="https://github.com/brc-smoketest/smoketest"|' config.sh
    sed -i 's|^DEPLOY=.*|DEPLOY=false|' config.sh

    BUILD_TMP=$(mktemp -d)
    mkdir -p "$BUILD_TMP/tools/smoketest"
    cp tests/fixtures/smoketest.def "$BUILD_TMP/tools/smoketest/smoketest.def"

    # cd into an isolated CWD so tools/, container_build.log, etc. land in
    # BUILD_TMP, not the real repo — but invoke via the real script's
    # absolute path so it still sources the (temporarily patched) real
    # config.sh via its own dirname.
    ( cd "$BUILD_TMP" && "$REPO_ROOT/apptainer_build.sh" )
    BUILD_STATUS=$?

    if [[ $BUILD_STATUS -eq 0 && -f "$BUILD_TMP/tools/smoketest/smoketest-0.0.1.sif" ]]; then
        echo "  ok   - apptainer_build.sh built smoketest-0.0.1.sif and exited 0"
        PASS=$((PASS + 1))
    else
        echo "  FAIL - apptainer_build.sh smoke build (exit $BUILD_STATUS)"
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$BUILD_TMP"
    restore_config
    trap - EXIT
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
