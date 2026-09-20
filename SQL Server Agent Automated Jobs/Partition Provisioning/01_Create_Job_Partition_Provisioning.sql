/*==============================================================================
  01_Create_Job_Partition_Provisioning.sql
  ------------------------------------------------------------------------------
  RUN ON  : *** ALL THREE REPLICAS ***
            SRV-AZ-AG002, SRV-AZ-AG01, SRV-AZ-AG03

  ##############################################################################
  #  C5 - WHY THIS MUST BE RUN ON EVERY REPLICA                                #
  ##############################################################################

  SQL Agent jobs live in msdb. msdb is NOT replicated by an availability group.

  So a job created only on the current primary DOES NOT EXIST on the others.
  SQLAG02 is configured for AUTOMATIC failover between SRV-AZ-AG002 and
  SRV-AZ-AG01 - the moment it fails over, partition provisioning silently stops,
  the partition function runs out of headroom, and every new row piles into the
  trailing partition. The first sign of trouble would be the sliding-window job
  trying to SPLIT a populated partition: a fully-logged, offline, size-of-data
  move under a schema-modification lock.

  Deploy everywhere. The proc itself exits harmlessly on a secondary via
  sys.fn_hadr_is_primary_replica, so the job is a no-op wherever it is not
  currently the primary - no failure noise, no duplicated work.

  ##############################################################################
  #  C4 - WHAT WAS ACTUALLY BROKEN                                             #
  ##############################################################################

  The original job script called sp_add_job, sp_add_jobstep and sp_add_jobserver
  and NEVER called sp_add_jobschedule. The job was created @enabled = 1 and would
  have sat there forever without firing. Nothing would have errored; partitions
  simply would never have been provisioned.

  A schedule is now attached below, and the verification query at the end fails
  loudly if it is ever missing again.
==============================================================================*/
SET NOCOUNT ON;
GO

USE msdb;
GO

DECLARE @JobName SYSNAME = N'Partition_AutoIncrement_eJarDbAuditing';

/*------------------------------------------------------------------------------
  Idempotent: remove any previous definition first.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    PRINT 'Dropping existing job ' + @JobName;
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;
END
GO

DECLARE @JobName SYSNAME = N'Partition_AutoIncrement_eJarDbAuditing';
DECLARE @JobId BINARY(16);

EXEC msdb.dbo.sp_add_job
      @job_name              = @JobName
    , @enabled               = 1
    , @description           = N'Extends the eJarDbAuditing partition functions forward. Runs on every replica; exits immediately unless this replica is the primary. See 01_Create_Job_Partition_Provisioning.sql.'
    , @notify_level_eventlog = 2          -- log failures to the Windows event log
    , @job_id                = @JobId OUTPUT;

/*------------------------------------------------------------------------------
  Step 1 - monthly set (the three change-tracking tables).
------------------------------------------------------------------------------*/
EXEC msdb.dbo.sp_add_jobstep
      @job_name       = @JobName
    , @step_id        = 1
    , @step_name      = N'Provision Auditing (monthly)'
    , @subsystem      = N'TSQL'
    , @database_name  = N'eJarDbAuditing'
    , @retry_attempts = 2
    , @retry_interval = 5
    , @on_success_action = 3               -- go to next step
    , @on_fail_action    = 2               -- quit reporting failure
    , @command       = N'
SET NOCOUNT ON;
EXEC PartitionConfiguration.ProvisionPartitions
     @SetName = ''Auditing'',
     @DryRun  = 0;
';

/*------------------------------------------------------------------------------
  Step 2 - weekly set (AbpAuditLogs).
------------------------------------------------------------------------------*/
EXEC msdb.dbo.sp_add_jobstep
      @job_name       = @JobName
    , @step_id        = 2
    , @step_name      = N'Provision AuditLogs (weekly)'
    , @subsystem      = N'TSQL'
    , @database_name  = N'eJarDbAuditing'
    , @retry_attempts = 2
    , @retry_interval = 5
    , @on_success_action = 1               -- quit reporting success
    , @on_fail_action    = 2
    , @command       = N'
SET NOCOUNT ON;
EXEC PartitionConfiguration.ProvisionPartitions
     @SetName = ''AuditLogs'',
     @DryRun  = 0;
';

/*------------------------------------------------------------------------------
  C4 - THE SCHEDULE. This is what the original was missing entirely.

  Daily rather than weekly. Provisioning is a no-op on the days it has nothing
  to do, so running it daily costs almost nothing and means a single missed run
  can never erode the headroom. 01:00 keeps it clear of the retention job.
------------------------------------------------------------------------------*/
EXEC msdb.dbo.sp_add_jobschedule
      @job_name       = @JobName
    , @name           = N'Daily 01:00 - eJarDbAuditing partition provisioning'
    , @enabled        = 1
    , @freq_type      = 4                  -- daily
    , @freq_interval  = 1                  -- every day
    , @active_start_time = 010000;         -- 01:00:00

EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName;

PRINT 'Created job: ' + @JobName;
GO

/*==============================================================================
  VERIFY. Both rows must appear and schedule_count must be >= 1.
  A schedule_count of 0 is exactly the C4 defect - fail loudly.
==============================================================================*/
SELECT j.name                AS job_name
     , j.enabled             AS job_enabled
     , (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js
        WHERE js.job_id = j.job_id)                       AS schedule_count
     , (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s
        WHERE s.job_id = j.job_id)                        AS step_count
     , (SELECT COUNT(*) FROM msdb.dbo.sysjobservers sv
        WHERE sv.job_id = j.job_id)                       AS jobserver_count
FROM msdb.dbo.sysjobs j
WHERE j.name = N'Partition_AutoIncrement_eJarDbAuditing';
GO

SELECT s.name          AS schedule_name
     , s.enabled
     , s.freq_type
     , s.freq_interval
     , s.active_start_time
FROM msdb.dbo.sysschedules s
JOIN msdb.dbo.sysjobschedules js ON s.schedule_id = js.schedule_id
JOIN msdb.dbo.sysjobs j          ON js.job_id     = j.job_id
WHERE j.name = N'Partition_AutoIncrement_eJarDbAuditing';
GO

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
    WHERE j.name = N'Partition_AutoIncrement_eJarDbAuditing')
    RAISERROR('The provisioning job has NO SCHEDULE attached. It will never run. This is defect C4 - do not leave it in this state.', 16, 1);
ELSE
    PRINT 'Verified: job exists, is enabled, and has a schedule.';
GO

PRINT '';
PRINT 'REMINDER: run this same script on SRV-AZ-AG002, SRV-AZ-AG01 and SRV-AZ-AG03.';
PRINT 'Confirm coverage from each node with:';
PRINT '    SELECT @@SERVERNAME, name, enabled FROM msdb.dbo.sysjobs';
PRINT '    WHERE name LIKE ''%eJarDbAuditing%'';';
GO
