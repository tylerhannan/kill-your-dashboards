-- =====================================================================
-- The dashboard rollup.
--
-- Run this AFTER 06_anomalies.sql. Two of the dashboard's tiles ask
-- questions about the whole dataset -- GGR by day across the window, and
-- hold by brand over the entire period -- so they cannot be date-bounded
-- without changing what they claim. At the 10B tier that made them a
-- 10-billion-row scan each, and the page took about a minute.
--
-- Those two tiles need 750 rows, not ten billion. This is the aggregate
-- they actually want, and it is the honest version of the argument the
-- repo is making: the way you make a dashboard fast is to precompute
-- exactly the questions it asks. That works right up until somebody asks
-- a different question, which is the entire point of `queries/02`.
--
-- Ordering matters. 06_anomalies.sql inserts the 240-account abuse
-- cohort's 72,000 bets after 04_bets.sql, so a rollup built before that
-- step silently omits them and `hold` disagrees with every other tile.
-- =====================================================================

DROP TABLE IF EXISTS igaming.ggr_rollup;

CREATE TABLE igaming.ggr_rollup
(
    d           Date,
    brand_name  LowCardinality(String),
    ggr_eur     Decimal(38, 4),
    stake_eur   Decimal(38, 4),
    bets        UInt64
)
ENGINE = SummingMergeTree
ORDER BY (d, brand_name);

-- No date filter. `hold` reports over the whole period, and bet
-- timestamps bleed a few hours past both window edges because
-- local-evening play in Ontario is the next day in UTC. Filtering here
-- would drop those rows and the rollup would stop matching the table.
INSERT INTO igaming.ggr_rollup
SELECT
    toDate(ts)      AS d,
    brand_name,
    sum(ggr_eur),
    sum(stake_eur),
    count()
FROM igaming.bets
WHERE status = 'settled'
GROUP BY d, brand_name;
