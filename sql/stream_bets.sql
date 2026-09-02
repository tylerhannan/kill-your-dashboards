-- =====================================================================
-- Live ingest.
--
-- Parameters:
--   {batch:UInt32}      bets per batch
--   {n_players:UInt32}  must match the loaded tier
--
-- Appends bets timestamped `now()` instead of inside the historical
-- window. Run it on a loop (see ../stream.sh) and the dataset stays
-- live while you present, so "what happened in the last thirty seconds"
-- is a real question with a moving answer.
--
-- This is a deliberately simpler generator than 04_bets.sql: one
-- session per batch is not the point here. The point is that a table
-- being written to continuously is still instantly queryable, which is
-- the property that makes a dashboard refresh interval look silly.
-- =====================================================================

INSERT INTO igaming.bets
(
    bet_id, ts, settled_ts,
    player_id, player_country, player_vip_tier, player_kyc_status,
    player_registered_on, player_birth_year, player_acq_channel,
    player_has_deposit_limit, player_self_excluded,
    brand_id, brand_name, jurisdiction, licence_body,
    session_id, device, os, app_version, ip_country, geo_mismatch,
    vertical, provider_id, game_id, game_name, game_volatility,
    theoretical_rtp, market_id, sport, competition, market_name,
    currency, stake, payout, stake_eur, payout_eur, odds,
    is_bonus, is_live, status, accept_latency_ms
)
SELECT
    -- Live bet ids sit in their own range so they never collide with
    -- the historical rows or the abuse cohort.
    toUInt64(30000000000 + cityHash64(now64(6), number) % 1000000000) AS bet_id,
    ts,
    ts + toIntervalMillisecond(toUInt32(200 + u(k, 800) * 2600)) AS settled_ts,

    player_id,
    player_country, player_vip_tier, player_kyc_status,
    player_registered_on, player_birth_year, player_acq_channel,
    player_has_deposit_limit, player_self_excluded,

    brand_id, brand_name, jurisdiction, licence_body,

    session_id,
    device, os, app_version,
    ip_country,
    ip_country != player_country AS geo_mismatch,

    vertical,
    if(vertical = 'sportsbook', 'In-House Sportsbook',
       dictGetString('igaming.dict_games', 'provider_id', game_id)) AS provider_id,
    game_id,
    dictGetString('igaming.dict_games', 'game_name',  game_id) AS game_name,
    dictGetString('igaming.dict_games', 'volatility', game_id) AS game_volatility,
    toDecimal64(rtp, 4) AS theoretical_rtp,
    market_id,
    dictGetString('igaming.dict_markets', 'sport',       market_id) AS sport,
    dictGetString('igaming.dict_markets', 'competition', market_id) AS competition,
    dictGetString('igaming.dict_markets', 'market_name', market_id) AS market_name,

    currency,
    toDecimal64(stake_eur  / fx, 4) AS stake,
    toDecimal64(payout_eur / fx, 4) AS payout,
    toDecimal64(stake_eur,  4)      AS stake_eur,
    toDecimal64(payout_eur, 4)      AS payout_eur,
    toDecimal64(odds, 3)            AS odds,

    is_bonus, is_live,
    'settled' AS status,
    toUInt16(least(65535.0, 8 + pow(u(k, 801), -0.42) * 22)) AS accept_latency_ms
