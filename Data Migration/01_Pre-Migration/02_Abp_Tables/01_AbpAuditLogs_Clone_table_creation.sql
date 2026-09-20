/*==============================================================================
  01_AbpAuditLogs_Clone_table_creation.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  PARTITION SET : AuditLogs  ->  PS_AuditLogs_Daily (ExecutionTime), DAILY
  REVISED       : 2026-09-12 - daily partitions (was weekly), on a single shared
                               filegroup FG_LOG_DATA

  Daily granularity is required by the retention policy this table actually has.
  [eJarDbReports].[Jobs].[PurgeLogs_eJar] enforces, via synonyms onto this table:
      Exception IS NULL      ->  7 days
      Exception IS NOT NULL  -> 30 days
  A 7-day rule cannot be expressed on weekly partitions at all.

  Note the partition scheme maps every partition to ONE filegroup (FG_LOG_DATA)
  rather than one per partition. At ~46 live partitions turning over daily,
  per-partition files would mean a filegroup and file created and dropped every
  day, each replayed on both AG secondaries. Truncated space is instead reused
  inside FG_LOG_DATA, which settles at ~30 GB.

  Only the table and its CLUSTERED index are created here. The nonclustered
  indexes are created AFTER the bulk load by
  03_Post Migration/02_Create_Nonclustered_Indexes.sql.

  Why: loading into a table that already carries its nonclustered indexes logs
  index maintenance for every row. Across these four tables the nonclustered
  indexes are 260 GB of the 733 GB footprint, so building them once after the
  load is substantially cheaper in both time and transaction log - which matters
  because this database is in a SYNCHRONOUS_COMMIT AG and log growth stalls
  commits for every database in SQLAG02 (W7).

  ------------------------------------------------------------------------------
  Fixes carried in this file
  ------------------------------------------------------------------------------
  W2  OPTIMIZE_FOR_SEQUENTIAL_KEY = ON (was OFF on all 11 indexes).
      Query Store, 31 days, these four tables: Buffer Latch = 167.05 hours -
      textbook last-page insert contention on an ascending key. This SQL 2019
      option exists specifically to relieve that convoy, and the new clustered
      index on (ExecutionTime, Id) is also strictly ascending.

  W3  DATA_COMPRESSION = PAGE (was ROW). Measured with
      sp_estimate_data_compression_savings on 2026-08-29:
          AbpAuditLogs              27.34 GB -> 22.25 GB  (-19%)
          AbpEntityChangeSets       47.15 GB -> 11.13 GB  (-76%)
          AbpEntityChanges         269.31 GB -> 52.59 GB  (-80%)
          AbpEntityPropertyChanges 389.07 GB -> 172.75 GB (-56%)
          TOTAL                   732.87 GB -> 258.72 GB  (-65%)
      Buffer IO was the single largest wait (195.14 h), so fewer pages is a
      direct win. AbpAuditLogs compresses poorly because most of its payload is
      nvarchar(max); PAGE is still no worse than ROW here.

  I3  The [FMonth] persisted computed column is REMOVED. It was added to all
      four tables and used by no index, no partition function and no query -
      pure storage plus per-insert CPU, and schema drift the EF Core model does
      not know about. It also changed what SELECT * returns, which matters for
      the dependent view dbo.AbpAuditLogs_Lite (W10).
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

IF OBJECT_ID('dbo.AbpAuditLogs_Clone', 'U') IS NOT NULL
BEGIN
    RAISERROR('dbo.AbpAuditLogs_Clone already exists. Drop it deliberately before re-running.', 16, 1);
    SET NOEXEC ON;
END
GO

/*==============================================================================
  1. TABLE
  ------------------------------------------------------------------------------
  Column types verified against the live schema on 2026-08-29 - all match.

  The PRIMARY KEY is NONCLUSTERED on (Id, ExecutionTime) rather than CLUSTERED
  on (Id). This is mandatory, not stylistic: a UNIQUE index on a partitioned
  table must contain the partitioning column in its key.

  Trade-off you are accepting (I4): (Id, ExecutionTime) being unique does not
  by itself guarantee Id alone is unique. Id is IDENTITY so collisions will not
  arise in practice, and EF Core still treats Id as the model key - but it is a
  real weakening of the constraint and should be a conscious sign-off.
==============================================================================*/
CREATE TABLE dbo.AbpAuditLogs_Clone
(
      [Id]                   BIGINT         IDENTITY(1,1) NOT NULL
    , [TenantId]             INT            NULL
    , [UserId]               BIGINT         NULL
    , [ServiceName]          NVARCHAR(MAX)  NULL
    , [MethodName]           NVARCHAR(MAX)  NULL
    , [Parameters]           NVARCHAR(MAX)  NULL
    , [ReturnValue]          NVARCHAR(MAX)  NULL
    , [ExecutionTime]        DATETIME2(7)   NOT NULL
    , [ExecutionDuration]    INT            NOT NULL
    , [ClientIpAddress]      NVARCHAR(MAX)  NULL
    , [ClientName]           NVARCHAR(MAX)  NULL
    , [BrowserInfo]          NVARCHAR(MAX)  NULL
    , [Exception]            NVARCHAR(MAX)  NULL
    , [ImpersonatorUserId]   BIGINT         NULL
    , [ImpersonatorTenantId] INT            NULL
    , [CustomData]           NVARCHAR(MAX)  NULL
    , [ExceptionMessage]     NVARCHAR(MAX)  NULL
    , [TraceId]              NVARCHAR(MAX)  NULL
    , CONSTRAINT PK_AbpAuditLogs_Clone PRIMARY KEY NONCLUSTERED
      (
            [Id]            ASC
          , [ExecutionTime] ASC
      )
      WITH (
            DATA_COMPRESSION            = PAGE
          , PAD_INDEX                   = OFF
          , STATISTICS_NORECOMPUTE      = OFF
          , IGNORE_DUP_KEY              = OFF
          , ALLOW_ROW_LOCKS             = ON
          , ALLOW_PAGE_LOCKS            = ON
          , OPTIMIZE_FOR_SEQUENTIAL_KEY = ON
      )
      ON PS_AuditLogs_Daily ([ExecutionTime])
)
ON PS_AuditLogs_Daily ([ExecutionTime])
WITH (DATA_COMPRESSION = PAGE);
GO

/*==============================================================================
  2. CLUSTERED INDEX
==============================================================================*/
CREATE CLUSTERED INDEX IX_AbpAuditLogs_Clone_ExecutionTime_Id
ON dbo.AbpAuditLogs_Clone
(
      [ExecutionTime] ASC
    , [Id]            ASC
)
WITH (
      DATA_COMPRESSION            = PAGE
    , PAD_INDEX                   = OFF
    , STATISTICS_NORECOMPUTE      = OFF
    , SORT_IN_TEMPDB              = OFF   -- tempdb is 9 x 1800 MB with 8 MB
                                          -- autogrowth; see I12. Revisit once
                                          -- tempdb growth is fixed.
    , DROP_EXISTING               = OFF
    , ONLINE                      = OFF   -- table is empty at this point
    , ALLOW_ROW_LOCKS             = ON
    , ALLOW_PAGE_LOCKS            = ON
    , OPTIMIZE_FOR_SEQUENTIAL_KEY = ON
)
ON PS_AuditLogs_Daily ([ExecutionTime]);
GO

SET NOEXEC OFF;
GO
PRINT 'Created: dbo.AbpAuditLogs_Clone (table + clustered index). '
    + 'Nonclustered indexes are created post-load.';
GO
