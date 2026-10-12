#Requires -Version 5.1
<#
.SYNOPSIS
Downloads the pinned official AZQR Windows executable for local use.
.DESCRIPTION
Verifies the official ZIP, its published checksum, and the extracted executable
against pinned hashes. Copies only azqr.exe into the launcher's tools directory.
Does not execute AZQR, authenticate, install cloud dependencies, or scan Azure.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$launcherRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$toolsDirectory = Join-Path $launcherRoot 'tools'
$destination = Join-Path $toolsDirectory 'azqr.exe'
$nativeArchitecture = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432 }
switch ($nativeArchitecture.ToUpperInvariant()) {
    'AMD64' {
        $architecture = 'amd64'
        $expectedZipHash = '68efc992445a424e1a89c2d312c1a30059a93dc627f7cf1b2848c1e392290e4e'
        $expectedExecutableHash = '1b7d8aafcd06a37f78af197d72f407a37220fd64a3eaf0ba1b6c7503ef2c7e35'
    }
    'ARM64' {
        $architecture = 'arm64'
        $expectedZipHash = '0bb6ae33f2ac714e1810d7786d02fdd12aaa434e5d3b20d7a0730257896e2044'
        $expectedExecutableHash = 'dda9cae36c75cc0063c13ccb0344055bb45313ff5ccec6ac9d3c42e54521a86a'
    }
    default { throw 'The reviewed AZQR release supports Windows AMD64 and ARM64. This local installer cannot select a binary for this architecture.' }
}
if (Test-Path -LiteralPath $destination -PathType Leaf) {
    $existingHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existingHash -eq $expectedExecutableHash) {
        Write-Output "Verified existing pinned AZQR 4.2.0 ($architecture): $destination. No executable was run."
        return
    }
    throw 'The launcher tools directory already contains a different azqr.exe. It was preserved; relocate it manually before installing the reviewed version.'
}

$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$temporaryDirectory = Join-Path $temporaryRoot ('powershell-ui-azqr-' + [guid]::NewGuid().ToString('N'))
$previousSecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
$archive = $null
try {
    [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    [void](New-Item -ItemType Directory -Path $temporaryDirectory)
    $zipPath = Join-Path $temporaryDirectory 'azqr.zip'
    $checksumPath = Join-Path $temporaryDirectory 'azqr.zip.sha256'
    $executablePath = Join-Path $temporaryDirectory 'azqr.exe'
    $releaseUri = 'https://github.com/Azure/azqr/releases/download/v.4.2.0/azqr-win-' + $architecture + '.zip'
    Invoke-WebRequest -UseBasicParsing -Uri $releaseUri -OutFile $zipPath
    Invoke-WebRequest -UseBasicParsing -Uri ($releaseUri + '.sha256') -OutFile $checksumPath
    $actualZipHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $publishedChecksum = (Get-Content -LiteralPath $checksumPath -Raw -Encoding UTF8).Trim()
    if ($actualZipHash -ne $expectedZipHash -or $publishedChecksum -notmatch ('(?i)^' + [regex]::Escape($expectedZipHash) + '\s')) {
        throw 'The downloaded AZQR archive or published checksum does not match the pinned official release. Nothing was installed.'
    }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    $executableEntries = @($archive.Entries | Where-Object { $_.Name -ieq 'azqr.exe' })
    if ($executableEntries.Count -ne 1) { throw 'The reviewed ZIP must contain exactly one azqr.exe. Nothing was installed.' }
    # Extract one selected entry only, without allowing archive paths to choose destinations.
    [IO.Compression.ZipFileExtensions]::ExtractToFile($executableEntries[0], $executablePath, $false)
    $archive.Dispose()
    $archive = $null
    $actualExecutableHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualExecutableHash -ne $expectedExecutableHash) {
        throw 'The extracted AZQR executable does not match the reviewed checksum. Nothing was installed.'
    }
    [void](New-Item -ItemType Directory -Path $toolsDirectory -Force)
    # File.Copy with overwrite=false preserves a destination created concurrently.
    [IO.File]::Copy($executablePath, $destination, $false)
    $installedHash = (Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($installedHash -ne $expectedExecutableHash) { throw 'The installed file failed checksum verification. Do not use it.' }
    Write-Output "Installed checksum-verified AZQR 4.2.0 ($architecture): $destination. No executable, Azure authentication, or cloud scan was run."
}
finally {
    if ($null -ne $archive) { $archive.Dispose() }
    [Net.ServicePointManager]::SecurityProtocol = $previousSecurityProtocol
    $resolvedTemporaryDirectory = [IO.Path]::GetFullPath($temporaryDirectory)
    $resolvedTemporaryRoot = $temporaryRoot.TrimEnd('\') + '\'
    if (-not $resolvedTemporaryDirectory.StartsWith($resolvedTemporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedTemporaryDirectory) -notmatch '^powershell-ui-azqr-[0-9a-f]{32}$') {
        throw 'Refusing to remove an unexpected local installer directory.'
    }
    if (Test-Path -LiteralPath $resolvedTemporaryDirectory) {
        Remove-Item -LiteralPath $resolvedTemporaryDirectory -Recurse -Force
    }
}
