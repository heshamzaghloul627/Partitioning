<#
================================================================================
 AbpBulkCopy.psm1
--------------------------------------------------------------------------------
 Shared bulk-copy engine for the eJarDbAuditing partitioning migration.

 Replaces the twelve near-identical *_BulkCopy*.ps1 scripts
 (01_Bulk_Load x4, 02_Delta x4, 03_Post Migration/Optional Rollback x4).

 W11: three of the four "Delta" scripts were BYTE-IDENTICAL to their Bulk_Load
      counterparts and the fourth differed by 3 bytes. Twelve copies of the same
      logic meant twelve copies of every bug below, and guaranteed future drift.
      One engine, one place to fix.

================================================================================
 FIXES CARRIED IN THIS MODULE
================================================================================

 C7  READPAST REMOVED.
     The original read the live source with WITH (READPAST), which SKIPS locked
     rows rather than waiting. The source absorbs ~73.8M writes/month, so rows
     WILL be locked. Because the checkpoint is MAX(Id) on the target and the next
     chunk selects WHERE Id > @LastId, any skipped row is never revisited -
     silent, unquantified loss of audit data with no reconciliation anywhere.

     No hint is needed as a replacement: eJarDbAuditing has
     READ_COMMITTED_SNAPSHOT = ON (verified 2026-08-29), so plain READ COMMITTED
     reads are row-versioned. They neither block nor are blocked, and they see a
     consistent snapshot. This is strictly better than READPAST in every respect.

 C8  NOLOCK REMOVED from the checkpoint query.
     Get-LastCheckpoint read MAX(Id) with (NOLOCK) while SqlBulkCopy had
     UseInternalTransaction (commit per batch). A dirty read could observe an Id
     from a batch that then rolled back; on restart the loop resumes above it and
     those rows are lost. It is a single-row aggregate - the read cost of doing
     it correctly is irrelevant.

 C1  RETENTION FLOOR ADDED. This is the fix for the disk-space showstopper.
     Measured 2026-08-29 from the statistics histograms:
         AbpEntityChanges     : only 17.7% of rows are inside 12 months
         AbpEntityChangeSets  : only 15.2% of rows are inside 12 months
     Copying all 733.92 GB required a second full copy on a volume with 217.1 GB
     free - arithmetically impossible. Copying only the retention window, PAGE
     compressed, needs roughly 64 GB. Rows outside the window are being deleted
     by the retention policy anyway, so copying them was pure waste.

 W8  SOURCE REPLICA IS NOW SELECTABLE, defaulting to the ASYNCHRONOUS_COMMIT
     replica for the bulk phase. The original read 389 GB from SRV-AZ-AG01, a
     SYNCHRONOUS_COMMIT replica with AUTOMATIC failover. Long reads on a readable
     secondary hold schema-stability locks that block redo, growing the redo
     queue and extending failover RTO. SRV-AZ-AG03 (async, manual failover) is
     the safe source for the long bulk phase. The final delta reads from the
     PRIMARY so it cannot miss recent rows to replica lag.

 W7  FINITE TIMEOUT. The original set BulkCopyTimeout = 0 (infinite), so a stuck
     load would hold TABLOCK indefinitely with no automatic release.

 I13 AUTHENTICATION IS EXPLICIT. The original hard-coded
     "Integrated Security=True" while the runbook specified SQL auth.

 I14 ROW COUNTS ARE REAL. The original reported $LastId - $StartId, an Id RANGE,
     as though it were a row count. With IDENTITY gaps (rollbacks, and any
     READPAST skips) that overstates progress. Uses $BulkCopy.RowsCopied.

 C7b ORPHANS ARE COUNTED, NOT SILENTLY DROPPED. AbpEntityPropertyChanges has no
     date column of its own, so ChangeTime comes from an INNER JOIN to the parent
     AbpEntityChanges row. An INNER JOIN silently discards any property-change
     row whose parent is missing. The join is still required (an orphan has no
     ChangeTime and therefore no partition to live in), but the count is now
     measured and reported so the loss is a decision rather than an accident.
================================================================================
#>

Set-StrictMode -Version Latest

