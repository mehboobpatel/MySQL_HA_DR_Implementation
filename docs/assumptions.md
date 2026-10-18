# Assumptions and what was left out

## Assumptions

- **Two VMs, shared with other services.** Site 1 runs on `interakt-dev-rabbitmq-01` (also runs RabbitMQ). Site 2 runs on `interakt-signoz` (also runs SigNoz). Only our containers were ever stopped or killed. MySQL is sized small (`innodb_buffer_pool_size=256M`, `max_connections=300`) to coexist with them.
- **"Sites" are two VMs in the same zone** (`asia-south1-a`, same subnet of `interakt-development-vnet`), each with its own Docker network. This demonstrates the mechanics and protects against losing a VM or host. It doesn't protect against a zone or region outage. In production, Site 2 would be in another region, and the measured RPO of 0 would become a small, non-zero, alerted value.
- **Data is persisted on the VM root disk.** Every datadir is a bind mount under `/data`, outside the container, so it survives container removal and upgrades. The brief asks for data outside the VM root disk too; no extra disk was attached for this PoC. In production `/data` would be a separate persistent disk, so the database can be snapshotted, resized and reattached independently of the OS.
- **Manual failover** for both local and DR, as allowed by the brief ("local failure handled automatically" is approximated by ProxySQL rerouting automatically once a human promotes). Automatic promotion is a stretch goal; see the improvements in `failover.md`.
- **A single ProxySQL instance** is a single point of failure for the application path. Accepted for the PoC.
- **`mysql_native_password` is enabled** (deprecated and off by default in 8.4) only for the `app` and `monitor` users, for ProxySQL compatibility. `repl` and `root` use `caching_sha2_password`.
- **TLS for replication** uses MySQL's auto-generated self-signed certificates (`SOURCE_SSL=1`). Traffic is encrypted, but the server certificate isn't verified (`SOURCE_SSL_VERIFY_SERVER_CERT=0`). Production would use a private CA and `SOURCE_SSL_VERIFY_SERVER_CERT=1`.
- **Secrets** live in a `.env` file (mode 600, gitignored, identical on both VMs). Production would use Secret Manager.
- **Firewall.** Explicit rules `site2-to-site1-mysql` and `site1-to-site2-mysql` document the required paths. If the VPC also has a broad internal allow rule, that rule is wider than necessary and would be removed in production. Docker-published ports bypass `ufw`, so the GCP firewall is the effective control.
- **Docker Content Trust** is enabled in the shell environment on the VMs. Official images can't be verified that way, so `restore-verify.sh` runs the restore container with `--disable-content-trust`. Compose doesn't enforce DCT. Images are pinned instead (`mysql:8.4.11`, `proxysql/proxysql:2.7.1`).
- **Backups use logical `mysqldump`.** That's fine at this size (2.9 MB compressed). For large datasets, use Percona XtraBackup or disk snapshots. Backups stay on the VM in `/data/backups`; production would copy them to a bucket in another region.
- **Workload.** Single-row inserts into an insert-only table about every 0.1 s from a bash loop. This is enough to observe loss and downtime, not a performance test. During Test 1, two workload processes were running by accident; this only increased coverage of the lost-write check.

## Deliberately out of scope (per the brief)

Connection pooling tuning, query optimisation, sharding, multi-primary writes, CI/CD and cost modelling were not built.

## Stretch goals: status

| Stretch goal | Status |
|---|---|
| Automatic failover (Orchestrator / MHA / Router / ProxySQL) | Partial. ProxySQL reroutes writes automatically once a node is writable; promotion itself is manual. |
| TLS for replication | Done (encrypted, without certificate verification). |
| Delayed replica in Site 2 | Not done. Would be a fourth instance with `SOURCE_DELAY=3600`, giving a one-hour window to recover from `DROP TABLE` without PITR. |
| Automated backup verification | Script exists (`restore-verify.sh`); not scheduled. A daily cron of `backup.sh` + `restore-verify.sh` with an alert on mismatch would complete it. |
