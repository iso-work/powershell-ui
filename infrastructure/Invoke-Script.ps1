param([Parameter(Mandatory)][string]$RequestPath)
$ErrorActionPreference='Stop'
try {
$request=Get-Content -LiteralPath $RequestPath -Raw | ConvertFrom-Json
$arguments=@{}
foreach($property in $request.Parameters.PSObject.Properties) { $arguments[$property.Name]=$property.Value }
Set-Location -LiteralPath (Split-Path -Parent $request.Script)
& $request.Script @arguments *>&1 | Out-String -Stream | ForEach-Object { [Console]::WriteLine($_) }
if(-not $?) { exit 1 }
} catch { [Console]::Error.WriteLine(($_ | Out-String)); exit 1 }
