Set-StrictMode -Version Latest

# Only these named operations can cross into retained service runspaces.
# This module does not offer an arbitrary PowerShell/script invocation interface.
$script:ServiceOperations=@{
    ExchangeOnline=@('ExchangeConfiguration')
    Azure=@('AzureSubscriptions')
    SharePointOnline=@('SharePointSites')
}

function Initialize-LauncherServiceSessions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    if(-not $Context.ContainsKey('Services')) { $Context.Services=[hashtable]::Synchronized(@{}) }
}

function Get-ServiceTenant {
    param([hashtable]$Context)
    if(-not $Context.ContainsKey('Tenant') -or -not $Context.Tenant) { throw 'Use Login to 365 first.' }
    $id=[guid]::Empty
    if(-not [guid]::TryParse([string]$Context.Tenant.Id,[ref]$id) -or $id -eq [guid]::Empty) { throw 'A verified Microsoft 365 tenant is required.' }
    return $id.ToString()
}

function Invoke-ServiceWorker {
    param($Entry,[scriptblock]$Code,[object[]]$Arguments=@())
    $worker=[powershell]::Create()
    $worker.Runspace=$Entry.Runspace
    $Entry | Add-Member -NotePropertyName ActiveWorker -NotePropertyValue $worker -Force
    try {
        [void]$worker.AddScript($Code.ToString())
        foreach($argument in $Arguments) { [void]$worker.AddArgument($argument) }
        $output=$worker.Invoke()
        if($worker.HadErrors) {
            # Do not return authentication/HTTP exception bodies or bearer headers.
            throw 'The service operation failed. Check sign-in, installed module version and read permissions; reconnect this service if its session expired.'
        }
        return $output
    } finally { $Entry.ActiveWorker=$null;$worker.Dispose() }
}

