# pg_rollup

Bi-temporal, versioned, incremental rollups for PostgreSQL. Answers "what does the rollup say now?" and "what did it say last week?" from the same table.

**[View the project website](https://amogh-supabase.github.io/pg_rollup/)**

pg_rollup is the anti-extension: pure SQL, no compilation, no superuser, no `CREATE EXTENSION`. Install with `psql -f install.sql`. Every refresh is versioned — old values are closed (not overwritten) and new ones are inserted, so the rollup carries a full audit trail. Query the current truth as a regular view, or replay the rollup at any historical timestamp.

## Architecture

Each rollup tracks two timelines:

| Timeline               | What it answers              | Object                                | Cost                       |
|------------------------|------------------------------|---------------------------------------|----------------------------|
| **As-is** (now)        | "What's true right now?"     | `rollup.<name>` (view)                | Index lookup, free         |
| **As-was** (then)      | "What did it say at time T?" | `rollup.<name>_at(t)` (generated fn)  | One row per change, ever   |

Every refresh updates the underlying `rollup._<name>_versions` table by closing any current row whose value changed (setting `_version_to = now()`, `_is_current = false`) and inserting a new row. Rows whose values didn't change are left alone — no version churn from no-op refreshes.

The lookback window (`bucket_size × 3` by default) catches late-arriving source data automatically. For older targeted rescans, pass `since := ...` to `rollup.refresh()`.

## Requirements

- PostgreSQL 15, 16, 17, or 18
- Optional: `pg_cron` extension — only needed if you want scheduled refreshes
- **No superuser required.** Everything runs in user-space SQL.

## Quick start

```bash
# Install (idempotent — safe to re-run for upgrades)
psql "$PGROLLUP_DB" -f install.sql
```

```sql
-- Create a versioned rollup
SELECT rollup.create(
    name        := 'ge_daily_by_category',
    source      := 'ge_transactions',
    time_column := 'traded_at',
    bucket_size := interval '1 day',
    groups      := ARRAY['item_category'],
    aggregates  := ARRAY[
        'count(*) as trade_count',
        'sum(total_gp) as total_volume_gp',
        'count(distinct player_name) as unique_traders'
    ],
    schedule    := '*/5 * * * *'     -- optional pg_cron
);

-- Initial population
SELECT rollup.refresh('ge_daily_by_category');

-- Query the current truth
SELECT * FROM rollup.ge_daily_by_category ORDER BY bucket DESC;
```

To try the full walkthrough with a synthetic 5,000-row dataset, run [`examples/ge_transactions_example.sql`](examples/ge_transactions_example.sql) to seed the source table, then step through [`examples/ge_analytics.sql`](examples/ge_analytics.sql).

## Common workflows

### As-is — query the current view

The rollup is a regular view filtered to `_is_current`. Drop-in for any dashboard or CSV export.

```sql
SELECT bucket::date, item_category, trade_count, total_volume_gp
FROM rollup.ge_daily_by_category
WHERE bucket > now() - interval '30 days'
ORDER BY total_volume_gp DESC;
```

### Late-arriving data

When a source row lands late for an already-rolled-up bucket, the next refresh catches it via the lookback window. The old value is closed (with `_version_to` set to now), and the new value is inserted.

```sql
-- A Twisted Bow trade settles weeks after the rollup was first computed
INSERT INTO ge_transactions (player_name, item_name, item_category, txn_type,
                             quantity, price_per_unit, world, is_members, traded_at)
VALUES ('Zezima', 'Twisted Bow', 'Weapons', 'sell',
        1, 1100000000, 301, true,
        '2024-12-20 14:30:00+00');

SELECT rollup.refresh('ge_daily_by_category');
```

### As-was — point-in-time reconstruction

Every rollup gets a generated `rollup.<name>_at(timestamptz)` function with the same column shape as the view. Passing a historical timestamp replays the rollup exactly as it existed then.

```sql
-- What did the rollup show last Wednesday at 9 AM?
SELECT * FROM rollup.ge_daily_by_category_at('2024-12-18 09:00');

-- Same query, 24 hours ago — useful for daily comparisons
SELECT *
FROM rollup.ge_daily_by_category_at(now() - interval '24 hours')
WHERE item_category = 'Weapons';
```

### Diff — what changed between two snapshots

`rollup.<name>_diff(time_a, time_b)` returns one row per `(bucket, group)` with paired `_a` / `_b` columns for every aggregate and a `change_type` marker.

```sql
SELECT bucket::date, item_category,
       trade_count_a, trade_count_b,
       total_volume_gp_a, total_volume_gp_b,
       (total_volume_gp_b - total_volume_gp_a) AS delta,
       change_type
FROM rollup.ge_daily_by_category_diff(
       now() - interval '24 hours', now())
WHERE change_type <> 'unchanged'
ORDER BY abs(total_volume_gp_b - total_volume_gp_a) DESC;
```

`change_type` is one of `added`, `removed`, `changed`, `unchanged`.

### Backfill — initial population of a large source

`rollup.backfill()` is a **procedure** (not a function). It commits between batches, so populating a rollup from a multi-million-row source doesn't hold one giant transaction. Must be called as a top-level statement.

```sql
-- Iterates the source in weekly chunks, committing each one
CALL rollup.backfill('ge_daily_by_category', batch_size := interval '1 week');
```

If your SQL editor wraps statements in a transaction (Supabase's editor does), use the single-shot equivalent instead:

```sql
SELECT rollup.refresh('ge_daily_by_category', since := '2024-01-01');
```

### Status

```sql
SELECT name,
       high_water_mark::date AS source_freshness,
       last_refresh_at,
       current_rows,
       total_versions,
       pg_size_pretty(size_bytes) AS size
FROM rollup.status();
```

## Safety

pg_rollup is designed to never give a wrong answer and never break the host database:

| Protection                | Description                                                                       |
|---------------------------|-----------------------------------------------------------------------------------|
| **Transactional refresh** | One BEGIN/COMMIT per refresh. Mid-flight failure rolls back everything.           |
| **Smart close-and-insert**| Buckets whose values didn't change keep their existing row. No-op refreshes don't pollute history. |
| **Bounded history**       | `rollup.purge_history(name, older_than)` deletes only closed versions. Current rows are never touched. |
| **No-superuser install**  | Pure user-space SQL. No `CREATE EXTENSION`, no `shared_preload_libraries`.        |

```sql
-- Trim closed versions older than 90 days
SELECT rollup.purge_history('ge_daily_by_category', older_than := interval '90 days');

-- Drop a rollup completely (view, versions table, generated _at/_diff, cron job)
SELECT rollup.drop('ge_daily_by_category');
```

## Configuration

All configuration lives on the rollup itself, set at `rollup.create()` time:

| Parameter         | Default                 | Notes                                                                  |
|-------------------|-------------------------|------------------------------------------------------------------------|
| `bucket_size`     | required                | One of: `1 minute`, `1 hour`, `1 day`, `1 week`, `1 month`, `3 months`, `1 year` |
| `groups`          | `ARRAY[]::text[]`       | Columns to GROUP BY in addition to the time bucket                     |
| `aggregates`      | required                | Pass-through SQL expressions, each ending with `AS <alias>`            |
| `lookback_window` | `bucket_size × 3`       | How far back each refresh re-scans to catch late-arriving data         |
| `schedule`        | NULL                    | pg_cron expression, e.g. `'*/5 * * * *'`. NULL = refresh manually      |

Aggregate expressions are opaque — anything valid in `SELECT ... GROUP BY` works: `count(*) filter (where ...)`, `percentile_cont(...) within group (order by ...)`, math, `round(...)`, `nullif(...)`. Column types are inferred automatically.

The current registry of all rollups lives in `rollup._registry`; execution history in `rollup._refresh_log`.

## Upgrade

Re-running `install.sql` is safe. All function definitions use `CREATE OR REPLACE`; all table creation uses `IF NOT EXISTS`. No data is lost.

```bash
psql "$PGROLLUP_DB" -f install.sql
```

## Uninstall

```bash
# Drops the rollup schema CASCADE and unschedules every pg_cron job pg_rollup created
psql "$PGROLLUP_DB" -f uninstall.sql
```

User-facing views and generated `_at` / `_diff` functions all live in the `rollup` schema, so the CASCADE removes them too. Source tables in `public` are untouched.

## Reference

For the full design rationale, build phases, and architecture decisions, see [pg_rollup_project_plan.md](pg_rollup_project_plan.md).

For a hands-on walkthrough using the synthetic Grand Exchange dataset, see [examples/ge_analytics.sql](examples/ge_analytics.sql).

## License

Licensed under the [Apache License, Version 2.0](LICENSE). See [NOTICE](NOTICE) for attribution.
