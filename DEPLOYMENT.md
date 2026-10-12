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

Deployments require a clean `main` worktree. `/etc/micupoker-build.env` must
contain only `TEST_DATABASE_URL`; there is deliberately no fallback to the
checkout `.env`, so production credentials are never available to the build
process.

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

## Database roles

`micupoker_migrate` owns the database, schema and objects. `micupoker_app` has
only table DML and sequence usage, with no access to `schema_migrations`.
`micupoker_backup` can only read. The first transition deliberately grants the
legacy `micupoker_user` a temporary DML bridge so the old unit remains a valid
rollback target. After the new runtime passes all probes:

```bash
sudo -u postgres psql -X -v ON_ERROR_STOP=1 \
  -f deploy/postgres/retire_legacy_role.sql
./scripts/check_database_privileges.sh
```

## Backups

`micupoker-backup.timer` creates a custom-format, checksummed PostgreSQL dump
each day under `/var/backups/micupoker` as the non-login `micupoker-backup`
identity. The role cannot write production data and the unit can only reach
localhost and its backup directory. The directory uses mode `0710`; the monitor
can stat the fixed success marker but cannot list or read backup artifacts.
Restore drills never target production:

```bash
sudo /opt/micupoker/current/ops/verify_postgres_backup.sh \
  /var/backups/micupoker/micupoker_TIMESTAMP.dump
```

The verifier requires safe ownership and mode, validates the checksum and
archive, restores into a uniquely named scratch database, checks schema/data
counts and ledger invariants, and drops the scratch database on exit.

## Detection and response

The micupoker-healthcheck timer runs every five minutes and checks both health
paths, the dedicated runtime identity, restart rate, release integrity and the
latest backup result and age. Unit and probe failures invoke the host's
independent e-mail alert handler. See INCIDENT_RESPONSE.md for containment,
evidence, credential rotation and recovery procedures.
