-- Test setup: ensures the test prerequisites are in place.
--
--   1. The pg_rollup library is installed (rollup schema exists).
--   2. The ge_transactions table is loaded with the synthetic dataset.
--   3. No leftover test rollups from previous runs.
--
-- Idempotent: safe to run repeatedly. Errors loudly if pg_rollup itself isn't
-- installed (the test harness can't bootstrap that part).

\set ON_ERROR_STOP on

-- ---- 1. pg_rollup must be installed ----------------------------------------
DO $$
BEGIN
    IF to_regclass('rollup._registry') IS NULL THEN
        RAISE EXCEPTION
            'pg_rollup is not installed. Run "psql ... -f install.sql" before the test suite.';
    END IF;
END $$;

-- ---- 2. Load ge_transactions if missing -----------------------------------
-- Identical generator to examples/ge_transactions_example.sql so the test
-- doesn't depend on whether someone seeded it earlier.
DO $$
DECLARE
    players text[] := ARRAY[
        'Zezima','xX_Dark_Lord_Xx','IronBTW','GE_Flipper_9000','RuneCrafting_Is_Pain',
        'Lumbridge_Noob','WoodcuttingAFK','PKer_Was_Here','Buying_GF_10gp','FlaxPickerPro',
        'SlayerMaster69','BankStander420','DropPartyHost','TzTok_Chad','Wilderness_Tax',
        'CookingCape4Life','Bond_Buyer_IRL','AgilityCourseAndy','NMZ_Sleeper','GnomeChildFan',
        'FarmingTickGuru','SandCrabAndy','PrayFlicker','ThirdAgeOrBust','PartyhatDreamer'
    ];
    items text[] := ARRAY[
        'Lobster|Food|180|true','Shark|Food|710|true','Cooked Karambwan|Food|520|true','Monkfish|Food|340|true',
        'Abyssal Whip|Weapons|1650000|true','Dragon Scimitar|Weapons|58000|true','Rune Crossbow|Weapons|9200|true',
        'Toxic Blowpipe|Weapons|2800000|true','Bandos Chestplate|Armour|14200000|true','Dragon Platelegs|Armour|161000|true',
        'Rune Platebody|Armour|38000|false','Amulet of Fury|Jewellery|2400000|true','Berserker Ring|Jewellery|2900000|true',
        'Ring of Wealth|Jewellery|22000|true','Ranarr Seed|Farming|42000|true','Snapdragon Seed|Farming|54000|true',
        'Magic Seed|Farming|121000|true','Yew Logs|Resources|290|false','Magic Logs|Resources|980|true',
        'Runite Ore|Resources|11000|false','Dragon Bones|Prayer|2100|true','Dagannoth Bones|Prayer|7800|true',
        'Nature Rune|Runes|180|false','Death Rune|Runes|210|false','Blood Rune|Runes|340|true',
        'Cannonball|Ammo|155|true','Dragon Arrow|Ammo|680|true','Twisted Bow|Weapons|1050000000|true',
        'Elysian Spirit Shield|Armour|680000000|true','3rd Age Platebody|Armour|1200000000|true'
    ];
    worlds int[] := ARRAY[301,302,303,308,309,312,314,318,320,322,325,329,330,333,336,338,341,344,350,351,354,358,360,362,365,368,370,373,376,378];
    start_date timestamptz := '2024-07-01 00:00:00+00';
    end_date   timestamptz := '2024-12-31 23:59:59+00';
    n int := 5000;
    i int;
    item_rec text[];
    rnd_type text;
    rnd_qty int;
    base_price int;
    actual_price int;
    rnd_time timestamptz;
BEGIN
    IF to_regclass('public.ge_transactions') IS NOT NULL
       AND (SELECT count(*) FROM public.ge_transactions) >= 5000 THEN
        RAISE NOTICE 'ge_transactions already loaded (skipping seed).';
        RETURN;
    END IF;

    DROP TABLE IF EXISTS public.ge_transactions;
    CREATE TABLE public.ge_transactions (
        txn_id          serial PRIMARY KEY,
        player_name     text NOT NULL,
        item_name       text NOT NULL,
        item_category   text NOT NULL,
        txn_type        text NOT NULL CHECK (txn_type IN ('buy','sell')),
        quantity        integer NOT NULL,
        price_per_unit  integer NOT NULL,
        total_gp        bigint GENERATED ALWAYS AS (quantity * price_per_unit) STORED,
        world           integer NOT NULL,
        is_members      boolean NOT NULL DEFAULT true,
        traded_at       timestamptz NOT NULL
    );

    PERFORM setseed(0.42);
    FOR i IN 1..n LOOP
        item_rec := string_to_array(items[1 + floor(random() * array_length(items,1))::int], '|');
        IF random() < 0.6 THEN rnd_type := 'buy'; ELSE rnd_type := 'sell'; END IF;
        base_price := item_rec[3]::int;
        IF    base_price > 10000000 THEN rnd_qty := 1;
        ELSIF base_price >   100000 THEN rnd_qty := 1 + floor(random()*5)::int;
        ELSIF base_price >     1000 THEN rnd_qty := 1 + floor(random()*100)::int;
        ELSE                              rnd_qty := 10 + floor(random()*5000)::int;
        END IF;
        actual_price := greatest(1, (base_price * (0.85 + random()*0.30))::int);
        rnd_time := start_date + (random() * (end_date - start_date));
        IF extract(hour from rnd_time) < 10 AND random() < 0.4 THEN
            rnd_time := rnd_time + interval '10 hours';
        END IF;
        INSERT INTO public.ge_transactions (
            player_name, item_name, item_category, txn_type,
            quantity, price_per_unit, world, is_members, traded_at
        ) VALUES (
            players[1 + floor(random()*array_length(players,1))::int],
            item_rec[1], item_rec[2], rnd_type, rnd_qty, actual_price,
            worlds[1 + floor(random()*array_length(worlds,1))::int],
            item_rec[4]::boolean, rnd_time
        );
    END LOOP;
END $$;

-- ---- 3. Clean up any leftover test rollups --------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM rollup._registry WHERE name = 'test_smoke_daily') THEN
        PERFORM rollup.drop('test_smoke_daily');
    END IF;
    DELETE FROM public.ge_transactions WHERE player_name = 'Employee-TEST-LATE';
END $$;
