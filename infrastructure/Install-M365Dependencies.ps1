#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
# Explicit local setup only. This never authenticates or changes tenant resources.
$packages=@{
 'Microsoft.Graph.Authentication'='2.41.2'
 'ExchangeOnlineManagement'='3.10.1'
 'Az.Accounts'='3.0.0'
 'Microsoft.Online.SharePoint.PowerShell'='16.0.27709.12000'
}
$repository=Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if(-not $repository){Register-PSRepository -Default;$repository=Get-PSRepository -Name PSGallery}
if($repository.SourceLocation -notmatch '^https://www\.powershellgallery\.com/api/v2/?$'){throw 'PSGallery source must be the official HTTPS gallery.'}
foreach($name in $packages.Keys){
    if(-not @(Get-Module -ListAvailable -Name $name | Where-Object Version -eq ([version]$packages[$name])).Count){
        Install-Module -Name $name -RequiredVersion $packages[$name] -Repository PSGallery -Scope CurrentUser -Force -AcceptLicense -ErrorAction Stop
    }
}
# SPO's Windows PowerShell compatibility session must be able to find its module.
$windowsModules=Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
$spoVersion=Join-Path $windowsModules ('Microsoft.Online.SharePoint.PowerShell\'+$packages['Microsoft.Online.SharePoint.PowerShell'])
if(-not (Test-Path -LiteralPath $spoVersion)){
    Save-Module -Name Microsoft.Online.SharePoint.PowerShell -RequiredVersion $packages['Microsoft.Online.SharePoint.PowerShell'] -Repository PSGallery -Path $windowsModules -AcceptLicense -Force
}
'Pinned local Microsoft 365 modules are installed. No Microsoft 365 login or tenant change was performed.'
