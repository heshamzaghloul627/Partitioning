/*==============================================================================
  03_Rollback_Cutover.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  PURPOSE       : reverse 02_Cutover.sql. Puts the original unpartitioned tables
                  back in service.

  W9: the original "Optional Rollback" folder contained four more copies of the
  bulk-copy script. That rolls back nothing - it just re-runs the load. This is
  the actual rollback.

  ------------------------------------------------------------------------------
  PRECONDITION
  ------------------------------------------------------------------------------
  Only valid while the *_Old tables still exist, i.e. before
  04_Decommission_Old_Tables.sql has been run. After that point there is no
  rollback and recovery is from backup.

  ------------------------------------------------------------------------------
  DATA WRITTEN AFTER CUTOVER IS NOT MERGED BACK
  ------------------------------------------------------------------------------
  Any audit rows the application wrote to the new partitioned tables between
  cutover and rollback stay in the *_Clone tables. They are NOT copied into the
  restored originals - doing that automatically would risk Id collisions with
  the reseeded identity.

  The script reports how many such rows exist. If the number is non-zero and the
  data matters, extract it manually before releasing the application:

      SELECT * FROM dbo.AbpEntityChanges_Clone
      WHERE Id > <MaxId recorded in dbo.MigrationCutoverLog for phase RESEED>;
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
  STEP 0 - GATES
==============================================================================*/
DECLARE @Errors INT = 0;

IF (SELECT COUNT(*) FROM sys.tables
    WHERE name IN ('AbpAuditLogs_Old','AbpEntityChangeSets_Old',
                   'AbpEntityChanges_Old','AbpEntityPropertyChanges_Old')) <> 4
BEGIN
    PRINT 'FAIL [0a] The four *_Old tables are not all present. Rollback is not';
    PRINT '          possible - recover from backup instead.';
    SET @Errors += 1;
END
ELSE PRINT 'PASS [0a] All four *_Old tables present.';

IF EXISTS (
    SELECT 1
    FROM sys.dm_tran_locks l
    JOIN sys.dm_exec_sessions s ON l.request_session_id = s.session_id
    WHERE l.resource_database_id = DB_ID()
      AND l.resource_associated_entity_id IN (
            OBJECT_ID('dbo.AbpAuditLogs'), OBJECT_ID('dbo.AbpEntityChangeSets'),
            OBJECT_ID('dbo.AbpEntityChanges'), OBJECT_ID('dbo.AbpEntityPropertyChanges'))
      AND s.session_id <> @@SPID AND s.is_user_process = 1)
BEGIN
    PRINT 'FAIL [0b] Application still connected. Quiesce it first.';
    SET @Errors += 1;
END
ELSE PRINT 'PASS [0b] No competing sessions.';

IF @Errors > 0
BEGIN
    RAISERROR('Rollback gates failed with %d error(s). Nothing changed.', 16, 1, @Errors);
    SET NOEXEC ON;
END
GO

/*==============================================================================
  STEP 1 - REPORT ROWS WRITTEN SINCE CUTOVER (these will be left behind)
==============================================================================*/
PRINT '';
PRINT 'Rows written to the partitioned tables since cutover (NOT merged back):';

SELECT t.name AS table_name,
       SUM(CASE WHEN dps.index_id IN (0,1) THEN dps.row_count ELSE 0 END) AS current_rows,
       (SELECT MAX(l.MaxId) FROM dbo.MigrationCutoverLog l
        WHERE l.Phase = 'RESEED' AND l.TableName = t.name) AS max_id_at_cutover
FROM sys.tables t
LEFT JOIN sys.dm_db_partition_stats dps ON dps.object_id = t.object_id
WHERE t.name IN ('AbpAuditLogs','AbpEntityChangeSets',
                 'AbpEntityChanges','AbpEntityPropertyChanges')
GROUP BY t.name
ORDER BY t.name;
GO

