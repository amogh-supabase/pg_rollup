-- Smoke test: full pg_rollup lifecycle in one file.
--
-- Covers the spec the project plan calls out:
--   - install → create → refresh → counts match a raw GROUP BY exactly
--   - late-arriving INSERT creates two version rows for the affected bucket
--   - rollup.<name>_at(t) reconstructs the OLD value before the cutover
--   - rollup.<name>_at(t) reconstructs the NEW value after the cutover
--   - rollup.<name>_diff(t1, t2) marks the changed bucket
--   - second refresh with no source changes is a no-op (idempotency)
--   - rollup.drop() cleans every artifact and rollup is gone
--
-- Assertions use RAISE EXCEPTION so any failure aborts the whole file and the
-- test runner picks up a non-zero exit code.

\set ON_ERROR_STOP on

-- ============================================================================
-- 1. Create the test rollup
-- ============================================================================
SELECT rollup.create(
    name        := 'test_smoke_daily',
    source      := 'ge_transactions',
    time_column := 'traded_at',
    bucket_size := interval '1 day',
    groups      := ARRAY['item_category'],
    aggregates  := ARRAY[
        'count(*) as trade_count',
        'sum(total_gp) as total_volume_gp',
        'count(distinct player_name) as unique_traders',
        'count(*) filter (where txn_type = ''buy'') as buy_count'
    ]
);

DO $$
BEGIN
    IF to_regclass('rollup._test_smoke_daily_versions') IS NULL THEN
        RAISE EXCEPTION 'TEST FAIL [create]: versions table not created';
    END IF;
    IF to_regclass('rollup.test_smoke_daily') IS NULL THEN
        RAISE EXCEPTION 'TEST FAIL [create]: view not created';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'test_smoke_daily_at'
        AND pronamespace = 'rollup'::regnamespace
    ) THEN
        RAISE EXCEPTION 'TEST FAIL [create]: _at() function not generated';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc WHERE proname = 'test_smoke_daily_diff'
        AND pronamespace = 'rollup'::regnamespace
    ) THEN
        RAISE EXCEPTION 'TEST FAIL [create]: _diff() function not generated';
    END IF;
END $$;

-- ============================================================================
-- 2. Initial refresh
-- ============================================================================
SELECT rollup.refresh('test_smoke_daily');

-- ============================================================================
-- 3. Rollup output must match a raw GROUP BY exactly
-- ============================================================================
DO $$
DECLARE
    extra_in_view  bigint;
    missing_in_view bigint;
    mismatched     bigint;
BEGIN
    WITH raw AS (
        SELECT date_trunc('day', traded_at)::timestamptz AS bucket,
               item_category,
               count(*) AS trade_count,
               sum(total_gp) AS total_volume_gp,
               count(distinct player_name) AS unique_traders,
               count(*) FILTER (WHERE txn_type = 'buy') AS buy_count
        FROM ge_transactions GROUP BY 1, 2
    ),
    cmp AS (
        SELECT
          count(*) FILTER (WHERE r.bucket IS NULL) AS extra_in_view,
          count(*) FILTER (WHERE v.bucket IS NULL) AS missing_in_view,
          count(*) FILTER (WHERE r.bucket IS NOT NULL AND v.bucket IS NOT NULL
                           AND (r.trade_count, r.total_volume_gp, r.unique_traders, r.buy_count)
                               IS DISTINCT FROM
                               (v.trade_count, v.total_volume_gp, v.unique_traders, v.buy_count))
            AS mismatched
        FROM raw r
        FULL JOIN rollup.test_smoke_daily v
          ON r.bucket = v.bucket AND r.item_category IS NOT DISTINCT FROM v.item_category
    )
    SELECT * INTO extra_in_view, missing_in_view, mismatched FROM cmp;

    IF extra_in_view > 0 OR missing_in_view > 0 OR mismatched > 0 THEN
        RAISE EXCEPTION 'TEST FAIL [refresh parity]: extra=%, missing=%, mismatched=%',
            extra_in_view, missing_in_view, mismatched;
    END IF;
END $$;

-- ============================================================================
-- 4. Idempotency: a second refresh with no source changes must be a no-op
-- ============================================================================
SELECT rollup.refresh('test_smoke_daily');

DO $$
DECLARE
    inserted_n bigint;
    closed_n   bigint;
