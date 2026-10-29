$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'infrastructure/Catalog.psm1') -Force
Import-Module (Join-Path $root 'infrastructure/Launcher.psm1') -Force
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
$expected=@{
    'conditional-access'='ConditionalAccess'
    'intune-readonly'='IntuneManagement'
    'm365-security'='M365Security'
    'service-inventory'='ServiceInventory'
}
$files=@(Get-ChildItem -LiteralPath (Join-Path $root 'infrastructure') -File -Filter *.ps*)+
    @(Get-Item -LiteralPath (Join-Path $root 'Start-PowerShellUI.ps1'))
foreach($folder in $expected.Values){$files+=@(Get-ChildItem -LiteralPath (Join-Path $root ('scripts/'+$folder)) -File -Filter *.ps1)}
foreach($file in $files){
    $tokens=$null;$errors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Assert ($errors.Count -eq 0) ("Syntax errors: "+$file.FullName+': '+($errors -join '; '))
}
$catalog=@(Get-ScriptCatalog $root)
Assert ($catalog.Count -eq 4) 'Expected exactly four approved Microsoft 365 report tools.'
foreach($id in $expected.Keys){
    $matches=@($catalog | Where-Object {$_.Manifest.id -eq $id})
    Assert ($matches.Count -eq 1) ('Missing/duplicate Microsoft 365 adapter: '+$id)
    Assert ($matches[0].Errors.Count -eq 0) ('Adapter integrity: '+$id+': '+($matches[0].Errors -join '; '))
    Assert ($matches[0].Manifest.readOnly -eq $true) 'Every exposed report must be read-only.'
}
Assert (@($catalog | Where-Object Path -match '[\\/]upstream[\\/]').Count -eq 0) 'Reference source must not be exposed as an executable tool.'
$registry=Get-Content -LiteralPath (Join-Path $root 'infrastructure/adapters.lock.json') -Raw | ConvertFrom-Json -AsHashtable
Assert ($registry.Count -eq 4 -and @($registry.Keys | Where-Object {$_ -notin $expected.Keys}).Count -eq 0) 'The registry must contain only the four Microsoft 365 report IDs.'

$session=New-LauncherSession
Assert (-not $session.SharedGraph.Ready) 'Fresh session must start logged out.'
Assert ((Resolve-LauncherTenant 'Contoso.onmicrosoft.com') -eq 'contoso.onmicrosoft.com') 'Tenant-domain validation failed.'
$blocked=$false
try{Resolve-LauncherTenant 'contoso.com/../../common?x=1' | Out-Null}catch{$blocked=$true}
Assert $blocked 'Unsafe tenant authority input was accepted.'
$secret=ConvertTo-SecureString 'fixture-password' -AsPlainText -Force
$session.Credentials.Fixture=[pscredential]::new('fixture-user',$secret)
$storedSecret=$session.Credentials.Fixture.Password
$session.Tokens.Fixture=ConvertTo-SecureString 'fixture-token' -AsPlainText -Force
$session.Tenant.Id='00000000-0000-0000-0000-000000000101'
$session.Tenant.Account='reader@fixture.example'
$clean=Protect-ReportData ([pscustomobject]@{password='do-not-export';clientSecret='do-not-export';safe='visible';ObservedUtc='2026-01-01';nested=@([pscustomobject]@{accessToken='do-not-export'})})
Assert ($clean.password -eq '[REDACTED]' -and $clean.clientSecret -eq '[REDACTED]') 'Secret field redaction failed.'
Assert ($clean.safe -eq 'visible' -and $clean.ObservedUtc -eq '2026-01-01') 'Nonsecret evidence fields were lost.'
Clear-LauncherSession $session
Assert ($session.Credentials.Count -eq 0 -and $session.Tokens.Count -eq 0 -and -not $session.SharedGraph.Ready -and -not $session.Tenant.Id -and -not $session.Tenant.Account) 'Logout must clear app-owned identity and credentials.'
$disposed=$false;try{$null=$storedSecret.Copy()}catch{$disposed=$true}
Assert $disposed 'Credential SecureString was not disposed.'

