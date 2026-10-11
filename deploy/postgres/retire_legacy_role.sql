\set ON_ERROR_STOP on
\connect micupoker

REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM micupoker_user, micu;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM micupoker_user, micu;
REVOKE ALL PRIVILEGES ON SCHEMA public FROM micupoker_user, micu;
REVOKE ALL PRIVILEGES ON DATABASE micupoker FROM micupoker_user, micu;
