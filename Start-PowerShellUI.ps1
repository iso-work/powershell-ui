[CmdletBinding()]
param([string]$ScriptsRoot=$PSScriptRoot,[string]$OutputRoot=(Join-Path $PSScriptRoot 'reports'),[switch]$VerifyUi,[string]$PreviewPath)
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.Major -lt 7 -or $env:OS -ne 'Windows_NT') { throw 'Run this launcher with PowerShell 7 on Windows.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'infrastructure/Catalog.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'infrastructure/Launcher.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'infrastructure/Presentation.psm1') -Force
[void][Windows.Forms.Application]::SetHighDpiMode([Windows.Forms.HighDpiMode]::PerMonitorV2)
[Windows.Forms.Application]::EnableVisualStyles()
$script:session=New-LauncherSession
$script:job=$null; $script:worker=$null; $script:catalog=@(); $script:inputs=@{}; $script:lastReport=$null
$script:ink=[Drawing.ColorTranslator]::FromHtml('#173454'); $script:muted=[Drawing.ColorTranslator]::FromHtml('#526478')
$script:accent=[Drawing.ColorTranslator]::FromHtml('#176B87'); $script:page=[Drawing.ColorTranslator]::FromHtml('#F2F5F9')
function Set-ButtonStyle {
param([Windows.Forms.Button]$Button,[bool]$Primary=$false)
$Button.Height=38; $Button.FlatStyle='Flat'; $Button.FlatAppearance.BorderSize=1; $Button.FlatAppearance.BorderColor=[Drawing.ColorTranslator]::FromHtml('#CBD5E1')
$Button.BackColor=if($Primary){$script:accent}else{[Drawing.Color]::White}; $Button.ForeColor=if($Primary){[Drawing.Color]::White}else{$script:ink}; $Button.Margin=[Windows.Forms.Padding]::new(0,0,10,0)
}
function Add-LayoutRow { param($Layout,[int]$Height) [void]$Layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute,$Height)) }
function New-ReadingBox {
$box=[Windows.Forms.RichTextBox]::new(); $box.Dock='Fill'; $box.ReadOnly=$true; $box.BorderStyle='None'; $box.BackColor=[Drawing.Color]::White; $box.DetectUrls=$false; return $box
}
$form=[Windows.Forms.Form]::new(); $form.Text='Infrastructure reports — read-only'; $form.Size=[Drawing.Size]::new(1320,930); $form.MinimumSize=[Drawing.Size]::new(1080,760); $form.StartPosition='CenterScreen'
$form.Font=[Drawing.Font]::new('Segoe UI',11); $form.AutoScaleMode='Dpi'; $form.BackColor=$script:page
$rootLayout=[Windows.Forms.TableLayoutPanel]::new(); $rootLayout.Dock='Fill'; $rootLayout.Padding=[Windows.Forms.Padding]::new(18); $rootLayout.ColumnCount=1; $rootLayout.RowCount=2
[void]$rootLayout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
Add-LayoutRow $rootLayout 88; [void]$rootLayout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100)); $form.Controls.Add($rootLayout)
$banner=[Windows.Forms.Panel]::new(); $banner.Dock='Fill'
$appTitle=[Windows.Forms.Label]::new(); $appTitle.Text='Infrastructure reports'; $appTitle.Font=[Drawing.Font]::new('Segoe UI',22,[Drawing.FontStyle]::Bold); $appTitle.ForeColor=$script:ink; $appTitle.AutoSize=$true
$steps=[Windows.Forms.Label]::new(); $steps.Text='1  Choose a report     2  Read the guide     3  Enter parameters     4  Run and review'; $steps.AutoSize=$true; $steps.ForeColor=$script:muted; $steps.Location=[Drawing.Point]::new(2,48)
$banner.Controls.AddRange(@($appTitle,$steps)); $rootLayout.Controls.Add($banner,0,0)
$split=[Windows.Forms.SplitContainer]::new(); $split.Dock='Fill'; $split.Size=[Drawing.Size]::new(1250,780); $split.SplitterDistance=285; $split.SplitterWidth=12; $split.Panel1MinSize=240; $split.Panel2MinSize=650; $rootLayout.Controls.Add($split,0,1)
$library=[Windows.Forms.TableLayoutPanel]::new(); $library.Dock='Fill'; $library.ColumnCount=1; $library.RowCount=5
[void]$library.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
Add-LayoutRow $library 30; Add-LayoutRow $library 44; [void]$library.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100)); Add-LayoutRow $library 66; Add-LayoutRow $library 138; $split.Panel1.Controls.Add($library)
$libraryTitle=[Windows.Forms.Label]::new(); $libraryTitle.Text='REPORT LIBRARY'; $libraryTitle.AutoSize=$true; $libraryTitle.ForeColor=$script:muted; $libraryTitle.Font=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold)
$search=[Windows.Forms.TextBox]::new(); $search.Dock='Top'; $search.PlaceholderText='Search reports'; $search.Margin=[Windows.Forms.Padding]::new(0,4,8,10)
$list=[Windows.Forms.ListBox]::new(); $list.Dock='Fill'; $list.DisplayMember='DisplayName'; $list.BorderStyle='None'; $list.IntegralHeight=$false; $list.ItemHeight=36; $list.DrawMode='OwnerDrawFixed'; $list.Margin=[Windows.Forms.Padding]::new(0,0,8,12)
$list.Add_DrawItem({
param($sender,$eventArgs)
if($eventArgs.Index -lt 0){return}
$eventArgs.DrawBackground(); $name=$sender.Items[$eventArgs.Index].DisplayName
$color=if(($eventArgs.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0){[Drawing.Color]::White}else{$script:ink}
$bounds=$eventArgs.Bounds; $bounds.X+=10; $bounds.Width-=12
[Windows.Forms.TextRenderer]::DrawText($eventArgs.Graphics,$name,$sender.Font,$bounds,$color,([Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)); $eventArgs.DrawFocusRectangle()
})
$memoryNote=[Windows.Forms.Label]::new(); $memoryNote.Dock='Fill'; $memoryNote.Text='Read-only collection.'+[Environment]::NewLine+'Credentials stay in this session and are cleared when you exit.'; $memoryNote.ForeColor=$script:muted; $memoryNote.Font=[Drawing.Font]::new('Segoe UI',9); $memoryNote.Padding=[Windows.Forms.Padding]::new(0,4,10,0)
$leftActions=[Windows.Forms.FlowLayoutPanel]::new(); $leftActions.Dock='Fill'; $leftActions.FlowDirection='TopDown'; $leftActions.WrapContents=$false
$refresh=[Windows.Forms.Button]::new(); $refresh.Text='Refresh reports'; $credentials=[Windows.Forms.Button]::new(); $credentials.Text='Session credentials'; $forget=[Windows.Forms.Button]::new(); $forget.Text='Clear saved session'
foreach($button in @($credentials,$forget,$refresh)) { $button.Width=260; Set-ButtonStyle $button; $button.Margin=[Windows.Forms.Padding]::new(0,0,0,6); $leftActions.Controls.Add($button) }
$library.Controls.Add($libraryTitle,0,0); $library.Controls.Add($search,0,1); $library.Controls.Add($list,0,2); $library.Controls.Add($memoryNote,0,3); $library.Controls.Add($leftActions,0,4)
$content=[Windows.Forms.TableLayoutPanel]::new(); $content.Dock='Fill'; $content.RowCount=3; $content.ColumnCount=1
[void]$content.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
Add-LayoutRow $content 72; [void]$content.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100)); Add-LayoutRow $content 152; $split.Panel2.Controls.Add($content)
$reportHeader=[Windows.Forms.Panel]::new(); $reportHeader.Dock='Fill'
$selectedTitle=[Windows.Forms.Label]::new(); $selectedTitle.Font=[Drawing.Font]::new('Segoe UI',17,[Drawing.FontStyle]::Bold); $selectedTitle.ForeColor=$script:ink; $selectedTitle.AutoSize=$true; $selectedTitle.Text='Choose a report'
$selectedHint=[Windows.Forms.Label]::new(); $selectedHint.Location=[Drawing.Point]::new(2,39); $selectedHint.AutoSize=$true; $selectedHint.ForeColor=$script:muted; $selectedHint.Font=[Drawing.Font]::new('Segoe UI',10); $selectedHint.Text='The guide explains the purpose, access requirements and expected results.'
$reportHeader.Controls.AddRange(@($selectedTitle,$selectedHint)); $content.Controls.Add($reportHeader,0,0)
$tabs=[Windows.Forms.TabControl]::new(); $tabs.Dock='Fill'; $tabs.Padding=[Drawing.Point]::new(13,8)
$usageTab=[Windows.Forms.TabPage]::new('Start here'); $paramTab=[Windows.Forms.TabPage]::new('Parameters'); $resultTab=[Windows.Forms.TabPage]::new('Report'); $gridTab=[Windows.Forms.TabPage]::new('Record table'); $dataTab=[Windows.Forms.TabPage]::new('JSON'); $detailsTab=[Windows.Forms.TabPage]::new('Technical details')
foreach($tabPage in @($usageTab,$paramTab,$resultTab,$gridTab,$dataTab,$detailsTab)) { $tabPage.BackColor=[Drawing.Color]::White; $tabPage.Padding=[Windows.Forms.Padding]::new(18) }
$usage=New-ReadingBox; $details=New-ReadingBox; $reportText=New-ReadingBox
$jsonText=[Windows.Forms.TextBox]::new(); $jsonText.Multiline=$true; $jsonText.ReadOnly=$true; $jsonText.ScrollBars='Both'; $jsonText.Dock='Fill'; $jsonText.WordWrap=$false; $jsonText.Font=[Drawing.Font]::new('Consolas',10); $jsonText.BackColor=[Drawing.Color]::White; $jsonText.BorderStyle='None'
$grid=[Windows.Forms.DataGridView]::new(); $grid.Dock='Fill'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.AutoSizeColumnsMode='DisplayedCells'; $grid.ClipboardCopyMode='EnableAlwaysIncludeHeaderText'; $grid.BackgroundColor=[Drawing.Color]::White; $grid.BorderStyle='None'; $grid.RowTemplate.Height=32; $grid.EnableHeadersVisualStyles=$false; $grid.ColumnHeadersDefaultCellStyle.BackColor=$script:page; $grid.ColumnHeadersDefaultCellStyle.ForeColor=$script:ink; $grid.ColumnHeadersDefaultCellStyle.Font=[Drawing.Font]::new('Segoe UI',10,[Drawing.FontStyle]::Bold)
$fields=[Windows.Forms.FlowLayoutPanel]::new(); $fields.Dock='Fill'; $fields.FlowDirection='TopDown'; $fields.WrapContents=$false; $fields.AutoScroll=$true
$usageTab.Controls.Add($usage); $paramTab.Controls.Add($fields); $resultTab.Controls.Add($reportText); $gridTab.Controls.Add($grid); $dataTab.Controls.Add($jsonText); $detailsTab.Controls.Add($details)
$tabs.TabPages.AddRange(@($usageTab,$paramTab,$resultTab,$gridTab,$dataTab,$detailsTab)); $content.Controls.Add($tabs,0,1)
$bottom=[Windows.Forms.TableLayoutPanel]::new(); $bottom.Dock='Fill'; $bottom.ColumnCount=1; $bottom.RowCount=3; $bottom.Padding=[Windows.Forms.Padding]::new(0,12,0,0)
[void]$bottom.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
Add-LayoutRow $bottom 44; Add-LayoutRow $bottom 26; [void]$bottom.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent,100))
$actions=[Windows.Forms.FlowLayoutPanel]::new(); $actions.Dock='Fill'
$run=[Windows.Forms.Button]::new(); $run.Text='Run report'; $run.Enabled=$false; $run.Width=135; Set-ButtonStyle $run $true
$stop=[Windows.Forms.Button]::new(); $stop.Text='Cancel'; $stop.Enabled=$false; $stop.Width=100; Set-ButtonStyle $stop
$open=[Windows.Forms.Button]::new(); $open.Text='Open report folder'; $open.Width=185; $open.Enabled=$false; Set-ButtonStyle $open; $actions.Controls.AddRange(@($run,$stop,$open))
$statusLabel=[Windows.Forms.Label]::new(); $statusLabel.Text='STATUS AND MICROSOFT SIGN-IN'; $statusLabel.ForeColor=$script:muted; $statusLabel.AutoSize=$true; $statusLabel.Font=[Drawing.Font]::new('Segoe UI',9,[Drawing.FontStyle]::Bold)
$status=[Windows.Forms.TextBox]::new(); $status.Dock='Fill'; $status.Multiline=$true; $status.ReadOnly=$true; $status.ScrollBars='Vertical'; $status.BackColor=[Drawing.Color]::White; $status.Text='Ready. Choose a report to see its guide.'; $status.Font=[Drawing.Font]::new('Segoe UI',10)
$bottom.Controls.Add($actions,0,0); $bottom.Controls.Add($statusLabel,0,1); $bottom.Controls.Add($status,0,2); $content.Controls.Add($bottom,0,2)
function Update-ParameterLayout {
$width=[Math]::Max(350,$fields.ClientSize.Width-30)
foreach($card in $fields.Controls) {
    $card.Width=$width
    if($card.Tag -is [hashtable]) {
        $card.MinimumSize=[Drawing.Size]::new($width,0); $card.MaximumSize=[Drawing.Size]::new($width,0)
        foreach($label in @($card.Tag.Title,$card.Tag.Help)) { $label.MaximumSize=[Drawing.Size]::new($width-4,0) }
    } else { $card.MaximumSize=[Drawing.Size]::new($width,0) }
}
}
$fields.Add_SizeChanged({Update-ParameterLayout})
function Add-ParameterCard {
param([hashtable]$Parameter)
$card=[Windows.Forms.TableLayoutPanel]::new(); $card.ColumnCount=1; $card.RowCount=3; $card.AutoSize=$true; $card.AutoSizeMode='GrowAndShrink'; $card.Margin=[Windows.Forms.Padding]::new(0,0,0,6); $card.Width=650
[void]$card.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100))
$title=[Windows.Forms.Label]::new(); $title.AutoSize=$true; $title.Font=[Drawing.Font]::new('Segoe UI',11,[Drawing.FontStyle]::Bold); $title.ForeColor=$script:ink; $title.Text=$Parameter.label+$(if($Parameter.required){'  ·  Required'}else{'  ·  Optional'})
$help=[Windows.Forms.Label]::new(); $help.AutoSize=$true; $help.ForeColor=$script:muted; $help.Font=[Drawing.Font]::new('Segoe UI',10); $help.Margin=[Windows.Forms.Padding]::new(0,4,0,4); $help.Text=[string]$Parameter.help
if($Parameter.type -eq 'boolean') { $control=[Windows.Forms.CheckBox]::new(); $control.AutoSize=$true; $control.Text='Include this in the report'; $control.Checked=[bool]$Parameter.default }
elseif($Parameter.type -eq 'integer') { $control=[Windows.Forms.NumericUpDown]::new(); $control.Minimum=1; $control.Maximum=36500; $control.Value=[decimal]$Parameter.default; $control.Width=160 }
else {
$control=[Windows.Forms.TextBox]::new(); $control.Dock='Fill'; $control.Margin=[Windows.Forms.Padding]::new(0,6,0,0)
if($Parameter.ContainsKey('placeholder')){$control.PlaceholderText=$Parameter.placeholder}
if($Parameter.ContainsKey('default')) { $control.Text=if($Parameter.type -eq 'file'){ConvertTo-LauncherFilePath $Parameter.default $PSScriptRoot}else{([string]$Parameter.default).Replace('{LauncherRoot}',$PSScriptRoot)} }
}
$card.Controls.Add($title,0,0); $card.Controls.Add($help,0,1)
if($Parameter.type -eq 'file') {
$pathRow=[Windows.Forms.TableLayoutPanel]::new(); $pathRow.Dock='Fill'; $pathRow.ColumnCount=2; $pathRow.RowCount=1; $pathRow.Height=43; $pathRow.Margin=[Windows.Forms.Padding]::new(0)
[void]$pathRow.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent,100)); [void]$pathRow.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute,108))
$browse=[Windows.Forms.Button]::new(); $browse.Text='Browse…'; $browse.Dock='Fill'; Set-ButtonStyle $browse; $browse.Tag=$control
$browse.Add_Click({
param($sender,$eventArgs)
$picker=[Windows.Forms.OpenFileDialog]::new(); $picker.Title='Choose the verified AZQR executable'; $picker.Filter='AZQR executable (azqr.exe)|azqr.exe|Executable files (*.exe)|*.exe'; $picker.CheckFileExists=$true
try { $current=$sender.Tag.Text; if($current -and (Test-Path -LiteralPath (Split-Path $current -Parent))) { $picker.InitialDirectory=Split-Path $current -Parent }; if($picker.ShowDialog($form) -eq 'OK') { $sender.Tag.Text=ConvertTo-LauncherFilePath $picker.FileName $PSScriptRoot } } finally { $picker.Dispose() }
})
$pathRow.Controls.Add($control,0,0); $pathRow.Controls.Add($browse,1,0); $card.Controls.Add($pathRow,0,2)
} else { $card.Controls.Add($control,0,2) }
$card.Tag=@{Title=$title;Help=$help}; $fields.Controls.Add($card); $script:inputs[$Parameter.name]=$control
}

