#requires -Version 7.0
[CmdletBinding()]
param([Parameter(Mandatory)][hashtable]$Parameters,[Parameter(Mandatory)][hashtable]$Context)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$computer=([string]$Parameters['ComputerName']).Trim()
if(-not $computer) { $computer='localhost' }
if($computer.Length -gt 253 -or $computer -notmatch '^(?:\.|[a-zA-Z0-9][a-zA-Z0-9._:-]*)$') { throw 'Enter one Windows computer name, DNS name or IP address.' }
function Read-HistoryInteger([string]$Name,[int]$Default,[int]$Maximum) {
    if(-not $Parameters.ContainsKey($Name)) { return $Default }
    $value=0
    if(-not [int]::TryParse([string]$Parameters[$Name],[ref]$value) -or $value -lt 1 -or $value -gt $Maximum) { throw "$Name must be between 1 and $Maximum." }
    return $value
}
$days=Read-HistoryInteger 'Days' 30 3650
$maxRows=Read-HistoryInteger 'MaxRows' 50 500
$minutes=Read-HistoryInteger 'ErrorWindowMinutes' 10 60
$now=[DateTime]::UtcNow; $start=$now.AddDays(-$days)
$connection=@{ErrorAction='Stop'}
$isLocal=$computer -in @('.','localhost',$env:COMPUTERNAME,[Environment]::MachineName)
$authentication='Current Windows identity'
if(-not $isLocal) {
    $connection.ComputerName=$computer
    if($Context.ContainsKey('Credentials') -and $Context.Credentials.ContainsKey('ActiveDirectory')) {
        if($Context.Credentials.ActiveDirectory -isnot [pscredential]) { throw 'The Directory account credential must be a PSCredential.' }
        $connection.Credential=$Context.Credentials.ActiveDirectory
        $authentication='Directory account from launcher session'
    }
}
function Send-HistoryProgress([string]$Text) {
    if($Context.ContainsKey('Progress')) { $Context.Progress.Enqueue($Text) }
}
function Read-SystemEvents([hashtable]$Filter,[int]$Limit) {
    try { Get-WinEvent @connection -FilterHashtable $Filter -MaxEvents $Limit }
    catch {
        # An empty successful query has a specific PowerShell error. Access/RPC failures must propagate.
        if(-not $_.FullyQualifiedErrorId.StartsWith('NoMatchingEventsFound',[StringComparison]::Ordinal)) { throw }
    }
}
function Get-HistoryValue($Object,[string]$Name) {
    $property=$Object.PSObject.Properties[$Name]
    if($null -ne $property) { return $property.Value }
    return $null
}
function ConvertTo-HistoryEvent($Event) {
    try {
        $data=@{}; $message=''
        try {
            $xml=[xml]$Event.ToXml()
            foreach($node in $xml.SelectNodes("/*[local-name()='Event']/*[local-name()='EventData']/*[local-name()='Data']")) {
                $name=$node.GetAttribute('Name')
                if($name) { $data[$name]=$node.InnerText }
            }
        } catch {}
        try { $message=[string]$Event.Message } catch { $message='Message text unavailable; use provider and event ID.' }
        if($message.Length -gt 2000) { $message=$message.Substring(0,2000)+' [truncated]' }
        [pscustomobject]@{
            Id=[int]$Event.Id; Provider=[string]$Event.ProviderName; RecordId=[long]$Event.RecordId
            Time=([DateTime]$Event.TimeCreated).ToUniversalTime(); Level=Get-HistoryValue $Event 'Level'
            Machine=[string](Get-HistoryValue $Event 'MachineName'); Message=$message; Data=$data
        }
    } finally { if($Event -is [IDisposable]) { $Event.Dispose() } }
}
function Get-LifecycleKind($Event) {
    switch($Event.Provider) {
        'Microsoft-Windows-Kernel-General' { if($Event.Id -eq 12){return 'Boot'}; if($Event.Id -eq 13){return 'CleanShutdown'} }
        'Microsoft-Windows-Kernel-Power' { if($Event.Id -eq 41){return 'Unexpected'} }
        'User32' { if($Event.Id -eq 1074){return 'Request'} }
        'Microsoft-Windows-User32' { if($Event.Id -eq 1074){return 'Request'} }
        'EventLog' {
            if($Event.Id -eq 6008){return 'Unexpected'}
            if($Event.Id -in @(6005,6009)){return 'StartupHint'}
            if($Event.Id -eq 6006){return 'CleanShutdown'}
        }
        'Microsoft-Windows-WER-SystemErrorReporting' { if($Event.Id -eq 1001){return 'Bugcheck'} }
    }
    return 'Other'
}
function Get-HistoryEvidence($Event) {
    # Preserve bounded message text and a small allowlist of fields, not arbitrary event XML.
    $selected=[ordered]@{}
    foreach($name in @('param1','param2','param3','param4','param5','param6','param7','BugcheckCode','BugcheckParameter1','BugcheckParameter2','BugcheckParameter3','BugcheckParameter4','PowerButtonTimestamp')) {
        if($Event.Data.ContainsKey($name)) { $value=[string]$Event.Data[$name]; $selected[$name]=$value.Substring(0,[Math]::Min($value.Length,2000)) }
    }
    [pscustomobject][ordered]@{
        EventId=$Event.Id; Provider=$Event.Provider; RecordId=$Event.RecordId
        TimeUtc=$Event.Time.ToString('o'); Level=$Event.Level; Message=$Event.Message
        Fields=[pscustomobject]$selected
    }
}

