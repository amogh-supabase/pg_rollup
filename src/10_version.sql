-- rollup.version() — returns the installed pg_rollup version as a text string.
-- Bump the literal below when cutting a new release.

CREATE OR REPLACE FUNCTION rollup.version()
RETURNS text AS $$
    SELECT '0.1.0'::text;
$$ LANGUAGE sql IMMUTABLE;
