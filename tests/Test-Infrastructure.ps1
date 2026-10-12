$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'infrastructure/Catalog.psm1') -Force
Import-Module (Join-Path $root 'infrastructure/Launcher.psm1') -Force
function Assert($condition,$message) { if(-not $condition) { throw $message } }
$files=@(Get-ChildItem -LiteralPath (Join-Path $root 'infrastructure') -File -Filter *.ps*)+
    @(Get-Item -LiteralPath (Join-Path $root 'Start-PowerShellUI.ps1'))+
    @(Get-ChildItem -LiteralPath (Join-Path $root 'scripts') -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter *.ps1 })
foreach($file in $files) {
    $tokens=$null; $errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) "Syntax errors: $($file.FullName): $errors"
}
$catalog=@(Get-ScriptCatalog $root)
Assert ($catalog.Count -eq 4) 'Expected four manifest-only reporting adapters.'
foreach($item in $catalog) { Assert ($item.Errors.Count -eq 0) "Adapter integrity: $($item.Name): $($item.Errors)" }
Assert (@($catalog | Where-Object Path -match 'upstream').Count -eq 0) 'Upstream management scripts must not be exposed.'
$session=New-LauncherSession
Assert ((Resolve-LauncherTenant 'Contoso.onmicrosoft.com') -eq 'contoso.onmicrosoft.com') 'Verified tenant-domain input failed.'
$tenantBlocked=$false
try { Resolve-LauncherTenant 'contoso.com/../../common?x=1' } catch { $tenantBlocked=$true }
Assert $tenantBlocked 'Unsafe tenant authority input was accepted.'
$secret=ConvertTo-SecureString 'fixture-password' -AsPlainText -Force
$session.Credentials.ActiveDirectory=[pscredential]::new('fixture-user',$secret)
$storedSecret=$session.Credentials.ActiveDirectory.Password
$session.Tokens.Graph=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force
$clean=Protect-ReportData ([pscustomobject]@{password='do-not-export';clientSecret='do-not-export';safe='visible';PasswordLastSetUtc='2025-01-01';nested=@([pscustomobject]@{accessToken='do-not-export'})})
Assert ($clean.password -eq '[REDACTED]' -and $clean.clientSecret -eq '[REDACTED]') 'Secret field redaction failed.'
Assert ($clean.safe -eq 'visible' -and $clean.PasswordLastSetUtc -eq '2025-01-01') 'Evidence fields were removed.'
Clear-LauncherSession $session
Assert ($session.Credentials.Count -eq 0 -and $session.Tokens.Count -eq 0) 'Session cleanup failed.'
$disposed=$false
try { $null=$storedSecret.Copy() } catch { $disposed=$true }
Assert $disposed 'Credential SecureString was not disposed.'
$secret.Dispose()
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('powershell-ui-tests-'+[guid]::NewGuid())
[void](New-Item -ItemType Directory -Path $fixture)
try {
    $manifest=@{id='offline-test';name='Offline report';purpose='Synthetic data only';source='test';output=@{llmInstructions='Fixture-specific guidance.'}}
    $result=[pscustomobject]@{Summary=[pscustomobject]@{ReadOnly=$true;Count=1};Records=@([pscustomobject]@{Name='one';password='never-write-this';Id='fixture-1'});Limitations=@('Synthetic fixture.')}
    $written=Write-LauncherReport $manifest @{Server='fixture'} $result 'Completed' $fixture ([DateTime]::UtcNow)
    $json=Get-Content -LiteralPath $written.JsonPath -Raw
    $parsed=$json | ConvertFrom-Json
    Assert ($parsed.records.Count -eq 1 -and $parsed.records[0].Id -eq 'fixture-1') 'Structured report roundtrip failed.'
    Assert ($json -notmatch 'never-write-this' -and $parsed.llmInstructions -contains 'Fixture-specific guidance.') 'Report redaction or LLM guidance failed.'
    Assert ((Get-Content -LiteralPath $written.MarkdownPath -Raw) -match 'Collected data') 'Human-readable report missing.'
    $entry=Join-Path $fixture 'Invoke-Report.ps1'
    Set-Content -LiteralPath $entry -Value 'param($Parameters,$Context) [pscustomobject]@{Summary=[pscustomobject]@{Incomplete=$true}; Records=@(); Limitations=@("fixture")}'
    $hash=(Get-FileHash -LiteralPath $entry).Hash
    $context=New-LauncherSession
    $report=Invoke-LauncherAdapter $manifest @{} $context $entry $fixture $hash
    Assert ($report.Report.status -eq 'Partial') 'Incomplete reports must be marked Partial.'
    $worker=[powershell]::Create()
    try {
        [void]$worker.AddScript({param($module,$manifest,$context,$entry,$output,$hash) Import-Module $module -Force; Invoke-LauncherAdapter $manifest @{} $context $entry $output $hash}).AddArgument((Join-Path $root 'infrastructure/Launcher.psm1')).AddArgument($manifest).AddArgument($context).AddArgument($entry).AddArgument($fixture).AddArgument($hash)
        $handle=$worker.BeginInvoke()
        $async=$worker.EndInvoke($handle)
        Assert ($async[-1].Report.status -eq 'Partial' -and $context.ContainsKey('RunDirectory')) 'Asynchronous runspace execution/shared session failed.'
    } finally { $worker.Dispose() }
    $blocked=$false
    try { Invoke-LauncherAdapter $manifest @{} $context $entry $fixture ('0'*64) } catch { $blocked=$true }
    Assert $blocked 'Modified/unregistered wrapper was not rejected.'
    Set-Content -LiteralPath $entry -Value 'param($Parameters,$Context) throw "sensitive-error-password"'
    $hash=(Get-FileHash -LiteralPath $entry).Hash
    $failed=Invoke-LauncherAdapter $manifest @{} $context $entry $fixture $hash
    $failedJson=Get-Content -LiteralPath $failed.JsonPath -Raw
    Assert ($failed.Report.status -eq 'Failed' -and $failedJson -notmatch 'sensitive-error-password') 'Failure status or safe error handling failed.'
    Clear-LauncherSession $context
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture)
    $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'powershell-ui-tests-*') { throw 'Unexpected test cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
& (Join-Path $root 'scripts/CleanupMonster/Test-Adapter.ps1')
& (Join-Path $root 'scripts/IntuneManagement/Test-Adapter.ps1')
& (Join-Path $root 'scripts/azqr/tests/Test-Wrapper.ps1')
& (Join-Path $root 'scripts/RebootHistory/Test-Adapter.ps1')
'PASS: launcher syntax, manifest-only discovery, integrity checks, redaction, session cleanup, report roundtrip and partial/failure handling. No live target queries were made.'

