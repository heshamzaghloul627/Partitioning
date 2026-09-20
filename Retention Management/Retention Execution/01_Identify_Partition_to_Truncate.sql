/*==============================================================================
  01_Identify_Partition_to_Truncate.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY) - read-only, so any replica works
  REVISED       : 2026-09-12 - DAY granularity, configurable clock, and the
                               secondary (7-day) retention tier
  PURPOSE       : diagnostics. Shows what retention WOULD remove, so you can
                  reason about it before running anything.

  This does NOT delete anything. The work is done by
  PartitionConfiguration.RetentionCleanup, or by
  [eJarDbReports].[Jobs].[PurgeLogs_eJar] which now delegates to it.

  ------------------------------------------------------------------------------
  Changes from the original
  ------------------------------------------------------------------------------
  * Hard-coded 'PFLeftYearMonthWeek' replaced with the two current functions,
    driven from PartitionConfiguration.PartitionSet.
  * The original section D ran four unbounded
    "SELECT $PARTITION.f(col), COUNT(*) ... GROUP BY" queries. On 1.28 billion
    rows that is a full scan of the largest table in the database, on a server
    whose buffer pool holds ~7% of the data. Replaced with
    sys.dm_db_partition_stats, which is metadata and instant.
  * Boundary arithmetic corrected for RANGE RIGHT (the original assumed
    RANGE LEFT). See 04_VIEW_Partition_Information.sql for the mapping.
  * CAST to DATETIME replaced with DATETIME2(7) - the original silently rounded
    datetime2(7) boundary values.
  * Reports BOTH retention tiers. AbpAuditLogs has a 30-day partition tier and a
    7-day "Exception IS NULL" DELETE tier; showing only the first would make the
    audit-log policy look wrong.

  Cutoffs compare the stored column value as-is - nothing is converted. The clock
  for "now" comes from PartitionSet.ClockSource (measured: the application writes
  UTC, so 'UTC').
==============================================================================*/
SET NOCOUNT ON;
GO

USE eJarDbAuditing;
GO

/*==============================================================================
  A. Configured policy, with both tiers and the resolved cutoffs.
==============================================================================*/
PRINT '=== A. Retention policy in force ===';

SELECT ps.SetName                                   AS partition_set
     , ps.Granularity
     , ps.ClockSource
     , n.ClockNow                                   AS now_in_that_clock
     , CAST(ps.RetentionUnits AS VARCHAR(10)) + ' ' + ps.Granularity AS primary_tier
     , c.Cutoff                                     AS primary_cutoff
     , ISNULL(CAST(ps.SecondaryRetentionUnits AS VARCHAR(10))
              + ' ' + ps.Granularity, '(none)')     AS secondary_tier
     , c.Cutoff2                                    AS secondary_cutoff
     , ISNULL(ps.SecondaryPredicate, '(none)')       AS secondary_predicate
     , ps.FilegroupMode
     , ISNULL(ps.SharedFilegroup, '(per partition)') AS filegroup_target
FROM PartitionConfiguration.PartitionSet ps
CROSS APPLY (SELECT CASE WHEN ps.ClockSource = 'LOCAL'
                         THEN SYSDATETIME() ELSE SYSUTCDATETIME() END) n(ClockNow)
CROSS APPLY (
    SELECT CASE ps.Granularity
                WHEN 'DAY'   THEN DATEADD(DAY,   -ps.RetentionUnits, n.ClockNow)
                WHEN 'WEEK'  THEN DATEADD(WEEK,  -ps.RetentionUnits, n.ClockNow)
                WHEN 'MONTH' THEN DATEADD(MONTH, -ps.RetentionUnits, n.ClockNow)
           END
         , CASE WHEN ps.SecondaryRetentionUnits IS NULL THEN NULL
                ELSE CASE ps.Granularity
                         WHEN 'DAY'   THEN DATEADD(DAY,   -ps.SecondaryRetentionUnits, n.ClockNow)
                         WHEN 'WEEK'  THEN DATEADD(WEEK,  -ps.SecondaryRetentionUnits, n.ClockNow)
                         WHEN 'MONTH' THEN DATEADD(MONTH, -ps.SecondaryRetentionUnits, n.ClockNow)
                     END
           END
) c(Cutoff, Cutoff2)
ORDER BY ps.SetName;
GO

/*==============================================================================
  B. Current partition layout. Metadata only - no table access.
==============================================================================*/
PRINT '=== B. Partition layout ===';

SELECT partition_set
     , table_name
     , partition_number
     , filegroup_name
     , lower_boundary_inclusive
     , upper_boundary_exclusive
     , number_of_rows
     , reserved_mb
     , notes
FROM PartitionConfiguration.Partition_Information
ORDER BY partition_set, table_name, partition_number;
GO

