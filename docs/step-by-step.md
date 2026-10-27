# Build Guide: Recreate the Ignition CI/CD Lab v0.3.0 State

## 1. Purpose

This guide enables a future developer to recreate the validated `v0.3.0` state of the Ignition 8.3 CI/CD lab.

The target state includes:

- one shared TEST Gateway for authoring;
- one isolated DEV Gateway for approved deployments;
- PostgreSQL with separate TEST and DEV databases and roles;
- Git-backed Ignition projects and selected Gateway resources;
- pull-request-based promotion to DEV;
- a self-hosted GitHub Actions runner;
- TEST and DEV Deployment Modes;
- environment-specific database and simulator overrides;
- Gateway-local referenced secret values;
- a complete, Git-managed image collection including `Builtin`;
- shared ACLs for the developer, GitHub Actions runner, and Ignition UID `2003`;
- concurrent editing by two Designer users on different resources;
- backup, verification, and rollback logic.

This guide assumes the repository already contains the implementation represented by Git tag `v0.3.0`. It explains how to provision a new environment and validate that it reaches the same operational state.

---

## 2. Target architecture

```text
Ubuntu VM
├── Git working tree
│   ├── projects/
│   ├── config/gateway/resources/
│   │   ├── core/
│   │   ├── test/
│   │   └── dev/
│   ├── compose/
│   ├── scripts/
│   └── .github/workflows/
│
├── Docker
│   ├── ignition-test       port 9088
│   ├── ignition-dev        port 9188
│   └── ignition-postgres   port 5432 internally
│
├── Repository-local ignored DEV targets
│   ├── services/ignition-dev/projects
│   └── services/ignition-dev/config/resources
│
└── /srv/ignition-lab
    ├── release
    ├── secrets
    ├── backups
    ├── deployment locks and metadata
    └── .env
```

### Runtime behavior

```text
TEST Designer edits
→ Git working tree
→ feature branch
→ pull request
→ merge into develop
→ self-hosted GitHub Actions runner
→ DEV project/config deployment
→ Ignition scan endpoints
→ content and health verification
```

---

## 3. Prerequisites

Provision an Ubuntu VM with at least:

- 4 CPU cores;
- 8 GB RAM;
- 40 GB free disk space;
- Docker Engine and Docker Compose v2;
- Git;
- `jq`;
- `rsync`;
- `curl`;
- `acl`, providing `setfacl` and `getfacl`;
- Java support is provided inside the Ignition container;
- access to the GitHub repository;
- permission to register a self-hosted GitHub Actions runner.

Install host packages:

```bash
sudo apt update
sudo apt install -y \
  git \
  jq \
  rsync \
  curl \
  acl
```

Verify Docker:

```bash
docker version
docker compose version
```

Verify required tools:

```bash
for command in git jq rsync curl setfacl getfacl; do
  command -v "$command" || echo "MISSING: $command"
done
```

---

## 4. Create Linux users and runner identity

The validated permissions model uses:

```text
Developer user: [USER_NAME]
GitHub Actions runner user: actions
Ignition container UID: 2003
```

If the developer username differs, use the actual account and override `DEVELOPER_USER` when running the ACL provisioner.

Create the runner account if it does not exist:

```bash
id actions >/dev/null 2>&1 || \
  sudo useradd --create-home --shell /bin/bash actions
```

Allow the runner to access Docker according to the organization's security policy. For this lab:

```bash
sudo usermod -aG docker actions
```

Log out and back in, or restart the runner service after changing group membership.

---

## 5. Clone and check out v0.3.0

Clone the repository:

```bash
mkdir -p ~/ignition-lab
cd ~/ignition-lab

git clone git@github.com:MaciekDanik/ignition-lab.git
cd ignition-lab
```

Fetch tags and check out the stable checkpoint:

```bash
git fetch --all --tags
git switch --detach v0.3.0
```

For continued development, create a branch from the tag:

```bash
git switch -c rebuild/v0.3.0
```

Confirm the repository state:

```bash
git status --short
git log -1 --oneline --decorate
```

Expected: a clean working tree based on `v0.3.0`.

---

## 6. Understand tracked and local data

### Tracked in Git

```text
projects/
config/gateway/resources/core/
config/gateway/resources/test/
config/gateway/resources/dev/
compose/
scripts/
.github/workflows/
.env.example
```

### Local and ignored

```text
services/ignition-dev/
runtime/
secrets/
recovery-output/
build/
deploy/
```

### Never commit

