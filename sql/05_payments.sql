-- =====================================================================
-- igaming.payments -- deposits and withdrawals.
--
-- Parameters:
--   {n_payments:UInt64}  rows to generate (generate.sh uses n_bets / 40)
--   {n_players:UInt32}   must match 02_reference.sql
--
-- Its own event stream rather than something derived from bets: players
-- deposit without playing, withdraw days later, and get declined by a
-- provider that has nothing to do with the games they like.
--
-- Contains ANOMALY 4, the payment provider outage.
-- =====================================================================

INSERT INTO igaming.payments
(
    txn_id, ts,
    player_id, player_country, player_vip_tier, player_kyc_status,
    brand_id, brand_name, jurisdiction,
    txn_type, method, psp, card_scheme,
    currency, amount, amount_eur,
    status, decline_reason, latency_ms, is_first_deposit, device
)
SELECT
    n AS txn_id,
    ts,
    player_id,
    player_country,
    player_vip_tier,
    player_kyc_status,
    brand_id,
    brand_name,
    jurisdiction,
    txn_type,
    method,
    psp,
    -- Only card payments carry a scheme.
    if(method = 'card',
       ['visa', 'mastercard', 'maestro', 'amex'][wpick(n, 300, [0.46, 0.42, 0.08, 0.04])],
       '') AS card_scheme,
    currency,
    toDecimal64(amount_eur / fx, 4) AS amount,
    toDecimal64(amount_eur, 4)      AS amount_eur,
    status,
    -- Approved transactions carry no reason. Declines get one that fits
    -- how they failed: an outage declines differently from a risk block.
    multiIf(
        status != 'declined', '',
        in_outage,            'issuer_unavailable',
        ['insufficient_funds', 'do_not_honour', 'expired_card', '3ds_failed',
         'risk_block', 'limit_exceeded', 'issuer_unavailable']
            [wpick(n, 301, [0.34, 0.21, 0.11, 0.13, 0.09, 0.08, 0.04])]
    ) AS decline_reason,
    -- Latency is per-provider, with a tail. During the outage the
    -- provider is not just failing, it is failing slowly -- which is the
    -- part that ties up connection pools.
    toUInt32(least(120000.0,
        psp_base_latency * (0.5 + pow(u(n, 302), -0.3))
                         * if(in_outage, 7.0, 1.0)
    )) AS latency_ms,
    is_first_deposit,
    device
