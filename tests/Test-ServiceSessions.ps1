$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'infrastructure\ServiceSessions.psm1') -Force
function Assert-ServiceFixture($Condition,[string]$Message) { if(-not $Condition){throw ('Service fixture assertion failed: '+$Message)} }

# These are actual retained runspaces with fake service command implementations.
# No external module is imported, browser opened, tenant read or credential used.
$bootstrap={
    param($fixture)
    $global:ServiceFixture=$fixture
    function global:Import-Module {
        [CmdletBinding()]
        param($Name,$MinimumVersion,[switch]$UseWindowsPowerShell)
        if($Name -notin @('ExchangeOnlineManagement','Microsoft.Online.SharePoint.PowerShell')) { throw 'Unapproved fixture module.' }
        if($Name -eq 'Microsoft.Online.SharePoint.PowerShell' -and -not $UseWindowsPowerShell) { throw 'SPO compatibility import missing.' }
        $global:ServiceFixture.Imports++
    }
    function global:Connect-ExchangeOnline {
        [CmdletBinding()]
        param([bool]$ShowBanner,[switch]$DisableWAM,[string[]]$CommandName,[switch]$SkipLoadingFormatData,$DelegatedOrganization,$UserPrincipalName)
        if(-not $DisableWAM -or -not $SkipLoadingFormatData -or $ShowBanner -or @($CommandName | Where-Object {$_ -notlike 'Get-*'}).Count) { throw 'Unsafe Exchange connection options.' }
        if($DelegatedOrganization -ne 'fixture.onmicrosoft.com') { throw 'Delegated tenant not specified.' }
        $global:ServiceFixture.LoginCount++
    }
    function global:Get-ConnectionInformation {
        [CmdletBinding()]param()
        [pscustomobject]@{TenantID=$global:ServiceFixture.ActualTenant;State='Connected';UserPrincipalName='reader@fixture.example'}
    }
    function global:Disconnect-ExchangeOnline { [CmdletBinding(SupportsShouldProcess)]param() $global:ServiceFixture.DisconnectCount++ }
    function global:Get-OrganizationConfig { [CmdletBinding()]param() [pscustomobject]@{Name='Fixture organization';Guid=$global:ServiceFixture.ActualTenant;OAuth2ClientProfileEnabled=$true;AuditDisabled=$false} }
    function global:Get-TransportConfig { [CmdletBinding()]param() [pscustomobject]@{Name='Fixture transport';SmtpClientAuthenticationDisabled=$true} }
    function global:Get-AuthenticationPolicy {
        [CmdletBinding()]param()
        if($global:ServiceFixture.FailCollection) { throw 'Secret-fixture-token-must-not-export' }
        [pscustomobject]@{Name='Basic auth blocked';AllowBasicAuthSmtp=$false}
    }
    function global:Get-AcceptedDomain { [CmdletBinding()]param() [pscustomobject]@{Name='Fixture domain';DomainName='fixture.example';DomainType='Authoritative';Default=$true} }
    function global:Get-InboundConnector { [CmdletBinding()]param() @() }
    function global:Get-OutboundConnector { [CmdletBinding()]param() @() }
    
    
    
    
    
    
    
    function global:Invoke-WebRequest {
        [CmdletBinding()]param($Uri,$Method,$MaximumRedirection,[switch]$SkipHttpErrorCheck,$TimeoutSec)
        if($Uri -ne 'https://fixture-admin.sharepoint.com/_vti_bin/client.svc' -or $Method -ne 'Get' -or $MaximumRedirection -ne 0 -or -not $SkipHttpErrorCheck) { throw 'Unexpected SPO realm probe.' }
        [pscustomobject]@{Headers=@{'WWW-Authenticate'=('Bearer realm="'+$global:ServiceFixture.ActualTenant+'"')}}
    }
    function global:Connect-SPOService {
        [CmdletBinding()]param($Url,[bool]$UseSystemBrowser,$AuthenticationUrl)
        if($Url -ne 'https://fixture-admin.sharepoint.com' -or -not $UseSystemBrowser -or $AuthenticationUrl -ne ('https://login.microsoftonline.com/'+$global:ServiceFixture.ExpectedTenant)) { throw 'SPO browser/tenant binding missing.' }
        $global:ServiceFixture.LoginCount++
    }
    function global:Get-SPOTenant { [CmdletBinding()]param() [pscustomobject]@{SharingCapability='Disabled';DefaultSharingLinkType='Direct';PreventExternalUsersFromResharing=$true} }
    function global:Get-SPOSite {
        [CmdletBinding()]param($Limit,[switch]$Detailed)
        if($Limit -ne 'All' -or -not $Detailed) { throw 'Expected full explicit site read.' }
        [pscustomobject]@{Url='https://fixture.sharepoint.com';Title='Fixture root';SharingCapability='Disabled';LockState='Unlock'}
    }
    function global:Disconnect-SPOService { [CmdletBinding()]param() $global:ServiceFixture.DisconnectCount++ }
    function global:Get-PSSession { [CmdletBinding()]param($Name) @() }
}

