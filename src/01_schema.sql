-- pg_rollup schema and metadata tables.

CREATE SCHEMA IF NOT EXISTS rollup;

-- One row per registered rollup. Holds the definition needed to refresh,
-- reconstruct, and drop the rollup. Tracks the high_water_mark to enable
-- incremental refresh without rescanning the full source table.
CREATE TABLE IF NOT EXISTS rollup._registry (
    name              text PRIMARY KEY,
    source_table      regclass NOT NULL,
    versions_table    text     NOT NULL,
    view_name         text     NOT NULL,
    time_column       text     NOT NULL,
    bucket_size       interval NOT NULL,
    group_columns     text[]   NOT NULL DEFAULT '{}',
    aggregate_exprs   text[]   NOT NULL,
    aggregate_aliases text[]   NOT NULL,
    lookback_window   interval NOT NULL,
    high_water_mark   timestamptz,
    schedule          text,
    cron_job_id       bigint,
    created_at        timestamptz NOT NULL DEFAULT now(),
    is_active         boolean     NOT NULL DEFAULT true
);

-- One row per refresh attempt. Status transitions: 'running' -> 'success' | 'error'.
-- Cascade-deleted when a rollup is dropped.
CREATE TABLE IF NOT EXISTS rollup._refresh_log (
    id            bigserial PRIMARY KEY,
    rollup_name   text NOT NULL REFERENCES rollup._registry(name) ON DELETE CASCADE,
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    window_start  timestamptz,
    window_end    timestamptz,
    rows_scanned  bigint,
    rows_inserted bigint,
    rows_closed   bigint,
    status        text NOT NULL DEFAULT 'running',
    error_message text
);

CREATE INDEX IF NOT EXISTS _refresh_log_rollup_started_idx
    ON rollup._refresh_log (rollup_name, started_at DESC);
