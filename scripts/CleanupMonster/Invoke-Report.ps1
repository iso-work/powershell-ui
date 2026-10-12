#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [hashtable] $Parameters,
    [Parameter(Mandatory = $true)]
    [hashtable] $Context
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# This adapter deliberately does not import CleanupMonster or call any cleanup cmdlet.
# The copied upstream repository is reference material, not an executable entry point.
$server = [string] $Parameters['Server']
if ([string]::IsNullOrWhiteSpace($server)) {
    throw 'Enter the Active Directory domain or domain controller in Server.'
}
$inactiveDays = 90
if ($Parameters.ContainsKey('InactiveDays') -and $null -ne $Parameters['InactiveDays']) {
    $parsedDays = 0
    if (-not [int]::TryParse([string] $Parameters['InactiveDays'], [ref] $parsedDays) -or $parsedDays -lt 1 -or $parsedDays -gt 36500) {
        throw 'InactiveDays must be a whole number between 1 and 36500.'
    }
    $inactiveDays = $parsedDays
}
$includeDisabled = $false
if ($Parameters.ContainsKey('IncludeDisabled') -and $null -ne $Parameters['IncludeDisabled']) {
    if ($Parameters['IncludeDisabled'] -is [bool]) {
        $includeDisabled = $Parameters['IncludeDisabled']
    } elseif (-not [bool]::TryParse([string] $Parameters['IncludeDisabled'], [ref] $includeDisabled)) {
        throw 'IncludeDisabled must be true or false.'
    }
}

if (-not (Get-Command -Name Get-ADComputer -ErrorAction SilentlyContinue)) {
    Import-Module ActiveDirectory -ErrorAction Stop
}

$query = @{
    Server = $server.Trim()
    Filter = 'Enabled -eq $true'
    Properties = @(
        'lastLogonTimestamp', 'PasswordLastSet', 'whenCreated',
        'OperatingSystem', 'OperatingSystemVersion', 'DNSHostName',
        'ProtectedFromAccidentalDeletion', 'userAccountControl'
    )
    ErrorAction = 'Stop'
}
if ($includeDisabled) { $query['Filter'] = '*' }
$searchBase = [string] $Parameters['SearchBase']
if (-not [string]::IsNullOrWhiteSpace($searchBase)) { $query['SearchBase'] = $searchBase.Trim() }
$authentication = 'Current Windows identity'
if ($Context.ContainsKey('Credentials') -and $null -ne $Context['Credentials']) {
    $credentials = $Context['Credentials']
    if ($credentials.ContainsKey('ActiveDirectory') -and $null -ne $credentials['ActiveDirectory']) {
        if ($credentials['ActiveDirectory'] -isnot [System.Management.Automation.PSCredential]) {
            throw 'The ActiveDirectory session credential must be a PSCredential.'
        }
        $query['Credential'] = $credentials['ActiveDirectory']
        $authentication = 'Launcher session credential: ActiveDirectory'
    }
}

$asOf = [DateTime]::UtcNow
$cutoff = $asOf.AddDays(-$inactiveDays)

function Get-AuditProperty {
    param([object] $InputObject, [string] $Name)
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $null
}

function ConvertTo-AuditUtc {
    param([object] $Value)
    if ($null -eq $Value) { return $null }
    try { return ([DateTime] $Value).ToUniversalTime() } catch { return $null }
}

function Format-AuditUtc {
    param([object] $Value)
    if ($null -eq $Value) { return $null }
    return ([DateTime] $Value).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
}

