#!/usr/bin/env bash
#
# Keep writing bets to the loaded dataset, timestamped now(), until you
# stop it with Ctrl-C.
#
#   CLICKHOUSE_HOST=localhost ./stream.sh
#   CLICKHOUSE_HOST=localhost ./stream.sh medium 20000
#
# REQUIRES A SERVER. This will not run against clickhouse-local.
#
# clickhouse-local is a single embedded process that takes an exclusive
# lock on its data directory, so nothing can read while it writes --
# which makes streaming into it pointless, because the whole reason to
# stream is to query live data while it arrives. Start a server first:
#
#   clickhousectl local server start
#   CLICKHOUSE_HOST=localhost ./generate.sh small
#   CLICKHOUSE_HOST=localhost ./stream.sh small
#
# Why bother: a table being written to continuously is still instantly
# queryable. Ask "what happened in the last thirty seconds" while this is
# running and the answer moves every time. That is the part a dashboard
# refresh interval cannot give you, and it is much more convincing live
# than on a slide.

set -euo pipefail

TIER="${1:-small}"
RATE="${2:-2000}"
SQL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sql"
CH="${CH:-clickhouse}"

case "$TIER" in
  small)  N_PLAYERS=8000 ;;
  medium) N_PLAYERS=800000 ;;
  large)  N_PLAYERS=8000000 ;;
  *) echo "unknown tier '$TIER' -- expected small, medium or large" >&2; exit 2 ;;
esac

if [[ -z "${CLICKHOUSE_HOST:-}" ]]; then
  cat >&2 <<'MSG'
stream.sh needs a server, not clickhouse-local.

clickhouse-local holds an exclusive lock on its data directory, so you
cannot query the table while this writes to it -- and querying live data
is the entire point of streaming.

Start a local server and load it, then stream into it:

  clickhousectl local server start
  CLICKHOUSE_HOST=localhost ./generate.sh small
  CLICKHOUSE_HOST=localhost ./stream.sh small

Or set CLICKHOUSE_HOST and CLICKHOUSE_PASSWORD for a Cloud service.
MSG
  exit 2
fi

case "$CLICKHOUSE_HOST" in
  localhost|127.0.0.1|::1) DEFAULT_SECURE=0 ;;
  *)                       DEFAULT_SECURE=1 ;;
esac
SECURE="${CLICKHOUSE_SECURE:-$DEFAULT_SECURE}"
RUN=("$CH" client --host "$CLICKHOUSE_HOST"
     --user "${CLICKHOUSE_USER:-default}" --password "${CLICKHOUSE_PASSWORD:-}")
[[ -n "${CLICKHOUSE_PORT:-}" ]] && RUN+=(--port "$CLICKHOUSE_PORT")
[[ "$SECURE" == "1" ]] && RUN+=(--secure)
TARGET="$CLICKHOUSE_HOST"

# One batch per second. Bigger batches are far kinder to MergeTree than
# many small ones -- a part per insert means a lot of merging.
BATCH="$RATE"

printf 'streaming to %s\n' "$TARGET"
printf 'rate         ~%s bets/sec (batch of %s, once a second)\n' "$RATE" "$BATCH"
printf 'stop         Ctrl-C\n\n'

trap 'printf "\nstopped after %d batches (~%d bets)\n" "$n" "$((n * BATCH))"; exit 0' INT

n=0
while true; do
  start=$(date +%s)
  if ! err=$("${RUN[@]}" --param_batch="$BATCH" --param_n_players="$N_PLAYERS" \
             --multiquery < "$SQL_DIR/stream_bets.sql" 2>&1); then
    printf 'insert failed:\n%s\n' "$err" >&2
    exit 1
  fi
  n=$((n + 1))
  printf '\rbatches %-8d bets %-12d' "$n" "$((n * BATCH))"
  # Sleep out the remainder of the second, if any is left.
  elapsed=$(( $(date +%s) - start ))
  [[ $elapsed -lt 1 ]] && sleep 1
done
