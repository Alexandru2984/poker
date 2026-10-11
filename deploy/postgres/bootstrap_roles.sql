\set ON_ERROR_STOP on

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'micupoker_migrate') THEN
    CREATE ROLE micupoker_migrate NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'micupoker_app') THEN
    CREATE ROLE micupoker_app NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'micupoker_backup') THEN
    CREATE ROLE micupoker_backup NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
  END IF;
END
$roles$;

ALTER ROLE micupoker_migrate NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE micupoker_app NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
ALTER ROLE micupoker_backup NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;

ALTER DATABASE micupoker OWNER TO micupoker_migrate;
\connect micupoker
REASSIGN OWNED BY micupoker_user TO micupoker_migrate;
ALTER SCHEMA public OWNER TO micupoker_migrate;

\ir runtime_privileges.sql

-- Temporary rollback bridge for the first rollout. Remove it with
-- retire_legacy_role.sql only after the dedicated runtime is healthy.
GRANT CONNECT ON DATABASE micupoker TO micupoker_user;
GRANT USAGE ON SCHEMA public TO micupoker_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO micupoker_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO micupoker_user;
