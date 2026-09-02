-- =====================================================================
-- ANOMALY 3: the bonus abuse cluster.
--
-- Parameters:
--   {n_players:UInt32}  must match 02_reference.sql -- used to offset the
--                       new player ids so they cannot collide
--
-- The cohort is a fixed 240 accounts placing 72,000 bets at every tier.
-- It is not scaled with the dataset: a needle should stay needle-sized,
-- and at ten billion rows this is genuinely buried.
--
-- Run AFTER 04_bets.sql and 05_payments.sql.
--
-- The other four anomalies are properties of rows that already exist, so
-- they cost nothing to plant. This one needs its own rows: a cohort of
-- accounts that did not exist before, behaving in a way no legitimate
-- player does.
--
-- The pattern is the real one. A few hundred accounts appear inside four
-- days, all through the same affiliate, all on the Dutch brand, all with
-- KYC left incomplete. Each makes the minimum qualifying deposit, then
-- plays a bonus balance at near-minimum stakes on two deliberately
-- low-volatility games -- because the aim is not to win, it is to clear
-- a wagering requirement with the least variance possible -- and
-- withdraws within days.
--
-- Every individual signal here is unremarkable. Small stakes are normal.
-- Bonus play is normal. Pending KYC is normal. It is only the
-- *conjunction*, in one cohort, in one window, that is damning -- which
-- is precisely why no dashboard has a tile for it, and why finding it
-- means asking a question nobody thought to pre-build.
--
-- Written with literal attribute values rather than dictionary lookups,
-- so this file does not depend on reloading dict_players after inserting
-- the new accounts.
-- =====================================================================

-- ---------------------------------------------------------------------
-- The accounts. 240 of them, ids immediately above the legitimate range.
-- ---------------------------------------------------------------------
INSERT INTO igaming.players
(
    player_id, brand_id, jurisdiction, country, registered_at, birth_year,
    kyc_status, vip_tier, acquisition_channel, preferred_currency,
    deposit_limit_eur, self_excluded_until, is_closed
)
SELECT
    toUInt32({n_players:UInt32} + number + 1)     AS player_id,
    'KES'                                         AS brand_id,
    'NL'                                          AS jurisdiction,
    'NL'                                          AS country,
    -- All 240 registered inside four days in late July.
    toDateTime('2026-07-20 00:00:00', 'UTC')
        + toIntervalSecond(toUInt32(u(number, 700) * 345600)) AS registered_at,
    -- Suspiciously clustered ages: the same handful of birth years reused
    -- across the cohort.
    toUInt16([1994, 1995, 1996, 1997][1 + (cityHash64(number, 701) % 4)]) AS birth_year,
    -- KYC never finished. That is what eventually blocks the withdrawal.
    if(u(number, 702) < 0.86, 'pending', 'failed')  AS kyc_status,
    'casual'                                      AS vip_tier,
    'affiliate'                                   AS acquisition_channel,
    'EUR'                                         AS preferred_currency,
    -- Nobody in this cohort sets a deposit limit.
    NULL                                          AS deposit_limit_eur,
    NULL                                          AS self_excluded_until,
    false                                         AS is_closed
FROM numbers(240);

-- ---------------------------------------------------------------------
-- The qualifying deposits. One each, at or just above the bonus minimum.
-- ---------------------------------------------------------------------
INSERT INTO igaming.payments
(
    txn_id, ts, player_id, player_country, player_vip_tier, player_kyc_status,
    brand_id, brand_name, jurisdiction, txn_type, method, psp, card_scheme,
    currency, amount, amount_eur, status, decline_reason, latency_ms,
    is_first_deposit, device
)
SELECT
    -- Offset well clear of the ids 05_payments.sql minted.
    toUInt64(9000000000 + number)                 AS txn_id,
    toDateTime64('2026-07-20 00:00:00.000', 3, 'UTC')
        + toIntervalSecond(toUInt32(u(number, 710) * 432000)) AS ts,
    toUInt32({n_players:UInt32} + (number % 240) + 1) AS player_id,
    'NL', 'casual', 'pending',
    'KES', 'Kestrel', 'NL',
    if(number < 240, 'deposit', 'withdrawal')     AS txn_type,
    -- One prepaid method and one wallet, over and over.
    ['paysafecard', 'skrill'][1 + (cityHash64(number, 711) % 2)] AS method,
    'Solaris Gateway'                             AS psp,
    ''                                            AS card_scheme,
    'EUR'                                         AS currency,
    -- Deposits cluster on the bonus minimum. Withdrawals are the bonus
    -- plus winnings, an order of magnitude larger.
    toDecimal64(if(number < 240,
                   20.00 + toUInt8(u(number, 712) * 3) * 5.0,
                   180.00 + u(number, 712) * 240.0), 4) AS amount,
    toDecimal64(if(number < 240,
                   20.00 + toUInt8(u(number, 712) * 3) * 5.0,
                   180.00 + u(number, 712) * 240.0), 4) AS amount_eur,
    -- The deposits clear. Most withdrawals sit pending forever, because
    -- KYC was never completed.
    multiIf(number < 240,                     'approved',
            u(number, 713) < 0.74,            'pending',
            u(number, 713) < 0.93,            'declined',
                                              'approved') AS status,
    multiIf(number < 240,                     '',
            u(number, 713) < 0.74,            '',
            u(number, 713) < 0.93,            'risk_block',
                                              '')         AS decline_reason,
    toUInt32(400 + u(number, 714) * 2600)         AS latency_ms,
    number < 240                                  AS is_first_deposit,
    'mobile'                                      AS device
FROM numbers(480);

