# Monitoring (Task 6)

Signals to watch, how each is read, the thresholds to alert on, and why. Values are per node unless stated. Every query here works with the `monitor` user (`REPLICATION CLIENT`), except where noted.

| Signal | How it is measured | Warn | Critical | Rationale |
|---|---|---|---|---|
| **Primary availability** | Synthetic `SELECT 1` and a heartbeat `INSERT` through ProxySQL `10.0.0.61:6033` every 10 s; ProxySQL `runtime_mysql_servers` has an `ONLINE` server in hostgroup 10 | 1 failed probe | 3 consecutive failures (~30 s), or HG10 empty | This is what the application experiences, and it's the page that starts a failover. |
| **Replication broken / stopped** | `SHOW REPLICA STATUS`: `Replica_IO_Running`, `Replica_SQL_Running` ≠ `Yes`, or `Last_IO_Errno` / `Last_SQL_Errno` ≠ 0 (`performance_schema.replication_connection_status` / `replication_applier_status_by_worker`) | — | Immediately, on any node that should be a replica | A stopped replica silently stops protecting you; promoting it later would lose data. |
| **Replication lag, Site 1 replica** | `Seconds_Behind_Source` (better: pt-heartbeat, which also works when the IO thread is stuck) | > 5 s for 1 min | > 30 s for 2 min | A lagging HA replica means a slow promotion, because it must apply its backlog before taking writes. |
| **Replication lag, DR** | Same, on `mysql-dr` | > 60 s for 5 min | > 300 s for 5 min | DR lag *is* the RPO of a site loss; alert before it exceeds the agreed RPO. |
| **Semi-sync degraded** | On the Site 1 primary: `Rpl_semi_sync_source_status`, `Rpl_semi_sync_source_clients`, rate of `Rpl_semi_sync_source_no_tx` | `no_tx` increasing | `status = OFF` or `clients = 0` for > 1 min | The primary has fallen back to async, so "acknowledged = on two nodes" no longer holds. Nothing else would tell you. |
| **Connection count** | `Threads_connected / max_connections` (300 here); `Aborted_connects` rate; ProxySQL `stats_mysql_connection_pool` `ConnERR` | > 75% | > 90%, or a sustained `Aborted_connects` spike | Connection exhaustion looks exactly like an outage to the application. |
| **Disk usage** | `/data` filesystem used % (node_exporter or `df`); binlog volume (`SHOW BINARY LOGS`) | > 80% | > 90%, or forecast full within 24 h | A full disk stops writes and binlogs, which breaks replication and PITR at the same time. |
| **Split-brain** | Count of nodes with `@@read_only = 0` across all three | — | > 1 | Two writers diverge the data. This is the worst failure mode and must never be silent. |
| **Errant transactions** | `GTID_SUBTRACT(replica.gtid_executed, primary.gtid_executed)` non-empty | — | Non-empty | A replica with its own writes can't be promoted safely, and will break when it becomes a source. |
| **Backup freshness and restore test** | Age of the newest file in the backup location; result of the last `restore-verify.sh` | > 26 h | > 50 h, or last restore test failed | A backup that's stale or never restored isn't a backup. |

## Implementation notes

- **Exporters:** `prom/mysqld-exporter` per MySQL container (using the `monitor` user), node_exporter for disk, and ProxySQL's built-in Prometheus endpoint (`admin-restapi_enabled`).
- **Using SigNoz:** SigNoz already runs on VM2. Its OpenTelemetry collector `mysql` receiver can scrape all three instances, and the alerts above can be defined there. This is the cheapest path to the "working dashboard" bonus.
- **Lag measurement:** `Seconds_Behind_Source` reads 0 when the IO thread is disconnected, and is relative to the last received event. pt-heartbeat (a row updated every second on the primary) gives true lag including network delay.
- **Quick manual check:** `scripts/status.sh` prints most of these signals on demand.
