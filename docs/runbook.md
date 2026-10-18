# Runbook

Written so that someone who did not build this can operate it. Every procedure states where to run it (VM1 = Site 1 `10.0.0.61`, VM2 = Site 2 `10.0.0.53`), what to check before, and what "done" looks like.

## 0. Conventions

```bash
source ~/mysql-ha-dr/scripts/lib.sh     # gives: sql <container> ..., waitdb <container>, padmin ... (VM1)
~/mysql-ha-dr/scripts/status.sh         # roles, GTIDs, replication, semi-sync, ProxySQL, disk
```

- **Container names never change; roles do.** Before any procedure, run `status.sh` on both VMs and write down which container is the primary (the only one with `read_only=0`).
- Host ports: `mysql-primary` → 3306, `mysql-replica` → 3307 on VM1; `mysql-dr` → 3306 on VM2. Inside `site1-net`, both Site 1 containers listen on 3306.
- **Never** make two nodes writable at the same time. Every node persists `super_read_only=ON`; writability is only ever granted with `SET GLOBAL` (not persisted), so any restart returns a node to read-only.
- Only kill/stop **our** containers (by name, or `docker compose` inside `config/site1` / `config/site2`). Both VMs run other services (RabbitMQ, SigNoz).
- Record times with `date -u +%FT%T.%3NZ` **in the same command line** as the action, e.g. `date -u +%FT%T.%3NZ; docker kill mysql-primary`.

## 1. Health check

Run `scripts/status.sh` on both VMs. Healthy steady state:

| Check | Expected |
|---|---|
| Writable nodes | exactly one, `read_only=0` |
| Every other node | `super_read_only=1`, `Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`, `Seconds_Behind_Source: 0`, no `Last_*_Error` |
| Site 1 primary | `Rpl_semi_sync_source_status ON`, `Rpl_semi_sync_source_clients 1`, `Rpl_semi_sync_source_yes_tx` increasing |
| ProxySQL | the Site 1 primary is the only server in hostgroup 10, `ONLINE` |
| GTIDs | replicas' `gtid_executed` equal to (or a moment behind) the primary's |

## 2. Promote the Site 1 replica

Use when the Site 1 primary is dead (unplanned) or for maintenance (planned). Below, `OLD` is the current primary container and `NEW` the replica being promoted. With the original roles, `OLD=mysql-primary`, `NEW=mysql-replica`, `NEW_PORT=3307`.

```bash
# VM1
OLD=mysql-primary NEW=mysql-replica NEW_PORT=3307
```

**Planned only — stop writes on the old primary first and let the replica catch up:**

```bash
sql $OLD -e "SET GLOBAL super_read_only = ON;"
OLDSET=$(sql $OLD -N -e "SELECT @@GLOBAL.gtid_executed" | tr -d '\n')
sql $NEW -e "SELECT WAIT_FOR_EXECUTED_GTID_SET('$OLDSET', 60) AS ok_if_0;"
```

**Unplanned — confirm the primary is really down** (`docker ps`, `sql $OLD -e 'SELECT 1'` fails). If it is only unreachable rather than dead, make sure it cannot accept writes (stop the container) before continuing.

**Promote (both cases):**

```bash
date -u +%FT%T.%3NZ
sql $NEW <<'SQL'
-- apply everything already received (semi-sync guarantees acknowledged writes are in the relay log)
SELECT WAIT_FOR_EXECUTED_GTID_SET(
  (SELECT RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME=''), 30) AS ok_if_0;
STOP REPLICA;
RESET REPLICA ALL;
SET PERSIST rpl_semi_sync_replica_enabled = OFF;
-- keep rpl_semi_sync_source_enabled OFF until a replica is attached (section 3),
-- otherwise every commit waits 10 s for an ACK no one can send
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
SQL
date -u +%FT%T.%3NZ
```

`ok_if_0` must be `0`. If it is `1` (timeout), the replica could not apply its relay log — investigate (`SHOW REPLICA STATUS\G`, `Last_SQL_Error`) before opening writes.

**ProxySQL follows automatically** — no application change:

```bash
padmin -e "SELECT hostgroup_id,hostname,status FROM runtime_mysql_servers ORDER BY hostgroup_id;"
# expected: $NEW in hostgroup 10 ONLINE; $OLD SHUNNED (dead) or in 20 (planned)
```

