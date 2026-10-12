[CmdletBinding()]
param([string]$ScriptsRoot=$PSScriptRoot,[string]$OutputRoot=(Join-Path $PSScriptRoot 'reports'),[switch]$VerifyUi)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7 -or $env:OS -ne 'Windows_NT') { throw 'Run this launcher with PowerShell 7 on Windows: pwsh -STA -File .\Start-PowerShellUI.ps1' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'infrastructure/Catalog.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'infrastructure/Launcher.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$script:session=New-LauncherSession
$script:job=$null; $script:worker=$null; $script:catalog=@(); $script:inputs=@{}; $script:lastReport=$null
$form=[Windows.Forms.Form]::new()
$form.Text='Read-only Infrastructure Reports'; $form.Size=[Drawing.Size]::new(1250,850)
$form.MinimumSize=[Drawing.Size]::new(1000,700); $form.StartPosition='CenterScreen'
$split=[Windows.Forms.SplitContainer]::new(); $split.Dock='Fill'; $split.Size=[Drawing.Size]::new(1200,750); $split.SplitterDistance=300
$form.Controls.Add($split)
$list=[Windows.Forms.ListBox]::new(); $list.Dock='Fill'; $list.DisplayMember='Name'
$search=[Windows.Forms.TextBox]::new(); $search.Dock='Top'; $search.PlaceholderText='Find a report'
$leftActions=[Windows.Forms.FlowLayoutPanel]::new(); $leftActions.Dock='Bottom'; $leftActions.Height=75
$refresh=[Windows.Forms.Button]::new(); $refresh.Text='Refresh'; $refresh.Width=90
$credentials=[Windows.Forms.Button]::new(); $credentials.Text='Session credentials'; $credentials.Width=180
$forget=[Windows.Forms.Button]::new(); $forget.Text='Clear credentials and tokens'; $forget.Width=270
$leftActions.Controls.AddRange(@($refresh,$credentials,$forget)); $split.Panel1.Controls.AddRange(@($list,$search,$leftActions))
$tabs=[Windows.Forms.TabControl]::new(); $tabs.Dock='Fill'
$usageTab=[Windows.Forms.TabPage]::new('Purpose and directions')
$paramTab=[Windows.Forms.TabPage]::new('Parameters')
$resultTab=[Windows.Forms.TabPage]::new('Report')
$dataTab=[Windows.Forms.TabPage]::new('Structured data')
$gridTab=[Windows.Forms.TabPage]::new('Record table')
$grid=[Windows.Forms.DataGridView]::new(); $grid.Dock='Fill'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.AutoSizeColumnsMode='DisplayedCells'; $grid.ClipboardCopyMode='EnableAlwaysIncludeHeaderText'; $gridTab.Controls.Add($grid)
$usage=[Windows.Forms.TextBox]::new(); $usage.Multiline=$true; $usage.ReadOnly=$true; $usage.ScrollBars='Both'; $usage.Dock='Fill'
$reportText=[Windows.Forms.TextBox]::new(); $reportText.Multiline=$true; $reportText.ReadOnly=$true; $reportText.ScrollBars='Both'; $reportText.Dock='Fill'
$jsonText=[Windows.Forms.TextBox]::new(); $jsonText.Multiline=$true; $jsonText.ReadOnly=$true; $jsonText.ScrollBars='Both'; $jsonText.Dock='Fill'; $jsonText.WordWrap=$false
$fields=[Windows.Forms.FlowLayoutPanel]::new(); $fields.Dock='Fill'; $fields.FlowDirection='TopDown'; $fields.WrapContents=$false; $fields.AutoScroll=$true
$usageTab.Controls.Add($usage); $paramTab.Controls.Add($fields); $resultTab.Controls.Add($reportText); $dataTab.Controls.Add($jsonText)
$tabs.TabPages.AddRange(@($usageTab,$paramTab,$resultTab,$gridTab,$dataTab))
$bottom=[Windows.Forms.Panel]::new(); $bottom.Dock='Bottom'; $bottom.Height=130
$actions=[Windows.Forms.FlowLayoutPanel]::new(); $actions.Dock='Top'; $actions.Height=36
$run=[Windows.Forms.Button]::new(); $run.Text='Run report'; $run.Enabled=$false; $run.Width=110
$stop=[Windows.Forms.Button]::new(); $stop.Text='Cancel'; $stop.Enabled=$false
$open=[Windows.Forms.Button]::new(); $open.Text='Open report folder'; $open.Width=150; $open.Enabled=$false
$actions.Controls.AddRange(@($run,$stop,$open))
$status=[Windows.Forms.TextBox]::new(); $status.Dock='Fill'; $status.Multiline=$true; $status.ReadOnly=$true; $status.ScrollBars='Vertical'; $status.Text='Ready. All exposed workflows collect read-only reports.'
$bottom.Controls.AddRange(@($status,$actions)); $split.Panel2.Controls.AddRange(@($tabs,$bottom))
function Set-Busy([bool]$busy) {
    foreach($control in @($list,$search,$refresh,$credentials,$forget)) { $control.Enabled=-not $busy }
    $stop.Enabled=$busy
    $run.Enabled=(-not $busy -and $null -ne $list.SelectedItem -and $list.SelectedItem.Errors.Count -eq 0)
}
function Update-List {
    $list.Items.Clear()
    foreach($item in $script:catalog) {
        if(($item.Name+' '+$item.Purpose).IndexOf($search.Text,[StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$list.Items.Add($item) }
    }
}
function Refresh-Catalog {
    try { $script:catalog=@(Get-ScriptCatalog $ScriptsRoot | Sort-Object Name); Update-List; $status.Text="$($script:catalog.Count) reporting adapters. Session credentials are memory-only." }
    catch { $status.Text='Cannot discover report manifests. Check the scripts root and directions files.' }
}
function Show-CredentialDialog {
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text='Credentials for this launcher session'; $dialog.Size=[Drawing.Size]::new(540,320); $dialog.StartPosition='CenterParent'
    $panel=[Windows.Forms.FlowLayoutPanel]::new(); $panel.Dock='Fill'; $panel.FlowDirection='TopDown'; $panel.WrapContents=$false
    $kind=[Windows.Forms.ComboBox]::new(); $kind.DropDownStyle='DropDownList'; $kind.Width=480
    $kind.Items.AddRange(@('ActiveDirectory','AzureServicePrincipal')); $kind.SelectedIndex=0
    $hint=[Windows.Forms.Label]::new(); $hint.Text='AD: DOMAIN\user + password. Azure: application/client ID + client secret.'; $hint.AutoSize=$true; $hint.MaximumSize=[Drawing.Size]::new(480,0)
    $username=[Windows.Forms.TextBox]::new(); $username.Width=480; $username.PlaceholderText='Username or application/client ID'
    $password=[Windows.Forms.TextBox]::new(); $password.Width=480; $password.UseSystemPasswordChar=$true; $password.PlaceholderText='Password or client secret (session only)'
    $save=[Windows.Forms.Button]::new(); $save.Text='Use in session'; $save.Width=140
    $save.Add_Click({
        if(-not $username.Text -or -not $password.Text) { return }
        $key=[string]$kind.SelectedItem
        $secret=ConvertTo-SecureString $password.Text -AsPlainText -Force
        if($script:session.Credentials.ContainsKey($key)) { $script:session.Credentials[$key].Password.Dispose() }
        $script:session.Credentials[$key]=[pscredential]::new($username.Text,$secret)
        $password.Clear(); $username.Clear(); $dialog.DialogResult='OK'; $dialog.Close()
    })
    $panel.Controls.AddRange(@($kind,$hint,$username,$password,$save)); $dialog.Controls.Add($panel)
    try { [void]$dialog.ShowDialog($form) } finally { $password.Clear(); $username.Clear(); $dialog.Dispose() }
}
$credentials.Add_Click({Show-CredentialDialog})
$forget.Add_Click({Clear-LauncherSession $script:session; $script:session=New-LauncherSession; $status.Text='Session credentials and access tokens cleared.'})
$search.Add_TextChanged({Update-List}); $refresh.Add_Click({Refresh-Catalog})
$list.Add_SelectedIndexChanged({
    $fields.Controls.Clear(); $script:inputs=@{}; $item=$list.SelectedItem
    Set-Busy ($null -ne $script:job)
    if($null -eq $item) { $usage.Clear(); return }
    $usage.Text=$item.Usage
    if($item.Errors.Count) { $usage.AppendText([Environment]::NewLine+'BLOCKED: '+($item.Errors -join '; ')) }
    foreach($parameter in $item.Parameters) {
        $label=[Windows.Forms.Label]::new(); $label.AutoSize=$true; $label.MaximumSize=[Drawing.Size]::new(700,0)
        $label.Text=$parameter.label+$(if($parameter.required){' (required)'}else{''})+' — '+$parameter.help
        $fields.Controls.Add($label)
        if($parameter.type -eq 'boolean') { $control=[Windows.Forms.CheckBox]::new(); $control.Text=$parameter.label; $control.Checked=[bool]$parameter.default; $control.AutoSize=$true }
        else { $control=[Windows.Forms.TextBox]::new(); $control.Width=650; if($parameter.ContainsKey('default')) { $control.Text=([string]$parameter.default).Replace('{LauncherRoot}',$PSScriptRoot) } }
        $fields.Controls.Add($control); $script:inputs[$parameter.name]=$control
    }
})
function Show-ReportResult {
            $reportText.Text=Get-Content -LiteralPath $script:lastReport.MarkdownPath -Raw
            $jsonText.Text=Get-Content -LiteralPath $script:lastReport.JsonPath -Raw
            $data=$jsonText.Text | ConvertFrom-Json -AsHashtable
            $table=[Data.DataTable]::new()
            $rows=@($data.records | Select-Object -First 5000)
            foreach($record in $rows) { foreach($key in $record.Keys) { if(-not $table.Columns.Contains($key)) { [void]$table.Columns.Add($key,[string]) } } }
            foreach($record in $rows) {
                $row=$table.NewRow()
                foreach($key in $record.Keys) { $value=$record[$key]; $row[$key]=if($null -eq $value) { '' } elseif($value -is [string] -or $value -is [ValueType]) { [string]$value } else { ConvertTo-Json -InputObject $value -Depth 50 -Compress } }
                $table.Rows.Add($row)
            }
            $grid.DataSource=$table
            $gridTab.Text="Record table ($($rows.Count) shown; full data in JSON)"

}
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=300
$timer.Add_Tick({
    $message=''
    while($script:session.Progress.TryDequeue([ref]$message)) { $status.AppendText([Environment]::NewLine+$message) }
    if($null -eq $script:job -or -not $script:job.IsCompleted) { return }
    $timer.Stop()
    try {
        $items=$script:worker.EndInvoke($script:job)
        $script:lastReport=$items | Where-Object { $_.PSObject.Properties.Name -contains 'JsonPath' } | Select-Object -Last 1
        if($null -eq $script:lastReport) {
            $fallbackDirectory=if($script:session.ContainsKey('RunDirectory') -and $script:session.RunDirectory) { $script:session.RunDirectory } else { Join-Path $OutputRoot ([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,8)) }
            [void](New-Item -ItemType Directory -Path $fallbackDirectory -Force)
            $fallback=[pscustomobject]@{Summary='Collection did not complete.';Records=@();Limitations=@('No complete result is available. Partial native files must not be interpreted as a complete report.')}
            $fallbackStatus=if($script:cancelled) { 'Cancelled' } else { 'Failed' }
            $script:lastReport=Write-LauncherReport $script:activeManifest $script:activeParameters $fallback $fallbackStatus $fallbackDirectory $script:activeStarted 'Collection stopped before a completed report was returned.'
        }
        if($script:lastReport) {
            Show-ReportResult
            $status.AppendText([Environment]::NewLine+"$($script:lastReport.Report.status): $($script:lastReport.JsonPath)")
            $open.Enabled=$true; $tabs.SelectedTab=$resultTab
        } else { $status.AppendText([Environment]::NewLine+'No completed report was returned. Collection failed or was cancelled.') }
    } catch {
        $status.AppendText([Environment]::NewLine+'Collection stopped or failed before report creation. Do not interpret missing results as healthy.')
        if($null -eq $script:lastReport -and $script:session.ContainsKey('RunDirectory') -and $script:session.RunDirectory) {
            $fallback=[pscustomobject]@{Summary='Collection did not complete.';Records=@();Limitations=@('Cancelled or failed collection; no complete data is available.')}
            $fallbackStatus=if($script:cancelled) { 'Cancelled' } else { 'Failed' }
            $script:lastReport=Write-LauncherReport $script:activeManifest $script:activeParameters $fallback $fallbackStatus $script:session.RunDirectory $script:activeStarted 'Collection stopped before completion.'
            $reportText.Text=Get-Content -LiteralPath $script:lastReport.MarkdownPath -Raw
            $jsonText.Text=Get-Content -LiteralPath $script:lastReport.JsonPath -Raw
            $open.Enabled=$true; $tabs.SelectedTab=$resultTab
        }
    }
    finally { $script:worker.Dispose(); $script:worker=$null; $script:job=$null; Set-Busy $false }
})
$run.Add_Click({
    try {
        $item=$list.SelectedItem
        if($null -eq $item -or $item.Errors.Count) { throw 'Select a registered read-only report.' }
        $parameters=@{}
        foreach($parameter in $item.Parameters) {
            $control=$script:inputs[$parameter.name]
            if($parameter.type -eq 'boolean') { $parameters[$parameter.name]=$control.Checked }
            else {
                $value=$control.Text.Trim()
                if($parameter.required -and -not $value) { throw "Enter $($parameter.label)." }
                if($value) { $parameters[$parameter.name]=if($parameter.type -eq 'integer') { [int]$value } else { $value } }
            }
        }
        if($item.Manifest.ContainsKey('credentialKey') -and $item.Manifest.credentialKey -eq 'AzureServicePrincipal' -and -not $script:session.Credentials.ContainsKey('AzureServicePrincipal')) { throw 'Use Session credentials to enter the Azure application ID and client secret first.' }
        $script:activeManifest=$item.Manifest; $script:activeParameters=$parameters; $script:activeStarted=[DateTime]::UtcNow; $script:cancelled=$false; $script:session.RunDirectory=''
        $script:worker=[powershell]::Create()
        $workerCode={
            param($module,$manifest,$parameters,$context,$entry,$outputRoot,$hash)
            $ErrorActionPreference='Stop'
            Import-Module $module -Force
            Invoke-LauncherAdapter -Manifest $manifest -Parameters $parameters -Context $context -EntryPath $entry -OutputRoot $outputRoot -ExpectedHash $hash
        }
        [void]$script:worker.AddScript($workerCode).AddArgument((Join-Path $PSScriptRoot 'infrastructure/Launcher.psm1')).AddArgument($item.Manifest).AddArgument($parameters).AddArgument($script:session).AddArgument($item.Path).AddArgument($OutputRoot).AddArgument($item.Hash)
        $script:lastReport=$null; $open.Enabled=$false; $reportText.Clear(); $jsonText.Clear(); $grid.DataSource=$null; $status.Text='Collecting read-only data. Microsoft sign-in instructions will appear here when needed.'
        $tabs.SelectedTab=$resultTab
        $script:job=$script:worker.BeginInvoke(); Set-Busy $true; $timer.Start()
    } catch {
        if($script:worker -and $null -eq $script:job) { $script:worker.Dispose(); $script:worker=$null }
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Report parameters')
    }
})
function Stop-Report {
    if($null -eq $script:worker) { return }
    $script:cancelled=$true
    foreach($process in $script:session.NativeProcesses) { try { if(-not $process.HasExited) { $process.Kill($true) } } catch {} }
    $script:worker.Stop()
}
$stop.Add_Click({Stop-Report; $status.AppendText([Environment]::NewLine+'Cancelled. Partial native files, if any, are not a completed report.')})
$open.Add_Click({if($script:lastReport){Start-Process explorer.exe -ArgumentList @('/select,',$script:lastReport.JsonPath)}})
$form.Add_FormClosing({Stop-Report})
Refresh-Catalog
try {
    if($VerifyUi) {
        if($list.Items.Count -ne 3) { throw 'Expected three reports.' }
        for($index=0;$index -lt $list.Items.Count;$index++) {
            $list.SelectedIndex=$index
            if(-not $run.Enabled -or $script:inputs.Count -eq 0) { throw 'Manifest parameter controls or integrity gate failed.' }
        }
        $displayFixture=Join-Path ([IO.Path]::GetTempPath()) ('launcher-display-'+[guid]::NewGuid())
        [void](New-Item -ItemType Directory -Path $displayFixture)
        try {
            $fixtureManifest=@{id='display-fixture';name='Synthetic display';purpose='Offline display verification';source='test'}
            $fixtureResult=[pscustomobject]@{Summary='Synthetic fixture';Records=@([pscustomobject]@{Id='display-1';Name='Example';Data=@{Healthy=$true}});Limitations=@('Synthetic, not tenant data.')}
            $script:lastReport=Write-LauncherReport $fixtureManifest @{} $fixtureResult 'Completed' $displayFixture ([DateTime]::UtcNow)
            Show-ReportResult
            if($grid.DataSource.Rows.Count -ne 1 -or $reportText.Text -notmatch 'Synthetic fixture' -or $jsonText.Text -notmatch 'display-1') { throw 'Report display failed.' }
        } finally {
            Remove-Item -LiteralPath (Join-Path $displayFixture 'report.json'),(Join-Path $displayFixture 'report.md') -Force
            Remove-Item -LiteralPath $displayFixture
            $script:lastReport=$null
        }
        'PASS: three manifests, directions, typed parameter controls, integrity gate, readable report, record table and JSON initialize in the Windows UI.'
    } else { [void]$form.ShowDialog() }
} finally {
    try {
        Stop-Report
        if($script:worker) { $script:worker.Dispose() }
        if($null -ne $script:job -and $script:session.ContainsKey('RunDirectory') -and $script:session.RunDirectory -and -not(Test-Path -LiteralPath (Join-Path $script:session.RunDirectory 'report.json'))) {
            $cancelled=[pscustomobject]@{Summary='Launcher closed before collection completed.';Records=@();Limitations=@('Cancelled collection. No complete data is available.')}
            [void](Write-LauncherReport $script:activeManifest $script:activeParameters $cancelled 'Cancelled' $script:session.RunDirectory $script:activeStarted 'Launcher closed before completion.')
        }
    } finally {
        Clear-LauncherSession $script:session
        $script:session=$null; $timer.Dispose(); $form.Dispose()
    }
}


