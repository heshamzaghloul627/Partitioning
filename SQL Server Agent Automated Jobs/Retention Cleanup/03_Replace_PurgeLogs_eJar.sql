/*==============================================================================
  03_Replace_PurgeLogs_eJar.sql
  ------------------------------------------------------------------------------
  TARGET DATABASE : eJarDbReports      (NOT eJarDbAuditing)
  TARGET SERVER   : SRV-AZ-AG002       (primary for BOTH eJarDbReports and
                                        eJarDbAuditing - verified 2026-09-12)
  RUN WHEN        : immediately after 02_Cutover.sql

  ##############################################################################
  #  WHY THIS FILE EXISTS                                                      #
  ##############################################################################

  [Jobs].[PurgeLogs_eJar] is the live retention mechanism for eJarDbAuditing. It
  operates through synonyms in eJarDbReports:

      Audit_dbo_AbpAuditLogs             -> [eJarDbAuditing].[dbo].[AbpAuditLogs]
      Audit_dbo_AbpEntityChangeSets      -> [eJarDbAuditing].[dbo].[AbpEntityChangeSets]
      Audit_dbo_AbpEntityChanges         -> [eJarDbAuditing].[dbo].[AbpEntityChanges]
      Audit_dbo_AbpEntityPropertyChanges -> [eJarDbAuditing].[dbo].[AbpEntityPropertyChanges]
      HangFire_State                     -> [eJarDbProd].[HangFire].[State]

  It is invoked by hand - there is no SQL Agent job and no HangFire recurring job
  that calls it (both checked on 2026-09-12).

  After partitioning, its Audit and Entity blocks would still work, but they would
  do the slowest possible thing: full-table #Scope scans feeding row-by-row
  DELETEs against tables that can now drop whole days and months as metadata.

  This replacement keeps the EXACT signature and call pattern you already use -

      EXEC [Jobs].[PurgeLogs_eJar] @Type = 'Audit,State', @Batch = 10000;

  - and delegates the audit work to the partition-aware proc in eJarDbAuditing.
  Nothing that calls it needs to change.

  ------------------------------------------------------------------------------
  BEHAVIOUR PRESERVED
  ------------------------------------------------------------------------------
    @Type matching '%Audit%'   -> AbpAuditLogs: 7-day success / 30-day error
    @Type matching '%Entity%'  -> change tracking: 12 months
    @Type matching '%state%'   -> HangFire.State: 30 days
    @Type NULL                 -> all three
    @Batch                     -> passed through as the DELETE batch size

  ------------------------------------------------------------------------------
  THREE BUGS IN THE ORIGINAL, FIXED HERE
  ------------------------------------------------------------------------------
  1. THE STATE PURGE HAS NEVER RUN. The original is:

         select Id into #ScopeState from HangFire_State with (nolock)
         where CreatedAt < dateadd(day,-30,getdate())
         create index rty on #ScopeState (Id)
         while @@ROWCOUNT > 0        <-- reads @@ROWCOUNT from CREATE INDEX

     CREATE INDEX is DDL and leaves @@ROWCOUNT = 0, so the loop body never
     executes. Evidence, measured 2026-09-12 on eJarDbProd:

         HangFire.State   1,842,143 rows   14.65 GB
         MIN(CreatedAt) = 2024-10-28       (policy says 30 days)

     Nearly two years of state under a 30-day policy. The Entity block avoids
     this by capturing @rc = @@ROWCOUNT BEFORE its CREATE INDEX statements; the
     State block simply forgot to. Fixed by capturing the row count first.

  2. LOCAL CLOCK AGAINST UTC COLUMNS. The original uses GETDATE(). Measured on
     SRV-AZ-AG002:

         SYSDATETIME()    = 2026-09-12 19:33:02   (local, UTC+3)
         SYSUTCDATETIME() = 2026-09-12 16:33:02
         MAX(ExecutionTime) = 2026-09-12 16:33:02  <- the app writes UTC

     So every cutoff sat 3 hours later than the stated policy and deleted 3 hours
     more than intended. Harmless at 1-year granularity, not harmless at 7 days
     against daily partitions. The audit path now derives its cutoff from
     PartitionConfiguration.PartitionSet.ClockSource ('UTC'). HangFire.State is
     left on GETDATE() because HangFire writes local time there - the fix is to
     compare like with like in each case, not to force one clock everywhere.

  3. HARD-CODED BATCH SIZE. The original had
         delete from Audit_dbo_AbpEntityChangeSets ... where id in (select top 10000 ...)
     in the middle of a proc that otherwise honours @Batch. Now consistent.

  Also inconsistent in the original and normalised here: the 7-day cutoff was
  CAST(... AS DATE) (midnight-aligned) while the 30-day cutoff was a rolling
  timestamp. Both are now handled by the partition logic, which is
  boundary-aligned by construction.
==============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE eJarDbReports;
GO

IF SERVERPROPERTY('IsHadrEnabled') = 1
   AND ISNULL(sys.fn_hadr_is_primary_replica(DB_NAME()), 0) <> 1
BEGIN
    RAISERROR('Not the primary replica for eJarDbReports. Connect to SRV-AZ-AG002.', 16, 1);
    SET NOEXEC ON;
END
GO

/*------------------------------------------------------------------------------
  Keep a copy of the original definition before replacing it. Cheap insurance -
  this proc is invoked by hand and by people, not from source control.
------------------------------------------------------------------------------*/
IF OBJECT_ID('Jobs.PurgeLogs_eJar_PrePartitioning', 'P') IS NULL
   AND OBJECT_ID('Jobs.PurgeLogs_eJar', 'P') IS NOT NULL
