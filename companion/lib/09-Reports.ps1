# =====================================================================
#  09-Reports.ps1  -  HTML PAGES AND REPORTS
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The WinRM toolkit's page style: a banner in the console colour, a
#  facts bar, tables whose rows are coloured by their Light, inline CSS
#  only (every page opens offline), the favicon drawn at start-up.
#  Export-ConsoleReport writes reports\<Console>-<stamp>.html and a CSV
#  beside it; New-DetailsHtml builds the details and Help pages.
# =====================================================================

$script:NonAsciiRegex = New-Object System.Text.RegularExpressions.Regex ('[^\x00-\x7F]', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function ConvertTo-PageText {
    # Every page is plain ASCII; text read from a source (a title, a signer) may carry typographic marks: folded here.
    param([string]$Text)
    if ($null -eq $Text -or -not $script:NonAsciiRegex.IsMatch($Text)) { return $Text }
    $sb = New-Object System.Text.StringBuilder $Text.Length
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 128) { [void]$sb.Append($ch); continue }
        switch ($code) {
            { $_ -in 0x2018, 0x2019, 0x201A, 0x2032, 0x00B4 } { [void]$sb.Append("'"); break }
            { $_ -in 0x201C, 0x201D, 0x201E, 0x2033, 0x00AB, 0x00BB } { [void]$sb.Append('"'); break }
            { $_ -in 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212 } { [void]$sb.Append('-'); break }
            { $_ -in 0x00A0, 0x2007, 0x2009, 0x202F } { [void]$sb.Append(' '); break }
            0x2026 { [void]$sb.Append('...'); break }
            0x2022 { [void]$sb.Append('*'); break }
            default { [void]$sb.Append('?') }
        }
    }
    return $sb.ToString()
}

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode((ConvertTo-PageText $Text))
}

function Get-HtmlLink {
    # A web address as a link for a page (the details window hands a click to the operator's browser).  Anything that
    # is not an http or https address comes back as plain text.
    param([string]$Url, [string]$Text = '')
    if (-not $Text) { $Text = $Url }
    if ([string]$Url -notmatch '^https?://[^\s"<>]+$') { return (ConvertTo-HtmlSafe $Text) }
    return ('<a href="{0}">{1}</a>' -f [System.Net.WebUtility]::HtmlEncode($Url), (ConvertTo-HtmlSafe $Text))
}