```text
plaintext passwords
tokens
private keys
Gateway UUIDs
keystores
identity-provider runtime data
user-source runtime data
secret-provider values
.resources
System resources
```

Check ignore behavior:

```bash
git check-ignore -v \
  services/ignition-dev/projects \
  services/ignition-dev/config/resources \
  secrets
```

---

## 7. Create host directories

Create repository-local DEV targets:

```bash
mkdir -p \
  services/ignition-dev/projects \
  services/ignition-dev/config/resources
```

Create operational directories:

```bash
sudo mkdir -p \
  /srv/ignition-lab/release \
  /srv/ignition-lab/secrets \
  /srv/ignition-lab/backups \
  /srv/ignition-lab/runtime/test/config/resources
```

Grant appropriate ownership to the release and backup areas according to the deployment scripts and runner setup.

---

## 8. Provision password files

Create local secret files outside Git.

Required files commonly include:

```text
secrets/test_gateway_admin_password.txt
secrets/dev_gateway_admin_password.txt
secrets/postgres_admin_password.txt
secrets/postgres_test_password.txt
secrets/postgres_dev_password.txt
```

Create the directory:

```bash
mkdir -p secrets
chmod 700 secrets
```

Create each file interactively without putting passwords into shell history:

```bash
read -rsp 'TEST Gateway admin password: ' value
echo
printf '%s' "$value" > secrets/test_gateway_admin_password.txt
unset value

read -rsp 'DEV Gateway admin password: ' value
echo
printf '%s' "$value" > secrets/dev_gateway_admin_password.txt
unset value

read -rsp 'PostgreSQL admin password: ' value
echo
printf '%s' "$value" > secrets/postgres_admin_password.txt
unset value

read -rsp 'PostgreSQL TEST password: ' value
echo
printf '%s' "$value" > secrets/postgres_test_password.txt
unset value

read -rsp 'PostgreSQL DEV password: ' value
echo
printf '%s' "$value" > secrets/postgres_dev_password.txt
unset value
```

Apply restrictive permissions:

```bash
chmod 600 secrets/*.txt
```

Ensure UID `2003` can read Gateway bootstrap password files when required by the container mount. Use the minimum ACL needed rather than world-readable permissions.

Example:

```bash
sudo setfacl -m u:2003:r-- secrets/test_gateway_admin_password.txt
sudo setfacl -m u:2003:r-- secrets/dev_gateway_admin_password.txt
```

Do not commit the `secrets/` directory.

---

## 9. Create the active Compose environment

Copy the example environment to the operational location:

```bash
sudo cp .env.example /srv/ignition-lab/.env
sudo chown root:root /srv/ignition-lab/.env
sudo chmod 600 /srv/ignition-lab/.env
```

Review and set absolute VM paths. The final values should resolve to the current clone, for example:

```dotenv
TEST_PROJECTS_PATH=/home/masiek/ignition-lab/ignition-lab/projects
TEST_CONFIG_RESOURCES_PATH=/srv/ignition-lab/runtime/test/config/resources
TEST_GATEWAY_CONFIG_ROOT=/home/masiek/ignition-lab/ignition-lab/config/gateway/resources/core
TEST_GATEWAY_RESOURCES_ROOT=/home/masiek/ignition-lab/ignition-lab/config/gateway/resources

DEV_PROJECTS_PATH=/home/masiek/ignition-lab/ignition-lab/services/ignition-dev/projects
DEV_CONFIG_RESOURCES_PATH=/home/masiek/ignition-lab/ignition-lab/services/ignition-dev/config/resources
```

Replace `/home/masiek` if the repository is owned by a different developer account.

Render Compose before starting services:

```bash
sudo docker compose \
  --env-file /srv/ignition-lab/.env \
  -f compose/compose.yml \
  config > /tmp/ignition-lab-compose.yml
```

Expected: exit code `0`.

---

## 10. Initialize TEST runtime configuration

TEST uses a broad runtime configuration tree plus curated Git-backed child mounts.

The recommended bootstrap method is:

1. start a commissioned TEST Gateway from a known backup or existing lab snapshot;
2. restore local Gateway configuration that must remain untracked;
3. retain local, security-sensitive, generated, and machine-specific resources in the broad runtime tree;
4. let curated child mounts replace the selected Git-managed scopes.

The broad TEST runtime must remain writable by Ignition UID `2003`:

```bash
sudo setfacl -R -m u:2003:rwX \
  /srv/ignition-lab/runtime/test

sudo setfacl -R -d -m u:2003:rwX \
  /srv/ignition-lab/runtime/test
```

