# Ignition 8.3 CI/CD Architecture v0.2.0

## 1. Purpose and status

This repository is a research CI/CD environment for Ignition 8.3. It promotes
Git-managed projects and selected Gateway resources from TEST to DEV with Git,
GitHub Actions, Docker, filesystem synchronization, and Ignition Gateway scan
APIs.

The completed `v0.2.0` architecture has:

- Docker TEST on `http://localhost:9088`;
- Docker DEV on `http://localhost:9188`;
- PostgreSQL on the private Docker network;
- GitHub Actions validation for pull requests and pushes;
- automatic DEV deployment after a merge to `develop`;
- separate project and Gateway-resource backups, locks, scans, and rollback;
- direct Git-backed authoring mounts in TEST and isolated deployment targets in
  DEV.

This remains a research and development environment, not a production
high-availability architecture.

## 2. Architecture

```text
Windows host
└── VirtualBox Ubuntu VM
    ├── Git working tree
    │   └── /home/masiek/ignition-lab/ignition-lab
    ├── Docker
    │   ├── ignition-test  (host port 9088)
    │   ├── ignition-dev   (host port 9188)
    │   └── ignition-postgres
    ├── /srv/ignition-lab
    │   ├── release/       fixed deployment checkout
    │   ├── runtime/       TEST transition fallback and runtime state
    │   ├── secrets/
    │   ├── backups/
    │   ├── locks and deployment metadata
    │   └── .env
    └── GitHub Actions self-hosted runner
```

The active Compose environment, release staging, secrets, backups, locks, and
deployment metadata continue to use `/srv/ignition-lab`. The developer
checkout is the source for local TEST authoring; the self-hosted runner stages
the approved `develop` checkout under `/srv/ignition-lab/release` before
deploying DEV.

## 3. Compose mounts and environment boundaries

The authoritative definition is
[`compose/compose.yml`](../compose/compose.yml).

### TEST

TEST is the authoring Gateway. It mounts:

- tracked `projects/` directly at the Ignition projects path;
- selected Gateway resources directly from
  `config/gateway/resources/core`;
- the local TEST password file;
- a named volume for Gateway runtime state.

The selected managed scopes are:

```text
core/com.inductiveautomation.opcua/device
core/ignition/tag-provider
core/ignition/tag-group
core/ignition/tag-definition
core/ignition/tag-type-definition
core/ignition/database-connection
core/ignition/images
```

TEST still has a broad `runtime/test/config/resources` mount as a transition
fallback. It supports resources that have not yet moved into the curated
direct-mount model. It must not be mistaken for the normal source of tracked
projects or managed Gateway scopes.

### DEV

DEV is the deployment and integration Gateway. It mounts only ignored local
targets:

```text
services/ignition-dev/projects
services/ignition-dev/config/resources
```

The `services/ignition-dev/` tree is populated by deployment automation and is
not a second Git source tree. DEV receives approved, merged `develop` content
through GitHub Actions; routine authoring must not be performed there.

TEST and DEV use separate named data volumes, password files, project/config
targets, and host ports.

## 4. Source policy

### Tracked source

```text
projects/
config/gateway/resources/core/
```

The project tree contains Ignition project resources. The Gateway tree
contains only the explicitly managed scopes listed above.

### Not tracked

The following remain Gateway-local or generated and are not promoted by this
architecture:

- `System` resources;
- `.resources` metadata;
- local resources;
- identity providers;
- secret providers;
- user sources;
- generated UUIDs;
- keystores and certificates;
- runtime state, credentials, logs, caches, and backups.

The `.gitignore` and
[`scripts/validate-repository.sh`](../scripts/validate-repository.sh) enforce
the relevant local/runtime and generated-file boundaries. `config/deployable`
is retired and must not be recreated or documented as an active source.

## 5. Normal workflow

```text
branch
  → edit the running TEST Gateway
  → review the Git changes
  → run validation
  → commit and open/update a PR
  → merge to develop
  → GitHub Actions validates the merged commit
  → GitHub Actions deploys projects and managed Gateway scopes to DEV
  → DEV performs filesystem scans and is verified healthy
```

The normal workflow does not extract TEST into Git. TEST projects and the
curated Gateway resources are already mounted from Git, so edits are reviewed
in the working tree while TEST is running.

Useful local validation:

```bash
./scripts/validate-repository.sh
docker compose --env-file .env -f compose/compose.yml config
```

The validation workflow also packages project resources for verification.

## 6. GitHub Actions and DEV deployment

[`validate.yml`](../.github/workflows/validate.yml) validates pull requests
targeting `develop` or `master`, and pushes to `develop` and feature branches.
It checks repository structure, shell and JSON syntax, project structure,
forbidden tracked files, ignore rules, Compose rendering, password guardrails,
and project packaging.

[`deploy-dev.yml`](../.github/workflows/deploy-dev.yml) runs only after a push
to `develop`. It:

1. checks out the merged `develop` commit;
2. validates and packages the exact source revision;
3. stages that revision in `/srv/ignition-lab/release`;
4. deploys projects to `services/ignition-dev/projects`;
5. deploys managed Gateway scopes to
   `services/ignition-dev/config/resources`;
6. verifies DEV and TEST health and records deployment metadata.

### Project deployment

[`scripts/deploy-dev.sh`](../scripts/deploy-dev.sh) backs up DEV projects,
uses a deployment lock, synchronizes the Git project tree with `rsync`, and
requests:

```text
POST http://localhost:9188/data/api/v1/scan/projects
```

The normal `DEPLOY_MODE=scan` path verifies that the DEV container ID and
start time do not change. It therefore does not normally restart DEV.
`DEPLOY_MODE=restart` remains an explicit exceptional/recovery mode.

### Gateway-resource deployment

[`scripts/deploy-dev-config.sh`](../scripts/deploy-dev-config.sh) backs up
each managed scope, synchronizes only the listed scopes, excludes generated
`.resources` and `System` content, and requests:

```text
POST http://localhost:9188/data/api/v1/scan/config
```

It verifies filesystem content and Gateway health after the scan. It does not
normally restart DEV.

Project and configuration deployments have independent locks and backup
trees:

```text
/srv/ignition-lab/backups/dev/
/srv/ignition-lab/backups/dev-config/
```

## 7. Recovery and rollback

The deployment scripts keep backups before changing DEV and restore them if a
deployment or scan verification fails. Deployment records and lock files are
kept under `/srv/ignition-lab`.

[`scripts/recovery/extract-test-projects.sh`](../scripts/recovery/extract-test-projects.sh)
and
[`scripts/recovery/extract-test-config.sh`](../scripts/recovery/extract-test-config.sh)
are recovery/import utilities only. They can recover or import settled TEST
content after an incident or migration, but they are not part of the normal
branch-to-DEV workflow.

## 8. Operational checks

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
curl -fsS http://localhost:9088/StatusPing
curl -fsS http://localhost:9188/StatusPing
```

Expected Gateway response:

```json
{"state":"RUNNING"}
```

Inspect the effective mounts with:

```bash
docker inspect ignition-test ignition-dev \
  --format '{{.Name}}{{range .Mounts}}{{println " " .Source "->" .Destination}}{{end}}'
```

## 9. Current limitations and future work

TEST’s broad runtime configuration mount remains during the curated-mount
transition. The following are future architecture work rather than active
v0.2.0 behavior:

- external collection design;
- Deployment Modes;
- environment-specific overrides;
- multi-user development design.

Other known limitations include no Gateway redundancy, no PostgreSQL
replication, and no guarantee that a successful filesystem scan means every
device, view, Named Query, tag, image, or database interaction is functional.
