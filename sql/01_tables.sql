-- =====================================================================
-- Tables.
--
-- Deliberately wide. That is a choice about this workload, and it is
-- not a recommendation to avoid joins in ClickHouse.
--
-- Be clear about that up front, because "denormalise everything" is
-- advice that has aged badly. ClickHouse supports every standard join
-- type plus SEMI, ANTI and ASOF, across six algorithms (hash, parallel
-- hash, grace hash, full sorting merge, partial merge, direct), with
-- automatic algorithm selection from statistics and global join
-- reordering. TPC-H join performance improved roughly fourfold through
-- 2025 and has kept improving through 2026 -- runtime filters, faster
-- outer joins, better correlated subqueries. If a join makes your schema
-- simpler and your data easier to manage, that is a good reason to use
-- one.
--
-- Denormalisation earns its place here for two specific reasons.
--
-- 1. Cost. Denormalised attributes are cheap in a column store.
--    `player_vip_tier` over ten billion rows is four distinct values:
--    LowCardinality dictionary-encodes it to a byte per row and ZSTD
--    takes most of that back. Section 10 of 10_verify.sql measures the
--    real per-column footprint rather than asserting it. Columns you do
--    not SELECT cost nothing to read.
--
-- 2. Concurrency. This dataset exists to be queried by agents, so one
--    question becomes dozens of simultaneous queries. A join holds
--    memory for the life of the query, and under that kind of fan-out
--    memory is what gets tight first. Forty concurrent scans need less
--    of it than forty concurrent joins, however well optimised.
--
-- So `bets` carries the attributes it is filtered and grouped by, and
-- the reference tables below source the dictionaries and answer the
-- questions that are genuinely about the catalogue itself.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS igaming;

-- ---------------------------------------------------------------------
-- Two conventions in this file that you should NOT copy by default.
--
-- Explicit codecs. Nearly every column below names a codec. ClickHouse's
-- default compression is already very good, and the right thing when
-- designing a schema is to leave codecs alone, measure real data, then
-- tune the specific columns that justify it. They are spelled out here
-- because this dataset's compression footprint is itself one of the
-- things being demonstrated, and because writing `Delta` on a monotonic
-- timestamp makes the reason visible to someone reading the DDL. That is
-- a teaching choice, not a recommendation.
--
-- Monthly partitioning. PARTITION BY toYYYYMM(ts) below is for data
-- management, not query speed: it makes "drop last June" a metadata
-- operation and keeps the observation window in three or four parts. The
-- thing that actually makes queries fast is the ORDER BY key. Do not
-- partition in the hope of faster SELECTs, and do not partition finely
-- enough to produce hundreds of partitions -- rg_events below is
-- unpartitioned for exactly that reason.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- bets -- the wide event table. Almost every question lands here, and
-- almost none of them need a join.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS igaming.bets;
CREATE TABLE igaming.bets
(
    bet_id                     UInt64 CODEC(Delta, ZSTD(1)),
    ts                         DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    settled_ts                 DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),

    -- ---- player, denormalised -----------------------------------
    player_id                  UInt32 CODEC(ZSTD(1)),
    player_country             LowCardinality(String),
    player_vip_tier            LowCardinality(String),   -- whale | high | mid | casual
    player_kyc_status          LowCardinality(String),   -- verified | pending | failed
    player_registered_on       Date CODEC(ZSTD(1)),
    player_birth_year          UInt16 CODEC(ZSTD(1)),
    player_acq_channel         LowCardinality(String),
    -- Booleans rather than the nullable amounts, because the question
    -- asked of them is almost always "did they set one at all".
    player_has_deposit_limit   Bool,
    player_self_excluded       Bool,

    -- ---- brand and regulator, denormalised ----------------------
    brand_id                   LowCardinality(String),
    brand_name                 LowCardinality(String),
    jurisdiction               LowCardinality(String),
    licence_body               LowCardinality(String),

    -- ---- session and device -------------------------------------
    session_id                 UInt64 CODEC(ZSTD(1)),
    device                     LowCardinality(String),
    os                         LowCardinality(String),
    app_version                LowCardinality(String),
    ip_country                 LowCardinality(String),
    geo_mismatch               Bool,

    -- ---- product, denormalised ----------------------------------
    vertical                   LowCardinality(String),   -- casino | live | sportsbook | bingo
    provider_id                LowCardinality(String),
    game_id                    UInt16 CODEC(ZSTD(1)),
    game_name                  LowCardinality(String),
    game_volatility            LowCardinality(String),
    -- The game's advertised return to player, carried on every row so
    -- that actual-versus-theoretical is a single scan with no join.
    -- This is the column that makes ANOMALY 1 findable.
    theoretical_rtp            Decimal(6, 4) CODEC(ZSTD(1)),
    market_id                  UInt16 CODEC(ZSTD(1)),
    sport                      LowCardinality(String),
    competition                LowCardinality(String),
    market_name                LowCardinality(String),

    -- ---- money --------------------------------------------------
    currency                   LowCardinality(String),
    stake                      Decimal(18, 4) CODEC(ZSTD(1)),
    payout                     Decimal(18, 4) CODEC(ZSTD(1)),
    stake_eur                  Decimal(18, 4) CODEC(ZSTD(1)),
    payout_eur                 Decimal(18, 4) CODEC(ZSTD(1)),
    -- Gross gaming revenue. Stored rather than aliased so it can be
    -- read by projections and skip indexes as well as by queries; the
    -- storage cost of a Decimal that is usually a small number, under
    -- ZSTD, is close to nothing.
    ggr_eur                    Decimal(18, 4) MATERIALIZED stake_eur - payout_eur CODEC(ZSTD(1)),
    odds                       Decimal(10, 3) CODEC(ZSTD(1)),

    is_bonus                   Bool,
    is_live                    Bool,                     -- in-play, not live-dealer
    status                     LowCardinality(String),   -- settled | void | cashout | open

    -- ---- operations ---------------------------------------------
    -- How long the platform took to accept the wager. The mean is
    -- boring and the p99 is the thing that ends up in an incident
    -- review, which is exactly why quantile pushdown matters.
    accept_latency_ms          UInt16 CODEC(ZSTD(1))
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (brand_id, vertical, ts)
SETTINGS index_granularity = 8192;

