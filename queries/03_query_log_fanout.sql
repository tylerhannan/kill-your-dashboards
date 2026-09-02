-- =====================================================================
-- Fan-out, measured from system.query_log.
--
-- Run this AFTER asking an agent a question over MCP. It counts what one
-- natural-language question actually became, using ClickHouse's own query
-- log rather than anything this repo generated.
--
-- Availability, tested rather than assumed:
--
--   ClickHouse Cloud            available (the SQL console relies on it)
--   clickhouse server (default) available
--   clickhousectl local server  NOT available. `log_queries` reads 1,
--                               but the shipped config has no <query_log>
--                               block, so the table is never created and
--                               SYSTEM FLUSH LOGS silently does nothing
--   clickhouse-local            NOT available. No system.query_log at all
--
-- To enable it on a clickhousectl-managed server, add to its config:
--
--   <query_log>
--     <database>system</database>
--     <table>query_log</table>
--     <flush_interval_milliseconds>1000</flush_interval_milliseconds>
--   </query_log>
--
-- The MCP server connects as a normal user, so its queries land in
-- query_log like any other client's. Narrow by user or time window if
-- other things are running.
--
-- Sample output from a 20-query burst against the `small` tier:
--   section 2  20 queries in one second, avg 72ms, 78.8M rows read
--   section 3  one shape run 15 times, another 5
--   section 4  peak 17 concurrent
--   section 5  27 queries, 808 MiB read, 2.47 GiB peak query memory
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. What the last ten minutes of agent activity looked like.
--
-- One row per completed query. If a question fanned out, you will see
-- the burst here as a cluster of near-simultaneous entries.
-- ---------------------------------------------------------------------
SELECT
    event_time,
    query_duration_ms,
    formatReadableQuantity(read_rows)   AS rows_read,
    formatReadableSize(read_bytes)      AS bytes_read,
    memory_usage,
    substring(replaceRegexpAll(query, '\\s+', ' '), 1, 90) AS query
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 10 MINUTE
  AND query NOT LIKE '%system.query_log%'
  AND query_kind = 'Select'
ORDER BY event_time DESC
LIMIT 40;


-- ---------------------------------------------------------------------
-- 2. Queries per second. This is the fan-out number.
--
-- A human asking questions produces a trickle. An agent answering one
-- question produces a spike. The peak second is the honest headline.
-- ---------------------------------------------------------------------
SELECT
    event_time                                  AS second,
    count()                                     AS queries,
    round(avg(query_duration_ms))               AS avg_ms,
    max(query_duration_ms)                      AS slowest_ms,
    formatReadableQuantity(sum(read_rows))      AS rows_read
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 10 MINUTE
  AND query NOT LIKE '%system.query_log%'
  AND query_kind = 'Select'
GROUP BY second
HAVING queries > 1
ORDER BY queries DESC
LIMIT 20;


-- ---------------------------------------------------------------------
-- 3. Repeated query shapes.
--
-- Normalise away the literals and the same question asked twice
-- collapses into one row with a count above 1. That is work paid for
-- more than once.
-- ---------------------------------------------------------------------
SELECT
    count()                                     AS times_run,
    round(avg(query_duration_ms))               AS avg_ms,
    round(sum(query_duration_ms) / 1000, 1)     AS total_seconds,
    substring(normalizeQuery(query), 1, 110)    AS shape
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 10 MINUTE
  AND query NOT LIKE '%system.query_log%'
  AND query_kind = 'Select'
GROUP BY normalizeQuery(query)
HAVING times_run > 1
ORDER BY times_run DESC
LIMIT 20;


-- ---------------------------------------------------------------------
-- 4. Concurrency: how many queries were in flight at once.
--
-- Each query contributes +1 at its start and -1 at its end; the running
-- sum is the number executing at that moment. Under agent fan-out this
-- peaks well above what a dashboard refresh would ever produce.
-- ---------------------------------------------------------------------
SELECT
    ts,
    max(in_flight) AS peak_concurrent_queries
FROM
(
    SELECT
        ts,
        sum(delta) OVER (ORDER BY ts, delta DESC ROWS UNBOUNDED PRECEDING) AS in_flight
    FROM
    (
        SELECT event_time_microseconds - toIntervalMillisecond(query_duration_ms) AS ts,
               1 AS delta
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND event_time > now() - INTERVAL 10 MINUTE
          AND query NOT LIKE '%system.query_log%'
          AND query_kind = 'Select'
        UNION ALL
        SELECT event_time_microseconds AS ts, -1 AS delta
        FROM system.query_log
        WHERE type = 'QueryFinish'
          AND event_time > now() - INTERVAL 10 MINUTE
          AND query NOT LIKE '%system.query_log%'
          AND query_kind = 'Select'
    )
)
GROUP BY ts
ORDER BY peak_concurrent_queries DESC
LIMIT 10;


-- ---------------------------------------------------------------------
-- 5. What it cost to answer.
--
-- Total work for the window: useful for saying "that one question read
-- this many rows" out loud with a number behind it.
-- ---------------------------------------------------------------------
SELECT
    count()                                     AS queries,
    formatReadableQuantity(sum(read_rows))      AS total_rows_read,
    formatReadableSize(sum(read_bytes))         AS total_bytes_read,
    round(sum(query_duration_ms) / 1000, 1)     AS total_query_seconds,
    round(max(query_duration_ms))               AS slowest_ms,
    formatReadableSize(max(memory_usage))       AS peak_query_memory
FROM system.query_log
WHERE type = 'QueryFinish'
  AND event_time > now() - INTERVAL 10 MINUTE
  AND query NOT LIKE '%system.query_log%'
  AND query_kind = 'Select';