$script:AbpTables = @(
    [ordered]@{
        Name           = 'AbpEntityChangeSets'
        DateColumn     = 'CreationTime'
        RetentionUnit  = 'Month'
        RetentionCount = 12
        Order          = 1
        Columns        = @(
            'Id','BrowserInfo','ClientIpAddress','ClientName','CreationTime',
            'ExtensionData','ImpersonatorTenantId','ImpersonatorUserId','Reason',
            'TenantId','UserId'
        )
    },
    [ordered]@{
        Name           = 'AbpEntityChanges'
        DateColumn     = 'ChangeTime'
        RetentionUnit  = 'Month'
        RetentionCount = 12
        Order          = 2
        Columns        = @(
            'Id','ChangeTime','ChangeType','EntityChangeSetId','EntityId',
            'EntityTypeFullName','TenantId'
        )
    },
    [ordered]@{
        Name           = 'AbpEntityPropertyChanges'
        DateColumn     = 'ChangeTime'      # denormalised from the parent
        RetentionUnit  = 'Month'
        RetentionCount = 12
        Order          = 3
        ParentJoin     = $true
        Columns        = @(
            'Id','EntityChangeId','NewValue','OriginalValue','PropertyName',
            'PropertyTypeFullName','TenantId','NewValueHash','OriginalValueHash',
            'ChangeTime'
        )
    },
    [ordered]@{
        Name           = 'AbpAuditLogs'
        DateColumn     = 'ExecutionTime'
        RetentionUnit  = 'Week'
        RetentionCount = 5
        Order          = 4
        Columns        = @(
            'Id','TenantId','UserId','ServiceName','MethodName','Parameters',
            'ReturnValue','ExecutionTime','ExecutionDuration','ClientIpAddress',
            'ClientName','BrowserInfo','Exception','ImpersonatorUserId',
            'ImpersonatorTenantId','CustomData','ExceptionMessage','TraceId'
        )
    }
)

function Get-AbpTableConfig {
    <#  Returns the table configurations in parent-before-child order.  #>
    [CmdletBinding()]
    param([string[]]$Only)

    $set = $script:AbpTables | Sort-Object { $_.Order }
    if ($Only) { $set = $set | Where-Object { $Only -contains $_.Name } }
    return $set
}

function New-AbpConnectionString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string]$Database,
        [ValidateSet('Windows','Sql')][string]$AuthMode = 'Windows',
        [string]$UserId,
        [System.Security.SecureString]$Password,
        [switch]$ReadOnlyIntent
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("Server=$Server")
    $parts.Add("Database=$Database")
    $parts.Add('TrustServerCertificate=True')
    $parts.Add('Connect Timeout=30')
    # Long-running bulk reads/writes; the command timeout is set per-command.
    $parts.Add('Application Name=eJarDbAuditing-Migration')

    if ($AuthMode -eq 'Windows') {
        $parts.Add('Integrated Security=True')
    }
    else {
        if (-not $UserId -or -not $Password) {
            throw "AuthMode 'Sql' requires -UserId and -Password."
        }
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringUni(
            [System.Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password))
        $parts.Add("User ID=$UserId")
        $parts.Add("Password=$plain")
    }

    # W8: ApplicationIntent only takes effect through an AG LISTENER. Against a
    # direct node name it is ignored. Emitted only when it can actually do
    # something, so it does not create a false impression of read-only routing.
    if ($ReadOnlyIntent) { $parts.Add('ApplicationIntent=ReadOnly') }

    return ($parts -join ';') + ';'
}

function Invoke-AbpScalar {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$Connection,
        [Parameter(Mandatory)][string]$Sql,
        [hashtable]$Parameters = @{},
        [int]$CommandTimeout = 600
    )

    if ($Connection.State -ne [System.Data.ConnectionState]::Open) {
        throw "Invoke-AbpScalar: connection is not open (State = $($Connection.State))."
    }

    $cmd = $null
    try {
        $cmd = $Connection.CreateCommand()
        $cmd.CommandText    = $Sql
        $cmd.CommandTimeout = $CommandTimeout

        foreach ($name in $Parameters.Keys) {
            $value = $Parameters[$name]
            # Explicit typing - the original inferred BigInt for anything that
            # was not an Int, which would have mistyped a DateTime parameter.
            switch ($true) {
                { $value -is [datetime] } {
                    $p = $cmd.Parameters.Add("@$name", [System.Data.SqlDbType]::DateTime2)
                    $p.Value = [datetime]$value; break
                }
                { $value -is [int] } {
                    $p = $cmd.Parameters.Add("@$name", [System.Data.SqlDbType]::Int)
                    $p.Value = [int]$value; break
                }
                default {
                    $p = $cmd.Parameters.Add("@$name", [System.Data.SqlDbType]::BigInt)
                    $p.Value = [int64]$value; break
                }
            }
        }
        return $cmd.ExecuteScalar()
    }
    finally {
        if ($cmd) { $cmd.Dispose() }
    }
}

