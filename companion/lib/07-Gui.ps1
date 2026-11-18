# =====================================================================
#  07-Gui.ps1  -  THE SHELL: window, colour-coded tabs, shared log, helpers
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The WinRM toolkit's shell, as it is there: the same window, tabs, banners,
#  buttons, grids, details window, frame, icon and favicon - an operator who
#  knows one knows the other.  Each console lives in its own file and exposes
#  New-<Name>Console -Tabs.  Nothing in this file goes online.
# =====================================================================

$script:Quips = @(
    'Every file checked twice is a file you can trust once.'
    'The catalogue never lies. It just has twelve rows for one update, {0}.'
    'Hashes first, heroics later.'
    'A library with one file per product is a library the airgap can read.'
    'Patch Tuesday is a lifestyle - the download is Wednesday morning.'
    'If in doubt, read the log. The log never lies (it just mumbles).'
    'Green means it is already there. Amber means go and get it.'
    'A signature by the wrong vendor is not a signature.'
    'Superseded files make the airgap grid wide. Prune them.'
    'The scheduled task does the fetching; you do the carrying.'
)
function Get-RandomQuip { return (($script:Quips | Get-Random) -f $script:Config.OperatorName) }

function New-GuiButton {
    # -ReadOnly buttons stay enabled while a download runs (they only look, never change the library).
    # The colour is the meaning: blue asks a source (read-only), steel blue brings files into the library, coral removes,
    # green saves on this PC, grey works on this PC.  Flat face, one-pixel edge in a darker shade of its own colour.
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 150, [int]$H = 40, [string]$Colour = '', [scriptblock]$OnClick, [string]$Tip = '', [switch]$ReadOnly)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, $H)
    if (-not $Colour) { $Colour = 'Gainsboro' }
    Set-GuiButtonColour -Button $b -Colour $Colour
    if ($Tip) { $script:Gui['Tips'].SetToolTip($b, $Tip) }
    if ($ReadOnly) { $b.Tag = 'readonly' }
    $b.Add_Click($OnClick)
    $script:Gui['Buttons'] += $b
    return $b
}

function Set-GuiButtonColour {
    # The face and, from it, the edge, hover and pressed shades - so a button recoloured later keeps the look.
    param($Button, [string]$Colour)
    $Button.BackColor = $Colour; $Button.UseVisualStyleBackColor = $false
    $Button.FlatStyle = 'Flat'; $Button.FlatAppearance.BorderSize = 1
    $Button.FlatAppearance.BorderColor = Get-EdgeColour -Colour $Button.BackColor
    $Button.FlatAppearance.MouseOverBackColor = Get-EdgeColour -Colour $Button.BackColor -Factor 0.93
    $Button.FlatAppearance.MouseDownBackColor = Get-EdgeColour -Colour $Button.BackColor -Factor 0.84
}

function Get-EdgeColour {
    param([System.Drawing.Color]$Colour, [double]$Factor = 0.62)
    return [System.Drawing.Color]::FromArgb([int]($Colour.R * $Factor), [int]($Colour.G * $Factor), [int]($Colour.B * $Factor))
}

# ---------------------------------------------------------------------
#  The window icon - drawn here, so the tool ships no picture file: a rounded square in the Fusetech blue with the
#  logo's white lightning bolt.  The same drawing is the favicon of every HTML page the tool writes.
# ---------------------------------------------------------------------
function New-ToolkitIconBitmap {
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $s = [single]$Size
        $d = [single](2 * [Math]::Max(2, [int]($Size * 0.22)))
        $x0 = [single]0.5; $x1 = $s - 0.5 - $d
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($x0, $x0, $d, $d, 180, 90); $path.AddArc($x1, $x0, $d, $d, 270, 90)
        $path.AddArc($x1, $x1, $d, $d, 0, 90);   $path.AddArc($x0, $x1, $d, $d, 90, 90)
        $path.CloseFigure()
        $blue = [System.Drawing.Color]::FromName($script:Config.BrandColour)
        $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($s, $s)), $blue, [System.Drawing.Color]::DeepSkyBlue)
        $g.FillPath($fill, $path)
        $edge = New-Object System.Drawing.Pen((Get-EdgeColour -Colour $blue -Factor 0.75), 1)
        $g.DrawPath($edge, $path)
        $k = $s / 32
        $bolt = [System.Drawing.PointF[]]@(foreach ($p in @(@(14, 1), @(22, 1), @(18, 13), @(25, 13), @(10, 31), @(14, 18), @(7, 18))) { New-Object System.Drawing.PointF(([single]($p[0] * $k)), ([single]($p[1] * $k))) })
        $g.FillPolygon([System.Drawing.Brushes]::White, $bolt)
        $fill.Dispose(); $edge.Dispose(); $path.Dispose()
    } finally { $g.Dispose() }
    return $bmp
}