BEGIN
    DECLARE @orig NVARCHAR(MAX) =
        (SELECT m.definition FROM sys.sql_modules m WHERE m.object_id = OBJECT_ID('Jobs.PurgeLogs_eJar'));

    /* Re-create it verbatim under an archive name. */
    SET @orig = REPLACE(REPLACE(@orig,
                    'CREATE PROC [Jobs].[PurgeLogs_eJar]',
                    'CREATE PROC [Jobs].[PurgeLogs_eJar_PrePartitioning]'),
                    'CREATE PROCEDURE [Jobs].[PurgeLogs_eJar]',
                    'CREATE PROCEDURE [Jobs].[PurgeLogs_eJar_PrePartitioning]');
    EXEC sp_executesql @orig;
    PRINT 'Archived original as [Jobs].[PurgeLogs_eJar_PrePartitioning].';
END
ELSE
    PRINT 'Archive [Jobs].[PurgeLogs_eJar_PrePartitioning] already exists (or no original found).';
GO

/*==============================================================================
  The replacement.
==============================================================================*/
CREATE OR ALTER PROC [Jobs].[PurgeLogs_eJar]
(
      @Type  NVARCHAR(MAX) = NULL
    , @Batch INT           = NULL
    , @DryRun BIT          = 0   -- kept OFF so the existing call site behaves as
                                 -- before; the partition proc has its own gates
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @Batch IS NULL SET @Batch = 10000;

    PRINT REPLICATE('=',78);
    PRINT 'PurgeLogs_eJar (partition-aware)  Type=' + ISNULL(@Type,'(all)')
        + '  Batch=' + CAST(@Batch AS VARCHAR(10))
        + '  DryRun=' + CAST(@DryRun AS VARCHAR(1));
    PRINT REPLICATE('=',78);

    /*==========================================================================
      AUDIT  - AbpAuditLogs, daily partitions.
               7-day Exception IS NULL  +  30-day Exception IS NOT NULL
    ==========================================================================*/
    IF @Type LIKE '%Audit%' OR @Type IS NULL
    BEGIN
        PRINT '';
        PRINT '--- AUDIT (AbpAuditLogs) ---';

        IF OBJECT_ID('eJarDbAuditing.PartitionConfiguration.RetentionCleanup') IS NULL
        BEGIN
            PRINT 'PartitionConfiguration.RetentionCleanup not found in eJarDbAuditing.';
            PRINT 'Either partitioning has not been deployed yet, or the cutover was';
            PRINT 'rolled back. Falling back to the archived pre-partitioning logic.';
            EXEC [Jobs].[PurgeLogs_eJar_PrePartitioning] @Type = 'Audit', @Batch = @Batch;
        END
        ELSE
        BEGIN
            EXEC eJarDbAuditing.PartitionConfiguration.RetentionCleanup
                   @SetName       = 'AuditLogs'
                 , @Batch         = @Batch
                 , @BatchDelaySec = 3          -- as in the original
                 , @DryRun        = @DryRun;
        END
    END

    /*==========================================================================
      ENTITY - the three change-tracking tables, monthly partitions, 12 months.

      NOTE: the invocation in use - @Type = 'Audit,State' - does NOT match
      '%Entity%', so this block is skipped, exactly as before. That is why the
      change tables still hold data back to 2013-05-12. Pass 'Entity' (or NULL)
      to exercise it. Do a @DryRun = 1 pass first: the first real run will remove
      roughly 82-85% of those three tables.
    ==========================================================================*/
    IF @Type LIKE '%Entity%' OR @Type IS NULL
    BEGIN
        PRINT '';
        PRINT '--- ENTITY (change tracking) ---';

        IF OBJECT_ID('eJarDbAuditing.PartitionConfiguration.RetentionCleanup') IS NULL
        BEGIN
            PRINT 'Partition proc not found - falling back to archived logic.';
            EXEC [Jobs].[PurgeLogs_eJar_PrePartitioning] @Type = 'Entity', @Batch = @Batch;
        END
        ELSE
        BEGIN
            EXEC eJarDbAuditing.PartitionConfiguration.RetentionCleanup
                   @SetName       = 'Auditing'
                 , @Batch         = @Batch
                 , @BatchDelaySec = 3
                 , @DryRun        = @DryRun;
        END
    END

    /*==========================================================================
      STATE - HangFire.State in eJarDbProd, 30 days.

      Unchanged in intent; fixed so that it actually runs (bug 1 in the header).
      HangFire writes local time here, so GETDATE() is the correct comparison -
      the column is used as-is, as everywhere else in this solution.
    ==========================================================================*/
    IF @Type LIKE '%state%' OR @Type IS NULL
    BEGIN
        PRINT '';
        PRINT '--- STATE (HangFire.State) ---';

        DECLARE @Cutoff DATETIME = DATEADD(DAY, -30, GETDATE());
        DECLARE @rc BIGINT, @total BIGINT = 0, @batches INT = 0;
        DECLARE @MaxBatches INT = 5000;   -- ~1.8M rows of backlog at 10k/batch

        DROP TABLE IF EXISTS #ScopeState;

        SELECT Id
        INTO #ScopeState
        FROM HangFire_State
        WHERE CreatedAt < @Cutoff;

        /* BUG 1 FIX: capture the count BEFORE the CREATE INDEX below. The
           original tested @@ROWCOUNT after it, which is always 0 for DDL, so the
           loop never ran and 14.65 GB accumulated. */
        SET @rc = @@ROWCOUNT;

        CREATE INDEX IX_ScopeState ON #ScopeState (Id);

        PRINT '  cutoff ' + CONVERT(VARCHAR(30), @Cutoff, 121)
            + '   candidate rows: ' + CAST(@rc AS VARCHAR(20));

        IF @DryRun = 1
            PRINT '  DryRun = 1: nothing deleted.';
        ELSE IF @rc > 0
        BEGIN
            /*------------------------------------------------------------------
              Both DELETEs must target the SAME batch of Ids, hence the identical
              "TOP (@Batch) ... ORDER BY Id" subquery in each. This mirrors the
              original proc, and it matters: an earlier draft of this rewrite
              used EXISTS for the target table and an unordered
              "DELETE TOP (@Batch) FROM #ScopeState" for the scope table, which
              can remove a scope row whose HangFire_State row has not been
              deleted yet - silently stranding rows that no later run would
              revisit.

              The loop is driven by the SCOPE table's row count, not the target
              table's. If rows have already been removed by something else, the
              target count can hit 0 while scope rows remain; driving off the
              target would exit early and leave the backlog in place.
            ------------------------------------------------------------------*/
            WHILE @batches < @MaxBatches
            BEGIN
                DELETE FROM HangFire_State
                WHERE Id IN (SELECT TOP (@Batch) Id FROM #ScopeState ORDER BY Id);

                SET @total += @@ROWCOUNT;

                DELETE FROM #ScopeState
                WHERE Id IN (SELECT TOP (@Batch) Id FROM #ScopeState ORDER BY Id);

                IF @@ROWCOUNT = 0 BREAK;

                SET @batches += 1;
                WAITFOR DELAY '00:00:01';
            END

            PRINT '  deleted ' + CAST(@total AS VARCHAR(20)) + ' row(s) in '
                + CAST(@batches AS VARCHAR(10)) + ' batch(es)';

            IF @batches >= @MaxBatches
                PRINT '  hit the @MaxBatches cap - re-run to continue clearing the backlog.';
        END
        ELSE
            PRINT '  nothing older than the cutoff.';

        DROP TABLE IF EXISTS #ScopeState;
    END

    PRINT '';
    PRINT 'PurgeLogs_eJar complete.';
END
GO

SET NOEXEC OFF;
GO

PRINT '';
PRINT 'Replaced: [Jobs].[PurgeLogs_eJar]  (original archived as *_PrePartitioning)';
PRINT '';
PRINT 'Your existing call is unchanged:';
PRINT '    EXEC [Jobs].[PurgeLogs_eJar] @Type = ''Audit,State'', @Batch = 10000;';
PRINT '';
PRINT 'Preview without deleting anything:';
PRINT '    EXEC [Jobs].[PurgeLogs_eJar] @Type = ''Audit,State'', @Batch = 10000, @DryRun = 1;';
PRINT '';
PRINT 'The 14.65 GB HangFire.State backlog will clear over several runs because';
PRINT 'of the @MaxBatches cap. Watch the "hit the @MaxBatches cap" message.';
GO
