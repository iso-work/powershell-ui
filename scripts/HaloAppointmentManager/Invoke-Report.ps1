#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][hashtable]$Parameters,[Parameter(Mandatory)][hashtable]$Context)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$text=([string]$Parameters['HaloUrl']).Trim()
if(-not $text) { $text='https://support.isoutsource.com' }
$uri=$null
if(-not [Uri]::TryCreate($text,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or -not $uri.IsDefaultPort -or
    $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/' -or $uri.Host.Contains('*')) {
    throw 'Enter an exact HTTPS Halo address with no credentials, path, query or nonstandard port.'
}
$origin=$uri.GetLeftPart([UriPartial]::Authority)
if(-not $Context.ContainsKey('RunDirectory') -or -not(Test-Path -LiteralPath $Context.RunDirectory -PathType Container)) { throw 'Use the launcher or Prepare-Extension.ps1 to create the report directory.' }
$expectedFiles=@{
    'content.js' = '025B2C87D5B28567FD8B189A3F9ECC1A83648B791ADDA499E7BAF6D15BD240E9'
    'core.js' = '780F08C3DB3F476E7FC5627B433A5B04F4F99A8DA79B0083D2681E5FB1CDE3ED'
    'hook.js' = '338F276F1231B4B88CBA2B9610DBE6A93D5B7FFC603AAB209FE031FBA419BDD8'
    'llm-instructions.txt' = '24A2E5D52E1DCB0BACAC65AAC3B820626FD377BC4F0C800B9540E9AE26D8D73B'
    'manifest.json' = 'CCCFF7F2DDB51EFE980179DF82E1FC4465299A03D863CCEF11FB80CB6CDF6486'
    'README.md' = '2A0BB5E8ACDA4923A4C2EFD96D6449AF2C9762ADEC4AA2EF099AE762D9FB678B'
}
if($expectedFiles.Count -lt 5) { throw 'Reviewed extension hashes are missing.' }
$source=Join-Path $PSScriptRoot 'extension'
if((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The extension source must not be a junction.' }
foreach($name in $expectedFiles.Keys) {
    $file=Get-Item -LiteralPath (Join-Path $source $name)
    if($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $expectedFiles[$name]) { throw 'Extension source integrity check failed.' }
}
$destination=Join-Path $Context.RunDirectory 'extension'
[void][IO.Directory]::CreateDirectory($destination)
foreach($name in $expectedFiles.Keys) { Copy-Item -LiteralPath (Join-Path $source $name) -Destination (Join-Path $destination $name) }
$manifestPath=Join-Path $destination 'manifest.json'
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
$pattern=$origin+'/*'
$manifest.host_permissions=@($pattern)
foreach($script in $manifest.content_scripts) { $script.matches=@($pattern) }
$manifest | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $manifestPath -Encoding utf8
$zipPath=Join-Path $Context.RunDirectory 'halo-appointment-manager.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($destination,$zipPath)
[pscustomobject]@{
    Summary=[pscustomobject][ordered]@{
        Operation='PrepareBrowserExtension';Version=$manifest.version;HaloOrigin=$origin
        LiveHaloRequests=0;AppointmentsCompleted=0;PackageFolder=$destination;ZipPath=$zipPath
        ZipSha256=(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
        ExtensionCanWrite=$true;RequiresExactSelectionConfirmation=$true
    }
    Records=@(
        [pscustomobject]@{Step=1;Instruction='Disable the original extension, then load this reviewed folder using Load unpacked in Edge or Chrome.';Location=$destination}
        [pscustomobject]@{Step=2;Instruction='Sign in to Halo normally and open its calendar. Open Halo appointments and Read appointments.';Location=($origin+'/calendar')}
        [pscustomobject]@{Step=3;Instruction='Select exact IDs, preview, acknowledge the changes and type the displayed COMPLETE count. The PowerShell launcher has not completed anything.';Location='Browser extension'}
        [pscustomobject]@{Step=4;Instruction='Review each outcome and save Markdown or JSON results with embedded LLM instructions. Close the Halo manager to clear its token cache.';Location='Browser downloads'}
    )
    Limitations=@(
        'This run prepared local files only. It did not contact Halo, authenticate, install a browser extension or change an appointment.',
        'The extension is write-capable and is the explicit exception to the other read-only reports. Only human-confirmed completion is exposed; delete, general edit and follow-up creation are not.',
        'The supplied 1.4.1 API contract was adapted and mock-tested, not validated against the deployed Halo tenant. Validate one appointment before using a larger batch.',
        'Halo credentials stay in the browser session, outside the launcher. Closing this launcher cannot clear an independently running browser; close the Halo manager or tab too.',
        'The copied upstream folder is reference material and includes broader original operations. Load the prepared extension folder, not upstream.',
        'Results exported by the extension can contain personal/business data. The launcher and extension send nothing to an LLM.'
    )
}
