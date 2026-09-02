-- =====================================================================
-- igaming.bets
--
-- Parameters:
--   {n_bets:UInt64}     rows to generate
--   {n_players:UInt32}  must match 02_reference.sql
--
-- Requires 02_reference.sql and 03_dictionaries.sql. Player, brand, game
-- and market attributes are read through dictionaries and written onto
-- every row, which is what lets the common queries filter and group
-- without reaching for another table. See 01_tables.sql for why that
-- suits this workload, and why it is not general advice.
--
-- ---------------------------------------------------------------------
-- Sessions are the unit of generation, not bets.
--
-- The obvious approach -- draw a timestamp per bet from a diurnal curve
-- -- produces a dataset where consecutive bets by one player are days
-- apart. Grouping those into sessions gives about 1.1 bets per session.
-- Real slot sessions are dozens to hundreds of spins a few seconds
-- apart, so every session-level metric built on that data would be
-- wrong, and obviously wrong to anyone who works in the industry.
--
-- So rows are generated in blocks of 96. Each block is split into one
-- or two sessions of between 13 and 83 bets; a session picks the player,
-- the day, the hour, the device and mostly the product, and the bets
-- inside it are spaced seconds apart. Bets per session then averages
-- ~48 with real variance, and session_id is a genuine grouping key.
--
-- Layers, outermost last:
--   L1  the session: who, when, how many bets, where in the block
--   L2  that player's attributes, their brand, the bet's timestamp
--   L3  the product and the stake
--   L4  the outcome and how the platform behaved
--
-- ANOMALY 1 (provider hit-rate drift) and ANOMALY 2 (World Cup final
-- latency) are here, because they are properties of rows that already
-- exist. ANOMALY 3 and 4 are elsewhere. All four: challenges/README.md.
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
    n AS bet_id,
    ts,
    -- Settlement lag by product. A casino round resolves immediately; a
    -- pre-match sportsbook bet can sit open for two days.
    ts + toIntervalMillisecond(
        multiIf(
            vertical != 'sportsbook', toUInt32(200 + u(n, 200) * 2800),
            is_live,                  toUInt32(60000 + u(n, 200) * 5340000),
                                      toUInt32(3600000 + u(n, 200) * 169200000))
    ) AS settled_ts,

    player_id,
    player_country,
    player_vip_tier,
    player_kyc_status,
    player_registered_on,
    player_birth_year,
    player_acq_channel,
    player_has_deposit_limit,
    player_self_excluded,

    brand_id,
    brand_name,
    jurisdiction,
    licence_body,

    session_id,
    device,
    os,
    app_version,
    ip_country,
    ip_country != player_country AS geo_mismatch,

    vertical,
    provider_id,
    game_id,
    game_name,
    game_volatility,
    toDecimal64(theoretical_rtp, 4) AS theoretical_rtp,
    market_id,
    sport,
    competition,
    market_name,

    currency,
    -- Local amounts derive from the EUR figures, so an FX reconciliation
    -- against fx_rates balances exactly.
    toDecimal64(stake_eur  / fx, 4) AS stake,
    toDecimal64(payout_eur / fx, 4) AS payout,
    toDecimal64(stake_eur,  4)      AS stake_eur,
    toDecimal64(payout_eur, 4)      AS payout_eur,
    toDecimal64(odds, 3)            AS odds,

    is_bonus,
    is_live,
    status,
    accept_latency_ms
