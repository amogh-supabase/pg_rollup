-- =============================================================================
-- pg_rollup walkthrough — Grand Exchange trade analytics
-- =============================================================================
-- Prerequisites:
--   * pg_rollup is installed in this database (`psql -f install.sql`).
--   * `ge_transactions` is loaded — run examples/ge_transactions_example.sql once
--     to generate 5,000 trades spanning 2024-07-01 to 2024-12-31.
--
-- Run each numbered block on its own in the Supabase SQL editor — the
-- output of one block informs what you'll see in the next.
-- =============================================================================


-- ── 1. Confirm the setup ─────────────────────────────────────────────────────
-- Hard guard: pg_rollup must be installed AND ge_transactions must be loaded.
-- If anything's missing, the error tells you exactly which file to run.
DO $$
BEGIN
    IF to_regclass('rollup._registry') IS NULL THEN
        RAISE EXCEPTION 'pg_rollup is not installed. Run "psql ... -f install.sql" first.';
    END IF;
    IF to_regclass('public.ge_transactions') IS NULL THEN
        RAISE EXCEPTION 'ge_transactions table is missing. Run "psql ... -f examples/ge_transactions_example.sql" first to seed the demo dataset.';
    END IF;
END $$;

SELECT (SELECT count(*) FROM ge_transactions) AS ge_rows,    -- expect 5000
       (SELECT count(*) FROM rollup._registry) AS rollups;  -- expect 0 to start


-- ── 2. Create a versioned daily rollup ───────────────────────────────────────
-- Tracks daily volume per item category, with buy/sell breakdown and a
-- distinct-trader count.
SELECT rollup.create(
    name        := 'ge_daily_by_category',
    source      := 'ge_transactions',
    time_column := 'traded_at',
    bucket_size := interval '1 day',
    groups      := ARRAY['item_category'],
    aggregates  := ARRAY[
        'count(*) as trade_count',
        'sum(total_gp) as total_volume_gp',
        'count(distinct player_name) as unique_traders',
        'count(*) filter (where txn_type = ''buy'') as buy_count',
        'count(*) filter (where txn_type = ''sell'') as sell_count'
    ]
);


-- ── 3. Populate it ──────────────────────────────────────────────────────────
-- The first call scans the full source. Subsequent calls only scan the
-- recent window (high_water_mark minus lookback).
SELECT rollup.refresh('ge_daily_by_category');


-- ── 4. Query the rollup as a regular view ────────────────────────────────────
-- A snapshot of the busiest categories in a single recent day.
SELECT bucket::date,
       item_category,
       trade_count,
       to_char(total_volume_gp, 'FM999,999,999,999') || ' gp' AS volume,
       unique_traders,
       buy_count,
       sell_count
FROM rollup.ge_daily_by_category
WHERE bucket = '2024-12-15'::timestamptz
ORDER BY total_volume_gp DESC NULLS LAST;


-- ── 5. Check freshness and footprint ─────────────────────────────────────────
SELECT name,
       high_water_mark::date  AS source_freshness,
       last_refresh_at,
       current_rows,
       total_versions,
       pg_size_pretty(size_bytes) AS size
FROM rollup.status();


-- ── 6. Simulate a late-arriving Twisted Bow trade ────────────────────────────
-- A megarare worth ~1B gp lands days after the dashboard was first compiled.
-- Other rollup systems would silently overwrite the old number. pg_rollup
-- keeps the old value AND the new — both queryable.
INSERT INTO ge_transactions (
    player_name, item_name, item_category, txn_type,
    quantity, price_per_unit, world, is_members, traded_at
) VALUES (
    'Zezima', 'Twisted Bow', 'Weapons', 'sell',
    1, 1100000000, 301, true,
    '2024-12-20 14:30:00+00'
);

SELECT rollup.refresh('ge_daily_by_category');

-- The view now reflects the late trade.
SELECT bucket::date, item_category,
       trade_count,
       to_char(total_volume_gp, 'FM999,999,999,999') || ' gp' AS volume
FROM rollup.ge_daily_by_category
WHERE bucket = '2024-12-20'::timestamptz AND item_category = 'Weapons';


-- ── 7. Time travel — what did the dashboard say BEFORE the megarare landed? ──
-- Every overwritten bucket leaves a closed version row whose _version_to
-- marks the cutover. Pull those timestamps and replay history.
WITH cutover AS (
    SELECT _version_from AS before_ts,
           _version_to   AS cutover_ts
    FROM rollup._ge_daily_by_category_versions
    WHERE bucket = '2024-12-20'::timestamptz
      AND item_category = 'Weapons'
      AND NOT _is_current
)
SELECT 'before megarare' AS phase,
       v.trade_count,
       to_char(v.total_volume_gp, 'FM999,999,999,999') || ' gp' AS volume
