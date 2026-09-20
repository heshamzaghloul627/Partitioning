/*==============================================================================
  04_Decommission_Old_Tables.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  RUN WHEN      : the application has been verified healthy on the partitioned
                  tables for an agreed period (suggest a minimum of 7 days, and
                  at least one full backup cycle).

  ##############################################################################
  #  THIS IS THE POINT OF NO RETURN. AFTER THIS, 03_Rollback_Cutover.sql        #
  #  CANNOT BE USED AND RECOVERY IS FROM BACKUP ONLY.                          #
  ##############################################################################

  This is also where the space is actually reclaimed. Measured 2026-08-29:

      eJarDbAuditing.mdf              772.36 GB   (single file, PRIMARY)
      the four Abp tables             733.92 GB   (99.99% of all objects)
      D:\ free                        217.10 GB

  Dropping the *_Old tables frees ~734 GB INSIDE the data file. It does not
  return anything to the operating system - that needs SHRINKFILE, in stages.

  Every step below is deliberately manual and commented out. Read each one,
  then uncomment it.
==============================================================================*/
SET NOCOUNT ON;
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
  STEP 1 - PRE-DROP REVIEW. Run this and read it before anything else.
==============================================================================*/
PRINT 'Tables that will be dropped:';
SELECT t.name AS table_name,
       SUM(CASE WHEN dps.index_id IN (0,1) THEN dps.row_count ELSE 0 END) AS row_count,
       CAST(SUM(dps.reserved_page_count)*8.0/1024/1024 AS DECIMAL(12,2))  AS reserved_gb
FROM sys.tables t
JOIN sys.dm_db_partition_stats dps ON dps.object_id = t.object_id
WHERE t.name LIKE 'Abp%_Old'
GROUP BY t.name
ORDER BY t.name;
GO

PRINT 'Tables that will REMAIN in service:';
SELECT t.name AS table_name,
       ISNULL(ps.name,'(not partitioned)') AS partition_scheme,
       SUM(CASE WHEN dps.index_id IN (0,1) THEN dps.row_count ELSE 0 END) AS row_count,
       CAST(SUM(dps.reserved_page_count)*8.0/1024/1024 AS DECIMAL(12,2))  AS reserved_gb
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
LEFT JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
JOIN sys.dm_db_partition_stats dps ON dps.object_id = t.object_id
WHERE t.name IN ('AbpAuditLogs','AbpEntityChangeSets',
                 'AbpEntityChanges','AbpEntityPropertyChanges')
GROUP BY t.name, ps.name
ORDER BY t.name;
GO

/*------------------------------------------------------------------------------
  GATE: refuse to continue unless the live tables are the partitioned ones.
  Protects against running this before cutover, or after a rollback.
------------------------------------------------------------------------------*/
IF (SELECT COUNT(*)
    FROM sys.tables t
    JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
    JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
    WHERE t.name IN ('AbpAuditLogs','AbpEntityChangeSets',
                     'AbpEntityChanges','AbpEntityPropertyChanges')) <> 4
BEGIN
    RAISERROR('The four live Abp tables are NOT all partitioned. Either cutover has not happened or it was rolled back. Refusing to drop the *_Old tables.', 16, 1);
    SET NOEXEC ON;
END
ELSE
    PRINT 'GATE PASSED: all four live tables are partitioned.';
GO

/*==============================================================================
  STEP 2 - TAKE A BACKUP FIRST. Not optional.
  ------------------------------------------------------------------------------
  BACKUP DATABASE eJarDbAuditing
  TO DISK = 'L:\Backup\eJarDbAuditing_PreDecommission.bak'
  WITH COMPRESSION, CHECKSUM, INIT, STATS = 5;
  GO
==============================================================================*/

/*==============================================================================
  STEP 3 - DROP THE OLD TABLES.

  Drop the largest first so space frees up early. These are metadata + deferred
  deallocation operations; the background cleanup of ~734 GB of extents takes a
  while and generates IO. Run off-peak.

  Note there are no foreign keys anywhere on these tables (verified 2026-08-29),
  so drop order does not matter for referential reasons - only for space.
  ------------------------------------------------------------------------------
  DROP TABLE dbo.AbpEntityPropertyChanges_Old;   -- 389.13 GB
  GO
  DROP TABLE dbo.AbpEntityChanges_Old;           -- 269.35 GB
  GO
  DROP TABLE dbo.AbpEntityChangeSets_Old;        --  45.03 GB
  GO
  DROP TABLE dbo.AbpAuditLogs_Old;               --  30.41 GB
  GO
==============================================================================*/

/*==============================================================================
  STEP 4 - RECLAIM SPACE TO THE OPERATING SYSTEM.

  Only after the drops have fully deallocated. Check free space inside the file
  first - there is no point shrinking what is already in use:
  ------------------------------------------------------------------------------
  SELECT name,
         CAST(size*8.0/1024/1024 AS DECIMAL(12,2))                        AS file_gb,
         CAST(FILEPROPERTY(name,'SpaceUsed')*8.0/1024/1024 AS DECIMAL(12,2)) AS used_gb,
         CAST((size - FILEPROPERTY(name,'SpaceUsed'))*8.0/1024/1024 AS DECIMAL(12,2)) AS free_in_file_gb
  FROM sys.database_files WHERE type_desc = 'ROWS';
  GO
  ------------------------------------------------------------------------------
  SHRINKFILE IN STAGES, NOT IN ONE CALL.

  A single shrink from 772 GB to ~70 GB on an AG-replicated file is a long,
  fully-logged, single-threaded operation that cannot be paused, and it will
  saturate D:\ (measured write latency on this estate has reached seconds).
  Step down in ~50 GB increments so each call is interruptible and the log and
  AG redo queue stay bounded. Take a log backup between steps.

  DBCC SHRINKFILE (N'eJarDbAuditing', 700000);   -- ~700 GB
  GO
  BACKUP LOG eJarDbAuditing TO DISK = 'L:\Backup\eJarDbAuditing_shrink_01.trn' WITH COMPRESSION;
  GO
  DBCC SHRINKFILE (N'eJarDbAuditing', 650000);
  GO
  ... continue in steps down to roughly 100000 (100 GB), leaving headroom ...

  Do NOT use TRUNCATEONLY here - the free space is scattered through the file,
  not at the end, so TRUNCATEONLY will reclaim almost nothing.
==============================================================================*/

/*==============================================================================
  STEP 5 - REBUILD AFTER SHRINKING.

  SHRINKFILE moves pages from the end of the file to the front and leaves heavy
  logical fragmentation behind. The partitioned indexes must be rebuilt. Do this
  per partition to keep each operation small:
  ------------------------------------------------------------------------------
  ALTER INDEX ALL ON dbo.AbpEntityPropertyChanges
        REBUILD PARTITION = <n> WITH (DATA_COMPRESSION = PAGE, ONLINE = ON, MAXDOP = 8);
  GO
  ------------------------------------------------------------------------------
  Then re-enable the maintenance job that is currently switched off for this
  database (W13) - it is why the read queries were slow in the first place:

  EXEC msdb.dbo.sp_update_job @job_name = N'Operation_IndexOptimize', @enabled = 1;
  GO
==============================================================================*/

SET NOEXEC OFF;
GO

PRINT '';
PRINT 'This script performs NO destructive action as shipped - every step is';
PRINT 'commented out. Uncomment them one at a time, in order, off-peak.';
GO
