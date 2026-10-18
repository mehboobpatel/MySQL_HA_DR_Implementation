# MySQL High Availability + Disaster Recovery PoC

Two-site MySQL 8.4 LTS setup on two GCP VMs:

| | Site 1 (HA) | Site 2 (DR) |
|---|---|---|
| VM | `interakt-dev-rabbitmq-01` | `interakt-signoz` |
| Internal IP | `10.0.0.61` | `10.0.0.53` |
| Docker network | `site1-net` 172.20.0.0/24 | `site2-net` 172.21.0.0/24 |
| Containers | `mysql-primary` (host port 3306), `mysql-replica` (3307), `proxysql` (6033 app, 6032 admin on 127.0.0.1 only) | `mysql-dr` (3306) |
| Replication | primary → replica: GTID, **semi-sync** (`AFTER_SYNC`), TLS | Site 1 primary → DR: GTID, **async**, TLS |

- MySQL version: **8.4.11** (`mysql:8.4.11`), ProxySQL **2.7.1**.
- Zone: `asia-south1-a`, VPC `interakt-development-vnet`.
- Design, diagram and the reasons behind each choice: [`docs/architecture.md`](docs/architecture.md).
- Test results with RPO/RTO: [`docs/failover.md`](docs/failover.md).
- Operating procedures (promote, rebuild, DR failover, failback, backup, PITR): [`docs/runbook.md`](docs/runbook.md).
- Monitoring signals and thresholds: [`docs/monitoring.md`](docs/monitoring.md).
- Assumptions and what was left out: [`docs/assumptions.md`](docs/assumptions.md).
- Raw command output backing every claim: [`docs/evidence/`](docs/evidence/).

> Container names are fixed, **roles are not**. After a failover `mysql-replica` can be the primary.
> Always check roles with `scripts/status.sh` before acting.

## Repository layout

```
config/common.cnf                 # identical my.cnf for every node (GTID, binlog, plugins)
config/site1/docker-compose.yml   # mysql-primary, mysql-replica, proxysql
config/site1/{primary,replica}.cnf# server_id / report_host only
config/site1/proxysql.cnf.tpl     # rendered with envsubst -> proxysql.cnf (gitignored)
config/site2/docker-compose.yml   # mysql-dr
config/site2/{dr,restore}.cnf
scripts/lib.sh                    # sql(), waitdb(), padmin() helpers
scripts/status.sh                 # role / replication / semi-sync / ProxySQL health summary
scripts/seed.sql                  # appdb.orders + 5000 rows
scripts/workload.sh               # continuous insert loop, logs every acknowledged id
scripts/check-acks.sh             # acknowledged ids missing on a server = lost writes
scripts/ack-gap.sh                # largest gap between acknowledged writes = write downtime
scripts/backup.sh                 # mysqldump --single-transaction --source-data=2 --set-gtid-purged=ON
scripts/restore-verify.sh         # restore into a fresh container and compare fingerprints
docs/                             # architecture, failover, runbook, monitoring, assumptions, evidence
```

## Bring it up from scratch

### 0. Prerequisites

GCP firewall rules (run from Cloud Shell):

```bash
ZONE=asia-south1-a; NET=interakt-development-vnet
gcloud compute instances add-tags interakt-dev-rabbitmq-01 --tags=mysql-site1 --zone=$ZONE
gcloud compute instances add-tags interakt-signoz          --tags=mysql-site2 --zone=$ZONE
gcloud compute firewall-rules create site2-to-site1-mysql --network=$NET --direction=INGRESS \
  --action=ALLOW --rules=tcp:3306,tcp:3307,tcp:6033 --source-ranges=10.0.0.53/32 --target-tags=mysql-site1
gcloud compute firewall-rules create site1-to-site2-mysql --network=$NET --direction=INGRESS \
  --action=ALLOW --rules=tcp:3306 --source-ranges=10.0.0.61/32 --target-tags=mysql-site2
```

On both VMs:

```bash
sudo apt update && sudo apt install -y mysql-client git gettext-base netcat-openbsd openssl
# docker.io + docker-compose-v2 only if Docker is not already installed
git clone https://github.com/mehboobpatel/MySQL_HA_DR_Implementation ~/mysql-ha-dr
```

