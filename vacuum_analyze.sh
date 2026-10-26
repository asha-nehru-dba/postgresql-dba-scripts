#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# vacuum_analyze.sh - Targeted VACUUM (ANALYZE) maintenance
#
# Instead of vacuuming everything, picks tables in each database whose
# dead-tuple ratio exceeds a threshold, then runs VACUUM (ANALYZE) on them.
# Optionally reports bloated indexes that may need REINDEX CONCURRENTLY.
#
# Usage: ./vacuum_analyze.sh            # all databases
#        ./vacuum_analyze.sh mydb       # one database
# ---------------------------------------------------------------------------
set -euo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

DEAD_PCT="${DEAD_PCT:-10}"          # vacuum tables with > 10% dead tuples
MIN_DEAD_ROWS="${MIN_DEAD_ROWS:-1000}"
LOG_FILE="${LOG_FILE:-/var/log/pg_vacuum.log}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

if [ $# -gt 0 ]; then
    dbs="$1"
else
    dbs=$(psql -At -X -c "SELECT datname FROM pg_database
                          WHERE datallowconn AND NOT datistemplate ORDER BY 1;")
fi

for db in $dbs; do
    log "== Database: $db =="

    tables=$(psql -At -X -d "$db" -c "
        SELECT format('%I.%I', schemaname, relname)
        FROM pg_stat_user_tables
        WHERE n_dead_tup > $MIN_DEAD_ROWS
          AND n_dead_tup * 100.0 / nullif(n_live_tup + n_dead_tup, 0) > $DEAD_PCT
        ORDER BY n_dead_tup DESC;")

    if [ -z "$tables" ]; then
        log "No tables above ${DEAD_PCT}% dead tuples"
    else
        for t in $tables; do
            start=$(date +%s)
            psql -X -q -d "$db" -c "VACUUM (ANALYZE, VERBOSE) $t;" >> "$LOG_FILE" 2>&1
            log "Vacuumed $t in $(( $(date +%s) - start ))s"
        done
    fi

    log "Large unused indexes (REINDEX / DROP candidates):"
    psql -At -X -d "$db" -c "
        SELECT format('  %s.%s  size=%s  scans=%s', schemaname, indexrelname,
                      pg_size_pretty(pg_relation_size(indexrelid)), idx_scan)
        FROM pg_stat_user_indexes
        WHERE idx_scan = 0 AND pg_relation_size(indexrelid) > 10 * 1024 * 1024
        ORDER BY pg_relation_size(indexrelid) DESC LIMIT 10;" | tee -a "$LOG_FILE"
done

log "Maintenance complete"
