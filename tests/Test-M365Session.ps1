# Synthetic SDK fixtures only. No browser, tenant, application or network is accessed.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'infrastructure\Launcher.psm1') -Force
Import-Module (Join-Path $root 'infrastructure\M365Session.psm1') -Force
function Assert-M365Test($Condition,[string]$Message) { if(-not $Condition) { throw $Message } }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('m365-sdk-tests-'+[guid]::NewGuid())
$moduleDirectory=Join-Path $fixture 'Modules\Microsoft.Graph.Authentication'
[void][IO.Directory]::CreateDirectory($moduleDirectory)
$savedModulePath=$env:PSModulePath
$fixtureKey='powershell-ui-offline-m365-fixture'
$contexts=[Collections.Generic.List[object]]::new()
$failures=[Collections.Generic.List[string]]::new();$checks=[Collections.Generic.List[string]]::new()
$fakeModule=@'
$script:Fixture=[AppDomain]::CurrentDomain.GetData('powershell-ui-offline-m365-fixture')
function Connect-MgGraph {
    [CmdletBinding()]param([string]$TenantId,[string]$ClientId,[string[]]$Scopes,[string]$ContextScope,[switch]$NoWelcome,[switch]$UseDeviceCode)
    if($UseDeviceCode) { throw 'Fixture expected browser login, not device code.' }
    if($ContextScope -ne 'Process') { throw 'Fixture expected process-only SDK cache.' }
    $script:Fixture.Connects++
    $script:Fixture.ConnectCalls.Add([pscustomobject]@{Tenant=$TenantId;Client=$ClientId;Scopes=@($Scopes);ContextScope=$ContextScope;DeviceCode=[bool]$UseDeviceCode})
    if(-not $ClientId) {$ClientId='00000000-0000-0000-0000-000000000202'}
    $tenant=if($script:Fixture.Mode -eq 'WrongTenant'){'00000000-0000-0000-0000-000000000999'}else{$script:Fixture.TenantId}
    $granted=@($Scopes)
    if($script:Fixture.Mode -eq 'UnexpectedScope') {$granted+='Mail.Send'}
    $script:Fixture.Identity=[pscustomobject]@{TenantId=$tenant;ClientId=$ClientId;Account='reader@fixture.onmicrosoft.com';Scopes=$granted;ContextScope='Process'}
}
function Get-MgContext { return $script:Fixture.Identity }
function Disconnect-MgGraph {
    [CmdletBinding()]param()
    $script:Fixture.Disconnects++;$script:Fixture.Identity=$null
}
function Set-MgGraphOption { [CmdletBinding()]param([bool]$DisableLoginByWAM) $script:Fixture.DisableWam=$DisableLoginByWAM }
function Invoke-MgGraphRequest {
    [CmdletBinding()]param([string]$Method,[string]$Uri,[string]$OutputType,$Body,[string]$ContentType,$Headers)
    $bodyObject=if($Body){$Body | ConvertFrom-Json -AsHashtable}else{$null}
    $script:Fixture.Requests.Add([pscustomobject]@{Method=$Method;Uri=$Uri;Body=$bodyObject})
    if($Method -eq 'POST') {
        if($Uri -ne 'https://graph.microsoft.com/v1.0/applications') { throw 'Unapproved fixture write.' }
        return [pscustomobject]@{id='00000000-0000-0000-0000-000000000301';appId='00000000-0000-0000-0000-000000000302'}
    }
    if($Method -ne 'GET') {throw 'Fixture permits GET and the one application POST only.'}
    $address=[uri]$Uri
    switch($address.AbsolutePath) {
        '/v1.0/organization' {
            return [pscustomobject]@{value=@([pscustomobject]@{id=$script:Fixture.Identity.TenantId;displayName='Fixture company';verifiedDomains=@([pscustomobject]@{name='fixture.onmicrosoft.com';isInitial=$true;isDefault=$true})})}
        }
        '/v1.0/applications' {
            $apps=@()
            if($script:Fixture.Mode -in @('ExistingApp','MultipleApps')) {
                $apps+=@([pscustomobject]@{id='00000000-0000-0000-0000-000000000401';appId='00000000-0000-0000-0000-000000000402';displayName='powershell-ui (read-only)';publicClient=@{redirectUris=@('http://localhost')};requiredResourceAccess=@()})
                if($script:Fixture.Mode -eq 'MultipleApps') {$apps+=@($apps[0])}
            }
            return [pscustomobject]@{value=$apps;'@odata.nextLink'=$null}
        }
        '/v1.0/servicePrincipals' {
            $definitions=@();$index=500
            foreach($scope in $script:Fixture.AllReadScopes) {
                $index++
                $definitions+=@([pscustomobject]@{id=('00000000-0000-0000-0000-'+$index.ToString('000000000000'));value=$scope;isEnabled=$true})
            }
            return [pscustomobject]@{value=@([pscustomobject]@{id='00000000-0000-0000-0000-000000000499';oauth2PermissionScopes=$definitions})}
        }
        '/v1.0/groups' {
            if($script:Fixture.Mode -eq 'PageFailure' -and $address.Query) {
                $response=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Synthetic access denied',$response)
            }
            if($script:Fixture.Mode -eq 'MalformedCollection') {return [pscustomobject]@{unexpected='not a collection'}}
            if($address.Query) {return [pscustomobject]@{value=@([pscustomobject]@{id='group-2';displayName='Second group'})}}
            $next='https://graph.microsoft.com/v1.0/groups?$skiptoken=second'
            if($script:Fixture.Mode -eq 'HostileNext') {$next='https://evil.example/v1.0/groups'}
            if($script:Fixture.Mode -eq 'RepeatedNext') {$next=$Uri}
            return [pscustomobject]@{value=@([pscustomobject]@{id='group-1';displayName='First group'});'@odata.nextLink'=$next}
        }
        default { return [pscustomobject]@{id='fixture-object';displayName='Read-only fixture'} }
    }
}
Export-ModuleMember Connect-MgGraph,Get-MgContext,Disconnect-MgGraph,Set-MgGraphOption,Invoke-MgGraphRequest
'@
[IO.File]::WriteAllText((Join-Path $moduleDirectory 'Microsoft.Graph.Authentication.psm1'),$fakeModule,[Text.UTF8Encoding]::new($false))
$env:PSModulePath=(Join-Path $fixture 'Modules')+[IO.Path]::PathSeparator+$savedModulePath
function New-M365TestContext([string]$Mode='Complete') {
    $state=[hashtable]::Synchronized(@{
        Mode=$Mode;TenantId='00000000-0000-0000-0000-000000000101';Connects=0;Disconnects=0;Identity=$null;DisableWam=$false
        ConnectCalls=[Collections.Generic.List[object]]::new();Requests=[Collections.Generic.List[object]]::new()
        AllReadScopes=@(Get-M365ReadScopes -Extended)
    })
    [AppDomain]::CurrentDomain.SetData('powershell-ui-offline-m365-fixture',$state)
    $context=@{Progress=[Collections.Concurrent.ConcurrentQueue[string]]::new()}
    Initialize-M365Session $context;$contexts.Add($context)
    return [pscustomobject]@{Context=$context;State=$state}
}
function Invoke-M365Test([string]$Name,[scriptblock]$Test) {
    try { & $Test; $checks.Add($Name) }
    catch { $failures.Add($Name+': '+$_.Exception.Message) }
}
try {
    Invoke-M365Test 'one-click login discovers account and tenant without input' {
        $case=New-M365TestContext
        $connected=Connect-M365Session $case.Context
        Assert-M365Test ($connected.Ready -and $case.State.ConnectCalls[0].Tenant -eq 'organizations') 'Default login must use work-account discovery without a tenant prompt.'
        Assert-M365Test ($case.Context.Tenant.Id -eq $case.State.TenantId -and $case.Context.Tenant.Account -eq 'reader@fixture.onmicrosoft.com' -and $case.Context.Tenant.DisplayName -eq 'Fixture company') 'Discovered account and tenant must be saved in session.'
        Invoke-M365GraphRequest $case.Context 'https://graph.microsoft.com/v1.0/me' | Out-Null
        Assert-M365Test ($case.State.Connects -eq 1) 'A report should reuse the automatically discovered session.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'custom app uses a discovered tenant or requests advanced setup' {
        $case=New-M365TestContext;$blocked=$false
        try {Connect-M365Session $case.Context -ClientId '00000000-0000-0000-0000-000000000333' | Out-Null}catch{$blocked=$true}
        Assert-M365Test ($blocked -and $case.State.Connects -eq 0) 'A single-tenant custom app must not use organizations blindly.'
        Connect-M365Session $case.Context | Out-Null
        Connect-M365Session $case.Context -ClientId '00000000-0000-0000-0000-000000000333' | Out-Null
        Assert-M365Test ($case.State.ConnectCalls[-1].Tenant -eq $case.State.TenantId -and $case.Context.SharedGraph.Ready) 'Custom app must reuse the previously verified tenant without asking for its GUID.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'browser login, discovery and reused worker' {
        $case=New-M365TestContext;$context=$case.Context;$state=$case.State
        $connected=Connect-M365Session $context -TenantId 'fixture.onmicrosoft.com'
        Assert-M365Test ($connected.Ready -and $context.SharedGraph.Ready) 'Sign-in did not become ready.'
        Assert-M365Test ($context.Tenant.Id -eq $state.TenantId -and $context.Tenant.Domain -eq 'fixture.onmicrosoft.com') 'Tenant identity/domain were not discovered.'
        Assert-M365Test ($context.Tenant.SharePointAdminUrl -eq 'https://fixture-admin.sharepoint.com') 'SharePoint URL derivation failed.'
        $worker=$context.SharedGraph.Runspace
        $a=Invoke-M365GraphRequest $context 'https://graph.microsoft.com/v1.0/me'
        $b=Invoke-M365GraphRequest $context 'https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies'
        Assert-M365Test ($a.id -and $b.id -and $state.Connects -eq 1 -and $context.SharedGraph.Runspace -eq $worker) 'Reports should reuse the authenticated worker without reconnecting.'
        Assert-M365Test ($state.ConnectCalls[0].ContextScope -eq 'Process' -and -not $state.ConnectCalls[0].DeviceCode) 'Login must use process scope and a normal Microsoft sign-in window.'
        Assert-M365Test (@($state.Requests | Where-Object Method -ne 'GET').Count -eq 0) 'Normal sign-in/data discovery issued a configuration write.'
        Disconnect-M365Session $context
        Assert-M365Test (-not $context.SharedGraph.Ready -and $null -eq $context.SharedGraph.Runspace -and $state.Disconnects -ge 1) 'Disconnect must release authentication and the worker.'
    }
    Invoke-M365Test 'custom app browser option and read scope allowlist' {
        $case=New-M365TestContext
        Connect-M365Session $case.Context -TenantId 'fixture.onmicrosoft.com' -ClientId '00000000-0000-0000-0000-000000000333' -Extended | Out-Null
        Assert-M365Test $case.State.DisableWam 'Custom application browser login should select the system-browser option.'
        $scopes=@(Get-M365ReadScopes -Extended)
        Assert-M365Test (@($scopes | Where-Object {$_ -match 'ReadWrite|Write|FullControl|AppRegistration.Create'}).Count -eq 0) 'Reporting scope list contains a write/setup scope.'
        Assert-M365Test ($case.Context.SharedGraph.ClientId -eq '00000000-0000-0000-0000-000000000333') 'Custom client binding missing.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'wrong tenant and unexpected scope rejection' {
        foreach($mode in @('WrongTenant','UnexpectedScope')) {
            $case=New-M365TestContext $mode;$blocked=$false
            try { Connect-M365Session $case.Context -TenantId $case.State.TenantId | Out-Null } catch {$blocked=$true}
            Assert-M365Test ($blocked -and -not $case.Context.SharedGraph.Ready) ('Unsafe login accepted: '+$mode)
            Disconnect-M365Session $case.Context
        }
    }
    Invoke-M365Test 'identity and permissions checked before every request' {
        $case=New-M365TestContext;Connect-M365Session $case.Context -TenantId 'fixture.onmicrosoft.com' | Out-Null
        $count=$case.State.Requests.Count;$case.State.Identity.TenantId='00000000-0000-0000-0000-000000000999';$blocked=$false
        try {Invoke-M365GraphRequest $case.Context 'https://graph.microsoft.com/v1.0/me' | Out-Null}catch{$blocked=$true}
        Assert-M365Test ($blocked -and $count -eq $case.State.Requests.Count) 'Changed tenant must fail before the HTTP request.'
        $case.State.Identity.TenantId=$case.State.TenantId;$case.State.Identity.Scopes+=@('Directory.ReadWrite.All');$blocked=$false
        try {Invoke-M365GraphRequest $case.Context 'https://graph.microsoft.com/v1.0/me' | Out-Null}catch{$blocked=$true}
        Assert-M365Test ($blocked -and $count -eq $case.State.Requests.Count) 'Write scope must fail before HTTP.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'forbidden URLs cannot use the authenticated worker' {
        $case=New-M365TestContext;Connect-M365Session $case.Context -TenantId 'fixture.onmicrosoft.com' | Out-Null
        $count=$case.State.Requests.Count
        foreach($uri in @('http://graph.microsoft.com/v1.0/me','https://evil.example/v1.0/me','https://graph.microsoft.com.evil.example/v1.0/me','https://user@graph.microsoft.com/v1.0/me','https://graph.microsoft.com:8443/v1.0/me','https://graph.microsoft.com/v1.0/me#fragment','https://graph.microsoft.com/v1.0/admin/serviceAnnouncement')) {
            $blocked=$false;try{Invoke-M365GraphRequest $case.Context $uri | Out-Null}catch{$blocked=$true}
            Assert-M365Test $blocked ('Forbidden URL was accepted: '+$uri)
        }
        Assert-M365Test ($count -eq $case.State.Requests.Count) 'Rejected URLs reached the SDK.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'pagination retains all returned rows without extra login' {
        $case=New-M365TestContext;Connect-M365Session $case.Context -TenantId 'fixture.onmicrosoft.com' | Out-Null
        $result=Invoke-M365GraphRead $case.Context '/v1.0/groups' -Collection
        Assert-M365Test ($result.Status -eq 'Complete' -and $result.Items.Count -eq 2 -and $result.Pages -eq 2) 'All collection pages must be returned.'
        Assert-M365Test ($case.State.Connects -eq 1) 'Pagination caused an additional sign-in.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'failed, repeated, malformed and external pages are not complete' {
        foreach($mode in @('PageFailure','RepeatedNext','MalformedCollection','HostileNext')) {
            $case=New-M365TestContext $mode;Connect-M365Session $case.Context -TenantId 'fixture.onmicrosoft.com' | Out-Null
            $result=Invoke-M365GraphRead $case.Context '/v1.0/groups' -Collection
            Assert-M365Test ($result.Status -in @('Partial','Failed')) ('A bad page was reported complete: '+$mode)
            if($mode -ne 'MalformedCollection') {Assert-M365Test ($result.Items.Count -eq 1) 'Successful first-page evidence was discarded.'}
            Assert-M365Test (@($case.State.Requests | Where-Object Uri -like '*evil.example*').Count -eq 0) 'External pagination reached the SDK.'
            Disconnect-M365Session $case.Context
        }
    }
    Invoke-M365Test 'application discovery remains read-only' {
        $case=New-M365TestContext 'ExistingApp';Connect-M365Session $case.Context -TenantId 'fixture.onmicrosoft.com' | Out-Null
        $result=Find-M365ReaderApplication $case.Context
        Assert-M365Test ($result.Status -eq 'Complete' -and $result.Items.Count -eq 1) 'Existing reader application was not found.'
        Assert-M365Test (@($case.State.Requests | Where-Object Method -ne 'GET').Count -eq 0) 'Discovery changed tenant configuration.'
        Disconnect-M365Session $case.Context
    }
    Invoke-M365Test 'registration requires confirmation and creates only a secretless reader app' {
        $case=New-M365TestContext;$blocked=$false
        try {Register-M365ReaderApplication $case.Context -TenantId 'fixture.onmicrosoft.com' -CreateConfirmed:$false | Out-Null}catch{$blocked=$true}
        Assert-M365Test ($blocked -and $case.State.Requests.Count -eq 0 -and $case.State.Connects -eq 0) 'Unconfirmed registration must not sign in or write.'
        $result=Register-M365ReaderApplication $case.Context -TenantId 'fixture.onmicrosoft.com' -CreateConfirmed
        $posts=@($case.State.Requests | Where-Object Method -eq 'POST')
        Assert-M365Test ($result.Created -and $posts.Count -eq 1 -and $posts[0].Uri -eq 'https://graph.microsoft.com/v1.0/applications') 'Registration should create exactly one application.'
        $body=$posts[0].Body
        Assert-M365Test ($body.signInAudience -eq 'AzureADMyOrg' -and $body.isFallbackPublicClient -and $body.publicClient.redirectUris[0] -eq 'http://localhost') 'Reader public-client settings are incorrect.'
        Assert-M365Test (-not $body.ContainsKey('passwordCredentials') -and -not $body.ContainsKey('keyCredentials')) 'Registration must not create secrets or certificates.'
        Assert-M365Test (@($body.requiredResourceAccess[0].resourceAccess | Where-Object type -ne 'Scope').Count -eq 0) 'Registration must configure delegated read scopes, not application roles.'
        Assert-M365Test (-not $case.Context.SharedGraph.Ready -and $null -eq $case.Context.SharedGraph.Runspace) 'Setup authentication must be disconnected, not reused for reads.'
        Assert-M365Test (@($case.State.Requests | Where-Object Uri -match 'oauth2PermissionGrants|appRoleAssignments').Count -eq 0) 'Registration must not automatically grant consent.'
    }
    Invoke-M365Test 'registration reuses one existing app and refuses ambiguous matches' {
        foreach($mode in @('ExistingApp','MultipleApps')) {
            $case=New-M365TestContext $mode;$blocked=$false;$result=$null
            try {$result=Register-M365ReaderApplication $case.Context -TenantId 'fixture.onmicrosoft.com' -CreateConfirmed}catch{$blocked=$true}
            Assert-M365Test (@($case.State.Requests | Where-Object Method -eq 'POST').Count -eq 0) 'Existing/ambiguous applications must not cause another app creation.'
            if($mode -eq 'ExistingApp') {Assert-M365Test (-not $blocked -and -not $result.Created) 'Single existing app should be returned for review.'}
            else {Assert-M365Test $blocked 'Multiple matches must be refused.'}
            Assert-M365Test (-not $case.Context.SharedGraph.Ready -and $null -eq $case.Context.SharedGraph.Runspace) 'Setup context was not cleared.'
        }
    }
    if($failures.Count) {throw ("M365 offline failures: "+($failures -join '; '))}
    "PASS: $($checks.Count) M365 SDK fixture scenarios: browser/process login, persistent read reuse, tenant/scope isolation, safe pagination, app discovery, confirmed secretless app setup and cleanup. No network or tenant changes."
} finally {
    foreach($context in $contexts) {try{Disconnect-M365Session $context}catch{}}
    [AppDomain]::CurrentDomain.SetData($fixtureKey,$null)
    $env:PSModulePath=$savedModulePath
    $resolved=[IO.Path]::GetFullPath($fixture);$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'm365-sdk-tests-*') {throw 'Unexpected M365 test fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
