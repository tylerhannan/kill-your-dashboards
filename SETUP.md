# Setup

Three ways to run this, smallest first. All of them use the same SQL;
only the target changes.

## 1. Laptop, no server at all

The fastest path. `clickhouse-local` is a single binary that reads and
writes a directory; there is nothing to start or stop.

```bash
curl https://clickhouse.com/ | sh
./generate.sh small
```

Roughly five seconds for ten million bets. Data lands in `./data`.

Query it:

```bash
clickhouse local --path ./data
```

```bash
clickhouse local --path ./data --multiquery < sql/10_verify.sql
```

Four of the five planted anomalies are findable at this tier. The fifth
needs more statistical power (see `challenges/README.md`).

## 2. Laptop, real server

Use this when you want a server an MCP client or a BI tool can actually
connect to on port 9000/8123.

```bash
clickhousectl local server start
```

That bootstraps from nothing: it installs the latest ClickHouse if you
have none, starts an instance named `default`, and keeps its data in
`.clickhouse/servers/default/data/`, which persists across restarts.

Point the generator at it:

```bash
CLICKHOUSE_HOST=localhost ./generate.sh small
```

TLS is off automatically for localhost. To use a bigger tier locally,
`medium` is fine on a workstation with enough disk. Expect roughly 25GB
for a billion bets, most of it the `bets` table and its projection.

Connect:

```bash
clickhousectl local client -q "SELECT count() FROM igaming.bets"
```

Handy for wiring up other tools: it writes the connection details out
as environment variables:

```bash
clickhousectl local server dotenv
```

Stop it when you're done:

```bash
clickhousectl local server stop default
```

## 3. ClickHouse Cloud

This is the tier where ten billion rows is reasonable and where the
concurrency story is real.

### Authenticate

OAuth login is **read-only**. Creating a service needs API key auth:

```bash
clickhousectl cloud auth login --api-key "$KEY" --api-secret "$SECRET"
clickhousectl cloud auth status
```

If you don't have an account yet, `clickhousectl cloud auth signup`.

### Create a service

Size it for the tier you intend to load. Scale vertically before you
scale horizontally: one replica with real memory, not several small ones.
That is the ClickHouse pattern generally and it is more pronounced on
Cloud, where storage is shared, so a second replica adds no I/O
parallelism to a single query and only splits your memory budget across
processes. Reach for replicas when you need concurrency or availability
that one replica cannot serve, and not before.

At the `large` tier, ten billion bets, give it real memory, because
`dict_players` holds eight million players in RAM during generation
(about 700MB) and the generator is CPU-bound on hashing:

```bash
clickhousectl cloud service create \
  --name igaming-demo \
  --provider aws \
  --region eu-west-1 \
  --num-replicas 1 \
  --min-replica-memory-gb 64 \
  --max-replica-memory-gb 356
```

That is vertical autoscaling: a fixed replica count with memory moving
between the two bounds on demand, so the floor is what you pay for at
rest and the ceiling is what a fan-out query can reach for. The maximum
is a multiple of 4, capped at 120GB on an unpaid service and 356GB on a
paid one.

For `medium`, 32–64GB is plenty. Still one replica.

To change it later without recreating the service:

```bash
clickhousectl cloud service scale <SERVICE_ID> \
  --num-replicas 1 \
  --min-replica-memory-gb 64 \
  --max-replica-memory-gb 356
```

Grab the host and password:

```bash
clickhousectl cloud service list
clickhousectl cloud service get <SERVICE_ID>
```

`cloud service reset-password <SERVICE_ID>` if you need a fresh one.

### Load it

```bash
export CLICKHOUSE_HOST=<host>.eu-west-1.aws.clickhouse.cloud
export CLICKHOUSE_PASSWORD=<password>
./generate.sh large
```

Generation runs entirely inside the service; nothing streams over your
network, because the data is computed from `numbers_mt()` server-side.
That is the main reason this dataset is SQL rather than a Python
generator: ten billion rows never crosses the wire.

Then:

```bash
clickhouse client --host "$CLICKHOUSE_HOST" --secure \
  --password "$CLICKHOUSE_PASSWORD" --multiquery < sql/10_verify.sql
```

### Stop it when you're not presenting

Cloud services idle down, but stopping is explicit and free:

