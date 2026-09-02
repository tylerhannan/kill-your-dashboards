-- =====================================================================
-- igaming.sessions
--
-- Parameters:
--   {n_empty_sessions:UInt64}  logins that produced no bets
--   {n_players:UInt32}         must match 02_reference.sql
--
-- Run AFTER 04_bets.sql.
--
-- Sessions that contain bets are aggregated out of the bets table
-- rather than generated independently. Generating both sides separately
-- is how synthetic datasets end up with session_ids in the fact table
-- that do not exist in the session table -- the exact class of quiet
-- referential break that makes a dataset useless for demonstrating
-- anything. Here, every session_id in `bets` is in `sessions` by
-- construction, and bet_count is the true count.
--
-- Then a second pass adds logins that produced no bets at all: someone
-- checks a balance, looks at the World Cup prices, and leaves. Roughly
-- a third of real sessions look like this, and they are invisible if
-- you only ever look at the bets table.
-- =====================================================================

TRUNCATE TABLE IF EXISTS igaming.sessions;

-- ---------------------------------------------------------------------
-- Pass 1: sessions with betting activity.
-- ---------------------------------------------------------------------
INSERT INTO igaming.sessions
(
    session_id, player_id, brand_id, jurisdiction,
    started_at, ended_at, duration_s,
    device, os, app_version, ip_country, player_country, geo_mismatch,
    bet_count, login_method
)
SELECT
    session_id,
    player_id,
    brand_id,
    jurisdiction,
    started_at,
    ended_at,
    toUInt32(dateDiff('second', started_at, ended_at)) AS duration_s,
    device,
    os,
    app_version,
    ip_country,
    player_country,
    geo_mismatch,
    bet_count,
    ['password', 'biometric', 'sso', 'magic_link']
        [wpick(session_id, 400, [0.42, 0.38, 0.12, 0.08])] AS login_method
FROM
(
    SELECT
        session_id,
        any(player_id)      AS player_id,
        any(brand_id)       AS brand_id,
        any(jurisdiction)   AS jurisdiction,
        -- A session starts before the first wager: login, navigate,
        -- pick a game. It ends a little after the last one.
        min(ts) - toIntervalSecond(toUInt32(15 + u(session_id, 401) * 240))  AS started_at,
        max(ts) + toIntervalSecond(toUInt32(20 + u(session_id, 402) * 900))  AS ended_at,
        -- These are session-constant in 04_bets.sql, so any() is exact
        -- rather than an arbitrary pick.
        any(device)         AS device,
        any(os)             AS os,
        any(app_version)    AS app_version,
        any(ip_country)     AS ip_country,
        any(player_country) AS player_country,
        any(geo_mismatch)   AS geo_mismatch,
        toUInt32(count())   AS bet_count
    FROM igaming.bets
    GROUP BY session_id
)
SETTINGS max_insert_threads = 16;

-- ---------------------------------------------------------------------
-- Pass 2: logins with no betting activity.
--
-- Keyed into a separate hash namespace so these ids cannot collide with
-- the ones minted in 04_bets.sql.
-- ---------------------------------------------------------------------
INSERT INTO igaming.sessions
(
    session_id, player_id, brand_id, jurisdiction,
    started_at, ended_at, duration_s,
    device, os, app_version, ip_country, player_country, geo_mismatch,
    bet_count, login_method
)
SELECT
    cityHash64('idle-session', player_id, day, n) AS session_id,
    player_id,
    brand_id,
    jurisdiction,
    started_at,
    started_at + toIntervalSecond(duration_s) AS ended_at,
    duration_s,
    device,
    os,
    app_version,
    ip_country,
    player_country,
    ip_country != player_country AS geo_mismatch,
    0 AS bet_count,
    ['password', 'biometric', 'sso', 'magic_link']
        [wpick(n, 410, [0.42, 0.38, 0.12, 0.08])] AS login_method
FROM
(
    SELECT
        n,
        day,
        player_id,
        player_country,
        brand_id,
        jurisdiction,
        started_at,
        -- Idle sessions are short. Most are under two minutes: open the
        -- app, glance at a balance, close it.
        toUInt32(8 + pow(u(n, 411), 2.4) * 1700) AS duration_s,
        ['mobile', 'desktop', 'tablet'][wpick(n, 412, [0.78, 0.16, 0.06])] AS device,
        multiIf(
            device = 'mobile', ['iOS', 'Android'][1 + (cityHash64(n, 413) % 2)],
            device = 'tablet', ['iPadOS', 'Android'][1 + (cityHash64(n, 413) % 2)],
            ['Windows', 'macOS', 'Linux'][wpick(n, 413, [0.72, 0.25, 0.03])]
        ) AS os,
        if(device = 'desktop',
           ['web-4.2', 'web-4.3', 'web-4.4'][wpick(n, 414, [0.15, 0.35, 0.50])],
           ['app-9.1', 'app-9.2', 'app-9.3', 'app-10.0']
               [wpick(n, 414, [0.08, 0.19, 0.44, 0.29])]) AS app_version,
        if(u(n, 415) < 0.96,
           player_country,
           ['GB','IE','DE','FR','PT','IT','PL','NO','MT','CY']
               [1 + (cityHash64(n, 416) % 10)]) AS ip_country
    FROM
    (
        SELECT
            number AS n,
            zipf_id(number, 420, {n_players:UInt32}) AS player_id,
            dictGetString('igaming.dict_players', 'country',  player_id) AS player_country,
            dictGetString('igaming.dict_players', 'brand_id', player_id) AS brand_id,
            dictGetString('igaming.dict_brands', 'jurisdiction', tuple(brand_id)) AS jurisdiction,
            dictGetInt8('igaming.dict_brands', 'tz_offset_hours', tuple(brand_id)) AS tz_off,

            wpick(number, 421, arrayMap(d ->
                multiIf(
                    d BETWEEN 47 AND 48, 3.80,
                    d BETWEEN 43 AND 44, 3.00,
                    d BETWEEN 38 AND 40, 2.50,
                    d BETWEEN 33 AND 36, 2.20,
                    d BETWEEN 27 AND 32, 2.00,
                    d BETWEEN 10 AND 26, 1.85,
                    1.00)
                * if(toDayOfWeek(toDate('2026-06-01') + toIntervalDay(d)) >= 6, 1.25, 1.0),
                range(92))) - 1 AS day,

            toDateTime64('2026-06-01 00:00:00.000', 3, 'UTC')
                + toIntervalSecond(day * 86400
                    + (wpick(number, 422,
                        [0.020, 0.012, 0.008, 0.006, 0.005, 0.006, 0.010, 0.018,
                         0.026, 0.032, 0.036, 0.040, 0.045, 0.046, 0.048, 0.052,
                         0.058, 0.068, 0.082, 0.096, 0.104, 0.098, 0.070, 0.044])
                       - 1 - tz_off) * 3600)
                + toIntervalMillisecond(toUInt32(u(number, 423) * 3600000)) AS started_at
        FROM numbers_mt({n_empty_sessions:UInt64})
    )
)
SETTINGS max_insert_threads = 16;
