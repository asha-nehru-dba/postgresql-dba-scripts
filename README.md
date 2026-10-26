# PostgreSQL DBA Scripts

Shell scripts I use to automate routine PostgreSQL administration on RHEL / CentOS:
backups with retention, daily health checks, streaming replication monitoring and
targeted VACUUM maintenance. All scripts are scheduled with crontab.

Tested on PostgreSQL 12 and 13 (RHEL 7.x).

## Scripts

| Script | What it does |
|---|---|
| [`pg_backup.sh`](scripts/pg_backup.sh) | Logical backups (`pg_dump -Fc` per database + `pg_dumpall --globals-only`) or physical backups (`pg_basebackup` with streamed WAL for PITR). Verifies each dump and deletes backups past the retention period. |
| [`pg_health_check.sh`](scripts/pg_health_check.sh) | Daily report: availability, role (primary/standby), connection usage, database sizes, long-running and blocked queries, idle-in-transaction sessions, XID wraparound risk, dead tuples, cache hit ratio and disk usage. |
| [`replication_monitor.sh`](scripts/replication_monitor.sh) | Detects whether the node is primary or standby. On the primary it reports each standby's state and byte lag plus replication slots; on a standby it checks the WAL receiver and replay delay. Warn/critical thresholds and exit codes for alerting. |
| [`vacuum_analyze.sh`](scripts/vacuum_analyze.sh) | Runs `VACUUM (ANALYZE)` only on tables above a dead-tuple threshold and lists large unused indexes as REINDEX/DROP candidates. |
| [`cron/crontab.example`](cron/crontab.example) | Sample schedule for all of the above. |

## Setup

```bash
git clone https://github.com/<your-username>/postgresql-dba-scripts.git
cd postgresql-dba-scripts
chmod +x scripts/*.sh
```

Connection settings come from the standard libpq environment variables, so the
scripts work with a `~/.pgpass` file and no passwords in code:

```bash
export PGHOST=localhost PGPORT=5432 PGUSER=postgres
export BACKUP_ROOT=/var/lib/pgsql/backups RETENTION_DAYS=7
```

## Usage

```bash
./scripts/pg_backup.sh logical        # nightly dumps
./scripts/pg_backup.sh physical       # base backup for PITR
./scripts/pg_health_check.sh          # writes /var/log/pg_health_YYYYMMDD.log
./scripts/replication_monitor.sh      # exit 0 OK, 1 warning, 2 critical
./scripts/vacuum_analyze.sh mydb      # maintenance on one database
```

Then install the schedule as the `postgres` user:

```bash
crontab -e   # paste from cron/crontab.example and fix the path
```

## Point-in-time recovery (PITR) notes

Physical backups from `pg_backup.sh physical` plus archived WAL allow restoring to
any moment. Example `postgresql.conf` on the primary:

```conf
wal_level = replica
archive_mode = on
archive_command = 'test ! -f /var/lib/pgsql/wal_archive/%f && cp %p /var/lib/pgsql/wal_archive/%f'
```

Restore outline (PostgreSQL 12+):

1. Stop PostgreSQL and move the old data directory aside.
2. Extract `base.tar.gz` and `pg_wal.tar.gz` from the backup into the data directory.
3. In `postgresql.conf` set
   `restore_command = 'cp /var/lib/pgsql/wal_archive/%f %p'` and
   `recovery_target_time = '2026-10-20 14:30:00'`.
4. Create an empty `recovery.signal` file and start PostgreSQL.
5. Check the log, then run `SELECT pg_wal_replay_resume();` to promote.

## License

MIT