function Get-ToolkitIcon {
    if ($script:ToolkitIcon) { return $script:ToolkitIcon }
    Add-Type -AssemblyName System.Drawing
    $sizes = @(16, 20, 24, 32, 48, 64)
    $frames = New-Object System.Collections.Generic.List[byte[]]
    foreach ($sz in $sizes) {
        $bmp = New-ToolkitIconBitmap -Size $sz
        if ($sz -eq 32) { $mem = New-Object System.IO.MemoryStream; $bmp.Save($mem, [System.Drawing.Imaging.ImageFormat]::Png); $script:ToolkitIconPng = $mem.ToArray(); $mem.Dispose() }
        $data = $bmp.LockBits((New-Object System.Drawing.Rectangle(0, 0, $sz, $sz)), [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $stride = $data.Stride
        $rows = New-Object byte[] ($stride * $sz)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $rows, 0, $rows.Length)
        $bmp.UnlockBits($data); $bmp.Dispose()
        $maskRow = [int][Math]::Ceiling($sz / 32.0) * 4
        $frame = New-Object System.IO.MemoryStream
        $fw = New-Object System.IO.BinaryWriter($frame)
        $fw.Write([uint32]40); $fw.Write([int32]$sz); $fw.Write([int32](2 * $sz)); $fw.Write([uint16]1); $fw.Write([uint16]32)
        $fw.Write([uint32]0); $fw.Write([uint32]($sz * $sz * 4 + $maskRow * $sz)); $fw.Write([int32]0); $fw.Write([int32]0); $fw.Write([uint32]0); $fw.Write([uint32]0)
        for ($y = $sz - 1; $y -ge 0; $y--) { $fw.Write($rows, $y * $stride, $sz * 4) }
        $fw.Write((New-Object byte[] ($maskRow * $sz)))
        $fw.Flush(); $frames.Add($frame.ToArray()); $frame.Dispose()
    }
    try {
        $ico = New-Object System.IO.MemoryStream
        $w = New-Object System.IO.BinaryWriter($ico)
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $w.Write([byte]$sizes[$i]); $w.Write([byte]$sizes[$i]); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
            $offset += $frames[$i].Length
        }
        foreach ($fr in $frames) { $w.Write([byte[]]$fr) }
        $w.Flush(); $ico.Position = 0
        $script:ToolkitIcon = New-Object System.Drawing.Icon($ico)
    } catch {
        $one = New-ToolkitIconBitmap -Size 32
        $script:ToolkitIcon = [System.Drawing.Icon]::FromHandle($one.GetHicon())
    }
    return $script:ToolkitIcon
}

function Get-ToolkitFaviconTag {
    try { [void](Get-ToolkitIcon); return '<link rel="icon" type="image/png" href="data:image/png;base64,' + [Convert]::ToBase64String($script:ToolkitIconPng) + '">' } catch { return '' }
}

# ---------------------------------------------------------------------
#  Actions, status, pop-ups
# ---------------------------------------------------------------------
function Invoke-GuiAction {
    # Wraps every button click: one place for busy-state, error catching and refresh.  -ReadOnly actions may run while
    # another action is in progress (its own loop pumps the message queue).
    param([string]$Name, [scriptblock]$Action, [switch]$ReadOnly)
    if ($script:Gui['Busy']) {
        if (-not $ReadOnly) { Write-PatchLog "Still busy with '$($script:Gui['BusyName'])' - wait for it to finish" 'WARN'; return }
        if ($script:Gui['NestedBusy']) { Write-PatchLog "A read-only action is already running alongside '$($script:Gui['BusyName'])' - wait for it" 'WARN'; return }
        $script:Gui['NestedBusy'] = $true
        Write-PatchLog "$Name requested while '$($script:Gui['BusyName'])' is running - allowed, it is read-only" 'WHY'
        try { & $Action } catch { Write-PatchLog "$Name failed: $(Get-ShortError $_)" 'ERROR' } finally { $script:Gui['NestedBusy'] = $false; Invoke-ConsoleRefresh }
        return
    }
    $script:Gui['Busy'] = $true
    $script:Gui['BusyName'] = $Name
    foreach ($b in $script:Gui['Buttons']) { if ($b.Tag -ne 'readonly') { $b.Enabled = $false } }
    $script:Gui['Progress'].Style = 'Marquee'
    Set-GuiStatus "$Name ..."
    try {
        & $Action
    } catch {
        Write-PatchLog "$Name failed: $(Get-ShortError $_)" 'ERROR'
        Write-PatchLog "   failed at: $(Get-ErrorLocation $_)" 'WHY'
    } finally {
        $script:Gui['Progress'].Style = 'Blocks'; $script:Gui['Progress'].Value = 0
        try { Invoke-ConsoleRefresh } catch { Write-PatchLog "refresh failed: $(Get-ShortError $_)" 'WARN' }
        foreach ($b in $script:Gui['Buttons']) { $b.Enabled = $true }
        $script:Gui['Busy'] = $false
        $script:Gui['QuipLabel'].Text = Get-RandomQuip
        Set-GuiStatus 'Ready.'
    }
}

function Test-GuiDialogAllowed {
    # A window that waits for an answer stops everything behind it.  Not while a read-only action runs inside another,
    # and not while a file is streaming: the download would stand still until the window closed, and a server drops a
    # connection that nobody reads.
    param([string]$What = 'That dialog')
    if ($script:Gui['Downloading']) { Write-PatchLog "$What is available again when the download has finished - it would hold the download up" 'WARN'; return $false }
    if ($script:Gui['NestedBusy']) { Write-PatchLog "$What is available again when '$($script:Gui['BusyName'])' finishes" 'WARN'; return $false }
    return $true
}

function Show-GuiNotice {
    param([string]$Text)
    if ($script:Gui['NestedBusy'] -or $script:Gui['Downloading']) { Write-PatchLog $Text 'WARN'; return }
    $null = Show-PatcherMessage -Text $Text -Icon 'Warning'
}

function Set-GuiStatus {
    param([string]$Text)
    $label = $script:Gui['StatusLabel']
    if ($label -and -not $label.IsDisposed) { $label.Text = $Text; [System.Windows.Forms.Application]::DoEvents() }
}

function Set-GuiProgress {
    # The bar in the status strip: -Percent 0..100 shows a real bar, -Marquee goes back to "busy, unknown length".
    param([int]$Percent = -1, [switch]$Marquee)
    $bar = $script:Gui['Progress']
    if (-not $bar -or $bar.IsDisposed) { return }
    if ($Marquee) { $bar.Style = 'Marquee'; return }
    $bar.Style = 'Continuous'
    if ($Percent -lt 0) { $Percent = 0 }; if ($Percent -gt 100) { $Percent = 100 }
    $bar.Value = $Percent
    [System.Windows.Forms.Application]::DoEvents()
}

