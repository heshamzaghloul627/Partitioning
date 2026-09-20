# Code Review — eJarDbAuditing Partitioning & Migration Scripts

**Reviewed:** `c:\Hesham\eJarDbAuditing_Final\` — 30 files (13 T-SQL, 12 PowerShell, 5 job/config)
**Review date:** 2026-08-29
**Reviewer:** manual review (CodeRabbit CLI unavailable — see *Tooling note*)
**Live verification:** read-only queries against `SRV-AZ-AG01` and `SRV-AZ-AG002`

---

## Tooling note

The `/coderabbit-review` skill could not run its engine: the CodeRabbit CLI is not installed on this
host, `git` is not installed, and `c:\Hesham` is not a git repository (CodeRabbit reviews diffs and
requires a work tree). This review was therefore performed directly, with the addition of live
schema/telemetry collection — which CodeRabbit could not have done, since it has no database
connection and no knowledge of this server's topology or workload.

---

## Environment as measured (not as assumed)

| Fact | Value |
|---|---|
| Instance | `SRV-AZ-AG01` — SQL Server 2019 Enterprise, 15.0.4480.2 (CU32-GDR) |
| Host | 32 logical CPUs, 63 GB RAM, `max server memory` 52,000 MB, MAXDOP 8, CTFP 25 |
| Availability Groups on this node | `SQLAG01`, `SQLAG02`, `SQLAG03`, `SQLAG04` |
| **`eJarDbAuditing` belongs to** | **`SQLAG02`** |
| **Role of `SRV-AZ-AG01` for `SQLAG02`** | **SECONDARY** (`fn_hadr_is_primary_replica` = `0`) |
| **Primary for `eJarDbAuditing`** | **`SRV-AZ-AG002`** (confirmed: `is_primary_replica` = `1`) |
| Third replica | `SRV-AZ-AG03` — ASYNCHRONOUS_COMMIT, MANUAL failover |
| `SQLAG02` listener | `ag-dnn2` port 7777 (did not respond from this host) |
| Recovery model / compat | FULL / 150, RCSI **on** |
| Data file | `D:\Data\eJarDbAuditing.mdf` — **772.36 GB**, single file, PRIMARY filegroup |
| Log file | `L:\Log\eJarDbAuditing_log.ldf` — 10.1 GB |
| **`D:\` free space** | **217.1 GB** of 1,800 GB |
| `L:\` free space | 889.0 GB of 1,024 GB |
| tempdb | 9 × 1,800 MB on `T:\`, autogrowth **8 MB** |
| Instant File Initialization | **Enabled** |
| Partition functions / schemes present | **none** — this is a greenfield deployment |

### Table sizes (live)

| Table | Rows | Reserved | Data | Index | Date range |
|---|---:|---:|---:|---:|---|
| `AbpEntityPropertyChanges` | 1,277,745,190 | 389.13 GB | 339.61 | 49.46 | *(no date column)* |
| `AbpEntityChanges` | 383,122,860 | 269.35 GB | 75.66 | 193.64 | 2013-05-12 → 2026-08-29 |
| `AbpEntityChangeSets` | 91,412,014 | 45.03 GB | 37.84 | 7.17 | 2021-12-14 → 2026-08-29 |
| `AbpAuditLogs` | 17,941,701 | 30.41 GB | 17.36 | 9.68 | **2026-07-30** → 2026-08-29 |
| **Total** | **1,770,221,765** | **733.92 GB** | | | |
| *All objects in DB* | | *734.01 GB* | | | |

These four tables are **99.99% of the database**.

### Workload (Query Store on the primary, 31-day window 2026-07-29 → 2026-08-29)

| Metric | Value |
|---|---|
| Write operations against the 4 tables | **73,814,971** |
| Weighted mean duration | 21.97 ms |
| Max single execution | **122,919 ms** (~2 min) |
| Cumulative execution time | **450.47 hours** |
| `SELECT` executions (all variants, same window) | **~600 total** |

**Wait breakdown for these tables (31 days):**

| Wait category | Hours |
|---|---:|
| Buffer IO | **195.14** |
| Buffer Latch | **167.05** |
| Lock | 77.45 |
| Latch | 6.45 |
| Memory | 1.55 |

**Index usage on the primary (31 days):**

| Index | Seeks | Scans | Updates |
|---|---:|---:|---:|
| `PK_AbpEntityChanges` (CL, `Id`) | **1,863,267** | 0 | 1,630,770 |
| `PK_AbpEntityChangeSets` (CL, `Id`) | **1,631,311** | 1 | 1,628,742 |
| `PK_AbpAuditLogs` (CL, `Id`) | 10,520 | 4,355 | 104,835,186 |
| `IX_AbpAuditLogs_ExecutionTime_Exception` | 768 | 10 | 104,835,186 |
| `IX_AbpEntityChanges_EntityId_EntityTypeFullName` | 503 | 0 | 1,630,770 |
| `IX_AbpEntityChanges_ChangeTime_EntityTypeFullName` | 97 | 0 | 1,630,770 |
| `IX_AbpEntityPropertyChanges_EntityChangeId` | 59 | 0 | 1,863,267 |
| `IX_AbpEntityChanges_EntityChangeSetId` | 22 | 0 | 1,630,770 |
| **`IX_AbpEntityChangeSets_CreationTime`** | **0** | **0** | 1,628,742 |
| **`IX_AbpEntityChangeSets_UserId`** | **0** | **0** | 1,628,742 |

---

# CRITICAL

## C1 — The migration does not fit on disk

`Data Migration/02_Migration/01_Bulk_Load/*.ps1`

The `_Clone` approach requires a **complete second copy** of the data to exist before the originals
can be dropped. The four tables total **733.92 GB**; `D:\` has **217.1 GB free**.

Even at an optimistic 50% ROW-compression ratio the clone needs ~367 GB — short by ~150 GB. A
realistic ROW-compression ratio on these types (mostly `nvarchar` and `bigint`) is 20–35%, putting
the requirement near 480–590 GB, i.e. short by **260–370 GB**. On top of that the partition scheme
pre-allocates 252 files × `SIZE = 100MB` = **25.2 GB**.

**Failure mode:** the bulk load runs for hours, fills `D:\` on the primary of a four-AG cluster, and
dies partway. `D:\` also hosts `eJarDbAuditing.mdf` itself and (given the naming) likely other AG
databases — so a full volume is an outage for more than this database.

**Options, in order of preference**
1. **Purge in place first.** Delete/archive old rows from the existing tables to get the live set
   under ~180 GB, shrink, *then* partition. This inverts the current plan but is the only sequence
   that fits the volume.
2. Stage the clone on a different volume (`L:\` has 889 GB free) via a dedicated filegroup, then
   relocate.
3. Avoid the copy entirely: build the partitioned structure and use `ALTER TABLE ... SWITCH` to move
   existing data in as partitions where the boundaries permit.

Note in all cases: dropping the old tables does **not** shrink the 772 GB `.mdf`. Reclaiming that
requires `DBCC SHRINKFILE`, which on an AG-replicated 772 GB file is long, fully logged, and leaves
heavy fragmentation.

## C2 — Every DDL script targets a read-only secondary

`01_Pre-Migration/**/*.sql`, `Retention Management/**/*.sql`, `SQL Server Agent Automated Jobs/**/*.sql`

The brief states the scripts run against `SRV-AZ-AG01`, which "replicates to AG002 and AG03". That
is true for `SQLAG01`, `SQLAG03` and `SQLAG04` — but **not for `eJarDbAuditing`**, which lives in
`SQLAG02` where `SRV-AZ-AG01` is a **SECONDARY**:

```
SELECT sys.fn_hadr_is_primary_replica('eJarDbAuditing');  -- returns 0 on SRV-AZ-AG01
                                                          -- returns 1 on SRV-AZ-AG002
