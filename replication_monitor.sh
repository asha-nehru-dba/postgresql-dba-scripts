#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# replication_monitor.sh - Streaming replication status and lag monitor
#
# On the PRIMARY : lists connected standbys, their state and byte lag,
#                  plus replication slots and retained WAL.
# On a STANDBY   : shows receiver status and replay delay in seconds.
#
# Alerts when lag passes the thresholds below. Suitable for crontab
# (e.g. every 5 minutes); exit code 1 = warning, 2 = critical.
#
# Usage: ./replication_monitor.sh
# ---------------------------------------------------------------------------
set -uo pipefail

PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-postgres}"
export PGHOST PGPORT PGUSER

LAG_WARN_MB="${LAG_WARN_MB:-100}"
LAG_CRIT_MB="${LAG_CRIT_MB:-500}"
DELAY_WARN_SEC="${DELAY_WARN_SEC:-60}"
DELAY_CRIT_SEC="${DELAY_CRIT_SEC:-300}"
LOG_FILE="${LOG_FILE:-/var/log/pg_replication.log}"

STATUS=0
q() { psql -At -X -F '|' -c "$1"; }
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }

pg_isready -q || { log "CRITICAL: PostgreSQL not reachable"; exit 2; }

if [ "$(q "SELECT pg_is_in_recovery();")" = "f" ]; then
    log "Node role: PRIMARY"

    standbys=$(q "SELECT application_name, client_addr, state, sync_state,
                         pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)
                  FROM pg_stat_replication;")

    if [ -z "$standbys" ]; then
        log "CRITICAL: no standby connected"
        STATUS=2
    else
        while IFS='|' read -r app addr state sync lag_bytes; do
            lag_mb=$(( ${lag_bytes%.*} / 1024 / 1024 ))
            msg="Standby $app ($addr) state=$state sync=$sync lag=${lag_mb}MB"
            if [ "$state" != "streaming" ]; then
                log "WARNING: $msg"; [ "$STATUS" -lt 1 ] && STATUS=1
            elif [ "$lag_mb" -ge "$LAG_CRIT_MB" ]; then
                log "CRITICAL: $msg"; STATUS=2
            elif [ "$lag_mb" -ge "$LAG_WARN_MB" ]; then
                log "WARNING: $msg"; [ "$STATUS" -lt 1 ] && STATUS=1
            else
                log "OK: $msg"
            fi
        done <<< "$standbys"
    fi

    log "Replication slots:"
    q "SELECT slot_name, slot_type, active,
              pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
       FROM pg_replication_slots;" | while IFS='|' read -r name type active retained; do
        log "  slot=$name type=$type active=$active retained_wal=$retained"
        [ "$active" = "f" ] && log "  WARNING: inactive slot $name is retaining WAL"
    done
else
    log "Node role: STANDBY"

    receiver=$(q "SELECT status, sender_host FROM pg_stat_wal_receiver;")
    if [ -z "$receiver" ]; then
        log "CRITICAL: WAL receiver not running"
        STATUS=2
    else
        IFS='|' read -r rstatus sender <<< "$receiver"
        log "WAL receiver: status=$rstatus primary=$sender"
    fi

    delay=$(q "SELECT CASE
                 WHEN pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() THEN 0
                 ELSE coalesce(extract(epoch FROM now() - pg_last_xact_replay_timestamp()), 0)
               END::int;")
    msg="Replay delay: ${delay}s"
    if [ "$delay" -ge "$DELAY_CRIT_SEC" ]; then
        log "CRITICAL: $msg"; STATUS=2
    elif [ "$delay" -ge "$DELAY_WARN_SEC" ]; then
        log "WARNING: $msg"; [ "$STATUS" -lt 1 ] && STATUS=1
    else
        log "OK: $msg"
    fi
fi

exit "$STATUS"