function Show-PatcherMessage {
    # One place for every pop-up.  RETURNS the button pressed ('OK', 'Cancel', 'Yes', 'No').
    param([string]$Text, [string]$Title = $script:Config.ToolName, [string]$Buttons = 'OK', [string]$Icon = 'Information', [string]$Default = 'Button1', [switch]$Wrap)
    Add-Type -AssemblyName System.Windows.Forms
    $lineCount = @($Text -split "`r?`n").Count
    if ($lineCount -gt 22 -or $Wrap) { return (Show-PatcherLongMessage -Text $Text -Title $Title -Buttons $Buttons -Default $Default -Wrap:$Wrap) }
    $owner = $script:Gui['Form']
    if ($owner -and -not $owner.IsDisposed) { return [string][System.Windows.Forms.MessageBox]::Show($owner, $Text, $Title, $Buttons, $Icon, $Default) }
    return [string][System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon, $Default)
}

function Show-PatcherLongMessage {
    param([string]$Text, [string]$Title, [string]$Buttons = 'OK', [string]$Default = 'Button1', [switch]$Wrap)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = New-Object System.Drawing.Size(900, 640); $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9); $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $true
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.Dock = 'Fill'; $box.BackColor = 'White'; $box.Text = $Text
    if ($Wrap) { $box.WordWrap = $true; $box.ScrollBars = 'Vertical'; $box.Font = New-Object System.Drawing.Font('Segoe UI', 10) }
    else { $box.WordWrap = $false; $box.ScrollBars = 'Both'; $box.Font = New-Object System.Drawing.Font('Consolas', 9) }
    $labels = @('OK'); if ($Buttons -eq 'OKCancel') { $labels = @('OK', 'Cancel') }; if ($Buttons -eq 'YesNo') { $labels = @('Yes', 'No') }
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @($labels | ForEach-Object { @{ Text = $_ } })
    $buttonObjects = @($bar.Buttons)
    foreach ($b in $buttonObjects) { $b.Tag = $b.Text; $b.Add_Click({ $this.FindForm().Tag = $this.Tag; $this.FindForm().Close() }) }
    $dlg.Controls.Add($box); $box.BringToFront(); $box.Select(0, 0)
    $dlg.AcceptButton = $buttonObjects[0]
    if ($Default -eq 'Button2' -and $buttonObjects.Count -gt 1) { $dlg.AcceptButton = $buttonObjects[1] }
    $dlg.CancelButton = $buttonObjects[-1]
    $dlg.Tag = $labels[-1]
    $owner = $script:Gui['Form']
    if ($owner -and -not $owner.IsDisposed) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $answer = [string]$dlg.Tag
    $dlg.Dispose()
    return $answer
}

# ---------------------------------------------------------------------
#  Consoles: refreshers, tabs, names
# ---------------------------------------------------------------------
function Register-ConsoleRefresher {
    param([string]$Console, [scriptblock]$Refresh)
    if (-not $script:Gui['RefreshByConsole']) { $script:Gui['RefreshByConsole'] = [ordered]@{}; $script:Gui['Stale'] = @{} }
    $script:Gui['RefreshByConsole'][$Console] = $Refresh
}

function Invoke-ConsoleRefresh {
    # Repaints the console on screen; the others are marked stale and repaint when their tab is opened.
    param([switch]$All)
    $map = $script:Gui['RefreshByConsole']; if (-not $map) { return }
    $visible = ''
    if (-not $All -and $script:Gui['Form'] -and $script:Gui['Form'].Visible -and $script:Gui['Tabs']) { try { $visible = [string]$script:Gui['Tabs'].SelectedTab.Tag } catch { $visible = '' } }
    foreach ($console in @($map.Keys)) {
        if ($visible -and $console -ne $visible) { $script:Gui['Stale'][$console] = $true; continue }
        try { & $map[$console] } catch { Write-PatchLog "refresh of the $console console failed: $(Get-ShortError $_)" 'WARN' }
        $script:Gui['Stale'][$console] = $false
    }
}

function Update-StaleConsole {
    param([string]$Console)
    if (-not $Console -or -not $script:Gui['Stale'] -or -not $script:Gui['Stale'][$Console]) { return }
    $r = $script:Gui['RefreshByConsole'][$Console]; if (-not $r) { return }
    try { & $r } catch { Write-PatchLog "refresh of the $Console console failed: $(Get-ShortError $_)" 'WARN' }
    $script:Gui['Stale'][$Console] = $false
}

function Get-ConsoleName {
    param([string]$Console)
    $n = [string]$script:Config.ConsoleNames[$Console]
    if ($n) { return $n }
    return $Console
}

function Register-ConsoleTab {
    param($Tabs, [string]$Console, [string]$Text)
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Text; $page.Tag = $Console; $page.BackColor = 'White'
    $Tabs.TabPages.Add($page)
    return $page
}

function Get-LightColour {
    # Row background per light (WinForms colour names): green only for "already in place".
    param([string]$Light)
    switch ($Light) {
        'Red'   { return 'MistyRose' }
        'Amber' { return 'LemonChiffon' }
        'Green' { return 'Honeydew' }
        'Blue'  { return 'AliceBlue' }
        default { return 'WhiteSmoke' }
    }
}

# ---------------------------------------------------------------------
#  Grid helpers - every console grid is a ListView built from a column list.  The FIRST column is the row key.
# ---------------------------------------------------------------------
function New-ConsoleGrid {
    param([object[]]$Columns, [switch]$NoCheckBoxes)
    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = (-not $NoCheckBoxes); $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.Dock = 'Fill'; $lv.HideSelection = $false; $lv.ShowItemToolTips = $true
    Set-GridColumns -Grid $lv -Columns $Columns
    $lv.Add_Resize({ Resize-GridFillColumn -Grid $this })
    if (-not $NoCheckBoxes) { Set-GridTickOnBoxOnly -Grid $lv }
    return $lv
}

