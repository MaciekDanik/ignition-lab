# Ignition CI/CD Lab v0.3.0

## Highlights

- Added TEST and DEV Gateway Deployment Modes.
- Added environment-specific PostgreSQL database overrides.
- Added mode-specific `CICD_Simulator` intervals.
- Retained Gateway-local secret values through referenced `CICD_Secrets/LabDatabasePassword` configuration.
- Versioned and deployed the complete Gateway image collection, including 704 Builtin files.
- Added `*.bak` deployment exclusions.
- Added shared ACL provisioning for `masiek`, `actions`, and Ignition UID `2003`.
- Verified Git branch switching for Ignition-created image resources.
- Verified concurrent editing by two Designer users on different project, tag, and image resources.
- Confirmed TEST remains online without restart during concurrent editing.

## Environment behavior

```text
TEST
- Deployment Mode: test
- Database: ignition_test
- Database role: ignition_test
- CICD_Simulator: 1000 ms

DEV
- Deployment Mode: dev
- Database: ignition_dev
- Database role: ignition_dev
- CICD_Simulator: 2000 ms
```

## Important operating rules

- Secret references are versioned; secret values remain local to each Gateway.
- Git owns the complete `core/ignition/images` collection.
- Run `sudo ./scripts/provision-git-resource-acls.sh` after clone, restore, or ACL loss.
- Multiple users may edit different resources concurrently.
- Use one active editor per individual view, tag resource, or image.
- The `core -> external` migration remains deferred.

## Validation

- Repository validation passed.
- TEST and DEV reached `RUNNING`.
- DEV deployment commit matched `origin/develop`.
- Database connections were valid in both modes.
- Mode-specific simulator overrides were visible.
- Complete image deployment was restored.
- Two-user different-resource editing passed.
