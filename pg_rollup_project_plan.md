# pg_rollup — Project Plan

## What this is

A pure-SQL toolkit that provides **versioned, incremental time-bucketed rollups**
for PostgreSQL 15+. No C extensions. No external runtime. Install with
`psql -f install.sql`.

Every refresh preserves the previous rollup state. You can always query the
current truth, and you can always reconstruct what the rollup showed at any
previous point in time.

pg_rollup fills the gap left by TimescaleDB's continuous aggregates (deprecated
from Supabase in Postgres 17, default image moving June 15, 2026) while adding
something no rollup system in the Postgres ecosystem provides: **rollup version
history with point-in-time reconstruction.**

---

## The problem

Applications accumulate event tables that grow by thousands or millions of rows
per day. Analysts and data engineers build rollup tables (hourly, daily, monthly
summaries) to make dashboards fast.

Two problems exist today:

### 1. Rollup refresh on managed Postgres is all-or-nothing

Materialized views recompute from scratch on every refresh. TimescaleDB solved
this with incremental continuous aggregates, but Supabase dropped TimescaleDB
from Postgres 17 due to maintenance burden. pg_ivm is not available on managed
platforms. There is no pure-SQL solution for incremental rollups.

### 2. Rollups lose their history

Every rollup system — materialized views, TimescaleDB continuous aggregates,
dbt incremental models, custom cron jobs — overwrites previous values on
refresh. When late-arriving data changes a historical bucket, the old value is
gone. Nobody can answer:

- "What did last Tuesday's number show when the CEO looked at it Wednesday morning?"
- "The board slides said 47 hires in July. Now the dashboard says 49. Which was right?"
- "When exactly did this metric change, and by how much?"

These are the questions that business analysts and stakeholders actually ask,
and no tool in the Postgres ecosystem can answer them.

---

## The value proposition

pg_rollup creates incrementally-maintained summary tables where **every refresh
is versioned**. You query the current truth by default. When you need to
reconstruct what the rollup showed at a previous point in time, you call a
function.

```sql
-- Create a versioned rollup over a hire events table
SELECT rollup.create(
    name        := 'hires_weekly',
    source      := 'hire',
    time_column := 'eventdate',
    bucket_size := '1 week',
    groups      := ARRAY['employment_start_type'],
    aggregates  := ARRAY[
        'count(*) as hire_count',
        'count(distinct cost_currency_code) as currency_count',
        'sum(relocation_cost) as total_relocation_cost',
        'round(avg(relocation_cost)::numeric, 2) as avg_relocation_cost',
        'count(*) filter (where relocation_cost is not null) as relocated_count'
    ],
    schedule    := '*/5 * * * *'
);

-- Current truth (default view, no filter needed)
SELECT * FROM rollup.hires_weekly ORDER BY bucket, employment_start_type;

-- What did the dashboard show last Wednesday at 9 AM?
SELECT * FROM rollup.as_of('hires_weekly', '2024-06-12 09:00');

-- What changed between Wednesday and today?
SELECT * FROM rollup.diff('hires_weekly', '2024-06-12 09:00', now());
```

**The pitch in one sentence:** pg_rollup gives you fast, incremental rollups
that remember what they said — the only rollup system in Postgres that can
reconstruct what your dashboard showed last week.

---

## Test data

The project uses a real HR hire events table from a Supabase demo instance.

**Table: `hire`** (705 rows)

| Column | Type | Description |
|---|---|---|
| employeeid | text | Employee identifier (e.g. 'Employee-5939') |
| eventdate | date | Date the hire event occurred |
| hire_date | date | Hire date (usually same as eventdate) |
| employment_start_type | text | Category: Growth, Replacement, Critical Growth, Critical Replacement |
| employment_start_reason | text | Specific reason: Growth, Voluntary Replacement, InternalHire, etc. |
| relocation_cost | numeric | Relocation cost (NULL for ~89% of rows, range 10K-120K when present) |
| cost_currency_code | text | Currency: USD, CAD, GBP, AUD, JPY, BRL, EUR, PLN, ARS |

