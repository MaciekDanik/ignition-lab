# Ignition 8.3 CI/CD Research Lab

## 1. Purpose

This repository contains a working CI/CD research environment for Inductive Automation Ignition 8.3. It demonstrates controlled promotion of Ignition projects and selected Gateway resources from a TEST Gateway to a DEV Gateway using Git, GitHub Actions, Docker, filesystem-backed Ignition resources, and Gateway scan APIs.

The current stable baseline is tagged:

```text
v0.1.0
```

The corresponding VirtualBox snapshot is:

```text
Ignition CI-CD Lab v0.1.0
```

This is a research and development environment. It is not a production high-availability architecture.

---

## 2. System Overview

```text
Windows host
├── Visual Studio Code
│   └── Remote SSH to Ubuntu through 127.0.0.1:2222
│
└── VirtualBox Ubuntu VM
    ├── Docker
    │   ├── ignition-test
    │   ├── ignition-dev
    │   └── ignition-postgres
    │
    ├── Git working tree
    │   └── /home/masiek/ignition-lab/ignition-lab
    │
    ├── Fixed deployment root
    │   └── /srv/ignition-lab
    │
    └── GitHub Actions self-hosted runner
        └── /opt/actions-runner
```

### Environments

| Environment | Purpose | Address inside Ubuntu | Authoring policy |
|---|---|---|---|
| TEST | Designer development and Gateway resource authoring | `http://localhost:9088` | Editable |
| DEV | Automated integration deployment target | `http://localhost:9188` | Deployment-only |
| PostgreSQL | Lab database service | `ignition-postgres:5432` | Managed through Compose |

Access from Windows is provided through VS Code Remote SSH port forwarding.

---

## 3. Technology Stack

- Ubuntu VM on VirtualBox
- Docker Engine and Docker Compose
- Ignition 8.3.9 Standard Edition
- PostgreSQL 16
- Git and GitHub
- GitHub-hosted runner for validation
- Repository-level Ubuntu self-hosted runner for DEV deployment
- Bash, `rsync`, `jq`, `curl`, `setfacl`, and Docker CLI

---

## 4. Repository Structure

```text
.github/workflows/
├── validate.yml
└── deploy-dev.yml

compose/
├── compose.yml
└── postgres-init/

config/
├── deployable/              # Git-managed Gateway resources
└── resources/               # Curated source configuration

projects/
└── CICD_Test/

scripts/
├── validate-repository.sh
├── package-projects.sh
├── extract-test-projects.sh
├── extract-test-config.sh
├── deploy-dev.sh
├── deploy-dev-config.sh
├── sync-test-runtime.sh
└── sync-dev-runtime.sh

docs/
```

Runtime data, secrets, deployment state, and build outputs are intentionally excluded from Git.

---

## 5. Runtime Layout

```text
/srv/ignition-lab/
├── release/                     # Repository revision used for deployment
├── runtime/
│   ├── test/
│   │   ├── projects/
│   │   └── config/resources/
│   └── dev/
│       ├── projects/
│       └── config/resources/
├── secrets/                     # Local passwords and API token
├── backups/
│   ├── dev/                     # Project deployment backups
│   └── dev-config/              # Gateway configuration backups
├── .env
├── last-successful-dev-deployment.json
└── last-successful-dev-config-deployment.json
```

The running containers use bind mounts below `/srv/ignition-lab`. DEV does not use the developer working tree under `/home/masiek`.

---

## 6. Docker Services

### ignition-test

- Host port: `9088`
- Container port: `8088`
- Named volume: `ignition-test-data`
- Project runtime: `/srv/ignition-lab/runtime/test/projects`
- Config runtime: `/srv/ignition-lab/runtime/test/config/resources`
- Maximum memory configured for the container: approximately 2.2 GB

### ignition-dev

- Host port: `9188`
- Container port: `8088`
- Named volume: `ignition-dev-data`
- Project runtime: `/srv/ignition-lab/runtime/dev/projects`
- Config runtime: `/srv/ignition-lab/runtime/dev/config/resources`
- Maximum memory configured for the container: approximately 2.2 GB

### ignition-postgres

- Docker service hostname: `ignition-postgres`
- Internal port: `5432`
- Persistent named volume: `ignition-postgres-data`
- Separate TEST and DEV databases and users

```text
TEST database: ignition_test
TEST user:     ignition_test

DEV database:  ignition_dev
DEV user:      ignition_dev
```

Database ports are not exposed outside the Docker network.

---

## 7. Branching and Promotion Model

```text
feature/* or test/*
        |
        v
     develop
        |
        v
       DEV

Stable promotion:

develop -> master -> annotated Git tag
```

### Branch roles

- `feature/*`: normal feature and infrastructure work
- `test/*`: controlled end-to-end promotion tests
- `develop`: validated integration branch and automatic DEV deployment source
- `master`: stable release milestones
- `backup/before-cicd-lab`: historical recovery reference

