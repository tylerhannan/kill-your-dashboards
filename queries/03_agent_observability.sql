-- =====================================================================
-- Agent observability.
--
-- The agents querying this data write their tool calls back into it, so
-- "why is the sportsbook slow" and "why did my agent give a wrong
-- answer" are the same kind of question, asked of the same engine, at
-- the same speed.
--
-- The alternative is a second stack for agent telemetry. That split is
-- how you end up correlating two systems by hand at 2am.
--
--   clickhouse local --path ./data --multiquery < queries/03_agent_observability.sql
-- =====================================================================

-- "How many queries does one question actually cost us?"
--
-- The number the abstract claims and this measures. One question in
-- words, dozens of queries in seconds.
SELECT
    round(avg(queries), 1)      AS avg_queries_per_question,
    quantile(0.50)(queries)     AS p50,
    quantile(0.95)(queries)     AS p95,
    quantile(0.99)(queries)     AS p99,
    max(queries)                AS worst,
    count()                     AS questions
FROM
(
    SELECT trace_id, count() AS queries
    FROM igaming.agent_traces
    GROUP BY trace_id
);


-- "Where does the time actually go?"
--
-- Execution time is not the problem. Queue wait is. It is near zero for
-- a narrow question and becomes the dominant term for a wide one,
-- because forty queries issued in the same second contend for the same
-- slots. This is the failure mode that staging never reproduces --
-- staging has one user.
SELECT
    multiIf(queries < 8,  '1. 1-7 queries',
            queries < 20, '2. 8-19',
            queries < 35, '3. 20-34',
                          '4. 35+')          AS fan_out_band,
    count()                                  AS questions,
    round(avg(exec_ms))                      AS avg_exec_ms,
    round(avg(queue_ms))                     AS avg_queue_ms,
    round(max(worst_queue_ms))               AS worst_queue_ms,
    round(100 * avg(queue_ms) / (avg(queue_ms) + avg(exec_ms)), 1) AS pct_time_waiting
FROM
(
    SELECT
        trace_id,
        count()                 AS queries,
        avg(duration_ms)        AS exec_ms,
        avg(queue_wait_ms)      AS queue_ms,
        max(queue_wait_ms)      AS worst_queue_ms
    FROM igaming.agent_traces
    GROUP BY trace_id
)
GROUP BY fan_out_band
ORDER BY fan_out_band;


-- "Which questions are the expensive ones?"
--
-- Cost per question, ranked. Useful for deciding what to pre-aggregate
-- and what to leave alone -- which is a very different exercise from
-- building a dashboard, because it is driven by what people actually
-- asked rather than what someone guessed they would.
SELECT
    user_question,
    count(DISTINCT trace_id)                    AS times_asked,
    round(avg(queries), 1)                      AS avg_queries,
    formatReadableQuantity(round(avg(rows_scanned))) AS avg_rows_scanned,
    round(avg(total_ms))                        AS avg_wall_ms
FROM
(
    SELECT
        trace_id,
        any(user_question)                          AS user_question,
        count()                                     AS queries,
        sum(rows_read)                              AS rows_scanned,
        sum(duration_ms) + sum(queue_wait_ms)       AS total_ms
    FROM igaming.agent_traces
    GROUP BY trace_id
)
GROUP BY user_question
ORDER BY avg_wall_ms DESC
LIMIT 12;


-- "Are we handing the model partial answers without telling it?"
--
-- The single most dangerous row in this table. A truncated result that
-- comes back looking complete produces a confident wrong answer, and
-- nothing downstream knows to distrust it.
SELECT
    agent_name,
    model,
    count()                                                    AS spans,
    countIf(silently_truncated)                                AS silent_truncations,
    round(100 * countIf(silently_truncated) / count(), 2)       AS pct_silent,
    countIf(status = 'timeout')                                AS timeouts,
    countIf(error_kind = 'too_many_simultaneous_queries')      AS rejected_for_concurrency
FROM igaming.agent_traces
GROUP BY agent_name, model
ORDER BY silent_truncations DESC;


-- "Are agents asking the same thing over and over inside one question?"
--
-- sql_fingerprint has its literals stripped, so identical shapes
-- collapse. The gap between total queries and distinct shapes is
-- redundant work you are paying for.
SELECT
    round(avg(queries), 1)                                  AS avg_queries,
    round(avg(distinct_shapes), 1)                          AS avg_distinct_shapes,
    round(avg(queries - distinct_shapes), 1)                AS avg_redundant,
    round(100 * avg(queries - distinct_shapes) / avg(queries), 1) AS pct_redundant
FROM
(
    SELECT
        trace_id,
        count()                         AS queries,
        uniqExact(sql_fingerprint)      AS distinct_shapes
    FROM igaming.agent_traces
    WHERE tool_name = 'run_select_query'
    GROUP BY trace_id
);


-- "Show me the adoption curve."
--
-- Agent query volume per week across the window. This is the Cambrian
-- slide: the environment did not change gradually.
SELECT
    toStartOfWeek(ts)                                   AS week,
    count()                                             AS spans,
    uniqExact(trace_id)                                 AS questions,
    formatReadableQuantity(sum(rows_read))              AS rows_scanned,
    formatReadableSize(sum(bytes_read))                 AS bytes_scanned
FROM igaming.agent_traces
GROUP BY week
ORDER BY week;


-- "Which tables are the agents actually hitting?"
--
-- Tells you where to spend effort. Note that the wide `bets` table
-- absorbs the overwhelming majority, which is the denormalisation
-- decision paying off.
SELECT
    target_table,
    count()                                     AS spans,
    formatReadableQuantity(sum(rows_read))      AS rows_scanned,
    round(avg(duration_ms))                     AS avg_exec_ms,
    round(quantile(0.99)(duration_ms))          AS p99_exec_ms
FROM igaming.agent_traces
WHERE tool_name = 'run_select_query'
GROUP BY target_table
ORDER BY spans DESC;


-- "What does discovery cost us?"
--
-- Every trace opens by working out what tables exist and what is in
-- them. Cheap individually, and paid on every single question -- which
-- is the argument for giving an agent durable context (a skill, a
-- description, a well-named schema) instead of making it rediscover the
-- world each time.
SELECT
    tool_name,
    count()                                                AS calls,
    round(100 * count() / (SELECT count() FROM igaming.agent_traces), 1) AS pct_of_all_calls,
    round(avg(duration_ms))                                AS avg_ms,
    round(avg(tokens_in))                                  AS avg_tokens_in
FROM igaming.agent_traces
GROUP BY tool_name
ORDER BY calls DESC;