Do not copy sensitive TEST runtime resources into Git.

---

## 11. Start PostgreSQL

Start PostgreSQL first:

```bash
sudo docker compose \
  --env-file /srv/ignition-lab/.env \
  -f compose/compose.yml \
  up -d ignition-postgres
```

Wait for health:

```bash
until docker inspect ignition-postgres \
  --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
  | grep -qx healthy
do
  sleep 3
done
```

Verify databases:

```bash
docker exec ignition-postgres \
  psql -U ignition_admin -d postgres -Atc \
  "SELECT datname FROM pg_database WHERE datname IN ('ignition_test','ignition_dev') ORDER BY datname;"
```

Expected:

```text
ignition_dev
ignition_test
```

Verify roles:

```bash
docker exec ignition-postgres \
  psql -U ignition_admin -d postgres -Atc \
  "SELECT rolname FROM pg_roles WHERE rolname IN ('ignition_test','ignition_dev') ORDER BY rolname;"
```

Expected:

```text
ignition_dev
ignition_test
```

---

## 12. Start TEST and DEV Gateways

Start both Gateways:

```bash
sudo docker compose \
  --env-file /srv/ignition-lab/.env \
  -f compose/compose.yml \
  up -d ignition-test ignition-dev
```

Wait for actual readiness, not only Docker health:

```bash
for port in 9088 9188; do
  for attempt in $(seq 1 60); do
    state="$(curl -sS --max-time 5 "http://localhost:${port}/StatusPing" 2>/dev/null || true)"
    login="$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' "http://localhost:${port}/data/app/login" || true)"

    echo "port=$port attempt=$attempt state=$state login=$login"

    if [[ "$state" == *'"RUNNING"'* &&
          "$login" != "000" &&
          "$login" != "500" &&
          "$login" != "503" ]]
    then
      break
    fi

    sleep 5
  done
done
```

A temporary HTTP `503` during startup is acceptable. Final state must be `RUNNING`, with a usable login response such as `302`.

---

## 13. Configure Deployment Modes

The repository contains mode collections named:

```text
test
dev
```

Compose starts each Gateway with a JVM argument:

```text
TEST: -Dignition.config.mode=test
DEV:  -Dignition.config.mode=dev
```

Verify:

```bash
for container in ignition-test ignition-dev; do
  echo "=== $container ==="
  docker inspect "$container" \
    --format '{{range .Config.Cmd}}{{println .}}{{end}}' \
    | grep '^-Dignition.config.mode='
done
```

Expected:

```text
ignition-test: -Dignition.config.mode=test
ignition-dev:  -Dignition.config.mode=dev
```

---

## 14. Configure Gateway-local referenced secrets

Both database overrides reference:

```text
Provider: CICD_Secrets
Secret: LabDatabasePassword
```

The reference is versioned, but each Gateway must hold its own value locally.

In TEST Gateway Secrets Management:

```text
CICD_Secrets/LabDatabasePassword
→ password for PostgreSQL role ignition_test
```

In DEV Gateway Secrets Management:

```text
CICD_Secrets/LabDatabasePassword
→ password for PostgreSQL role ignition_dev
```

Do not copy secret-provider values through Git.

After provisioning secrets, restart the affected database connection or recreate the Gateway once if the reference was loaded before the local value existed.

Verify in the Gateway UI:

```text
TEST CICD_Lab_DB: Valid, ignition_test
DEV CICD_Lab_DB:  Valid, ignition_dev
```

---

## 15. Verify mode-specific simulator overrides

The tested resource is:

```text
CICD_Simulator
```

Expected effective values:

```text
TEST: timeIntervalRate = 1000 ms
DEV:  timeIntervalRate = 2000 ms
```

Confirm both devices remain connected and the effective override belongs to the active mode.

---

## 16. Provision Git-backed resource ACLs

Ignition writes mounted image resources as UID `2003`. Git branch switching and the self-hosted runner require access for the developer and `actions` user.

Run:

```bash
sudo ./scripts/provision-git-resource-acls.sh
```

If usernames differ:

```bash
sudo DEVELOPER_USER="$USER" \
  RUNNER_USER=actions \
  IGNITION_UID=2003 \
  ./scripts/provision-git-resource-acls.sh
```

Verify default ACL inheritance:

```bash
getfacl config/gateway/resources/core/ignition/images \
  | sed -n '1,40p'
```

Required entries include effective and default ACLs for:

```text
developer user
actions
UID 2003
```

Run the provisioner after:

- a fresh clone;
- restoring a VM snapshot;
- replacing the image tree;
- an archive or copy operation that does not preserve ACLs;
- any recurrence of `unable to unlink ... Permission denied` during Git branch switching.

---

## 17. Validate the complete image collection

Git owns the complete directory:

```text
config/gateway/resources/core/ignition/images
```

The `Builtin` tree must be tracked. Do not add this rule to `.gitignore`:

```gitignore
**/ignition/images/Builtin/
```

Verify tracked baseline:

```bash
git ls-files \
  'config/gateway/resources/core/ignition/images/Builtin/**' \
  | wc -l
```

Validated `v0.3.0` baseline:

```text
Builtin files: 704
Complete image tree: 708 files
```

Compare Git with DEV:

```bash
GIT_IMAGES="$PWD/config/gateway/resources/core/ignition/images"
DEV_IMAGES="$PWD/services/ignition-dev/config/resources/core/ignition/images"

sudo -u actions rsync -rcni --delete \
  --exclude='.resources/' \
  --exclude='System/' \
  --exclude='*.bak/' \
  "$GIT_IMAGES/" \
  "$DEV_IMAGES/"
```

Acceptance: no output.

---

## 18. Install the self-hosted GitHub Actions runner

In GitHub, open:

```text
Repository Settings
→ Actions
→ Runners
→ New self-hosted runner
```

Select Linux x64 and follow GitHub's generated commands while logged in as `actions`.

Install the runner as a system service using the generated service helper.

Verify:

```bash
sudo systemctl status \
  actions.runner.MaciekDanik-ignition-lab.Ubuntu-VM.service
```

Expected:

```text
active (running)
```

The exact service name depends on repository and runner names. Use:

```bash
systemctl list-units --type=service \
  | grep 'actions.runner'
```

if the name differs.

---

## 19. Populate the fixed release copy

The deployment workflow uses:

```text
/srv/ignition-lab/release
```

Ensure the self-hosted workflow synchronizes the approved `develop` checkout into this release location before running deployment scripts.

The active `/srv/ignition-lab/.env` and `/srv/ignition-lab/secrets` must remain local and must not be overwritten by repository synchronization.

Verify released scripts after the first deployment:

```bash
sudo test -x /srv/ignition-lab/release/scripts/deploy-dev.sh
sudo test -x /srv/ignition-lab/release/scripts/deploy-dev-config.sh
```

---

## 20. Run repository validation

```bash
./scripts/validate-repository.sh
git diff --check
```

Expected:

```text
REPOSITORY VALIDATION PASSED
```

Validation includes:

- required repository paths;
- shell syntax;
- JSON syntax;
- project structure;
- forbidden tracked files;
- ignore policy;
- Docker Compose rendering;
- password guardrails;
- Deployment Mode resources;
- complete image collection requirements;
- ACL provisioner presence.

---

## 21. Run an end-to-end promotion test

Create a feature branch:

```bash
git switch develop
git pull --ff-only origin develop
git switch -c test/rebuild-smoke
```

On TEST:

1. change a disposable Perspective label;
2. change a persisted tag property such as Documentation;
3. optionally add a disposable custom image.

Verify Git detects complete resources:

```bash
git status --short
./scripts/validate-repository.sh
git diff --check
```

Before merge, confirm DEV does not contain the marker.

Commit and push:

```bash
git add <complete-resource-directories>
git commit -m "test: verify rebuilt v0.3.0 promotion"
git push -u origin test/rebuild-smoke
```

Create a pull request into `develop`, wait for validation, and merge.

After deployment, verify:

- project marker appears on DEV;
- persisted tag property appears on DEV;
- image appears on DEV if tested;
- Git and DEV managed scopes match;
- DEV did not restart during normal deployment;
- both Gateways remain `RUNNING`.

Remove or revert disposable test content afterward through a normal pull request.

---

## 22. Create a second Designer user

In the TEST Gateway user source used by the default Identity Provider, create a second account with the same Designer access needed for the test.

Use two independent Designer sessions:

```text
Session A: existing authoring user
Session B: second authoring user
```

Verify concurrent editing on different resources:

- different Perspective views;
- different tags;
- different images.

Expected `v0.3.0` behavior:

- both complete view resources are written;
- both tag changes persist;
- both image resources are created;
- image ACL inheritance works;
- TEST does not restart.

Operational rule:

