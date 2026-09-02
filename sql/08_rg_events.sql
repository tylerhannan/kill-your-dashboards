-- =====================================================================
-- igaming.rg_events -- responsible gaming.
--
-- Run AFTER 05_payments.sql and 06_sessions.sql.
--
-- Almost every row here is DERIVED from what actually happened in the
-- other tables rather than invented independently. A limit_hit event
-- exists because that player's approved deposits that day really did
-- exceed the limit on their account; a reality_check exists because the
-- session really did run long.
--
-- That coherence is the whole point. It means a question like "were all
-- of our deposit limit breaches flagged?" has a real answer that
-- requires cross-referencing payments against a nullable column in
-- players and then against this table -- three sources, no dashboard
-- tile, and the sort of question you only ever ask in words.
--
-- Which sets up ANOMALY 5, the quietest of the five: the automated
-- monitor did NOT catch every breach. See challenges/README.md.
-- =====================================================================

TRUNCATE TABLE IF EXISTS igaming.rg_events;

-- ---------------------------------------------------------------------
-- Pass 1: limit_set.
-- Every player carrying a deposit limit set it at some point.
-- ---------------------------------------------------------------------
INSERT INTO igaming.rg_events
(
    event_id, ts, player_id, player_vip_tier, player_country,
    brand_id, brand_name, jurisdiction, licence_body,
    event_type, triggered_by, threshold_eur, observed_eur, reviewed, notes
)
SELECT
    cityHash64('limit_set', p.player_id)          AS event_id,
    -- Set either at signup or partway through the window.
    if(u(p.player_id, 500) < 0.62,
       toDateTime64(p.registered_at, 3, 'UTC'),
       toDateTime64('2026-06-01 00:00:00.000', 3, 'UTC')
           + toIntervalSecond(toUInt32(u(p.player_id, 501) * 7862400)))  AS ts,
    p.player_id,
    p.vip_tier,
    p.country,
    p.brand_id,
    dictGetString('igaming.dict_brands', 'brand_name',   tuple(p.brand_id)) AS brand_name,
    p.jurisdiction,
    dictGetString('igaming.dict_brands', 'licence_body', tuple(p.brand_id)) AS licence_body,
    'limit_set'                                   AS event_type,
    -- Most limits are player-chosen. A minority are imposed by the
    -- operator after an intervention, which is a materially different
    -- thing and worth being able to tell apart.
    if(u(p.player_id, 502) < 0.88, 'player', 'operator') AS triggered_by,
    p.deposit_limit_eur                           AS threshold_eur,
    NULL                                          AS observed_eur,
    true                                          AS reviewed,
    concat('Daily deposit limit set to EUR ', toString(p.deposit_limit_eur)) AS notes
FROM igaming.players AS p
WHERE p.deposit_limit_eur IS NOT NULL;

-- ---------------------------------------------------------------------
-- Pass 2: limit_hit -- derived from real deposit activity.
--
-- A player with a daily limit whose approved deposits that day exceeded
-- it. Note the deliberate 86% coverage: the automated monitor missed
-- roughly one breach in seven. Those unflagged breaches are ANOMALY 5,
-- and they are only findable by reconciling three tables.
-- ---------------------------------------------------------------------
INSERT INTO igaming.rg_events
(
    event_id, ts, player_id, player_vip_tier, player_country,
    brand_id, brand_name, jurisdiction, licence_body,
    event_type, triggered_by, threshold_eur, observed_eur, reviewed, notes
)
SELECT
    cityHash64('limit_hit', player_id, breach_day) AS event_id,
    breach_ts                                      AS ts,
    player_id,
    vip_tier,
    country,
    brand_id,
    dictGetString('igaming.dict_brands', 'brand_name',   tuple(brand_id)) AS brand_name,
    jurisdiction,
    dictGetString('igaming.dict_brands', 'licence_body', tuple(brand_id)) AS licence_body,
    'limit_hit'                                    AS event_type,
    'automated'                                    AS triggered_by,
    toDecimal64(limit_eur, 2)                      AS threshold_eur,
    toDecimal64(deposited_eur, 2)                  AS observed_eur,
    -- Even when the monitor fires, a human does not always look. The
    -- gap between flagged and reviewed is its own compliance question.
    u(player_id + breach_day, 510) < 0.71          AS reviewed,
    concat('Approved deposits EUR ', toString(round(deposited_eur, 2)),
           ' against daily limit EUR ', toString(round(limit_eur, 2))) AS notes
FROM
(
    SELECT
        pay.player_id                       AS player_id,
        toDate(pay.ts)                      AS breach_day,
        -- The event lands when the breaching deposit was approved.
        max(pay.ts)                         AS breach_ts,
        sum(pay.amount_eur)                 AS deposited_eur,
        any(pl.deposit_limit_eur)           AS limit_eur,
        any(pay.player_vip_tier)            AS vip_tier,
        any(pay.player_country)             AS country,
        any(pay.brand_id)                   AS brand_id,
        any(pay.jurisdiction)               AS jurisdiction
    FROM igaming.payments AS pay
    INNER JOIN igaming.players AS pl ON pl.player_id = pay.player_id
    WHERE pay.txn_type = 'deposit'
      AND pay.status = 'approved'
      -- IS NOT NULL matters: a NULL limit is "no limit set", and
      -- treating it as zero would flag the entire player base.
      AND pl.deposit_limit_eur IS NOT NULL
    GROUP BY pay.player_id, toDate(pay.ts)
    HAVING deposited_eur > limit_eur
)
-- ANOMALY 5: the monitor only caught 86% of breaches.
WHERE u(player_id * 1000 + toUInt32(breach_day), 511) < 0.86;