**Re-point DR to the new primary** (VM2):

```bash
sql mysql-dr -e "STOP REPLICA; CHANGE REPLICATION SOURCE TO SOURCE_HOST='10.0.0.61', SOURCE_PORT=3307, SOURCE_AUTO_POSITION=1; START REPLICA;"
sql mysql-dr -e "SHOW REPLICA STATUS\G" | grep -E 'Source_Port|Running:|Behind|Last_.*Error:'
```

(`SOURCE_PORT` = the new primary's host port: 3307 for `mysql-replica`, 3306 for `mysql-primary`.)

Then rebuild the old primary as a replica (section 3). Until then Site 1 runs **without** a semi-sync replica: acknowledged writes exist on one node only.

## 3. Rebuild a broken or former-primary node as a replica

`TARGET` = node to rebuild, `SOURCE` = current Site 1 primary (container name, as seen inside `site1-net`).

```bash
# VM1
TARGET=mysql-primary SOURCE=mysql-replica
docker start $TARGET 2>/dev/null; waitdb $TARGET       # boots super_read_only=ON
SRCSET=$(sql $SOURCE -N -e "SELECT @@GLOBAL.gtid_executed" | tr -d '\n')
sql $TARGET -e "SELECT GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$SRCSET') AS errant;"
```

An **errant** transaction exists only on `TARGET`. With `AFTER_SYNC` this can happen: a transaction written to the old primary's binlog but not yet acknowledged when it crashed is committed during its crash recovery. It was never acknowledged to a client, but replicating on top of it would diverge the data.

### 3a. `errant` is empty → attach

```bash
sql $TARGET <<SQL
SET PERSIST rpl_semi_sync_source_enabled = OFF;
SET PERSIST rpl_semi_sync_replica_enabled = ON;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='$SOURCE', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PASSWORD}', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_CONNECT_RETRY=5;
START REPLICA;
SQL
sql $SOURCE -e "SET PERSIST rpl_semi_sync_source_enabled = ON; SET PERSIST rpl_semi_sync_source_timeout = 10000;"
sql $SOURCE -e "SHOW GLOBAL STATUS WHERE Variable_name IN ('Rpl_semi_sync_source_status','Rpl_semi_sync_source_clients');"
```

Done when `TARGET` shows both threads `Yes`, lag 0, and `SOURCE` shows `Rpl_semi_sync_source_status ON`, `clients 1`.

### 3b. `errant` is not empty, the node is far behind, or its data is damaged → clone

The recipient must be writable for the duration of the clone (otherwise `ERROR 1290 ... super-read-only`), and its replication config is re-created afterwards.

```bash
sql $TARGET <<SQL
STOP REPLICA; RESET REPLICA ALL;
SET GLOBAL super_read_only = OFF;
SET GLOBAL clone_valid_donor_list = '$SOURCE:3306';
CLONE INSTANCE FROM 'root'@'$SOURCE':3306 IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
SQL
waitdb $TARGET        # the server restarts itself after the clone; it boots super_read_only=ON again
```

Then run 3a. ProxySQL places the rebuilt node in hostgroup 20 automatically because it is read-only.

To rebuild `mysql-dr` from Site 1, run the same on VM2 with `TARGET=mysql-dr`, donor `'root'@'10.0.0.61':<primary host port>`, and `clone_valid_donor_list='10.0.0.61:<port>'`; then re-create DR's async replication (section 4 of the README, without semi-sync).

## 4. Fail over to DR (Site 1 lost)

Who decides: the on-call engineer, when Site 1 is unreachable and not expected back within the agreed RTO. This is a manual decision on purpose — automatic cross-site promotion risks split-brain on a network partition.

**1. Fence Site 1** so it cannot take writes if it is only partitioned, not dead: stop its MySQL containers if VM1 is reachable (`cd ~/mysql-ha-dr/config/site1 && docker compose stop`), or block it at the network (GCP firewall deny rule / stop the VM if nothing else on it matters).

**2. Promote `mysql-dr`** (VM2):

```bash
source ~/mysql-ha-dr/scripts/lib.sh
date -u +%FT%T.%3NZ
sql mysql-dr <<'SQL'
SELECT WAIT_FOR_EXECUTED_GTID_SET(
  (SELECT RECEIVED_TRANSACTION_SET FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME=''), 30) AS ok_if_0;
STOP REPLICA;
RESET REPLICA ALL;
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
SQL
date -u +%FT%T.%3NZ
```

**3. Re-point the application** to `10.0.0.53:3306` (from VM2 itself: `127.0.0.1:3306`). Do this **before** any measurement or investigation — it is the RTO.

**4. Record RPO** afterwards: `sql mysql-dr -e "SELECT MAX(id), MAX(created_at) FROM appdb.orders"` compared with the application's last confirmed write, and the Site 1 primary's `gtid_executed` once it is reachable again (`GTID_SUBTRACT(site1_set, dr_set)` = transactions lost).

**5. Keep backups running** against `mysql-dr` (section 6) — it is now the only copy taking writes.

## 5. Fail back from Site 2 to Site 1

Do this in a maintenance window once Site 1 is healthy again. Below, `S1LEAD` is the Site 1 node that will become primary (the one that was primary when Site 1 was lost — at the time of writing `mysql-replica`, host port 3307) and `S1OTHER` the other Site 1 node.

```bash
# VM1
S1LEAD=mysql-replica S1LEAD_PORT=3307 S1OTHER=mysql-primary
cd ~/mysql-ha-dr/config/site1 && docker compose up -d && waitdb $S1LEAD && waitdb $S1OTHER
source ~/mysql-ha-dr/scripts/lib.sh
```

**1. Check for errant transactions** on both Site 1 nodes against DR (anything Site 1 committed that never reached DR):

```bash
DRSET=$(mysql -h10.0.0.53 -P3306 -uroot -p"$MYSQL_ROOT_PASSWORD" -N -e "SELECT @@GLOBAL.gtid_executed" 2>/dev/null | tr -d '\n')
for c in $S1LEAD $S1OTHER; do sql $c -N -e "SELECT '$c', GTID_SUBTRACT(@@GLOBAL.gtid_executed, '$DRSET');"; done
```

Empty → continue. Not empty → clone that node from DR (section 3b with donor `10.0.0.53:3306`) before continuing; the extra transactions on Site 1 were never acknowledged after DR promotion and must be discarded or reconciled manually.

**2. Make `S1LEAD` an async replica of DR** (semi-sync off across sites):

```bash
sql $S1LEAD <<SQL
STOP REPLICA; RESET REPLICA ALL;
SET PERSIST rpl_semi_sync_replica_enabled = OFF;
SET PERSIST rpl_semi_sync_source_enabled = OFF;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='10.0.0.53', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PASSWORD}', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_CONNECT_RETRY=5;
START REPLICA;
SQL
```

`S1OTHER` should still be replicating from `S1LEAD` (check with `status.sh`; if not, run section 3a with `TARGET=$S1OTHER SOURCE=$S1LEAD`). Site 1 is now a chain: DR → S1LEAD → S1OTHER. Wait until both show lag 0.

**3. Switch over** (short write outage):

```bash
# VM2 — stop writes on DR
sql mysql-dr -e "SET GLOBAL super_read_only = ON;"
DRSET=$(sql mysql-dr -N -e "SELECT @@GLOBAL.gtid_executed" | tr -d '\n'); echo "$DRSET"
```

```bash
# VM1 — wait for Site 1 to have everything, then promote S1LEAD
sql $S1LEAD -e "SELECT WAIT_FOR_EXECUTED_GTID_SET('<paste DRSET>', 60) AS ok_if_0;"
sql $S1LEAD <<'SQL'
STOP REPLICA; RESET REPLICA ALL;
SET PERSIST rpl_semi_sync_source_enabled = ON;
SET PERSIST rpl_semi_sync_source_timeout = 10000;
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;
SQL
sql $S1OTHER -e "SET PERSIST rpl_semi_sync_replica_enabled = ON; STOP REPLICA IO_THREAD; START REPLICA IO_THREAD;"
padmin -e "SELECT hostgroup_id,hostname,status FROM runtime_mysql_servers ORDER BY hostgroup_id;"   # S1LEAD in HG10
```

**4. Application back to** `10.0.0.61:6033` (ProxySQL).

**5. DR back to being a replica of Site 1** (VM2):

```bash
sql mysql-dr <<SQL
CHANGE REPLICATION SOURCE TO SOURCE_HOST='10.0.0.61', SOURCE_PORT=${S1LEAD_PORT:-3307},
  SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PASSWORD}', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_CONNECT_RETRY=5;
START REPLICA;
SQL
```

**6. Verify** with `status.sh` on both VMs (section 1 table). Semi-sync clients on the Site 1 primary must be `1`.

## 6. Backup

Run against the **current primary**, or preferably a caught-up replica, on the VM where it lives:

```bash
~/mysql-ha-dr/scripts/backup.sh <container>      # writes /data/backups/appdb-<timestamp>.sql.gz
```

`mysqldump --single-transaction --source-data=2 --set-gtid-purged=ON --routines --triggers --events --databases appdb`:
consistent InnoDB snapshot without blocking writes (a brief global lock is taken only to read the binlog position), and the dump records both the binlog coordinates and the GTID set it contains — the starting point for point-in-time recovery. The warning about "a partial dump from a server that has GTIDs" is expected for a single-database dump.

Copy backups off the VM (e.g. `gsutil cp` to a bucket in another region); `/data/backups` on the same VM does not survive losing the VM.

## 7. Restore and verify

```bash
~/mysql-ha-dr/scripts/restore-verify.sh /data/backups/appdb-<timestamp>.sql.gz <source-container>
docker rm -f mysql-restore
```

The script starts a fresh `mysql-restore` container, resets its GTID state (required for `SET @@GLOBAL.GTID_PURGED` in the dump), loads the dump, then compares `COUNT(*)` and a `SUM(CRC32(...))` fingerprint of all rows with `id <= MAX(id in the backup)` against the source. The table is insert-only, so rows up to the backup's highest id must be identical even while writes continue. The two lines must match. Last verified result: `docs/evidence/task5-restore.txt` (225,380 rows, identical fingerprint).

## 8. Point-in-time recovery

**What must be in place**

- A full backup that records its position (`--source-data=2` and `GTID_PURGED`, as above).
- An unbroken chain of binary logs from that backup to the target time: `binlog_expire_logs_seconds` (7 days here) longer than the backup interval.
- Those binlogs stored **off the database host**, e.g. continuously streamed with `mysqlbinlog --read-from-remote-server --raw --stop-never` to another site or a bucket. Otherwise losing the host loses the binlogs too.
- `sync_binlog=1`, `binlog_format=ROW` (default), GTIDs on — all set here.
- Knowing the server time zone: containers run in UTC, so target times are UTC.

**Procedure — e.g. undo an accidental `DROP TABLE appdb.orders` at about 14:32 UTC**

1. Note the time and pause the application if further writes would make reconciliation harder. Replicas and DR have already applied the `DROP` too — replication protects against hardware loss, not logical errors (a delayed replica would).
2. Find the exact bad event in the binlogs of the current primary:
   ```bash
   docker exec <primary> ls /var/lib/mysql/ | grep binlog
   docker exec -e MYSQL_PWD=$MYSQL_ROOT_PASSWORD <primary> mysqlbinlog --base64-output=DECODE-ROWS -v \
     /var/lib/mysql/binlog.0000NN | grep -n -B12 'DROP TABLE'
   ```
   Note its GTID (`SET @@SESSION.GTID_NEXT= 'uuid:N'`) and timestamp.
3. Restore the newest full backup taken **before** that time into a fresh instance (`restore-verify.sh <file>`; ignore the comparison lines).
4. Copy the binlogs from the backup's position onward into the restore container and replay them up to — but not including — the bad event:
   ```bash
   docker cp <primary>:/var/lib/mysql/binlog.0000NN /tmp/ && docker cp /tmp/binlog.0000NN mysql-restore:/tmp/
   docker exec -e MYSQL_PWD=$MYSQL_ROOT_PASSWORD mysql-restore sh -c \
     "mysqlbinlog --exclude-gtids='<uuid:N>' /tmp/binlog.0000NN | mysql -uroot"
   # or stop at a time:  mysqlbinlog --stop-datetime='2026-10-17 14:31:59' ...
   ```
   Transactions already contained in the backup are skipped automatically because their GTIDs are in the restored `gtid_purged`.
5. Verify the data on `mysql-restore`, then either copy the recovered table back to the primary (`mysqldump appdb orders` from the restore instance) or promote the restored instance and rebuild the others from it (section 3b).
