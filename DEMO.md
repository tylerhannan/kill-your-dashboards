# The demo

The questions to ask, in order, and what each one should come back with.

Everything below was checked against a `small` tier build. Numbers move a
little between tiers (the `medium` tier smooths daily GGR considerably),
so re-run `sql/10_verify.sql` after generating and note the figures you
actually get.

## The shape of it

The dashboard is not wrong. That is the whole point, and it is worth
saying out loud on stage. Every tile on it is accurate. It simply cannot
answer a question nobody thought to build it for.

Three questions live, in a 25-minute slot. The fourth and fifth are in
this file for anyone who wants to carry on afterwards, and saying so from
the stage is better than rushing them.

| Beat | What happens | ~Time |
|---|---|---|
| 1 | Dashboard. Margin looks soft that week, nothing explains it | 60s |
| 2 | **Question 1.** The vague one a human actually asks | 90s |
| 3 | **Question 2.** Agent narrows it: hit frequency, not RTP | 120s |
| 4 | **Question 3.** Group by provider. There it is | 90s |
| 5 | **Back to the dashboard.** The provider tile points the wrong way | 75s |

About eight minutes of clock. Budget nine.

Beat 5 is the one people remember and the one that gets skipped. It is
also the one you never cut: if you are at seven minutes and the payoff is
still coming, drop beat 4's hourly confirmation and go straight to the
dashboard.

Time is spent on the agent, not on you. A question that fans out to a
dozen tool calls is a minute or two of wall clock on its own, and you
cannot narrate silently over all of it. Two things buy that time back:

- **Pre-warm everything.** A cold Cloud service, a cold MCP connection
  and a cold model context will cost you a minute you have not got. Run a
  throwaway question before you walk on.
- **Seed the skill** with the metric rule in beat 3. Without it the agent
  may reach for RTP, find noise, and confidently report nothing wrong.
  That is a ninety-second detour with no payoff.

## Beat 1 — the dashboard

Open `dashboard/index.html`. Six tiles, all honest, all built from the
generated data.

What to say: margin was soft the week of 6 July. GGR by day is noisy and
several days that month are negative, so nothing on this screen isolates
a cause. The games team says nothing changed.

## Question 1 — the one a human actually asks

> **"Margin was soft the week of the 6th of July. What happened?"**

Deliberately vague, because that is how it arrives in real life. Nobody
opens an incident with a hypothesis.

Expect the agent to look at GGR by day, maybe by brand and vertical, and
report that turnover dipped and hold went negative on the 8th without
being able to say why. That is the correct answer to a vague question.

## Question 2 — sharpening it

> **"Which games paid out more often than they were supposed to on the
> 8th, and when did it start?"**

The phrasing matters. "More often" points at hit frequency. If you ask
"which games had bad RTP" instead, expect the agent to find noise: at one
day of one game's volume, realised RTP swings ±25% on high-volatility
titles and several games will look broken when they are fine.

**This is the beat most likely to go sideways.** Two ways to handle it:

- Give the agent a skill with the domain rule in it — *"for windows
  shorter than a week, prefer hit frequency over realised RTP; RTP is
  dominated by rare large wins on large stakes."* This is your
  skills-versus-semantic-layer slide, demonstrated rather than asserted.
- Or let it reach for RTP, watch it find nothing conclusive, and say so.
  Owning that is more convincing than a demo that never stumbles.

## Question 3 — the pivot that finds it

> **"Group that by provider rather than by game."**

The effect is spread across roughly fifty Redwood titles. Each one alone
looks like variance. Together, they are unmistakable, and this is where
you stop and go back to the dashboard.

If there is time, the hourly confirmation is worth showing. If there is
not, say it out loud instead: it is roughly 34% inside 02:00–14:00 UTC
against roughly 24.7% outside, while no other provider moves more than
about two points. Then tell them it is question 4 in the repo.

## Beat 5 — back to the dashboard