function Get-AbpRetentionFloor {
    <#
      The earliest date to copy. Aligned to the START of the period so the floor
      lands exactly on a partition boundary - a floor mid-period would leave a
      partially populated oldest partition that retention then ages out early.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TableConfig,
        [datetime]$AsOfUtc = [datetime]::UtcNow
    )

    if ($TableConfig.RetentionUnit -eq 'Month') {
        $d = $AsOfUtc.AddMonths(-$TableConfig.RetentionCount)
        return [datetime]::new($d.Year, $d.Month, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
    }
    else {
        $d = $AsOfUtc.AddDays(-7 * $TableConfig.RetentionCount).Date
        # Monday of that week, independent of culture/DATEFIRST.
        $offset = ([int]$d.DayOfWeek + 6) % 7
        return $d.AddDays(-$offset)
    }
}

function Get-AbpSourceQuery {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$TableConfig, [switch]$CountOnly)

    $t = $TableConfig

    if ($t.ParentJoin) {
        # C7b: INNER JOIN is required (an orphan has no ChangeTime and so no
        # partition). Orphans are counted separately by Measure-AbpOrphan.
        # NOTE: no READPAST, no NOLOCK - RCSI makes plain READ COMMITTED
        # non-blocking and consistent.
        $cols = ($t.Columns | ForEach-Object {
            if ($_ -eq 'ChangeTime') { 'ec.ChangeTime' } else { "pc.$_" }
        }) -join ",`n       "

        if ($CountOnly) {
            return @"
SELECT COUNT_BIG(*)
FROM dbo.AbpEntityPropertyChanges AS pc
     INNER JOIN dbo.AbpEntityChanges AS ec ON ec.Id = pc.EntityChangeId
WHERE ec.ChangeTime >= @RetentionFrom;
"@
        }

        return @"
SELECT TOP (@ChunkSize)
       $cols
FROM dbo.AbpEntityPropertyChanges AS pc
     INNER JOIN dbo.AbpEntityChanges AS ec ON ec.Id = pc.EntityChangeId
WHERE pc.Id > @LastId
  AND ec.ChangeTime >= @RetentionFrom
ORDER BY pc.Id;
"@
    }

    $cols = $t.Columns -join ",`n       "

    if ($CountOnly) {
        return @"
SELECT COUNT_BIG(*)
FROM dbo.$($t.Name)
WHERE $($t.DateColumn) >= @RetentionFrom;
"@
    }

    return @"
SELECT TOP (@ChunkSize)
       $cols
FROM dbo.$($t.Name)
WHERE Id > @LastId
  AND $($t.DateColumn) >= @RetentionFrom
ORDER BY Id;
"@
}

function Measure-AbpOrphan {
    <#
      C7b: quantify property-change rows whose parent entity-change is absent.

      EXPENSIVE. This is a full anti-join over 1,277,745,190 rows with no date
      column to narrow it - there is no cheap way to scope it, because the only
      thing that dates a property-change row IS its parent. Expect hours.

      Run it ONCE during rehearsal on a restored copy, or against the async
      replica SRV-AZ-AG03 out of hours. It is opt-in (-CheckOrphans) precisely
      so it never fires accidentally during a cutover window.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Data.SqlClient.SqlConnection]$SourceConnection,
        [int]$CommandTimeout = 21600
    )

    $sql = @"
SELECT COUNT_BIG(*)
FROM dbo.AbpEntityPropertyChanges AS pc
WHERE NOT EXISTS (SELECT 1 FROM dbo.AbpEntityChanges AS ec WHERE ec.Id = pc.EntityChangeId);
"@
    return Invoke-AbpScalar -Connection $SourceConnection -Sql $sql -CommandTimeout $CommandTimeout
}

