$ErrorActionPreference='Stop'
$global:fixtureADQuery=$null
function Assert-AD($value,$message) { if(-not $value) { throw $message } }
function global:Get-ADComputer {
    param($Server,$Filter,$Properties,$Credential,$SearchBase,$ErrorAction)
    $global:fixtureADQuery=@{Server=$Server;Filter=$Filter;Credential=$Credential}
    $old=[DateTime]::UtcNow.AddDays(-300)
    $recent=[DateTime]::UtcNow.AddDays(-2)
    foreach($row in @(@('old',$old,4096,$false),@('recent',$recent,4096,$false),@('dc',$old,8192,$false),@('protected',$old,4096,$true),@('unknown',$null,4096,$false))) {
        [pscustomobject]@{Name=$row[0];ObjectGUID=[guid]::NewGuid();Enabled=$true;lastLogonTimestamp=$(if($row[1]){$row[1].ToFileTimeUtc()}else{$null});PasswordLastSet=$old;whenCreated=$old;ProtectedFromAccidentalDeletion=$row[3];userAccountControl=$row[2]}
    }
}
$secret=ConvertTo-SecureString 'fixture-only' -AsPlainText -Force
$credential=[pscredential]::new('fixture-user',$secret)
try {
    $context=@{Credentials=@{ActiveDirectory=$credential}}
    $result=& (Join-Path $PSScriptRoot 'Invoke-Report.ps1') -Parameters @{Server='fixture.invalid';InactiveDays=90;IncludeDisabled=$false} -Context $context
    Assert-AD ($result.Records.Count -eq 5) 'AD fixture record count failed.'
    foreach($expectation in @{old='ReviewCandidate';recent='RecentActivity';dc='ExcludedDomainController';protected='ProtectedReview';unknown='UnknownActivity'}.GetEnumerator()) {
        Assert-AD (($result.Records | Where-Object Name -eq $expectation.Key).Assessment -eq $expectation.Value) "AD assessment failed: $($expectation.Key)"
    }
    Assert-AD ($global:fixtureADQuery.Credential.UserName -eq 'fixture-user' -and $global:fixtureADQuery.Filter -eq 'Enabled -eq $true') 'AD credential/filter forwarding failed.'
    Assert-AD (($result | ConvertTo-Json -Depth 20) -notmatch 'fixture-only') 'Credential appeared in AD output.'
    'PASS: AD read-only fixture assessments, credential forwarding and output.'
} finally {
    Remove-Item Function:\Get-ADComputer -ErrorAction SilentlyContinue
    Remove-Variable fixtureADQuery -Scope Global -ErrorAction SilentlyContinue
    $secret.Dispose()
}

