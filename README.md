# iGaming, synthetically

A reproducible synthetic dataset for an online gambling operator: eight
brands, eight regulated markets, a World Cup, and up to ten billion
bets. Built for ClickHouse, generated entirely in SQL, and shipped with
five things wrong with it that you have to find.

It exists to make one argument testable. If the only way to explore data
is a dashboard, you can only ever ask the questions somebody already
built a tile for. Every problem planted in this dataset is invisible to
any dashboard you would plausibly have built, and obvious within about
thirty seconds of being able to ask a question in words.

## Quick start

```bash
curl https://clickhouse.com/ | sh
./generate.sh small
```

About five seconds for ten million bets on a laptop. Then:

```bash
clickhouse local --path ./data --multiquery < sql/10_verify.sql
```

Against ClickHouse Cloud:

```bash
CLICKHOUSE_HOST=abc.eu-west-1.aws.clickhouse.cloud \
CLICKHOUSE_PASSWORD=... \
./generate.sh large
```

Full setup, including `clickhousectl` for Cloud and running a real local
server, is in [SETUP.md](SETUP.md).

## What to read next

| | |
|---|---|
| [SETUP.md](SETUP.md) | Laptop, local server, and Cloud via `clickhousectl`. MCP, remote and local. Sizing. |
| [DEMO.md](DEMO.md) | The questions to ask an agent, in order, and what each should return. |
| [dashboard/](dashboard/index.html) | A competent operator dashboard that misses the problem entirely. |
| [challenges/](challenges/README.md) | The five planted problems, with hints and answers. Start here. |
| [queries/01_operator_basics.sql](queries/01_operator_basics.sql) | The dashboard tiles. Questions somebody already built for you. |
| [queries/02_beyond_the_dashboard.sql](queries/02_beyond_the_dashboard.sql) | The questions nobody pre-built. The point of the repo. |
| [queries/03_agent_observability.sql](queries/03_agent_observability.sql) | Fan-out, queue wait, silent truncation, adoption curve. |
| [sql/10_verify.sql](sql/10_verify.sql) | Every invariant the data should satisfy. Run it after generating. |

## Live data

To keep writing new bets while you query, against a server (not
`clickhouse-local`, which locks its data directory):

```bash
clickhousectl local server start
CLICKHOUSE_HOST=localhost ./generate.sh small
CLICKHOUSE_HOST=localhost ./stream.sh small 4000
```

Then ask what happened in the last thirty seconds, twice, and get two
different answers.

## Tiers

| Tier | Bets | Players | Notes |
|---|---|---|---|
| `small` | 10M | 8,000 | Laptop. Four of the five anomalies are findable. |
| `medium` | 1B | 800,000 | All five, including the ones that need statistical power. |
| `large` | 10B | 8,000,000 | Cloud. The 240-account abuse cohort is genuinely buried. |

Player counts scale with bet counts on purpose: `n_players = n_bets /
1250`. That keeps bets per player near what an operator really sees over
a quarter (about 38 sessions of about 48 bets). Raising the player count
without raising the bet count gives sessions of one bet each, which
silently invalidates every session-level metric in the dataset.

## What's in it

| Table | Rows at `medium` | What it is |
|---|---|---|
| `bets` | 1B | Every wager: casino, live dealer, sportsbook, bingo |
| `payments` | 25M | Deposits and withdrawals, by provider and method |
| `sessions` | ~30M | One row per login, including logins with no bets |
| `rg_events` | ~3M | Responsible gaming: limits, cool-offs, exclusions, flags |
| `agent_traces` | 20M | Every tool call an agent made against this data |
| `players`, `games`, `markets`, `brands`, `fx_rates` | small | Reference data |

### The wide table

`bets` has 45 columns and carries the player, brand, game and market
attributes on every row. This is a deliberate choice for this dataset's
access pattern, not general advice to avoid joins.

