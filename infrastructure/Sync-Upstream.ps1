#requires -Version 7.2
<#
.SYNOPSIS
Copies three approved, pinned public source snapshots without executing upstream code.
.DESCRIPTION
Validates the manifest and existing provenance; verifies each remote commit and every
archive file against Git's blob SHA-1. Copies only into the three approved upstream
directories and writes matching UPSTREAM.json provenance. It does not delete old
directories, install dependencies, initialize submodules, invoke upstream scripts,
commit, or push. Run -ValidateOnly for a local, network-free configuration check.
.PARAMETER RepositoryRoot
Launcher repository directory. Defaults to the parent of infrastructure/.
.PARAMETER ValidateOnly
Check local pins and path safety only. Makes no file or network changes.
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Split-Path -Parent $PSScriptRoot),
    [switch] $ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'RepositoryRoot must be an existing directory.' }
$comparison = [StringComparison]::Ordinal
$pathComparer = [StringComparer]::Ordinal
if ($IsWindows) { $comparison = [StringComparison]::OrdinalIgnoreCase; $pathComparer = [StringComparer]::OrdinalIgnoreCase }
$rootPrefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar

# These source repositories and commits are deliberately fixed. Updating a pin
# requires a reviewed change to this allowlist and the manifest together.
$approved = @{
    CleanupMonster = @{ Repository = 'https://github.com/EvotecIT/CleanupMonster'; Commit = '52e339e7f31a74736feb0daf664fd8d808150446' }
    IntuneManagement = @{ Repository = 'https://github.com/Micke-K/IntuneManagement'; Commit = '1bd21513584c7decbe574fcaca6668c3a54e0603' }
    azqr = @{ Repository = 'https://github.com/Azure/azqr'; Commit = '3ccbd659d78a9cec6d60f7b43e5bc093f453ed25' }
}

function Assert-SnapshotPath {
    param([string] $Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.StartsWith($rootPrefix, $comparison)) { throw "Snapshot path escapes RepositoryRoot: $Path" }
    $current = $root
    $segments = $fullPath.Substring($rootPrefix.Length) -split '[\\/]'
    foreach ($segment in $segments) {
        if ($segment -eq '.git') { throw 'A .git path is prohibited in a source snapshot.' }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Snapshot path contains a link or reparse point: $current" }
        }
    }
    return $fullPath
}

function Get-GitBlobHash {
    param([byte[]] $Bytes)
    $header = [Text.Encoding]::ASCII.GetBytes("blob $($Bytes.Length)`0")
    $hasher = [Security.Cryptography.SHA1]::Create()
    try {
        $null = $hasher.TransformBlock($header, 0, $header.Length, $header, 0)
        $null = $hasher.TransformFinalBlock($Bytes, 0, $Bytes.Length)
        return -join ($hasher.Hash | ForEach-Object { $_.ToString('x2') })
    } finally { $hasher.Dispose() }
}

$jsonOptions = @{}
# PowerShell 7.5+ otherwise converts ISO date strings to DateTime automatically.
# Keep the provenance timestamp exactly as recorded on every supported version.
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions['DateKind'] = 'String' }
$manifestPath = Assert-SnapshotPath (Join-Path $root 'infrastructure/upstream-sources.json')
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json @jsonOptions
if ($manifest.schemaVersion -ne 1 -or @($manifest.sources).Count -ne 3) { throw 'Expected schemaVersion 1 and exactly three approved sources.' }
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($source in $manifest.sources) {
    if (-not (@($approved.Keys) -ccontains [string] $source.folder) -or -not $seen.Add([string] $source.folder)) { throw 'Unknown or duplicate source folder.' }
    $expected = $approved[$source.folder]
    if ($source.repository -cne $expected.Repository -or $source.commit -cne $expected.Commit -or $source.commit -notmatch '^[a-f0-9]{40}$') { throw "Unapproved repository or commit for $($source.folder)." }
    $parsedTimestamp = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string] $source.copiedUtc, [ref] $parsedTimestamp) -or $parsedTimestamp.Offset -ne [TimeSpan]::Zero) { throw 'copiedUtc must be a UTC timestamp.' }
    $target = Assert-SnapshotPath (Join-Path $root "scripts/$($source.folder)/upstream")
    $provenancePath = Assert-SnapshotPath (Join-Path $root "scripts/$($source.folder)/UPSTREAM.json")
    if (Test-Path -LiteralPath $provenancePath) {
        $provenance = Get-Content -LiteralPath $provenancePath -Raw | ConvertFrom-Json @jsonOptions
        if ($provenance.repository -cne $source.repository -or $provenance.commit -cne $source.commit -or $provenance.copiedUtc -cne $source.copiedUtc -or $provenance.format -cne 'complete working tree snapshot; .git excluded') {
            throw "Existing provenance does not match the approved local pin for $($source.folder)."
        }
    }
}
if ($ValidateOnly) {
    Write-Output 'Validated three pinned sources and existing local provenance. No files or network state changed.'
    return
}

