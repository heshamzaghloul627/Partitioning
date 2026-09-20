/*==============================================================================
  01_Create_Procedure_RetentionCleanup.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  REVISED       : 2026-09-12 - two-tier retention, DAY granularity, configurable
                               clock; aligned to [eJarDbReports].[Jobs].[PurgeLogs_eJar]

  Replaces dbo.sp_RetentionCleanup_eJarDbAuditing.

  ##############################################################################
  #  HOW THIS MAPS ONTO THE EXISTING RETENTION MODEL                           #
  ##############################################################################

  PurgeLogs_eJar does three things. This proc reproduces the first two exactly,
  using partition operations where they are cheaper and batched DELETEs where a
  partition operation cannot express the policy. (The HangFire "State" block is
  not in scope here - see 03_Replace_PurgeLogs_eJar.sql, which also fixes a bug
  that has stopped it working entirely.)

  PurgeLogs_eJar                          This proc
  --------------------------------------  ----------------------------------------
  AbpAuditLogs, Exception IS NOT NULL,    PRIMARY TIER: TRUNCATE + MERGE daily
  30 days. Batched DELETE over a          partitions whose whole range is older
  full-table #Scope scan.                 than 30 days. Metadata-only, reclaims
                                          space, no row-by-row logging.

  AbpAuditLogs, Exception IS NULL,        SECONDARY TIER: batched DELETE, but
  7 days. Batched DELETE over a           scoped with $PARTITION to one day at a
  full-table #Scope scan.                 time so it reads one partition instead
                                          of the whole table.

  AbpEntityChangeSets CreationTime        PRIMARY TIER: TRUNCATE + MERGE monthly
  older than 1 year, children deleted     partitions. All three tables are on the
  by navigating EntityChangeSetId /       same monthly function, so one merge
  EntityChangeId.                         ages all three out together.

  ------------------------------------------------------------------------------
  WHY TWO TIERS ARE UNAVOIDABLE
  ------------------------------------------------------------------------------
  Partition truncation is all-or-nothing on the partitioning column. The audit-log
  policy splits on Exception, which is NOT the partitioning column, so a single
  partition holds rows with two different expiry dates. No partition scheme can
  express that. The 30-day tier is therefore partition-based and the 7-day tier
  stays a DELETE - just a far better targeted one.

  Measured 2026-09-12: ~2.2M success and ~17k error rows/day. So the secondary
  tier deletes ~99.2% of a day's partition and the primary tier later truncates
  the ~29 MB error remainder.

  ------------------------------------------------------------------------------
  PARENT-DRIVEN VS CHILD-DRIVEN AGEING - a real, measured difference
  ------------------------------------------------------------------------------
  PurgeLogs_eJar ages children out by their PARENT's CreationTime. This proc ages
  each table out by its own partitioning column. Sampled 454,517 parent/child
  pairs on 2026-09-12:

      exact_match           0        (always differs at sub-second resolution)
      max skew              0 s      (ChangeTime is never AFTER CreationTime)
      min skew       -193,637 s      (a child can be ~2.24 days EARLIER)
      different day         5        (0.001%)
      different MONTH       0

  At MONTH granularity the two models agree - which is why the change-tracking
  tables are monthly and not daily. The residual risk is a transaction spanning a
  month boundary, where a child could be aged out one month before its parent.
  Nothing enforces the relationship (there are no foreign keys), and the direction
  is the benign one: a retained parent with missing children, never an orphan.

  ------------------------------------------------------------------------------
  Other fixes carried here
  ------------------------------------------------------------------------------
  C5  Exits immediately unless this replica is the primary. msdb is not
      AG-replicated, so the job must be deployed to all three replicas.
  W4  RECLAIMS the filegroup and file after a merge (PER_PARTITION sets only).
      The original truncated and merged but never removed anything, orphaning a
      >=100 MB file on every cycle.
  I6  No sp_ prefix - SQL Server resolves those against master first.
  W13 Retention comes from PartitionConfiguration.PartitionSet, one place.

  Structural: the original special-cased AbpAuditLogs with
  "TRUNCATE ... WITH (PARTITIONS (1 TO N))" and no merge, because all four tables
  shared one partition function while needing two different policies. Separate
  partition sets remove that special case.

  ------------------------------------------------------------------------------
  RANGE RIGHT ARITHMETIC
  ------------------------------------------------------------------------------
    partition p covers  [ boundary(p-1) , boundary(p) )
    partition 1 covers  ( -infinity     , boundary(1) )    <- catch-all
    last partition      [ boundary(n)   , +infinity   )    <- must stay empty

  So partition p's upper bound is the boundary with boundary_id = p, and
  partition 2 is fully expired when boundary(2) <= cutoff. Removing it means
  MERGE boundary(1): under RANGE RIGHT that releases partition 2's filegroup and
  folds its range into partition 1. boundary_id renumbers contiguously after each
  merge, so the loop simply re-reads boundaries 1 and 2 each pass.

  Truncate BEFORE merge. That makes the merge metadata-only; merging a populated
  partition is a fully-logged, offline, size-of-data movement. The original got
  this right and it is preserved.
==============================================================================*/
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

