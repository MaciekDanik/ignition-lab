# Ignition 8.3 CI/CD Lab - Final Implementation Guide

## Document status

- **Version:** 0.3.0
- **Date:** 2026-10-27
- **Repository:** `MaciekDanik/ignition-lab`
- **Status:** Implemented and validated
- **Scope:** Git-backed TEST authoring, automated DEV deployment, Deployment Modes, shared permissions, complete image collection, and concurrent editing

---

## 1. Purpose

This document describes the implemented Ignition 8.3 development and deployment model used by the lab. The solution provides:

- direct authoring on a shared TEST Gateway;
- Git version control for projects and selected Gateway resources;
- pull-request-based promotion into `develop`;
- automated deployment to DEV through a self-hosted GitHub Actions runner;
- environment-specific configuration through Gateway Deployment Modes;
- referenced secrets whose values remain local to each Gateway;
- shared ACLs for resources written by Ignition UID `2003`;
- controlled concurrent editing by two Designer users;
- deterministic promotion of the complete image collection.

---

## 2. Implemented architecture

```text
Git repository
├── projects/
│   └── CICD_Test
├── config/gateway/resources/
│   ├── core/
│   │   ├── com.inductiveautomation.opcua/device
│   │   └── ignition/
│   │       ├── database-connection
│   │       ├── images
│   │       ├── tag-definition
│   │       ├── tag-group
│   │       ├── tag-provider
│   │       └── tag-type-definition
│   ├── test/
│   └── dev/
├── compose/
├── scripts/
└── .github/workflows/

TEST Gateway
├── projects mounted directly from Git
├── curated core resources mounted directly from Git
├── test and dev Deployment Mode collections mounted from Git
├── active Deployment Mode: test
└── broad runtime configuration retained for local Gateway resources

DEV Gateway
├── projects deployed to services/ignition-dev/projects
├── configuration deployed to services/ignition-dev/config/resources
├── active Deployment Mode: dev
└── receives only approved changes merged into develop
```

DEV runtime targets are ignored by Git. `/srv/ignition-lab` remains an operational location for the fixed release copy, secrets, backups, deployment locks, deployment metadata, and the active Compose environment file.

---

## 3. Normal development workflow

1. Update local `develop`.
2. Create a short-lived feature branch.
3. Open Ignition Designer against TEST on port `9088`.
4. Edit and publish project or Gateway resources.
5. Review filesystem changes with Git.
6. Stage complete Ignition resources, including manifests and generated thumbnails when applicable.
7. Run repository validation.
8. Commit and push.
9. Open a pull request into `develop`.
10. Merge after validation succeeds.
11. GitHub Actions deploys approved project and configuration changes to DEV.
12. Verify DEV on port `9188`.

Example:

```bash
git switch develop
git pull --ff-only origin develop
git switch -c feature/example-change

./scripts/validate-repository.sh
git diff --check

git add <complete-resource-directories>
git commit -m "feat: describe the change"
git push -u origin feature/example-change
```

Recovery extraction scripts under `scripts/recovery/` are not part of the normal workflow.

---

## 4. Deployment Modes

Two Gateway Deployment Modes are implemented.

### TEST mode

- **Mode name:** `test`
- **Startup argument:** `-Dignition.config.mode=test`
- **Database:** `ignition_test`
- **Database role:** `ignition_test`
- **CICD_Simulator interval:** `1000 ms`

### DEV mode

- **Mode name:** `dev`
- **Startup argument:** `-Dignition.config.mode=dev`
- **Database:** `ignition_dev`
- **Database role:** `ignition_dev`
- **CICD_Simulator interval:** `2000 ms`

Both database overrides use the same reference:

```text
Provider: CICD_Secrets
Secret: LabDatabasePassword
```

The reference is versioned. The actual secret value is local to each Gateway:

```text
TEST local value -> password for ignition_test
DEV local value  -> password for ignition_dev
```

Secret values and secret-provider runtime state are not deployed through Git.

---

## 5. Project deployment

Project deployment reads from tracked `projects/` and writes to:

```text
services/ignition-dev/projects
```

The deployment process:

1. acquires a deployment lock;
2. backs up the current DEV target;
3. synchronizes approved files;
4. preserves generated `.resources` content;
5. requests an Ignition project scan;
6. verifies content and Gateway health;
7. restores the backup if validation fails.

Normal project promotion does not require a Gateway restart.

---

## 6. Gateway configuration deployment

Tracked configuration is stored under:

```text
config/gateway/resources
```

Managed core scopes include:

```text
core/com.inductiveautomation.opcua/device
core/ignition/database-connection
core/ignition/images
core/ignition/tag-definition
core/ignition/tag-group
core/ignition/tag-provider
core/ignition/tag-type-definition
```

The complete `test` and `dev` mode collections are also managed.

The config deployment process:

1. acquires a deployment lock;
2. backs up each managed scope;
3. verifies that the `actions` user can create and remove files;
4. synchronizes managed scopes;
5. excludes `.resources`, `System`, and temporary `*.bak` directories;
6. requests an Ignition configuration scan;
7. verifies content and Gateway health;
8. rolls back on failure.

