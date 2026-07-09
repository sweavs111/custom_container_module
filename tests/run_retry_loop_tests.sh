#!/bin/bash
# Regression tests for apptainer_build.sh's automatic retry loop (see
# CLAUDE.md "Automatic Retry on Build Failure"). Exercises the real
# control flow — attempt counting, environment-failure short-circuiting,
# the sandbox diagnostic, invariant rejection/restore, and the pre-deploy
# confirmation gate — without a real apptainer build or a real Claude
# call:
#
#   - `apptainer` is replaced by an exported bash function. Bash resolves
#     functions before PATH lookups for a bare command name, so this
#     intercepts every `apptainer build` / `apptainer build --sandbox` /
#     `apptainer exec` call regardless of what `module load apptainer`
#     does to PATH.
#   - `fix_def_file.sh` is replaced with a stub script placed next to a
#     private copy of apptainer_build.sh/config.sh/def_lib.sh (the real
#     script always resolves it via "$(dirname "$0")/fix_def_file.sh", so
#     the copy's directory is what controls which one runs).
#
# No network, no real apptainer, no real claude — safe to run alongside
# the other unit tests.

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
check_files_match() {
    local desc="$1" file="$2" expected_content="$3"
    if diff -q <(printf '%s' "$expected_content") "$file" > /dev/null 2>&1; then
        check "$desc" "match" "match"
    else
        check "$desc" "mismatch" "match"
    fi
}

FIXTURE_DEF='Bootstrap: docker
From: ubuntu:22.04

%labels
    Maintainer sdweave2@ncsu.edu
    Source https://github.com/example/retrytesttool
    Version 1.2.3

%post
    set -e
    echo "installing"

%runscript
    exec tool "$@"

%test
    tool --help
'

# Mock apptainer. $MOCK_BUILD_PLAN_FILE has one "exitcode:::stderr text"
# line per expected `apptainer build` call (the last line repeats for any
# call beyond the file's length). Sandbox/exec calls are simulated too so
# run_sandbox_diagnostic's probe logic runs for real against fake state.
apptainer() {
    if [[ "$1" == "build" && "$2" == "--sandbox" ]]; then
        local dir="$4"
        mkdir -p "$dir"
        local count_file="$MOCK_STATE_DIR/sandbox_call_count"
        local n=0
        [[ -f "$count_file" ]] && n=$(cat "$count_file")
        echo "$((n + 1))" > "$count_file"
        return 0
    elif [[ "$1" == "build" ]]; then
        local sif="$2" def="$3"
        local count_file="$MOCK_STATE_DIR/build_call_count"
        local n=0
        [[ -f "$count_file" ]] && n=$(cat "$count_file")
        n=$((n + 1))
        echo "$n" > "$count_file"
        local plan_line
        plan_line=$(sed -n "${n}p" "$MOCK_BUILD_PLAN_FILE" 2>/dev/null)
        [[ -z "$plan_line" ]] && plan_line=$(tail -1 "$MOCK_BUILD_PLAN_FILE")
        local exit_code="${plan_line%%:::*}" stderr_text="${plan_line#*:::}"
        if [[ "$exit_code" == "0" ]]; then
            echo "mock apptainer build: succeeded"
            : > "$sif"
            return 0
        else
            echo "$stderr_text" >&2
            return "$exit_code"
        fi
    elif [[ "$1" == "exec" ]]; then
        shift 2   # exec, --writable
        local dir="$1"; shift
        if [[ "$1" == "command" && "$2" == "-v" ]]; then
            [[ "${MOCK_SANDBOX_CMD_RESOLVES:-yes}" == "yes" ]] && { echo "/usr/local/bin/$3"; return 0; }
            return 1
        else
            echo "mock exec: $* (inside $dir)"
            return 0
        fi
    else
        echo "mock apptainer: unhandled invocation: $*" >&2
        return 1
    fi
}
export -f apptainer

# Private copies of the scripts under test, with a stub fix_def_file.sh
# standing in for the one that would otherwise call the real claude CLI.
SCRIPTS_DIR=$(mktemp -d)
cp "$REPO_ROOT/apptainer_build.sh" "$REPO_ROOT/config.sh" "$REPO_ROOT/def_lib.sh" "$SCRIPTS_DIR/"

