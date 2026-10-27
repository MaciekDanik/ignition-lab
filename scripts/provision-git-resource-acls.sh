#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCE_ROOT="${RESOURCE_ROOT:-$REPO_ROOT/config/gateway/resources/core/ignition/images}"
DEVELOPER_USER="${DEVELOPER_USER:-masiek}"
RUNNER_USER="${RUNNER_USER:-actions}"
IGNITION_UID="${IGNITION_UID:-2003}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v setfacl >/dev/null 2>&1 ||
    fail "setfacl is required. Install the acl package."

id "$DEVELOPER_USER" >/dev/null 2>&1 ||
    fail "Developer user does not exist: $DEVELOPER_USER"

id "$RUNNER_USER" >/dev/null 2>&1 ||
    fail "Runner user does not exist: $RUNNER_USER"

[[ -d "$RESOURCE_ROOT" ]] ||
    fail "Resource root does not exist: $RESOURCE_ROOT"

echo "Provisioning shared ACLs:"
echo "  Resource root: $RESOURCE_ROOT"
echo "  Developer:     $DEVELOPER_USER"
echo "  Runner:        $RUNNER_USER"
echo "  Ignition UID:  $IGNITION_UID"

find "$RESOURCE_ROOT" \
    -type d \
    -exec setfacl -m \
        "u:${DEVELOPER_USER}:rwx,u:${RUNNER_USER}:rwx,u:${IGNITION_UID}:rwx,m::rwx" \
        {} +

find "$RESOURCE_ROOT" \
    -type d \
    -exec setfacl -d -m \
        "u:${DEVELOPER_USER}:rwx,u:${RUNNER_USER}:rwx,u:${IGNITION_UID}:rwx,m::rwx" \
        {} +

find "$RESOURCE_ROOT" \
    -type f \
    -exec setfacl -m \
        "u:${DEVELOPER_USER}:rw-,u:${RUNNER_USER}:rw-,u:${IGNITION_UID}:rw-,m::rw-" \
        {} +

echo "Shared ACL provisioning completed."
