# pg_rollup

## What this is
A pure-SQL toolkit that provides versioned, incremental time-bucketed
aggregation for PostgreSQL 15+. No C extensions. Installable with
`psql -f install.sql`.

## Full specification
Read pg_rollup_project_plan.md for the complete project plan, architecture,
and build phases.

## Project structure
- `src/` — SQL source files, numbered for dependency order
- `test/` — SQL test files and bash test runner
- `install.sql` — includes all src/ files in order
- `uninstall.sql` — drops everything cleanly
- `examples/` — self-contained demo scripts

## Development database
- Platform: Supabase (Postgres 17)
- Connection string is in `.env` (gitignored) as `PGROLLUP_DB`
- Load it into the shell before running psql: `set -a; source .env; set +a`
- Connect: `psql "$PGROLLUP_DB"`
- pg_cron is available
- Run files: `psql "$PGROLLUP_DB" -f install.sql`

## Conventions
- All objects live in the `rollup` schema
- Internal tables/objects prefixed with underscore: `rollup._registry`
- User-facing views use clean names: `rollup.api_requests_hourly`
- Functions use PL/pgSQL
- Dynamic SQL uses `format()` with `%I` and `%L` — never concatenate
- All functions should be idempotent where possible
- `install.sql` must be runnable on a clean PG15+ database
- `uninstall.sql` must remove everything without leaving artifacts

## Testing
- Tests are SQL files that raise exceptions on failure
- Run all tests: `bash test/run_tests.sh`
- Each test file should clean up after itself
- Test commands use: `psql "$PGROLLUP_DB" -f test/test_name.sql`

## Key design decisions
- Summary data stored in versioned tables (close-and-insert, not upsert)
- User queries a view (`WHERE _is_current = true`) — never sees version columns
- Incremental refresh uses high-water-mark + lookback window
- pg_cron scheduling is optional (works without it)
- Version history enables `as_of()` and `diff()` — the headline features
