<#
================================================================================
 Run-Delta.ps1
--------------------------------------------------------------------------------
 PHASE 2 of the data migration: catch up the rows that arrived during the bulk
 load, with the application quiesced, immediately before cutover.

 Replaces the four 02_Delta/*_BulkCopy.ps1 scripts.

--------------------------------------------------------------------------------
 W11 - WHAT WAS ACTUALLY WRONG WITH THE ORIGINAL "DELTA"
--------------------------------------------------------------------------------
 The original 02_Delta scripts were BYTE-IDENTICAL to the 01_Bulk_Load scripts
 for three of the four tables (AbpEntityChangeSets 12,169 B both;
 AbpEntityChanges 11,770 B both; AbpEntityPropertyChanges 12,257 B both) and
 differed by three bytes for AbpAuditLogs. There was no delta logic at all -
 just the same MAX(Id) resume, which captures only newly INSERTED rows.

 That is survivable ONLY because these tables are append-only. This script now
 verifies that assumption instead of assuming it (see -SkipUpdateCheck), because
 if the application ever starts updating audit rows, a MAX(Id) delta will miss
 every one of those changes silently.

--------------------------------------------------------------------------------
 DIFFERENCE FROM PHASE 1
--------------------------------------------------------------------------------
 Source is the PRIMARY (SRV-AZ-AG002), not the async replica. During the bulk
 phase, replica lag is harmless because a later pass picks the rows up. For the
 FINAL delta it is not: a lagging async secondary would make the migration look
 complete while rows were still missing. Read from the primary.

--------------------------------------------------------------------------------
 EXAMPLES
--------------------------------------------------------------------------------
   .\Run-Delta.ps1 -WhatIf        # counts only
   .\Run-Delta.ps1                # the real final delta
================================================================================
#>

[CmdletBinding()]
param(
    # Both default to the PRIMARY - see header.
    [string]$SourceServer = 'SRV-AZ-AG002',
    [string]$TargetServer = 'SRV-AZ-AG002',
    [string]$Database     = 'eJarDbAuditing',

    [ValidateSet('Windows','Sql')]
    [string]$AuthMode     = 'Windows',
    [string]$UserId,

    [string[]]$Only,
    [int]$ChunkSize       = 200000,   # smaller: this runs inside the outage window
    [int]$BatchSize       = 25000,
    [int]$BulkTimeoutSec  = 1800,

    [switch]$SkipUpdateCheck,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\_Common\AbpBulkCopy.psm1') -Force

$password = $null
if ($AuthMode -eq 'Sql') {
    if (-not $UserId) { throw '-UserId is required when -AuthMode Sql.' }
    $password = Read-Host -AsSecureString "Password for SQL login '$UserId'"
}

$srcCs = New-AbpConnectionString -Server $SourceServer -Database $Database `
            -AuthMode $AuthMode -UserId $UserId -Password $password
$tgtCs = New-AbpConnectionString -Server $TargetServer -Database $Database `
            -AuthMode $AuthMode -UserId $UserId -Password $password

Write-Host ('#' * 78)
Write-Host '# eJarDbAuditing - PHASE 2 FINAL DELTA'
Write-Host "# Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "# Source  : $SourceServer  (PRIMARY - not the async replica)"
Write-Host "# Target  : $TargetServer"
Write-Host ('#' * 78)
Write-Host ''
Write-Host '!! The application MUST be quiesced before this runs. A MAX(Id) delta'
Write-Host '!! cannot converge against a live writer, and the reconciliation deltas'
Write-Host '!! below must all reach zero for the cutover to be safe.'
Write-Host ''

# ------------------------------------------------------------------------------
# W11: verify the append-only assumption the delta strategy depends on.
# ------------------------------------------------------------------------------
if (-not $SkipUpdateCheck) {
    Write-Host 'Checking Query Store for UPDATE/DELETE activity against the Abp tables...'
    $conn = [System.Data.SqlClient.SqlConnection]::new($srcCs)
    try {
        $conn.Open()
        $sql = @"
SELECT ISNULL(SUM(rs.count_executions), 0)
FROM sys.query_store_query q
JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
JOIN sys.query_store_plan p        ON q.query_id = p.query_id
JOIN sys.query_store_runtime_stats rs ON p.plan_id = rs.plan_id
WHERE qt.query_sql_text LIKE '%Abp%'
  AND (qt.query_sql_text LIKE '%UPDATE %' OR qt.query_sql_text LIKE '%DELETE %')
  AND qt.query_sql_text NOT LIKE '%query_store%';
"@
        $mutations = Invoke-AbpScalar -Connection $conn -Sql $sql -CommandTimeout 300
        if ([int64]$mutations -gt 0) {
            Write-Warning ("Query Store shows $mutations UPDATE/DELETE execution(s) touching " +
                'the Abp tables. A MAX(Id)-based delta CANNOT capture those changes. Review ' +
                'them before cutting over, or the clone will silently diverge from the source. ' +
                'Re-run with -SkipUpdateCheck once you have confirmed they are benign.')
            if (-not $WhatIf) {
                throw 'Aborting: append-only assumption not verified. See warning above.'
            }
        }
        else {
            Write-Host 'No UPDATE/DELETE activity found - append-only assumption holds.'
        }
    }
    finally {
        if ($conn) { try { $conn.Close(); $conn.Dispose() } catch { } }
    }
    Write-Host ''
}

$overall = Get-Date
$results = @()

try {
    foreach ($table in (Get-AbpTableConfig -Only $Only)) {
        $results += Copy-AbpTable -TableConfig $table `
                        -SourceConnectionString $srcCs `
                        -TargetConnectionString $tgtCs `
                        -ChunkSize      $ChunkSize `
                        -BatchSize      $BatchSize `
                        -BulkTimeoutSec $BulkTimeoutSec `
                        -WhatIf:$WhatIf
    }
}
finally {
    Write-Host ''
    Write-Host ('#' * 78)
    Write-Host '# SUMMARY'
    Write-Host ('#' * 78)
    if ($results) {
        $results | Format-Table Table, Expected, Copied, TargetCount, Delta,
                                RetentionFrom, Duration -AutoSize |
                   Out-String -Width 200 | Write-Host

        $bad = @($results | Where-Object { -not $_.WhatIf -and $_.Delta -ne 0 })
        if ($bad.Count -gt 0) {
            Write-Host ''
            Write-Warning ('DO NOT CUT OVER. ' + $bad.Count + ' table(s) still have a non-zero ' +
                'reconciliation delta: ' + (($bad | ForEach-Object { "$($_.Table)=$($_.Delta)" }) -join ', ') +
                '. Confirm the application is fully quiesced and re-run.')
        }
        elseif (-not $WhatIf) {
            Write-Host ''
            Write-Host '# All reconciliation deltas are zero. Safe to proceed to:'
            Write-Host '#   ..\..\03_Post Migration\02_Create_Nonclustered_Indexes.sql'
            Write-Host '#   ..\..\03_Post Migration\03_Cutover.sql'
        }
    }
    Write-Host ("# Total elapsed: {0:hh\:mm\:ss}" -f ((Get-Date) - $overall))
    Write-Host ('#' * 78)
}