Worth being clear about, because the "denormalise everything in
ClickHouse" advice you may have read is out of date. ClickHouse supports
all standard join types plus SEMI, ANTI and ASOF, across six join
[algorithms](https://clickhouse.com/docs/guides/joining-tables) with
automatic optimisation from statistics and global join reordering. TPC-H
join performance improved roughly fourfold through 2025, and kept
improving through 2026 with runtime filters, faster outer joins and
better correlated subquery handling. Joins are a legitimate modelling
tool here, and where one makes a schema simpler and the data easier to
manage, use it.

Denormalisation is the right call *here* because this dataset exists to
demonstrate one specific thing: maximum single-query performance on a
known access pattern, under heavy concurrency. That is precisely the
case the canonical guidance says denormalisation still fits.

Run section 11 of `10_verify.sql` and you get the argument in numbers.
On a 10M-row build, the denormalised attribute columns cost this much
per row, compressed:

```text
game_volatility       0.136 bytes
player_acq_channel    0.137 bytes
os                    0.112 bytes
status                0.108 bytes
provider_id           0.223 bytes
```

Against `ts` at 2.1 bytes and `settled_ts` at 3.1. The entire
denormalised player and product attribute set costs a fraction of one
timestamp column, because
[`LowCardinality`](https://clickhouse.com/docs/sql-reference/data-types/lowcardinality)
dictionary-encodes them to a byte and ZSTD takes most of that back.
Columns you don't select cost nothing to read at all.

The second reason is concurrency. A join holds memory for the life of
the query, and memory is the resource that gets tight when one question
fans out into forty simultaneous queries. That is an argument about this
workload's shape, not about join performance: forty concurrent
well-optimised joins still need more memory than forty scans.

Reference tables still exist, and
[dictionaries](https://clickhouse.com/docs/dictionary) over them are how
the generators stay honest, so RTP and margin have exactly one source of
truth. Query them directly for the catalogue itself. There is no reason
to join them onto `bets` for attributes `bets` already carries.

### Agent traces

One row per tool call, many rows per `trace_id`, because one question in
words becomes many queries against the database. At the `small` tier
that ratio comes out at a median of 14 and a 95th percentile of 43.

Three columns are there because they are the three that hurt:

- **`queue_wait_ms`** — time waiting for a slot rather than executing.
  This moves long before p99 execution time does. It goes from 11ms at
  low fan-out to 3.5 seconds average, 30 seconds worst, above 35
  queries per question.
- **`silently_truncated`** — the result was cut short and the model was
  handed a partial answer without being told. About 2.3% of spans. This
  is where confident wrong answers come from.
- **`sql_fingerprint`** — literals stripped. Group by it within a trace
  and the redundant re-asking becomes countable: about 6.7 repeated
  shapes per question.

Agent traffic also grows across the window, from a few hundred spans in
the first week to several hundred thousand in the last. Plot spans per
week and the adoption curve draws itself.

## The five things wrong with it

See [`challenges/README.md`](challenges/README.md). Short version: a
provider config push that loosened hit frequency for twelve hours, an
in-play latency collapse during the World Cup final, a 240-account bonus
abuse cohort, a payment provider outage, and 1,746 deposit limit
breaches that nothing ever flagged.

Solutions are in the generator files, which are commented, so the SQL
is the spoiler. Read `challenges/README.md` first if you want to try
them cold.

## The dashboard that misses it

`dashboard/index.html` is a single self-contained file: six tiles of GGR
by day, hold by brand, hit rate by provider, deposit approval, latency,
and top games. Every figure on it is accurate.

None of them find the 8 July problem. The provider tile is worse than
useless: it shows the culprit with the *lowest* hit rate of any provider
that day, because it averages twelve broken hours with twelve normal
ones and because that provider's baseline is genuinely the lowest in the
portfolio. The dashboard is not wrong. It simply cannot answer a
question nobody built it for.

Open it directly for baked-in figures, or point it at ClickHouse over
HTTP to query live. [DEMO.md](DEMO.md) has the running order.

## How the generation works

Everything derives from row numbers through `cityHash64`, so a given
tier always produces byte-identical data. There are no seeds to pass
around and no `rand()` drift between runs. Any single row can be
regenerated in isolation.

`sql/00_functions.sql` defines the helpers as SQL UDFs: `u()` for a
uniform draw, `wpick()` for a weighted choice, `pareto_unit()` for a
heavy tail with mean pinned at exactly 1.0. That last one is why
realised RTP converges on each game's theoretical RTP by construction
rather than by hand-tuned weight vectors, which is in turn what gives
the RTP anomaly something real to drift from.

Sessions are the unit of generation, not bets. Rows come in blocks that
get divided into sessions; a session picks the player, the day, the
hour, the device and mostly the product, and the bets inside it are
seconds apart. Drawing a timestamp per bet instead gives about 1.1 bets
per session, and every session metric built on that is meaningless.

Run the files in numeric order, or just use `generate.sh`. Order matters
in two places: the abuse cohort is inserted before sessions are derived
from bets, and responsible gaming events are derived after both payments
and sessions exist.

## Known limitations

Stated plainly, because a synthetic dataset that oversells itself is
worse than useless.

- **Session length is bounded.** Sessions run 13 to 83 bets. Real player
  bases include marathon sessions of several hundred spins; single-pass
  generation cannot easily produce that tail.
- **High-volatility RTP is noisy.** Realised RTP for high-volatility
  games lands within about 3% of theoretical at the `small` tier and
  tightens as you scale. Payouts are heavy-tailed and stakes are
  concentrated among whales, so the estimator is dominated by rare large
  wins. That is true of real slot data too, and it is why the RTP
  anomaly is modelled as a hit-rate shift.
- **`is_first_deposit` is approximate.** A true first-deposit flag needs
  a player's whole history; the generator marks roughly one deposit in
  fifty, biased toward accounts that registered inside the window.
- **Timestamps bleed past the window edges** by a few hours, because
  local-evening play in Ontario is the next day in UTC. That is correct
  behaviour, not a bug.
- **The brands, games, providers and payment providers are invented.**
  Any resemblance to a real operator is accidental. The 2026 World Cup
  calendar is real; the betting on it is not.

## Licence

MIT. The data is synthetic and contains no real people.
