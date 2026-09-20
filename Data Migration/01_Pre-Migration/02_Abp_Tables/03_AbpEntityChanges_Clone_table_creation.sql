/*==============================================================================
  03_AbpEntityChanges_Clone_table_creation.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  PARTITION SET : Auditing  ->  PS_Auditing_Monthly (ChangeTime), monthly

  Table + clustered index only. Nonclustered indexes are created post-load by
  03_Post Migration/02_Create_Nonclustered_Indexes.sql. See
  01_AbpAuditLogs_Clone_table_creation.sql for the full rationale on
  PAGE compression (W3), OPTIMIZE_FOR_SEQUENTIAL_KEY (W2) and removing
  [FMonth] (I3).

  Measured PAGE compression for this table: 269.31 GB -> 52.59 GB (-80%),
  the best ratio of the four. Its three nonclustered indexes are 193.64 GB
  today and compress to roughly 38 GB.
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

IF OBJECT_ID('dbo.AbpEntityChanges_Clone', 'U') IS NOT NULL
BEGIN
    RAISERROR('dbo.AbpEntityChanges_Clone already exists. Drop it deliberately before re-running.', 16, 1);
    SET NOEXEC ON;
END
GO

/*==============================================================================
  1. TABLE   (column types verified against the live schema 2026-08-29)
==============================================================================*/
CREATE TABLE dbo.AbpEntityChanges_Clone
(
      [Id]                  BIGINT        IDENTITY(1,1) NOT NULL
    , [ChangeTime]          DATETIME2(7)  NOT NULL
    , [ChangeType]          TINYINT       NOT NULL
    , [EntityChangeSetId]   BIGINT        NOT NULL
    , [EntityId]            NVARCHAR(48)  NULL
    , [EntityTypeFullName]  NVARCHAR(192) NULL
    , [TenantId]            INT           NULL
    , CONSTRAINT PK_AbpEntityChanges_Clone PRIMARY KEY NONCLUSTERED
      (
            [Id]         ASC
          , [ChangeTime] ASC
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
      ON PS_Auditing_Monthly ([ChangeTime])
)
ON PS_Auditing_Monthly ([ChangeTime])
WITH (DATA_COMPRESSION = PAGE);
GO

/*==============================================================================
  2. CLUSTERED INDEX
==============================================================================*/
CREATE CLUSTERED INDEX IX_AbpEntityChanges_Clone_ChangeTime_Id
ON dbo.AbpEntityChanges_Clone
(
      [ChangeTime] ASC
    , [Id]         ASC
)
WITH (
      DATA_COMPRESSION            = PAGE
    , PAD_INDEX                   = OFF
    , STATISTICS_NORECOMPUTE      = OFF
    , SORT_IN_TEMPDB              = OFF
    , DROP_EXISTING               = OFF
    , ONLINE                      = OFF
    , ALLOW_ROW_LOCKS             = ON
    , ALLOW_PAGE_LOCKS            = ON
    , OPTIMIZE_FOR_SEQUENTIAL_KEY = ON
)
ON PS_Auditing_Monthly ([ChangeTime]);
GO

SET NOEXEC OFF;
GO
PRINT 'Created: dbo.AbpEntityChanges_Clone (table + clustered index).';
GO
