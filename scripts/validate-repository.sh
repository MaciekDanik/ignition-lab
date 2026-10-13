#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAILED=0

error() {
    echo "::error::$1"
    FAILED=1
}

section() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

section "1. Required repository paths"

REQUIRED_PATHS=(
    "projects"
    "config/resources"
    "compose/compose.yml"
    "scripts/sync-test-runtime.sh"
    "scripts/sync-dev-runtime.sh"
    "scripts/extract-test-projects.sh"
    "scripts/deploy-dev.sh"
    ".github/workflows/deploy-dev.yml"
    ".env.example"
)

for path in "${REQUIRED_PATHS[@]}"; do
    if [[ -e "$path" ]]; then
        echo "OK: $path"
    else
        error "Required path is missing: $path"
    fi
done

section "2. Shell script syntax"

while IFS= read -r script; do
    echo "Checking: $script"

    if ! bash -n "$script"; then
        error "Shell syntax error: $script"
    fi
done < <(find scripts -type f -name '*.sh' | sort)

section "3. JSON syntax"

JSON_COUNT=0

while IFS= read -r file; do
    JSON_COUNT=$((JSON_COUNT + 1))

    if ! jq empty "$file" >/dev/null 2>&1; then
        error "Invalid JSON: $file"
    fi
done < <(find config projects -type f -name '*.json' | sort)

echo "Checked JSON files: $JSON_COUNT"

section "4. Project structure"

PROJECT_COUNT=0

while IFS= read -r project_dir; do
    PROJECT_COUNT=$((PROJECT_COUNT + 1))
    project_name="$(basename "$project_dir")"

    echo "Checking project: $project_name"

    if [[ ! "$project_name" =~ ^[A-Za-z][A-Za-z0-9_-]*$ ]]; then
        error "Invalid project directory name: $project_name"
    fi

    if [[ ! -f "$project_dir/project.json" ]]; then
        error "Project is missing project.json: $project_name"
    fi
done < <(
    find projects \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        ! -name '.resources' \
        | sort
)

if [[ "$PROJECT_COUNT" -eq 0 ]]; then
    error "No Ignition projects were found under projects/"
else
    echo "Projects found: $PROJECT_COUNT"
fi

section "5. Forbidden tracked files"

FORBIDDEN_TRACKED=0

while IFS= read -r file; do
    [[ -n "$file" ]] || continue

    echo "Forbidden tracked file: $file"
    FORBIDDEN_TRACKED=1
done < <(
    git ls-files |
    grep -E \
        '(^|/)\.env$|(^|/)runtime/|(^|/)secrets/|\.gwbk$|\.p12$|\.pfx$|\.pem$|(^|/)id_rsa|(^|/)id_ed25519' \
        || true
)

if [[ "$FORBIDDEN_TRACKED" -ne 0 ]]; then
    error "Repository contains tracked secrets, runtime files, or backups"
else
    echo "No forbidden tracked files found"
fi

section "6. Ignored local path policy"

REQUIRED_IGNORE_PATTERNS=(
    "/runtime/"
    "/secrets/"
    "/deploy/"
    "/build/"
)

for pattern in "${REQUIRED_IGNORE_PATTERNS[@]}"; do
    if grep -Fxq "$pattern" .gitignore; then
        echo "OK: .gitignore contains $pattern"
    else
        error ".gitignore is missing required rule: $pattern"
    fi
done

section "7. Docker Compose structure"

# Use the committed template because CI must not have the local .env file.
if ! docker compose \
    --env-file .env.example \
    -f compose/compose.yml \
    config >/tmp/ignition-compose-rendered.yml; then
    error "Docker Compose validation failed"
else
    echo "Docker Compose validation passed"
fi

if [[ -f /tmp/ignition-compose-rendered.yml ]]; then
    if grep -Fq 'container_name: ignition-test' /tmp/ignition-compose-rendered.yml; then
        echo "OK: ignition-test service found"
    else
        error "ignition-test service is missing"
    fi

    if grep -Fq 'container_name: ignition-dev' /tmp/ignition-compose-rendered.yml; then
        echo "OK: ignition-dev service found"
    else
        error "ignition-dev service is missing"
    fi

    if grep -Fq 'published: "9088"' /tmp/ignition-compose-rendered.yml; then
        echo "OK: TEST port 9088 found"
    else
        error "TEST published port 9088 is missing"
    fi

    if grep -Fq 'published: "9188"' /tmp/ignition-compose-rendered.yml; then
        echo "OK: DEV port 9188 found"
    else
        error "DEV published port 9188 is missing"
    fi
fi

section "8. Literal password guardrail"

# Inspect executable and deployment configuration, but not documentation.
# Documentation may legitimately contain examples of validation patterns.
SECRET_SCAN_PATHS=(
    "compose"
    "scripts"
    ".env.example"
)

if [[ -d ".github/workflows" ]]; then
    SECRET_SCAN_PATHS+=(".github/workflows")
fi

if grep -RInE \
    --exclude="validate-repository.sh" \
    --exclude="*.md" \
    'GATEWAY_ADMIN_PASSWORD:[[:space:]]*[^$<{[:space:]]+' \
    "${SECRET_SCAN_PATHS[@]}" \
    2>/dev/null
then
    error "Possible literal Gateway administrator password found"
else
    echo "No literal Gateway administrator password found"
fi

echo
echo "============================================================"

if [[ "$FAILED" -ne 0 ]]; then
    echo "REPOSITORY VALIDATION FAILED"
    echo "============================================================"
    exit 1
fi

echo "REPOSITORY VALIDATION PASSED"
echo "============================================================"
