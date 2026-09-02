# Five things are wrong with this data

Each one is a real incident pattern from online gambling operations.
Each one is invisible to any dashboard you would plausibly have built,
because a dashboard can only show you the question somebody already
thought to ask.

None of them are hidden by obscurity. They are hidden by the fact that
finding them requires a question, and the question is different every
time.

**Spoiler warning.** The generator files in `sql/` are commented, so
they give away exactly what was planted and where. If you want to try
these cold, don't read them yet.

## What you get told

Nothing except this: something is wrong, and here is the database.

That is deliberate, and it is the realistic version. Nobody opens an
incident with "the hit frequency on one provider's titles is 30% high
between 02:00 and 14:00 UTC". They open it with "revenue looks weird"
or, more often, with a regulator's email.

If you want a warmer start, each challenge below has a **Symptom** you
can treat as the opening line.

## 1. Revenue is soft and nobody can say why

**Symptom.** Casino margin was down for a day in early July. Daily GGR
is within normal variance. The games team says nothing changed.

**Tier.** Findable at `small`.

<details>
<summary>Hint</summary>

Realised RTP is a trap here. It is dominated by rare large wins on large
stakes, so at one day of one provider's volume it is far too noisy to
show a real 30% shift — you will see games that look 25% off which are
simply variance.

Ask a lower-variance question. What fraction of bets pay out anything at
all? That is a binomial statistic and it settles in a few hundred rows.

Then: group by what? Not by game: the effect is spread across dozens of
titles, and each one individually looks like noise. Something the titles
have in common.
</details>

<details>
<summary>Answer</summary>

A configuration push loosened hit frequency across **every title from
one provider (`Redwood`) on all eight brands**, between **02:00 and
14:00 UTC on 8 July 2026**. Hit rate runs about 30% above normal;
`theoretical_rtp` on the row was never changed, so the games were paying
out more than they advertised.

```sql
SELECT
    provider_id,
    countIf(toHour(ts) BETWEEN 2 AND 13)                      AS bets_inside,
    round(100 * countIf(payout_eur > 0 AND toHour(ts) BETWEEN 2 AND 13)
              / countIf(toHour(ts) BETWEEN 2 AND 13), 2)      AS hit_pct_inside,
    round(100 * countIf(payout_eur > 0 AND toHour(ts) NOT BETWEEN 2 AND 13)
              / countIf(toHour(ts) NOT BETWEEN 2 AND 13), 2)  AS hit_pct_outside
FROM igaming.bets
WHERE vertical != 'sportsbook' AND status = 'settled' AND NOT is_bonus
  AND toDate(ts) = '2026-07-08'
GROUP BY provider_id
ORDER BY hit_pct_inside - hit_pct_outside DESC;
```

Redwood shows roughly 34% inside the window against 25% outside. Every
other provider moves less than two points.

**The trap.** Sort that result by `hit_pct_inside` instead of by the
*delta* and Redwood is not even top of the list, because two other providers
have higher absolute hit rates, because their game mix differs. The
signal is the change, not the level. A dashboard tile showing "hit rate
by provider" would have been reassuring.
</details>

## 2. The night of the final

**Symptom.** Complaints from in-play bettors during the World Cup final
on 19 July. Turnover for the day was a record. The dashboard is green.

**Tier.** Findable at `small`.

<details>
<summary>Hint</summary>

Averages will not show you this and neither will hourly buckets.
Whatever you look at, look at the tail of it, and look at it in
fifteen-minute slices.
</details>

<details>
<summary>Answer</summary>

In-play bet acceptance latency went up roughly sixfold between **19:00
and 22:30 UTC on 19 July**. p50 goes from about 37ms to about 183ms; p99
from about 150ms to about 900ms.

```sql
SELECT
    toStartOfFifteenMinutes(ts)               AS quarter_hour,
    count()                                   AS in_play_bets,
    round(quantile(0.50)(accept_latency_ms))  AS p50_ms,
    round(quantile(0.99)(accept_latency_ms))  AS p99_ms
FROM igaming.bets
WHERE vertical = 'sportsbook' AND is_live AND toDate(ts) = '2026-07-19'
GROUP BY quarter_hour
ORDER BY quarter_hour;
```

Revenue was never affected in a way anyone would notice, which is
exactly why it stayed invisible. The cost was borne by customers who
could not get a bet on.
</details>

## 3. The promotion that worked too well

**Symptom.** A welcome bonus on the Dutch brand converted far better
than forecast in late July. Marketing is delighted. Finance is not sure
why the numbers do not reconcile.

**Tier.** Findable at `small`. Genuinely buried at `large`.

<details>
<summary>Hint</summary>

Every single attribute of these accounts is individually normal. Small
stakes are normal. Bonus play is normal. Incomplete KYC is normal.
Playing one or two games is normal.

You cannot find this by filtering on any one column. You find it by
looking for accounts that are *identical to each other*, and asking how
many distinct values a group of accounts has where you would expect
many.
</details>

<details>
<summary>Answer</summary>

**240 accounts**, all registered inside four days, all through the
`affiliate` channel, all on brand `KES`, all with KYC left incomplete.
Each made one minimum qualifying deposit, then ground out roughly 300
bets at €0.10–€0.50 on exactly two low-volatility games, from two IP
countries that are not the Netherlands, on a single app build, with no
diurnal pattern at all — they played at every hour, because they were
not people sleeping.

