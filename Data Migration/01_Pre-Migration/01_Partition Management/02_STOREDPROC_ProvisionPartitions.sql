/*==============================================================================
  02_STOREDPROC_ProvisionPartitions.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  REVISED       : 2026-09-12 - DAY granularity, shared-filegroup mode,
                               configurable clock

  Replaces BOTH of the original procs:
      PartitionConfiguration.AutoCreatePartition            (initial build)
      PartitionConfiguration.AutoCreateNext52WeekPartitions (sliding window)

  Those two generated boundaries and filegroup names by different, incompatible
  rules, so the sliding window drifted off the pattern the initial build had
  established. One code path removes that class of bug: initial build and
  extension are now literally the same loop.

  ------------------------------------------------------------------------------
  Fixes carried in this file
  ------------------------------------------------------------------------------
  C6  The original derived @finalDate from @firstRunDate ('20210101' + 5y9m =
      2026-04-01), which was already in the PAST. All current data would have
      landed in the trailing partition (mapped to [PRIMARY]) and the first SPLIT
      would then have run offline against a populated partition. Boundaries are
      now always derived from the CURRENT date.

  W5  The original slot rule (DATEPART(DAY) <= 7 -> 0, <= 14 -> 1, <= 21 -> 2,
      ELSE 3) collided when +7-day stepping produced two boundaries past day 21
      in the same month (day 24 and day 31 both mapped to slot 3), so two
      partitions silently shared one filegroup and file. Period-start dates are
      now the filegroup identity, so collisions are impossible by construction.

  W6  252 filegroups/files reduced to ~16 for the monthly set, and ONE shared
      filegroup for the daily set. Every ADD FILE is redone on both secondaries
      of a SYNCHRONOUS_COMMIT AG; 252 was a large, avoidable risk and a daily
      per-partition file would have meant a create/drop every day forever.

  I2  RANGE LEFT with '23:59:59.997' boundaries was a datetime artifact applied
      to a datetime2(7) function, leaving a ~3 ms gap per boundary that fell
      into the next partition. Now RANGE RIGHT on clean midnight boundaries.

  I7  All identifiers pass through QUOTENAME; all dynamic SQL via sp_executesql.
  I8  One file-naming rule, not three.
  I9  Secondary files are .ndf, not .mdf.
  I11 Dropped the "SELECT TOP 4 MIN(row_number)" no-op.

  The obsolete view PartitionConfiguration.Partition_Query is dropped - the
  original non-first-run branch drove itself from it. It remains in the backup
  folder for reference.
==============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE eJarDbAuditing;
GO

IF OBJECT_ID('PartitionConfiguration.Partition_Query', 'V') IS NOT NULL
    DROP VIEW PartitionConfiguration.Partition_Query;
GO
IF OBJECT_ID('PartitionConfiguration.AutoCreatePartition', 'P') IS NOT NULL
    DROP PROCEDURE PartitionConfiguration.AutoCreatePartition;
GO
IF OBJECT_ID('PartitionConfiguration.AutoCreateNext52WeekPartitions', 'P') IS NOT NULL
    DROP PROCEDURE PartitionConfiguration.AutoCreateNext52WeekPartitions;
GO

/*==============================================================================
  Helper: the start of the period containing @d, for a given granularity.

  DAY   -> midnight of that day
  WEEK  -> the Monday of that week
  MONTH -> the 1st of that month

  1900-01-01 was a Monday, so the WEEK case is independent of SET DATEFIRST and
  @@LANGUAGE - it does not depend on session settings the Agent might differ on.
==============================================================================*/
CREATE OR ALTER FUNCTION PartitionConfiguration.fn_PeriodStart
(
      @d    DATETIME2(7)
    , @gran VARCHAR(10)
)
RETURNS DATETIME2(7)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE @gran
               WHEN 'DAY'   THEN CAST(CAST(@d AS DATE) AS DATETIME2(7))
               WHEN 'MONTH' THEN CAST(DATEFROMPARTS(YEAR(@d), MONTH(@d), 1) AS DATETIME2(7))
               WHEN 'WEEK'  THEN CAST(DATEADD(DAY,
                                     -(DATEDIFF(DAY, CAST('19000101' AS DATE), CAST(@d AS DATE)) % 7),
                                     CAST(@d AS DATE)) AS DATETIME2(7))
           END;
END
GO

