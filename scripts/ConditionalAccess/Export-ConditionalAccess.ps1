#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][guid]$ClientId,
    [bool]$IncludeHiddenMembership=$true,
    [bool]$IncludeFilterContext=$true,
    [bool]$UseBetaPolicies=$true,
    [ValidateRange(1,1440)][int]$MaxMinutes=180,
    [string]$OutputRoot
)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $OutputRoot) { $OutputRoot=Join-Path $root 'reports' }
Import-Module (Join-Path $root 'infrastructure\Catalog.psm1') -Force
Import-Module (Join-Path $root 'infrastructure\Launcher.psm1') -Force
$context=New-LauncherSession
$parameters=@{TenantId=$TenantId;ClientId=$ClientId.ToString();IncludeHiddenMembership=$IncludeHiddenMembership;IncludeFilterContext=$IncludeFilterContext;UseBetaPolicies=$UseBetaPolicies;MaxMinutes=$MaxMinutes}
try {
    $items=@(Get-ScriptCatalog $root | Where-Object {$_.Manifest.id -eq 'conditional-access'})
    if($items.Count -ne 1 -or $items[0].Errors.Count) { throw 'Conditional Access adapter is missing or failed its integrity check.' }
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess -ConsoleSignIn
    $item=$items[0]
    $report=Invoke-LauncherAdapter $item.Manifest $parameters $context $item.Path $OutputRoot $item.Hash
    $report
    if($report.Report.status -eq 'Failed') { throw 'Conditional Access collection failed. Review the saved report.' }
} finally { Clear-LauncherSession $context }
