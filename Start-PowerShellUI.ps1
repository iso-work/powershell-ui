[CmdletBinding()]
param([string]$ScriptsRoot=$PSScriptRoot,[string]$OutputRoot=(Join-Path $PSScriptRoot 'reports'),[switch]$VerifyUi,[string]$PreviewPath)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7 -or $env:OS -ne 'Windows_NT'){throw 'Use PowerShell 7 on Windows.'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
foreach($module in @('Catalog','Launcher','Presentation')){Import-Module (Join-Path $PSScriptRoot "infrastructure/$module.psm1") -Force}
[void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2)
[Windows.Forms.Application]::EnableVisualStyles()
$script:session=New-LauncherSession
$script:worker=$null;$script:job=$null;$script:action='';$script:catalog=@();$script:inputs=@{};$script:lastReport=$null
$ink=[Drawing.ColorTranslator]::FromHtml('#173454');$accent=[Drawing.ColorTranslator]::FromHtml('#176B87')
$form=[Windows.Forms.Form]::new();$form.Text='Microsoft 365 reader';$form.Size=[Drawing.Size]::new(1320,930);$form.MinimumSize=[Drawing.Size]::new(1080,760);$form.StartPosition='CenterScreen';$form.Font=[Drawing.Font]::new('Segoe UI',11)
$layout=[Windows.Forms.TableLayoutPanel]::new();$layout.Dock='Fill';$layout.Padding=[Windows.Forms.Padding]::new(18);$layout.RowCount=3;$layout.ColumnCount=1
[void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
foreach($height in @(100,-1,115)){[void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new($(if($height -lt 0){[Windows.Forms.SizeType]::Percent}else{[Windows.Forms.SizeType]::Absolute}),$(if($height -lt 0){100}else{$height})))}
$form.Controls.Add($layout)
$header=[Windows.Forms.TableLayoutPanel]::new();$header.Dock='Fill';$header.ColumnCount=2
[void]$header.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,48));[void]$header.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,52))
$title=[Windows.Forms.Label]::new();$title.Text='Microsoft 365 reader';$title.Font=[Drawing.Font]::new('Segoe UI',23,[Drawing.FontStyle]::Bold);$title.ForeColor=$ink;$title.Dock='Fill'
$identity=[Windows.Forms.Label]::new();$identity.Dock='Fill';$identity.TextAlign='TopRight';$identity.Font=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold);$identity.Text='Not logged in'
$header.Controls.Add($title,0,0);$header.Controls.Add($identity,1,0);$layout.Controls.Add($header,0,0)
$split=[Windows.Forms.SplitContainer]::new();$split.Dock='Fill';$split.Size=[Drawing.Size]::new(1240,650);$split.SplitterDistance=280;$split.Panel1MinSize=220;$split.Panel2MinSize=600;$layout.Controls.Add($split,0,1)
$library=[Windows.Forms.TableLayoutPanel]::new();$library.Dock='Fill';$library.RowCount=5;$library.ColumnCount=1
foreach($height in @(32,-1,44,44,44)){[void]$library.RowStyles.Add([Windows.Forms.RowStyle]::new($(if($height -lt 0){[Windows.Forms.SizeType]::Percent}else{[Windows.Forms.SizeType]::Absolute}),$(if($height -lt 0){100}else{$height})))}
$libraryLabel=[Windows.Forms.Label]::new();$libraryLabel.Text='MICROSOFT 365 REPORTS';$libraryLabel.AutoSize=$true;$libraryLabel.ForeColor=$ink
$list=[Windows.Forms.ListBox]::new();$list.Dock='Fill';$list.DisplayMember='DisplayName';$list.IntegralHeight=$false
function New-Button([string]$Text){$button=[Windows.Forms.Button]::new();$button.Text=$Text;$button.Height=36;$button.Width=230;$button.FlatStyle='Flat';$button.Margin=[Windows.Forms.Padding]::new(3);return $button}
$login=New-Button 'Login to 365';$login.Dock='Fill';$login.BackColor=$accent;$login.ForeColor=[Drawing.Color]::White
$logout=New-Button 'Logout / clear session';$logout.Dock='Fill'
$refresh=New-Button 'Refresh report library';$refresh.Dock='Fill'
$library.Controls.Add($libraryLabel,0,0);$library.Controls.Add($list,0,1);$library.Controls.Add($login,0,2);$library.Controls.Add($logout,0,3);$library.Controls.Add($refresh,0,4);$split.Panel1.Controls.Add($library)
$tabs=[Windows.Forms.TabControl]::new();$tabs.Dock='Fill';$split.Panel2.Controls.Add($tabs)
$loginTab=[Windows.Forms.TabPage]::new('Login to 365');$guideTab=[Windows.Forms.TabPage]::new('Purpose and directions');$parametersTab=[Windows.Forms.TabPage]::new('Parameters');$directionsTab=[Windows.Forms.TabPage]::new('Full directions');$reportTab=[Windows.Forms.TabPage]::new('Report');$tableTab=[Windows.Forms.TabPage]::new('Record table');$jsonTab=[Windows.Forms.TabPage]::new('JSON')
foreach($page in @($loginTab,$guideTab,$parametersTab,$directionsTab,$reportTab,$tableTab,$jsonTab)){$page.Padding=[Windows.Forms.Padding]::new(16);$page.BackColor=[Drawing.Color]::White;$tabs.TabPages.Add($page)}
$loginFields=[Windows.Forms.FlowLayoutPanel]::new();$loginFields.Dock='Fill';$loginFields.FlowDirection='TopDown';$loginFields.WrapContents=$false;$loginFields.AutoScroll=$true;$loginTab.Controls.Add($loginFields)
$loginHelp=[Windows.Forms.Label]::new();$loginHelp.Text='Please login to 365. Choose your work account in the Microsoft window. Reports unlock only after your username, tenant ID and organization details are discovered and saved in memory.';$loginHelp.AutoSize=$true;$loginHelp.MaximumSize=[Drawing.Size]::new(680,0)
$signIn=New-Button 'Login to 365';$signIn.BackColor=$accent;$signIn.ForeColor=[Drawing.Color]::White
$extended=[Windows.Forms.CheckBox]::new();$extended.Text='Extended read permissions for Intune and optional policy references';$extended.AutoSize=$true
$advanced=[Windows.Forms.CheckBox]::new();$advanced.Text='Advanced / switch customer';$advanced.AutoSize=$true
$advancedPanel=[Windows.Forms.FlowLayoutPanel]::new();$advancedPanel.FlowDirection='TopDown';$advancedPanel.WrapContents=$false;$advancedPanel.AutoSize=$true;$advancedPanel.Visible=$false
function New-AdvancedInput([string]$Caption){$label=[Windows.Forms.Label]::new();$label.Text=$Caption;$label.AutoSize=$true;$box=[Windows.Forms.TextBox]::new();$box.Width=620;$advancedPanel.Controls.Add($label);$advancedPanel.Controls.Add($box);return $box}
$tenantBox=New-AdvancedInput 'Optional customer domain/GUID override (blank = discover automatically)'
$clientBox=New-AdvancedInput 'Optional existing public reader app ID'
$spoBox=New-AdvancedInput 'SharePoint admin URL (suggested after discovery; verify renamed tenants)'
$advanced.Add_CheckedChanged({$advancedPanel.Visible=$advanced.Checked})
$serviceButtons=[Windows.Forms.FlowLayoutPanel]::new();$serviceButtons.Width=720;$serviceButtons.Height=135
$actions=@{}
foreach($spec in @(@('FindApp','Find reader app'),@('RegisterApp','Register reader app...'),@('ExchangeOnline','Connect Exchange'),@('SharePointOnline','Connect SharePoint'),@('SearchLogs','Search downloaded logs'))){
    $button=New-Button $spec[1];$button.Tag=$spec[0];$button.Width=216
    $button.Add_Click({param($sender,$e) Start-Operation ([string]$sender.Tag)})
    $actions[$spec[0]]=$button;$serviceButtons.Controls.Add($button)
}
$install=New-Button 'Install local prerequisites...'
$connection=[Windows.Forms.TextBox]::new();$connection.Width=680;$connection.Height=140;$connection.Multiline=$true;$connection.ReadOnly=$true;$connection.ScrollBars='Vertical';$connection.Text='Not logged in. Please login to 365.'
foreach($control in @($loginHelp,$signIn,$extended,$advanced,$advancedPanel,$serviceButtons,$install,$connection)){$loginFields.Controls.Add($control)}
$loginFields.Add_SizeChanged({
    $width=[Math]::Max(300,$loginFields.ClientSize.Width-25)
    $loginHelp.MaximumSize=[Drawing.Size]::new($width,0);$extended.MaximumSize=[Drawing.Size]::new($width,0)
    $advancedPanel.MaximumSize=[Drawing.Size]::new($width,0)
    foreach($control in @($tenantBox,$clientBox,$spoBox,$connection,$serviceButtons)){$control.Width=$width-8}
    $serviceButtons.Height=if($width -lt 680){135}else{95}
})
$guide=[Windows.Forms.RichTextBox]::new();$guide.Dock='Fill';$guide.ReadOnly=$true;$guide.BorderStyle='None';$guide.BackColor=[Drawing.Color]::White;$guideTab.Controls.Add($guide)
$directions=[Windows.Forms.RichTextBox]::new();$directions.Dock='Fill';$directions.ReadOnly=$true;$directions.BorderStyle='None';$directions.BackColor=[Drawing.Color]::White;$directionsTab.Controls.Add($directions)
$fields=[Windows.Forms.FlowLayoutPanel]::new();$fields.Dock='Fill';$fields.FlowDirection='TopDown';$fields.WrapContents=$false;$fields.AutoScroll=$true;$parametersTab.Controls.Add($fields)
$report=[Windows.Forms.RichTextBox]::new();$report.Dock='Fill';$report.ReadOnly=$true;$report.BorderStyle='None';$report.BackColor=[Drawing.Color]::White;$reportTab.Controls.Add($report)
$json=[Windows.Forms.TextBox]::new();$json.Dock='Fill';$json.ReadOnly=$true;$json.Multiline=$true;$json.WordWrap=$false;$json.ScrollBars='Both';$json.Font=[Drawing.Font]::new('Consolas',10);$jsonTab.Controls.Add($json)
$grid=[Windows.Forms.DataGridView]::new();$grid.Dock='Fill';$grid.ReadOnly=$true;$grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.AutoSizeColumnsMode='DisplayedCells';$grid.BackgroundColor=[Drawing.Color]::White;$tableTab.Controls.Add($grid)
$footer=[Windows.Forms.TableLayoutPanel]::new();$footer.Dock='Fill';$footer.RowCount=2;$footer.ColumnCount=1
[void]$footer.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,43));[void]$footer.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
$run=New-Button 'Run read-only report';$cancel=New-Button 'Cancel';$cancel.Width=100;$open=New-Button 'Open report folder'
$footerButtons=[Windows.Forms.FlowLayoutPanel]::new();$footerButtons.Dock='Fill';$footerButtons.Controls.AddRange(@($run,$cancel,$open))
$status=[Windows.Forms.TextBox]::new();$status.Dock='Fill';$status.Multiline=$true;$status.ReadOnly=$true;$status.ScrollBars='Vertical';$status.Text='Please login to 365.'
$footer.Controls.Add($footerButtons,0,0);$footer.Controls.Add($status,0,1);$layout.Controls.Add($footer,0,2)
function Test-LoggedIn {
    return [bool]($script:session.SharedGraph.Ready -and $script:session.Tenant.Id -and $script:session.Tenant.Account -and $script:session.Tenant.Id -eq $script:session.SharedGraph.TenantId)
}
function Update-LoginState {
    $busy=$null -ne $script:job;$ready=(Test-LoggedIn) -and $script:action -notin @('Login','RegisterApp')
    $list.Enabled=$ready -and -not $busy;$refresh.Enabled=$ready -and -not $busy;$fields.Enabled=$ready -and -not $busy
    $run.Enabled=$ready -and -not $busy -and $null -ne $list.SelectedItem -and $list.SelectedItem.Errors.Count -eq 0
    $logout.Enabled=$ready -and -not $busy;$open.Enabled=$ready -and -not $busy -and $null -ne $script:lastReport
    $cancel.Enabled=$busy;$login.Enabled=-not $busy;$signIn.Enabled=-not $busy;$install.Enabled=-not $busy -and -not $ready
    $advanced.Enabled=-not $busy;$advancedPanel.Enabled=-not $busy;$extended.Enabled=-not $busy
    foreach($button in $actions.Values){$button.Enabled=$ready -and -not $busy}
    foreach($page in @($guideTab,$parametersTab,$directionsTab,$reportTab,$tableTab,$jsonTab)){$page.Enabled=$ready -and -not $busy}
    if($ready){
        $identity.Text='Logged in as '+$script:session.Tenant.Account+[Environment]::NewLine+$script:session.Tenant.DisplayName+[Environment]::NewLine+'Tenant: '+$script:session.Tenant.Id
        $identity.ForeColor=$ink
        $loginHelp.Text='Logged in. Your verified account and tenant are stored in this session for all Microsoft 365 reports.'
        $connection.Text='Account: '+$script:session.Tenant.Account+[Environment]::NewLine+'Organization: '+$script:session.Tenant.DisplayName+[Environment]::NewLine+'Tenant ID: '+$script:session.Tenant.Id+[Environment]::NewLine+'Domain: '+$script:session.Tenant.Domain
        foreach($service in @(Get-LauncherServiceStatus $script:session)){$connection.AppendText([Environment]::NewLine+$service.Service+': '+$service.Status)}
    }else{
        $identity.Text=if($busy -and $script:action -eq 'Login'){'Signing in...'}else{'Not logged in'}
        $identity.ForeColor=[Drawing.Color]::DimGray
        $loginHelp.Text='Please login to 365. Reports remain locked until account and tenant discovery succeeds.'
        if(-not $busy){$connection.Text=if($script:session.SharedGraph.LastError){$script:session.SharedGraph.LastError}else{'Not logged in. Please login to 365.'}}
        $tabs.SelectedTab=$loginTab
    }
}
function Clear-Results {$script:lastReport=$null;$report.Clear();$json.Clear();$grid.DataSource=$null}
function Set-Parameters {
    foreach($control in @($fields.Controls)){$fields.Controls.Remove($control);$control.Dispose()}
    $script:inputs=@{}
    if(-not $list.SelectedItem){return}
    $item=$list.SelectedItem
    Set-LauncherGuide $guide $item.Manifest
    Set-LauncherTechnicalDetails $directions $item.Usage
    foreach($parameter in $item.Parameters){
        $label=[Windows.Forms.Label]::new();$label.Text=$parameter.label;$label.AutoSize=$true;$label.Font=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold)
        $help=[Windows.Forms.Label]::new();$help.Text=$parameter.help;$help.AutoSize=$true;$help.MaximumSize=[Drawing.Size]::new(650,0)
        $fields.Controls.Add($label);$fields.Controls.Add($help)
        if($parameter.type -eq 'boolean'){$input=[Windows.Forms.CheckBox]::new();$input.Text='Include';$input.Checked=[bool]$parameter.default}
        elseif($parameter.type -eq 'integer'){$input=[Windows.Forms.NumericUpDown]::new();$input.Minimum=$parameter.minimum;$input.Maximum=$parameter.maximum;$input.Value=$parameter.default}
        else{$input=[Windows.Forms.TextBox]::new();$input.Width=600;if($parameter.ContainsKey('default')){$input.Text=[string]$parameter.default}}
        $fields.Controls.Add($input);$script:inputs[$parameter.name]=$input
    }
    Update-LoginState
}
function Refresh-Reports {
    $script:catalog=@(Get-ScriptCatalog $ScriptsRoot | Sort-Object DisplayName)
    $list.Items.Clear();foreach($item in $script:catalog){[void]$list.Items.Add($item)}
    if($list.Items.Count){$list.SelectedIndex=0}
    Update-LoginState
}
function Show-Report {
    $json.Text=Get-Content -LiteralPath $script:lastReport.JsonPath -Raw
    Set-LauncherTechnicalDetails $report (Get-Content -LiteralPath $script:lastReport.MarkdownPath -Raw)
    $data=$json.Text | ConvertFrom-Json -AsHashtable;$table=[Data.DataTable]::new()
    $rows=@($data.records | Select-Object -First 5000)
    $item=$script:catalog | Where-Object {$_.Manifest.id -eq $data.tool} | Select-Object -First 1
    $columns=if($item -and $item.Manifest.output.ContainsKey('primaryColumns')){@($item.Manifest.output.primaryColumns)}else{@($rows | ForEach-Object {$_.Keys} | Select-Object -Unique)}
    foreach($name in $columns){[void]$table.Columns.Add([string]$name,[string])}
    foreach($record in $rows){$row=$table.NewRow();foreach($name in $columns){$value=$record[$name];$row[$name]=if($null -eq $value){''}elseif($value -is [string] -or $value -is [ValueType]){[string]$value}else{ConvertTo-Json -InputObject $value -Depth 50 -Compress}};$table.Rows.Add($row)}
    $grid.DataSource=$table;$tabs.SelectedTab=$tableTab
}
function Start-Operation([string]$Action) {
    if($script:job){return}
    if($Action -notin @('Login','Install') -and -not (Test-LoggedIn)){$status.Text='Please login to 365.';Update-LoginState;return}
    $options=@{Tenant=$tenantBox.Text.Trim();Client=$clientBox.Text.Trim();Extended=$extended.Checked;SharePointUrl=$spoBox.Text.Trim()}
    if($Action -eq 'RegisterApp'){
        if([Windows.Forms.MessageBox]::Show('Create a secretless public reader app in the verified tenant? This explicit setup requests registration permission, configures delegated read scopes, and disconnects the reader session. It does not grant consent or roles.','Review app registration','YesNo','Question') -ne 'Yes'){return}
    }
    if($Action -eq 'Install'){
        if([Windows.Forms.MessageBox]::Show('Install the pinned Graph Authentication, Exchange and SharePoint modules for this Windows user from the official PowerShell Gallery and accept their package licenses? No tenant settings are changed.','Local prerequisites','YesNo','Question') -ne 'Yes'){return}
    }
    if($Action -eq 'Report'){
        $item=$list.SelectedItem;if(-not $item -or $item.Errors.Count){return}
        $options.Parameters=@{}
        foreach($parameter in $item.Parameters){$input=$script:inputs[$parameter.name];$options.Parameters[$parameter.name]=if($parameter.type -eq 'boolean'){$input.Checked}elseif($parameter.type -eq 'integer'){[int]$input.Value}else{$input.Text.Trim()}}
        $options.Manifest=$item.Manifest;$options.Entry=$item.Path;$options.Hash=$item.Hash
    }
    if($Action -eq 'SearchLogs'){
        $picker=[Windows.Forms.FolderBrowserDialog]::new();$picker.Description='Choose a report folder containing log-download.json'
        try{if($picker.ShowDialog($form) -ne 'OK'){return};$options.Folder=$picker.SelectedPath}finally{$picker.Dispose()}
        Add-Type -AssemblyName Microsoft.VisualBasic
        $options.Query=[Microsoft.VisualBasic.Interaction]::InputBox('Which issue, error code, account, IP or correlation ID should be searched locally?','Search downloaded logs','')
        if(-not $options.Query){return}
    }
    if($Action -in @('Login','RegisterApp')){Clear-Results}
    $script:action=$Action;$script:worker=[powershell]::Create()
    $code={
        param($root,$context,$action,$options,$output)
        $ErrorActionPreference='Stop';Import-Module (Join-Path $root 'infrastructure/Launcher.psm1') -Force
        switch($action){
            'Login' {
                $target=$options.Tenant
                if(-not $target -and $options.Client -and $context.Tenant.Id){$target=$context.Tenant.Id}
                Clear-LauncherSession $context
                Connect-M365Session $context -TenantId $target -ClientId $options.Client -Extended:$options.Extended
            }
            'Install' {& (Join-Path $root 'infrastructure/Install-M365Dependencies.ps1')}
            'FindApp' {Find-M365ReaderApplication $context}
            'RegisterApp' {$target=if($options.Tenant){$options.Tenant}else{$context.Tenant.Id};Disconnect-LauncherServices $context;Register-M365ReaderApplication $context -TenantId $target -CreateConfirmed}
            'Report' {Invoke-LauncherAdapter $options.Manifest $options.Parameters $context $options.Entry $output $options.Hash}
            'SearchLogs' {
                $download=Get-Content -LiteralPath (Join-Path $options.Folder 'log-download.json') -Raw | ConvertFrom-Json -AsHashtable
                if($download.TenantId -ne $context.Tenant.Id){throw 'These logs belong to another tenant.'}
                $result=& (Join-Path $root 'scripts/M365Security/Search-DownloadedLogs.ps1') -DownloadFolder $options.Folder -Query $options.Query
                $directory=Join-Path $output ('log-search-'+[guid]::NewGuid());[void][IO.Directory]::CreateDirectory($directory)
                $manifest=@{id='local-log-search';name='Downloaded Microsoft 365 log search';purpose='Literal local search';readOnly=$true;source='Verified downloaded JSONL'}
                Write-LauncherReport $manifest @{Query=$options.Query;TenantId=$context.Tenant.Id} $result $(if($result.Summary.Incomplete){'Partial'}else{'Completed'}) $directory ([DateTime]::UtcNow)
            }
            default {
                if($action -notin @('ExchangeOnline','SharePointOnline')){throw 'Unsupported Microsoft 365 operation.'}
                $context.Tenant.SharePointAdminUrl=$options.SharePointUrl
                Connect-LauncherService $context -Service $action
            }
        }
    }
    [void]$script:worker.AddScript($code).AddArgument($PSScriptRoot).AddArgument($script:session).AddArgument($Action).AddArgument($options).AddArgument($OutputRoot)
    $script:job=$script:worker.BeginInvoke();$status.Text=if($Action -eq 'Login'){'Please complete Microsoft sign-in. Reports unlock after tenant discovery.'}else{'Working: '+$Action}
    Update-LoginState;$timer.Start()
}
function Stop-Operation {
    if($script:session.SharedGraph.ActiveWorker){try{[void]$script:session.SharedGraph.ActiveWorker.BeginStop($null,$null)}catch{}}
    foreach($entry in @($script:session.Services.Values)){if($entry.PSObject.Properties['ActiveWorker'] -and $entry.ActiveWorker){try{[void]$entry.ActiveWorker.BeginStop($null,$null)}catch{}}}
    if($script:worker){$script:worker.Stop()}
}
$timer=[Windows.Forms.Timer]::new();$timer.Interval=250
$timer.Add_Tick({
    $message='';while($script:session.Progress.TryDequeue([ref]$message)){$status.AppendText([Environment]::NewLine+$message)}
    if(-not $script:job -or -not $script:job.IsCompleted){return}
    $timer.Stop();$action=$script:action
    try {
        $items=$script:worker.EndInvoke($script:job)
        if($script:worker.HadErrors){throw $script:worker.Streams.Error[0]}
        if($action -in @('Report','SearchLogs')){$script:lastReport=$items | Where-Object {$_.PSObject.Properties['JsonPath']} | Select-Object -Last 1;if(-not $script:lastReport){throw 'No report was returned.'};Show-Report;$status.Text=$script:lastReport.Report.status+': '+$script:lastReport.JsonPath}
        elseif($action -eq 'FindApp'){$apps=@($items[-1].Items);if($items[-1].Status -ne 'Complete'){throw 'App search failed.'};if($apps.Count -eq 1){$clientBox.Text=$apps[0].appId};$status.Text=($apps | ForEach-Object {$_.displayName+' | '+$_.appId}) -join [Environment]::NewLine}
        elseif($action -eq 'RegisterApp'){$clientBox.Text=$items[-1].AppId;$status.Text=$items[-1].Note+' Please login to 365 again.'}
        else {$status.Text='Completed: '+$action;if($action -eq 'Login'){$spoBox.Text=$script:session.Tenant.SharePointAdminUrl;$status.Text='Logged in. Account and tenant details are saved in this session. Choose a Microsoft 365 report.'}}
    } catch {
        $status.Text=if($action -eq 'Login' -and $script:session.SharedGraph.LastError){$script:session.SharedGraph.LastError}else{'Operation could not complete. Verify this tenant, service connection and required read permissions. No successful or healthy result is implied.'}
    } finally {$script:worker.Dispose();$script:worker=$null;$script:job=$null;$script:action='';Update-LoginState}
})
$login.Add_Click({$tabs.SelectedTab=$loginTab;if(-not (Test-LoggedIn)){Start-Operation 'Login'}})
$signIn.Add_Click({Start-Operation 'Login'})
$install.Add_Click({Start-Operation 'Install'})
$logout.Add_Click({Clear-LauncherSession $script:session;$script:session=New-LauncherSession;$tenantBox.Clear();$clientBox.Clear();$spoBox.Clear();$advanced.Checked=$false;Clear-Results;$status.Text='Please login to 365.';Update-LoginState})
$refresh.Add_Click({Refresh-Reports})
$list.Add_SelectedIndexChanged({Set-Parameters})
$run.Add_Click({Start-Operation 'Report'})
$cancel.Add_Click({Stop-Operation})
$open.Add_Click({if((Test-LoggedIn) -and $script:lastReport){Start-Process explorer.exe -ArgumentList @('/select,',$script:lastReport.JsonPath)}})
$tabs.Add_Selecting({param($sender,$e) if(-not (Test-LoggedIn) -and $e.TabPage -ne $loginTab){$e.Cancel=$true}})
$form.Add_FormClosing({Stop-Operation})
Refresh-Reports;Update-LoginState
try {
    if($VerifyUi){
        if($script:catalog.Count -ne 4 -or @($script:catalog | Where-Object {$_.Errors.Count}).Count){throw 'Expected four valid Microsoft 365 reports.'}
        if($list.Enabled -or $run.Enabled -or $logout.Enabled -or $actions['FindApp'].Enabled -or $identity.Text -ne 'Not logged in'){throw 'Unauthenticated controls were not locked.'}
        $form.ShowInTaskbar=$false;$form.StartPosition='Manual';$form.Location=[Drawing.Point]::new(-30000,-30000);$form.Opacity=0;$form.Show()
        $saved=(Get-Command Start-Operation).ScriptBlock;$script:clicked=''
        try{Set-Item Function:\Start-Operation {param($Action) $script:clicked=$Action};$login.PerformClick();if($script:clicked -ne 'Login' -or $tenantBox.Text){throw 'One-click discovery failed.'}}finally{Set-Item Function:\Start-Operation $saved}
        $script:session.SharedGraph.Ready=$true;$script:session.SharedGraph.TenantId='00000000-0000-0000-0000-000000000001'
        $script:session.Tenant.Id=$script:session.SharedGraph.TenantId;$script:session.Tenant.Account='reader@fixture.example';$script:session.Tenant.DisplayName='Synthetic organization'
        Update-LoginState
        if(-not $list.Enabled -or -not $run.Enabled -or $identity.Text -notmatch 'Logged in as reader@fixture.example'){throw 'Authenticated controls or identity banner failed.'}
        foreach($item in $script:catalog){$list.SelectedItem=$item;if(-not $script:inputs.Count -or $guide.Text -notmatch 'Before you start' -or -not $directions.Text.Trim()){throw 'Manifest UI failed.'}}
        $fixture=Join-Path ([IO.Path]::GetTempPath()) ('m365-ui-fixture-'+[guid]::NewGuid())
        [void][IO.Directory]::CreateDirectory($fixture)
        try{
            $manifest=($script:catalog | Where-Object {$_.Manifest.id -eq 'service-inventory'}).Manifest
            $evidence=[pscustomobject]@{Summary=[pscustomobject]@{Count=1;Incomplete=$false};Records=@([pscustomobject]@{Service='ExchangeOnline';Collection='Fixture evidence';Id='fixture-record-1'});Limitations=@('Synthetic UI verification only.')}
            $script:lastReport=Write-LauncherReport $manifest @{TenantId=$script:session.Tenant.Id} $evidence 'Completed' $fixture ([DateTime]::UtcNow)
            Show-Report;[Windows.Forms.Application]::DoEvents()
            if($grid.Rows.Count -ne 1 -or $grid.Rows[0].Cells['Id'].Value -ne 'fixture-record-1' -or $json.Text -notmatch 'fixture-record-1' -or $report.Text -notmatch 'Instructions for an LLM'){throw 'Report evidence did not reach all UI views.'}
        }finally{
            Clear-Results
            $resolved=[IO.Path]::GetFullPath($fixture);$tempBase=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
            if(-not $resolved.StartsWith($tempBase,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'm365-ui-fixture-*'){throw 'Unexpected UI fixture cleanup path.'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
        if($PreviewPath){[void][IO.Directory]::CreateDirectory($PreviewPath)}
        foreach($view in @('logged-in','locked','locked-compact')){
            if($view -like 'locked*'){$script:session.SharedGraph.Ready=$false;Update-LoginState}
            if($view -eq 'locked-compact'){$form.Size=$form.MinimumSize}
            $tabs.SelectedTab=$loginTab;$form.PerformLayout();[Windows.Forms.Application]::DoEvents()
            if($header.Right -gt $layout.ClientSize.Width -or $identity.Right -gt $header.Width){throw 'The login identity banner extends beyond the window.'}
            if($PreviewPath){$bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height);try{$form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height));$bitmap.Save((Join-Path $PreviewPath ($view+'.png')))}finally{$bitmap.Dispose()}}
        }
        if($list.Enabled -or $run.Enabled -or $identity.Text -ne 'Not logged in'){throw 'Expired session did not relock controls.'}
        $form.Hide()
        'PASS: four Microsoft 365 tools, login-first gating, direct login action, saved identity banner, manifest inputs, table/JSON/readable report views and relock after authentication loss. No live sign-in.'
    } else {[void]$form.ShowDialog()}
} finally {Stop-Operation;Clear-LauncherSession $script:session;$timer.Dispose();$form.Dispose()}