```

Every `USE eJarDbAuditing` + `CREATE`/`ALTER` in the folder fails immediately on `SRV-AZ-AG01`.

Note the internal contradiction: the PowerShell scripts already set
`$TargetServer = "SRV-AZ-AG002"  # Primary/write replica` — **correct** — while the T-SQL runbook and
the brief say AG01. The two halves of the deliverable disagree about which server is the primary.
Pin this down before anything runs, and prefer the listener `ag-dnn2,7777` over a node name so the
scripts survive a failover.

## C3 — `ChangeTime NOT NULL` with no default breaks every application write

`01_Pre-Migration/02_Abp_Tables/04_AbpEntityPropertyChanges_Clone_table_creation.sql:24`

```sql
[ChangeTime] [datetime2](7) NOT NULL,
```

Verified against the live schema: `dbo.AbpEntityPropertyChanges` has 9 columns and **no
`ChangeTime`**, and there are **zero default constraints on any of the four Abp tables**. The column
is a denormalisation the bulk copy populates by joining the parent — but nothing populates it at
runtime.

The application's actual insert, from Query Store on the primary:

```sql
INSERT INTO [AbpEntityPropertyChanges]
  ([EntityChangeId], [NewValue], [NewValueHash], [OriginalValue],
   [OriginalValueHash], [PropertyName], [PropertyTypeFullName], [TenantId])
OUTPUT INSERTED.[Id] VALUES (@p16, @p17, ..., @p23)
```