**Key characteristics:**
- Date range: 2020-07-01 to 2020-10-30 (88 distinct dates, ~4 months)
- 2 employees appear twice (rehires on different dates): Employee-6030, Employee-873
- Natural key: (employeeid, eventdate)
- 4 start types, 10 start reasons, 9 currencies
- Only 79 of 705 rows have relocation costs

**Meaningful rollup examples for testing:**

Weekly hires by start type:
```sql
SELECT date_trunc('week', eventdate) AS bucket,
       employment_start_type,
       count(*) AS hire_count,
       count(*) filter (where relocation_cost is not null) AS relocated_count,
       sum(relocation_cost) AS total_relocation_cost
FROM hire
GROUP BY 1, 2
ORDER BY 1, 2;
```

Monthly hires by currency (useful for regional analysis):
```sql
SELECT date_trunc('month', eventdate) AS bucket,
       cost_currency_code,
       count(*) AS hire_count,
       round(avg(relocation_cost)::numeric, 2) AS avg_relocation_cost
FROM hire
GROUP BY 1, 2
ORDER BY 1, 2;
```

---

## Target audience

- Business analysts who need to explain why numbers changed between reports
- Supabase developers migrating off TimescaleDB continuous aggregates
- Solo developers / vibe coders whose event tables outgrew raw queries
- Teams using Postgres for analytics without a separate data warehouse
- Anyone on managed Postgres (RDS, Aurora, Neon) who can't install C extensions

---

## Scope — what we build

### Core (v0.1 — MVP)

1. **`rollup.create()`** — registers a rollup definition, creates the versioned
   summary table and a current-only view, schedules a pg_cron job.

2. **`rollup.refresh()`** — incremental refresh with version history. Closes out
   old versions of affected buckets, inserts new versions. Only scans the
   recent time window, not the full source table.

3. **`rollup.as_of()`** — returns the rollup state as it existed at a given
   point in time. Reconstructs exactly what any query against the rollup would
   have returned at that timestamp.

4. **`rollup.diff()`** — compares the rollup state at two points in time. Shows
   which buckets changed and by how much. Directly answers "why do the numbers
   look different from last week's report?"

5. **`rollup.backfill()`** — processes historical data in batches for when a
   rollup is created on a table that already has months of data.

6. **`rollup.status()`** — shows all registered rollups with freshness, last
   refresh duration, row counts, version counts, and history size.

7. **`rollup.drop()`** — removes a rollup: drops the summary table and view,
   unschedules the pg_cron job, cleans up metadata.

8. **`rollup.purge_history()`** — removes versions older than a specified
   retention window to prevent unbounded growth.

9. **Metadata tables** — `rollup._registry` (rollup definitions),
   `rollup._refresh_log` (execution history).

10. **Install / uninstall scripts** — idempotent and transactional.

### Deferred (v0.2+)

- Rollup chaining (weekly -> monthly -> quarterly, with dependency-ordered refresh)
- Retention policies (auto-purge old versions on a schedule)
- Pause / resume individual rollups
- Schema change detection (alert when source table columns change)
- `rollup.explain()` — shows the generated refresh query without executing
- Optional unversioned mode for users who just want fast rollups without history

### Out of scope

- Real-time aggregation (transparent query-time stitching of materialized +
  unmaterialized data). Requires executor hooks that pure SQL can't provide.
- Chunk-level invalidation tracking. We use high-water-mark + lookback.
- Compression. Use pg_duckdb or Analytics Buckets.
- Automatic partitioning. Use pg_partman.
- Anything that requires a C extension.

---

## Technical approach

### Architecture

```
+--------------------------------------------------------------+
|                    Supabase Postgres instance                 |
|                                                              |
|  +---------------+         +----------------------------+    |
|  | hire           |-------->| rollup._hires_weekly       |    |
|  | (source)       | refresh | _versions (table)          |    |
|  | 705 rows       |         | with version history       |    |
|  +---------------+         +-------------+--------------+    |
|                                          |                   |
|                                   +------v--------------+    |
|                                   | rollup.hires_weekly  |    |
|                                   | (view)               |    |
|                                   | WHERE _is_current    |    |
|                                   +---------------------+    |
|                                                              |
|  +---------------+    +---------------------+                |
|  | rollup        |    | pg_cron             |                |
|  | ._registry    |    | (schedules refresh) |                |
|  | ._refresh_log |    +---------------------+                |
|  +---------------+                                           |
+--------------------------------------------------------------+
```

