/*==============================================================================
  00_Preflight_Checks.sql
  ------------------------------------------------------------------------------
  RUN FIRST. Read-only. Aborts with RAISERROR if the environment is not ready.

  TARGET SERVER : SRV-AZ-AG002   <-- the PRIMARY replica for eJarDbAuditing
                                     (eJarDbAuditing is in AG "SQLAG02";
                                      SRV-AZ-AG01 is a READ-ONLY SECONDARY for it)
  RUN AS        : sqlcmd -S SRV-AZ-AG002 -d eJarDbAuditing -i 00_Preflight_Checks.sql

  This script verifies every assumption the migration depends on. Do not skip it.
==============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE eJarDbAuditing;
GO

DECLARE @Errors INT = 0;
DECLARE @Msg NVARCHAR(2000);

PRINT REPLICATE('=',78);
PRINT 'PREFLIGHT CHECKS - eJarDbAuditing partitioning';
PRINT 'Server   : ' + @@SERVERNAME;
PRINT 'Database : ' + DB_NAME();
PRINT 'UTC now  : ' + CONVERT(VARCHAR(30), SYSUTCDATETIME(), 121);
PRINT REPLICATE('=',78);

/*------------------------------------------------------------------------------
  1. Must be the PRIMARY replica. All DDL below fails on a secondary.
------------------------------------------------------------------------------*/
IF SERVERPROPERTY('IsHadrEnabled') = 1
BEGIN
    IF ISNULL(sys.fn_hadr_is_primary_replica(DB_NAME()), 0) <> 1
    BEGIN
        PRINT 'FAIL  [1] This is NOT the primary replica for ' + DB_NAME() + '.';
        PRINT '           Connect to the primary (SRV-AZ-AG002) and re-run.';
        SET @Errors += 1;
    END
    ELSE
        PRINT 'PASS  [1] Primary replica confirmed.';
END
ELSE
    PRINT 'WARN  [1] HADR not enabled on this instance - unexpected for this estate.';

/*------------------------------------------------------------------------------
  2. Edition must support partitioning + online index operations.
------------------------------------------------------------------------------*/
IF CAST(SERVERPROPERTY('EngineEdition') AS INT) NOT IN (3, 5, 8)   -- 3=Enterprise
BEGIN
    PRINT 'FAIL  [2] Edition does not support the required features: '
          + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));
    SET @Errors += 1;
END
ELSE
    PRINT 'PASS  [2] Edition OK: ' + CAST(SERVERPROPERTY('Edition') AS NVARCHAR(128));

/*------------------------------------------------------------------------------
  3. Instant File Initialization - without it, creating the partition files
     zero-fills and takes far longer.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.dm_server_services
           WHERE servicename LIKE 'SQL Server (%'
             AND instant_file_initialization_enabled = 'Y')
    PRINT 'PASS  [3] Instant File Initialization enabled.';
ELSE
    PRINT 'WARN  [3] Instant File Initialization NOT enabled. Grant the service '
          + 'account "Perform volume maintenance tasks" to speed up file creation.';

/*------------------------------------------------------------------------------
  4. Free space on the data volume vs. what the migration actually needs.
     The migration copies ONLY the retention window (see 02_Migration scripts),
     PAGE-compressed - not the whole 734 GB.
------------------------------------------------------------------------------*/
DECLARE @FreeGB DECIMAL(12,1), @DataPath NVARCHAR(260);

SELECT TOP 1
       @FreeGB   = CAST(vs.available_bytes/1073741824.0 AS DECIMAL(12,1)),
       @DataPath = vs.volume_mount_point
FROM sys.database_files df
CROSS APPLY sys.dm_os_volume_stats(DB_ID(), df.file_id) vs
WHERE df.type_desc = 'ROWS';

PRINT '      [4] Data volume ' + ISNULL(@DataPath,'?') + ' free space: '
      + CAST(ISNULL(@FreeGB,0) AS VARCHAR(20)) + ' GB';

