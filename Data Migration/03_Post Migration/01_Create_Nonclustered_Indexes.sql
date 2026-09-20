/*==============================================================================
  01_Create_Nonclustered_Indexes.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  RUN WHEN      : after Run-BulkLoad.ps1 and Run-Delta.ps1 report zero deltas,
                  BEFORE 02_Cutover.sql.

  The clone tables were created with their CLUSTERED index only. This script adds
  the nonclustered indexes once, over already-loaded data (W7) - far cheaper in
  time and transaction log than maintaining them row-by-row through a load of
  ~300M rows, especially on a SYNCHRONOUS_COMMIT AG where log growth stalls
  commits for every database in SQLAG02.

  ##############################################################################
  #  W1 - READ THIS BEFORE CHANGING ANY "ON PS_..." CLAUSE                     #
  ##############################################################################

  Every index here is partition-ALIGNED. That is not a preference, it is a hard
  requirement. From the TRUNCATE TABLE documentation:

      "To truncate a partitioned table, the table and indexes must be aligned
       (partitioned on the same partition function)."

  The same applies to ALTER TABLE ... SWITCH. So if you de-align any index to
  speed up a lookup, you lose partition-level TRUNCATE and SWITCH - which is the
  entire retention mechanism. There is no configuration in which you get both.

  The residual cost, stated plainly: an index whose leading key is NOT the
  partitioning column cannot eliminate partitions, so a lookup on that key must
  probe every partition. Three indexes below are in that position:

      IX_AbpEntityChanges_EntityChangeSetId          (EntityChangeSetId)
      IX_AbpEntityChanges_EntityId_EntityTypeFullName (EntityId, ...)
      IX_AbpEntityPropertyChanges_EntityChangeId     (EntityChangeId)

  This was mitigated structurally rather than by de-aligning, by cutting the
  partition count on the three change-tracking tables from 253 to ~16 (monthly
  instead of 4-per-month) - a ~16x reduction in probe fan-out.

  AbpAuditLogs is on its OWN function at DAILY granularity (~46 partitions,
  30 days retention + 14 ahead), so its reduction is ~5.5x rather than ~16x.
  That is the right trade for this table: daily is required to express its 7-day
  success / 30-day error policy, and its Id-seek traffic is negligible next to
  the change tables - 10,520 seeks in 31 days versus 1,863,267 on
  PK_AbpEntityChanges. The partitions that matter for probe cost are the monthly
  ones, and those are ~16.

  It is not eliminated. Measured on the primary over 31 days, seeks by Id on the
  clustered PKs are the dominant index operation - PK_AbpEntityChanges 1,863,267
  and PK_AbpEntityChangeSets 1,631,311 - and those are EF resolving parent rows
  during audit WRITES, not user searches. Load-test the write path before
  go-live; this is the change most likely to surprise you.
==============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE eJarDbAuditing;
GO

IF SERVERPROPERTY('IsHadrEnabled') = 1
   AND ISNULL(sys.fn_hadr_is_primary_replica(DB_NAME()), 0) <> 1
BEGIN
    RAISERROR('Not the primary replica for %s. Connect to SRV-AZ-AG002.', 16, 1, 'eJarDbAuditing');
    SET NOEXEC ON;
END
GO

/*------------------------------------------------------------------------------
  Build options used throughout, and why:

    DATA_COMPRESSION = PAGE   measured 65% smaller overall; Buffer IO was the
                              largest single wait at 195.14 h (W3)
    ONLINE = OFF              the clone is not in use by the application yet, so
                              an offline build is correct and much faster
    SORT_IN_TEMPDB = OFF      tempdb is 9 x 1800 MB with 8 MB autogrowth (I12).
                              Turn this ON only after tempdb sizing is fixed.
    MAXDOP = 8                matches the instance setting; the box has 32 cores
    OPTIMIZE_FOR_SEQUENTIAL_KEY  omitted on non-ascending-key indexes, where it
                              has no effect; set ON where the leading key is the
                              ascending date column (W2)
------------------------------------------------------------------------------*/

/*==============================================================================
  AbpAuditLogs_Clone   ->  PS_AuditLogs_Daily (ExecutionTime)
==============================================================================*/
PRINT 'AbpAuditLogs_Clone: IX_AbpAuditLogs_Clone_ExecutionTime_Exception';
CREATE NONCLUSTERED INDEX IX_AbpAuditLogs_Clone_ExecutionTime_Exception
ON dbo.AbpAuditLogs_Clone ([ExecutionTime] ASC)
INCLUDE ([Exception], [TenantId], [MethodName], [ExecutionDuration], [TraceId])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8,
      OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
ON PS_AuditLogs_Daily ([ExecutionTime]);
GO

/*==============================================================================
  AbpEntityChangeSets_Clone   ->  PS_Auditing_Monthly (CreationTime)
==============================================================================*/
PRINT 'AbpEntityChangeSets_Clone: IX_AbpEntityChangeSets_Clone_CreationTime';
CREATE NONCLUSTERED INDEX IX_AbpEntityChangeSets_Clone_CreationTime
ON dbo.AbpEntityChangeSets_Clone ([CreationTime] ASC)
INCLUDE ([TenantId])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8,
      OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
ON PS_Auditing_Monthly ([CreationTime]);
GO

