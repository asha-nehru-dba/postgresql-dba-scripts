#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# pg_backup.sh - Automated PostgreSQL backups with retention
#
# Modes:
#   logical  : pg_dump (custom format) for every database + pg_dumpall globals
#   physical : pg_basebackup (tar, compressed, WAL streamed) for PITR
#
# Usage:
#   ./pg_backup.sh logical
#   ./pg_backup.sh physical
#
# Configure with environment variables or edit the defaults below.
# ---------------------------------------------------------------------------
set -euo pipefail

MODE="${1:-logical}"

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
BACKUP_ROOT="${BACKUP_ROOT:-/var/lib/pgsql/backups}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_FILE="${LOG_FILE:-/var/log/pg_backup.log}"

TS="$(date +%Y%m%d_%H%M%S)"
export PGHOST PGPORT PGUSER

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$MODE] $*" | tee -a "$LOG_FILE"; }
fail() { log "ERROR: $*"; exit 1; }

trap 'fail "Backup failed at line $LINENO"' ERR

check_connection() {
    pg_isready -q || fail "PostgreSQL is not accepting connections on $PGHOST:$PGPORT"
}

logical_backup() {
    local dir="$BACKUP_ROOT/logical/$TS"
    mkdir -p "$dir"

    log "Dumping global objects (roles, tablespaces)"
    pg_dumpall --globals-only -f "$dir/globals.sql"

    local dbs
    dbs=$(psql -At -c "SELECT datname FROM pg_database
                       WHERE datallowconn AND NOT datistemplate ORDER BY 1;")

    for db in $dbs; do
        log "Dumping database: $db"
        pg_dump -Fc -Z 6 -d "$db" -f "$dir/${db}.dump"
        # Verify the archive is readable
        pg_restore -l "$dir/${db}.dump" > /dev/null \
            || fail "Verification failed for $db"
    done

    log "Logical backup finished: $dir ($(du -sh "$dir" | cut -f1))"
}

physical_backup() {
    local dir="$BACKUP_ROOT/physical/$TS"
    mkdir -p "$dir"

    log "Starting pg_basebackup"
    pg_basebackup -D "$dir" -Ft -z -X stream -P -c fast \
        -l "base_backup_$TS" >> "$LOG_FILE" 2>&1

    log "Physical backup finished: $dir ($(du -sh "$dir" | cut -f1))"
}

cleanup_old() {
    log "Removing backups older than $RETENTION_DAYS days"
    find "$BACKUP_ROOT/$MODE" -mindepth 1 -maxdepth 1 -type d \
        -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} + >> "$LOG_FILE" 2>&1 || true
}

check_connection
case "$MODE" in
    logical)  logical_backup ;;
    physical) physical_backup ;;
    *) fail "Unknown mode '$MODE' (use logical or physical)" ;;
esac
cleanup_old
log "Done"
