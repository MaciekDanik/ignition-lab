#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DEPLOY_ROOT="/srv/ignition-lab"
GIT_CONFIG_ROOT="$SOURCE_ROOT/config/deployable"
DEV_CONFIG_ROOT="$DEPLOY_ROOT/runtime/dev/config/resources"
BACKUP_ROOT="$DEPLOY_ROOT/backups/dev-config"

API_TOKEN_FILE="$DEPLOY_ROOT/secrets/dev_gateway_api_token.txt"
CONFIG_SCAN_URL="http://localhost:9188/data/api/v1/scan/config"
HEALTH_URL="http://localhost:9188/StatusPing"

CONTAINER_NAME="ignition-dev"
IGNITION_UID="2003"
LOCK_FILE="$DEPLOY_ROOT/deploy-dev-config.lock"

MANAGED_PATHS=(
    "core/com.inductiveautomation.opcua/device"
    "core/ignition/tag-provider"
    "core/ignition/tag-group"
    "core/ignition/tag-definition"
    "core/ignition/tag-type-definition"
    "core/ignition/database-connection"
    "core/ignition/images"
)

DEPLOYMENT_ID="${GITHUB_SHA:-manual}-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP_DIR="$BACKUP_ROOT/$DEPLOYMENT_ID"
MANIFEST_FILE="$BACKUP_DIR/manifest.tsv"

RUNTIME_MODIFIED=0
DEPLOYMENT_SUCCEEDED=0
API_HEADER_FILE=""

log() {
    printf '[deploy-dev-config] %s\n' "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    if [[ -n "$API_HEADER_FILE" && -f "$API_HEADER_FILE" ]]; then
        rm -f "$API_HEADER_FILE"
    fi
}

validate_json_tree() {
    local root="$1"
    local file

    [[ -d "$root" ]] || return 0

    while IFS= read -r -d '' file; do
        jq empty "$file" >/dev/null
    done < <(find "$root" -type f -name '*.json' -print0)
}

prepare_api_header() {
    [[ -s "$API_TOKEN_FILE" ]] \
        || fail "DEV Gateway API token is missing or empty: $API_TOKEN_FILE"

    API_HEADER_FILE="$(mktemp "$DEPLOY_ROOT/config-api-header.XXXXXX")"
    chmod 600 "$API_HEADER_FILE"

    printf 'X-Ignition-API-Token: %s\n' "$(<"$API_TOKEN_FILE")" \
        > "$API_HEADER_FILE"
}

scan_config() {
    local response_file
    local http_code
    local curl_exit=0

    response_file="$(mktemp "$DEPLOY_ROOT/config-scan-response.XXXXXX")"

    http_code="$(
        curl -sS \
            --max-time 30 \
            -o "$response_file" \
            -w '%{http_code}' \
            -X POST \
            -H "@$API_HEADER_FILE" \
            "$CONFIG_SCAN_URL"
    )" || curl_exit=$?

    if [[ "$curl_exit" -ne 0 ]]; then
        log "Configuration scan transport failed with curl exit $curl_exit."
        rm -f "$response_file"
        return 1
    fi

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log "Configuration scan returned HTTP $http_code."

        if [[ -s "$response_file" ]]; then
            cat "$response_file"
            echo
        fi

        rm -f "$response_file"
        return 1
    fi

    rm -f "$response_file"
    log "Configuration scan accepted with HTTP $http_code."
}

verify_gateway() {
    local state
    local health
    local oom

    curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null

    state="$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}')"
    health="$(docker inspect "$CONTAINER_NAME" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    oom="$(docker inspect "$CONTAINER_NAME" --format '{{.State.OOMKilled}}')"

    log "DEV state=$state health=$health OOMKilled=$oom"

    [[ "$state" == "running" ]] \
        && [[ "$health" == "healthy" ]] \
        && [[ "$oom" == "false" ]]
}

apply_permissions() {
    local relative_path="$1"
    local target="$DEV_CONFIG_ROOT/$relative_path"
    local child

    [[ -d "$target" ]] || return 0

    setfacl -m "u:${IGNITION_UID}:rwX" "$target"
    setfacl -d -m "u:${IGNITION_UID}:rwX" "$target"

    case "$relative_path" in
        "core/ignition/tag-provider"|\
        "core/ignition/tag-group"|\
        "core/ignition/tag-definition"|\
        "core/ignition/tag-type-definition")
            while IFS= read -r -d '' child; do
                if [[ "$(basename "$child")" == "System" ]]; then
                    continue
                fi

                setfacl -R -m "u:${IGNITION_UID}:rwX" "$child"
                setfacl -R -d -m "u:${IGNITION_UID}:rwX" "$child"
            done < <(
                find "$target" \
                    -mindepth 1 \
                    -maxdepth 1 \
                    -type d \
                    -print0
            )
            ;;
        *)
            setfacl -R -m "u:${IGNITION_UID}:rwX" "$target"
            setfacl -R -d -m "u:${IGNITION_UID}:rwX" "$target"
            ;;
    esac
}

