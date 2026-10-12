Set-StrictMode -Version Latest
function Get-ScriptCatalog {
param([Parameter(Mandatory)][string]$Root)
$base=(Resolve-Path -LiteralPath $Root).Path
$registryPath=Join-Path $PSScriptRoot 'adapters.lock.json'; $registry=@{}
if(Test-Path -LiteralPath $registryPath) { $registry=Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable }
$pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($base)
while($pending.Count) {
$directory=$pending.Pop()
foreach($child in Get-ChildItem -LiteralPath $directory -Directory -Force) {
if($child.Name -notin @('.git','upstream','infrastructure','tests','reports','work') -and -not($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($child.FullName) }
}
$path=Join-Path $directory 'launcher.json'
if(-not(Test-Path -LiteralPath $path)) { continue }
try {
$manifest=Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
$errors=[Collections.Generic.List[string]]::new()
if($manifest.readOnly -ne $true) { $errors.Add('Only read-only report adapters are allowed.') }
if($manifest.entryPoint -ne 'Invoke-Report.ps1') { $errors.Add('Unsupported entry point.') }
$entry=Join-Path $directory 'Invoke-Report.ps1'; $hash=''
if(-not(Test-Path -LiteralPath $entry)) { $errors.Add('Entry point missing.') }
else {
$hash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
$tokens=$null; $parseErrors=$null
[void][Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$parseErrors)
foreach($errorItem in $parseErrors) { $errors.Add($errorItem.Message) }
}
if(-not $registry.ContainsKey($manifest.id) -or $registry[$manifest.id] -ne $hash) { $errors.Add('Adapter has not passed the registered integrity check.') }
$directions=Join-Path $directory 'directions.txt'
$usage=if(Test-Path -LiteralPath $directions) { Get-Content -LiteralPath $directions -Raw } else { 'Missing directions.txt'; $errors.Add('Missing directions.txt') }
[pscustomobject]@{Name=$manifest.name;DisplayName=$(if($manifest.ContainsKey('displayName')){$manifest.displayName}else{$manifest.name});Purpose=$manifest.purpose;Path=$entry;Manifest=$manifest;Hash=$hash;Parameters=@($manifest.parameters);Usage=$usage;Errors=@($errors)}
} catch { Write-Warning "Invalid manifest: $path" }
}
}
Export-ModuleMember Get-ScriptCatalog

