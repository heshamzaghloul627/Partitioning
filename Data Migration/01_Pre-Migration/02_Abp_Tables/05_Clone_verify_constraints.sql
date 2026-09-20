/*==============================================================================
  05_Clone_verify_constraints.sql
  ------------------------------------------------------------------------------
  TARGET SERVER : SRV-AZ-AG002 (PRIMARY for eJarDbAuditing)

  Replaces the original 05_Clone_disable_constraints.sql.

  ------------------------------------------------------------------------------
  Why the original was replaced (W12)
  ------------------------------------------------------------------------------
  The original ran:

      ALTER TABLE dbo.AbpAuditLogs_Clone NOCHECK CONSTRAINT ALL;
      ... (and the same for the other three _Clone tables)

  NOCHECK CONSTRAINT only affects CHECK and FOREIGN KEY constraints. Verified on
  the live database 2026-08-29:

      sys.foreign_keys      rows for these four tables : 0
      sys.check_constraints rows for these four tables : 0

  So the original script - and its partner 03_Post Migration/
  01_Re-enable Constraints.sql - were complete no-ops on both the source and the
  clone tables. Worse, the re-enable script used

      ALTER TABLE ... WITH NOCHECK CHECK CONSTRAINT ALL

  which re-enables WITHOUT validating, leaving constraints is_not_trusted = 1 so
  the optimizer ignores them. The correct form is WITH CHECK CHECK CONSTRAINT ALL.

  Rather than ship two scripts that do nothing, this one asserts the assumption
  they silently relied on. If a future release of the application adds foreign
  keys to these tables, this script fails loudly and the migration plan has to
  be revisited - because a FOREIGN KEY also blocks TRUNCATE TABLE entirely,
  which would break the whole retention design.

  ------------------------------------------------------------------------------
  Worth being explicit about
  ------------------------------------------------------------------------------
  The relationships

      AbpEntityPropertyChanges.EntityChangeId  -> AbpEntityChanges.Id
      AbpEntityChanges.EntityChangeSetId       -> AbpEntityChangeSets.Id

  are enforced by the application only, not by the database. That is unchanged
  by this migration - but it is why the retention proc must truncate child
  partitions before parent partitions, and why the property-change delta query
  must not silently drop rows whose parent is missing (see C7 in the bulk copy
  scripts).
==============================================================================*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE eJarDbAuditing;
GO

DECLARE @Errors INT = 0;

/*------------------------------------------------------------------------------
  1. No FOREIGN KEY constraints. A FK on any of these tables makes
     TRUNCATE TABLE illegal, which the retention design depends on.
------------------------------------------------------------------------------*/
IF EXISTS (
    SELECT 1 FROM sys.foreign_keys
    WHERE OBJECT_NAME(parent_object_id)     LIKE 'Abp%'
       OR OBJECT_NAME(referenced_object_id) LIKE 'Abp%'
)
BEGIN
    PRINT 'FAIL [1] FOREIGN KEY constraints found on the Abp tables:';
    SELECT fk.name                                  AS fk_name
         , OBJECT_NAME(fk.parent_object_id)         AS parent_table
         , OBJECT_NAME(fk.referenced_object_id)     AS referenced_table
         , fk.is_disabled
         , fk.is_not_trusted
    FROM sys.foreign_keys fk
    WHERE OBJECT_NAME(fk.parent_object_id)     LIKE 'Abp%'
       OR OBJECT_NAME(fk.referenced_object_id) LIKE 'Abp%';
    PRINT '         TRUNCATE TABLE cannot be used on a table referenced by a FK.';
    PRINT '         The partition-truncation retention design will not work as-is.';
    SET @Errors += 1;
END
ELSE
    PRINT 'PASS [1] No FOREIGN KEY constraints - TRUNCATE-based retention is viable.';

/*------------------------------------------------------------------------------
  2. No CHECK constraints, so nothing needs disabling for the bulk load.
------------------------------------------------------------------------------*/
IF EXISTS (
    SELECT 1 FROM sys.check_constraints
    WHERE OBJECT_NAME(parent_object_id) LIKE 'Abp%'
)
BEGIN
    PRINT 'WARN [2] CHECK constraints found. Review whether the bulk load needs';
    PRINT '         them disabled, and re-enable with WITH CHECK (not WITH NOCHECK):';
    SELECT name, OBJECT_NAME(parent_object_id) AS tbl, definition, is_disabled, is_not_trusted
    FROM sys.check_constraints
    WHERE OBJECT_NAME(parent_object_id) LIKE 'Abp%';
END
ELSE
    PRINT 'PASS [2] No CHECK constraints - no disable/re-enable step required.';

/*------------------------------------------------------------------------------
  3. No indexed views. An indexed view also blocks TRUNCATE TABLE.
------------------------------------------------------------------------------*/
IF EXISTS (
    SELECT 1
    FROM sys.indexes i
    JOIN sys.views v ON i.object_id = v.object_id
    JOIN sys.sql_expression_dependencies d ON d.referencing_id = v.object_id
    WHERE d.referenced_entity_name LIKE 'Abp%'
)
BEGIN
    PRINT 'FAIL [3] An indexed view references the Abp tables. This blocks TRUNCATE TABLE.';
    SET @Errors += 1;
END
ELSE
    PRINT 'PASS [3] No indexed views referencing the Abp tables.';

/*------------------------------------------------------------------------------
  4. No triggers. A trigger breaks EF Core's MERGE ... OUTPUT INSERTED.[Id].
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.triggers WHERE OBJECT_NAME(parent_id) LIKE 'Abp%')
BEGIN
    PRINT 'FAIL [4] Triggers found on the Abp tables. EF Core uses';
    PRINT '         MERGE ... OUTPUT INSERTED.[Id], which fails on a table with triggers.';
    SET @Errors += 1;
END
ELSE
    PRINT 'PASS [4] No triggers on the Abp tables.';

IF @Errors > 0
    RAISERROR('Constraint verification failed with %d blocking issue(s).', 16, 1, @Errors);
ELSE
    PRINT 'All constraint assumptions verified. No disable step needed before the load.';
GO