USE eJarDbAuditing;
GO

IF OBJECT_ID('dbo.sp_RetentionCleanup_eJarDbAuditing', 'P') IS NOT NULL
    DROP PROCEDURE dbo.sp_RetentionCleanup_eJarDbAuditing;
GO

CREATE OR ALTER PROCEDURE PartitionConfiguration.RetentionCleanup
(
      @SetName       SYSNAME = NULL   -- NULL = every set in PartitionSet
    , @MaxPartitions INT     = 6      -- safety cap on partitions purged per run
    , @Batch         INT     = 10000  -- matches PurgeLogs_eJar's @Batch default
    , @BatchDelaySec INT     = 3       -- matches its WAITFOR DELAY '00:00:03'
    , @MaxBatches    INT     = 500     -- safety cap on the secondary tier
    , @RemoveFiles   BIT     = 1       -- W4: reclaim released filegroup/file
    , @SkipSecondary BIT     = 0       -- 1 = partition work only
    , @DryRun        BIT     = 1       -- SAFE DEFAULT: report only
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*--------------------------------------------------------------------------
      C5 - primary replica guard.
    --------------------------------------------------------------------------*/
    IF SERVERPROPERTY('IsHadrEnabled') = 1
       AND ISNULL(sys.fn_hadr_is_primary_replica(DB_NAME()), 0) <> 1
    BEGIN
        PRINT 'RetentionCleanup: not the primary replica for ' + DB_NAME()
            + ' - nothing to do.';
        RETURN 0;
    END

    IF @BatchDelaySec < 0 OR @BatchDelaySec > 59
    BEGIN
        RAISERROR('@BatchDelaySec must be between 0 and 59.', 16, 1);
        RETURN 1;
    END

    DECLARE @Delay CHAR(8) = '00:00:' + RIGHT('0' + CAST(@BatchDelaySec AS VARCHAR(2)), 2);

    DECLARE @Sets TABLE (SetName SYSNAME PRIMARY KEY);
    INSERT @Sets (SetName)
    SELECT SetName FROM PartitionConfiguration.PartitionSet
    WHERE @SetName IS NULL OR SetName = @SetName;

    IF NOT EXISTS (SELECT 1 FROM @Sets)
    BEGIN
        RAISERROR('RetentionCleanup: no matching partition set for ''%s''.', 16, 1, @SetName);
        RETURN 1;
    END

    DECLARE @Set SYSNAME;
    DECLARE setCur CURSOR LOCAL FAST_FORWARD FOR SELECT SetName FROM @Sets;
    OPEN setCur;
    FETCH NEXT FROM setCur INTO @Set;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @PF SYSNAME, @PS SYSNAME, @Gran VARCHAR(10), @Retention INT,
                @Ret2 INT, @Pred2 NVARCHAR(500), @Clock VARCHAR(5),
                @FgMode VARCHAR(15);

        SELECT @PF        = PartitionFunction
             , @PS        = PartitionScheme
             , @Gran      = Granularity
             , @Retention = RetentionUnits
             , @Ret2      = SecondaryRetentionUnits
             , @Pred2     = SecondaryPredicate
             , @Clock     = ClockSource
             , @FgMode    = FilegroupMode
        FROM PartitionConfiguration.PartitionSet WHERE SetName = @Set;

        /*----------------------------------------------------------------------
          "Now" from the configured clock. The COLUMN VALUE IS NEVER CONVERTED -
          a row stamped 2026-09-14 10:00 is compared as 2026-09-14 10:00.
          Measured: the application writes UTC, so ClockSource defaults to 'UTC'.
          PurgeLogs_eJar uses GETDATE() (local, +3h) against the same UTC column
          and therefore deletes 3 hours more than its stated policy.
        ----------------------------------------------------------------------*/
        DECLARE @Now DATETIME2(7) =
            CASE WHEN @Clock = 'LOCAL' THEN SYSDATETIME() ELSE SYSUTCDATETIME() END;

        DECLARE @Cutoff DATETIME2(7) =
            CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   -@Retention, @Now)
                       WHEN 'WEEK'  THEN DATEADD(WEEK,  -@Retention, @Now)
                       WHEN 'MONTH' THEN DATEADD(MONTH, -@Retention, @Now)
            END;

        DECLARE @Cutoff2 DATETIME2(7) =
            CASE WHEN @Ret2 IS NULL THEN NULL
                 ELSE CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   -@Ret2, @Now)
                                 WHEN 'WEEK'  THEN DATEADD(WEEK,  -@Ret2, @Now)
                                 WHEN 'MONTH' THEN DATEADD(MONTH, -@Ret2, @Now)
                      END
            END;

        PRINT REPLICATE('=',78);
        PRINT 'RETENTION  set=' + @Set + '  function=' + @PF + '  granularity=' + @Gran;
        PRINT '  clock            = ' + @Clock + '  (now = ' + CONVERT(VARCHAR(30), @Now, 121) + ')';
        PRINT '  primary tier     = ' + CAST(@Retention AS VARCHAR(10)) + ' ' + @Gran
            + '(s)  -> TRUNCATE + MERGE   cutoff ' + CONVERT(VARCHAR(30), @Cutoff, 121);
        IF @Ret2 IS NOT NULL
            PRINT '  secondary tier   = ' + CAST(@Ret2 AS VARCHAR(10)) + ' ' + @Gran
                + '(s)  -> DELETE WHERE ' + @Pred2 + '   cutoff '
                + CONVERT(VARCHAR(30), @Cutoff2, 121);
        PRINT '  DryRun = ' + CAST(@DryRun AS VARCHAR(1))
            + '   Batch = ' + CAST(@Batch AS VARCHAR(10))
            + '   Delay = ' + @Delay
            + '   MaxPartitions = ' + CAST(@MaxPartitions AS VARCHAR(10));
        PRINT REPLICATE('=',78);

        /*----------------------------------------------------------------------
          Tables on this scheme, child-before-parent.

          No foreign keys exist, so this ordering is not enforced by the engine.
          It matters because the application treats
          PropertyChanges -> Changes -> ChangeSets as a hierarchy and a reader
          mid-run should never see a parent whose children have gone.
        ----------------------------------------------------------------------*/
        DECLARE @Tables TABLE (Seq INT IDENTITY(1,1), SchemaName SYSNAME,
                               TableName SYSNAME, PartCol SYSNAME NULL);
        DELETE @Tables;

        INSERT @Tables (SchemaName, TableName)
        SELECT s.name, t.name
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
        JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
        WHERE ps.name = @PS
        ORDER BY CASE t.name
                     WHEN 'AbpEntityPropertyChanges' THEN 1
                     WHEN 'AbpEntityChanges'         THEN 2
                     WHEN 'AbpEntityChangeSets'      THEN 3
                     ELSE 4
                 END;

        /* Resolve each table's partitioning column once. */
        UPDATE tt
        SET PartCol = c.name
        FROM @Tables tt
        CROSS APPLY (
            SELECT TOP 1 c2.name
            FROM sys.index_columns ic
            JOIN sys.columns c2 ON ic.object_id = c2.object_id AND ic.column_id = c2.column_id
            JOIN sys.indexes i  ON ic.object_id = i.object_id  AND ic.index_id  = i.index_id
            WHERE i.object_id = OBJECT_ID(QUOTENAME(tt.SchemaName) + '.' + QUOTENAME(tt.TableName))
              AND i.index_id IN (0,1)
              AND ic.partition_ordinal = 1
        ) c(name);

        IF NOT EXISTS (SELECT 1 FROM @Tables)
        BEGIN
            PRINT '  No tables are on scheme ' + @PS + ' - skipping.';
            FETCH NEXT FROM setCur INTO @Set;
            CONTINUE;
        END

        DECLARE @Seq INT, @Sch SYSNAME, @Tbl SYSNAME, @Col SYSNAME,
                @sql NVARCHAR(MAX), @Rows BIGINT;

        /*======================================================================
          PRIMARY TIER - truncate and merge fully expired partitions.
        ======================================================================*/
        PRINT '';
        PRINT '--- PRIMARY TIER (partition truncate + merge) ---';

        DECLARE @Done INT = 0;

        WHILE @Done < @MaxPartitions
        BEGIN
            DECLARE @B1 DATETIME2(7), @B2 DATETIME2(7);

            SELECT @B1 = MAX(CASE WHEN boundary_id = 1 THEN CAST(value AS DATETIME2(7)) END)
                 , @B2 = MAX(CASE WHEN boundary_id = 2 THEN CAST(value AS DATETIME2(7)) END)
            FROM sys.partition_range_values prv
            JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
            WHERE pf.name = @PF AND prv.boundary_id IN (1,2);

            /* Two boundaries are needed: one to merge, and one to prove the
               partition being removed is entirely expired. */
            IF @B1 IS NULL OR @B2 IS NULL
            BEGIN
                PRINT '  Fewer than two boundaries remain - stopping.';
                BREAK;
            END

            IF @B2 > @Cutoff
            BEGIN
                PRINT '  Partition 2 upper bound ' + CONVERT(VARCHAR(30), @B2, 121)
                    + ' is inside retention - nothing further to purge.';
                BREAK;
            END

            PRINT '';
            PRINT '  Purging partition 2  [' + CONVERT(VARCHAR(30), @B1, 121)
                + ', ' + CONVERT(VARCHAR(30), @B2, 121) + ')';

            /* W4 - capture the filegroup MERGE RANGE will release. Under
               RANGE RIGHT that is partition 2's filegroup. Meaningless in
               SHARED mode, where every partition maps to the same filegroup. */
            DECLARE @FGToDrop SYSNAME = NULL;

            IF @FgMode = 'PER_PARTITION'
            BEGIN
                SELECT @FGToDrop = fg.name
                FROM sys.partition_schemes ps
                JOIN sys.destination_data_spaces dds
                     ON  dds.partition_scheme_id = ps.data_space_id
                     AND dds.destination_id      = 2
                JOIN sys.filegroups fg ON fg.data_space_id = dds.data_space_id
                WHERE ps.name = @PS;

                PRINT '  filegroup to be released: ' + ISNULL(@FGToDrop, '(none/PRIMARY)');
            END

            /* Safety check: belt and braces over the boundary arithmetic. */
            DECLARE @Bad BIGINT = 0;
            SET @Seq = 1;

            WHILE EXISTS (SELECT 1 FROM @Tables WHERE Seq = @Seq)
            BEGIN
                SELECT @Sch = SchemaName, @Tbl = TableName, @Col = PartCol
                FROM @Tables WHERE Seq = @Seq;

                SET @sql = N'SELECT @n = COUNT_BIG(*) FROM '
                         + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                         + N' WHERE $PARTITION.' + QUOTENAME(@PF) + N'(' + QUOTENAME(@Col) + N') = 2'
                         + N'   AND ' + QUOTENAME(@Col) + N' >= @cut;';
                EXEC sp_executesql @sql, N'@cut datetime2(7), @n bigint OUTPUT',
                                   @cut = @Cutoff, @n = @Rows OUTPUT;

                IF @Rows > 0
                BEGIN
                    PRINT '  SAFETY CHECK FAILED: ' + @Sch + '.' + @Tbl + ' has '
                        + CAST(@Rows AS VARCHAR(20)) + ' row(s) inside retention in partition 2.';
                    SET @Bad += @Rows;
                END

                SET @Seq += 1;
            END

            IF @Bad > 0
            BEGIN
                PRINT '  Aborting this set - safety check failed.';
                BREAK;
            END

            /* TRUNCATE each table's partition 2, child before parent. */
            SET @Seq = 1;
            WHILE EXISTS (SELECT 1 FROM @Tables WHERE Seq = @Seq)
            BEGIN
                SELECT @Sch = SchemaName, @Tbl = TableName FROM @Tables WHERE Seq = @Seq;

                SET @sql = N'TRUNCATE TABLE ' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                         + N' WITH (PARTITIONS (2));';
                PRINT '    ' + @sql;
                IF @DryRun = 0 EXEC sp_executesql @sql;

                SET @Seq += 1;
            END

            /* MERGE the boundary, removing the now-empty partition. */
            SET @sql = N'ALTER PARTITION FUNCTION ' + QUOTENAME(@PF) + N'() MERGE RANGE (@b);';
            PRINT '    ' + @sql + '   -- @b = ' + CONVERT(VARCHAR(30), @B1, 121);
            IF @DryRun = 0 EXEC sp_executesql @sql, N'@b datetime2(7)', @b = @B1;

            /* W4 - remove the released file and filegroup. Never PRIMARY, which
               is partition 1's permanent home; never in SHARED mode. */
            IF @RemoveFiles = 1 AND @FgMode = 'PER_PARTITION'
               AND @FGToDrop IS NOT NULL AND @FGToDrop <> 'PRIMARY'
            BEGIN
                IF @DryRun = 1
                    PRINT '    -- would remove file(s) and filegroup ' + @FGToDrop
                        + ' (skipped: DryRun)';
                ELSE IF EXISTS (
                    SELECT 1
                    FROM sys.destination_data_spaces dds
                    JOIN sys.filegroups fg ON fg.data_space_id = dds.data_space_id
                    JOIN sys.partition_schemes ps ON ps.data_space_id = dds.partition_scheme_id
                    WHERE fg.name = @FGToDrop AND ps.name = @PS)
                BEGIN
                    PRINT '    -- filegroup ' + @FGToDrop
                        + ' is still referenced by the scheme; not removing.';
                END
                ELSE
                BEGIN
                    DECLARE @F SYSNAME;
                    DECLARE fCur CURSOR LOCAL FAST_FORWARD FOR
                        SELECT df.name
                        FROM sys.database_files df
                        JOIN sys.filegroups fg ON df.data_space_id = fg.data_space_id
                        WHERE fg.name = @FGToDrop;
                    OPEN fCur; FETCH NEXT FROM fCur INTO @F;
                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        SET @sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
                                 + N' REMOVE FILE ' + QUOTENAME(@F) + N';';
                        PRINT '    ' + @sql;
                        EXEC sp_executesql @sql;
                        FETCH NEXT FROM fCur INTO @F;
                    END
                    CLOSE fCur; DEALLOCATE fCur;

                    SET @sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
                             + N' REMOVE FILEGROUP ' + QUOTENAME(@FGToDrop) + N';';
                    PRINT '    ' + @sql;
                    EXEC sp_executesql @sql;
                END
            END

            SET @Done += 1;

            IF @DryRun = 1
            BEGIN
                PRINT '';
                PRINT '  DryRun = 1: stopping after one partition (nothing changed, so the';
                PRINT '  loop would otherwise repeat forever on the same boundary).';
                BREAK;
            END
        END

        PRINT '  primary tier: ' + CAST(@Done AS VARCHAR(10)) + ' partition(s) purged.';
        IF @Done >= @MaxPartitions
            PRINT '  Hit the @MaxPartitions cap - re-run to continue.';

        /*======================================================================
          SECONDARY TIER - batched DELETE inside partitions that are past the
          secondary cutoff but not yet past the primary cutoff.

          This is the "Exception IS NULL after 7 days" rule. $PARTITION in the
          predicate gives partition elimination, so each statement reads one
          day's partition instead of the whole table.
        ======================================================================*/
        IF @Ret2 IS NOT NULL AND @SkipSecondary = 0
        BEGIN
            PRINT '';
            PRINT '--- SECONDARY TIER (batched DELETE WHERE ' + @Pred2 + ') ---';

            SET @Seq = 1;
            WHILE EXISTS (SELECT 1 FROM @Tables WHERE Seq = @Seq)
            BEGIN
                SELECT @Sch = SchemaName, @Tbl = TableName, @Col = PartCol
                FROM @Tables WHERE Seq = @Seq;

                /* The predicate is set-level config but may not be valid for
                   every table on the set (Exception exists only on
                   AbpAuditLogs). Probe it once rather than failing mid-delete. */
                DECLARE @Valid BIT = 1;
                BEGIN TRY
                    SET @sql = N'SELECT TOP 0 1 FROM ' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                             + N' WHERE ' + @Pred2 + N';';
                    EXEC sp_executesql @sql;
                END TRY
                BEGIN CATCH
                    SET @Valid = 0;
                    PRINT '  ' + @Sch + '.' + @Tbl + ': predicate not applicable ('
                        + ERROR_MESSAGE() + ') - skipped.';
                END CATCH

                IF @Valid = 1
                BEGIN
                    /* Partitions to process: upper bound past the secondary
                       cutoff, but still inside the primary window (anything past
                       the primary cutoff was truncated wholesale above). */
                    DECLARE @Parts TABLE (PartitionNumber INT PRIMARY KEY,
                                          UpperBound DATETIME2(7));
                    DELETE @Parts;

                    INSERT @Parts (PartitionNumber, UpperBound)
                    SELECT prv.boundary_id, CAST(prv.value AS DATETIME2(7))
                    FROM sys.partition_range_values prv
                    JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
                    WHERE pf.name = @PF
                      AND CAST(prv.value AS DATETIME2(7)) <= @Cutoff2
                      AND CAST(prv.value AS DATETIME2(7)) >  @Cutoff;

                    IF NOT EXISTS (SELECT 1 FROM @Parts)
                        PRINT '  ' + @Sch + '.' + @Tbl + ': no partitions in the secondary window.';

                    DECLARE @P INT, @PUpper DATETIME2(7), @TotalDeleted BIGINT;
                    DECLARE pCur CURSOR LOCAL FAST_FORWARD FOR
                        SELECT PartitionNumber, UpperBound FROM @Parts ORDER BY PartitionNumber;
                    OPEN pCur; FETCH NEXT FROM pCur INTO @P, @PUpper;

                    WHILE @@FETCH_STATUS = 0
                    BEGIN
                        SET @TotalDeleted = 0;

                        /*------------------------------------------------------
                          The DELETE reports its own row count through an OUTPUT
                          parameter rather than leaving the caller to read
                          @@ROWCOUNT after EXEC sp_executesql.

                          @@ROWCOUNT is not reliably preserved across the
                          EXECUTE boundary, and if it came back as 0 this loop
                          would exit after a single batch - quietly deleting
                          only @Batch rows per run instead of draining the
                          partition. Making the dynamic batch set @n itself
                          removes the ambiguity.
                        ------------------------------------------------------*/
                        SET @sql = N'DELETE TOP (@b) '
                                 + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                                 + N' WHERE $PARTITION.' + QUOTENAME(@PF)
                                 + N'(' + QUOTENAME(@Col) + N') = ' + CAST(@P AS NVARCHAR(10))
                                 + N'   AND (' + @Pred2 + N');'
                                 + N' SET @n = @@ROWCOUNT;';

                        /* Report the scope first - this is what a DryRun shows. */
                        DECLARE @Candidates BIGINT;
                        DECLARE @csql NVARCHAR(MAX) =
                              N'SELECT @n = COUNT_BIG(*) FROM '
                            + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                            + N' WHERE $PARTITION.' + QUOTENAME(@PF)
                            + N'(' + QUOTENAME(@Col) + N') = ' + CAST(@P AS NVARCHAR(10))
                            + N'   AND (' + @Pred2 + N');';
                        EXEC sp_executesql @csql, N'@n bigint OUTPUT', @n = @Candidates OUTPUT;

                        PRINT '  partition ' + CAST(@P AS VARCHAR(10))
                            + '  (< ' + CONVERT(VARCHAR(30), @PUpper, 121) + ')  '
                            + CAST(@Candidates AS VARCHAR(20)) + ' candidate row(s)';

                        IF @DryRun = 1
                        BEGIN
                            PRINT '      ' + @sql + '   -- (skipped: DryRun)';
                        END
                        ELSE IF @Candidates > 0
                        BEGIN
                            DECLARE @Batches INT = 0;
                            SET @Rows = 1;

                            WHILE @Rows > 0 AND @Batches < @MaxBatches
                            BEGIN
                                EXEC sp_executesql @sql,
                                     N'@b int, @n bigint OUTPUT',
                                     @b = @Batch, @n = @Rows OUTPUT;

                                SET @TotalDeleted += @Rows;
                                SET @Batches += 1;

                                IF @Rows > 0 AND @BatchDelaySec > 0
                                    WAITFOR DELAY @Delay;
                            END

                            PRINT '      deleted ' + CAST(@TotalDeleted AS VARCHAR(20))
                                + ' row(s) in ' + CAST(@Batches AS VARCHAR(10)) + ' batch(es)';

                            IF @Batches >= @MaxBatches
                                PRINT '      hit the @MaxBatches cap - re-run to continue.';
                        END

                        FETCH NEXT FROM pCur INTO @P, @PUpper;
                    END
                    CLOSE pCur; DEALLOCATE pCur;
                END

                SET @Seq += 1;
            END
        END
        ELSE IF @Ret2 IS NOT NULL
            PRINT '  secondary tier skipped (@SkipSecondary = 1).';

        PRINT '';
        FETCH NEXT FROM setCur INTO @Set;
    END

    CLOSE setCur; DEALLOCATE setCur;
    RETURN 0;
END
GO

PRINT 'Created: PartitionConfiguration.RetentionCleanup';
PRINT '';
PRINT 'Preview (changes nothing):';
PRINT '  EXEC PartitionConfiguration.RetentionCleanup @DryRun = 1;';
PRINT 'Apply:';
PRINT '  EXEC PartitionConfiguration.RetentionCleanup @DryRun = 0;';
PRINT 'Partition work only, no row-by-row deletes:';
PRINT '  EXEC PartitionConfiguration.RetentionCleanup @DryRun = 0, @SkipSecondary = 1;';
GO
