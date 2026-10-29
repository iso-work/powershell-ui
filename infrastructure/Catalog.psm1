Set-StrictMode -Version Latest
function Get-ScriptCatalog {
    param([Parameter(Mandatory)][string]$Root)
    $base=(Resolve-Path -LiteralPath $Root).Path
    $approved=@('conditional-access','intune-readonly','m365-security','service-inventory')
    $registryPath=Join-Path $PSScriptRoot 'adapters.lock.json'
    $registry=Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json -AsHashtable
    $pending=[Collections.Generic.Stack[string]]::new();$pending.Push($base)
    $seenIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    while($pending.Count) {
        $directory=$pending.Pop()
        foreach($child in Get-ChildItem -LiteralPath $directory -Directory -Force) {
            if($child.Name -notin @('.git','upstream','infrastructure','tests','reports','tools','work','archive','legacy','disabled') -and
                -not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint)) {$pending.Push($child.FullName)}
        }
        $manifestPath=Join-Path $directory 'launcher.json'
        if(-not(Test-Path -LiteralPath $manifestPath -PathType Leaf)){continue}
        try {
            $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
            # Setup is separate. Unknown/local manifests cannot expand the reporting catalog.
            if(-not $manifest.ContainsKey('id') -or $manifest.id -notin $approved){continue}
            $errors=[Collections.Generic.List[string]]::new()
            if(-not $seenIds.Add([string]$manifest.id)){$errors.Add('Duplicate registered Microsoft 365 tool ID.')}
            if($manifest.readOnly -ne $true){$errors.Add('Only read-only Microsoft 365 report adapters are allowed.')}
            if($manifest.ContainsKey('kind') -and $manifest.kind -ne 'report'){$errors.Add('Unsupported Microsoft 365 report kind.')}
            if($manifest.entryPoint -ne 'Invoke-Report.ps1'){$errors.Add('Unsupported entry point.')}
            $entry=Join-Path $directory 'Invoke-Report.ps1';$hash=''
            if(-not(Test-Path -LiteralPath $entry -PathType Leaf)){$errors.Add('Entry point missing.')}
            else {
                if((Get-Item -LiteralPath $entry).Attributes -band [IO.FileAttributes]::ReparsePoint){$errors.Add('Entry point must be an ordinary file.')}
                $hash=(Get-FileHash -LiteralPath $entry -Algorithm SHA256).Hash
                $tokens=$null;$parseErrors=$null
                [void][Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$parseErrors)
                foreach($errorItem in $parseErrors){$errors.Add($errorItem.Message)}
            }
            if(-not $registry.ContainsKey($manifest.id) -or $registry[$manifest.id] -ne $hash){$errors.Add('Adapter has not passed the registered integrity check.')}
            $directions=Join-Path $directory 'directions.txt'
            $usage=if(Test-Path -LiteralPath $directions -PathType Leaf){Get-Content -LiteralPath $directions -Raw}else{$errors.Add('Missing directions.txt');'Missing directions.txt'}
            [pscustomobject]@{
                Name=$manifest.name;DisplayName=$(if($manifest.ContainsKey('displayName')){$manifest.displayName}else{$manifest.name})
                Purpose=$manifest.purpose;Path=$entry;Manifest=$manifest;Hash=$hash
                Parameters=@($manifest.parameters);Usage=$usage;Errors=@($errors)
            }
        } catch {Write-Warning "Invalid Microsoft 365 manifest: $manifestPath"}
    }
}
Export-ModuleMember Get-ScriptCatalog