Create `~/mysql-ha-dr/.env` from `.env.example` (generate passwords once, copy the **same** file to both VMs, `chmod 600`).
Link it into each compose folder so plain `docker compose` picks it up:

```bash
ln -s ../../.env ~/mysql-ha-dr/config/site1/.env     # VM1
ln -s ../../.env ~/mysql-ha-dr/config/site2/.env     # VM2
```

Data directories (bind mounts on the VM, outside the containers):

```bash
sudo mkdir -p /data/mysql-primary /data/mysql-replica /data/backups && sudo chown $USER /data/backups   # VM1
sudo mkdir -p /data/mysql-dr /data/backups && sudo chown $USER /data/backups                            # VM2
```

If `DOCKER_CONTENT_TRUST=1` is set in your shell, `docker run` of official images fails; `restore-verify.sh` already passes `--disable-content-trust`.

### 1. Site 1 (VM1)

```bash
cd ~/mysql-ha-dr/config/site1 && docker compose up -d mysql-primary mysql-replica
source ~/mysql-ha-dr/scripts/lib.sh; waitdb mysql-primary; waitdb mysql-replica

for c in mysql-primary mysql-replica; do
  sql $c -e "RESET BINARY LOGS AND GTIDS; SET PERSIST super_read_only = ON;"
done

sql mysql-primary <<SQL
SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF;
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPL_PASSWORD}' REQUIRE SSL;
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
CREATE USER 'monitor'@'%' IDENTIFIED WITH mysql_native_password BY '${MONITOR_PASSWORD}';
GRANT REPLICATION CLIENT ON *.* TO 'monitor'@'%';
CREATE DATABASE appdb;
CREATE USER 'app'@'%' IDENTIFIED WITH mysql_native_password BY '${APP_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'app'@'%';
SET PERSIST rpl_semi_sync_source_enabled = ON;
SET PERSIST rpl_semi_sync_source_timeout = 10000;
SET PERSIST rpl_semi_sync_source_wait_point = AFTER_SYNC;
SQL
sql mysql-primary < ~/mysql-ha-dr/scripts/seed.sql

sql mysql-replica <<SQL
SET PERSIST rpl_semi_sync_replica_enabled = ON;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql-primary', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_CONNECT_RETRY=5;
START REPLICA;
SQL

envsubst < proxysql.cnf.tpl > proxysql.cnf && docker compose up -d proxysql
```

### 2. Site 2 (VM2)

```bash
nc -zv 10.0.0.61 3306
cd ~/mysql-ha-dr/config/site2 && docker compose up -d
source ~/mysql-ha-dr/scripts/lib.sh; waitdb mysql-dr
sql mysql-dr <<SQL
RESET BINARY LOGS AND GTIDS;
SET PERSIST super_read_only = ON;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='10.0.0.61', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='${REPL_PASSWORD}',
  SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_CONNECT_RETRY=5;
START REPLICA;
SQL
```

### 3. Verify

```bash
~/mysql-ha-dr/scripts/status.sh          # on each VM
```

Healthy means: one node with `read_only=0`; every other node `super_read_only=1` with both replication threads `Yes` and lag `0`;
`Rpl_semi_sync_source_status ON` and `Rpl_semi_sync_source_clients 1` on the Site 1 primary; ProxySQL shows the Site 1 primary in hostgroup 10.

From VM2 (the "application"): `mysql -h10.0.0.61 -P6033 -uapp -p"$APP_PASSWORD" -e "SELECT @@hostname"`.

### 4. Workload

```bash
cd ~/mysql-ha-dr/scripts && rm -f ack.log fail.log      # VM2
nohup ./workload.sh 10.0.0.61 6033 >/dev/null 2>&1 &
# stop with: pkill -f workload.sh   (check with: pgrep -fa workload.sh — run only ONE instance)
```

## Current state of the environment

At the time of writing the environment is **failed over to Site 2**: `mysql-dr` is the writable primary, both Site 1 nodes are up but read-only.
Failback is documented in [`docs/runbook.md`](docs/runbook.md#5-fail-back-from-site-2-to-site-1).