-- A projection for player-centric reads ("this whale's last 500 bets",
-- "did this account breach its limit"), which the ORDER BY above cannot
-- serve because it leads with brand_id.
--
-- Note the order of operations, because this example inverts the advice
-- and should say so. Get the sorting key right first: it is the biggest
-- lever on query performance and it costs nothing extra. Only reach for
-- a projection (https://clickhouse.com/docs/data-modeling/projections)
-- when a *secondary* pattern is still slow afterwards, and
-- validate it against production-scale data before committing, because
-- projections are not free. This one roughly doubles the table's
-- footprint, adds work on every insert, and at scale the planner spends
-- time evaluating it.
--
-- It is created here at schema time only because this repository ships
-- a known, fixed pair of access patterns and the projection is part of
-- what the dataset is demonstrating. Do not copy that habit into a
-- schema you are still designing. To drop it:
--
--   ALTER TABLE igaming.bets DROP PROJECTION bets_by_player;
ALTER TABLE igaming.bets ADD PROJECTION bets_by_player
(
    SELECT *
    ORDER BY (player_id, ts)
);

-- Skip index for the fraud and RG lookups that filter on a single
-- session rather than a player.
ALTER TABLE igaming.bets
    ADD INDEX idx_session session_id TYPE bloom_filter(0.01) GRANULARITY 4;


-- ---------------------------------------------------------------------
-- payments -- deposits and withdrawals. Its own event stream because
-- payments happen without bets and vice versa.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS igaming.payments;
CREATE TABLE igaming.payments
(
    txn_id              UInt64 CODEC(Delta, ZSTD(1)),
    ts                  DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),

    player_id           UInt32 CODEC(ZSTD(1)),
    player_country      LowCardinality(String),
    player_vip_tier     LowCardinality(String),
    player_kyc_status   LowCardinality(String),

    brand_id            LowCardinality(String),
    brand_name          LowCardinality(String),
    jurisdiction        LowCardinality(String),

    txn_type            LowCardinality(String),   -- deposit | withdrawal
    method              LowCardinality(String),   -- card | apple_pay | trustly | ...
    psp                 LowCardinality(String),   -- payment service provider
    card_scheme         LowCardinality(String),   -- '' for non-card methods

    currency            LowCardinality(String),
    amount              Decimal(18, 4) CODEC(ZSTD(1)),
    amount_eur          Decimal(18, 4) CODEC(ZSTD(1)),

    status              LowCardinality(String),   -- approved | declined | pending | reversed
    decline_reason      LowCardinality(String),   -- '' when approved
    latency_ms          UInt32 CODEC(ZSTD(1)),
    is_first_deposit    Bool,
    device              LowCardinality(String)
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (brand_id, psp, ts);


-- ---------------------------------------------------------------------
-- sessions -- one row per login. Sessions with no bets in them are a
-- real and interesting population, so this is not derivable from bets.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS igaming.sessions;
CREATE TABLE igaming.sessions
(
    session_id          UInt64 CODEC(ZSTD(1)),
    player_id           UInt32 CODEC(ZSTD(1)),
    brand_id            LowCardinality(String),
    jurisdiction        LowCardinality(String),
    started_at          DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    ended_at            DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    duration_s          UInt32 CODEC(ZSTD(1)),
    device              LowCardinality(String),
    os                  LowCardinality(String),
    app_version         LowCardinality(String),
    ip_country          LowCardinality(String),
    player_country      LowCardinality(String),
    geo_mismatch        Bool,
    bet_count           UInt32 CODEC(ZSTD(1)),
    login_method        LowCardinality(String)    -- password | biometric | sso | magic_link
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(started_at)
ORDER BY (brand_id, started_at);


-- ---------------------------------------------------------------------
-- rg_events -- responsible gaming. A small table with outsized
-- consequences: these are the rows where an agent reasoning over a
-- sample produces a confident answer that a regulator later reads.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS igaming.rg_events;
CREATE TABLE igaming.rg_events
(
    event_id            UInt64 CODEC(Delta, ZSTD(1)),
    ts                  DateTime64(3, 'UTC') CODEC(Delta, ZSTD(1)),
    player_id           UInt32 CODEC(ZSTD(1)),
    player_vip_tier     LowCardinality(String),
    player_country      LowCardinality(String),
    brand_id            LowCardinality(String),
    brand_name          LowCardinality(String),
    jurisdiction        LowCardinality(String),
    licence_body        LowCardinality(String),
    event_type          LowCardinality(String),
        -- limit_set | limit_changed | limit_hit | cool_off | self_exclude
        -- | reality_check | affordability_flag | intervention_sent
    triggered_by        LowCardinality(String),   -- player | operator | automated
    threshold_eur       Nullable(Decimal(12, 2)),
    observed_eur        Nullable(Decimal(12, 2)),
    -- Whether a human reviewed the automated flag. The gap between
    -- flagged and reviewed is the compliance story.
    reviewed            Bool,
    notes               String CODEC(ZSTD(3))
)
ENGINE = MergeTree
-- Deliberately unpartitioned, unlike the other event tables.
--
-- These rows are not confined to the observation window: a limit_set
-- event carries the date the player actually set the limit, which can be
-- 2014, and a self_exclude carries a date in the future. Partitioning
-- monthly gave 150-odd partitions and ClickHouse rejected the insert --
-- correctly. Its error message is the lesson: partitions exist for data
-- manipulation, not for query speed, and the ORDER BY key is what makes
-- range queries fast. This table is small, so it needs no partitions at
-- all.
ORDER BY (brand_id, ts);


-- =====================================================================
-- Reference tables.
--
-- Small, slow-moving, and mostly here to source the dictionaries in
-- 03_dictionaries.sql. Query them directly when you want the catalogue
-- itself ("which providers do we carry", "which games launched in
-- 2025"); do not join them onto `bets` for attributes `bets` already
-- has.
-- =====================================================================

DROP TABLE IF EXISTS igaming.brands;
CREATE TABLE igaming.brands
(
    brand_id        LowCardinality(String),
    brand_name      String,
    jurisdiction    LowCardinality(String),
    licence_body    LowCardinality(String),
    base_currency   LowCardinality(String),
    tz_offset_hours Int8,
    launched_on     Date
)
ENGINE = MergeTree ORDER BY brand_id;

DROP TABLE IF EXISTS igaming.games;
CREATE TABLE igaming.games
(
    game_id         UInt16,
    game_name       String,
    provider_id     LowCardinality(String),
    vertical        LowCardinality(String),
    theoretical_rtp Decimal(6, 4),
    volatility      LowCardinality(String),
    -- Pareto tail index and hit rate implied by the volatility class.
    -- Generator inputs, kept here so the data is reproducible from the
    -- catalogue alone.
    tail_alpha      Float32,
    hit_rate        Float32,
    min_stake_eur   Decimal(10, 2),
    max_stake_eur   Decimal(10, 2),
    launched_on     Date
)
ENGINE = MergeTree ORDER BY game_id;

DROP TABLE IF EXISTS igaming.markets;
CREATE TABLE igaming.markets
(
    market_id       UInt16,
    sport           LowCardinality(String),
    competition     LowCardinality(String),
    market_name     String,
    margin          Float32     -- bookmaker overround
)
ENGINE = MergeTree ORDER BY market_id;

-- The full player record. `bets` carries the attributes queries
-- actually filter on; this holds the rest, including the nullable
-- amounts that the booleans on `bets` flatten.
DROP TABLE IF EXISTS igaming.players;
CREATE TABLE igaming.players
(
    player_id           UInt32 CODEC(Delta, ZSTD(1)),
    brand_id            LowCardinality(String),
    jurisdiction        LowCardinality(String),
    country             LowCardinality(String),
    registered_at       DateTime('UTC') CODEC(Delta, ZSTD(1)),
    birth_year          UInt16 CODEC(ZSTD(1)),
    kyc_status          LowCardinality(String),
    vip_tier            LowCardinality(String),
    acquisition_channel LowCardinality(String),
    preferred_currency  LowCardinality(String),
    -- NULL means no limit set, which is not the same as a limit of zero.
    -- The number of agent-written WHERE clauses that get this wrong is
    -- the reason it is modelled honestly.
    deposit_limit_eur   Nullable(Decimal(12, 2)),
    self_excluded_until Nullable(Date),
    is_closed           Bool
)
ENGINE = MergeTree ORDER BY player_id;

DROP TABLE IF EXISTS igaming.fx_rates;
CREATE TABLE igaming.fx_rates
(
    rate_date   Date,
    currency    LowCardinality(String),
    eur_per_1   Decimal(12, 6)
)
ENGINE = MergeTree ORDER BY (currency, rate_date);
