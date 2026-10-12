#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTAINER_NAME="ignition-dev"
IGNITION_UID="2003"

echo "Preparing DEV runtime from Git source..."
echo

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "ERROR: $CONTAINER_NAME is currently running."
    echo
    echo "Stop it first:"
    echo "  docker compose --env-file .env -f compose/compose.yml stop ignition-dev"
    exit 1
fi

if [[ ! -d projects ]]; then
    echo "ERROR: Source directory does not exist: projects"
    exit 1
fi

if [[ ! -d config/resources ]]; then
    echo "ERROR: Source directory does not exist: config/resources"
    exit 1
fi

echo "1. Synchronizing Ignition projects..."

mkdir -p runtime/dev/projects

rsync -a --delete \
    --exclude='.resources/' \
    projects/ \
    runtime/dev/projects/

echo "   Projects synchronized."

echo
echo "2. Synchronizing selected Gateway configuration..."

mkdir -p runtime/dev/config/resources

rsync -a --delete \
    --exclude='.resources/' \
    --exclude='core/ignition/identity-provider/' \
    --exclude='core/ignition/user-source/' \
    --exclude='core/ignition/security-properties/' \
    --exclude='core/ignition/opc-connection/' \
    --exclude='core/com.inductiveautomation.opcua/' \
    config/resources/ \
    runtime/dev/config/resources/

echo "   Selected Gateway configuration synchronized."

echo
echo "3. Applying container access permissions..."

sudo setfacl -R -m "u:${IGNITION_UID}:rwX" runtime/dev
sudo setfacl -R -d -m "u:${IGNITION_UID}:rwX" runtime/dev

echo "   ACL permissions applied for Ignition UID ${IGNITION_UID}."

echo
echo "DEV runtime synchronization completed."
echo
echo "The following Gateway-local resources were not overwritten:"
echo "  - identity providers"
echo "  - user sources"
echo "  - security properties"
echo "  - OPC connections"
echo "  - OPC UA server configuration"
echo
echo "Start DEV with:"
echo "  docker compose --env-file .env -f compose/compose.yml up -d ignition-dev"
