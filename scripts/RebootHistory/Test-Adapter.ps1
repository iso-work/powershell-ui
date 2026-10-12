$ErrorActionPreference='Stop'
function Assert-History($Condition,[string]$Message) { if(-not $Condition) { throw $Message } }
function New-HistoryFixture([int]$Id,[string]$Provider,[DateTime]$Time,[long]$Record,[hashtable]$Data=@{},[int]$Level=4) {
    $fields=foreach($pair in $Data.GetEnumerator()) { '<Data Name="'+[Security.SecurityElement]::Escape($pair.Key)+'">'+[Security.SecurityElement]::Escape([string]$pair.Value)+'</Data>' }
    $event=[pscustomobject]@{
        Id=$Id;ProviderName=$Provider;TimeCreated=$Time;RecordId=$Record;Level=$Level;MachineName='fixture.invalid'
        Message='Synthetic event text; not parsed for intent.';Xml=('<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><EventData>'+($fields -join '')+'</EventData></Event>')
    }
    $event | Add-Member ScriptMethod ToXml { return $this.Xml }
    return $event
}
$global:historyFixture=@{Events=@();Queries=[Collections.Generic.List[object]]::new();Oldest=[DateTime]::UtcNow.AddDays(-60);FailMarkers=$false;FailErrors=$false}
function global:Get-WinEvent {
    [CmdletBinding()]
    param([hashtable]$FilterHashtable,[string]$ComputerName,[pscredential]$Credential,[string]$LogName,[switch]$Oldest,[int]$MaxEvents)
    $global:historyFixture.Queries.Add(@{Filter=$FilterHashtable;ComputerName=$ComputerName;Credential=$Credential;Oldest=$Oldest;MaxEvents=$MaxEvents;LogName=$LogName})
    if($Oldest) { return [pscustomobject]@{TimeCreated=$global:historyFixture.Oldest} }
    if($FilterHashtable.ContainsKey('Id') -and $global:historyFixture.FailMarkers) { throw 'Access denied sensitive-fixture-secret' }
    if($FilterHashtable.ContainsKey('Level') -and $global:historyFixture.FailErrors) { throw 'Error lookup failed sensitive-fixture-secret' }
    $matching=@($global:historyFixture.Events | Where-Object {
        $_.TimeCreated -ge $FilterHashtable.StartTime -and $_.TimeCreated -le $FilterHashtable.EndTime -and
        ((-not $FilterHashtable.ContainsKey('Id')) -or $_.Id -in $FilterHashtable.Id) -and
        ((-not $FilterHashtable.ContainsKey('Level')) -or $_.Level -in $FilterHashtable.Level)
    } | Sort-Object TimeCreated -Descending | Select-Object -First $MaxEvents)
    if(-not $matching.Count) {
        $errorRecord=[Management.Automation.ErrorRecord]::new([Exception]::new('No events'),'NoMatchingEventsFound',[Management.Automation.ErrorCategory]::ObjectNotFound,$null)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
    return $matching
}
$secret=ConvertTo-SecureString 'sensitive-fixture-secret' -AsPlainText -Force
$context=@{Credentials=@{ActiveDirectory=[pscredential]::new('fixture-reader',$secret)}}
$adapter=Join-Path $PSScriptRoot 'Invoke-Report.ps1'
try {
    $base=[DateTime]::UtcNow.AddDays(-6)
    $b1=$base.AddDays(1); $b2=$base.AddDays(2); $b3=$base.AddDays(3); $b4=$base.AddDays(4); $b5=$base.AddDays(5); $b6=$b5.AddSeconds(90); $b7=$base.AddDays(5.5)
    $global:historyFixture.Events=@(
        New-HistoryFixture 41 'UnrelatedProvider' $base 1 @{} 1
        New-HistoryFixture 1074 'User32' $b1.AddMinutes(-2) 10 @{param1='updater.exe';param3='Other (Unplanned)';param4='0x0';param5='restart';param7='DOMAIN\Operator'}
        New-HistoryFixture 13 'Microsoft-Windows-Kernel-General' $b1.AddMinutes(-1) 11
        New-HistoryFixture 6006 'EventLog' $b1.AddSeconds(-30) 12
        New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b1 13
        New-HistoryFixture 6005 'EventLog' $b1.AddSeconds(1) 14
        New-HistoryFixture 6009 'EventLog' $b1.AddSeconds(2) 15
        New-HistoryFixture 7 'disk' $b1.AddSeconds(30) 16 @{} 2
        New-HistoryFixture 41 'Microsoft-Windows-Kernel-Power' $b2.AddSeconds(-1) 20 @{BugcheckCode='159'} 1
        New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b2 21
        New-HistoryFixture 6008 'EventLog' $b2.AddSeconds(2) 22 @{} 2
        New-HistoryFixture 1001 'Microsoft-Windows-WER-SystemErrorReporting' $b2.AddSeconds(5) 23 @{} 2
        New-HistoryFixture 1074 'UnrelatedProvider' $b3.AddMinutes(-1) 30
        New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b3 31
        New-HistoryFixture 1074 'User32' $b4.AddMinutes(-1) 40 @{param5='restart'}
        New-HistoryFixture 41 'Microsoft-Windows-Kernel-Power' $b4.AddSeconds(-1) 41 @{} 1
        New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b4 42
        New-HistoryFixture 1074 'User32' $b5.AddSeconds(-30) 50 @{param5='restart'}
        New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b5 51
        New-HistoryFixture 41 'Microsoft-Windows-Kernel-Power' $b6.AddSeconds(-1) 52 @{} 1
        New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b6 53
        New-HistoryFixture 6005 'EventLog' $b7 60
    )
    $result=& $adapter -Parameters @{ComputerName='fixture.invalid';Days=30;MaxRows=50;ErrorWindowMinutes=10} -Context $context
    Assert-History ($result.Records.Count -eq 7) 'Startup markers must deduplicate without merging rapid Kernel starts.'
    $byId=@{}; foreach($record in $result.Records) { $byId[$record.Id]=$record }
    Assert-History ($byId['System:fixture.invalid:13'].Classification -eq 'Intentional') 'Unplanned reason text must still recognize an explicit request.'
    Assert-History ($byId['System:fixture.invalid:13'].RequestedBy -eq 'DOMAIN\Operator' -and $byId['System:fixture.invalid:13'].NearbyErrorCount -eq 1) 'Request XML and nearby errors missing.'
    Assert-History ($byId['System:fixture.invalid:21'].Classification -eq 'Unintentional' -and $byId['System:fixture.invalid:21'].BugcheckCodeDecimal -eq '159') 'Unexpected shutdown and bugcheck fields failed.'
    Assert-History ($byId['System:fixture.invalid:31'].Classification -eq 'Uncertain') 'Wrong-provider event IDs must not establish intent.'
    Assert-History ($byId['System:fixture.invalid:42'].Classification -eq 'Uncertain') 'Conflicting evidence must remain uncertain.'
    Assert-History ($byId['System:fixture.invalid:51'].Classification -eq 'Intentional' -and $byId['System:fixture.invalid:53'].Classification -eq 'Unintentional') 'A restart request must not be reused for the next boot.'
    Assert-History ($byId['System:fixture.invalid:60'].Classification -eq 'Uncertain' -and $result.Records[0].Id -eq 'System:fixture.invalid:60') 'Fallback service starts and newest-first order failed.'
    $errorIds=@($result.Records | ForEach-Object { foreach($nearby in $_.NearbyErrors) { $nearby.RecordId } })
    Assert-History ($errorIds.Count -eq @($errorIds | Select-Object -Unique).Count) 'Nearby error windows overlap.'
    Assert-History (-not $result.Summary.Incomplete -and ($result | ConvertTo-Json -Depth 30) -notmatch 'sensitive-fixture-secret') 'Complete report or credential exclusion failed.'
    foreach($query in $global:historyFixture.Queries) {
        Assert-History ($query.ComputerName -eq 'fixture.invalid' -and $query.Credential.UserName -eq 'fixture-reader') 'Remote session credential not forwarded.'
        Assert-History ($query.LogName -eq 'System' -or $query.Filter.LogName -eq 'System') 'Only System should be queried.'
    }
    $limited=& $adapter -Parameters @{ComputerName='localhost';MaxRows=2} -Context $context
    Assert-History ($limited.Records.Count -eq 2 -and $limited.Summary.OlderRowsOmitted) 'Explicit small-list row limit failed.'
    $lastQuery=$global:historyFixture.Queries[$global:historyFixture.Queries.Count-1]
    Assert-History (-not $lastQuery.Credential -and -not $lastQuery.ComputerName) 'Local reads must use the current Windows identity.'
    $global:historyFixture.FailErrors=$true
    $partial=& $adapter -Parameters @{ComputerName='fixture.invalid'} -Context $context
    Assert-History ($partial.Summary.Incomplete -and $partial.Records[0].ErrorCollectionStatus -eq 'Unavailable' -and ($partial | ConvertTo-Json -Depth 30) -notmatch 'sensitive-fixture-secret') 'Error lookup failure must remain incomplete without leaking exceptions.'
    $global:historyFixture.FailErrors=$false
    $global:historyFixture.Oldest=[DateTime]::UtcNow.AddDays(-2)
    $retained=& $adapter -Parameters @{ComputerName='localhost'} -Context $context
    Assert-History $retained.Summary.Incomplete 'Rolled-over history must be marked partial.'
    $global:historyFixture.Oldest=[DateTime]::UtcNow.AddDays(-60)
    $global:historyFixture.Events=@()
    $empty=& $adapter -Parameters @{ComputerName='localhost'} -Context $context
    Assert-History ($empty.Records.Count -eq 0 -and $empty.Summary.RowsReturned -eq 0) 'NoMatchingEventsFound must be handled as an empty query.'
    $global:historyFixture.FailMarkers=$true
    $blocked=$false
    try { & $adapter -Parameters @{ComputerName='fixture.invalid'} -Context $context } catch { $blocked=$true }
    Assert-History $blocked 'Access failures must never become successful empty history.'
    $global:historyFixture.FailMarkers=$false
    $global:historyFixture.Events=@(New-HistoryFixture 1001 'Microsoft-Windows-WER-SystemErrorReporting' $b1 105 @{} 2)
    $bugcheckOnly=& $adapter -Parameters @{ComputerName='localhost'} -Context $context
    Assert-History ($bugcheckOnly.Records.Count -eq 1 -and $bugcheckOnly.Records[0].Classification -eq 'Unintentional' -and $bugcheckOnly.Records[0].StartupEvidence -match 'Fallback') 'A standalone reboot bugcheck must remain visible as fallback evidence.'
    foreach($invalid in @(@{Days=0},@{MaxRows=501},@{ErrorWindowMinutes=61},@{ComputerName='server;Restart-Computer'})) {
        $blocked=$false
        try { & $adapter -Parameters $invalid -Context $context } catch { $blocked=$true }
        Assert-History $blocked 'Invalid scope input was accepted.'
    }
    $recent=[DateTime]::UtcNow.AddMinutes(-1)
    $global:historyFixture.Events=@(New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $recent 101)
    $active=& $adapter -Parameters @{ComputerName='localhost'} -Context $context
    Assert-History ($active.Summary.Incomplete -and $active.Records[0].ErrorCollectionStatus -eq 'Window still in progress') 'Newest unfinished error window must be partial.'
    $global:historyFixture.Events=@(New-HistoryFixture 12 'Microsoft-Windows-Kernel-General' $b1 101)
    $global:historyFixture.Events+=@(1..101 | ForEach-Object { New-HistoryFixture 7 'disk' $b1.AddSeconds($_) (200+$_) @{} 2 })
    $truncated=& $adapter -Parameters @{ComputerName='localhost'} -Context $context
    Assert-History ($truncated.Summary.Incomplete -and $truncated.Records[0].ErrorCollectionStatus -eq 'Truncated' -and $truncated.Records[0].NearbyErrorCount -eq 100 -and $truncated.Records[0].ErrorStatus -match 'Truncated') 'Error detail cap failed.'
    $global:historyFixture.Events=@(1..20001 | ForEach-Object { New-HistoryFixture 12 'UnrelatedProvider' $b1.AddMilliseconds($_) $_ })
    $capped=& $adapter -Parameters @{ComputerName='localhost'} -Context $context
    Assert-History ($capped.Summary.Incomplete -and $capped.Summary.CoverageNotes -match '20,000' -and $capped.Records.Count -eq 0) 'Lifecycle cap must be partial without classifying unrelated providers.'
    'PASS: reboot history mock checks: intent, unexpected/conflicting/missing evidence, provider checks, deduplication, rapid boots, credential reuse, bounded errors, limits, retention, empty/access failure and incomplete windows. No machine was queried or restarted.'
} finally {
    Remove-Item Function:\Get-WinEvent -ErrorAction SilentlyContinue
    Remove-Variable historyFixture -Scope Global -ErrorAction SilentlyContinue
    $secret.Dispose()
}