38,118 direct executions plus the batched `MERGE ... WHEN NOT MATCHED THEN INSERT` variants — same
column list, no `ChangeTime`. Total writes to this table in 31 days: part of the 73.8 M figure above.

**On cutover, every audit write fails with `Msg 515` (cannot insert NULL).** Because ABP persists
audit records inside the request pipeline, this does not degrade gracefully.

**Fix:** add `DEFAULT (SYSUTCDATETIME())` — and get the app team to confirm, because a default is
*not* semantically the same as the parent's `ChangeTime`. If exact parent-time fidelity is required,
this needs an application change, not a schema-only one.

## C4 — Neither Agent job has a schedule

`SQL Server Agent Automated Jobs/Partition Provisioning/02_Create_Job_*.sql`
`SQL Server Agent Automated Jobs/Retention Cleanup/02_Create_Job_*.sql`

Both scripts call `sp_add_job`, `sp_add_jobstep`, `sp_add_jobserver` — and **never
`sp_add_jobschedule`**. The jobs are created `@enabled = 1` and will never fire.

Silent consequence: partitions are never provisioned and retention never runs. The partition function
runs out of range, and every new row accumulates in the trailing partition — the exact condition C6
describes, reached with no error anywhere.

## C5 — Jobs are not AG-aware, and `msdb` is not replicated by an AG

Same two files. Two separate problems:

1. `msdb` is outside the AG, so jobs created on one replica **do not exist** on the others. After a
   failover to `SRV-AZ-AG002` (AUTOMATIC failover is configured) the jobs are simply gone.
2. Neither job step guards on replica role. A job present on a replica that is *not* primary fails on
   every execution against a read-only database, generating perpetual job-failure alerts.

**Fix:** deploy the jobs to all three replicas and open every step with

```sql
IF sys.fn_hadr_is_primary_replica('eJarDbAuditing') <> 1 RETURN;
```

## C6 — The pre-created partition range ended five months ago

`01_Pre-Migration/01_Partition Management/02_STOREDPROC_AutoCreatePartition.sql:39`

```sql
DECLARE @finalDate datetime2 = CONVERT(NVARCHAR(8), DATEADD(QQ, 3, DATEADD(YY, 5, @i)), 112);
```

`@finalDate` is derived from `@firstRunDate` (`'20210101'`), not from the current date, giving a last
boundary of **2026-04-01**. Live `MAX(ChangeTime)` is **2026-08-29** — today.

Two consequences:

1. At deployment, ~5 months of the hottest data **plus all future rows** fall into the trailing
   partition, which the scheme maps to `[PRIMARY]` — the same 772 GB filegroup the whole exercise is
   meant to move away from.
2. The first `AutoCreateNext52WeekPartitions` run then issues `SPLIT RANGE` against that
   **non-empty** partition. Splitting a populated partition is a fully-logged, offline,
   size-of-data data movement under a schema-modification lock, replicated synchronously to
   `SRV-AZ-AG002`. On a partition holding months of a 389 GB table this is a long hard outage.

The standard rule is that the trailing partition must always be empty. **Fix:** derive `@finalDate`
from `GETDATE()` plus headroom, and provision forward before go-live.

## C7 — `READPAST` in the bulk copy silently discards rows

All 12 `*_BulkCopy*.ps1` files, e.g. `01_Bulk_Load/AbpAuditLogs_BulkCopy.ps1:255,294`

```powershell
FROM $SourceTable WITH (READPAST)
WHERE Id > @LastId
ORDER BY Id;
```

`READPAST` **skips locked rows** instead of waiting for them. The source is live and absorbing
~73.8 M writes per month, so rows *will* be locked during the read.

Skipped rows are never recovered, because the restart checkpoint is `MAX(Id)` **on the target** and
the next chunk selects `WHERE Id > @LastId`. Once the checkpoint moves past a skipped Id, that row is
gone from the migration permanently.

There is no `COUNT(*)` or checksum reconciliation anywhere in the folder, so the loss would be
**silent and unquantified** — on audit data, which is typically the data with the strongest
retention and integrity obligations.

**Fix:** remove `READPAST`; read under `SNAPSHOT` isolation, or source from the
ASYNCHRONOUS_COMMIT replica `SRV-AZ-AG03` where contention is lower. Add a mandatory per-range
source-vs-target row count and checksum gate before cutover.

## C8 — `NOLOCK` checkpoint can advance past uncommitted rows