### Versioned summary table structure

For the `hires_weekly` rollup, the generated table:

```sql
CREATE TABLE rollup._hires_weekly_versions (
    bucket                  timestamptz NOT NULL,
    employment_start_type   text,
    hire_count              bigint,
    relocated_count         bigint,
    total_relocation_cost   numeric,
    avg_relocation_cost     numeric,
    currency_count          bigint,
    _version_from           timestamptz NOT NULL DEFAULT now(),
    _version_to             timestamptz,          -- NULL means current
    _is_current             boolean NOT NULL DEFAULT true,
    _is_partial             boolean NOT NULL DEFAULT false,
    PRIMARY KEY (bucket, employment_start_type, _version_from)
);

-- Index for fast current-only queries
CREATE INDEX ON rollup._hires_weekly_versions (bucket)
WHERE _is_current = true;

-- The user-facing view
CREATE VIEW rollup.hires_weekly AS
SELECT bucket, employment_start_type, hire_count, relocated_count,
       total_relocation_cost, avg_relocation_cost, currency_count
FROM rollup._hires_weekly_versions
WHERE _is_current = true;
```

### How versioned incremental refresh works

```
1. Read the rollup definition from rollup._registry
   -> source table, time column, bucket size, groups, aggregates, high_water_mark

2. Compute the refresh window:
   -> start = high_water_mark - lookback_window  (catches late-arriving data)
   -> end   = date_trunc(bucket_size, now())

3. Run the aggregation query against the source table:
   SELECT
       date_trunc({bucket_size}, {time_column}) AS bucket,
       {groups},
       {aggregates}
   FROM {source}
   WHERE {time_column} >= {start}
     AND {time_column} < {end} + {bucket_size}
   GROUP BY bucket, {groups}

4. Close out old versions for affected buckets:
   UPDATE {versions_table}
   SET _version_to = now(), _is_current = false
   WHERE _is_current = true
     AND bucket >= {start}
     AND bucket <= {end}

5. Insert new versions:
   INSERT INTO {versions_table}
       (bucket, {groups}, {aggregates}, _version_from, _is_current, _is_partial)
   VALUES
       (..., now(), true, <true if bucket is current partial, false otherwise>)

6. Update high_water_mark in rollup._registry

7. Log execution in rollup._refresh_log
```

All steps run in a single transaction. If anything fails, everything rolls back.

### as_of() implementation

```sql
CREATE FUNCTION rollup.as_of(
    rollup_name text,
    as_of_time  timestamptz
) RETURNS SETOF record AS $$
    -- Returns all rows where this version was active at as_of_time:
    -- _version_from <= as_of_time AND (_version_to IS NULL OR _version_to > as_of_time)
    --
    -- Dynamic SQL against the correct versions table
    -- Returns only business columns (no version metadata)
$$ LANGUAGE plpgsql;
```

### diff() implementation

```sql
CREATE FUNCTION rollup.diff(
    rollup_name text,
    time_a      timestamptz,
    time_b      timestamptz
) RETURNS TABLE (...) AS $$
    -- Gets state at both timestamps using as_of() logic
    -- Full outer joins on (bucket, groups)
    -- Returns: bucket, groups, value_a, value_b, delta, change_type
    -- change_type: 'added', 'removed', 'changed', 'unchanged'
$$ LANGUAGE plpgsql;
```

### Late-arriving data

The lookback_window parameter (default: 3x bucket_size) controls how far back
each refresh re-aggregates. When late data arrives for a completed bucket, the
next refresh picks it up, closes the old version, and inserts a new version
with the corrected value. The old version is preserved.

This is the core differentiator: in every other system, the late arrival
silently overwrites the old value. In pg_rollup, it creates a new version.

### Version pruning

```sql
SELECT rollup.purge_history('hires_weekly', older_than := '90 days');
```

