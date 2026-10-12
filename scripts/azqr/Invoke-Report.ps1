#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][hashtable]$Parameters,
    [Parameter(Mandatory = $true)][hashtable]$Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-NativeArgument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-AzqrProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [string]$IsolatedHome,
        [hashtable]$CredentialEnvironment,
        [hashtable]$RunContext,
        [int]$TimeoutMilliseconds = 1800000
    )

    $process = New-Object System.Diagnostics.Process
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $registered = $false
    try {
        $info.FileName = $Executable
        $info.Arguments = (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
        $info.WorkingDirectory = $WorkingDirectory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        # No inherited credential chain, custom authority, or SDK logging settings.
        foreach ($key in @($info.EnvironmentVariables.Keys)) {
            if ([string]$key -match '^AZURE_') { $info.EnvironmentVariables.Remove([string]$key) }
        }
        $info.EnvironmentVariables['HOME'] = $IsolatedHome
        $info.EnvironmentVariables['USERPROFILE'] = $IsolatedHome
        $info.EnvironmentVariables['AZURE_CLOUD'] = 'AzurePublic'
        $info.EnvironmentVariables['AZURE_AUTHORITY_HOST'] = 'https://login.microsoftonline.com/'
        $info.EnvironmentVariables['AZURE_TOKEN_CREDENTIALS'] = 'EnvironmentCredential'
        foreach ($key in $CredentialEnvironment.Keys) {
            $info.EnvironmentVariables[[string]$key] = [string]$CredentialEnvironment[$key]
        }
        $process.StartInfo = $info
        if ($RunContext.ContainsKey('NativeProcesses') -and $null -ne $RunContext.NativeProcesses) {
            [void]$RunContext.NativeProcesses.Add($process)
            $registered = $true
        }
        if (-not $process.Start()) { throw 'AZQR could not be started.' }
        # Drain both pipes concurrently, including when a large scan fills either buffer.
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill() } catch { }
            [void]$process.WaitForExit(5000)
            throw 'AZQR exceeded the 30-minute limit. Narrow the subscription or resource-group scope and retry.'
        }
        $stdoutText = $stdoutTask.GetAwaiter().GetResult()
        $stderrText = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StandardOutput = $stdoutText
            StandardError = $stderrText
        }
    }
    finally {
        # This changes the child configuration only; the launcher's environment is untouched.
        $info.EnvironmentVariables.Clear()
        $CredentialEnvironment.Clear()
        if ($registered) {
            try { [void]$RunContext.NativeProcesses.Remove($process) } catch { }
        }
        try {
            if (-not $process.HasExited) {
                $process.Kill()
                [void]$process.WaitForExit(5000)
            }
        } catch { }
        $process.Dispose()
    }
}

