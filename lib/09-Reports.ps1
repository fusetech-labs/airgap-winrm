# =====================================================================
#  09-Reports.ps1  -  HTML + CSV REPORTS FOR EVERY CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Export-ConsoleReport writes two things from the same rows:
#    reports\<Console>-<yyyyMMdd-HHmmss>.html  summary at the top, data below,
#                                             inline CSS only (opens offline),
#                                             rows coloured by their Light
#    reports\<Console>-<yyyyMMdd-HHmmss>[-<Section>].csv   data only, UTF-8 BOM
#  A console may pass several sections (Patching: KB verdicts + Software).
#  Reports contain host names and account names: reports\ is git-ignored.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  09-Reports.ps1  (new in version 2)
# ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _______cf_______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

$script:NonAsciiRegex = New-Object System.Text.RegularExpressions.Regex ('[^\x00-\x7F]', [System.Text.RegularExpressions.RegexOptions]::Compiled)

function ConvertTo-PageText {
    # Every page and report the toolkit writes is plain ASCII, but text read from a server (an event message, a product
    # name, a certificate subject) may carry typographic quotes, dashes and non-breaking spaces.  Those are folded to
    # their plain forms; anything else becomes '?'.  Returns the text untouched (no copy) when it is ASCII already.
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

function ConvertTo-EvidenceHtml {
    # An Evidence cell: the check's summary, then one line per finding (the row's Items), so several findings never
    # read as one sentence.  A row without Items whose text is still a "; "-joined list gets one line per part.
    param($Row, [string]$Text)
    $items = @()
    if ($Row.PSObject.Properties['Items']) { $items = @($Row.Items | Where-Object { "$_" -ne '' }) }
    if ($items.Count -gt 0) {
        $head = ''
        if ($Row.PSObject.Properties['Summary'] -and [string]$Row.Summary) { $head = '<div>' + (ConvertTo-HtmlSafe ([string]$Row.Summary)) + '</div>' }
        return ($head + '<ul class="ev">' + (($items | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe ([string]$_)) + '</li>' }) -join '') + '</ul>')
    }
    $parts = @($Text -split ';\s+' | Where-Object { $_ })
    if ($parts.Count -gt 1) { return (($parts | ForEach-Object { '<div>' + (ConvertTo-HtmlSafe $_) + '</div>' }) -join '') }
    return (ConvertTo-HtmlSafe $Text)
}

# Where a path or host name may wrap (a <wbr> goes after the match): after each \ and /, and after a dot only when another
# dot follows in the same word (the parts of a host name, never a file's extension - a search for "name.ps1" in the page
# still hits); never after a leading \ (a task's "\Name" would leave the \ alone on a line)
$script:ReportSoftBreakPattern = '(?<!^)([\\/]|\.(?=[^\s;,\\/]*\.))(?=.)'

function ConvertTo-FilterLinkHtml {
    # "a.bat; b.ps1" (the script files a cell lists) -> each one a link that puts its file name into the page's filter box
    # (the click handler is in Get-ReportPageScript), so the script's own row shows without copying the name by hand.
    # A trailing "(not found)" stays in the text and out of the file name.
    param([string]$Text, [switch]$Soft)
    $parts = @(($Text -split ';\s*') | Where-Object { $_ })
    $out = foreach ($p in $parts) {
        $leaf = (($p -replace '\s*\(not found\)\s*$', '') -replace '^.*[\\/]', '').Trim()
        $enc = [System.Net.WebUtility]::HtmlEncode($p); if ($Soft) { $enc = $enc -replace $script:ReportSoftBreakPattern, '$1<wbr>' }
        if (-not $leaf) { $enc; continue }
        $q = [System.Net.WebUtility]::HtmlEncode($leaf)
        '<a href="#" class="q" data-q="' + $q + '" title="Filter: ' + $q + '">' + $enc + '</a>'
    }
    return ($out -join '; ')
}