Normal configuration promotion does not require a Gateway restart. A restart is required when changing the JVM-selected Deployment Mode.

---

## 7. Image collection ownership

The implementation uses a whole-folder authoritative model for:

```text
config/gateway/resources/core/ignition/images
```

Git contains the complete collection:

- `Builtin`: 704 files;
- custom image resources: 4 files in the validated baseline;
- total validated baseline: 708 files.

This is required because TEST mounts the complete images directory and DEV deploys the complete scope with `rsync --delete`. The complete `Builtin` tree must remain tracked. Do not restore this ignore rule:

```gitignore
**/ignition/images/Builtin/
```

Temporary Ignition backup directories matching `*.bak/` are excluded from deployment.

When a new image is added in TEST Designer:

1. Ignition writes the resource into the Git-mounted image folder;
2. Git detects the image file and `resource.json`;
3. the complete resource directory is committed;
4. after merge, DEV receives the image through the managed image scope.

Deleting a tracked image and merging that deletion also deletes it from DEV.

---

## 8. Shared filesystem permissions

Ignition writes mounted resources as UID `2003`. The self-hosted GitHub Actions runner uses Linux user `actions`, while interactive Git work uses `masiek`.

The repository includes:

```text
scripts/provision-git-resource-acls.sh
```

The script provisions current and default ACLs for the Git-backed image tree so all three identities can create, modify, and delete resources:

```text
masiek
Linux user actions
Ignition UID 2003
```

Run after cloning, restoring, replacing resource directories, or losing filesystem ACLs:

```bash
sudo ./scripts/provision-git-resource-acls.sh
```

The tested result is that an image created by UID `2003` can be committed on a feature branch and removed cleanly by Git when switching to `develop`.

---

## 9. Concurrent two-user editing

A shared TEST Gateway was tested with two independent Designer users.

### Verified behavior

- User `admin` modified `AfterView`.
- User `designer` modified `BeforeView`.
- Both complete Perspective resources were written: `view.json`, `resource.json`, and `thumbnail.png`.
- Two different tag documentation changes were persisted.
- Two different image resources were created.
- New image directories inherited ACLs for `masiek`, `actions`, and UID `2003`.
- TEST remained running and did not restart.

### Not verified

Same-resource collision behavior was not conclusively tested for:

- the same Perspective view;
- the same tag resource;
- the same image resource.

### Operating rule

Multiple users may edit different resources concurrently on the shared TEST Gateway. Only one user should actively edit a specific view, tag resource, or image at a time. Resource ownership should be coordinated before editing to avoid last-write-wins overwrites.

The branch `test/two-user-editing` and its draft PR may be retained as evidence but should not be merged because it contains disposable test content.

---

## 10. Validation and acceptance checks

### Repository

```bash
git switch develop
git pull --ff-only origin develop
./scripts/validate-repository.sh
git diff --check
git status --short
```

Acceptance:

- validation passes;
- no whitespace errors;
- clean working tree.

### Gateway health

```bash
curl -fsS http://localhost:9088/StatusPing
echo
curl -fsS http://localhost:9188/StatusPing
echo
```

Expected:

```json
{"state":"RUNNING"}
```

### Active modes

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
ignition-test -> test
ignition-dev  -> dev
```

### Images

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

### Runner

```bash
sudo systemctl is-active \
  actions.runner.MaciekDanik-ignition-lab.Ubuntu-VM.service
```

Expected:

```text
active
```

---

## 11. Rollback

Configuration and project deployment scripts create backups before modifying DEV. Their rollback logic restores the previous managed content when deployment validation fails.

Before any large Git rollback, preserve current work on a safety branch or tag. The known historical fallback commit is:

```text
ff7d35619702e2245edebb3e08d17e8289bf64a9
```

Do not use a destructive force-push or hard reset on shared `develop` without first preserving the current state and reviewing the commit range. Prefer a reviewed revert commit for shared history.

---

## 12. Deferred work

The following work is intentionally deferred:

- migrating managed resources from `core` to `external`;
- testing same-resource editing collisions;
- moving all remaining operational `/srv/ignition-lab` responsibilities;
- replacing the current local referenced-secret approach;
- introducing per-user Gateways.

A future `core -> external` migration must treat each selected collection as a complete authoritative dataset. Partial nested overlays must not be used because they can hide or delete resources absent from Git.

---

## 13. Definition of done

The implementation is accepted when:

- TEST and DEV are healthy;
- project and configuration promotion succeeds;
- TEST uses mode `test` and DEV uses mode `dev`;
- TEST and DEV database connections are valid against their own databases;
- simulator overrides resolve to `1000 ms` and `2000 ms` respectively;
- the complete image collection is tracked and synchronized;
- new image resources can be created and branch-switched without permission errors;
- two users can edit different resources concurrently;
- repository validation passes;
- documentation, tag, release, and VM snapshot are complete.
