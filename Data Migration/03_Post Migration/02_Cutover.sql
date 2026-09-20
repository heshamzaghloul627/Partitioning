/*==============================================================================
  02_Cutover.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)
  RUN WHEN      : application quiesced, Run-Delta.ps1 reported all deltas = 0,
                  01_Create_Nonclustered_Indexes.sql completed.

  ##############################################################################
  #  W9 - THIS SCRIPT DID NOT EXIST                                            #
  ##############################################################################

  The original folder was structured 01_Pre-Migration -> 02_Migration ->
  03_Post Migration but contained NOTHING that made the application start using
  the partitioned tables. Missing pieces, all of them required:

    * the rename itself
    * DBCC CHECKIDENT reseed. All four tables use Id BIGINT IDENTITY(1,1) and
      the clone was loaded with SqlBulkCopy KeepIdentity, which does NOT advance
      the identity counter. Without a reseed the counter sits at its seed value
      and the FIRST application insert after cutover fails on the primary key.
    * constraint/index renaming, so the live schema is not littered with
      "_Clone" object names
    * a rollback path. The original "Optional Rollback" folder contained only
      four more copies of the bulk-copy script, which is not a rollback of a
      cutover.

  The original tables are renamed to *_Old, NOT dropped. They are your rollback.
  Drop them with 04_Decommission_Old_Tables.sql only after the application has
  been verified healthy for an agreed period.

  ------------------------------------------------------------------------------
  SPACE NOTE
  ------------------------------------------------------------------------------
  While *_Old and the new tables coexist, the data file holds both. Measured
  2026-08-29: the .mdf is 772.36 GB with D:\ at 217.1 GB free, and the
  PAGE-compressed retention-window clone is ~64 GB. The file will autogrow by
  roughly that much. Confirm free space before running.
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
  STEP 0 - GATES. All four must pass or the script stops.
==============================================================================*/
DECLARE @Errors INT = 0;

-- 0a. All four clone tables exist and are partitioned.
IF (SELECT COUNT(*) FROM sys.tables t
    JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0,1)
    JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
    WHERE t.name IN ('AbpAuditLogs_Clone','AbpEntityChangeSets_Clone',
                     'AbpEntityChanges_Clone','AbpEntityPropertyChanges_Clone')) <> 4
BEGIN
    PRINT 'FAIL [0a] Expected 4 partitioned _Clone tables.';
    SET @Errors += 1;
END
ELSE PRINT 'PASS [0a] Four partitioned _Clone tables present.';

-- 0b. Every clone index is aligned, or TRUNCATE-based retention will not work.
IF EXISTS (
    SELECT 1 FROM sys.indexes i
    LEFT JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
    WHERE OBJECT_NAME(i.object_id) LIKE 'Abp%_Clone' AND i.type > 0 AND ps.name IS NULL)
BEGIN
    PRINT 'FAIL [0b] One or more clone indexes are NOT partition-aligned.';
    SET @Errors += 1;
END
ELSE PRINT 'PASS [0b] All clone indexes are partition-aligned.';

-- 0c. C3 - the ChangeTime default must exist, or every app write fails.
IF NOT EXISTS (
    SELECT 1 FROM sys.columns c
    JOIN sys.default_constraints dc ON c.default_object_id = dc.object_id
    WHERE c.object_id = OBJECT_ID('dbo.AbpEntityPropertyChanges_Clone')
      AND c.name = 'ChangeTime')
BEGIN
    PRINT 'FAIL [0c] AbpEntityPropertyChanges_Clone.ChangeTime has NO DEFAULT.';
    PRINT '          The application does not supply this column - every INSERT';
    PRINT '          would fail with Msg 515. See C3 in the table DDL.';
    SET @Errors += 1;
END
ELSE PRINT 'PASS [0c] ChangeTime DEFAULT constraint present.';

-- 0d. No open transactions or active sessions against the source tables.
IF EXISTS (
    SELECT 1
    FROM sys.dm_tran_locks l
    JOIN sys.dm_exec_sessions s ON l.request_session_id = s.session_id
    WHERE l.resource_database_id = DB_ID()
      AND l.resource_associated_entity_id IN (
            OBJECT_ID('dbo.AbpAuditLogs'), OBJECT_ID('dbo.AbpEntityChangeSets'),
            OBJECT_ID('dbo.AbpEntityChanges'), OBJECT_ID('dbo.AbpEntityPropertyChanges'))
      AND s.session_id <> @@SPID
      AND s.is_user_process = 1)
