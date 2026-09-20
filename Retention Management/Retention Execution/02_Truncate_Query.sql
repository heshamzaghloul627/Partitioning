/*==============================================================================
  02_Truncate_Query.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  PURPOSE       : manual, single-partition purge. For break-glass use only.

  ##############################################################################
  #  PREFER THE PROCEDURE                                                      #
  #                                                                            #
  #    EXEC PartitionConfiguration.RetentionCleanup @DryRun = 1;   -- preview   #
  #    EXEC PartitionConfiguration.RetentionCleanup @DryRun = 0;   -- apply     #
  #                                                                            #
  #  The procedure does the safety checks, the boundary merge and the filegroup #
  #  reclaim. This script does the truncate only, and leaves the partition,     #
  #  filegroup and file in place.                                              #
  ##############################################################################

  ------------------------------------------------------------------------------
  Changes from the original
  ------------------------------------------------------------------------------
  The original was four bare TRUNCATE statements with a literal
  "<PartitionNumber>" placeholder:

      TRUNCATE TABLE dbo.AbpEntityPropertyChanges WITH (PARTITIONS ( <PartitionNumber> ));
      ...

  Problems with shipping that as-is:
    * "<PartitionNumber>" is not valid T-SQL, so the file could not be run
      without hand-editing - and hand-editing a TRUNCATE against a 1.28 billion
      row table under time pressure is how accidents happen.
    * It included AbpAuditLogs alongside the three change-tracking tables. Those
      are now on SEPARATE partition functions with different retention, so
      partition number N means a different date range for each. Truncating "N"
      across all four would delete the wrong data.
    * No verification that the partition is actually outside retention.

  This version takes the partition number as a variable, verifies it first, and
  refuses to proceed if the partition contains data inside the retention window.
==============================================================================*/
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

/*==============================================================================
  SET THESE TWO, then run.
==============================================================================*/
DECLARE @SetName         SYSNAME = N'Auditing';   -- 'Auditing' or 'AuditLogs'
DECLARE @PartitionNumber INT     = 2;             -- from 01_Identify_Partition_to_Truncate.sql
DECLARE @DryRun          BIT     = 1;             -- set to 0 to actually truncate

/*==============================================================================
  Everything below is generated. No editing required.
==============================================================================*/
DECLARE @PF SYSNAME, @PS SYSNAME, @Gran VARCHAR(10), @Retention INT,
        @Cutoff DATETIME2(7), @Upper DATETIME2(7), @Lower DATETIME2(7),
        @sql NVARCHAR(MAX), @Errors INT = 0;

SELECT @PF = PartitionFunction, @PS = PartitionScheme,
       @Gran = Granularity, @Retention = RetentionUnits
FROM PartitionConfiguration.PartitionSet
WHERE SetName = @SetName;

IF @PF IS NULL
BEGIN
    RAISERROR('Unknown SetName ''%s''. Valid values are in PartitionConfiguration.PartitionSet.', 16, 1, @SetName);
    SET NOEXEC ON;
END

/* "Now" from the set's configured clock; the column value itself is compared
   as-is, with no conversion. Measured: the application writes UTC.            */
DECLARE @Clock VARCHAR(5);
SELECT @Clock = ClockSource FROM PartitionConfiguration.PartitionSet WHERE SetName = @SetName;

DECLARE @Now DATETIME2(7) =
    CASE WHEN @Clock = 'LOCAL' THEN SYSDATETIME() ELSE SYSUTCDATETIME() END;

SET @Cutoff = CASE @Gran WHEN 'DAY'   THEN DATEADD(DAY,   -@Retention, @Now)
                         WHEN 'WEEK'  THEN DATEADD(WEEK,  -@Retention, @Now)
                         WHEN 'MONTH' THEN DATEADD(MONTH, -@Retention, @Now) END;

SELECT @Upper = MAX(CASE WHEN boundary_id = @PartitionNumber     THEN CAST(value AS DATETIME2(7)) END)
     , @Lower = MAX(CASE WHEN boundary_id = @PartitionNumber - 1 THEN CAST(value AS DATETIME2(7)) END)
