function ConvertTo-LauncherFilePath {
    param([string]$Value,[string]$Root)
    $path=[Environment]::ExpandEnvironmentVariables($Value.Trim().Trim('"')).Replace('{LauncherRoot}',$Root).Replace('/','\')
    if(-not [IO.Path]::IsPathRooted($path)) { $path=Join-Path $Root $path }
    [IO.Path]::GetFullPath($path)
}
function Add-GuideParagraph {
    param([Windows.Forms.RichTextBox]$Box,[string]$Text,[ValidateSet('title','heading','body','bullet','step')][string]$Style='body')
    $Box.SelectionStart=$Box.TextLength
    $Box.SelectionLength=0
    $fontSize=switch($Style){title{20} heading{13} default{11}}
    $fontStyle=if($Style -in @('title','heading')){[Drawing.FontStyle]::Bold}else{[Drawing.FontStyle]::Regular}
    $Box.SelectionFont=[Drawing.Font]::new('Segoe UI',$fontSize,$fontStyle)
    $Box.SelectionColor=if($Style -in @('title','heading')){[Drawing.ColorTranslator]::FromHtml('#173454')}else{[Drawing.ColorTranslator]::FromHtml('#253547')}
    $Box.SelectionBullet=($Style -eq 'bullet')
    $Box.SelectionIndent=if($Style -eq 'bullet'){18}else{0}
    $Box.SelectionHangingIndent=if($Style -eq 'bullet'){4}else{0}
    $Box.AppendText($Text+[Environment]::NewLine)
    $Box.SelectionBullet=$false; $Box.SelectionIndent=0; $Box.SelectionHangingIndent=0
    $Box.AppendText([Environment]::NewLine)
}
function Set-LauncherGuide {
    param([Windows.Forms.RichTextBox]$Box,[hashtable]$Manifest)
    $Box.Clear()
    Add-GuideParagraph $Box $Manifest.displayName 'title'
    Add-GuideParagraph $Box 'What this report is for' 'heading'
    Add-GuideParagraph $Box $Manifest.guide.overview
    Add-GuideParagraph $Box 'Before you start' 'heading'
    foreach($text in $Manifest.guide.prerequisites) { Add-GuideParagraph $Box $text 'bullet' }
    Add-GuideParagraph $Box 'Run the report' 'heading'
    $number=1
    foreach($text in $Manifest.guide.steps) { Add-GuideParagraph $Box ("$number. "+$text) 'step'; $number++ }
    Add-GuideParagraph $Box 'What you will see' 'heading'
    foreach($text in $Manifest.guide.outcomes) { Add-GuideParagraph $Box $text 'bullet' }
    Add-GuideParagraph $Box 'Good to know' 'heading'
    foreach($text in $Manifest.guide.notes) { Add-GuideParagraph $Box $text 'bullet' }
    $Box.SelectionStart=0; $Box.SelectionLength=0; $Box.ScrollToCaret()
}
function Set-LauncherTechnicalDetails {
    param([Windows.Forms.RichTextBox]$Box,[string]$Text)
    $Box.Clear()
    $paragraphs=[regex]::Split($Text.Trim(),'(?:\r?\n){2,}')
    foreach($paragraph in $paragraphs) {
        $lines=@($paragraph -split '\r?\n')
        if($paragraph -match '^#{1,6}\s+') {
            Add-GuideParagraph $Box ($paragraph -replace '^#{1,6}\s+','') 'heading'
        } elseif($paragraph -match '^\s*[-*]\s+') {
            foreach($line in $lines) {
                if($line -match '^\s*[-*]\s+') { Add-GuideParagraph $Box ($line -replace '^\s*[-*]\s+','') 'bullet' }
                else { Add-GuideParagraph $Box $line }
            }
        } elseif($paragraph -match '^\s*[\{\[]') {
            # Keep JSON evidence intact, including escapes and indentation.
            Add-GuideParagraph $Box $paragraph
        } elseif($lines.Count -eq 1 -and $paragraph.Length -lt 95 -and $paragraph -notmatch '^https?://') {
            Add-GuideParagraph $Box $paragraph 'heading'
        } else {
            # Preserve commands, URLs and numbered lists. Join wrapped prose for responsive reading.
            $text=if($paragraph -match '(?m)^\s*(?:\d+[.)]\s|https?://|pwsh\s|powershell.exe\s|/v1.0/|/beta/)') { $paragraph } else { $lines -join ' ' }
            Add-GuideParagraph $Box $text
        }
    }
    $Box.SelectionStart=0; $Box.SelectionLength=0; $Box.ScrollToCaret()
}
Export-ModuleMember ConvertTo-LauncherFilePath,Add-GuideParagraph,Set-LauncherGuide,Set-LauncherTechnicalDetails

