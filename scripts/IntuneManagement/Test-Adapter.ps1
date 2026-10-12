[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$adapterPath = Join-Path $PSScriptRoot 'Invoke-Report.ps1'
$fakeSecret = 'mock-token-never-export'
$global:IntuneAdapterTestState = @{ Requests = (New-Object System.Collections.Generic.List[string]); Scenario = 'Complete'; LastHeaders = $null; FakeSecret = $fakeSecret }
$context = @{ Tokens = @{ Graph = (ConvertTo-SecureString -String $fakeSecret -AsPlainText -Force) } }
$parameters = @{ TenantId = 'example.onmicrosoft.com'; ClientId = '00000000-0000-0000-0000-000000000001'; IncludeDevices = $false }
$testCount = 0

function Assert-Adapter {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('ASSERTION FAILED: ' + $Message) }
}

function global:Invoke-RestMethod {
    param($Method, $Uri, $Headers, $ErrorAction)
    Assert-Adapter -Condition ([string]$Method -eq 'Get') -Message 'Only GET is permitted.'
    Assert-Adapter -Condition ($Headers.Authorization -eq ('Bearer ' + $global:IntuneAdapterTestState.FakeSecret)) -Message 'Token is supplied only in the request header.'
    $global:IntuneAdapterTestState.LastHeaders = $Headers
    $global:IntuneAdapterTestState.Requests.Add([string]$Uri)
    $address = [uri]$Uri
    Assert-Adapter -Condition ($address.DnsSafeHost -eq 'graph.microsoft.com') -Message 'No non-Graph request may be made.'
    switch ($address.AbsolutePath) {
        '/v1.0/deviceManagement/deviceConfigurations' {
            if ($address.Query -eq '?page=2') {
                if ($global:IntuneAdapterTestState.Scenario -eq 'PageFailure') { throw ('Request failed: ' + $global:IntuneAdapterTestState.FakeSecret) }
                return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'profile-2'; displayName = 'Second profile'; '@odata.type' = '#microsoft.graph.windows10GeneralConfiguration' }) }
            }
            $next = 'https://graph.microsoft.com/v1.0/deviceManagement/deviceConfigurations?page=2'
            if ($global:IntuneAdapterTestState.Scenario -eq 'HostileOrigin') { $next = 'https://evil.example/v1.0/deviceManagement/deviceConfigurations' }
            if ($global:IntuneAdapterTestState.Scenario -eq 'HostilePath') { $next = 'https://graph.microsoft.com/v1.0/users' }
            if ($global:IntuneAdapterTestState.Scenario -eq 'RepeatedPage') { $next = [string]$Uri }
            return [pscustomobject]@{
                value = @([pscustomobject]@{
                    id = 'profile-1'; displayName = 'First profile'; description = 'Ordinary profile description'
                    nested = [pscustomobject]@{ password = 'must-not-export'; allowed = $true; values = @('one','two') }
                    omaSettings = @([pscustomobject]@{ omaUri = './Vendor/MSFT/WiFi/Profile/Password'; value = 'wifi-secret' })
                })
                '@odata.nextLink' = $next
            }
        }
        '/v1.0/deviceManagement/deviceCompliancePolicies' { return [pscustomobject]@{ value = @() } }
        '/v1.0/deviceAppManagement/mobileApps' {
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'app-1'; displayName = 'App'; largeIcon = @{ value = 'binary' } }) }
        }
        '/beta/deviceManagement/configurationPolicies' {
            if ($global:IntuneAdapterTestState.Scenario -eq 'BetaFailure') { throw ('Forbidden request with sensitive diagnostic: ' + $global:IntuneAdapterTestState.FakeSecret) }
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'catalog-1'; name = 'Catalog'; settingCount = 2 }) }
        }
        '/v1.0/deviceManagement/managedDevices' {
            Assert-Adapter -Condition ($address.Query -like '*$select=*') -Message 'Device inventory has an explicit field selection.'
            Assert-Adapter -Condition ($address.Query -notmatch 'activationLock|remoteAssistance|emailAddress|userPrincipalName') -Message 'Device selection excludes sensitive/contact fields.'
            return [pscustomobject]@{ value = @([pscustomobject]@{ id = 'device-1'; deviceName = 'PC-1'; complianceState = 'compliant'; isEncrypted = $true }) }
        }
        default { throw ('Unexpected test request path: ' + $address.AbsolutePath) }
    }
}

