-- rollup.create() — register a new versioned rollup.
--
-- Builds the versions table by probing the source with CREATE TABLE ... LIMIT 0,
-- so aggregate column types are inferred by Postgres (no parsing of expressions).
-- Aggregate expressions are opaque SQL strings: anything valid in SELECT ... GROUP BY
-- works, including count(*) filter (...), percentile_cont(...), math expressions, etc.

-- Helper: map a supported bucket interval to a date_trunc field name.
CREATE OR REPLACE FUNCTION rollup._bucket_field(bucket_size interval)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    CASE bucket_size
        WHEN interval '1 minute'  THEN RETURN 'minute';
        WHEN interval '1 hour'    THEN RETURN 'hour';
        WHEN interval '1 day'     THEN RETURN 'day';
        WHEN interval '1 week'    THEN RETURN 'week';
        WHEN interval '1 month'   THEN RETURN 'month';
        WHEN interval '3 months'  THEN RETURN 'quarter';
        WHEN interval '1 year'    THEN RETURN 'year';
        ELSE
            RAISE EXCEPTION 'pg_rollup: bucket_size must be one of: 1 minute, 1 hour, 1 day, 1 week, 1 month, 3 months, 1 year (got %)', bucket_size;
    END CASE;
END;
$$;

-- Helper: split an aggregate expression like "count(*) as foo" into base and alias.
-- Greedy match on the last case-insensitive " AS <identifier>".
CREATE OR REPLACE FUNCTION rollup._parse_aggregate(agg text,
                                                   OUT base_expr text,
                                                   OUT alias     text)
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    m text[];
BEGIN
    m := regexp_match(agg, '(?i)^(.+)\s+as\s+([a-z_][a-z0-9_]*)\s*$');
    IF m IS NULL THEN
        RAISE EXCEPTION 'pg_rollup: aggregate expression must end with `AS <alias>`: %', agg;
    END IF;
    base_expr := trim(m[1]);
    alias     := m[2];
END;
$$;

