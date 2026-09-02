-- =====================================================================
-- Reference data.
--
-- Run this before the event tables: the generators read these through
-- dictionaries to get per-game RTP, per-market margin and per-player
-- attributes, so the wide tables end up denormalised from a single
-- source of truth rather than from duplicated literals.
--
-- Parameters (passed by generate.sh via --param_):
--   {n_players:UInt32}   number of player rows
--
-- The observation window is fixed at 2026-06-01 .. 2026-08-31 because
-- the sportsbook data is built around the 2026 World Cup calendar. If
-- you shift the window, shift 04_bets.sql's tournament dates too.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Brands. One operator, eight brands, eight regulated markets.
-- ---------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS igaming.brands;
INSERT INTO igaming.brands VALUES
    ('AUR', 'Aurora Bet',    'GB',    'UKGC',            'GBP',  0, '2016-03-14'),
    ('VEG', 'Vega Casino',   'MT',    'MGA',             'EUR',  1, '2014-09-01'),
    ('IRN', 'Ironhorse',     'CA-ON', 'AGCO',            'CAD', -5, '2022-04-04'),
    ('TIV', 'Tivoli Play',   'DK',    'Spillemyndighed', 'DKK',  1, '2018-11-20'),
    ('NST', 'Northstar',     'SE',    'Spelinspektionen','SEK',  1, '2019-01-02'),
    ('CSV', 'Casa Verde',    'ES',    'DGOJ',            'EUR',  1, '2020-06-15'),
    ('KES', 'Kestrel',       'NL',    'KSA',             'EUR',  1, '2021-10-01'),
    ('BLP', 'Bluepeak',      'RO',    'ONJN',            'RON',  2, '2017-05-08');

-- ---------------------------------------------------------------------
-- Games. 420 titles across four verticals.
--
-- Volatility class drives the Pareto tail and hit rate; theoretical RTP
-- is set per vertical the way a real portfolio looks -- slots in the
-- low nineties, live dealer up near 99%, bingo well below.
-- ---------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS igaming.games;
INSERT INTO igaming.games
WITH
    ['Nordic Reels','Helix Studios','Panther Gaming','Lumen Live',
     'Atlas Originals','Redwood','Kite Interactive','Sable Studios'] AS providers,
    ['Gold','Crimson','Frozen','Emerald','Midnight','Ancient','Wild','Royal',
     'Thunder','Sacred','Neon','Iron','Lucky','Cosmic','Feral','Velvet'] AS adj,
    ['Pharaoh','Kraken','Bison','Orchid','Temple','Reels','Fortune','Vault',
     'Serpent','Compass','Anvil','Lantern','Falcon','Harvest','Tiger','Comet'] AS noun,
    ['Megaways','Deluxe','Bonanza','II','Cash Drop','Hold & Win','Gigablox',''] AS suffix,
    ['Blackjack','Roulette','Baccarat','Casino Hold''em','Dragon Tiger',
     'Lightning Roulette','Speed Blackjack','Sic Bo'] AS live_names,
    ['Salon','Grand','Prestige','VIP','Turbo','Classic'] AS live_prefix