FROM
(
    -- ================= L4: outcome and platform behaviour =================
    SELECT
        *,
        -- Raw win amount, before status adjustments.
        --
        -- Casino path: E[payout] = stake * rtp, exactly. pareto_unit has
        -- mean 1 by construction and is divided by the configured hit
        -- rate, so realised RTP converges on theoretical RTP. Without
        -- that calibrated baseline there would be nothing for ANOMALY 1
        -- to drift from.
        --
        -- Sportsbook path: E[payout] = stake * (1 - margin), because win
        -- probability is 1/odds discounted by the overround.
        multiIf(
            vertical = 'sportsbook',
                if(u(n, 210) < (1.0 / odds) * (1.0 - margin), stake_eur * odds, 0.0),
            -- Gated on the *effective* hit rate but normalised by the
            -- *configured* one. Outside the anomaly window they are
            -- equal and RTP lands on theoretical. Inside it, the game
            -- pays out 30% more often at unchanged win sizes -- which is
            -- what a bad config push actually looks like.
            u(n, 210) < hit_rate_effective,
                -- The cap is a real slot's max-win rule, not a fudge. At
                -- these alphas it trims well under 1% off the mean,
                -- which 10_verify.sql measures rather than assumes.
                stake_eur * rtp
                          * least(pareto_unit(n, 211, tail_alpha), 20000.0)
                          / hit_rate,
            0.0
        ) AS gross_payout_eur,

        multiIf(
            u(n, 212) < 0.010,                             'void',
            vertical = 'sportsbook' AND u(n, 213) < 0.045, 'cashout',
            vertical = 'sportsbook'
                AND ts > toDateTime64('2026-08-31 22:00:00.000', 3, 'UTC'), 'open',
            'settled'
        ) AS status,

        -- A void returns the stake. A cash-out settles between a third
        -- and one and a half times it. An open bet has paid nothing yet.
        multiIf(
            status = 'void',    stake_eur,
            status = 'cashout', stake_eur * (0.30 + u(n, 214) * 1.20),
            status = 'open',    0.0,
            gross_payout_eur
        ) AS payout_eur,

        -- ANOMALY 2: platform stress during the World Cup final.
        -- In-play acceptance latency inflates roughly sixfold for three
        -- and a half hours on 19 July. Turnover for the day looks
        -- healthy; only the latency tail shows it.
        toUInt16(least(65535.0,
            8 + pow(u(n, 215), -0.42) * 22
              * if(vertical = 'sportsbook'
                   AND is_live
                   AND ts >= toDateTime64('2026-07-19 19:00:00.000', 3, 'UTC')
                   AND ts <  toDateTime64('2026-07-19 22:30:00.000', 3, 'UTC'),
                   6.0, 1.0)
        )) AS accept_latency_ms
    FROM
    (
        -- ================= L3: product and stake =================
        SELECT
            *,
            -- Product is chosen per session, not per bet: players stay
            -- inside one vertical for a session far more often than they
            -- hop. Sportsbook's share of sessions roughly doubles on
            -- tournament days.
            ['casino', 'live', 'sportsbook', 'bingo'][
                wpick(session_id, 220, if(is_wc, [0.44, 0.10, 0.43, 0.03],
                                                 [0.60, 0.14, 0.22, 0.04]))
            ] AS vertical,

            -- Within a session a player works through a handful of
            -- titles rather than one, switching roughly every twelve
            -- bets. game_key is what makes that happen while keeping the
            -- head-heavy popularity curve.
            cityHash64(session_id, intDiv(seq_in_session, 12)) AS game_key,

            multiIf(
                vertical = 'casino', toUInt16(1   + pow(u(game_key, 221), 2.2) * 299),
                vertical = 'live',   toUInt16(301 + pow(u(game_key, 221), 1.6) * 69),
                vertical = 'bingo',  toUInt16(371 + u(game_key, 221) * 49),
                toUInt16(0)
            ) AS game_id,

            -- Markets 1-8 are the World Cup, 9-24 everything else.
            if(vertical = 'sportsbook',
               if(is_wc, toUInt16(1 + pow(u(game_key, 222), 1.5) * 7),
                         toUInt16(9 + u(game_key, 222) * 15)),
               toUInt16(0)) AS market_id,

            dictGetString('igaming.dict_games', 'game_name',   game_id) AS game_name,
            dictGetString('igaming.dict_games', 'volatility',  game_id) AS game_volatility,
            dictGetFloat32('igaming.dict_games', 'rtp',        game_id) AS rtp,
            dictGetFloat32('igaming.dict_games', 'tail_alpha', game_id) AS tail_alpha,
            dictGetFloat32('igaming.dict_games', 'hit_rate',   game_id) AS hit_rate,

            if(vertical = 'sportsbook',
               'In-House Sportsbook',
               dictGetString('igaming.dict_games', 'provider_id', game_id)) AS provider_id,

            dictGetString('igaming.dict_markets', 'sport',       market_id) AS sport,
            dictGetString('igaming.dict_markets', 'competition', market_id) AS competition,
            dictGetString('igaming.dict_markets', 'market_name', market_id) AS market_name,
            dictGetFloat32('igaming.dict_markets', 'margin',     market_id) AS margin,

            -- Price. The cube keeps most stakes on short odds while
            -- leaving a genuine long-shot tail.
            if(vertical = 'sportsbook',
               1.10 + (dictGetFloat32('igaming.dict_markets', 'max_odds', market_id) - 1.10)
                      * pow(u(n, 223), 3.0),
               0.0) AS odds,

            if(vertical = 'sportsbook', u(session_id, 224) < if(is_wc, 0.45, 0.35), false) AS is_live,
            -- Bonus play is a session-level property: you are either
            -- playing through a bonus balance or you are not.
            u(session_id, 225) < 0.11 AS is_bonus,

            -- Stake in EUR: log-scaled, then multiplied by player value.
            -- Casino stakes respect the game's own table limits. The
            -- per-session base means a player's stakes are consistent
            -- within a session, with per-bet variation on top.
            if(vertical = 'sportsbook',
               least(greatest(0.50 * exp(pow(u(session_id, 231), 1.7) * 6.2)
                                   * (0.6 + u(n, 232) * 0.8) * tier_mult, 0.50), 25000.0),
               least(greatest(
                   dictGetFloat32('igaming.dict_games', 'min_stake_eur', game_id)
                       * exp(pow(u(session_id, 231), 1.9) * 5.2)
                       * (0.7 + u(n, 232) * 0.6) * tier_mult,
                   dictGetFloat32('igaming.dict_games', 'min_stake_eur', game_id)),
                   dictGetFloat32('igaming.dict_games', 'max_stake_eur', game_id))
            ) AS stake_eur,

            -- ANOMALY 1: a provider config push that loosened hit
            -- frequency without anyone changing the advertised RTP.
            --
            -- Every Redwood title, across all eight brands, pays out 30%
            -- more often than it should between 02:00 and 14:00 UTC on
            -- 8 July. `theoretical_rtp` on the row is untouched, so the
            -- drift is real and measurable.
            --
            -- Modelled as a hit-rate shift rather than a payout
            -- multiplier deliberately. Hit frequency is binomial and
            -- settles within a few hundred rows; realised RTP is
            -- dominated by rare large wins on large stakes and stays
            -- noisy into the thousands. So this is findable on a laptop
            -- by whoever reasons about hit frequency, and only findable
            -- through RTP once you have a billion rows. That asymmetry
            -- is the lesson, not an accident.
            hit_rate * if(provider_id = 'Redwood'
                          AND ts >= toDateTime64('2026-07-08 02:00:00.000', 3, 'UTC')
                          AND ts <  toDateTime64('2026-07-08 14:00:00.000', 3, 'UTC'),
                          1.30, 1.0) AS hit_rate_effective,

            rtp AS theoretical_rtp
        FROM
        (
            -- ================= L2: player, brand, timestamp =================
            SELECT
                n,
                session_id,
                seq_in_session,
                day,
                is_wc,

                player_id,
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

                -- The bet's brand is the player's brand, by construction.
                dictGetString('igaming.dict_players', 'brand_id', player_id) AS brand_id,
                dictGetString('igaming.dict_brands', 'brand_name',    tuple(brand_id)) AS brand_name,
                dictGetString('igaming.dict_brands', 'jurisdiction',  tuple(brand_id)) AS jurisdiction,
                dictGetString('igaming.dict_brands', 'licence_body',  tuple(brand_id)) AS licence_body,
                dictGetString('igaming.dict_brands', 'base_currency', tuple(brand_id)) AS currency,
                dictGetInt8('igaming.dict_brands', 'tz_offset_hours', tuple(brand_id)) AS tz_off,
                dictGetFloat64('igaming.dict_fx', 'eur_per_1', tuple(currency)) AS fx,

                -- Stake multiplier by player value. Derived from the
                -- player record, not the id, so the turnover skew and
                -- the tier label can never disagree. Paired with
                -- zipf_id's exponent: frequency skew comes from there,
                -- size skew from here. Together, the top 1% of accounts
                -- take ~40% of turnover on ~5% of bets.
                multiIf(
                    player_vip_tier = 'whale', 20.0,
                    player_vip_tier = 'high',   4.0,
                    player_vip_tier = 'mid',    1.6,
                    1.0) AS tier_mult,

                -- Device, OS, build and IP country belong to the
                -- session. Drawn per bet, a player would swap phone and
                -- country between spins.
                ['mobile', 'desktop', 'tablet'][wpick(session_id, 226, [0.71, 0.21, 0.08])] AS device,
                multiIf(
                    device = 'mobile', ['iOS', 'Android'][1 + (cityHash64(session_id, 227) % 2)],
                    device = 'tablet', ['iPadOS', 'Android'][1 + (cityHash64(session_id, 227) % 2)],
                    ['Windows', 'macOS', 'Linux'][wpick(session_id, 227, [0.72, 0.25, 0.03])]
                ) AS os,
                if(device = 'desktop',
                   ['web-4.2', 'web-4.3', 'web-4.4'][wpick(session_id, 228, [0.15, 0.35, 0.50])],
                   ['app-9.1', 'app-9.2', 'app-9.3', 'app-10.0']
                       [wpick(session_id, 228, [0.08, 0.19, 0.44, 0.29])]) AS app_version,
                if(u(session_id, 229) < 0.96,
                   player_country,
                   ['GB','IE','DE','FR','PT','IT','PL','NO','MT','CY']
                       [1 + (cityHash64(session_id, 230) % 10)]) AS ip_country,

                -- The session's own start: local hour of day, converted
                -- to UTC through the brand's offset, so Ontario peaks
                -- five hours after Malta. A second session in the same
                -- block starts later the same day.
                toDateTime64('2026-06-01 00:00:00.000', 3, 'UTC')
                    + toIntervalSecond(day * 86400 + (hour_local - tz_off) * 3600)
                    + toIntervalMillisecond(toUInt32(u(session_id, 240) * 3540000))
                    + toIntervalHour(if(sub = 1, toUInt8(3 + u(session_id, 241) * 6), 0))
                    AS session_start,

                -- Bets inside a session are seconds apart. The base gap
                -- is per-session -- some players tap fast, some let each
                -- round finish -- with per-bet jitter on top.
                session_start
                    + toIntervalMillisecond(
                        toUInt32(seq_in_session * (1400 + u(session_id, 242) * 24000)
                                 + u(n, 243) * 1200)) AS ts
            FROM
            (
                -- ================= L1: the session =================
                SELECT
                    number AS n,
                    -- Rows arrive in blocks of 96, split into one or two
                    -- sessions at a per-block boundary. Session sizes end
                    -- up between 13 and 83 bets, averaging ~48.
                    intDiv(number, 96) AS blk,
                    toUInt8(number % 96) AS pos,
                    toUInt8(24 + (cityHash64(blk, 260) % 60)) AS split_at,
                    toUInt8(if(pos < split_at, 0, 1)) AS sub,
                    cityHash64(blk, sub, 'session') AS session_id,
                    toUInt16(if(sub = 0, pos, pos - split_at)) AS seq_in_session,

                    -- One player per block, so both sessions in a block
                    -- belong to the same person. Cubed-ish uniform over
                    -- player ids: the player table is built so low ids
                    -- are the whales.
                    zipf_id(blk, 252, {n_players:UInt32}) AS player_id,

                    -- Day of the window, drawn against a curve encoding
                    -- the weekend bump and the 2026 World Cup calendar:
                    -- group stage from 11 June, final on 19 July.
                    wpick(blk, 250, arrayMap(d ->
                        multiIf(
                            d BETWEEN 47 AND 48, 4.20,   -- third place, final
                            d BETWEEN 43 AND 44, 3.20,   -- semi-finals
                            d BETWEEN 38 AND 40, 2.60,   -- quarter-finals
                            d BETWEEN 33 AND 36, 2.30,   -- round of 16
                            d BETWEEN 27 AND 32, 2.10,   -- round of 32
                            d BETWEEN 10 AND 26, 1.90,   -- group stage
                            1.00)
                        * if(toDayOfWeek(toDate('2026-06-01') + toIntervalDay(d)) >= 6, 1.25, 1.0),
                        range(92))) - 1 AS day,

                    day BETWEEN 10 AND 48 AS is_wc,

                    -- Local hour: trough at 04:00, peak at 20:00.
                    wpick(blk, 251,
                        [0.020, 0.012, 0.008, 0.006, 0.005, 0.006, 0.010, 0.018,
                         0.026, 0.032, 0.036, 0.040, 0.045, 0.046, 0.048, 0.052,
                         0.058, 0.068, 0.082, 0.096, 0.104, 0.098, 0.070, 0.044]) - 1
                        AS hour_local
                FROM numbers_mt({n_bets:UInt64})
            )
        )
    )
)
SETTINGS
    -- Generation is CPU-bound on hashing and dictionary lookups.
    max_insert_threads = 16,
    max_block_size = 65536,
    min_insert_block_size_rows = 1048576;
