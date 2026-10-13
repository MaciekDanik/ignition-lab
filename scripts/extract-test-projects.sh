#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTAINER_NAME="ignition-test"

echo "Extracting TEST project resources into Git source..."
echo

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "ERROR: $CONTAINER_NAME is currently running."
    echo
    echo "Stop TEST before extracting project resources:"
    echo "  docker compose --env-file .env -f compose/compose.yml stop ignition-test"
    exit 1
fi

if [[ ! -d runtime/test/projects ]]; then
    echo "ERROR: TEST runtime projects directory does not exist:"
    echo "  runtime/test/projects"
    exit 1
fi

if [[ ! -d projects ]]; then
    echo "ERROR: Git project source directory does not exist:"
    echo "  projects"
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

rsync -a --delete \
    --exclude='.resources/' \
    runtime/test/projects/ \
    projects/

echo
echo "Project extraction complete."
echo
echo "Review the result with:"
echo "  git status --short"
echo "  git diff --stat"
echo "  git diff"
