-- =====================================================================
-- Verification suite.
--
-- Run after generation. Every check below either states an invariant the
-- data should satisfy or measures a property the dataset claims to have.
-- If one of these looks wrong, the data is wrong -- do not build a demo
-- on top of it.
--
--   clickhouse client --queries-file sql/10_verify.sql
--
-- The compressed-size check at the end is worth reading even when
-- everything passes: it is the evidence for the wide-table decision in
-- 01_tables.sql.
-- =====================================================================

SELECT '=== 1. row counts ===' AS check;

SELECT
    'bets' AS table, count() AS rows, min(ts) AS earliest, max(ts) AS latest
FROM igaming.bets
UNION ALL SELECT 'payments', count(), min(ts), max(ts) FROM igaming.payments
UNION ALL SELECT 'sessions', count(), min(started_at), max(started_at) FROM igaming.sessions
UNION ALL SELECT 'rg_events', count(), min(ts), max(ts) FROM igaming.rg_events
UNION ALL SELECT 'agent_traces', count(), min(ts), max(ts) FROM igaming.agent_traces;


SELECT '=== 2. RTP calibration: realised vs theoretical ===' AS check;

-- Theoretical RTP must be weighted by STAKE, not by bet count. Comparing
-- a turnover-weighted actual against a count-weighted theoretical
-- produces a spurious two-percent gap that looks like a generator bug.
-- Expect every class within ~1.5%; the small negative bias is the
-- 20,000x max-win cap trimming the tail.
SELECT
    game_volatility,
    count()                                                       AS bets,
    round(sum(stake_eur * theoretical_rtp) / sum(stake_eur), 4)    AS theoretical,
    round(sum(payout_eur) / sum(stake_eur), 4)                     AS realised,
    round(100 * (sum(payout_eur) - sum(stake_eur * theoretical_rtp))
              / sum(stake_eur * theoretical_rtp), 2)               AS pct_off
FROM igaming.bets
WHERE vertical != 'sportsbook' AND status = 'settled' AND NOT is_bonus
GROUP BY game_volatility
ORDER BY bets DESC;

SELECT '--- sportsbook hold should approximate the blended overround ---' AS check;
SELECT
    round(sum(stake_eur - payout_eur) / sum(stake_eur), 4) AS realised_hold,
    count()                                                AS bets
FROM igaming.bets
WHERE vertical = 'sportsbook' AND status = 'settled';


SELECT '=== 3. player value concentration ===' AS check;

-- Target: whales are ~1% of accounts placing ~5% of bets and taking
-- ~40% of turnover.
SELECT
    player_vip_tier,
    uniqExact(player_id)                                                  AS players,
    round(100 * count() / (SELECT count() FROM igaming.bets), 1)          AS pct_of_bets,
    round(100 * sum(stake_eur) / (SELECT sum(stake_eur) FROM igaming.bets), 1) AS pct_of_turnover,
    round(avg(stake_eur), 2)                                              AS avg_stake_eur
FROM igaming.bets
GROUP BY player_vip_tier
ORDER BY pct_of_turnover DESC;


SELECT '=== 4. session coherence ===' AS check;

-- Bets per session must be dozens, not one. A value near 1 means bet
-- timestamps were drawn independently and every session-level metric
-- built on this data is meaningless.
SELECT
    round(avg(bet_count), 1)        AS avg_bets_per_session,
    quantile(0.5)(bet_count)        AS p50_bets,
    quantile(0.95)(bet_count)       AS p95_bets,
    round(avg(duration_s))          AS avg_duration_s,
    count()                         AS sessions_with_bets
FROM igaming.sessions
WHERE bet_count > 0;

SELECT '--- device and geo must be constant within a session ---' AS check;
SELECT
    max(devices)   AS max_devices_per_session,
    max(countries) AS max_ip_countries_per_session
FROM
(
    SELECT session_id, uniqExact(device) AS devices, uniqExact(ip_country) AS countries
    FROM igaming.bets
    GROUP BY session_id
);

