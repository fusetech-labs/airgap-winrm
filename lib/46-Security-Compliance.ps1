# =====================================================================
#  46-Security-Compliance.ps1  -  THE COMPLIANCE DASHBOARD AND THE EXECUTIVE SUMMARY
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Under the Security console's server grid (behind a divider): how
#  compliant the servers shown are, as two donut charts -
#    Essential Eight   the controls at or below the maturity target (ML1-3)
#    ISM               every control that applies at the network's
#                      classification (Security profile)
#  - and a table with the same two figures for every group.
#  Every audited check of every server counts once:
#    Compliant                 it passed
#    Compliant by tailoring    a recorded risk decision accepts the failure, or
#                              it passed only against a tailored threshold
#    Not compliant             it failed or warned - also when the risk
#                              acceptance that covered it is past its review date
#    left out                  not applicable at this classification or for
#                              this server, not assessable from a server, or
#                              the value could not be read (listed separately)
#  Percentage = (compliant + compliant by tailoring) / everything counted.
#  "Executive summary..." turns the same figures into a plain-language
#  report for a manager: the charts first, then the main gaps, the risk
#  decisions behind the tailoring, and a short line per server.
#  Nothing here talks to a server: it reads the audit already made.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  46-Security-Compliance.ps1
#  New 2026-10-23.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# The chart colours (also the legend): green = in place, blue = in place by a recorded decision, red = not in place.
$script:ComplianceColours = [ordered]@{ Compliant = '#2E8B57'; Accepted = '#4A86C5'; NonCompliant = '#C0392B' }
$script:ComplianceLabels = [ordered]@{ Compliant = 'Compliant'; Accepted = 'Compliant by tailoring'; NonCompliant = 'Not compliant' }

function Get-ComplianceClass {
    # One resolved Security check row -> Compliant, Accepted (compliant by tailoring), NonCompliant, NotRead or Excluded.
    param($Row)
    $tail = [string]$Row.Tailoring
    switch ([string]$Row.Verdict) {
        'Pass' {
            # passed only because a tailored threshold relaxed it: any threshold token still in force counts (an overdue one
            # no longer relaxes anything, and a second, valid rule may stand next to it)
            $live = @(($tail -split ';\s*') | Where-Object { $_ -like 'threshold*' -and $_ -notlike '*(review overdue)*' })
            if ($live.Count -gt 0) { return 'Accepted' }
            return 'Compliant'
        }
        'RiskAccepted' {
            # a risk acceptance past its review date no longer makes the control compliant
            if ($tail -match 'accepted \(review overdue\)' -or [string]$Row.Note -match 'REVIEW OVERDUE') { return 'NonCompliant' }
            return 'Accepted'
        }
        'NotApplicable' { return 'Excluded' }
        'NotAssessable' { return 'Excluded' }
        'Error' { return 'NotRead' }
        'NotCollected' { return 'NotRead' }   # the collector was never asked on this server: not a gap, not compliant
        'Warn' { if (Test-UnreadEvidence -Evidence $Row.Evidence) { return 'NotRead' }; return 'NonCompliant' }
        'Fail' { return 'NonCompliant' }
    }
    return 'Excluded'
}

function Get-MaturityTarget {
    $prof = Get-SecurityProfile
    $target = 2; $parsed = 0
    if ([int]::TryParse([string]$prof.maturityTarget, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 3) { $target = $parsed }
    return $target
}

function Get-ServerCompliance {
    # One audited server classified: @{ Rows; E8; Ism } (counts by class).  Kept in the check-row cache, so it is cleared
    # with the server's rows (a new audit, a tailoring, profile, data-file or group change) and the dashboard, the group
    # rows and the report classify each server once - a fleet of hundreds is a sum of cached counts, not a re-count.
    param([string]$Server, [int]$Target)
    if (-not $script:CheckRowCache) { $script:CheckRowCache = @{} }
    $key = 'Compliance{0}|{1}' -f $Target, $Server   # "<what>|<server>": Clear-CheckRowCache -Servers finds it by the server part
    if ($script:CheckRowCache.ContainsKey($key)) { return $script:CheckRowCache[$key] }
    $rows = New-Object System.Collections.Generic.List[object]
    $e8 = @{ Compliant = 0; Accepted = 0; NonCompliant = 0; NotRead = 0 }; $ism = @{ Compliant = 0; Accepted = 0; NonCompliant = 0; NotRead = 0 }
    foreach ($r in @(Get-SecurityRows -Server $Server)) {
        $class = Get-ComplianceClass -Row $r
        if ($class -eq 'Excluded') { continue }
        $isE8 = ([int]$r.ML -gt 0 -and [int]$r.ML -le $Target)
        $rows.Add([pscustomobject]@{ Server = $Server; Id = $r.Id; Title = $r.Title; Group = $r.Group; ML = [int]$r.ML; Severity = $r.Severity; Class = $class; E8 = $isE8; Tailoring = [string]$r.Tailoring; Note = [string]$r.Note; Evidence = [string]$r.Evidence })
        $ism[$class]++
        if ($isE8) { $e8[$class]++ }
    }
    $entry = @{ Rows = $rows.ToArray(); E8 = $e8; Ism = $ism }
    $script:CheckRowCache[$key] = $entry
    return $entry
}

function Get-ComplianceFigures {
    # The two figures for a set of servers: @{ E8; Ism } each with Compliant, Accepted, NonCompliant, NotRead, Counted,
    # Percent; plus Audited (the servers that have an audit) and Rows (every classified row, for the report).
    param([string[]]$Servers)
    $target = Get-MaturityTarget
    $new = { [pscustomobject]@{ Compliant = 0; Accepted = 0; NonCompliant = 0; NotRead = 0; Counted = 0; Percent = $null } }
    $e8 = & $new; $ism = & $new
    $rows = New-Object System.Collections.Generic.List[object]; $audited = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($Servers)) {
        if (-not (Test-SecurityCollected -Server $s)) { continue }
        $audited.Add($s)
        $one = Get-ServerCompliance -Server $s -Target $target
        $rows.AddRange([object[]]$one.Rows)
        foreach ($k in 'Compliant', 'Accepted', 'NonCompliant', 'NotRead') { $e8.$k += $one.E8[$k]; $ism.$k += $one.Ism[$k] }
    }
    $audited = $audited.ToArray(); $rows = $rows.ToArray()
    foreach ($fig in $e8, $ism) {
        $fig.Counted = $fig.Compliant + $fig.Accepted + $fig.NonCompliant
        if ($fig.Counted -gt 0) {
            # rounded down: 99.6% is not "100%" while one control is still open
            $fig.Percent = [int][math]::Floor(100.0 * ($fig.Compliant + $fig.Accepted) / $fig.Counted)
        }
    }
    return [pscustomobject]@{ E8 = $e8; Ism = $ism; Audited = $audited; Rows = $rows; Target = $target; Classification = [string](Get-SecurityProfile).classification }
}