backup_managed_paths() {
    local relative_path
    local source_path
    local backup_path

    mkdir -p "$BACKUP_DIR/resources"
    : > "$MANIFEST_FILE"

    for relative_path in "${MANAGED_PATHS[@]}"; do
        source_path="$DEV_CONFIG_ROOT/$relative_path"
        backup_path="$BACKUP_DIR/resources/$relative_path"

        if [[ -d "$source_path" ]]; then
            printf 'present\t%s\n' "$relative_path" >> "$MANIFEST_FILE"
            mkdir -p "$backup_path"
            rsync -a \
                --no-owner \
                --no-group \
                --no-perms \
                --no-times \
                --exclude='.resources/' \
                --exclude='System/' \
                "$source_path/" \
                "$backup_path/"
        else
            printf 'absent\t%s\n' "$relative_path" >> "$MANIFEST_FILE"
        fi
    done
}

deploy_managed_paths() {
    local relative_path
    local source_path
    local destination_path

    for relative_path in "${MANAGED_PATHS[@]}"; do
        source_path="$GIT_CONFIG_ROOT/$relative_path"
        destination_path="$DEV_CONFIG_ROOT/$relative_path"

        log "Deploying scope: $relative_path"

        if [[ -d "$source_path" ]]; then
            validate_json_tree "$source_path"
            mkdir -p "$destination_path"

            rsync -a --delete \
                --no-owner \
                --no-group \
                --no-perms \
                --no-times \
                --exclude='.resources/' \
                --exclude='System/' \
                "$source_path/" \
                "$destination_path/"

            apply_permissions "$relative_path"
        else
            log "Git scope is absent; leaving DEV scope unchanged."
        fi
    done
}

restore_managed_paths() {
    local state
    local relative_path
    local destination_path
    local backup_path

    while IFS=$'\t' read -r state relative_path; do
        [[ -n "$relative_path" ]] || continue

        destination_path="$DEV_CONFIG_ROOT/$relative_path"
        backup_path="$BACKUP_DIR/resources/$relative_path"

        if [[ "$state" == "present" ]]; then
            mkdir -p "$destination_path"

            rsync -a --delete \
                --no-owner \
                --no-group \
                --no-perms \
                --no-times \
                --exclude='.resources/' \
                --exclude='System/' \
                "$backup_path/" \
                "$destination_path/"

            apply_permissions "$relative_path"
        else
            rm -rf "$destination_path"
        fi
    done < "$MANIFEST_FILE"
}

verify_managed_paths() {
    local relative_path
    local source_path
    local destination_path
    local differences

    for relative_path in "${MANAGED_PATHS[@]}"; do
        source_path="$GIT_CONFIG_ROOT/$relative_path"
        destination_path="$DEV_CONFIG_ROOT/$relative_path"

        if [[ -d "$source_path" ]]; then
            if [[ ! -d "$destination_path" ]]; then
                log "Missing DEV scope: $relative_path"
                return 1
            fi

            differences="$(
                rsync -rcni --delete \
                    --exclude='.resources/' \
                    --exclude='System/' \
                    "$source_path/" \
                    "$destination_path/"
            )"

            if [[ -n "$differences" ]]; then
                log "Content differs for scope: $relative_path"
                printf '%s\n' "$differences"
                return 1
            fi
        fi
    done
}

rollback() {
    local exit_code=$?

    trap - EXIT

    if [[ "$DEPLOYMENT_SUCCEEDED" -eq 1 ]]; then
        cleanup
        exit 0
    fi

    log "Deployment failed with exit code $exit_code."

    if [[ "$RUNTIME_MODIFIED" -eq 1 && -f "$MANIFEST_FILE" ]]; then
        log "Restoring managed DEV configuration..."
        restore_managed_paths

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

for command_name in docker rsync curl flock jq setfacl find; do
    command -v "$command_name" >/dev/null \
        || fail "Required command is missing: $command_name"
done

prepare_api_header
verify_gateway || fail "DEV is not healthy before configuration deployment."

mkdir -p "$BACKUP_DIR"
printf '%s\n' "$DEPLOYMENT_ID" > "$BACKUP_DIR/deployment-id.txt"
printf '%s\n' "${GITHUB_SHA:-manual}" > "$BACKUP_DIR/commit.txt"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$BACKUP_DIR/created-at.txt"

backup_managed_paths

RUNTIME_MODIFIED=1
deploy_managed_paths

scan_config || fail "DEV configuration scan failed."
sleep 5

verify_gateway || fail "DEV failed health verification after configuration scan."
verify_managed_paths || fail "DEV managed configuration differs from Git."

cat > "$DEPLOY_ROOT/last-successful-dev-config-deployment.json" <<METADATA
{
  "deploymentId": "$DEPLOYMENT_ID",
  "commit": "${GITHUB_SHA:-manual}",
  "scopes": [
    "core/com.inductiveautomation.opcua/device",
    "core/ignition/tag-provider",
    "core/ignition/tag-group",
    "core/ignition/tag-definition",
    "core/ignition/tag-type-definition",
    "core/ignition/database-connection",
    "core/ignition/images"
  ],
  "completedAt": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
METADATA

log "Pruning old DEV configuration backups..."

if ! find "$BACKUP_ROOT" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -printf '%T@ %p\n' \
    | sort -nr \
    | tail -n +11 \
    | cut -d' ' -f2- \
    | xargs -r rm -rf
then
    log "WARNING: some old DEV configuration backups could not be removed."
fi

DEPLOYMENT_SUCCEEDED=1
log "DEV managed configuration deployment completed successfully."

cleanup
trap - EXIT
exit 0
