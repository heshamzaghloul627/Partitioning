# eJarDbAuditing Partitioning — Runbook

Revised 2026-09-12 (retention model aligned to `PurgeLogs_eJar`; audit logs moved to
daily partitions). Originals preserved in `../eJarDbAuditing_Final_ORIGINAL_20260829/`.

---

## 1. What changed and why

The original scripts could not execute (wrong server, no job schedules, disk-space
shortfall) and would have broken the application if they had. The full findings are in
[CODE_REVIEW_eJarDbAuditing_Partitioning.md](CODE_REVIEW_eJarDbAuditing_Partitioning.md).

Three design changes drive everything else:

**Monthly partitions, not 4-per-month.** `TRUNCATE TABLE ... WITH (PARTITIONS)` requires
*every* index to be partition-aligned — so an index whose leading key is not the
partitioning column must probe every partition. `Id` seeks on the clustered PKs are the
dominant index operation on this database (1.86M/month on `AbpEntityChanges`), and they
come from the *write* path. Cutting 253 partitions to ~16 reduces that fan-out ~16×.
It also cuts 252 filegroups/files to ~16, which matters because every `ADD FILE` is
redone on both secondaries.

**Two partition sets, not one shared function.** `AbpAuditLogs` is retained for **days**
(7 for successes, 30 for errors); the change-tracking tables for **12 months**. One shared
function forced a special case into the retention proc and gave every table 253
partitions. Separate sets remove the special case and give each table the granularity its
own policy needs — **daily** for the audit log, monthly for change tracking. See §4.

The audit log's ~46 daily partitions all sit on a **single shared filegroup**
(`FG_LOG_DATA`) rather than one per partition: at daily turnover, per-partition files
would mean a filegroup and file created and dropped every day, each replayed on both AG
secondaries. Truncated space is reused in place instead, and the filegroup settles at
~30 GB.

**Copy only the retention window.** This is the fix for the disk-space showstopper.
Measured from the statistics histograms: only **17.7%** of `AbpEntityChanges` and
**15.2%** of `AbpEntityChangeSets` rows fall inside 12 months. Copying all 734 GB onto a
volume with <200 GB free was arithmetically impossible; copying the retention window,
PAGE-compressed, needs about **64 GB**. The excluded rows are what the retention policy
deletes anyway.

---

## 2. Measured baseline

Collected from `SRV-AZ-AG01` and `SRV-AZ-AG002` on 2026-08-29. Re-measure before you act
on any of it.

### Topology

`eJarDbAuditing` is in AG **`SQLAG02`**, not the AG that `SRV-AZ-AG01` is primary for.

| Replica | Role for SQLAG02 | Commit mode | Failover |
|---|---|---|---|
| **SRV-AZ-AG002** | **PRIMARY** | SYNCHRONOUS | AUTOMATIC |
| SRV-AZ-AG01 | SECONDARY | SYNCHRONOUS | AUTOMATIC |
| SRV-AZ-AG03 | SECONDARY | ASYNCHRONOUS | MANUAL |

Listener `ag-dnn2` port 7777 (did not respond from the `c:\Hesham` workstation; connect
to `SRV-AZ-AG002` by name).

### Volumes — free space per replica

Files are created on **all three** replicas, so the smallest number governs.