All 12 `*_BulkCopy*.ps1` files, `Get-LastCheckpoint`:

```powershell
SELECT ISNULL(MAX(Id), 0) FROM $TargetTable WITH (NOLOCK);
```

`SqlBulkCopy` is configured with `UseInternalTransaction` and `BatchSize = 50000`, so batches commit
independently. A dirty read can observe an `Id` from a batch that subsequently **rolls back**; on
restart the loop resumes above that `Id` and those rows are never copied. Same class of silent loss
as C7. Remove `NOLOCK` — this is a single-row aggregate, the read cost is irrelevant.

---

# WARNING

## W1 — Partition-aligning the non-date indexes penalises the write path

`01_Pre-Migration/02_Abp_Tables/*.sql`

The design demotes the clustered PK on `Id` to `PRIMARY KEY NONCLUSTERED (Id, ChangeTime)` and makes
the clustered index `(ChangeTime, Id)`, everything aligned on `PSYearMonthWeek(ChangeTime)`.

A predicate on `Id` alone **cannot eliminate partitions**, so every `Id` lookup becomes a probe of
~253 B-trees instead of one seek.

Measured on the primary over 31 days, `Id` seeks on the clustered PKs are the *dominant* index
operation:

- `PK_AbpEntityChanges` — **1,863,267 seeks**
- `PK_AbpEntityChangeSets` — **1,631,311 seeks**

Critically, these are not user searches. `IX_AbpEntityPropertyChanges_EntityChangeId` shows
`user_updates = 1,863,267` — the same number — indicating these seeks are EF resolving parent rows
**during audit writes**. So the amplification lands on the hot write path, not on a rarely-used
report.

The same problem applies to `IX_AbpEntityChanges_EntityChangeSetId` and
`IX_AbpEntityPropertyChanges_EntityChangeId`: both are placed `ON [PSYearMonthWeek]([ChangeTime])`
without `ChangeTime` in the key, so SQL Server silently appends the partitioning column and lookups
by the intended key must span all partitions.

**This is the single largest application-compatibility risk in the plan and the scripts do not
address it.** The genuine tension: leaving these indexes non-aligned (`ON [PRIMARY]`) preserves the
lookups but forfeits partition-level `TRUNCATE`/`SWITCH`, which is the entire retention mechanism.
That trade-off needs an explicit decision, tested against the real access paths.

## W2 — `OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF` against 167 hours of measured Buffer Latch wait

Set explicitly on **all 11 indexes** across the four clone DDL files.

Query Store wait stats for these tables over 31 days show **Buffer Latch = 167.05 hours** — the
textbook signature of last-page insert contention on a monotonically ascending key at high
concurrency. SQL Server 2019's `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` exists specifically to relieve
this convoy.

Turning it **off** discards the cheapest, lowest-risk available improvement. Worse, the new clustered
index `(ChangeTime, Id)` is *also* strictly ascending, relocating the hotspot onto the clustered
index of a 389 GB table.

**Fix:** `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` on the clustered indexes and the nonclustered PKs at
minimum. This is worth testing on its own, before partitioning, as it may deliver a meaningful share
of the hoped-for benefit at near-zero risk.

## W3 — Partitioning does not target the measured bottleneck

Worth stating plainly so expectations are calibrated. The measured profile is:

- **Buffer IO 195.14 h** — the buffer pool holds ~7% of the database (52 GB `max server memory` vs
  772 GB of data). Partitioning does not change the working set, so it does not reduce this.
- **Buffer Latch 167.05 h** — insert contention (see W2). Partitioning does not help; the design may
  worsen it.
- **Lock 77.45 h** — `TRUNCATE`/`MERGE RANGE` add schema-mod locks here.