BEGIN
    SELECT rows_inserted, rows_closed INTO inserted_n, closed_n
    FROM rollup._refresh_log
    WHERE rollup_name = 'test_smoke_daily'
    ORDER BY id DESC LIMIT 1;

    IF inserted_n <> 0 OR closed_n <> 0 THEN
        RAISE EXCEPTION 'TEST FAIL [idempotency]: no-op refresh inserted=%, closed=% (expected 0, 0)',
            inserted_n, closed_n;
    END IF;
END $$;

-- ============================================================================
-- 5. Late-arriving data — capture pre-state, insert, refresh, verify
-- ============================================================================

-- Pick a target bucket within the default 3-day lookback so a vanilla refresh()
-- picks it up. Source max is 2024-12-31, so high_water_mark advances to
-- 2025-01-01 after the initial refresh, and the lookback window starts at
-- 2024-12-29. Inserting on 2024-12-30 sits comfortably inside that window.
DO $$
DECLARE
    before_trade_count    bigint;
    before_total_volume_gp bigint;
    expected_new_total    bigint;
    after_trade_count     bigint;
    after_total_volume_gp bigint;
    bucket_versions       bigint;
    closed_versions       bigint;
BEGIN
    -- Pre-state
    SELECT trade_count, total_volume_gp
      INTO before_trade_count, before_total_volume_gp
      FROM rollup.test_smoke_daily
     WHERE bucket = '2024-12-30'::timestamptz AND item_category = 'Weapons';

    IF before_trade_count IS NULL THEN
        RAISE EXCEPTION 'TEST FAIL [late arrival setup]: no pre-existing data for target bucket';
    END IF;

    expected_new_total := before_total_volume_gp + 1100000000;

    -- Insert the late-arriving Twisted Bow
    INSERT INTO ge_transactions (
        player_name, item_name, item_category, txn_type,
        quantity, price_per_unit, world, is_members, traded_at
    ) VALUES (
        'Employee-TEST-LATE', 'Twisted Bow', 'Weapons', 'sell',
        1, 1100000000, 301, true,
        '2024-12-30 14:30:00+00'
    );

    -- Refresh — lookback should catch this
    PERFORM rollup.refresh('test_smoke_daily');

    -- Post-state
    SELECT trade_count, total_volume_gp
      INTO after_trade_count, after_total_volume_gp
      FROM rollup.test_smoke_daily
     WHERE bucket = '2024-12-30'::timestamptz AND item_category = 'Weapons';

    IF after_trade_count <> before_trade_count + 1 THEN
        RAISE EXCEPTION 'TEST FAIL [late arrival]: trade_count expected %, got %',
            before_trade_count + 1, after_trade_count;
    END IF;
    IF after_total_volume_gp <> expected_new_total THEN
        RAISE EXCEPTION 'TEST FAIL [late arrival]: total_volume_gp expected %, got %',
            expected_new_total, after_total_volume_gp;
    END IF;

    -- Version history check: this (bucket, group) must now have 2 rows total,
    -- exactly 1 closed and 1 current.
    SELECT count(*), count(*) FILTER (WHERE NOT _is_current)
      INTO bucket_versions, closed_versions
      FROM rollup._test_smoke_daily_versions
     WHERE bucket = '2024-12-30'::timestamptz AND item_category = 'Weapons';

    IF bucket_versions <> 2 THEN
        RAISE EXCEPTION 'TEST FAIL [versioning]: expected 2 version rows, got %', bucket_versions;
    END IF;
    IF closed_versions <> 1 THEN
        RAISE EXCEPTION 'TEST FAIL [versioning]: expected 1 closed row, got %', closed_versions;
    END IF;
END $$;

-- ============================================================================
-- 6. _at() reconstructs historical and current state correctly
-- ============================================================================
DO $$
DECLARE
    cutover_ts    timestamptz;
    old_created   timestamptz;
    was_count     bigint;
    is_count      bigint;
    was_total     bigint;
    is_total      bigint;
    new_count     bigint;
    new_total     bigint;