| Replica | `C:\` | `D:\` (data) | `L:\` (log) | `T:\` (tempdb) |
|---|---:|---:|---:|---:|
| **SRV-AZ-AG002** (primary) | 16.1 GB | **185.9 GB** | 884.5 GB | 230.4 GB |
| SRV-AZ-AG01 | 42.6 GB | 217.1 GB | 889.0 GB | 239.9 GB |
| SRV-AZ-AG03 | — | 876.7 GB | 351.9 GB | 72.3 GB |

`D:\` on the primary is the binding constraint. `C:\` on the primary at 16.1 GB is
separately worth attention.

### Size and compression

| Table | Rows | Now | PAGE compressed | % in 12 months |
|---|---:|---:|---:|---:|
| AbpEntityPropertyChanges | 1,277,861,484 | 389.17 GB | 172.75 GB | ~17.7% |
| AbpEntityChanges | 383,153,669 | 269.38 GB | 52.59 GB (−80%) | 17.7% |
| AbpEntityChangeSets | 91,418,417 | 45.03 GB | 11.13 GB (−76%) | 15.2% |
| AbpAuditLogs | 18,279,265 | 30.41 GB | 22.25 GB (−19%) | 100% (30 days) |
| **Total** | **1,770,712,835** | **733.99 GB** | **258.72 GB** | |

Compression from `sp_estimate_data_compression_savings`; retention percentages from
`sys.dm_db_stats_histogram` (stats last updated 2026-08-26/27).

**Target after compression + 12-month retention: ~64 GB.**

### Workload — read this before expecting a speed-up

31 days of Query Store on the primary, these four tables:

| | |
|---|---|
| Write operations | **73,814,971** |
| `SELECT` executions | **~600** |
| Cumulative execution time | 450.47 hours |
| Buffer IO wait | **195.14 h** |
| Buffer Latch wait | **167.05 h** |
| Lock wait | 77.45 h |

Buffer IO is the buffer pool holding ~7% of the data (52 GB max server memory vs 772 GB) —
partitioning does not change the working set. Buffer Latch is last-page insert contention.
**Partitioning is being adopted here as a retention enabler, not a query accelerator.**
The savings come from having less data.

---

## 3. Execution order

Run everything against **`SRV-AZ-AG002`** unless a step says otherwise. Every script
refuses to run on a secondary.

### Phase 0 — cheap wins first, no schema change

Do these before the migration. They are low-risk and may deliver a useful share of the
benefit on their own.

1. **Rotate the `LinkedServer` credential.** It is `sysadmin` + `securityadmin` +
   `dbcreator` with the password identical to the username, on a four-AG production
   cluster. Scope the replacement to `db_owner` + `ALTER ANY DATABASE`.
2. Re-enable `Operation_IndexOptimize` for this database — currently disabled, which is
   why statistics are stale and the read queries are slow.
3. Set `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` on the existing clustered PKs and measure the
   effect on the 167 h of Buffer Latch wait.
4. Drop `IX_AbpEntityChangeSets_UserId` — 0 seeks and 0 scans in 31 days against
   1,628,742 writes.
5. Fix tempdb autogrowth from 8 MB to a fixed 256–512 MB.

### Phase 1 — build the structure

| # | Script | Notes |
|---|---|---|
| 1 | `01_Pre-Migration/00_Preflight_Checks.sql` | Read-only. Aborts if anything is wrong. **Complete manual check [9] on all three replicas.** |
| 2 | `01_Pre-Migration/01_Partition Management/01_TABLE_PartitionConfig.sql` | Confirm the seeded retention policy. |
| 3 | `.../02_STOREDPROC_ProvisionPartitions.sql` | Creates the proc. |
| 4 | `.../04_VIEW_Partition_Information.sql` | Creates the view. |
| 5 | `.../03_EXECUTE_PartitionFunctionScheme.sql` | Run as shipped for the dry-run preview, then uncomment STEP 2. |
| 6 | `01_Pre-Migration/02_Abp_Tables/01..04_*_Clone_table_creation.sql` | In order. Script 04 verifies the `ChangeTime` default — **confirm it before continuing.** |
| 7 | `01_Pre-Migration/02_Abp_Tables/05_Clone_verify_constraints.sql` | Asserts no FKs/triggers/indexed views. |

### Phase 2 — load

| # | Step | Notes |
|---|---|---|
| 8 | `02_Migration/01_Bulk_Load/Run-BulkLoad.ps1 -WhatIf` | Counts and retention floors only. |
| 9 | `Run-BulkLoad.ps1` | App stays online. Reads from `SRV-AZ-AG03`. Restartable — re-run as often as needed to shrink the gap. |
| 10 | **Quiesce the application** | Stop the app pool / drain connections. |
| 11 | `02_Migration/02_Delta/Run-Delta.ps1` | Reads from the **primary**. Every reconciliation delta must reach **0**. |
| 12 | `03_Post Migration/01_Create_Nonclustered_Indexes.sql` | Built post-load on purpose. Longest step. |

### Phase 3 — cut over

| # | Step | Notes |
|---|---|---|
| 13 | `03_Post Migration/02_Cutover.sql` | Four gates, rename, **identity reseed**, plan recompile, dependent-object refresh, C3 smoke test. |
| 14 | Functionally test `AbpAuditLogs_Lite`, `FindError`, `FindSuccess`, `FindEntityChanges` | The migration never touched these; a rename rebinds them silently. |
| 15 | Release the application, monitor the write path | Watch `PAGELATCH`/`WRITELOG` and the insert latency percentiles. |
| 16 | `SQL Server Agent Automated Jobs/Partition Provisioning/01_*.sql` — **on all three replicas** | `msdb` is not AG-replicated. Daily 01:00. |
| 17 | `SQL Server Agent Automated Jobs/Retention Cleanup/01_*.sql` then `02_*.sql` — **on all three replicas** | Proc, then job. Job deploys in **dry-run** mode, daily 02:00. |
| 18 | `SQL Server Agent Automated Jobs/Retention Cleanup/03_Replace_PurgeLogs_eJar.sql` — on **`eJarDbReports`** | Repoints the existing manual command at the partition-aware proc, and fixes the `HangFire.State` purge that has never run (14.65 GB backlog). Archives the original. |

**`PurgeLogs_eJar` must not run during steps 13–15.** Its synonyms resolve by literal
name, so between the two renames they point at a table that does not exist. They heal
once the clone is renamed into place.

Rollback at any point up to step 19: `03_Post Migration/03_Rollback_Cutover.sql`.

### Phase 4 — reclaim the space

| # | Step | Notes |
|---|---|---|
| 19 | `03_Post Migration/04_Decommission_Old_Tables.sql` | **Point of no return.** Every action is commented out; uncomment one at a time. Backup first, shrink in ~50 GB stages, rebuild after. |
| 20 | Switch retention to enforcing | See the checklist at the bottom of `02_Create_Job_RetentionCleanup.sql`. |

---

## 4. The retention model (revised 2026-09-12)

### What was already there

`[eJarDbReports].[Jobs].[PurgeLogs_eJar]` is the live retention mechanism. It reaches
into this database through **synonyms** created 2022-10-09 —
`Audit_dbo_AbpAuditLogs → [eJarDbAuditing].[dbo].[AbpAuditLogs]` and three more — which
is why nothing *inside* eJarDbAuditing appeared to purge anything.

It is run **by hand**. No SQL Agent job and no HangFire recurring job calls it.

| Scope | Policy | Evidence it is running (2026-09-12) |
|---|---|---|
| `AbpAuditLogs`, `Exception IS NULL` | **7 days** | successes exist only from 2026-09-05 (~2.2M/day) |
| `AbpAuditLogs`, `Exception IS NOT NULL` | **30 days** | `MIN(ExecutionTime)` = 2026-08-13, exactly 30 days back; ~17k errors/day |
| change tracking, on `AbpEntityChangeSets.CreationTime` | **12 months**, parent-driven | **never run** — `@Type='Audit,State'` doesn't match `'%Entity%'`, hence data back to 2013-05-12 |
| `HangFire.State` in eJarDbProd | 30 days | **never run** — see the bug below |

### How the partitioned design reproduces it

`AbpAuditLogs` is **daily** (as requested) with **two tiers**, because its policy splits on
`Exception` — not the partitioning column — so one partition holds rows with two
different expiry dates. No partition scheme can express that.

| Tier | Mechanism | Config column |
|---|---|---|
| 30 days (error tail) | `TRUNCATE` + `MERGE RANGE` — metadata-only, reclaims space | `RetentionUnits = 30` |
| 7 days (successes) | batched `DELETE`, scoped with `$PARTITION` to one day | `SecondaryRetentionUnits = 7`, `SecondaryPredicate = 'Exception IS NULL'` |

This is strictly cheaper than today: the current proc does
`SELECT Id INTO #Scope FROM ... WHERE ExecutionTime < cutoff AND Exception IS NULL`,
a full-table scan. Scoped by `$PARTITION` it reads one day.