/*----------------------------------------------------------------------------
  Measured 2026-08-29:
    PAGE-compressed, 12-month-retention-filtered target size  ~=  64 GB
    Partition files at creation (~33 x 1 GB)                  ~=  33 GB
    Peak during migration (files grow to hold the data)        ~=  70 GB

  The existing 772 GB .mdf does NOT grow: all clone data lands in the new
  per-period filegroups, and partition 1 (the only PRIMARY-mapped partition)
  receives zero rows because the migration copies only data at or after the
  first boundary.

  Free space measured per replica on the same date - the PRIMARY is the
  binding constraint, and files are created on all three:
    SRV-AZ-AG002 (primary)  D:\  185.9 GB
    SRV-AZ-AG01             D:\  217.1 GB
    SRV-AZ-AG03             D:\  876.7 GB

  100 GB threshold gives ~30 GB of headroom over the peak. Raise it if the
  retention policy is widened.
----------------------------------------------------------------------------*/
DECLARE @RequiredGB DECIMAL(12,1) = 100.0;

IF ISNULL(@FreeGB, 0) < @RequiredGB
BEGIN
    PRINT 'FAIL  [4] Need at least ' + CAST(@RequiredGB AS VARCHAR(20))
          + ' GB free; found ' + CAST(ISNULL(@FreeGB,0) AS VARCHAR(20)) + ' GB.';
    SET @Errors += 1;
END
ELSE
    PRINT 'PASS  [4] Sufficient free space.';

/*------------------------------------------------------------------------------
  5. Source table sizes - recorded so the runbook has the real numbers.
------------------------------------------------------------------------------*/
PRINT '      [5] Current source footprint:';
DECLARE @tbl SYSNAME, @rows BIGINT, @gb DECIMAL(12,2);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT t.name,
           SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END),
           CAST(SUM(ps.reserved_page_count)*8.0/1024/1024 AS DECIMAL(12,2))
    FROM sys.dm_db_partition_stats ps
    JOIN sys.tables t ON ps.object_id = t.object_id
    WHERE t.name IN ('AbpAuditLogs','AbpEntityChangeSets',
                     'AbpEntityChanges','AbpEntityPropertyChanges')
    GROUP BY t.name;
OPEN c; FETCH NEXT FROM c INTO @tbl, @rows, @gb;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '           ' + LEFT(@tbl + REPLICATE(' ',30), 30)
          + RIGHT(REPLICATE(' ',16) + CAST(@rows AS VARCHAR(20)), 16) + ' rows  '
          + RIGHT(REPLICATE(' ',10) + CAST(@gb AS VARCHAR(20)), 10) + ' GB';
    FETCH NEXT FROM c INTO @tbl, @rows, @gb;
END
CLOSE c; DEALLOCATE c;

/*------------------------------------------------------------------------------
  6. Objects that depend on the four tables. These must be re-tested after
     cutover - a rename rebinds them silently.
------------------------------------------------------------------------------*/
PRINT '      [6] Dependent objects requiring post-cutover regression testing:';
IF EXISTS (SELECT 1 FROM sys.sql_expression_dependencies
           WHERE referenced_entity_name LIKE 'Abp%')
BEGIN
    DECLARE @dep NVARCHAR(300);
    DECLARE d CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT o.type_desc + '  ' + OBJECT_SCHEMA_NAME(sed.referencing_id)
               + '.' + OBJECT_NAME(sed.referencing_id)
        FROM sys.sql_expression_dependencies sed
        JOIN sys.objects o ON sed.referencing_id = o.object_id
        WHERE sed.referenced_entity_name LIKE 'Abp%';
    OPEN d; FETCH NEXT FROM d INTO @dep;
    WHILE @@FETCH_STATUS = 0
    BEGIN PRINT '           ' + @dep; FETCH NEXT FROM d INTO @dep; END
    CLOSE d; DEALLOCATE d;
END
ELSE
    PRINT '           (none)';

