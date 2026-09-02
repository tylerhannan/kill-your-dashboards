-- =====================================================================
-- igaming.agent_traces -- agent observability.
--
-- Parameters:
--   {n_spans:UInt64}  tool-call rows to generate
--
-- One row per tool call. Many rows share a trace_id, because one
-- question in words becomes many queries against the database. That
-- ratio is the entire argument, and this table is where it stops being
-- an assertion and becomes a number you can GROUP BY.
--
-- Three things are modelled deliberately, because they are the three
-- that hurt in production:
--
--   queue_wait_ms       time the query spent waiting for a slot rather
--                       than executing. Under fan-out this moves first,
--                       and long before p99 execution time does.
--
--   silently_truncated  the result was cut short and the model was
--                       handed a partial answer without being told.
--                       This is where confident wrong answers come from.
--
--   sql_fingerprint     literals stripped. Group by it inside a trace
--                       and the redundant re-asking becomes countable.
--
-- Agent traffic also GROWS across the 92-day window, from a trickle in
-- June to the dominant query source by late August. Plot spans per day
-- and you have the Cambrian slide, drawn from data rather than asserted.
-- =====================================================================

TRUNCATE TABLE IF EXISTS igaming.agent_traces;

INSERT INTO igaming.agent_traces
(
    trace_id, span_id, parent_span_id, ts,
    agent_name, agent_version, model, user_question, loop_iteration,
    tool_name, sql_fingerprint, target_table,
    duration_ms, queue_wait_ms, rows_read, bytes_read, result_rows,
    peak_memory_bytes, tokens_in, tokens_out,
    status, error_kind, silently_truncated
)
SELECT
    det_uuid(trace_key, 600)              AS trace_id,
    det_uuid(n, 601)                      AS span_id,
    -- The first span of a trace is the root; everything else hangs off
    -- it. Real traces nest deeper, but one level is enough to make
    -- fan-out per question countable.
    if(seq = 0, NULL, det_uuid(trace_key * 1000, 601)) AS parent_span_id,
    ts,

    agent_name,
    agent_version,
    model,
    user_question,
    -- Discovery happens on iteration 0; the query fan-out follows.
    toUInt8(if(seq = 0, 0, 1 + intDiv(seq - 1, 9))) AS loop_iteration,

    tool_name,
    sql_fingerprint,
    target_table,

    duration_ms,
    queue_wait_ms,
    rows_read,
    bytes_read,
    result_rows,
    -- Roughly proportional to what the query had to hold: wide scans
    -- with a GROUP BY dominate.
    toUInt64(4194304 + rows_read * 11 + result_rows * 2048) AS peak_memory_bytes,

    tokens_in,
    tokens_out,
    status,
    multiIf(
        status = 'ok',      '',
        status = 'timeout', 'query_timeout',
        status = 'error',   ['syntax_error', 'unknown_column', 'memory_limit_exceeded',
                             'too_many_simultaneous_queries', 'type_mismatch']
                                [wpick(n, 610, [0.31, 0.24, 0.18, 0.19, 0.08])],
                            'result_row_limit'
    ) AS error_kind,
    silently_truncated
