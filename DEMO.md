# Demo run sheet

Target: 10 minutes. Key numbers are given for both the `small` and
`large` tiers, because several of them move by three orders of magnitude
between the two. Re-run `sql/10_verify.sql` after generating and use what
you get.

## Before you walk on

- Start the Cloud service. Run one throwaway question to warm the MCP
  connection and the model context.
- Open `dashboard/index.html`. **SNAPSHOT mode carries `small` tier
  figures.** If you are demoing against a `large` build, switch it to
  LIVE and point it at that service, or the dashboard and your live
  queries will disagree in front of the room. LIVE works against Cloud:
  the no-preflight design holds, because `text/plain` is a CORS-safelisted
  content type and the service returns
  `Access-Control-Allow-Origin: *`.
- Load the metric-choice skill (see Q3 below).

## Run sheet

| # | Say | Expect | Key number | Time |
|---|---|---|---|---|
| 1 | *Dashboard.* Margin was soft the week of 6 July. Nothing here says why. | — | 8 July is the softest day in the window. `small`: GGR −€122k vs €137k prior-7 avg. `large`: hold 6.20% vs 6.7–6.9% on surrounding days | 75s |
| 2 | "Margin was soft the week of the 6th of July. What happened?" | GGR by day, maybe by brand. Turnover dipped and the 8th is the weakest day. No cause. | `small`: turnover €2.66M vs €4.92M. `large`: €2.57B vs €4.79B prior-7 avg | 100s |
| 3 | "Which games paid out more often than they were supposed to on the 8th, and when did it start?" | `small`: groups by game, ~50 titles, each looks like variance. `large`: **Redwood's titles stand out immediately** | `small`: single-day RTP is 69% off at p90. `large`: 11% at p90, and the broken cohort separates cleanly. See below | 140s |
| 4 | "Group that by provider rather than by game." | Redwood, 02:00–14:00 UTC | `small`: 34.0% in-window vs 24.7% out. `large`: 32.17% vs 24.70% | 100s |
| 5 | *Back to the dashboard.* Hit rate by provider tile. | Redwood bottom of eight | `small`: 28.1%. `large`: 27.55%. Lowest of eight either way, on the day it broke | 90s |

**Beat 3 does not fail at `large`. Measured 6 September.** The beat was
built on per-game, per-day realised RTP being too noisy to read, and that
noise shrinks with the tier. At 10B it has shrunk past the point of
usefulness:

| Per-game deviation, 8 July | `small` | `large` |
|---|---|---|
| p90, all 417 games | 69% | 11% |
| p50, all 417 games | | 2% |
| Redwood's 60 titles, p10 | | +6.9% |
| The other 357 titles, p90 | | +2.8% |

The two cohorts barely overlap. Redwood's tenth percentile sits well
above everyone else's ninetieth, its median title overpays by 11.2%, and
15 of the 20 most overpaying titles are Redwood's. Ask for RTP by game on
the 8th at this tier and the agent finds it on the first ask.

The cause is sample size, not a change to the anomaly. A game gets about
76 cash bets on a single day at `small` and about 75,500 at `large`, so
one large win stops dominating.

Figures are `quantileExact` grouped by `game_id`, filtered to settled
cash play. Group by `game_name` instead and the cohorts move between
runs: 48 of the 353 names are shared by more than one game, several
across providers, so `any(provider_id)` assigns some titles arbitrarily.

Two consequences for the run sheet. Beat 3 lands in one question rather
than two, which buys back most of its 140s. And the
skills-versus-semantic-layer point has nothing to hang on at this tier,
so either make it at `small` or make it another way.

Ends on beat 5. Two more questions are worth asking and not worth the
clock. Quote them instead:

- Redwood's hit rate by hour on the 8th runs 34% inside 02:00–14:00 UTC
  against 24.7% outside at `small`, 32.17% against 24.70% at `large`. No
  other provider moves more than two points at `small`, and no more than
  0.07 points at `large`. The contrast gets cleaner with scale, not
  weaker.
