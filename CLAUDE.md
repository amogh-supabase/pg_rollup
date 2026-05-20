{\rtf1\ansi\ansicpg1252\cocoartf2869
\cocoatextscaling0\cocoaplatform0{\fonttbl\f0\fswiss\fcharset0 Helvetica;}
{\colortbl;\red255\green255\blue255;}
{\*\expandedcolortbl;;}
\margl1440\margr1440\vieww11520\viewh8400\viewkind0
\pard\tx720\tx1440\tx2160\tx2880\tx3600\tx4320\tx5040\tx5760\tx6480\tx7200\tx7920\tx8640\pardirnatural\partightenfactor0

\f0\fs24 \cf0 # pg_rollup\
\
## What this is\
A pure-SQL toolkit that provides versioned, incremental time-bucketed\
aggregation for PostgreSQL 15+. No C extensions. Installable with\
`psql -f install.sql`.\
\
## Full specification\
Read pg_rollup_project_plan.md for the complete project plan, architecture,\
and build phases.\
\
## Project structure\
- `src/` \'97 SQL source files, numbered for dependency order\
- `test/` \'97 SQL test files and bash test runner\
- `install.sql` \'97 includes all src/ files in order\
- `uninstall.sql` \'97 drops everything cleanly\
- `examples/` \'97 self-contained demo scripts\
\
## Development database\
- Platform: Supabase (Postgres 17)\
- Connect: `psql "$PGROLLUP_DB"` (connection string in env var)\
- pg_cron is available\
- Run files: `psql "$PGROLLUP_DB" -f install.sql`\
\
## Conventions\
- All objects live in the `rollup` schema\
- Internal tables/objects prefixed with underscore: rollup._registry\
- User-facing views use clean names: rollup.api_requests_hourly\
- Functions use PL/pgSQL\
- Dynamic SQL uses format() with %I and %L \'97 never concatenate\
- All functions should be idempotent where possible\
- install.sql must be runnable on a clean PG15+ database\
- uninstall.sql must remove everything without leaving artifacts\
\
## Testing\
- Tests are SQL files that raise exceptions on failure\
- Run all tests: `bash test/run_tests.sh`\
- Each test file should clean up after itself\
- Test commands use: `psql "$PGROLLUP_DB" -f test/test_name.sql`\
\
## Key design decisions\
- Summary data stored in versioned tables (close-and-insert, not upsert)\
- User queries a view (WHERE _is_current = true) \'97 never sees version columns\
- Incremental refresh uses high-water-mark + lookback window\
- pg_cron scheduling is optional (works without it)\
- Version history enables as_of() and diff() \'97 the headline features}