function Set-GridTickOnBoxOnly {
    # Only a click on the box itself, the space bar, or the tool's own code may change a tick (a double-click opens details).
    param($Grid)
    $Grid.Add_MouseDown({
        if (-not $script:GridMouse) { $script:GridMouse = @{} }
        $hit = $this.HitTest($_.X, $_.Y)
        $script:GridMouse[$this.GetHashCode()] = @{ When = [datetime]::Now; OnBox = ($hit.Location -eq 'StateImage') }
    })
    $Grid.Add_KeyDown({ if ($script:GridMouse) { $script:GridMouse.Remove($this.GetHashCode()) } })
    $Grid.Add_ItemCheck({
        if ($script:GridProgrammatic) { return }
        $m = $null; if ($script:GridMouse) { $m = $script:GridMouse[$this.GetHashCode()] }
        if ($m -and -not $m.OnBox -and ([datetime]::Now - $m.When).TotalMilliseconds -lt 800) { $_.NewValue = $_.CurrentValue }
    })
}

function Set-GridChecks {
    param($Grid, [bool]$Checked)
    $script:GridProgrammatic = $true
    try { foreach ($i in $Grid.Items) { $i.Checked = $Checked } } finally { $script:GridProgrammatic = $false }
}

function Resize-GridFillColumn {
    param($Grid)
    if (-not $Grid -or $Grid.Columns.Count -eq 0) { return }
    $fill = $null; $others = 0
    foreach ($c in $Grid.Columns) { if ([string]$c.Tag -like 'fill:*') { $fill = $c } else { $others += $c.Width } }
    if (-not $fill) { return }
    $min = 120; [void][int]::TryParse(([string]$fill.Tag -split ':')[1], [ref]$min)
    $avail = $Grid.ClientSize.Width - $others - 4
    if ($avail -lt $min) { $avail = $min }
    if ($fill.Width -ne $avail) { $fill.Width = $avail }
    if ($Grid.Items.Count -gt 0) { Start-GridOriginCheck -Grid $Grid }
}

function Start-GridOriginCheck {
    param($Grid)
    if (-not $script:GridRepairTimers) { $script:GridRepairTimers = @{} }
    $key = $Grid.GetHashCode()
    $timer = $script:GridRepairTimers[$key]
    if (-not $timer) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 60; $timer.Tag = $Grid
        $timer.Add_Tick({ $this.Stop(); Repair-GridOrigin -Grid $this.Tag })
        $script:GridRepairTimers[$key] = $timer
    }
    $timer.Stop(); $timer.Start()
}

function Repair-GridOrigin {
    param($Grid)
    if (-not $Grid -or $Grid.IsDisposed -or $Grid.Items.Count -eq 0) { return $false }
    $shift = $Grid.Items[0].Bounds.X
    if ($shift -le 0) { return $false }
    $Grid.BeginUpdate()
    try { $Grid.View = 'List'; $Grid.View = 'Details' } finally { $Grid.EndUpdate() }
    return $true
}

function Set-GridColumns {
    param($Grid, [object[]]$Columns)
    $Grid.Columns.Clear()
    foreach ($c in $Columns) {
        $header = $Grid.Columns.Add([string]$c.Name, [int]$c.Width)
        if ($c.Fill) { $header.Tag = 'fill:' + [int]$c.Width }
    }
}

function Set-GridRows {
    # $Rows are objects; cell text = property named like the column.  $RowColour { param($row) -> colour name }.
    # $CellColourProperty names a hashtable on the row (column name -> colour name) for cells coloured apart from their row.
    param($Grid, [object[]]$Rows, [scriptblock]$RowColour, [string]$ToolTipProperty = '', [switch]$NoKeepChecks, [string]$CellColourProperty = '')
    $wasChecked = @{}
    if (-not $NoKeepChecks) { foreach ($k in @(Get-GridChecked -Grid $Grid)) { $wasChecked[$k] = $true } }
    $names = @($Grid.Columns | ForEach-Object { $_.Text })
    $script:GridProgrammatic = $true
    $Grid.BeginUpdate()
    try {
    $Grid.Items.Clear()
    $items = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
    foreach ($row in @($Rows)) {
        $first = [string]$row.($names[0])
        $item = New-Object System.Windows.Forms.ListViewItem($first)
        if ($names.Count -gt 1) {
            $subs = New-Object string[] ($names.Count - 1)
            for ($i = 1; $i -lt $names.Count; $i++) { $v = $row.($names[$i]); if ($v -is [array]) { $v = ($v -join ', ') }; $subs[$i - 1] = [string]$v }
            $item.SubItems.AddRange($subs)
        }
        if ($RowColour) { $col = & $RowColour $row; if ($col) { $item.BackColor = $col } }
        if ($CellColourProperty) {
            $cells = $row.$CellColourProperty
            if ($cells -and $cells.Count -gt 0) {
                $item.UseItemStyleForSubItems = $false
                $base = $item.BackColor
                for ($i = 0; $i -lt $names.Count; $i++) { $cc = $cells[$names[$i]]; if ($cc) { $item.SubItems[$i].BackColor = [System.Drawing.Color]::FromName([string]$cc) } else { $item.SubItems[$i].BackColor = $base } }
            }
        }
        if ($ToolTipProperty) { $item.ToolTipText = [string]$row.$ToolTipProperty }
        $item.Tag = $row
        if ($wasChecked.Count -gt 0 -and $wasChecked.ContainsKey($first)) { $item.Checked = $true }
        $items.Add($item)
    }
    $Grid.Items.AddRange($items.ToArray())
    } finally { $Grid.EndUpdate(); $script:GridProgrammatic = $false }
    Resize-GridFillColumn -Grid $Grid
}

function Get-GridChecked {
    param($Grid)
    $names = @()
    foreach ($item in $Grid.Items) { if ($item.Checked) { $names += $item.Text } }
    return @(Get-UniqueNames $names)
}