SELECT '--- referential integrity: every bet session must exist ---' AS check;
SELECT count() AS orphaned_bets
FROM igaming.bets
WHERE session_id NOT IN (SELECT session_id FROM igaming.sessions);


SELECT '=== 5. ANOMALY 1 -- provider hit-rate drift, 8 July ===' AS check;

-- One provider should stand out sharply. Everything else should be flat.
SELECT
    provider_id,
    countIf(toHour(ts) BETWEEN 2 AND 13)                                       AS bets_in_window,
    round(100 * countIf(payout_eur > 0 AND toHour(ts) BETWEEN 2 AND 13)
              / countIf(toHour(ts) BETWEEN 2 AND 13), 2)                       AS hit_pct_inside,
    round(100 * countIf(payout_eur > 0 AND toHour(ts) NOT BETWEEN 2 AND 13)
              / countIf(toHour(ts) NOT BETWEEN 2 AND 13), 2)                   AS hit_pct_outside
FROM igaming.bets
WHERE vertical != 'sportsbook' AND status = 'settled' AND toDate(ts) = '2026-07-08'
GROUP BY provider_id
ORDER BY hit_pct_inside - hit_pct_outside DESC;


SELECT '=== 6. ANOMALY 2 -- in-play latency, World Cup final ===' AS check;

SELECT
    toStartOfHour(ts)                          AS hour,
    count()                                    AS in_play_bets,
    round(quantile(0.50)(accept_latency_ms))   AS p50_ms,
    round(quantile(0.99)(accept_latency_ms))   AS p99_ms
FROM igaming.bets
WHERE vertical = 'sportsbook' AND is_live AND toDate(ts) = '2026-07-19'
GROUP BY hour
ORDER BY hour;


SELECT '=== 7. ANOMALY 3 -- bonus abuse cluster ===' AS check;

-- Skipped silently if 09_anomalies.sql has not been run.
SELECT
    count()                                    AS cohort_accounts,
    sum(bets)                                  AS cohort_bets,
    round(avg(avg_stake), 3)                   AS avg_stake_eur,
    round(100 * avg(pct_bonus), 1)             AS pct_bonus_play
FROM
(
    SELECT
        player_id,
        count()                       AS bets,
        avg(stake_eur)                AS avg_stake,
        countIf(is_bonus) / count()   AS pct_bonus
    FROM igaming.bets
    WHERE brand_id = 'KES' AND player_acq_channel = 'affiliate'
      AND player_kyc_status != 'verified' AND geo_mismatch
      AND ts >= '2026-07-24' AND ts < '2026-07-28'
    GROUP BY player_id
    HAVING bets > 50 AND pct_bonus > 0.95
);


SELECT '=== 8. ANOMALY 4 -- payment provider outage, 14 August ===' AS check;

SELECT
    psp,
    countIf(toHour(ts) BETWEEN 11 AND 16)                                     AS deposits_in_window,
    round(100 * countIf(status = 'declined' AND toHour(ts) BETWEEN 11 AND 16)
              / countIf(toHour(ts) BETWEEN 11 AND 16), 1)                     AS declined_pct_inside,
    round(100 * countIf(status = 'declined' AND toHour(ts) NOT BETWEEN 11 AND 16)
              / countIf(toHour(ts) NOT BETWEEN 11 AND 16), 1)                 AS declined_pct_outside
FROM igaming.payments
WHERE txn_type = 'deposit' AND toDate(ts) = '2026-08-14'
GROUP BY psp
ORDER BY declined_pct_inside DESC;


SELECT '=== 9. ANOMALY 5 -- deposit limit breaches that were never flagged ===' AS check;

