-- pg_rollup prerequisites: enforce PG15+ and report pg_cron status.
-- pg_cron is optional — without it, refreshes must be invoked manually.

DO $$
BEGIN
    IF current_setting('server_version_num')::int < 150000 THEN
        RAISE EXCEPTION
            'pg_rollup requires PostgreSQL 15 or later (found %)',
            current_setting('server_version');
    END IF;
END
$$;

DO $$
DECLARE
    cron_available boolean;
    cron_installed boolean;
BEGIN
    SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron')
      INTO cron_available;
    SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
      INTO cron_installed;

    IF cron_installed THEN
        RAISE NOTICE 'pg_rollup: pg_cron detected and installed — scheduled refreshes enabled.';
    ELSIF cron_available THEN
        RAISE NOTICE 'pg_rollup: pg_cron available but not installed. Run "CREATE EXTENSION pg_cron;" to enable scheduled refreshes.';
    ELSE
        RAISE NOTICE 'pg_rollup: pg_cron not available on this server. Call rollup.refresh() manually or from an external scheduler.';
    END IF;
END
$$;
