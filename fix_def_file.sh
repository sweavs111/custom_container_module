#!/bin/bash
# Regenerates a .def file that failed a real apptainer build, using the
# actual failure evidence (build log tail, optional sandbox probe results)
# plus whatever AUTHORITATIVE context was gathered for the original
# generation (create_def_file.sh's .def_context sidecar, if present).
#
# Usage: fix_def_file.sh <DefPath> <LogTailFile> [SandboxDiagFile]
#
# Called by apptainer_build.sh's retry loop — never invoked directly in
# normal use. Overwrites <DefPath> in place only if Claude's output passes
# the same postprocessing/sanity check as initial generation
# (finalize_generated_def, def_lib.sh). Does NOT run check_def_invariants
# itself — apptainer_build.sh does that immediately after, since it also
# owns the decision of what to do on failure (abort vs. keep the last
# known-good .def).

set -euo pipefail

source "$(dirname "$0")/config.sh"
source "$(dirname "$0")/def_lib.sh"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: fix_def_file.sh <DefPath> <LogTailFile> [SandboxDiagFile]" >&2
    exit 1
fi
DEF_FILE="$1"
LOG_TAIL_FILE="$2"
SANDBOX_DIAG_FILE="${3:-}"

if [[ ! -f "$DEF_FILE" ]]; then
    echo "ERROR: $DEF_FILE does not exist" >&2
    exit 1
fi
if [[ ! -f "$LOG_TAIL_FILE" ]]; then
    echo "ERROR: $LOG_TAIL_FILE does not exist" >&2
    exit 1
fi

CLAUDE=$(command -v claude 2>/dev/null || echo "$CLAUDE_BIN")
if [[ ! -x "$CLAUDE" ]]; then
    echo "ERROR: claude CLI not found" >&2
    exit 1
fi

DEF_DIR="$(dirname "$DEF_FILE")"
CONTEXT_FILE="$DEF_DIR/.def_context"

CURRENT_DEF=$(cat "$DEF_FILE")
LOG_TAIL=$(cat "$LOG_TAIL_FILE")
SANDBOX_DIAG=""
[[ -n "$SANDBOX_DIAG_FILE" && -f "$SANDBOX_DIAG_FILE" ]] && SANDBOX_DIAG=$(cat "$SANDBOX_DIAG_FILE")
ORIGINAL_CONTEXT=""
[[ -f "$CONTEXT_FILE" ]] && ORIGINAL_CONTEXT=$(cat "$CONTEXT_FILE")

echo "Asking Claude to fix $DEF_FILE based on the failed build..."

FIX_TMP=$(mktemp)
trap 'rm -f "$FIX_TMP"' EXIT

"$CLAUDE" --model "$CLAUDE_MODEL" --allowedTools "WebFetch WebSearch" --disallowedTools "Write Edit Bash NotebookEdit" -p "This Apptainer .def file failed a real 'apptainer build'. Fix the root
cause of the failure and output a complete, corrected .def file.

Do NOT satisfy this by weakening or removing any hard requirement below —
in particular, do not drop 'set -e' from %post, do not hollow out %test
into a trivial always-passing check, and do not silently drop an install
step that was actually needed. If the real fix requires more than editing
one line (e.g. switching install patterns entirely), do that instead of
papering over the symptom.

## Why the build failed — tail of the real apptainer build log:
$LOG_TAIL

$(if [[ -n "$SANDBOX_DIAG" ]]; then echo "## Additional diagnostic — a --sandbox build of this same .def was probed directly (checked whether the intended command actually resolves and runs inside the container, independent of what %post claimed):
$SANDBOX_DIAG
"; fi)
$(if [[ -n "$ORIGINAL_CONTEXT" ]]; then echo "## Original verified evidence this .def was generated from (AUTHORITATIVE — do not contradict without a concrete reason visible in the log above):
$ORIGINAL_CONTEXT
"; fi)
$(render_hard_requirements)

## Current .def file content to fix:
$CURRENT_DEF" > "$FIX_TMP"

if ! finalize_generated_def "$FIX_TMP"; then
    echo "ERROR: Claude did not produce a valid fixed .def — leaving $DEF_FILE unchanged" >&2
    exit 1
fi

mv "$FIX_TMP" "$DEF_FILE"
trap - EXIT
echo "Rewrote $DEF_FILE"