```bash
clickhousectl cloud service stop <SERVICE_ID>
clickhousectl cloud service start <SERVICE_ID>
```

## Agent skills

`clickhousectl` ships the official ClickHouse agent skills, which teach a
coding agent how to use ClickHouse and this CLI properly:

```bash
clickhousectl skills --agent claude
```

Project scope is the default, so they land in the repo you run it from.
`--global` puts them in your home directory instead. This matters for
the demo: it is the difference between an agent that guesses at
ClickHouse idiom and one that knows `LowCardinality`, dictionaries and
projections are available to it.

## MCP

Two options, and which one you want depends on where the data is.

### Remote MCP, for ClickHouse Cloud

If the dataset is in Cloud, there is a hosted MCP server and nothing to
run yourself. Enable it per service first: open the service in the Cloud
console, click **Connect**, choose **MCP**, and enable it. Then point
your client at:

```
https://mcp.clickhouse.cloud/mcp
```

Authentication is OAuth 2.1, so the first connection opens a browser for
you to sign in with your Cloud credentials. There is no API key to place
in a config file, which also means no password sitting in a JSON file on
the laptop you are presenting from. Verified against the live endpoint:
it advertises PKCE (`S256`), `authorization_code` and `refresh_token`
grants, a public client (`token_endpoint_auth_method: none`), dynamic
client registration at `/register`, and the scope `mcp:access`. An
unauthenticated request returns `401` with a `WWW-Authenticate: Bearer`
header pointing at
`/.well-known/oauth-protected-resource/mcp`, which is what lets a client
discover all of the above on its own.

It exposes **17 read-only tools**, counted off a live session rather than
read from a docs page. Three are the ones this dataset cares about:
`run_select_query`, `list_databases`, `list_tables`. The rest are there
for when the agent needs to reason about the service and not just the
data in it:

| Group | Tools |
|---|---|
| Data | `run_select_query`, `list_databases`, `list_tables` |
| Postgres (beta) | `run_postgres_select_query`, `list_postgres_slow_query_patterns`, `get_postgres_slow_query_pattern_details`, `get_postgres_metrics` |
| Service and org | `get_organizations`, `get_organization_details`, `get_organization_cost`, `get_services_list`, `get_service_details` |
| ClickPipes | `get_clickpipe`, `list_clickpipes` |
| Backups | `list_service_backups`, `get_service_backup_details`, `get_service_backup_configuration` |

The server identifies itself as `ClickHouse MCP Cloud Server` 1.0.0 and
speaks MCP protocol `2025-06-18` over Streamable HTTP, answering with
`text/event-stream`.

Two things to check before you rely on this, because both fail silently:

- **Generative AI features have to be enabled on the organisation**
  before the Connect → MCP option does anything.
- **MCP then has to be enabled on each service**, via Connect → MCP in
  the console. Enabling it for the organisation is not enough, and this
  is the one that will catch you out: OAuth succeeds, `tools/list`
  returns all 17 tools, and `get_services_list` happily names the
  service. Only the tools that touch its data fail, with:

      "Forbidden. Service does not allow MCP calls"

  There is no way to check this ahead of time. `clickhousectl cloud
  service get` returns no MCP field, and neither does the organisation
  record, so nothing short of calling `list_databases` against the
  service will tell you whether it is switched on. If you see that
  message, the client config is not the problem.

Once both switches are on, this path is verified against the 10B build:
`list_databases` returns `igaming`, and `run_select_query` answers the
demo's provider question (8 July hit frequency grouped by provider, 54M
rows) in 0.29s.

One thing that differs from the local server and will bite a hand-written
skill: **the hosted tools are organisation-scoped, so they take a
`serviceId`.** `run_select_query` requires `query` and `serviceId` (and
takes an optional `timeoutSeconds`), `list_databases` requires
`serviceId`, `list_tables` requires `serviceId` and `database`, and
`get_services_list` requires an `organizationId`. An agent finds those
ids for itself via `get_organizations` then `get_services_list`, but it
does cost a round trip or two before the first real query.

If you cannot get the remote server working, the local server below runs
against a Cloud service perfectly well and is the safer choice if you are
about to demo in front of people.

### Local MCP server, for anything self-hosted

