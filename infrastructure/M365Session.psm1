Set-StrictMode -Version Latest
function Get-M365ReadScopes {
    param([switch]$Extended)
    $scopes=@('User.Read','Organization.Read.All','Directory.Read.All','Policy.Read.All','AuditLog.Read.All','SecurityEvents.Read.All')
    if($Extended) { $scopes+=@('RoleManagement.Read.Directory','Agreement.Read.All','CrossTenantInformation.ReadBasic.All','NetworkAccess.Read.All','Member.Read.Hidden','CustomSecAttributeDefinition.Read.All','CustomSecAttributeAssignment.Read.All','DeviceManagementConfiguration.Read.All','DeviceManagementApps.Read.All','DeviceManagementManagedDevices.Read.All') }
    return $scopes
}
function Initialize-M365Session {
    param([hashtable]$Context)
    if(-not $Context.ContainsKey('Tenant')) { $Context.Tenant=[hashtable]::Synchronized(@{Id='';Domain='';DisplayName='';Account='';SharePointAdminUrl=''}) }
    if(-not $Context.ContainsKey('Services')) { $Context.Services=[hashtable]::Synchronized(@{}) }
    if(-not $Context.ContainsKey('SharedGraph')) {
        $Context.SharedGraph=[hashtable]::Synchronized(@{Ready=$false;TenantId='';Account='';ClientId='';Generation=[guid]::NewGuid().ToString();Runspace=$null;Gate=[object]::new();Scopes=@();LastError='';ActiveWorker=$null})
    }
}
function Get-M365AllowedReadScopes {
    # Compatible existing reader apps may have these additional read-only grants.
    # They are accepted, never automatically requested or added to new app setup.
    return @((Get-M365ReadScopes -Extended))+@('Reports.Read.All','Application.Read.All','User.Read.All','Group.Read.All','UserAuthenticationMethod.Read.All','openid','profile','email','offline_access')
}
function Invoke-M365Worker {
    param([hashtable]$Context,[scriptblock]$Script,[object[]]$Arguments=@())
    Initialize-M365Session $Context
    $graph=$Context.SharedGraph
    [Threading.Monitor]::Enter($graph.Gate)
    try {
        if($null -eq $graph.Runspace) {
            $rs=[runspacefactory]::CreateRunspace();$rs.ApartmentState='STA';$rs.ThreadOptions='ReuseThread';$rs.Open();$graph.Runspace=$rs
        }
        $ps=[powershell]::Create();$ps.Runspace=$graph.Runspace;$graph.ActiveWorker=$ps
        try {
            [void]$ps.AddScript($Script.ToString())
            foreach($argument in $Arguments) { [void]$ps.AddArgument($argument) }
            $values=$ps.Invoke()
            if($ps.HadErrors) { throw $ps.Streams.Error[0] }
            return $values
        } finally { $graph.ActiveWorker=$null;$ps.Dispose() }
    } finally { [Threading.Monitor]::Exit($graph.Gate) }
}
function Assert-M365ReadContext {
    param($Context,$GraphContext)
    if(-not $Context.SharedGraph.Ready -or $null -eq $GraphContext -or $GraphContext.TenantId -ne $Context.SharedGraph.TenantId -or
        $GraphContext.Account -ne $Context.SharedGraph.Account -or $GraphContext.ClientId -ne $Context.SharedGraph.ClientId -or $GraphContext.ContextScope -ne 'Process') { throw 'Microsoft 365 session changed. Sign in again before collecting data.' }
    $allowed=@(Get-M365AllowedReadScopes)
    foreach($scope in $GraphContext.Scopes) { if($scope -notin $allowed) { throw 'This connection has permissions outside the reviewed read-only profile. Use a dedicated reader application.' } }
}
function Connect-M365Session {
    [CmdletBinding()]
    param([hashtable]$Context,[Parameter(Mandatory)][string]$TenantId,[string]$ClientId,[switch]$Extended)
    Initialize-M365Session $Context
    $tenant=Resolve-LauncherTenant $TenantId
    $parsedClient=[guid]::Empty
    if($ClientId -and (-not [guid]::TryParse($ClientId,[ref]$parsedClient) -or $parsedClient -eq [guid]::Empty)) { throw 'Application ID must be a nonempty GUID, or leave it blank for Microsoft Graph PowerShell.' }
    $scopes=@(Get-M365ReadScopes -Extended:$Extended)
    $Context.SharedGraph.Ready=$false
    try {
        $result=@(Invoke-M365Worker $Context {
            param($tenant,$client,$scopes)
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            if(Get-MgContext) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
            if($client -and (Get-Command Set-MgGraphOption).Parameters.ContainsKey('DisableLoginByWAM')) { Set-MgGraphOption -DisableLoginByWAM $true }
            $connect=@{TenantId=$tenant;Scopes=$scopes;ContextScope='Process';NoWelcome=$true;ErrorAction='Stop'}
            if($client) { $connect.ClientId=$client }
            Connect-MgGraph @connect | Out-Null
            $identity=Get-MgContext
            $organization=Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,displayName,verifiedDomains' -OutputType PSObject
            $orgs=@($organization.value)
            if($orgs.Count -ne 1 -or $orgs[0].id -ne $identity.TenantId) { throw 'Tenant identity could not be verified.' }
            $domainNames=@($orgs[0].verifiedDomains | ForEach-Object {$_.name})
            if($tenant -ne $identity.TenantId -and $tenant -notin $domainNames) { throw 'The selected account belongs to a different target tenant.' }
            [pscustomobject]@{Identity=$identity;Organization=$orgs[0]}
        } @($tenant,$ClientId,$scopes))
        $identity=$result[-1].Identity;$org=$result[-1].Organization
        $Context.SharedGraph.TenantId=$identity.TenantId;$Context.SharedGraph.Account=$identity.Account;$Context.SharedGraph.ClientId=$identity.ClientId
        $Context.SharedGraph.Scopes=@($identity.Scopes);$Context.SharedGraph.Generation=[guid]::NewGuid().ToString();$Context.SharedGraph.Ready=$true
        Assert-M365ReadContext $Context $identity
        $domain=@($org.verifiedDomains | Where-Object isInitial | Select-Object -First 1)
        $initialDomain=if($domain.Count){$domain[0].name}else{''}
        $Context.Tenant.Id=$identity.TenantId;$Context.Tenant.Domain=$initialDomain;$Context.Tenant.DisplayName=$org.displayName;$Context.Tenant.Account=$identity.Account
        $Context.Tenant.SharePointAdminUrl=if($initialDomain -match '^([a-zA-Z0-9-]+)\.onmicrosoft\.com$'){'https://'+$Matches[1]+'-admin.sharepoint.com'}else{''}
        $Context.SharedGraph.LastError=''
        return [pscustomobject]@{TenantId=$identity.TenantId;Tenant=$org.displayName;Domain=$initialDomain;Account=$identity.Account;Scopes=@($identity.Scopes);Ready=$true}
    } catch {
        Disconnect-M365Session $Context
        $Context.SharedGraph.LastError='Sign-in failed. Check the target tenant, application consent, installed Graph.Authentication module and tenant access policy. No data was collected.'
        throw $Context.SharedGraph.LastError
    }
}
function Invoke-M365GraphRequest {
    [CmdletBinding()]
    param([hashtable]$Context,[Parameter(Mandatory)][string]$Uri)
    Initialize-M365Session $Context
    $parsed=$null
    if(-not [uri]::TryCreate($Uri,[UriKind]::Absolute,[ref]$parsed) -or $parsed.Scheme -ne 'https' -or $parsed.Host -ne 'graph.microsoft.com' -or $parsed.Port -ne 443 -or $parsed.UserInfo -or $parsed.Fragment -or
        $parsed.AbsolutePath -notmatch '^/(v1\.0|beta)/(organization|me|identity/conditionalAccess|groups|users|devices|servicePrincipals|applications|directoryObjects|directory/|roleManagement/directory|policies/|identityGovernance/termsOfUse|tenantRelationships/|networkAccess/|deviceManagement/|deviceAppManagement/|security/|reports/|auditLogs/)' -or $Uri -match '(^|/)\.\.(/|$)') { throw 'Only reviewed Microsoft Graph read endpoints are allowed.' }
    if(-not $Context.SharedGraph.Ready) { throw 'Choose Login to 365 before running this report.' }
    $values=@(Invoke-M365Worker $Context {
        param($uri,$tenant,$account,$client,$allowed)
        $identity=Get-MgContext
        if($null -eq $identity -or $identity.TenantId -ne $tenant -or $identity.Account -ne $account -or $identity.ClientId -ne $client -or $identity.ContextScope -ne 'Process') { throw 'The Microsoft Graph identity changed. Sign in again.' }
        foreach($scope in $identity.Scopes) { if($scope -notin $allowed) { throw 'A non-reader Graph permission was detected.' } }
        Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType PSObject -Headers @{Prefer='include-unknown-enum-members'} -ErrorAction Stop
    } @($Uri,$Context.SharedGraph.TenantId,$Context.SharedGraph.Account,$Context.SharedGraph.ClientId,(@(Get-M365AllowedReadScopes))))
    if($values.Count -ne 1) { throw 'Graph did not return a single JSON response.' }
    return $values[0]
}
function Invoke-M365GraphRead {
    [CmdletBinding()]
    param([hashtable]$Context,[Parameter(Mandatory)][string]$Path,[switch]$Collection)
    if(-not $Path.StartsWith('/') -or $Path.StartsWith('//')) { throw 'Graph reads require a relative reviewed path.' }
    $initial=[uri]('https://graph.microsoft.com'+$Path);$next=$initial.AbsoluteUri
    $items=[Collections.Generic.List[object]]::new();$seen=[Collections.Generic.HashSet[string]]::new();$status='Complete';$code=0
    try {
        do {
            $address=[uri]$next
            if($address.Scheme -ne 'https' -or $address.Host -ne 'graph.microsoft.com' -or $address.Port -ne 443 -or $address.UserInfo -or $address.Fragment -or $address.AbsolutePath -cne $initial.AbsolutePath -or -not $seen.Add($next) -or $seen.Count -gt 10000) { throw 'Invalid or repeated Graph page.' }
            for($attempt=0;$attempt -lt 4;$attempt++) {
                try {$page=Invoke-M365GraphRequest $Context $next;break}
                catch {
                    try{$code=[int]$_.Exception.Response.StatusCode}catch{$code=0}
                    if($code -notin @(429,503,504) -or $attempt -eq 3){throw}
                    Start-Sleep -Seconds ([Math]::Min(30,[Math]::Pow(2,$attempt+1)))
                }
            }
            if(-not $Collection) { return [pscustomobject]@{Object=$page;Status='Resolved';HttpStatus=0} }
            if($page -is [Collections.IDictionary]) {
                $values=$page['value'];$next=[string]$page['@odata.nextLink']
            } else {
                $value=$page.PSObject.Properties['value'];$values=$null
                if($null -ne $value){$values=$value.Value}
                $link=$page.PSObject.Properties['@odata.nextLink'];$next=if($null -ne $link){[string]$link.Value}else{''}
            }
            if($null -eq $values -or $values -is [string] -or $values -is [Collections.IDictionary] -or $values -isnot [Collections.IEnumerable]) { throw 'Missing Graph collection value.' }
            foreach($item in $values) { $items.Add($item) }
        } while($next)
    } catch {
        try{$code=[int]$_.Exception.Response.StatusCode}catch{}
        $status=if($items.Count){'Partial'}else{'Failed'}
    }
    if($Collection) { return [pscustomobject]@{Items=@($items.ToArray());Status=$status;HttpStatus=$code;Pages=$seen.Count} }
    return [pscustomobject]@{Object=$null;Status='Unresolved';HttpStatus=$code}
}
function Find-M365ReaderApplication {
    param([hashtable]$Context)
    $result=Invoke-M365GraphRead $Context '/v1.0/applications?$select=id,appId,displayName,publicClient,isFallbackPublicClient,requiredResourceAccess' -Collection
    $definitions=Invoke-M365GraphRead $Context '/v1.0/servicePrincipals?$filter=appId%20eq%20%2700000003-0000-0000-c000-000000000000%27&$select=oauth2PermissionScopes' -Collection
    $allowedIds=@()
    if($definitions.Status -eq 'Complete' -and $definitions.Items.Count -eq 1) {
        $readNames=@(Get-M365AllowedReadScopes)
        $allowedIds=@($definitions.Items[0].oauth2PermissionScopes | Where-Object {$_.value -in $readNames} | ForEach-Object {$_.id})
    }
    $candidates=@(foreach($app in $result.Items) {
        $known=$app.displayName -eq 'powershell-ui (read-only)'
        $public=$null -ne $app.publicClient -and @($app.publicClient.redirectUris | Where-Object {$_ -match '^http://localhost/?$'}).Count -gt 0
        $graphAccess=@($app.requiredResourceAccess | Where-Object resourceAppId -eq '00000003-0000-0000-c000-000000000000')
        $permissions=@($graphAccess | ForEach-Object {$_.resourceAccess})
        $verified=$public -and $permissions.Count -gt 0 -and @($permissions | Where-Object {$_.type -ne 'Scope' -or $_.id -notin $allowedIds}).Count -eq 0
        if($known -or $verified) {
            [pscustomobject]@{id=$app.id;appId=$app.appId;displayName=$app.displayName;ReviewStatus=$(if($verified){'Configured Graph scopes match the reader allowlist; review consent and required scope coverage.'}else{'Known launcher name; review public-client redirect, permissions and consent before use.'})}
        }
    })
    [pscustomobject]@{Items=$candidates;Status=$result.Status;HttpStatus=$result.HttpStatus;Pages=$result.Pages}
}
function Register-M365ReaderApplication {
    [CmdletBinding()]
    param([hashtable]$Context,[Parameter(Mandatory)][string]$TenantId,[Parameter(Mandatory)][switch]$CreateConfirmed)
    if(-not $CreateConfirmed) { throw 'Review and confirm application creation first.' }
    $tenant=Resolve-LauncherTenant $TenantId
    Initialize-M365Session $Context
    Disconnect-M365Session $Context
    try {
        $results=@(Invoke-M365Worker $Context {
            param($tenant,$readScopes)
            Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
            # Setup is intentionally serialized in this worker: Graph SDK context is process-wide.
            Connect-MgGraph -TenantId $tenant -Scopes @('AppRegistration.Create','Directory.Read.All','Organization.Read.All','User.Read') -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
            $identity=Get-MgContext
            $organizations=Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/organization?$select=id,verifiedDomains' -OutputType PSObject
            if(@($organizations.value).Count -ne 1 -or $organizations.value[0].id -ne $identity.TenantId -or
                ($tenant -ne $identity.TenantId -and $tenant -notin @($organizations.value[0].verifiedDomains | ForEach-Object {$_.name}))) { throw 'Setup connected to the wrong tenant.' }
            $existing=Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/applications?$filter=displayName%20eq%20%27powershell-ui%20(read-only)%27&$select=id,appId,displayName,publicClient,requiredResourceAccess' -OutputType PSObject
            $nextLink=if($existing -is [Collections.IDictionary]){$existing['@odata.nextLink']}elseif($existing.PSObject.Properties['@odata.nextLink']){$existing.'@odata.nextLink'}else{''}
            if($nextLink -or @($existing.value).Count -gt 1) { throw 'Multiple matching applications exist. Select and review one in Entra; no new application was created.' }
            if(@($existing.value).Count -eq 1) { return [pscustomobject]@{AppId=$existing.value[0].appId;Created=$false;Note='Existing application found. Review permissions and redirect URI before use; it was not changed.'} }
            $resource=Invoke-MgGraphRequest -Method GET -Uri 'https://graph.microsoft.com/v1.0/servicePrincipals?$filter=appId%20eq%20%2700000003-0000-0000-c000-000000000000%27&$select=id,oauth2PermissionScopes' -OutputType PSObject
            if(@($resource.value).Count -ne 1) { throw 'Microsoft Graph permission definitions could not be resolved.' }
            $permissions=@()
            foreach($scope in $readScopes) {
                $matches=@($resource.value[0].oauth2PermissionScopes | Where-Object {$_.value -eq $scope -and $_.isEnabled})
                if($matches.Count -ne 1 -or $scope -match 'Write|FullControl') { throw 'A requested read permission is unavailable. No application created.' }
                $permissions+=@{id=$matches[0].id;type='Scope'}
            }
            $body=@{displayName='powershell-ui (read-only)';signInAudience='AzureADMyOrg';isFallbackPublicClient=$true;publicClient=@{redirectUris=@('http://localhost')};requiredResourceAccess=@(@{resourceAppId='00000003-0000-0000-c000-000000000000';resourceAccess=$permissions})}
            $app=Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/applications' -Body ($body | ConvertTo-Json -Depth 12) -ContentType 'application/json' -OutputType PSObject
            [pscustomobject]@{AppId=$app.appId;Created=$true;Note='Public reader app created without secrets. An authorized administrator must review/consent the delegated read permissions. No consent grants or directory roles were changed.'}
        } @($tenant,@(Get-M365ReadScopes -Extended)))
        return $results[-1]
    } finally { Disconnect-M365Session $Context }
}
function Disconnect-M365Session {
    param([hashtable]$Context)
    if(-not $Context.ContainsKey('SharedGraph')) { return }
    $graph=$Context.SharedGraph;$graph.Ready=$false;$graph.Generation=[guid]::NewGuid().ToString()
    if($null -ne $graph.Runspace) {
        try { Invoke-M365Worker $Context { try {if(Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) {Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null}} finally {Remove-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue} } | Out-Null } catch {}
        try{$graph.Runspace.Close();$graph.Runspace.Dispose()}catch{}
        $graph.Runspace=$null
    }
    $graph.TenantId='';$graph.Account='';$graph.ClientId='';$graph.Scopes=@()
}
Export-ModuleMember Get-M365ReadScopes,Initialize-M365Session,Connect-M365Session,Invoke-M365GraphRequest,Invoke-M365GraphRead,Find-M365ReaderApplication,Register-M365ReaderApplication,Disconnect-M365Session
