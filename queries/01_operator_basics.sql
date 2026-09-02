-- =====================================================================
-- The dashboard tiles.
--
-- Everything here is a question somebody already knew you would ask, so
-- somebody already built it. These are the queries behind a normal
-- operator dashboard, and they run on this dataset unmodified.
--
-- They also happen to be single-table scans, because `bets` carries the
-- attributes they group by. That is a property of how this table was
-- modelled for this access pattern, not a claim that joins should be
-- avoided -- 02_beyond_the_dashboard.sql joins three tables to answer a
-- question worth asking, and does it in the same breath.
--
--   clickhouse local --path ./data --multiquery < queries/01_operator_basics.sql
-- =====================================================================

-- "What is our gross gaming revenue by day?"
SELECT
    toDate(ts)                          AS day,
    round(sum(ggr_eur))                 AS revenue_eur,
    round(sum(stake_eur))               AS turnover_eur,
    count()                             AS bets,
    uniqExact(player_id)                AS active_players
FROM igaming.bets
WHERE status = 'settled'
GROUP BY day
ORDER BY day
LIMIT 10;


-- "Break revenue down by brand and regulator."
SELECT
    brand_name,
    jurisdiction,
    licence_body,
    round(sum(stake_eur))                                        AS turnover_eur,
    -- Note the alias is not `ggr_eur`. Aliasing an aggregate to the
    -- name of the column it aggregates shadows that column, so a later
    -- sum(ggr_eur) in the same SELECT resolves to the alias and
    -- ClickHouse rejects the query as a nested aggregate.
    round(sum(ggr_eur))                                          AS revenue_eur,
    round(100 * sum(ggr_eur) / sum(stake_eur), 2)                AS hold_pct
FROM igaming.bets
WHERE status = 'settled'
GROUP BY brand_name, jurisdiction, licence_body
ORDER BY revenue_eur DESC;


-- "Which are our top games by revenue?"
SELECT
    game_name,
    provider_id,
    game_volatility,
    count()                                       AS bets,
    round(sum(stake_eur))                         AS turnover_eur,
    round(sum(ggr_eur))                           AS revenue_eur,
    round(sum(payout_eur) / sum(stake_eur), 4)    AS realised_rtp,
    round(avg(theoretical_rtp), 4)                AS advertised_rtp
FROM igaming.bets
WHERE vertical = 'casino' AND status = 'settled'
GROUP BY game_name, provider_id, game_volatility
ORDER BY revenue_eur DESC
LIMIT 15;


-- "How does the product mix split, and what does each vertical hold?"
SELECT
    vertical,
    count()                                        AS bets,
    round(100 * count() / (SELECT count() FROM igaming.bets), 1) AS pct_of_bets,
    round(sum(stake_eur))                          AS turnover_eur,
    round(100 * sum(ggr_eur) / sum(stake_eur), 2)  AS hold_pct
FROM igaming.bets
WHERE status = 'settled'
GROUP BY vertical
ORDER BY turnover_eur DESC;


-- "Deposit success rate by provider."
SELECT
    psp,
    count()                                                AS attempts,
    round(100 * countIf(status = 'approved') / count(), 2)  AS approved_pct,
    round(100 * countIf(status = 'declined') / count(), 2)  AS declined_pct,
    round(sum(amount_eur * (status = 'approved')))          AS deposited_eur,
    round(quantile(0.95)(latency_ms))                       AS p95_latency_ms
FROM igaming.payments
WHERE txn_type = 'deposit'
GROUP BY psp
ORDER BY attempts DESC;


-- "Player value distribution."
SELECT
    player_vip_tier,
    uniqExact(player_id)                                        AS players,
    round(sum(stake_eur))                                       AS turnover_eur,
    round(100 * sum(stake_eur)
          / (SELECT sum(stake_eur) FROM igaming.bets), 1)        AS pct_of_turnover,
    round(avg(stake_eur), 2)                                    AS avg_stake_eur,
    round(sum(ggr_eur) / uniqExact(player_id))                  AS ggr_per_player_eur
FROM igaming.bets
WHERE status = 'settled'
GROUP BY player_vip_tier
ORDER BY turnover_eur DESC;


-- "Bet acceptance latency by brand." The mean is decoration -- the tail
-- is the thing that shows up in an incident review.
SELECT
    brand_name,
    count()                                    AS bets,
    round(avg(accept_latency_ms))              AS mean_ms,
    round(quantile(0.50)(accept_latency_ms))   AS p50_ms,
    round(quantile(0.99)(accept_latency_ms))   AS p99_ms,
    round(quantile(0.999)(accept_latency_ms))  AS p999_ms
FROM igaming.bets
GROUP BY brand_name
ORDER BY p99_ms DESC;


-- "How did the World Cup change the business?" Still a dashboard
-- question, but only because somebody thought to build it in advance.
SELECT
    if(ts >= '2026-06-11' AND ts < '2026-07-20', 'during World Cup', 'outside') AS period,
    count()                                                     AS bets,
    round(sum(stake_eur))                                       AS turnover_eur,
    round(100 * countIf(vertical = 'sportsbook') / count(), 1)  AS pct_sportsbook,
    round(100 * countIf(is_live) / countIf(vertical = 'sportsbook'), 1) AS pct_in_play
FROM igaming.bets
WHERE status = 'settled'
GROUP BY period
ORDER BY period;