cat > "$SCRIPTS_DIR/fix_def_file.sh" <<'STUBEOF'
#!/bin/bash
set -euo pipefail
DEF_FILE="$1"
LOG_TAIL_FILE="$2"
SANDBOX_DIAG_FILE="${3:-}"

COUNT_FILE="$MOCK_STATE_DIR/fix_call_count"
N=0
[[ -f "$COUNT_FILE" ]] && N=$(cat "$COUNT_FILE")
N=$((N + 1))
echo "$N" > "$COUNT_FILE"

{
    echo "=== fix call $N ==="
    echo "--- log tail received ---"
    cat "$LOG_TAIL_FILE"
    echo "--- sandbox diag received ---"
    [[ -n "$SANDBOX_DIAG_FILE" && -f "$SANDBOX_DIAG_FILE" ]] && cat "$SANDBOX_DIAG_FILE"
    echo "=== end ==="
} >> "$MOCK_STATE_DIR/fix_call_log"

case "${MOCK_FIX_MODE:-good}" in
    fail)
        echo "mock fix_def_file.sh: simulated failure" >&2
        exit 1
        ;;
    bad_invariant)
        sed 's/^    set -e$/    echo "no set -e here"/' "$MOCK_GOOD_FIXTURE" > "$DEF_FILE"
        ;;
    *)
        cp "$MOCK_GOOD_FIXTURE" "$DEF_FILE"
        ;;
esac
STUBEOF
chmod +x "$SCRIPTS_DIR/fix_def_file.sh"

GOOD_FIXTURE=$(mktemp)
printf '%s' "$FIXTURE_DEF" > "$GOOD_FIXTURE"

# Runs one scenario: fresh isolated BUILD_TMP (cwd for the build, so
# tools/ and container_build.log never touch the real repo) and
# MOCK_STATE_DIR (call counters/logs), invokes the copied
# apptainer_build.sh with DEPLOY=false, and leaves both dirs in place for
# the caller to assert against and clean up.
run_scenario() {
    local plan="$1" sandbox_resolves="$2" fix_mode="$3" stdin_text="$4"
    BUILD_TMP=$(mktemp -d)
    MOCK_STATE_DIR=$(mktemp -d)
    MOCK_BUILD_PLAN_FILE=$(mktemp)
    printf '%s\n' "$plan" > "$MOCK_BUILD_PLAN_FILE"
    export MOCK_STATE_DIR MOCK_BUILD_PLAN_FILE
    export MOCK_GOOD_FIXTURE="$GOOD_FIXTURE"
    export MOCK_SANDBOX_CMD_RESOLVES="$sandbox_resolves"
    export MOCK_FIX_MODE="$fix_mode"

    mkdir -p "$BUILD_TMP/tools/retrytesttool"
    printf '%s' "$FIXTURE_DEF" > "$BUILD_TMP/tools/retrytesttool/retrytesttool.def"

    ( cd "$BUILD_TMP" && printf '%b' "$stdin_text" | \
        GITHUB_URL="https://github.com/example/retrytesttool" DEPLOY=false \
        "$SCRIPTS_DIR/apptainer_build.sh" )
    SCENARIO_EXIT=$?
}
build_calls()   { cat "$MOCK_STATE_DIR/build_call_count" 2>/dev/null || echo 0; }
fix_calls()     { cat "$MOCK_STATE_DIR/fix_call_count" 2>/dev/null || echo 0; }
sandbox_calls() { cat "$MOCK_STATE_DIR/sandbox_call_count" 2>/dev/null || echo 0; }
cleanup_scenario() { rm -rf "$BUILD_TMP" "$MOCK_STATE_DIR" "$MOCK_BUILD_PLAN_FILE"; }

