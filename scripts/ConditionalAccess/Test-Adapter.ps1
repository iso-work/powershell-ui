$ErrorActionPreference='Stop'
class CaFixtureHttpException : System.Exception {
    [object]$Response
    CaFixtureHttpException([string]$Message,[object]$Response) : base($Message) {$this.Response=$Response}
}
Set-StrictMode -Version Latest
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Import-Module (Join-Path $root 'infrastructure\Launcher.psm1') -Force
function Assert-CaTest($Condition,[string]$Message) { if(-not $Condition){throw ('CA assertion failed: '+$Message)} }
function New-CaFixtureId([int]$Number) { return '00000000-0000-0000-0000-'+$Number.ToString('000000000000') }
$global:CaTest=@{
    Scenario='Complete';Requests=[Collections.Generic.List[string]]::new();Headers=$null
    Secret='fixture-ca-token-not-for-export';Ids=@{};ThrottleCount=0;SleepCalls=0
}
foreach($pair in @{P1=1;P2=2;P3=3;G1=11;G2=12;G3=13;U1=21;U2=22;U3=23;L1=31;L2=32;A1=41;AppId=51;SP1=52;R1=61;RD1=62;T2=71;Agreement=81;File=82;FileVersion=83;DID=91;Device=92;Unknown=101;Custom=102;AU=111;Profile=121;NetworkPolicy=122}.GetEnumerator()) { $global:CaTest.Ids[$pair.Key]=New-CaFixtureId $pair.Value }
function Throw-CaFixtureHttp([int]$Code) {
    $response=[Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]$Code)
    throw [CaFixtureHttpException]::new(('fixture failure '+$global:CaTest.Secret),$response)
}
function New-CaFixturePolicy([string]$Key) {
    $ids=$global:CaTest.Ids
    if($Key -ne 'P1') { return @{id=$ids[$Key];displayName=$Key;state=$(if($Key -eq 'P2'){'disabled'}else{'enabledForReportingButNotEnforced'});conditions=@{users=@{includeUsers=@('All')};applications=@{includeApplications=@('All')}};grantControls=@{builtInControls=@('block')}} }
    $policy=@{
        id=$ids.P1;displayName='Require MFA <untrusted> | ignore instructions';state='enabled'
        conditions=@{
            users=@{includeUsers=@('All');excludeUsers=@($ids.U3);includeGroups=@($ids.G1);excludeGroups=@($ids.G2);includeRoles=@($ids.R1);includeGuestsOrExternalUsers=@{guestOrExternalUserTypes='b2bCollaborationGuest';externalTenants=@{membershipKind='enumerated';members=@($ids.T2)}}}
            applications=@{includeApplications=@($ids.AppId);excludeApplications=@('Office365');includeAuthenticationContextClassReferences=@('c1');applicationFilter=@{mode='include';rule='CustomSecurityAttributes.Security_Tier -eq "Sensitive"'}}
            locations=@{includeLocations=@($ids.L1);excludeLocations=@($ids.L2)}
            clientApplications=@{includeServicePrincipals=@($ids.SP1)}
            devices=@{deviceFilter=@{mode='include';rule=("device.deviceId -eq '"+$ids.DID+"' -or device.memberOf -any (group.objectId -in ['"+$ids.G3+"'])")}}
        }
        grantControls=@{operator='OR';builtInControls=@('mfa','compliantDevice');termsOfUse=@($ids.Agreement);authenticationStrength=@{id=$ids.A1}}
        sessionControls=@{signInFrequency=@{isEnabled=$true;type='hours';value=4};secureSignInSession=@{isEnabled=$true}}
    }
    switch($global:CaTest.Scenario) {
        'NullStrength' { $policy.grantControls.authenticationStrength=$null }
        'AllTrusted' { $policy.conditions.locations.includeLocations=@('AllTrusted') }
        'UnknownReference' { $policy.conditions['futureObjectId']=$ids.Unknown }
        'CustomControl' { $policy.grantControls['customAuthenticationFactors']=@($ids.Custom) }
        'NetworkProfile' { $policy.sessionControls['globalSecureAccessFilteringProfile']=@{isEnabled=$true;profileId=$ids.Profile} }
    }
    return $policy
}
function New-CaFixtureMember([string]$Key,[string]$Type) {
    return @{id=$global:CaTest.Ids[$Key];displayName=$Key;'@odata.type'=('#microsoft.graph.'+$Type)}
}
function global:Start-Sleep { param($Seconds) $global:CaTest.SleepCalls++ }
function Invoke-CaFixtureResponse {
    param($Method,$Uri,$Headers,$TimeoutSec,$MaximumRedirection,$ErrorAction)
    Assert-CaTest ($Method -eq 'Get') 'Collector must use GET only.'
    Assert-CaTest ($MaximumRedirection -eq 0 -and $TimeoutSec -eq 90) 'Redirect and timeout controls missing.'
    Assert-CaTest ($Headers.Authorization -eq ('Bearer '+$global:CaTest.Secret)) 'Bearer must be supplied only through headers.'
    $global:CaTest.Headers=$Headers; $global:CaTest.Requests.Add([string]$Uri)
    $address=[uri]$Uri; $path=$address.AbsolutePath; $query=$address.Query; $ids=$global:CaTest.Ids; $scenario=$global:CaTest.Scenario
    Assert-CaTest ($address.Host -eq 'graph.microsoft.com') 'Bearer must never be sent to an external host.'
    if($path -match '^/(beta|v1\.0)/identity/conditionalAccess/policies$') {
        if($scenario -eq 'PolicyFailure') { Throw-CaFixtureHttp 403 }
        if($query) {
            if($scenario -eq 'PolicyPageFailure') { Throw-CaFixtureHttp 403 }
            return @{value=@((New-CaFixturePolicy P2),(New-CaFixturePolicy P3))}
        }
        if($scenario -eq 'Empty') { return @{value=@()} }
        return @{value=@((New-CaFixturePolicy P1));'@odata.nextLink'=($address.GetLeftPart([UriPartial]::Path)+'?$skiptoken=next')}
    }
    if($path -match '^/(beta|v1\.0)/identity/conditionalAccess/policies/([^/]+)$') {
        $matchId=$Matches[2]
        foreach($key in @('P1','P2','P3')) { if($matchId -eq $ids[$key]) { return New-CaFixturePolicy $key } }
        throw 'Unknown fixture policy.'
    }
    if($path -like '*/grantControls/authenticationStrength') { Throw-CaFixtureHttp 404 }
    if($path -eq '/beta/identity/conditionalAccess/namedLocations') {
        return @{value=@(@{id=$ids.L1;displayName='Office';'@odata.type'='#microsoft.graph.ipNamedLocation';isTrusted=$true;ipRanges=@(@{'@odata.type'='#microsoft.graph.iPv4CidrRange';cidrAddress='192.0.2.0/24'})},@{id=$ids.L2;displayName='Countries';'@odata.type'='#microsoft.graph.countryNamedLocation';countriesAndRegions=@('US','CA');includeUnknownCountriesAndRegions=$true})}
    }
    if($path -match '^/beta/identity/conditionalAccess/namedLocations/([^/]+)$') {
        if($Matches[1] -eq $ids.L1) { return @{id=$ids.L1;displayName='Office';isTrusted=$true;ipRanges=@(@{cidrAddress='192.0.2.0/24'})} }
        return @{id=$ids.L2;displayName='Countries';countriesAndRegions=@('US','CA');includeUnknownCountriesAndRegions=$true}
    }
    if($path -match '^/beta/groups/([^/]+)/(members|transitiveMembers|owners)$') {
        $groupId=$Matches[1];$relation=$Matches[2]
        if($groupId -eq $ids.G1 -and $relation -eq 'members') {
            if($scenario -eq 'EmptyMembers') { return @{value=@()} }
            if($scenario -eq 'MalformedMembers') { return @{value=@{id=$ids.U1}} }
            if($scenario -eq 'MembersFailure') { Throw-CaFixtureHttp 403 }
            if($scenario -eq 'ThrottleOnce' -and $global:CaTest.ThrottleCount++ -eq 0) { Throw-CaFixtureHttp 429 }
            if($query -like '*$skiptoken=*') { return @{value=@((New-CaFixtureMember G3 group),(New-CaFixtureMember SP1 servicePrincipal))} }
            $next='https://graph.microsoft.com'+$path+'?$select=id,displayName&$skiptoken=second'
            switch($scenario) {
                'HostileHost' {$next='https://evil.example'+$path}
                'HostilePath' {$next='https://graph.microsoft.com/beta/users'}
                'HostileQuery' {$next='https://graph.microsoft.com'+$path+'?$expand=owners'}
                'RepeatedPage' {$next=[string]$Uri}
            }
            return @{value=@((New-CaFixtureMember U1 user));'@odata.nextLink'=$next}
        }
        if($relation -eq 'owners') { return @{value=@((New-CaFixtureMember U1 user))} }
        if($groupId -eq $ids.G1) { return @{value=@((New-CaFixtureMember U1 user),(New-CaFixtureMember U2 user),(New-CaFixtureMember G3 group),(New-CaFixtureMember SP1 servicePrincipal))} }
        if($groupId -eq $ids.G2) { return @{value=@((New-CaFixtureMember U3 user))} }
        # Synthetic cycle verifies that queues/cache terminate without recursive duplication.
        return @{value=@((New-CaFixtureMember U2 user),(New-CaFixtureMember G1 group))}
    }
    if($path -match '^/beta/groups/([^/]+)$') {
        return @{id=$Matches[1];displayName='Fixture group';visibility=$(if($scenario -eq 'HiddenGroup'){'HiddenMembership'}else{'Private'});groupTypes=@('DynamicMembership');membershipRule='user.department -eq "IT"';membershipRuleProcessingState='On';securityEnabled=$true}
    }
    if($path -match '^/v1.0/users/([^/]+)$') {
        if($scenario -eq 'LimitedUser' -and $Matches[1] -eq $ids.U2) { return @{id=$Matches[1];displayName=$null;userPrincipalName=$null} }
        if($scenario -eq 'UserDenied' -and $Matches[1] -eq $ids.U2) { Throw-CaFixtureHttp 403 }
        return @{id=$Matches[1];displayName='Fixture user';userPrincipalName=($Matches[1]+'@fixture.example');accountEnabled=$true;userType='Member'}
    }
    if($path -eq '/v1.0/servicePrincipals' -or $path -eq '/beta/servicePrincipals') { return @{value=@(@{id=$ids.SP1;appId=$ids.AppId;displayName='Enterprise app';'@odata.type'='#microsoft.graph.servicePrincipal';customSecurityAttributes=@{Security=@{Tier='Sensitive'}}})} }
    if($path -match '^/beta/servicePrincipals/([^/]+)$') { return @{id=$Matches[1];appId=$ids.AppId;displayName='Enterprise app';servicePrincipalType='Application';accountEnabled=$true} }
    if($path -eq '/beta/devices') { return @{value=@(@{id=$ids.Device;deviceId=$ids.DID;displayName='Device';isCompliant=$true;extensionAttributes=@{extensionAttribute1='Example'}})} }
    if($path -match '^/beta/devices/([^/]+)$') { return @{id=$Matches[1];deviceId=$ids.DID;displayName='Device';isCompliant=$true} }
    if($path -eq '/v1.0/directory/customSecurityAttributeDefinitions') { return @{value=@(@{id='Security_Tier';attributeSet='Security';name='Tier';type='String'})} }
    if($path -eq '/v1.0/directory/attributeSets') { return @{value=@(@{id='Security';description='Fixture set'})} }
    if($path -like '*/customSecurityAttributeDefinitions/*/allowedValues') { return @{value=@(@{id='Sensitive';isActive=$true})} }
    if($path -eq '/beta/identity/conditionalAccess/authenticationContextClassReferences/c1') { return @{id='c1';displayName='Sensitive context';isAvailable=$true} }
    if($path -eq ('/v1.0/policies/authenticationStrengthPolicies/'+$ids.A1)) { return @{id=$ids.A1;displayName='Phishing resistant';allowedCombinations=@('fido2','windowsHelloForBusiness');requirementsSatisfied='mfa'} }
    if($path -like '*/authenticationStrengthPolicies/*/combinationConfigurations') { return @{value=@(@{id='fido-fixture';allowedAAGUIDs=@('fixture-aaguid');appliesToCombinations=@('fido2')})} }
    if($path -eq ('/v1.0/roleManagement/directory/roleDefinitions/'+$ids.R1)) { Throw-CaFixtureHttp 404 }
    if($path -eq '/v1.0/roleManagement/directory/roleDefinitions') { return @{value=@(@{id=$ids.RD1;templateId=$ids.R1;displayName='Security Reader';rolePermissions=@(@{allowedResourceActions=@('read-only-fixture')})})} }
    if($path -match '^/v1.0/roleManagement/directory/(roleAssignments|roleAssignmentScheduleInstances|roleEligibilityScheduleInstances)$') {
        return @{value=@(@{id='assignment-fixture';principalId=$ids.G2;roleDefinitionId=$ids.RD1;directoryScopeId=('/administrativeUnits/'+$ids.AU)})}
    }
    if($path -match '^/v1.0/directory/administrativeUnits/([^/]+)$') { return @{id=$Matches[1];displayName='Scoped administrative unit';membershipType='Assigned'} }
    if($path -match '^/v1.0/directoryObjects/([^/]+)$') {
        if($Matches[1] -eq $ids.Unknown) { Throw-CaFixtureHttp 404 }
        return @{id=$Matches[1];displayName='Directory object';'@odata.type'='#microsoft.graph.group'}
    }
    if($path -like '/v1.0/tenantRelationships/findTenantInformationByTenantId*') { return @{tenantId=$ids.T2;displayName='External tenant';defaultDomainName='external.example'} }
    $agreementPath='/v1.0/identityGovernance/termsOfUse/agreements/'+$ids.Agreement
    if($path -eq $agreementPath) { return @{id=$ids.Agreement;displayName='Terms';isViewingBeforeAcceptanceRequired=$true} }
    if($path -eq ($agreementPath+'/files')) { return @{value=@(@{id=$ids.File;fileName='terms.pdf';language='en-US'})} }
    if($path -eq ($agreementPath+'/files/'+$ids.File)) { return @{id=$ids.File;fileName='terms.pdf';fileData=@{data='Zml4dHVyZQ=='}} }
    if($path -eq ($agreementPath+'/files/'+$ids.File+'/versions')) { return @{value=@(@{id=$ids.FileVersion;fileData=@{data='Zml4dHVyZQ=='}})} }
    if($path -eq ('/beta/networkAccess/filteringProfiles/'+$ids.Profile)) { return @{id=$ids.Profile;name='Filtering profile';priority=100} }
    if($path -eq ('/beta/networkAccess/filteringProfiles/'+$ids.Profile+'/policies')) { return @{value=@(@{id='link-fixture';policy=@{id=$ids.NetworkPolicy;'@odata.type'='#microsoft.graph.networkaccess.filteringPolicy'}})} }
    if($path -eq ('/beta/networkAccess/filteringPolicies/'+$ids.NetworkPolicy)) { return @{id=$ids.NetworkPolicy;name='Web categories';action='block'} }
    if($path -eq ('/beta/networkAccess/filteringPolicies/'+$ids.NetworkPolicy+'/policyRules')) { return @{value=@(@{id='network-rule';destinations=@('fixture.example')})} }
    throw ('Unmocked fixture URI: '+$Uri)
}
function global:Invoke-RestMethod {
    param($Method,$Uri,$Headers,$TimeoutSec,$MaximumRedirection,$ErrorAction)
    $response=Invoke-CaFixtureResponse @PSBoundParameters
    if($global:CaTest.Scenario -eq 'PsCustomObjects') { return $response | ConvertTo-Json -Depth 65 | ConvertFrom-Json -NoEnumerate }
    return $response
}
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('ca-adapter-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
$context=New-LauncherSession
$context.Tokens.GraphConditionalAccess=ConvertTo-SecureString $global:CaTest.Secret -AsPlainText -Force
$context.TokenMetadata.GraphConditionalAccess=@{Tenant='fixture.onmicrosoft.com';Client=(New-CaFixtureId 999);Profile='ConditionalAccess';Expires=[DateTime]::UtcNow.AddHours(1)}
$context.RunDirectory=$fixture
$parameters=@{TenantId='fixture.onmicrosoft.com';ClientId=(New-CaFixtureId 999);IncludeHiddenMembership=$true;IncludeFilterContext=$true;UseBetaPolicies=$true;MaxMinutes=180}
$adapter=Join-Path $PSScriptRoot 'Invoke-Report.ps1'; $checks=0
try {
    $output=@(& $adapter -Parameters $parameters -Context $context)
    Assert-CaTest ($output.Count -eq 1) 'Exactly one result object is returned.'
    $result=$output[0]
    $bundle=Get-Content -LiteralPath (Join-Path $fixture 'conditional-access.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-CaTest (-not $result.Summary.Incomplete -and $bundle.Policies.Count -eq 3) ('All policy pages and states must be complete. '+(($bundle.Objects | Where-Object Status -notin @('Resolved','Symbolic') | Select-Object Kind,Status,Id) | ConvertTo-Json -Compress))
    Assert-CaTest (($bundle.Policies.State -join ',') -match 'disabled' -and ($bundle.Policies.State -join ',') -match 'enabledForReportingButNotEnforced') 'Disabled/report-only policies are retained.'
    Assert-CaTest ($bundle.Policies[0].RawPolicy.grantControls.operator -eq 'OR' -and $bundle.Policies[0].RawPolicy.sessionControls.secureSignInSession.isEnabled) 'Full raw grant/session controls must survive.'
    Assert-CaTest (@($bundle.Policies[0].References | Where-Object Path -eq 'conditions.users.excludeGroups[0]').Count -eq 1) 'Excluded group must retain its reference path.'
    $group=$bundle.Objects | Where-Object Key -eq ('Group:'+$global:CaTest.Ids.G1)
    Assert-CaTest ($group.Relationships.members.ObjectKeys.Count -eq 3 -and $group.Relationships.transitiveMembers.ObjectKeys.Count -eq 4) 'Direct pagination and transitive membership are retained.'
    Assert-CaTest (@($bundle.Objects | Where-Object Kind -eq 'Group').Count -eq 3) 'Nested cycle must not duplicate group objects.'
    Assert-CaTest (@($bundle.Objects | Where-Object Kind -eq 'User').Count -eq 3) 'All direct/nested/excluded members must be resolved.'
    Assert-CaTest (@($bundle.Objects | Where-Object Kind -eq 'NamedLocation').Count -eq 2 -and ($bundle | ConvertTo-Json -Depth 65 -Compress) -match '192.0.2.0/24') 'Location details must be present.'
    foreach($kind in @('Role','Application','ServicePrincipal','AuthenticationContext','AuthenticationStrength','TermsOfUse','ExternalTenant','DeviceId','AdministrativeUnit')) { Assert-CaTest (@($bundle.Objects | Where-Object Kind -eq $kind).Count -ge 1) ('Missing reference kind: '+$kind) }
    Assert-CaTest ($bundle.FilterContext.CustomSecurityAttributeDefinitions.Status -eq 'Complete') 'Custom attribute context must be exported.'
    Assert-CaTest ((Get-Content -LiteralPath (Join-Path $fixture 'conditional-access.md') -Raw) -match '&lt;untrusted&gt;') 'Untrusted policy names must be escaped in Markdown.'
    Assert-CaTest ((Get-Content -LiteralPath (Join-Path $fixture 'conditional-access.json') -Raw) -notmatch $global:CaTest.Secret) 'No token may be exported.'
    Assert-CaTest ($global:CaTest.Headers.Count -eq 0) 'Temporary headers must be cleared.'
    $manifest=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher.json') -Raw | ConvertFrom-Json -AsHashtable
    $roundtrip=Write-LauncherReport $manifest $parameters $result 'Completed' $fixture ([DateTime]::UtcNow)
    Assert-CaTest ((Get-Content -LiteralPath $roundtrip.JsonPath -Raw) -notmatch '\[depth limit\]') 'Nested report must not truncate the linked graph.'
    $checks++
    foreach($scenario in @('MembersFailure','MalformedMembers','LimitedUser','UserDenied','HostileHost','HostilePath','HostileQuery','RepeatedPage','PolicyPageFailure','AllTrusted','UnknownReference','CustomControl')) {
        $global:CaTest.Scenario=$scenario; $global:CaTest.Requests.Clear()
        $result=& $adapter -Parameters $parameters -Context $context
        Assert-CaTest $result.Summary.Incomplete ('Coverage gap must be partial: '+$scenario)
        Assert-CaTest (@($global:CaTest.Requests | Where-Object {$_ -like '*evil.example*' -or $_ -eq 'https://graph.microsoft.com/beta/users'}).Count -eq 0) 'Hostile pages must be blocked before HTTP.'
        Assert-CaTest ($global:CaTest.Headers.Count -eq 0 -and ($result | ConvertTo-Json -Depth 65) -notmatch $global:CaTest.Secret) 'Failure must not retain/export headers.'
        if($scenario -eq 'UserDenied') { Assert-CaTest (@($result.Records | Where-Object { $_.RecordType -eq 'Group' -and $_.ResolutionStatus -eq 'Partial' }).Count -ge 1) 'Nested-member failures must propagate.' }
        if($scenario -eq 'PolicyPageFailure') { Assert-CaTest ($result.Summary.PolicyCount -eq 1 -and $result.Summary.PolicyCollectionStatus -eq 'Partial') 'Successful first policy page must survive.' }
        $checks++
    }
    foreach($scenario in @('PsCustomObjects','EmptyMembers','NullStrength')) {
        $global:CaTest.Scenario=$scenario
        $result=& $adapter -Parameters $parameters -Context $context
        Assert-CaTest (-not $result.Summary.Incomplete) ('Valid response must remain complete: '+$scenario)
        if($scenario -eq 'EmptyMembers') {
            $groupRecord=$result.Records | Where-Object Id -eq ('Group:'+$global:CaTest.Ids.G1)
            Assert-CaTest ($groupRecord.Data.Relationships.members.ReturnedCount -eq 0 -and $groupRecord.Data.Relationships.members.Status -eq 'Complete') 'Empty membership must remain distinct from denied membership.'
        }
        $checks++
    }
    $global:CaTest.Scenario='NetworkProfile'
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest (-not $result.Summary.Incomplete -and @($result.Records | Where-Object RecordType -eq 'FilteringPolicy').Count -eq 1) 'Supported Global Secure Access profile/policy/rules must resolve.'
    $checks++
    $global:CaTest.Scenario='ThrottleOnce'
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest (-not $result.Summary.Incomplete -and $global:CaTest.SleepCalls -eq 1) 'A bounded throttled GET should retry.'
    $checks++
    $global:CaTest.Scenario='HiddenGroup';$parameters.IncludeHiddenMembership=$false
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest $result.Summary.Incomplete 'Hidden groups without hidden-member scope must not claim completeness.'
    $parameters.IncludeHiddenMembership=$true;$checks++
    $global:CaTest.Scenario='Complete';$parameters.IncludeFilterContext=$false
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest $result.Summary.Incomplete 'Skipped filter context must be visible.'
    $parameters.IncludeFilterContext=$true;$checks++
    $parameters.UseBetaPolicies=$false
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest ($result.Summary.Incomplete -and $result.Summary.PolicyApiVersion -eq 'v1.0') 'Stable-only policy coverage must be labelled.'
    $parameters.UseBetaPolicies=$true;$checks++
    $global:CaTest.Scenario='Empty'
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest ($result.Summary.PolicyCount -eq 0 -and -not $result.Summary.Incomplete) 'An observed empty policy set is complete.'
    $checks++
    $global:CaTest.Scenario='PolicyFailure';$blocked=$false
    try { & $adapter -Parameters $parameters -Context $context | Out-Null } catch { $blocked=$true }
    Assert-CaTest $blocked 'Total policy read failure must fail rather than succeed empty.'
    $checks++
    $global:CaTest.Scenario='Complete';$global:CaTest.Requests.Clear();$parameters.IncludeHiddenMembership='false';$blocked=$false
    try { & $adapter -Parameters $parameters -Context $context | Out-Null } catch { $blocked=$true }
    Assert-CaTest ($blocked -and $global:CaTest.Requests.Count -eq 0) 'String booleans must fail before requests.'
    $parameters.IncludeHiddenMembership=$true
    $context.TokenMetadata.GraphConditionalAccess.Tenant='wrong.onmicrosoft.com';$blocked=$false
    try { & $adapter -Parameters $parameters -Context $context | Out-Null } catch { $blocked=$true }
    Assert-CaTest ($blocked -and $global:CaTest.Requests.Count -eq 0) 'Wrong-tenant token must fail before requests.'
    $checks++
    function global:Invoke-M365GraphRequest {
        param($Context,$Uri)
        if(-not $Context.SharedGraph.Ready){throw 'Missing shared fixture session.'}
        $global:CaTest.SharedReads++
        $testHeaders=@{Authorization=('Bearer '+$global:CaTest.Secret)}
        try {Invoke-CaFixtureResponse -Method Get -Uri $Uri -Headers $testHeaders -TimeoutSec 90 -MaximumRedirection 0}
        finally {$testHeaders.Clear()}
    }
    $global:CaTest.SharedReads=0;$global:CaTest.Scenario='Complete'
    $context.SharedGraph.Ready=$true;$context.SharedGraph.ClientId=(New-CaFixtureId 999)
    $context.Tenant.Id=(New-CaFixtureId 998)
    $result=& $adapter -Parameters $parameters -Context $context
    Assert-CaTest (-not $result.Summary.Incomplete -and $global:CaTest.SharedReads -gt 10 -and $result.Summary.Tenant -eq $context.Tenant.Id) 'CA must use the shared SDK transport and discovered tenant, without a legacy profile token.'
    $checks++
    "PASS: $checks Conditional Access offline scenarios: full policy/reference graph, nested memberships, locations, pagination, partial/empty/failure coverage, throttling, token boundaries and safe exports. No tenant was accessed."
} finally {
    Remove-Item Function:\Invoke-RestMethod,Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-M365GraphRequest -ErrorAction SilentlyContinue
    Clear-LauncherSession $context
    Remove-Variable -Name CaTest -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($fixture);$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'ca-adapter-tests-*') { throw 'Unexpected CA fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
