function Get-ScriptCatalog {
param([Parameter(Mandatory)][string]$Root)
$base=(Resolve-Path -LiteralPath $Root).Path
$pending=[Collections.Generic.Stack[string]]::new(); $pending.Push($base)
while($pending.Count) {
$dir=$pending.Pop()
foreach($child in Get-ChildItem -LiteralPath $dir -Directory -Force) {
if($child.Name -notin @('.git','infrastructure','tests') -and -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pending.Push($child.FullName) }
}
if($dir -eq $base) { continue }
foreach($file in Get-ChildItem -LiteralPath $dir -File -Filter *.ps1) {
$usage=Join-Path $dir ($file.BaseName+'.txt')
if(-not (Test-Path -LiteralPath $usage)) { $usage=Join-Path $dir 'usage.txt' }
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
$parameters=@()
if($ast.ParamBlock) { $parameters=@($ast.ParamBlock.Parameters | ForEach-Object {
[pscustomobject]@{Name=$_.Name.VariablePath.UserPath; Declaration=$_.Extent.Text; IsSwitch=($_.StaticType -eq [Management.Automation.SwitchParameter])}
}) }
[pscustomobject]@{Name=$file.FullName.Substring($base.Length).TrimStart([char[]]@('/','\')); Path=$file.FullName; Parameters=$parameters; Errors=@($errors | ForEach-Object Message); Usage=$(if(Test-Path -LiteralPath $usage){Get-Content -LiteralPath $usage -Raw}else{'Missing usage.txt or script-name.txt'})}
}
}
}
Export-ModuleMember Get-ScriptCatalog
