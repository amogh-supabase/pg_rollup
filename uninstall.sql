-- pg_rollup uninstaller. Run with:  psql "$PGROLLUP_DB" -f uninstall.sql
-- Removes the rollup schema (including all generated versions tables and views),
-- and unschedules any pg_cron jobs registered by pg_rollup. Idempotent.

\set ON_ERROR_STOP on

BEGIN;

-- Unschedule pg_cron jobs registered by any rollup before we drop the registry.
DO $$
DECLARE
    job_id bigint;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RETURN;
    END IF;
    IF to_regclass('rollup._registry') IS NULL THEN
        RETURN;
    END IF;

    FOR job_id IN
        SELECT cron_job_id FROM rollup._registry WHERE cron_job_id IS NOT NULL
    LOOP
        BEGIN
            PERFORM cron.unschedule(job_id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'pg_rollup: could not unschedule cron job % (%): %', job_id, SQLSTATE, SQLERRM;
        END;
    END LOOP;
END
$$;

DROP SCHEMA IF EXISTS rollup CASCADE;

COMMIT;

\echo '== pg_rollup: uninstall complete'