Return to the *Hit rate by provider* tile. For 8 July it reads:

| Provider | Hit rate, 8 July |
|---|---|
| Sable Studios | 34.3% |
| Atlas Originals | 33.6% |
| Kite Interactive | 32.4% |
| Helix Studios | 32.1% |
| Nordic Reels | 31.4% |
| Lumen Live | 30.3% |
| Panther Gaming | 29.9% |
| **Redwood** | **28.1%** |

Redwood is **last**. Lowest hit rate of any provider on the day it broke.

Two things are happening. The tile averages the twelve broken hours with
twelve normal ones, and Redwood's baseline is genuinely the lowest in the
portfolio because of its game mix. So the one tile you would have built
does not just miss the problem, it actively points away from it.

The signal was never the level. It was the change against its own
baseline, inside a window nobody chose in advance.

**The detail worth pausing on.** Look at which tiles compare the day
against the prior week and which do not. Deposit approval does. Bet
acceptance latency does. Every headline figure does. Hit rate by provider
does not, because nobody ever worried about game providers drifting.

Somebody will say the fix is obvious: put a baseline on the provider
tile. They are right, and that is the point. It is obvious *now*, once
you know what happened. The tile you need is always obvious after the
incident and never before it, which is why the ability to ask the
question matters more than the tile.

## Questions 4 and 5 — not live, in the repo

Say from the stage that these are in the repo. It is a better close than
a rushed fourth query, and it gives people a reason to clone it.

> **4. "Show me Redwood's hit rate by hour on the 8th against the same
> hours the week before."**

The confirmation. Roughly 34% inside 02:00–14:00 UTC against 24.7%
outside, with no other provider moving more than about two points.

> **5. "How much did that cost us, and which brands were affected?"**

All eight, because the config push was provider-wide. The action is
concrete: roll the provider config back and reconcile the affected
rounds.

## Agent observability, briefly

Worth one line rather than a detour: you should not be building this
yourself. [Langfuse](https://langfuse.com) is the open-source platform
for LLM and agent observability — traces, evaluations, prompt management
— and ClickHouse acquired it in January 2026. Its architecture runs
entirely on ClickHouse in both the cloud and self-hosted deployments,
which is the same argument this dataset makes, already shipped as a
product.

The `agent_traces` table in this repo is synthetic. It exists so the
fan-out number is measurable rather than asserted, and
`queries/03_agent_observability.sql` shows what you would ask of it. It
is not a substitute for real tracing.

## Question bank

For Q&A, or a longer slot. Each one is answerable against this dataset,
and none of them is a tile anybody would have pre-built.

**Responsible gaming and compliance**

> "Did anyone breach their deposit limit without being flagged?"
> "Are any of our self-excluded accounts still placing bets?"
> "Which affordability flags has nobody reviewed?"
> "Find accounts whose stakes escalated sharply after a big loss."
> "How many withdrawals are stuck pending because KYC never completed?"

**Fraud and bonus abuse**

> "Show me groups of accounts that behave identically."
> "Which accounts registered in the same week, play only two games, and
>  wager exclusively bonus balance?"
> "Are there sessions where the IP country doesn't match the account?"

**Operations**

> "Is in-play bet acceptance slower during the World Cup than before it?"
> "What's the p99 bet acceptance latency by brand and hour?"
> "Which payment provider is declining the most, and where?"
> "Did the outage on 14 August cost us deposits, or just delay them?"

**Commercial**

> "What's the hold on World Cup markets compared with the Premier League?"
> "Which acquisition channel brings players who deposit but never bet?"
> "Which games do whales play that casual players don't?"
> "Compare average session length for whales against casual players."
> "How much revenue did the World Cup final actually generate?"

## If the network dies

Generate the `small` tier locally beforehand and point the MCP server at
`clickhouse-local`. Beats 2 through 6 work identically offline. The
dashboard's default mode has its numbers baked in and needs nothing at
all.