/*==============================================================================
  C. PRIMARY TIER - partitions the truncate/merge pass would remove.

     A partition is fully expired when its UPPER boundary is at or before the
     cutoff. Under RANGE RIGHT, partition p's upper boundary is the boundary
     whose boundary_id = p.

     Partition 1 is the permanent pre-retention catch-all: it is emptied, then
     absorbs the range of each partition removed after it, and is never merged
     away itself.
==============================================================================*/
PRINT '=== C. PRIMARY TIER - partitions eligible for TRUNCATE + MERGE ===';

;WITH cfg AS
(
    SELECT ps.SetName, ps.PartitionFunction, ps.PartitionScheme,
           ps.Granularity, ps.RetentionUnits,
           CASE ps.Granularity
                WHEN 'DAY'   THEN DATEADD(DAY,   -ps.RetentionUnits, n.ClockNow)
                WHEN 'WEEK'  THEN DATEADD(WEEK,  -ps.RetentionUnits, n.ClockNow)
                WHEN 'MONTH' THEN DATEADD(MONTH, -ps.RetentionUnits, n.ClockNow)
           END AS Cutoff
    FROM PartitionConfiguration.PartitionSet ps
    CROSS APPLY (SELECT CASE WHEN ps.ClockSource = 'LOCAL'
                             THEN SYSDATETIME() ELSE SYSUTCDATETIME() END) n(ClockNow)
),
bounds AS
(
    SELECT cfg.SetName, cfg.Cutoff, cfg.RetentionUnits, cfg.Granularity,
           cfg.PartitionScheme,
           prv.boundary_id                   AS partition_number,
           CAST(prv.value AS DATETIME2(7))   AS upper_boundary_exclusive
    FROM cfg
    JOIN sys.partition_functions    pf  ON pf.name = cfg.PartitionFunction
    JOIN sys.partition_range_values prv ON prv.function_id = pf.function_id
)
SELECT b.SetName                                              AS partition_set
     , b.partition_number
     , b.upper_boundary_exclusive
     , b.Cutoff                                               AS retention_cutoff
     , CAST(b.RetentionUnits AS VARCHAR(10)) + ' ' + b.Granularity AS policy
     , CASE WHEN b.upper_boundary_exclusive <= b.Cutoff
            THEN 'ELIGIBLE - would be truncated + merged'
            ELSE 'inside retention' END                       AS verdict
     , (SELECT SUM(pi.number_of_rows)
        FROM PartitionConfiguration.Partition_Information pi
        WHERE pi.partition_scheme = b.PartitionScheme
          AND pi.partition_number = b.partition_number)       AS rows_across_tables
     , (SELECT SUM(pi.reserved_mb)
        FROM PartitionConfiguration.Partition_Information pi
        WHERE pi.partition_scheme = b.PartitionScheme
          AND pi.partition_number = b.partition_number)       AS reserved_mb_across_tables
FROM bounds b
ORDER BY b.SetName, b.partition_number;
GO

/*==============================================================================
  D. SECONDARY TIER - the batched-DELETE pass.

     For AbpAuditLogs this is "Exception IS NULL, older than 7 days". It cannot
     be a partition operation because Exception is not the partitioning column,
     so one partition holds rows with two different expiry dates.

     Row counts here DO touch the table, but each is scoped with $PARTITION to a
     single day, so it reads one partition rather than the whole table.
==============================================================================*/
PRINT '=== D. SECONDARY TIER - rows eligible for batched DELETE ===';

DECLARE @Rpt TABLE (partition_set SYSNAME, table_name SYSNAME, partition_number INT,
                    upper_boundary DATETIME2(7), predicate NVARCHAR(500),
                    candidate_rows BIGINT);

DECLARE @Set SYSNAME, @PF SYSNAME, @PS SYSNAME, @Gran VARCHAR(10),
        @Ret INT, @Ret2 INT, @Pred NVARCHAR(500), @Clock VARCHAR(5);

DECLARE sc CURSOR LOCAL FAST_FORWARD FOR
    SELECT SetName, PartitionFunction, PartitionScheme, Granularity,
           RetentionUnits, SecondaryRetentionUnits, SecondaryPredicate, ClockSource
    FROM PartitionConfiguration.PartitionSet
    WHERE SecondaryRetentionUnits IS NOT NULL;
OPEN sc;
FETCH NEXT FROM sc INTO @Set, @PF, @PS, @Gran, @Ret, @Ret2, @Pred, @Clock;

