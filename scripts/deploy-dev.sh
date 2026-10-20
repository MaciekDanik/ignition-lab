#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DEPLOY_ROOT="/srv/ignition-lab"
RELEASE_ROOT="$DEPLOY_ROOT/release"
RUNTIME_ROOT="$DEPLOY_ROOT/runtime"
BACKUP_ROOT="$DEPLOY_ROOT/backups/dev"
SECRETS_ROOT="$DEPLOY_ROOT/secrets"

ENV_FILE="$DEPLOY_ROOT/.env"
COMPOSE_FILE="$RELEASE_ROOT/compose/compose.yml"
API_TOKEN_FILE="$SECRETS_ROOT/dev_gateway_api_token.txt"

DEV_RUNTIME="$RUNTIME_ROOT/dev/projects"
SOURCE_PROJECTS="$SOURCE_ROOT/projects"

CONTAINER_NAME="ignition-dev"
HEALTH_URL="http://localhost:9188/StatusPing"
PROJECT_SCAN_URL="http://localhost:9188/data/api/v1/scan/projects"
PROJECT_SMOKE_URL="${PROJECT_SMOKE_URL:-}"

# Supported modes:
#   scan    - update projects in place and ask Ignition to rescan them.
#   restart - stop DEV, update projects, and start DEV again.
DEPLOY_MODE="${DEPLOY_MODE:-scan}"

# A retry of the same GitHub commit needs its own backup directory.
DEPLOYMENT_BASE_ID="${GITHUB_SHA:-manual}"
DEPLOYMENT_SUFFIX="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$(date -u +%Y%m%dT%H%M%SZ)"
DEPLOYMENT_ID="${DEPLOYMENT_BASE_ID}-${DEPLOYMENT_SUFFIX}"
BACKUP_DIR="$BACKUP_ROOT/$DEPLOYMENT_ID"

LOCK_FILE="$DEPLOY_ROOT/deploy-dev.lock"
IGNITION_UID="2003"

RUNTIME_MODIFIED=0
BACKUP_CREATED=0
DEPLOYMENT_SUCCEEDED=0
API_HEADER_FILE=""

CONTAINER_ID_BEFORE=""
CONTAINER_STARTED_BEFORE=""

log() {
    printf '[deploy-dev] %s\n' "$*"
}

fail() {
    log "ERROR: $*"
    exit 1
}

compose() {
    docker compose \
        --env-file "$ENV_FILE" \
        -f "$COMPOSE_FILE" \
        "$@"
}

cleanup_temp_files() {
    if [[ -n "$API_HEADER_FILE" && -f "$API_HEADER_FILE" ]]; then
        rm -f "$API_HEADER_FILE"
    fi
}

prepare_api_header() {
    [[ -s "$API_TOKEN_FILE" ]] \
        || fail "DEV Gateway API token file is missing or empty: $API_TOKEN_FILE"

    API_HEADER_FILE="$(mktemp "$DEPLOY_ROOT/api-header.XXXXXX")"
    chmod 600 "$API_HEADER_FILE"

    printf 'X-Ignition-API-Token: %s\n' "$(<"$API_TOKEN_FILE")" \
        > "$API_HEADER_FILE"
}

scan_projects() {
    local http_code
    local response_file
    local curl_exit=0

    [[ -n "$API_HEADER_FILE" && -f "$API_HEADER_FILE" ]] \
        || return 1

    response_file="$(mktemp "$DEPLOY_ROOT/scan-response.XXXXXX")"

    http_code="$(
        curl -sS \
            -o "$response_file" \
            -w '%{http_code}' \
            -X POST \
            -H "@$API_HEADER_FILE" \
            "$PROJECT_SCAN_URL"
    )" || curl_exit=$?

    if [[ "$curl_exit" -ne 0 ]]; then
        log "Project scan request failed at the HTTP transport layer (curl exit $curl_exit)."
        rm -f "$response_file"
        return 1
    fi

    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log "Project scan returned HTTP status $http_code."

        if [[ -s "$response_file" ]]; then
            log "Project scan response follows:"
            cat "$response_file"
            echo
        fi

        rm -f "$response_file"
        return 1
    fi

    rm -f "$response_file"
    log "Ignition project scan accepted with HTTP status $http_code."
}

wait_for_health() {
    local attempt
    local max_attempts="${1:-30}"
    local delay_seconds="${2:-10}"

    for attempt in $(seq 1 "$max_attempts"); do
        if curl -fsS --max-time 10 "$HEALTH_URL" >/dev/null 2>&1; then
            log "DEV health check passed on attempt $attempt."
            return 0
        fi

        log "Waiting for DEV health, attempt $attempt of $max_attempts..."
        sleep "$delay_seconds"
    done

    return 1
}

