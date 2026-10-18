# Evidence index

Raw command output (`*.txt`) and terminal screenshots (`screenshots/`) behind every result in `docs/failover.md`.

| Task | Files |
|---|---|
| Firewall / network | `screenshots/01-firewall-rules.png`, `screenshots/07-task2-site2-to-site1-connectivity.png` |
| Task 1: HA in Site 1 | `task1-replica-status.txt`, `task1-primary-status.txt`, `task1-semisync.txt`, `task1-readonly.txt`, `task1-replica-rejects-write.txt`, `screenshots/02`–`06` |
| Task 2: DR replica | `screenshots/08-task2-dr-replication-status.png` |
| ProxySQL | `proxysql-before.txt`, `proxysql-after-local-failover.txt`, `screenshots/09-proxysql-runtime.png` |
| Task 3: data | `screenshots/03-seed-5000-rows.png`, `screenshots/10-test1-workload-start.png` |
| Task 4, Test 1: local failover | `test1-acks.txt`, `test1-downtime.txt`, `test1-old-primary-rejoined.txt`, `screenshots/11`–`14` |
| Task 4, Test 2: DR failover | `test2-rpo.txt`, `test2-first-write-on-dr.txt`, `test2-site1-returned-readonly.txt`, `screenshots/15`–`18` |
| Task 5: backup and restore | `task5-restore.txt` (backup `appdb-2026-10-18-142901.sql.gz`, 2.9 MB, from `mysql-dr`); `screenshots/19-task5-first-attempt-vm1.png` shows the first attempt on VM1, which failed on Docker Content Trust |

Notes for reading `task1-semisync.txt`: it was captured right after the replica attached, so `Rpl_semi_sync_source_yes_tx` is still 0. The two `no_tx` commits are the setup statements run before any replica existed. Semi-sync acknowledgement under load is shown by Test 1 (0 of 17,110 acknowledged writes lost), and `status.sh` shows a growing `yes_tx` on a running primary.