Deletes version rows where `_is_current = false` and `_version_to` is older
than the retention threshold. Current rows are never pruned.

---

## Benefits vs. tradeoffs

### What you get (vs. raw materialized views)

| Aspect | REFRESH MATERIALIZED VIEW | pg_rollup |
|---|---|---|
| Refresh cost | Full recompute every time | Scans only recent window |
| History of changes | None - old values overwritten | Full version history |
| "What did it say last week?" | Impossible | rollup.as_of() |
| "What changed?" | Impossible | rollup.diff() |

### What you get (vs. TimescaleDB continuous aggregates)

| Aspect | TimescaleDB caggs | pg_rollup |
|---|---|---|
| Installation | C extension, version-coupled | Pure SQL, psql -f install.sql |
| Managed Postgres | Unavailable on most platforms | Works everywhere |
| Version history | No - overwrites on refresh | Yes - full version trail |
| Point-in-time reconstruction | Not possible | rollup.as_of() |
| Change diff between refreshes | Not possible | rollup.diff() |
| Real-time aggregation | Yes, transparent stitching | No - partial bucket on schedule |

### What you don't get

- Sub-second freshness (minimum pg_cron interval is 1 minute)
- Query-time real-time aggregation (requires executor hooks)
- Chunk-level precision (lookback may re-aggregate unchanged buckets)
- Compression or columnar storage (use Hydra/pg_duckdb)

---

## Project structure

```
pg_rollup/
|-- README.md
|-- LICENSE                          (PostgreSQL license)
|-- CLAUDE.md                        (Claude Code project context)
|-- pg_rollup_project_plan.md        (this file)
|-- install.sql                      (concatenates src/ in order)
|-- uninstall.sql                    (drops schema cascade + pg_cron jobs)
|-- src/
|   |-- 00_prerequisites.sql         (version check, pg_cron detection)
|   |-- 01_schema.sql                (rollup schema, metadata tables)
|   |-- 02_create.sql                (rollup.create function)
|   |-- 03_refresh.sql               (rollup.refresh function)
|   |-- 04_as_of.sql                 (rollup.as_of function)
|   |-- 05_diff.sql                  (rollup.diff function)
|   |-- 06_backfill.sql              (rollup.backfill function)
|   |-- 07_status.sql                (rollup.status function)
|   |-- 08_drop.sql                  (rollup.drop function)
|   |-- 09_purge.sql                 (rollup.purge_history function)
|-- test/
|   |-- setup.sql                    (loads Hire.csv into hire table if needed)
|   |-- test_create.sql
|   |-- test_refresh.sql
|   |-- test_versioning.sql          (verify old versions preserved)
|   |-- test_as_of.sql               (point-in-time reconstruction)
|   |-- test_diff.sql                (change comparison)
|   |-- test_late_arriving.sql
|   |-- test_backfill.sql
|   |-- test_idempotency.sql
|   |-- test_purge.sql
|   |-- test_drop.sql
|   |-- run_tests.sh
|-- examples/
|   |-- hire_analytics.sql           (complete walkthrough using hire data)
|-- data/
|   |-- Hire.csv                     (705-row test dataset)
|-- .github/
    |-- workflows/
        |-- test.yml                 (CI: PG17+, run tests)
```

---

## Build plan for Claude Code

The test data is a `hire` table already loaded in the Supabase demo instance.
705 rows of HR hire events from 2020-07-01 to 2020-10-30.

### Phase 1 — Foundation (get versioned refresh working)

**Step 1: Scaffold**
- Directory structure, CLAUDE.md
- src/00_prerequisites.sql: PG 15+ check, pg_cron detection
- src/01_schema.sql: rollup schema, _registry table, _refresh_log table
- install.sql and uninstall.sql

