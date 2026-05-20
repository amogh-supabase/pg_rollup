-- rollup.refresh(name [, since]) — incremental refresh with version history.
--
-- Algorithm:
--   1. Pick the refresh window [start, end):
--        end   = date_trunc(bucket_field, now()) + bucket_size   (covers the partial current bucket)
--        start = date_trunc(bucket_field,
--                           COALESCE(since,
--                                    COALESCE(high_water_mark, -infinity) - lookback_window))
--      `since` is an optional override for backfills / forced rescans.
--   2. Stage new aggregates into a temp table by re-running the aggregation
--      over the source within the window.
--   3. For each (bucket, groups) tuple in the window, close the existing current
--      row only if its values changed OR if no source row exists anymore (data
--      deleted). Unchanged buckets keep their existing current row — no version
--      churn from no-op refreshes.
--   4. Insert new rows for buckets whose current row doesn't already match.
--      Mark _is_partial=true for the bucket containing now().
--   5. Advance high_water_mark to max(bucket) + bucket_size, never going backward.
--      Tracking source-time (not wall-clock) keeps the lookback meaningful even
--      for historical or sparse data.
--   6. Log the run on _refresh_log.
--
-- Everything runs in the caller's transaction. On error, all changes roll back,
-- including the log row.

CREATE OR REPLACE FUNCTION rollup.refresh(
    rollup_name text,
    since       timestamptz DEFAULT NULL,
    until_excl  timestamptz DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql AS
$fn$
DECLARE
    r                record;
    v_log_id         bigint;
    v_start          timestamptz;
    v_end_excl       timestamptz;     -- exclusive upper bound of source scan
    v_partial_bucket timestamptz;     -- bucket containing now(), if it falls in window
    v_bucket_field   text;
    v_new_hwm        timestamptz;

    v_groups_csv         text := '';
    v_groups_select_csv  text := '';
    v_aliases_csv        text;
    v_aliases_select_csv text;
    v_aggregates_csv     text;
    v_group_match        text := 'true';
    v_agg_differs        text;
    v_group_by_ord       text := '';

    v_rows_scanned  bigint := 0;
    v_rows_inserted bigint := 0;
    v_rows_closed   bigint := 0;
BEGIN
    SELECT * INTO r FROM rollup._registry WHERE name = rollup_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_rollup: rollup % not found', rollup_name;
    END IF;
    IF NOT r.is_active THEN
        RAISE EXCEPTION 'pg_rollup: rollup % is paused (is_active=false)', rollup_name;
    END IF;

    v_bucket_field   := rollup._bucket_field(r.bucket_size);
    v_partial_bucket := date_trunc(v_bucket_field, now())::timestamptz;
    v_end_excl       := COALESCE(until_excl, v_partial_bucket + r.bucket_size);
    v_start          := date_trunc(
                            v_bucket_field,
                            COALESCE(
                                since,
                                COALESCE(r.high_water_mark, '-infinity'::timestamptz) - r.lookback_window
                            )
                        )::timestamptz;

    INSERT INTO rollup._refresh_log (rollup_name, window_start, window_end)
    VALUES (rollup_name, v_start, v_end_excl)
    RETURNING id INTO v_log_id;

    -- ---- Build dynamic SQL fragments ----
    IF array_length(r.group_columns, 1) > 0 THEN
        SELECT string_agg(format('%I', g), ', ' ORDER BY ord)
          INTO v_groups_csv
          FROM unnest(r.group_columns) WITH ORDINALITY AS u(g, ord);
        SELECT string_agg(format('n.%I', g), ', ' ORDER BY ord)
          INTO v_groups_select_csv
          FROM unnest(r.group_columns) WITH ORDINALITY AS u(g, ord);
        SELECT string_agg(format('v.%I IS NOT DISTINCT FROM n.%I', g, g), ' AND ' ORDER BY ord)
          INTO v_group_match
          FROM unnest(r.group_columns) WITH ORDINALITY AS u(g, ord);
        SELECT ', ' || string_agg((ord + 1)::text, ', ' ORDER BY ord)
          INTO v_group_by_ord
          FROM unnest(r.group_columns) WITH ORDINALITY AS u(g, ord);
    END IF;

    SELECT string_agg(format('%I', a), ', ' ORDER BY ord)
      INTO v_aliases_csv
      FROM unnest(r.aggregate_aliases) WITH ORDINALITY AS u(a, ord);
    SELECT string_agg(format('n.%I', a), ', ' ORDER BY ord)
      INTO v_aliases_select_csv
      FROM unnest(r.aggregate_aliases) WITH ORDINALITY AS u(a, ord);
    SELECT string_agg(format('v.%I IS DISTINCT FROM n.%I', a, a), ' OR ' ORDER BY ord)
      INTO v_agg_differs
      FROM unnest(r.aggregate_aliases) WITH ORDINALITY AS u(a, ord);
    SELECT string_agg(format('%s AS %I', e, a), ', ' ORDER BY ord)
      INTO v_aggregates_csv
      FROM unnest(r.aggregate_exprs, r.aggregate_aliases) WITH ORDINALITY AS u(e, a, ord);

    -- ---- Stage new aggregates ----
    EXECUTE format(
      'CREATE TEMP TABLE _pg_rollup_new ON COMMIT DROP AS
       SELECT date_trunc(%L, %I::timestamptz)::timestamptz AS bucket%s, %s
       FROM %s
       WHERE %I::timestamptz >= $1 AND %I::timestamptz < $2
       GROUP BY 1%s',
      v_bucket_field,
      r.time_column,
      CASE WHEN v_groups_csv = '' THEN '' ELSE ', ' || v_groups_csv END,
      v_aggregates_csv,
      r.source_table,
      r.time_column, r.time_column,
      v_group_by_ord
    ) USING v_start, v_end_excl;

    SELECT count(*), max(bucket)
      INTO v_rows_scanned, v_new_hwm
      FROM _pg_rollup_new;

    -- ---- Close current rows whose value changed or disappeared ----
    EXECUTE format(
      'UPDATE rollup.%I AS v
         SET _version_to = now(), _is_current = false
       WHERE v._is_current
         AND v.bucket >= $1 AND v.bucket < $2
         AND (
           NOT EXISTS (
             SELECT 1 FROM _pg_rollup_new AS n
             WHERE n.bucket = v.bucket AND %s
           )
           OR EXISTS (
             SELECT 1 FROM _pg_rollup_new AS n
             WHERE n.bucket = v.bucket AND %s AND (%s)
           )
         )',
      r.versions_table, v_group_match, v_group_match, v_agg_differs
    ) USING v_start, v_end_excl;
    GET DIAGNOSTICS v_rows_closed = ROW_COUNT;

    -- ---- Insert new versions ----
    EXECUTE format(
      'INSERT INTO rollup.%I (bucket%s, %s, _is_partial)
       SELECT n.bucket%s, %s, (n.bucket = $1) AS _is_partial
       FROM _pg_rollup_new AS n
       WHERE NOT EXISTS (
         SELECT 1 FROM rollup.%I AS v
         WHERE v._is_current AND v.bucket = n.bucket AND %s
       )',
      r.versions_table,
      CASE WHEN v_groups_csv = '' THEN '' ELSE ', ' || v_groups_csv END,
      v_aliases_csv,
      CASE WHEN v_groups_select_csv = '' THEN '' ELSE ', ' || v_groups_select_csv END,
      v_aliases_select_csv,
      r.versions_table, v_group_match
    ) USING v_partial_bucket;
    GET DIAGNOSTICS v_rows_inserted = ROW_COUNT;

    DROP TABLE _pg_rollup_new;

    -- ---- Advance high_water_mark in source-time ----
    -- Never regress (since may have been used to force a narrow window that
    -- doesn't include the data tip). v_new_hwm is NULL if no rows were scanned.
    IF v_new_hwm IS NOT NULL THEN
        UPDATE rollup._registry
           SET high_water_mark = GREATEST(
                   COALESCE(rollup._registry.high_water_mark, '-infinity'::timestamptz),
                   v_new_hwm + r.bucket_size
               )
         WHERE name = rollup_name;
    END IF;

    UPDATE rollup._refresh_log
       SET finished_at  = now(),
           status       = 'success',
           rows_scanned = v_rows_scanned,
           rows_inserted= v_rows_inserted,
           rows_closed  = v_rows_closed
     WHERE id = v_log_id;

    RAISE NOTICE 'pg_rollup: refresh % — buckets=%, closed=%, inserted=%',
        rollup_name, v_rows_scanned, v_rows_closed, v_rows_inserted;
END;
$fn$;
