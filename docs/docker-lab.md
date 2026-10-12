# Finish and Commit the Docker TEST Gateway

This phase completes the first containerized Ignition milestone.

At this point:

- the native Ubuntu Gateway is still running on Ubuntu port `8088`;
- the Docker TEST Gateway is running on Ubuntu port `9088`;
- the Docker TEST Gateway is healthy;
- the Docker TEST Gateway survives a restart;
- the `admin` account works;
- Git-controlled source is separated from ignored Gateway runtime files;
- the known OPC UA `opcua-module` warning is not blocking this milestone;
- the DEV Gateway has not been added yet.

The purpose of this phase is to:

1. make TEST runtime synchronization repeatable;
2. document the current lab layout;
3. validate the files;
4. commit the TEST Gateway setup on the feature branch;
5. measure memory before adding DEV.

---

## 1. Confirm the current branch

Go to the repository:

```bash
cd ~/ignition-lab/ignition-lab
```

Check the branch:

```bash
git branch --show-current
```

Expected result:

```text
feature/docker-test-gateway
```

If it shows `master`, switch back:

```bash
git checkout feature/docker-test-gateway
```

---

## 2. Create the TEST runtime synchronization script

The script will:

- refuse to run while `ignition-test` is running;
- copy Git-controlled projects into the ignored TEST runtime directory;
- copy selected Gateway configuration into TEST runtime;
- preserve Gateway-local security and OPC UA configuration;
- reapply ACL permissions for the Ignition container user, UID `2003`.

Create the scripts directory:

```bash
mkdir -p scripts
```

Create `scripts/sync-test-runtime.sh`:

```bash
cat <<'EOF' > scripts/sync-test-runtime.sh
#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONTAINER_NAME="ignition-test"
IGNITION_UID="2003"

echo "Preparing TEST runtime from Git source..."
echo

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "ERROR: $CONTAINER_NAME is currently running."
    echo
    echo "Stop it first:"
    echo "  docker compose --env-file .env -f compose/compose.yml stop ignition-test"
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

mkdir -p runtime/test/projects

rsync -a --delete \
    --exclude='.resources/' \
    projects/ \
    runtime/test/projects/

echo "   Projects synchronized."

echo
echo "2. Synchronizing selected Gateway configuration..."

mkdir -p runtime/test/config/resources

rsync -a --delete \
    --exclude='.resources/' \
    --exclude='core/ignition/identity-provider/' \
    --exclude='core/ignition/user-source/' \
    --exclude='core/ignition/security-properties/' \
    --exclude='core/ignition/opc-connection/' \
    --exclude='core/com.inductiveautomation.opcua/' \
    config/resources/ \
    runtime/test/config/resources/

echo "   Selected Gateway configuration synchronized."

echo
echo "3. Applying container access permissions..."

sudo setfacl -R -m "u:${IGNITION_UID}:rwX" runtime/test
sudo setfacl -R -d -m "u:${IGNITION_UID}:rwX" runtime/test

echo "   ACL permissions applied for Ignition UID ${IGNITION_UID}."

echo
echo "TEST runtime synchronization completed."
echo
echo "The following Gateway-local resources were not overwritten:"
echo "  - identity providers"
echo "  - user sources"
echo "  - security properties"
echo "  - OPC connections"
echo "  - OPC UA server configuration"
echo
echo "Start TEST with:"
echo "  docker compose --env-file .env -f compose/compose.yml up -d ignition-test"
EOF
```

Make the script executable:

```bash
chmod +x scripts/sync-test-runtime.sh
```

### Why the script refuses to run while TEST is running

Replacing filesystem-backed resources underneath a running Gateway may cause partial reads, transient configurations, or unexpected resource reloads.

For this first implementation, synchronization is performed only while the target Gateway is stopped.

### Why excluded directories are preserved

The script uses:

```text
--delete
```

but it does not use:

```text
--delete-excluded
```