function Format-CompliancePercent {
    param($Figure)
    if ($null -eq $Figure.Percent) { return 'not audited' }
    return ('{0}% ({1} of {2})' -f $Figure.Percent, ($Figure.Compliant + $Figure.Accepted), $Figure.Counted)
}

function New-ComplianceChart {
    # A donut chart as a bitmap: title, the slices, the percentage in the hole, the legend with counts underneath.
    # The dashboard shows it in a PictureBox; the executive summary embeds the same picture (PNG).
    param([string]$Title, $Figure, [int]$Size = 230, [string]$Subtitle = '')
    # everything scales with the size: the report draws its charts at twice the size it shows them (sharp in print)
    $sc = $Size / 230.0
    $w = $Size + [int](20 * $sc); $h = $Size + [int](112 * $sc)
    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::White)
        $centre = New-Object System.Drawing.StringFormat; $centre.Alignment = 'Center'; $centre.LineAlignment = 'Center'
        $titleFont = New-Object System.Drawing.Font('Segoe UI', [single]([math]::Max(7, 10.5 * $sc)), [System.Drawing.FontStyle]::Bold)
        $small = New-Object System.Drawing.Font('Segoe UI', [single]([math]::Max(6, 7.7 * $sc)))
        $big = New-Object System.Drawing.Font('Segoe UI', [single]([math]::Max(11, 28.7 * $sc)), [System.Drawing.FontStyle]::Bold)
        $dark = [System.Drawing.Brushes]::Black; $grey = [System.Drawing.Brushes]::DimGray
        $g.DrawString($Title, $titleFont, $dark, (New-Object System.Drawing.RectangleF(0, [single](2 * $sc), $w, [single](22 * $sc))), $centre)
        if ($Subtitle) { $g.DrawString($Subtitle, $small, $grey, (New-Object System.Drawing.RectangleF(0, [single](22 * $sc), $w, [single](16 * $sc))), $centre) }
        $pad = [int](20 * $sc)
        $rect = New-Object System.Drawing.Rectangle($pad, [int](42 * $sc), ($Size - $pad), ($Size - $pad))
        $total = [int]$Figure.Counted
        if ($total -le 0) {
            $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gainsboro)), $rect)
        } else {
            $start = -90.0
            foreach ($k in @($script:ComplianceColours.Keys)) {
                $n = [int]$Figure.$k
                if ($n -le 0) { continue }
                $sweep = 360.0 * $n / $total
                $g.FillPie((New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($script:ComplianceColours[$k]))), $rect, [single]$start, [single]$sweep)
                $start += $sweep
            }
        }
        $inset = [int]($rect.Width * 0.22)
        $hole = New-Object System.Drawing.Rectangle(($rect.X + $inset), ($rect.Y + $inset), ($rect.Width - 2 * $inset), ($rect.Height - 2 * $inset))
        $g.FillEllipse([System.Drawing.Brushes]::White, $hole)
        $pctText = 'n/a'; if ($null -ne $Figure.Percent) { $pctText = [string]$Figure.Percent + '%' }
        $g.DrawString($pctText, $big, $dark, (New-Object System.Drawing.RectangleF($hole.X, [single]($hole.Y - 8 * $sc), $hole.Width, $hole.Height)), $centre)
        $g.DrawString('compliant', $small, $grey, (New-Object System.Drawing.RectangleF($hole.X, [single]($hole.Y + $hole.Height * 0.62), $hole.Width, [single](16 * $sc))), $centre)
        # the legend: one line per slice with its count, then what was left out
        $y = $rect.Bottom + 8 * $sc
        foreach ($k in @($script:ComplianceColours.Keys)) {
            $g.FillRectangle((New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($script:ComplianceColours[$k]))), [single](22 * $sc), [single]($y + 3 * $sc), [single](11 * $sc), [single](11 * $sc))
            $g.DrawString(('{0}: {1}' -f $script:ComplianceLabels[$k], [int]$Figure.$k), $small, $dark, [single](38 * $sc), [single]$y)
            $y += 17 * $sc
        }
        if ([int]$Figure.NotRead -gt 0) { $g.DrawString(('Not read (left out): {0}' -f [int]$Figure.NotRead), $small, $grey, [single](38 * $sc), [single]$y) }
    } finally {
        foreach ($o in @($titleFont, $small, $big, $centre)) { if ($o) { $o.Dispose() } }   # drawn on every repaint: GDI+ objects must not pile up
        $g.Dispose()
    }
    return $bmp
}