/*------------------------------------------------------------------------------
  I5 - IX_AbpEntityChangeSets_UserId IS DELIBERATELY NOT CREATED.

  Measured on the PRIMARY over the 31 days 2026-07-29 to 2026-08-29:

      IX_AbpEntityChangeSets_UserId        user_seeks = 0   user_scans = 0
                                           user_updates = 1,628,742

  Zero reads, 1.6M writes. It is pure overhead on the hot insert path, and this
  is the table whose inserts already average 554 ms.

  CAVEAT: 31 days may not cover a quarterly or annual report that filters by
  UserId. If such a report exists, uncomment this block. It is cheap to add
  later and expensive to carry if unused.

CREATE NONCLUSTERED INDEX IX_AbpEntityChangeSets_Clone_UserId
ON dbo.AbpEntityChangeSets_Clone ([UserId] ASC, [TenantId] ASC)
INCLUDE ([CreationTime])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8)
ON PS_Auditing_Monthly ([CreationTime]);
GO
------------------------------------------------------------------------------*/

/*==============================================================================
  AbpEntityChanges_Clone   ->  PS_Auditing_Monthly (ChangeTime)
==============================================================================*/
PRINT 'AbpEntityChanges_Clone: IX_AbpEntityChanges_Clone_ChangeTime_EntityTypeFullName';
CREATE NONCLUSTERED INDEX IX_AbpEntityChanges_Clone_ChangeTime_EntityTypeFullName
ON dbo.AbpEntityChanges_Clone ([ChangeTime] ASC, [EntityTypeFullName] ASC)
INCLUDE ([EntityChangeSetId], [TenantId], [ChangeType], [EntityId])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8,
      OPTIMIZE_FOR_SEQUENTIAL_KEY = ON)
ON PS_Auditing_Monthly ([ChangeTime]);
GO

/* Leading key is not the partitioning column - see the W1 note in the header.
   ChangeTime is listed explicitly in INCLUDE rather than left to SQL Server to
   append implicitly, so the definition documents its own true shape.          */
PRINT 'AbpEntityChanges_Clone: IX_AbpEntityChanges_Clone_EntityChangeSetId';
CREATE NONCLUSTERED INDEX IX_AbpEntityChanges_Clone_EntityChangeSetId
ON dbo.AbpEntityChanges_Clone ([EntityChangeSetId] ASC)
INCLUDE ([ChangeTime])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8)
ON PS_Auditing_Monthly ([ChangeTime]);
GO

PRINT 'AbpEntityChanges_Clone: IX_AbpEntityChanges_Clone_EntityId_EntityTypeFullName';
CREATE NONCLUSTERED INDEX IX_AbpEntityChanges_Clone_EntityId_EntityTypeFullName
ON dbo.AbpEntityChanges_Clone ([EntityId] ASC, [EntityTypeFullName] ASC)
INCLUDE ([EntityChangeSetId], [TenantId], [ChangeTime])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8)
ON PS_Auditing_Monthly ([ChangeTime]);
GO

/*==============================================================================
  AbpEntityPropertyChanges_Clone   ->  PS_Auditing_Monthly (ChangeTime)
  1.28 billion rows. This is the longest build in the script.
==============================================================================*/
PRINT 'AbpEntityPropertyChanges_Clone: IX_AbpEntityPropertyChanges_Clone_EntityChangeId';
CREATE NONCLUSTERED INDEX IX_AbpEntityPropertyChanges_Clone_EntityChangeId
ON dbo.AbpEntityPropertyChanges_Clone ([EntityChangeId] ASC)
INCLUDE ([TenantId], [ChangeTime])
WITH (DATA_COMPRESSION = PAGE, ONLINE = OFF, SORT_IN_TEMPDB = OFF, MAXDOP = 8)
ON PS_Auditing_Monthly ([ChangeTime]);
GO

/*==============================================================================
  Statistics. Index creation gives fully-scanned stats for the index keys, but
  the column-level stats the optimizer will want are not there yet, and the
  Ola Hallengren job that would normally do this (Operation_IndexOptimize) is
  currently DISABLED for this database (W13).
==============================================================================*/
PRINT 'Updating statistics with FULLSCAN...';
UPDATE STATISTICS dbo.AbpAuditLogs_Clone             WITH FULLSCAN;
UPDATE STATISTICS dbo.AbpEntityChangeSets_Clone      WITH FULLSCAN;
UPDATE STATISTICS dbo.AbpEntityChanges_Clone         WITH FULLSCAN;
UPDATE STATISTICS dbo.AbpEntityPropertyChanges_Clone WITH FULLSCAN;
GO

SET NOEXEC OFF;
GO

/*==============================================================================
  Verify: every index on every clone table must be aligned to its scheme.
  Anything returned here breaks TRUNCATE-based retention.
==============================================================================*/
SELECT OBJECT_NAME(i.object_id) AS table_name,
       i.name                   AS index_name,
       i.type_desc,
       ISNULL(ps.name, 'NOT PARTITIONED -- BREAKS RETENTION') AS partition_scheme
FROM sys.indexes i
LEFT JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
WHERE OBJECT_NAME(i.object_id) LIKE 'Abp%_Clone'
  AND i.type > 0
ORDER BY table_name, i.index_id;
GO

SELECT table_name, index_name, partition_scheme
FROM (
    SELECT OBJECT_NAME(i.object_id) AS table_name, i.name AS index_name,
           ps.name AS partition_scheme
    FROM sys.indexes i
    LEFT JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
    WHERE OBJECT_NAME(i.object_id) LIKE 'Abp%_Clone' AND i.type > 0
) x
WHERE partition_scheme IS NULL;
GO
