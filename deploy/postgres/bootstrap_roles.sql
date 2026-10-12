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
ALTER SCHEMA public OWNER TO micupoker_migrate;

-- REASSIGN OWNED also changes shared objects, including every database owned by
-- the legacy role. Transfer only MicuPoker objects in this database so the test
-- database and unrelated databases keep their existing owners.
DO $objects$
DECLARE
  candidate record;
  object_type text;
BEGIN
  FOR candidate IN
    SELECT class.relkind, namespace.nspname, class.relname
    FROM pg_class AS class
    JOIN pg_namespace AS namespace ON namespace.oid = class.relnamespace
    WHERE namespace.nspname = 'public'
      AND class.relowner = (SELECT oid FROM pg_roles WHERE rolname = 'micupoker_user')
      AND class.relkind IN ('r', 'p', 'S', 'v', 'm', 'f')
  LOOP
    object_type := CASE candidate.relkind
      WHEN 'r' THEN 'TABLE'
      WHEN 'p' THEN 'TABLE'
      WHEN 'S' THEN 'SEQUENCE'
      WHEN 'v' THEN 'VIEW'
      WHEN 'm' THEN 'MATERIALIZED VIEW'
      WHEN 'f' THEN 'FOREIGN TABLE'
    END;
    EXECUTE format(
      'ALTER %s %I.%I OWNER TO micupoker_migrate',
      object_type,
      candidate.nspname,
      candidate.relname
    );
  END LOOP;

  FOR candidate IN
    SELECT namespace.nspname, procedure.proname,
      pg_get_function_identity_arguments(procedure.oid) AS arguments
    FROM pg_proc AS procedure
    JOIN pg_namespace AS namespace ON namespace.oid = procedure.pronamespace
    WHERE namespace.nspname = 'public'
      AND procedure.proowner = (SELECT oid FROM pg_roles WHERE rolname = 'micupoker_user')
      AND procedure.prokind IN ('f', 'p')
  LOOP
    EXECUTE format(
      'ALTER ROUTINE %I.%I(%s) OWNER TO micupoker_migrate',
      candidate.nspname,
      candidate.proname,
      candidate.arguments
    );
  END LOOP;

  FOR candidate IN
    SELECT namespace.nspname, type.typname
    FROM pg_type AS type
    JOIN pg_namespace AS namespace ON namespace.oid = type.typnamespace
    WHERE namespace.nspname = 'public'
      AND type.typowner = (SELECT oid FROM pg_roles WHERE rolname = 'micupoker_user')
      AND type.typtype IN ('d', 'e')
  LOOP
    EXECUTE format(
      'ALTER TYPE %I.%I OWNER TO micupoker_migrate',
      candidate.nspname,
      candidate.typname
    );
  END LOOP;
END
$objects$;

\ir runtime_privileges.sql

-- Temporary rollback bridge for the first rollout. Remove it with
-- retire_legacy_role.sql only after the dedicated runtime is healthy.
GRANT CONNECT ON DATABASE micupoker TO micupoker_user;
GRANT USAGE ON SCHEMA public TO micupoker_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO micupoker_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO micupoker_user;