The three change tables stay **monthly** — measured, 0 of 454,517 parent/child pairs
differ by calendar month, so month-granularity ageing by each table's own column matches
the existing parent-driven deletes.

### Dates are used as-is

Nothing is converted, shifted or normalised. A row stamped `2026-09-14 10:00` is compared
as `2026-09-14 10:00`. The only choice is which clock "now" comes from, and that is
explicit per set via `PartitionSet.ClockSource`, defaulting to `UTC` because the
application demonstrably writes UTC:

```
SYSDATETIME()                         = 2026-09-12 19:33:02   (local, UTC+3)
SYSUTCDATETIME()                      = 2026-09-12 16:33:02
MAX(AbpAuditLogs.ExecutionTime)       = 2026-09-12 16:33:02   <- UTC
MAX(AbpEntityChanges.ChangeTime)      = 2026-09-12 16:33:02   <- UTC
MAX(AbpEntityChangeSets.CreationTime) = 2026-09-12 16:33:02   <- UTC
```

`PurgeLogs_eJar` uses `GETDATE()` (local) against those UTC columns, so its cutoffs sit
**3 hours later** than the stated policy and it deletes 3 hours more than 7 / 30 days.
Immaterial at 1-year granularity; not immaterial at 7 days against daily partitions. Set
`ClockSource = 'LOCAL'` if you want that behaviour reproduced bug-for-bug.

