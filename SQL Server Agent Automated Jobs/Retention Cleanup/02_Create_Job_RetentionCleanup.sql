/*==============================================================================
  02_Create_Job_RetentionCleanup.sql
  ------------------------------------------------------------------------------
  RUN ON  : *** ALL THREE REPLICAS ***
            SRV-AZ-AG002, SRV-AZ-AG01, SRV-AZ-AG03

  C5: msdb is not AG-replicated, so this job must exist on every replica.
      PartitionConfiguration.RetentionCleanup exits immediately on a secondary,
      so it is a harmless no-op wherever this node is not currently primary.
      See the header of 01_Create_Job_Partition_Provisioning.sql for the detail.

  C4: the original job script never called sp_add_jobschedule, so retention would
      never have run. A schedule is attached below and verified at the end.

  ------------------------------------------------------------------------------
  DEPLOYED IN DRY-RUN MODE ON PURPOSE
  ------------------------------------------------------------------------------
  Step 1 runs with @DryRun = 1. It reports exactly which partitions it WOULD
  purge and changes nothing.

  This is deliberate. Retention deletes audit data irreversibly.

  ------------------------------------------------------------------------------
  THE EXISTING MECHANISM - RESOLVED 2026-09-12
  ------------------------------------------------------------------------------
  The earlier revision of this file said the purge mechanism was unidentified.
  It has since been found:

      [eJarDbReports].[Jobs].[PurgeLogs_eJar]

  reaches into eJarDbAuditing through synonyms (Audit_dbo_AbpAuditLogs ->
  [eJarDbAuditing].[dbo].[AbpAuditLogs], and three more), which is why no object
  inside eJarDbAuditing appeared to purge anything.

  It is run BY HAND. There is no SQL Agent job and no HangFire recurring job that
  calls it - both checked. Retention on this estate depends on someone
  remembering to run:

      EXEC [Jobs].[PurgeLogs_eJar] @Type = 'Audit,State', @Batch = 10000;

  Its policy has been transferred verbatim into
  PartitionConfiguration.PartitionSet:

      AuditLogs : 30 days primary (Exception IS NOT NULL tail, truncate + merge)
                   7 days secondary (Exception IS NULL, batched DELETE)
      Auditing  : 12 months (matches DATEADD(year,-1,...))

  ------------------------------------------------------------------------------
  TWO MECHANISMS, ONE POLICY - HOW THEY ARE RECONCILED
  ------------------------------------------------------------------------------
  Do NOT run this job and the old PurgeLogs_eJar side by side. Instead, deploy
  03_Replace_PurgeLogs_eJar.sql: it keeps the same name, signature and call
  pattern, and delegates to the same PartitionConfiguration.RetentionCleanup
  this job calls. After that, the manual command and this job are two doors onto
  one implementation and cannot disagree.

  This job then adds only the thing that is genuinely missing today: a schedule.

  ------------------------------------------------------------------------------
  STILL TO CONFIRM BEFORE ENFORCING
  ------------------------------------------------------------------------------
    1. The 12-month entity retention HAS NEVER RUN. @Type='Audit,State' does not
       match '%Entity%', so that block has always been skipped - which is why the
       change tables still hold data back to 2013-05-12. The first enforcing run
       removes roughly 82-85% of those three tables. That is the point of the
       exercise, but it is a large irreversible deletion and needs sign-off.

    2. AbpAuditLogs at 7/30 days is already in force, so no behaviour change
       there. Confirm the numbers are still the intended policy rather than an
       accident of history.
==============================================================================*/
SET NOCOUNT ON;
GO

USE msdb;
GO

DECLARE @JobName SYSNAME = N'TruncatePartition_eJarDbAuditing';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
BEGIN
    PRINT 'Dropping existing job ' + @JobName;
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;
END
GO

DECLARE @JobName SYSNAME = N'TruncatePartition_eJarDbAuditing';
DECLARE @JobId BINARY(16);

EXEC msdb.dbo.sp_add_job
      @job_name              = @JobName
    , @enabled               = 1
    , @description           = N'eJarDbAuditing partition retention. DEPLOYED IN DRY-RUN MODE - see 02_Create_Job_RetentionCleanup.sql before switching to enforcing.'
    , @notify_level_eventlog = 2
    , @job_id                = @JobId OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
      @job_name       = @JobName
    , @step_id        = 1
    , @step_name      = N'Retention cleanup (DRY RUN)'
    , @subsystem      = N'TSQL'
    , @database_name  = N'eJarDbAuditing'
    , @retry_attempts = 1
    , @retry_interval = 10
    , @on_success_action = 1
    , @on_fail_action    = 2
    , @command       = N'
SET NOCOUNT ON;

/* @DryRun = 1  -> reports only, changes nothing.
   Change to 0 ONLY after the retention policy has been signed off and
   03_Replace_PurgeLogs_eJar.sql has been deployed so the two entry points
   share one implementation. See the script header.

   @Batch and @BatchDelaySec match PurgeLogs_eJar''s existing tuning
   (@Batch = 10000, WAITFOR DELAY ''00:00:03''), so the secondary tier behaves
   like the purge this estate is already used to.                             */