FROM
(
    -- ================= outcome =================
    SELECT
        *,
        -- ANOMALY 4: payment provider outage.
        -- Northgate degrades for six hours on 14 August. Declines go
        -- from roughly one in twelve to better than three in four, all
        -- reporting issuer_unavailable, with latency up sevenfold.
        --
        -- Six hours and provider-wide, not forty minutes in one market,
        -- because a narrower slice would be a handful of rows at the
        -- 10M tier and impossible to distinguish from noise. Decline
        -- rate is binomial, so a few hundred rows is plenty.
        (psp = 'Northgate'
         AND ts >= toDateTime64('2026-08-14 11:00:00.000', 3, 'UTC')
         AND ts <  toDateTime64('2026-08-14 17:00:00.000', 3, 'UTC')) AS in_outage,

        multiIf(
            -- Withdrawals mostly clear, but sit pending for review more
            -- often -- especially for accounts that never finished KYC.
            txn_type = 'withdrawal',
                multiIf(
                    player_kyc_status != 'verified' AND u(n, 310) < 0.42, 'pending',
                    u(n, 310) < 0.030, 'declined',
                    u(n, 310) < 0.055, 'pending',
                    u(n, 310) < 0.061, 'reversed',
                    'approved'),
            -- Deposits during the outage.
            in_outage,
                if(u(n, 310) < 0.78, 'declined', 'approved'),
            -- Deposits normally. Unverified accounts get declined more.
            u(n, 310) < if(player_kyc_status = 'verified', 0.078, 0.19), 'declined',
            u(n, 310) < 0.088, 'pending',
            'approved'
        ) AS status
    FROM
    (
        -- ================= who, what, how much =================
        SELECT
            n,
            ts,
            player_id,
            player_country,
            player_vip_tier,
            player_kyc_status,
            brand_id,
            brand_name,
            jurisdiction,
            currency,
            fx,
            txn_type,
            method,
            device,

            -- Provider routing is by market, not random: an operator
            -- uses different acquirers in different jurisdictions, which
            -- is why a single provider's outage hits some brands harder.
            multiIf(
                jurisdiction IN ('SE', 'DK'),
                    ['Northgate', 'Baltic Pay', 'Solaris Gateway']
                        [wpick(n, 320, [0.44, 0.36, 0.20])],
                jurisdiction IN ('GB', 'MT'),
                    ['Veritas PSP', 'Northgate', 'Corvus']
                        [wpick(n, 320, [0.41, 0.31, 0.28])],
                jurisdiction = 'CA-ON',
                    ['Meridian', 'Corvus', 'Northgate']
                        [wpick(n, 320, [0.52, 0.27, 0.21])],
                    ['Solaris Gateway', 'Veritas PSP', 'Meridian', 'Northgate']
                        [wpick(n, 320, [0.33, 0.28, 0.22, 0.17])]
            ) AS psp,

            multiIf(
                psp = 'Northgate',       900.0,
                psp = 'Baltic Pay',      640.0,
                psp = 'Veritas PSP',    1250.0,
                psp = 'Corvus',          780.0,
                psp = 'Solaris Gateway', 540.0,
                                        1050.0
            ) AS psp_base_latency,

            -- Deposits cluster on small round-ish amounts; withdrawals
            -- are larger and lumpier because people cash out a balance,
            -- not a fixed figure.
            if(txn_type = 'deposit',
               least(greatest(10.0 * exp(pow(u(n, 321), 1.6) * 4.4) * tier_mult, 5.0), 50000.0),
               least(greatest(25.0 * exp(pow(u(n, 321), 1.3) * 5.0) * tier_mult, 10.0), 250000.0)
            ) AS amount_eur,

            -- Approximate rather than exact: a true first-deposit flag
            -- needs to know a player's whole history, which a
            -- single-pass generator does not have. Roughly one deposit
            -- in fifty is marked, biased toward accounts that
            -- registered inside the window.
            txn_type = 'deposit'
                AND u(n, 322) < if(player_registered_on >= toDate('2026-06-01'), 0.34, 0.006)
                AS is_first_deposit
        FROM
        (
            -- ================= when and who =================
            SELECT
                number AS n,
                zipf_id(number, 330, {n_players:UInt32}) AS player_id,

                dictGetString('igaming.dict_players', 'country',    player_id) AS player_country,
                dictGetString('igaming.dict_players', 'vip_tier',   player_id) AS player_vip_tier,
                dictGetString('igaming.dict_players', 'kyc_status', player_id) AS player_kyc_status,
                dictGetDate('igaming.dict_players', 'registered_on', player_id) AS player_registered_on,
                dictGetString('igaming.dict_players', 'brand_id',   player_id) AS brand_id,

                dictGetString('igaming.dict_brands', 'brand_name',    tuple(brand_id)) AS brand_name,
                dictGetString('igaming.dict_brands', 'jurisdiction',  tuple(brand_id)) AS jurisdiction,
                dictGetString('igaming.dict_brands', 'base_currency', tuple(brand_id)) AS currency,
                dictGetInt8('igaming.dict_brands', 'tz_offset_hours', tuple(brand_id)) AS tz_off,
                dictGetFloat64('igaming.dict_fx', 'eur_per_1', tuple(currency)) AS fx,

                multiIf(
                    player_vip_tier = 'whale', 14.0,
                    player_vip_tier = 'high',   3.6,
                    player_vip_tier = 'mid',    1.5,
                    1.0) AS tier_mult,

                -- Roughly four deposits per withdrawal, which is what
                -- keeps an operator in business.
                if(u(number, 331) < 0.79, 'deposit', 'withdrawal') AS txn_type,

                -- Withdrawal methods are narrower than deposit methods:
                -- money generally has to go back the way it came.
                if(txn_type = 'deposit',
                   ['card', 'apple_pay', 'google_pay', 'trustly', 'paypal',
                    'bank_transfer', 'skrill', 'paysafecard', 'crypto']
                       [wpick(number, 332,
                        [0.38, 0.14, 0.07, 0.12, 0.09, 0.06, 0.05, 0.06, 0.03])],
                   ['card', 'trustly', 'bank_transfer', 'paypal', 'skrill', 'crypto']
                       [wpick(number, 332, [0.31, 0.21, 0.27, 0.11, 0.07, 0.03])]
                ) AS method,

                ['mobile', 'desktop', 'tablet'][wpick(number, 333, [0.68, 0.24, 0.08])] AS device,

                -- Payments follow the same local-evening curve as play,
                -- but flatter: people top up when they run out, which
                -- happens across the whole session rather than at peak.
                toDateTime64('2026-06-01 00:00:00.000', 3, 'UTC')
                    + toIntervalSecond(
                        (wpick(number, 334, arrayMap(d ->
                            multiIf(
                                d BETWEEN 47 AND 48, 3.60,
                                d BETWEEN 43 AND 44, 2.90,
                                d BETWEEN 38 AND 40, 2.40,
                                d BETWEEN 33 AND 36, 2.15,
                                d BETWEEN 27 AND 32, 1.95,
                                d BETWEEN 10 AND 26, 1.80,
                                1.00)
                            * if(toDayOfWeek(toDate('2026-06-01') + toIntervalDay(d)) >= 6, 1.22, 1.0),
                            range(92))) - 1) * 86400
                        + (wpick(number, 335,
                            [0.024, 0.016, 0.011, 0.008, 0.007, 0.009, 0.014, 0.022,
                             0.030, 0.036, 0.040, 0.043, 0.046, 0.047, 0.048, 0.051,
                             0.055, 0.062, 0.072, 0.084, 0.090, 0.086, 0.066, 0.043])
                           - 1 - tz_off) * 3600)
                    + toIntervalMillisecond(toUInt32(u(number, 336) * 3600000)) AS ts
            FROM numbers_mt({n_payments:UInt64})
        )
    )
)
SETTINGS
    max_insert_threads = 16,
    min_insert_block_size_rows = 1048576;
