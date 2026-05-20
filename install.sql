-- pg_rollup installer. Run with:  psql "$PGROLLUP_DB" -f install.sql
-- Idempotent: re-running on an already-installed database is a no-op.

\set ON_ERROR_STOP on

BEGIN;

\echo '== pg_rollup: checking prerequisites'
\i src/00_prerequisites.sql

\echo '== pg_rollup: creating schema and metadata tables'
\i src/01_schema.sql

\echo '== pg_rollup: installing rollup.create()'
\i src/02_create.sql

\echo '== pg_rollup: installing rollup.refresh()'
\i src/03_refresh.sql

\echo '== pg_rollup: installing as_of generator'
\i src/04_as_of.sql

\echo '== pg_rollup: installing diff generator'
\i src/05_diff.sql

\echo '== pg_rollup: installing rollup.backfill()'
\i src/06_backfill.sql

\echo '== pg_rollup: installing rollup.status()'
\i src/07_status.sql

\echo '== pg_rollup: installing rollup.drop()'
\i src/08_drop.sql

\echo '== pg_rollup: installing rollup.purge_history()'
\i src/09_purge.sql

COMMIT;

\echo '== pg_rollup: install complete'