EXEC PartitionConfiguration.RetentionCleanup
     @SetName       = NULL,    -- all partition sets
     @MaxPartitions = 6,       -- safety cap per run
     @Batch         = 10000,
     @BatchDelaySec = 3,
     @MaxBatches    = 500,
     @RemoveFiles   = 1,       -- W4: reclaim the released filegroup and file
     @DryRun        = 1;
';

/*------------------------------------------------------------------------------
  C4 - THE SCHEDULE.

  DAILY at 02:00, one hour after the provisioning job so headroom is always
  extended before anything is removed.

  Daily, not weekly. An earlier revision used weekly, which was defensible when
  AbpAuditLogs was on weekly partitions - it is wrong now:

    * AbpAuditLogs is DAILY with a 7-day secondary tier. A weekly run would let
      up to 7 daily partitions of successes (~2.2M rows each, ~3.7 GB each)
      accumulate past their expiry before anything removed them, then try to
      clear ~15M rows in one pass.
    * A daily run removes ~1 partition and ~1 day of successes each time, which
      is a small, predictable amount of work.

  The monthly set yields at most one purgeable partition per month, so running
  daily simply means 30 no-op passes and one that does work. @MaxPartitions = 6
  absorbs any backlog from missed runs.

  freq_type     = 4   daily
  freq_interval = 1   every day
------------------------------------------------------------------------------*/
EXEC msdb.dbo.sp_add_jobschedule
      @job_name          = @JobName
    , @name              = N'Daily 02:00 - eJarDbAuditing retention'
    , @enabled           = 1
    , @freq_type         = 4
    , @freq_interval     = 1
    , @active_start_time = 020000;

EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName;

PRINT 'Created job: ' + @JobName + '  (DRY-RUN mode)';
GO

/*==============================================================================
  VERIFY
==============================================================================*/
SELECT j.name    AS job_name
     , j.enabled AS job_enabled
     , (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js WHERE js.job_id = j.job_id) AS schedule_count
     , (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps   s  WHERE s.job_id  = j.job_id) AS step_count
     , (SELECT COUNT(*) FROM msdb.dbo.sysjobservers sv WHERE sv.job_id = j.job_id) AS jobserver_count
     , CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps s
                         WHERE s.job_id = j.job_id AND s.command LIKE '%@DryRun        = 1%')
            THEN 'DRY RUN (reports only)' ELSE 'ENFORCING (deletes data)' END AS mode
FROM msdb.dbo.sysjobs j
WHERE j.name = N'TruncatePartition_eJarDbAuditing';
GO

IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobs j
    JOIN msdb.dbo.sysjobschedules js ON j.job_id = js.job_id
    WHERE j.name = N'TruncatePartition_eJarDbAuditing')
    RAISERROR('The retention job has NO SCHEDULE attached. It will never run. This is defect C4.', 16, 1);
ELSE
    PRINT 'Verified: job exists, is enabled, and has a schedule.';
GO

/*==============================================================================
  SWITCHING TO ENFORCING MODE
  ------------------------------------------------------------------------------
  Prerequisites, all of them:

    [ ] Retention policy signed off by the business, per table.
        Change it in one place if needed - units follow each set's Granularity:

            -- 'Auditing' is MONTH granularity
            UPDATE PartitionConfiguration.PartitionSet
               SET RetentionUnits = <n>              -- months
             WHERE SetName = 'Auditing';

            -- 'AuditLogs' is DAY granularity, and has TWO tiers
            UPDATE PartitionConfiguration.PartitionSet
               SET RetentionUnits          = <n>,    -- days, Exception IS NOT NULL
                   SecondaryRetentionUnits = <m>     -- days, Exception IS NULL
             WHERE SetName = 'AuditLogs';            -- m must be < n

    [ ] 03_Replace_PurgeLogs_eJar.sql deployed, so the manual
        "EXEC [Jobs].[PurgeLogs_eJar] @Type='Audit,State'" command and this job
        share one implementation instead of competing.

    [ ] A dry run reviewed. Run it by hand and read every line:
            EXEC PartitionConfiguration.RetentionCleanup @DryRun = 1;

    [ ] A full backup taken - particularly before the FIRST run with
        @SetName = 'Auditing', which removes ~82-85% of the three change tables
        because that tier has never actually executed.

  Then run this to flip the job step:
  ------------------------------------------------------------------------------
  USE msdb;
  GO
  EXEC msdb.dbo.sp_update_jobstep
        @job_name  = N'TruncatePartition_eJarDbAuditing'
      , @step_id   = 1
      , @step_name = N'Retention cleanup (ENFORCING)'
      , @command   = N'
  SET NOCOUNT ON;
  EXEC PartitionConfiguration.RetentionCleanup
       @SetName       = NULL,
       @MaxPartitions = 6,
       @Batch         = 10000,
       @BatchDelaySec = 3,
       @MaxBatches    = 500,
       @RemoveFiles   = 1,
       @DryRun        = 0;
  ';
  GO
  ------------------------------------------------------------------------------
  Repeat on all three replicas.
==============================================================================*/

PRINT '';
PRINT 'REMINDER: run this same script on SRV-AZ-AG002, SRV-AZ-AG01 and SRV-AZ-AG03.';
GO
