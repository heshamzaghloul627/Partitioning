/*==============================================================================
  02_AbpEntityChangeSets_Clone_table_creation.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  PARTITION SET : Auditing  ->  PS_Auditing_Monthly (CreationTime), monthly

  Table + clustered index only. Nonclustered indexes are created post-load by
  03_Post Migration/02_Create_Nonclustered_Indexes.sql. See
  01_AbpAuditLogs_Clone_table_creation.sql for the full rationale on
  PAGE compression (W3), OPTIMIZE_FOR_SEQUENTIAL_KEY (W2) and removing
  [FMonth] (I3).

  Measured PAGE compression for this table: 47.15 GB -> 11.13 GB (-76%).
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

IF OBJECT_ID('dbo.AbpEntityChangeSets_Clone', 'U') IS NOT NULL
BEGIN
    RAISERROR('dbo.AbpEntityChangeSets_Clone already exists. Drop it deliberately before re-running.', 16, 1);
    SET NOEXEC ON;
END
GO

/*==============================================================================
  1. TABLE   (column types verified against the live schema 2026-08-29)
==============================================================================*/
CREATE TABLE dbo.AbpEntityChangeSets_Clone
(
      [Id]                   BIGINT         IDENTITY(1,1) NOT NULL
    , [BrowserInfo]          NVARCHAR(512)  NULL
    , [ClientIpAddress]      NVARCHAR(64)   NULL
    , [ClientName]           NVARCHAR(128)  NULL
    , [CreationTime]         DATETIME2(7)   NOT NULL
    , [ExtensionData]        NVARCHAR(MAX)  NULL
    , [ImpersonatorTenantId] INT            NULL
    , [ImpersonatorUserId]   BIGINT         NULL
    , [Reason]               NVARCHAR(256)  NULL
    , [TenantId]             INT            NULL
    , [UserId]               BIGINT         NULL
    , CONSTRAINT PK_AbpEntityChangeSets_Clone PRIMARY KEY NONCLUSTERED
      (
            [Id]           ASC
          , [CreationTime] ASC
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
      ON PS_Auditing_Monthly ([CreationTime])
)
ON PS_Auditing_Monthly ([CreationTime])
WITH (DATA_COMPRESSION = PAGE);
GO

/*==============================================================================
  2. CLUSTERED INDEX
==============================================================================*/
CREATE CLUSTERED INDEX IX_AbpEntityChangeSets_Clone_CreationTime_Id
ON dbo.AbpEntityChangeSets_Clone
(
      [CreationTime] ASC
    , [Id]           ASC
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
ON PS_Auditing_Monthly ([CreationTime]);
GO

SET NOEXEC OFF;
GO
PRINT 'Created: dbo.AbpEntityChangeSets_Clone (table + clustered index).';
GO