$script:PrepareServiceRunspace={
    param([string]$service,[string]$tenantId,[string]$domain,[string]$account,[string]$adminUrl)
    $ErrorActionPreference='Stop'
    Set-StrictMode -Version Latest
    $script:LauncherService=$service
    $script:LauncherTenantId=$tenantId
    $script:LauncherDomain=$domain
    $script:LauncherAccount=$account
    $script:LauncherAdminUrl=$adminUrl
    $script:LauncherConnected=$false
    function Assert-ServiceTenant {
        $actual=''
        switch($script:LauncherService) {
            ExchangeOnline {
                $connections=@(Get-ConnectionInformation -ErrorAction Stop | Where-Object { $_.State -eq 'Connected' })
                if($connections.Count -ne 1) { throw 'Expected one retained Exchange connection.' }
                $actual=[string]$connections[0].TenantID
            }
            Azure {
                $current=Get-AzContext -ErrorAction Stop
                $actual=[string]$current.Tenant.Id
            }
            SharePointOnline {
                # All SPO commands in this private runspace use the specific admin
                # endpoint whose unauthenticated realm was verified before login.
                $actual=$script:LauncherVerifiedSharePointRealm
            }
        }
        if($actual -ne $script:LauncherTenantId) { throw 'Service connection belongs to a different tenant. No data was collected.' }
    }
    function Get-ReadCollection {
        param([string]$Name,[scriptblock]$Read)
        try {
            $records=@(& $Read)
            return [pscustomobject]@{Name=$Name;Status='Complete';Records=$records;Count=$records.Count}
        } catch {
            return [pscustomobject]@{Name=$Name;Status='Failed';Records=@();Count=0;Error='Read failed or access denied. This does not establish an empty collection.'}
        }
    }
    function Disconnect-ThisService {
        switch($script:LauncherService) {
            ExchangeOnline { if(Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } }
            Azure {
                if(Get-Command Disconnect-AzAccount -ErrorAction SilentlyContinue) { Disconnect-AzAccount -Scope Process -ErrorAction SilentlyContinue | Out-Null }
                if(Get-Command Clear-AzContext -ErrorAction SilentlyContinue) { Clear-AzContext -Scope Process -Force -ErrorAction SilentlyContinue | Out-Null }
            }
            SharePointOnline {
                if(Get-Command Disconnect-SPOService -ErrorAction SilentlyContinue) { Disconnect-SPOService -ErrorAction SilentlyContinue }
                # Shut down only the compatibility process owned by this service runspace.
                if(Get-PSSession -Name WinPSCompatSession -ErrorAction SilentlyContinue) { Get-PSSession -Name WinPSCompatSession | Remove-PSSession -ErrorAction SilentlyContinue }
            }
        }
        $script:LauncherConnected=$false
    }
    switch($service) {
        ExchangeOnline {
            Import-Module ExchangeOnlineManagement -MinimumVersion 3.7.2 -ErrorAction Stop
            $command=Get-Command Connect-ExchangeOnline -ErrorAction Stop
            if(-not $command.Parameters.ContainsKey('DisableWAM')) { throw 'Update ExchangeOnlineManagement for browser sign-in support.' }
            $commands=@('Get-OrganizationConfig','Get-TransportConfig','Get-AuthenticationPolicy','Get-AcceptedDomain','Get-InboundConnector','Get-OutboundConnector')
            $connect=@{ShowBanner=$false;DisableWAM=$true;CommandName=$commands;SkipLoadingFormatData=$true;ErrorAction='Stop'}
            if($domain) { $connect.DelegatedOrganization=$domain }
            if($account) { $connect.UserPrincipalName=$account }
            Connect-ExchangeOnline @connect
        }
        Azure {
            Import-Module Az.Accounts -MinimumVersion 3.0.0 -ErrorAction Stop
            Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
            Update-AzConfig -EnableLoginByWam $false -EnableErrorRecordsPersistence $false -EnableDataCollection $false -Scope Process -ErrorAction Stop | Out-Null
            $connect=@{Tenant=$tenantId;Scope='Process';SkipContextPopulation=$true;ErrorAction='Stop'}
            if($account) { $connect.AccountId=$account }
            Connect-AzAccount @connect | Out-Null
        }
        SharePointOnline {
            $uri=$null
            if(-not [uri]::TryCreate($adminUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or
                $uri.AbsolutePath -ne '/' -or $uri.Host -notmatch '^[a-zA-Z0-9-]+-admin\.sharepoint\.com$') { throw 'Enter the exact HTTPS SharePoint admin URL for this tenant.' }
            # Resolve the tenant realm before any credential is given to this endpoint.
            # Never follow a redirect from a user-supplied admin address.
            $probe=Invoke-WebRequest -Uri ($uri.GetLeftPart([UriPartial]::Authority)+'/_vti_bin/client.svc') -Method Get -MaximumRedirection 0 -SkipHttpErrorCheck -TimeoutSec 30 -ErrorAction Stop
            $challenge=[string]($probe.Headers['WWW-Authenticate'] -join ' ')
            if($challenge -notmatch '(?i)realm="([0-9a-f-]{36})"' -or $Matches[1] -ne $tenantId) { throw 'SharePoint admin URL could not be verified as the selected tenant.' }
            $script:LauncherVerifiedSharePointRealm=$Matches[1]
            if($PSVersionTable.PSEdition -eq 'Core') { Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell -ErrorAction Stop }
            else { Import-Module Microsoft.Online.SharePoint.PowerShell -ErrorAction Stop }
            $command=Get-Command Connect-SPOService -ErrorAction Stop
            if(-not $command.Parameters.ContainsKey('UseSystemBrowser')) { throw 'Update SharePoint Online PowerShell for system-browser sign-in.' }
            Connect-SPOService -Url $uri.GetLeftPart([UriPartial]::Authority) -UseSystemBrowser $true -AuthenticationUrl ("https://login.microsoftonline.com/"+$tenantId) -ErrorAction Stop
            # Read a tenant property once to establish that sign-in actually succeeded.
            $null=Get-SPOTenant -ErrorAction Stop
        }
    }
    try { Assert-ServiceTenant } catch { Disconnect-ThisService; throw }
    $script:LauncherConnected=$true
    [pscustomobject]@{Service=$service;TenantId=$tenantId;Account=$account;Status='Connected';ConnectedUtc=[DateTime]::UtcNow.ToString('o')}
}

$script:ReadServiceRunspace={
    param([string]$operation)
    if(-not $script:LauncherConnected) { throw 'Service is not connected.' }
    Assert-ServiceTenant
    $collections=@()
    switch($operation) {
        ExchangeConfiguration {
            if($script:LauncherService -ne 'ExchangeOnline') { throw 'Operation is not allowed for this service.' }
            $collections=@(
                (Get-ReadCollection 'OrganizationConfig' { Get-OrganizationConfig -ErrorAction Stop | Select-Object Name,Guid,OAuth2ClientProfileEnabled,AuditDisabled,DefaultAuthenticationPolicy,AppsForOfficeEnabled,PublicFoldersEnabled }),
                (Get-ReadCollection 'TransportConfig' { Get-TransportConfig -ErrorAction Stop | Select-Object Name,SmtpClientAuthenticationDisabled,ExternalDelayDsnEnabled,ExternalDsnReportingAuthority,InternalDelayDsnEnabled,MaxReceiveSize,MaxSendSize }),
                (Get-ReadCollection 'AuthenticationPolicies' { Get-AuthenticationPolicy -ErrorAction Stop | Select-Object Name,Guid,AllowBasicAuthActiveSync,AllowBasicAuthAutodiscover,AllowBasicAuthImap,AllowBasicAuthMapi,AllowBasicAuthOfflineAddressBook,AllowBasicAuthOutlookService,AllowBasicAuthPop,AllowBasicAuthPowerShell,AllowBasicAuthReportingWebServices,AllowBasicAuthRpc,AllowBasicAuthSmtp,AllowBasicAuthWebServices }),
                (Get-ReadCollection 'AcceptedDomains' { Get-AcceptedDomain -ErrorAction Stop | Select-Object Name,DomainName,DomainType,Default }),
                (Get-ReadCollection 'InboundConnectors' { Get-InboundConnector -ErrorAction Stop | Select-Object Identity,Name,Enabled,ConnectorType,SenderDomains,SenderIPAddresses,RequireTls,RestrictDomainsToIPAddresses,RestrictDomainsToCertificate,TlsSenderCertificateName }),
                (Get-ReadCollection 'OutboundConnectors' { Get-OutboundConnector -ErrorAction Stop | Select-Object Identity,Name,Enabled,ConnectorType,RecipientDomains,SmartHosts,UseMXRecord,TlsSettings,TlsDomain,RouteAllMessagesViaOnPremises })
            )
        }
        AzureSubscriptions {
            if($script:LauncherService -ne 'Azure') { throw 'Operation is not allowed for this service.' }
            $collections=@((Get-ReadCollection 'Subscriptions' { Get-AzSubscription -TenantId $script:LauncherTenantId -ErrorAction Stop | Select-Object Id,Name,TenantId,State }))
        }
        SharePointSites {
            if($script:LauncherService -ne 'SharePointOnline') { throw 'Operation is not allowed for this service.' }
            $collections=@(
                (Get-ReadCollection 'TenantSettings' { Get-SPOTenant -ErrorAction Stop | Select-Object SharingCapability,DefaultSharingLinkType,DefaultLinkPermission,ExternalServicesEnabled,RequireAcceptingAccountMatchInvitedAccount,PreventExternalUsersFromResharing,EnableAIPIntegration,EnableAzureADB2BIntegration }),
                (Get-ReadCollection 'Sites' { Get-SPOSite -Limit All -Detailed -ErrorAction Stop | Select-Object Url,Title,Owner,Template,Status,LockState,SharingCapability,StorageUsageCurrent,LastContentModifiedDate,ConditionalAccessPolicy,LimitedAccessFileType })
            )
        }
        default { throw 'Unsupported read operation.' }
    }
    Assert-ServiceTenant
    $records=@(foreach($collection in $collections) {
        foreach($record in $collection.Records) { [pscustomobject]@{Collection=$collection.Name;Data=$record} }
    })
    [pscustomobject]@{
        Service=$script:LauncherService;Operation=$operation;TenantId=$script:LauncherTenantId
        CapturedUtc=[DateTime]::UtcNow.ToString('o');Incomplete=(@($collections | Where-Object Status -ne 'Complete').Count -gt 0)
        Collections=@($collections | Select-Object Name,Status,Count,Error)
        Records=$records
        Limitations=@('Service modules enforce the signed-in account permissions. These fixed operations read configuration only; this is not a complete service/security audit.',
            'Collection errors are explicit and do not imply an empty or healthy result. One SharePoint admin endpoint/geo is connected at a time; OneDrive personal sites are not enumerated.',
            'Shared launcher cleanup disconnects these connections; Microsoft/browser-managed cookies or external caches are independent and are not a promise of forensic memory erasure.')
    }
}

function Connect-LauncherService {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateSet('ExchangeOnline','Azure','SharePointOnline')][string]$Service
    )
    $tenantId=Get-ServiceTenant $Context
    Initialize-LauncherServiceSessions $Context
    [Threading.Monitor]::Enter($Context.Services.SyncRoot)
    try {
        if(-not $Context.Services.ContainsKey($Service)) {
            $runspace=[runspacefactory]::CreateRunspace()
            $runspace.ApartmentState='STA';$runspace.ThreadOptions='ReuseThread';$runspace.Open()
            $Context.Services[$Service]=[pscustomobject]@{Service=$Service;Runspace=$runspace;Gate=[object]::new();TenantId=$tenantId;Account='';Status='NotConnected';ConnectedUtc=''}
        }
        $entry=$Context.Services[$Service]
    } finally { [Threading.Monitor]::Exit($Context.Services.SyncRoot) }
    [Threading.Monitor]::Enter($entry.Gate)
    try {
        if($entry.TenantId -ne $tenantId) { throw 'Disconnect the existing service session before switching tenants.' }
        if($entry.Status -eq 'Connected') { return [pscustomobject]@{Service=$Service;TenantId=$entry.TenantId;Account=$entry.Account;Status='Connected';ConnectedUtc=$entry.ConnectedUtc;Reused=$true} }
        if($entry.Status -ne 'NotConnected') { try { [void](Invoke-ServiceWorker $entry {if(Get-Command Disconnect-ThisService -ErrorAction SilentlyContinue){Disconnect-ThisService}}) } catch {} }
        $domain=[string]$Context.Tenant.Domain
        if($Service -eq 'ExchangeOnline' -and $domain -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$') { throw 'The selected tenant needs a verified domain for Exchange connection.' }
        if($Context.ContainsKey('Progress')) { $Context.Progress.Enqueue("Opening $Service browser sign-in for the selected tenant. This service session will remain available until logout/exit.") }
        $result=@(Invoke-ServiceWorker $entry $script:PrepareServiceRunspace @($Service,$tenantId,$domain,[string]$Context.Tenant.Account,[string]$Context.Tenant.SharePointAdminUrl)) | Select-Object -Last 1
        if(-not $result -or $result.Status -ne 'Connected' -or $result.TenantId -ne $tenantId) { throw 'The service did not confirm a connection to the selected tenant.' }
        $entry.Status='Connected';$entry.Account=$result.Account;$entry.ConnectedUtc=$result.ConnectedUtc
        return $result
    } catch {
        $entry.Status='Failed'
        try { [void](Invoke-ServiceWorker $entry {if(Get-Command Disconnect-ThisService -ErrorAction SilentlyContinue){Disconnect-ThisService}}) } catch {}
        throw
    } finally { [Threading.Monitor]::Exit($entry.Gate) }
}

