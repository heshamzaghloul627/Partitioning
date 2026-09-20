/*==============================================================================
  01_TABLE_PartitionConfig.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  REVISED       : 2026-09-12 - aligned to the existing retention model in
                  [eJarDbReports].[Jobs].[PurgeLogs_eJar]

  Replaces the original 01_TABLE_PartitionFilePath.sql.

  ##############################################################################
  #  THE EXISTING RETENTION MODEL, AS MEASURED                                 #
  ##############################################################################

  [eJarDbReports].[Jobs].[PurgeLogs_eJar] is the live retention mechanism for
  eJarDbAuditing. It reaches across databases through SYNONYMS:

      eJarDbReports.dbo.Audit_dbo_AbpAuditLogs
          -> [eJarDbAuditing].[dbo].[AbpAuditLogs]
      eJarDbReports.dbo.Audit_dbo_AbpEntityChangeSets
          -> [eJarDbAuditing].[dbo].[AbpEntityChangeSets]
      eJarDbReports.dbo.Audit_dbo_AbpEntityChanges
          -> [eJarDbAuditing].[dbo].[AbpEntityChanges]
      eJarDbReports.dbo.Audit_dbo_AbpEntityPropertyChanges
          -> [eJarDbAuditing].[dbo].[AbpEntityPropertyChanges]

  (created 2022-10-09). That is why no job in eJarDbAuditing appeared to purge
  anything - the purge is driven from the reports database.

  Its policy, and the evidence that it is running:

   AbpAuditLogs - TWO TIERS split on a NON-PARTITIONING column:
       Exception IS NULL      ->  7 days   (cast to date, midnight-aligned)
       Exception IS NOT NULL  -> 30 days   (rolling timestamp)

     Confirmed by row distribution on 2026-09-12:
       2026-08-13 .. 2026-09-04   success_rows = 0,       error_rows ~15-57k/day
       2026-09-05 .. 2026-09-12   success_rows ~2.2M/day, error_rows ~17k/day
       MIN(ExecutionTime) = 2026-08-13  (exactly 30 days back)

   AbpEntityChangeSets / Changes / PropertyChanges:
       CreationTime < DATEADD(year,-1,...)  -> 12 months, PARENT-DRIVEN
     Children are deleted by navigating EntityChangeSetId / EntityChangeId, not
     by their own date columns.

     NOTE: this block only runs when @Type matches '%Entity%'. The invocation in
     use - @type='Audit,State' - SKIPS it, which is why data reaches back to
     2013-05-12.

  ##############################################################################
  #  WHAT THIS MEANS FOR PARTITIONING - AND WHY THERE ARE TWO RETENTION TIERS  #
  ##############################################################################

  Partition truncation is all-or-nothing on the partitioning column. You cannot
  express "delete successes after 7 days but keep errors for 30" by truncating
  partitions of ExecutionTime, because a partition holds both.

  So AbpAuditLogs uses a HYBRID, encoded in the two Retention* column pairs:

     RetentionUnits          = 30 DAYS  -> partition TRUNCATE + MERGE.
                                           Removes the error tail. Instant,
                                           minimally logged, reclaims space.
     SecondaryRetentionUnits =  7 DAYS  -> batched DELETE of rows matching
                               SecondaryPredicate ('Exception IS NULL'), scoped
                               with $PARTITION to one partition at a time.

  This reproduces the existing policy exactly, and is strictly cheaper than the
  current proc: today it does
      SELECT Id INTO #Scope FROM ... WHERE ExecutionTime < cutoff AND Exception IS NULL
  which scans the whole table. Scoped by $PARTITION it reads one day.

  ##############################################################################
  #  CLOCK: THE COLUMN VALUE IS USED AS-IS, NO CONVERSION                      #
  ##############################################################################

  Retention compares the stored column value directly against a cutoff. Nothing
  is converted, shifted or normalised - a row stamped 2026-09-14 10:00 is
  treated as 2026-09-14 10:00.

  The only decision is which clock "now" comes from, and it is explicit per set
  via ClockSource. Measured on SRV-AZ-AG002 at 2026-09-12 19:33:02 local:

      SYSDATETIME()     = 2026-09-12 19:33:02      (local, UTC+3)
      SYSUTCDATETIME()  = 2026-09-12 16:33:02
      MAX(AbpAuditLogs.ExecutionTime)        = 2026-09-12 16:33:02   <- UTC
      MAX(AbpEntityChanges.ChangeTime)       = 2026-09-12 16:33:02   <- UTC
      MAX(AbpEntityChangeSets.CreationTime)  = 2026-09-12 16:33:02   <- UTC

  The application writes UTC. HangFire corroborates it: every recurring job on
  this estate carries TimeZoneId = 'UTC'.

  ClockSource therefore defaults to 'UTC', so cutoff and column are in the same
  frame. You asked that local-vs-UTC not matter, and for the *column* it does
  not - it is read verbatim. It does matter for "now", by exactly 180 minutes:

      PurgeLogs_eJar uses GETDATE() (LOCAL) against a UTC column, so its cutoff
      sits 3 hours later than the stated policy and it deletes 3 hours MORE than
      7 / 30 days. Harmless at monthly granularity; at DAILY granularity it
      shifts the boundary into a day you meant to keep.

  Set ClockSource = 'LOCAL' if you would rather reproduce that 3-hour skew
  bug-for-bug. The default does not.
==============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE eJarDbAuditing;
GO

IF SCHEMA_ID('PartitionConfiguration') IS NULL
    EXEC ('CREATE SCHEMA [PartitionConfiguration]');
GO

/*------------------------------------------------------------------------------
  Drop and recreate if the pre-2026-09-12 shape is present, so the new columns
  and the DAY granularity are picked up.
------------------------------------------------------------------------------*/
IF OBJECT_ID('PartitionConfiguration.PartitionSet') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.columns
                   WHERE object_id = OBJECT_ID('PartitionConfiguration.PartitionSet')
                     AND name = 'ClockSource')
