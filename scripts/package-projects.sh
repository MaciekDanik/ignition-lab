#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUILD_DIR="$REPO_ROOT/build/projects"

echo "Packaging Ignition projects..."

rm -rf "$REPO_ROOT/build"
mkdir -p "$BUILD_DIR"

PROJECT_COUNT=0

while IFS= read -r project_dir; do
    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    project_name="$(basename "$project_dir")"
    output_file="$BUILD_DIR/${project_name}.zip"

    echo "Packaging: $project_name"

    (
        cd "$project_dir"

        zip -qr "$output_file" . \
            -x '.resources/*'
    )

    if [[ ! -s "$output_file" ]]; then
        echo "ERROR: Package was not created: $output_file" >&2
        exit 1
    fi

    echo "Created: $output_file"
done < <(
    find projects \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        ! -name '.resources' \
        | sort
)

if [[ "$PROJECT_COUNT" -eq 0 ]]; then
    echo "ERROR: No projects found under projects/" >&2
    exit 1
fi

echo
echo "Created project packages:"

find "$BUILD_DIR" \
    -maxdepth 1 \
    -type f \
    -name '*.zip' \
    -printf '%f %s bytes\n' \
    | sort
