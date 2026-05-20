-- rollup.status() — one row per registered rollup with freshness, sizes, and
-- the most recent successful refresh stats. Intended for ad-hoc monitoring:
--   SELECT * FROM rollup.status();

CREATE OR REPLACE FUNCTION rollup.status()
RETURNS TABLE (
    name              text,
    source_table      regclass,
    bucket_size       interval,
    is_active         boolean,
    schedule          text,
    cron_job_id       bigint,
    high_water_mark   timestamptz,        -- source-time freshness
    last_refresh_at   timestamptz,        -- wall-clock freshness
    last_refresh_secs numeric,
    current_rows      bigint,
    total_versions    bigint,
    size_bytes        bigint
)
LANGUAGE plpgsql STABLE AS
$fn$
DECLARE
    rec record;
BEGIN
    FOR rec IN SELECT * FROM rollup._registry ORDER BY name LOOP
        status.name              := rec.name;
        status.source_table      := rec.source_table;
        status.bucket_size       := rec.bucket_size;
        status.is_active         := rec.is_active;
        status.schedule          := rec.schedule;
        status.cron_job_id       := rec.cron_job_id;
        status.high_water_mark   := rec.high_water_mark;

        SELECT l.started_at,
               EXTRACT(EPOCH FROM (l.finished_at - l.started_at))::numeric
          INTO status.last_refresh_at, status.last_refresh_secs
          FROM rollup._refresh_log l
         WHERE l.rollup_name = rec.name AND l.status = 'success'
         ORDER BY l.finished_at DESC NULLS LAST
         LIMIT 1;

        EXECUTE format(
            'SELECT count(*) FILTER (WHERE _is_current), count(*) FROM rollup.%I',
            rec.versions_table
        ) INTO status.current_rows, status.total_versions;

        status.size_bytes := pg_total_relation_size(
            format('rollup.%I', rec.versions_table)::regclass);

        RETURN NEXT;
    END LOOP;
END;
$fn$;