function Get-GridCheckedRows {
    param($Grid)
    return @(foreach ($item in $Grid.Items) { if ($item.Checked) { $item.Tag } })
}

function Get-GridSelectedRow {
    param($Grid)
    if ($Grid.SelectedItems.Count -gt 0) { return $Grid.SelectedItems[0].Tag }
    return $null
}

# ---------------------------------------------------------------------
#  Links: a source the operator can open and look at (a product's page, a line of the log)
# ---------------------------------------------------------------------
function Open-WebLink {
    # A web address the operator clicked, opened in the default browser.  Only http and https - nothing else is ever
    # started from a text - and nothing the tool fetched is opened by itself: a person clicks.  Returns whether it opened.
    # ($script:WebLinkOpener, when set, is called instead of the browser.)
    param([string]$Url)
    $address = ([string]$Url).Trim().TrimEnd('.', ',', ';', ')', ']', '>')
    if ($address -notmatch '^https?://[^\s"<>]+$') { Write-PatchLog ("not opened, not a web address: {0}" -f $Url) 'WARN'; return $false }
    try {
        if ($script:WebLinkOpener) { & $script:WebLinkOpener $address } else { Start-Process -FilePath $address }
        Write-PatchLog ("Opened in the browser: {0}" -f $address) 'INFO'
        return $true
    } catch { Write-PatchLog ("could not open {0}: {1}" -f $address, (Get-ShortError $_)) 'WARN'; return $false }
}

function Get-GridLinkAt {
    # The address under the mouse in a grid's link column ('' anywhere else)
    param($Grid, [int]$X, [int]$Y)
    $info = $null; if ($script:GridLinks) { $info = $script:GridLinks[$Grid.GetHashCode()] }
    if (-not $info) { return '' }
    $hit = $Grid.HitTest($X, $Y)
    if (-not $hit -or -not $hit.Item -or -not $hit.SubItem -or -not $hit.Item.Tag) { return '' }
    if ($hit.Item.SubItems.IndexOf($hit.SubItem) -ne $info.Index) { return '' }
    return [string]$hit.Item.Tag.($info.UrlProperty)
}

function Set-GridLinkColumn {
    # One column of a grid drawn and behaving as links: blue and underlined where the row has an address (its property
    # $UrlProperty), a hand over it, a click opens it (Open-WebLink).  Call it after every Set-GridRows: the rows are new.
    param($Grid, [string]$Column, [string]$UrlProperty = 'Url')
    $index = -1
    for ($i = 0; $i -lt $Grid.Columns.Count; $i++) { if ($Grid.Columns[$i].Text -eq $Column) { $index = $i } }
    if ($index -lt 0) { return }
    if (-not $script:GridLinks) { $script:GridLinks = @{} }
    $key = $Grid.GetHashCode()
    if (-not $script:GridLinks.ContainsKey($key)) {
        $script:GridLinks[$key] = @{ Index = $index; UrlProperty = $UrlProperty; Font = (New-Object System.Drawing.Font($Grid.Font, [System.Drawing.FontStyle]::Underline)) }
        $Grid.Add_MouseMove({ if (Get-GridLinkAt -Grid $this -X $_.X -Y $_.Y) { $this.Cursor = [System.Windows.Forms.Cursors]::Hand } else { $this.Cursor = [System.Windows.Forms.Cursors]::Default } })
        $Grid.Add_MouseLeave({ $this.Cursor = [System.Windows.Forms.Cursors]::Default })
        $Grid.Add_MouseUp({ if ($_.Button -eq 'Left') { $address = Get-GridLinkAt -Grid $this -X $_.X -Y $_.Y; if ($address) { $null = Open-WebLink -Url $address } } })
    }
    $info = $script:GridLinks[$key]; $info.Index = $index; $info.UrlProperty = $UrlProperty
    foreach ($item in $Grid.Items) { Set-GridLinkCell -Grid $Grid -Item $item }
}

function Set-GridLinkCell {
    # One row of a grid with a link column drawn again: every cell in the row's colours, the link blue and underlined.
    # (Call it after changing a row's colours: a cell of its own colour needs the row's style switched off, so the other
    # cells take the row's colours by hand.)
    param($Grid, $Item)
    $info = $null; if ($script:GridLinks) { $info = $script:GridLinks[$Grid.GetHashCode()] }
    if (-not $info -or -not $Item -or -not $Item.Tag -or $Item.SubItems.Count -le $info.Index) { return }
    if (-not [string]$Item.Tag.($info.UrlProperty)) { return }
    $Item.UseItemStyleForSubItems = $false
    foreach ($cell in $Item.SubItems) { $cell.BackColor = $Item.BackColor; $cell.ForeColor = $Item.ForeColor }
    $Item.SubItems[$info.Index].ForeColor = [System.Drawing.Color]::Blue
    $Item.SubItems[$info.Index].Font = $info.Font
}

# ---------------------------------------------------------------------
#  Banner, toolbar, headers, dialogs, the details window
# ---------------------------------------------------------------------
function New-ConsoleBanner {
    param($Tab, [string]$Console, [string]$Title, [string]$Subtitle = '')
    $back = $script:Config.ConsoleColours[$Console]; if (-not $back) { $back = 'MidnightBlue' }
    $fore = $script:Config.ConsoleText[$Console]; if (-not $fore) { $fore = 'White' }
    $banner = New-Object System.Windows.Forms.Panel
    $banner.Dock = 'Top'; $banner.Height = 64; $banner.BackColor = $back
    $rule = New-Object System.Windows.Forms.Panel; $rule.Dock = 'Bottom'; $rule.Height = 3; $rule.BackColor = 'Goldenrod'
    $banner.Controls.Add($rule)
    $t = New-Object System.Windows.Forms.Label
    $t.Text = $Title; $t.ForeColor = $fore; $t.AutoSize = $true
    $t.Font = New-Object System.Drawing.Font('Segoe UI', 20, [System.Drawing.FontStyle]::Bold)
    $t.Location = New-Object System.Drawing.Point(12, 6)
    $banner.Controls.Add($t)
    $s = New-Object System.Windows.Forms.Label
    $s.Text = $Subtitle; $s.ForeColor = 'White'; $s.AutoSize = $true
    $s.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Italic)
    $s.Location = New-Object System.Drawing.Point(520, 24)
    $banner.Controls.Add($s)
    $Tab.Controls.Add($banner)
    return [pscustomobject]@{ Panel = $banner; Title = $t; Subtitle = $s }
}

