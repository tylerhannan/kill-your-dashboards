# Demo run sheet

Target: 13 minutes. Figures from a `small` tier build; re-run
`sql/10_verify.sql` after generating and use what you get.

## Before you walk on

- Start the Cloud service. Run one throwaway question to warm the MCP
  connection and the model context.
- Open `dashboard/index.html`. Leave it in SNAPSHOT mode.
- Load the metric-choice skill (see Q3 below).

## Run sheet

| # | Say | Expect | Key number | Time |
|---|---|---|---|---|
| 1 | *Dashboard.* Margin was soft the week of 6 July. Nothing here says why. | — | GGR −€122k vs €137k prior-7 avg | 75s |
| 2 | "Margin was soft the week of the 6th of July. What happened?" | GGR by day, maybe by brand. Turnover dipped, hold went negative on the 8th. No cause. | Turnover €2.66M vs €4.92M | 100s |
| 3 | "Which games paid out more often than they were supposed to on the 8th, and when did it start?" | Groups by game. ~50 titles, each looks like variance. | RTP swings ±25% at one game-day | 140s |
| 4 | "Group that by provider rather than by game." | Redwood, 02:00–14:00 UTC | 34.0% in-window vs 24.7% out | 100s |
| 5 | *Back to the dashboard.* Hit rate by provider tile. | Redwood bottom of eight | 28.1%, lowest on the day it broke | 90s |
| 6 | "Show me Redwood's hit rate by hour on the 8th against the same hours last week." | Step change at 02:00, back at 14:00 | No other provider moves >2pts | 100s |
| 7 | "How much did that cost us, and which brands?" | All eight brands | Provider-wide config push | 90s |

Cut in this order if running long: **7, then 6, then Q3's second
attempt.** Never 5.

## Beat 5: three points

1. Redwood shows the **lowest** hit rate of any provider on the day it
   broke: 28.1%, against Sable Studios at 34.3%.
2. Two reasons. The tile averages 12 broken hours with 12 normal ones,
   and Redwood's baseline is the portfolio's lowest anyway.
3. Deposit approval and latency tiles both compare against last week.
   The provider tile does not. Nobody was watching providers.

If someone says "just put a baseline on that tile", they're right. It is
obvious after the incident and nobody built it before.

## Q3: the beat that goes wrong

Ask for RTP instead of hit frequency and the agent finds noise, then
reports nothing wrong. Two options:

- **Seed a skill:** *"For windows shorter than a week, prefer hit
  frequency over realised RTP. RTP is dominated by rare large wins on
  large stakes."* Doubles as the skills-vs-semantic-layer point.
- **Let it fail**, then redirect. Costs ~60s. Owning it plays well.

## Agent observability: one line

Langfuse: open-source LLM and agent observability, acquired by ClickHouse
in January 2026, runs entirely on ClickHouse. Don't build tracing
yourself.

For live fan-out, run `queries/03_query_log_fanout.sql` against
`system.query_log` after a question. The count is real, and it is the
strongest version of the argument.

## Reference numbers

| Metric | Value |
|---|---|
| Limit breaches / caught / missed | 12,185 / 10,439 / 1,746 |
| Denormalised column cost | 0.11–0.22 bytes/row, vs 2.1 for a timestamp |

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