SELECT
    toUInt16(n + 1)                                            AS game_id,
    multiIf(
        vert = 'live',
            concat(live_prefix[1 + (cityHash64(n, 91) % 6)], ' ',
                   live_names[1 + (cityHash64(n, 92) % 8)]),
        vert = 'bingo',
            concat('Bingo ', toString(75 + (cityHash64(n, 93) % 16)), ' Room ',
                   char(65 + toUInt8(cityHash64(n, 94) % 8))),
        -- slots
            trimBoth(concat(
                adj[1 + (cityHash64(n, 95) % 16)], ' ',
                noun[1 + (cityHash64(n, 96) % 16)], ' ',
                suffix[1 + (cityHash64(n, 97) % 8)]))
    )                                                          AS game_name,
    providers[1 + (cityHash64(n, 98) % 8)]                     AS provider_id,
    vert                                                       AS vertical,
    toDecimal64(
        multiIf(
            vert = 'live',  0.9700 + u(n, 11) * 0.0250,   -- 97.0 .. 99.5
            vert = 'bingo', 0.8400 + u(n, 12) * 0.0600,   -- 84.0 .. 90.0
                            0.9200 + u(n, 13) * 0.0550),  -- 92.0 .. 97.5
        4)                                                     AS theoretical_rtp,
    vol                                                        AS volatility,
    -- Pareto tail index. Lower = fatter tail = bigger rare wins.
    --
    -- These are deliberately above 2.0 for every class except 'high'.
    -- A Pareto with alpha <= 2 has infinite variance, which means the
    -- realised RTP of those games never settles no matter how many rows
    -- you generate -- an earlier draft used 1.4 and high-volatility
    -- games came out 6.7% off their theoretical RTP at ten million
    -- rows. Fat tails are realistic; unfalsifiable baselines are not.
    multiIf(vol = 'low', 3.2, vol = 'medium', 2.4, 1.9)        AS tail_alpha,
    multiIf(vol = 'low', 0.45, vol = 'medium', 0.26, 0.14)     AS hit_rate,
    toDecimal64(multiIf(vert = 'live', 0.50, vert = 'bingo', 0.05, 0.10), 2)
                                                               AS min_stake_eur,
    toDecimal64(multiIf(vert = 'live', 5000.00, vert = 'bingo', 20.00, 500.00), 2)
                                                               AS max_stake_eur,
    toDate('2014-01-01') + toIntervalDay(toUInt16(u(n, 14) * 4400))
                                                               AS launched_on
FROM
(
    SELECT
        number AS n,
        -- 300 slots, 70 live dealer, 50 bingo rooms.
        multiIf(number < 300, 'casino', number < 370, 'live', 'bingo') AS vert,
        -- Live dealer and bingo are inherently low variance; slots span
        -- the full range with a bias toward medium.
        multiIf(
            number >= 300, 'low',
            u(number, 21) < 0.25, 'low',
            u(number, 21) < 0.75, 'medium',
            'high') AS vol
    FROM numbers(420)
);

-- ---------------------------------------------------------------------
-- Sportsbook markets. Margin is the bookmaker's overround and is the
-- only thing standing between the sportsbook and a 100% RTP.
-- ---------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS igaming.markets;
INSERT INTO igaming.markets VALUES
    (1,  'football',   'FIFA World Cup 2026', 'Match Result 1X2',      0.048),
    (2,  'football',   'FIFA World Cup 2026', 'Over/Under 2.5 Goals',  0.045),
    (3,  'football',   'FIFA World Cup 2026', 'Both Teams To Score',   0.058),
    (4,  'football',   'FIFA World Cup 2026', 'Correct Score',         0.125),
    (5,  'football',   'FIFA World Cup 2026', 'First Goalscorer',      0.142),
    (6,  'football',   'FIFA World Cup 2026', 'Outright Winner',       0.098),
    (7,  'football',   'FIFA World Cup 2026', 'Asian Handicap',        0.042),
    (8,  'football',   'FIFA World Cup 2026', 'In-Play Next Goal',     0.072),
    (9,  'football',   'Premier League',      'Match Result 1X2',      0.050),
    (10, 'football',   'Premier League',      'Over/Under 2.5 Goals',  0.046),
    (11, 'football',   'Premier League',      'Anytime Goalscorer',    0.115),
    (12, 'football',   'La Liga',             'Match Result 1X2',      0.052),
    (13, 'football',   'Serie A',             'Match Result 1X2',      0.052),
    (14, 'tennis',     'ATP Tour',            'Match Winner',          0.038),
    (15, 'tennis',     'ATP Tour',            'Total Games',           0.055),
    (16, 'tennis',     'WTA Tour',            'Match Winner',          0.040),
    (17, 'basketball', 'NBA',                 'Moneyline',             0.040),
    (18, 'basketball', 'NBA',                 'Points Spread',         0.043),
    (19, 'basketball', 'NBA',                 'Player Points O/U',     0.088),
    (20, 'horses',     'UK & IRE Racing',     'Win',                   0.155),
    (21, 'horses',     'UK & IRE Racing',     'Each Way',              0.148),
    (22, 'esports',    'CS2 Majors',          'Map Winner',            0.068),
    (23, 'esports',    'League of Legends',   'Match Winner',          0.065),
    (24, 'cricket',    'T20 Internationals',  'Match Winner',          0.055);