Therefore, excluded Gateway-local directories are not overwritten or deleted during an ordinary synchronization.

---

## 3. Validate the script

Check the shell syntax:

```bash
bash -n scripts/sync-test-runtime.sh
```

Expected result: no output.

Check executable permissions:

```bash
ls -l scripts/sync-test-runtime.sh
```

Expected beginning:

```text
-rwxr-xr-x
```

---

## 4. Verify the script blocks synchronization while TEST is running

The TEST Gateway should currently be running.

Run:

```bash
./scripts/sync-test-runtime.sh
```

Expected result:

```text
ERROR: ignition-test is currently running.
```

This is intentional.

---

## 5. Perform a real TEST runtime synchronization

Stop TEST:

```bash
docker compose \
  --env-file .env \
  -f compose/compose.yml \
  stop ignition-test
```

Confirm that the container is stopped:

```bash
docker ps --filter name=ignition-test
```

The command should not list a running `ignition-test` container.

Run the synchronization script:

```bash
./scripts/sync-test-runtime.sh
```

The script may ask for the Ubuntu password because it runs `sudo setfacl`.

Expected ending:

```text
TEST runtime synchronization completed.
```

---

## 6. Verify project synchronization

Confirm that the project exists in TEST runtime:

```bash
test -f runtime/test/projects/CICD_Test/project.json \
  && echo "CICD_Test synchronized correctly" \
  || echo "ERROR: CICD_Test is missing"
```

Expected:

```text
CICD_Test synchronized correctly
```

Compare the Git project source with TEST runtime:

```bash
diff -qr \
  --exclude='.resources' \
  projects \
  runtime/test/projects
```

Expected result: no output.

No output means the project runtime copy matches the Git source.

---

## 7. Verify Gateway-local configuration

Check whether the clean TEST Gateway has generated its local security resources:

```bash
for path in \
  runtime/test/config/resources/core/ignition/identity-provider \
  runtime/test/config/resources/core/ignition/user-source \
  runtime/test/config/resources/core/ignition/security-properties
do
    if [[ -d "$path" ]]; then
        echo "Preserved Gateway-local path: $path"
    else
        echo "NOTICE: Gateway-local path not currently present: $path"
    fi
done
```

These directories may exist because Ignition generated them during commissioning.

The important point is that the synchronization script does not overwrite them with old credentials from Git.

The OPC UA issue can remain for this milestone. It does not block:

- Gateway startup;
- the admin login;
- Perspective;
- the container health check;
- repository work;
- future GitHub Actions work.

---

## 8. Start TEST again

```bash
docker compose \
  --env-file .env \
  -f compose/compose.yml \
  up -d ignition-test
```

Wait for startup:

```bash
sleep 60
```

Check health:

```bash
docker inspect ignition-test \
  --format 'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'
```

If health is still `starting`, wait another 30 seconds:

```bash
sleep 30
```

Then repeat the health check.

The desired result is similar to:

```text
Status=running Health=healthy OOMKilled=false
```

Check the status endpoint:

```bash
curl -sS http://localhost:9088/StatusPing
echo
```

Expected:

```json
{"state":"RUNNING"}
```

Open the Gateway from the Ubuntu browser:

```text
http://localhost:9088
```

Confirm:

- the `admin` login still works;
- commissioning remains complete;
- the Gateway name is `ignition-test`;
- `CICD_Test` appears;
- the Perspective project opens.

Windows access through VirtualBox is not required for this milestone. The Docker TEST Gateway and future self-hosted runner operate inside Ubuntu.

---

## 9. Confirm Git source remains isolated

Check repository status:

```bash
git status --short
```

Expected result is approximately:

```text
 M .gitignore
?? .env.example
?? compose/
?? scripts/
```

Check the original Ignition source directories directly:

```bash
git status --short -- projects config/resources
```

Expected result: no output.

Check ignored local data:

```bash
git status --short --ignored \
  | grep -E '^!! (\.env$|runtime/|secrets/)'
```

