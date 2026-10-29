param([hashtable]$Parameters,[hashtable]$Context)
$ErrorActionPreference='Stop'
foreach($key in @('ExchangeOnline','SharePointOnline')) {if(-not $Parameters.ContainsKey($key) -or $Parameters[$key] -isnot [bool]){throw 'Service selections must be Boolean values.'}}
$records=[Collections.Generic.List[object]]::new();$statuses=[Collections.Generic.List[object]]::new();$limitations=[Collections.Generic.List[string]]::new();$incomplete=$false
foreach($service in @('ExchangeOnline','SharePointOnline')) {
    if(-not $Parameters[$service]) {continue}
    $operation=switch($service){'ExchangeOnline'{'ExchangeConfiguration'} 'SharePointOnline'{'SharePointSites'}}
    try {
        $result=Invoke-LauncherServiceRead -Context $Context -Service $service -Operation $operation
        if($result.Incomplete){$incomplete=$true}
        $statuses.Add([pscustomobject]@{Service=$service;Status=$(if($result.Incomplete){'Partial'}else{'Complete'});Collections=$result.Collections})
        foreach($row in $result.Records){$records.Add([pscustomobject]@{Id=($service+':'+$records.Count);Service=$service;Collection=$row.Collection;Data=$row.Data})}
        foreach($line in $result.Limitations){$limitations.Add($line)}
    } catch {$incomplete=$true;$statuses.Add([pscustomobject]@{Service=$service;Status='Failed';Error='Connect this service from Login to 365 and verify its read permissions.'})}
}
if(-not $statuses.Count){throw 'Choose at least one service.'}
[pscustomobject]@{Summary=[pscustomobject]@{TenantId=$Context.Tenant.Id;Incomplete=$incomplete;Services=@($statuses.ToArray())};Records=@($records.ToArray());Limitations=@($limitations.ToArray())+@('Fixed read operations only. A failed read is not evidence of an empty or healthy service. Reuses retained sessions; no arbitrary PowerShell commands are accepted.')}