foreach ($name in @('TenantId', 'SubscriptionId')) {
    $parsedGuid = [guid]::Empty
    if (-not $Parameters.ContainsKey($name) -or
        -not [guid]::TryParse([string]$Parameters[$name], [ref]$parsedGuid) -or
        $parsedGuid -eq [guid]::Empty) {
        throw "$name must be a non-empty GUID."
    }
}
$tenantId = ([guid]$Parameters.TenantId).ToString()
$subscriptionId = ([guid]$Parameters.SubscriptionId).ToString()
$resourceGroup = if ($Parameters.ContainsKey('ResourceGroup')) { ([string]$Parameters.ResourceGroup).Trim() } else { '' }
if ($resourceGroup -and ($resourceGroup -notmatch '^[\p{L}\p{Nd}_().-]{1,90}$' -or $resourceGroup.EndsWith('.'))) {
    throw 'ResourceGroup must be one valid Azure resource-group name (1-90 letters, numbers, underscores, parentheses, hyphens or periods; no trailing period).'
}
if (-not $Parameters.ContainsKey('AzqrPath') -or -not (Test-Path -LiteralPath ([string]$Parameters.AzqrPath) -PathType Leaf)) {
    throw 'AzqrPath must point to an existing trusted azqr.exe version 4.2.0. See directions.txt for the official release.'
}
$executableItem = Get-Item -LiteralPath ([string]$Parameters.AzqrPath)
if ($executableItem.PSProvider.Name -ne 'FileSystem' -or $executableItem.Name -ine 'azqr.exe') {
    throw 'AzqrPath must point to a trusted file named azqr.exe.'
}
# Hashes computed from the official v.4.2.0 Windows release archives after their
# SHA256 values were verified against the matching published .zip.sha256 assets.
$trustedExecutableHashes = @(
    '1b7d8aafcd06a37f78af197d72f407a37220fd64a3eaf0ba1b6c7503ef2c7e35', # amd64
    'dda9cae36c75cc0063c13ccb0344055bb45313ff5ccec6ac9d3c42e54521a86a'  # arm64
)
$actualExecutableHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $executableItem.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualExecutableHash -notin $trustedExecutableHashes) {
    throw 'azqr.exe does not match either reviewed official version 4.2.0 Windows executable checksum. No executable or scan was started.'
}
if (-not $Context.ContainsKey('RunDirectory') -or -not (Test-Path -LiteralPath ([string]$Context.RunDirectory) -PathType Container)) {
    throw 'The launcher must supply an existing RunDirectory for local reports.'
}
if (-not $Context.ContainsKey('Credentials') -or -not $Context.Credentials.ContainsKey('AzureServicePrincipal') -or
    $Context.Credentials.AzureServicePrincipal -isnot [System.Management.Automation.PSCredential]) {
    throw 'Add the AzureServicePrincipal credential in the launcher: username is the application/client ID and password is its client secret.'
}
$credential = $Context.Credentials.AzureServicePrincipal
$clientId = [guid]::Empty
if (-not [guid]::TryParse($credential.UserName, [ref]$clientId) -or $clientId -eq [guid]::Empty) {
    throw 'The AzureServicePrincipal username must be the non-empty application/client ID GUID.'
}
if ($credential.Password.Length -eq 0) { throw 'The AzureServicePrincipal client secret cannot be empty.' }
$runDirectory = (Get-Item -LiteralPath ([string]$Context.RunDirectory)).FullName
# azqr auto-loads YAML plugins from the home directory and current working directory.
# A fresh local home and fresh run directory keep those locations isolated.
$isolationDirectory = Join-Path $runDirectory ('.azqr-isolation-' + [guid]::NewGuid().ToString('N'))
$isolatedHome = Join-Path $isolationDirectory 'home'
$isolatedWork = Join-Path $isolationDirectory 'work'
[void](New-Item -ItemType Directory -Path $isolatedHome)
[void](New-Item -ItemType Directory -Path $isolatedWork)

