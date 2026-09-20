/*==============================================================================
  03_EXECUTE_PartitionFunctionScheme.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)

  Builds both partition structures. Run 00_Preflight_Checks.sql first.

  The original passed @DBName = 'eJarDbAuditing' as a string that was then
  concatenated into ALTER DATABASE statements. That parameter is gone - the proc
  operates on the current database via DB_NAME(), so it cannot be pointed at the
  wrong database by a typo.

  RUN THIS TWICE:
    Pass 1 (@DryRun = 1) prints every statement and changes nothing. Read it.
    Pass 2 (@DryRun = 0) applies it.
==============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE eJarDbAuditing;
GO

/*------------------------------------------------------------------------------
  STEP 1 - PREVIEW. Safe to run at any time on the primary.
------------------------------------------------------------------------------*/
EXEC PartitionConfiguration.ProvisionPartitions @SetName = 'Auditing',  @DryRun = 1;
GO
EXEC PartitionConfiguration.ProvisionPartitions @SetName = 'AuditLogs', @DryRun = 1;
GO

/*------------------------------------------------------------------------------
  STEP 2 - APPLY.

  Uncomment and run only after reviewing the STEP 1 output and completing the
  manual replica-path check from 00_Preflight_Checks.sql [9].

  Because the first run stops after creating the function and scheme, each set
  needs the call twice: once to create, once to extend forward. Running it a
  third time is harmless - it is idempotent.
------------------------------------------------------------------------------*/
/*
EXEC PartitionConfiguration.ProvisionPartitions @SetName = 'Auditing',  @DryRun = 0;
GO
EXEC PartitionConfiguration.ProvisionPartitions @SetName = 'Auditing',  @DryRun = 0;
GO
EXEC PartitionConfiguration.ProvisionPartitions @SetName = 'AuditLogs', @DryRun = 0;
GO
EXEC PartitionConfiguration.ProvisionPartitions @SetName = 'AuditLogs', @DryRun = 0;
GO
*/

/*------------------------------------------------------------------------------
  STEP 3 - VERIFY. Expect roughly:
     PS_Auditing_Monthly  ~16 partitions  (12 months retention + 3 ahead + 1)
                          one filegroup per partition, except partition 1 =
                          [PRIMARY] (the pre-retention catch-all)
     PS_AuditLogs_Daily   ~46 partitions  (30 days retention + 14 ahead + 1)
                          ALL partitions on the single shared filegroup
                          FG_LOG_DATA, except partition 1 = [PRIMARY]
------------------------------------------------------------------------------*/
SELECT ps.name                AS partition_scheme,
       COUNT(*)               AS partition_count
FROM sys.partition_schemes ps
JOIN sys.destination_data_spaces dds ON dds.partition_scheme_id = ps.data_space_id
GROUP BY ps.name;
GO

SELECT * FROM PartitionConfiguration.Partition_Information
ORDER BY partition_scheme, partition_number;
GO
