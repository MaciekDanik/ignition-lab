#!/usr/bin/env bash
set -Eeuo pipefail

SOURCE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEPLOY_ROOT="/srv/ignition-lab"
GIT_DEVICES="$SOURCE_ROOT/config/deployable/core/com.inductiveautomation.opcua/device"
DEV_DEVICES="$DEPLOY_ROOT/runtime/dev/config/resources/core/com.inductiveautomation.opcua/device"
BACKUP_ROOT="$DEPLOY_ROOT/backups/dev-config"
API_TOKEN_FILE="$DEPLOY_ROOT/secrets/dev_gateway_api_token.txt"
CONFIG_SCAN_URL="http://localhost:9188/data/api/v1/scan/config"
HEALTH_URL="http://localhost:9188/StatusPing"
CONTAINER_NAME="ignition-dev"
IGNITION_UID="2003"
LOCK_FILE="$DEPLOY_ROOT/deploy-dev-config.lock"

DEPLOYMENT_ID="${GITHUB_SHA:-manual}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$DEPLOYMENT_ID"
ORIGINAL_STATE="absent"
RUNTIME_MODIFIED=0
DEPLOYMENT_SUCCEEDED=0
API_HEADER_FILE=""

log() { printf '[deploy-dev-devices] %s\n' "$*"; }
fail() { log "ERROR: $*"; exit 1; }

cleanup() {
    [[ -z "$API_HEADER_FILE" || ! -f "$API_HEADER_FILE" ]] || rm -f "$API_HEADER_FILE"
}

prepare_api_header() {
    [[ -s "$API_TOKEN_FILE" ]] || fail "DEV Gateway API token is missing or empty."
    API_HEADER_FILE="$(mktemp "$DEPLOY_ROOT/config-api-header.XXXXXX")"
    chmod 600 "$API_HEADER_FILE"
    printf 'X-Ignition-API-Token: %s\n' "$(<"$API_TOKEN_FILE")" > "$API_HEADER_FILE"
}

scan_config() {
    local response_file http_code curl_exit=0
    response_file="$(mktemp "$DEPLOY_ROOT/config-scan-response.XXXXXX")"

    http_code="$(curl -sS --max-time 30 \
        -o "$response_file" \
        -w '%{http_code}' \
        -X POST \
        -H "@$API_HEADER_FILE" \
        "$CONFIG_SCAN_URL")" || curl_exit=$?

    if [[ "$curl_exit" -ne 0 ]]; then
        log "Configuration scan transport failed (curl exit $curl_exit)."
        rm -f "$response_file"
        return 1
    fi

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log "Configuration scan returned HTTP $http_code."
        [[ ! -s "$response_file" ]] || cat "$response_file"
        rm -f "$response_file"
        return 1
    fi

    rm -f "$response_file"
    log "Configuration scan accepted with HTTP $http_code."
}

verify_gateway() {
    local state health oom
    curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null
    state="$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}')"
    health="$(docker inspect "$CONTAINER_NAME" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    oom="$(docker inspect "$CONTAINER_NAME" --format '{{.State.OOMKilled}}')"
    log "DEV state=$state health=$health OOMKilled=$oom"
    [[ "$state" == "running" && "$health" == "healthy" && "$oom" == "false" ]]
}

apply_permissions() {
    chown -R actions:actions "$DEV_DEVICES"
    setfacl -R -m "u:${IGNITION_UID}:rwX" "$DEV_DEVICES"
    setfacl -R -d -m "u:${IGNITION_UID}:rwX" "$DEV_DEVICES"
}

restore_backup() {
    log "Restoring previous DEV device folder..."
    if [[ "$ORIGINAL_STATE" == "present" ]]; then
        mkdir -p "$DEV_DEVICES"
        rsync -a --delete "$BACKUP_DIR/device/" "$DEV_DEVICES/"
        apply_permissions
    else
        rm -rf "$DEV_DEVICES"
    fi
}

rollback() {
    local exit_code=$?
    trap - EXIT

    if [[ "$DEPLOYMENT_SUCCEEDED" -eq 1 ]]; then
        cleanup
        exit 0
    fi

    log "Deployment failed with exit code $exit_code."
    if [[ "$RUNTIME_MODIFIED" -eq 1 ]]; then
        restore_backup
        if scan_config && sleep 5 && verify_gateway; then
            log "Rollback completed successfully."
        else
            log "CRITICAL: rollback verification failed. Manual recovery is required."
        fi
    fi

    cleanup
    exit "$exit_code"
}

trap rollback EXIT
exec 9>"$LOCK_FILE"
flock -n 9 || fail "Another DEV configuration deployment is running."

for command_name in docker rsync curl flock jq setfacl; do
    command -v "$command_name" >/dev/null || fail "Required command is missing: $command_name"
done

[[ -d "$GIT_DEVICES" ]] || fail "Git-managed device directory does not exist: $GIT_DEVICES"

log "Validating Git-managed device JSON..."
while IFS= read -r -d '' file; do
    jq empty "$file" >/dev/null
done < <(find "$GIT_DEVICES" -type f -name '*.json' -print0)

prepare_api_header
verify_gateway || fail "DEV is not healthy before configuration deployment."

mkdir -p "$BACKUP_DIR"
printf '%s\n' "$DEPLOYMENT_ID" > "$BACKUP_DIR/deployment-id.txt"
printf '%s\n' "${GITHUB_SHA:-manual}" > "$BACKUP_DIR/commit.txt"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$BACKUP_DIR/created-at.txt"

if [[ -d "$DEV_DEVICES" ]]; then
    ORIGINAL_STATE="present"
    mkdir -p "$BACKUP_DIR/device"
    rsync -a "$DEV_DEVICES/" "$BACKUP_DIR/device/"
fi
printf '%s\n' "$ORIGINAL_STATE" > "$BACKUP_DIR/original-state.txt"

log "Synchronizing the complete Git-managed device folder to DEV..."
RUNTIME_MODIFIED=1
mkdir -p "$DEV_DEVICES"
rsync -a --delete \
    --exclude='.resources/' \
    "$GIT_DEVICES/" \
    "$DEV_DEVICES/"
apply_permissions

scan_config || fail "DEV configuration scan failed."
sleep 5
verify_gateway || fail "DEV failed health verification after configuration scan."

if rsync -ain --delete \
    --exclude='.resources/' \
    "$GIT_DEVICES/" \
    "$DEV_DEVICES/" \
    | grep -q .
then
    fail "DEV device filesystem differs from the Git-managed source after deployment."
fi

cat > "$DEPLOY_ROOT/last-successful-dev-config-deployment.json" <<METADATA
{
  "deploymentId": "$DEPLOYMENT_ID",
  "commit": "${GITHUB_SHA:-manual}",
  "scope": "core/com.inductiveautomation.opcua/device",
  "completedAt": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
METADATA

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
    | sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -rf

DEPLOYMENT_SUCCEEDED=1
log "DEV device configuration deployment completed successfully."
cleanup
trap - EXIT