WHILE @@FETCH_STATUS = 0
BEGIN
    DECLARE @Now DATETIME2(7) =
        CASE WHEN @Clock = 'LOCAL' THEN SYSDATETIME() ELSE SYSUTCDATETIME() END;

    DECLARE @C1 DATETIME2(7) =
        CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   -@Ret,  @Now)
                   WHEN 'WEEK'  THEN DATEADD(WEEK,  -@Ret,  @Now)
                   WHEN 'MONTH' THEN DATEADD(MONTH, -@Ret,  @Now) END;
    DECLARE @C2 DATETIME2(7) =
        CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   -@Ret2, @Now)
                   WHEN 'WEEK'  THEN DATEADD(WEEK,  -@Ret2, @Now)
                   WHEN 'MONTH' THEN DATEADD(MONTH, -@Ret2, @Now) END;

    DECLARE @Sch SYSNAME, @Tbl SYSNAME, @Col SYSNAME, @P INT,
            @Upper DATETIME2(7), @n BIGINT, @sql NVARCHAR(MAX);

    DECLARE tc CURSOR LOCAL FAST_FORWARD FOR
        SELECT s.name, t.name,
               (SELECT TOP 1 c.name
                FROM sys.index_columns ic
                JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                WHERE ic.object_id = t.object_id AND ic.index_id = i.index_id
                  AND ic.partition_ordinal = 1)
        FROM sys.tables t
        JOIN sys.schemas s ON t.schema_id = s.schema_id
        JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
        JOIN sys.partition_schemes pscheme ON i.data_space_id = pscheme.data_space_id
        WHERE pscheme.name = @PS;
    OPEN tc; FETCH NEXT FROM tc INTO @Sch, @Tbl, @Col;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE pc CURSOR LOCAL FAST_FORWARD FOR
            SELECT prv.boundary_id, CAST(prv.value AS DATETIME2(7))
            FROM sys.partition_range_values prv
            JOIN sys.partition_functions pf2 ON pf2.function_id = prv.function_id
            WHERE pf2.name = @PF
              AND CAST(prv.value AS DATETIME2(7)) <= @C2
              AND CAST(prv.value AS DATETIME2(7)) >  @C1
            ORDER BY prv.boundary_id;
        OPEN pc; FETCH NEXT FROM pc INTO @P, @Upper;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                SET @sql = N'SELECT @out = COUNT_BIG(*) FROM '
                         + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
                         + N' WHERE $PARTITION.' + QUOTENAME(@PF)
                         + N'(' + QUOTENAME(@Col) + N') = ' + CAST(@P AS NVARCHAR(10))
                         + N'   AND (' + @Pred + N');';
                EXEC sp_executesql @sql, N'@out bigint OUTPUT', @out = @n OUTPUT;

                INSERT @Rpt VALUES (@Set, @Sch + '.' + @Tbl, @P, @Upper, @Pred, @n);
            END TRY
            BEGIN CATCH
                /* The predicate is set-level config and may not apply to every
                   table on the set - Exception exists only on AbpAuditLogs. */
                INSERT @Rpt VALUES (@Set, @Sch + '.' + @Tbl, @P, @Upper,
                                    'N/A - ' + ERROR_MESSAGE(), NULL);
            END CATCH

            FETCH NEXT FROM pc INTO @P, @Upper;
        END
        CLOSE pc; DEALLOCATE pc;

        FETCH NEXT FROM tc INTO @Sch, @Tbl, @Col;
    END
    CLOSE tc; DEALLOCATE tc;

    FETCH NEXT FROM sc INTO @Set, @PF, @PS, @Gran, @Ret, @Ret2, @Pred, @Clock;
END
CLOSE sc; DEALLOCATE sc;

IF EXISTS (SELECT 1 FROM @Rpt)
    SELECT * FROM @Rpt ORDER BY partition_set, table_name, partition_number;
ELSE
    PRINT '  No partitions currently sit between the secondary and primary cutoffs.';
GO

/*==============================================================================
  E. Trailing-partition health check.

     The trailing partition MUST stay empty. If it has rows, provisioning has
     fallen behind and the next SPLIT would be an offline, size-of-data movement.
     Anything returned here needs attention.
==============================================================================*/
PRINT '=== E. Trailing partition must be empty ===';

SELECT partition_set
     , table_name
     , partition_number
     , lower_boundary_inclusive
     , number_of_rows
     , 'PROVISIONING IS BEHIND - extend partitions before the next split' AS action
FROM PartitionConfiguration.Partition_Information
WHERE upper_boundary_exclusive IS NULL      -- the trailing partition
  AND number_of_rows > 0
ORDER BY partition_set, table_name;
GO

PRINT '';
PRINT 'To act on the above:';
PRINT '  Preview : EXEC PartitionConfiguration.RetentionCleanup @DryRun = 1;';
PRINT '  Apply   : EXEC PartitionConfiguration.RetentionCleanup @DryRun = 0;';
PRINT '  Existing entry point (now delegates to the above):';
PRINT '    EXEC [eJarDbReports].[Jobs].[PurgeLogs_eJar] @Type=''Audit,State'', @Batch=10000;';
GO