The write:read ratio is roughly **73,800,000 : 600**. Partition elimination is real and will help the
read side — the audit grid's count query (`SELECT COUNT(*) FROM [AbpAuditLogs] ... StartDate /
EndDate / UserName`) has a 4,722 ms weighted average and would improve substantially — but at 101
executions per month that is not where the 450 hours are going.

**The genuine wins available here are retention (less data), compression (fewer pages), and more
RAM.** Retention is the strongest, and it is the part of this plan most worth keeping. It is worth
being explicit with stakeholders that partitioning is being adopted primarily as a *retention
enabler*, not as a query accelerator.

## W4 — Retention orphans a filegroup and a file on every cycle

`SQL Server Agent Automated Jobs/Retention Cleanup/01_Create_Procedure_sp_RetentionCleanup_eJarDbAuditing.sql:168`

The proc does `TRUNCATE ... WITH (PARTITIONS (...))` then `ALTER PARTITION FUNCTION ... MERGE RANGE`,
but never `ALTER DATABASE ... REMOVE FILE` / `REMOVE FILEGROUP`. After the merge the filegroup is
unreferenced by the scheme, yet its ≥100 MB file remains forever. Over years this accumulates
hundreds of dead files, inflating backup time, restore time, startup time and AG seeding time.

*Credit where due:* truncating **before** merging is correct and important — it makes the merge a
metadata operation instead of a size-of-data data movement. Keep that ordering.

## W5 — Week-slot collision breaks the one-partition-per-filegroup invariant

`SQL Server Agent Automated Jobs/Partition Provisioning/01_Create_Procedure_AutoCreateNext52WeekPartitions.sql:96-102,183`

The proc advances strictly by seven days:

```sql
SET @NextBoundary = DATEADD(DAY, 7, @NextBoundary);
```

but derives the filegroup slot from the day-of-month:

```sql
SET @WeekSlot = CASE WHEN DATEPART(DAY, @NextBoundary) <= 7  THEN 0
                     WHEN DATEPART(DAY, @NextBoundary) <= 14 THEN 1
                     WHEN DATEPART(DAY, @NextBoundary) <= 21 THEN 2
                     ELSE 3 END;
```

Within a single month, +7 stepping can produce two boundaries both past day 21 (e.g. day 24 and day
31) — **both map to slot 3**, i.e. the same `FG_DT_03_MM_YYYY`. The `IF NOT EXISTS` guards then skip
`ADD FILEGROUP` and `ADD FILE`, and `NEXT USED` points a *second* partition at the same filegroup and
the same 100 MB file. Partition-level truncate/merge/file-removal all assume a 1:1 mapping.

Separately, the +7 walk never lands on an end-of-month date, so it drifts off the initial
07/14/21/EOM pattern established by `AutoCreatePartition` and month-end rows bleed into the next
month's slot-0 partition. The comment `-- Existing naming logic (DO NOT CHANGE)` suggests this
mismatch was noticed but deferred.

## W6 — 252 `ADD FILE` operations against a synchronous-commit AG

`01_Pre-Migration/01_Partition Management/02_STOREDPROC_AutoCreatePartition.sql:128`

The first run creates **252 filegroups and 252 files** (4 per month × 63 months). Every
`ALTER DATABASE ... ADD FILE` is redone on `SRV-AZ-AG002` (sync) and `SRV-AZ-AG03` (async).

**If `D:\Data\` does not exist at the identical path on both secondaries, redo fails and the database
drops out of the availability group** (suspended / not synchronizing). Nothing in the scripts checks
the path on the replicas, and `@fgPath` is hard-coded to `'D:\Data\'` in two places plus the job
definition.