For `clickhouse-local` or the local server from option 2, run
[mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse) yourself.

The config below invokes `uv`, so you need it on your `PATH` first.
`brew install uv`, or `curl -LsSf https://astral.sh/uv/install.sh | sh`.
Without it the client reports the server failing to start and says
nothing about why. If you would rather not use `uv`, a plain
`pip install mcp-clickhouse` into a virtualenv works and you point
`command` at that environment's `mcp-clickhouse` binary instead.

Against the local server from option 2:

```json
{
  "mcpServers": {
    "clickhouse": {
      "command": "uv",
      "args": ["run", "--with", "mcp-clickhouse", "--python", "3.13",
               "mcp-clickhouse"],
      "env": {
        "CLICKHOUSE_HOST": "localhost",
        "CLICKHOUSE_PORT": "8123",
        "CLICKHOUSE_USER": "default",
        "CLICKHOUSE_PASSWORD": "",
        "CLICKHOUSE_SECURE": "false",
        "CLICKHOUSE_DATABASE": "igaming"
      }
    }
  }
}
```

You can point the same server at Cloud by setting `CLICKHOUSE_HOST` to
the service host, `CLICKHOUSE_PORT` to `8443` and `CLICKHOUSE_SECURE` to
`true`. That path is verified against the 10B build. Version 0.6.0
registers three tools, `list_databases`, `list_tables` and `run_query`,
and all three answer correctly over TLS against a Cloud service with
`CLICKHOUSE_DATABASE` set to `igaming`.

Note `run_query`, not `run_select_query`. The local and hosted servers do
not use the same tool names, which matters if you write a skill that
names a tool explicitly rather than describing what it wants.

Prefer the remote server if the data is in Cloud and you have it working,
since it needs no local process and stores no password. Prefer this one
if you need certainty, because everything it depends on is on your own
machine.

Check the [mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse)
README for the current configuration surface, which moves faster than
this file will.

### Agent observability

Whichever you use, do not build the tracing side yourself.
[Langfuse](https://langfuse.com) is the open-source platform for LLM and
agent observability, and ClickHouse
[acquired it](https://clickhouse.com/blog/clickhouse-acquires-langfuse-open-source-llm-observability)
in January 2026. Its architecture runs entirely on ClickHouse in both
the cloud and self-hosted deployments.

For fan-out on your own runs, `system.query_log` has it: every query the
MCP server issued, with rows and bytes read. See
`queries/03_query_log_fanout.sql`.

One gotcha, found the hard way. `clickhousectl local server` ships a
config with no `<query_log>` block, so the table is never created even
though the `log_queries` setting reads 1. `clickhouse-local` has no
`system.query_log` at all. Use Cloud, or add the config block that
`queries/03_query_log_fanout.sql` documents.

## Sizing reference

| Tier | Bets | On disk (all tables) | Bytes/row | Generation |
|---|---|---|---|---|
| `small` | 10M | ~400MB | 40.8 | ~5s on a laptop, 13s to Cloud |
| `medium` | 1B | ~45GB | ~48 | minutes |
| `large` | 10B | ~525GB | 55.0 | ~66 min, 1 replica at 64–356GB |

`small` and `large` are measured. `medium` is interpolated between them
and is the one number here still worth distrusting.

Do not scale the disk figure linearly from `small`: bytes per row grows
with the tier, from 40.8 to 55.0, because player and session identifiers
are what dominate `bets` once they stop being low-cardinality. `small`
has 8,000 players, `large` has 8,000,000, so `player_id` and
`session_id` compress far less well at the top tier. Extrapolating
`small` linearly gives about 400GB for `large` and the real answer is
525GB.

The `large` generation time above is the whole nine-step run against a
single replica. Almost all of it is `bets`: 3754s of 3932s, at roughly
3M rows/sec, CPU-bound on hashing. `07_sessions` aggregates all ten
billion rows into 308M sessions in 114s, which is the step people expect
to be slow and isn't.

The `bets_by_player` projection adds about half again to the `bets`
table's footprint, not double: at `large` it is 170GB of the table's
514GB, against 344GB for the base table. It is worth it for
player-centric lookups, but if you are tight on disk, drop it:

```sql
ALTER TABLE igaming.bets DROP PROJECTION bets_by_player;
```
