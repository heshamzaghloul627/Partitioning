<#
================================================================================
 Run-BulkLoad.ps1
--------------------------------------------------------------------------------
 PHASE 1 of the data migration: bulk-load the retention window into the
 partitioned _Clone tables while the application stays online.

 Replaces the four 01_Bulk_Load/*_BulkCopy.ps1 scripts. All logic lives in
 ../_Common/AbpBulkCopy.psm1 - see that file's header for the full list of fixes.

--------------------------------------------------------------------------------
 TOPOLOGY (verified 2026-08-29 - the original scripts had this back to front)
--------------------------------------------------------------------------------
   eJarDbAuditing is in availability group SQLAG02.

     SRV-AZ-AG002   PRIMARY        SYNCHRONOUS_COMMIT   <- the only writable copy
     SRV-AZ-AG01    SECONDARY      SYNCHRONOUS_COMMIT   AUTOMATIC failover
     SRV-AZ-AG03    SECONDARY      ASYNCHRONOUS_COMMIT  MANUAL failover

   Source defaults to SRV-AZ-AG03. W8: long reads on a readable secondary hold
   schema-stability locks that block redo. Doing that to the SYNCHRONOUS_COMMIT
   replica (SRV-AZ-AG01) grows its redo queue and extends failover RTO on a
   replica configured for automatic failover. The async replica is the safe
   place to spend hours reading.

--------------------------------------------------------------------------------
 RESTARTABLE
--------------------------------------------------------------------------------
 Safe to re-run after any failure. Each table resumes from MAX(Id) on its target.
 Nothing is dropped or truncated by this script.

--------------------------------------------------------------------------------
 EXAMPLES
--------------------------------------------------------------------------------
   # Preview: row counts and retention floors, no data movement
   .\Run-BulkLoad.ps1 -WhatIf

   # Windows authentication (default)
   .\Run-BulkLoad.ps1

   # SQL authentication
   .\Run-BulkLoad.ps1 -AuthMode Sql -UserId svc_migration

   # One table only, smaller chunks on a constrained window
   .\Run-BulkLoad.ps1 -Only AbpEntityChangeSets -ChunkSize 100000
================================================================================
#>

[CmdletBinding()]
param(
    [string]$SourceServer = 'SRV-AZ-AG03',
    [string]$TargetServer = 'SRV-AZ-AG002',
    [string]$Database     = 'eJarDbAuditing',

    [ValidateSet('Windows','Sql')]
    [string]$AuthMode     = 'Windows',
    [string]$UserId,

    [string[]]$Only,
    [int]$ChunkSize       = 500000,
    [int]$BatchSize       = 50000,
    [int]$BulkTimeoutSec  = 3600,

    [switch]$CheckOrphans,
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
Write-Host '# eJarDbAuditing - PHASE 1 BULK LOAD'
Write-Host "# Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "# Source  : $SourceServer  (read-only)"
Write-Host "# Target  : $TargetServer  (must be PRIMARY)"
Write-Host "# Auth    : $AuthMode"
Write-Host ('#' * 78)

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
                        -CheckOrphans:$CheckOrphans `
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
    }
    Write-Host ("# Total elapsed: {0:hh\:mm\:ss}" -f ((Get-Date) - $overall))
    Write-Host ''
    Write-Host '# NEXT: while the application is still online, re-run this script as many'
    Write-Host '#       times as needed to keep the gap small. Then quiesce the app and run'
    Write-Host '#       ..\02_Delta\Run-Delta.ps1 followed by the cutover script.'
    Write-Host ('#' * 78)
}