Add an explicit pre-flight verification of `D:\Data\` on all three replicas, with free-space
headroom, before running anything.

*Credit:* Instant File Initialization is enabled (`instant_file_initialization_enabled = Y`), so file
creation itself will be fast rather than zero-filling 25 GB.

## W7 — The bulk load will flood the transaction log and stall the AG

All 12 `*_BulkCopy*.ps1`, `$BulkOptions` block:

```powershell
[SqlBulkCopyOptions]::TableLock -bor ::KeepIdentity -bor ::KeepNulls -bor ::UseInternalTransaction
```

`TABLOCK` on a target that **already has nonclustered indexes** does not qualify for minimal logging,
so a ~734 GB load is **fully logged** under FULL recovery with SYNCHRONOUS_COMMIT to
`SRV-AZ-AG002`. The current log is 10 GB.

Expect very large log growth and a large `log_send_queue`. While the synchronous secondary lags,
commits stall for **every database in `SQLAG02`**, not just this one. Given the tail latency already
present (max single write 122,919 ms), this is a plausible application outage.

Also: `$Timeout = 0` (infinite `BulkCopyTimeout`) means a stuck load holds `TABLOCK` indefinitely
with no automatic release.

**Mitigations:** load into the clone **before** creating its nonclustered indexes (build them after);
switch to BULK_LOGGED for the load window if the RPO permits; add frequent log backups throughout;
run against the async replica topology if possible; set a finite timeout.

## W8 — Long reads on a synchronous-commit secondary block redo

All 12 `*_BulkCopy*.ps1`:

```powershell
$SourceServer = "SRV-AZ-AG01"    # Secondary/readable replica
"ApplicationIntent=ReadOnly"
```

Two points. First, `ApplicationIntent=ReadOnly` only triggers read-only routing through an AG
*listener*; against a direct node name it is ignored. Here it happens to point at a secondary
already, so the intent is satisfied by accident rather than by configuration.

Second, and more important: reading 389 GB from a **SYNCHRONOUS_COMMIT** secondary holds
schema-stability locks that **block redo**, growing the redo queue and extending failover RTO on a
replica configured for AUTOMATIC failover. `SRV-AZ-AG03` (ASYNCHRONOUS_COMMIT, MANUAL failover) is
the safer source.

## W9 — There is no cutover script, and no IDENTITY reseed

The folder is structured `01_Pre-Migration` → `02_Migration` → `03_Post Migration`, but nothing
renames `AbpX_Clone` to `AbpX`. Missing entirely:

- an application quiesce / read-only gate,
- a final-delta-then-verify gate,
- the rename itself (both directions),
- **`DBCC CHECKIDENT` reseed** — all four tables use `Id BIGINT IDENTITY(1,1)` and the clone is
  loaded with `KeepIdentity`, so the clone's identity counter is left at its seed. Without a reseed
  the **first application insert after cutover collides** on the primary key,
- a rollback for the rename. `03_Post Migration/Optional Rollback/` contains only the same bulk-copy
  scripts again, which is not a rollback of a cutover.

## W10 — Existing dependent objects are ignored

Live dependency check found four objects the migration never mentions:

| Object | Type | References |
|---|---|---|
| `dbo.AbpAuditLogs_Lite` | VIEW | `AbpAuditLogs` |
| `dbo.FindError` | PROCEDURE | `AbpAuditLogs` |
| `dbo.FindSuccess` | PROCEDURE | `AbpAuditLogs` |
| `dbo.FindEntityChanges` | PROCEDURE | `AbpEntityChanges`, `AbpEntityChangeSets`, `AbpEntityPropertyChanges` |

After a rename-based cutover these rebind by name to the new tables. Consequences to check:

- any `SELECT *` now also returns the new `FMonth` column (see I3), which can break callers that
  bind by ordinal or map strictly;
- `FindEntityChanges` joins all three change tables — if it filters by `EntityChangeSetId` or
  `EntityChangeId` without a date predicate it degrades to all-partition probing (W1);
- `AbpAuditLogs_Lite` may reference columns whose nullability or position changed.

All four need review and regression testing as part of the cutover.

*No triggers exist* on any of the four tables — worth noting, because a trigger would have broken
EF's `MERGE ... OUTPUT INSERTED.[Id]` pattern outright.

## W11 — The "Delta" scripts are copies of the bulk-load scripts

`02_Migration/02_Delta/*.ps1` are byte-identical to `02_Migration/01_Bulk_Load/*.ps1` for three of
four tables (`AbpEntityChangeSets` 12,169 B both; `AbpEntityChanges` 11,770 B both;
`AbpEntityPropertyChanges` 12,257 B both), and differ by 3 bytes for `AbpAuditLogs`.

They use the same `MAX(Id)` resume, so they capture only **newly inserted** rows. Any `UPDATE` or
`DELETE` on the source during the load window is never propagated. These tables appear append-only,
which makes this survivable — but it is an unstated, unverified assumption underpinning the
correctness of the whole cutover. Document it, and verify it (e.g. confirm no `UPDATE`/`DELETE`
against these tables in Query Store) before relying on it.

## W12 — `WITH NOCHECK CHECK CONSTRAINT ALL` leaves constraints untrusted

`03_Post Migration/01_Re-enable Constraints.sql:3-6`

```sql
ALTER TABLE AbpAuditLogs_Clone WITH NOCHECK CHECK CONSTRAINT ALL;
```

`WITH NOCHECK` re-enables without validating, leaving `is_not_trusted = 1` so the optimizer ignores
the constraint for simplification. The correct form is `WITH CHECK CHECK CONSTRAINT ALL`.

Currently **moot**: the live tables have **zero foreign keys and zero check constraints**, so both
`05_Clone_disable_constraints.sql` and this file are complete no-ops. That is itself worth surfacing —
the scripts imply referential protection that does not exist. The `AbpEntityPropertyChanges →
AbpEntityChanges → AbpEntityChangeSets` relationships are application-enforced only, which is why the
"child before parent" truncate ordering matters and why the delta join in C7/W11 can drop orphans.

## W13 — The 7-day AbpAuditLogs retention is a silent behaviour change

`Retention Cleanup/01_Create_Procedure_...sql:10` — `@AuditLogRetentionDays INT = 7`

Live `MIN(AbpAuditLogs.ExecutionTime)` is **2026-07-30** — about **30 days** retained today
(17.9 M rows / 30.4 GB). The job's default would delete roughly 23 of those 30 days on its first run.

Compounding this: **no SQL Agent job currently purges `eJarDbAuditing`.** The only related job,
`Operation_IndexOptimize` (which also carries `@UpdateStatistics='ALL'` for this database), is
**disabled** (`enabled = 0`). So whatever maintains the 30-day window is the application or a manual
process.

Identify that mechanism before adding a second one, or the two will overlap — and confirm 7 days is
actually the agreed retention, since it is a 4× reduction from current behaviour on audit data.

Related: index maintenance and statistics updates for this database are currently switched off, which
is part of why the read queries are slow. Re-enabling that is cheaper than partitioning.

---

# INFO

**I1 — Eight years of unplanned data lands in partition 1.**
`MIN(AbpEntityChanges.ChangeTime)` is **2013-05-12**, but `@firstRunDate = '20210101'`. `RANGE LEFT`
leaves the leftmost partition unbounded below, so 2013–2021 all lands in partition 1 on a single
filegroup sized `SIZE = 100MB`. Functionally correct, badly mis-sized, and evidence the data range
was never checked.

**I2 — `.997` boundaries are a `datetime` artifact applied to a `datetime2(7)` function.**
`02_STOREDPROC_AutoCreatePartition.sql:182-190` builds boundaries as `...T23:59:59.997`. `.997` is the
maximum `datetime` tick; on `datetime2(7)` it leaves a ~3 ms window at each boundary that falls into
the *next* partition. Prefer `RANGE RIGHT` with midnight boundaries — the conventional pattern, and
it removes the whole class of off-by-a-tick reasoning from the retention logic.

**I3 — The `FMonth` computed column is dead weight.**
`[FMonth] AS (DATEPART(month,[<date>])) PERSISTED` is added to all four tables and used by no index,
no partition function, and no query. On 1.28 billion rows that is pure storage plus per-insert CPU.
It is also schema drift the EF model does not know about, and it changes what `SELECT *` returns
(see W10).

**I4 — The composite PK weakens the `Id` uniqueness guarantee.**
`PRIMARY KEY NONCLUSTERED (Id, ChangeTime)` is the standard workaround for aligning a unique index
with the partitioning column, but it no longer enforces `Id` alone as unique. `IDENTITY` makes
collisions unlikely in practice and EF still treats `Id` as the key, so this is low risk — but it
should be a conscious sign-off rather than a side effect.

**I5 — Two provably unused indexes are faithfully recreated.**
Over 31 days on the primary, `IX_AbpEntityChangeSets_UserId` and
`IX_AbpEntityChangeSets_CreationTime` both show **0 seeks and 0 scans** while absorbing 1,628,742
updates each. Both are reproduced in the clone. Dropping them instead would remove write overhead
from the hot path and save part of that table's 7.17 GB of index. *Caveat:* 31 days may not cover
quarterly or annual reporting — confirm before dropping.

**I6 — `sp_` prefix on a user-database procedure.**
`dbo.sp_RetentionCleanup_eJarDbAuditing` — SQL Server resolves `sp_`-prefixed names against `master`
first. Rename to e.g. `PartitionConfiguration.RetentionCleanup`.

**I7 — Unparameterised dynamic SQL.**
`@DBName NVARCHAR(MAX)` and the `Partition_Query` view's columns are concatenated directly into
`ALTER DATABASE` / `ALTER PARTITION` statements with no `QUOTENAME`. Inputs are internal so practical
exposure is low, but these procs are callable by the Agent service account. Use `QUOTENAME()` and
`sp_executesql`.

**I8 — Three different file-naming conventions for the same object class.**
`AutoCreatePartition` first-run: `D:\Data\eJarDbAuditing_File_DT_00_01_2021.mdf`.
Non-first-run branch: `@FolderPath NVARCHAR(MAX) = '_'` — which contradicts its own comment
(`-- Use '\' for Windows, '/' for Linux`) and yields `D:\Data\_File_DT_00_01_2027.mdf`.
`AutoCreateNext52WeekPartitions`: `<path><dbname>_<FileName>.mdf`. Pick one.

**I9 — Secondary data files are named `.mdf`.**
252 secondary files carry the primary-file extension. Convention is `.ndf`; some backup and
monitoring tooling keys off it.

**I10 — `01_TABLE_PartitionFilePath.sql` is not re-runnable.**
Bare `CREATE TABLE` with no existence guard, plus an unguarded 12-iteration insert loop. A second run
errors on the `CREATE`; if the `CREATE` were guarded, the loop would append rows 13–24 and
`WHERE Month = DATEPART(MONTH, ...)` would start matching multiple rows. There is also no
PK/unique constraint on `[Month]`, which is an `IDENTITY` column doing duty as a business key.

**I11 — `SELECT TOP 4 MIN(row_number)` is a no-op.**
`02_STOREDPROC_AutoCreatePartition.sql:259-266`. `MIN`/`MAX` are aggregates over the whole table, so
`TOP 4` returns exactly one row either way. The intended "four slots" behaviour is actually achieved
by the later `SET @maxRowNum = @partitionsPerMonth - 1` clamp. Harmless but misleading.

**I12 — Index-build options conflict with the repository's own convention.**
`CLAUDE.md` requires `WITH (ONLINE = ON, SORT_IN_TEMPDB = ON)` on every create/rebuild; the clone DDL
uses `ONLINE = OFF, SORT_IN_TEMPDB = OFF` on all 11 indexes. Harmless as written, because the tables
are empty at creation time. Note for any *later* rebuild: tempdb is 9 × 1,800 MB with **8 MB
autogrowth**, so `SORT_IN_TEMPDB = ON` is currently the riskier choice — fix tempdb sizing and
growth increments first.

**I13 — Authentication method disagrees with the runbook.**
The PowerShell scripts use `Integrated Security=True` (Windows auth); the credentials supplied for
this engagement are SQL auth. Reconcile, and note the Agent service account will need the relevant
rights on both replicas.

**I14 — Progress metrics report an Id range as a row count.**
`$Rows = $LastId - $StartId`. With `IDENTITY` gaps (rollbacks, and any `READPAST` skips per C7) this
overstates progress. The inline comment acknowledges the caveat; `$BulkCopy.RowsCopied` is exact.

---

# SECURITY

## S1 — A sysadmin account with a trivially guessable password

The credentials supplied for this review (`LinkedServer` / `LinkedServer`, SQL auth) were verified to
hold:

```
is_sysadmin = 1, is_securityadmin = 1, is_dbcreator = 1   -- member of the sysadmin server role
```

This is full administrative control over a four-availability-group production cluster, behind a
password identical to the username. It is very likely also configured as a linked-server credential
somewhere, given the name — meaning it may be stored reversibly on other instances.

This is independent of the partitioning work, but it is the most severe issue found. Recommended:
rotate immediately, scope the replacement to the least privilege the scripts actually require
(`db_owner` on `eJarDbAuditing` plus `ALTER ANY DATABASE` for the `ADD FILE` operations — not
`sysadmin`), and audit where the current credential is embedded.

## S2 — Credentials transmitted in plaintext

The same credentials were pasted into this chat. Treat them as compromised and rotate regardless of
S1. For future reviews, a read-only login with `VIEW SERVER STATE`, `VIEW ANY DEFINITION` and
`db_datareader` is sufficient for everything this review needed.

---

# Recommended sequence

The plan's *goal* — bound the growth of a 772 GB audit database — is right, and retention via
partition truncation is a sound mechanism. The problem is that the current scripts cannot execute
(C1, C2, C4), and would break the application if they did (C3, W1).

Suggested order:

**Phase 0 — cheap wins, no schema change, measurable in days**
1. Rotate the credential (S1).
2. Re-enable `Operation_IndexOptimize` for this database — statistics are currently stale (W13).
3. Set `OPTIMIZE_FOR_SEQUENTIAL_KEY = ON` on the existing clustered PKs and measure the effect on
   the 167 h of Buffer Latch wait (W2).
4. Drop the two provably unused indexes on `AbpEntityChangeSets` (I5).
5. Fix tempdb autogrowth from 8 MB to a fixed 256–512 MB (I12).

**Phase 1 — reclaim space in place, which is the actual constraint**
6. Agree the real retention policy with the business, for each table separately (W13).
7. Purge to that policy **in place**, in throttled batches, on the existing tables. This is the only
   route that creates the free space C1 requires.
8. Apply PAGE (not ROW) compression to the surviving data, measured per index.
9. Shrink `D:\Data\eJarDbAuditing.mdf` in stages, off-peak, then rebuild.

**Phase 2 — partition, once it fits**
10. Fix C2, C3, C4, C5, C6, C7, C8, W5, W6 in the scripts.
11. Decide W1 explicitly: which indexes stay non-aligned, and what that costs the retention design.
12. Verify `D:\Data\` and free space on all three replicas (W6).
13. Add the missing cutover, reseed, reconciliation and rollback scripts (W7, W9).
14. Rehearse end-to-end on a restored copy — not on the clone, and not on production.

Happy to take any of these individually; C3 and C4 are the two I would fix first, since they are
small edits that turn a guaranteed outage into a merely risky deployment.