BEGIN
    PRINT 'Upgrading PartitionConfiguration.PartitionSet to the 2026-09-12 shape.';
    DROP TABLE PartitionConfiguration.PartitionSet;
END
GO

IF OBJECT_ID('PartitionConfiguration.PartitionSet') IS NULL
BEGIN
    CREATE TABLE PartitionConfiguration.PartitionSet
    (
          SetName                 SYSNAME        NOT NULL
        , PartitionFunction       SYSNAME        NOT NULL
        , PartitionScheme         SYSNAME        NOT NULL
        , Granularity             VARCHAR(10)    NOT NULL
        , FilegroupPrefix         VARCHAR(20)    NOT NULL

          /* PER_PARTITION : one filegroup + file per partition. Lets retention
                             hand space back to the OS, and lets you mark old
                             partitions READ_ONLY. Right for slow-churn monthly.
             SHARED        : every partition maps to SharedFilegroup. Truncated
                             space is reused in place rather than returned, so
                             the filegroup settles at a steady size. Right for
                             DAILY, where PER_PARTITION would mean ~60 files
                             being created and dropped continuously - and every
                             ADD FILE / REMOVE FILE is redone on both
                             secondaries of a SYNCHRONOUS_COMMIT AG.           */
        , FilegroupMode           VARCHAR(15)    NOT NULL
        , SharedFilegroup         SYSNAME        NULL

        , DataPath                NVARCHAR(260)  NOT NULL

          /* Primary tier - drives partition TRUNCATE + MERGE. */
        , RetentionUnits          INT            NOT NULL

          /* Secondary tier - batched DELETE for a policy that splits on a
             non-partitioning column. NULL = not used.                         */
        , SecondaryRetentionUnits INT            NULL
        , SecondaryPredicate      NVARCHAR(500)  NULL

          /* 'UTC' or 'LOCAL' - which clock "now" comes from. See header. */
        , ClockSource             VARCHAR(5)     NOT NULL

          /* How far ahead to provision, expressed in the SAME unit as
             Granularity. Deliberately not "months ahead": at DAY granularity a
             3-month lookahead would create ~90 partitions and reintroduce the
             all-partition-probe cost that moving off the original 253-partition
             design was meant to remove.                                       */
        , AheadUnits              INT            NOT NULL
          CONSTRAINT DF_PartitionSet_AheadUnits DEFAULT (3)

        , CONSTRAINT PK_PartitionSet       PRIMARY KEY CLUSTERED (SetName)
        , CONSTRAINT UQ_PartitionSet_Func  UNIQUE (PartitionFunction)
        , CONSTRAINT CK_PartitionSet_Gran  CHECK (Granularity IN ('DAY','WEEK','MONTH'))
        , CONSTRAINT CK_PartitionSet_Ret   CHECK (RetentionUnits > 0)
        , CONSTRAINT CK_PartitionSet_Ret2  CHECK (SecondaryRetentionUnits IS NULL
                                                  OR SecondaryRetentionUnits > 0)
        , CONSTRAINT CK_PartitionSet_Path  CHECK (RIGHT(DataPath,1) = '\')
        , CONSTRAINT CK_PartitionSet_Clock CHECK (ClockSource IN ('UTC','LOCAL'))
        , CONSTRAINT CK_PartitionSet_FgMode CHECK (FilegroupMode IN ('PER_PARTITION','SHARED'))
          /* SHARED needs a target filegroup; PER_PARTITION must not have one. */
        , CONSTRAINT CK_PartitionSet_FgShared CHECK
            ((FilegroupMode = 'SHARED'        AND SharedFilegroup IS NOT NULL)
          OR (FilegroupMode = 'PER_PARTITION' AND SharedFilegroup IS NULL))
          /* A secondary tier is meaningless without a predicate, and must be
             shorter than the primary tier or it would never fire.             */
        , CONSTRAINT CK_PartitionSet_Ret2Pair CHECK
            ((SecondaryRetentionUnits IS NULL     AND SecondaryPredicate IS NULL)
          OR (SecondaryRetentionUnits IS NOT NULL AND SecondaryPredicate IS NOT NULL
              AND SecondaryRetentionUnits < RetentionUnits))
    );
END
GO

/*------------------------------------------------------------------------------
  Seed / update. MERGE keeps this re-runnable.
------------------------------------------------------------------------------*/
;WITH src (SetName, PartitionFunction, PartitionScheme, Granularity, FilegroupPrefix,
           FilegroupMode, SharedFilegroup, DataPath, RetentionUnits,
           SecondaryRetentionUnits, SecondaryPredicate, ClockSource, AheadUnits) AS
(
    /*--------------------------------------------------------------------------
      AbpEntityChangeSets / AbpEntityChanges / AbpEntityPropertyChanges
      MONTHLY, 12 months - matches PurgeLogs_eJar's DATEADD(year,-1,...).
      One filegroup per month: ~3.5 GB each, slow churn, and old months can be
      marked READ_ONLY to drop them out of differential backups.
    --------------------------------------------------------------------------*/
    SELECT 'Auditing',  'PF_Auditing_Monthly', 'PS_Auditing_Monthly', 'MONTH',
           'FG_AUD', 'PER_PARTITION', NULL, N'D:\Data\',
           12, NULL, NULL, 'UTC', 3

    UNION ALL
    /*--------------------------------------------------------------------------
      AbpAuditLogs
      DAILY, as requested. Two tiers, reproducing PurgeLogs_eJar exactly:
          30 days -> TRUNCATE + MERGE the partition   (the Exception tail)
           7 days -> batched DELETE of Exception IS NULL within a partition

      Volume measured 2026-09-12: ~2.2M success + ~17k error rows/day, ~1.7 KB
      per row. So a fresh daily partition is ~3.7 GB and, once the 7-day success
      purge has passed over it, ~29 MB. Steady state ~27-30 GB.

      AheadUnits = 14 DAYS (not 3 months). 30 retention + 14 ahead + the
      catch-all and trailing partitions is ~46 partitions. A 3-month lookahead
      would be ~120, which is the all-partition-probe problem all over again.
      14 days is ample headroom for a job that runs daily.

      SHARED filegroup: at PER_PARTITION this set would create and drop a
      filegroup and file every single day, and every one of those is redone on
      both AG secondaries. Truncated space is instead reused inside
      FG_LOG_DATA, which settles at ~30 GB.
    --------------------------------------------------------------------------*/
    SELECT 'AuditLogs', 'PF_AuditLogs_Daily', 'PS_AuditLogs_Daily', 'DAY',
           'FG_LOG', 'SHARED', 'FG_LOG_DATA', N'D:\Data\',
           30, 7, N'Exception IS NULL', 'UTC', 14
)
MERGE PartitionConfiguration.PartitionSet AS tgt
USING src ON tgt.SetName = src.SetName
WHEN MATCHED THEN UPDATE SET
      tgt.PartitionFunction       = src.PartitionFunction
    , tgt.PartitionScheme         = src.PartitionScheme
    , tgt.Granularity             = src.Granularity
    , tgt.FilegroupPrefix         = src.FilegroupPrefix
    , tgt.FilegroupMode           = src.FilegroupMode
    , tgt.SharedFilegroup         = src.SharedFilegroup
    , tgt.DataPath                = src.DataPath
    , tgt.RetentionUnits          = src.RetentionUnits
    , tgt.SecondaryRetentionUnits = src.SecondaryRetentionUnits
    , tgt.SecondaryPredicate      = src.SecondaryPredicate
    , tgt.ClockSource             = src.ClockSource
    , tgt.AheadUnits             = src.AheadUnits
WHEN NOT MATCHED BY TARGET THEN
    INSERT (SetName, PartitionFunction, PartitionScheme, Granularity, FilegroupPrefix,
            FilegroupMode, SharedFilegroup, DataPath, RetentionUnits,
            SecondaryRetentionUnits, SecondaryPredicate, ClockSource, AheadUnits)
    VALUES (src.SetName, src.PartitionFunction, src.PartitionScheme, src.Granularity,
            src.FilegroupPrefix, src.FilegroupMode, src.SharedFilegroup, src.DataPath,
            src.RetentionUnits, src.SecondaryRetentionUnits, src.SecondaryPredicate,
            src.ClockSource, src.AheadUnits);
GO

SELECT SetName, Granularity, RetentionUnits,
       SecondaryRetentionUnits, SecondaryPredicate,
       ClockSource, FilegroupMode, SharedFilegroup, AheadUnits
FROM PartitionConfiguration.PartitionSet
ORDER BY SetName;
GO

/*------------------------------------------------------------------------------
  RETENTION POLICY - the seeded values mirror PurgeLogs_eJar. Change here, in
  one place, rather than in the procs:

      UPDATE PartitionConfiguration.PartitionSet
         SET RetentionUnits = 18                       -- months
       WHERE SetName = 'Auditing';

      UPDATE PartitionConfiguration.PartitionSet
         SET RetentionUnits = 60, SecondaryRetentionUnits = 14   -- days
       WHERE SetName = 'AuditLogs';

  Two things to settle with the business, both of which this seeding deliberately
  does NOT decide for you:

  1. The 12-month entity retention has never actually run (@type='Audit,State'
     skips it), so data goes back to 2013-05-12. Enabling it removes ~82-85% of
     the three change tables. That is the whole point of the exercise - but it
     is a large, irreversible first deletion. Confirm it is wanted.

  2. AbpAuditLogs at 7/30 days is already being enforced manually, so no change
     in behaviour there. Note that nothing SCHEDULES it: there is no SQL Agent
     job and no HangFire recurring job that calls PurgeLogs_eJar. Retention on
     this estate is a manual command someone remembers to run.
------------------------------------------------------------------------------*/
