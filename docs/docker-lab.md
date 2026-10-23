# Ignition CI/CD Lab

Concise operating guide for the completed v0.2.0 architecture. The detailed
runbook is [`docs-v0.2.0.md`](./docs-v0.2.0.md).

## Gateways

| Gateway | URL | Role |
|---|---|---|
| TEST | `http://localhost:9088` | Live authoring and review |
| DEV | `http://localhost:9188` | Automated integration target |

Both Gateways run from [`compose/compose.yml`](../compose/compose.yml).

## Mount model

TEST mounts tracked `projects/` directly and mounts the selected Gateway
scopes directly from `config/gateway/resources/core`. It also retains a broad
`runtime/test/config/resources` fallback while curated mounts are being
completed.

DEV mounts ignored deployment targets:

```text
services/ignition-dev/projects
services/ignition-dev/config/resources
```

Only merged `develop` changes deployed by GitHub Actions populate DEV.
Filesystem deployments request project and configuration scans and normally do
not restart the Gateway.

Managed Gateway scopes are:

```text
device
tag-provider
tag-group
tag-definition
tag-type-definition
database-connection
images
```

System resources, `.resources`, local resources, identity providers, secret
providers, user sources, UUIDs, and keystores remain local or generated and
are not tracked. `config/deployable` is retired.

## Normal workflow

```text
branch → edit running TEST → Git review → validation
→ commit/PR → merge to develop → automatic DEV deployment and scan
```

Do not use extraction as the normal path. The scripts under
[`scripts/recovery/`](../scripts/recovery/) are recovery/import tools only.

Validate locally:

```bash
./scripts/validate-repository.sh
docker compose --env-file .env -f compose/compose.yml config
```

Check Gateway health:

```bash
curl -fsS http://localhost:9088/StatusPing
curl -fsS http://localhost:9188/StatusPing
```

## Host operations

`/srv/ignition-lab` remains active for release staging, secrets, backups,
deployment locks, metadata, and the active Compose environment. Do not commit
`.env`, secrets, runtime state, deployment targets, build output, or backups.

Future work includes external collection, Deployment Modes, environment
overrides, and multi-user development design.
