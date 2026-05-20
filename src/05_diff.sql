-- rollup._install_diff_function(name) — generates rollup.<name>_diff(t_a, t_b).
--
-- The generated function returns one row per (bucket, groups) tuple comparing
-- the rollup state at two timestamps:
--   bucket, [group columns], [<agg>_a, <agg>_b for each aggregate], change_type
--
-- change_type is:
--   'added'     — the row appeared between time_a and time_b
--   'removed'   — the row disappeared between time_a and time_b
--   'unchanged' — same values at both times
--   'changed'   — same key, different values
--
-- Internally the function joins two calls to rollup.<name>_at(), so install_at
-- must run before install_diff for any given rollup.

CREATE OR REPLACE FUNCTION rollup._install_diff_function(rollup_name text)
RETURNS void
LANGUAGE plpgsql AS
$fn$
DECLARE
    r                 record;
    v_groups_sig      text := '';
    v_groups_coalesce text := '';
    v_groups_join     text := '';
    v_aggs_sig        text;
    v_aggs_cols       text;
    v_aggs_unchanged  text;
    v_versions_oid    regclass;
BEGIN
    SELECT * INTO r FROM rollup._registry WHERE name = rollup_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_rollup: rollup % not found', rollup_name;
    END IF;
    v_versions_oid := format('rollup.%I', r.versions_table)::regclass;

    -- Groups: build signature/COALESCE-select/JOIN-condition fragments.
    IF array_length(r.group_columns, 1) > 0 THEN
        SELECT
            ', ' || string_agg(
                format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)),
                ', ' ORDER BY a.attnum),
            ', ' || string_agg(
                format('COALESCE(a.%I, b.%I) AS %I', a.attname, a.attname, a.attname),
                ', ' ORDER BY a.attnum),
            ' AND ' || string_agg(
                format('a.%I IS NOT DISTINCT FROM b.%I', a.attname, a.attname),
                ' AND ' ORDER BY a.attnum)
          INTO v_groups_sig, v_groups_coalesce, v_groups_join
          FROM pg_attribute a
         WHERE a.attrelid = v_versions_oid
           AND a.attnum > 0 AND NOT a.attisdropped
           AND a.attname = ANY(r.group_columns);
    END IF;

    -- Aggregates: <alias>_a/<alias>_b columns with the original types.
    SELECT
        string_agg(
            format('%I %s, %I %s',
                   a.attname || '_a', format_type(a.atttypid, a.atttypmod),
                   a.attname || '_b', format_type(a.atttypid, a.atttypmod)),
            ', ' ORDER BY a.attnum),
        string_agg(
            format('a.%I AS %I, b.%I AS %I',
                   a.attname, a.attname || '_a',
                   a.attname, a.attname || '_b'),
            ', ' ORDER BY a.attnum)
      INTO v_aggs_sig, v_aggs_cols
      FROM pg_attribute a
     WHERE a.attrelid = v_versions_oid
       AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname = ANY(r.aggregate_aliases);

    -- "(a.agg1, a.agg2, ...) IS NOT DISTINCT FROM (b.agg1, b.agg2, ...)"
    SELECT
        '(' || string_agg(format('a.%I', a.attname), ', ' ORDER BY a.attnum) || ')'
        || ' IS NOT DISTINCT FROM '
        || '(' || string_agg(format('b.%I', a.attname), ', ' ORDER BY a.attnum) || ')'
      INTO v_aggs_unchanged
      FROM pg_attribute a
     WHERE a.attrelid = v_versions_oid
       AND a.attnum > 0 AND NOT a.attisdropped
       AND a.attname = ANY(r.aggregate_aliases);

    EXECUTE format(
        'CREATE OR REPLACE FUNCTION rollup.%I(time_a timestamptz, time_b timestamptz)
         RETURNS TABLE (
             bucket timestamptz%s,
             %s,
             change_type text
         )
         LANGUAGE sql STABLE AS $f$
            WITH a AS (SELECT * FROM rollup.%I(time_a)),
                 b AS (SELECT * FROM rollup.%I(time_b))
            SELECT
                COALESCE(a.bucket, b.bucket) AS bucket%s,
                %s,
                CASE
                    WHEN a.bucket IS NULL THEN ''added''
                    WHEN b.bucket IS NULL THEN ''removed''
                    WHEN %s THEN ''unchanged''
                    ELSE ''changed''
                END AS change_type
            FROM a
            FULL OUTER JOIN b
              ON a.bucket = b.bucket%s
         $f$',
        rollup_name || '_diff',
        v_groups_sig,
        v_aggs_sig,
        rollup_name || '_at',
        rollup_name || '_at',
        v_groups_coalesce,
        v_aggs_cols,
        v_aggs_unchanged,
        v_groups_join
    );
END;
$fn$;