### Three bugs found in the existing proc

1. **The `State` purge has never executed.** It tests `@@ROWCOUNT` *after* a
   `CREATE INDEX`, which is DDL and leaves it at 0, so the loop body never runs.
   `HangFire.State` in eJarDbProd: **1,842,143 rows / 14.65 GB, `MIN(CreatedAt)` =
   2024-10-28** under a 30-day policy. The `Entity` block avoids this by capturing
   `@rc = @@ROWCOUNT` before its `CREATE INDEX`; the `State` block forgot to.
2. **Local clock against UTC columns** — as above.
3. **Hard-coded `top 10000`** in the `AbpEntityChangeSets` delete, inside a proc that
   otherwise honours `@Batch`.

All three are fixed in `03_Replace_PurgeLogs_eJar.sql`, which keeps the same name and
signature so your existing command is unchanged:

```sql
EXEC [Jobs].[PurgeLogs_eJar] @Type = 'Audit,State', @Batch = 10000;
```

It archives the original as `[Jobs].[PurgeLogs_eJar_PrePartitioning]` and falls back to it
if the partition procs are absent (e.g. after a rollback).

---

## 5. Open items requiring a decision

| Item | Where | Why it needs you |
|---|---|---|
| **12-month entity retention has never run** | `PartitionConfiguration.PartitionSet` | The first enforcing run removes ~82–85% of the three change tables. That is the goal, but it is a large irreversible deletion. |
| **Is 7 / 30 days still the intended audit-log policy?** | same | It is what is enforced today, but confirm it is deliberate rather than historical. |
| **Append-only assumption** | `Run-Delta.ps1` | A `MAX(Id)` delta cannot capture `UPDATE`/`DELETE`. The script now checks Query Store and refuses if it finds any. |
| **Orphaned property changes** | `Run-BulkLoad.ps1 -CheckOrphans` | Rows whose parent is missing have no `ChangeTime` and cannot be migrated. Quantify once during rehearsal (expensive — full anti-join on 1.28 B rows). |
| **`IX_AbpEntityChangeSets_UserId`** | `01_Create_Nonclustered_Indexes.sql` | Not created — 0 seeks in 31 days. 31 days may not cover a quarterly report. |

Resolved since the previous revision: the `ChangeTime` default clock (measured — UTC),
and what purges `AbpAuditLogs` today (`PurgeLogs_eJar`, manually).

---

## 6. Verification performed on these scripts

- All **20** `.sql` files pass `SET PARSEONLY ON` against SQL Server 2019 on the live
  instance (the eJarDbReports script parsed in that database's context).
- All 3 PowerShell files pass `[Parser]::ParseFile` with zero errors.
- `00_Preflight_Checks.sql` executed successfully against the real primary
  (`SRV-AZ-AG002`) and passed all automated checks.
- Every schema claim, size, wait statistic, index-usage figure, row distribution and
  clock reading quoted in the scripts was read from the live server, not assumed.

Two bugs were found and fixed in **my own** revised scripts during review:

- the secondary-tier `DELETE` loop read `@@ROWCOUNT` after `EXEC sp_executesql`, which is
  not reliably preserved across the `EXECUTE` boundary; it would have deleted only one
  batch per run. Now returned through an `OUTPUT` parameter.
- the `HangFire_State` loop used `EXISTS` for the target table but an unordered
  `DELETE TOP (n)` for the scope table, so the two could diverge and strand rows. Both
  now take the identical `TOP (@Batch) ... ORDER BY Id` set, and the loop is driven by the
  scope table's count.

Not yet verified: no script that modifies anything has been executed. The partition
build, load, cutover and retention paths need a rehearsal on a restored copy.
