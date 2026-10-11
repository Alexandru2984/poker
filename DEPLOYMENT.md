# MicuPoker production deployment

Production runs a root-owned release under the non-login `micupoker` identity.
The interactive checkout is build input only and is hidden from the service.

## Filesystem contract

- `/opt/micupoker/releases/<commit>-<timestamp>`: immutable releases.
- `/opt/micupoker/current`: atomically switched release symlink.
- `/etc/micupoker/app.env`: root-owned, non-secret runtime settings.
- `/etc/micupoker/credentials/`: root-owned database, signing and dashboard
  credentials consumed through systemd `LoadCredential`.
- `/var/lib/micupoker`: crash diagnostics only; game state remains PostgreSQL.
- `/home/micu/backups/service-migrations/micupoker-deploy-*`: unit and previous
  release pointers needed for rollback.

`app.env` must not contain `DATABASE_URL`, `SECRET_KEY_BASE` or
`ADMIN_PASSWORD`. Their `_FILE` variables are injected by the unit and point at
the private systemd credential directory.

## Gates and deployment

```bash
./scripts/deploy.sh --build-only
./scripts/deploy.sh
```

The full path builds from a detached worktree at the exact committed revision,
runs all tests and audits, installs a checksummed root-owned release, takes a
database backup when the backup unit is installed, runs migrations with the
separate migration credential, switches the symlink atomically and runs public,
origin and WebSocket probes. A failure after the switch restores the previous
release. The first rollout additionally preserves and restores the legacy unit.

Deployments require a clean `main` worktree. `/etc/micupoker/build.env` should
contain only `TEST_DATABASE_URL`; the production database credential is never
available to the build process.

## Manual rollback

Inspect the recorded previous release first, then switch atomically:

```bash
sudo cat /home/micu/backups/service-migrations/micupoker-deploy-*/previous-release
sudo ln -s /opt/micupoker/releases/KNOWN_GOOD /opt/micupoker/.rollback
sudo mv -Tf /opt/micupoker/.rollback /opt/micupoker/current
sudo systemctl restart micupoker.service
./scripts/deploy_check.sh
```

Database migrations must remain backward-compatible with the prior release.
The release rollback does not reverse schema or data changes; use the verified
pre-deploy backup only as an incident-recovery decision, never automatically.