/*==============================================================================
  STEP 2 - REVERSE THE RENAME
==============================================================================*/
BEGIN TRY
    BEGIN TRANSACTION;

    -- 2a. Partitioned tables and their objects back to _Clone names.
    EXEC sp_rename N'dbo.AbpEntityPropertyChanges.IX_AbpEntityPropertyChanges_EntityChangeId',
                   N'IX_AbpEntityPropertyChanges_Clone_EntityChangeId', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityPropertyChanges.IX_AbpEntityPropertyChanges_ChangeTime_Id',
                   N'IX_AbpEntityPropertyChanges_Clone_ChangeTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_EntityId_EntityTypeFullName',
                   N'IX_AbpEntityChanges_Clone_EntityId_EntityTypeFullName', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_EntityChangeSetId',
                   N'IX_AbpEntityChanges_Clone_EntityChangeSetId', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_ChangeTime_EntityTypeFullName',
                   N'IX_AbpEntityChanges_Clone_ChangeTime_EntityTypeFullName', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_ChangeTime_Id',
                   N'IX_AbpEntityChanges_Clone_ChangeTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_CreationTime',
                   N'IX_AbpEntityChangeSets_Clone_CreationTime', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_CreationTime_Id',
                   N'IX_AbpEntityChangeSets_Clone_CreationTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpAuditLogs.IX_AbpAuditLogs_ExecutionTime_Exception',
                   N'IX_AbpAuditLogs_Clone_ExecutionTime_Exception', 'INDEX';
    EXEC sp_rename N'dbo.AbpAuditLogs.IX_AbpAuditLogs_ExecutionTime_Id',
                   N'IX_AbpAuditLogs_Clone_ExecutionTime_Id', 'INDEX';

    EXEC sp_rename 'dbo.DF_AbpEntityPropertyChanges_ChangeTime',
                   'DF_AbpEntityPropertyChanges_Clone_ChangeTime', 'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityPropertyChanges', 'PK_AbpEntityPropertyChanges_Clone', 'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChanges',         'PK_AbpEntityChanges_Clone',         'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChangeSets',      'PK_AbpEntityChangeSets_Clone',      'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpAuditLogs',             'PK_AbpAuditLogs_Clone',             'OBJECT';

    EXEC sp_rename 'dbo.AbpEntityPropertyChanges', 'AbpEntityPropertyChanges_Clone';
    EXEC sp_rename 'dbo.AbpEntityChanges',         'AbpEntityChanges_Clone';
    EXEC sp_rename 'dbo.AbpEntityChangeSets',      'AbpEntityChangeSets_Clone';
    EXEC sp_rename 'dbo.AbpAuditLogs',             'AbpAuditLogs_Clone';

    -- 2b. Originals back into service.
    EXEC sp_rename 'dbo.AbpEntityPropertyChanges_Old', 'AbpEntityPropertyChanges';
    EXEC sp_rename 'dbo.AbpEntityChanges_Old',         'AbpEntityChanges';
    EXEC sp_rename 'dbo.AbpEntityChangeSets_Old',      'AbpEntityChangeSets';
    EXEC sp_rename 'dbo.AbpAuditLogs_Old',             'AbpAuditLogs';

    EXEC sp_rename 'dbo.PK_AbpAuditLogs_Old',             'PK_AbpAuditLogs',             'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChangeSets_Old',      'PK_AbpEntityChangeSets',      'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChanges_Old',         'PK_AbpEntityChanges',         'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityPropertyChanges_Old', 'PK_AbpEntityPropertyChanges', 'OBJECT';

    EXEC sp_rename N'dbo.AbpAuditLogs.IX_AbpAuditLogs_ExecutionTime_Exception_Old',
                   N'IX_AbpAuditLogs_ExecutionTime_Exception', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_UserId_Old',
                   N'IX_AbpEntityChangeSets_UserId', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_CreationTime_Old',
                   N'IX_AbpEntityChangeSets_CreationTime', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_EntityChangeSetId_Old',
                   N'IX_AbpEntityChanges_EntityChangeSetId', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_ChangeTime_EntityTypeFullName_Old',
                   N'IX_AbpEntityChanges_ChangeTime_EntityTypeFullName', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_EntityId_EntityTypeFullName_Old',
                   N'IX_AbpEntityChanges_EntityId_EntityTypeFullName', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityPropertyChanges.IX_AbpEntityPropertyChanges_EntityChangeId_Old',
                   N'IX_AbpEntityPropertyChanges_EntityChangeId', 'INDEX';

    COMMIT TRANSACTION;
    PRINT 'Rename reversed.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'ROLLBACK FAILED and was itself rolled back. Error '
          + CAST(ERROR_NUMBER() AS VARCHAR(10)) + ': ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/*==============================================================================
  STEP 3 - IDENTITY. The originals were never reseeded, but the app inserted
  into the partitioned copies, so re-assert the counter on the restored tables.