FROM cutover, rollup.ge_daily_by_category_at(before_ts) v
WHERE v.bucket = '2024-12-20'::timestamptz AND v.item_category = 'Weapons'

UNION ALL

SELECT 'after megarare',
       v.trade_count,
       to_char(v.total_volume_gp, 'FM999,999,999,999') || ' gp'
FROM cutover, rollup.ge_daily_by_category_at(cutover_ts + interval '1 millisecond') v
WHERE v.bucket = '2024-12-20'::timestamptz AND v.item_category = 'Weapons';


-- ── 8. Diff — exactly what changed between two timestamps ────────────────────
-- Returns one row per (bucket, group) with _a/_b columns for each aggregate
-- and a change_type ('added' | 'removed' | 'changed' | 'unchanged').
WITH cutover AS (
    SELECT _version_from AS before_ts,
           _version_to   AS cutover_ts
    FROM rollup._ge_daily_by_category_versions
    WHERE bucket = '2024-12-20'::timestamptz
      AND item_category = 'Weapons'
      AND NOT _is_current
)
SELECT bucket::date,
       item_category,
       trade_count_a, trade_count_b,
       to_char(total_volume_gp_a, 'FM999,999,999,999') || ' gp' AS volume_before,
       to_char(total_volume_gp_b, 'FM999,999,999,999') || ' gp' AS volume_after,
       to_char(total_volume_gp_b - total_volume_gp_a, 'FM999,999,999,999') || ' gp' AS delta,
       change_type
FROM cutover,
     rollup.ge_daily_by_category_diff(before_ts, cutover_ts + interval '1 millisecond')
WHERE change_type <> 'unchanged'
ORDER BY bucket;


-- ── 9. A second rollup: hourly price tracking ────────────────────────────────
-- Demonstrates min/max/avg aggregates and per-item granularity. Pair this
-- with the daily-by-category rollup to see two rollups coexist on the same
-- source, refreshing independently.
SELECT rollup.create(
    name        := 'ge_hourly_prices',
    source      := 'ge_transactions',
    time_column := 'traded_at',
    bucket_size := interval '1 hour',
    groups      := ARRAY['item_name'],
    aggregates  := ARRAY[
        'count(*) as trade_count',
        'round(avg(price_per_unit)::numeric, 0) as avg_price',
        'min(price_per_unit) as low_price',
        'max(price_per_unit) as high_price',
        'sum(quantity) as total_quantity',
        'sum(total_gp) as total_volume_gp'
    ]
);


-- ── 10. Backfill the hourly rollup in weekly batches ─────────────────────────
-- Six months of hourly buckets across 30 items is ~130k bucket combinations.
-- backfill() is a PROCEDURE (it COMMITs between batches so long backfills
-- don't hold one giant transaction). Run this block on its own.
CALL rollup.backfill('ge_hourly_prices', interval '1 week');

-- If the SQL editor wraps your statements in a transaction and the above
-- errors with "invalid transaction termination", use this single-shot
-- alternative instead:
--   SELECT rollup.refresh('ge_hourly_prices', since := '2024-07-01');


-- ── 11. Sample the hourly rollup — Twisted Bow price history ─────────────────
-- Pick an item with sparse trading to see hour-by-hour variation.
SELECT bucket,
       trade_count,
       to_char(avg_price,   'FM999,999,999,999') AS avg_gp,
       to_char(low_price,   'FM999,999,999,999') AS low_gp,
       to_char(high_price,  'FM999,999,999,999') AS high_gp,
       total_quantity
FROM rollup.ge_hourly_prices
WHERE item_name = 'Twisted Bow'
ORDER BY bucket DESC
LIMIT 8;


-- ── 12. Status overview ──────────────────────────────────────────────────────
SELECT name,
       high_water_mark::date AS source_freshness,
       current_rows,
       total_versions,
       pg_size_pretty(size_bytes) AS size
FROM rollup.status();


-- ── 13. Clean up ─────────────────────────────────────────────────────────────
SELECT rollup.drop('ge_daily_by_category');
SELECT rollup.drop('ge_hourly_prices');
DELETE FROM ge_transactions WHERE player_name = 'Zezima' AND item_name = 'Twisted Bow'
                              AND traded_at = '2024-12-20 14:30:00+00';