The _registry table:
```sql
CREATE TABLE rollup._registry (
    name              text PRIMARY KEY,
    source_table      regclass NOT NULL,
    versions_table    text NOT NULL,
    view_name         text NOT NULL,
    time_column       text NOT NULL,
    bucket_size       interval NOT NULL,
    group_columns     text[] NOT NULL DEFAULT '{}',
    aggregate_exprs   text[] NOT NULL,
    aggregate_aliases text[] NOT NULL,
    lookback_window   interval NOT NULL,
    high_water_mark   timestamptz,
    schedule          text,
    cron_job_id       bigint,
    created_at        timestamptz NOT NULL DEFAULT now(),
    is_active         boolean NOT NULL DEFAULT true
);
```

The _refresh_log table:
```sql
CREATE TABLE rollup._refresh_log (
    id                bigserial PRIMARY KEY,
    rollup_name       text NOT NULL REFERENCES rollup._registry(name),
    started_at        timestamptz NOT NULL DEFAULT now(),
    finished_at       timestamptz,
    window_start      timestamptz,
    window_end        timestamptz,
    rows_scanned      bigint,
    rows_inserted     bigint,
    rows_closed       bigint,
    status            text NOT NULL DEFAULT 'running',
    error_message     text
);
```

**Test:** install.sql runs clean, uninstall removes everything, reinstall works.

**Step 2: rollup.create()**
- Validates inputs
- Creates the versions table with correct schema
- Creates the current-only view
- Creates a partial index on _is_current = true
- Inserts into _registry
- Optionally schedules pg_cron job

**Test against hire table:**
```sql
SELECT rollup.create(
    name        := 'hires_weekly',
    source      := 'hire',
    time_column := 'eventdate',
    bucket_size := '1 week',
    groups      := ARRAY['employment_start_type'],
    aggregates  := ARRAY[
        'count(*) as hire_count',
        'count(*) filter (where relocation_cost is not null) as relocated_count',
        'sum(relocation_cost) as total_relocation_cost'
    ]
);
```
Verify: rollup._hires_weekly_versions table exists with correct columns.
Verify: rollup.hires_weekly view exists. Verify: _registry entry exists.

**Step 3: rollup.refresh() — hardcoded first**
- Build against the `hire` table specifically
- Static SQL, no dynamic generation
- Implement the close-and-insert versioning logic
- Verify: versions inserted, high_water_mark advances
- Verify: rollup.hires_weekly view shows correct counts

Validate the rollup against a raw query:
```sql
-- This should match the view output
SELECT date_trunc('week', eventdate) AS bucket,
       employment_start_type,
       count(*) AS hire_count,
       count(*) filter (where relocation_cost is not null) AS relocated_count,
       sum(relocation_cost) AS total_relocation_cost
FROM hire
GROUP BY 1, 2
ORDER BY 1, 2;
```

**Step 4: rollup.refresh() — generalize**
- Refactor to dynamic SQL using format() and EXECUTE
- Read everything from _registry
- Handle arbitrary group columns and aggregate expressions

**Test the versioning behavior:**
1. Run rollup.refresh('hires_weekly') — initial version created
2. Insert a late-arriving hire event:
   ```sql
   INSERT INTO hire VALUES
   ('Employee-9999', '2020-07-15', '2020-07-15', 'Growth', 'Growth', 50000, 'USD');
   ```
3. Run rollup.refresh('hires_weekly') again
4. Verify: the week containing 2020-07-15 now has TWO version rows
   in rollup._hires_weekly_versions — the old version (closed) and
   the new version (current) with updated counts
5. Verify: rollup.hires_weekly view shows only the new version
6. Clean up the test insert

### Phase 2 — The headline features

**Step 5: rollup.as_of()**

**Test scenario:**
1. Run refresh. Record timestamp_1 with `SELECT now()`.
2. Wait: `SELECT pg_sleep(1);`
3. Insert a late hire:
   ```sql
   INSERT INTO hire VALUES
   ('Employee-8888', '2020-08-10', '2020-08-10', 'Replacement',
    'Voluntary Replacement', 75000, 'GBP');
   ```
4. Run refresh again. Record timestamp_2.
5. `rollup.as_of('hires_weekly', timestamp_1)` should show the old
   Replacement count for the week of 2020-08-10.
6. `rollup.as_of('hires_weekly', timestamp_2)` should show the count
   incremented by 1 and total_relocation_cost increased by 75000.
