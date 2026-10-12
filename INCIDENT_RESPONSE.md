# MicuPoker incident response

This runbook covers application compromise, credential exposure, database
tampering, release drift, availability loss and failed backups. It supplements
the host-wide response process; it does not authorize automatic destruction or
restoration of production data.

## Detection and targets

The micupoker-healthcheck timer checks the public and local health endpoints,
runtime identity, release manifest, restart rate and backup job every five
minutes. The application, migration, backup and healthcheck units route failures
to the host's independent e-mail alert handler. Target MTTD is six minutes and
target containment is 60 minutes after a confirmed high-severity alert.

Treat unexpected release-integrity or runtime-identity drift, unauthorized
database changes, credential disclosure, or successful account abuse as high
severity. A healthcheck or backup failure is medium severity until evidence
shows compromise or sustained data unavailability.

## Triage and containment

1. Record UTC time, alert text and the affected unit. Preserve the relevant
   journal and Nginx access/error logs before restarting anything.
2. Confirm the immutable release target and manifest with the installed
   verify_release script.
3. Inspect unit status, restart count, process identity and loopback/public
   health. Do not paste credentials or user data into tickets or chat.
4. If active exploitation is credible, deny public ingress at Nginx or
   Cloudflare while retaining local access for evidence. Stop the application
   only when continued execution risks more damage.
5. Preserve the newest pre-incident database dump and checksum. Never restore
   over production during triage.

## Eradication and recovery

- Rotate the affected micupoker_app, micupoker_migrate and micupoker_backup
  credentials separately. Rotate SECRET_KEY_BASE when sessions may be
  compromised and the dashboard password when admin access is in scope.
- Build from a reviewed commit, verify the root-owned release manifest and use
  the atomic deployment path. Do not execute a checkout as the service user.
- Prove a candidate backup with verify_postgres_backup.sh; it restores only
  into a uniquely named scratch database under a temporary unprivileged role.
  A production restore is a separate, operator-approved recovery action.
- Run the full deploy probe, strict database privilege audit and a fresh backup
  after recovery. Monitor closely for at least one hour.

## Evidence, notification and vendors

The database can contain usernames, e-mail addresses, password hashes, room
password hashes, play-money history and authentication tokens. Determine the
affected user count from a preserved snapshot. If a personal-data breach is
likely, start the GDPR assessment immediately; the supervisory-authority window
can be 72 hours after awareness. Preserve an incident timeline and prepare a
plain-language user notice, but involve the owner/legal decision maker before
external notification.

Relevant dependencies are Cloudflare (DNS/proxy/tunnel), Resend (operator
alerts), GitHub plus Hex/npm release sources (build supply chain), and local
PostgreSQL. Record provider status, credential identity and the last reviewed
security evidence. The alert path and this runbook require a tabletop exercise;
until that is recorded, response readiness remains partially unverified.