Send-HistoryProgress "Reading System log reboot history from $computer."
$incomplete=$false; $coverageNotes=[Collections.Generic.List[string]]::new()
$earliest=$null
try {
    $first=@(Get-WinEvent @connection -LogName 'System' -Oldest -MaxEvents 1)
    if($first.Count) {
        try { $earliest=([DateTime]$first[0].TimeCreated).ToUniversalTime() }
        finally { if($first[0] -is [IDisposable]) { $first[0].Dispose() } }
    }
} catch { $incomplete=$true; $coverageNotes.Add('Could not establish the oldest retained System event. History coverage is unknown.') }
if($null -ne $earliest -and $earliest -gt $start) {
    $incomplete=$true; $coverageNotes.Add('The oldest retained System event is newer than the requested start. Earlier history may have rolled over or been cleared.')
}
$markerLimit=20000
$events=@(Read-SystemEvents @{LogName='System';Id=@(12,13,41,1001,1074,6005,6006,6008,6009);StartTime=$start.AddDays(-1);EndTime=$now} ($markerLimit+1) | ForEach-Object { ConvertTo-HistoryEvent $_ })
if($events.Count -gt $markerLimit) {
    $incomplete=$true; $coverageNotes.Add('The lifecycle event query reached its 20,000-event limit. Older markers were omitted.')
    $events=@($events | Select-Object -First $markerLimit)
}
$events=@($events | Sort-Object Time,RecordId)
foreach($event in $events) { $event | Add-Member NoteProperty Kind (Get-LifecycleKind $event) }
$markers=@($events | Where-Object Kind -ne 'Other')
$anchors=[Collections.Generic.List[object]]::new()
foreach($event in @($markers | Where-Object Kind -eq 'Boot')) {
    $anchors.Add([pscustomobject]@{Time=$event.Time;RecordId=$event.RecordId;Confirmed=$true;Events=[Collections.Generic.List[object]]::new()})
}
function Find-HistoryNearest($Items,[DateTime]$Time) {
    if(-not $Items.Count) { return $null }
    $low=0; $high=$Items.Count-1
    while($low -le $high) {
        $middle=[int][Math]::Floor(($low+$high)/2)
        if($Items[$middle].Time -lt $Time) { $low=$middle+1 } else { $high=$middle-1 }
    }
    $best=$null; $distance=[double]::MaxValue
    foreach($candidate in @($high,$low)) {
        if($candidate -ge 0 -and $candidate -lt $Items.Count) {
            $delta=[Math]::Abs(($Items[$candidate].Time-$Time).TotalSeconds)
            if($delta -lt $distance) { $best=$Items[$candidate]; $distance=$delta }
        }
    }
    if($distance -le $minutes*60) { return $best }
    return $null
}
# Kernel starts are never merged, even when two real restarts occur close together.
# If they are absent, weaker startup markers create explicitly unconfirmed rows.
$fallback=[Collections.Generic.List[object]]::new()
foreach($event in @($markers | Where-Object { $_.Kind -in @('Unexpected','StartupHint','Bugcheck') })) {
    $near=Find-HistoryNearest $anchors $event.Time
    if($null -eq $near -and ($fallback.Count -eq 0 -or ($event.Time-$fallback[$fallback.Count-1].Time).TotalMinutes -gt $minutes)) {
        $fallback.Add([pscustomobject]@{Time=$event.Time;RecordId=$event.RecordId;Confirmed=$false;Events=[Collections.Generic.List[object]]::new()})
    }
}
$anchors=@((@($anchors)+@($fallback)) | Sort-Object Time,RecordId)
$anchorsByRecord=@{}
foreach($anchor in $anchors) { $anchorsByRecord[$anchor.RecordId]=$anchor }
# Assign each startup marker once to the nearest start, with a bounded time window.
foreach($event in @($markers | Where-Object { $_.Kind -in @('Boot','Unexpected','StartupHint','Bugcheck') })) {
    $nearest=Find-HistoryNearest $anchors $event.Time
    if($event.Kind -eq 'Boot') { $nearest=$anchorsByRecord[$event.RecordId] }
    if($null -ne $nearest) { $nearest.Events.Add($event) }
}
$selected=@($anchors | Where-Object {$_.Time -ge $start -and $_.Time -le $now} | Sort-Object Time -Descending | Select-Object -First $maxRows)
$rows=[Collections.Generic.List[object]]::new()
foreach($anchor in $selected) {
    $index=[Array]::IndexOf($anchors,$anchor)
    $previous=if($index -gt 0){$anchors[$index-1].Time}else{$null}
    $next=if($index -lt $anchors.Count-1){$anchors[$index+1].Time}else{$null}
    $before=$anchor.Time.AddDays(-1)
    if($null -ne $previous -and $previous -gt $before) { $before=$previous }
    $prior=@($markers | Where-Object { $_.Time -gt $before -and $_.Time -lt $anchor.Time -and $_.Kind -in @('Request','CleanShutdown') })
    $request=@($prior | Where-Object Kind -eq 'Request' | Sort-Object Time -Descending | Select-Object -First 1)
    $clean=@($prior | Where-Object Kind -eq 'CleanShutdown')
    $unexpected=@($anchor.Events | Where-Object { $_.Kind -in @('Unexpected','Bugcheck') })
    $classification='Uncertain'
    $reason='No explicit restart request or unexpected shutdown marker was correlated with this startup.'
    if($unexpected.Count -and $request.Count) { $reason='A restart or shutdown was requested, but Windows also recorded an unexpected shutdown or bugcheck. Intent and shutdown outcome conflict.' }
    elseif($unexpected.Count) { $classification='Unintentional'; $reason='Windows recorded an unexpected shutdown or bugcheck. This does not establish its root cause or human intent.' }
    elseif($request.Count -and $anchor.Confirmed) { $classification='Intentional'; $reason='Windows recorded an explicit user or process shutdown/restart request before this operating-system start.' }
    elseif(-not $anchor.Confirmed) { $reason='Only fallback startup markers are available. An Event Log service start alone does not prove a machine restart.' }
    if($clean.Count -and -not $request.Count -and -not $unexpected.Count) { $reason+=' Clean shutdown evidence is present, but intentionality is not established.' }
    $errorStart=$anchor.Time.AddMinutes(-$minutes); $errorEnd=$anchor.Time.AddMinutes($minutes)
    # Midpoints prevent overlapping error windows from counting an event twice for rapid boots.
    if($null -ne $previous) { $mid=$previous.AddTicks([long](($anchor.Time-$previous).Ticks/2)); if($mid -gt $errorStart){$errorStart=$mid} }
    if($null -ne $next) { $mid=$anchor.Time.AddTicks([long](($next-$anchor.Time).Ticks/2)); if($mid -lt $errorEnd){$errorEnd=$mid.AddTicks(-1)} }
    if($errorEnd -gt $now) { $errorEnd=$now }
    $errorStatus='Complete'; $nearby=@()
    try {
        $nearby=@(Read-SystemEvents @{LogName='System';Level=@(1,2);StartTime=$errorStart;EndTime=$errorEnd} 101 | ForEach-Object { ConvertTo-HistoryEvent $_ })
        if($nearby.Count -gt 100) { $nearby=@($nearby | Select-Object -First 100); $errorStatus='Truncated'; $incomplete=$true }
    } catch { $errorStatus='Unavailable'; $incomplete=$true }
    if($anchor.Time.AddMinutes($minutes) -gt $now -and $null -eq $next) {
        $errorStatus=if($errorStatus -eq 'Complete'){'Window still in progress'}else{$errorStatus}
        $incomplete=$true
    }
    $errorState=if($nearby.Count) {
        if($errorStatus -eq 'Complete'){'Errors recorded nearby'}else{"Errors recorded nearby; $errorStatus"}
    } elseif($errorStatus -ne 'Complete') {'Unknown or incomplete'} else {'None recorded in checked System window'}
    $evidence=@($anchor.Events)+$prior
    $requestData=if($request.Count){$request[0].Data}else{@{}}
    $bugcheck=@($anchor.Events | Where-Object { $_.Provider -eq 'Microsoft-Windows-Kernel-Power' -and $_.Data.ContainsKey('BugcheckCode') } | Select-Object -First 1)
    $bugcheckCode=if($bugcheck.Count){[string]$bugcheck[0].Data.BugcheckCode}else{''}
    $rows.Add([pscustomobject][ordered]@{
        Computer=$computer; StartedUtc=$anchor.Time.ToString('o'); Classification=$classification
        ErrorStatus=$errorState; NearbyErrorCount=$nearby.Count
        RequestedBy=[string]$requestData['param7']; InitiatingProcess=[string]$requestData['param1']
        RequestedAction=[string]$requestData['param5']; WindowsReason=[string]$requestData['param3']
        ReasonCode=[string]$requestData['param4']; BugcheckCodeDecimal=$bugcheckCode
        Explanation=$reason; StartupEvidence=$(if($anchor.Confirmed){'Kernel-General 12: OS start'}else{'Fallback: startup time is approximate'})
        Id=('System:{0}:{1}' -f $computer,$anchor.RecordId)
        ErrorCollectionStatus=$errorStatus; ErrorWindowStartUtc=$errorStart.ToString('o'); ErrorWindowEndUtc=$errorEnd.ToString('o')
        Evidence=@($evidence | Sort-Object Time,RecordId -Unique | ForEach-Object { Get-HistoryEvidence $_ })
        NearbyErrors=@($nearby | Sort-Object Time,RecordId | ForEach-Object { Get-HistoryEvidence $_ })
    })
}
$counts=[ordered]@{}
foreach($label in @('Intentional','Unintentional','Uncertain')) { $counts[$label]=@($rows | Where-Object Classification -eq $label).Count }
$matchingCount=@($anchors | Where-Object {$_.Time -ge $start -and $_.Time -le $now}).Count
[pscustomobject]@{
    Summary=[pscustomobject][ordered]@{
        Report='Windows reboot history';ReadOnly=$true;Computer=$computer;FromUtc=$start.ToString('o');ToUtc=$now.ToString('o')
        Authentication=$authentication;RowsReturned=$rows.Count;StartsDetected=$matchingCount;RowLimit=$maxRows
        OlderRowsOmitted=($matchingCount -gt $maxRows);Classifications=[pscustomobject]$counts
        OldestRetainedSystemEventUtc=$(if($null -ne $earliest){$earliest.ToString('o')}else{$null})
        Incomplete=$incomplete;CoverageNotes=@($coverageNotes)
    }
    Records=@($rows)
    Limitations=@(
        'Rows represent Windows starts, which may be reboots or power-on after shutdown. Sleep/resume and Fast Startup do not always produce equivalent events.',
        'Intentional means a recorded user/process request, including automatic update requests. The Windows Planned/Unplanned reason label is not a measure of human intent.',
        'Unintentional means unexpected shutdown evidence. A forced human power-off can produce the same evidence; event 41 alone cannot identify a root cause.',
        'Conflicting or missing evidence is Uncertain. A fallback Event Log service start alone is not a confirmed reboot.',
        "Lifecycle evidence is matched by provider, time and record ID. Startup markers use the nearest start within $minutes minutes; preceding shutdown requests use up to 24 hours, bounded by the previous start. These are correlation heuristics.",
        "Only System-log Critical/Error events within $minutes minutes before and after each start are checked. Windows are split between close starts. They are temporal context, not proof of causation; Application, Security, warnings and crash dumps are not collected.",
        'A 6008 timestamp is when the previous unexpected shutdown was reported, not its actual failure time. The report does not guess that localized failure timestamp.',
        'History depends on retained logs and read permissions. Empty results and no nearby errors do not establish a healthy or reboot-free system.',
        'The newest 50 rows are shown by default; increase MaxRows up to 500. Lifecycle queries are capped at 20,000 events and error detail at 100 per row. Truncated/failed queries produce a Partial report.',
        'UTC timestamps avoid assuming that the target shares the launcher timezone. Clock changes, slow startup, long downtime or missing markers can affect correlation.',
        'This adapter only calls Get-WinEvent on the target. It never restarts machines, clears logs, enables remote access or changes configuration.'
    )+@($coverageNotes)
}
