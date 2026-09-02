-- =====================================================================
-- The questions no dashboard has a tile for.
--
-- Every query in this file answers a question a person would ask out
-- loud, in a meeting, after something went wrong. None of them would
-- have been pre-built, because nobody knew to build them until the
-- moment they were needed.
--
-- That is the whole argument. Not that dashboards are bad -- they are
-- fine for 01_operator_basics.sql. It is that the set of questions worth
-- asking is unbounded, and pre-building is a bet that it isn't.
--
--   clickhouse local --path ./data --multiquery < queries/02_beyond_the_dashboard.sql
-- =====================================================================

-- "Which games are paying out more often than they're supposed to, and
--  when did it start?"
--
-- Hit frequency by provider by hour. Not RTP -- hit frequency. RTP is
-- dominated by rare large wins on large stakes and stays noisy -- hit
-- frequency is binomial and settles in a few hundred rows. Choosing the
-- low-variance metric is the difference between finding this and not.
SELECT
    provider_id,
    toStartOfInterval(ts, INTERVAL 6 HOUR)                  AS window,
    count()                                                 AS bets,
    round(100 * countIf(payout_eur > 0) / count(), 2)        AS hit_pct
FROM igaming.bets
WHERE vertical != 'sportsbook'
  AND status = 'settled'
  AND NOT is_bonus
  AND ts >= '2026-07-06' AND ts < '2026-07-11'
GROUP BY provider_id, window
HAVING bets > 200
ORDER BY hit_pct DESC
LIMIT 12;


-- "Are any of our self-excluded players still placing bets?"
--
-- The kind of question that ends careers if the answer is yes and
-- nobody checked. Answerable directly because self-exclusion is
-- denormalised onto every bet.
SELECT
    brand_name,
    licence_body,
    uniqExact(player_id)   AS excluded_players_still_betting,
    count()                AS bets,
    round(sum(stake_eur))  AS turnover_eur
FROM igaming.bets
WHERE player_self_excluded
GROUP BY brand_name, licence_body
ORDER BY bets DESC;


-- "Did anyone breach their deposit limit without being flagged?"
--
-- Three sources: payments for what went in, players for the limit
-- (nullable -- a NULL means no limit set, not a limit of zero), and
-- rg_events for whether anything noticed. No dashboard reconciles three
-- tables to answer a question nobody asked yet.
WITH breaches AS
(
    SELECT
        pay.player_id                AS player_id,
        toDate(pay.ts)               AS breach_day,
        sum(pay.amount_eur)          AS deposited_eur,
        any(pl.deposit_limit_eur)    AS limit_eur,
        any(pay.brand_name)          AS brand_name
    FROM igaming.payments AS pay
    INNER JOIN igaming.players AS pl ON pl.player_id = pay.player_id
    WHERE pay.txn_type = 'deposit'
      AND pay.status = 'approved'
      AND pl.deposit_limit_eur IS NOT NULL
    GROUP BY player_id, breach_day
    HAVING deposited_eur > limit_eur
)
SELECT
    b.brand_name                                                AS brand_name,
    count()                                                     AS breaches,
    countIf(rg.event_id = 0)                                    AS never_flagged,
    round(100 * countIf(rg.event_id != 0) / count(), 1)         AS pct_flagged,
    round(sum(b.deposited_eur - b.limit_eur))                   AS excess_eur
FROM breaches AS b
LEFT JOIN
(
    SELECT player_id, toDate(ts) AS d, any(event_id) AS event_id
    FROM igaming.rg_events
    WHERE event_type = 'limit_hit'
    GROUP BY player_id, d
) AS rg
  ON rg.player_id = b.player_id AND rg.d = b.breach_day
GROUP BY brand_name
ORDER BY never_flagged DESC;


-- "Show me groups of accounts that behave identically."
--
-- Bonus abuse never announces itself in one column. Small stakes are
-- normal. Bonus play is normal. Incomplete KYC is normal. It is the
-- conjunction, in one cohort, in one window, that is damning -- and
-- conjunctions are exactly what you cannot pre-build a tile for.
SELECT
    brand_name,
    player_acq_channel,
    toDate(player_registered_on)                         AS registered,
    uniqExact(player_id)                                 AS accounts,
    count()                                              AS bets,
    round(avg(stake_eur), 3)                             AS avg_stake_eur,
    round(100 * countIf(is_bonus) / count(), 1)          AS pct_bonus,
    round(100 * countIf(geo_mismatch) / count(), 1)      AS pct_geo_mismatch,
    uniqExact(game_id)                                   AS distinct_games,
    uniqExact(app_version)                               AS distinct_app_builds
FROM igaming.bets
WHERE player_kyc_status != 'verified'
GROUP BY brand_name, player_acq_channel, registered
HAVING accounts > 20 AND pct_bonus > 90 AND distinct_games < 5
ORDER BY accounts DESC
LIMIT 10;