function New-ComplianceDonut {
    # A bare donut - the slices and the percentage only - for the report's group cards, whose labels and counts are page
    # text (small charts with their own legend print too small to read).
    param($Figure, [int]$Size = 240)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
        $g.Clear([System.Drawing.Color]::White)
        $pad = [int]($Size * 0.04)
        $rect = New-Object System.Drawing.Rectangle($pad, $pad, ($Size - 2 * $pad), ($Size - 2 * $pad))
        $total = [int]$Figure.Counted
        if ($total -le 0) { $g.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Gainsboro)), $rect) }
        else {
            $start = -90.0
            foreach ($k in @($script:ComplianceColours.Keys)) {
                $n = [int]$Figure.$k
                if ($n -le 0) { continue }
                $sweep = 360.0 * $n / $total
                $g.FillPie((New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml($script:ComplianceColours[$k]))), $rect, [single]$start, [single]$sweep)
                $start += $sweep
            }
        }
        $inset = [int]($rect.Width * 0.22)
        $hole = New-Object System.Drawing.Rectangle(($rect.X + $inset), ($rect.Y + $inset), ($rect.Width - 2 * $inset), ($rect.Height - 2 * $inset))
        $g.FillEllipse([System.Drawing.Brushes]::White, $hole)
        $centre = New-Object System.Drawing.StringFormat; $centre.Alignment = 'Center'; $centre.LineAlignment = 'Center'
        $pctText = 'n/a'; if ($null -ne $Figure.Percent) { $pctText = [string]$Figure.Percent + '%' }
        $font = New-Object System.Drawing.Font('Segoe UI', [single]($Size * 0.12), [System.Drawing.FontStyle]::Bold)
        $g.DrawString($pctText, $font, [System.Drawing.Brushes]::Black, (New-Object System.Drawing.RectangleF($hole.X, $hole.Y, $hole.Width, $hole.Height)), $centre)
    } finally {
        foreach ($o in @($font, $centre)) { if ($o) { $o.Dispose() } }
        $g.Dispose()
    }
    return $bmp
}

function ConvertTo-ImageTag {
    # A bitmap as an <img> with the PNG inline, so the report is one file that works offline.  -Width shows it smaller
    # than it was drawn: a chart drawn at twice the size and shown at half prints sharp on paper and in a PDF.
    param($Bitmap, [string]$Alt, [int]$Width = 0, [string]$Style = 'display:inline-block;margin:6px 18px 6px 0;border:1px solid #ddd')
    $ms = New-Object System.IO.MemoryStream
    try { $Bitmap.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $b64 = [Convert]::ToBase64String($ms.ToArray()) } finally { $ms.Dispose() }
    $size = ''
    if ($Width -gt 0) { $size = ' width="{0}" height="{1}"' -f $Width, [int]($Bitmap.Height * $Width / $Bitmap.Width) }
    return ('<img src="data:image/png;base64,{0}" alt="{1}"{2} style="{3}">' -f $b64, (ConvertTo-HtmlSafe $Alt), $size, $Style)
}

function New-ChartTag {
    # One chart for the report: drawn at twice the size shown (sharp in print), returned as an inline <img>.
    param([string]$Title, $Figure, [int]$Size, [string]$Subtitle = '', [string]$Alt, [string]$Style = 'display:inline-block;margin:6px 18px 6px 0;border:1px solid #ddd')
    $bmp = New-ComplianceChart -Title $Title -Figure $Figure -Size ($Size * 2) -Subtitle $Subtitle
    try { return (ConvertTo-ImageTag -Bitmap $bmp -Alt $Alt -Width ($Size + 20) -Style $Style) } finally { $bmp.Dispose() }
}

