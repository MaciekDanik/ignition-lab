#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTAINER_NAME="ignition-test"
TEST_RUNTIME="/srv/ignition-lab/runtime/test/projects"
SOURCE_PROJECTS="$REPO_ROOT/projects"
    
echo "Extracting TEST project resources into Git source..."
echo

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "ERROR: $CONTAINER_NAME is currently running."
    echo
    echo "Stop TEST before extracting project resources:"
    echo "  docker compose --env-file /srv/ignition-lab/.env -f /srv/ignition-lab/release/compose/compose.yml stop ignition-test"
    exit 1
fi

if [[ ! -d "$TEST_RUNTIME" ]]; then
    echo "ERROR: TEST runtime projects directory does not exist:"
    echo "  $TEST_RUNTIME"
    exit 1
fi

if [[ ! -d "$SOURCE_PROJECTS" ]]; then
    echo "ERROR: Git project source directory does not exist:"
    echo "  $SOURCE_PROJECTS"
    exit 1
fi

if [[ -n "$(git status --short -- projects)" ]]; then
    echo "ERROR: Git project source already contains uncommitted changes."
    echo
    echo "Review or commit them before extracting from TEST:"
    git status --short -- projects
    exit 1
fi

echo "Synchronizing TEST project resources..."

rsync -a --delete --exclude='.resources/' "$TEST_RUNTIME/" "$SOURCE_PROJECTS/"

echo
echo "Project extraction complete."
echo
echo "Review the result with:"
echo "  git status --short"
echo "  git diff --stat"
echo "  git diff"