Pull requests should normally target `develop`. Stable releases are promoted from `develop` to `master` through a reviewed pull request.

---

## 8. CI/CD Pipeline

### Pull-request validation

The validation workflow runs on a GitHub-hosted runner and checks:

- required repository structure;
- shell syntax;
- JSON syntax;
- project structure;
- forbidden tracked files;
- required `.gitignore` rules;
- Docker Compose rendering;
- literal password guardrails;
- packaging of project resources.

### DEV deployment

A successful merge to `develop` triggers the self-hosted runner.

```text
Checkout merged develop revision
→ validate source
→ update /srv/ignition-lab/release
→ deploy project resources
→ request /data/api/v1/scan/projects
→ verify DEV health and no restart
→ deploy managed Gateway resources
→ request /data/api/v1/scan/config
→ verify DEV health and managed filesystem content
→ record deployment metadata
```

Project and Gateway configuration deployments use separate backups and locks.

---

## 9. Managed Project Resources

Project resources are stored under:

```text
projects/
```

This includes:

- Perspective views and resources;
- project script libraries;
- Gateway event scripts stored in the project;
- Perspective and component event scripts;
- message handlers;
- Named Queries;
- project properties and settings.

Named Queries and project scripts do not require separate Gateway configuration deployment because they are part of the project resource tree.

---

## 10. Managed Gateway Resources

Git-managed Gateway resources are stored under:

```text
config/deployable/
```

Current managed scopes include:

```text
core/com.inductiveautomation.opcua/device
core/ignition/tag-provider
core/ignition/tag-group
core/ignition/tag-definition
core/ignition/tag-type-definition
core/ignition/database-connection
core/ignition/images
```

These scopes cover:

- OPC UA device connections;
- Standard Tag Provider definitions;
- Tag Groups;
- atomic tags and folders;
- UDT instances;
- UDT definitions;
- database connection definitions;
- Gateway images.

### System resource exclusion

The Ignition-managed `System` Tag Provider is explicitly excluded from:

- extraction;
- deployment;
- backup;
- rollback;
- ACL changes;
- filesystem comparison.

The pipeline must never copy, delete, or modify:

```text
core/ignition/tag-definition/System
```

---

## 11. Current Authoring and Promotion Workflow

The current `v0.1.0` baseline uses an extraction model.

### Project changes

```text
Create feature branch
→ edit and publish in TEST Designer
→ stop TEST
→ extract TEST project resources into projects/
→ restart TEST
→ review Git diff
→ validate
→ commit and push
→ PR into develop
→ merge
→ automatic DEV project deployment
```

### Gateway configuration changes

```text
Create feature branch
→ edit Gateway resources on TEST
→ run extract-test-config.sh
→ review config/deployable diff
→ validate
→ commit and push
→ PR into develop
→ merge
→ automatic DEV config deployment and scan
```

The extraction script requires `config/deployable` to be clean before it runs. This prevents uncommitted Git changes from being overwritten by TEST runtime state.

---

## 12. Deployment Safety Controls

### Project deployment

- DEV project backup before synchronization
- serialized deployment lock
- checksum/content comparison
- `/scan/projects` request
- DEV health verification
- container ID and start-time verification
- automatic rollback and rescan
- restart fallback retained for exceptional failure

### Gateway configuration deployment

- per-scope DEV backup
- serialized deployment lock
- JSON validation
- content synchronization with generated resources excluded
- `/scan/config` request
- DEV health verification
- checksum/content comparison
- automatic rollback and rescan
- nonfatal old-backup pruning

### Backup retention

The deployment scripts retain the ten newest project and configuration backups. Cleanup failure must generate a warning rather than fail an otherwise successful deployment.

---

## 13. Secrets and Security Boundaries

The following must never be committed:

```text
.env
runtime/
secrets/
build/
deploy/
```

Local secret files include:

```text
/srv/ignition-lab/secrets/test_gateway_admin_password.txt
/srv/ignition-lab/secrets/dev_gateway_admin_password.txt
/srv/ignition-lab/secrets/dev_gateway_api_token.txt
/srv/ignition-lab/secrets/postgres_admin_password.txt
/srv/ignition-lab/secrets/postgres_test_password.txt
/srv/ignition-lab/secrets/postgres_dev_password.txt
```

The DEV deployment API key is used locally by the self-hosted runner and has permission to request project and configuration filesystem scans.

Database connection passwords use Ignition Referenced Secrets. The connection resource can be versioned, while the actual password value remains environment-local.

The self-hosted runner has Docker access and therefore effectively has root-level control of the VM. It must only run trusted deployment jobs from the private repository and must not execute unreviewed pull-request code.

---

## 14. Environment-Specific Configuration

The current baseline promotes Gateway resources from TEST to DEV without environment-specific overrides.

This is visible in the PostgreSQL experiment:

```text
TEST connection URL: jdbc:postgresql://ignition-postgres:5432/ignition_test
TEST username:       ignition_test
```