/*==============================================================================
  Helper: create a filegroup and its file, idempotently.
==============================================================================*/
CREATE OR ALTER PROCEDURE PartitionConfiguration.usp_EnsureFilegroupAndFile
(
      @Filegroup SYSNAME
    , @DataPath  NVARCHAR(260)
    , @SizeMB    INT = 1024
    , @DryRun    BIT = 1
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql NVARCHAR(MAX);
    DECLARE @File SYSNAME = REPLACE(@Filegroup, 'FG_', 'File_');
    DECLARE @Full NVARCHAR(400) = @DataPath + DB_NAME() + N'_' + @File + N'.ndf';

    IF NOT EXISTS (SELECT 1 FROM sys.filegroups WHERE name = @Filegroup)
    BEGIN
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME())
                 + N' ADD FILEGROUP ' + QUOTENAME(@Filegroup) + N';';
        PRINT '  ' + @sql;
        IF @DryRun = 0 EXEC sp_executesql @sql;
    END

    IF NOT EXISTS (SELECT 1 FROM sys.database_files WHERE name = @File)
    BEGIN
        /*----------------------------------------------------------------------
          Sizing measured 2026-09-12:
            change tracking, 12 months PAGE-compressed ~= 42 GB -> ~3.5 GB/month
            audit logs, steady state                   ~= 30 GB

          Modest initial size on purpose. Most files a provisioning run creates
          are for FUTURE periods and sit empty for weeks, and the binding
          constraint is free space on the PRIMARY's data volume:

            SRV-AZ-AG002 (primary)  D:\  185.9 GB free
            SRV-AZ-AG01             D:\  217.1 GB free
            SRV-AZ-AG03             D:\  876.7 GB free

          Autogrowth is cheap because Instant File Initialization is enabled
          (verified instant_file_initialization_enabled = 'Y'), so a 1 GB growth
          is a metadata operation, not a zero-fill.

          The clone tables put nothing in PRIMARY: partition 1 is the
          pre-retention catch-all and the migration copies only data at or after
          the first boundary, so it receives zero rows. The existing 772 GB .mdf
          does not grow during the migration.
        ----------------------------------------------------------------------*/
        SET @sql = N'ALTER DATABASE ' + QUOTENAME(DB_NAME()) + N' ADD FILE ('
                 + N' NAME = ' + QUOTENAME(@File, '''')
                 + N', FILENAME = ' + QUOTENAME(@Full, '''')
                 + N', SIZE = ' + CAST(@SizeMB AS NVARCHAR(10)) + N'MB'
                 + N', MAXSIZE = UNLIMITED, FILEGROWTH = 1024MB)'
                 + N' TO FILEGROUP ' + QUOTENAME(@Filegroup) + N';';
        PRINT '  ' + @sql;
        IF @DryRun = 0 EXEC sp_executesql @sql;
    END
END
GO

/*==============================================================================
  ProvisionPartitions
==============================================================================*/
CREATE OR ALTER PROCEDURE PartitionConfiguration.ProvisionPartitions
(
      @SetName     SYSNAME
    , @ThroughDate DATE    = NULL   -- default: now + AheadUnits, in the set's unit
    , @DryRun      BIT     = 1      -- SAFE DEFAULT: print only, change nothing
)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*--------------------------------------------------------------------------
      C2/C5  Never run on a secondary. ADD FILEGROUP / ADD FILE / SPLIT all fail
             on a read-only replica, and after a failover this proc may be
             invoked on the wrong node.
    --------------------------------------------------------------------------*/
    IF SERVERPROPERTY('IsHadrEnabled') = 1
       AND ISNULL(sys.fn_hadr_is_primary_replica(DB_NAME()), 0) <> 1
    BEGIN
        PRINT 'ProvisionPartitions: not the primary replica for ' + DB_NAME()
              + ' - nothing to do.';
        RETURN 0;
    END

    DECLARE @PF SYSNAME, @PS SYSNAME, @Gran VARCHAR(10), @Prefix VARCHAR(20),
            @Path NVARCHAR(260), @Retention INT, @Ahead INT,
            @FgMode VARCHAR(15), @SharedFg SYSNAME, @Clock VARCHAR(5);

    SELECT @PF        = PartitionFunction
         , @PS        = PartitionScheme
         , @Gran      = Granularity
         , @Prefix    = FilegroupPrefix
         , @Path      = DataPath
         , @Retention = RetentionUnits
         , @Ahead     = AheadUnits
         , @FgMode    = FilegroupMode
         , @SharedFg  = SharedFilegroup
         , @Clock     = ClockSource
    FROM PartitionConfiguration.PartitionSet
    WHERE SetName = @SetName;

    IF @PF IS NULL
    BEGIN
        RAISERROR('ProvisionPartitions: unknown SetName ''%s''. See PartitionConfiguration.PartitionSet.',
                  16, 1, @SetName);
        RETURN 1;
    END

    /*--------------------------------------------------------------------------
      "Now" comes from the configured clock. The column value itself is never
      converted anywhere in this solution - see 01_TABLE_PartitionConfig.sql.
      Measured: the application writes UTC, so ClockSource defaults to 'UTC'.
    --------------------------------------------------------------------------*/
    DECLARE @Now DATETIME2(7) =
        CASE WHEN @Clock = 'LOCAL' THEN SYSDATETIME() ELSE SYSUTCDATETIME() END;

    IF @ThroughDate IS NULL
        SET @ThroughDate = CAST(
            CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   @Ahead, @Now)
                       WHEN 'WEEK'  THEN DATEADD(WEEK,  @Ahead, @Now)
                       WHEN 'MONTH' THEN DATEADD(MONTH, @Ahead, @Now)
            END AS DATE);

    DECLARE @sql NVARCHAR(MAX), @Created INT = 0;

    PRINT REPLICATE('-',78);
    PRINT 'ProvisionPartitions  set=' + @SetName + '  function=' + @PF;
    PRINT '  granularity  = ' + @Gran
        + '   retention = ' + CAST(@Retention AS VARCHAR(10)) + ' ' + @Gran + '(s)'
        + '   ahead = '     + CAST(@Ahead AS VARCHAR(10)) + ' ' + @Gran + '(s)';
    PRINT '  clock        = ' + @Clock + '  (now = ' + CONVERT(VARCHAR(30), @Now, 121) + ')';
    PRINT '  filegroups   = ' + @FgMode + ISNULL(' -> ' + @SharedFg, '');
    PRINT '  through date = ' + CONVERT(VARCHAR(10), @ThroughDate, 23)
        + '   DryRun = ' + CAST(@DryRun AS VARCHAR(1));
    PRINT REPLICATE('-',78);

    /* In SHARED mode every partition maps to one filegroup, sized for the whole
       steady-state set rather than for one period. */
    DECLARE @SharedSizeMB INT = 8192;   -- ~30 GB steady state, grows in 1 GB steps

    IF @FgMode = 'SHARED'
        EXEC PartitionConfiguration.usp_EnsureFilegroupAndFile
             @Filegroup = @SharedFg, @DataPath = @Path,
             @SizeMB = @SharedSizeMB, @DryRun = @DryRun;

    DECLARE @NextBoundary DATETIME2(7), @LastBoundary DATETIME2(7), @FG SYSNAME;

    /*==========================================================================
      1. Create the function + scheme on a first run.

         Partition 1 is deliberately an unbounded catch-all on [PRIMARY]:
         everything older than the retention window lands there and is emptied
         by the first retention run. That is why we do NOT pre-create partitions
         back to 2021 (or to MIN(ChangeTime) = 2013-05-12) as the original did -
         82-85% of existing rows are outside the retention window and are not
         being migrated at all.
    ==========================================================================*/
    IF NOT EXISTS (SELECT 1 FROM sys.partition_functions WHERE name = @PF)
    BEGIN
        DECLARE @FirstBoundary DATETIME2(7) =
            PartitionConfiguration.fn_PeriodStart(
                CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   -@Retention, @Now)
                           WHEN 'WEEK'  THEN DATEADD(WEEK,  -@Retention, @Now)
                           WHEN 'MONTH' THEN DATEADD(MONTH, -@Retention, @Now)
                END, @Gran);

        SET @FG = CASE WHEN @FgMode = 'SHARED' THEN @SharedFg
                       ELSE @Prefix + '_' +
                            CASE @Gran WHEN 'MONTH' THEN FORMAT(@FirstBoundary, 'yyyyMM')
                                       ELSE FORMAT(@FirstBoundary, 'yyyyMMdd') END
                  END;

        PRINT 'First run: creating function and scheme.';
        PRINT '  partition 1 = (-inf, ' + CONVERT(VARCHAR(30), @FirstBoundary, 121)
            + ')  -> [PRIMARY]   (pre-retention catch-all)';
        PRINT '  partition 2 = [' + CONVERT(VARCHAR(30), @FirstBoundary, 121)
            + ', +inf) -> ' + @FG;

        IF @FgMode <> 'SHARED'
            EXEC PartitionConfiguration.usp_EnsureFilegroupAndFile
                 @Filegroup = @FG, @DataPath = @Path, @DryRun = @DryRun;

        SET @sql = N'CREATE PARTITION FUNCTION ' + QUOTENAME(@PF)
                 + N' (datetime2(7)) AS RANGE RIGHT FOR VALUES (@b);';
        PRINT @sql;
        IF @DryRun = 0 EXEC sp_executesql @sql, N'@b datetime2(7)', @b = @FirstBoundary;

        SET @sql = N'CREATE PARTITION SCHEME ' + QUOTENAME(@PS)
                 + N' AS PARTITION ' + QUOTENAME(@PF)
                 + N' TO ([PRIMARY], ' + QUOTENAME(@FG) + N');';
        PRINT @sql;
        IF @DryRun = 0 EXEC sp_executesql @sql;

        SET @Created += 1;

        IF @DryRun = 1
        BEGIN
            PRINT '';
            PRINT 'DryRun = 1: stopping after the first-run preview. Re-run with';
            PRINT '@DryRun = 0 to create the structure, then again to extend it.';
            PRINT REPLICATE('-',78);
            RETURN 0;
        END
    END

    /*==========================================================================
      2. Extend forward, one period at a time, to @ThroughDate.

         Each iteration splits the trailing partition, which must be EMPTY for
         the split to be metadata-only. That is why AheadUnits headroom exists
         and why the provisioning job must run reliably (C4: the original job had
         no schedule at all).
    ==========================================================================*/
    SELECT @LastBoundary = MAX(CAST(prv.value AS DATETIME2(7)))
    FROM sys.partition_functions pf
    JOIN sys.partition_range_values prv ON pf.function_id = prv.function_id
    WHERE pf.name = @PF;

    IF @LastBoundary IS NULL
    BEGIN
        RAISERROR('ProvisionPartitions: function %s exists but has no boundaries.', 16, 1, @PF);
        RETURN 1;
    END

    SET @NextBoundary = CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   1, @LastBoundary)
                                   WHEN 'WEEK'  THEN DATEADD(WEEK,  1, @LastBoundary)
                                   WHEN 'MONTH' THEN DATEADD(MONTH, 1, @LastBoundary)
                       END;

    WHILE CAST(@NextBoundary AS DATE) <= @ThroughDate
    BEGIN
        SET @FG = CASE WHEN @FgMode = 'SHARED' THEN @SharedFg
                       ELSE @Prefix + '_' +
                            CASE @Gran WHEN 'MONTH' THEN FORMAT(@NextBoundary, 'yyyyMM')
                                       ELSE FORMAT(@NextBoundary, 'yyyyMMdd') END
                  END;

        PRINT '';
        PRINT 'boundary ' + CONVERT(VARCHAR(30), @NextBoundary, 121) + '  ->  ' + @FG;

        /* Guard: splitting a populated partition is a fully-logged, offline,
           size-of-data data movement under a SCH-M lock (C6). Refuse instead. */
        IF @DryRun = 0
        BEGIN
            DECLARE @RowsInLast BIGINT;

            SELECT @RowsInLast = ISNULL(SUM(p.rows), 0)
            FROM sys.partitions p
            JOIN sys.indexes i ON p.object_id = i.object_id AND p.index_id = i.index_id
            JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
            WHERE ps.name = @PS
              AND p.index_id IN (0,1)
              AND p.partition_number = (SELECT COUNT(*) + 1
                                        FROM sys.partition_functions pf2
                                        JOIN sys.partition_range_values prv2
                                             ON pf2.function_id = prv2.function_id
                                        WHERE pf2.name = @PF);

            IF @RowsInLast > 0
            BEGIN
                PRINT '  ABORT: trailing partition holds ' + CAST(@RowsInLast AS VARCHAR(20))
                    + ' row(s). Splitting it would move data offline.';
                PRINT '  Raise AheadUnits so provisioning stays ahead of the data, then retry.';
                RAISERROR('ProvisionPartitions: trailing partition is not empty for %s.',
                          16, 1, @PF);
                RETURN 1;
            END
        END

        IF @FgMode <> 'SHARED'
            EXEC PartitionConfiguration.usp_EnsureFilegroupAndFile
                 @Filegroup = @FG, @DataPath = @Path, @DryRun = @DryRun;

        SET @sql = N'ALTER PARTITION SCHEME ' + QUOTENAME(@PS)
                 + N' NEXT USED ' + QUOTENAME(@FG) + N';';
        PRINT '  ' + @sql;
        IF @DryRun = 0 EXEC sp_executesql @sql;

        SET @sql = N'ALTER PARTITION FUNCTION ' + QUOTENAME(@PF)
                 + N'() SPLIT RANGE (@b);';
        PRINT '  ' + @sql + '   -- @b = ' + CONVERT(VARCHAR(30), @NextBoundary, 121);
        IF @DryRun = 0 EXEC sp_executesql @sql, N'@b datetime2(7)', @b = @NextBoundary;

        SET @Created += 1;

        SET @NextBoundary = CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   1, @NextBoundary)
                                       WHEN 'WEEK'  THEN DATEADD(WEEK,  1, @NextBoundary)
                                       WHEN 'MONTH' THEN DATEADD(MONTH, 1, @NextBoundary)
                           END;
    END

    PRINT '';
    PRINT 'ProvisionPartitions: ' + CAST(@Created AS VARCHAR(10))
        + ' partition(s) provisioned for set ' + @SetName + '.';
    PRINT REPLICATE('-',78);
    RETURN 0;
END
GO

PRINT 'Created: PartitionConfiguration.fn_PeriodStart';
PRINT 'Created: PartitionConfiguration.usp_EnsureFilegroupAndFile';
PRINT 'Created: PartitionConfiguration.ProvisionPartitions';
GO
