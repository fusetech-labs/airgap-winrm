# =====================================================================
#  07-Gui.ps1  -  THE SHELL: window, colour-coded tabs, shared log, helpers
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Version 2 layout:
#    [ tabs: O/S Patching | Software | Health | Security | Commands | Code Tour | Settings | About ]  (painted in the console colour)
#    [ the selected console: banner, toolbar, grids, buttons                  ]
#    [ shared log (bottom of the window, visible from every console)          ]
#    [ status bar + patch-o-meter ]
#  This file holds only what every console shares: the window, the tab
#  painting, the log, Invoke-GuiAction, New-GuiButton, the grid helpers, the
#  banner/toolbar builders, the details window and the Code Tour tab.
#  Each console lives in its own file (20-Console-Patching.ps1, 30-Console-
#  Health.ps1, 40-Console-Security.ps1, 50-Console-Software.ps1, 60-Console-
#  Settings.ps1, 70-Console-About.ps1, 80-Console-Commands.ps1) and exposes
#  New-<Name>Console -Tabs.
#  Nothing in this file talks to a server.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  07-Gui.ps1
# ---------------------------------------------------------------------
#  Version 1 review (see CODE-REVIEW.md): R-02, R-12, R-28, R-30, R-32, R-01 rule.
#  Version 2: reduced to the shell; the Patching console moved to 20-Console-Patching.ps1
#  unchanged in behaviour; grid/banner/toolbar helpers and the generic details window added.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [ ] every button   [ ] closing during an install is refused
#  Comments   :
#    -
# =====================================================================

$script:Quips = @(
    'Snapshots first, heroics later.'
    'Solidcore in Update Mode? Of course it is, {0}.'
    'Patching: like gardening, but the weeds fight back.'
    'Every reboot is a small holiday for a server.'
    'KBs do not install themselves. Well... they do now.'
    'If in doubt, read the log. The log never lies (it just mumbles).'
    'Rule #1: the plan screen is not decorative.'
    '3010 is a happy number. It means "reboot me", not "I failed".'
    'Zero servers pending reboot? Frame it.'
    'Green is good. Amber is work. Red is coffee.'
    'One WinRM port: the little door every server leaves open for you.'
    'Patch Tuesday is a lifestyle.'
    'A green audit is just a red audit that got attention.'
)

# {0} = the operator's name, filled in when the quip is shown (the Settings tab may have changed it since this file loaded)
function Get-RandomQuip { return (($script:Quips | Get-Random) -f $script:Config.OperatorName) }

function New-GuiButton {
    # -ReadOnly buttons stay enabled while an install runs (they only look, never change anything).
    param([string]$Text, [int]$X, [int]$Y, [int]$W = 150, [int]$H = 40, [string]$Colour = '', [scriptblock]$OnClick, [string]$Tip = '', [switch]$ReadOnly)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text; $b.Location = New-Object System.Drawing.Point($X, $Y); $b.Size = New-Object System.Drawing.Size($W, $H)
    # Every button carries a colour of its own (grey when none is asked for): on a white console page a themed button
    # can draw as bare text and read as a link (operator screenshots 2026-10-23); a coloured one draws its edges everywhere.
    # The colour is the meaning, the same on every console: blue asks the servers (read-only), red changes them, coral
    # removes, khaki reboots, wheat is the Trellix Agent services, steel blue stages files without installing, green saves
    # on this PC, grey works on this PC.  The face is flat with a one-pixel edge in a darker shade of its own colour (the
    # capability brief's look, field review 2026-11) - the colour stays functional, the raised bevel goes.
    if (-not $Colour) { $Colour = 'Gainsboro' }
    $b.BackColor = $Colour; $b.UseVisualStyleBackColor = $false
    $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 1
    $b.FlatAppearance.BorderColor = Get-EdgeColour -Colour $b.BackColor
    $b.FlatAppearance.MouseOverBackColor = Get-EdgeColour -Colour $b.BackColor -Factor 0.93
    $b.FlatAppearance.MouseDownBackColor = Get-EdgeColour -Colour $b.BackColor -Factor 0.84
    if ($Tip) { $script:Gui['Tips'].SetToolTip($b, $Tip) }
    if ($ReadOnly) { $b.Tag = 'readonly' }
    $b.Add_Click($OnClick)
    $script:Gui['Buttons'] += $b
    return $b
}

function Get-DialogFrameColour {
    # The frame of every pop-up window: a darker shade of the brand blue (the main window wears the blue itself)
    return (Get-EdgeColour -Colour ([System.Drawing.Color]::FromName($script:Config.BrandColour)) -Factor 0.7)
}

function New-ToolkitDialogForm {
    # Every pop-up window of the toolkit starts here (owner's ask, 2026-11-06): a Form with a 3 px frame in a darker shade
    # of the brand blue, like the main window's, and the window icon.  The padding keeps docked children off the frame;
    # the frame is painted on every paint and after every resize; absolutely placed controls start at 10 px or more.
    # A MessageBox (Show-PatcherMessage) is Windows' own window and cannot wear it.
    $f = New-Object System.Windows.Forms.Form
    $f.Padding = New-Object System.Windows.Forms.Padding(3)
    try { $f.Icon = Get-ToolkitIcon } catch { }
    $f.Add_Paint({
        $c = Get-DialogFrameColour
        [System.Windows.Forms.ControlPaint]::DrawBorder($_.Graphics, $this.ClientRectangle, $c, 3, 'Solid', $c, 3, 'Solid', $c, 3, 'Solid', $c, 3, 'Solid')
    })
    $f.Add_Resize({ $this.Invalidate() })
    return $f
}

function Get-EdgeColour {
    # A darker shade of a colour - its red, green and blue scaled by the factor: the edge of a flat button, its pressed face
    param([System.Drawing.Color]$Colour, [double]$Factor = 0.62)
    return [System.Drawing.Color]::FromArgb([int]($Colour.R * $Factor), [int]($Colour.G * $Factor), [int]($Colour.B * $Factor))
}

# ---------------------------------------------------------------------
#  The window icon - drawn here, so the tool ships no picture file: a rounded square in the Fusetech blue with the
#  logo's white lightning bolt.  The same drawing is the favicon of every HTML page the tool writes.
# ---------------------------------------------------------------------
function New-ToolkitIconBitmap {
    # One size of the icon as a bitmap with a transparent background
    param([int]$Size)
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $s = [single]$Size
        $d = [single](2 * [Math]::Max(2, [int]($Size * 0.22)))   # the corner diameter
        $x0 = [single]0.5; $x1 = $s - 0.5 - $d                     # a half-pixel in from the edge, so the outline is not cut
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddArc($x0, $x0, $d, $d, 180, 90); $path.AddArc($x1, $x0, $d, $d, 270, 90)
        $path.AddArc($x1, $x1, $d, $d, 0, 90);   $path.AddArc($x0, $x1, $d, $d, 90, 90)
        $path.CloseFigure()
        $blue = [System.Drawing.Color]::FromName($script:Config.BrandColour)
        $fill = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.PointF(0, 0)), (New-Object System.Drawing.PointF($s, $s)), $blue, [System.Drawing.Color]::DeepSkyBlue)
        $g.FillPath($fill, $path)
        $edge = New-Object System.Drawing.Pen((Get-EdgeColour -Colour $blue -Factor 0.75), 1)
        $g.DrawPath($edge, $path)
        # the bolt: seven corners on a 32-unit drawing, scaled to the size
        $k = $s / 32
        $bolt = [System.Drawing.PointF[]]@(foreach ($p in @(@(14, 1), @(22, 1), @(18, 13), @(25, 13), @(10, 31), @(14, 18), @(7, 18))) { New-Object System.Drawing.PointF(([single]($p[0] * $k)), ([single]($p[1] * $k))) })
        $g.FillPolygon([System.Drawing.Brushes]::White, $bolt)
        $fill.Dispose(); $edge.Dispose(); $path.Dispose()
    } finally { $g.Dispose() }
    return $bmp
}