The same resource reaches DEV unchanged. DEV can therefore display the connection resource while the connection remains faulted if its local referenced secret contains the DEV password.

This behavior is expected in `v0.1.0` and demonstrates the requirement for Deployment Modes.

The planned solution is:

```text
Shared definition
├── connection name
├── JDBC driver
├── common pool settings
└── referenced secret name

TEST override
├── ignition_test database
└── ignition_test username

DEV override
├── ignition_dev database
└── ignition_dev username
```

---

## 15. Resources Kept Local

The following resources are intentionally not promoted through the current pipeline:

- secret values and secret-provider state;
- API keys;
- users, user sources, and identity providers;
- password hashes and authentication policies;
- certificates, PKI, and trust stores;
- Gateway identity and host-local system properties;
- licensing;
- OPC UA security material;
- generated System tags;
- migration logs and `.resources` metadata;
- runtime logs and caches.

---

## 16. Operational Verification

### Container health

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

### Gateway state

```bash
for container in ignition-test ignition-dev; do
  docker inspect "$container" \
    --format '{{.Name}} Status={{.State.Status}} Health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} OOMKilled={{.State.OOMKilled}}'
done
```

### Status endpoints

```bash
curl -fsS http://localhost:9088/StatusPing
echo
curl -fsS http://localhost:9188/StatusPing
echo
```

Expected response:

```json
{"state":"RUNNING"}
```

### Deployment records

```bash
sudo jq . /srv/ignition-lab/last-successful-dev-deployment.json
sudo jq . /srv/ignition-lab/last-successful-dev-config-deployment.json
```

### Active project mounts

```bash
for container in ignition-test ignition-dev; do
  docker inspect "$container" \
    --format '{{range .Mounts}}{{if eq .Destination "/usr/local/bin/ignition/data/projects"}}{{println .Source "->" .Destination}}{{end}}{{end}}'
done
```

---

## 17. Known Limitations

### Extraction-based TEST workflow

TEST projects and managed Gateway configuration are currently stored in runtime directories below `/srv`. Changes must be extracted into Git before commit.

### TEST project downtime during extraction

Project extraction currently stops TEST to provide a stable filesystem snapshot.

### Environment overrides are not implemented

Database URLs, usernames, physical device addresses, and other environment-specific properties are not yet modeled through Deployment Modes.

### DEV connection validity can differ from deployment success

A database or device resource can deploy successfully but remain faulted because its endpoint or local credential does not match DEV.

### StatusPing is not a functional smoke test

`StatusPing` confirms that the Gateway process is running. It does not prove that every view, Named Query, tag, device, image, or database interaction works.

### No high availability

The environment has one DEV Gateway and one PostgreSQL container. It does not provide Ignition redundancy, PostgreSQL replication, rolling upgrades, or production-grade HA.

### Infrastructure changes are not fully automated

Compose changes may require a deliberate `docker compose up -d` or service recreation after the repository deployment is merged.

---

## 18. Planned Architecture Evolution

### v0.2.0: Git-backed TEST

Target outcomes:

- mount Git-controlled `projects/` directly into TEST;
- keep TEST running during Designer work;
- remove routine project extraction;
- introduce a Git-backed Gateway configuration tree;
- retain DEV isolation under `/srv`;
- keep extraction scripts only as migration or recovery tools.

### v0.3.0: Deployment Modes

Target outcomes:

- place centrally managed resources in the `external` collection;
- add TEST and DEV deployment-mode collections;
- use environment-specific overrides for database connections and device endpoints;
- retain host-specific values in `local`;
- keep referenced secret values local to each Gateway.

---

## 19. Recovery Model

### Source recovery

```text
Git tag: v0.1.0
Stable branch: master
Integration branch: develop
```

### Runtime recovery

```text
VirtualBox snapshot: Ignition CI-CD Lab v0.1.0
```

The Git tag preserves repository state. The VM snapshot preserves commissioned Gateway state, Docker volumes, PostgreSQL data, local secrets, API keys, and runner registration.

### Deployment recovery

Project and Gateway configuration deployments keep independent backups below:

```text
/srv/ignition-lab/backups/dev
/srv/ignition-lab/backups/dev-config
```

Failed deployments restore the previous managed state and request another filesystem scan.

---

## 20. Current Success Criteria

The baseline is healthy when:

- TEST and DEV containers are running and healthy;
- both report `OOMKilled=false`;
- PostgreSQL is healthy;
- TEST and DEV use `/srv/ignition-lab` runtime mounts;
- pull-request validation passes;
- merges to `develop` deploy automatically to DEV;
- DEV project deployment succeeds without restart;
- DEV configuration deployment succeeds without restart;
- devices, providers, tags, UDTs, database definitions, images, scripts, and Named Queries are promoted;
- generated System tags remain untouched;
- backups and rollback work;
- deployment metadata records the merged commit;
- runtime data and secrets remain outside Git.