wait_for_scan_reload() {
    # StatusPing proves that the Gateway stayed available. The optional
    # project smoke test below provides project-level verification.
    if ! wait_for_health 12 5; then
        return 1
    fi

    sleep 3
}

run_project_smoke_test() {
    if [[ -z "$PROJECT_SMOKE_URL" ]]; then
        log "No project-specific smoke-test URL is configured."
        return 0
    fi

    log "Running project smoke test: $PROJECT_SMOKE_URL"

    curl -fsSL \
        --max-time 30 \
        -o /dev/null \
        "$PROJECT_SMOKE_URL"
}

verify_container_state() {
    local state
    local health
    local oom

    state="$(docker inspect "$CONTAINER_NAME" --format '{{.State.Status}}')"
    health="$(docker inspect "$CONTAINER_NAME" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
    oom="$(docker inspect "$CONTAINER_NAME" --format '{{.State.OOMKilled}}')"

    log "DEV state: $state"
    log "DEV health: $health"
    log "DEV OOM-killed: $oom"

    [[ "$state" == "running" ]] \
        && [[ "$health" == "healthy" ]] \
        && [[ "$oom" == "false" ]]
}

apply_project_permissions() {
    # Deployment owns the synchronized project files. Ignition UID 2003 needs
    # read/write/traverse access and matching defaults for files it creates.
    setfacl -R -m "u:${IGNITION_UID}:rwX" "$DEV_RUNTIME"
    setfacl -R -d -m "u:${IGNITION_UID}:rwX" "$DEV_RUNTIME"
}

restore_backup_files() {
    log "Restoring DEV projects from backup..."

    mkdir -p "$DEV_RUNTIME"

    rsync -a --delete \
        --exclude='.resources/' \
        "$BACKUP_DIR/projects/" \
        "$DEV_RUNTIME/"

    apply_project_permissions
}

restart_dev() {
    log "Restarting DEV..."

    compose restart ignition-dev

    wait_for_health 30 10 \
        && verify_container_state \
        && run_project_smoke_test
}

rollback_scan_mode() {
    log "Requesting project scan after restoring the backup..."

    if scan_projects \
        && wait_for_scan_reload \
        && verify_container_state \
        && run_project_smoke_test
    then
        log "Scan-based rollback completed successfully."
        return 0
    fi

    log "Scan-based rollback verification failed."
    log "Falling back to a full DEV restart."

    restart_dev
}

rollback_restart_mode() {
    log "Starting DEV after restoring the backup..."

    compose up -d ignition-dev

    wait_for_health 30 10 \
        && verify_container_state \
        && run_project_smoke_test
}

rollback() {
    local exit_code=$?
    local rollback_ok=0

    # Prevent another EXIT trap while rollback itself is running.
    trap - EXIT

    if [[ "$DEPLOYMENT_SUCCEEDED" -eq 1 ]]; then
        cleanup_temp_files
        exit 0
    fi

    log "Deployment failed with exit code $exit_code."

    if [[ "$RUNTIME_MODIFIED" -eq 0 ]]; then
        log "Runtime was not modified. Rollback is not required."
        cleanup_temp_files
        exit "$exit_code"
    fi

    if [[ "$BACKUP_CREATED" -ne 1 ]]; then
        log "No backup is available. Automatic rollback is impossible."
        cleanup_temp_files
        exit "$exit_code"
    fi

    log "Starting rollback..."
    restore_backup_files

    if [[ "$DEPLOY_MODE" == "scan" ]]; then
        rollback_scan_mode && rollback_ok=1
    else
        rollback_restart_mode && rollback_ok=1
    fi

    if [[ "$rollback_ok" -eq 1 ]]; then
        log "Rollback completed successfully."
    else
        log "CRITICAL: automatic rollback failed. DEV requires manual recovery."
    fi

    cleanup_temp_files
    exit "$exit_code"
}

trap rollback EXIT

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    fail "Another DEV deployment is already running."
fi

case "$DEPLOY_MODE" in
    scan|restart)
        ;;
    *)
        fail "Unsupported DEPLOY_MODE: $DEPLOY_MODE. Use scan or restart."
        ;;
esac

log "Deployment ID: $DEPLOYMENT_ID"
log "Deployment mode: $DEPLOY_MODE"
log "Source root: $SOURCE_ROOT"
log "Release root: $RELEASE_ROOT"

[[ -d "$SOURCE_PROJECTS" ]] \
    || fail "Source projects directory does not exist: $SOURCE_PROJECTS"

[[ -f "$SOURCE_PROJECTS/CICD_Test/project.json" ]] \
    || fail "CICD_Test project.json is missing from deployment source."

[[ -d "$DEV_RUNTIME" ]] \
    || fail "DEV runtime projects directory does not exist: $DEV_RUNTIME"

[[ -f "$ENV_FILE" ]] \
    || fail "Deployment environment file is missing: $ENV_FILE"

