/*==============================================================================
  04_AbpEntityPropertyChanges_Clone_table_creation.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  PARTITION SET : Auditing  ->  PS_Auditing_Monthly (ChangeTime), monthly

  Largest table in the database: 1,277,745,190 rows / 389.07 GB.
  Measured PAGE compression: 389.07 GB -> 172.75 GB (-56%).

  Table + clustered index only. Nonclustered index is created post-load by
  03_Post Migration/02_Create_Nonclustered_Indexes.sql.

  ##############################################################################
  #  C3 - THE DEPLOYMENT-BLOCKING FIX IN THIS FILE                             #
  ##############################################################################

  The source table has NO date column of its own. [ChangeTime] is denormalised
  from the parent AbpEntityChanges row so this table can be partitioned and
  aged out in step with its parent.

  The original DDL declared it:

      [ChangeTime] [datetime2](7) NOT NULL          -- no default

  Verified against the live database on 2026-08-29:
    * dbo.AbpEntityPropertyChanges has 9 columns and no ChangeTime.
    * There are ZERO default constraints on any of the four Abp tables.
    * There are ZERO triggers that could have populated it.

  And the application's actual INSERT, taken from Query Store on the primary:

      INSERT INTO [AbpEntityPropertyChanges]
        ([EntityChangeId], [NewValue], [NewValueHash], [OriginalValue],
         [OriginalValueHash], [PropertyName], [PropertyTypeFullName], [TenantId])
      OUTPUT INSERTED.[Id] VALUES (@p16, ... , @p23)

  38,118 direct executions in 31 days, plus the batched
  "MERGE ... WHEN NOT MATCHED THEN INSERT" variants which use the same column
  list. None of them supply ChangeTime.

  So on cutover, EVERY application write to this table would have failed with
  Msg 515 "Cannot insert the value NULL into column 'ChangeTime'". ABP persists
  audit records inside the request pipeline, so this does not degrade
  gracefully - it breaks the application's write path.

  Fixed below with a DEFAULT constraint.

  ------------------------------------------------------------------------------
  SYSUTCDATETIME() IS CORRECT - VERIFIED 2026-09-12, NO LONGER AN ASSUMPTION
  ------------------------------------------------------------------------------
  Measured on SRV-AZ-AG002:

      SYSDATETIME()                          = 2026-09-12 19:33:02  (local, UTC+3)
      SYSUTCDATETIME()                       = 2026-09-12 16:33:02
      MAX(AbpAuditLogs.ExecutionTime)        = 2026-09-12 16:33:02  <-- UTC
      MAX(AbpEntityChanges.ChangeTime)       = 2026-09-12 16:33:02  <-- UTC
      MAX(AbpEntityChangeSets.CreationTime)  = 2026-09-12 16:33:02  <-- UTC

  The application writes UTC. Corroborated independently: every HangFire
  recurring job on this estate carries TimeZoneId = 'UTC'.

  So the default matches what the app itself would have written, and a row's
  ChangeTime is directly comparable to its parent's. Do NOT change this to
  SYSDATETIME() - that would put new rows 3 hours ahead of every migrated row.

  ------------------------------------------------------------------------------
  ONE RESIDUAL DIFFERENCE, MEASURED AND ACCEPTED
  ------------------------------------------------------------------------------
  The default records INSERT time, not the parent's ChangeTime. Sampled 454,517
  parent/child pairs on 2026-09-12:

      ChangeTime is NEVER later than the parent's CreationTime (max skew 0 s)
      but can be up to 2.24 days EARLIER (min skew -193,637 s)
      different calendar day:   5 of 454,517  (0.001%)
      different calendar MONTH: 0 of 454,517

  At the MONTH granularity this table is partitioned on, the two are equivalent
  in practice. If exact parent-time fidelity is ever required, that needs an
  application change to pass the value explicitly - a schema default cannot
  provide it.
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

IF OBJECT_ID('dbo.AbpEntityPropertyChanges_Clone', 'U') IS NOT NULL
BEGIN
    RAISERROR('dbo.AbpEntityPropertyChanges_Clone already exists. Drop it deliberately before re-running.', 16, 1);
    SET NOEXEC ON;
END
GO

/*==============================================================================
  1. TABLE   (column types verified against the live schema 2026-08-29)
==============================================================================*/
CREATE TABLE dbo.AbpEntityPropertyChanges_Clone
(
      [Id]                   BIGINT        IDENTITY(1,1) NOT NULL
    , [EntityChangeId]       BIGINT        NOT NULL
    , [NewValue]             NVARCHAR(512) NULL
    , [OriginalValue]        NVARCHAR(512) NULL
    , [PropertyName]         NVARCHAR(96)  NULL
    , [PropertyTypeFullName] NVARCHAR(192) NULL
    , [TenantId]             INT           NULL
    , [NewValueHash]         NVARCHAR(MAX) NULL
    , [OriginalValueHash]    NVARCHAR(MAX) NULL

      -- C3: denormalised partitioning column. MUST have a default; see header.
    , [ChangeTime]           DATETIME2(7)  NOT NULL
      CONSTRAINT DF_AbpEntityPropertyChanges_Clone_ChangeTime
      DEFAULT (SYSUTCDATETIME())

    , CONSTRAINT PK_AbpEntityPropertyChanges_Clone PRIMARY KEY NONCLUSTERED
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
CREATE CLUSTERED INDEX IX_AbpEntityPropertyChanges_Clone_ChangeTime_Id
ON dbo.AbpEntityPropertyChanges_Clone
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

/*==============================================================================
  3. VERIFY THE C3 FIX. This must return exactly one row.
     If it returns nothing, STOP - the application will not be able to write.
==============================================================================*/
SELECT c.name                AS column_name
     , dc.name               AS default_constraint
     , dc.definition
FROM sys.columns c
JOIN sys.default_constraints dc ON c.default_object_id = dc.object_id
WHERE c.object_id = OBJECT_ID('dbo.AbpEntityPropertyChanges_Clone')
  AND c.name = 'ChangeTime';
GO

PRINT 'Created: dbo.AbpEntityPropertyChanges_Clone (table + clustered index).';
PRINT 'Confirm the DEFAULT constraint above is present before proceeding.';
GO