function New-ServiceFixtureEntry([string]$Service,[hashtable]$Store) {
    $runspace=[runspacefactory]::CreateRunspace();$runspace.ApartmentState='STA';$runspace.ThreadOptions='ReuseThread';$runspace.Open()
    $worker=[powershell]::Create();$worker.Runspace=$runspace
    try {
        [void]$worker.AddScript($bootstrap.ToString()).AddArgument($Store)
        $null=$worker.Invoke()
        if($worker.HadErrors) { throw 'Fixture bootstrap failed.' }
    } finally { $worker.Dispose() }
    return [pscustomobject]@{Service=$Service;Runspace=$runspace;Gate=[object]::new();TenantId=$Store.ExpectedTenant;Account='';Status='NotConnected';ConnectedUtc=''}
}
$tenantId='00000000-0000-0000-0000-000000000001'
$otherTenant='00000000-0000-0000-0000-000000000002'
$context=@{
    Tenant=[hashtable]::Synchronized(@{Id=$tenantId;Domain='fixture.onmicrosoft.com';Account='reader@fixture.example';SharePointAdminUrl='https://fixture-admin.sharepoint.com'})
    Progress=[Collections.Concurrent.ConcurrentQueue[string]]::new()
}
$stores=@{};$checks=0
Initialize-LauncherServiceSessions $context
try {
    foreach($service in @('ExchangeOnline','SharePointOnline')) {
        $store=[hashtable]::Synchronized(@{ExpectedTenant=$tenantId;ActualTenant=$tenantId;Imports=0;LoginCount=0;DisconnectCount=0;Cleared=0;FailCollection=$false})
        $stores[$service]=$store
        $entry=New-ServiceFixtureEntry $service $store
        $context.Services[$service]=$entry
        $connected=Connect-LauncherService $context $service
        Assert-ServiceFixture ($connected.TenantId -eq $tenantId -and $store.LoginCount -eq 1) ($service+' must connect exactly once to selected tenant.')
        $reused=Connect-LauncherService $context $service
        Assert-ServiceFixture ($reused.Reused -and $store.LoginCount -eq 1 -and [object]::ReferenceEquals($context.Services[$service].Runspace,$entry.Runspace)) ($service+' must retain/reuse its runspace.')
        $operation=switch($service){ExchangeOnline{'ExchangeConfiguration'}  SharePointOnline{'SharePointSites'}}
        $first=Invoke-LauncherServiceRead $context $service $operation
        $second=Invoke-LauncherServiceRead $context $service $operation
        Assert-ServiceFixture ($first.TenantId -eq $tenantId -and -not $first.Incomplete -and $second.Records.Count -gt 0 -and $store.LoginCount -eq 1) ($service+' reads must reuse sign-in and return scoped data.')
        $blocked=$false
        try { Invoke-LauncherServiceRead $context $service 'Set-Anything' | Out-Null } catch { $blocked=$true }
        Assert-ServiceFixture $blocked 'Arbitrary commands must be rejected.'
        $context.Tenant.Id=$otherTenant;$blocked=$false
        try { Invoke-LauncherServiceRead $context $service $operation | Out-Null } catch { $blocked=$true }
        Assert-ServiceFixture $blocked 'Changing selected tenant must not reuse previous service data.'
        $context.Tenant.Id=$tenantId
        $null=Connect-LauncherService $context $service
        $store.ActualTenant=$otherTenant
        $blocked=$false
        try { Invoke-LauncherServiceRead $context $service $operation | Out-Null } catch { $blocked=$true }
        if($service -eq 'SharePointOnline') {
            # The SPO connection is anchored to its pre-verified admin endpoint;
            # changing a mocked account home tenant does not change that endpoint.
            Assert-ServiceFixture (-not $blocked) 'SPO is scoped by verified admin endpoint, not reader home tenant.'
        } else {
            Assert-ServiceFixture ($blocked -and $context.Services[$service].Status -eq 'ReconnectRequired') 'Actual service tenant mismatch must fail closed and require reconnect.'
        }
        $store.ActualTenant=$tenantId
        if($service -ne 'SharePointOnline') { $null=Connect-LauncherService $context $service }
        $checks++
    }
    $stores.ExchangeOnline.FailCollection=$true
    $partial=Invoke-LauncherServiceRead $context ExchangeOnline ExchangeConfiguration
    Assert-ServiceFixture ($partial.Incomplete -and @($partial.Collections | Where-Object Status -eq 'Failed').Count -eq 1) 'Read permission failures must be partial.'
    Assert-ServiceFixture (($partial | ConvertTo-Json -Depth 20) -notmatch 'Secret-fixture-token') 'Raw service error bodies must not be exported.'
    $checks++
    $blocked=$false
    try { Invoke-LauncherServiceRead $context SharePointOnline ExchangeConfiguration | Out-Null } catch { $blocked=$true }
    Assert-ServiceFixture $blocked 'Cross-service operation must be rejected before execution.'
    Assert-ServiceFixture (@(Get-LauncherServiceStatus $context).Count -eq 2) 'Connection overview must describe retained services.'
    $checks++
    Disconnect-LauncherServices $context
    Assert-ServiceFixture ($context.Services.Count -eq 0) 'Logout must remove all retained service entries.'
    foreach($store in $stores.Values) { Assert-ServiceFixture ($store.DisconnectCount -ge 1) 'Every service must disconnect on cleanup.' }
    $checks++
    $spoStore=[hashtable]::Synchronized(@{ExpectedTenant=$tenantId;ActualTenant=$otherTenant;Imports=0;LoginCount=0;DisconnectCount=0;Cleared=0;FailCollection=$false})
    $context.Services.SharePointOnline=New-ServiceFixtureEntry SharePointOnline $spoStore
    $blocked=$false
    try { Connect-LauncherService $context SharePointOnline | Out-Null } catch { $blocked=$true }
    Assert-ServiceFixture ($blocked -and $spoStore.LoginCount -eq 0) 'Wrong SharePoint realm must be rejected before browser authentication.'
    $checks++
    "PASS: $checks retained-service scenarios: browser options, one-login reuse, fixed read allowlists, tenant binding, partial failures, redaction and complete logout. No cloud connection was made."
} finally { Disconnect-LauncherServices $context }
