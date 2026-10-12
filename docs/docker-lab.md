# Finish and Commit the Docker TEST and DEV Gateways

This phase completes the initial two-Gateway Docker milestone for the Ignition research lab.

## Current verified state

The Ubuntu VM now runs two containerized Ignition 8.3.9 Gateways:

- Docker TEST Gateway on Ubuntu port `9088`;
- Docker DEV Gateway on Ubuntu port `9188`.

The native Ubuntu Ignition Gateway has been stopped to free memory. The native Windows Gateway remains independent and can continue running.

The following behavior has been verified:

- TEST and DEV are both running;
- both Docker health checks report `healthy`;
- both Gateways return `{"state":"RUNNING"}` from `StatusPing`;
- neither container has been OOM-killed;
- neither container has restarted unexpectedly;
- TEST survives a container restart;
- DEV survives a container restart;
- the `admin` account works on both Gateways;
- TEST and DEV use different administrator password files;
- `CICD_Test` is available on both Gateways;
- Git-controlled source is separated from ignored Gateway runtime files;
- the running Gateways do not write directly into `projects/` or `config/resources/`;
- the known OPC UA `opcua-module` warning is not blocking this milestone.

The purpose of this phase is to:

1. keep TEST and DEV runtime synchronization repeatable;
2. document the current lab layout;
3. validate the repository files;
4. commit the DEV Gateway setup on its feature branch;
5. preserve the current memory operating rule before adding CI/CD automation.

---

## 1. Current architecture

```text
Windows host
├── Native Windows Ignition Gateway
│   └── Windows localhost:8088
│
└── VirtualBox Ubuntu VM
    ├── Native Ubuntu Ignition Gateway
    │   └── Stopped to save memory
    │
    ├── Docker TEST Gateway
    │   ├── Container port: 8088
    │   ├── Ubuntu host port: 9088
    │   ├── Named volume: ignition-test-data
    │   └── Runtime: runtime/test/
    │
    └── Docker DEV Gateway
        ├── Container port: 8088
        ├── Ubuntu host port: 9188
        ├── Named volume: ignition-dev-data
        └── Runtime: runtime/dev/
```

The primary Ubuntu addresses are:

```text
Docker TEST: http://localhost:9088
Docker DEV:  http://localhost:9188
```

The self-hosted GitHub Actions runner will eventually run inside Ubuntu, so it will use the Ubuntu addresses directly. VirtualBox forwarding to Windows is not required for the CI/CD workflow.

---

## 2. Branch state

The TEST milestone was committed and pushed from:

```text
feature/docker-test-gateway
```

Verified TEST commit:

```text
8151c84 Add containerized Ignition TEST gateway
```

The DEV work should be performed on:

```text
feature/docker-dev-gateway
```

Confirm the current branch:

```bash
cd ~/ignition-lab/ignition-lab
git branch --show-current
```

Expected while finishing DEV:

```text
feature/docker-dev-gateway
```

---

## 3. Source and runtime separation

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

Ignored DEV runtime:

```text
runtime/dev/projects/
runtime/dev/config/resources/
```

Local secrets:

```text
secrets/test_gateway_admin_password.txt
secrets/dev_gateway_admin_password.txt
```

Local environment file:

```text
.env
```

The running containers must mount the ignored runtime directories, not the Git source directories directly.

---

## 4. TEST synchronization script

The existing TEST synchronization script is:

```text
scripts/sync-test-runtime.sh
```

It should:

- refuse to run while `ignition-test` is running;
- synchronize `projects/` into `runtime/test/projects/`;
- synchronize selected `config/resources/` into `runtime/test/config/resources/`;
- preserve Gateway-local security and OPC UA configuration;
- apply ACL access for Ignition UID `2003`.

Use it with:

```bash
docker compose --env-file .env -f compose/compose.yml stop ignition-test
./scripts/sync-test-runtime.sh
docker compose --env-file .env -f compose/compose.yml up -d ignition-test
```

---

## 5. DEV synchronization script

The DEV synchronization script is:

```text
scripts/sync-dev-runtime.sh
```

It should contain:

```bash
CONTAINER_NAME="ignition-dev"
```

and use:

```text
runtime/dev/projects
runtime/dev/config/resources
```

It must not use:

```text
runtime/test
ignition-test
```

Validate it:

