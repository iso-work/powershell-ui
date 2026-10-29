$ErrorActionPreference='Stop'
function global:Invoke-LauncherServiceRead {
    param($Context,$Service,$Operation)
    if($Service -eq 'SharePointOnline'){throw 'Synthetic denied read'}
    [pscustomobject]@{Incomplete=$false;Collections=@(@{Name='Fixture';Status='Complete'});Records=@(@{Collection='Fixture';Data=@{Name='Example'}});Limitations=@('Synthetic fixture only.')}
}
try {
    $context=@{Tenant=@{Id='00000000-0000-0000-0000-000000000001'}}
    $result=& (Join-Path $PSScriptRoot 'Invoke-Report.ps1') -Context $context -Parameters @{ExchangeOnline=$true;SharePointOnline=$false}
    if($result.Summary.Incomplete -or $result.Records.Count -ne 1){throw 'Successful service result was not preserved.'}
    $result=& (Join-Path $PSScriptRoot 'Invoke-Report.ps1') -Context $context -Parameters @{ExchangeOnline=$true;SharePointOnline=$true}
    if(-not $result.Summary.Incomplete -or @($result.Summary.Services | Where-Object Status -eq 'Failed').Count -ne 1){throw 'Denied service must not become a healthy/empty result.'}
    'PASS: service inventory adapter success/partial routing; no service calls.'
} finally {Remove-Item Function:\Invoke-LauncherServiceRead -ErrorAction SilentlyContinue}