try {
    $versionResult = Invoke-AzqrProcess -Executable $executableItem.FullName -Arguments @('--version') `
        -WorkingDirectory $isolatedWork -IsolatedHome $isolatedHome -CredentialEnvironment @{} -RunContext $Context -TimeoutMilliseconds 10000
} catch { throw 'Unable to verify azqr.exe. Use the trusted official Windows release version 4.2.0.' }
$actualVersion = $versionResult.StandardOutput.Trim()
if ($versionResult.ExitCode -ne 0 -or $actualVersion -notin @('azqr version v.4.2.0', 'azqr version v4.2.0', 'azqr version 4.2.0')) {
    throw 'This wrapper requires trusted azqr.exe version 4.2.0, whose flags and read-only scan were reviewed. See directions.txt.'
}
$versionResult = $null

$outputBase = Join-Path $runDirectory 'azqr-native'
$arguments = @('scan', '--subscription-id', $subscriptionId, '--json', '--xlsx=false', '--mask=true', '--output-name', $outputBase)
if ($resourceGroup) { $arguments += @('--resource-group', $resourceGroup) }
$bstr = [IntPtr]::Zero
$plainSecret = $null
$credentialEnvironment = @{}
$scanResult = $null
try {
    # The native SDK requires a plaintext environment value in its own process.
    # Convert only at launch; no secret is placed in arguments, files, logs, or parent environment.
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($credential.Password)
    $plainSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    $credentialEnvironment = @{
        AZURE_CLIENT_ID = $clientId.ToString()
        AZURE_CLIENT_SECRET = $plainSecret
        AZURE_TENANT_ID = $tenantId
    }
    $scanResult = Invoke-AzqrProcess -Executable $executableItem.FullName -Arguments $arguments `
        -WorkingDirectory $isolatedWork -IsolatedHome $isolatedHome -CredentialEnvironment $credentialEnvironment -RunContext $Context
} catch {
    # Do not forward native exception text, which may contain authentication material.
    throw 'AZQR could not complete. Verify the executable, network access, Reader permissions, credentials, and scope; a 30-minute run limit applies.'
}
finally {
    if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    $credentialEnvironment.Clear()
    $plainSecret = $null
    $credential = $null
}
if ($scanResult.ExitCode -ne 0) {
    $exitCode = $scanResult.ExitCode
    $scanResult = $null
    throw "AZQR failed with exit code $exitCode. Verify Reader access, the tenant/client secret, and the scan scope. Native authentication output is withheld to protect credentials."
}
$cleanLog = [regex]::Replace([string]$scanResult.StandardError, '\x1B\[[0-?]*[ -/]*[@-~]', '')
$upstreamWarnings = [regex]::Matches($cleanLog, '(?im)(?:^|\s)(?:WRN|ERR|WARN|ERROR)\b').Count
$cleanLog = $null
$scanResult = $null
$nativeJsonPath = $outputBase + '.json'
if (-not (Test-Path -LiteralPath $nativeJsonPath -PathType Leaf)) {
    throw 'AZQR completed without its expected consolidated JSON report. No complete result is available.'
}
try { $report = Get-Content -LiteralPath $nativeJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { throw 'AZQR produced an unreadable JSON report. No complete result is available.' }
if ($null -eq $report -or $report -isnot [pscustomobject]) {
    throw 'AZQR produced an unexpected JSON report shape. No complete result is available.'
}
foreach ($requiredDataset in @('recommendations', 'impacted', 'resourceType', 'inventory', 'outOfScope')) {
    if ($requiredDataset -notin $report.PSObject.Properties.Name) {
        throw 'AZQR omitted a required default scan dataset. No complete result is available.'
    }
}

$records = New-Object 'System.Collections.Generic.List[object]'
$counts = [ordered]@{}
$permittedDatasets = @('recommendations', 'impacted', 'resourceType', 'inventory', 'outOfScope', 'advisor', 'defender')
foreach ($property in $report.PSObject.Properties) {
    if ($property.Name -notin $permittedDatasets) {
        throw 'AZQR returned an unexpected dataset. This wrapper permits only the reviewed default scan datasets and no external plugins.'
    }
    $rows = if ($null -eq $property.Value) { @() } else { @($property.Value) }
    $counts[$property.Name] = @($rows).Count
    foreach ($row in $rows) {
        [void]$records.Add([pscustomobject]@{ Dataset = $property.Name; Data = $row })
    }
}
$limitations = @(
    'Read-only Azure assessment: the wrapper runs the reviewed default scan only, without remediation, custom plugins, or cloud writes.',
    'Use an application granted only Azure Reader at the requested subscription. Azure role assignments are administered outside the launcher.',
    'Results reflect the requested subscription and optional resource group at collection time; permissions and API availability can limit coverage.',
    'Recommendations are review candidates, not proof of a vulnerability or a compliance certification. Missing or empty findings do not prove the absence of issues.',
    'Subscription IDs are masked by AZQR. Resource names, resource identifiers, and topology may still be sensitive; review before sharing with an LLM.',
    'Native logs are not exported because authentication output can disclose sensitive information. The combined native JSON is retained locally as azqr-native.json.'
)
if ($upstreamWarnings -gt 0) {
    $limitations += 'AZQR emitted warnings or errors despite a zero exit code. Treat the report as potentially partial and verify coverage before drawing conclusions.'
}
[pscustomobject]@{
    Summary = [pscustomobject]@{
        Tool = 'Azure Quick Review'
        UpstreamVersion = '4.2.0'
        CollectedAtUtc = [DateTime]::UtcNow.ToString('o')
        Cloud = 'AzurePublic'
        ReadOnly = $true
        SubscriptionIdsMasked = $true
        ResourceGroup = $resourceGroup
        DatasetCounts = [pscustomobject]$counts
        RecordCount = $records.Count
        UpstreamWarningCount = $upstreamWarnings
        Incomplete = ($upstreamWarnings -gt 0)
        Coverage = $(if ($upstreamWarnings -gt 0) { 'Potentially partial' } else { 'Not independently verified' })
    }
    Records = @($records.ToArray())
    Limitations = $limitations
}
