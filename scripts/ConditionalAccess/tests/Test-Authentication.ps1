$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
Import-Module (Join-Path $root 'infrastructure\Launcher.psm1') -Force
function Assert-CaAuth($Condition,[string]$Message) { if(-not $Condition){throw ('CA auth assertion failed: '+$Message)} }
$global:CaAuthFixture=@{Requests=[Collections.Generic.List[object]]::new();Scenario='Complete';Scope=''}
function global:Invoke-RestMethod {
    param($Method,$Uri,$Body)
    Assert-CaAuth ($Method -eq 'Post' -and ([uri]$Uri).Host -eq 'login.microsoftonline.com') 'Authentication may POST only to Microsoft login.'
    $global:CaAuthFixture.Requests.Add([pscustomobject]@{Uri=$Uri;Client=$Body.client_id})
    if($Uri -like '*/devicecode') {
        $global:CaAuthFixture.Scope=$Body.scope
        return @{verification_uri='https://microsoft.com/devicelogin';user_code='FAKE-CODE';device_code='fixture-device-code';expires_in=60;interval=0}
    }
    $scope=$global:CaAuthFixture.Scope
    switch($global:CaAuthFixture.Scenario) {
        'WriteScope' {$scope+=' Policy.ReadWrite.ConditionalAccess'}
        'UnexpectedRead' {$scope+=' Mail.Read'}
        'MissingScope' {$scope=($scope -split ' ' | Where-Object {$_ -notlike '*Directory.Read.All'}) -join ' '}
    }
    return @{access_token='fixture-auth-token';scope=$scope;expires_in=3600}
}
function global:Start-Sleep { param($Seconds) }
$contexts=[Collections.Generic.List[object]]::new();$checks=0
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ca-auth-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
$parameters=@{TenantId='fixture.onmicrosoft.com';ClientId='00000000-0000-0000-0000-000000009999';IncludeHiddenMembership=$true;IncludeFilterContext=$true;IncludeDevices=$false}
try {
    $context=New-LauncherSession;$contexts.Add($context)
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess
    Assert-CaAuth ($context.Tokens.GraphConditionalAccess -is [Security.SecureString] -and -not $context.Tokens.ContainsKey('Graph')) 'CA token must be isolated from Intune.'
    $scope=$global:CaAuthFixture.Scope
    foreach($required in @('Policy.Read.All','Directory.Read.All','RoleManagement.Read.Directory','Agreement.Read.All','CrossTenantInformation.ReadBasic.All','NetworkAccess.Read.All','Member.Read.Hidden','CustomSecAttributeDefinition.Read.All','CustomSecAttributeAssignment.Read.All')) { Assert-CaAuth ($scope -like ('*https://graph.microsoft.com/'+$required+'*')) ('Required read scope missing: '+$required) }
    Assert-CaAuth ($scope -notmatch 'ReadWrite|offline_access|DeviceManagement') 'CA scopes must not include writes, refresh access or Intune permissions.'
    $requestCount=$global:CaAuthFixture.Requests.Count
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess
    Assert-CaAuth ($global:CaAuthFixture.Requests.Count -eq $requestCount) 'Same tenant/client/scopes must reuse the memory token.'
    $oldToken=$context.Tokens.GraphConditionalAccess
    $context.TokenMetadata.GraphConditionalAccess.Expires=[DateTime]::UtcNow.AddSeconds(30)
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess
    $disposed=$false;try{$null=$oldToken.Copy()}catch{$disposed=$true}
    Assert-CaAuth $disposed 'Superseded token SecureString must be disposed.'
    $checks++
    $parameters.TenantId='second.onmicrosoft.com'
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess
    Assert-CaAuth ($context.TokenMetadata.GraphConditionalAccess.Tenant -eq 'second.onmicrosoft.com' -and $global:CaAuthFixture.Requests[-1].Uri -like '*/second.onmicrosoft.com/*') 'Tenant change must bind a new sign-in.'
    $parameters.TenantId='fixture.onmicrosoft.com';$parameters.ClientId='00000000-0000-0000-0000-000000008888'
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess
    Assert-CaAuth ($context.TokenMetadata.GraphConditionalAccess.Client -eq $parameters.ClientId) 'Client change must bind a new sign-in.'
    $parameters.IncludeHiddenMembership=$false;$parameters.IncludeFilterContext=$false
    Connect-LauncherGraph $parameters $context -Profile ConditionalAccess
    Assert-CaAuth ($global:CaAuthFixture.Scope -notmatch 'Member.Read.Hidden|CustomSecAttribute') 'Disabled optional scopes must not be requested.'
    Connect-LauncherGraph $parameters $context
    Assert-CaAuth ($context.Tokens.ContainsKey('Graph') -and $context.Tokens.ContainsKey('GraphConditionalAccess') -and $global:CaAuthFixture.Scope -match 'DeviceManagementConfiguration.Read.All' -and $global:CaAuthFixture.Scope -notmatch 'Agreement.Read.All') 'Original Intune profile must remain separate and unchanged.'
    $checks++
    foreach($scenario in @('WriteScope','UnexpectedRead','MissingScope')) {
        $global:CaAuthFixture.Scenario=$scenario
        $rejected=New-LauncherSession;$contexts.Add($rejected);$blocked=$false
        try { Connect-LauncherGraph $parameters $rejected -Profile ConditionalAccess } catch { $blocked=$true }
        Assert-CaAuth ($blocked -and -not $rejected.Tokens.ContainsKey('GraphConditionalAccess')) ('Unsafe/incomplete grant must never be cached: '+$scenario)
        $checks++
    }
    $global:CaAuthFixture.Scenario='Complete';$parameters.TenantId='evil.example/../../common';$blocked=$false
    $requestCount=$global:CaAuthFixture.Requests.Count
    try { Connect-LauncherGraph $parameters $context -Profile ConditionalAccess } catch { $blocked=$true }
    Assert-CaAuth ($blocked -and $requestCount -eq $global:CaAuthFixture.Requests.Count) 'Invalid tenant must fail before OAuth requests.'
    $checks++
    $parameters.TenantId='fixture.onmicrosoft.com'
    $routedContext=New-LauncherSession;$contexts.Add($routedContext)
    $entry=Join-Path $fixture 'Invoke-Report.ps1'
    Set-Content -LiteralPath $entry -Value 'param($Parameters,$Context) [pscustomobject]@{Summary=[pscustomobject]@{Incomplete=$false;Scope="mock"};Records=@();Limitations=@("Synthetic authentication routing test.")}'
    $manifest=@{id='conditional-access';name='Synthetic CA routing';purpose='Offline auth dispatch';source='test';readOnly=$true;auth='GraphConditionalAccess'}
    $routed=Invoke-LauncherAdapter $manifest $parameters $routedContext $entry $fixture (Get-FileHash -LiteralPath $entry).Hash
    Assert-CaAuth ($routed.Report.status -eq 'Completed' -and $routed.Report.readOnly -and $routedContext.Tokens.ContainsKey('GraphConditionalAccess') -and -not $routedContext.Tokens.ContainsKey('Graph')) 'Launcher must dispatch CA through its isolated read-only profile.'
    $checks++
    "PASS: $checks Conditional Access authentication scenarios: exact read scopes, optional grants, tenant/client/cache isolation, disposal and write/unexpected/missing-scope rejection. OAuth was mocked."
} finally {
    Remove-Item Function:\Invoke-RestMethod,Function:\Start-Sleep -ErrorAction SilentlyContinue
    foreach($context in $contexts) { Clear-LauncherSession $context }
    Remove-Variable -Name CaAuthFixture -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture);$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'ca-auth-tests-*') { throw 'Unexpected CA auth fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
