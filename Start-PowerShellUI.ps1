[CmdletBinding()]
param([string]$ScriptsRoot=$PSScriptRoot)
$ErrorActionPreference='Stop'
if($env:OS -ne 'Windows_NT') { throw 'Windows is required for the desktop interface.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (Join-Path $PSScriptRoot 'infrastructure/Catalog.psm1') -Force
[Windows.Forms.Application]::EnableVisualStyles()
$form=New-Object Windows.Forms.Form
$form.Text='PowerShell Script Library'; $form.Size=New-Object Drawing.Size(1100,800)
$form.MinimumSize=New-Object Drawing.Size(900,650); $form.StartPosition='CenterScreen'
$split=New-Object Windows.Forms.SplitContainer
$split.Dock='Fill'; $split.SplitterDistance=280; $form.Controls.Add($split)
$list=New-Object Windows.Forms.ListBox; $list.Dock='Fill'; $list.DisplayMember='Name'
$search=New-Object Windows.Forms.TextBox; $search.Dock='Top'
$refresh=New-Object Windows.Forms.Button; $refresh.Text='Refresh scripts'; $refresh.Dock='Bottom'
$split.Panel1.Controls.AddRange(@($list,$search,$refresh))
$tabs=New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'
$usageTab=New-Object Windows.Forms.TabPage; $usageTab.Text='Usage and expected output'
$paramTab=New-Object Windows.Forms.TabPage; $paramTab.Text='Parameters'
$resultTab=New-Object Windows.Forms.TabPage; $resultTab.Text='Results'
$usage=New-Object Windows.Forms.TextBox; $usage.Multiline=$true; $usage.ReadOnly=$true; $usage.ScrollBars='Both'; $usage.Dock='Fill'
$output=New-Object Windows.Forms.TextBox; $output.Multiline=$true; $output.ReadOnly=$true; $output.ScrollBars='Both'; $output.Dock='Fill'
$fields=New-Object Windows.Forms.FlowLayoutPanel
$fields.Dock='Fill'; $fields.FlowDirection='TopDown'; $fields.WrapContents=$false; $fields.AutoScroll=$true
$usageTab.Controls.Add($usage); $paramTab.Controls.Add($fields); $resultTab.Controls.Add($output)
$tabs.TabPages.AddRange(@($usageTab,$paramTab,$resultTab))
$actions=New-Object Windows.Forms.FlowLayoutPanel; $actions.Dock='Bottom'; $actions.Height=40
$run=New-Object Windows.Forms.Button; $run.Text='Run'; $run.Enabled=$false
$stop=New-Object Windows.Forms.Button; $stop.Text='Stop'; $stop.Enabled=$false
$status=New-Object Windows.Forms.Label; $status.AutoSize=$true; $status.Text='Ready'
$actions.Controls.AddRange(@($run,$stop,$status))
$split.Panel2.Controls.AddRange(@($tabs,$actions))
$script:catalog=@(); $script:inputs=@{}; $script:process=$null; $script:temp=$null
function Update-List {
$list.Items.Clear()
foreach($item in $script:catalog) { if($item.Name.IndexOf($search.Text,[StringComparison]::OrdinalIgnoreCase) -ge 0) { [void]$list.Items.Add($item) } }
}
function Refresh-Catalog {
try { $script:catalog=@(Get-ScriptCatalog -Root $ScriptsRoot | Sort-Object Name); Update-List; $status.Text="$($script:catalog.Count) scripts" }
catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Discovery error') }
}
$search.Add_TextChanged({Update-List}); $refresh.Add_Click({Refresh-Catalog})
$list.Add_SelectedIndexChanged({
$fields.Controls.Clear(); $script:inputs=@{}; $item=$list.SelectedItem
$run.Enabled=($null -ne $item -and $null -eq $script:process -and $item.Errors.Count -eq 0)
if($null -eq $item) { $usage.Clear(); return }
$usage.Text=$item.Usage
if($item.Errors.Count) { $usage.Text += [Environment]::NewLine+($item.Errors -join [Environment]::NewLine) }
foreach($parameter in $item.Parameters) {
$label=New-Object Windows.Forms.Label; $label.AutoSize=$true; $label.MaximumSize=New-Object Drawing.Size(600,0)
$label.Text=$parameter.Declaration; $fields.Controls.Add($label)
if($parameter.IsSwitch) { $control=New-Object Windows.Forms.CheckBox; $control.Text=$parameter.Name }
else { $control=New-Object Windows.Forms.TextBox; $control.Width=550 }
$fields.Controls.Add($control); $script:inputs[$parameter.Name]=$control
}
})
$timer=New-Object Windows.Forms.Timer; $timer.Interval=250
$timer.Add_Tick({
if($null -eq $script:process -or -not $script:process.HasExited) { return }
$timer.Stop()
$output.Text=$script:stdout.GetAwaiter().GetResult()+$script:stderr.GetAwaiter().GetResult()
$status.Text="Completed (exit $($script:process.ExitCode))"
$script:process.Dispose(); $script:process=$null
Remove-Item -LiteralPath $script:temp -Force; $script:temp=$null
$stop.Enabled=$false; $refresh.Enabled=$true; $list.Enabled=$true; $search.Enabled=$true
$run.Enabled=($null -ne $list.SelectedItem -and $list.SelectedItem.Errors.Count -eq 0)
})
$run.Add_Click({
try {
$parameters=@{}
foreach($key in $script:inputs.Keys) {
$control=$script:inputs[$key]
if($control -is [Windows.Forms.CheckBox]) { if($control.Checked) { $parameters[$key]=$true } }
elseif($control.Text.Length) { $parameters[$key]=$control.Text }
}
$script:temp=[IO.Path]::GetTempFileName()
@{Script=$list.SelectedItem.Path; Parameters=$parameters} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $script:temp -Encoding UTF8
$info=New-Object Diagnostics.ProcessStartInfo
$info.FileName=(Get-Process -Id $PID).Path
$runner=Join-Path $PSScriptRoot 'infrastructure/Invoke-Script.ps1'
$info.Arguments='-NoProfile -NonInteractive -File "'+$runner+'" -RequestPath "'+$script:temp+'"'
$info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
$script:process=New-Object Diagnostics.Process; $script:process.StartInfo=$info; [void]$script:process.Start()
$script:stdout=$script:process.StandardOutput.ReadToEndAsync(); $script:stderr=$script:process.StandardError.ReadToEndAsync()
$output.Clear(); $tabs.SelectedTab=$resultTab; $status.Text='Running...'
$run.Enabled=$false; $stop.Enabled=$true; $refresh.Enabled=$false; $list.Enabled=$false; $search.Enabled=$false
$timer.Start()
} catch {
if($script:temp) { Remove-Item -LiteralPath $script:temp -Force -ErrorAction SilentlyContinue; $script:temp=$null }
if($script:process) { $script:process.Dispose(); $script:process=$null }
[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Run error')
}
})
$stop.Add_Click({if($script:process -and -not $script:process.HasExited) { $script:process.Kill(); $status.Text='Stopping...' }})
$form.Add_FormClosing({
if($script:process -and -not $script:process.HasExited) {
[void][Windows.Forms.MessageBox]::Show('Stop the running script before closing.','Script running')
$_.Cancel=$true
}
})
Refresh-Catalog
try { [void]$form.ShowDialog() } finally { $timer.Dispose(); $form.Dispose() }