-- ---------------------------------------------------------------------
-- FX rates. Daily, smooth random walk around a plausible base so that
-- multi-currency GGR needs a real join to a real dimension.
-- ---------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS igaming.fx_rates;
INSERT INTO igaming.fx_rates
WITH
    ['EUR','GBP','CAD','SEK','DKK','RON','USD'] AS ccy,
    [1.0, 1.172, 0.638, 0.0895, 0.1341, 0.2010, 0.928] AS base
SELECT
    toDate('2026-05-25') + toIntervalDay(d)                    AS rate_date,
    ccy[c + 1]                                                 AS currency,
    toDecimal64(
        if(ccy[c + 1] = 'EUR',
           1.0,
           base[c + 1] * (1
               + 0.018 * sin((d + c * 17) / 11.0)
               + 0.004 * (u(d * 10 + c, 55) - 0.5))),
        6)                                                     AS eur_per_1
-- `d` is days since 2026-05-25: the window plus headroom either side.
FROM (SELECT number AS d FROM numbers(105)) AS days
CROSS JOIN (SELECT number AS c FROM numbers(7)) AS currencies;

-- ---------------------------------------------------------------------
-- Players.
--
-- Low player_id == high value. zipf_id() concentrates bets on low ids,
-- so tiering by id is what produces the whale distribution downstream.
-- ---------------------------------------------------------------------
TRUNCATE TABLE IF EXISTS igaming.players;
INSERT INTO igaming.players
WITH
    ['AUR','VEG','IRN','TIV','NST','CSV','KES','BLP'] AS brand_ids,
    ['GB','MT','CA-ON','DK','SE','ES','NL','RO']      AS juris,
    ['GBP','EUR','CAD','DKK','SEK','EUR','EUR','RON'] AS ccy,
    ['seo','affiliate','paid_social','tv','retail_crossover',
     'referral','app_store','sponsorship']            AS channels,
    {n_players:UInt32} AS np
SELECT
    toUInt32(number + 1)                                       AS player_id,
    brand_ids[b + 1]                                           AS brand_id,
    juris[b + 1]                                               AS jurisdiction,
    -- Most players sit in the brand's home market; a slice do not,
    -- which is what makes geo_mismatch interesting later.
    if(u(number, 31) < 0.93,
       juris[b + 1],
       ['GB','IE','DE','FR','PT','IT','PL','NO'][1 + (cityHash64(number, 32) % 8)])
                                                               AS country,
    toDateTime('2014-01-01 00:00:00', 'UTC')
        + toIntervalSecond(toUInt32(pow(u(number, 33), 0.55) * 397440000))
                                                               AS registered_at,
    toUInt16(1957 + toUInt8(pow(u(number, 34), 1.6) * 51))     AS birth_year,
    multiIf(u(number, 35) < 0.88, 'verified',
            u(number, 35) < 0.97, 'pending',
                                  'failed')                    AS kyc_status,
    -- Tiering follows player_id so it lines up with the turnover skew.
    multiIf(number < np * 0.01,  'whale',
            number < np * 0.06,  'high',
            number < np * 0.30,  'mid',
                                 'casual')                     AS vip_tier,
    channels[1 + (cityHash64(number, 36) % 8)]                 AS acquisition_channel,
    ccy[b + 1]                                                 AS preferred_currency,
    -- ~38% of players have set a deposit limit. The rest are NULL, not
    -- zero -- an important difference when an agent writes the WHERE.
    if(u(number, 37) < 0.38,
       toDecimal64(([50, 100, 250, 500, 1000, 2500, 5000]
                    [1 + (cityHash64(number, 38) % 7)]), 2),
       NULL)                                                   AS deposit_limit_eur,
    -- ~1.2% are self-excluded, most of them still inside the exclusion.
    if(u(number, 39) < 0.012,
       toDate('2026-01-01') + toIntervalDay(toUInt16(u(number, 40) * 700)),
       NULL)                                                   AS self_excluded_until,
    u(number, 41) < 0.07                                       AS is_closed
FROM
(
    SELECT
        number,
        toUInt8(cityHash64(number, 30) % 8) AS b
    FROM numbers_mt({n_players:UInt32})
);