function Get-ToolkitIcon {
    # The window icon, drawn once per run in the sizes Windows asks for (title bar, taskbar, Alt+Tab, each one crisp),
    # packed as an in-memory .ico of plain 32-bit bitmaps - the one form every Windows and every System.Drawing reads
    # (PNG entries draw in a title bar, but Icon.ToBitmap in Windows PowerShell turns them to noise).  Also keeps the
    # 32 px drawing as a PNG for Get-ToolkitFaviconTag.
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
        $maskRow = [int][Math]::Ceiling($sz / 32.0) * 4   # the 1-bit AND mask, each row padded to 4 bytes; all zero, the alpha channel decides
        $frame = New-Object System.IO.MemoryStream
        $fw = New-Object System.IO.BinaryWriter($frame)
        # BITMAPINFOHEADER: size, width, height (colour rows + mask rows), planes, bits, compression, image size, 4 zeros
        $fw.Write([uint32]40); $fw.Write([int32]$sz); $fw.Write([int32](2 * $sz)); $fw.Write([uint16]1); $fw.Write([uint16]32)
        $fw.Write([uint32]0); $fw.Write([uint32]($sz * $sz * 4 + $maskRow * $sz)); $fw.Write([int32]0); $fw.Write([int32]0); $fw.Write([uint32]0); $fw.Write([uint32]0)
        for ($y = $sz - 1; $y -ge 0; $y--) { $fw.Write($rows, $y * $stride, $sz * 4) }   # bottom-up, BGRA as GDI+ holds it
        $fw.Write((New-Object byte[] ($maskRow * $sz)))
        $fw.Flush(); $frames.Add($frame.ToArray()); $frame.Dispose()
    }
    try {
        $ico = New-Object System.IO.MemoryStream
        $w = New-Object System.IO.BinaryWriter($ico)
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)   # ICONDIR: reserved, type 1 = icon, count
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {                                 # ICONDIRENTRY per size
            $w.Write([byte]$sizes[$i]); $w.Write([byte]$sizes[$i]); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$frames[$i].Length); $w.Write([uint32]$offset)
            $offset += $frames[$i].Length
        }
        foreach ($fr in $frames) { $w.Write([byte[]]$fr) }
        $w.Flush(); $ico.Position = 0
        $script:ToolkitIcon = New-Object System.Drawing.Icon($ico)
    } catch {
        # should the .ico not be read: the 32 px drawing alone, scaled by Windows
        $one = New-ToolkitIconBitmap -Size 32
        $script:ToolkitIcon = [System.Drawing.Icon]::FromHandle($one.GetHicon())
    }
    return $script:ToolkitIcon
}

function Get-ToolkitFaviconTag {
    # The window icon as the favicon of an HTML page: a data: link, so the page stays one file.  Empty if the drawing fails.
    try {
        [void](Get-ToolkitIcon)
        return '<link rel="icon" type="image/png" href="data:image/png;base64,' + [Convert]::ToBase64String($script:ToolkitIconPng) + '">'
    } catch { return '' }
}

function Invoke-GuiAction {
    # Wraps every button click: one place for busy-state, error catching and refresh.
    # -ReadOnly actions (status checks, WinRM test) may run WHILE an install is in progress - the
    # install's own wait loop pumps the message queue, so a click arrives in the middle of it and the
    # read-only action simply runs nested, without touching the busy flag or the locked buttons.
    param([string]$Name, [scriptblock]$Action, [switch]$ReadOnly)
    if ($script:Gui['Busy']) {
        if (-not $ReadOnly) { Write-PatchLog "Still busy with '$($script:Gui['BusyName'])' - wait for it to finish" 'WARN'; return }
        if ($script:Gui['NestedBusy']) { Write-PatchLog "A read-only action is already running alongside '$($script:Gui['BusyName'])' - wait for it" 'WARN'; return }
        $script:Gui['NestedBusy'] = $true
        Write-PatchLog "$Name requested while '$($script:Gui['BusyName'])' is running - allowed, it is read-only" 'WHY'
        try {
            & $Action
        } catch {
            Write-PatchLog "$Name failed: $(Get-ShortError $_)" 'ERROR'
        } finally {
            $script:Gui['NestedBusy'] = $false
            Invoke-ConsoleRefresh
        }
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
        $script:Gui['Progress'].Style = 'Blocks'
        $script:Gui['Progress'].Value = 0
        try { Invoke-ConsoleRefresh } catch { Write-PatchLog "refresh failed: $(Get-ShortError $_)" 'WARN' }   # before Busy is cleared: no queued click may start inside a half-built grid
        foreach ($b in $script:Gui['Buttons']) { $b.Enabled = $true }
        $script:Gui['Busy'] = $false
        $script:Gui['QuipLabel'].Text = Get-RandomQuip
        Set-GuiStatus 'Ready.'
    }
}

function Test-GuiDialogAllowed {
    # A modal dialog opened from a read-only action that runs ALONGSIDE an install would suspend the install's
    # wait loop (the dialog's own message loop replaces DoEvents until it closes) - so while another action
    # is running, dialogs wait.  Call it before any ShowDialog / Show-PatcherMessage inside a -ReadOnly action.
    param([string]$What = 'That dialog')
    if ($script:Gui['NestedBusy']) { Write-PatchLog "$What is available again when '$($script:Gui['BusyName'])' finishes" 'WARN'; return $false }
    return $true
}

function Show-GuiNotice {
    # A short warning pop-up - or a log line instead when a read-only action runs alongside another action
    # (a modal pop-up would suspend that action, see Test-GuiDialogAllowed).
    param([string]$Text)
    if ($script:Gui['NestedBusy']) { Write-PatchLog $Text 'WARN'; return }
    $null = Show-PatcherMessage -Text $Text -Icon 'Warning'
}

function Register-ConsoleRefresher {
    # Each console registers how it repaints itself from the shared results.
    param([string]$Console, [scriptblock]$Refresh)
    if (-not $script:Gui['RefreshByConsole']) { $script:Gui['RefreshByConsole'] = [ordered]@{}; $script:Gui['Stale'] = @{} }
    $script:Gui['RefreshByConsole'][$Console] = $Refresh
}