[[ -f "$COMPOSE_FILE" ]] \
    || fail "Compose file is missing: $COMPOSE_FILE"

for required_command in docker rsync curl flock jq setfacl; do
    command -v "$required_command" >/dev/null \
        || fail "Required command is not installed: $required_command"
done

log "Validating Compose configuration..."
compose config >/dev/null

log "Validating source JSON..."
while IFS= read -r file; do
    jq empty "$file" >/dev/null
done < <(find "$SOURCE_PROJECTS" -type f -name '*.json' | sort)

if [[ "$DEPLOY_MODE" == "scan" ]]; then
    prepare_api_header

    log "Verifying DEV before scan deployment..."
    wait_for_health 12 5 \
        || fail "DEV is not reachable before deployment."

    verify_container_state \
        || fail "DEV is not healthy before deployment."

    CONTAINER_ID_BEFORE="$(docker inspect "$CONTAINER_NAME" --format '{{.Id}}')"
    CONTAINER_STARTED_BEFORE="$(docker inspect "$CONTAINER_NAME" --format '{{.State.StartedAt}}')"

    log "Container ID before deployment: $CONTAINER_ID_BEFORE"
    log "Container start time before deployment: $CONTAINER_STARTED_BEFORE"
fi

log "Creating backup: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR/projects"

rsync -a \
    --exclude='.resources/' \
    "$DEV_RUNTIME/" \
    "$BACKUP_DIR/projects/"

BACKUP_CREATED=1

printf '%s\n' "$DEPLOYMENT_ID" > "$BACKUP_DIR/deployment-id.txt"
printf '%s\n' "${GITHUB_SHA:-manual}" > "$BACKUP_DIR/commit.txt"
printf '%s\n' "$DEPLOY_MODE" > "$BACKUP_DIR/deployment-mode.txt"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$BACKUP_DIR/created-at.txt"

if [[ "$DEPLOY_MODE" == "restart" ]]; then
    log "Stopping DEV..."
    compose stop ignition-dev
fi

log "Synchronizing validated project source into DEV runtime..."

# Set this before rsync so a partial synchronization also triggers rollback.
RUNTIME_MODIFIED=1

mkdir -p "$DEV_RUNTIME"

rsync -a --delete \
    --exclude='.resources/' \
    "$SOURCE_PROJECTS/" \
    "$DEV_RUNTIME/"

apply_project_permissions

if [[ "${DEPLOY_TEST_FORCE_FAILURE:-false}" == "true" ]]; then
    fail "Deliberate rollback test failure after project synchronization."
fi

if [[ "$DEPLOY_MODE" == "scan" ]]; then
    log "Requesting Ignition project filesystem scan..."

    scan_projects \
        || fail "Ignition project scan request failed."

    wait_for_scan_reload \
        || fail "DEV did not remain available after project scan."

    verify_container_state \
        || fail "DEV failed container verification after project scan."

    CONTAINER_ID_AFTER="$(docker inspect "$CONTAINER_NAME" --format '{{.Id}}')"
    CONTAINER_STARTED_AFTER="$(docker inspect "$CONTAINER_NAME" --format '{{.State.StartedAt}}')"

    [[ "$CONTAINER_ID_BEFORE" == "$CONTAINER_ID_AFTER" ]] \
        || fail "DEV container was unexpectedly replaced during scan deployment."

    [[ "$CONTAINER_STARTED_BEFORE" == "$CONTAINER_STARTED_AFTER" ]] \
        || fail "DEV container was unexpectedly restarted during scan deployment."

    log "Container ID and start time remained unchanged."

    run_project_smoke_test \
        || fail "Project smoke test failed after scan deployment."
else
    log "Starting DEV..."
    compose up -d ignition-dev

    log "Waiting for DEV health..."
    wait_for_health 30 10 \
        || fail "DEV did not become healthy within five minutes."

    verify_container_state \
        || fail "DEV failed container verification after restart deployment."

    run_project_smoke_test \
        || fail "Project smoke test failed after restart deployment."
fi

printf '%s\n' "$DEPLOYMENT_ID" \
    > "$DEPLOY_ROOT/last-successful-dev-deployment.txt"

cat > "$DEPLOY_ROOT/last-successful-dev-deployment.json" <<METADATA
{
  "deploymentId": "$DEPLOYMENT_ID",
  "commit": "${GITHUB_SHA:-manual}",
  "mode": "$DEPLOY_MODE",
  "completedAt": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
METADATA

# Keep the ten newest deployment backups.
log "Pruning old DEV project backups..."

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
    log "WARNING: some old DEV project backups could not be removed."
fi

DEPLOYMENT_SUCCEEDED=1

if [[ "$DEPLOY_MODE" == "scan" ]]; then
    log "DEV deployment completed successfully without a Gateway restart."
else
    log "DEV deployment completed successfully using restart mode."
fi

cleanup_temp_files
trap - EXIT
exit 0
