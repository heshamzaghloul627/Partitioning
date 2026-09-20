/*==============================================================================
  04_VIEW_Partition_Information.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY)  - but the view itself is read-only and
                  can be queried on any replica.

  Replaces the original 05_VIEW_Partition_Information.sql.

  Changes from the original:
    - The original joined sys.system_internals_allocation_units, which is an
      undocumented internal view and forced a DISTINCT to undo the row
      multiplication it caused. Dropped; sys.dm_db_partition_stats gives the
      same information supportably.
    - The original CAST boundary values to DATETIME, silently rounding a
      datetime2(7) boundary. Now DATETIME2(7) throughout.
    - The original hard-coded ps.name = 'PSYearMonthWeek'. Now driven from
      PartitionConfiguration.PartitionSet, so it covers both schemes.
    - Shows BOTH bounds and the mapped filegroup, which is what you actually
      need when reasoning about retention.

  RANGE RIGHT mapping, stated explicitly because it is easy to get wrong:
      partition p covers  [ boundary(p-1) , boundary(p) )
      partition 1 covers  ( -infinity     , boundary(1) )
      last partition      [ boundary(n)   , +infinity   )
  So partition p's UPPER bound is the boundary whose boundary_id = p.
==============================================================================*/
SET NOCOUNT ON;
GO

USE eJarDbAuditing;
GO

IF OBJECT_ID('PartitionConfiguration.Partition_Information', 'V') IS NOT NULL
    DROP VIEW PartitionConfiguration.Partition_Information;
GO

CREATE VIEW PartitionConfiguration.Partition_Information
AS
SELECT
      cfg.SetName                                     AS partition_set
    , pf.name                                         AS partition_function
    , ps.name                                         AS partition_scheme
    , OBJECT_SCHEMA_NAME(i.object_id)                 AS schema_name
    , OBJECT_NAME(i.object_id)                         AS table_name
    , p.partition_number
    , fg.name                                         AS filegroup_name
    , CAST(lo.value AS DATETIME2(7))                  AS lower_boundary_inclusive
    , CAST(hi.value AS DATETIME2(7))                  AS upper_boundary_exclusive
    , p.rows                                          AS number_of_rows
    , CAST(dps.reserved_page_count * 8.0 / 1024
           AS DECIMAL(14,1))                          AS reserved_mb
    , CASE WHEN hi.value IS NULL THEN 'TRAILING (must stay empty)'
           WHEN lo.value IS NULL THEN 'CATCH-ALL (pre-retention)'
           ELSE '' END                                AS notes
FROM sys.partitions AS p
JOIN sys.indexes AS i
     ON  p.object_id = i.object_id
     AND p.index_id  = i.index_id
JOIN sys.partition_schemes AS ps
     ON ps.data_space_id = i.data_space_id
JOIN sys.partition_functions AS pf
     ON pf.function_id = ps.function_id
JOIN PartitionConfiguration.PartitionSet AS cfg
     ON cfg.PartitionScheme = ps.name
JOIN sys.destination_data_spaces AS dds
     ON  dds.partition_scheme_id = ps.data_space_id
     AND dds.destination_id      = p.partition_number
JOIN sys.filegroups AS fg
     ON fg.data_space_id = dds.data_space_id
LEFT JOIN sys.partition_range_values AS hi
     ON  hi.function_id = pf.function_id
     AND hi.boundary_id = p.partition_number
LEFT JOIN sys.partition_range_values AS lo
     ON  lo.function_id = pf.function_id
     AND lo.boundary_id = p.partition_number - 1
LEFT JOIN sys.dm_db_partition_stats AS dps
     ON  dps.object_id        = p.object_id
     AND dps.index_id         = p.index_id
     AND dps.partition_number = p.partition_number
WHERE i.index_id IN (0, 1);       -- heap or clustered index only
GO

PRINT 'Created: PartitionConfiguration.Partition_Information';
GO