BEGIN
    -- Boundary timestamps for the bucket we just modified
    SELECT _version_from, _version_to
      INTO old_created, cutover_ts
      FROM rollup._test_smoke_daily_versions
     WHERE bucket = '2024-12-30'::timestamptz
       AND item_category = 'Weapons'
       AND NOT _is_current;

    -- Current (new) value
    SELECT trade_count, total_volume_gp
      INTO new_count, new_total
      FROM rollup.test_smoke_daily
     WHERE bucket = '2024-12-30'::timestamptz AND item_category = 'Weapons';

    -- _at() right BEFORE the cutover — should return the OLD (pre-late-arrival) value
    SELECT trade_count, total_volume_gp
      INTO was_count, was_total
      FROM rollup.test_smoke_daily_at(cutover_ts - interval '1 millisecond')
     WHERE bucket = '2024-12-30'::timestamptz AND item_category = 'Weapons';

    IF was_count = new_count THEN
        RAISE EXCEPTION
            'TEST FAIL [_at before cutover]: expected old value, got current (count=%, total=%)',
            was_count, was_total;
    END IF;
    IF was_total + 1100000000 <> new_total THEN
        RAISE EXCEPTION
            'TEST FAIL [_at before cutover]: old + Twisted Bow (1.1B) should equal new; got was=%, new=%',
            was_total, new_total;
    END IF;

    -- _at() right AFTER the cutover — should return the NEW (current) value
    SELECT trade_count, total_volume_gp
      INTO is_count, is_total
      FROM rollup.test_smoke_daily_at(cutover_ts + interval '1 millisecond')
     WHERE bucket = '2024-12-30'::timestamptz AND item_category = 'Weapons';

    IF is_count <> new_count OR is_total <> new_total THEN
        RAISE EXCEPTION
            'TEST FAIL [_at after cutover]: expected current value (count=%, total=%), got (count=%, total=%)',
            new_count, new_total, is_count, is_total;
    END IF;
END $$;

-- ============================================================================
-- 7. _diff() marks the changed bucket
-- ============================================================================
DO $$
DECLARE
    cutover_ts  timestamptz;
    old_created timestamptz;
    n_changed   bigint;
    n_other     bigint;
BEGIN
    SELECT _version_from, _version_to
      INTO old_created, cutover_ts
      FROM rollup._test_smoke_daily_versions
     WHERE bucket = '2024-12-30'::timestamptz
       AND item_category = 'Weapons'
       AND NOT _is_current;

    SELECT
        count(*) FILTER (WHERE change_type = 'changed'
                           AND bucket = '2024-12-30'::timestamptz
                           AND item_category = 'Weapons'),
        count(*) FILTER (WHERE change_type = 'changed'
                           AND NOT (bucket = '2024-12-30'::timestamptz
                                    AND item_category = 'Weapons'))
      INTO n_changed, n_other
      FROM rollup.test_smoke_daily_diff(
             cutover_ts - interval '1 millisecond',
             cutover_ts + interval '1 millisecond'
           );

    IF n_changed <> 1 THEN
        RAISE EXCEPTION
            'TEST FAIL [_diff]: expected exactly 1 changed row for (2024-12-30, Weapons); got %', n_changed;
    END IF;
    IF n_other > 0 THEN
        RAISE EXCEPTION
            'TEST FAIL [_diff]: unexpected other changed buckets: %', n_other;
    END IF;
END $$;

-- ============================================================================
-- 8. Drop the rollup — every artifact must disappear
-- ============================================================================
SELECT rollup.drop('test_smoke_daily');

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM rollup._registry WHERE name = 'test_smoke_daily') THEN
        RAISE EXCEPTION 'TEST FAIL [drop]: registry row still present';
    END IF;
    IF to_regclass('rollup._test_smoke_daily_versions') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAIL [drop]: versions table still present';
    END IF;
    IF to_regclass('rollup.test_smoke_daily') IS NOT NULL THEN
        RAISE EXCEPTION 'TEST FAIL [drop]: view still present';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_proc WHERE proname IN ('test_smoke_daily_at','test_smoke_daily_diff')
        AND pronamespace = 'rollup'::regnamespace
    ) THEN
        RAISE EXCEPTION 'TEST FAIL [drop]: generated helper functions still present';
    END IF;
END $$;

-- ============================================================================
-- 9. Clean up the test late-arrival row in the source
-- ============================================================================
DELETE FROM ge_transactions WHERE player_name = 'Employee-TEST-LATE';

\echo '== test_smoke: ALL ASSERTIONS PASSED =='