function ConvertTo-ReportTable {
    # Rows -> one HTML table.  $Columns picks and orders the properties; the Light column (if any) colours the row and
    # is never a column of the page (the colour says it; the CSV beside a report keeps it for filtering).
    # Written for thousands of rows: the encoder is called directly (a function call per cell costs a second per
    # thousand rows in PowerShell 5.1) and only the Evidence column goes through ConvertTo-EvidenceHtml.
    # $NoWrap: columns of short values that must not break ("25% (3 of 12)", a date) when a long column squeezes the table.
    # $Widths: column -> CSS width ('112px', '12%'). Given, the table is laid out with fixed column widths - a wide table
    #          of long paths next to short dates stays readable: a path wraps inside its cell, a date never breaks, and
    #          a column not named shares what is left.
    # $SoftBreak: columns of paths and host names; a break is allowed after each \ / and the inner dots of a host name, so
    #          they wrap at a natural point (never at a file's extension: the page can still be searched for "name.ps1").
    # $FilterLinks: columns that list script files ("a.bat; b.ps1"); each becomes a link that puts its file name into the
    #          page's filter box (reports only - a details page has no filter box), so the script's own row is one click away.
    param([object[]]$Rows, [string[]]$Columns, [string]$LightColumn = 'Light', [string[]]$NoWrap = @(), [hashtable]$Widths = $null, [string[]]$SoftBreak = @(), [string[]]$FilterLinks = @())
    if (-not $Rows -or $Rows.Count -eq 0) { return '<p class="empty">(no rows)</p>' }
    if (-not $Columns -or $Columns.Count -eq 0) { $Columns = @($Rows[0].PSObject.Properties | ForEach-Object { $_.Name }) }
    if ($LightColumn) { $Columns = @($Columns | Where-Object { $_ -ne $LightColumn }) }
    if ($Columns.Count -eq 0) { return '<p class="empty">(no columns)</p>' }
    $open = @{}; foreach ($col in $Columns) { $open[$col] = $(if (@($NoWrap) -contains $col) { '<td class="nw">' } else { '<td>' }) }
    $soft = @{}; foreach ($col in @($SoftBreak)) { if ($col) { $soft[$col] = $true } }
    $links = @{}; foreach ($col in @($FilterLinks)) { if ($col) { $links[$col] = $true } }
    $sb = New-Object System.Text.StringBuilder
    if ($Widths -and $Widths.Count -gt 0) {
        [void]$sb.Append('<table class="fx"><colgroup>')
        foreach ($col in $Columns) { $w = [string]$Widths[$col]; if ($w) { [void]$sb.Append('<col style="width:' + [System.Net.WebUtility]::HtmlEncode($w) + '">') } else { [void]$sb.Append('<col>') } }
        [void]$sb.Append('</colgroup><thead><tr>')
    } else { [void]$sb.Append('<table><thead><tr>') }
    foreach ($col in $Columns) { [void]$sb.Append('<th>' + [System.Net.WebUtility]::HtmlEncode((ConvertTo-PageText $col)) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    $hasLight = ($LightColumn -and $Rows[0].PSObject.Properties[$LightColumn])
    $rx = $script:NonAsciiRegex
    foreach ($r in $Rows) {
        if ($hasLight) { [void]$sb.Append('<tr class="').Append([System.Net.WebUtility]::HtmlEncode([string]$r.$LightColumn)).Append('">') } else { [void]$sb.Append('<tr>') }
        foreach ($col in $Columns) {
            $v = $r.$col
            if ($col -eq 'Evidence') { [void]$sb.Append('<td>').Append((ConvertTo-EvidenceHtml -Row $r -Text ([string]$v))).Append('</td>'); continue }
            if ($v -is [array]) { $v = ($v -join ', ') }
            $s = [string]$v; if ($rx.IsMatch($s)) { $s = ConvertTo-PageText $s }   # the fold only when needed - a call per cell would cost
            if ($links.ContainsKey($col) -and $s) { [void]$sb.Append($open[$col]).Append((ConvertTo-FilterLinkHtml -Text $s -Soft:($soft.ContainsKey($col)))).Append('</td>'); continue }
            $enc = [System.Net.WebUtility]::HtmlEncode($s)
            if ($soft.ContainsKey($col)) { $enc = $enc -replace $script:ReportSoftBreakPattern, '$1<wbr>' }
            [void]$sb.Append($open[$col]).Append($enc).Append('</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-ReportCss {
    # One style sheet for the reports and the details windows (inline, so the files work offline anywhere).
    param([string]$Colour = 'MidnightBlue', [string]$Text = 'White')
    return @"
<style>
body{font-family:Segoe UI,Arial,sans-serif;font-size:13px;margin:0;color:#222;background:#fff}
.banner{background:$Colour;color:$Text;padding:14px 24px}.banner h1{margin:0;font-size:22px}.banner p{margin:4px 0 0 0;opacity:.9}
.meta{padding:10px 24px;background:#f4f4f4;border-bottom:1px solid #ddd}.meta span{margin-right:24px;display:inline-block}
section{padding:12px 24px}h2{font-size:16px;margin:18px 0 6px 0;border-bottom:2px solid #ccc}h3{font-size:13px;margin:12px 0 2px 0;color:#333}
table{border-collapse:collapse;width:100%;margin-bottom:12px}th{background:#333;color:#fff;text-align:left;padding:5px 8px;position:sticky;top:0}
td{padding:4px 8px;border-bottom:1px solid #e3e3e3;vertical-align:top;font-size:12px}tr:hover td{background:#f0f6ff}
tr.Red td{background:#f8d7da}tr.Amber td{background:#fff3cd}tr.Green td{background:#d4edda}tr.Blue td{background:#dbeafa}tr.Grey td{background:#e9ecef;color:#555}
.notes{font-size:12px;color:#444}.empty{color:#777;font-style:italic}.foot{padding:10px 24px;color:#777;font-size:11px}
input#filter{margin:8px 0;padding:4px 8px;width:440px}
pre{font-family:Consolas,monospace;font-size:12px;background:#f7f7f7;padding:8px;white-space:pre-wrap;word-wrap:break-word}
ul{margin:4px 0 8px 18px}
ul.ev{margin:2px 0 0 16px;padding:0}ul.ev li{margin:0 0 1px 0}
.cell{display:inline-block;border:1px solid #bbb;padding:2px 8px;font-size:12px;background:#fff;min-width:70px;white-space:nowrap}
.btn{display:inline-block;border:1px solid #888;border-radius:3px;padding:4px 10px;font-size:12px;background:#f0f0f0;box-shadow:1px 1px 0 #bbb;white-space:nowrap}
table.mock td,table.mock th{border:1px solid #d0d0d0;font-size:12px;padding:3px 6px}table.mock th{background:#e8e8e8;color:#222;position:static}
.swatch{display:inline-block;width:18px;height:14px;border:1px solid #999;vertical-align:middle;margin-right:6px}
.tour p{max-width:1100px;line-height:1.45;margin:6px 0 10px 0}.tour h3{font-size:14px;margin:16px 0 6px 0;color:#333}h2 .sub,h3 .sub{font-weight:normal;color:#666;font-size:12px}
pre.lay{background:#fafafa;border-left:3px solid #ccc;padding:6px 10px;margin:4px 0 10px 0;font-size:12px;white-space:pre;word-wrap:normal;overflow-x:auto}
pre.src{background:#f6f8fa;border:1px solid #d8dee4;padding:10px;font-size:12px;white-space:pre;word-wrap:normal;overflow-x:auto;line-height:1.35}pre.src .cm{color:#2e7d32}
.pic{margin:4px 0 14px 0}.pic img{max-width:100%;border:1px solid #ccc}.pic .cap{font-size:11px;color:#777}.warn{color:#b00020;font-weight:bold}p.top{font-size:11px}
.cards{margin:4px 0}.card{display:inline-block;vertical-align:top;border:1px solid #ddd;margin:0 10px 10px 0;padding:6px 8px;background:#fff}
.card .h{font-weight:bold;font-size:13px;max-width:290px;word-wrap:break-word}.card .s{color:#666;font-size:11px;margin-bottom:2px}.card img{margin:0 2px 0 0;vertical-align:top}
.card .none{color:#777;font-style:italic;padding:8px 0;width:280px}
table.mini{width:auto;margin:4px 0 0 0}table.mini td{border:0;padding:0 8px 0 0;width:140px;text-align:center;vertical-align:top;font-size:11px}table.mini .cap{margin-top:2px;color:#333}
table.mini tr:hover td{background:transparent}.hint{background:#fff8dc;border:1px solid #e6d9a8;padding:6px 10px;font-size:12px;margin:4px 0}
img{max-width:100%}td.nw{white-space:nowrap}
table.fx{table-layout:fixed}table.fx td,table.fx th{padding-left:6px;padding-right:6px;overflow-wrap:break-word;word-wrap:break-word}table.fx td.nw{overflow:hidden;text-overflow:ellipsis}
thead th{cursor:pointer}table.mock th{cursor:default}th[data-s="a"]:after{content:" \2191"}th[data-s="d"]:after{content:" \2193"}
a.q{color:inherit;text-decoration:none;border-bottom:1px dotted #999}a.q:hover{color:#0a58ca;border-bottom-color:#0a58ca}
/* Printing (Print > Save as PDF): keep the colours, never leave a heading at the foot of a page (the empty block after
   each h2 must fit below it, or the heading moves to the next page), never split a chart, a card or a table row across
   pages, repeat the table header on every page, three group cards to a row, and narrow the margins to the paper */
@page{margin:12mm}
@media print{
*{-webkit-print-color-adjust:exact;print-color-adjust:exact;color-adjust:exact}
body{font-size:11px}.banner{padding:8px 12px}.banner h1{font-size:19px}.meta{padding:6px 12px}section{padding:4px 12px}.foot{padding:6px 12px}
h2{font-size:14px;margin:10px 0 4px 0;break-after:avoid;page-break-after:avoid;break-inside:avoid;page-break-inside:avoid}h3{font-size:12px;margin:8px 0 2px 0;break-after:avoid;page-break-after:avoid}
h2::after{content:"";display:block;height:150px;margin-bottom:-150px}section.cardsec h2::after{height:250px;margin-bottom:-250px}
section.keep,.card,img,tr,.pic{break-inside:avoid;page-break-inside:avoid}
thead{display:table-header-group}th{position:static;font-size:10px;padding:3px 5px}td{font-size:10px;padding:2px 5px;word-break:break-word}
.cards{orphans:1;widows:1}.card{padding:4px 6px;margin:0 6px 6px 0}.card .h{font-size:11px;max-width:200px}.card .s{font-size:9px}.card .none{width:190px}
.card img{width:80px;height:80px}table.mini td{width:96px;padding:0 4px 0 0;font-size:9px}
tr:hover td{background:inherit}input#filter,.noprint{display:none}
}
</style>
"@
}

function Get-ReportPageScript {
    # The page's own script, plain and offline: (1) a click on a column heading sorts its table by that column, a second
    # click the other way round - numbers as numbers, the rest as text, empty cells last either way; (2) a click on a
    # filter link (ConvertTo-FilterLinkHtml) puts its file name into the filter box and filters every table by it.
    return '<script>document.addEventListener("click",function(e){var th=e.target;while(th&&th.nodeName!=="TH"){th=th.parentNode;}if(!th||!th.parentNode||th.parentNode.parentNode.nodeName!=="THEAD"){return;}var t=th.parentNode.parentNode.parentNode,b=t.tBodies[0];if(!b||b.rows.length<2){return;}var i=th.cellIndex,up=th.getAttribute("data-s")!=="a",hs=th.parentNode.cells,k;for(k=0;k<hs.length;k++){hs[k].removeAttribute("data-s");}th.setAttribute("data-s",up?"a":"d");var num=/^\s*-?[\d.,]+\s*(%|KB|MB|GB|s)?\s*$/;function v(r){var c=r.cells[i];return c?(c.textContent||"").replace(/^\s+|\s+$/g,""):"";}var rs=[];for(k=0;k<b.rows.length;k++){rs.push(b.rows[k]);}rs.sort(function(x,y){var p=v(x),q=v(y),c;if(p===q){return 0;}if(p===""){return 1;}if(q===""){return -1;}if(num.test(p)&&num.test(q)){c=parseFloat(p.replace(/,/g,""))-parseFloat(q.replace(/,/g,""));}else{c=p.localeCompare(q,undefined,{numeric:true,sensitivity:"base"});}return up?c:-c;});for(k=0;k<rs.length;k++){b.appendChild(rs[k]);}});' +
           'document.addEventListener("click",function(e){var a=e.target;while(a&&a.nodeName!=="A"){a=a.parentNode;}if(!a||!a.getAttribute||!a.getAttribute("data-q")){return;}e.preventDefault();var i=document.getElementById("filter");if(!i){return;}i.value=a.getAttribute("data-q");if(typeof f==="function"){f(i.value);}i.scrollIntoView();i.focus();});</script>'
}

function ConvertFrom-PipeLines {
    # "a|b|c" text lines (how the collectors send their lists) -> objects with the given property names.
    param([string[]]$Lines, [string[]]$Columns)
    $rows = @()
    foreach ($line in @($Lines)) {
        if ($null -eq $line -or [string]$line -eq '') { continue }
        $f = [string]$line -split '\|'
        $o = [ordered]@{}
        for ($i = 0; $i -lt $Columns.Count; $i++) { $o[$Columns[$i]] = $(if ($i -lt $f.Count) { $f[$i] } else { '' }) }
        $rows += [pscustomobject]$o
    }
    return $rows
}

function New-DetailsHtml {
    # A self-contained page for the details windows: banner, a line of facts, then sections.
    #   $Facts    : pairs shown under the banner, e.g. @(@('Collected', '10:15'), @('Window', '24 h'))
    #   $Sections : @{ Heading; Rows; Columns; [LightColumn]; [Note] } (a table, rows coloured by their Light)
    #               [Keep = $true] on any section: printing keeps it on one page (charts, cards)
    #               [Class = 'name'] on any section: a style hook (section.cardsec); [NoWrap = columns] on a table
    #               [PageColumns], [Widths], [SoftBreak] on a table: the page's own columns and their layout (ConvertTo-ReportTable)
    #               @{ Heading; Lines; [Note] } (a list)      @{ Heading; Text } (preformatted text)
    #               @{ Heading; Groups = @(@{ Heading; Lines }) } (headed bullet lists: the licensing counting rules)
    param([string]$Title, [string]$Subtitle = '', [string]$Console = 'Patching', [object[]]$Facts = @(), [object[]]$Sections = @())
    $colour = $script:Config.ConsoleColours[$Console]; if (-not $colour) { $colour = 'MidnightBlue' }
    $text = $script:Config.ConsoleText[$Console]; if (-not $text) { $text = 'White' }
    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="X-UA-Compatible" content="IE=edge"><title>' + (ConvertTo-HtmlSafe $Title) + '</title>' + (Get-ToolkitFaviconTag))
    [void]$html.AppendLine((Get-ReportCss -Colour $colour -Text $text) + '</head><body>')
    [void]$html.AppendLine('<div class="banner"><h1>' + (ConvertTo-HtmlSafe $Title) + '</h1><p>' + (ConvertTo-HtmlSafe $Subtitle) + '</p></div>')
    # The facts bar shows the page's own time (Checked / Collected / Audited); the footer carries the generated stamp.
    # A pair that arrived flattened (@(@('a', 'b')) unwraps to 'a', 'b') is re-paired here rather than shown as two single letters.
    $pairs = @()
    $flat = @($Facts); $i = 0
    while ($i -lt $flat.Count) {
        if ($flat[$i] -is [array] -and $flat[$i].Count -ge 2) { $pairs += , @([string]$flat[$i][0], [string]$flat[$i][1]); $i++ }
        elseif ($i + 1 -lt $flat.Count) { $pairs += , @([string]$flat[$i], [string]$flat[$i + 1]); $i += 2 }
        else { $i++ }
    }
    if ($pairs.Count -gt 0) {
        [void]$html.AppendLine('<div class="meta">' + (($pairs | ForEach-Object { '<span><b>' + (ConvertTo-HtmlSafe $_[0]) + ':</b> ' + (ConvertTo-HtmlSafe $_[1]) + '</span>' }) -join '') + '</div>')
    }
    foreach ($sec in @($Sections)) {
        $count = ''
        if ($sec.ContainsKey('Rows')) { $count = ' (' + @($sec.Rows).Count + ')' }
        # Keep = a short section (charts, cards) that printing should not split across pages
        $cls = @(); if ($sec.ContainsKey('Keep') -and $sec.Keep) { $cls += 'keep' }; if ($sec.ContainsKey('Class') -and $sec.Class) { $cls += [string]$sec.Class }
        if ($cls.Count -gt 0) { [void]$html.AppendLine('<section class="' + (ConvertTo-HtmlSafe ($cls -join ' ')) + '">') } else { [void]$html.AppendLine('<section>') }
        if ([string]$sec.Heading) { [void]$html.AppendLine('<h2>' + (ConvertTo-HtmlSafe ([string]$sec.Heading)) + $count + '</h2>') }
        if ($sec.ContainsKey('Note') -and $sec.Note) { [void]$html.AppendLine('<p class="notes">' + (ConvertTo-HtmlSafe ([string]$sec.Note)) + '</p>') }
        if ($sec.ContainsKey('Rows')) {
            $lc = 'Light'; if ($sec.ContainsKey('LightColumn')) { $lc = [string]$sec.LightColumn }
            $nw = @(); if ($sec.ContainsKey('NoWrap')) { $nw = @($sec.NoWrap) }
            $pageCols = @($sec.Columns); if ($sec.ContainsKey('PageColumns') -and @($sec.PageColumns).Count -gt 0) { $pageCols = @($sec.PageColumns) }
            $widths = $null; if ($sec.ContainsKey('Widths')) { $widths = $sec.Widths }
            $soft = @(); if ($sec.ContainsKey('SoftBreak')) { $soft = @($sec.SoftBreak) }
            [void]$html.AppendLine((ConvertTo-ReportTable -Rows @($sec.Rows) -Columns $pageCols -LightColumn $lc -NoWrap $nw -Widths $widths -SoftBreak $soft))
        } elseif ($sec.ContainsKey('Lines')) {
            if (@($sec.Lines).Count -eq 0) { [void]$html.AppendLine('<p class="empty">(none)</p>') }
            else { [void]$html.AppendLine('<ul>' + ((@($sec.Lines) | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe ([string]$_)) + '</li>' }) -join '') + '</ul>') }
        } elseif ($sec.ContainsKey('Groups')) {
            [void]$html.AppendLine((ConvertTo-GroupListHtml -Groups @($sec.Groups)))
        } elseif ($sec.ContainsKey('Text')) {
            [void]$html.AppendLine('<pre>' + (ConvertTo-HtmlSafe ([string]$sec.Text)) + '</pre>')
        } elseif ($sec.ContainsKey('Html')) {
            [void]$html.AppendLine([string]$sec.Html)   # already escaped by the caller (ConvertTo-HtmlFromNotes)
        }
        [void]$html.AppendLine('</section>')
    }
    [void]$html.AppendLine('<div class="foot">' + (ConvertTo-HtmlSafe ('Generated {0} by {1} with {2} {3}. Pages contain host names and findings - treat as internal.' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), (Get-OperatorIdentity), $script:Config.ToolName, $script:Config.ToolVersion)) + '</div>')
    [void]$html.AppendLine((Get-ReportPageScript) + '</body></html>')
    return $html.ToString()
}

# ---------------------------------------------------------------------
#  Help pages (the "Help" button of a console): tables whose first column shows the thing as the window draws
#  it - a grid cell, a button, a coloured row - next to what it means.  Styles .cell / .btn / .swatch /
#  table.mock live in Get-ReportCss.
# ---------------------------------------------------------------------
function Get-HelpCell {
    # One grid cell: bordered, coloured like its row would be.
    param([string]$Text, [string]$Colour = 'white')
    return ('<span class="cell" style="background:{0}">{1}</span>' -f $Colour, (ConvertTo-HtmlSafe $Text))
}

function Get-HelpButton {
    param([string]$Text, [string]$Colour = '#f0f0f0')
    return ('<span class="btn" style="background:{0}">{1}</span>' -f $Colour, (ConvertTo-HtmlSafe $Text))
}

function Get-HelpSwatch {
    # A colour square with its name, for row-colour legends.
    param([string]$Colour, [string]$Name)
    return ('<span class="swatch" style="background:{0}"></span>{1}' -f $Colour, (ConvertTo-HtmlSafe $Name))
}

function New-HelpTable {
    # $Rows = arrays; element 0 is ready-made HTML (the example), the others plain text (escaped here).
    # -TrellixRows: while Trellix is not in use (Settings tab) the Trellix rows go - a row whose example names Trellix (the
    # box, the buttons) or which explains the Solidcore / Trellix Agent column or the orange agent cell.
    param([string[]]$Headers, [object[]]$Rows, [switch]$TrellixRows)
    if ($TrellixRows -and -not (Test-TrellixInUse)) {
        $kept = @(); foreach ($r in @($Rows)) { if (-not ([string]$r[0] -match 'Trellix' -or [string]$r[1] -match '^(Solidcore:|Trellix Agent:|The Trellix Agent cell)')) { $kept += , $r } }
        $Rows = $kept
    }
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

function New-MockGrid {
    # A small copy of a grid: $Headers, then rows as @{ Colour = 'mistyrose'; Cells = @('a', 'b', ...) } - plus, for a
    # cell coloured apart from its row, CellColours = @{ <cell index> = 'palegreen' }.
    # -TrellixColumns: while Trellix is not in use (Settings tab) the Solidcore and Trellix Agent columns go, as in the grid.
    param([string[]]$Headers, [object[]]$Rows, [switch]$TrellixColumns)
    if ($TrellixColumns -and -not (Test-TrellixInUse)) {
        $keep = @(for ($i = 0; $i -lt $Headers.Count; $i++) { if ($Headers[$i] -notin 'Solidcore', 'Trellix Agent') { $i } })
        $slim = @()
        foreach ($r in @($Rows)) {
            $cells = @($r.Cells); $hues = @{}
            for ($j = 0; $j -lt $keep.Count; $j++) { if ($r.CellColours -and $r.CellColours[$keep[$j]]) { $hues[$j] = $r.CellColours[$keep[$j]] } }
            $slim += @{ Colour = $r.Colour; Cells = @(foreach ($i in $keep) { $cells[$i] }); CellColours = $hues }
        }
        $Headers = @(foreach ($i in $keep) { $Headers[$i] }); $Rows = $slim
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table class="mock"><thead><tr>')
    foreach ($h in $Headers) { [void]$sb.Append('<th>' + (ConvertTo-HtmlSafe $h) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in $Rows) {
        [void]$sb.Append('<tr>')
        $cells = @($r.Cells)
        for ($i = 0; $i -lt $cells.Count; $i++) {
            $colour = [string]$r.Colour
            if ($r.CellColours -and $r.CellColours[$i]) { $colour = [string]$r.CellColours[$i] }
            $style = ''; if ($colour) { $style = ' style="background:' + $colour + '"' }
            [void]$sb.Append('<td' + $style + '>' + (ConvertTo-HtmlSafe ([string]$cells[$i])) + '</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Show-ConsoleHelp {
    # The Help button of a console: $Html comes from the console's Get-<Console>HelpHtml.
    param([string]$Console, [string]$Html)
    if (-not (Test-GuiDialogAllowed 'The help page')) { return }
    Show-DetailsWindow -Title ('Help: the {0} console' -f (Get-ConsoleName $Console)) -Html $Html
}
function ConvertTo-HtmlFromNotes {
    # Plain notes (the how-to text, Code Tour style) -> HTML: CAPITAL headings and "A. HEADING" lines become
    # headings, "1." and "*" lines become lists (indented continuation lines join the item), blank lines
    # separate paragraphs, web addresses are shown in code style so they are easy to copy.  Everything is escaped.
    param([string]$Text)
    $html = New-Object System.Text.StringBuilder
    # the state lives in one hashtable because the helper blocks below run in their own scope: they can change
    # a property of $st, but an assignment to a plain variable would only make a local copy
    $st = @{ List = ''; Item = $null; Para = @() }
    $flushItem = { if ($null -ne $st.Item) { [void]$html.Append('<li>' + (ConvertTo-NotesInline $st.Item) + '</li>'); $st.Item = $null } }
    $closeList = { & $flushItem; if ($st.List) { [void]$html.AppendLine('</' + $st.List + '>'); $st.List = '' } }
    $flushPara = { if ($st.Para.Count -gt 0) { [void]$html.AppendLine('<p>' + (ConvertTo-NotesInline ($st.Para -join ' ')) + '</p>'); $st.Para = @() } }
    foreach ($raw in ($Text -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^\s*$') { & $closeList; & $flushPara; continue }
        # a heading is "A. Something" at the left margin, or a line written entirely in capitals
        # (-cmatch: -match is case-insensitive and would turn every line into a heading)
        if (($line -cmatch '^[A-Z]\.\s+\S') -or ($line -cmatch '^[A-Z0-9][A-Z0-9 ,\-/().:]+$' -and $line.Length -gt 3)) { & $closeList; & $flushPara; [void]$html.AppendLine('<h2>' + (ConvertTo-HtmlSafe $line.Trim()) + '</h2>'); continue }
        if ($line -match '^\s+(\d+)\.\s+(.*)$') { $itemText = $Matches[2]; & $flushPara; if ($st.List -ne 'ol') { & $closeList; $st.List = 'ol'; [void]$html.AppendLine('<ol>') }; & $flushItem; $st.Item = $itemText; continue }
        if ($line -match '^\s+\*\s+(.*)$') { $itemText = $Matches[1]; & $flushPara; if ($st.List -ne 'ul') { & $closeList; $st.List = 'ul'; [void]$html.AppendLine('<ul>') }; & $flushItem; $st.Item = $itemText; continue }
        if ($st.List -and $line -match '^\s+\S') { $st.Item += ' ' + $line.Trim(); continue }   # continuation of a list item
        & $closeList
        $st.Para += $line.Trim()
    }
    & $closeList; & $flushPara
    return $html.ToString()
}

function ConvertTo-NotesInline {
    # Escapes a line of notes and marks web addresses and quoted names so they stand out.
    param([string]$Line)
    $safe = ConvertTo-HtmlSafe $Line
    # an address may hold an escaped placeholder (&lt;version&gt;): entities stay inside the code span, a plain ; ends it
    $safe = [regex]::Replace($safe, '(https?://(?:[^\s,;)&]|&(?:lt|gt|amp);)+)', '<code>$1</code>')
    $safe = [regex]::Replace($safe, '&quot;([^&]{2,60})&quot;', '<b>$1</b>')
    return $safe
}

function ConvertTo-GroupListHtml {
    # Headed bullet lists -> HTML: @(@{ Heading = 'Windows Server'; Lines = @('per core: ...', ...) }, ...), one h3 and
    # one list per group, so a set of rules reads point by point instead of as a paragraph.  Everything is escaped; a
    # web address in a line is shown in code style (ConvertTo-NotesInline).
    param([object[]]$Groups)
    $sb = New-Object System.Text.StringBuilder
    foreach ($g in @($Groups)) {
        if ([string]$g.Heading) { [void]$sb.Append('<h3>' + (ConvertTo-HtmlSafe ([string]$g.Heading)) + '</h3>') }
        $lines = @($g.Lines)
        if ($lines.Count -gt 0) { [void]$sb.AppendLine('<ul>' + (($lines | ForEach-Object { '<li>' + (ConvertTo-NotesInline ([string]$_)) + '</li>' }) -join '') + '</ul>') }
    }
    return $sb.ToString()
}

function Export-ConsoleReport {
    # $Sections: array of hashtables @{ Name = 'Checks'; Rows = <objects>; Columns = @('Server', ...) } (a table, with a
    #            CSV beside the page) or @{ Name; Groups = @(@{ Heading; Lines }) } (headed bullet lists, page only).
    #            A table may add [PageColumns] (the page shows these, the CSV keeps every column - a path the page splits
    #            into name and folder), [NoWrap], [Widths], [SoftBreak] and [FilterLinks] (its layout; ConvertTo-ReportTable).
    # $Summary : rows for the summary table at the top (any objects); $Notes: lines under the header.
    param(
        [Parameter(Mandatory = $true)][string]$Console,
        [string]$Title = '',
        [object[]]$Summary = @(),
        [string[]]$SummaryColumns = @(),
        [Parameter(Mandatory = $true)][object[]]$Sections,
        [string[]]$Notes = @(),
        [string]$Prefix = ''          # the file name's first word when it is not the console's (Scripts-<date> from the Health console)
    )
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'   # seconds, so two reports in one minute never overwrite each other
    if (-not $Prefix) { $Prefix = $Console }
    $base = Join-Path $script:Config.ReportFolder ("{0}-{1}" -f $Prefix, $stamp)
    $colour = $script:Config.ConsoleColours[$Console]; if (-not $colour) { $colour = 'MidnightBlue' }
    $text = $script:Config.ConsoleText[$Console]; if (-not $text) { $text = 'White' }
    if (-not $Title) { $Title = "$Console report" }
    $when = Get-Date -Format 'yyyy-MM-dd HH:mm'
    $operator = Get-OperatorIdentity

    $html = New-Object System.Text.StringBuilder
    [void]$html.AppendLine('<!DOCTYPE html><html><head><meta charset="utf-8"><title>' + (ConvertTo-HtmlSafe $Title) + '</title>' + (Get-ToolkitFaviconTag))
    [void]$html.AppendLine((Get-ReportCss -Colour $colour -Text $text) + '</head><body>')
    [void]$html.AppendLine('<div class="banner"><h1>' + (ConvertTo-HtmlSafe $Title) + '</h1><p>' + (ConvertTo-HtmlSafe "$($script:Config.ToolName) $($script:Config.ToolVersion) - $(Get-ConsoleName $Console) console") + '</p></div>')
    [void]$html.AppendLine('<div class="meta"><span>Generated: ' + (ConvertTo-HtmlSafe $when) + '</span><span>By: ' + (ConvertTo-HtmlSafe $operator) + '</span><span>Tool folder: ' + (ConvertTo-HtmlSafe $script:RootFolder) + '</span></div>')
    if ($Notes.Count -gt 0) {
        [void]$html.AppendLine('<section class="notes">')
        foreach ($n in $Notes) { [void]$html.AppendLine('<div>' + (ConvertTo-HtmlSafe $n) + '</div>') }
        [void]$html.AppendLine('</section>')
    }
    [void]$html.AppendLine('<section><h2>Summary</h2>')
    [void]$html.AppendLine((ConvertTo-ReportTable -Rows $Summary -Columns $SummaryColumns))
    [void]$html.AppendLine('</section>')
    # a tiny filter box, the heading-click sort and the filter links - the only scripts in the page; all work offline
    [void]$html.AppendLine('<section><input id="filter" placeholder="filter rows (type to search all tables; click a column heading to sort)" onkeyup="f(this.value)"><script>function f(q){q=q.toLowerCase();var rs=document.querySelectorAll("tbody tr");for(var i=0;i<rs.length;i++){rs[i].style.display=rs[i].innerText.toLowerCase().indexOf(q)>=0?"":"none";}}</script>' + (Get-ReportPageScript) + '</section>')

    $csvPaths = @()
    foreach ($sec in $Sections) {
        $name = [string]$sec.Name
        if ($sec.ContainsKey('Groups')) {
            # headed bullet lists (the licensing counting rules): a section of the page, no CSV
            [void]$html.AppendLine('<section><h2>' + (ConvertTo-HtmlSafe $name) + '</h2>' + (ConvertTo-GroupListHtml -Groups @($sec.Groups)) + '</section>')
            continue
        }
        $rows = @($sec.Rows)
        $cols = @($sec.Columns)
        $pageCols = $cols; if ($sec.ContainsKey('PageColumns') -and @($sec.PageColumns).Count -gt 0) { $pageCols = @($sec.PageColumns) }
        $nw = @(); if ($sec.ContainsKey('NoWrap')) { $nw = @($sec.NoWrap) }
        $widths = $null; if ($sec.ContainsKey('Widths')) { $widths = $sec.Widths }
        $soft = @(); if ($sec.ContainsKey('SoftBreak')) { $soft = @($sec.SoftBreak) }
        $fl = @(); if ($sec.ContainsKey('FilterLinks')) { $fl = @($sec.FilterLinks) }
        [void]$html.AppendLine('<section><h2>' + (ConvertTo-HtmlSafe $name) + ' (' + $rows.Count + ')</h2>')
        # a browser copes with a few thousand table rows, not a hundred thousand: the page is cut, the CSV is complete
        $cap = [int]$script:Config.MaxReportRowsPerSection; $shownRows = $rows
        if ($cap -gt 0 -and $rows.Count -gt $cap) { $shownRows = @($rows[0..($cap - 1)]); [void]$html.AppendLine('<p class="notes">' + (ConvertTo-HtmlSafe ('This page shows the first {0} of {1} rows so it stays readable in a browser; the CSV beside it has every row.' -f $cap, $rows.Count)) + '</p>') }
        [void]$html.AppendLine((ConvertTo-ReportTable -Rows $shownRows -Columns $pageCols -NoWrap $nw -Widths $widths -SoftBreak $soft -FilterLinks $fl))
        [void]$html.AppendLine('</section>')
        $csvPath = $base + '.csv'
        if ($Sections.Count -gt 1) { $csvPath = $base + '-' + ($name -replace '[^A-Za-z0-9]', '') + '.csv' }
        if ($rows.Count -gt 0) {
            # written by hand (Export-Csv would copy every object): one quoted field per column, arrays joined "a, b",
            # and a cell that starts with = + - @ (a service or product name can) is prefixed with an apostrophe so it
            # cannot run as a formula when the CSV is opened in Excel - numbers such as -0.5 are left alone
            if ($cols.Count -eq 0) { $cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name }) }
            $csv = New-Object System.Text.StringBuilder
            [void]$csv.AppendLine((($cols | ForEach-Object { '"' + ($_ -replace '"', '""') + '"' }) -join ','))
            foreach ($r in $rows) {
                $cells = foreach ($c in $cols) {
                    $v = ''; if ($r.PSObject.Properties[$c]) { $v = $r.$c }
                    if ($v -is [array]) { $v = ($v -join ', ') }
                    $v = [string]$v
                    if ($v -match '^[=+\-@\t\r]' -and $v -notmatch '^-?\d+([.,]\d+)*$') { $v = "'" + $v }   # only a cell that is wholly a number is left alone
                    '"' + ($v -replace '"', '""') + '"'
                }
                [void]$csv.AppendLine($cells -join ',')
            }
            [System.IO.File]::WriteAllText($csvPath, $csv.ToString(), (New-Object System.Text.UTF8Encoding $true))
        } else {
            [System.IO.File]::WriteAllText($csvPath, '', (New-Object System.Text.UTF8Encoding $true))   # not Set-Content -Path: [ ] in a path are wildcards
        }
        $csvPaths += $csvPath
    }
    [void]$html.AppendLine('<div class="foot">' + (ConvertTo-HtmlSafe "$($script:Config.ToolName) $($script:Config.ToolVersion). Reports contain host names, account names (local administrators, the renamed Administrator, failed-logon accounts) and findings - treat as internal.") + '</div></body></html>')
    $htmlPath = $base + '.html'
    [System.IO.File]::WriteAllText($htmlPath, $html.ToString(), (New-Object System.Text.UTF8Encoding($true)))
    Write-PatchLog ("REPORT {0}: {1}" -f $Console, $htmlPath) 'OK'
    foreach ($p in $csvPaths) { Write-PatchLog "   csv: $p" 'INFO' }
    return [pscustomobject]@{ Html = $htmlPath; Csv = $csvPaths }
}

function Show-ReportDone {
    # After a report is written: offer to open it.  Not with a pop-up while another action is running
    # alongside (the Report buttons work during an install) - a modal pop-up would suspend that action.
    param($Report)
    if (-not (Test-GuiDialogAllowed 'The "open the report?" question')) { Write-PatchLog ("Report written: {0} - open it from the reports folder" -f $Report.Html) 'OK'; return }
    if ((Show-PatcherMessage -Text "Report written:`n$($Report.Html)`n`nOpen it now?" -Title 'Report' -Buttons 'YesNo') -eq 'Yes') { Start-Process $Report.Html }
}

function Open-ReportFolder {
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    Invoke-Item -LiteralPath $script:Config.ReportFolder
}