$fixture=Join-Path ([IO.Path]::GetTempPath()) ('m365-infrastructure-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
$context=New-LauncherSession
try{
    $manifest=@{id='offline-test';name='Offline Microsoft 365 evidence';purpose='Synthetic data only';source='test';readOnly=$true;auth='M365';output=@{llmInstructions='Fixture-specific guidance.'}}
    $result=[pscustomobject]@{Summary=[pscustomobject]@{Incomplete=$false;Count=1};Records=@([pscustomobject]@{Id='fixture-1';Name='Example';password='never-write-this'});Limitations=@('Synthetic fixture only.')}
    $written=Write-LauncherReport $manifest @{Scope='fixture'} $result 'Completed' $fixture ([DateTime]::UtcNow)
    $json=Get-Content -LiteralPath $written.JsonPath -Raw
    $parsed=$json | ConvertFrom-Json
    Assert ($parsed.records.Count -eq 1 -and $parsed.records[0].Id -eq 'fixture-1') 'Structured report roundtrip failed.'
    Assert ($json -notmatch 'never-write-this' -and $parsed.llmInstructions -contains 'Fixture-specific guidance.') 'Report redaction/LLM guidance failed.'
    Assert ((Get-Content -LiteralPath $written.MarkdownPath -Raw) -match 'Collected data') 'Human-readable report missing.'

    # A ready synthetic session exercises report plumbing without any SDK/network.
    $context.SharedGraph.Ready=$true
    $context.SharedGraph.TenantId='00000000-0000-0000-0000-000000000101'
    $context.SharedGraph.ClientId='00000000-0000-0000-0000-000000000102'
    $context.Tenant.Id=$context.SharedGraph.TenantId
    $context.Tenant.Account='reader@fixture.example'
    $entry=Join-Path $fixture 'Invoke-Report.ps1'
    Set-Content -LiteralPath $entry -Value 'param($Parameters,$Context) [pscustomobject]@{Summary=[pscustomobject]@{Incomplete=$true};Records=@();Limitations=@("Synthetic partial collection.")}'
    $hash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
    $report=Invoke-LauncherAdapter $manifest @{} $context $entry $fixture $hash
    Assert ($report.Report.status -eq 'Partial') 'Incomplete collection must be marked Partial.'
    $worker=[powershell]::Create()
    try{
        [void]$worker.AddScript({param($module,$manifest,$context,$entry,$output,$hash) Import-Module $module -Force;Invoke-LauncherAdapter $manifest @{} $context $entry $output $hash}).AddArgument((Join-Path $root 'infrastructure/Launcher.psm1')).AddArgument($manifest).AddArgument($context).AddArgument($entry).AddArgument($fixture).AddArgument($hash)
        $handle=$worker.BeginInvoke();$async=$worker.EndInvoke($handle)
        Assert ($async[-1].Report.status -eq 'Partial' -and $context.ContainsKey('RunDirectory')) 'Async execution/shared context failed.'
    }finally{$worker.Dispose()}
    $blocked=$false
    try{Invoke-LauncherAdapter $manifest @{} $context $entry $fixture ('0'*64) | Out-Null}catch{$blocked=$true}
    Assert $blocked 'Changed/unregistered wrapper hash was accepted.'
    Set-Content -LiteralPath $entry -Value 'param($Parameters,$Context) throw "sensitive-error-password"'
    $hash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
    $failed=Invoke-LauncherAdapter $manifest @{} $context $entry $fixture $hash
    Assert ($failed.Report.status -eq 'Failed' -and (Get-Content -LiteralPath $failed.JsonPath -Raw) -notmatch 'sensitive-error-password') 'Failure status or safe error handling failed.'

    # Unknown manifests are ignored even if they claim read-only behavior.
    $unknown=Join-Path $fixture 'unapproved';[void][IO.Directory]::CreateDirectory($unknown)
    @{id='unapproved-local-tool';name='Fixture';purpose='Fixture';readOnly=$true;entryPoint='Invoke-Report.ps1';parameters=@()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $unknown 'launcher.json')
    Assert (@(Get-ScriptCatalog $unknown).Count -eq 0) 'An unknown local tool expanded the catalog.'
    $fake=Join-Path $fixture 'write-impostor';[void][IO.Directory]::CreateDirectory($fake)
    @{id='conditional-access';name='Fixture';purpose='Fixture';readOnly=$false;entryPoint='Invoke-Report.ps1';parameters=@()} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $fake 'launcher.json')
    Set-Content -LiteralPath (Join-Path $fake 'Invoke-Report.ps1') -Value 'param($Parameters,$Context)'
    Set-Content -LiteralPath (Join-Path $fake 'directions.txt') -Value 'Synthetic fixture.'
    $rejected=@(Get-ScriptCatalog $fake)
    Assert ($rejected.Count -eq 1 -and ($rejected[0].Errors -join ' ') -match 'Only read-only Microsoft 365') 'A write-capable manifest bypassed the catalog.'
    Assert (($rejected[0].Errors -join ' ') -match 'integrity') 'Unregistered content was not rejected.'
}finally{
    Clear-LauncherSession $context
    $resolved=[IO.Path]::GetFullPath($fixture);$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'm365-infrastructure-tests-*'){throw 'Unexpected fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
'PASS: Microsoft 365-only catalog, integrity, session cleanup, redaction, async report roundtrip and explicit partial/failure behavior. No tenant access.'
& (Join-Path $root 'scripts/IntuneManagement/Test-Adapter.ps1')
& (Join-Path $root 'scripts/ConditionalAccess/Test-Adapter.ps1')
& (Join-Path $root 'scripts/ConditionalAccess/tests/Test-Authentication.ps1')
& (Join-Path $root 'tests/Test-M365Session.ps1')
& (Join-Path $root 'tests/Test-ServiceSessions.ps1')
& (Join-Path $root 'scripts/M365Security/Test-Adapter.ps1')
& (Join-Path $root 'scripts/ServiceInventory/Test-Adapter.ps1')