function ConvertTo-ReportTable {
    # Rows -> one HTML table.  $Columns picks and orders the properties; the Light column (if any) colours the row.
    param([object[]]$Rows, [string[]]$Columns, [string]$LightColumn = 'Light', [string[]]$NoWrap = @())
    if (-not $Rows -or $Rows.Count -eq 0) { return '<p class="empty">(no rows)</p>' }
    if (-not $Columns -or $Columns.Count -eq 0) { $Columns = @($Rows[0].PSObject.Properties | ForEach-Object { $_.Name }) }
    $open = @{}; foreach ($col in $Columns) { $open[$col] = $(if (@($NoWrap) -contains $col) { '<td class="nw">' } else { '<td>' }) }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($col in $Columns) { [void]$sb.Append('<th>' + [System.Net.WebUtility]::HtmlEncode((ConvertTo-PageText $col)) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    $hasLight = ($LightColumn -and $Rows[0].PSObject.Properties[$LightColumn])
    $rx = $script:NonAsciiRegex
    foreach ($r in $Rows) {
        if ($hasLight) { [void]$sb.Append('<tr class="').Append([System.Net.WebUtility]::HtmlEncode([string]$r.$LightColumn)).Append('">') } else { [void]$sb.Append('<tr>') }
        foreach ($col in $Columns) {
            $v = $r.$col
            if ($v -is [array]) { $v = ($v -join ', ') }
            $s = [string]$v; if ($rx.IsMatch($s)) { $s = ConvertTo-PageText $s }
            [void]$sb.Append($open[$col]).Append([System.Net.WebUtility]::HtmlEncode($s)).Append('</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-ReportCss {
    param([string]$Colour = 'MidnightBlue', [string]$Text = 'White')
    return @"
<style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:0;color:#222;background:#fff}
.banner{background:$Colour;color:$Text;padding:14px 24px}.banner h1{margin:0;font-size:22px}.banner p{margin:4px 0 0 0;opacity:.9}
.meta{padding:10px 24px;background:#f4f4f4;border-bottom:1px solid #ddd}.meta span{margin-right:24px;display:inline-block}
section{padding:12px 24px}h2{font-size:16px;margin:18px 0 6px 0;border-bottom:2px solid #ccc}
table{border-collapse:collapse;width:100%;margin-bottom:12px}th{background:#333;color:#fff;text-align:left;padding:5px 8px;position:sticky;top:0}
td{padding:4px 8px;border-bottom:1px solid #e3e3e3;vertical-align:top;font-size:12px}tr:hover td{background:#f0f6ff}
tr.Red td{background:#f8d7da}tr.Amber td{background:#fff3cd}tr.Green td{background:#d4edda}tr.Blue td{background:#dbeafa}tr.Grey td{background:#e9ecef;color:#555}
.notes{font-size:12px;color:#444}.empty{color:#777;font-style:italic}.foot{padding:10px 24px;color:#777;font-size:11px}
input#filter{margin:8px 0;padding:4px 8px;width:320px}
pre{font-family:Consolas,monospace;font-size:12px;background:#f7f7f7;padding:8px;white-space:pre-wrap;word-wrap:break-word}
ul{margin:4px 0 8px 18px}ol{margin:4px 0 8px 22px}p{max-width:1100px;line-height:1.45;margin:6px 0 10px 0}
.cell{display:inline-block;border:1px solid #bbb;padding:2px 8px;font-size:12px;background:#fff;min-width:70px;white-space:nowrap}
.btn{display:inline-block;border:1px solid #888;border-radius:3px;padding:4px 10px;font-size:12px;background:#f0f0f0;box-shadow:1px 1px 0 #bbb;white-space:nowrap}
table.mock td,table.mock th{border:1px solid #d0d0d0;font-size:12px;padding:3px 6px}table.mock th{background:#e8e8e8;color:#222;position:static}
.swatch{display:inline-block;width:18px;height:14px;border:1px solid #999;vertical-align:middle;margin-right:6px}
code{background:#f3f3f3;padding:0 3px}.hint{background:#fff8dc;border:1px solid #e6d9a8;padding:6px 10px;font-size:12px;margin:4px 0}
img{max-width:100%}td.nw{white-space:nowrap}
@page{margin:12mm}
@media print{*{-webkit-print-color-adjust:exact;print-color-adjust:exact}body{font-size:11px}thead{display:table-header-group}th{position:static}tr{break-inside:avoid;page-break-inside:avoid}input#filter{display:none}}
</style>
"@
}

function New-DetailsHtml {
    # A self-contained page: banner, a line of facts, then sections (@{ Heading; Rows; Columns; [LightColumn]; [Note]; [NoWrap] } /
    # @{ Heading; Lines } / @{ Heading; Text } / @{ Heading; Html }).
    param([string]$Title, [string]$Subtitle = '', [string]$Console = 'Library', [object[]]$Facts = @(), [object[]]$Sections = @())
    $colour = $script:Config.ConsoleColours[$Console]; if (-not $colour) { $colour = 'MidnightBlue' }
    $text = $script:Config.ConsoleText[$Console]; if (-not $text) { $text = 'White' }
    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>' + (ConvertTo-HtmlSafe $Title) + '</title>' + (Get-ToolkitFaviconTag))
    [void]$html.AppendLine((Get-ReportCss -Colour $colour -Text $text) + '</head><body>')
    [void]$html.AppendLine('<div class="banner"><h1>' + (ConvertTo-HtmlSafe $Title) + '</h1><p>' + (ConvertTo-HtmlSafe $Subtitle) + '</p></div>')
    $pairs = @()
    $flat = @($Facts); $i = 0
    while ($i -lt $flat.Count) {
        if ($flat[$i] -is [array] -and $flat[$i].Count -ge 2) { $pairs += , @([string]$flat[$i][0], [string]$flat[$i][1]); $i++ }
        elseif ($i + 1 -lt $flat.Count) { $pairs += , @([string]$flat[$i], [string]$flat[$i + 1]); $i += 2 }
        else { $i++ }
    }
    if ($pairs.Count -gt 0) { [void]$html.AppendLine('<div class="meta">' + (($pairs | ForEach-Object { '<span><b>' + (ConvertTo-HtmlSafe $_[0]) + ':</b> ' + (ConvertTo-HtmlSafe $_[1]) + '</span>' }) -join '') + '</div>') }
    foreach ($sec in @($Sections)) {
        $count = ''; if ($sec.ContainsKey('Rows')) { $count = ' (' + @($sec.Rows).Count + ')' }
        [void]$html.AppendLine('<section>')
        if ([string]$sec.Heading) { [void]$html.AppendLine('<h2>' + (ConvertTo-HtmlSafe ([string]$sec.Heading)) + $count + '</h2>') }
        if ($sec.ContainsKey('Note') -and $sec.Note) { [void]$html.AppendLine('<p class="notes">' + (ConvertTo-HtmlSafe ([string]$sec.Note)) + '</p>') }
        if ($sec.ContainsKey('Rows')) {
            $lc = 'Light'; if ($sec.ContainsKey('LightColumn')) { $lc = [string]$sec.LightColumn }
            $nw = @(); if ($sec.ContainsKey('NoWrap')) { $nw = @($sec.NoWrap) }
            [void]$html.AppendLine((ConvertTo-ReportTable -Rows @($sec.Rows) -Columns @($sec.Columns) -LightColumn $lc -NoWrap $nw))
        } elseif ($sec.ContainsKey('Lines')) {
            if (@($sec.Lines).Count -eq 0) { [void]$html.AppendLine('<p class="empty">(none)</p>') }
            else { [void]$html.AppendLine('<ul>' + ((@($sec.Lines) | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe ([string]$_)) + '</li>' }) -join '') + '</ul>') }
        } elseif ($sec.ContainsKey('Text')) {
            [void]$html.AppendLine('<pre>' + (ConvertTo-HtmlSafe ([string]$sec.Text)) + '</pre>')
        } elseif ($sec.ContainsKey('Html')) {
            [void]$html.AppendLine([string]$sec.Html)
        }
        [void]$html.AppendLine('</section>')
    }
    [void]$html.AppendLine('<div class="foot">' + (ConvertTo-HtmlSafe ('Generated {0} by {1} with {2} {3}.' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), (Get-OperatorIdentity), $script:Config.ToolName, $script:Config.ToolVersion)) + '</div>')
    [void]$html.AppendLine('</body></html>')
    return $html.ToString()
}

# ---------------------------------------------------------------------
#  Help pages: tables whose first column shows the thing as the window draws it
# ---------------------------------------------------------------------
function Get-HelpCell { param([string]$Text, [string]$Colour = 'white') return ('<span class="cell" style="background:{0}">{1}</span>' -f $Colour, (ConvertTo-HtmlSafe $Text)) }
function Get-HelpButton { param([string]$Text, [string]$Colour = '#f0f0f0') return ('<span class="btn" style="background:{0}">{1}</span>' -f $Colour, (ConvertTo-HtmlSafe $Text)) }
function Get-HelpSwatch { param([string]$Colour, [string]$Name) return ('<span class="swatch" style="background:{0}"></span>{1}' -f $Colour, (ConvertTo-HtmlSafe $Name)) }

function New-HelpTable {
    # $Rows = arrays; element 0 is ready-made HTML (the example), the others plain text (escaped here).
    param([string[]]$Headers, [object[]]$Rows)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($h in $Headers) { [void]$sb.Append('<th>' + (ConvertTo-HtmlSafe $h) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr><td>' + [string]$r[0] + '</td>')
        for ($i = 1; $i -lt $r.Count; $i++) { [void]$sb.Append('<td>' + (ConvertTo-HtmlSafe ([string]$r[$i])) + '</td>') }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function ConvertTo-HtmlFromNotes {
    # Plain notes -> HTML: a line in CAPITALS or "A. Heading" is a heading, "  1." and "  *" lines are lists, blank lines
    # separate paragraphs, web addresses are shown in code style.  Everything is escaped.
    param([string]$Text)
    $html = New-Object System.Text.StringBuilder
    $st = @{ List = ''; Item = $null; Para = @() }
    $flushItem = { if ($null -ne $st.Item) { [void]$html.Append('<li>' + (ConvertTo-NotesInline $st.Item) + '</li>'); $st.Item = $null } }
    $closeList = { & $flushItem; if ($st.List) { [void]$html.AppendLine('</' + $st.List + '>'); $st.List = '' } }
    $flushPara = { if ($st.Para.Count -gt 0) { [void]$html.AppendLine('<p>' + (ConvertTo-NotesInline ($st.Para -join ' ')) + '</p>'); $st.Para = @() } }
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*$') { & $closeList; & $flushPara; continue }
        if (($line -cmatch '^[A-Z]\.\s+\S') -or ($line -cmatch '^[A-Z0-9][A-Z0-9 ,\-/().:]+$' -and $line.Length -gt 3)) { & $closeList; & $flushPara; [void]$html.AppendLine('<h2>' + (ConvertTo-HtmlSafe $line.Trim()) + '</h2>'); continue }
        if ($line -match '^\s+(\d+)\.\s+(.*)$') { $itemText = $Matches[2]; & $flushPara; if ($st.List -ne 'ol') { & $closeList; $st.List = 'ol'; [void]$html.AppendLine('<ol>') }; & $flushItem; $st.Item = $itemText; continue }
        if ($line -match '^\s+\*\s+(.*)$') { $itemText = $Matches[1]; & $flushPara; if ($st.List -ne 'ul') { & $closeList; $st.List = 'ul'; [void]$html.AppendLine('<ul>') }; & $flushItem; $st.Item = $itemText; continue }
        if ($st.List -and $line -match '^\s+\S') { $st.Item += ' ' + $line.Trim(); continue }
        & $closeList
        $st.Para += $line.Trim()
    }
    & $closeList; & $flushPara
    return $html.ToString()
}

function ConvertTo-NotesInline {
    param([string]$Line)
    $safe = ConvertTo-HtmlSafe $Line
    $safe = [regex]::Replace($safe, '(https?://(?:[^\s,;)&]|&(?:lt|gt|amp);)+)', '<code>$1</code>')
    $safe = [regex]::Replace($safe, '&quot;([^&]{2,60})&quot;', '<b>$1</b>')
    return $safe
}

function Show-ConsoleHelp {
    param([string]$Console, [string]$Html)
    if (-not (Test-GuiDialogAllowed 'The help page')) { return }
    Show-DetailsWindow -Title ('Help: the {0} console' -f (Get-ConsoleName $Console)) -Html $Html
}

# ---------------------------------------------------------------------
#  Reports
# ---------------------------------------------------------------------
function Export-ConsoleReport {
    # $Sections: @{ Name; Rows; Columns }.  Writes reports\<Console>-<stamp>.html and one CSV per section.
    param([Parameter(Mandatory = $true)][string]$Console, [string]$Title = '', [object[]]$Summary = @(), [string[]]$SummaryColumns = @(), [Parameter(Mandatory = $true)][object[]]$Sections, [string[]]$Notes = @())
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = Join-Path $script:Config.ReportFolder ("{0}-{1}" -f $Console, $stamp)
    $colour = $script:Config.ConsoleColours[$Console]; if (-not $colour) { $colour = 'MidnightBlue' }
    $text = $script:Config.ConsoleText[$Console]; if (-not $text) { $text = 'White' }
    if (-not $Title) { $Title = "$Console report" }
    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + (ConvertTo-HtmlSafe $Title) + '</title>' + (Get-ToolkitFaviconTag))
    [void]$html.AppendLine((Get-ReportCss -Colour $colour -Text $text) + '</head><body>')
    [void]$html.AppendLine('<div class="banner"><h1>' + (ConvertTo-HtmlSafe $Title) + '</h1><p>' + (ConvertTo-HtmlSafe "$($script:Config.ToolName) $($script:Config.ToolVersion) - $(Get-ConsoleName $Console) console") + '</p></div>')
    [void]$html.AppendLine('<div class="meta"><span>Generated: ' + (ConvertTo-HtmlSafe (Get-Date -Format 'yyyy-MM-dd HH:mm')) + '</span><span>By: ' + (ConvertTo-HtmlSafe (Get-OperatorIdentity)) + '</span><span>Library: ' + (ConvertTo-HtmlSafe $script:Config.LibraryFolder) + '</span><span>Environment: ' + (ConvertTo-HtmlSafe (Get-EnvironmentText)) + '</span></div>')
    if ($Notes.Count -gt 0) { [void]$html.AppendLine('<section class="notes">'); foreach ($n in $Notes) { [void]$html.AppendLine('<div>' + (ConvertTo-HtmlSafe $n) + '</div>') }; [void]$html.AppendLine('</section>') }
    if (@($Summary).Count -gt 0) { [void]$html.AppendLine('<section><h2>Summary</h2>' + (ConvertTo-ReportTable -Rows $Summary -Columns $SummaryColumns) + '</section>') }
    [void]$html.AppendLine('<section><input id="filter" placeholder="filter rows (type to search all tables)" onkeyup="f(this.value)"><script>function f(q){q=q.toLowerCase();var rs=document.querySelectorAll("tbody tr");for(var i=0;i<rs.length;i++){rs[i].style.display=rs[i].innerText.toLowerCase().indexOf(q)>=0?"":"none";}}</script></section>')
    $csvPaths = @()
    foreach ($sec in $Sections) {
        $name = [string]$sec.Name; $rows = @($sec.Rows); $cols = @($sec.Columns)
        [void]$html.AppendLine('<section><h2>' + (ConvertTo-HtmlSafe $name) + ' (' + $rows.Count + ')</h2>' + (ConvertTo-ReportTable -Rows $rows -Columns $cols) + '</section>')
        $csvPath = $base + '.csv'
        if ($Sections.Count -gt 1) { $csvPath = $base + '-' + ($name -replace '[^A-Za-z0-9]', '') + '.csv' }
        if ($rows.Count -gt 0) {
            if ($cols.Count -eq 0) { $cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) }
            $csv = New-Object System.Text.StringBuilder
            [void]$csv.AppendLine((($cols | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','))
            foreach ($r in $rows) {
                $cells = foreach ($c in $cols) {
                    $v = ''; if ($r.PSObject.Properties[$c]) { $v = $r.$c }
                    if ($v -is [array]) { $v = ($v -join ', ') }
                    $v = [string]$v
                    if ($v -match '^[=+\-@\t\r]' -and $v -notmatch '^-?\d+([.,]\d+)*$') { $v = "'" + $v }
                    '"' + ($v -replace '"', '""') + '"'
                }
                [void]$csv.AppendLine($cells -join ',')
            }
            [System.IO.File]::WriteAllText($csvPath, $csv.ToString(), (New-Object System.Text.UTF8Encoding $true))
        } else { [System.IO.File]::WriteAllText($csvPath, '', (New-Object System.Text.UTF8Encoding $true)) }
        $csvPaths += $csvPath
    }
    [void]$html.AppendLine('<div class="foot">' + (ConvertTo-HtmlSafe "$($script:Config.ToolName) $($script:Config.ToolVersion). The library listed here is what the WinRM toolkit will install on the servers - treat as internal.") + '</div></body></html>')
    $htmlPath = $base + '.html'
    [System.IO.File]::WriteAllText($htmlPath, $html.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-PatchLog ("REPORT {0}: {1}" -f $Console, $htmlPath) 'OK'
    foreach ($p in $csvPaths) { Write-PatchLog "   csv: $p" 'INFO' }
    return [pscustomobject]@{ Html = $htmlPath; Csv = $csvPaths }
}

function Export-LibraryReport {
    # The Library console's report: the products and what was found, then every file in the library.
    param([object[]]$Rows = $null, [string]$Title = '', [string[]]$Notes = @())
    if ($null -eq $Rows) { $Rows = @(Get-LibraryRows) }
    if (-not $Title) { $Title = 'Update library' }
    $files = @(Get-LibraryFileRows)
    $summary = @(foreach ($v in @('Current', 'Download', 'Held', 'Check failed', 'Download failed', 'Changed', 'Not checked', 'Not set up', 'Off')) { $n = @($Rows | Where-Object { $_.Verdict -eq $v }).Count; if ($n -gt 0) { [pscustomobject]@{ Verdict = $v; Rows = $n } } })
    return (Export-ConsoleReport -Console 'Library' -Title $Title -Summary $summary -SummaryColumns @('Verdict', 'Rows') -Notes $Notes -Sections @(
        @{ Name = 'Products'; Rows = $Rows; Columns = @('Light', 'Product', 'For', 'In library', 'Latest found', 'Verdict', 'Verified', 'Size', 'Published', 'Source', 'Checked', 'Reason') },
        @{ Name = 'Library files'; Rows = $files; Columns = @('Light', 'File', 'Folder', 'Product', 'For', 'KB / version', 'Size', 'State', 'Signer', 'Downloaded', 'SHA256') }))
}

function Show-ReportDone {
    param($Report)
    if (-not (Test-GuiDialogAllowed 'The "open the report?" question')) { Write-PatchLog ("Report written: {0} - open it from the reports folder" -f $Report.Html) 'OK'; return }
    if ((Show-PatcherMessage -Text "Report written:`n$($Report.Html)`n`nOpen it now?" -Title 'Report' -Buttons 'YesNo') -eq 'Yes') { Start-Process $Report.Html }
}

function Open-ReportFolder {
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    Invoke-Item -LiteralPath $script:Config.ReportFolder
}
