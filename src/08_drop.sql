-- rollup.drop(name) — remove a rollup completely:
--   - drop the user-facing view rollup.<name>
--   - drop the versions table rollup._<name>_versions
--   - drop the generated helpers rollup.<name>_at and rollup.<name>_diff
--   - unschedule the pg_cron job if one was registered (no-op if pg_cron absent)
--   - delete the _registry row (which cascades to _refresh_log)

CREATE OR REPLACE FUNCTION rollup.drop(rollup_name text)
RETURNS void
LANGUAGE plpgsql AS
$fn$
DECLARE
    r record;
BEGIN
    SELECT * INTO r FROM rollup._registry WHERE name = rollup_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_rollup: rollup % not found', rollup_name;
    END IF;

    IF r.cron_job_id IS NOT NULL
       AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        BEGIN
            PERFORM cron.unschedule(r.cron_job_id);
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE 'pg_rollup: failed to unschedule cron job %: %', r.cron_job_id, SQLERRM;
        END;
    END IF;

    EXECUTE format('DROP VIEW IF EXISTS rollup.%I',  r.view_name);
    EXECUTE format('DROP TABLE IF EXISTS rollup.%I CASCADE', r.versions_table);
    EXECUTE format('DROP FUNCTION IF EXISTS rollup.%I(timestamptz)',
                   r.name || '_at');
    EXECUTE format('DROP FUNCTION IF EXISTS rollup.%I(timestamptz, timestamptz)',
                   r.name || '_diff');

    DELETE FROM rollup._registry WHERE name = rollup_name;

    RAISE NOTICE 'pg_rollup: dropped rollup %', rollup_name;
END;
$fn$;
