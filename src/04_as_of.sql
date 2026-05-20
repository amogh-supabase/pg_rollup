-- rollup._install_at_function(name) — generates rollup.<name>_at(timestamptz).
--
-- The generated function returns the rollup's business columns (bucket, groups,
-- aggregates) as they existed at the given timestamp. A row was active at time t
-- iff _version_from <= t AND (_version_to IS NULL OR _version_to > t).
--
-- Column shape (and types) is read directly from the versions table, so any
-- aggregate the user defined works without further configuration.

CREATE OR REPLACE FUNCTION rollup._install_at_function(rollup_name text)
RETURNS void
LANGUAGE plpgsql AS
$fn$
DECLARE
    r              record;
    v_cols_sig     text;
    v_cols_select  text;
BEGIN
    SELECT * INTO r FROM rollup._registry WHERE name = rollup_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_rollup: rollup % not found', rollup_name;
    END IF;

    -- All non-meta columns from the versions table, preserving order.
    SELECT
        string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)),
                   ', ' ORDER BY a.attnum),
        string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
      INTO v_cols_sig, v_cols_select
      FROM pg_attribute a
     WHERE a.attrelid = format('rollup.%I', r.versions_table)::regclass
       AND a.attnum > 0
       AND NOT a.attisdropped
       AND a.attname NOT LIKE '\_%' ESCAPE '\';

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION rollup.%I(at_time timestamptz)
         RETURNS TABLE (%s)
         LANGUAGE sql STABLE AS $f$
            SELECT %s
              FROM rollup.%I
             WHERE _version_from <= at_time
               AND (_version_to IS NULL OR _version_to > at_time)
         $f$',
        rollup_name || '_at',
        v_cols_sig,
        v_cols_select,
        r.versions_table
    );
END;
$fn$;