function New-GridHeader {
    param([string]$Heading, [string]$Detail = '', [string]$Tip = '')
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = 'Top'; $panel.Height = 26; $panel.BackColor = 'WhiteSmoke'
    $rule = New-Object System.Windows.Forms.Panel; $rule.Dock = 'Bottom'; $rule.Height = 1; $rule.BackColor = 'Silver'
    $headLabel = New-Object System.Windows.Forms.Label
    $headLabel.Text = $Heading; $headLabel.AutoSize = $true; $headLabel.Location = New-Object System.Drawing.Point(6, 5)
    $headLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold); $headLabel.ForeColor = 'Black'
    $detailLabel = New-Object System.Windows.Forms.Label
    $detailLabel.Text = $Detail; $detailLabel.AutoSize = $true; $detailLabel.ForeColor = 'DimGray'; $detailLabel.Location = New-Object System.Drawing.Point(($headLabel.PreferredWidth + 18), 7)
    $panel.Controls.AddRange(@($rule, $headLabel, $detailLabel))
    if ($Tip) { $script:Gui['Tips'].SetToolTip($headLabel, $Tip); $script:Gui['Tips'].SetToolTip($detailLabel, $Tip) }
    return @{ Panel = $panel; Title = $headLabel; Info = $detailLabel }
}

function New-ConsoleToolbar {
    param($Tab, [int]$Height = 56)
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = 'Top'; $toolbar.Height = $Height
    $Tab.Controls.Add($toolbar)
    return $toolbar
}

function New-DialogButtonBar {
    # A bottom bar with right-aligned buttons.  $Buttons: @{ Text; Result (optional); Width, Colour (optional) }, left to right.
    # Each wears the same flat face as the buttons of the tabs (grey unless a colour is asked for): left to the Windows
    # theme, a button of a pop-up window can draw as bare text and read as a label.
    param($Dialog, [object[]]$Buttons, [int]$Height = 44, [string]$Hint = '')
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = 'Bottom'; $bar.Height = $Height; $bar.Width = $Dialog.ClientSize.Width
    if ($Hint) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $Hint; $lbl.Location = New-Object System.Drawing.Point(10, 13); $lbl.AutoSize = $true; $lbl.ForeColor = 'DimGray'
        $bar.Controls.Add($lbl)
    }
    $x = $Dialog.ClientSize.Width - 10
    $made = @()
    for ($i = $Buttons.Count - 1; $i -ge 0; $i--) {
        $spec = $Buttons[$i]
        $w = 100; if ($spec.Width) { $w = [int]$spec.Width }
        $x -= $w
        $b = New-Object System.Windows.Forms.Button
        $b.Text = [string]$spec.Text; $b.Size = New-Object System.Drawing.Size($w, 30); $b.Location = New-Object System.Drawing.Point($x, 7); $b.Anchor = 'Top,Right'
        $face = [string]$spec.Colour; if (-not $face) { $face = 'Gainsboro' }
        Set-GuiButtonColour -Button $b -Colour $face
        if ($spec.Result) { $b.DialogResult = [string]$spec.Result }
        $bar.Controls.Add($b)
        $made = @($b) + $made
        $x -= 10
    }
    $Dialog.Controls.Add($bar)
    return @{ Panel = $bar; Buttons = $made }
}

function Save-HtmlAs {
    param([string]$Html, [string]$BaseName, $Owner, [string]$What = 'page')
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    $save = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $save.Title = "Save this $What as HTML"; $save.Filter = 'HTML page (*.html)|*.html|All files (*.*)|*.*'; $save.DefaultExt = 'html'; $save.AddExtension = $true; $save.OverwritePrompt = $true
        $save.InitialDirectory = $script:Config.ReportFolder
        $save.FileName = (($BaseName -replace '[^A-Za-z0-9]+', '-').Trim('-')) + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.html'
        if ($save.ShowDialog($Owner) -ne 'OK') { return '' }
        [System.IO.File]::WriteAllText($save.FileName, $Html, (New-Object System.Text.UTF8Encoding($true)))
        Write-PatchLog "Saved: $($save.FileName)" 'OK'
        return $save.FileName
    } finally { $save.Dispose() }
}

function Test-DetailsNavigation {
    # What the details window does when its page is asked to go somewhere: its own page (about:) loads; a web link is
    # handed to the operator's own browser (Open-WebLink: http and https only) and is not followed here; anything
    # else goes nowhere.  Returns whether the page itself may navigate.
    param($Url)
    $address = [string]$Url
    if (-not $address -or $address -like 'about:*') { return $true }
    if ($address -match '^https?://') { $null = Open-WebLink -Url $address }
    return $false
}

function New-DetailsView {
    # The built-in browser control that shows a details or Help page.  A link on the page (a product's release notes)
    # opens in the operator's own browser; the page itself stays where it is and never opens a second window.
    param([string]$Html)
    $view = New-Object System.Windows.Forms.WebBrowser
    $view.Dock = 'Fill'; $view.ScriptErrorsSuppressed = $true; $view.AllowWebBrowserDrop = $false; $view.IsWebBrowserContextMenuEnabled = $true
    $view.Add_Navigating({ if (-not (Test-DetailsNavigation -Url $_.Url)) { $_.Cancel = $true } })
    $view.Add_NewWindow({ $_.Cancel = $true })
    $view.DocumentText = $Html
    return $view
}