/*------------------------------------------------------------------------------
  6b. CROSS-DATABASE dependencies. sys.sql_expression_dependencies is per
      database, so check [6] above CANNOT see them - and the most important
      consumer of these tables lives in another database.

      eJarDbReports holds SYNONYMS onto all four tables (created 2022-10-09),
      and [eJarDbReports].[Jobs].[PurgeLogs_eJar] is the live retention
      mechanism. Synonyms store a literal name, so across the cutover they:
        - break while the original is renamed to *_Old  (resolution fails)
        - heal once *_Clone is renamed into place
      They are therefore self-correcting, but PurgeLogs_eJar MUST NOT RUN during
      the cutover window.
------------------------------------------------------------------------------*/
PRINT '      [6b] Cross-database synonyms pointing at these tables:';
DECLARE @syn NVARCHAR(500);
DECLARE sy CURSOR LOCAL FAST_FORWARD FOR
    SELECT s.name + '  ->  ' + s.base_object_name
    FROM eJarDbReports.sys.synonyms s
    WHERE s.base_object_name LIKE '%[[]' + DB_NAME() + '[]]%Abp%';
OPEN sy; FETCH NEXT FROM sy INTO @syn;
IF @@FETCH_STATUS <> 0
    PRINT '           (none found - verify eJarDbReports is reachable)';
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT '           eJarDbReports.dbo.' + @syn;
    FETCH NEXT FROM sy INTO @syn;
END
CLOSE sy; DEALLOCATE sy;

IF OBJECT_ID('eJarDbReports.Jobs.PurgeLogs_eJar') IS NOT NULL
    PRINT '           [eJarDbReports].[Jobs].[PurgeLogs_eJar] EXISTS - this is the '
        + 'live retention proc. Replace it with 03_Replace_PurgeLogs_eJar.sql at '
        + 'cutover, and do not let it run during the cutover window.';

/*------------------------------------------------------------------------------
  7. Triggers would break EF Core's "MERGE ... OUTPUT INSERTED.Id" pattern.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.triggers WHERE OBJECT_NAME(parent_id) LIKE 'Abp%')
BEGIN
    PRINT 'FAIL  [7] Triggers exist on the Abp tables. EF Core uses '
          + 'MERGE ... OUTPUT INSERTED.[Id], which fails on a table with triggers.';
    SET @Errors += 1;
END
ELSE
    PRINT 'PASS  [7] No triggers on the Abp tables.';

/*------------------------------------------------------------------------------
  8. Objects from a previous run that would collide.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.partition_functions
           WHERE name IN ('PF_Auditing_Monthly','PF_AuditLogs_Daily'))
   OR EXISTS (SELECT 1 FROM sys.tables WHERE name LIKE 'Abp%_Clone')
BEGIN
    PRINT 'WARN  [8] Partition functions and/or _Clone tables already exist. '
          + 'This is a re-run. Verify state before continuing.';
END
ELSE
    PRINT 'PASS  [8] No leftover objects from a previous run.';

/*------------------------------------------------------------------------------
  9. MANUAL CHECK - cannot be verified from T-SQL. Read this and act.
------------------------------------------------------------------------------*/
PRINT '';
PRINT 'MANUAL [9] Verify on EVERY replica (SRV-AZ-AG01, SRV-AZ-AG002, SRV-AZ-AG03):';
PRINT '            - the data path below exists, with identical drive letter';
PRINT '            - it has the free space from check [4]';
PRINT '            - the SQL Server service account can write to it';
PRINT '           ADD FILE is redone on every secondary. If the path is missing';
PRINT '           on any replica, redo FAILS and the database leaves the AG.';
PRINT '           Path in use: ' + ISNULL(@DataPath,'(unknown)') + 'Data\';
PRINT '';

/*------------------------------------------------------------------------------
  Verdict
------------------------------------------------------------------------------*/
PRINT REPLICATE('=',78);
IF @Errors > 0
BEGIN
    SET @Msg = 'PREFLIGHT FAILED with ' + CAST(@Errors AS VARCHAR(10))
             + ' blocking error(s). Do not proceed.';
    PRINT @Msg;
    PRINT REPLICATE('=',78);
    RAISERROR(@Msg, 16, 1);
END
ELSE
BEGIN
    PRINT 'PREFLIGHT PASSED. Complete manual check [9], then run 01_Partition Management.';
    PRINT REPLICATE('=',78);
END
GO