try {
    $output = @(& $adapterPath -Parameters $parameters -Context $context)
    Assert-Adapter ($output.Count -eq 1) 'Adapter returns one structured result.'
    $report = $output[0]
    Assert-Adapter (-not $report.Summary.Incomplete) 'Successful collections produce a complete report.'
    Assert-Adapter ($report.Summary.RecordCount -eq 4) 'Pagination collects both profiles plus app and settings catalog.'
    Assert-Adapter ($global:IntuneAdapterTestState.Requests.Count -eq 5) 'Four collections, including one extra pagination request, are queried.'
    Assert-Adapter (@($report.Summary.Collections | Where-Object { $_.ReportType -eq 'CompliancePolicies' })[0].RecordCount -eq 0) 'A successful empty collection is explicitly complete.'
    Assert-Adapter ($report.Records[0].Data.nested.password -eq '[REDACTED]') 'Nested credential properties are redacted.'
    Assert-Adapter ($report.Records[0].Data.omaSettings[0].value -eq '[REDACTED]') 'Credential OMA-URI values are redacted.'
    Assert-Adapter ($report.Records[0].Data.nested.values.Count -eq 2) 'Arrays are preserved.'
    $json = $report | ConvertTo-Json -Depth 40
    Assert-Adapter ($json -notmatch [regex]::Escape($fakeSecret)) 'Report never includes the bearer token.'
    Assert-Adapter ($json -notmatch 'must-not-export|wifi-secret|binary') 'Credential and opaque payload values are absent.'
    Assert-Adapter ($global:IntuneAdapterTestState.LastHeaders.Count -eq 0) 'Ephemeral authorization header is cleared.'
    $testCount++

    $global:IntuneAdapterTestState.Requests.Clear()
    $parameters.IncludeDevices = $true
    $report = & $adapterPath -Parameters $parameters -Context $context
    Assert-Adapter ($report.Summary.RecordCount -eq 5) 'Optional device inventory is returned.'
    Assert-Adapter (@($report.Records | Where-Object { $_.ReportType -eq 'ManagedDevices' }).Count -eq 1) 'Device report type is identified.'
    $parameters.IncludeDevices = $false
    $testCount++

    foreach ($failureScenario in @('BetaFailure','HostileOrigin','HostilePath','RepeatedPage','PageFailure')) {
        $global:IntuneAdapterTestState.Scenario = $failureScenario
        $global:IntuneAdapterTestState.Requests.Clear()
        $report = & $adapterPath -Parameters $parameters -Context $context
        Assert-Adapter $report.Summary.Incomplete ('Failure must mark report incomplete: ' + $failureScenario)
        Assert-Adapter (@($report.Records | Where-Object { $_.Type -eq 'CollectionError' }).Count -eq 1) ('Failure is visible in records: ' + $failureScenario)
        Assert-Adapter (($report | ConvertTo-Json -Depth 40) -notmatch [regex]::Escape($fakeSecret)) ('Raw exception secret is never exported: ' + $failureScenario)
        Assert-Adapter ($global:IntuneAdapterTestState.LastHeaders.Count -eq 0) ('Headers cleared even after failure: ' + $failureScenario)
        Assert-Adapter (@($global:IntuneAdapterTestState.Requests | Where-Object { $_ -match 'evil.example|/users' }).Count -eq 0) ('Hostile pagination is blocked before HTTP: ' + $failureScenario)
        if ($failureScenario -eq 'PageFailure') {
            Assert-Adapter (@($report.Summary.Collections | Where-Object { $_.ReportType -eq 'ConfigurationProfiles' })[0].Status -eq 'Partial') 'Successful first-page records are retained as partial.'
        }
        $testCount++
    }

    $global:IntuneAdapterTestState.Scenario = 'Complete'
    $global:IntuneAdapterTestState.Requests.Clear()
    $rejected = $false
    try { & $adapterPath -Parameters $parameters -Context @{ Tokens = @{ Graph = 'plain-text-token' } } | Out-Null }
    catch { $rejected = $true }
    Assert-Adapter $rejected 'Plain-text token inputs are rejected.'
    Assert-Adapter ($global:IntuneAdapterTestState.Requests.Count -eq 0) 'Invalid token cannot make a request.'
    $testCount++

    $parameters.IncludeDevices = 'false'
    $rejected = $false
    try { & $adapterPath -Parameters $parameters -Context $context | Out-Null }
    catch { $rejected = $true }
    Assert-Adapter $rejected 'String Boolean is rejected rather than accidentally enabling devices.'
    Assert-Adapter ($global:IntuneAdapterTestState.Requests.Count -eq 0) 'Invalid parameter cannot make a request.'
    $testCount++

    $manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher.json') -Raw | ConvertFrom-Json
    Assert-Adapter ($manifest.readOnly -eq $true -and $manifest.auth -eq 'Graph') 'Manifest declares read-only Graph auth.'
    Assert-Adapter ($manifest.entryPoint -eq 'Invoke-Report.ps1') 'Upstream GUI is not an executable catalog entry.'
    $testCount++
    Write-Output ('PASS: ' + $testCount + ' Intune adapter mock checks; no network calls made.')
}
finally {
    Remove-Item Function:\Invoke-RestMethod -ErrorAction SilentlyContinue
    $context.Tokens.Graph.Dispose()
    $context.Clear()
    Remove-Variable -Name IntuneAdapterTestState -Scope Global -ErrorAction SilentlyContinue
}

