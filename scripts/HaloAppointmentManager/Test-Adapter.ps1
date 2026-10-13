$ErrorActionPreference='Stop'
function Assert-Halo($Condition,[string]$Message) { if(-not $Condition) { throw $Message } }
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('halo-package-tests-'+[guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($fixture)
try {
    $output=Join-Path $fixture 'output'; [void][IO.Directory]::CreateDirectory($output)
    $result=& (Join-Path $PSScriptRoot 'Invoke-Report.ps1') -Parameters @{HaloUrl='https://halo.fixture.example'} -Context @{RunDirectory=$output}
    Assert-Halo ($result.Summary.LiveHaloRequests -eq 0 -and $result.Summary.AppointmentsCompleted -eq 0) 'Preparation must not claim live activity.'
    $manifest=Get-Content -LiteralPath (Join-Path $result.Summary.PackageFolder 'manifest.json') -Raw | ConvertFrom-Json -AsHashtable
    Assert-Halo ($manifest.host_permissions.Count -eq 1 -and $manifest.host_permissions[0] -eq 'https://halo.fixture.example/*') 'Package must be scoped to one exact host.'
    Assert-Halo ($manifest.content_scripts[0].matches[0] -eq 'https://halo.fixture.example/*' -and $manifest.content_scripts[1].matches[0] -eq 'https://halo.fixture.example/*') 'All script matches must use the configured host.'
    Assert-Halo (-not $manifest.ContainsKey('permissions')) 'Reviewed extension must not request persistent storage permissions.'
    Assert-Halo (Test-Path -LiteralPath (Join-Path $result.Summary.PackageFolder 'llm-instructions.txt')) 'LLM instructions missing from package.'
    foreach($name in @('core.js','content.js','hook.js')) {
        Assert-Halo ((Get-FileHash -LiteralPath (Join-Path $result.Summary.PackageFolder $name)).Hash -eq (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "extension\$name")).Hash) 'Prepared code differs from reviewed source.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($result.Summary.ZipPath)
    try {
        Assert-Halo ($zip.Entries.Count -eq 6 -and $null -ne $zip.GetEntry('manifest.json') -and $null -ne $zip.GetEntry('llm-instructions.txt')) 'Extension ZIP is incomplete or contains unreviewed assets.'
    } finally { $zip.Dispose() }
    foreach($bad in @('http://halo.example','https://user:secret@halo.example','https://halo.example/calendar','https://halo.example?token=secret','https://halo.example:8443','https://*.example','https://halo.example/#calendar')) {
        $blocked=$false
        try { & (Join-Path $PSScriptRoot 'Invoke-Report.ps1') -Parameters @{HaloUrl=$bad} -Context @{RunDirectory=$output} } catch { $blocked=$true }
        Assert-Halo $blocked 'An unsupported or credential-bearing Halo URL was accepted.'
    }
    $copied=Join-Path $fixture 'tampered'
    [void][IO.Directory]::CreateDirectory($copied)
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Invoke-Report.ps1') -Destination $copied
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'extension') -Destination $copied -Recurse
    Add-Content -LiteralPath (Join-Path $copied 'extension\core.js') -Value '/* changed fixture */'
    $blocked=$false
    try { & (Join-Path $copied 'Invoke-Report.ps1') -Parameters @{HaloUrl='https://halo.example'} -Context @{RunDirectory=$output} } catch { $blocked=$true }
    Assert-Halo $blocked 'Altered extension source was not blocked.'
    $provenance=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UPSTREAM.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach($entry in $provenance.files.GetEnumerator()) {
        Assert-Halo ((Get-FileHash -LiteralPath (Join-Path $PSScriptRoot ('upstream\'+$entry.Key))).Hash -eq $entry.Value) 'Original source snapshot changed.'
    }
    $node=Get-Command node -ErrorAction SilentlyContinue
    if(-not $node) { throw 'Node.js is required for Halo offline JavaScript verification, not for using the extension.' }
    & $node.Source --test (Join-Path $PSScriptRoot 'tests\Test-Core.cjs') (Join-Path $PSScriptRoot 'tests\Test-Browser.cjs')
    Assert-Halo ($LASTEXITCODE -eq 0) 'Halo JavaScript checks failed.'
    'PASS: Halo package host scope, no live activity, ZIP contents, instructions, source integrity, unsupported URLs and original snapshot. JavaScript tests use synthetic requests; no Halo appointment was read or changed.'
} finally {
    $resolved=[IO.Path]::GetFullPath($fixture); $tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'halo-package-tests-*') { throw 'Unexpected Halo fixture cleanup path.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