function Copy-AbpTable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$TableConfig,
        [Parameter(Mandatory)][string]$SourceConnectionString,
        [Parameter(Mandatory)][string]$TargetConnectionString,
        [datetime]$RetentionFrom,
        [int]$ChunkSize      = 500000,
        [int]$BatchSize      = 50000,
        [int]$BulkTimeoutSec = 3600,     # W7: finite, was 0 (infinite)
        [switch]$CheckOrphans,           # see Measure-AbpOrphan - expensive, opt-in
        [switch]$WhatIf
    )

    $t          = $TableConfig
    $source     = "dbo.$($t.Name)"
    $target     = "dbo.$($t.Name)_Clone"
    $started    = Get-Date
    $totalRows  = [int64]0

    if (-not $PSBoundParameters.ContainsKey('RetentionFrom')) {
        $RetentionFrom = Get-AbpRetentionFloor -TableConfig $t
    }

    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host "TABLE          : $source  ->  $target"
    Write-Host "Retention floor: $($RetentionFrom.ToString('yyyy-MM-dd HH:mm:ss')) UTC  ($($t.RetentionCount) $($t.RetentionUnit.ToLower())s on $($t.DateColumn))"
    Write-Host "Chunk / Batch  : $ChunkSize / $BatchSize"
    Write-Host ('=' * 78)

    $srcConn = $null; $tgtConn = $null; $bulk = $null; $reader = $null; $cmd = $null

    try {
        $srcConn = [System.Data.SqlClient.SqlConnection]::new($SourceConnectionString)
        $tgtConn = [System.Data.SqlClient.SqlConnection]::new($TargetConnectionString)
        $srcConn.Open()
        $tgtConn.Open()

        Write-Host "Source: $($srcConn.DataSource)   Target: $($tgtConn.DataSource)"

        # ---- Guard: the target must be writable, i.e. we must be on the primary.
        $isPrimary = Invoke-AbpScalar -Connection $tgtConn `
            -Sql "SELECT CAST(ISNULL(sys.fn_hadr_is_primary_replica(DB_NAME()),1) AS BIGINT);"
        if ([int64]$isPrimary -ne 1) {
            throw "Target $($tgtConn.DataSource) is NOT the primary replica for this database. " +
                  "eJarDbAuditing is in AG SQLAG02, whose primary is SRV-AZ-AG002."
        }

        # ---- Expected row count in the window, for reconciliation.
        $expected = Invoke-AbpScalar -Connection $srcConn `
            -Sql (Get-AbpSourceQuery -TableConfig $t -CountOnly) `
            -Parameters @{ RetentionFrom = $RetentionFrom } `
            -CommandTimeout 3600
        Write-Host "Source rows in retention window: $expected"

        if ($t.ParentJoin) {
            if ($CheckOrphans) {
                Write-Host 'Orphan check running (full anti-join, expect hours)...'
                $orphans = Measure-AbpOrphan -SourceConnection $srcConn
                if ([int64]$orphans -gt 0) {
                    Write-Warning ("C7b: $orphans property-change row(s) have no parent " +
                        "AbpEntityChanges row and CANNOT be migrated (no ChangeTime, so no " +
                        "partition). This is a reported, deliberate exclusion - the original " +
                        "scripts dropped them silently via INNER JOIN.")
                }
                else {
                    Write-Host 'Orphan check: none found.'
                }
            }
            else {
                Write-Host ('Orphan check SKIPPED (-CheckOrphans not set). Rows with no parent ' +
                            'AbpEntityChanges row are excluded by the INNER JOIN. Run once ' +
                            'during rehearsal to quantify.')
            }
        }

        if ($WhatIf) {
            Write-Host 'WhatIf: no rows copied.'
            return [pscustomobject]@{
                Table = $t.Name; Expected = [int64]$expected; Copied = [int64]0
                RetentionFrom = $RetentionFrom; Duration = (Get-Date) - $started; WhatIf = $true
            }
        }

        # ---- Bulk copy setup.
        $options = [System.Data.SqlClient.SqlBulkCopyOptions]::TableLock `
             -bor [System.Data.SqlClient.SqlBulkCopyOptions]::KeepIdentity `
             -bor [System.Data.SqlClient.SqlBulkCopyOptions]::KeepNulls `
             -bor [System.Data.SqlClient.SqlBulkCopyOptions]::UseInternalTransaction

        $bulk = [System.Data.SqlClient.SqlBulkCopy]::new($tgtConn, $options, $null)
        $bulk.DestinationTableName = $target
        $bulk.BatchSize            = $BatchSize
        $bulk.BulkCopyTimeout      = $BulkTimeoutSec
        $bulk.EnableStreaming      = $true
        foreach ($c in $t.Columns) { [void]$bulk.ColumnMappings.Add($c, $c) }

        # ---- C8: checkpoint WITHOUT NOLOCK.
        $checkpointSql = "SELECT ISNULL(MAX(Id), 0) FROM $target;"
        $lastId = [int64](Invoke-AbpScalar -Connection $tgtConn -Sql $checkpointSql)
        Write-Host "Resuming from target MAX(Id) = $lastId"

        $sourceSql = Get-AbpSourceQuery -TableConfig $t

        while ($true) {
            $cmd = $srcConn.CreateCommand()
            $cmd.CommandText    = $sourceSql
            $cmd.CommandTimeout = 0     # the reader streams; bulk timeout bounds the write

            $pChunk = $cmd.Parameters.Add('@ChunkSize',     [System.Data.SqlDbType]::Int)
            $pChunk.Value = $ChunkSize
            $pLast  = $cmd.Parameters.Add('@LastId',        [System.Data.SqlDbType]::BigInt)
            $pLast.Value  = $lastId
            $pFrom  = $cmd.Parameters.Add('@RetentionFrom', [System.Data.SqlDbType]::DateTime2)
            $pFrom.Value  = $RetentionFrom

            $before = $bulk.RowsCopied
            $sw     = [System.Diagnostics.Stopwatch]::StartNew()

            try {
                $reader = $cmd.ExecuteReader([System.Data.CommandBehavior]::SequentialAccess)
                $bulk.WriteToServer($reader)
            }
            finally {
                if ($reader) { if (-not $reader.IsClosed) { $reader.Close() }; $reader.Dispose(); $reader = $null }
                if ($cmd)    { $cmd.Dispose(); $cmd = $null }
            }

            $sw.Stop()
            # I14: real row count from the provider, not an Id-range subtraction.
            $chunkRows  = $bulk.RowsCopied - $before
            $totalRows += $chunkRows

            if ($chunkRows -eq 0) { Write-Host 'No more rows in the retention window. Done.'; break }

            $newLastId = [int64](Invoke-AbpScalar -Connection $tgtConn -Sql $checkpointSql)
            if ($newLastId -le $lastId) {
                throw "No forward progress: target MAX(Id) is still $newLastId after copying $chunkRows row(s). Aborting rather than looping."
            }
            $lastId = $newLastId

            $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($chunkRows / $sw.Elapsed.TotalSeconds, 0) } else { 0 }
            Write-Host ("  chunk {0,10:N0} rows | total {1,13:N0} | {2,8:N0} rows/s | MAX(Id) {3} | {4:hh\:mm\:ss}" -f `
                        $chunkRows, $totalRows, $rate, $lastId, $sw.Elapsed)
        }

        # ---- Reconciliation (C7): the original had none anywhere.
        $targetCount = Invoke-AbpScalar -Connection $tgtConn `
            -Sql "SELECT COUNT_BIG(*) FROM $target;" -CommandTimeout 3600

        $delta = [int64]$expected - [int64]$targetCount
        Write-Host ''
        Write-Host "RECONCILIATION  source(window) = $expected   target = $targetCount   delta = $delta"
        if ($delta -ne 0) {
            Write-Warning ("Row count mismatch of $delta for $($t.Name). Expected during the " +
                "bulk phase while the source is live (new rows keep arriving). Must be 0 " +
                "after the final delta with the application quiesced.")
        }
        else {
            Write-Host 'Counts match.'
        }

        return [pscustomobject]@{
            Table = $t.Name; Expected = [int64]$expected; Copied = [int64]$totalRows
            TargetCount = [int64]$targetCount; Delta = $delta
            RetentionFrom = $RetentionFrom; Duration = (Get-Date) - $started; WhatIf = $false
        }
    }
    finally {
        foreach ($d in @($reader, $cmd, $bulk)) {
            if ($d) { try { $d.Dispose() } catch { } }
        }
        foreach ($c in @($srcConn, $tgtConn)) {
            if ($c) {
                try { if ($c.State -ne [System.Data.ConnectionState]::Closed) { $c.Close() }; $c.Dispose() } catch { }
            }
        }
        Write-Host ("Elapsed for $($t.Name): {0:hh\:mm\:ss}" -f ((Get-Date) - $started))
    }
}

Export-ModuleMember -Function Get-AbpTableConfig, New-AbpConnectionString, Invoke-AbpScalar,
                              Get-AbpRetentionFloor, Get-AbpSourceQuery, Measure-AbpOrphan,
                              Copy-AbpTable
