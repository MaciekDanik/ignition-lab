#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TEST_CONFIG_ROOT="/srv/ignition-lab/runtime/test/config/resources"
GIT_CONFIG_ROOT="$REPO_ROOT/config/deployable"

MANAGED_PATHS=(
    "core/com.inductiveautomation.opcua/device"
    "core/ignition/tag-definition/default"
    "core/ignition/tag-type-definition/default"
)

log() {
    printf '[extract-test-config] %s\n' "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

validate_json_tree() {
    local root="$1"
    local file

    [[ -d "$root" ]] || return 0

    while IFS= read -r -d '' file; do
        jq empty "$file" >/dev/null
    done < <(find "$root" -type f -name '*.json' -print0)
}

check_credential_tree() {
    local root="$1"

    [[ -d "$root" ]] || return 0

    if grep -RInEi \
        --exclude-dir='.resources' \
        '"?(password|secret|token|credential|private.?key|username)"?[[:space:]]*[:=][[:space:]]*"?[^"${<[:space:]]+' \
        "$root"
    then
        return 1
    fi
}

cd "$REPO_ROOT"

for command_name in rsync jq git grep find; do
    command -v "$command_name" >/dev/null \
        || fail "Required command is missing: $command_name"
done

if [[ -n "$(git status --short -- config/deployable 2>/dev/null)" ]]; then
    fail "config/deployable already contains uncommitted changes. Review or commit them first."
fi

for relative_path in "${MANAGED_PATHS[@]}"; do
    source_path="$TEST_CONFIG_ROOT/$relative_path"
    destination_path="$GIT_CONFIG_ROOT/$relative_path"

    log "Processing: $relative_path"

    if [[ ! -d "$source_path" ]]; then
        log "Source is absent; removing the corresponding Git scope if present."
        rm -rf "$destination_path"
        continue
    fi

    log "Validating TEST JSON..."
    validate_json_tree "$source_path"

    log "Checking for obvious plaintext credentials..."
    if ! check_credential_tree "$source_path"; then
        fail "Possible credential material found in: $relative_path"
    fi

    mkdir -p "$destination_path"

    rsync -a --delete \
        --exclude='.resources/' \
        "$source_path/" \
        "$destination_path/"

    log "Validating exported JSON..."
    validate_json_tree "$destination_path"

    log "Verifying extracted content..."

    if rsync -rcni --delete \
        --exclude='.resources/' \
        "$source_path/" \
        "$destination_path/" \
        | grep -q .
    then
        fail "Source content changed during extraction: $relative_path"
    fi
done

log "Gateway configuration extraction completed."
log "Review with:"
log "  git status --short -- config/deployable"
log "  git diff -- config/deployable"