# Get-ADComputer is the only command in this adapter that queries the target directory.
# With ErrorAction Stop, query failures cannot be mistaken for a complete empty inventory.
$computers = @(Get-ADComputer @query)
$records = @(
    foreach ($computer in $computers) {
        $lastLogon = $null
        $rawTimestamp = Get-AuditProperty -InputObject $computer -Name 'lastLogonTimestamp'
        if ($null -ne $rawTimestamp) {
            try {
                if ([long] $rawTimestamp -gt 0) { $lastLogon = [DateTime]::FromFileTimeUtc([long] $rawTimestamp) }
            } catch { $lastLogon = $null }
        }
        $passwordLastSet = ConvertTo-AuditUtc (Get-AuditProperty $computer 'PasswordLastSet')
        $created = ConvertTo-AuditUtc (Get-AuditProperty $computer 'whenCreated')
        $enabled = Get-AuditProperty $computer 'Enabled'
        $protected = Get-AuditProperty $computer 'ProtectedFromAccidentalDeletion'
        $accountControl = Get-AuditProperty $computer 'userAccountControl'
        $isDomainController = $null
        if ($null -ne $accountControl) { $isDomainController = (([long] $accountControl -band 8192) -ne 0) }

        $assessment = 'UnknownActivity'
        $reason = 'A required activity timestamp is unavailable; inactivity cannot be established.'
        if ($isDomainController -eq $true) {
            $assessment = 'ExcludedDomainController'
            $reason = 'Domain controller account; excluded from inactivity review candidates.'
        } elseif ($null -eq $enabled -or $null -eq $isDomainController) {
            $reason = 'Account enabled state or domain controller classification is unavailable.'
        } elseif ($enabled -eq $false) {
            $assessment = 'Disabled'
            $reason = 'Already disabled; included for inventory only.'
        } elseif (($null -ne $lastLogon -and $lastLogon -gt $asOf) -or ($null -ne $passwordLastSet -and $passwordLastSet -gt $asOf) -or ($null -ne $created -and $created -gt $asOf)) {
            $reason = 'A directory timestamp is in the future; investigate clock or data quality before interpreting inactivity.'
        } elseif (($null -ne $lastLogon -and $lastLogon -ge $cutoff) -or ($null -ne $passwordLastSet -and $passwordLastSet -ge $cutoff) -or ($null -ne $created -and $created -ge $cutoff)) {
            $assessment = 'RecentActivity'
            $reason = 'A recorded logon, password update, or object creation is within the review period.'
        } elseif ($null -ne $lastLogon -and $null -ne $passwordLastSet -and $null -ne $created) {
            if ($null -eq $protected) {
                $reason = 'Activity timestamps are old, but accidental-deletion protection state is unavailable.'
            } elseif ($protected -eq $true) {
                $assessment = 'ProtectedReview'
                $reason = 'Activity and creation timestamps are older than the review period; account is protected from accidental deletion.'
            } else {
                $assessment = 'ReviewCandidate'
                $reason = 'Recorded logon, password update, and creation are older than the review period. This is evidence for manual review, not proof that the computer is unused.'
            }
        }

        [PSCustomObject] [ordered] @{
            Name = [string] (Get-AuditProperty $computer 'Name')
            SamAccountName = [string] (Get-AuditProperty $computer 'SamAccountName')
            DNSHostName = [string] (Get-AuditProperty $computer 'DNSHostName')
            ObjectGuid = [string] (Get-AuditProperty $computer 'ObjectGUID')
            DistinguishedName = [string] (Get-AuditProperty $computer 'DistinguishedName')
            Enabled = $enabled
            IsDomainController = $isDomainController
            ProtectedFromAccidentalDeletion = $protected
            OperatingSystem = [string] (Get-AuditProperty $computer 'OperatingSystem')
            OperatingSystemVersion = [string] (Get-AuditProperty $computer 'OperatingSystemVersion')
            LastLogonTimestampUtc = Format-AuditUtc $lastLogon
            LastLogonAgeDays = $(if ($null -ne $lastLogon) { [Math]::Floor(($asOf - $lastLogon).TotalDays) } else { $null })
            PasswordLastSetUtc = Format-AuditUtc $passwordLastSet
            PasswordAgeDays = $(if ($null -ne $passwordLastSet) { [Math]::Floor(($asOf - $passwordLastSet).TotalDays) } else { $null })
            CreatedUtc = Format-AuditUtc $created
            Assessment = $assessment
            Reason = $reason
        }
    }
)
$counts = [ordered] @{}
foreach ($assessmentName in @('ReviewCandidate', 'RecentActivity', 'UnknownActivity', 'Disabled', 'ExcludedDomainController', 'ProtectedReview')) {
    $counts[$assessmentName] = @($records | Where-Object { $_.Assessment -eq $assessmentName }).Count
}

[PSCustomObject] @{
    Summary = [PSCustomObject] [ordered] @{
        Report = 'Active Directory computer hygiene audit'
        ReadOnly = $true
        AsOfUtc = Format-AuditUtc $asOf
        Server = $server.Trim()
        SearchBase = $(if ($query.ContainsKey('SearchBase')) { $query['SearchBase'] } else { 'Default naming context for the selected server' })
        InactiveDays = $inactiveDays
        IncludeDisabled = $includeDisabled
        Authentication = $authentication
        ComputerCount = $records.Count
        AssessmentCounts = [PSCustomObject] $counts
        DirectoryChanges = 0
    }
    Records = $records
    Limitations = @(
        'This is a separate read-only inventory adapter inspired by CleanupMonster. It does not run the upstream cleanup workflows or reproduce every upstream selection rule.',
        'lastLogonTimestamp is replicated and updated on an interval governed by msDS-LogonTimeSyncInterval. It is approximate, not the latest logon across all domain controllers.',
        'PasswordLastSet and whenCreated provide corroborating context, not proof of use or abandonment. Missing timestamps are unknown, not stale.',
        'Only the selected server/domain naming context and optional SearchBase are queried. This is not an automatic whole-forest, Entra, Intune, or Jamf inventory.',
        'Results depend on the account read permissions and the selected domain controller. Protected accounts and domain controllers are never ordinary review candidates.',
        'No account is disabled, moved, deleted, modified, or tested with a cleanup command. The launcher alone writes the requested local report files.'
    )
}