function Get-ComplianceGroupRows {
    # One row per group (from the group files), with the two figures for its audited servers.  -Within: only the groups
    # that hold at least one of these servers, and only those servers count - a report for one group lists the other
    # groups it shares servers with, figured on the shared servers alone ("2 of 2 audited (6 in the group)").
    # Figures / Members / Sort ride along for the report's group cards (the grid and the tables show the named columns).
    param([string[]]$Within = @())
    $inScope = @{}; foreach ($s in @($Within)) { if ($s) { $inScope[[string]$s] = $true } }   # @{} keys ignore case
    $out = @()
    foreach ($grp in @($script:Groups)) {
        $servers = @(Get-UniqueNames @($grp.Servers))
        if ($servers.Count -eq 0) { continue }
        $all = $servers.Count
        if ($inScope.Count -gt 0) { $servers = @($servers | Where-Object { $inScope.ContainsKey([string]$_) }); if ($servers.Count -eq 0) { continue } }
        $f = Get-ComplianceFigures -Servers $servers
        $overdue = @($f.Rows | Where-Object { $_.Tailoring -match 'overdue' } | ForEach-Object { $_.Id } | Select-Object -Unique).Count
        $count = '{0} of {1} audited' -f @($f.Audited).Count, $servers.Count
        if ($servers.Count -lt $all) { $count += (' ({0} in the group)' -f $all) }
        $out += [pscustomobject]@{
            Group = [string]$grp.Name; Servers = $count
            'Essential Eight' = (Format-CompliancePercent $f.E8); ISM = (Format-CompliancePercent $f.Ism)
            'By tailoring' = $f.Ism.Accepted; 'Not compliant' = $f.Ism.NonCompliant; 'Overdue reviews' = $overdue; 'Not read' = $f.Ism.NotRead
            # green only when something is actually in place: a group whose every counted control is met by tailoring alone is blue
            Light = $(if ($null -eq $f.Ism.Percent) { 'Grey' } elseif ($f.Ism.NonCompliant -eq 0 -and $f.Ism.Compliant -eq 0 -and $f.Ism.Accepted -gt 0) { 'Blue' } elseif ($f.Ism.NonCompliant -eq 0) { 'Green' } elseif ($f.Ism.Percent -ge 80) { 'Amber' } else { 'Red' })
            Figures = $f; Members = $servers; InGroup = $all; Sort = $(if ($null -eq $f.Ism.Percent) { 1000 } else { $f.Ism.Percent })
        }
    }
    return $out
}

function Update-SecurityDashboard {
    # Repaints the two charts (servers shown) and the table (every group).
    param([string[]]$Servers)
    $pies = $script:Gui['SecDashPies']
    if (-not $pies) { return }
    $f = Get-ComplianceFigures -Servers $Servers
    $prof = Get-SecurityProfile
    $pairs = @(@($script:Gui['SecDashE8'], ('Essential Eight ML{0}' -f $f.Target), $f.E8, ('controls at maturity level 1-{0}' -f $f.Target)), @($script:Gui['SecDashIsm'], ('ISM - {0}' -f $prof.classification), $f.Ism, 'every control for this classification'))
    foreach ($p in $pairs) {
        $old = $p[0].Image
        $p[0].Image = New-ComplianceChart -Title $p[1] -Figure $p[2] -Subtitle $p[3]
        if ($old) { $old.Dispose() }
    }
    $scope = [string]$script:Gui['SecurityGroupCombo'].SelectedItem; if (-not $scope) { $scope = '(all groups)' }
    $script:Gui['SecDashInfo'].Text = ('{0}: {1} of {2} server(s) audited' -f $scope, @($f.Audited).Count, @($Servers).Count)
    Set-GridRows -Grid $script:Gui['SecDashGroups'] -Rows @(Get-ComplianceGroupRows) -NoKeepChecks -RowColour { param($r) Get-LightColour $r.Light }
}