function Show-DetailsWindow {
    # The window behind every double-click and Help button: -Html in the built-in browser control, -Text in a box.
    param([string]$Title, [string]$Text = '', [string]$Html = '')
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title
    $w = 1200; $h = 780
    try { $owner = $script:Gui['Form']; if ($owner -and -not $owner.IsDisposed) { $wa = [System.Windows.Forms.Screen]::FromControl($owner).WorkingArea; $w = [math]::Min($w, $wa.Width - 40); $h = [math]::Min($h, $wa.Height - 40) } } catch { }
    $dlg.Size = New-Object System.Drawing.Size($w, $h)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $dlg.Icon = Get-ToolkitIcon
    if ($Html) {
        $view = New-DetailsView -Html $Html
        $script:Gui['DetailsHtml'] = $Html
        $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = 'Save as HTML...'; Width = 130 }, @{ Text = 'Close'; Result = 'Cancel'; Width = 90 }) -Height 40 -Hint 'Ctrl+A then Ctrl+C copies the page; Save as HTML... asks where to save it (the reports folder is offered first).'
        $script:Gui['DetailsHint'] = $bar.Panel.Controls[0]
        $bar.Buttons[0].Add_Click({
            try {
                $path = Save-HtmlAs -Html $script:Gui['DetailsHtml'] -BaseName ('Details-' + $script:Gui['DetailsTitle']) -Owner $this.FindForm()
                if ($path) { $script:Gui['DetailsHint'].Text = 'Saved: ' + $path } else { $script:Gui['DetailsHint'].Text = 'Not saved.' }
            } catch { $script:Gui['DetailsHint'].Text = 'Not saved: ' + (Get-ShortError $_); Write-PatchLog "Save failed: $(Get-ShortError $_)" 'ERROR' }
        })
        $script:Gui['DetailsTitle'] = $Title
        $dlg.Controls.Add($view)
        $view.BringToFront()
        $dlg.CancelButton = $bar.Buttons[1]
    } else {
        $box = New-Object System.Windows.Forms.TextBox
        $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Both'; $box.WordWrap = $false
        $box.Font = New-Object System.Drawing.Font('Consolas', 9); $box.BackColor = 'White'; $box.Dock = 'Fill'
        $box.Text = $Text
        $box.Select(0, 0)
        $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = 'Close'; Result = 'Cancel'; Width = 90 }) -Height 40 -Hint 'Ctrl+A then Ctrl+C copies everything.'
        $dlg.Controls.Add($box)
        $box.BringToFront()
        $dlg.CancelButton = $bar.Buttons[0]
    }
    [void]$dlg.ShowDialog($script:Gui['Form'])
    $dlg.Dispose()
}