FROM
(
    SELECT
        n, seq, trace_key, ts, fan_out,
        agent_name, agent_version, model, user_question,
        tool_name, sql_fingerprint, target_table,
        rows_read,
        toUInt64(rows_read * bytes_per_row) AS bytes_read,
        result_rows,
        tokens_in,
        tokens_out,
        status,
        silently_truncated,

        -- Execution time tracks the scan, with a tail.
        toUInt32(least(90000.0,
            6 + rows_read / 42000000.0 * 1000 * (0.6 + pow(u(n, 620), -0.35))
        )) AS duration_ms,

        -- Queue wait is the fan-out tax. It is near zero for a small
        -- trace and becomes the dominant term for a wide one, because
        -- forty queries issued in the same second contend for the same
        -- slots. Peak evening hours make it worse.
        toUInt32(least(120000.0,
            pow(greatest(fan_out - 4, 0), 1.45)
                * (2.5 + u(n, 621) * 9.0)
                * if(toHour(ts) BETWEEN 18 AND 22, 2.4, 1.0)
        )) AS queue_wait_ms
    FROM
    (
        SELECT
            n, seq, trace_key, ts, fan_out, q,
            agent_name, agent_version, model,
            questions[q]     AS user_question,
            q_target[q]      AS target_table,

            -- Iteration 0 is schema discovery: what tables exist, what
            -- is in them. Everything after is querying.
            multiIf(
                seq = 0 AND u(n, 630) < 0.34, 'list_tables',
                seq = 0,                      'describe_table',
                seq = 1 AND u(n, 630) < 0.22, 'describe_table',
                'run_select_query'
            ) AS tool_name,

            -- Literals stripped, so repeated shapes collapse. The
            -- templates are the queries these questions really provoke.
            if(tool_name != 'run_select_query',
               concat('-- ', tool_name, ' ', q_target[q]),
               replaceAll(
                   fingerprints[1 + (cityHash64(n, 631) % length(fingerprints))],
                   '{t}', q_target[q])
            ) AS sql_fingerprint,

            -- Scan size depends on how selective the query is. A wide
            -- window over the bets table is a different animal from a
            -- single-player lookup that the projection can serve.
            toUInt64(multiIf(
                tool_name != 'run_select_query', 0,
                q_target[q] = 'bets' AND sql_fingerprint LIKE '%player_id =%',
                    toUInt64(900 + u(n, 632) * 240000),
                q_target[q] = 'bets',
                    toUInt64(2600000 + pow(u(n, 632), 0.55) * 780000000),
                q_target[q] = 'payments',
                    toUInt64(90000 + pow(u(n, 632), 0.6) * 24000000),
                q_target[q] = 'sessions',
                    toUInt64(140000 + pow(u(n, 632), 0.6) * 41000000),
                q_target[q] = 'agent_traces',
                    toUInt64(20000 + pow(u(n, 632), 0.6) * 3900000),
                    toUInt64(1200 + u(n, 632) * 320000)
            )) AS rows_read,

            multiIf(q_target[q] = 'bets', 46.0, q_target[q] = 'payments', 38.0, 31.0)
                AS bytes_per_row,

            -- Aggregates return few rows; the occasional unaggregated
            -- SELECT returns as many as the limit allows.
            toUInt32(if(u(n, 633) < 0.86,
                        toUInt32(1 + u(n, 634) * 220),
                        toUInt32(1 + u(n, 634) * 1000))) AS result_rows,

            toUInt32(1800 + u(n, 635) * 26000) AS tokens_in,
            toUInt32(90 + pow(u(n, 636), 1.7) * 2400) AS tokens_out,

            multiIf(
                u(n, 637) < 0.9312, 'ok',
                u(n, 637) < 0.9660, 'error',
                u(n, 637) < 0.9840, 'timeout',
                                    'truncated'
            ) AS status,

            -- The dangerous case: the row limit was hit, the result came
            -- back looking complete, and nothing told the model. More
            -- likely on wide fan-out, because those are the traces
            -- issuing unbounded exploratory selects.
            (result_rows >= 1000 AND u(n, 638) < 0.62)
                OR (fan_out > 30 AND u(n, 638) < 0.07) AS silently_truncated
        FROM
        (
            SELECT
                n, seq, trace_key, fan_out, ts,
                1 + (cityHash64(trace_key, 640) % 26) AS q,
                ['ops-copilot', 'ops-copilot', 'ops-copilot',
                 'rg-monitor', 'trading-assist', 'finance-close', 'fraud-triage']
                    [wpick(trace_key, 641, [0.20, 0.16, 0.14, 0.18, 0.14, 0.10, 0.08])]
                    AS agent_name,
                ['1.2.0', '1.3.0', '1.4.1', '2.0.0']
                    [wpick(trace_key, 642, [0.11, 0.23, 0.38, 0.28])] AS agent_version,
                ['claude-opus-5', 'claude-sonnet-5', 'claude-haiku-4-5']
                    [wpick(trace_key, 643, [0.24, 0.58, 0.18])] AS model,

                -- Questions an operator actually asks out loud. Note how
                -- few of these correspond to a tile that would already
                -- exist on a dashboard.
                ['Why did GGR drop in Ontario last night?',
                 'Which games are paying out more than they should today?',
                 'Did any player exceed their deposit limit this week without being flagged?',
                 'Show me the biggest single wins across all brands in the last 24 hours',
                 'Is in-play bet acceptance slower during the World Cup than before it?',
                 'Which payment provider is declining the most, and where?',
                 'Are any of our self-excluded accounts still placing bets?',
                 'What is the hold on World Cup markets compared with the Premier League?',
                 'Which acquisition channel produces players who deposit but never bet?',
                 'Find accounts whose stakes escalated sharply after a big loss',
                 'What proportion of turnover comes from bonus balance by brand?',
                 'Which provider had a change in hit frequency in the last month?',
                 'Compare average session length for whales against casual players',
                 'Are there sessions where the IP country does not match the registered country?',
                 'What is the p99 bet acceptance latency by brand and hour?',
                 'Which games do whales play that casual players do not?',
                 'How much revenue did the World Cup final actually generate?',
                 'Did the payment outage on 14 August cost us deposits or just delay them?',
                 'Which affordability flags have not been reviewed?',
                 'What is our exposure on outright World Cup winner markets?',
                 'Show players who deposited, lost it all, and deposited again within an hour',
                 'How many withdrawals are stuck pending because KYC never completed?',
                 'Which brand has the worst first-deposit conversion, and why?',
                 'Are agents asking the same question more than once per trace?',
                 'What is the busiest hour of the week for each jurisdiction?',
                 'Which games have the widest gap between theoretical and actual RTP?'
                ] AS questions,

                ['bets', 'bets', 'payments', 'bets', 'bets', 'payments', 'bets', 'bets',
                 'payments', 'bets', 'bets', 'bets', 'sessions', 'sessions', 'bets',
                 'bets', 'bets', 'payments', 'rg_events', 'bets', 'payments', 'payments',
                 'payments', 'agent_traces', 'sessions', 'bets'] AS q_target,

                -- Twenty-four shapes, not ten. With a pool of ten and a
                -- median fan-out in the thirties, duplicate shapes per
                -- trace came out at 22 -- which reads as damning
                -- evidence of agents re-asking the same question, but
                -- was really just the pool being too small to fill a
                -- trace. Some genuine redundancy remains, which is
                -- honest: agents do re-ask.
                ['SELECT sum(stake_eur) - sum(payout_eur) FROM igaming.{t} WHERE ts >= ? AND ts < ? GROUP BY ?',
                 'SELECT count(), sum(stake_eur) FROM igaming.{t} WHERE ts BETWEEN ? AND ? AND brand_id = ? GROUP BY ?',
                 'SELECT ?, count() FROM igaming.{t} WHERE ts >= ? GROUP BY ? ORDER BY count() DESC LIMIT ?',
                 'SELECT quantile(?)(accept_latency_ms) FROM igaming.{t} WHERE ts >= ? GROUP BY ?',
                 'SELECT * FROM igaming.{t} WHERE player_id = ? ORDER BY ts DESC LIMIT ?',
                 'SELECT ?, sum(?) / sum(?) FROM igaming.{t} WHERE ts >= ? AND vertical = ? GROUP BY ? HAVING count() > ?',
                 'SELECT uniqExact(player_id) FROM igaming.{t} WHERE ts >= ? AND ? = ?',
                 'SELECT toStartOfHour(ts), count() FROM igaming.{t} WHERE ts >= ? GROUP BY ? ORDER BY ?',
                 'SELECT ? FROM igaming.{t} WHERE ts >= ? AND status = ? GROUP BY ? ORDER BY ? DESC LIMIT ?',
                 'SELECT avg(?), max(?), count() FROM igaming.{t} WHERE ts >= ? GROUP BY ?',
                 'SELECT jurisdiction, sum(stake_eur) FROM igaming.{t} WHERE ts >= ? GROUP BY ? WITH TOTALS',
                 'SELECT topK(?)(game_name) FROM igaming.{t} WHERE ts >= ? AND player_vip_tier = ?',
                 'SELECT toStartOfFifteenMinutes(ts), quantile(?)(?) FROM igaming.{t} WHERE ts >= ? GROUP BY ?',
                 'SELECT provider_id, countIf(payout_eur > ?) / count() FROM igaming.{t} WHERE ts >= ? GROUP BY ?',
                 'SELECT player_id, sum(amount_eur) FROM igaming.{t} WHERE ts >= ? AND txn_type = ? GROUP BY ? HAVING sum(amount_eur) > ?',
                 'SELECT psp, countIf(status = ?) / count() FROM igaming.{t} WHERE ts >= ? GROUP BY ?, ?',
                 'SELECT uniqExact(session_id), avg(duration_s) FROM igaming.{t} WHERE started_at >= ? GROUP BY ?',
                 'SELECT event_type, count() FROM igaming.{t} WHERE ts >= ? AND reviewed = ? GROUP BY ?',
                 'SELECT ? FROM igaming.{t} WHERE ts >= ? AND geo_mismatch = ? LIMIT ?',
                 'SELECT sum(stake_eur * theoretical_rtp) - sum(payout_eur) FROM igaming.{t} WHERE ts >= ? GROUP BY ?',
                 'SELECT market_name, sum(stake_eur), sum(payout_eur) FROM igaming.{t} WHERE competition = ? GROUP BY ?',
                 'SELECT count() FROM igaming.{t} WHERE ts >= ? AND player_self_excluded = ?',
                 'SELECT device, os, count() FROM igaming.{t} WHERE ts >= ? GROUP BY ?, ? ORDER BY count() DESC',
                 'SELECT argMax(?, stake_eur), max(stake_eur) FROM igaming.{t} WHERE ts >= ? GROUP BY ?'
                ] AS fingerprints
            FROM
            (
                SELECT
                    number AS n,
                    -- Rows arrive in blocks of 128, and each block is
                    -- divided among k traces of roughly 128/k spans.
                    --
                    -- An earlier version split each block into exactly
                    -- two traces at a random boundary. That forces a
                    -- bimodal distribution -- one small trace and one
                    -- large one, every time, mean pinned at half the
                    -- block, nothing in the middle and a hard ceiling.
                    -- Dividing by a variable k instead gives a
                    -- right-skewed unimodal spread: most questions
                    -- resolve in ten to twenty queries, and the ones
                    -- where k lands on 1 run to 128.
                    intDiv(number, 128) AS blk,
                    toUInt16(number % 128) AS pos,
                    toUInt16(1 + (cityHash64(blk, 650) % 12)) AS k,
                    toUInt16(intDiv(pos * k, 128)) AS sub,
                    cityHash64(blk, sub, 'trace') AS trace_key,
                    -- ceil(sub * 128 / k): the first position belonging
                    -- to this trace. Sizes sum to exactly 128.
                    toUInt16(intDiv(sub * 128 + k - 1, k)) AS trace_start,
                    toUInt16(pos - trace_start) AS seq,
                    toUInt16(intDiv((sub + 1) * 128 + k - 1, k) - trace_start) AS fan_out,

                    -- Agent adoption ramps across the window: a handful
                    -- of traces a day in early June, the dominant source
                    -- of queries by the end of August.
                    wpick(blk, 651, arrayMap(d -> pow(1.0 + d, 1.9), range(92))) - 1 AS day,

                    -- Agents run around the clock, but the humans who
                    -- prompt them still work office hours.
                    wpick(blk, 652,
                        [0.021, 0.019, 0.018, 0.017, 0.017, 0.019, 0.024, 0.032,
                         0.048, 0.062, 0.068, 0.066, 0.058, 0.062, 0.066, 0.064,
                         0.058, 0.049, 0.044, 0.041, 0.038, 0.033, 0.028, 0.024]) - 1
                        AS hour_utc,

                    -- Spans inside a trace fire within seconds of each
                    -- other. That simultaneity is what creates the
                    -- queueing this table is here to show.
                    toDateTime64('2026-06-01 00:00:00.000', 3, 'UTC')
                        + toIntervalSecond(day * 86400 + hour_utc * 3600
                                           + toUInt32(u(blk, 653) * 3500))
                        + toIntervalMillisecond(
                            toUInt32(if(seq = 0, 0,
                                        700 + seq * (40 + u(trace_key, 654) * 260)
                                            + u(number, 655) * 400))) AS ts
                FROM numbers_mt({n_spans:UInt64})
            )
        )
    )
)
SETTINGS
    max_insert_threads = 8,
    min_insert_block_size_rows = 524288;