function Show-RepaintNotice {
    # The status bar says which console is repainting and the pointer waits, both painted at once: a repaint blocks the
    # window, and with many servers the operator saw nothing move for seconds after opening a tab (owner 2026-11-09).
    # -Off puts the text and the pointer back.  Nothing before the window shows (-NoShow, the start-up).
    param([string]$Console, [switch]$Off)
    $form = $script:Gui['Form']; $label = $script:Gui['StatusLabel']
    if (-not $form -or $form.IsDisposed -or -not $form.Visible) { return }
    try {
        if ($Off) {
            $form.UseWaitCursor = $false; [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
            if ($label -and $script:Gui.ContainsKey('StatusBeforeRepaint')) { $label.Text = [string]$script:Gui['StatusBeforeRepaint']; $script:Gui.Remove('StatusBeforeRepaint'); if ($label.Owner) { $label.Owner.Update() } }
        } else {
            if ($label) { $script:Gui['StatusBeforeRepaint'] = $label.Text; $label.Text = ('Repainting the {0} console ...' -f (Get-ConsoleName $Console)); if ($label.Owner) { $label.Owner.Refresh() } }   # Refresh paints now, without pumping other messages
            $form.UseWaitCursor = $true; [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
        }
    } catch { }
}

function Invoke-ConsoleRefresh {
    # Repaints the console on screen.  The others are only marked stale and repaint when their tab is opened: with
    # hundreds of servers a repaint of all three consoles after every click costs seconds.  Before the window is shown
    # (-NoShow) or with -All, every console repaints.  A hand edit of a data, SOE or security file since the
    # last repaint clears the cached verdicts first.
    param([switch]$All)
    if (Test-ToolFilesChanged) { Clear-CheckRowCache }
    $map = $script:Gui['RefreshByConsole']; if (-not $map) { return }
    $visible = ''
    if (-not $All -and $script:Gui['Form'] -and $script:Gui['Form'].Visible -and $script:Gui['Tabs']) { try { $visible = [string]$script:Gui['Tabs'].SelectedTab.Tag } catch { $visible = '' } }
    foreach ($console in @($map.Keys)) {
        if ($visible -and $console -ne $visible) { $script:Gui['Stale'][$console] = $true; continue }
        $notice = [bool]($visible -and $console -eq $visible)   # the console on screen: say so while it repaints
        if ($notice) { Show-RepaintNotice -Console $console }
        try { & $map[$console] } catch { Write-PatchLog "refresh of the $console console failed: $(Get-ShortError $_)" 'WARN' } finally { if ($notice) { Show-RepaintNotice -Console $console -Off } }
        $script:Gui['Stale'][$console] = $false
    }
}

function Update-StaleConsole {
    # The tab just opened: repaint its console if a refresh skipped it while it was hidden.
    param([string]$Console)
    if (-not $Console -or -not $script:Gui['Stale'] -or -not $script:Gui['Stale'][$Console]) { return }
    $r = $script:Gui['RefreshByConsole'][$Console]; if (-not $r) { return }
    Show-RepaintNotice -Console $Console
    try { & $r } catch { Write-PatchLog "refresh of the $Console console failed: $(Get-ShortError $_)" 'WARN' } finally { Show-RepaintNotice -Console $Console -Off }
    $script:Gui['Stale'][$Console] = $false
}

# ---------------------------------------------------------------------
#  Grid helpers - every console grid is a ListView built from a column list.
#  $Columns = @( @{ Name = 'Server'; Width = 170 }, ... ).  The FIRST column is
#  the row key (ticks survive a rebuild by that key).
# ---------------------------------------------------------------------
function New-ConsoleGrid {
    # Columns: @{ Name; Width; Fill = $true }.  The Fill column takes whatever width is left when the window is
    # wide, so long text (reasons, roles) is shown instead of empty space.
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
    # A ListView with tick boxes toggles the tick on a double-click anywhere in the row - and a double-click is
    # also how the details window opens, so a server got ticked by accident.  Only a click on the box itself,
    # the space bar, or the tool's own code (Set-GridChecks, Set-GridRows) may change a tick.
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
    # Tick or untick every row from code (the Tick all / Untick buttons) - bypasses the box-only rule above.
    param($Grid, [bool]$Checked)
    $script:GridProgrammatic = $true
    try { foreach ($i in $Grid.Items) { $i.Checked = $Checked } } finally { $script:GridProgrammatic = $false }
}

function Resize-GridFillColumn {
    # Gives the column tagged 'fill:<minimum>' the width that is left over (never less than its minimum).
    param($Grid)
    if (-not $Grid -or $Grid.Columns.Count -eq 0) { return }
    $fill = $null; $others = 0
    foreach ($c in $Grid.Columns) { if ([string]$c.Tag -like 'fill:*') { $fill = $c } else { $others += $c.Width } }
    if (-not $fill) { return }
    $min = 120; [void][int]::TryParse(([string]$fill.Tag -split ':')[1], [ref]$min)
    $avail = $Grid.ClientSize.Width - $others - 4
    if ($avail -lt $min) { $avail = $min }
    if ($fill.Width -ne $avail) { $fill.Width = $avail }
    # ComCtl quirk (field finding 2026-10-19): a grid that was scrolled sideways and then grows until everything fits
    # ends up with its content shifted RIGHT by the old scroll amount - no scrollbar, last column off the edge.  The
    # shift only appears after this handler has returned, so a one-shot timer looks again a moment later.
    if ($Grid.Items.Count -gt 0) { Start-GridOriginCheck -Grid $Grid }
}

function Start-GridOriginCheck {
    # One 60 ms timer per grid (kept in $script:GridRepairTimers), restarted on every resize; its tick runs Repair-GridOrigin.
    param($Grid)
    if (-not $script:GridRepairTimers) { $script:GridRepairTimers = @{} }
    $key = $Grid.GetHashCode()
    $timer = $script:GridRepairTimers[$key]
    if (-not $timer) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 60; $timer.Tag = $Grid
        $timer.Add_Tick({ $this.Stop(); Repair-GridOrigin -Grid $this.Tag })   # $this = the timer; its Tag = the grid
        $script:GridRepairTimers[$key] = $timer
    }
    $timer.Stop(); $timer.Start()
}

function Repair-GridOrigin {
    # Content shifted right (the first item's Bounds.X > 0) is never a legitimate scroll position.  Switching the view
    # to List and back makes the control recompute its origin; ticks, selection and column widths survive (verified
    # in the field test).  Returns $true when a repair was made.
    param($Grid)
    if (-not $Grid -or $Grid.IsDisposed -or $Grid.Items.Count -eq 0) { return $false }
    $shift = $Grid.Items[0].Bounds.X
    if ($shift -le 0) { return $false }
    $Grid.BeginUpdate()
    try { $Grid.View = 'List'; $Grid.View = 'Details' } finally { $Grid.EndUpdate() }
    Write-PatchLog ('grid origin repaired (content was shifted {0} px right after a resize)' -f $shift) 'INFO'
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
    # $ToolTipProperty names a property shown when hovering the row.  Ticks are kept by first-column text.
    # $CellColourProperty names a hashtable on the row (column name -> colour name) for cells coloured apart from
    # their row (the Software grid: an installed package green in a row that is yellow for another).
    # Built for thousands of rows: cells are read straight off the object (a missing property reads as empty) and
    # added in one AddRange per row.
    param($Grid, [object[]]$Rows, [scriptblock]$RowColour, [string]$ToolTipProperty = '', [switch]$NoKeepChecks, [string]$CellColourProperty = '')
    $wasChecked = @{}
    if (-not $NoKeepChecks) { foreach ($k in @(Get-GridChecked -Grid $Grid)) { $wasChecked[$k] = $true } }
    $names = @($Grid.Columns | ForEach-Object { $_.Text })
    $script:GridProgrammatic = $true    # restoring ticks is the tool's doing, not a click (see Set-GridTickOnBoxOnly)
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
                # each cell then carries its own colour: the row's, unless the table names another
                $item.UseItemStyleForSubItems = $false
                $base = $item.BackColor
                for ($i = 0; $i -lt $names.Count; $i++) {
                    $cc = $cells[$names[$i]]
                    if ($cc) { $item.SubItems[$i].BackColor = [System.Drawing.Color]::FromName([string]$cc) } else { $item.SubItems[$i].BackColor = $base }
                }
            }
        }
        if ($ToolTipProperty) { $item.ToolTipText = [string]$row.$ToolTipProperty }
        $item.Tag = $row
        if ($wasChecked.Count -gt 0 -and $wasChecked.ContainsKey($first)) { $item.Checked = $true }
        $items.Add($item)
    }
    $Grid.Items.AddRange($items.ToArray())
    } finally { $Grid.EndUpdate(); $script:GridProgrammatic = $false }   # never leave a grid frozen or the tick guard off
    Resize-GridFillColumn -Grid $Grid
}

function Set-GridItemCellColour {
    # One cell of a ListView row in its own colour (a hand-built grid: the O/S Patching list).  The first call switches the
    # row to per-cell style and gives every cell the row's colour first, so the others keep looking like the row.
    param([Parameter(Mandatory = $true)]$Item, [int]$Index, [string]$Colour)
    if (-not $Colour -or $Index -lt 0 -or $Index -ge $Item.SubItems.Count) { return }
    if ($Item.UseItemStyleForSubItems) {
        $Item.UseItemStyleForSubItems = $false
        foreach ($si in $Item.SubItems) { $si.BackColor = $Item.BackColor }
    }
    $Item.SubItems[$Index].BackColor = [System.Drawing.Color]::FromName($Colour)
}

function Get-GridChecked {
    param($Grid)
    $names = @()
    foreach ($item in $Grid.Items) { if ($item.Checked) { $names += $item.Text } }
    return @(Get-UniqueNames $names)
}

function Get-GridAllKeys {
    param($Grid)
    return @(Get-UniqueNames @($Grid.Items | ForEach-Object { $_.Text }))
}

function Get-GridSelectedRow {
    param($Grid)
    if ($Grid.SelectedItems.Count -gt 0) { return $Grid.SelectedItems[0].Tag }
    return $null
}