-- ---------------------------------------------------------------------
-- The play. Bonus balance, minimum stakes, two low-volatility games,
-- ground out over four days.
-- ---------------------------------------------------------------------
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
    toUInt64(18000000000 + n)                     AS bet_id,
    ts,
    ts + toIntervalMillisecond(toUInt32(300 + u(n, 720) * 1400)) AS settled_ts,

    player_id,
    'NL'                                          AS player_country,
    'casual'                                      AS player_vip_tier,
    'pending'                                     AS player_kyc_status,
    -- Recomputed from the same expression the players insert above uses,
    -- so the denormalised date on the bet agrees with the reference
    -- table. Hardcoding one date here instead left every cohort bet
    -- claiming 21 July while `players` spread them over four days -- a
    -- silent disagreement between a wide table and its source, which is
    -- the exact failure denormalisation is accused of and worth not
    -- actually committing.
    toDate(toDateTime('2026-07-20 00:00:00', 'UTC')
           + toIntervalSecond(
               toUInt32(u(player_id - {n_players:UInt32} - 1, 700) * 345600)))
                                                  AS player_registered_on,
    toUInt16([1994, 1995, 1996, 1997][1 + (cityHash64(player_id, 701) % 4)]) AS player_birth_year,
    'affiliate'                                   AS player_acq_channel,
    false                                         AS player_has_deposit_limit,
    false                                         AS player_self_excluded,

    'KES'                                         AS brand_id,
    'Kestrel'                                     AS brand_name,
    'NL'                                          AS jurisdiction,
    'KSA'                                         AS licence_body,

    session_id,
    'mobile'                                      AS device,
    'Android'                                     AS os,
    -- One build across the whole cohort. Real player bases spread across
    -- four or five.
    'app-9.3'                                     AS app_version,
    -- Registered in the Netherlands, playing from two other countries.
    ip_country,
    true                                          AS geo_mismatch,

    'casino'                                      AS vertical,
    dictGetString('igaming.dict_games', 'provider_id', game_id) AS provider_id,
    game_id,
    dictGetString('igaming.dict_games', 'game_name',  game_id) AS game_name,
    dictGetString('igaming.dict_games', 'volatility', game_id) AS game_volatility,
    toDecimal64(dictGetFloat32('igaming.dict_games', 'rtp', game_id), 4) AS theoretical_rtp,
    toUInt16(0), '', '', '',

    'EUR'                                         AS currency,
    toDecimal64(stake_eur, 4)                     AS stake,
    toDecimal64(payout_eur, 4)                    AS payout,
    toDecimal64(stake_eur, 4)                     AS stake_eur,
    toDecimal64(payout_eur, 4)                    AS payout_eur,
    toDecimal64(0.0, 3)                           AS odds,

    -- The tell, if you think to ask for it: every single bet is bonus.
    true                                          AS is_bonus,
    false                                         AS is_live,
    'settled'                                     AS status,
    toUInt16(12 + u(n, 721) * 40)                 AS accept_latency_ms
FROM
(
    SELECT
        n,
        player_id,
        session_id,
        game_id,
        ip_country,
        ts,
        stake_eur,
        -- Ordinary RTP: they are not exploiting the game, they are
        -- exploiting the promotion. Payout behaviour has to look normal
        -- or the cluster would be trivially findable.
        if(u(n, 730) < dictGetFloat32('igaming.dict_games', 'hit_rate', game_id),
           stake_eur * dictGetFloat32('igaming.dict_games', 'rtp', game_id)
                     * least(pareto_unit(n, 731,
                         dictGetFloat32('igaming.dict_games', 'tail_alpha', game_id)), 20000.0)
                     / dictGetFloat32('igaming.dict_games', 'hit_rate', game_id),
           0.0) AS payout_eur
    FROM
    (
        SELECT
            n,
            player_id,
            game_id,
            ip_country,
            stake_eur,
            cityHash64('abuse', player_id, sess_no) AS session_id,
            -- Bets inside a grinding session are four to nine seconds
            -- apart, so the session is temporally coherent. Scattering
            -- them across the whole four-day window instead gave
            -- "sessions" spanning days, which dragged the dataset-wide
            -- average session duration from 20 minutes to four hours.
            session_start + toIntervalMillisecond(
                toUInt32(seq * (4000 + u(player_id, 745) * 5000) + u(n, 746) * 900)) AS ts
        FROM
        (
            SELECT
                number AS n,
                -- 480 sessions of 150 bets across 240 accounts: two
                -- sessions each.
                intDiv(number, 150) AS session_ordinal,
                toUInt16(number % 150) AS seq,
                toUInt32({n_players:UInt32} + (session_ordinal % 240) + 1) AS player_id,
                toUInt8(intDiv(session_ordinal, 240)) AS sess_no,
                -- Two games only, both low volatility. Games 2 and 4 are
                -- the highest-traffic low-volatility slots in the
                -- catalogue, so the cohort hides inside real volume.
                toUInt16([2, 4][1 + (cityHash64(player_id, 741) % 2)]) AS game_id,
                ['PL', 'RO'][1 + (cityHash64(player_id, 742) % 2)] AS ip_country,
                -- Sessions land at any hour of the day or night across
                -- four days. The absence of a diurnal curve is itself a
                -- signal: real players sleep.
                toDateTime64('2026-07-24 00:00:00.000', 3, 'UTC')
                    + toIntervalSecond(toUInt32(sess_no * 129600
                                                + u(player_id + sess_no, 743) * 129600)) AS session_start,
                -- Near-minimum stakes, barely varying.
                0.10 + toUInt8(u(number, 744) * 4) * 0.10 AS stake_eur
            FROM numbers(72000)
        )
    )
)
SETTINGS max_insert_threads = 8;