Expected output should include:

```text
!! .env
!! runtime/
!! secrets/
```

Confirm that the password file is ignored:

```bash
git check-ignore -v secrets/test_gateway_admin_password.txt
```

Confirm that TEST runtime is ignored:

```bash
git check-ignore -v runtime/test/projects
```

---

## 10. Create the Docker lab documentation

Create the documentation directory:

```bash
mkdir -p docs
```

Create `docs/docker-lab.md`:

````bash
cat <<'EOF' > docs/docker-lab.md
# Docker Ignition Research Lab

## Current Gateways

The Ubuntu VM currently contains:

1. A native Ubuntu Ignition Gateway.
2. A Docker TEST Ignition Gateway.

A separate native Ignition Gateway also runs on Windows.

## Port Layout

### Native Windows Gateway

Accessible on Windows at:

```text
http://localhost:8088
```

### Native Ubuntu Gateway

Accessible inside Ubuntu at:

```text
http://localhost:8088
```

### Docker TEST Gateway

Docker publishes:

```text
Ubuntu port 9088 -> container port 8088
```

Accessible inside Ubuntu at:

```text
http://localhost:9088
```

The current Windows VirtualBox forwarding is not relied upon by the CI/CD workflow. Docker TEST administration is currently performed inside Ubuntu.

### Future Docker DEV Gateway

Reserved mapping:

```text
Ubuntu port 9188 -> container port 8088
```

## Source and Runtime Separation

Git-controlled source:

```text
projects/
config/resources/
```

Ignored TEST runtime:

```text
runtime/test/projects/
runtime/test/config/resources/
```

The running Gateway must not mount the Git source directories directly.

Use this script to prepare TEST runtime:

```bash
docker compose --env-file .env -f compose/compose.yml stop ignition-test
./scripts/sync-test-runtime.sh
docker compose --env-file .env -f compose/compose.yml up -d ignition-test
```

## Gateway-Local Resources

The initial synchronization does not overwrite:

- identity providers;
- user sources;
- security properties;
- OPC connections;
- OPC UA server configuration.

These resources may include credentials or environment-specific configuration.

## Known OPC UA Issue

The source OPC UA configuration references a user source named `opcua-module`.

The original user source contains existing hashed credentials and is not automatically deployed to the clean TEST Gateway.

OPC UA security will be configured later using lab-only credentials. This issue does not currently prevent the Gateway, Perspective project, Docker health check, or Git workflow from operating.

## TEST Health Check

```bash
curl -fsS http://localhost:9088/StatusPing
```

Expected result:

```json
{"state":"RUNNING"}
```
EOF
````

---

## 11. Run pre-commit validation

### Validate Compose

```bash
docker compose \
  --env-file .env \
  -f compose/compose.yml \
  config >/dev/null \
  && echo "Compose validation passed"
```

### Validate shell syntax

```bash
bash -n scripts/sync-test-runtime.sh \
  && echo "Script syntax passed"
```

### Validate source JSON

```bash
failed=0

while IFS= read -r file; do
    if ! jq empty "$file" >/dev/null 2>&1; then
        echo "INVALID JSON: $file"
        failed=1
    fi
done < <(find config projects -type f -name '*.json' | sort)

if [[ "$failed" -eq 0 ]]; then
    echo "All source JSON files are valid"
fi
```

### Check Git whitespace

```bash
git diff --check
```

Expected result: no output.

---

## 12. Review what will be committed

Check status:

```bash
git status --short
```

Expected approximately:

```text
 M .gitignore
?? .env.example
?? compose/
?? docs/
?? scripts/
```

Inspect `.gitignore` changes:

```bash
git diff -- .gitignore
```

The file should include:

```gitignore
/runtime/
/secrets/
/deploy/
/build/
```

It should already include:

```gitignore
.env
.env.*
!.env.example
```

Inspect the environment template:

