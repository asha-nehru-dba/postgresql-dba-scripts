#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pg_health_check.sh - Daily PostgreSQL health report
#
# Checks: availability, version/uptime, connections vs max_connections,
# database sizes, long-running queries, blocked sessions, idle-in-transaction
# sessions, transaction ID wraparound risk, dead tuples, cache hit ratio,
# disk usage of the data directory.
#
# Usage: ./pg_health_check.sh [report_file]
# Exit code is non-zero if any check reaches CRITICAL.
# ---------------------------------------------------------------------------
set -uo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
PGDATABASE="${PGDATABASE:-postgres}"
export PGHOST PGPORT PGUSER PGDATABASE

CONN_WARN_PCT="${CONN_WARN_PCT:-80}"
LONG_QUERY_MIN="${LONG_QUERY_MIN:-5}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"
REPORT="${1:-/var/log/pg_health_$(date +%Y%m%d).log}"

STATUS=0
q() { psql -At -X -c "$1"; }
section() { printf '\n==== %s ====\n' "$1"; }
warn() { echo "WARNING: $*"; [ "$STATUS" -lt 1 ] && STATUS=1; }
crit() { echo "CRITICAL: $*"; STATUS=2; }

{
echo "PostgreSQL Health Check - $(hostname) - $(date)"

section "Availability"
if pg_isready -q; then
    echo "OK: server is accepting connections"
else
    crit "server is not accepting connections"
    exit 2
fi

section "Version and uptime"
q "SELECT version();"
q "SELECT 'Uptime: ' || date_trunc('second', now() - pg_postmaster_start_time());"
q "SELECT 'Role: ' || CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;"

section "Connections"
read -r used max <<< "$(q "SELECT count(*), current_setting('max_connections')
                           FROM pg_stat_activity;" | tr '|' ' ')"
pct=$(( used * 100 / max ))
echo "Connections: $used / $max ($pct%)"
[ "$pct" -ge "$CONN_WARN_PCT" ] && warn "connection usage above ${CONN_WARN_PCT}%"
q "SELECT state, count(*) FROM pg_stat_activity
   WHERE state IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;"

section "Database sizes"
q "SELECT datname || ': ' || pg_size_pretty(pg_database_size(datname))
   FROM pg_database WHERE NOT datistemplate
   ORDER BY pg_database_size(datname) DESC;"

section "Long-running queries (> ${LONG_QUERY_MIN} min)"
long=$(q "SELECT pid || ' | ' || usename || ' | ' || datname || ' | '
          || date_trunc('second', now() - query_start) || ' | ' || left(query, 80)
          FROM pg_stat_activity
          WHERE state = 'active' AND pid <> pg_backend_pid()
            AND now() - query_start > interval '${LONG_QUERY_MIN} minutes';")
if [ -n "$long" ]; then warn "long-running queries found"; echo "$long"; else echo "OK: none"; fi

section "Blocked sessions"
blocked=$(q "SELECT pid || ' blocked by ' || array_to_string(pg_blocking_pids(pid), ',')
             || ' | ' || left(query, 80)
             FROM pg_stat_activity WHERE cardinality(pg_blocking_pids(pid)) > 0;")
if [ -n "$blocked" ]; then warn "blocked sessions found"; echo "$blocked"; else echo "OK: none"; fi

section "Idle in transaction (> 10 min)"
idle=$(q "SELECT pid || ' | ' || usename || ' | ' || date_trunc('second', now() - state_change)
          FROM pg_stat_activity
          WHERE state = 'idle in transaction'
            AND now() - state_change > interval '10 minutes';")
if [ -n "$idle" ]; then warn "idle-in-transaction sessions found"; echo "$idle"; else echo "OK: none"; fi

section "Transaction ID wraparound"
q "SELECT datname || ': ' || age(datfrozenxid) || ' ('
   || round(age(datfrozenxid) * 100.0 / 2000000000, 1) || '% of limit)'
   FROM pg_database ORDER BY age(datfrozenxid) DESC;"
max_age=$(q "SELECT max(age(datfrozenxid)) FROM pg_database;")
[ "$max_age" -gt 1500000000 ] && crit "XID age above 1.5 billion - run VACUUM FREEZE"
[ "$max_age" -gt 1000000000 ] && [ "$max_age" -le 1500000000 ] && warn "XID age above 1 billion"

section "Top 10 tables by dead tuples (current DB)"
q "SELECT schemaname || '.' || relname || ': ' || n_dead_tup || ' dead / '
   || n_live_tup || ' live, last autovacuum: ' || coalesce(last_autovacuum::text, 'never')
   FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;"

section "Cache hit ratio"
ratio=$(q "SELECT round(sum(blks_hit) * 100.0 / nullif(sum(blks_hit) + sum(blks_read), 0), 2)
           FROM pg_stat_database;")
echo "Cache hit ratio: ${ratio}%"
awk "BEGIN {exit !($ratio < 95)}" && warn "cache hit ratio below 95% - review shared_buffers"

section "Data directory disk usage"
datadir=$(q "SHOW data_directory;")
if [ -d "$datadir" ]; then
    use=$(df -P "$datadir" | awk 'NR==2 {gsub("%","",$5); print $5}')
    df -h "$datadir"
    [ "$use" -ge "$DISK_WARN_PCT" ] && warn "disk usage at ${use}%"
else
    echo "Data directory not accessible from this host (remote check)"
fi

section "Summary"
case "$STATUS" in
    0) echo "ALL CHECKS PASSED" ;;
    1) echo "COMPLETED WITH WARNINGS" ;;
    2) echo "CRITICAL ISSUES FOUND" ;;
esac
exit "$STATUS"
} 2>&1 | tee "$REPORT"

exit "${PIPESTATUS[0]}"
