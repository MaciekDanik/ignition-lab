#!/usr/bin/env bash

set -Eeuo pipefail

SOURCE_ROOT="${GITHUB_WORKSPACE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

DEPLOY_ROOT="/srv/ignition-lab"
RELEASE_ROOT="$DEPLOY_ROOT/release"
RUNTIME_ROOT="$DEPLOY_ROOT/runtime"
BACKUP_ROOT="$DEPLOY_ROOT/backups/dev"

ENV_FILE="$DEPLOY_ROOT/.env"
COMPOSE_FILE="$RELEASE_ROOT/compose/compose.yml"

DEV_RUNTIME="$RUNTIME_ROOT/dev/projects"
SOURCE_PROJECTS="$SOURCE_ROOT/projects"

CONTAINER_NAME="ignition-dev"
HEALTH_URL="http://localhost:9188/StatusPing"

DEPLOYMENT_ID="${GITHUB_SHA:-manual-$(date -u +%Y%m%dT%H%M%SZ)}"
BACKUP_DIR="$BACKUP_ROOT/$DEPLOYMENT_ID"

LOCK_FILE="$DEPLOY_ROOT/deploy-dev.lock"
IGNITION_UID="2003"

DEPLOYMENT_STARTED=0
BACKUP_CREATED=0
DEPLOYMENT_SUCCEEDED=0

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

wait_for_health() {
    local attempt

    for attempt in $(seq 1 30); do
        if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
            log "DEV health check passed on attempt $attempt."
            return 0
        fi

        log "Waiting for DEV health, attempt $attempt of 30..."
        sleep 10
    done

    return 1
}

rollback() {
    local exit_code=$?

    if [[ "$DEPLOYMENT_SUCCEEDED" -eq 1 ]]; then
        return 0
    fi

    log "Deployment failed with exit code $exit_code."

    if [[ "$DEPLOYMENT_STARTED" -eq 0 ]]; then
        log "Runtime was not modified. Rollback is not required."
        return "$exit_code"
    fi

    if [[ "$BACKUP_CREATED" -ne 1 ]]; then
        log "No backup is available. Automatic rollback is impossible."
        return "$exit_code"
    fi

    log "Starting rollback..."

    compose stop ignition-dev || true

    mkdir -p "$DEV_RUNTIME"

    rsync -a --delete \
        "$BACKUP_DIR/projects/" \
        "$DEV_RUNTIME/"

    setfacl -R -m "u:${IGNITION_UID}:rwX" "$DEV_RUNTIME"
    setfacl -R -d -m "u:${IGNITION_UID}:rwX" "$DEV_RUNTIME"

    compose up -d ignition-dev

    if wait_for_health; then
        log "Rollback completed successfully."
    else
        log "CRITICAL: rollback completed, but DEV did not become healthy."
    fi

    return "$exit_code"
}

trap rollback EXIT

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    fail "Another DEV deployment is already running."
fi

log "Deployment ID: $DEPLOYMENT_ID"
log "Source root: $SOURCE_ROOT"
log "Release root: $RELEASE_ROOT"

[[ -d "$SOURCE_PROJECTS" ]] \
    || fail "Source projects directory does not exist: $SOURCE_PROJECTS"

[[ -f "$SOURCE_PROJECTS/CICD_Test/project.json" ]] \
    || fail "CICD_Test project.json is missing from deployment source."

[[ -f "$ENV_FILE" ]] \
    || fail "Deployment environment file is missing: $ENV_FILE"

[[ -f "$COMPOSE_FILE" ]] \
    || fail "Compose file is missing: $COMPOSE_FILE"

command -v docker >/dev/null \
    || fail "Docker is not installed."

command -v rsync >/dev/null \
    || fail "rsync is not installed."

command -v curl >/dev/null \
    || fail "curl is not installed."

command -v flock >/dev/null \
    || fail "flock is not installed."

log "Validating Compose configuration..."

compose config >/dev/null

log "Validating source JSON..."

while IFS= read -r file; do
    jq empty "$file" >/dev/null
done < <(find "$SOURCE_PROJECTS" -type f -name '*.json' | sort)

log "Creating backup: $BACKUP_DIR"

mkdir -p "$BACKUP_DIR/projects"

rsync -a \
    "$DEV_RUNTIME/" \
    "$BACKUP_DIR/projects/"

BACKUP_CREATED=1

printf '%s\n' "$DEPLOYMENT_ID" > "$BACKUP_DIR/deployment-id.txt"
printf '%s\n' "${GITHUB_SHA:-manual}" > "$BACKUP_DIR/commit.txt"
date -u +'%Y-%m-%dT%H:%M:%SZ' > "$BACKUP_DIR/created-at.txt"

log "Stopping DEV..."

compose stop ignition-dev

DEPLOYMENT_STARTED=1

log "Synchronizing validated project source into DEV runtime..."

mkdir -p "$DEV_RUNTIME"

rsync -a --delete \
    --exclude='.resources/' \
    "$SOURCE_PROJECTS/" \
    "$DEV_RUNTIME/"

setfacl -R -m "u:${IGNITION_UID}:rwX" "$DEV_RUNTIME"
setfacl -R -d -m "u:${IGNITION_UID}:rwX" "$DEV_RUNTIME"


log "Starting DEV..."

compose up -d ignition-dev

log "Waiting for DEV health..."

if ! wait_for_health; then
    fail "DEV did not become healthy within five minutes."
fi

state="$(docker inspect ignition-dev --format '{{.State.Status}}')"
health="$(docker inspect ignition-dev \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
oom="$(docker inspect ignition-dev --format '{{.State.OOMKilled}}')"

log "DEV state: $state"
log "DEV health: $health"
log "DEV OOM-killed: $oom"

[[ "$state" == "running" ]] \
    || fail "DEV container state is not running."

[[ "$health" == "healthy" ]] \
    || fail "DEV container is not healthy."

[[ "$oom" == "false" ]] \
    || fail "DEV container was OOM-killed."

printf '%s\n' "$DEPLOYMENT_ID" \
    > "$DEPLOY_ROOT/last-successful-dev-deployment.txt"

DEPLOYMENT_SUCCEEDED=1

log "DEV deployment completed successfully."
