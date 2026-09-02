#!/usr/bin/env bash
#
# Generate the iGaming dataset.
#
#   ./generate.sh small          ~10M bets     laptop, about a minute
#   ./generate.sh medium         ~1B bets      workstation or Cloud
#   ./generate.sh large          ~10B bets     ClickHouse Cloud
#
# Target selection:
#
#   default                      clickhouse-local, data in ./data
#   CLICKHOUSE_HOST=... 	   remote server or ClickHouse Cloud
#
# Examples:
#
#   ./generate.sh small
#
#   CLICKHOUSE_HOST=abc123.eu-west-1.aws.clickhouse.cloud \
#   CLICKHOUSE_PASSWORD=... \
#   ./generate.sh large
#
# Everything is derived from row numbers via cityHash64, so a given tier
# always produces byte-identical data. Re-running is safe: each step
# truncates what it owns before inserting.

set -euo pipefail

TIER="${1:-small}"
SQL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sql"
# Find the binary. `curl https://clickhouse.com/ | sh` drops it in the
# working directory, which is what the README tells you to do, so check
# there before PATH. Override with CH=/path/to/clickhouse.
if [[ -n "${CH:-}" ]]; then
  :
elif [[ -x ./clickhouse ]]; then
  CH=./clickhouse
elif command -v clickhouse >/dev/null 2>&1; then
  CH=clickhouse
else
  cat >&2 <<'EOF'
No clickhouse binary found.

  curl https://clickhouse.com/ | sh     # drops ./clickhouse here

Or point at one you already have:

  CH=/usr/local/bin/clickhouse ./generate.sh small
EOF
  exit 127
fi

case "$TIER" in
  small)
    N_BETS=10000000;    N_PLAYERS=8000;      N_PAYMENTS=250000
    N_EMPTY_SESSIONS=100000 ;;
  medium)
    N_BETS=1000000000;  N_PLAYERS=800000;    N_PAYMENTS=25000000
    N_EMPTY_SESSIONS=10000000 ;;
  large)
    N_BETS=10000000000; N_PLAYERS=8000000;   N_PAYMENTS=250000000
    N_EMPTY_SESSIONS=100000000 ;;
  *)
    echo "unknown tier '$TIER' -- expected small, medium or large" >&2
    exit 2 ;;
esac

# The ratios above are not arbitrary. n_players = n_bets / 1250 keeps
# bets-per-player near what an operator actually sees over a quarter
# (~38 sessions of ~48 bets). Raising the player count without raising
# the bet count produces sessions of one bet each, which quietly breaks
# every session-level metric in the dataset.

# Three targets:
#
#   no CLICKHOUSE_HOST          embedded clickhouse-local, data in ./data
#   CLICKHOUSE_HOST=localhost   a local server (clickhousectl local server start)
#   CLICKHOUSE_HOST=<cloud>     ClickHouse Cloud, TLS on
#
# TLS defaults to on for anything that is not localhost. Override with
# CLICKHOUSE_SECURE=0 or 1.
if [[ -n "${CLICKHOUSE_HOST:-}" ]]; then
  case "$CLICKHOUSE_HOST" in
    localhost|127.0.0.1|::1) DEFAULT_SECURE=0 ;;
    *)                       DEFAULT_SECURE=1 ;;
  esac
  SECURE="${CLICKHOUSE_SECURE:-$DEFAULT_SECURE}"

  RUN=("$CH" client
       --host "$CLICKHOUSE_HOST"
       --user "${CLICKHOUSE_USER:-default}"
       --password "${CLICKHOUSE_PASSWORD:-}")
  [[ -n "${CLICKHOUSE_PORT:-}" ]] && RUN+=(--port "$CLICKHOUSE_PORT")

  # Not `TARGET="$HOST$([[ $SECURE == 1 ]] && echo ' (TLS)')"`. Under
  # `set -e` the assignment inherits the exit status of the command
  # substitution, so when the test fails the whole script exits -- with
  # no output at all, which is a miserable thing to debug.
  if [[ "$SECURE" == "1" ]]; then
    RUN+=(--secure)
    TARGET="$CLICKHOUSE_HOST (TLS)"
  else
    TARGET="$CLICKHOUSE_HOST"
  fi
else
  mkdir -p ./data
  RUN=("$CH" local --path ./data)
  TARGET="clickhouse-local (./data)"
fi

PARAMS=(
  --param_n_bets="$N_BETS"
  --param_n_players="$N_PLAYERS"
  --param_n_payments="$N_PAYMENTS"
  --param_n_empty_sessions="$N_EMPTY_SESSIONS"
)

printf 'tier      %s\n' "$TIER"
printf 'target    %s\n' "$TARGET"
printf 'bets      %s\n' "$(printf "%'d" "$N_BETS")"
printf 'players   %s\n\n' "$(printf "%'d" "$N_PLAYERS")"

# Order matters twice over. The bonus abuse cohort is inserted before
# sessions are derived, or its bets carry session_ids that no session
# row matches. Responsible gaming events are derived from payments and
# sessions, so they come after both.
STEPS=(
  00_functions:"deterministic helpers"
  01_tables:"tables, projection, skip index"
  02_reference:"brands, games, markets, fx, players"
  03_dictionaries:"dictionaries"
  04_bets:"bets"
  05_payments:"payments"
  06_anomalies:"bonus abuse cohort"
  07_sessions:"sessions"
  08_rg_events:"responsible gaming"
)

TOTAL_START=$SECONDS
for step in "${STEPS[@]}"; do
  file="${step%%:*}"
  label="${step#*:}"
  printf '%-16s %-38s ' "$file" "$label"
  start=$SECONDS
  if ! err=$("${RUN[@]}" "${PARAMS[@]}" --multiquery < "$SQL_DIR/$file.sql" 2>&1); then
    printf 'FAILED\n\n%s\n' "$err" >&2
    exit 1
  fi
  # ClickHouse can report an error without a non-zero exit in some
  # multiquery paths, so check the output too.
  if grep -qiE '^Code: [0-9]+\. DB::Exception' <<<"$err"; then
    printf 'FAILED\n\n%s\n' "$err" >&2
    exit 1
  fi
  printf '%4ds\n' "$((SECONDS - start))"

  # Reference data changed, so the dictionaries that read it must be
  # rebuilt before the generators that depend on them run.
  if [[ "$file" == "03_dictionaries" ]]; then
    "${RUN[@]}" -q "SYSTEM RELOAD DICTIONARIES" >/dev/null 2>&1 || true
  fi
done

printf '\ndone in %ds\n\n' "$((SECONDS - TOTAL_START))"

# Echo back the exact invocation for the target that was actually used,
# TLS flag included or omitted to match.
if [[ -n "${CLICKHOUSE_HOST:-}" ]]; then
  VERIFY="$CH client --host $CLICKHOUSE_HOST"
  [[ "$SECURE" == "1" ]] && VERIFY="$VERIFY --secure"
else
  VERIFY="$CH local --path ./data"
fi
printf 'verify with:\n  %s --multiquery < %s\n' "$VERIFY" "$SQL_DIR/10_verify.sql"
