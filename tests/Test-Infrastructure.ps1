$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'infrastructure/Catalog.psm1') -Force
function Assert($condition,$message) { if(-not $condition) { throw $message } }
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File | Where-Object Extension -in '.ps1','.psm1') {
$tokens=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
Assert ($errors.Count -eq 0) "Syntax errors: $($file.FullName): $errors"
}
$catalog=@(Get-ScriptCatalog -Root $root)
$example=@($catalog | Where-Object Name -like '*Get-Greeting.ps1')
Assert ($example.Count -eq 1) 'Example discovery failed'
Assert ($example[0].Parameters.Count -eq 2) 'Parameter discovery failed'
Assert ($example[0].Usage -match 'EXPECTED OUTPUT') 'Usage discovery failed'
Assert (@($catalog | Where-Object Name -match 'infrastructure|tests').Count -eq 0) 'Excluded folders discovered'
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('powershell-ui-test-'+[guid]::NewGuid())
New-Item -ItemType Directory -Path (Join-Path $fixture 'nested/deeper') -Force | Out-Null
try {
Set-Content -LiteralPath (Join-Path $fixture 'nested/deeper/one.ps1') -Value 'param([string]$Name) $Name'
Set-Content -LiteralPath (Join-Path $fixture 'nested/deeper/usage.txt') -Value 'fallback'
Set-Content -LiteralPath (Join-Path $fixture 'nested/deeper/one.txt') -Value 'specific'
$found=@(Get-ScriptCatalog -Root $fixture)
Assert ($found.Count -eq 1 -and $found[0].Usage.Trim() -eq 'specific') 'Recursive discovery or usage precedence failed'
Set-Content -LiteralPath (Join-Path $fixture 'nested/deeper/broken.ps1') -Value 'param('
$broken=@(Get-ScriptCatalog -Root $fixture | Where-Object Name -like '*broken.ps1')
Assert ($broken[0].Errors.Count -gt 0) 'Syntax error detection failed'
$request=Join-Path $fixture 'request.json'
@{Script=$example[0].Path; Parameters=@{Name='Alex'; Uppercase=$true}} | ConvertTo-Json | Set-Content -LiteralPath $request
$engine=(Get-Process -Id $PID).Path
$result=& $engine -NoProfile -NonInteractive -File (Join-Path $root 'infrastructure/Invoke-Script.ps1') -RequestPath $request
Assert ($LASTEXITCODE -eq 0 -and ($result -join '').Trim() -eq 'HELLO, ALEX!') 'Worker output or switch handling failed'
@{Script=$example[0].Path; Parameters=@{}} | ConvertTo-Json | Set-Content -LiteralPath $request
$result=& $engine -NoProfile -NonInteractive -File (Join-Path $root 'infrastructure/Invoke-Script.ps1') -RequestPath $request 2>&1
Assert ($LASTEXITCODE -ne 0) 'Missing mandatory parameter did not fail'
'PASS: syntax, recursive discovery, usage precedence, parameter metadata, exclusions, worker output, switch and failure handling.'
} finally {
# fixture is a GUID-named directory created in this test, never a user-provided path.
Remove-Item -LiteralPath $fixture -Recurse -Force
}