> Multiple users may work concurrently on different resources. Only one user should actively edit a specific view, tag resource, or image at a time.

Same-resource conflict handling was not accepted as proven in `v0.3.0`.

---

## 23. Final acceptance checklist

### Repository

```bash
git switch develop
git pull --ff-only origin develop
./scripts/validate-repository.sh
git diff --check
git status --short
```

Required:

- validation passes;
- working tree is clean.

### Gateways

```bash
curl -fsS http://localhost:9088/StatusPing
echo
curl -fsS http://localhost:9188/StatusPing
echo
```

Required twice:

```json
{"state":"RUNNING"}
```

### Containers

```bash
for container in ignition-test ignition-dev; do
  docker inspect "$container" \
    --format '{{.Name}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}}'
done
```

Required:

```text
running
healthy
OOMKilled=false
```

### Deployment Modes

```text
TEST: test
DEV:  dev
```

### Database connections

```text
TEST: Valid, ignition_test, ignition_test
DEV:  Valid, ignition_dev, ignition_dev
```

### Simulator

```text
TEST: 1000 ms
DEV:  2000 ms
```

### Images

```text
Builtin tracked: 704 files
Git vs DEV rsync difference: 0
Builtin and custom images visible in both Designers
```

### Runner

```bash
sudo systemctl is-active \
  actions.runner.MaciekDanik-ignition-lab.Ubuntu-VM.service
```

Required:

```text
active
```

### Deployment record

```bash
develop_commit="$(git rev-parse origin/develop)"
deployed_commit="$(sudo jq -r '.commit' /srv/ignition-lab/last-successful-dev-config-deployment.json)"

printf 'Develop:  %s\n' "$develop_commit"
printf 'Deployed: %s\n' "$deployed_commit"

test "$develop_commit" = "$deployed_commit"
```

Required: matching commits.

---

## 24. Common failure modes

### Git cannot switch branches because it cannot unlink an image

Symptom:

```text
warning: unable to unlink ... Permission denied
```

Fix:

```bash
sudo ./scripts/provision-git-resource-acls.sh
```

Then restore or remove only the stale conflicting resource and retry the branch switch or pull.

### DEV database is Faulted after enabling Deployment Mode

Check:

- DEV runs with `-Dignition.config.mode=dev`;
- the DEV override points to `ignition_dev` and username `ignition_dev`;
- password type is `Referenced`;
- DEV has a local `CICD_Secrets/LabDatabasePassword` value matching the PostgreSQL role password;
- restart the connection or Gateway once after provisioning the secret.

### Gateway health is green but login returns 503

Wait until `StatusPing` reports `RUNNING` and the login route becomes usable. Docker health may become green before full Gateway readiness.

### Builtin images disappear

Confirm:

- `Builtin` is tracked in Git;
- the full image collection exists in the mounted Git directory;
- Git and DEV image trees match;
- the obsolete ignore rule is absent;
- `*.bak` directories are excluded from deployment.

### DEV deployment reports destination content differences

Run the relevant `rsync -rcni` comparison, identify the managed scope, and ensure the deployment source is complete. Do not manually delete local security or generated resources outside managed scopes.

---

## 25. Rollback strategy

Deployment scripts create backups and restore managed scopes on failure.

Before a large repository rollback:

1. preserve current work on a safety branch or tag;
2. record current `develop` SHA;
3. inspect the commit range;
4. prefer reviewed revert commits over rewriting shared history.

Historical fallback reference:

```text
ff7d35619702e2245edebb3e08d17e8289bf64a9
```

Do not use `git reset --hard` and force-push shared `develop` without explicit approval and a preserved safety reference.

---

## 26. Deferred work after v0.3.0

Do not treat the following as required for recreating `v0.3.0`:

- migration from `core` to `external`;
- same-resource collision testing;
- per-user Gateways;
- complete removal of `/srv/ignition-lab`;
- replacement of the current local referenced-secret model.

A future `core -> external` migration must use complete authoritative collections. Partial nested overlays can hide or delete resources absent from Git.

---

## 27. Completion record

Record the rebuilt environment:

```text
Git tag: v0.3.0
VM name:
VM snapshot:
Ubuntu version:
Docker version:
Ignition version: 8.3.9
TEST URL: http://localhost:9088
DEV URL: http://localhost:9188
Runner service:
Validation date:
Validated by:
```

Take a VM snapshot after all acceptance checks pass.

Suggested snapshot name:

```text
Ignition CI-CD Lab v0.3.0 Rebuilt
```