BEGIN
    PRINT 'FAIL [0d] Other sessions hold locks on the source tables.';
    PRINT '          The application is not fully quiesced. Sessions:';
    SELECT DISTINCT s.session_id, s.login_name, s.host_name, s.program_name, s.status
    FROM sys.dm_tran_locks l
    JOIN sys.dm_exec_sessions s ON l.request_session_id = s.session_id
    WHERE l.resource_database_id = DB_ID()
      AND l.resource_associated_entity_id IN (
            OBJECT_ID('dbo.AbpAuditLogs'), OBJECT_ID('dbo.AbpEntityChangeSets'),
            OBJECT_ID('dbo.AbpEntityChanges'), OBJECT_ID('dbo.AbpEntityPropertyChanges'))
      AND s.session_id <> @@SPID AND s.is_user_process = 1;
    SET @Errors += 1;
END
ELSE PRINT 'PASS [0d] No competing sessions on the source tables.';

IF @Errors > 0
BEGIN
    RAISERROR('Cutover gates failed with %d error(s). Nothing has been changed.', 16, 1, @Errors);
    SET NOEXEC ON;
END
GO

/*==============================================================================
  STEP 1 - RECORD PRE-CUTOVER ROW COUNTS, for the record and for rollback.
==============================================================================*/
IF OBJECT_ID('dbo.MigrationCutoverLog') IS NULL
    CREATE TABLE dbo.MigrationCutoverLog
    (
          LogId        INT IDENTITY(1,1) PRIMARY KEY
        , CapturedAt   DATETIME2(3) NOT NULL CONSTRAINT DF_MigrationCutoverLog_At
                       DEFAULT (SYSUTCDATETIME())
        , Phase        VARCHAR(30)  NOT NULL
        , TableName    SYSNAME      NOT NULL
        , RowCountVal  BIGINT       NULL
        , MaxId        BIGINT       NULL
        , Notes        NVARCHAR(400) NULL
    );
GO

INSERT dbo.MigrationCutoverLog (Phase, TableName, RowCountVal, MaxId, Notes)
SELECT 'PRE-CUTOVER', t.name,
       SUM(CASE WHEN ps.index_id IN (0,1) THEN ps.row_count ELSE 0 END),
       NULL,
       'reserved_gb=' + CAST(CAST(SUM(ps.reserved_page_count)*8.0/1024/1024 AS DECIMAL(12,2)) AS VARCHAR(20))
FROM sys.dm_db_partition_stats ps
JOIN sys.tables t ON ps.object_id = t.object_id
WHERE t.name LIKE 'Abp%'
GROUP BY t.name;
GO

SELECT * FROM dbo.MigrationCutoverLog WHERE Phase = 'PRE-CUTOVER' ORDER BY TableName;
GO

