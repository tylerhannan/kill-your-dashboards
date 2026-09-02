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
concurrency story is real, because you have replicas to contend over.

### Authenticate

OAuth login is **read-only**. Creating a service needs API key auth:

```bash
clickhousectl cloud auth login --api-key "$KEY" --api-secret "$SECRET"
clickhousectl cloud auth status
```

If you don't have an account yet, `clickhousectl cloud auth signup`.

### Create a service

Size it for the tier you intend to load. At the `large` tier, ten
billion bets, give it real memory, because `dict_players` holds eight million
players in RAM during generation (about 700MB) and the generator is
CPU-bound on hashing:

```bash
clickhousectl cloud service create \
  --name igaming-demo \
  --provider aws \
  --region eu-west-1 \
  --num-replicas 3 \
  --min-replica-memory-gb 64 \
  --max-replica-memory-gb 128
```

For `medium`, 32–64GB and a single replica is plenty.

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

Authentication is OAuth 2.0, so the first connection opens a browser for
you to sign in with your Cloud credentials. There is no API key to place
in a config file, which also means no password sitting in a JSON file on
the laptop you are presenting from.

It exposes 13 read-only tools. Three are the ones this dataset cares
about — `run_select_query`, `list_databases`, `list_tables` — and the
rest cover service, backup, ClickPipes and billing metadata, which is
useful when the agent needs to reason about the service and not just the
data in it.

### Local MCP server, for anything self-hosted

For `clickhouse-local` or the local server from option 2, run
[mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse) yourself.

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
`true`, but prefer the remote MCP server above if the data is in Cloud:
it needs no local process and no stored password.

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

For fan-out on your own runs, `system.query_log` already has it: every
query the MCP server issued, with rows and bytes read. See
`queries/03_query_log_fanout.sql`.

## Sizing reference

Measured on the `small` tier and extrapolated; your compression will
vary a little with the data you generate.

| Tier | Bets | On disk (all tables) | Generation |
|---|---|---|---|
| `small` | 10M | ~350MB | ~5s on a laptop |
| `medium` | 1B | ~25GB | minutes |
| `large` | 10B | ~250GB | tens of minutes on a sized service |

The `bets_by_player` projection roughly doubles the `bets` table's
footprint. It is worth it for player-centric lookups, but if you are
tight on disk, drop it:

```sql
ALTER TABLE igaming.bets DROP PROJECTION bets_by_player;
```