7. Clean up.

**Step 6: rollup.diff()**

**Test scenario:** Using the same timestamps from Step 5:
```sql
SELECT * FROM rollup.diff('hires_weekly', timestamp_1, timestamp_2);
```
Should show:
- The week of 2020-08-10 / Replacement bucket with change_type = 'changed'
- hire_count delta = +1
- total_relocation_cost delta = +75000
- All other buckets with change_type = 'unchanged'

### Phase 3 — Production readiness

**Step 7: rollup.backfill()**

Test: Create a new rollup `hires_monthly` on the hire table. The data
spans 2020-07 to 2020-10. Run backfill with batch_size = '1 month'.
Verify all 4 months are populated.

**Step 8: rollup.status()**

Test: With both `hires_weekly` and `hires_monthly` registered, status()
should show both with correct freshness, version counts, and sizes.

**Step 9: rollup.drop()**

Test: Drop `hires_monthly`. Verify table and view are gone. Verify
_registry entry is removed. Verify `hires_weekly` is unaffected.

**Step 10: rollup.purge_history()**

Test: After multiple refreshes of `hires_weekly`, run purge with a
short retention window. Verify old closed versions are removed.
Verify current versions are untouched.

**Step 11: Comprehensive tests**
- Idempotency: refresh twice with no data changes, verify correctness
- Multiple rollups on same source: hires_weekly and hires_monthly
  coexist and refresh independently
- Complex aggregates: test with percentile, filter, and math expressions
- NULL handling: relocation_cost is NULL for most rows, verify aggregates
  handle this correctly (sum ignores NULLs, count doesn't)
- Verify rollup works with an additional test:
  ```sql
  SELECT rollup.create(
      name        := 'hires_monthly_by_currency',
      source      := 'hire',
      time_column := 'eventdate',
      bucket_size := '1 month',
      groups      := ARRAY['cost_currency_code'],
      aggregates  := ARRAY[
          'count(*) as hire_count',
          'round(100.0 * count(*) filter (where employment_start_type = ''Growth'') / nullif(count(*), 0), 1) as growth_pct',
          'sum(relocation_cost) as total_relocation_cost'
      ]
  );
  ```

### Phase 4 — Ship

**Step 12:** examples/hire_analytics.sql — full walkthrough using the hire
data, demonstrating create, refresh, as_of, diff, and the business value
of versioned rollups in an HR analytics context.

**Step 13:** README emphasizing "rollups that remember"

**Step 14:** GitHub Actions CI, v0.1.0 release, community posts

---

## Key implementation decisions

### Naming convention
- Versions table: rollup._<name>_versions (underscore prefix = internal)
- User-facing view: rollup.<name> (clean name, no version columns)

### Dynamic SQL generation
Use format() with %I (identifier) and %L (literal) throughout.
Never concatenate user input directly into SQL strings.

### Aggregate expression handling
Aggregate expressions are opaque SQL strings. Do NOT attempt to parse,
validate, or transform them beyond extracting the alias. Pass them through
to Postgres via format() and let Postgres validate them with a LIMIT 0
test query. Anything valid in a SELECT ... GROUP BY works, including:
- count(*) filter (where condition)
- percentile_cont(0.95) within group (order by col)
- round(sum(a) / nullif(count(*), 0)::numeric, 2)
- count(distinct col)

Extract alias by splitting on the last ' as ' (case-insensitive).
Reject expressions without an alias.

### pg_cron dependency
Optional. If pg_cron is not available, everything works — the user
calls rollup.refresh('name') manually or from an external scheduler.

### Postgres version compatibility
Target PG 15+ for broad compatibility. Use date_trunc() for bucketing.
Test on PG 17 (current Supabase default).

---

## Success criteria

1. A developer goes from psql -f install.sql to a working versioned rollup
   over the hire table in under 5 minutes.
2. rollup.as_of() correctly reconstructs rollup state at any historical timestamp.
3. rollup.diff() accurately shows what changed between two points in time,
   including the impact of late-arriving hire events.
4. The test suite passes on PG 17.
5. Total codebase is under 2,500 lines of SQL.
