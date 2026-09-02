-- =====================================================================
-- Deterministic pseudo-random helpers.
--
-- Everything in this dataset is generated from row numbers via
-- cityHash64, so the same scale factor always produces byte-identical
-- data. No seeds to pass around, no rand() drift between runs, and any
-- single row can be regenerated in isolation.
-- =====================================================================

DROP FUNCTION IF EXISTS u;
DROP FUNCTION IF EXISTS pick;
DROP FUNCTION IF EXISTS wpick;
DROP FUNCTION IF EXISTS pareto_unit;
DROP FUNCTION IF EXISTS zipf_id;

-- Uniform [0, 1). `salt` gives independent streams from the same n.
CREATE FUNCTION u AS (n, salt) ->
    (cityHash64(n, salt) % 1000000000) / 1000000000.0;

-- Uniform choice from an array.
CREATE FUNCTION pick AS (n, salt, arr) ->
    arr[1 + (cityHash64(n, salt) % length(arr))];

-- Weighted choice. `w` is any array of non-negative weights; returns a
-- 1-based index into it. Used for hour-of-day curves, device mix, etc.
CREATE FUNCTION wpick AS (n, salt, w) ->
    arrayFirstIndex(
        c -> c >= u(n, salt) * arraySum(w),
        arrayCumSum(w));

-- Pareto(alpha) scaled to have mean exactly 1.0.
--
-- This is the workhorse for win multipliers. Because the mean is
-- pinned at 1, a payout of `stake * rtp * pareto_unit(...) / hit_rate`
-- has expectation `stake * rtp` for any alpha and any hit rate -- so
-- the realised RTP converges on the game's theoretical RTP by
-- construction rather than by hand-tuned weight vectors.
--
-- Lower alpha = fatter tail = higher volatility.
CREATE FUNCTION pareto_unit AS (n, salt, alpha) ->
    ((alpha - 1) / alpha) * pow(1 - u(n, salt), -1 / alpha);

-- Skewed player selection. Raising a uniform to a power concentrates
-- draws on low ids, and the player table is built so low ids are the
-- whales.
--
-- The exponent is 1.5, not 3. Cubing looked more dramatic but produced
-- whales taking 22% of all bets, which is wrong: high-value players bet
-- *bigger*, not vastly more often. At 1.5 the top 1% of accounts place
-- ~5% of bets, and the stake multiplier in 04_bets.sql turns that into
-- ~40% of turnover -- which is what operator data actually looks like.
CREATE FUNCTION zipf_id AS (n, salt, max_id) ->
    1 + toUInt32(pow(u(n, salt), 1.5) * (max_id - 1));