-- ---------------------------------------------------------------------
-- Pass 3: reality_check -- derived from long sessions.
-- Regulators in several of these markets require a periodic prompt once
-- a session passes a duration threshold.
-- ---------------------------------------------------------------------
INSERT INTO igaming.rg_events
(
    event_id, ts, player_id, player_vip_tier, player_country,
    brand_id, brand_name, jurisdiction, licence_body,
    event_type, triggered_by, threshold_eur, observed_eur, reviewed, notes
)
SELECT
    cityHash64('reality_check', s.session_id)     AS event_id,
    s.started_at + toIntervalSecond(1800)         AS ts,
    s.player_id,
    dictGetString('igaming.dict_players', 'vip_tier', s.player_id) AS player_vip_tier,
    s.player_country,
    s.brand_id,
    dictGetString('igaming.dict_brands', 'brand_name',   tuple(s.brand_id)) AS brand_name,
    s.jurisdiction,
    dictGetString('igaming.dict_brands', 'licence_body', tuple(s.brand_id)) AS licence_body,
    'reality_check'                               AS event_type,
    'automated'                                   AS triggered_by,
    NULL                                          AS threshold_eur,
    NULL                                          AS observed_eur,
    true                                          AS reviewed,
    concat('Thirty minutes elapsed in session; ', toString(s.bet_count), ' bets placed') AS notes
FROM igaming.sessions AS s
-- Thirty minutes, not sixty. Both intervals are used in practice, and
-- 06_sessions.sql produces sessions with a p95 around 36 minutes, so a
-- sixty-minute trigger fired on nothing at all.
WHERE s.duration_s > 1800
  -- Not every jurisdiction mandates it, and not every prompt fires.
  AND s.jurisdiction IN ('GB', 'SE', 'DK', 'NL', 'CA-ON')
  AND u(s.session_id, 520) < 0.93;

-- ---------------------------------------------------------------------
-- Pass 4: cool_off and self_exclude, for accounts that have one on
-- record in the player table.
-- ---------------------------------------------------------------------
INSERT INTO igaming.rg_events
(
    event_id, ts, player_id, player_vip_tier, player_country,
    brand_id, brand_name, jurisdiction, licence_body,
    event_type, triggered_by, threshold_eur, observed_eur, reviewed, notes
)
SELECT
    cityHash64('exclusion', p.player_id, ev)      AS event_id,
    -- A cool-off typically precedes a full exclusion by days or weeks.
    toDateTime64(p.self_excluded_until, 3, 'UTC')
        - toIntervalDay(if(ev = 'cool_off',
                           toUInt16(30 + u(p.player_id, 530) * 120),
                           toUInt16(u(p.player_id, 531) * 30)))         AS ts,
    p.player_id,
    p.vip_tier,
    p.country,
    p.brand_id,
    dictGetString('igaming.dict_brands', 'brand_name',   tuple(p.brand_id)) AS brand_name,
    p.jurisdiction,
    dictGetString('igaming.dict_brands', 'licence_body', tuple(p.brand_id)) AS licence_body,
    ev                                            AS event_type,
    if(ev = 'self_exclude', 'player', 'operator')  AS triggered_by,
    NULL                                          AS threshold_eur,
    NULL                                          AS observed_eur,
    true                                          AS reviewed,
    if(ev = 'self_exclude',
       concat('Self-exclusion recorded until ', toString(p.self_excluded_until)),
       'Temporary cool-off applied prior to exclusion')                 AS notes
FROM igaming.players AS p
ARRAY JOIN ['cool_off', 'self_exclude'] AS ev
WHERE p.self_excluded_until IS NOT NULL
  -- Not everyone who self-excludes had a cool-off first.
  AND (ev = 'self_exclude' OR u(p.player_id, 532) < 0.58);

-- ---------------------------------------------------------------------
-- Pass 5: affordability_flag -- derived from deposit behaviour.
--
-- Fires on accounts whose deposits over the window are large relative to
-- what the operator knows about them. Modelled on total approved
-- deposits, because that is the signal an operator actually has.
-- ---------------------------------------------------------------------
INSERT INTO igaming.rg_events
(
    event_id, ts, player_id, player_vip_tier, player_country,
    brand_id, brand_name, jurisdiction, licence_body,
    event_type, triggered_by, threshold_eur, observed_eur, reviewed, notes
)
SELECT
    cityHash64('affordability', player_id)        AS event_id,
    flag_ts                                       AS ts,
    player_id,
    vip_tier,
    country,
    brand_id,
    dictGetString('igaming.dict_brands', 'brand_name',   tuple(brand_id)) AS brand_name,
    jurisdiction,
    dictGetString('igaming.dict_brands', 'licence_body', tuple(brand_id)) AS licence_body,
    'affordability_flag'                          AS event_type,
    'automated'                                   AS triggered_by,
    toDecimal64(25000.00, 2)                      AS threshold_eur,
    toDecimal64(total_deposited, 2)               AS observed_eur,
    -- Affordability flags are the least consistently reviewed of all of
    -- them, which is exactly the sort of thing worth being asked about.
    u(player_id, 540) < 0.44                      AS reviewed,
    concat('Cumulative approved deposits EUR ', toString(round(total_deposited, 0)),
           ' over 90 days exceeds affordability threshold')             AS notes
FROM
(
    SELECT
        player_id,
        sum(amount_eur)          AS total_deposited,
        max(ts)                  AS flag_ts,
        any(player_vip_tier)     AS vip_tier,
        any(player_country)      AS country,
        any(brand_id)            AS brand_id,
        any(jurisdiction)        AS jurisdiction
    FROM igaming.payments
    WHERE txn_type = 'deposit' AND status = 'approved'
    GROUP BY player_id
    HAVING total_deposited > 25000
);
