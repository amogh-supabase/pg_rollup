-- rollup.purge_history(name, older_than) — delete closed version rows whose
-- _version_to is older than (now() - older_than). Current rows are never touched.
-- Returns the count of rows deleted.

CREATE OR REPLACE FUNCTION rollup.purge_history(
    rollup_name text,
    older_than  interval
) RETURNS bigint
LANGUAGE plpgsql AS
$fn$
DECLARE
    r        record;
    v_cutoff timestamptz := now() - older_than;
    v_count  bigint;
BEGIN
    SELECT * INTO r FROM rollup._registry WHERE name = rollup_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_rollup: rollup % not found', rollup_name;
    END IF;

    EXECUTE format(
        'DELETE FROM rollup.%I
           WHERE NOT _is_current AND _version_to < $1',
        r.versions_table
    ) USING v_cutoff;
    GET DIAGNOSTICS v_count = ROW_COUNT;

    RAISE NOTICE 'pg_rollup: purged % closed version row(s) from % (older than %)',
        v_count, rollup_name, older_than;
    RETURN v_count;
END;
$fn$;
