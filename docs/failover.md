# Failover tests (Task 4) — results

Evidence paths are relative to `docs/evidence/`. All timestamps are UTC on 2026-10-18. Epoch values come from `date +%s.%3N`; GCP VMs are NTP-synced, and the evidence below shows client (VM2) and server (VM1) clocks agree to within about 2 s.

## How it was measured

- `scripts/workload.sh` ran on **VM2** (the "application") against `10.0.0.61:6033` (ProxySQL), inserting into `appdb.orders` roughly every 0.1 s. Every insert that returned successfully was logged with its id (`ack.log`); failures went to `fail.log`.
- **Lost acknowledged writes** = ids in `ack.log` that are missing on the new primary (`scripts/check-acks.sh`).
- **Write downtime** = largest gap between consecutive acknowledged writes (`scripts/ack-gap.sh`).
- **RPO** = acknowledged writes missing on DR, plus the time between the last acknowledged write and DR's newest row.
- **RTO** = time from the failure to the first successful application write on the new primary.

## Test 1 — Local failover (kill the Site 1 primary)

### What I expected

- **No acknowledged write lost.** Semi-sync `AFTER_SYNC` means every acknowledged commit was already in the replica's relay log.
- **No application change.** ProxySQL should move the promoted node into writer hostgroup 10 within about 1 s of `read_only` turning off.
- **Downtime is mostly human time.** Detection and promotion are manual, so downtime should equal operator reaction plus about 20 s of commands.

### What happened

| Step | Time (UTC) | Evidence |
|---|---|---|
| `docker kill mysql-primary` | ≈ 10:48:59 (t0 in `~/t0_local.txt` on VM1) | `screenshots/11-test1-kill-and-promote.png` |
| Only failed application write | 10:48:59.929 | `test1-downtime.txt`, `screenshots/14-test1-fail-log.png` |
| Replica promoted (`WAIT_FOR_EXECUTED_GTID_SET` returned 0, `RESET REPLICA ALL`, `read_only=OFF`) | 10:49:19.329 (t1) | `screenshots/11-test1-kill-and-promote.png` |
| ProxySQL: `mysql-replica` in HG10, `mysql-primary` SHUNNED | next poll after t1 | `proxysql-after-local-failover.txt` |
| DR re-pointed to `10.0.0.61:3307`, both threads `Yes`, lag 0 | after t1 | `screenshots/12-test1-dr-repointed-3307.png` |
| Lost-write check: 17,110 acknowledged, **0 lost** | — | `test1-acks.txt`, `screenshots/13-test1-acks-zero-lost.png` |
| Old primary restarted read-only, errant GTIDs **empty**, rejoined as semi-sync replica (`Rpl_semi_sync_source_clients = 1` on new primary) | — | `test1-old-primary-rejoined.txt` |

**Answers to the brief:**

- **How long did it take?** Promotion completed about **20 s** after the primary was killed, all of it manual command time. Exact write downtime is the gap reported by `ack-gap.sh` (see the note below).
- **Did the application need a config change?** **No.** The workload kept using `10.0.0.61:6033` throughout. ProxySQL moved the writer role by itself when `read_only` changed.
- **Was any acknowledged write lost?** **No.** 0 of 17,110.

Only one write failed, even though writes were impossible for about 20 s. While no backend is available, ProxySQL holds the client connection and keeps retrying the backend, rather than returning an error immediately. The application therefore mostly saw **stalled** writes rather than errors. This is why the gap between acknowledged writes, not `fail.log`, is the correct downtime measure.

Note on measurement: `ack.log` from Test 1 was cleared before Test 2, and two workload processes were running during Test 1 (a leftover background job), so the exact gap was not recorded. This does not affect the zero-loss result, since every acknowledged id from both writers was checked. To reproduce a precise figure, re-run Test 1 with one workload process and run `scripts/ack-gap.sh`.

### What I would improve