- All eight brands were affected, because the config push was
  provider-wide.

Both are in `queries/02_beyond_the_dashboard.sql`. Telling the room they
are in the repo closes better than a rushed sixth query.

If running long: at `small`, drop Q3's second attempt. At `large` there
is no second attempt to drop, so take the time out of beats 1 and 2.
Never drop beat 5.

## Beat 5: three points

1. Redwood shows the **lowest** hit rate of any provider on the day it
   broke: 28.1% against Sable Studios at 34.3% (`small`), 27.55% against
   34.37% (`large`). The gap widens slightly with scale, 6.2 points to
   6.8.
2. Two reasons. The tile averages 12 broken hours with 12 normal ones,
   and Redwood's baseline is the portfolio's lowest anyway.
3. Deposit approval and latency tiles both compare against last week.
   The provider tile does not. Nobody was watching providers.

If someone says "just put a baseline on that tile", they're right. It is
obvious after the incident and nobody built it before.

## Q3: the beat that goes wrong, and only at `small`

At `small`, asking for RTP instead of hit frequency finds noise and the
agent reports nothing wrong. Two options there:

- **Seed a skill:** *"For windows shorter than a week, prefer hit
  frequency over realised RTP. RTP is dominated by rare large wins on
  large stakes."* Doubles as the skills-vs-semantic-layer point.
- **Let it fail**, then redirect. Costs ~60s. Owning it plays well.

Neither applies at `large`, where RTP resolves and the beat succeeds on
the first ask. The advice in that skill is still correct — hit frequency
is five times tighter at the median, 0.4% against 2.0% — it just no
longer rescues anything, because nothing needs rescuing.

If the skills point matters more than the tier, run the demo at `small`.
Beat 5 works identically at both, and it is the beat that carries the
talk.

## Agent observability: one line

Langfuse: open-source LLM and agent observability, acquired by ClickHouse
in January 2026, runs entirely on ClickHouse. Don't build tracing
yourself.

For live fan-out, run `queries/03_query_log_fanout.sql` against
`system.query_log` after a question. The count is real, and it is the
strongest version of the argument.

## Reference numbers

| Metric | `small` | `large` |
|---|---|---|
| Limit breaches / caught / missed | 12,185 / 10,439 / 1,746 | 12,493,550 / 10,744,641 / 1,748,909 |
| Proportion caught | 86% | 86% |
| Rows in `bets` | 10,000,072 | 10,000,072,000 |
| Denormalised column cost | 0.11–0.22 bytes/row, vs 2.1 for a timestamp | — |

The breach figures are **player-days in breach**, not accounts. The
query groups by `(player_id, breach_day)`, so one player breaching on
nine days counts nine times. They scale with the player base, which goes
×1,000 between tiers. The 86% is fixed by construction and is the only
tier-independent form of the statistic. The `+72` and `+72,000` on the
row counts are the fixed 240-account abuse cohort, which does not scale.

## If the network dies

Generate `small` locally, point MCP at `clickhouse-local`. Q2–Q7 work
offline. The dashboard's SNAPSHOT mode needs nothing.

## Question bank

For Q&A, or a longer slot.

**Compliance**
- "Did anyone breach their deposit limit without being flagged?"
- "Are any self-excluded accounts still placing bets?"
- "Which affordability flags has nobody reviewed?"
- "How many withdrawals are stuck pending on incomplete KYC?"

**Fraud**
- "Show me groups of accounts that behave identically."
- "Which accounts registered the same week, play two games, and wager
  only bonus balance?"
- "Any sessions where IP country doesn't match the account?"

**Operations**
- "Is in-play acceptance slower during the World Cup than before it?"
- "p99 bet acceptance latency by brand and hour?"
- "Which payment provider is declining most, and where?"
- "Did the 14 August outage cost us deposits, or just delay them?"

**Commercial**
- "Hold on World Cup markets versus the Premier League?"
- "Which acquisition channel brings players who deposit but never bet?"
- "Which games do whales play that casual players don't?"
- "How much did the World Cup final generate?"