```bash
cat .env.example
```

It should contain no passwords, for example:

```dotenv
IGNITION_VERSION=8.3.9
TZ=Europe/Warsaw
```

Inspect Compose:

```bash
cat compose/compose.yml
```

Confirm the TEST port mapping:

```yaml
ports:
  - "9088:8088"
```

Confirm the runtime mounts:

```yaml
- ../runtime/test/projects:/usr/local/bin/ignition/data/projects
- ../runtime/test/config/resources:/usr/local/bin/ignition/data/config/resources
```

Confirm the password is read from a file:

```yaml
GATEWAY_ADMIN_PASSWORD_FILE: /run/secrets/gateway_admin_password
```

There must be no literal password in Compose or `.env.example`.

---

## 13. Search for accidentally exposed secrets

Run this basic guardrail search:

```bash
grep -RInE \
  '(GATEWAY_ADMIN_PASSWORD:|password[[:space:]]*[:=][[:space:]]*[^$<{[:space:]]+)' \
  .env.example compose scripts docs \
  2>/dev/null
```

Expected result: no actual password value.

Confirm ignored local files are not tracked:

```bash
git ls-files \
  '.env' \
  'secrets/**' \
  'runtime/**'
```

Expected result: no output.

---

## 14. Measure memory before adding DEV

Check TEST container memory:

```bash
docker stats --no-stream ignition-test
```

Check the VM:

```bash
free -h
swapon --show
```

Check container state:

```bash
docker inspect ignition-test \
  --format 'OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'
```

The restart count may include earlier failed starts, but it should no longer increase unexpectedly.

The native Ubuntu Gateway is also consuming VM memory. These measurements will determine whether:

- TEST and DEV can run while the native Ubuntu Gateway remains active; or
- the native Ubuntu Gateway should be stopped while both Docker Gateways run.

---

## 15. Stage the intended files

Confirm the current branch:

```bash
git branch --show-current
```

Expected:

```text
feature/docker-test-gateway
```

Stage only the intended files:

```bash
git add \
  .gitignore \
  .env.example \
  compose/compose.yml \
  scripts/sync-test-runtime.sh \
  docs/docker-lab.md
```

Review staged file names:

```bash
git diff --cached --name-status
```

Expected files:

```text
.gitignore
.env.example
compose/compose.yml
docs/docker-lab.md
scripts/sync-test-runtime.sh
```

Review all staged content:

```bash
git diff --cached
```

Carefully verify that the staged content contains no password.

---

## 16. Commit the TEST milestone

```bash
git commit -m "chore: add containerized Ignition TEST gateway"
```

Check the commit:

```bash
git log -1 --oneline --decorate
```

---

## 17. Push the feature branch

```bash
git push -u origin feature/docker-test-gateway
```

Do not merge into `master` yet.

---

## 18. Final diagnostic block

Run:

```bash
echo "=== LAST COMMIT ==="
git log -1 --oneline --decorate

echo
echo "=== WORKING TREE ==="
git status --short

echo
echo "=== TEST HEALTH ==="
docker inspect ignition-test \
  --format 'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'

echo
echo "=== TEST STATUS PING ==="
curl -sS http://localhost:9088/StatusPing
echo

echo
echo "=== MEMORY ==="
docker stats --no-stream ignition-test
free -h
swapon --show

echo
echo "=== SOURCE CHANGES ==="
git status --short -- projects config/resources
```

## Expected final state

- The feature branch has been pushed.
- The working tree is clean.
- TEST is `running` and `healthy`.
- `OOMKilled=false`.
- `StatusPing` returns `RUNNING`.
- The original `projects/` and `config/resources/` source directories show no runtime changes.
- `.env`, `secrets/`, and `runtime/` remain ignored.
- `CICD_Test` opens in the Docker TEST Gateway on Ubuntu at `http://localhost:9088`.
- The admin account still works after a restart.

Do not add DEV until memory usage has been reviewed.