FROM
(
    SELECT
        *,
        multiIf(
            vertical = 'sportsbook',
                if(u(k, 810) < (1.0 / odds) * (1.0 - margin), stake_eur * odds, 0.0),
            u(k, 810) < hit_rate,
                stake_eur * rtp * least(pareto_unit(k, 811, tail_alpha), 20000.0) / hit_rate,
            0.0
        ) AS payout_eur
    FROM
    (
        SELECT
            number,
            -- Seeded from wall-clock time, so every batch is different.
            -- This is the one place the dataset is intentionally
            -- non-reproducible: live data that replayed identically
            -- would not be live.
            cityHash64(now64(6), number) AS k,

            now64(3, 'UTC') - toIntervalMillisecond(toUInt32(u(k, 820) * 2000)) AS ts,

            zipf_id(k, 821, {n_players:UInt32}) AS player_id,
            dictGetString('igaming.dict_players', 'country',    player_id) AS player_country,
            dictGetString('igaming.dict_players', 'vip_tier',   player_id) AS player_vip_tier,
            dictGetString('igaming.dict_players', 'kyc_status', player_id) AS player_kyc_status,
            dictGetDate('igaming.dict_players', 'registered_on', player_id) AS player_registered_on,
            dictGetUInt16('igaming.dict_players', 'birth_year',  player_id) AS player_birth_year,
            dictGetString('igaming.dict_players', 'acq_channel', player_id) AS player_acq_channel,
            dictGetUInt8('igaming.dict_players', 'has_deposit_limit', player_id) = 1
                AS player_has_deposit_limit,
            dictGetUInt8('igaming.dict_players', 'self_excluded', player_id) = 1
                AS player_self_excluded,

            dictGetString('igaming.dict_players', 'brand_id', player_id) AS brand_id,
            dictGetString('igaming.dict_brands', 'brand_name',    tuple(brand_id)) AS brand_name,
            dictGetString('igaming.dict_brands', 'jurisdiction',  tuple(brand_id)) AS jurisdiction,
            dictGetString('igaming.dict_brands', 'licence_body',  tuple(brand_id)) AS licence_body,
            dictGetString('igaming.dict_brands', 'base_currency', tuple(brand_id)) AS currency,
            dictGetFloat64('igaming.dict_fx', 'eur_per_1', tuple(currency)) AS fx,

            cityHash64('live', player_id, intDiv(toUnixTimestamp(now()), 900)) AS session_id,

            ['mobile', 'desktop', 'tablet'][wpick(session_id, 822, [0.71, 0.21, 0.08])] AS device,
            multiIf(
                device = 'mobile', ['iOS', 'Android'][1 + (cityHash64(session_id, 823) % 2)],
                device = 'tablet', ['iPadOS', 'Android'][1 + (cityHash64(session_id, 823) % 2)],
                ['Windows', 'macOS', 'Linux'][wpick(session_id, 823, [0.72, 0.25, 0.03])]
            ) AS os,
            if(device = 'desktop',
               ['web-4.3', 'web-4.4'][wpick(session_id, 824, [0.3, 0.7])],
               ['app-9.3', 'app-10.0'][wpick(session_id, 824, [0.4, 0.6])]) AS app_version,
            if(u(session_id, 825) < 0.96, player_country,
               ['GB','IE','DE','FR','PT','IT','PL','NO','MT','CY']
                   [1 + (cityHash64(session_id, 826) % 10)]) AS ip_country,

            ['casino', 'live', 'sportsbook', 'bingo']
                [wpick(session_id, 827, [0.60, 0.14, 0.22, 0.04])] AS vertical,

            multiIf(
                vertical = 'casino', toUInt16(1   + pow(u(k, 828), 2.2) * 299),
                vertical = 'live',   toUInt16(301 + pow(u(k, 828), 1.6) * 69),
                vertical = 'bingo',  toUInt16(371 + u(k, 828) * 49),
                toUInt16(0)) AS game_id,
            if(vertical = 'sportsbook', toUInt16(9 + u(k, 829) * 15), toUInt16(0)) AS market_id,

            dictGetFloat32('igaming.dict_games', 'rtp',        game_id) AS rtp,
            dictGetFloat32('igaming.dict_games', 'tail_alpha', game_id) AS tail_alpha,
            dictGetFloat32('igaming.dict_games', 'hit_rate',   game_id) AS hit_rate,
            dictGetFloat32('igaming.dict_markets', 'margin',   market_id) AS margin,

            if(vertical = 'sportsbook',
               1.10 + (dictGetFloat32('igaming.dict_markets', 'max_odds', market_id) - 1.10)
                      * pow(u(k, 830), 3.0),
               0.0) AS odds,

            if(vertical = 'sportsbook', u(session_id, 831) < 0.35, false) AS is_live,
            u(session_id, 832) < 0.11 AS is_bonus,

            multiIf(
                player_vip_tier = 'whale', 20.0,
                player_vip_tier = 'high',   4.0,
                player_vip_tier = 'mid',    1.6,
                1.0) AS tier_mult,

            if(vertical = 'sportsbook',
               least(greatest(0.50 * exp(pow(u(k, 833), 1.7) * 6.2) * tier_mult, 0.50), 25000.0),
               least(greatest(
                   dictGetFloat32('igaming.dict_games', 'min_stake_eur', game_id)
                       * exp(pow(u(k, 833), 1.9) * 5.2) * tier_mult,
                   dictGetFloat32('igaming.dict_games', 'min_stake_eur', game_id)),
                   dictGetFloat32('igaming.dict_games', 'max_stake_eur', game_id))
            ) AS stake_eur
        FROM numbers({batch:UInt32})
    )
);
