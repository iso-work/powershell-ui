#requires -Version 7.0
[CmdletBinding()]
param([string]$HaloUrl='https://support.isoutsource.com',[string]$OutputRoot)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if(-not $OutputRoot) { $OutputRoot=Join-Path $root 'reports' }
Import-Module (Join-Path $root 'infrastructure/Catalog.psm1') -Force
Import-Module (Join-Path $root 'infrastructure/Launcher.psm1') -Force
$session=New-LauncherSession
try {
    $item=Get-ScriptCatalog $root | Where-Object { $_.Manifest.id -eq 'halo-appointment-manager' }
    if(-not $item -or $item.Errors.Count) { throw 'The Halo preparation adapter failed its integrity check.' }
    $report=Invoke-LauncherAdapter -Manifest $item.Manifest -Parameters @{HaloUrl=$HaloUrl} -Context $session -EntryPath $item.Path -OutputRoot $OutputRoot -ExpectedHash $item.Hash
    if($report.Report.status -ne 'Completed') { throw 'Extension preparation failed. Review the local report.' }
    $report
} finally { Clear-LauncherSession $session }