function Get-ComplianceExecutiveHtml {
    # The executive / project-manager summary: plain words, the charts first, then the gaps, the risk decisions and a
    # line per server.  $Servers = the servers shown; $Scope = how they were chosen ("all groups", a group name).
    param([string[]]$Servers, [string]$Scope = 'all groups')
    $Servers = @(Get-UniqueNames @($Servers))
    $f = Get-ComplianceFigures -Servers $Servers
    $prof = Get-SecurityProfile
    $audited = @($f.Audited)
    $groupRows = @(Get-ComplianceGroupRows -Within $Servers)
    # when the audits were run: one time, or the oldest to the newest (a fleet is rarely audited in one go)
    $when = 'not yet'
    $stamps = @($audited | ForEach-Object { (Get-CollectorResult -Name 'Settings' -Server $_).Checked } | Sort-Object)
    if ($stamps.Count -gt 0) {
        $when = $stamps[-1].ToString('yyyy-MM-dd HH:mm')
        if ($stamps[0].ToString('yyyy-MM-dd') -ne $stamps[-1].ToString('yyyy-MM-dd')) { $when = $stamps[0].ToString('yyyy-MM-dd') + ' to ' + $stamps[-1].ToString('yyyy-MM-dd') }
    }
    $facts = @(@('Scope', $Scope), @('Servers audited', ('{0} of {1}' -f $audited.Count, $Servers.Count)))
    if ($groupRows.Count -gt 0) { $facts += , @('Groups', [string]$groupRows.Count) }
    $facts += @(@('Network classification', [string]$prof.classification), @('Essential Eight target', ('Maturity Level {0}' -f $f.Target)), @('ISM release', (Get-IsmRelease)), @('Audited', $when), @('Prepared by', (Get-OperatorIdentity)))
    # on screen only: how to make the PDF (the hint is not printed)
    $sections = @(@{ Heading = ''; Html = '<style>@page{size:A4 portrait}</style><div class="hint noprint">To keep or send this report as a PDF: Print (Ctrl+P) and choose Save as PDF or Microsoft Print to PDF - the pages are laid out for A4 portrait. The charts and colours are part of the page; if they do not print, tick "Background graphics" in the print settings.</div>' })
    # ---- 1. at a glance: the two charts and the headline in words ----
    $glance = (New-ChartTag -Title ('Essential Eight - Maturity Level {0}' -f $f.Target) -Figure $f.E8 -Size 260 -Subtitle ('controls at maturity level 1-{0}' -f $f.Target) -Alt 'Essential Eight compliance') +
        (New-ChartTag -Title ('ISM - {0}' -f $prof.classification) -Figure $f.Ism -Size 260 -Subtitle 'every control for this classification' -Alt 'ISM compliance')
    $say = @()
    if ($audited.Count -eq 0) { $say += 'No server in this scope has been audited yet - run AUDIT on the Security console first.' }
    else {
        $say += ('Across the {0} audited server(s), {1} of the Essential Eight controls the Maturity Level {2} target needs are met ({3} of {4}).' -f $audited.Count, $(if ($null -ne $f.E8.Percent) { [string]$f.E8.Percent + '%' } else { 'none' }), $f.Target, ($f.E8.Compliant + $f.E8.Accepted), $f.E8.Counted)
        $say += ('Against everything the ISM asks at {0}, {1} is met ({2} of {3}).' -f $prof.classification, $(if ($null -ne $f.Ism.Percent) { [string]$f.Ism.Percent + '%' } else { 'none' }), ($f.Ism.Compliant + $f.Ism.Accepted), $f.Ism.Counted)
        if ($f.Ism.Accepted -gt 0) { $say += ('{0} of those are met by tailoring: the risk was assessed and accepted by a named person with a review date, or a different value was approved (see Risk decisions below).' -f $f.Ism.Accepted) }
        if ($f.Ism.NotRead -gt 0) { $say += ('{0} value(s) could not be read on the servers and are left out of the figures.' -f $f.Ism.NotRead) }
    }
    $sections += @{ Heading = 'Compliance at a glance'; Keep = $true; Html = ('<div>' + $glance + '</div><ul>' + ((@($say) | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe $_) + '</li>' }) -join '') + '</ul>') }
    # ---- 2. by group: a card per group (its two donuts, the counts as text), lowest compliance first, then every group in
    #      a table.  One group = the charts above already are that group: the table alone.  No group file: no section. ----
    $inReport = @{}; foreach ($s in $Servers) { $inReport[$s] = $true }   # @{} keys ignore case
    $memberOf = @{}; foreach ($s in $Servers) { $memberOf[$s] = @(foreach ($sg in @(Get-ServerGroups -Name $s)) { [string]$sg.Name }) }
    if ($groupRows.Count -gt 0) {
        $notes = @()
        $html = ''
        if ($groupRows.Count -ge 2) {
            $maxCards = 24
            $byGroup = @($groupRows | Sort-Object Sort, Group)
            $legend = (@($script:ComplianceColours.Keys) | ForEach-Object { '<span class="swatch" style="background:{0}"></span>{1}' -f $script:ComplianceColours[$_], (ConvertTo-HtmlSafe $script:ComplianceLabels[$_]) }) -join ' &nbsp; '
            $cards = New-Object System.Text.StringBuilder
            [void]$cards.Append('<p class="notes">' + $legend + ' &nbsp; - the percentage in each ring is compliant + compliant by tailoring. Lowest first.</p><div class="cards">')
            foreach ($item in @($byGroup | Select-Object -First $maxCards)) {
                $gf = $item.Figures
                $sub = '{0} of {1} server(s) audited' -f @($gf.Audited).Count, @($item.Members).Count
                if (@($item.Members).Count -lt $item.InGroup) { $sub += (' - {0} in the group' -f $item.InGroup) }
                [void]$cards.Append('<div class="card"><div class="h">' + (ConvertTo-HtmlSafe $item.Group) + '</div><div class="s">' + (ConvertTo-HtmlSafe $sub) + '</div>')
                if (@($gf.Audited).Count -eq 0) { [void]$cards.Append('<div class="none">not audited yet - no figures</div></div>'); continue }
                [void]$cards.Append('<table class="mini"><tr>')
                foreach ($pair in @(@(('Essential Eight ML{0}' -f $f.Target), $gf.E8), @(('ISM - {0}' -f $prof.classification), $gf.Ism))) {
                    $bmp = New-ComplianceDonut -Figure $pair[1] -Size 240
                    $img = ConvertTo-ImageTag -Bitmap $bmp -Alt ($item.Group + ' ' + $pair[0]) -Width 110 -Style 'display:block;margin:0 auto'
                    $bmp.Dispose()
                    $cap = '<b>' + (ConvertTo-HtmlSafe $pair[0]) + '</b><br>' + $(if ($pair[1].Counted -gt 0) { '{0} of {1} met' -f ($pair[1].Compliant + $pair[1].Accepted), $pair[1].Counted } else { 'nothing counted' })
                    if ($pair[1].Accepted -gt 0) { $cap += ('<br>{0} by tailoring' -f $pair[1].Accepted) }
                    [void]$cards.Append('<td>' + $img + '<div class="cap">' + $cap + '</div></td>')
                }
                [void]$cards.Append('</tr></table></div>')
            }
            [void]$cards.Append('</div>')
            $html = $cards.ToString()
            if ($byGroup.Count -gt $maxCards) { $notes += ('The {0} groups with the lowest compliance are shown as charts; all {1} are in the table.' -f $maxCards, $byGroup.Count) }
        }
        if (@($groupRows | Where-Object { @($_.Members).Count -lt $_.InGroup }).Count -gt 0) { $notes += 'A group that shares only some of its servers with this report is figured on those servers alone ("in the group" gives its full size).' }
        # a server listed in more than one group counts in each of them (the totals at the top count it once)
        $multi = @($Servers | Where-Object { @($memberOf[$_]).Count -gt 1 }).Count
        if ($multi -gt 0) { $notes += ('{0} server(s) belong to more than one group and count in each of them; the figures at the top count every server once.' -f $multi) }
        $loose = @($Servers | Where-Object { @($memberOf[$_]).Count -eq 0 }).Count
        if ($loose -gt 0) { $notes += ('{0} server(s) are in no group: they count in the figures at the top and are listed under Servers.' -f $loose) }
        if ($notes.Count -gt 0) { $html += '<p class="notes">' + ((@($notes) | ForEach-Object { ConvertTo-HtmlSafe $_ }) -join ' ') + '</p>' }
        $sections += @{ Heading = 'By group'; Html = $html; Class = $(if ($groupRows.Count -ge 2) { 'cardsec' } else { '' }) }
        $sections += @{ Heading = ''; Rows = @($groupRows | Sort-Object Sort, Group); Columns = @('Group', 'Servers', 'Essential Eight', 'ISM', 'By tailoring', 'Not compliant', 'Not read', 'Overdue reviews'); NoWrap = @('Servers', 'Essential Eight', 'ISM') }   # Not read: left out of the percentages, so it is shown beside them (R6-E-L5)
    }
    # ---- 3. the main gaps: the controls not met on the most servers ----
    $gaps = @($f.Rows | Where-Object { $_.Class -eq 'NonCompliant' } | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
        $first = $_.Group[0]
        $overdue = @($_.Group | Where-Object { $_.Tailoring -match 'accepted \(review overdue\)' }).Count
        [pscustomobject]@{ Control = $first.Title; Area = $first.Group; 'Servers not compliant' = ('{0} of {1}' -f $_.Count, $audited.Count); 'Essential Eight' = $(if ($first.ML -gt 0) { 'Maturity Level ' + $first.ML } else { '-' }); Priority = $first.Severity; Note = $(if ($overdue -gt 0) { 'the risk acceptance is past its review date on ' + $overdue } else { '' }) }
    })
    if ($gaps.Count -eq 0) { $sections += @{ Heading = 'Main gaps'; Lines = @($(if ($audited.Count -eq 0) { 'Nothing to list until the servers are audited.' } else { 'None: every counted control is met on every audited server.' })) } }
    else { $sections += @{ Heading = 'Main gaps'; Rows = $gaps; Columns = @('Control', 'Area', 'Servers not compliant', 'Essential Eight', 'Priority', 'Note'); NoWrap = @('Servers not compliant', 'Essential Eight'); Note = 'The controls not met on the most servers (up to 15). The technical detail of each - what was found and how to fix it - is in the Security report and on each server''s page in the tool.' } }
    # ---- 4. the risk decisions behind "compliant by tailoring": those that reach a server in this report ----
    $titles = @{}; foreach ($c in (Get-Checks -Console 'Security')) { $titles[$c.Id] = $c.Title }
    $groupsIn = @{}; foreach ($r in $groupRows) { $groupsIn[$r.Group] = $true }
    $allRules = @((Get-SecurityTailoring).rules)
    $rules = @($allRules | Where-Object {
        $sc = [string]$_.scope
        (-not $sc) -or $sc -eq 'all' -or ($sc -match '^group:(.+)$' -and $groupsIn.ContainsKey($Matches[1])) -or ($sc -match '^server:(.+)$' -and $inReport.ContainsKey($Matches[1]))
    })
    $decisions = @($rules | ForEach-Object {
        $rule = $_   # inside the switch, $_ is the action word
        $what = switch ([string]$rule.action) { 'disable' { 'Risk accepted' } 'downgrade' { 'Lower priority (still not compliant)' } 'threshold' { 'Different value approved: ' + [string]$rule.value } default { [string]$rule.action } }
        $od = Test-TailoringOverdue -Rule $_
        $known = $titles.ContainsKey([string]$_.check)   # a rule for a check that no longer exists affects nothing: amber, and not "in force"
        [pscustomobject]@{ Light = $(if ($od -or -not $known) { 'Amber' } else { 'Grey' }); Control = $(if ($known) { $titles[[string]$_.check] } else { [string]$_.check + ' (no such check)' }); 'Applies to' = $(if (-not [string]$_.scope -or [string]$_.scope -eq 'all') { 'every server' } else { ([string]$_.scope -replace '^group:', 'group ' -replace '^server:', 'server ') }); Decision = $what; Reason = [string]$_.reason; 'Decided by' = [string]$_.by; Date = [string]$_.date; Review = [string]$_.review; Status = $(if ($od) { 'REVIEW OVERDUE - no longer counted as compliant' } elseif (-not $known) { 'no such check - the rule affects nothing' } else { 'in' + [char]0xA0 + 'force' }) }   # a no-break space: a squeezed column must not split it
    })
    $note = 'Each decision is recorded with who made it, why and when it is reviewed. An accepted risk or an approved value counts as compliant until its review date; after that it counts as not compliant again until it is reviewed. "Lower priority" changes how urgent a gap is shown, not whether it is met.'
    if ($allRules.Count -gt $rules.Count) { $note += (' {0} decision(s) for groups or servers outside this report are left out.' -f ($allRules.Count - $rules.Count)) }
    $sections += @{ Heading = 'Risk decisions (tailoring)'; Rows = $decisions; Columns = @('Control', 'Applies to', 'Decision', 'Reason', 'Decided by', 'Date', 'Review', 'Status'); NoWrap = @('Date', 'Review'); Note = $note }
    # ---- 5. how the figures are worked out (before the server list, which can run to many pages) ----
    $sections += @{ Heading = 'How the figures are worked out'; Lines = @(
        'Every security control the tool checks counts once per server.',
        ('Essential Eight: the controls at Maturity Level 1 to {0} (the target). ISM: every control that applies to a {1} network.' -f $f.Target, $prof.classification),
        'Compliant = the server meets it. Compliant by tailoring = it does not, but a recorded risk decision accepts that, or an approved different value is met. Not compliant = it does not meet it - including where the risk acceptance has passed its review date.',
        'Left out of the figures: controls that do not apply at this classification or to this kind of server, controls that cannot be checked on a server (for example backups or a SIEM - they need their own evidence), and values that could not be read.',
        'A control that cannot be checked on a server but has a recorded risk decision (for example "backups are taken by product X") counts as compliant by tailoring from then on - the decision is the evidence, and the review date keeps it honest.',
        'A server in more than one group counts in each group''s figures, and once in the figures at the top.',
        'The percentage is rounded down, so 100% means every counted control is met.') }
    # ---- 6. a line per server: lowest compliance first; every group it is in; the servers not audited yet last ----
    $serverRows = @(foreach ($s in $Servers) {
        $sf = Get-ComplianceFigures -Servers @($s)
        $done = @($sf.Audited).Count -gt 0
        [pscustomobject]@{ Server = $s; Groups = $(if (@($memberOf[$s]).Count) { @($memberOf[$s]) -join ', ' } else { '-' }); 'Essential Eight' = (Format-CompliancePercent $sf.E8); ISM = (Format-CompliancePercent $sf.Ism); 'By tailoring' = $(if ($done) { $sf.Ism.Accepted } else { '' }); 'Not compliant' = $(if ($done) { $sf.Ism.NonCompliant } else { '' }); 'Not read' = $(if ($done) { $sf.Ism.NotRead } else { '' })
            Sort = $(if ($null -eq $sf.Ism.Percent) { 1000 } else { $sf.Ism.Percent }) }
    })
    $serverRows = @($serverRows | Sort-Object Sort, Server)
    $serverNote = 'Lowest compliance first; servers not audited yet are listed last.'
    # srv01 in one group file and srv01.corp.local in another are two rows and two audits of what is probably one machine
    $twice = @($Servers | Group-Object { ([string]$_ -split '\.')[0].ToLower() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { @($_.Group) -join ' / ' })
    if ($twice.Count -gt 0) { $serverNote += (' WARNING: {0} name(s) look like one machine listed twice (short name and full name) and count twice: {1}. Use one spelling in the group files.' -f $twice.Count, (($twice | Select-Object -First 5) -join '; ')) }
    $sections += @{ Heading = 'Servers'; Rows = $serverRows; Columns = @('Server', 'Groups', 'Essential Eight', 'ISM', 'By tailoring', 'Not compliant', 'Not read'); NoWrap = @('Essential Eight', 'ISM'); Note = $serverNote }
    return (New-DetailsHtml -Title 'Security compliance summary' -Subtitle ('Essential Eight and ISM compliance of {0} - for management and project reporting' -f $Scope) -Console 'Security' -Facts $facts -Sections $sections)
}