-- Main entry point. Default groups=array[]::text[] so callers can omit it.
CREATE OR REPLACE FUNCTION rollup.create(
    name            text,
    source          regclass,
    time_column     text,
    bucket_size     interval,
    aggregates      text[],
    groups          text[]   DEFAULT ARRAY[]::text[],
    lookback_window interval DEFAULT NULL,
    schedule        text     DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql AS
$fn$
DECLARE
    v_name           text := name;
    v_versions_table text := '_' || name || '_versions';
    v_view_name      text := name;
    v_bucket_field   text;
    v_resolved_lb    interval;
    v_agg_exprs      text[] := ARRAY[]::text[];
    v_agg_aliases    text[] := ARRAY[]::text[];
    v_groups_sql     text   := '';
    v_aggs_sql       text;
    v_pk_cols        text;
    v_groups         text[] := COALESCE(groups, ARRAY[]::text[]);
    v_agg            text;
    v_g              text;
    v_pair           record;
    v_time_type      text;
BEGIN
    -- ---- 1. Validate name -----------------------------------------------
    IF v_name IS NULL OR v_name = '' THEN
        RAISE EXCEPTION 'pg_rollup: name must be non-empty';
    END IF;
    IF v_name !~ '^[a-z_][a-z_0-9]*$' THEN
        RAISE EXCEPTION 'pg_rollup: name must match ^[a-z_][a-z_0-9]*$ (got %)', v_name;
    END IF;
    IF length(v_name) > 50 THEN
        RAISE EXCEPTION 'pg_rollup: name too long (max 50 chars): %', v_name;
    END IF;
    IF EXISTS (SELECT 1 FROM rollup._registry r WHERE r.name = v_name) THEN
        RAISE EXCEPTION 'pg_rollup: rollup % already exists', v_name;
    END IF;
    IF to_regclass(format('rollup.%I', v_versions_table)) IS NOT NULL THEN
        RAISE EXCEPTION 'pg_rollup: orphan table rollup.% exists; drop it before creating rollup %', v_versions_table, v_name;
    END IF;
    IF to_regclass(format('rollup.%I', v_view_name)) IS NOT NULL THEN
        RAISE EXCEPTION 'pg_rollup: orphan view rollup.% exists; drop it before creating rollup %', v_view_name, v_name;
    END IF;

    -- ---- 2. Validate time_column ----------------------------------------
    SELECT format_type(atttypid, atttypmod) INTO v_time_type
    FROM pg_attribute
    WHERE attrelid = source AND attname = time_column
      AND attnum > 0 AND NOT attisdropped;
    IF v_time_type IS NULL THEN
        RAISE EXCEPTION 'pg_rollup: column %.% does not exist', source, time_column;
    END IF;
    IF v_time_type NOT IN ('date', 'timestamp without time zone', 'timestamp with time zone') THEN
        RAISE EXCEPTION 'pg_rollup: time_column %.% must be date/timestamp/timestamptz (found %)',
            source, time_column, v_time_type;
    END IF;

    -- ---- 3. Validate group columns exist --------------------------------
    FOREACH v_g IN ARRAY v_groups LOOP
        IF NOT EXISTS (
            SELECT 1 FROM pg_attribute
            WHERE attrelid = source AND attname = v_g
              AND attnum > 0 AND NOT attisdropped
        ) THEN
            RAISE EXCEPTION 'pg_rollup: group column %.% does not exist', source, v_g;
        END IF;
    END LOOP;

    -- ---- 4. Resolve bucket_size to a date_trunc field -------------------
    v_bucket_field := rollup._bucket_field(bucket_size);

    -- ---- 5. Parse aggregate expressions into (expr, alias) --------------
    IF aggregates IS NULL OR array_length(aggregates, 1) IS NULL THEN
        RAISE EXCEPTION 'pg_rollup: aggregates must contain at least one expression';
    END IF;
    FOREACH v_agg IN ARRAY aggregates LOOP
        SELECT base_expr, alias INTO v_pair FROM rollup._parse_aggregate(v_agg);
        IF v_pair.alias LIKE '\_%' ESCAPE '\' THEN
            RAISE EXCEPTION 'pg_rollup: aggregate alias may not start with underscore (got %)', v_pair.alias;
        END IF;
        IF v_pair.alias = 'bucket' THEN
            RAISE EXCEPTION 'pg_rollup: aggregate alias "bucket" collides with the bucket column';
        END IF;
        IF v_pair.alias = ANY (v_groups) THEN
            RAISE EXCEPTION 'pg_rollup: aggregate alias % collides with a group column', v_pair.alias;
        END IF;
        v_agg_exprs   := array_append(v_agg_exprs,   v_pair.base_expr);
        v_agg_aliases := array_append(v_agg_aliases, v_pair.alias);
    END LOOP;
    -- Alias uniqueness within the aggregates list
    IF (SELECT count(DISTINCT a) FROM unnest(v_agg_aliases) a) <> array_length(v_agg_aliases, 1) THEN
        RAISE EXCEPTION 'pg_rollup: duplicate aggregate alias in %', v_agg_aliases;
    END IF;

    -- ---- 6. Build SQL fragments for groups and aggregates ---------------
    IF array_length(v_groups, 1) > 0 THEN
        SELECT string_agg(format('%I', g), ', ' ORDER BY ord)
          INTO v_groups_sql
          FROM unnest(v_groups) WITH ORDINALITY AS u(g, ord);
    END IF;
    SELECT string_agg(a, ', ' ORDER BY ord)
      INTO v_aggs_sql
      FROM unnest(aggregates) WITH ORDINALITY AS u(a, ord);

    -- ---- 7. Create the versions table via CREATE TABLE AS LIMIT 0 -------
    --        Postgres infers all column types from the probe SELECT.
    -- Probe with a real GROUP BY so the aggregate query is well-formed; WITH NO DATA
    -- materializes only the column types, not rows.
    EXECUTE format(
        'CREATE TABLE rollup.%I AS
         SELECT date_trunc(%L, %I::timestamptz)::timestamptz AS bucket%s, %s
         FROM %s
         GROUP BY 1%s
         WITH NO DATA',
        v_versions_table,
        v_bucket_field,
        time_column,
        CASE WHEN v_groups_sql = '' THEN '' ELSE ', ' || v_groups_sql END,
        v_aggs_sql,
        source,
        CASE WHEN v_groups_sql = '' THEN '' ELSE
            ', ' || (SELECT string_agg((ord + 1)::text, ', ') FROM unnest(v_groups) WITH ORDINALITY u(g, ord))
        END
    );

    -- Add version metadata columns and lock down bucket.
    EXECUTE format(
        'ALTER TABLE rollup.%I
            ALTER COLUMN bucket SET NOT NULL,
            ADD COLUMN _version_from timestamptz NOT NULL DEFAULT now(),
            ADD COLUMN _version_to   timestamptz,
            ADD COLUMN _is_current   boolean     NOT NULL DEFAULT true,
            ADD COLUMN _is_partial   boolean     NOT NULL DEFAULT false',
        v_versions_table
    );

    -- Uniqueness on (bucket, groups..., _version_from). NULLS NOT DISTINCT so
    -- rows with NULL group values still get a unique constraint.
    IF array_length(v_groups, 1) > 0 THEN
        v_pk_cols := 'bucket, ' || v_groups_sql || ', _version_from';
    ELSE
        v_pk_cols := 'bucket, _version_from';
    END IF;
    EXECUTE format(
        'CREATE UNIQUE INDEX %I ON rollup.%I (%s) NULLS NOT DISTINCT',
        v_versions_table || '_uniq',
        v_versions_table,
        v_pk_cols
    );

    -- Partial index for the common "current rows only" lookup path.
    EXECUTE format(
        'CREATE INDEX %I ON rollup.%I (bucket) WHERE _is_current',
        v_versions_table || '_current_idx',
        v_versions_table
    );

    -- ---- 8. Create the current-only view --------------------------------
    DECLARE
        v_view_cols text := 'bucket';
    BEGIN
        IF v_groups_sql <> '' THEN
            v_view_cols := v_view_cols || ', ' || v_groups_sql;
        END IF;
        SELECT v_view_cols || ', ' || string_agg(format('%I', a), ', ' ORDER BY ord)
          INTO v_view_cols
          FROM unnest(v_agg_aliases) WITH ORDINALITY AS u(a, ord);

        EXECUTE format(
            'CREATE VIEW rollup.%I AS SELECT %s FROM rollup.%I WHERE _is_current',
            v_view_name, v_view_cols, v_versions_table
        );
    END;

    -- ---- 9. Resolve defaults and write the registry row -----------------
    v_resolved_lb := COALESCE(lookback_window, bucket_size * 3);

    INSERT INTO rollup._registry (
        name, source_table, versions_table, view_name,
        time_column, bucket_size, group_columns,
        aggregate_exprs, aggregate_aliases,
        lookback_window, schedule
    ) VALUES (
        v_name, source, v_versions_table, v_view_name,
        time_column, bucket_size, v_groups,
        v_agg_exprs, v_agg_aliases,
        v_resolved_lb, schedule
    );

    -- ---- 10. Schedule cron job (deferred) -------------------------------
    -- Generate the per-rollup query helpers. _at must come before _diff because
    -- the diff function's body references _at.
    PERFORM rollup._install_at_function(v_name);
    PERFORM rollup._install_diff_function(v_name);

    -- Schedule the periodic refresh via pg_cron (optional). If pg_cron isn't
    -- installed and the user passes a schedule, we error so the misconfiguration
    -- is visible — pg_cron must be enabled explicitly.
    IF schedule IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
            RAISE EXCEPTION
                'pg_rollup: schedule = % was given but pg_cron is not installed. Run "CREATE EXTENSION pg_cron;" first, or omit the schedule and call rollup.refresh() manually.',
                schedule;
        END IF;
        DECLARE v_cron_job_id bigint;
        BEGIN
            v_cron_job_id := cron.schedule(
                'pg_rollup_' || v_name,
                schedule,
                format('SELECT rollup.refresh(%L)', v_name)
            );
            UPDATE rollup._registry r SET cron_job_id = v_cron_job_id WHERE r.name = v_name;
            RAISE NOTICE 'pg_rollup: scheduled rollup % via pg_cron job id % (%)',
                v_name, v_cron_job_id, schedule;
        END;
    END IF;

    RAISE NOTICE 'pg_rollup: created rollup % (versions=rollup.%, view=rollup.%, lookback=%)',
        v_name, v_versions_table, v_view_name, v_resolved_lb;
END;
$fn$;
