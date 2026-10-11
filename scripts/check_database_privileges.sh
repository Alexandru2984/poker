#!/usr/bin/env bash
set -euo pipefail

allow_legacy=false
case "${1:-}" in
  "") ;;
  --allow-legacy) allow_legacy=true ;;
  *) echo "usage: $0 [--allow-legacy]" >&2; exit 2 ;;
esac

sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d micupoker \
  -v allow_legacy="$allow_legacy" <<'SQL'
DO $audit$
DECLARE
  relation_name text;
  sequence_name text;
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_roles
    WHERE rolname IN ('micupoker_migrate', 'micupoker_app', 'micupoker_backup')
      AND (rolsuper OR rolcreatedb OR rolcreaterole OR rolreplication)
  ) THEN
    RAISE EXCEPTION 'a MicuPoker role has administrative attributes';
  END IF;

  IF pg_get_userbyid((SELECT datdba FROM pg_database WHERE datname = 'micupoker'))
       <> 'micupoker_migrate' THEN
    RAISE EXCEPTION 'migration role does not own the database';
  END IF;

  IF pg_get_userbyid((SELECT nspowner FROM pg_namespace WHERE nspname = 'public'))
       <> 'micupoker_migrate' THEN
    RAISE EXCEPTION 'migration role does not own the public schema';
  END IF;

  IF has_database_privilege('micupoker_app', 'micupoker', 'CREATE') OR
     has_database_privilege('micupoker_app', 'micupoker', 'TEMP') OR
     has_schema_privilege('micupoker_app', 'public', 'CREATE') THEN
    RAISE EXCEPTION 'runtime role can create database or schema objects';
  END IF;

  IF has_table_privilege('micupoker_app', 'public.schema_migrations', 'SELECT') OR
     has_table_privilege('micupoker_app', 'public.schema_migrations', 'INSERT') OR
     has_table_privilege('micupoker_app', 'public.schema_migrations', 'UPDATE') OR
     has_table_privilege('micupoker_app', 'public.schema_migrations', 'DELETE') THEN
    RAISE EXCEPTION 'runtime role can modify the migration ledger';
  END IF;

  IF NOT has_table_privilege('micupoker_backup', 'public.schema_migrations', 'SELECT') OR
     has_table_privilege('micupoker_backup', 'public.schema_migrations', 'INSERT') OR
     has_table_privilege('micupoker_backup', 'public.schema_migrations', 'UPDATE') OR
     has_table_privilege('micupoker_backup', 'public.schema_migrations', 'DELETE') THEN
    RAISE EXCEPTION 'backup role cannot safely read the migration ledger';
  END IF;

  FOR relation_name IN
    SELECT format('%I.%I', schemaname, tablename)
    FROM pg_tables
    WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
  LOOP
    IF NOT has_table_privilege('micupoker_app', relation_name, 'SELECT') OR
       NOT has_table_privilege('micupoker_app', relation_name, 'INSERT') OR
       NOT has_table_privilege('micupoker_app', relation_name, 'UPDATE') OR
       NOT has_table_privilege('micupoker_app', relation_name, 'DELETE') THEN
      RAISE EXCEPTION 'runtime DML privilege missing on %', relation_name;
    END IF;
    IF has_table_privilege('micupoker_app', relation_name, 'TRUNCATE') OR
       has_table_privilege('micupoker_app', relation_name, 'REFERENCES') OR
       has_table_privilege('micupoker_app', relation_name, 'TRIGGER') THEN
      RAISE EXCEPTION 'runtime role has an excessive privilege on %', relation_name;
    END IF;
    IF NOT has_table_privilege('micupoker_backup', relation_name, 'SELECT') OR
       has_table_privilege('micupoker_backup', relation_name, 'INSERT') OR
       has_table_privilege('micupoker_backup', relation_name, 'UPDATE') OR
       has_table_privilege('micupoker_backup', relation_name, 'DELETE') OR
       has_table_privilege('micupoker_backup', relation_name, 'TRUNCATE') THEN
      RAISE EXCEPTION 'backup privilege mismatch on %', relation_name;
    END IF;
  END LOOP;

  FOR sequence_name IN
    SELECT format('%I.%I', sequence_schema, sequence_name)
    FROM information_schema.sequences
    WHERE sequence_schema = 'public'
  LOOP
    IF NOT has_sequence_privilege('micupoker_app', sequence_name, 'USAGE') OR
       NOT has_sequence_privilege('micupoker_app', sequence_name, 'SELECT') OR
       has_sequence_privilege('micupoker_app', sequence_name, 'UPDATE') THEN
      RAISE EXCEPTION 'runtime sequence privilege mismatch on %', sequence_name;
    END IF;
    IF NOT has_sequence_privilege('micupoker_backup', sequence_name, 'SELECT') OR
       has_sequence_privilege('micupoker_backup', sequence_name, 'USAGE') OR
       has_sequence_privilege('micupoker_backup', sequence_name, 'UPDATE') THEN
      RAISE EXCEPTION 'backup sequence privilege mismatch on %', sequence_name;
    END IF;
  END LOOP;
END
$audit$;

\if :allow_legacy
\else
DO $legacy_audit$
BEGIN
  IF has_database_privilege('micupoker_user', 'micupoker', 'CONNECT') OR
     has_schema_privilege('micupoker_user', 'public', 'USAGE') OR
     has_database_privilege('micu', 'micupoker', 'CONNECT') OR
     has_schema_privilege('micu', 'public', 'USAGE') THEN
    RAISE EXCEPTION 'a legacy role still reaches the production database';
  END IF;
END
$legacy_audit$;
\endif
SQL

echo "database_privileges=passed allow_legacy=$allow_legacy"
