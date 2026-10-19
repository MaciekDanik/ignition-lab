#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DEVICES="/srv/ignition-lab/runtime/test/config/resources/core/com.inductiveautomation.opcua/device"
GIT_DEVICES="$REPO_ROOT/config/deployable/core/com.inductiveautomation.opcua/device"

log() { printf '[extract-test-devices] %s\n' "$*"; }
fail() { log "ERROR: $*"; exit 1; }

cd "$REPO_ROOT"

for command_name in rsync jq git grep; do
    command -v "$command_name" >/dev/null || fail "Required command is missing: $command_name"
done

[[ -d "$TEST_DEVICES" ]] || fail "TEST device directory does not exist: $TEST_DEVICES"

if [[ -n "$(git status --short -- config/deployable/core/com.inductiveautomation.opcua/device 2>/dev/null)" ]]; then
    fail "Git device resources already contain uncommitted changes. Review or commit them first."
fi

log "Validating TEST device JSON..."
while IFS= read -r -d '' file; do
    sudo jq empty "$file" >/dev/null
 done < <(sudo find "$TEST_DEVICES" -type f -name '*.json' -print0)

log "Checking TEST device resources for obvious plaintext credentials..."
if sudo grep -RInEi \
    --exclude-dir='.resources' \
    '"?(password|secret|token|credential|private.?key|username)"?[[:space:]]*[:=][[:space:]]*"?[^"${<[:space:]]+' \
    "$TEST_DEVICES"
then
    fail "Possible credential material found. Review the matches before exporting."
fi

mkdir -p "$(dirname "$GIT_DEVICES")"

log "Exporting the complete TEST device folder into Git source..."
sudo rsync -a --delete \
    --exclude='.resources/' \
    "$TEST_DEVICES/" \
    "$GIT_DEVICES/"

sudo chown -R "$(id -u):$(id -g)" "$REPO_ROOT/config/deployable"

log "Validating exported JSON..."
while IFS= read -r -d '' file; do
    jq empty "$file" >/dev/null
done < <(find "$GIT_DEVICES" -type f -name '*.json' -print0)

log "Checking extracted device content..."

if sudo rsync -rcni --delete \
    --exclude='.resources/' \
    "$TEST_DEVICES/" \
    "$GIT_DEVICES/" \
    | grep -q .
then
    fail "TEST device content changed during extraction. Run the extraction again after Gateway writes settle."
fi

log "Device extraction completed."
log "Review with:"
log "  git status --short -- config/deployable"
log "  git diff -- config/deployable"
