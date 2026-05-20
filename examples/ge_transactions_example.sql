-- pg_rollup example data: RuneScape Grand Exchange Transactions
-- A totally serious analytics dataset for totally serious business intelligence.
--
-- Creates a table of 5,000 GE transactions spanning 6 months (2024-07 to 2024-12),
-- suitable for demonstrating hourly, daily, and weekly rollups.

DROP TABLE IF EXISTS ge_transactions;

CREATE TABLE ge_transactions (
    txn_id          serial PRIMARY KEY,
    player_name     text NOT NULL,
    item_name       text NOT NULL,
    item_category   text NOT NULL,
    txn_type        text NOT NULL CHECK (txn_type IN ('buy', 'sell')),
    quantity        integer NOT NULL,
    price_per_unit  integer NOT NULL,
    total_gp        bigint GENERATED ALWAYS AS (quantity * price_per_unit) STORED,
    world           integer NOT NULL,
    is_members      boolean NOT NULL DEFAULT true,
    traded_at       timestamptz NOT NULL
);

-- Generate reproducible random data.
-- Items are stored pipe-delimited (name|category|base_price|is_members) because
-- Postgres can't index 2D text[][] arrays by single row — items[i] returns NULL,
-- not the i-th row. string_to_array() on a 1D entry is the canonical workaround.
DO $$
DECLARE
    players text[] := ARRAY[
        'Zezima', 'xX_Dark_Lord_Xx', 'IronBTW', 'GE_Flipper_9000',
        'RuneCrafting_Is_Pain', 'Lumbridge_Noob', 'WoodcuttingAFK',
        'PKer_Was_Here', 'Buying_GF_10gp', 'FlaxPickerPro',
        'SlayerMaster69', 'BankStander420', 'DropPartyHost',
        'TzTok_Chad', 'Wilderness_Tax', 'CookingCape4Life',
        'Bond_Buyer_IRL', 'AgilityCourseAndy', 'NMZ_Sleeper',
        'GnomeChildFan', 'FarmingTickGuru', 'SandCrabAndy',
        'PrayFlicker', 'ThirdAgeOrBust', 'PartyhatDreamer'
    ];
    items text[] := ARRAY[
        'Lobster|Food|180|true',
        'Shark|Food|710|true',
        'Cooked Karambwan|Food|520|true',
        'Monkfish|Food|340|true',
        'Abyssal Whip|Weapons|1650000|true',
        'Dragon Scimitar|Weapons|58000|true',
        'Rune Crossbow|Weapons|9200|true',
        'Toxic Blowpipe|Weapons|2800000|true',
        'Bandos Chestplate|Armour|14200000|true',
        'Dragon Platelegs|Armour|161000|true',
        'Rune Platebody|Armour|38000|false',
        'Amulet of Fury|Jewellery|2400000|true',
        'Berserker Ring|Jewellery|2900000|true',
        'Ring of Wealth|Jewellery|22000|true',
        'Ranarr Seed|Farming|42000|true',
        'Snapdragon Seed|Farming|54000|true',
        'Magic Seed|Farming|121000|true',
        'Yew Logs|Resources|290|false',
        'Magic Logs|Resources|980|true',
        'Runite Ore|Resources|11000|false',
        'Dragon Bones|Prayer|2100|true',
        'Dagannoth Bones|Prayer|7800|true',
        'Nature Rune|Runes|180|false',
        'Death Rune|Runes|210|false',
        'Blood Rune|Runes|340|true',
        'Cannonball|Ammo|155|true',
        'Dragon Arrow|Ammo|680|true',
        'Twisted Bow|Weapons|1050000000|true',
        'Elysian Spirit Shield|Armour|680000000|true',
        '3rd Age Platebody|Armour|1200000000|true'
    ];
    worlds int[] := ARRAY[301,302,303,308,309,312,314,318,320,322,325,329,330,333,336,338,341,344,350,351,354,358,360,362,365,368,370,373,376,378];
    start_date timestamptz := '2024-07-01 00:00:00+00';
    end_date   timestamptz := '2024-12-31 23:59:59+00';
    n int := 5000;
    i int;
    item_rec     text[];
    rnd_type     text;
    rnd_qty      int;
    base_price   int;
    actual_price int;
    rnd_time     timestamptz;