==============================================================================*/
DECLARE @t SYSNAME, @max BIGINT, @sql NVARCHAR(500);
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.tables
    WHERE name IN ('AbpAuditLogs','AbpEntityChangeSets',
                   'AbpEntityChanges','AbpEntityPropertyChanges');
OPEN cur; FETCH NEXT FROM cur INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @m = ISNULL(MAX(Id),0) FROM dbo.' + QUOTENAME(@t) + N';';
    EXEC sp_executesql @sql, N'@m BIGINT OUTPUT', @m = @max OUTPUT;
    PRINT 'RESEED dbo.' + @t + ' -> ' + CAST(@max AS VARCHAR(20));
    SET @sql = N'DBCC CHECKIDENT (''dbo.' + @t + N''', RESEED, ' + CAST(@max AS NVARCHAR(20)) + N');';
    EXEC sp_executesql @sql;
    FETCH NEXT FROM cur INTO @t;
END
CLOSE cur; DEALLOCATE cur;
GO

EXEC sp_recompile 'dbo.AbpAuditLogs';
EXEC sp_recompile 'dbo.AbpEntityChangeSets';
EXEC sp_recompile 'dbo.AbpEntityChanges';
EXEC sp_recompile 'dbo.AbpEntityPropertyChanges';
GO

IF OBJECT_ID('dbo.AbpAuditLogs_Lite', 'V') IS NOT NULL EXEC sp_refreshsqlmodule 'dbo.AbpAuditLogs_Lite';
IF OBJECT_ID('dbo.FindError', 'P') IS NOT NULL           EXEC sp_refreshsqlmodule 'dbo.FindError';
IF OBJECT_ID('dbo.FindSuccess', 'P') IS NOT NULL         EXEC sp_refreshsqlmodule 'dbo.FindSuccess';
IF OBJECT_ID('dbo.FindEntityChanges', 'P') IS NOT NULL   EXEC sp_refreshsqlmodule 'dbo.FindEntityChanges';
GO

/*==============================================================================
  STEP 4 - DISABLE THE NEW JOBS. They target partition objects the application
  is no longer using; leaving them enabled would fail nightly.
==============================================================================*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'Partition_AutoIncrement_eJarDbAuditing')
    EXEC msdb.dbo.sp_update_job @job_name = N'Partition_AutoIncrement_eJarDbAuditing', @enabled = 0;
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'TruncatePartition_eJarDbAuditing')
    EXEC msdb.dbo.sp_update_job @job_name = N'TruncatePartition_eJarDbAuditing', @enabled = 0;
GO

INSERT dbo.MigrationCutoverLog (Phase, TableName, Notes)
SELECT 'ROLLBACK', name, 'cutover rolled back'
FROM sys.tables
WHERE name IN ('AbpAuditLogs','AbpEntityChangeSets',
               'AbpEntityChanges','AbpEntityPropertyChanges');
GO

SET NOEXEC OFF;
GO

SELECT t.name AS table_name,
       ISNULL(ps.name, '(not partitioned - original restored)') AS partition_scheme,
       IDENT_CURRENT('dbo.' + t.name) AS identity_current
FROM sys.tables t
JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
LEFT JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
WHERE t.name IN ('AbpAuditLogs','AbpEntityChangeSets',
                 'AbpEntityChanges','AbpEntityPropertyChanges')
ORDER BY t.name;
GO

PRINT '';
PRINT 'ROLLBACK COMPLETE. The originals are back in service; the partitioned';
PRINT 'copies remain as *_Clone. Both jobs have been disabled.';
GO
