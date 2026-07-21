#!/bin/bash
# Appends the load-logging TCL hook to a module file — the same hook
# container-mod_nf's PATCH_LOG_HOOK stage stamps onto modules it builds.
# Called by apptainer_build.sh after a successful container-mod deploy,
# since this pipeline registers modules directly rather than going through
# container-mod_nf.
#
# Usage: patch_log_hook.sh <tool_lower> <version>

set -uo pipefail

TOOL_LOWER="${1:?ERROR: patch_log_hook.sh requires <tool_lower> as \$1}"
VERSION="${2:?ERROR: patch_log_hook.sh requires <version> as \$2}"
MOD_DIR="${MOD_DIR:-/usr/local/usrapps/brc/brc_modules/modules}"
MODULE_FILE="$MOD_DIR/$TOOL_LOWER/$VERSION"

if [ ! -f "$MODULE_FILE" ]; then
    echo "[WARN] patch_log_hook: module file not found: $MODULE_FILE" >&2
    exit 0
fi

# Idempotency guard — don't append twice.
if grep -q "Log module load" "$MODULE_FILE"; then
    exit 0
fi

cat >> "$MODULE_FILE" << 'HOOK_EOF'

#-- Log module load
if { [module-info mode load] } {
    catch {
        set _ts    [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%SZ} -gmt 1]
        set _user  $env(USER)
        set _group $env(GROUP)
        set _parts [split [module-info name] /]
        set _tool  [lindex $_parts 0]
        set _ver   [lindex $_parts 1]
        set _fh    [open "/usr/local/usrapps/brc/brc_modules/logs/module_loads.log" a]
        puts $_fh  "${_ts}|${_user}|${_group}|${_tool}|${_ver}"
        close $_fh
    }
}
HOOK_EOF

echo "[OK] patched log hook: $TOOL_LOWER/$VERSION"