foreach ($source in $manifest.sources) {
    $repoSlug = $source.repository.Substring('https://github.com/'.Length)
    $apiBase = "https://api.github.com/repos/$repoSlug"
    $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'iso-work-powershell-ui-source-copy' }
    $remoteCommit = Invoke-RestMethod -Uri "$apiBase/git/commits/$($source.commit)" -Headers $headers
    if ($remoteCommit.sha -cne $source.commit) { throw "Remote commit did not match the pin for $repoSlug." }
    $remoteTree = Invoke-RestMethod -Uri "$apiBase/git/trees/$($source.commit)?recursive=1" -Headers $headers
    if ($remoteTree.truncated) { throw "Remote tree was truncated for $repoSlug; refusing an incomplete copy." }
    $expectedFiles = [Collections.Generic.Dictionary[string,object]]::new($pathComparer)
    $gitlinks = @()
    foreach ($entry in $remoteTree.tree) {
        if ($entry.type -eq 'tree') { continue }
        if ($entry.mode -eq '160000') { $gitlinks += "$($entry.path)@$($entry.sha)"; continue }
        if ($entry.type -ne 'blob' -or $entry.mode -notin @('100644', '100755')) { throw "Unsupported source object mode at $($entry.path)." }
        $expectedFiles.Add([string] $entry.path, $entry)
    }
    $target = Assert-SnapshotPath (Join-Path $root "scripts/$($source.folder)/upstream")
    if (Test-Path -LiteralPath $target) {
        foreach ($existingFile in Get-ChildItem -LiteralPath $target -Recurse -File -Force) {
            $relative = [IO.Path]::GetRelativePath($target, $existingFile.FullName).Replace('\', '/')
            $null = Assert-SnapshotPath $existingFile.FullName
            if (-not $expectedFiles.ContainsKey($relative)) { throw "Unexpected existing file requires manual review; no deletion performed: $($existingFile.FullName)" }
        }
    }

    $zipPath = [IO.Path]::GetTempFileName()
    $zip = $null
    try {
        # Only public codeload archives for the fixed repositories above are downloaded.
        Invoke-WebRequest -Uri "https://codeload.github.com/$repoSlug/zip/$($source.commit)" -OutFile $zipPath -Headers @{ 'User-Agent' = 'iso-work-powershell-ui-source-copy' }
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        $archiveRoot = ($repoSlug -split '/')[1] + '-' + $source.commit + '/'
        $archiveFiles = [Collections.Generic.Dictionary[string,object]]::new($pathComparer)
        foreach ($zipEntry in $zip.Entries) {
            if (-not $zipEntry.FullName.StartsWith($archiveRoot, [StringComparison]::Ordinal)) { throw 'Unexpected archive root.' }
            $relative = $zipEntry.FullName.Substring($archiveRoot.Length)
            if ([string]::IsNullOrEmpty($relative)) { continue }
            if ($relative -match '(^|/)(\.\.?|\.git)(/|$)' -or $relative.Contains('\') -or $relative.StartsWith('/')) { throw 'Unsafe archive entry path.' }
            $destination = Assert-SnapshotPath (Join-Path $target $relative)
            if ($zipEntry.FullName.EndsWith('/')) { continue }
            if (-not $expectedFiles.ContainsKey($relative)) { throw "Archive has an unexpected file: $relative" }
            $archiveFiles.Add($relative, $zipEntry)
        }
        if ($archiveFiles.Count -ne $expectedFiles.Count) { throw 'Archive is missing source files. No snapshot copy attempted.' }
        $copied = 0
        foreach ($relative in $expectedFiles.Keys) {
            $zipEntry = $archiveFiles[$relative]
            $buffer = [IO.MemoryStream]::new()
            $stream = $zipEntry.Open()
            try { $stream.CopyTo($buffer); $bytes = $buffer.ToArray() } finally { $stream.Dispose(); $buffer.Dispose() }
            if ((Get-GitBlobHash $bytes) -cne $expectedFiles[$relative].sha) { throw "Source blob verification failed: $relative" }
            $destination = Assert-SnapshotPath (Join-Path $target $relative)
            $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
            [IO.File]::WriteAllBytes($destination, $bytes)
            if (-not $IsWindows) {
                # Preserve executable bits from the Git source tree on the Linux runner.
                $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::GroupRead -bor [IO.UnixFileMode]::OtherRead
                if ($expectedFiles[$relative].mode -eq '100755') { $mode = $mode -bor [IO.UnixFileMode]::UserExecute -bor [IO.UnixFileMode]::GroupExecute -bor [IO.UnixFileMode]::OtherExecute }
                [IO.File]::SetUnixFileMode($destination, $mode)
            }
            $copied++
        }
        $provenance = [ordered] @{
            format = 'complete working tree snapshot; .git excluded'
            repository = $source.repository
            commit = $source.commit
            copiedUtc = $source.copiedUtc
        }
        $provenancePath = Assert-SnapshotPath (Join-Path $root "scripts/$($source.folder)/UPSTREAM.json")
        [IO.File]::WriteAllText($provenancePath, ($provenance | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
        [PSCustomObject] @{
            Repository = $repoSlug
            Commit = $source.commit
            VerifiedFiles = $copied
            UninitializedSubmodules = $gitlinks
        }
    } finally {
        if ($null -ne $zip) { $zip.Dispose() }
        # Only the exact temporary archive created by this invocation is removed.
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    }
}