-- Three sources: payments for what was deposited, players for the
-- nullable limit, rg_events for whether anyone noticed. Expect ~86%
-- caught. Note the IS NOT NULL -- a null limit means no limit set, and
-- treating it as zero flags the entire player base.
WITH breaches AS
(
    SELECT
        pay.player_id  AS player_id,
        toDate(pay.ts) AS breach_day
    FROM igaming.payments AS pay
    INNER JOIN igaming.players AS pl ON pl.player_id = pay.player_id
    WHERE pay.txn_type = 'deposit'
      AND pay.status = 'approved'
      AND pl.deposit_limit_eur IS NOT NULL
    GROUP BY player_id, breach_day
    HAVING sum(pay.amount_eur) > any(pl.deposit_limit_eur)
)
SELECT
    (SELECT count() FROM breaches)                                              AS actual_breaches,
    (SELECT count() FROM igaming.rg_events WHERE event_type = 'limit_hit')      AS flagged,
    (SELECT count() FROM breaches)
        - (SELECT count() FROM igaming.rg_events WHERE event_type = 'limit_hit') AS never_flagged,
    round(100.0 * (SELECT count() FROM igaming.rg_events WHERE event_type = 'limit_hit')
          / (SELECT count() FROM breaches), 1)                                  AS pct_caught;


SELECT '=== 10. agent fan-out: queries per question ===' AS check;

SELECT
    round(avg(spans), 1)      AS avg_queries_per_question,
    quantile(0.5)(spans)      AS p50,
    quantile(0.95)(spans)     AS p95,
    max(spans)                AS worst,
    count()                   AS questions
FROM (SELECT trace_id, count() AS spans FROM igaming.agent_traces GROUP BY trace_id);

SELECT '--- queue wait is the concurrency tax, and it scales with fan-out ---' AS check;
SELECT
    multiIf(spans < 8, '1. 1-7 queries', spans < 20, '2. 8-19',
            spans < 35, '3. 20-34', '4. 35+')  AS fan_out_band,
    count()                                    AS questions,
    round(avg(mean_queue))                     AS avg_queue_ms,
    round(max(worst_queue))                    AS worst_queue_ms
FROM
(
    SELECT trace_id, count() AS spans,
           avg(queue_wait_ms) AS mean_queue, max(queue_wait_ms) AS worst_queue
    FROM igaming.agent_traces
    GROUP BY trace_id
)
GROUP BY fan_out_band
ORDER BY fan_out_band;

SELECT '--- results the model was handed without being told they were partial ---' AS check;
SELECT
    round(100 * countIf(silently_truncated) / count(), 2) AS pct_silently_truncated,
    round(100 * countIf(status != 'ok') / count(), 2)     AS pct_failed
FROM igaming.agent_traces;

SELECT '--- the same query shape re-asked within one question ---' AS check;
SELECT round(avg(dupes), 2) AS avg_repeated_shapes_per_question
FROM
(
    SELECT trace_id, count() - uniqExact(sql_fingerprint) AS dupes
    FROM igaming.agent_traces
    WHERE tool_name = 'run_select_query'
    GROUP BY trace_id
);


SELECT '=== 11. what the wide table actually costs ===' AS check;

-- The case for denormalising. The denormalised LowCardinality columns
-- should be a rounding error next to the timestamps and the money.
SELECT
    name                                            AS column,
    formatReadableSize(sum(data_compressed_bytes))  AS compressed,
    formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
    round(sum(data_uncompressed_bytes) / sum(data_compressed_bytes), 1) AS ratio,
    round(sum(data_compressed_bytes) / (SELECT count() FROM igaming.bets), 3) AS bytes_per_row
FROM system.columns
WHERE database = 'igaming' AND table = 'bets'
GROUP BY name
ORDER BY sum(data_compressed_bytes) DESC;

SELECT '--- table totals ---' AS check;
SELECT
    table,
    formatReadableSize(sum(bytes_on_disk))     AS on_disk,
    sum(rows)                                  AS rows,
    round(sum(bytes_on_disk) / sum(rows), 2)   AS bytes_per_row
FROM system.parts
WHERE database = 'igaming' AND active
GROUP BY table
ORDER BY sum(bytes_on_disk) DESC;