function Set-Busy([bool]$busy) {
    foreach($control in @($list,$search,$refresh,$credentials,$forget,$fields)) { $control.Enabled=-not $busy }
    $stop.Enabled=$busy
    $run.Enabled=(-not $busy -and $null -ne $list.SelectedItem -and $list.SelectedItem.Errors.Count -eq 0)
}
function Update-List {
    $list.Items.Clear()
    foreach($item in $script:catalog) {
        if(($item.DisplayName+' '+$item.Name+' '+$item.Purpose).IndexOf($search.Text,[StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$list.Items.Add($item) }
    }
    if($list.Items.Count) { $list.SelectedIndex=0 }
}
function Refresh-Catalog {
    try { $script:catalog=@(Get-ScriptCatalog $ScriptsRoot | Sort-Object Name); Update-List; $status.Text="$($script:catalog.Count) reporting adapters. Session credentials are memory-only." }
    catch { $status.Text='Cannot discover report manifests. Check the scripts root and directions files.' }
}
function Show-CredentialDialog {
    param([string]$PreviewFile)
    $dialog=[Windows.Forms.Form]::new(); $dialog.Text='Session credentials'; $dialog.Size=[Drawing.Size]::new(640,600); $dialog.StartPosition='CenterParent'; $dialog.Font=$form.Font; $dialog.FormBorderStyle='FixedDialog'; $dialog.MaximizeBox=$false; $dialog.MinimizeBox=$false; $dialog.BackColor=[Drawing.Color]::White
    $panel=[Windows.Forms.FlowLayoutPanel]::new(); $panel.Dock='Fill'; $panel.FlowDirection='TopDown'; $panel.WrapContents=$false; $panel.Padding=[Windows.Forms.Padding]::new(24)
    $heading=[Windows.Forms.Label]::new(); $heading.Text='Use credentials across reports'; $heading.AutoSize=$true; $heading.Font=[Drawing.Font]::new('Segoe UI',16,[Drawing.FontStyle]::Bold); $heading.Margin=[Windows.Forms.Padding]::new(0,0,0,14)
    $kind=[Windows.Forms.ComboBox]::new(); $kind.DropDownStyle='DropDownList'; $kind.Width=560; $kind.Margin=[Windows.Forms.Padding]::new(0,0,0,12)
    $kind.Items.AddRange(@('Directory account','Azure application')); $kind.SelectedIndex=0
    $hint=[Windows.Forms.Label]::new(); $hint.AutoSize=$true; $hint.MaximumSize=[Drawing.Size]::new(560,0); $hint.ForeColor=$script:muted; $hint.Margin=[Windows.Forms.Padding]::new(0,0,0,16)
    $usernameLabel=[Windows.Forms.Label]::new(); $usernameLabel.AutoSize=$true
    $username=[Windows.Forms.TextBox]::new(); $username.Width=560; $username.Margin=[Windows.Forms.Padding]::new(0,4,0,14)
    $passwordLabel=[Windows.Forms.Label]::new(); $passwordLabel.AutoSize=$true
    $password=[Windows.Forms.TextBox]::new(); $password.Width=560; $password.UseSystemPasswordChar=$true; $password.Margin=[Windows.Forms.Padding]::new(0,4,0,14)
    $note=[Windows.Forms.Label]::new(); $note.AutoSize=$true; $note.MaximumSize=[Drawing.Size]::new(560,0); $note.ForeColor=$script:muted; $note.Text='• Kept in memory for this session.'+[Environment]::NewLine+'• Cleared when you exit or choose Clear saved session.'; $note.Margin=[Windows.Forms.Padding]::new(0,0,0,18)
    $save=[Windows.Forms.Button]::new(); $save.Text='Use in session'; $save.Width=160; Set-ButtonStyle $save $true
    $updateCredentialHelp={
        $username.Clear(); $password.Clear()
        if($kind.SelectedIndex -eq 1) {
            $hint.Text='For Azure resource review. Use an existing application with Reader access to the subscription.'
            $usernameLabel.Text='Application ID'; $username.PlaceholderText='Application (client) ID from Microsoft Entra ID'
            $passwordLabel.Text='Client secret'; $password.PlaceholderText='Secret value, not the secret ID'
        } else {
            $hint.Text='For AD computer activity. Leave this unset to use your current Windows identity. Intune uses Microsoft sign-in instead.'
            $usernameLabel.Text='Directory username'; $username.PlaceholderText='DOMAIN\user or user@domain.example'
            $passwordLabel.Text='Password'; $password.PlaceholderText='Directory account password'
        }
    }
    $kind.Add_SelectedIndexChanged($updateCredentialHelp); & $updateCredentialHelp
    $save.Add_Click({
        if(-not $username.Text -or -not $password.Text) { return }
        $key=if($kind.SelectedIndex -eq 1){'AzureServicePrincipal'}else{'ActiveDirectory'}
        $secret=ConvertTo-SecureString $password.Text -AsPlainText -Force
        if($script:session.Credentials.ContainsKey($key)) { $script:session.Credentials[$key].Password.Dispose() }
        $script:session.Credentials[$key]=[pscredential]::new($username.Text,$secret)
        $password.Clear(); $username.Clear(); $dialog.DialogResult='OK'; $dialog.Close()
    })
    $panel.Controls.AddRange(@($heading,$kind,$hint,$usernameLabel,$username,$passwordLabel,$password,$note,$save)); $dialog.Controls.Add($panel); $dialog.AcceptButton=$save
    try {
        if($PreviewFile) {
            $kind.SelectedIndex=1; $dialog.ShowInTaskbar=$false; $dialog.StartPosition='Manual'; $dialog.Location=[Drawing.Point]::new(-30000,-30000); $dialog.Opacity=0; $dialog.Show()
            [Windows.Forms.Application]::DoEvents()
            if($save.Bottom -gt $panel.ClientSize.Height) { throw 'Credential dialog action is clipped.' }
            $bitmap=[Drawing.Bitmap]::new($dialog.Width,$dialog.Height)
            try { $dialog.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$dialog.Width,$dialog.Height)); $bitmap.Save($PreviewFile,[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
            $dialog.Hide()
        } else { [void]$dialog.ShowDialog($form) }
    } finally { $password.Clear(); $username.Clear(); $dialog.Dispose() }
}
$credentials.Add_Click({Show-CredentialDialog})
$forget.Add_Click({Clear-LauncherSession $script:session; $script:session=New-LauncherSession; $status.Text='Session credentials and access tokens cleared.'})
$search.Add_TextChanged({Update-List}); $refresh.Add_Click({Refresh-Catalog})
$list.Add_SelectedIndexChanged({
    foreach($old in @($fields.Controls)) { $fields.Controls.Remove($old); $old.Dispose() }
    $script:inputs=@{}; $item=$list.SelectedItem
    Set-Busy ($null -ne $script:job)
    if($null -eq $item) { $usage.Clear(); $details.Clear(); $selectedTitle.Text='Choose a report'; $selectedHint.Text='Select a report from the library.'; return }
    $selectedTitle.Text=$item.DisplayName
    $selectedHint.Text='Read-only report  ·  '+$item.Name
    if($item.Manifest.ContainsKey('guide')) { Set-LauncherGuide $usage $item.Manifest } else { Set-LauncherTechnicalDetails $usage $item.Usage }
    Set-LauncherTechnicalDetails $details $item.Usage
    if($item.Errors.Count) { Add-GuideParagraph $usage ('Report unavailable: '+($item.Errors -join '; ')) 'heading' }
    $intro=[Windows.Forms.Label]::new(); $intro.AutoSize=$true; $intro.MaximumSize=[Drawing.Size]::new(650,0); $intro.ForeColor=$script:muted; $intro.Margin=[Windows.Forms.Padding]::new(0,0,0,12)
    $intro.Text='Enter the values below. Required fields define the account or system to read. Enter credentials separately using Session credentials.'
    $fields.Controls.Add($intro)
    foreach($parameter in $item.Parameters) { Add-ParameterCard $parameter }
    Update-ParameterLayout
    $tabs.SelectedTab=$usageTab
})
function Show-ReportResult {
            Set-LauncherTechnicalDetails $reportText (Get-Content -LiteralPath $script:lastReport.MarkdownPath -Raw)
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
            $gridTab.Text="Record table ($($rows.Count))"

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
            Set-LauncherTechnicalDetails $reportText (Get-Content -LiteralPath $script:lastReport.MarkdownPath -Raw)
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
                if($value) { $parameters[$parameter.name]=if($parameter.type -eq 'integer') { [int]$value } elseif($parameter.type -eq 'file') { ConvertTo-LauncherFilePath $value $PSScriptRoot } else { $value } }
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
            if($usage.Text -notmatch 'Before you start' -or $usage.Rtf -notmatch '\\pntext') { throw 'Readable guide headings or bullets missing.' }
            foreach($parameter in $list.SelectedItem.Parameters) {
                $editor=$script:inputs[$parameter.name]
                if($parameter.type -eq 'file' -and ($editor.Text -match '/' -or -not [IO.Path]::IsPathFullyQualified($editor.Text))) { throw 'Executable default must be a consistent absolute Windows path.' }
                if($parameter.type -eq 'integer' -and $editor -isnot [Windows.Forms.NumericUpDown]) { throw 'Integer parameter needs a numeric editor.' }
            }
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
        if($PreviewPath) {
            # Render this application's own controls offscreen using synthetic data only.
            [void][IO.Directory]::CreateDirectory($PreviewPath)
            $list.SelectedIndex=@($list.Items | ForEach-Object {$_.Manifest.id}).IndexOf('azqr-readonly')
            $gridTab.Text='Record table'
            $form.ShowInTaskbar=$false; $form.StartPosition='Manual'; $form.Location=[Drawing.Point]::new(-30000,-30000); $form.Opacity=0
            $form.Show(); [Windows.Forms.Application]::DoEvents()
            foreach($view in @('guide','parameters','compact')) {
                $tabs.SelectedTab=if($view -eq 'guide'){$usageTab}else{$paramTab}
                if($view -eq 'compact') { $form.Size=$form.MinimumSize }
                $null=$form.Handle
                $form.PerformLayout(); $rootLayout.PerformLayout(); $split.PerformLayout(); $content.PerformLayout(); $tabs.PerformLayout(); $fields.PerformLayout()
                Update-ParameterLayout
                [Windows.Forms.Application]::DoEvents()
                if($tabs.Right -gt $content.ClientSize.Width -or $status.Right -gt $bottom.ClientSize.Width) { throw 'Content extends beyond the resized window.' }
                foreach($card in $fields.Controls) { if($card.Right -gt $fields.ClientSize.Width) { throw 'A parameter field extends beyond its panel.' } }
                $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height)
                try { $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save((Join-Path $PreviewPath ("launcher-$view.png")),[Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }
            }
            Show-CredentialDialog -PreviewFile (Join-Path $PreviewPath 'launcher-credentials.png')
            $form.Hide()
        }
        'PASS: three manifests, formatted guides with bullets, typed parameter controls, Windows paths, integrity gate, readable report, record table and JSON initialize in the Windows UI.'
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