/*==============================================================================
  STEP 2 - THE RENAME, in one transaction.

  sp_rename on a table does NOT rename its indexes or constraints, and constraint
  names are unique per database - so the old objects must be renamed out of the
  way first, then the clone's objects renamed into the canonical names.
==============================================================================*/
BEGIN TRY
    BEGIN TRANSACTION;

    ----------------------------------------------------------------------------
    -- 2a. Old constraints and indexes out of the way.
    ----------------------------------------------------------------------------
    EXEC sp_rename 'dbo.PK_AbpAuditLogs',             'PK_AbpAuditLogs_Old',             'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChangeSets',      'PK_AbpEntityChangeSets_Old',      'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChanges',         'PK_AbpEntityChanges_Old',         'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityPropertyChanges', 'PK_AbpEntityPropertyChanges_Old', 'OBJECT';

    EXEC sp_rename N'dbo.AbpAuditLogs.IX_AbpAuditLogs_ExecutionTime_Exception',
                   N'IX_AbpAuditLogs_ExecutionTime_Exception_Old', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_UserId',
                   N'IX_AbpEntityChangeSets_UserId_Old', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_CreationTime',
                   N'IX_AbpEntityChangeSets_CreationTime_Old', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_EntityChangeSetId',
                   N'IX_AbpEntityChanges_EntityChangeSetId_Old', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_ChangeTime_EntityTypeFullName',
                   N'IX_AbpEntityChanges_ChangeTime_EntityTypeFullName_Old', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_EntityId_EntityTypeFullName',
                   N'IX_AbpEntityChanges_EntityId_EntityTypeFullName_Old', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityPropertyChanges.IX_AbpEntityPropertyChanges_EntityChangeId',
                   N'IX_AbpEntityPropertyChanges_EntityChangeId_Old', 'INDEX';

    ----------------------------------------------------------------------------
    -- 2b. Old tables out of the way.
    ----------------------------------------------------------------------------
    EXEC sp_rename 'dbo.AbpAuditLogs',             'AbpAuditLogs_Old';
    EXEC sp_rename 'dbo.AbpEntityChangeSets',      'AbpEntityChangeSets_Old';
    EXEC sp_rename 'dbo.AbpEntityChanges',         'AbpEntityChanges_Old';
    EXEC sp_rename 'dbo.AbpEntityPropertyChanges', 'AbpEntityPropertyChanges_Old';

    ----------------------------------------------------------------------------
    -- 2c. Clone tables into place.
    ----------------------------------------------------------------------------
    EXEC sp_rename 'dbo.AbpAuditLogs_Clone',             'AbpAuditLogs';
    EXEC sp_rename 'dbo.AbpEntityChangeSets_Clone',      'AbpEntityChangeSets';
    EXEC sp_rename 'dbo.AbpEntityChanges_Clone',         'AbpEntityChanges';
    EXEC sp_rename 'dbo.AbpEntityPropertyChanges_Clone', 'AbpEntityPropertyChanges';

    ----------------------------------------------------------------------------
    -- 2d. Clone constraints and indexes into canonical names.
    ----------------------------------------------------------------------------
    EXEC sp_rename 'dbo.PK_AbpAuditLogs_Clone',             'PK_AbpAuditLogs',             'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChangeSets_Clone',      'PK_AbpEntityChangeSets',      'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityChanges_Clone',         'PK_AbpEntityChanges',         'OBJECT';
    EXEC sp_rename 'dbo.PK_AbpEntityPropertyChanges_Clone', 'PK_AbpEntityPropertyChanges', 'OBJECT';

    EXEC sp_rename 'dbo.DF_AbpEntityPropertyChanges_Clone_ChangeTime',
                   'DF_AbpEntityPropertyChanges_ChangeTime', 'OBJECT';

    EXEC sp_rename N'dbo.AbpAuditLogs.IX_AbpAuditLogs_Clone_ExecutionTime_Id',
                   N'IX_AbpAuditLogs_ExecutionTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpAuditLogs.IX_AbpAuditLogs_Clone_ExecutionTime_Exception',
                   N'IX_AbpAuditLogs_ExecutionTime_Exception', 'INDEX';

    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_Clone_CreationTime_Id',
                   N'IX_AbpEntityChangeSets_CreationTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChangeSets.IX_AbpEntityChangeSets_Clone_CreationTime',
                   N'IX_AbpEntityChangeSets_CreationTime', 'INDEX';

    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_Clone_ChangeTime_Id',
                   N'IX_AbpEntityChanges_ChangeTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_Clone_ChangeTime_EntityTypeFullName',
                   N'IX_AbpEntityChanges_ChangeTime_EntityTypeFullName', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_Clone_EntityChangeSetId',
                   N'IX_AbpEntityChanges_EntityChangeSetId', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityChanges.IX_AbpEntityChanges_Clone_EntityId_EntityTypeFullName',
                   N'IX_AbpEntityChanges_EntityId_EntityTypeFullName', 'INDEX';

    EXEC sp_rename N'dbo.AbpEntityPropertyChanges.IX_AbpEntityPropertyChanges_Clone_ChangeTime_Id',
                   N'IX_AbpEntityPropertyChanges_ChangeTime_Id', 'INDEX';
    EXEC sp_rename N'dbo.AbpEntityPropertyChanges.IX_AbpEntityPropertyChanges_Clone_EntityChangeId',
                   N'IX_AbpEntityPropertyChanges_EntityChangeId', 'INDEX';

    COMMIT TRANSACTION;
    PRINT 'STEP 2 complete: tables renamed.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    PRINT 'STEP 2 FAILED and was rolled back. Error ' + CAST(ERROR_NUMBER() AS VARCHAR(10))
          + ': ' + ERROR_MESSAGE();
    THROW;
END CATCH
GO

/*==============================================================================
  STEP 3 - RESEED IDENTITY.

  Mandatory. SqlBulkCopy with KeepIdentity inserts the supplied Id values but
  does NOT advance the table's identity counter, so it is still at its seed.
  Without this, the first application INSERT reuses Id = 1 and violates the PK.
==============================================================================*/
DECLARE @t SYSNAME, @max BIGINT, @sql NVARCHAR(500);

DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.tables
    WHERE name IN ('AbpAuditLogs','AbpEntityChangeSets',
                   'AbpEntityChanges','AbpEntityPropertyChanges');