- **Automate detection and promotion** with Orchestrator, or MySQL Router with InnoDB ReplicaSet. That takes downtime from roughly 20 s plus human reaction to a few seconds.
- **Make ProxySQL highly available.** A single ProxySQL is a single point of failure. Run two instances behind a GCP internal load balancer, or a VIP with keepalived.
- **Script the promotion as one command.** A `promote.sh` would run the GTID wait, detach, writable flip, semi-sync role swap and DR re-point together. That removes typing time and ordering mistakes.
- **Re-point DR automatically,** or have DR replicate through a stable endpoint, so it doesn't stay disconnected after a local failover.

## Test 2 — DR failover (lose Site 1 entirely)

### What I expected

- **RPO near 0.** Both VMs are in the same subnet, so async lag is milliseconds. Cross-region it would be larger.
- **RTO of a few minutes, dominated by human steps.** These are: decide Site 1 is gone, promote DR, re-point the application. The application change is unavoidable here, because there's no proxy spanning both sites.

### What happened

| Step | Time (UTC) | Evidence |
|---|---|---|
| Last acknowledged write before outage: id **223064**, attempt started 14:15:28.737 | 14:15:28.737 | `test2-rpo.txt` |
| Newest row on DR: id **223064**, `created_at` 14:15:30.819 (committed on Site 1) | 14:15:30.819 | `test2-rpo.txt` |
| `docker compose kill` of all 3 Site 1 containers (effective failure time, see note) | ≈ 14:15:31 | `screenshots/16-test2-kill-site1.png` |
| DR promoted (`WAIT_FOR_EXECUTED_GTID_SET` returned 0, `RESET REPLICA ALL`, `read_only=OFF`) | 14:16:05.874 (`t1_dr`) | `screenshots/17-test2-dr-promote-and-rpo.png` |
| First application write on DR (id 223065) | 14:18:39.559 | `test2-first-write-on-dr.txt`, `screenshots/18-test2-first-write-on-dr.png` |
| Site 1 brought back: both nodes `super_read_only=1`, ProxySQL HG10 empty | later | `test2-site1-returned-readonly.txt` |

| Metric | Result |
|---|---|
| **RPO (transactions)** | **0**: 1,049 acknowledged, 0 missing on DR |
| **RPO (time)** | **0 s**: the newest acknowledged write is on DR |
| **RTO, database** (failure → DR writable) | **≈ 35 s** (14:15:31 → 14:16:05.9) |
| **RTO, application** (failure → first write on DR) | **≈ 189 s / 3 min 9 s** (14:15:30.8 → 14:18:39.6) |

**Note on t0.** The recorded `t0_dr` (14:14:13.107) was taken about 77 s *before* the `docker compose kill` was actually executed. The `date` command and the kill were typed separately. Writes kept succeeding until 14:15:30.8, so the real failure time is the last committed row. Using the recorded t0 would overstate RTO as 266 s. In the runbook, t0 is now captured in the same command line as the failure.

**Why the application RTO is about 2.5 minutes longer than the database RTO.** After DR was writable, the RPO measurements were run *before* the workload was re-pointed. In a real incident the order would be reversed: re-point first, measure later. The realistic RTO for this setup is therefore roughly 40–60 s plus decision time.

The application **did** need a config change: its target moved from `10.0.0.61:6033` to the DR endpoint (`127.0.0.1:3306` on VM2).

### What I would improve

- **Use a stable application endpoint across sites,** such as a Cloud DNS record with a short TTL, or a global ProxySQL / MySQL Router tier. DR cutover then becomes "flip DNS" instead of an application change.
- **Write a single `dr-promote.sh`** that records t0, waits for the relay log, promotes, flips DNS and prints RPO.
- **Fence Site 1 explicitly when declaring disaster.** Block it with a GCP firewall rule, or stop the VM, so a partially alive Site 1 can't take writes. Read-only-at-boot covers restarts, but not a primary that never died and was only partitioned.
- **Run DR in a different region.** Same-zone DR only protects against VM and host loss, not zone or region loss. The RPO will then be non-zero and should be alerted on via DR lag.
- **Add a delayed replica** (`SOURCE_DELAY`) in Site 2 to protect against logical errors such as `DROP TABLE`, which replicate instantly to every node here.
- **Stream binlogs off-site continuously** (`mysqlbinlog --read-from-remote-server --raw --stop-never`) so that PITR is still possible if both MySQL sites lose data.