function Export-ComplianceExecutiveReport {
    # Writes reports\Security-Summary-<stamp>.html (one file: the charts are inside) and returns @{ Html }.
    param([string[]]$Servers, [string]$Scope = 'all groups')
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    $path = Join-Path $script:Config.ReportFolder ('Security-Summary-{0}.html' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($path, (Get-ComplianceExecutiveHtml -Servers $Servers -Scope $Scope), (New-Object System.Text.UTF8Encoding($true)))
    Write-PatchLog ("Executive summary written by {0}: {1}" -f (Get-OperatorIdentity), $path) 'OK'
    return [pscustomobject]@{ Html = $path; Csv = @() }
}

function New-SecurityDashboard {
    # The dashboard under the server grid (Panel2 of the Servers page's divider).
    param($Panel)
    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock = 'Top'; $bar.Height = 40; $bar.BackColor = 'WhiteSmoke'
    $title = New-Object System.Windows.Forms.Label; $title.Text = 'COMPLIANCE'; $title.Location = New-Object System.Drawing.Point(6, 11); $title.AutoSize = $true
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $exec = New-GuiButton -Text 'Executive summary report...' -X 110 -Y 5 -W 210 -H 30 -Colour 'LightSteelBlue' -ReadOnly -Tip 'A plain-language report for management: the charts first, then the main gaps, the risk decisions and a line per server - reports\Security-Summary-<date>.html' -OnClick {
        Invoke-GuiAction -Name 'Executive summary' -ReadOnly -Action {
            $scope = [string]$script:Gui['SecurityGroupCombo'].SelectedItem
            if (-not $scope -or $scope -eq '(all groups)') { $scope = 'all groups' } else { $scope = 'group ' + $scope }
            Show-ReportDone -Report (Export-ComplianceExecutiveReport -Servers (Get-SecurityShownServers) -Scope $scope)
        } }
    $info = New-Object System.Windows.Forms.Label; $info.Location = New-Object System.Drawing.Point(330, 12); $info.AutoSize = $true; $info.ForeColor = 'DimGray'
    $bar.Controls.AddRange(@($title, $exec, $info))
    $pies = New-Object System.Windows.Forms.FlowLayoutPanel; $pies.Dock = 'Left'; $pies.Width = 520; $pies.WrapContents = $false; $pies.AutoScroll = $true; $pies.BackColor = 'White'
    $e8 = New-Object System.Windows.Forms.PictureBox; $e8.Size = New-Object System.Drawing.Size(250, 342); $e8.SizeMode = 'Normal'
    $ism = New-Object System.Windows.Forms.PictureBox; $ism.Size = New-Object System.Drawing.Size(250, 342); $ism.SizeMode = 'Normal'
    $script:Gui['Tips'].SetToolTip($e8, 'Essential Eight controls at or below the maturity target (Security profile) on the servers shown')
    $script:Gui['Tips'].SetToolTip($ism, 'Every ISM control that applies at the network classification (Security profile) on the servers shown')
    $pies.Controls.AddRange(@($e8, $ism))
    $right = New-Object System.Windows.Forms.Panel; $right.Dock = 'Fill'
    $groups = New-ConsoleGrid -NoCheckBoxes -Columns @(@{ Name = 'Group'; Width = 150 }, @{ Name = 'Servers'; Width = 110 }, @{ Name = 'Essential Eight'; Width = 130 }, @{ Name = 'ISM'; Width = 130 }, @{ Name = 'By tailoring'; Width = 80 }, @{ Name = 'Not compliant'; Width = 90 }, @{ Name = 'Overdue reviews'; Width = 100 }, @{ Name = 'Not read'; Width = 70; Fill = $true })
    $groups.Add_DoubleClick({
        # show that group in the grid and the charts (the Group picker of the toolbar)
        if ($this.SelectedItems.Count -gt 0) { $name = $this.SelectedItems[0].Text; $combo = $script:Gui['SecurityGroupCombo']; if ($combo.Items.Contains($name)) { $combo.SelectedItem = $name } }
    })
    # no explainer text under the grid: the colours and what is counted are the heading's tool tip
    $gh = New-GridHeader -Heading 'BY GROUP' -Detail '' -Tip ("Percent compliant (met / counted): compliant + compliant by tailoring, of every counted control, rounded down.`nGreen = compliant; blue = compliant by tailoring (a recorded risk acceptance, or an approved value that is met) - a group row is blue when every counted control is met that way; red = not compliant (an acceptance past its review date counts here).`nLeft out: not applicable at this classification, not assessable from a server, values that could not be read.`nDouble-click a group to show it.")
    $right.Controls.AddRange(@($groups, $gh.Panel)); $groups.BringToFront()
    $Panel.Controls.AddRange(@($right, $pies, $bar)); $right.BringToFront()
    $script:Gui['SecDashPies'] = $pies; $script:Gui['SecDashE8'] = $e8; $script:Gui['SecDashIsm'] = $ism; $script:Gui['SecDashGroups'] = $groups; $script:Gui['SecDashInfo'] = $info
}