```bash
bash -n scripts/sync-dev-runtime.sh
```

Inspect its important settings:

```bash
grep -nE \
  'CONTAINER_NAME|runtime/dev|ignition-dev|runtime/test|ignition-test' \
  scripts/sync-dev-runtime.sh
```

Use it with:

```bash
docker compose --env-file .env -f compose/compose.yml stop ignition-dev
./scripts/sync-dev-runtime.sh
docker compose --env-file .env -f compose/compose.yml up -d ignition-dev
```

The script should refuse to run while DEV is running. Test that behavior with:

```bash
./scripts/sync-dev-runtime.sh
```

Expected while DEV is active:

```text
ERROR: ignition-dev is currently running.
```

---

## 6. Gateway-local resource exclusions

The first synchronization policy does not overwrite:

```text
core/ignition/identity-provider/
core/ignition/user-source/
core/ignition/security-properties/
core/ignition/opc-connection/
core/com.inductiveautomation.opcua/
```

These areas are initially Gateway-local because they contain or reference:

- administrator and application authentication;
- hashed user credentials;
- identity-provider settings;
- OPC UA authentication profiles;
- environment-specific OPC connections;
- Gateway-specific security settings.

The current source OPC UA configuration references:

```json
"authenticationProfile": "opcua-module"
```

The corresponding source user profile is intentionally not automatically deployed because it contains existing hashed credentials.

This known issue does not currently prevent:

- TEST or DEV startup;
- Gateway administration;
- Perspective project loading;
- Docker health checks;
- Git operations;
- later CI/CD automation.

OPC UA security should be configured later using lab-only credentials and an explicit deployment policy.

---

## 7. Current Docker Compose requirements

Validate Compose:

```bash
docker compose \
  --env-file .env \
  -f compose/compose.yml \
  config >/dev/null \
  && echo "Compose validation passed"
```

### TEST requirements

TEST must use:

```yaml
container_name: ignition-test
hostname: ignition-test
```

Port mapping:

```yaml
ports:
  - "9088:8088"
```

Runtime mounts:

```yaml
- ../runtime/test/projects:/usr/local/bin/ignition/data/projects
- ../runtime/test/config/resources:/usr/local/bin/ignition/data/config/resources
```

Password file:

```yaml
GATEWAY_ADMIN_PASSWORD_FILE: /run/secrets/gateway_admin_password
```

```yaml
- ../secrets/test_gateway_admin_password.txt:/run/secrets/gateway_admin_password:ro
```

Named volume:

```yaml
ignition-test-data:
  name: ignition-test-data
```

### DEV requirements

DEV must use:

```yaml
container_name: ignition-dev
hostname: ignition-dev
```

Port mapping:

```yaml
ports:
  - "9188:8088"
```

Runtime mounts:

```yaml
- ../runtime/dev/projects:/usr/local/bin/ignition/data/projects
- ../runtime/dev/config/resources:/usr/local/bin/ignition/data/config/resources
```

Password file:

```yaml
GATEWAY_ADMIN_PASSWORD_FILE: /run/secrets/gateway_admin_password
```

```yaml
- ../secrets/dev_gateway_admin_password.txt:/run/secrets/gateway_admin_password:ro
```

Named volume:

```yaml
ignition-dev-data:
  name: ignition-dev-data
```

TEST and DEV must not share:

- administrator password files;
- named data volumes;
- project runtime directories;
- configuration runtime directories;
- Ubuntu host ports.

---

## 8. Verify both Gateways

List the containers:

```bash
docker ps \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Expected mappings:

```text
ignition-test   ...   0.0.0.0:9088->8088/tcp
ignition-dev    ...   0.0.0.0:9188->8088/tcp
```

Check health:

```bash
for container in ignition-test ignition-dev; do
  docker inspect "$container" \
    --format '{{.Name}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'
done
```

Verified result:

```text
/ignition-test Status=running Health=healthy OOMKilled=false RestartCount=0
/ignition-dev Status=running Health=healthy OOMKilled=false RestartCount=0
```

Check the status endpoints:

```bash
echo "TEST:"
curl -sS http://localhost:9088/StatusPing
echo

echo "DEV:"
curl -sS http://localhost:9188/StatusPing
echo
```

Expected for both:

```json
{"state":"RUNNING"}
```

---

## 9. Verify restart persistence

Restart TEST:

```bash
docker restart ignition-test
sleep 90
```

Check TEST:

```bash
docker inspect ignition-test \
  --format 'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'
