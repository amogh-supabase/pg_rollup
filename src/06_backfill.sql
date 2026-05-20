-- rollup.backfill(name [, batch_size]) — chunked initial population.
--
-- For a rollup created against a source table that already has historical data,
-- backfill processes the data range in [batch_size]-wide chunks. Each chunk is
-- its own refresh call inside its own transaction (the procedure COMMITs between
-- batches), so long-running backfills don't hold one giant transaction or one
-- giant lock.
--
-- batch_size defaults to bucket_size * 10. It should be a multiple of bucket_size;
-- otherwise the bucket that straddles a batch boundary will be transiently wrong
-- (the final state still ends up correct as long as the last batch covering each
-- bucket sees its complete source data — which requires alignment).

CREATE OR REPLACE PROCEDURE rollup.backfill(
    rollup_name text,
    batch_size  interval DEFAULT NULL
)
LANGUAGE plpgsql AS
$proc$
DECLARE
    r              record;
    v_min          timestamptz;
    v_max          timestamptz;
    v_end_excl     timestamptz;
    v_batch_size   interval;
    v_field        text;
    v_batch_start  timestamptz;
    v_batch_end    timestamptz;
    v_batches      int := 0;
BEGIN
    SELECT * INTO r FROM rollup._registry WHERE name = rollup_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pg_rollup: rollup % not found', rollup_name;
    END IF;
    v_field      := rollup._bucket_field(r.bucket_size);
    v_batch_size := COALESCE(batch_size, r.bucket_size * 10);

    EXECUTE format(
        'SELECT min(%I)::timestamptz, max(%I)::timestamptz FROM %s',
        r.time_column, r.time_column, r.source_table
    ) INTO v_min, v_max;

    IF v_min IS NULL THEN
        RAISE NOTICE 'pg_rollup: source % is empty, nothing to backfill', r.source_table;
        RETURN;
    END IF;

    -- Align both ends to bucket boundaries.
    v_batch_start := date_trunc(v_field, v_min)::timestamptz;
    v_end_excl    := date_trunc(v_field, v_max)::timestamptz + r.bucket_size;

    WHILE v_batch_start < v_end_excl LOOP
        v_batch_end := LEAST(v_batch_start + v_batch_size, v_end_excl);
        PERFORM rollup.refresh(rollup_name,
                               since      := v_batch_start,
                               until_excl := v_batch_end);
        COMMIT;
        v_batches := v_batches + 1;
        v_batch_start := v_batch_end;
    END LOOP;

    RAISE NOTICE 'pg_rollup: backfilled % in % batch(es), range % to %',
        rollup_name, v_batches, v_min, v_max;
END;
$proc$;