function Invoke-LauncherServiceRead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][ValidateSet('ExchangeOnline','Azure','SharePointOnline')][string]$Service,
        [Parameter(Mandatory)][string]$Operation
    )
    if($Operation -notin $script:ServiceOperations[$Service]) { throw 'Only the registered read operation is permitted for this service.' }
    $tenantId=Get-ServiceTenant $Context
    Initialize-LauncherServiceSessions $Context
    if(-not $Context.Services.ContainsKey($Service) -or $Context.Services[$Service].Status -ne 'Connected') { throw "Connect $Service from Login to 365 before running this report." }
    $entry=$Context.Services[$Service]
    [Threading.Monitor]::Enter($entry.Gate)
    try {
        if($entry.TenantId -ne $tenantId) { throw 'Service session does not match the selected tenant.' }
        $result=@(Invoke-ServiceWorker $entry $script:ReadServiceRunspace @($Operation)) | Select-Object -Last 1
        if(-not $result -or $result.TenantId -ne $tenantId) { throw 'Read result does not match the selected tenant.' }
        return $result
    } catch {
        $entry.Status='ReconnectRequired'
        throw
    } finally { [Threading.Monitor]::Exit($entry.Gate) }
}

function Get-LauncherServiceStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context)
    Initialize-LauncherServiceSessions $Context
    foreach($entry in @($Context.Services.Values)) { [pscustomobject]@{Service=$entry.Service;TenantId=$entry.TenantId;Account=$entry.Account;Status=$entry.Status;ConnectedUtc=$entry.ConnectedUtc} }
}

function Disconnect-LauncherServices {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Context,[ValidateSet('ExchangeOnline','Azure','SharePointOnline')][string[]]$Service=@('ExchangeOnline','Azure','SharePointOnline'))
    if(-not $Context.ContainsKey('Services')) { return }
    foreach($name in $Service) {
        if(-not $Context.Services.ContainsKey($name)) { continue }
        $entry=$Context.Services[$name]
        [Threading.Monitor]::Enter($entry.Gate)
        try {
            try { [void](Invoke-ServiceWorker $entry {if(Get-Command Disconnect-ThisService -ErrorAction SilentlyContinue){Disconnect-ThisService}}) } catch {}
            $entry.Status='Disconnected'
            try { $entry.Runspace.Close() } finally { $entry.Runspace.Dispose() }
            $Context.Services.Remove($name)
        } finally { [Threading.Monitor]::Exit($entry.Gate) }
    }
}

Export-ModuleMember Initialize-LauncherServiceSessions,Connect-LauncherService,Invoke-LauncherServiceRead,Get-LauncherServiceStatus,Disconnect-LauncherServices