BEGIN
    PERFORM setseed(0.42);

    FOR i IN 1..n LOOP
        item_rec := string_to_array(
            items[1 + floor(random() * array_length(items, 1))::int], '|');

        -- buy/sell ~60/40
        IF random() < 0.6 THEN rnd_type := 'buy'; ELSE rnd_type := 'sell'; END IF;

        -- Quantity bracket depends on item value
        base_price := item_rec[3]::int;
        IF    base_price > 10000000 THEN rnd_qty := 1;                                    -- megarares
        ELSIF base_price >   100000 THEN rnd_qty := 1 + floor(random() *    5)::int;      -- expensive
        ELSIF base_price >     1000 THEN rnd_qty := 1 + floor(random() *  100)::int;      -- mid
        ELSE                              rnd_qty := 10 + floor(random() * 5000)::int;    -- bulk
        END IF;

        -- Price varies +/- 15% from base
        actual_price := greatest(1, (base_price * (0.85 + random() * 0.30))::int);

        -- Random timestamp within range, with a slight bias toward evening hours
        rnd_time := start_date + (random() * (end_date - start_date));
        IF extract(hour from rnd_time) < 10 AND random() < 0.4 THEN
            rnd_time := rnd_time + interval '10 hours';
        END IF;

        INSERT INTO ge_transactions (
            player_name, item_name, item_category, txn_type,
            quantity, price_per_unit, world, is_members, traded_at
        ) VALUES (
            players[1 + floor(random() * array_length(players, 1))::int],
            item_rec[1], item_rec[2], rnd_type,
            rnd_qty, actual_price,
            worlds[1 + floor(random() * array_length(worlds, 1))::int],
            item_rec[4]::boolean,
            rnd_time
        );
    END LOOP;
END $$;

-- Verify
SELECT
    count(*)                                    AS total_transactions,
    count(DISTINCT player_name)                 AS unique_players,
    count(DISTINCT item_name)                   AS unique_items,
    count(DISTINCT item_category)               AS unique_categories,
    min(traded_at)::date                        AS first_trade,
    max(traded_at)::date                        AS last_trade,
    to_char(sum(total_gp), 'FM999,999,999,999,999') || ' gp' AS total_volume
FROM ge_transactions;

-- ── Suggested rollups to try with pg_rollup ────────────────────────────────

-- Daily trade volume by item category — refreshes every 5 minutes
-- SELECT rollup.create(
--     name        := 'ge_daily_by_category',
--     source      := 'ge_transactions',
--     time_column := 'traded_at',
--     bucket_size := interval '1 day',
--     groups      := ARRAY['item_category'],
--     aggregates  := ARRAY[
--         'count(*) as trade_count',
--         'sum(total_gp) as total_volume_gp',
--         'count(distinct player_name) as unique_traders',
--         'count(*) filter (where txn_type = ''buy'') as buy_count',
--         'count(*) filter (where txn_type = ''sell'') as sell_count'
--     ],
--     schedule    := '*/5 * * * *'
-- );

-- Hourly price tracking per item
-- SELECT rollup.create(
--     name        := 'ge_hourly_prices',
--     source      := 'ge_transactions',
--     time_column := 'traded_at',
--     bucket_size := interval '1 hour',
--     groups      := ARRAY['item_name'],
--     aggregates  := ARRAY[
--         'count(*) as trade_count',
--         'round(avg(price_per_unit)::numeric, 0) as avg_price',
--         'min(price_per_unit) as low_price',
--         'max(price_per_unit) as high_price',
--         'sum(quantity) as total_quantity',
--         'sum(total_gp) as total_volume_gp'
--     ],
--     schedule    := '*/5 * * * *'
-- );

-- Weekly player leaderboard
-- SELECT rollup.create(
--     name        := 'ge_weekly_traders',
--     source      := 'ge_transactions',
--     time_column := 'traded_at',
--     bucket_size := interval '1 week',
--     groups      := ARRAY['player_name'],
--     aggregates  := ARRAY[
--         'count(*) as trade_count',
--         'sum(total_gp) as total_volume_gp',
--         'count(distinct item_name) as unique_items_traded',
--         'round(avg(total_gp)::numeric, 0) as avg_trade_value',
--         'max(total_gp) as biggest_trade'
--     ],
--     schedule    := '*/5 * * * *'
-- );
