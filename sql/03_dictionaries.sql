-- =====================================================================
-- Dictionaries.
--
-- The wide tables are denormalised, but the values are not duplicated by
-- hand -- the generators read them through these dictionaries, so the
-- reference tables in 02_reference.sql stay the single source of truth
-- for RTP, margin, licence body and player attributes.
--
-- A dictionary is an in-memory key-value lookup. `dictGet` is a good fit
-- when you want a handful of attributes from a small, slow-moving table
-- on a per-row basis, as the generators do here millions of times over.
-- It is a complement to joins rather than a replacement: a join is the
-- right tool the moment you need the whole right-hand table, more than a
-- few columns from it, or anything other than an equality lookup on its
-- key. ClickHouse's `direct` join algorithm will use a dictionary for
-- you where one applies.
--
-- Memory: dict_players is the only large one. Roughly 90 bytes per
-- player, so ~18 MB at the 200k tier, ~1.8 GB at the 20M tier. If that
-- is not available, generate the bets table in date-range chunks.
-- =====================================================================

DROP DICTIONARY IF EXISTS igaming.dict_games;
CREATE DICTIONARY igaming.dict_games
(
    game_id         UInt16,
    game_name       String,
    vertical        String,
    provider_id     String,
    volatility      String,
    rtp             Float32,
    tail_alpha      Float32,
    hit_rate        Float32,
    min_stake_eur   Float32,
    max_stake_eur   Float32
)
PRIMARY KEY game_id
SOURCE(CLICKHOUSE(QUERY '
    SELECT
        game_id, game_name, vertical, provider_id, volatility,
        toFloat32(theoretical_rtp)  AS rtp,
        tail_alpha,
        hit_rate,
        toFloat32(min_stake_eur)    AS min_stake_eur,
        toFloat32(max_stake_eur)    AS max_stake_eur
    FROM igaming.games'))
LIFETIME(MIN 600 MAX 900)
LAYOUT(FLAT(INITIAL_ARRAY_SIZE 1024 MAX_ARRAY_SIZE 65536));

DROP DICTIONARY IF EXISTS igaming.dict_markets;
CREATE DICTIONARY igaming.dict_markets
(
    market_id       UInt16,
    sport           String,
    competition     String,
    market_name     String,
    margin          Float32,
    -- Longest price the market realistically offers, which sets the
    -- shape of the odds distribution: a 1X2 market tops out near 12, a
    -- correct-score market runs to 150.
    max_odds        Float32
)
PRIMARY KEY market_id
SOURCE(CLICKHOUSE(QUERY '
    SELECT
        market_id, sport, competition, market_name, margin,
        multiIf(
            market_name = ''Correct Score'',       150.0,
            market_name = ''First Goalscorer'',     60.0,
            market_name = ''Anytime Goalscorer'',   18.0,
            market_name = ''Outright Winner'',      80.0,
            market_name = ''Win'',                  66.0,
            market_name = ''Each Way'',             40.0,
            market_name = ''Moneyline'',             7.0,
            market_name = ''Both Teams To Score'',   3.2,
            market_name = ''In-Play Next Goal'',    15.0,
            market_name LIKE ''%Over/Under%'',       4.0,
            market_name LIKE ''%Handicap%'',         4.5,
            market_name LIKE ''%Total Games%'',      5.0,
            market_name LIKE ''%Spread%'',           4.5,
            market_name LIKE ''%Player Points%'',    8.0,
            12.0) AS max_odds
    FROM igaming.markets'))
LIFETIME(MIN 600 MAX 900)
LAYOUT(FLAT(INITIAL_ARRAY_SIZE 64 MAX_ARRAY_SIZE 4096));

DROP DICTIONARY IF EXISTS igaming.dict_brands;
CREATE DICTIONARY igaming.dict_brands
(
    brand_id        String,
    brand_name      String,
    jurisdiction    String,
    licence_body    String,
    base_currency   String,
    tz_offset_hours Int8
)
PRIMARY KEY brand_id
SOURCE(CLICKHOUSE(QUERY '
    SELECT brand_id, brand_name, jurisdiction, licence_body,
           base_currency, tz_offset_hours
    FROM igaming.brands'))
LIFETIME(MIN 600 MAX 900)
LAYOUT(COMPLEX_KEY_HASHED());

-- Latest rate per currency. The daily series lives in fx_rates for
-- anyone who wants a proper as-of join; this is the fast path.
DROP DICTIONARY IF EXISTS igaming.dict_fx;
CREATE DICTIONARY igaming.dict_fx
(
    currency    String,
    eur_per_1   Float64
)
PRIMARY KEY currency
SOURCE(CLICKHOUSE(QUERY '
    SELECT currency, toFloat64(argMax(eur_per_1, rate_date)) AS eur_per_1
    FROM igaming.fx_rates
    GROUP BY currency'))
LIFETIME(MIN 600 MAX 900)
LAYOUT(COMPLEX_KEY_HASHED());

-- The player attributes that get denormalised onto every event row.
-- Booleans are UInt8 because that is what dictionaries store.
DROP DICTIONARY IF EXISTS igaming.dict_players;
CREATE DICTIONARY igaming.dict_players
(
    player_id           UInt32,
    brand_id            String,
    country             String,
    vip_tier            String,
    kyc_status          String,
    acq_channel         String,
    preferred_currency  String,
    registered_on       Date,
    birth_year          UInt16,
    has_deposit_limit   UInt8,
    self_excluded       UInt8
)
PRIMARY KEY player_id
SOURCE(CLICKHOUSE(QUERY '
    SELECT
        player_id,
        brand_id,
        country,
        vip_tier,
        kyc_status,
        acquisition_channel                   AS acq_channel,
        preferred_currency,
        toDate(registered_at)                 AS registered_on,
        birth_year,
        deposit_limit_eur IS NOT NULL         AS has_deposit_limit,
        self_excluded_until IS NOT NULL       AS self_excluded
    FROM igaming.players'))
LIFETIME(MIN 3600 MAX 7200)
LAYOUT(FLAT(INITIAL_ARRAY_SIZE 1048576 MAX_ARRAY_SIZE 50000000));