# ---------------------------------------------------------------------
#  Banner, toolbar, group picker - the same look on every console tab.
# ---------------------------------------------------------------------
function New-ConsoleBanner {
    param($Tab, [string]$Console, [string]$Title, [string]$Subtitle = '')
    $back = $script:Config.ConsoleColours[$Console]; if (-not $back) { $back = 'MidnightBlue' }
    $fore = $script:Config.ConsoleText[$Console]; if (-not $fore) { $fore = 'White' }
    $banner = New-Object System.Windows.Forms.Panel
    $banner.Dock = 'Top'; $banner.Height = 64; $banner.BackColor = $back
    # the console keeps its own colour; the gold rule along the foot of every banner is the one accent they share
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
    # A heading strip above a grid: bold heading on the left, live detail text (counts) in grey after it, a rule
    # underneath.  Dock Top - add it to the grid's parent AFTER the grid and BringToFront the grid (dock order).
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

# ---------------------------------------------------------------------
#  Lists that must survive a big fleet (hundreds of servers)
#    New-TickList      a filter box over a CheckedListBox; ticks live in a hashtable so filtering never loses them
#    Set-ComboTypeAhead / Get-ComboChoice   a combo you can type into, with suggestions, instead of a 500-row drop-down
# ---------------------------------------------------------------------
function New-TickList {
    # Returns the state hashtable: Panel (Dock Left, or re-dock it yourself), List, Filter, TitleLabel, Names, Ticks.
    # Every handler finds that state through its control's Tag; -OnChange runs after any tick change.
    param([string]$Title, [scriptblock]$OnChange, [int]$Width = 260)
    $state = @{ Names = @(); Ticks = @{}; OnChange = $OnChange; TitleText = $Title; Filling = $false }
    $panel = New-Object System.Windows.Forms.Panel; $panel.Dock = 'Left'; $panel.Width = $Width
    $titleLabel = New-Object System.Windows.Forms.Label; $titleLabel.Dock = 'Top'; $titleLabel.Height = 24; $titleLabel.Text = $Title; $titleLabel.Padding = New-Object System.Windows.Forms.Padding(4, 6, 0, 0)
    $filterBar = New-Object System.Windows.Forms.Panel; $filterBar.Dock = 'Top'; $filterBar.Height = 28
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Location = New-Object System.Drawing.Point(4, 4); $filter.Width = $Width - 8; $filter.Tag = $state
    $script:Gui['Tips'].SetToolTip($filter, 'Type part of a name to shorten the list; ticks are kept while you filter.')
    $filter.Add_TextChanged({ Update-TickListItems -State $this.Tag })
    $filterBar.Controls.Add($filter)
    $list = New-Object System.Windows.Forms.CheckedListBox; $list.Dock = 'Fill'; $list.CheckOnClick = $true; $list.IntegralHeight = $false; $list.Tag = $state
    $list.Add_ItemCheck({
        # fires BEFORE the tick changes: record the new state, then tell the owner
        $st = $this.Tag; if ($st.Filling) { return }
        $st.Ticks[[string]$this.Items[$_.Index]] = ($_.NewValue -eq 'Checked')
        Update-TickListTitle -State $st
        if ($st.OnChange) { & $st.OnChange }
    })
    $btns = New-Object System.Windows.Forms.Panel; $btns.Dock = 'Bottom'; $btns.Height = 38
    $all = New-Object System.Windows.Forms.Button; $all.Text = 'Tick shown'; $all.Location = New-Object System.Drawing.Point(4, 5); $all.Size = New-Object System.Drawing.Size(100, 28); $all.Tag = $state
    $all.Add_Click({ Set-TickListShown -State $this.Tag -Checked $true })
    $none = New-Object System.Windows.Forms.Button; $none.Text = 'Untick shown'; $none.Location = New-Object System.Drawing.Point(110, 5); $none.Size = New-Object System.Drawing.Size(100, 28); $none.Tag = $state
    $none.Add_Click({ Set-TickListShown -State $this.Tag -Checked $false })
    $btns.Controls.AddRange(@($all, $none))
    $panel.Controls.AddRange(@($list, $filterBar, $titleLabel, $btns)); $list.BringToFront()
    $state.Panel = $panel; $state.List = $list; $state.Filter = $filter; $state.TitleLabel = $titleLabel
    return $state
}

function Set-TickListNames {
    # The names to offer: names already known keep their tick, new ones get -DefaultTicked, vanished ones are dropped.
    param($State, [string[]]$Names, [bool]$DefaultTicked = $false)
    $ticks = @{}
    foreach ($n in @($Names)) { if ($State.Ticks.ContainsKey($n)) { $ticks[$n] = $State.Ticks[$n] } else { $ticks[$n] = $DefaultTicked } }
    $State.Names = @($Names); $State.Ticks = $ticks
    Update-TickListItems -State $State
}

function Update-TickListItems {
    # Rebuilds the visible list from the names that match the filter, ticking from the hashtable.
    param($State)
    $q = [string]$State.Filter.Text
    $State.Filling = $true
    try {
        $State.List.BeginUpdate(); $State.List.Items.Clear()
        foreach ($n in @($State.Names)) {
            if ($q -and $n.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }   # plain text, not a wildcard pattern
            $idx = $State.List.Items.Add($n)
            if ($State.Ticks[$n]) { $State.List.SetItemChecked($idx, $true) }
        }
    } finally { $State.List.EndUpdate(); $State.Filling = $false }
    Update-TickListTitle -State $State
}

function Update-TickListTitle {
    param($State)
    $q = [string]$State.Filter.Text
    $ticked = @($State.Ticks.Keys | Where-Object { $State.Ticks[$_] }).Count
    $State.TitleLabel.Text = ('{0}  ({1} of {2} ticked{3})' -f $State.TitleText, $ticked, @($State.Names).Count, $(if ($q) { ', ' + $State.List.Items.Count + ' shown' } else { '' }))
}

function Set-TickListShown {
    # Tick shown / Untick shown: only the names the filter currently shows.
    param($State, [bool]$Checked)
    foreach ($n in @($State.List.Items | ForEach-Object { [string]$_ })) { $State.Ticks[$n] = $Checked }
    Update-TickListItems -State $State
    if ($State.OnChange) { & $State.OnChange }
}

function Get-TickListChecked {
    param($State)
    return @(@($State.Names) | Where-Object { $State.Ticks[$_] })
}

function Set-ComboTypeAhead {
    # A long list becomes typeable: the box accepts text and suggests the matching items as you type.
    param($Combo)
    $Combo.DropDownStyle = 'DropDown'; $Combo.AutoCompleteMode = 'SuggestAppend'; $Combo.AutoCompleteSource = 'ListItems'; $Combo.DropDownHeight = 320
}

function Get-ComboChoice {
    # The item a type-ahead combo names right now: its text when that matches an item (any case), else ''.
    param($Combo)
    $t = ([string]$Combo.Text).Trim()
    if (-not $t) { return '' }
    foreach ($i in $Combo.Items) { if ([string]$i -ieq $t) { return [string]$i } }
    return ''
}

function New-ConsoleToolbar {
    param($Tab, [int]$Height = 56)
    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Dock = 'Top'; $toolbar.Height = $Height
    $Tab.Controls.Add($toolbar)
    return $toolbar
}

function New-GroupPicker {
    # "Group: [combo]" on a toolbar; the combo is filled by Initialize-ToolkitData for every console.
    param($Toolbar, [int]$X = 8, [scriptblock]$OnChange)
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Group:'; $lbl.Location = New-Object System.Drawing.Point($X, 13); $lbl.AutoSize = $true
    $Toolbar.Controls.Add($lbl)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.Location = New-Object System.Drawing.Point(($X + 47), 9); $combo.Width = 170; $combo.DropDownStyle = 'DropDownList'
    if ($OnChange) { $combo.Add_SelectedIndexChanged($OnChange) }
    $Toolbar.Controls.Add($combo)
    $script:Gui['GroupCombos'] += $combo
    return $combo
}

function Get-GroupRows {
    # (Server, Group) pairs for the group a combo has selected.
    param($Combo)
    $filter = [string]$Combo.SelectedItem
    $rows = @()
    foreach ($g in $script:Groups) {
        if ($filter -and $filter -ne '(all groups)' -and $filter -ne $g.Name) { continue }
        foreach ($name in $g.Servers) { $rows += [pscustomobject]@{ Server = $name; Group = $g.Name } }
    }
    return $rows
}

function New-DialogButtonBar {
    # A bottom bar with right-aligned buttons that stay right-aligned when the dialog is resized.
    # A control anchored Right keeps the distance to its parent's edge AS IT WAS when the anchor was set, so the
    # bar must already have the dialog's width before the buttons are placed - a Panel is 200 px wide until it
    # is docked, and a button placed at X 880 in it ends up far outside the dialog (field finding, 2026-10-19).
    # $Buttons: @{ Text; Result ('OK', 'Cancel', 'Yes', 'No' - optional); Width (optional) }, left to right.
    # Returns @{ Panel; Buttons } with the Button objects in the same order.
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
        if ($spec.Result) { $b.DialogResult = [string]$spec.Result }
        $bar.Controls.Add($b)
        $made = @($b) + $made
        $x -= 10
    }
    $Dialog.Controls.Add($bar)
    return @{ Panel = $bar; Buttons = $made }
}

