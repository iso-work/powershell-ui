[CmdletBinding()]
param([Parameter(Mandatory)][string]$Name, [switch]$Uppercase)
$message="Hello, $Name!"
if($Uppercase) { $message=$message.ToUpperInvariant() }
$message