```

Restart DEV:

```bash
docker restart ignition-dev
sleep 90
```

Check DEV:

```bash
docker inspect ignition-dev \
  --format 'Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'
```

After restart, confirm on both Gateways:

- commissioning remains complete;
- the appropriate `admin` password still works;
- the Gateway name remains correct;
- `CICD_Test` remains available;
- `StatusPing` returns `RUNNING`.

---

## 10. Current memory assessment

The two Docker Gateways were measured at approximately:

```text
ignition-test: 1.144 GiB
ignition-dev:  992.5 MiB
```

VM memory with both running and the native Ubuntu Gateway stopped:

```text
Total RAM:      5.3 GiB
Available RAM:  1.3 GiB
Swap used:      approximately 468 MiB
```

Both containers remained healthy and their memory use was stable during the observation period.

### Current operating rule

The native Ubuntu Ignition Gateway must remain stopped while both Docker Gateways are running.

Check it with:

```bash
systemctl is-active Ignition-Gateway
```

Expected:

```text
inactive
```

Do not run this while both Docker Gateways are active:

```bash
sudo systemctl start Ignition-Gateway
```

### Current capacity decision

The VM can support TEST and DEV simultaneously for this research lab, but it has limited spare capacity.

Do not add yet:

- a third Ignition Gateway;
- PostgreSQL;
- heavy Reporting workloads;
- large Historian queries;
- extensive module sets without additional measurement.

Monitor memory with:

```bash
docker stats --no-stream ignition-test ignition-dev
free -h
swapon --show
```

Stop DEV if memory becomes unstable:

```bash
docker stop ignition-dev
```

---

## 11. Confirm Git source remains isolated

Check source directories:

```bash
git status --short -- projects config/resources
```

Expected: no output.

Check ignored local data:

```bash
git status --short --ignored \
  | grep -E '^!! (\.env$|runtime/|secrets/)'
```

Expected:

```text
!! .env
!! runtime/
!! secrets/
```

Confirm local secrets and runtime files are not tracked:

```bash
git ls-files \
  '.env' \
  'secrets/**' \
  'runtime/**'
```

Expected: no output.

---

## 12. Validate scripts and repository source

Validate shell scripts:

```bash
bash -n scripts/sync-test-runtime.sh
bash -n scripts/sync-dev-runtime.sh
```

Expected: no output.

Validate source JSON:

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

Check Git whitespace:

```bash
git diff --check
```

Expected: no output.

---

## 13. Check for accidentally exposed secrets

Search the new infrastructure files:

```bash
grep -RInE \
  '(GATEWAY_ADMIN_PASSWORD:|password[[:space:]]*[:=][[:space:]]*[^$<{[:space:]]+)' \
  .env.example compose scripts docs \
  2>/dev/null
```

There should be no actual password value.

The following setting is expected and safe:

```yaml
GATEWAY_ADMIN_PASSWORD_FILE: /run/secrets/gateway_admin_password
```

Confirm passwords are ignored:

```bash
git check-ignore -v \
  secrets/test_gateway_admin_password.txt \
  secrets/dev_gateway_admin_password.txt
```

---

## 14. Update `docs/docker-lab.md`

The documentation should now describe both existing Docker Gateways, not a future DEV Gateway.

Ensure it includes:

```text
Docker TEST: Ubuntu port 9088 -> container port 8088
Docker DEV:  Ubuntu port 9188 -> container port 8088
```

It should also state:

- DEV is a deployment target and should not be edited manually;
- TEST and DEV have separate state and secrets;
- the native Ubuntu Gateway remains stopped while both containers run;
- PostgreSQL is postponed due to memory limits;
- OPC UA security remains Gateway-local for now.

---

## 15. Review the DEV feature changes

Check status:

```bash
git status --short
```

Before the DEV commit, the expected changes are:

```text
 M compose/compose.yml
 M docs/docker-lab.md
?? scripts/sync-dev-runtime.sh
```

Review Compose:

```bash
git diff -- compose/compose.yml
```

Review documentation:

```bash
git diff -- docs/docker-lab.md
```

Review the DEV script:

```bash
sed -n '1,260p' scripts/sync-dev-runtime.sh
```

---

## 16. Stage the DEV files

```bash
git add \
  compose/compose.yml \
  docs/docker-lab.md \
  scripts/sync-dev-runtime.sh