echo "== retry loop: recovers from a fixable failure on attempt 2 =="
run_scenario $'1:::ERROR: could not install package foo-bar (version conflict)\n0:::' "no" "good" "y\n"
check "exit code"                              "$SCENARIO_EXIT"  "0"
check "build called twice"                     "$(build_calls)"  "2"
check "fix_def_file called once"               "$(fix_calls)"    "1"
check "sandbox diagnostic ran once"            "$(sandbox_calls)" "1"
# grep -q/found-missing rather than an exact line count: with the mock
# `apptainer` implemented as a bash function (not a separate process, per
# the module-load note above), run_logged's `set -x` also traces the
# mock's own internal statements, so the message can legitimately appear
# on more than one traced line here even though it would appear once in
# production (where apptainer is a real external binary, not traced).
check "container_build.log captured the real apptainer error text (not just the xtrace)" \
    "$(grep -q 'could not install package foo-bar' "$BUILD_TMP/container_build.log" && echo found || echo missing)" "found"
check "fix_def_file.sh received the real failure text in its log tail" \
    "$(grep -q 'could not install package foo-bar' "$MOCK_STATE_DIR/fix_call_log" && echo found || echo missing)" "found"
check "fix_def_file.sh received a sandbox probe noting the command didn't resolve" \
    "$(grep -q 'does NOT resolve' "$MOCK_STATE_DIR/fix_call_log" && echo found || echo missing)" "found"
cleanup_scenario

echo
echo "== retry loop: environment-style failures hard-stop without a Claude call =="
run_scenario "1:::No space left on device" "yes" "good" ""
check "exit code"                   "$SCENARIO_EXIT"   "1"
check "build called once"           "$(build_calls)"   "1"
check "fix_def_file NOT called"      "$(fix_calls)"      "0"
check "sandbox diagnostic NOT run"   "$(sandbox_calls)"  "0"
cleanup_scenario

echo
echo "== retry loop: gives up after DEF_FIX_MAX_ATTEMPTS attempts =="
run_scenario "1:::pip install failed: package not found" "yes" "good" ""
check "exit code"                                          "$SCENARIO_EXIT"   "1"
check "build called three times (DEF_FIX_MAX_ATTEMPTS)"    "$(build_calls)"   "3"
check "fix_def_file called twice (one fewer than attempts)" "$(fix_calls)"     "2"
check "sandbox diagnostic ran only once (attempt 1 only)"   "$(sandbox_calls)" "1"
cleanup_scenario

echo
echo "== retry loop: rejects and reverts a fix that violates safety invariants =="
run_scenario "1:::pip install failed: package not found" "yes" "bad_invariant" ""
check "exit code"                                    "$SCENARIO_EXIT" "1"
check "build called once (rejected fix never retried)" "$(build_calls)" "1"
check "fix_def_file called once"                       "$(fix_calls)"   "1"
check_files_match ".def restored to the originally reviewed version" \
    "$BUILD_TMP/tools/retrytesttool/retrytesttool.def" "$FIXTURE_DEF"
check "retry scratch artifacts cleaned up" \
    "$(ls "$BUILD_TMP"/tools/retrytesttool/*.attempt* "$BUILD_TMP"/tools/retrytesttool/*.orig.tmp 2>/dev/null | wc -l | tr -d ' ')" "0"
cleanup_scenario

echo
echo "== retry loop: aborts cleanly if fix_def_file.sh itself fails =="
run_scenario "1:::pip install failed: package not found" "yes" "fail" ""
check "exit code"                        "$SCENARIO_EXIT" "1"
check "build called once"                "$(build_calls)" "1"
check "fix_def_file called once"         "$(fix_calls)"   "1"
check_files_match ".def left unchanged" \
    "$BUILD_TMP/tools/retrytesttool/retrytesttool.def" "$FIXTURE_DEF"
cleanup_scenario

echo
echo "== retry loop: does not interfere with a build that succeeds on the first attempt =="
run_scenario "0:::" "yes" "good" ""
check "exit code"                   "$SCENARIO_EXIT"   "0"
check "build called once"           "$(build_calls)"   "1"
check "fix_def_file NOT called"      "$(fix_calls)"      "0"
check "sandbox diagnostic NOT run"   "$(sandbox_calls)"  "0"
cleanup_scenario

echo
echo "== retry loop: declining the post-fix review prompt stops without deploying =="
run_scenario $'1:::ERROR: could not install package foo-bar (version conflict)\n0:::' "yes" "good" "n\n"
check "exit code"          "$SCENARIO_EXIT" "0"
check "build called twice" "$(build_calls)" "2"
cleanup_scenario

rm -rf "$SCRIPTS_DIR" "$GOOD_FIXTURE"

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
