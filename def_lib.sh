# Shared helpers for generating and repairing .def files. Sourced by
# create_def_file.sh, fix_def_file.sh, and apptainer_build.sh so the
# "what makes a .def valid" logic lives in exactly one place instead of
# drifting apart between initial generation and retry-fixing.

# Extracts the body of a %<section> block (exclusive of the header line),
# stopping at the next line that starts with '%' or at EOF.
_def_extract_section() {
    local file="$1" section="$2"
    awk -v sec="%${section}" '
        $0 ~ "^"sec"([[:space:]]|$)" { infound=1; next }
        infound && /^%/ { exit }
        infound { print }
    ' "$file"
}

# Echoes the "Hard requirements (always apply)" block used in both the
# initial-generation prompt and the retry-fix prompt. Verbatim text
# originally inline in create_def_file.sh's Claude prompt.
render_hard_requirements() {
    cat <<'EOF'
Hard requirements (always apply):
- Bootstrap: docker
- Maintainer: sdweave2@ncsu.edu
- Version label in %labels must equal the installed version exactly
- The %post section header must be exactly '%post -c /bin/bash' (with that
  exact -c argument) and its first body line must be 'set -e' (add
  'set -o pipefail' too if any install line pipes through another command).
  Apptainer's %post does NOT honor a '#!/bin/bash' shebang line inside the
  body — that is not a supported mechanism for this section, and the line
  is silently inert; %post always runs under /bin/sh (dash) unless the
  interpreter is set via '-c <shell>' on the header line itself. Without
  that, dash's 'set' does not support the '-o pipefail' option — attempting
  it there fails immediately with "Illegal option -o pipefail", aborting
  %post before any real install work runs. '%post -c /bin/bash' makes both
  'set -e' and 'set -o pipefail' behave correctly regardless of whether this
  particular .def happens to pipe anything. Apptainer does NOT fail the
  build when a %post command fails on its own — without set -e, a broken
  install step (dead URL, SSL failure, missing package) silently continues,
  and the build reports success with a .sif that's missing whatever failed
  to install. This exact failure mode is why VirSorter's original def
  "built" while never actually installing its bioconda toolchain — see
  CLAUDE.md lesson 6.
- %post must include: mkdir -p /rs1 /share /home /usr/local/usrapps
- Pin the version explicitly in the install command for reproducibility —
  use only a version number given to you above or found verbatim in the
  README/repo tree; never invent or guess one
- %runscript must be: exec <command> "$@" — <command> MUST be a single
  bare executable name with no spaces, no paths, and no interpreter
  prefix (e.g. 'viralm', NOT 'python3 /opt/ViraLM/viralm.py'). It must be
  resolvable via 'command -v <command>' inside the built container.
  container-mod's Programs field and its generated exec wrappers both
  require exactly this — a multi-word runscript silently breaks the
  deployed module even though the container itself still runs fine.
  If the tool has no console-script entry point (Pattern 3, a flat
  script with no packaging), do NOT fall back to a raw interpreter
  invocation or a PYTHONPATH-only export — create a wrapper in %post:
    cat > /usr/local/bin/<command> << 'INNEREOF'
    #!/bin/bash
    exec python3 /opt/<Tool>/<script>.py "$@"
    INNEREOF
    chmod +x /usr/local/bin/<command>
  then point %runscript/%test at that bare <command> name.
- %test must be a real invocation that exits 0 (prefer '<command> --help';
  if the tool has no top-level --help flag, use a bare invocation that
  prints usage and exits cleanly instead of guessing a flag that doesn't exist).
  Verify --help/-h actually exits 0 for this tool's CLI framework before
  relying on it — some frameworks treat help text as a usage error and
  exit nonzero by design (e.g. Perl Getopt::Long + Pod::Usage's pod2usage()
  exits 2). If you can't confirm it exits 0, test on output content
  instead: '<command> --help 2>&1 | grep -q "<distinctive string>"'
- Output ONLY the .def file content — no explanation, no markdown fences, no commentary
EOF
}

# Strips markdown fences / preamble from a Claude-generated .def and
# sanity-checks that real output was produced (vs. a clarifying question).
# Does not exit or delete anything itself — callers decide cleanup.
finalize_generated_def() {
    local def_file="$1"

    python3 - "$def_file" <<'PYEOF'
import sys, re
path = sys.argv[1]
content = open(path).read()
m = re.search(r'```[^\n]*\n(.*?)```', content, re.DOTALL)
if m:
    content = m.group(1)
else:
    idx = content.find('Bootstrap:')
    if idx != -1:
        content = content[idx:]
with open(path, 'w') as f:
    f.write(content.rstrip() + '\n')
PYEOF

    if [[ ! -s "$def_file" ]]; then
        echo "ERROR: Claude produced no output" >&2
        return 1
    fi
    if [[ "$(head -1 "$def_file")" != Bootstrap:* ]]; then
        echo "ERROR: Claude did not produce a valid .def file — it responded instead of generating one:" >&2
        echo "---" >&2
        cat "$def_file" >&2
        echo "---" >&2
        return 1
    fi
    return 0
}

# Fails closed if a .def violates any hard safety invariant. Meant to run
# on every Claude-regenerated .def (retries especially) before it's
# trusted enough to attempt a build — guards against "fixing" a build by
# weakening set -e / %test / %runscript instead of the real bug.
check_def_invariants() {
    local file="$1"
    local reasons=()

    local post_header
    post_header=$(grep -m1 -E '^%post([[:space:]]|$)' "$file")
    if [[ "$post_header" != "%post -c /bin/bash" ]]; then
        reasons+=("%post header is not exactly '%post -c /bin/bash' (found: '${post_header:-<empty>}') — required because Apptainer's %post does not honor shebang lines; the interpreter can only be set via -c on the header line, and without it %post runs under /bin/sh (dash), which doesn't support 'set -o pipefail'")
    fi

    local post_first
    post_first=$(_def_extract_section "$file" post | grep -vE '^[[:space:]]*(#.*)?$' | head -1 | sed -E 's/^[[:space:]]+//')
    if [[ "$post_first" != "set -e"* ]]; then
        reasons+=("%post does not have 'set -e' as its first non-comment line (found: '${post_first:-<empty>}')")
    fi

    local version
    version=$(grep -m1 -iE '^[[:space:]]+Version[[:space:]]+' "$file" | awk '{print $NF}')
    if [[ -z "$version" || "$version" == *"<"* ]]; then
        reasons+=("Version label is empty or still a placeholder (found: '${version:-<empty>}')")
    fi

    local test_body test_trimmed
    test_body=$(_def_extract_section "$file" test | grep -vE '^[[:space:]]*(#.*)?$')
    test_trimmed=$(echo "$test_body" | tr -d '[:space:]')
    if [[ -z "$test_body" || "$test_trimmed" == "exit0" || "$test_trimmed" == "true" ]]; then
        reasons+=("%test is empty or trivially always-passing (found: '${test_body:-<empty>}')")
    fi

    local runscript_line
    runscript_line=$(_def_extract_section "$file" runscript | grep -E '^[[:space:]]*exec[[:space:]]' | head -1)
    if ! echo "$runscript_line" | grep -qE '^[[:space:]]*exec[[:space:]]+[^[:space:]/]+[[:space:]]+"\$@"[[:space:]]*$'; then
        reasons+=("%runscript's exec line is not 'exec <bareword> \"\$@\"' (found: '${runscript_line:-<empty>}')")
    fi

    if (( ${#reasons[@]} > 0 )); then
        printf 'Invariant check failed for %s:\n' "$file" >&2
        printf '  - %s\n' "${reasons[@]}" >&2
        return 1
    fi
    return 0
}

# Classifies a build-log tail as an infra/environment failure (network,
# disk, rate limits) that no .def edit can fix — a retry loop should hard
# stop on these instead of burning a Claude call against an unfixable
# environment. Deliberately narrow: generic SSL/cert errors are NOT
# included here since those are frequently real, fixable .def bugs
# (CLAUDE.md lessons 6, 9), not environment failures.
is_environment_failure() {
    local log_text="$1"
    local patterns=(
        'No space left on device'
        'Disk quota exceeded'
        'Could not resolve host'
        'Temporary failure in name resolution'
        'Connection timed out'
        'Connection refused'
        '429 Too Many Requests'
        'rate limit'
        'i/o timeout'
    )
    local pat
    for pat in "${patterns[@]}"; do
        if echo "$log_text" | grep -qiE "$pat"; then
            echo "Matched environment-failure pattern: $pat" >&2
            return 0
        fi
    done
    return 1
}