function Save-HtmlAs {
    # A standard Save dialog for an HTML page: any folder, with the reports folder and a stamped file name offered.
    # Returns the path written, or '' when the user cancelled.  Used by the details window and the Code Tour.
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

function Show-DetailsWindow {
    # The window behind every console's double-click.  -Html shows a formatted page (headings, tables, coloured
    # lights, wrapped text) in the built-in browser control, offline; -Text shows plain text in a box.
    param([string]$Title, [string]$Text = '', [string]$Html = '')
    $dlg = New-ToolkitDialogForm
    $dlg.Text = $Title
    # 1200 x 780, or what the screen has: on a 1366 x 768 laptop the full size would put the button bar below the edge
    $w = 1200; $h = 780
    try { $owner = $script:Gui['Form']; if ($owner -and -not $owner.IsDisposed) { $wa = [System.Windows.Forms.Screen]::FromControl($owner).WorkingArea; $w = [math]::Min($w, $wa.Width - 40); $h = [math]::Min($h, $wa.Height - 40) } } catch { }
    $dlg.Size = New-Object System.Drawing.Size($w, $h)
    $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    if ($Html) {
        $view = New-Object System.Windows.Forms.WebBrowser
        $view.Dock = 'Fill'; $view.ScriptErrorsSuppressed = $true; $view.AllowNavigation = $false; $view.AllowWebBrowserDrop = $false; $view.IsWebBrowserContextMenuEnabled = $true
        $view.DocumentText = $Html
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

function Get-ConsoleName {
    # The name a console is shown by (ConsoleNames in 01-Config.ps1: Patching -> 'O/S Patching'); the key stays the
    # same inside the tool (colours, report file names, refreshers).
    param([string]$Console)
    $n = [string]$script:Config.ConsoleNames[$Console]
    if ($n) { return $n }
    return $Console
}

function Register-PanelButtonRows {
    # A right-hand panel's rows of two or three buttons keep up with the panel's width (the divider dragged, a wide
    # window): the full-width buttons are anchored to the right edge already; these rows are re-laid on every resize,
    # each button keeping its share of the width, so every right edge is the same (owner's screenshot 2026-10-28).
    # A row = the buttons that share a Top and are narrower than the full width.
    # The full-width controls (list, folder line, PATCH IT!, Help ...) and the ones pinned to the right edge are placed
    # here too, not by Anchor: in a scrolling panel narrower than its design width WinForms' anchoring stops 5 px short
    # and leaves a horizontal scroll bar (measured 2026-10-29), so every edge is set from the client width instead.
    param($Panel, [string]$Name)
    $rows = @()
    foreach ($g in @($Panel.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Width -lt 390 } | Group-Object Top)) {
        if ($g.Count -lt 2) { continue }
        $buttons = @($g.Group | Sort-Object Left)
        $rows += , @{ Buttons = $buttons; Widths = @($buttons | ForEach-Object { $_.Width }) }
    }
    $full = @($Panel.Controls | Where-Object { $_.Width -ge 390 })
    $pinned = @($Panel.Controls | Where-Object { $_.Width -lt 390 -and ($_.Anchor -band [System.Windows.Forms.AnchorStyles]::Right) -and -not ($_.Anchor -band [System.Windows.Forms.AnchorStyles]::Left) })
    foreach ($c in $full + $pinned) { $c.Anchor = 'Top, Left' }
    if (-not $script:Gui['PanelRows']) { $script:Gui['PanelRows'] = @{} }
    $script:Gui['PanelRows'][$Name] = $rows
    $script:Gui['PanelRows'][$Name + '|full'] = $full
    $script:Gui['PanelRows'][$Name + '|pinned'] = $pinned
    $Panel.Name = $Name
    $Panel.Add_ClientSizeChanged({ Resize-PanelButtonRows -Panel $this })   # also when a scroll bar comes or goes
    Resize-PanelButtonRows -Panel $Panel
}

function Resize-PanelButtonRows {
    param($Panel)
    if (-not $script:Gui['PanelRows'] -or -not $Panel.Name -or -not $script:Gui['PanelRows'].ContainsKey($Panel.Name)) { return }
    if ($script:Gui['PanelResizing']) { return }   # the layout pass below changes the client size once more: no second round
    $script:Gui['PanelResizing'] = $true
    try { Set-PanelButtonLayout -Panel $Panel; $Panel.PerformLayout() } finally { $script:Gui['PanelResizing'] = $false }   # the pass drops a sideways scroll bar computed before the controls moved
}

function Set-PanelButtonLayout {
    param($Panel)
    $rows = @($script:Gui['PanelRows'][$Panel.Name])
    $avail = $Panel.ClientSize.Width - 25   # 10 px on the left, 15 on the right: where the full-width buttons sit at the design width
    if ($avail -lt 120) { return }
    $sx = $Panel.AutoScrollPosition.X   # a panel scrolled sideways: positions are relative to the visible area
    foreach ($c in @($script:Gui['PanelRows'][$Panel.Name + '|full'])) { $c.Left = 10 + $sx; $c.Width = $avail }
    foreach ($c in @($script:Gui['PanelRows'][$Panel.Name + '|pinned'])) { $c.Left = 10 + $sx + $avail - $c.Width }
    foreach ($row in $rows) {
        $buttons = @($row.Buttons); $widths = @($row.Widths)
        $n = $buttons.Count; $gap = 5
        $total = ($widths | Measure-Object -Sum).Sum
        $x = 10; $left = $avail - $gap * ($n - 1)
        for ($i = 0; $i -lt $n; $i++) {
            $w = [int][math]::Floor($left * $widths[$i] / $total)
            if ($i -eq $n - 1) { $w = $avail - ($x - 10) }   # the last one takes the rounding, so the right edge is exact
            $buttons[$i].Left = $x + $sx; $buttons[$i].Width = $w
            $x += $w + $gap
        }
    }
}

function Add-PanelBand {
    # A band of a right-hand panel that a setting can take away (the Trellix boxes and buttons): its controls, and the
    # height they take - when hidden, everything below moves up by it, so no hole is left (Set-PanelBandShown).
    param($Panel, [object[]]$Controls, [int]$Height, [string]$Kind)
    if (-not $script:Gui['PanelBands']) { $script:Gui['PanelBands'] = @() }
    $designTop = (@($Controls) | Measure-Object -Property Top -Minimum).Minimum
    $script:Gui['PanelBands'] += , @{ Panel = $Panel; Controls = @($Controls); Height = $Height; Kind = $Kind; Shown = $true; DesignTop = $designTop }
}

function Get-PanelBandOffset {
    # How much higher a control designed at $DesignTop sits while bands above it are hidden - for a panel that re-places its
    # own controls from their design positions (the Software panel, under its "* NEW" box).
    param($Panel, [int]$DesignTop)
    $off = 0
    foreach ($band in @($script:Gui['PanelBands'])) { if ([object]::ReferenceEquals($band.Panel, $Panel) -and -not $band.Shown -and $band.DesignTop -lt $DesignTop) { $off -= $band.Height } }
    return $off
}

function Set-PanelBandShown {
    # Every band of $Kind shown or hidden; a change moves the controls below the band by its height.  Called after the
    # panels' button rows are registered (Register-PanelButtonRows groups by Top: moved first, a hidden row and the row
    # below would become one).
    param([string]$Kind, [bool]$Shown)
    foreach ($band in @($script:Gui['PanelBands'])) {
        if ($band.Kind -ne $Kind -or [bool]$band.Shown -eq $Shown) { continue }
        $top = (@($band.Controls) | Measure-Object -Property Top -Minimum).Minimum
        $by = $band.Height; if (-not $Shown) { $by = -$band.Height }
        # at or below the band's top: hidden, the next row sits exactly there, and showing it again must move that row too
        foreach ($c in @($band.Panel.Controls)) { if (@($band.Controls) -notcontains $c -and $c.Top -ge $top) { $c.Top += $by } }
        foreach ($c in @($band.Controls)) { $c.Visible = $Shown }
        $band.Shown = $Shown
    }
}

function Update-TrellixShown {
    # TrellixInUse (Settings tab), applied at once: the Trellix bands of both right-hand panels (the "Stop the Trellix Agent
    # services first" box, the Start / Stop Trellix Agent buttons).  The Trellix columns follow the setting whenever a
    # grid is built (a save marks every console for a redraw).
    Set-PanelBandShown -Kind 'Trellix' -Shown (Test-TrellixInUse)
}

function Get-ToolkitStartSize {
    # The window's first size.  Tall enough that the right-hand panels (O/S Patching, Software) show every button
    # without scrolling - measured from the controls themselves, so a new button is allowed for - and as
    # wide as the screen allows, up to 1600 px.  The log underneath gets 220 px, and gives way down to 120 px on a short
    # screen; a screen shorter still opens the window maximised and the panels scroll.
    param($Form, $Outer, $Strip, $Tabs, [System.Drawing.Rectangle]$Screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea)
    $need = 0
    foreach ($p in @($script:Gui['RightPanels'])) {
        $bottom = 0
        foreach ($c in $p.Controls) {
            $h = $c.Height
            if ($c -is [System.Windows.Forms.Label] -and $c.AutoSize) { $h = [Math]::Max($h, $c.PreferredSize.Height) }   # a wrapped legend
            $bottom = [Math]::Max($bottom, $c.Top + $h)
        }
        $chrome = 0; foreach ($c in $p.Parent.Controls) { if ([string]$c.Dock -eq 'Top') { $chrome += $c.Height } }   # banner + toolbar
        $need = [Math]::Max($need, $chrome + $bottom + $p.Padding.Bottom + 6)
    }
    $fixed = ($Tabs.ItemSize.Height + 8) + $Outer.SplitterWidth + $Strip.Height + $Form.Padding.Vertical + ($Form.Size.Height - $Form.ClientSize.Height)
    $log = 220
    $max = $false
    if ($need + $fixed + $log -gt $Screen.Height) {
        $log = [Math]::Max(120, $Screen.Height - $need - $fixed)
        if ($need + $fixed + $log -gt $Screen.Height) { $max = $true }
    }
    $height = [Math]::Max($Form.MinimumSize.Height, [Math]::Min($Screen.Height, $need + $fixed + $log))
    $width = [Math]::Max($Form.MinimumSize.Width, [Math]::Min(1600, $Screen.Width))
    return [pscustomobject]@{ Width = $width; Height = $height; Log = $log; PanelNeed = $need; Maximised = $max; Screen = $Screen }
}

function Register-ConsoleTab {
    # Creates a TabPage whose header is painted in the console colour (see the DrawItem handler).
    param($Tabs, [string]$Console, [string]$Text)
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = $Text; $page.Tag = $Console; $page.BackColor = 'White'
    $Tabs.TabPages.Add($page)
    return $page
}

# ---------------------------------------------------------------------
#  The window
# ---------------------------------------------------------------------
function Show-ToolkitGui {
    param([switch]$NoShow, [int]$AutoCloseSeconds = 0)   # -NoShow builds the form without displaying it; -AutoCloseSeconds shows it and closes it again (both to check the window without an operator)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $script:Gui = @{ Buttons = @(); Busy = $false; Tips = (New-Object System.Windows.Forms.ToolTip); RefreshByConsole = [ordered]@{}; Stale = @{}; GroupCombos = @(); OnFirstShow = @{}; RightPanels = @() }
    $font = New-Object System.Drawing.Font('Segoe UI', 9)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:Config.OperatorName)'s $($script:Config.ToolName) $($script:Config.ToolVersion) - offline, over WinRM"
    if ($script:SpokeMode) { $form.Text = "$($script:Config.OperatorName)'s $($script:Config.ToolName) $($script:Config.ToolVersion) - SPOKE on $(Get-ThisComputerFqdn): this computer only, no WinRM" }
    $form.Size = New-Object System.Drawing.Size(1360, 900)
    $form.MinimumSize = New-Object System.Drawing.Size(1100, 720)
    $form.StartPosition = 'CenterScreen'
    $form.Font = $font
    # the Fusetech frame: a 3 px line in the brand blue round the whole client area, drawn by the form itself, so every
    # Windows version shows it the same.  A control inherits its parent's BackColor unless one is set, so the split
    # container and the status bar below are given the usual grey by name.
    $form.BackColor = [System.Drawing.Color]::FromName($script:Config.BrandColour); $form.Padding = New-Object System.Windows.Forms.Padding(3)
    $form.Icon = Get-ToolkitIcon
    $script:Gui['Form'] = $form

    # ---- status bar (bottom) ----
    $strip = New-Object System.Windows.Forms.StatusStrip
    $strip.BackColor = [System.Drawing.SystemColors]::Control
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $statusLabel.Text = 'Ready.'; $statusLabel.Spring = $true; $statusLabel.TextAlign = 'MiddleLeft'
    $progress = New-Object System.Windows.Forms.ToolStripProgressBar
    $progress.Size = New-Object System.Drawing.Size(220, 16); $progress.ToolTipText = 'Patch-o-meter'
    # Stop: shown only while a read-only collector runs - the servers that have not answered are given up (nothing is
    # changed on them); an install is never stoppable from here (06-Install waits its own way and never stops a job)
    $stop = New-Object System.Windows.Forms.ToolStripButton
    $stop.Text = 'Stop waiting'; $stop.Visible = $false; $stop.ToolTipText = 'Give up on the servers that have not answered yet (read-only checks only; nothing is changed on them)'
    $stop.Add_Click({ $script:Gui['StopRequested'] = $true; $this.Enabled = $false; $this.Text = 'stopping...' })
    [void]$strip.Items.Add($statusLabel); [void]$strip.Items.Add($stop); [void]$strip.Items.Add($progress)
    $script:Gui['StatusLabel'] = $statusLabel; $script:Gui['Progress'] = $progress; $script:Gui['StopButton'] = $stop

    # ---- tabs on top, shared log underneath ----
    $outer = New-Object System.Windows.Forms.SplitContainer
    $outer.Dock = 'Fill'; $outer.Orientation = 'Horizontal'; $outer.BackColor = [System.Drawing.SystemColors]::Control
    $outer.FixedPanel = 'Panel2'   # the log keeps its height when the window is resized or maximised; the consoles grow
    $tabs = New-Object System.Windows.Forms.TabControl
    # eight tabs of 132 px fit the narrowest window (MinimumSize 1100) without scroll arrows
    $tabs.Dock = 'Fill'; $tabs.DrawMode = 'OwnerDrawFixed'; $tabs.ItemSize = New-Object System.Drawing.Size(132, 30); $tabs.SizeMode = 'Fixed'
    # The tab headers are bold, but a Font set on the TabControl is inherited by every page and every grid on
    # it - so the header font is kept separately and used only by the DrawItem handler below.
    $script:Gui['TabHeaderFont'] = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $tabs.Add_DrawItem({
        param($src, $e)   # ($sender is an automatic variable: not a name to take)
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
        $first = $script:Gui['OnFirstShow'][[string]$p.Tag]   # a console that builds its page only when first opened (About, Commands)
        # not while a read-only action already runs nested (the page's action would be refused and the entry lost): the next visit builds it
        if ($first -and -not $script:Gui['NestedBusy']) { $script:Gui['OnFirstShow'].Remove([string]$p.Tag); & $first }
    })
    $outer.Panel1.Controls.Add($tabs)
    $script:Gui['Tabs'] = $tabs

    $logBox = New-Object System.Windows.Forms.RichTextBox
    $logBox.Dock = 'Fill'; $logBox.ReadOnly = $true; $logBox.BackColor = 'White'; $logBox.WordWrap = $false
    $logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $outer.Panel2.Controls.Add($logBox)
    $script:Gui['LogBox'] = $logBox
    # the WARN / ERROR lines of the start-up (settings.json skipped a value, a safeguard switched off): shown first, so the
    # operator who never looks at the console window sees them
    foreach ($pre in @($script:PreGuiLines)) {
        if (-not $pre) { continue }
        $logBox.SelectionStart = $logBox.TextLength; $logBox.SelectionLength = 0
        $logBox.SelectionColor = [System.Drawing.Color]::FromName($(if ($pre[0] -eq 'ERROR') { 'Red' } else { 'DarkOrange' }))
        $logBox.AppendText([string]$pre[1] + "`r`n")
    }
    $script:PreGuiLines = @()

    # ---- the consoles, in tab order ----
    New-PatchingConsole -Tabs $tabs
    New-SoftwareConsole -Tabs $tabs
    New-HealthConsole -Tabs $tabs
    New-SecurityConsole -Tabs $tabs
    New-CommandsConsole -Tabs $tabs
    New-CodeTourTab -Tabs $tabs
    New-SettingsConsole -Tabs $tabs
    New-AboutConsole -Tabs $tabs
    Update-TrellixShown   # TrellixInUse off: the Trellix boxes and buttons go before the window is sized

    $form.Controls.Add($outer)
    $form.Controls.Add($strip)
    $outer.BringToFront()
    $form.Add_Shown({
        try { $outer.SplitterDistance = [Math]::Max(300, $outer.Height - [int]$script:Gui['LogHeight'] - $outer.SplitterWidth) } catch { }   # the log underneath (Get-ToolkitStartSize), draggable
        try { $script:Gui['TourSplit'].SplitterDistance = 450 } catch { }   # the longest topic title plus the menu's scroll bar
        Select-CodeTourTopic -Index 0
        # the saved results, now that the window is on screen: a small box in front says "Loading last data" meanwhile
        if ($script:Gui['LoadOnShow']) { $script:Gui['LoadOnShow'] = $false; try { Show-SavedResultsLoading } catch { Write-PatchLog ("Loading last data failed: {0}" -f (Get-ShortError $_)) 'ERROR' } }
    })
    # Closing the window while a copy or install is running would leave sessions and DISM to their fate.
    $form.Add_FormClosing({
        if ($script:Gui['Busy']) {
            $_.Cancel = $true
            Write-PatchLog "Close refused - still busy with '$($script:Gui['BusyName'])'. Wait for it to finish, then close. (During an install: untick Auto-check or press 'Let the servers go' - the servers carry on by themselves and a later status check records the results.)" 'WARN'
            Set-GuiStatus "Close refused - '$($script:Gui['BusyName'])' is still running"   # no pop-up: a modal dialog would pause the install's progress loop
            return
        }
        # a timed close (-AutoCloseSeconds) must not stop at this question
        if ($script:Gui['SettingsDirty'] -and -not $script:Gui['AutoCloseTimer']) {
            $a = Show-PatcherMessage -Title 'Unsaved settings' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text "The Settings tab has changes that are not saved.`n`nClose anyway and lose them?"
            if ($a -ne 'Yes') { $_.Cancel = $true; $script:Gui['Tabs'].SelectedTab = @($script:Gui['Tabs'].TabPages | Where-Object { $_.Tag -eq 'Settings' })[0]; return }
            else { Write-PatchLog 'Closed with unsaved changes on the Settings tab - they were not saved' 'WARN' }
        }
        # the results the timer has not written yet go to state\servers\ now (14-State.ps1)
        try { $t = $script:Gui['StateTimer']; if ($t) { $t.Stop() }; $n = Save-DirtyStates -All; if ($n -gt 0) { Write-PatchLog ("Saved results written for {0} server(s) at close" -f $n) 'INFO' } } catch { Write-PatchLog ("Saved results not written at close: {0}" -f (Get-ShortError $_)) 'WARN' }
    })
    # the results of every check reach state\servers\ a few files at a time, between the operator's clicks (Save-DirtyStates).
    # Not with -NoShow: nothing pumps messages for a timer there, so Invoke-Collector writes the files itself (review 2026-11-08)
    if ($NoShow) { if ($script:Gui.ContainsKey('StateTimer')) { $script:Gui.Remove('StateTimer') } } else {
        $stateTimer = New-Object System.Windows.Forms.Timer
        $stateTimer.Interval = 700
        $stateTimer.Add_Tick({ try { $null = Save-DirtyStates -MaxMs 250 } catch { } })
        $stateTimer.Start()
        $script:Gui['StateTimer'] = $stateTimer
    }

    # ---- load the data and go ----
    Write-PatchLog ("Welcome, {0}! {1} {2}, root folder = {3}   (running as {4})" -f $script:Config.OperatorName, $script:Config.ToolName, $script:Config.ToolVersion, $script:RootFolder, (Get-OperatorIdentity)) 'INFO'
    # a big fleet's saved results take seconds to read: the window opens first and reads them behind the "Loading last
    # data" box (the Shown handler above); with -NoShow there is no Shown, so Initialize-ToolkitData reads them here
    $loadOnShow = (-not $NoShow) -and [bool]$script:Config.KeepResults
    $script:Gui['LoadOnShow'] = $loadOnShow
    Initialize-ToolkitData -WithoutSavedResults:$loadOnShow
    # the first size: every button of the right-hand panels in view (measured after the data is in: the NEW box moves them)
    $size = Get-ToolkitStartSize -Form $form -Outer $outer -Strip $strip -Tabs $tabs
    $form.Size = New-Object System.Drawing.Size($size.Width, $size.Height)
    if ($size.Maximised) { $form.WindowState = 'Maximized' }
    $script:Gui['LogHeight'] = $size.Log
    $script:Gui['StartSize'] = $size
    try { $form.PerformLayout(); $outer.SplitterDistance = [Math]::Max(300, $outer.Height - $size.Log - $outer.SplitterWidth) } catch { }   # before the first paint, so nothing jumps
    if ($NoShow) { return $form }
    if ($AutoCloseSeconds -gt 0) {
        # -AutoCloseSeconds: show the window for real so every Shown / paint / selection handler runs, then close it
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $AutoCloseSeconds * 1000
        $timer.Add_Tick({ $this.Stop(); $script:Gui['Form'].Close() })
        $timer.Start()
        $script:Gui['AutoCloseTimer'] = $timer
    }
    Write-PatchLog 'GUI is open. This console window keeps a colour copy of everything.' 'INFO'
    try {
        [void]$form.ShowDialog()
    } finally {
        try { $stateTimer.Stop(); $stateTimer.Dispose(); $script:Gui.Remove('StateTimer'); $null = Save-DirtyStates -All } catch { }
        $form.Dispose()
        # When the launcher was dot-sourced ($NoGui), $script: is the console's own scope - do not leave a password behind.
        if ($script:Credential) { Clear-PatcherCredential }
        Write-PatchLog 'GUI closed. Bye!' 'INFO'
    }
}

function Initialize-ToolkitData {
    # Reads the group files and the patch folders, fills every group combo, then lets each console repaint.  The saved
    # results (14-State.ps1) come in too - every file at the first load, at a Reload the files written since, which is
    # how a self-check or a spoke that writes into this folder arrives - unless -WithoutSavedResults: the first open of
    # the window reads them once it is on screen, behind the "Loading last data" box (Show-SavedResultsLoading).
    param([switch]$WithoutSavedResults)
    Get-PatchGroups | Out-Null
    Get-PatchFiles  | Out-Null
    Get-SoftwarePackageFiles | Out-Null
    Clear-CheckRowCache   # class: and soe: on the group lines feed the checks
    if (-not $WithoutSavedResults) { $null = Import-SavedResults }
    foreach ($combo in @($script:Gui['GroupCombos'])) {
        $keep = [string]$combo.SelectedItem
        $combo.Items.Clear()
        [void]$combo.Items.Add('(all groups)')
        foreach ($g in $script:Groups) { [void]$combo.Items.Add($g.Name) }
        if ($keep -and $combo.Items.Contains($keep)) { $combo.SelectedItem = $keep } else { $combo.SelectedIndex = 0 }
    }
    Invoke-ConsoleRefresh
}

function Show-SavedResultsLoading {
    # The first open: the window is on screen with its lists and no results yet; this box in front of it says "Loading
    # last data" and counts the files off while Import-SavedResults reads state\servers\.  The box's own Shown handler
    # does the reading, a DoEvents per file keeps both windows painting, and the window behind takes no click until the
    # box closes - then the console on screen repaints with what came in.  No file yet: no box, the log line says so.
    $folder = Get-StateFolder
    $total = 0
    if (Test-Path -LiteralPath $folder) { $total = @(Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File -ErrorAction SilentlyContinue).Count }
    if ($total -eq 0) { $null = Import-SavedResults; return }
    Write-PatchLog ("Loading last data: {0} saved results file(s) in {1}" -f $total, $folder) 'INFO'
    Set-GuiStatus 'Loading last data ...'
    $box = New-ToolkitDialogForm
    $box.Text = 'Loading last data'; $box.FormBorderStyle = 'FixedDialog'; $box.ControlBox = $false
    $box.MaximizeBox = $false; $box.MinimizeBox = $false; $box.ShowInTaskbar = $false; $box.StartPosition = 'CenterParent'
    $box.ClientSize = New-Object System.Drawing.Size(480, 112); $box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $head = New-Object System.Windows.Forms.Label
    $head.Text = 'Loading last data - the saved results of the last checks'; $head.AutoSize = $false
    $head.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $head.Location = New-Object System.Drawing.Point(16, 14); $head.Size = New-Object System.Drawing.Size(448, 22)
    $line = New-Object System.Windows.Forms.Label
    $line.Text = ('{0} file(s) in {1}' -f $total, $folder); $line.AutoSize = $false; $line.AutoEllipsis = $true
    $line.Location = New-Object System.Drawing.Point(16, 40); $line.Size = New-Object System.Drawing.Size(448, 22)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = 'Continuous'; $bar.Minimum = 0; $bar.Maximum = $total; $bar.Value = 0
    $bar.Location = New-Object System.Drawing.Point(16, 72); $bar.Size = New-Object System.Drawing.Size(448, 20)
    $box.Controls.AddRange([System.Windows.Forms.Control[]]@($head, $line, $bar))
    $script:Gui['LoadBox'] = @{ Line = $line; Bar = $bar }
    $box.Add_Shown({
        # the reading, once the box is painted; whatever happens the box closes and the window takes over
        try {
            $null = Import-SavedResults -Progress {
                param($FileNo, $FileCount, $FileName)
                $lb = $script:Gui['LoadBox']
                if ($lb) {
                    $lb.Line.Text = ('Reading file {0} of {1}: {2}' -f $FileNo, $FileCount, $FileName)
                    $lb.Bar.Value = [Math]::Min([int]$FileNo, [int]$lb.Bar.Maximum)
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
        } catch { Write-PatchLog ("Loading last data failed: {0}" -f (Get-ShortError $_)) 'ERROR' }
        $this.Close()
    })
    try { [void]$box.ShowDialog($script:Gui['Form']) } finally { $script:Gui.Remove('LoadBox'); $box.Dispose() }
    try { Invoke-ConsoleRefresh } catch { Write-PatchLog ("The repaint after loading last data failed: {0}" -f (Get-ShortError $_)) 'WARN' }
    Set-GuiStatus 'Ready.'
}

# ---------------------------------------------------------------------
#  Code Tour tab: the topics by part on the left, each topic as an HTML page on the right.
# ---------------------------------------------------------------------
function New-CodeTourTab {
    # The menu on the left is a tree: one bold node per part (A-F), one node per topic with its whole title.
    # The right side shows the topic as an HTML page (Get-CodeTourHtml): the explanation, the picture, the live source.
    param($Tabs)
    $tabTour = Register-ConsoleTab -Tabs $Tabs -Console 'Tour' -Text 'Code Tour'
    $tourSplit = New-Object System.Windows.Forms.SplitContainer
    $tourSplit.Dock = 'Fill'; $tourSplit.Orientation = 'Vertical'; $tourSplit.FixedPanel = 'Panel1'
    $tabTour.Controls.Add($tourSplit)
    # A TreeView clips a node drawn in a wider font than its own, so the TREE font is the bold one (part headings)
    # and the topics get the regular font, which is narrower.
    $bold = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $regular = New-Object System.Drawing.Font('Segoe UI', 10)
    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'; $tree.Font = $bold; $tree.HideSelection = $false; $tree.FullRowSelect = $true; $tree.ShowLines = $false
    $tree.ItemHeight = 26; $tree.Indent = 16; $tree.BackColor = 'White'
    $nodes = New-Object 'System.Windows.Forms.TreeNode[]' (@($script:CodeTour).Count)
    foreach ($key in $script:CodeTourParts.Keys) {
        $partNode = $tree.Nodes.Add(('Part {0} - {1}' -f $key, $script:CodeTourParts[$key]))
        for ($i = 0; $i -lt @($script:CodeTour).Count; $i++) {
            if ((Get-CodeTourPart -Entry $script:CodeTour[$i]) -ne $key) { continue }
            $n = $partNode.Nodes.Add([string]$script:CodeTour[$i].Title); $n.Tag = $i; $n.NodeFont = $regular; $nodes[$i] = $n
        }
    }
    $tree.ExpandAll()
    # Handlers run long after this function has returned, so they read $this, $_ or $script:Gui - never a local here.
    $tree.Add_AfterSelect({
        $n = $_.Node
        if ($null -eq $n.Tag) { if ($n.Nodes.Count -gt 0) { $this.SelectedNode = $n.Nodes[0] }; return }   # a part heading opens its first topic
        Show-CodeTourEntry -Index ([int]$n.Tag)
    })
    $tourSplit.Panel1.Controls.Add($tree)

    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock = 'Top'; $bar.Height = 40; $bar.BackColor = 'WhiteSmoke'
    $bar.Controls.Add((New-GuiButton -Text '< Previous' -X 8 -Y 6 -W 95 -H 28 -ReadOnly -OnClick { Select-CodeTourTopic -Index ([int]$script:Gui['TourIndex'] - 1) }))
    $bar.Controls.Add((New-GuiButton -Text 'Next >' -X 108 -Y 6 -W 95 -H 28 -ReadOnly -OnClick { Select-CodeTourTopic -Index ([int]$script:Gui['TourIndex'] + 1) }))
    $picButton = New-GuiButton -Text 'Open picture' -X 218 -Y 6 -W 110 -H 28 -ReadOnly -Tip 'The picture full size in the Windows photo viewer' -OnClick {
        Invoke-GuiAction -Name 'Open picture' -ReadOnly -Action {
            $e = $script:CodeTour[[int]$script:Gui['TourIndex']]
            if ($e -and $e.Image) { $p = Join-Path $script:RootFolder $e.Image; if (Test-Path -LiteralPath $p) { Start-Process $p } }
        } }
    $bar.Controls.Add($picButton)
    $bar.Controls.Add((New-GuiButton -Text 'Save page as HTML...' -X 333 -Y 6 -W 150 -H 28 -ReadOnly -Tip 'This topic as one HTML file (picture included) - to read in a browser or print' -OnClick {
        Invoke-GuiAction -Name 'Save tour page' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The save dialog')) { return }
            $title = [string]$script:CodeTour[[int]$script:Gui['TourIndex']].Title
            $p = Save-HtmlAs -Html $script:Gui['TourHtml'] -BaseName ('CodeTour-' + ($title -split '\.')[0]) -Owner $script:Gui['Form'] -What 'topic'
            if ($p) { $script:Gui['TourPosition'].Text = 'Saved: ' + $p }
        } }))
    $bar.Controls.Add((New-GuiButton -Text 'Save whole tour as HTML...' -X 488 -Y 6 -W 185 -H 28 -ReadOnly -Tip 'Every topic in one HTML file with a contents list - for training or printing' -OnClick {
        Invoke-GuiAction -Name 'Save whole tour' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The save dialog')) { return }
            $p = Save-HtmlAs -Html (Export-CodeTourHtml) -BaseName 'CodeTour-all' -Owner $script:Gui['Form'] -What 'tour'
            if ($p) { $script:Gui['TourPosition'].Text = 'Saved: ' + $p }
        } }))
    $pos = New-Object System.Windows.Forms.Label; $pos.Location = New-Object System.Drawing.Point(685, 12); $pos.AutoSize = $true; $pos.ForeColor = 'DimGray'
    $bar.Controls.Add($pos)

    $view = New-Object System.Windows.Forms.WebBrowser
    $view.Dock = 'Fill'; $view.ScriptErrorsSuppressed = $true; $view.AllowWebBrowserDrop = $false; $view.IsWebBrowserContextMenuEnabled = $true
    # each topic is set as DocumentText (about:blank); anything else - a link, a typed address - is refused: the tool never goes online
    $view.Add_Navigating({ if ($_.Url -and $_.Url.Scheme -ne 'about') { $_.Cancel = $true } })
    $tourSplit.Panel2.Controls.Add($view); $tourSplit.Panel2.Controls.Add($bar); $view.BringToFront()

    $script:Gui['TourTree'] = $tree; $script:Gui['TourNodes'] = $nodes; $script:Gui['TourView'] = $view; $script:Gui['TourSplit'] = $tourSplit
    $script:Gui['TourPosition'] = $pos; $script:Gui['TourPicButton'] = $picButton; $script:Gui['TourIndex'] = 0; $script:Gui['TourHtml'] = ''
}

function Select-CodeTourTopic {
    # Previous / Next and the first page: move the tree's selection, which shows the page.  Before the window has a
    # handle the tree raises no events, so the page is drawn directly (-NoShow).
    param([int]$Index)
    $nodes = $script:Gui['TourNodes']
    if (-not $nodes -or $Index -lt 0 -or $Index -ge $nodes.Count) { return }
    $tree = $script:Gui['TourTree']
    $tree.SelectedNode = $nodes[$Index]
    $nodes[$Index].EnsureVisible()
    if (-not $tree.IsHandleCreated) { Show-CodeTourEntry -Index $Index }
}

function Show-CodeTourEntry {
    # Draws one topic as a page in the Code Tour tab.
    param([int]$Index)
    $entry = $script:CodeTour[$Index]
    if (-not $entry) { return }
    $script:Gui['TourIndex'] = $Index
    try { $html = Get-CodeTourHtml -Entry $entry -Index $Index }
    catch { $html = New-DetailsHtml -Title ([string]$entry.Title) -Console 'Tour' -Subtitle ('this topic could not be drawn: ' + (Get-ShortError $_)) }
    $script:Gui['TourHtml'] = $html
    $script:Gui['TourView'].DocumentText = $html
    $script:Gui['TourPosition'].Text = ('topic {0} of {1}' -f ($Index + 1), @($script:CodeTour).Count)
    $script:Gui['TourPicButton'].Enabled = [bool]$entry.Image
}
