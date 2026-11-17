#!/bin/bash
#
# Publishes a built .sif to GitHub Container Registry (ghcr.io) as an ORAS
# artifact: oras://ghcr.io/<GHCR_NAMESPACE>/<tool, lowercased>:<version>
#
# Usage:
#   ./push_sif.sh [--force_ghcr_overwrite] <sif> <tool> <version>
#   ./push_sif.sh --check <tool> <version>
#
#   --check                 Only check whether the tag already exists on
#                           ghcr.io (no .sif needed, nothing is pushed).
#                           Exit 0 = tag is free (or overwrite allowed),
#                           1 = tag exists and overwrite not allowed,
#                           2 = could not determine (auth/network error).
#   --force_ghcr_overwrite  Push even if the tag already exists, replacing
#                           what it points to. (Also: GHCR_OVERWRITE=true.)
#
# Called by apptainer_build.sh when PUSH=true; also usable by hand, e.g. to
# backfill images already sitting in the public image dir:
#   ./push_sif.sh /usr/local/usrapps/brc/brc_modules/images/pixy-2.2.4.sif pixy 2.2.4
#
# Auth: relies on an existing `apptainer registry login oras://ghcr.io`,
# which stores credentials in ~/.docker/config.json (auths["ghcr.io"].auth).
# This script never takes a token on the command line; the tag-existence
# check reads that same stored credential and passes it to curl over stdin
# (curl -K -), so it never appears in the process list.
#
# Tags are treated as immutable by default: a rebuild with the same Version
# label but different contents (e.g. after a retry-loop .def fix) must not
# silently change what an already-published <tool>:<version> resolves to.

set -uo pipefail
SCRIPT_DIR="${SLURM_SUBMIT_DIR:-$(dirname "$0")}"
source "$SCRIPT_DIR/config.sh"

GHCR_HOST="ghcr.io"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

usage() {
    echo "Usage: $0 [--force_ghcr_overwrite] <sif> <tool> <version>" >&2
    echo "       $0 --check <tool> <version>" >&2
    exit 1
}

CHECK_ONLY=false
POSITIONAL=()
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=true ;;
        --force_ghcr_overwrite) GHCR_OVERWRITE=true ;;
        -*) usage ;;
        *) POSITIONAL+=("$arg") ;;
    esac
done
GHCR_OVERWRITE="${GHCR_OVERWRITE:-false}"

if [[ "$CHECK_ONLY" == true ]]; then
    [[ ${#POSITIONAL[@]} -eq 2 ]] || usage
    SIF_FILE=""
    TOOL="${POSITIONAL[0]}"
    VERSION="${POSITIONAL[1]}"
else
    [[ ${#POSITIONAL[@]} -eq 3 ]] || usage
    SIF_FILE="${POSITIONAL[0]}"
    TOOL="${POSITIONAL[1]}"
    VERSION="${POSITIONAL[2]}"
    [[ -f "$SIF_FILE" ]] || { echo "ERROR: .sif not found: $SIF_FILE" >&2; exit 1; }
fi

if [[ -z "${GHCR_NAMESPACE:-}" ]]; then
    echo "ERROR: GHCR_NAMESPACE not set — check config.sh" >&2
    exit 1
fi

# OCI repository names must be lowercase; tags have their own charset/length rule.
REPO="${GHCR_NAMESPACE,,}/${TOOL,,}"
if [[ ! "$REPO" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]]; then
    echo "ERROR: '$REPO' is not a valid OCI repository name" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
    echo "ERROR: version '$VERSION' is not a valid OCI tag (allowed: [A-Za-z0-9_][A-Za-z0-9_.-]{0,127})" >&2
    exit 1
fi
REF="oras://${GHCR_HOST}/${REPO}:${VERSION}"

# Returns 0 if REPO:VERSION exists on ghcr.io, 1 if it does not, 2 on any
# error (missing credentials, auth failure, network). Callers treat 2 as
# "unknown" and fail closed — never assume a tag is free when unsure.
tag_exists() {
    local basic bearer code
    basic=$(jq -er --arg h "$GHCR_HOST" '.auths[$h].auth // empty' "$DOCKER_CONFIG_FILE" 2>/dev/null) || {
        echo "ERROR: no stored credentials for $GHCR_HOST in $DOCKER_CONFIG_FILE — run: apptainer registry login --username <user> oras://$GHCR_HOST" >&2
        return 2
    }

    bearer=$(printf 'header = "Authorization: Basic %s"\n' "$basic" \
        | curl -sS -f -K - "https://${GHCR_HOST}/token?service=${GHCR_HOST}&scope=repository:${REPO}:pull" \
        | jq -er '.token // empty') || {
        echo "ERROR: could not obtain a registry token from $GHCR_HOST (bad/expired credentials or network?)" >&2
        return 2
    }

    code=$(printf 'header = "Authorization: Bearer %s"\n' "$bearer" \
        | curl -sS -o /dev/null -w '%{http_code}' -I -K - \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "https://${GHCR_HOST}/v2/${REPO}/manifests/${VERSION}") || code="000"

    case "$code" in
        200) return 0 ;;
        404) return 1 ;;
        *)   echo "ERROR: unexpected HTTP $code checking ${REPO}:${VERSION} on $GHCR_HOST" >&2; return 2 ;;
    esac
}

tag_exists
EXISTS_RC=$?
if [[ $EXISTS_RC -eq 2 ]]; then
    echo "ERROR: could not verify whether ${REF} already exists — refusing to push" >&2
    exit 2
fi
if [[ $EXISTS_RC -eq 0 ]]; then
    if [[ "$GHCR_OVERWRITE" == true ]]; then
        echo "WARNING: ${REF} already exists — overwriting (--force_ghcr_overwrite)" >&2
    else
        echo "ERROR: ${REF} already exists on ${GHCR_HOST}. Published tags are treated as immutable." >&2
        echo "       Bump the .def's Version label, delete the old tag on GitHub, or pass --force_ghcr_overwrite." >&2
        exit 1
    fi
fi

if [[ "$CHECK_ONLY" == true ]]; then
    echo "OK: ${REF} can be pushed$([[ $EXISTS_RC -eq 0 ]] && echo ' (will overwrite existing tag)')"
    exit 0
fi

command -v apptainer >/dev/null 2>&1 || module load apptainer
echo "Pushing $SIF_FILE -> $REF"
if ! apptainer push "$SIF_FILE" "$REF"; then
    echo "ERROR: apptainer push failed for $REF" >&2
    exit 1
fi

# Confirm the registry actually has it, rather than trusting push's exit code alone.
tag_exists
if [[ $? -ne 0 ]]; then
    echo "ERROR: push reported success but ${REPO}:${VERSION} is not visible on ${GHCR_HOST}" >&2
    exit 1
fi
echo "Pushed: $REF"
