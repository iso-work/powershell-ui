#Requires -Version 5.1
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-AzqrFixture {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "AZQR fixture assertion failed: $Message" }
}

$testRoot = $PSScriptRoot
$temporaryDirectory = Join-Path $testRoot ('work-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $temporaryDirectory)
$wrapper = Join-Path (Split-Path $testRoot -Parent) 'Invoke-Report.ps1'
$fixtureWrapper = Join-Path $temporaryDirectory 'Invoke-FixtureReport.ps1'
$fixtureSource = Join-Path $temporaryDirectory 'Fixture.cs'
$fixtureExecutable = Join-Path $temporaryDirectory 'azqr.exe'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
$savedInheritedValue = [Environment]::GetEnvironmentVariable('AZURE_CLIENT_CERTIFICATE_PATH', 'Process')
$savedFixtureMode = [Environment]::GetEnvironmentVariable('ISO_AZQR_FIXTURE_MODE', 'Process')
$dummySecret = 'fixture-only-do-not-emit-this-secret'
$secureSecret = ConvertTo-SecureString -String $dummySecret -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential('11111111-1111-1111-1111-111111111111', $secureSecret)
$parameters = @{
    TenantId = '22222222-2222-2222-2222-222222222222'
    SubscriptionId = '33333333-3333-3333-3333-333333333333'
    ResourceGroup = 'Fixture-Group'
    AzqrPath = $fixtureExecutable
}
$nativeProcesses = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'
$context = @{
    Credentials = @{ AzureServicePrincipal = $credential }
    RunDirectory = $temporaryDirectory
    NativeProcesses = $nativeProcesses
}
$fixtureCode = @'
using System;
using System.IO;
using System.Linq;
public class Fixture {
    public static int Main(string[] args) {
        if (args.Length == 1 && args[0] == "--version") {
            if (!String.IsNullOrEmpty(Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET"))) return 91;
            Console.WriteLine("azqr version v.4.2.0");
            return 0;
        }
        if (args.Length < 9 || args[0] != "scan" || !args.Contains("--json") ||
            !args.Contains("--xlsx=false") || !args.Contains("--mask=true") ||
            args.Contains("--plugin") || args.Contains("--stages")) return 92;
        if (Environment.GetEnvironmentVariable("AZURE_TOKEN_CREDENTIALS") != "EnvironmentCredential" ||
            Environment.GetEnvironmentVariable("AZURE_CLIENT_ID") != "11111111-1111-1111-1111-111111111111" ||
            Environment.GetEnvironmentVariable("AZURE_TENANT_ID") != "22222222-2222-2222-2222-222222222222" ||
            Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET") != "fixture-only-do-not-emit-this-secret" ||
            !String.IsNullOrEmpty(Environment.GetEnvironmentVariable("AZURE_CLIENT_CERTIFICATE_PATH"))) return 93;
        if (Environment.GetEnvironmentVariable("USERPROFILE") == Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)) return 94;
        if (Directory.Exists(Path.Combine(Environment.CurrentDirectory, "plugins"))) return 95;
        var mode = Environment.GetEnvironmentVariable("ISO_AZQR_FIXTURE_MODE");
        if (mode == "fail") {
            Console.Error.WriteLine("ERR " + Environment.GetEnvironmentVariable("AZURE_CLIENT_SECRET"));
            return 23;
        }
        if (mode == "warning") Console.Error.WriteLine("WRN Simulated missing permission");
        int outputIndex = Array.IndexOf(args, "--output-name") + 1;
        if (outputIndex < 1 || outputIndex >= args.Length) return 96;
        string output = args[outputIndex] + ".json";
        if (mode == "invalid-json") { File.WriteAllText(output, "{"); return 0; }
        string extra = mode == "plugin" ? ",\"externalPlugins\":[]" : "";
        File.WriteAllText(output, "{\"recommendations\":[{\"recommendationId\":\"fixture-001\",\"impactedResources\":\"1\"}],\"impacted\":[{\"name\":\"fixture-resource\"}],\"resourceType\":[],\"inventory\":[{\"name\":\"fixture-resource\",\"sku\":\"example\"}],\"outOfScope\":null,\"advisor\":[],\"defender\":[]" + extra + "}");
        // Large outputs on both pipes exercise the wrapper's concurrent draining.
        Console.Out.Write(new String('x', 131072));
        Console.Error.Write(new String('y', 131072));
        return 0;
    }
}
'@

try {
    Set-Content -LiteralPath $fixtureSource -Value $fixtureCode -Encoding UTF8
    & $compiler /nologo /target:exe ("/out:" + $fixtureExecutable) /reference:System.Core.dll $fixtureSource
    if ($LASTEXITCODE -ne 0) { throw 'Could not compile the local AZQR fixture.' }
    $caught = $false
    try { $null = & $wrapper -Parameters $parameters -Context $context }
    catch {
        $caught = $true
        Assert-AzqrFixture ($_.Exception.Message -like '*checksum*') 'Production wrapper did not reject the untrusted fixture before execution.'
    }
    Assert-AzqrFixture $caught 'Production checksum enforcement accepted the fake executable.'
    # Test the real native-process contract with only the checksum allowlist
    # changed in a temporary wrapper copy. Production source is never modified.
    $fixtureHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $fixtureExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    $wrapperText = Get-Content -LiteralPath $wrapper -Raw
    $wrapperText = $wrapperText.Replace('1b7d8aafcd06a37f78af197d72f407a37220fd64a3eaf0ba1b6c7503ef2c7e35', $fixtureHash)
    Set-Content -LiteralPath $fixtureWrapper -Value $wrapperText -Encoding UTF8
    [Environment]::SetEnvironmentVariable('AZURE_CLIENT_CERTIFICATE_PATH', 'inherited-value-must-not-reach-child', 'Process')
    [Environment]::SetEnvironmentVariable('ISO_AZQR_FIXTURE_MODE', $null, 'Process')
    $result = & $fixtureWrapper -Parameters $parameters -Context $context
    Assert-AzqrFixture ($result.Records.Count -eq 3) 'Combined native JSON did not map to three typed records.'
    Assert-AzqrFixture ($result.Summary.DatasetCounts.inventory -eq 1) 'Inventory summary is incorrect.'
    Assert-AzqrFixture ($nativeProcesses.Count -eq 0) 'Native process registry was not cleared.'
    Assert-AzqrFixture ([Environment]::GetEnvironmentVariable('AZURE_CLIENT_CERTIFICATE_PATH', 'Process') -eq 'inherited-value-must-not-reach-child') 'Parent environment was mutated.'
    Assert-AzqrFixture (($result | ConvertTo-Json -Depth 20) -notmatch [regex]::Escape($dummySecret)) 'Result disclosed the credential.'
    [Environment]::SetEnvironmentVariable('ISO_AZQR_FIXTURE_MODE', 'warning', 'Process')
    $warningResult = & $fixtureWrapper -Parameters $parameters -Context $context
    Assert-AzqrFixture ($warningResult.Summary.UpstreamWarningCount -eq 1) 'Warning was not counted.'
    Assert-AzqrFixture ($warningResult.Summary.Coverage -eq 'Potentially partial') 'Warning did not mark partial coverage.'
    foreach ($mode in @('fail', 'invalid-json', 'plugin')) {
        [Environment]::SetEnvironmentVariable('ISO_AZQR_FIXTURE_MODE', $mode, 'Process')
        $caught = $false
        try { $null = & $fixtureWrapper -Parameters $parameters -Context $context }
        catch {
            $caught = $true
            Assert-AzqrFixture ($_.Exception.Message -notmatch [regex]::Escape($dummySecret)) "The $mode error disclosed the credential."
        }
        Assert-AzqrFixture $caught "The $mode fixture was incorrectly accepted."
        Assert-AzqrFixture ($nativeProcesses.Count -eq 0) "Process registry was not cleared after $mode."
    }
    [Environment]::SetEnvironmentVariable('ISO_AZQR_FIXTURE_MODE', $null, 'Process')
    $invalidParameters = $parameters.Clone()
    $invalidParameters.SubscriptionId = 'not-a-guid'
    $caught = $false
    try { $null = & $fixtureWrapper -Parameters $invalidParameters -Context $context } catch { $caught = $true }
    Assert-AzqrFixture $caught 'Invalid subscription was accepted.'
    Write-Output 'PASS: AZQR native fixture (no cloud calls): production checksum rejection, arguments, child credentials, inherited credential removal, parent environment, plugin isolation, JSON mapping, large dual-pipe output, partial coverage, failure redaction, malformed JSON, unexpected dataset, invalid GUID, and process cleanup.'
}
finally {
    [Environment]::SetEnvironmentVariable('AZURE_CLIENT_CERTIFICATE_PATH', $savedInheritedValue, 'Process')
    [Environment]::SetEnvironmentVariable('ISO_AZQR_FIXTURE_MODE', $savedFixtureMode, 'Process')
    $secureSecret.Dispose()
    # The generated target must remain directly under this test directory.
    $resolvedTemporary = [IO.Path]::GetFullPath($temporaryDirectory)
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\') + '\'
    if (-not $resolvedTemporary.StartsWith($resolvedTestRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove an unexpected fixture directory.'
    }
    Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
}