FROM sys.partition_range_values prv
JOIN sys.partition_functions pf ON pf.function_id = prv.function_id
WHERE pf.name = @PF;

PRINT REPLICATE('=',78);
PRINT 'Set              : ' + @SetName + '  (' + @PF + ')';
PRINT 'Partition        : ' + CAST(@PartitionNumber AS VARCHAR(10));
PRINT 'Range            : [' + ISNULL(CONVERT(VARCHAR(30), @Lower, 121), '-infinity')
                      + ', ' + ISNULL(CONVERT(VARCHAR(30), @Upper, 121), '+infinity') + ')';
PRINT 'Retention cutoff : ' + CONVERT(VARCHAR(30), @Cutoff, 121)
                      + '  (' + CAST(@Retention AS VARCHAR(10)) + ' ' + @Gran + 's)';
PRINT 'DryRun           : ' + CAST(@DryRun AS VARCHAR(1));
PRINT REPLICATE('=',78);

/*------------------------------------------------------------------------------
  Gate 1 - the trailing partition has no upper bound and must never be truncated
  this way; it holds current data.
------------------------------------------------------------------------------*/
IF @Upper IS NULL
BEGIN
    PRINT 'REFUSED: partition ' + CAST(@PartitionNumber AS VARCHAR(10))
        + ' is the trailing partition and holds current data.';
    SET @Errors += 1;
END

/*------------------------------------------------------------------------------
  Gate 2 - the whole partition must be outside retention.
------------------------------------------------------------------------------*/
IF @Upper IS NOT NULL AND @Upper > @Cutoff
BEGIN
    PRINT 'REFUSED: upper boundary ' + CONVERT(VARCHAR(30), @Upper, 121)
        + ' is INSIDE the retention window (cutoff ' + CONVERT(VARCHAR(30), @Cutoff, 121) + ').';
    SET @Errors += 1;
END

IF @Errors > 0
BEGIN
    RAISERROR('Refusing to truncate. Nothing was changed.', 16, 1);
    SET NOEXEC ON;
END

/*------------------------------------------------------------------------------
  Report what will go, then truncate child-before-parent.
------------------------------------------------------------------------------*/
SELECT table_name, partition_number, filegroup_name,
       lower_boundary_inclusive, upper_boundary_exclusive,
       number_of_rows, reserved_mb
FROM PartitionConfiguration.Partition_Information
WHERE partition_scheme = @PS AND partition_number = @PartitionNumber
ORDER BY table_name;

DECLARE @Tables TABLE (Seq INT IDENTITY(1,1), SchemaName SYSNAME, TableName SYSNAME);

INSERT @Tables (SchemaName, TableName)
SELECT s.name, t.name
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
WHERE ps.name = @PS
ORDER BY CASE t.name
             WHEN 'AbpEntityPropertyChanges' THEN 1   -- child
             WHEN 'AbpEntityChanges'         THEN 2
             WHEN 'AbpEntityChangeSets'      THEN 3   -- parent
             ELSE 4
         END;

DECLARE @Seq INT = 1, @Sch SYSNAME, @Tbl SYSNAME;

WHILE EXISTS (SELECT 1 FROM @Tables WHERE Seq = @Seq)
BEGIN
    SELECT @Sch = SchemaName, @Tbl = TableName FROM @Tables WHERE Seq = @Seq;

    SET @sql = N'TRUNCATE TABLE ' + QUOTENAME(@Sch) + N'.' + QUOTENAME(@Tbl)
             + N' WITH (PARTITIONS (' + CAST(@PartitionNumber AS NVARCHAR(10)) + N'));';
    PRINT @sql;
    IF @DryRun = 0 EXEC sp_executesql @sql;

    SET @Seq += 1;
END

IF @DryRun = 1
    PRINT 'DryRun = 1: nothing was truncated.';
ELSE
BEGIN
    PRINT 'Truncated partition ' + CAST(@PartitionNumber AS VARCHAR(10)) + '.';
    PRINT 'NOTE: the partition, its filegroup and its file still exist. Use';
    PRINT '      PartitionConfiguration.RetentionCleanup to also merge the boundary';
    PRINT '      and reclaim the filegroup and file (W4).';
END
GO

SET NOEXEC OFF;
GO