OPEN cur;
FETCH NEXT FROM cur INTO @t;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = N'SELECT @m = ISNULL(MAX(Id), 0) FROM dbo.' + QUOTENAME(@t) + N';';
    EXEC sp_executesql @sql, N'@m BIGINT OUTPUT', @m = @max OUTPUT;

    PRINT 'RESEED dbo.' + @t + ' -> ' + CAST(@max AS VARCHAR(20));
    -- DBCC CHECKIDENT does not accept a variable for the table name.
    SET @sql = N'DBCC CHECKIDENT (''dbo.' + @t + N''', RESEED, ' + CAST(@max AS NVARCHAR(20)) + N');';
    EXEC sp_executesql @sql;

    INSERT dbo.MigrationCutoverLog (Phase, TableName, MaxId, Notes)
    VALUES ('RESEED', @t, @max, 'identity reseeded to MAX(Id)');

    FETCH NEXT FROM cur INTO @t;
END
CLOSE cur; DEALLOCATE cur;
GO

/*==============================================================================
  STEP 4 - CLEAR STALE PLANS.
  Cached plans still reference the old object ids. Recompiling avoids a burst of
  bad plans against the newly partitioned tables.
==============================================================================*/
EXEC sp_recompile 'dbo.AbpAuditLogs';
EXEC sp_recompile 'dbo.AbpEntityChangeSets';
EXEC sp_recompile 'dbo.AbpEntityChanges';
EXEC sp_recompile 'dbo.AbpEntityPropertyChanges';
GO

/*==============================================================================
  STEP 5 - REFRESH DEPENDENT OBJECTS.

  W10: these exist and the original migration never mentioned them. They are not
  schema-bound, so they rebind by name - but that means their behaviour can
  change silently. sp_refreshsqlmodule updates their cached metadata; you still
  need to functionally test them.
==============================================================================*/
IF OBJECT_ID('dbo.AbpAuditLogs_Lite', 'V') IS NOT NULL
    EXEC sp_refreshsqlmodule 'dbo.AbpAuditLogs_Lite';
IF OBJECT_ID('dbo.FindError', 'P') IS NOT NULL
    EXEC sp_refreshsqlmodule 'dbo.FindError';
IF OBJECT_ID('dbo.FindSuccess', 'P') IS NOT NULL
    EXEC sp_refreshsqlmodule 'dbo.FindSuccess';
IF OBJECT_ID('dbo.FindEntityChanges', 'P') IS NOT NULL
    EXEC sp_refreshsqlmodule 'dbo.FindEntityChanges';
GO

PRINT '';
PRINT 'MANUAL: functionally test dbo.AbpAuditLogs_Lite, dbo.FindError,';
PRINT '        dbo.FindSuccess and dbo.FindEntityChanges before releasing the app.';
PRINT '        FindEntityChanges joins all three change tables - if it filters by';
PRINT '        EntityChangeSetId or EntityChangeId with no date predicate it now';
PRINT '        probes every partition (W1).';
GO

SET NOEXEC OFF;
GO

/*==============================================================================
  STEP 6 - POST-CUTOVER VERIFICATION.
==============================================================================*/
SELECT t.name                                   AS table_name
     , ISNULL(ps.name, '(not partitioned)')     AS partition_scheme
     , SUM(CASE WHEN dps.index_id IN (0,1) THEN dps.row_count ELSE 0 END) AS row_count
     , IDENT_CURRENT('dbo.' + t.name)           AS identity_current
FROM sys.tables t
JOIN sys.indexes i  ON t.object_id = i.object_id AND i.index_id IN (0,1)
LEFT JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
LEFT JOIN sys.dm_db_partition_stats dps ON dps.object_id = t.object_id
WHERE t.name IN ('AbpAuditLogs','AbpEntityChangeSets',
                 'AbpEntityChanges','AbpEntityPropertyChanges')
GROUP BY t.name, ps.name
ORDER BY t.name;
GO

/* Smoke test the C3 fix: this must succeed. Roll it back - it is only a probe. */
BEGIN TRANSACTION;
BEGIN TRY
    INSERT dbo.AbpEntityPropertyChanges
        (EntityChangeId, NewValue, NewValueHash, OriginalValue,
         OriginalValueHash, PropertyName, PropertyTypeFullName, TenantId)
    VALUES (0, N'probe', NULL, N'probe', NULL, N'CutoverProbe', N'System.String', NULL);
    PRINT 'PASS: INSERT without ChangeTime succeeded - the C3 default is working.';
END TRY
BEGIN CATCH
    PRINT 'FAIL: INSERT without ChangeTime failed - ' + ERROR_MESSAGE();
    PRINT '      The application WILL NOT be able to write. Roll back the cutover.';
END CATCH
ROLLBACK TRANSACTION;
GO

PRINT '';
PRINT 'CUTOVER COMPLETE. The *_Old tables are retained as your rollback.';
PRINT 'Release the application, monitor, then run 04_Decommission_Old_Tables.sql.';
GO