```sql
SELECT
    brand_name,
    player_acq_channel,
    player_registered_on,
    uniqExact(player_id)                             AS accounts,
    count()                                          AS bets,
    round(avg(stake_eur), 3)                         AS avg_stake_eur,
    round(100 * countIf(is_bonus) / count(), 1)      AS pct_bonus,
    uniqExact(game_id)                               AS distinct_games,
    uniqExact(app_version)                           AS distinct_app_builds,
    uniqExact(ip_country)                            AS distinct_ip_countries
FROM igaming.bets
WHERE player_kyc_status != 'verified'
GROUP BY brand_name, player_acq_channel, player_registered_on
HAVING accounts > 20 AND pct_bonus > 90 AND distinct_games < 5
ORDER BY accounts DESC;
```

Grouping by registration date matters: without it the cohort is diluted
by the legitimate unverified players on the same brand and channel, and
the query returns nothing. The cohort surfaces as four consecutive
registration dates, roughly sixty accounts each, every one of them 100%
bonus play across two games on a single app build.

Then look at
`igaming.payments` for the same cohort: the withdrawals are mostly
`pending`, because KYC was never completed.

**Why no dashboard finds it.** The signal is a *conjunction* across six
low-cardinality columns. Pre-building that means pre-guessing the
combination, and there are more combinations than tiles.
</details>

## 4. A bad afternoon in August

**Symptom.** Deposit volume dipped on 14 August. Support saw a spike in
tickets. It recovered on its own, so nobody investigated.

**Tier.** Findable at `small`.

<details>
<summary>Hint</summary>

Decline rate is a proportion, so it is stable in small samples. Slice it
by the thing that sits between you and the customer's bank.
</details>

<details>
<summary>Answer</summary>

The payment provider `Northgate` degraded for six hours, **11:00 to
17:00 UTC on 14 August**. Deposit declines went from roughly 8% to
roughly 75%, all reporting `issuer_unavailable`, with latency up
sevenfold.

```sql
SELECT
    psp,
    countIf(toHour(ts) BETWEEN 11 AND 16)                                  AS attempts_inside,
    round(100 * countIf(status = 'declined' AND toHour(ts) BETWEEN 11 AND 16)
              / countIf(toHour(ts) BETWEEN 11 AND 16), 1)                  AS declined_inside,
    round(100 * countIf(status = 'declined' AND toHour(ts) NOT BETWEEN 11 AND 16)
              / countIf(toHour(ts) NOT BETWEEN 11 AND 16), 1)              AS declined_outside
FROM igaming.payments
WHERE txn_type = 'deposit' AND toDate(ts) = '2026-08-14'
GROUP BY psp
ORDER BY declined_inside DESC;
```

The follow-up question is the one that matters commercially: did those
customers come back and deposit successfully later, or did they leave?
The data can answer that. Nothing on a dashboard would have prompted
anyone to ask.
</details>

## 5. The one that would end up in front of a regulator

**Symptom.** None. Nothing alerted. This is the quiet one.

**Tier.** Findable at `small`.

<details>
<summary>Hint</summary>

Three tables. What players said their limit was, what they actually
deposited, and what the monitoring system noticed.

Watch the NULLs. A player with no deposit limit set has `NULL`, not
zero, and if you treat those as zero you will "find" that your entire
player base is in breach.
</details>

<details>
<summary>Answer</summary>

Of the deposit-limit breaches that actually occurred, the automated
monitor caught about **86%**. At the `small` tier that leaves **1,746
breaches that nothing ever flagged**.

```sql
WITH breaches AS
(
    SELECT pay.player_id AS player_id, toDate(pay.ts) AS breach_day
    FROM igaming.payments AS pay
    INNER JOIN igaming.players AS pl ON pl.player_id = pay.player_id
    WHERE pay.txn_type = 'deposit'
      AND pay.status = 'approved'
      AND pl.deposit_limit_eur IS NOT NULL     -- NULL means no limit, not zero
    GROUP BY player_id, breach_day
    HAVING sum(pay.amount_eur) > any(pl.deposit_limit_eur)
)
SELECT
    (SELECT count() FROM breaches)                                          AS actual,
    (SELECT count() FROM igaming.rg_events WHERE event_type = 'limit_hit')  AS flagged,
    (SELECT count() FROM breaches)
      - (SELECT count() FROM igaming.rg_events WHERE event_type = 'limit_hit') AS never_flagged;
```

And a second layer underneath it: of the breaches that *were* flagged,
only about 71% were ever reviewed by a human. Affordability flags are
worse, at about 40%.

```sql
SELECT
    event_type,
    count()                                          AS flags,
    countIf(NOT reviewed)                            AS unreviewed,
    round(100 * countIf(NOT reviewed) / count(), 1)   AS pct_unreviewed
FROM igaming.rg_events
WHERE triggered_by = 'automated'
GROUP BY event_type
ORDER BY unreviewed DESC;
```

This is the one that matters most and the one least likely to be on a
dashboard, because the metric is an *absence*. You cannot build a tile
for the events that did not happen. You can only ask.
</details>

## Doing this with an agent

Point an agent at the database over MCP (see
[`../SETUP.md`](../SETUP.md)), give it the symptom line, and watch what
it does. That is more interesting than solving them yourself.

Things worth watching for:

- **Does it pick the low-variance metric?** Challenge 1 punishes anything
  that reaches for RTP first.
- **Does it handle the NULLs?** Challenge 5 has a wrong answer that looks
  extremely convincing.
- **How many queries does it take?** Every tool call it makes lands in
  `igaming.agent_traces` if you are logging them. The median in the
  shipped trace data is 14 queries per question, and the 95th percentile
  is 43.
- **Does it notice when a result was truncated?** About 2.3% of the
  shipped spans came back cut short with nothing signalling it. An agent
  that reasons confidently over a partial result set produces exactly the
  kind of answer that gets believed and is wrong.