```

Review staged names:

```bash
git diff --cached --name-status
```

Expected:

```text
M compose/compose.yml
M docs/docker-lab.md
A scripts/sync-dev-runtime.sh
```

Review the full staged change:

```bash
git diff --cached
```

Verify that it contains no passwords or runtime files.

---

## 17. Commit the DEV Gateway milestone

Commit:

```bash
git commit -m "chore: add containerized Ignition DEV gateway"
```

Push:

```bash
git push -u origin feature/docker-dev-gateway
```

Verify:

```bash
git status
git log -2 --oneline --decorate
```

Expected:

- the working tree is clean;
- the branch is synchronized with `origin/feature/docker-dev-gateway`;
- the new DEV commit is above the TEST milestone in history.

---

## 18. Create the DEV pull request

Create a GitHub Pull Request:

```text
feature/docker-dev-gateway -> master
```

Suggested title:

```text
Add containerized Ignition DEV Gateway
```

Suggested description:

```markdown
## Summary

Adds a separate Ignition 8.3.9 DEV Gateway as the future automated deployment target.

## Included

- separate DEV container;
- separate named data volume;
- separate administrator password file;
- separate project and configuration runtime directories;
- DEV runtime synchronization script;
- Ubuntu port 9188;
- updated lab documentation.

## Validation

- TEST healthy;
- DEV healthy;
- OOM killed: false for both;
- restart count: 0 for both;
- TEST status endpoint: RUNNING;
- DEV status endpoint: RUNNING;
- restart persistence verified;
- Git source directories remain unchanged.

## Resource note

The native Ubuntu Gateway must remain stopped while both Docker Gateways run.
```

Do not merge until the changes have been reviewed.

---

## 19. Daily operating commands

Show both services:

```bash
docker compose --env-file .env -f compose/compose.yml ps
```

Start both:

```bash
docker compose --env-file .env -f compose/compose.yml up -d
```

Stop both:

```bash
docker compose --env-file .env -f compose/compose.yml stop
```

Check health:

```bash
for container in ignition-test ignition-dev; do
  docker inspect "$container" \
    --format '{{.Name}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}}'
done
```

Check endpoints:

```bash
curl -fsS http://localhost:9088/StatusPing
echo
curl -fsS http://localhost:9188/StatusPing
echo
```

Check memory:

```bash
docker stats --no-stream ignition-test ignition-dev
free -h
swapon --show
```

---

## 20. Final diagnostic block

Run after committing and pushing DEV:

```bash
echo "=== BRANCH AND COMMIT ==="
git branch --show-current
git log -2 --oneline --decorate

echo
echo "=== WORKING TREE ==="
git status --short

echo
echo "=== NATIVE UBUNTU GATEWAY ==="
systemctl is-active Ignition-Gateway

echo
echo "=== CONTAINERS ==="
docker ps \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo
echo "=== HEALTH ==="
for container in ignition-test ignition-dev; do
  docker inspect "$container" \
    --format '{{.Name}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}} RestartCount={{.RestartCount}}'
done

echo
echo "=== STATUS PING ==="
echo "TEST:"
curl -sS http://localhost:9088/StatusPing
echo
echo "DEV:"
curl -sS http://localhost:9188/StatusPing
echo

echo
echo "=== MEMORY ==="
docker stats --no-stream ignition-test ignition-dev
free -h
swapon --show

echo
echo "=== SOURCE CHANGES ==="
git status --short -- projects config/resources
```

## Expected final state

- TEST and DEV are both running and healthy.
- Both containers report `OOMKilled=false`.
- Both status endpoints report `RUNNING`.
- TEST uses Ubuntu port `9088`.
- DEV uses Ubuntu port `9188`.
- TEST and DEV use separate volumes, runtime directories, and password files.
- The native Ubuntu Gateway is inactive.
- Available memory remains around 1.3 GiB during idle operation.
- Swap use remains stable around 468 MiB rather than continuously increasing.
- Git-controlled `projects/` and `config/resources/` remain unchanged by runtime activity.
- The DEV feature branch is pushed and ready for review.

The next milestone is to define the Git branch and promotion workflow, then automate deployment to DEV through a self-hosted GitHub Actions runner.