# ---------------------------------------------------------------------
#  The window
# ---------------------------------------------------------------------
function Show-ToolkitGui {
    param([switch]$NoShow, [int]$AutoCloseSeconds = 0)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:Gui = @{ Buttons = @(); Busy = $false; Tips = (New-Object System.Windows.Forms.ToolTip); RefreshByConsole = [ordered]@{}; Stale = @{}; OnFirstShow = @{} }
    $font = New-Object System.Drawing.Font('Segoe UI', 9)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:Config.OperatorName)'s $($script:Config.ToolName) $($script:Config.ToolVersion) - internet side, the library for the airgap"
    $form.Size = New-Object System.Drawing.Size(1360, 900)
    $form.MinimumSize = New-Object System.Drawing.Size(1100, 720)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font
    # the Fusetech frame: a 3 px line in the brand blue round the whole client area
    $form.BackColor = [System.Drawing.Color]::FromName($script:Config.BrandColour); $form.Padding = New-Object System.Windows.Forms.Padding(3)
    $form.Icon = Get-ToolkitIcon
    $script:Gui['Form'] = $form

    # ---- status bar (bottom) ----
    $strip = New-Object System.Windows.Forms.StatusStrip
    $strip.BackColor = [System.Drawing.SystemColors]::Control
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready.'; $statusLabel.Spring = $true; $statusLabel.TextAlign = 'MiddleLeft'
    $progress = New-Object System.Windows.Forms.ToolStripProgressBar
    $progress.Size = New-Object System.Drawing.Size(220, 16); $progress.ToolTipText = 'Download-o-meter'
    $stop = New-Object System.Windows.Forms.ToolStripButton
    $stop.Text = 'Stop download'; $stop.Visible = $false; $stop.ToolTipText = 'Gives up the file being downloaded (the part file is deleted); the library is not changed'
    $stop.Add_Click({ $script:Gui['StopRequested'] = $true; $this.Enabled = $false; $this.Text = 'stopping...' })
    [void]$strip.Items.Add($statusLabel); [void]$strip.Items.Add($stop); [void]$strip.Items.Add($progress)
    $script:Gui['StatusLabel'] = $statusLabel; $script:Gui['Progress'] = $progress; $script:Gui['StopButton'] = $stop

    # ---- tabs on top, shared log underneath ----
    $outer = New-Object System.Windows.Forms.SplitContainer
    $outer.Dock = 'Fill'; $outer.Orientation = 'Horizontal'; $outer.BackColor = [System.Drawing.SystemColors]::Control
    $outer.FixedPanel = 'Panel2'
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = 'Fill'; $tabs.DrawMode = 'OwnerDrawFixed'; $tabs.ItemSize = New-Object System.Drawing.Size(132, 30); $tabs.SizeMode = 'Fixed'
    $script:Gui['TabHeaderFont'] = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $tabs.Add_DrawItem({
        param($src, $e)
        $page = $src.TabPages[$e.Index]
        $back = $script:Config.ConsoleColours[[string]$page.Tag]; if (-not $back) { $back = 'Gray' }
        $fore = $script:Config.ConsoleText[[string]$page.Tag]; if (-not $fore) { $fore = 'White' }
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromName($back))
        $e.Graphics.FillRectangle($brush, $e.Bounds)
        if ($e.Index -eq $src.SelectedIndex) { $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromName($fore), 3); $e.Graphics.DrawLine($pen, $e.Bounds.Left, $e.Bounds.Bottom - 2, $e.Bounds.Right, $e.Bounds.Bottom - 2) }
        $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
        $e.Graphics.DrawString($page.Text, $script:Gui['TabHeaderFont'], (New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromName($fore))), [System.Drawing.RectangleF]::op_Implicit($e.Bounds), $fmt)
    })
    $tabs.Add_SelectedIndexChanged({
        $p = $this.SelectedTab; if (-not $p) { return }
        Set-GuiStatus ("{0} console" -f $p.Text)
        Update-StaleConsole -Console ([string]$p.Tag)
        $first = $script:Gui['OnFirstShow'][[string]$p.Tag]
        if ($first -and -not $script:Gui['NestedBusy']) { $script:Gui['OnFirstShow'].Remove([string]$p.Tag); & $first }
    })
    $outer.Panel1.Controls.Add($tabs)
    $script:Gui['Tabs'] = $tabs

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock = 'Fill'; $logBox.ReadOnly = $true; $logBox.BackColor = 'White'; $logBox.WordWrap = $false
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    # every address the tool asked is in the log as a link: a click opens it, so a source can be looked at
    $logBox.DetectUrls = $true
    $logBox.Add_LinkClicked({ $null = Open-WebLink -Url $_.LinkText })
    $outer.Panel2.Controls.Add($logBox)
    $script:Gui['LogBox'] = $logBox
    foreach ($pre in @($script:PreGuiLines)) {
        if (-not $pre) { continue }
        $logBox.SelectionStart = $logBox.TextLength; $logBox.SelectionLength = 0
        $logBox.SelectionColor = [System.Drawing.Color]::FromName($(if ($pre[0] -eq 'ERROR') { 'Red' } else { 'DarkOrange' }))
        $logBox.AppendText([string]$pre[1] + "`r`n")
    }
    $script:PreGuiLines = @()

    # ---- the consoles, in tab order ----
    New-LibraryConsole -Tabs $tabs
    New-ProductsConsole -Tabs $tabs
    New-ScheduleConsole -Tabs $tabs
    New-SettingsConsole -Tabs $tabs
    New-AboutConsole -Tabs $tabs

    $form.Controls.Add($outer)
    $form.Controls.Add($strip)
    $outer.BringToFront()
    $script:Gui['Outer'] = $outer
    $form.Add_Shown({ try { $o = $script:Gui['Outer']; $o.SplitterDistance = [Math]::Max(300, $o.Height - 220 - $o.SplitterWidth) } catch { } })
    $form.Add_FormClosing({
        if ($script:Gui['Busy']) {
            $_.Cancel = $true
            Write-PatchLog "Close refused - still busy with '$($script:Gui['BusyName'])'. Wait for it to finish (or press Stop download), then close." 'WARN'
            Set-GuiStatus "Close refused - '$($script:Gui['BusyName'])' is still running"
            return
        }
        if (($script:Gui['SettingsDirty'] -or $script:Gui['ProductsDirty']) -and -not $script:Gui['AutoCloseTimer']) {
            $what = @(); if ($script:Gui['ProductsDirty']) { $what += 'Products' }; if ($script:Gui['SettingsDirty']) { $what += 'Settings' }
            $a = Show-PatcherMessage -Title 'Unsaved changes' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("The {0} tab has changes that are not saved.`n`nClose anyway and lose them?" -f ($what -join ' and '))
            if ($a -ne 'Yes') { $_.Cancel = $true; $script:Gui['Tabs'].SelectedTab = @($script:Gui['Tabs'].TabPages | Where-Object { $_.Tag -eq $what[0] })[0] }
            else { Write-PatchLog ('Closed with unsaved changes on the {0} tab - they were not saved' -f ($what -join ' and ')) 'WARN' }
        }
    })

    # ---- load the data and go ----
    Write-PatchLog ("Welcome, {0}! {1} {2}, root folder = {3}   (running as {4})" -f $script:Config.OperatorName, $script:Config.ToolName, $script:Config.ToolVersion, $script:RootFolder, (Get-OperatorIdentity)) 'INFO'
    Initialize-ToolkitData
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = New-Object System.Drawing.Size([Math]::Max($form.MinimumSize.Width, [Math]::Min(1600, $screen.Width)), [Math]::Max($form.MinimumSize.Height, [Math]::Min(900, $screen.Height)))
    if ($screen.Height -lt 740) { $form.WindowState = 'Maximized' }
    try { $form.PerformLayout(); $outer.SplitterDistance = [Math]::Max(300, $outer.Height - 220 - $outer.SplitterWidth) } catch { }
    if ($NoShow) { return $form }
    if ($AutoCloseSeconds -gt 0) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $AutoCloseSeconds * 1000
        $timer.Add_Tick({ $this.Stop(); $script:Gui['Form'].Close() })
        $timer.Start()
        $script:Gui['AutoCloseTimer'] = $timer
    }
    Write-PatchLog 'GUI is open. This console window keeps a colour copy of everything.' 'INFO'
    try { [void]$form.ShowDialog() } finally { $form.Dispose(); Write-PatchLog 'GUI closed. Bye!' 'INFO' }
}

function Initialize-ToolkitData {
    # Reads the products and the library folders, then lets each console repaint.
    $null = Get-Products
    $null = Get-LibraryFiles -Refresh
    Invoke-ConsoleRefresh -All
}