-- "Find players who deposited, lost it all, and deposited again within
--  the hour."
--
-- Loss-chasing. A behavioural sequence, not an aggregate, and there is
-- no threshold you could have put on a dashboard that would surface it.
SELECT
    brand_name,
    uniqExact(player_id)                    AS players,
    count()                                 AS reload_events,
    round(avg(gap_minutes), 1)              AS avg_gap_minutes,
    round(avg(second_amount_eur), 2)        AS avg_reload_eur
FROM
(
    SELECT
        player_id,
        brand_name,
        amount_eur                                                       AS second_amount_eur,
        dateDiff('minute', lagInFrame(ts) OVER w, ts)                    AS gap_minutes,
        lagInFrame(amount_eur) OVER w                                    AS first_amount_eur
    FROM igaming.payments
    WHERE txn_type = 'deposit' AND status = 'approved'
    WINDOW w AS (PARTITION BY player_id ORDER BY ts
                 ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
)
WHERE gap_minutes BETWEEN 1 AND 60
  AND second_amount_eur >= first_amount_eur
GROUP BY brand_name
ORDER BY reload_events DESC;


-- "Did in-play bet acceptance get worse during the final, and by how
--  much?"
--
-- Turnover that day looks healthy. Only the latency tail shows it, and
-- only at fifteen-minute resolution -- hourly averages smear it away.
SELECT
    toStartOfFifteenMinutes(ts)                 AS quarter_hour,
    count()                                     AS in_play_bets,
    round(quantile(0.50)(accept_latency_ms))    AS p50_ms,
    round(quantile(0.99)(accept_latency_ms))     AS p99_ms,
    round(sum(stake_eur))                       AS turnover_eur
FROM igaming.bets
WHERE vertical = 'sportsbook'
  AND is_live
  AND ts >= '2026-07-19 17:00:00' AND ts < '2026-07-20 00:00:00'
GROUP BY quarter_hour
ORDER BY quarter_hour;


-- "Which acquisition channel brings players who deposit but never bet?"
--
-- Cross-stream, and the answer is a channel-level judgement about
-- marketing spend. Nobody builds this tile because nobody thinks to ask
-- until the quarter looks wrong.
SELECT
    dictGetString('igaming.dict_players', 'acq_channel', p.player_id) AS channel,
    uniqExact(p.player_id)                                            AS depositors,
    countIf(b.bets = 0)                                               AS never_bet,
    round(100 * countIf(b.bets = 0) / uniqExact(p.player_id), 1)      AS pct_never_bet,
    round(sum(p.deposited_eur))                                       AS deposited_eur
FROM
(
    SELECT player_id, sum(amount_eur) AS deposited_eur
    FROM igaming.payments
    WHERE txn_type = 'deposit' AND status = 'approved'
    GROUP BY player_id
) AS p
LEFT JOIN
(
    SELECT player_id, count() AS bets FROM igaming.bets GROUP BY player_id
) AS b ON b.player_id = p.player_id
GROUP BY channel
ORDER BY pct_never_bet DESC;


-- "What do whales play that casual players don't?"
--
-- A comparison of two populations across a catalogue of 420 titles. As a
-- dashboard this is 420 tiles, or a filter nobody set correctly.
SELECT
    game_name,
    game_volatility,
    round(100 * countIf(player_vip_tier = 'whale') / count(), 1)  AS pct_whale_bets,
    countIf(player_vip_tier = 'whale')                            AS whale_bets,
    countIf(player_vip_tier = 'casual')                           AS casual_bets,
    round(avgIf(stake_eur, player_vip_tier = 'whale'), 2)         AS whale_avg_stake
FROM igaming.bets
WHERE vertical = 'casino'
GROUP BY game_name, game_volatility
HAVING whale_bets > 100
ORDER BY pct_whale_bets DESC
LIMIT 15;


-- "Are there sessions where the IP country doesn't match the account?"
--
-- Cheap here because geo_mismatch is computed on write and sits on the
-- row. Expensive anywhere that would need to join a session to an
-- account to a country.
SELECT
    jurisdiction,
    ip_country,
    player_country,
    uniqExact(session_id)  AS sessions,
    uniqExact(player_id)   AS players,
    round(sum(stake_eur))  AS turnover_eur
FROM igaming.bets
WHERE geo_mismatch
GROUP BY jurisdiction, ip_country, player_country
ORDER BY sessions DESC
LIMIT 12;


-- "Which affordability flags has nobody looked at?"
--
-- The gap between an automated system firing and a human reviewing it.
-- Every operator has this number. Very few have it on a dashboard.
SELECT
    event_type,
    licence_body,
    count()                                              AS flags,
    countIf(NOT reviewed)                                AS unreviewed,
    round(100 * countIf(NOT reviewed) / count(), 1)       AS pct_unreviewed,
    round(sum(observed_eur))                             AS observed_eur
FROM igaming.rg_events
WHERE triggered_by = 'automated'
GROUP BY event_type, licence_body
ORDER BY unreviewed DESC;
