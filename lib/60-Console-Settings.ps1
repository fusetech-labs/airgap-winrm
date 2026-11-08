# =====================================================================
#  60-Console-Settings.ps1  -  THE SETTINGS CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  One page, eight boxes, saved together with "Save settings":
#    1. Before any change: the pre-action confirmations - which products
#       are in use here (VMware, Trellix Solidcore, Airlock, any other step), so
#       which Yes/No pop-ups come before every install and removal.
#    2. Change records: the change management system, the fields that must
#       be filled in, and per action: change record required / or a
#       maintenance activity / not recorded.
#    3. The running log: command and reasoning lines, size, log retention.
#    4. Warnings and safety limits.
#    5. The Software console: its timeout, and how many packages it shows
#       at once (a big library).
#    6. The Commands console: how long a command may run, how much of each
#       answer is kept, and whether a command that may change a server also
#       asks the pre-action confirmations.
#    7. Health warning thresholds (Group Policy refresh included).
#    8. The Security console: how far back the GPO impact checks look.
#  lib\12-Settings.ps1 checks and saves the values (settings\settings.json)
#  and logs every change with who made it.  Save shows the changes first
#  and says which of them weaken a safeguard.  Nothing here talks to a
#  server.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  60-Console-Settings.ps1
#  New 2026-10-21.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _________cf_____________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] Save   [x] Undo   [x] Restore defaults   [x] closing with unsaved changes
#  Comments   :
#    -
# =====================================================================

function Set-SettingsDirty {
    # Any edit on the page: "unsaved changes" shows until Save or Undo (not while the page is being filled).
    if ($script:Gui['SettingsFilling']) { return }
    $script:Gui['SettingsDirty'] = $true
    $script:Gui['SettingsDirtyLabel'].Visible = $true
}

function Update-SettingsStatus {
    # The line beside the buttons: where the settings come from.
    $info = $script:SettingsInfo
    $text = 'No settings saved yet - the defaults of lib\01-Config.ps1 apply.'
    if ($info -and $info.Exists) {
        $text = ('{0} - saved {1} by {2}; {3} value(s) differ from the defaults.' -f $info.Path, $info.Saved, $info.SavedBy, @($info.Applied).Count)
        if (@($info.Problems).Count -gt 0) { $text += (' {0} value(s) in the file were skipped - see the log.' -f @($info.Problems).Count) }
    }
    $script:Gui['SettingsStatus'].Text = $text
}

function Set-SettingsForm {
    # Fills every control from $Values (key -> value): the live settings, or the defaults for "Restore defaults".
    param([hashtable]$Values)
    $script:Gui['SettingsFilling'] = $true
    try {
        $grid = $script:Gui['SettingsChecksGrid']
        $grid.Rows.Clear()
        foreach ($c in @($Values['SafetyChecks'])) { if ($c) { [void]$grid.Rows.Add([object[]]@([bool]$c.Enabled, [string]$c.Name, [string]$c.Question, [string]$c.IfNo)) } }
        $combo = $script:Gui['SettingsSystemCombo']
        $combo.Items.Clear()
        foreach ($v in @($Values['ChangeSystems'])) { if ($v) { [void]$combo.Items.Add([string]$v) } }
        $combo.Text = [string]$Values['ChangeSystem']
        $script:Gui['SettingsSystemsBox'].Text = (@($Values['ChangeSystems']) -join '; ')
        foreach ($f in @($script:Gui['SettingsFieldBoxes'].Keys)) { $script:Gui['SettingsFieldBoxes'][$f].Checked = (@($Values['ChangeRequiredFields']) -contains $f) }
        $pg = $script:Gui['SettingsPolicyGrid']
        foreach ($row in $pg.Rows) {
            $p = [string]$Values['ChangePolicy'][[string]$row.Cells[0].Value]
            if (-not $script:ChangePolicyNames.Contains($p)) { $p = 'Required' }
            $row.Cells[1].Value = $script:ChangePolicyNames[$p]
        }
        foreach ($key in @($script:Gui['SettingControls'].Keys)) {
            $ctl = $script:Gui['SettingControls'][$key]; $v = $Values[$key]
            if ($ctl -is [System.Windows.Forms.CheckBox]) { $ctl.Checked = [bool]$v }
            elseif ($ctl -is [System.Windows.Forms.NumericUpDown]) { $ctl.Value = [decimal]([math]::Max([double]$ctl.Minimum, [math]::Min([double]$ctl.Maximum, [double]$v))) }
            elseif ([string]$ctl.Tag -eq 'list') { $ctl.Text = (@($v) -join '; ') }   # a list setting: items between semicolons
            else { $ctl.Text = [string]$v }
        }
    } finally { $script:Gui['SettingsFilling'] = $false }
    $script:Gui['SettingsDirty'] = $false
    $script:Gui['SettingsDirtyLabel'].Visible = $false
    Update-SettingsStatus
    Update-TrellixSettingRows
}

function Update-TrellixSettingRows {
    # "Trellix is used here" unticked on the page: what then does nothing is greyed - the agent-stop setting and the Trellix
    # pre-action confirmation.  They keep their values and count again once it is ticked.
    $on = $true; $box = $script:Gui['SettingControls']['TrellixInUse']; if ($box) { $on = [bool]$box.Checked }
    $stop = $script:Gui['SettingControls']['StopTrellixAgentForInstall']; if ($stop) { $stop.Enabled = $on }
    $grid = $script:Gui['SettingsChecksGrid']
    if (-not $grid) { return }
    foreach ($row in $grid.Rows) {
        if ($row.IsNewRow -or [string]$row.Cells[1].Value -notmatch '(?i)trellix') { continue }
        $row.DefaultCellStyle.ForeColor = $(if ($on) { [System.Drawing.SystemColors]::ControlText } else { [System.Drawing.Color]::Gray })
        $row.Cells[0].ToolTipText = $(if ($on) { '' } else { 'Not asked: Trellix is not in use here (Warnings and safety limits below)' })
    }
}

function Get-SettingsLive {
    # The live settings (key -> value), as Set-SettingsForm takes them.
    $v = @{}
    foreach ($s in $script:SettingSpecs) { $v[$s.Key] = $script:Config[$s.Key] }
    return $v
}

function Get-SettingsFormValues {
    # What the page shows now, key -> value, unchecked: Get-SettingsPreview / Save-ToolkitSettings check it.
    $grid = $script:Gui['SettingsChecksGrid']; [void]$grid.EndEdit()
    $pg = $script:Gui['SettingsPolicyGrid']; [void]$pg.EndEdit()
    $v = @{}
    $v['SafetyChecks'] = @(foreach ($row in $grid.Rows) {
        [pscustomobject]@{ Enabled = [bool]$row.Cells[0].Value; Name = [string]$row.Cells[1].Value; Question = [string]$row.Cells[2].Value; IfNo = [string]$row.Cells[3].Value }
    })
    $v['ChangeSystem'] = [string]$script:Gui['SettingsSystemCombo'].Text
    $v['ChangeSystems'] = @(([string]$script:Gui['SettingsSystemsBox'].Text) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $v['ChangeRequiredFields'] = @(@($script:Gui['SettingsFieldBoxes'].Keys) | Where-Object { $script:Gui['SettingsFieldBoxes'][$_].Checked })
    $policy = [ordered]@{}
    foreach ($row in $pg.Rows) {
        $shown = [string]$row.Cells[1].Value
        $key = @($script:ChangePolicyNames.Keys | Where-Object { $script:ChangePolicyNames[$_] -eq $shown })[0]
        if ($key) { $policy[[string]$row.Cells[0].Value] = $key }
    }
    $v['ChangePolicy'] = $policy
    foreach ($key in @($script:Gui['SettingControls'].Keys)) {
        $ctl = $script:Gui['SettingControls'][$key]
        if ($ctl -is [System.Windows.Forms.CheckBox]) { $v[$key] = $ctl.Checked }
        elseif ($ctl -is [System.Windows.Forms.NumericUpDown]) { $v[$key] = [int]$ctl.Value }
        elseif ([string]$ctl.Tag -eq 'list') { $v[$key] = @(([string]$ctl.Text) -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        else { $v[$key] = [string]$ctl.Text }
    }
    return $v
}

function Invoke-SettingsSave {
    # Save settings: check every value, show what changes (and what weakens a safeguard - then No is the default),
    # save, refill the page from what was saved, and let the consoles re-judge with the new thresholds.
    $values = Get-SettingsFormValues
    try { $preview = Get-SettingsPreview -Values $values }
    catch { $null = Show-PatcherMessage -Text ("Nothing was saved:`n`n{0}" -f $_.Exception.Message) -Title 'Settings not saved' -Icon 'Warning'; return }
    if (@($preview.Changes).Count -eq 0) {
        Write-PatchLog 'Settings: nothing to save - the page shows the settings in use' 'INFO'
        Set-SettingsForm -Values (Get-SettingsLive)
        return
    }
    $text = "Save these changes?`n`n" + ((@($preview.Changes) | ForEach-Object { '- ' + $_ }) -join "`n")
    $weaker = @($preview.Weaker)
    if ($weaker.Count -gt 0) { $text += "`n`nTHESE WEAKEN A SAFEGUARD:`n" + (($weaker | ForEach-Object { '! ' + $_ }) -join "`n") }
    $notes = @($preview.Notes)
    if ($notes.Count -gt 0) { $text += "`n`nWORTH KNOWING (saved as you set them):`n" + (($notes | ForEach-Object { '- ' + $_ }) -join "`n") }
    $answer = Show-PatcherMessage -Title 'Save settings' -Buttons 'YesNo' -Icon $(if ($weaker.Count -gt 0) { 'Warning' } else { 'Question' }) -Default $(if ($weaker.Count -gt 0) { 'Button2' } else { 'Button1' }) -Text $text
    if ($answer -ne 'Yes') { Write-PatchLog 'Settings not saved (answered No) - the page still shows the unsaved changes' 'INFO'; return }
    # the windows and rules the servers are asked WITH: a change applies at the next check, and the operator is told so
    $collectKeys = @('TaskFailDays', 'CertExpiryDays', 'EventWindowHours', 'LogonFailWindowHours', 'MaxEvents', 'CpuSampleSeconds', 'TreatPendingFileRenameAsReboot', 'ImpactDays')
    $before = @{}; foreach ($k in $collectKeys) { $before[$k] = [string]$script:Config[$k] }
    $null = Save-ToolkitSettings -Values $values
    Set-SettingsForm -Values (Get-SettingsLive)
    # thresholds feed the cached Health / Security verdicts: every console re-judges when it is next shown
    Clear-CheckRowCache
    foreach ($k in @($script:Gui['RefreshByConsole'].Keys)) { $script:Gui['Stale'][$k] = $true }
    Update-TrellixShown   # TrellixInUse: the Trellix boxes and buttons come or go at once
    $atCollect = @($collectKeys | Where-Object { [string]$script:Config[$_] -ne $before[$_] })
    if ($atCollect.Count -gt 0) { Write-PatchLog ('Settings: {0} - handed to the servers at collection time, so the change applies at the next check; until then the rows show what the last check used' -f ($atCollect -join ', ')) 'WARN' }
    Remove-OldPatchLogs   # LogKeepDays: applied now, not only at the next start
}

function Restore-SettingsDefaults {
    # Restore defaults: the page shows the defaults of lib\01-Config.ps1; nothing is saved until Save settings.
    $a = Show-PatcherMessage -Title 'Restore defaults' -Buttons 'YesNo' -Icon 'Question' -Default 'Button2' -Text "Fill the page with the defaults of lib\01-Config.ps1?`n`nNothing is saved until you press Save settings; Undo unsaved changes goes back to the settings in use."
    if ($a -ne 'Yes') { return }
    Set-SettingsForm -Values (Get-SettingsDefaults)
    Set-SettingsDirty
}

function Add-SettingsCheckStep {
    $grid = $script:Gui['SettingsChecksGrid']
    $i = $grid.Rows.Add([object[]]@($true, 'New step', 'Has <what> been done for every server below?', 'Do <what> first, then come back.'))
    $grid.CurrentCell = $grid.Rows[$i].Cells[1]
    [void]$grid.BeginEdit($true)
    Set-SettingsDirty
}

function Remove-SettingsCheckStep {
    $grid = $script:Gui['SettingsChecksGrid']
    if (-not $grid.CurrentCell) { return }
    $grid.Rows.RemoveAt($grid.CurrentCell.RowIndex)
    Set-SettingsDirty
}

function Move-SettingsCheckStep {
    # Up (-1) or down (+1): the confirmations are asked in the order of the list.
    param([int]$By)
    $grid = $script:Gui['SettingsChecksGrid']
    if (-not $grid.CurrentCell) { return }
    [void]$grid.EndEdit()
    $from = $grid.CurrentCell.RowIndex; $col = $grid.CurrentCell.ColumnIndex; $to = $from + $By
    if ($to -lt 0 -or $to -ge $grid.Rows.Count) { return }
    $row = $grid.Rows[$from]
    $grid.Rows.RemoveAt($from)
    $grid.Rows.Insert($to, $row)
    $grid.CurrentCell = $grid.Rows[$to].Cells[$col]
    Set-SettingsDirty
}

function New-SettingsBox {
    # One titled box on the page; returns it.  $Body = the scrolling page.
    param($Body, [string]$Title, [int]$Y, [int]$Height)
    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text = $Title; $box.Location = New-Object System.Drawing.Point(10, $Y); $box.Size = New-Object System.Drawing.Size(1040, $Height)
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $Body.Controls.Add($box)
    return $box
}

function New-SettingsNote {
    # A grey explanation line inside a box (regular font: the box's title font is bold).
    param($Box, [string]$Text, [int]$Y, [int]$Height = 20)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text; $l.Location = New-Object System.Drawing.Point(12, $Y); $l.Size = New-Object System.Drawing.Size(1015, $Height); $l.ForeColor = 'DimGray'
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $Box.Controls.Add($l)
    return $l
}

function Add-SettingRows {
    # Simple settings as rows in a box, two to a line: a tick box for yes/no, otherwise its label and a number or text
    # box.  Each control is kept in $script:Gui['SettingControls'] by its key.  Returns the y below the last row.
    param($Box, [object[]]$Specs, [int]$Top = 26)
    $regular = New-Object System.Drawing.Font('Segoe UI', 9)
    $colW = 510
    $i = 0
    foreach ($s in $Specs) {
        # the row carries a short label; the longer explanation (a spec's Tip) goes in the tool tip, so nothing wraps or is cut
        $tipText = ('{0}  ({1} in lib\01-Config.ps1)' -f $s.Label, $s.Key)
        if ($s.Tip) { $tipText = ('{0}  ({1} in lib\01-Config.ps1)' -f $s.Tip, $s.Key) }
        if ($s.Type -eq 'list' -and ($i % 2) -eq 1) { $i++ }   # a list setting takes a row of its own: a wide box for its items
        $x = 10 + ($i % 2) * $colW; $y = $Top + [math]::Floor($i / 2) * 30
        if ($s.Type -eq 'bool') {
            $c = New-Object System.Windows.Forms.CheckBox
            $c.Text = $s.Label; $c.Size = New-Object System.Drawing.Size(($colW - 15), 24); $c.Location = New-Object System.Drawing.Point($x, $y)
            $c.Add_CheckedChanged({ Set-SettingsDirty })
        } else {
            $l = New-Object System.Windows.Forms.Label
            $l.Text = $s.Label; $l.Size = New-Object System.Drawing.Size(($colW - 140), 20); $l.Location = New-Object System.Drawing.Point($x, ($y + 4)); $l.AutoEllipsis = $true; $l.Font = $regular
            $script:Gui['Tips'].SetToolTip($l, $tipText)
            $Box.Controls.Add($l)
            if ($s.Type -eq 'int') {
                $c = New-Object System.Windows.Forms.NumericUpDown
                $c.Maximum = $s.Max; $c.Minimum = $s.Min; $c.ThousandsSeparator = ($s.Max -ge 100000); $c.TextAlign = 'Right'
                $c.Add_ValueChanged({ Set-SettingsDirty })
            } else {
                $c = New-Object System.Windows.Forms.TextBox
                $c.MaxLength = $s.MaxLen
                $c.Add_TextChanged({ Set-SettingsDirty })
            }
            $c.Location = New-Object System.Drawing.Point(($x + $colW - 135), $y); $c.Width = 115
            if ($s.Type -eq 'list') { $c.Tag = 'list'; $c.MaxLength = 0; $l.Size = New-Object System.Drawing.Size(330, 20); $c.Location = New-Object System.Drawing.Point(($x + 340), $y); $c.Width = ($colW * 2) - 355 }   # MaxLen is per item (the validator); the box holds them all
        }
        $c.Font = $regular
        $script:Gui['Tips'].SetToolTip($c, $tipText)
        $Box.Controls.Add($c)
        $script:Gui['SettingControls'][$s.Key] = $c
        if ($s.Type -eq 'list') { $i++ }   # the whole row
        $i++
    }
    return ($Top + [math]::Ceiling($i / 2) * 30)
}

function Get-SettingRowSlots {
    # How many half-rows a set of specs takes in Add-SettingRows (a list setting takes a full row of its own)
    param([object[]]$Specs)
    $i = 0
    foreach ($s in @($Specs)) { if ($s.Type -eq 'list') { if (($i % 2) -eq 1) { $i++ }; $i += 2 } else { $i++ } }
    return $i
}

function New-SettingsGrid {
    # An editable table for the confirmations and the recording rules (Ask / Recording are committed as they are
    # clicked, so the page knows at once that something changed).
    param($Box, [int]$Y, [int]$Height)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = New-Object System.Drawing.Point(12, $Y); $g.Size = New-Object System.Drawing.Size(1015, $Height)
    $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false; $g.RowHeadersVisible = $false
    $g.SelectionMode = 'CellSelect'; $g.MultiSelect = $false; $g.BackgroundColor = 'White'; $g.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $g.ColumnHeadersHeightSizeMode = 'DisableResizing'; $g.ColumnHeadersHeight = 26
    $g.Add_CurrentCellDirtyStateChanged({
        if ($this.IsCurrentCellDirty -and ($this.CurrentCell -is [System.Windows.Forms.DataGridViewCheckBoxCell] -or $this.CurrentCell -is [System.Windows.Forms.DataGridViewComboBoxCell])) { [void]$this.CommitEdit('CurrentCellChange') }
    })
    $g.Add_CellValueChanged({ Set-SettingsDirty })
    $g.Add_DataError({ $_.ThrowException = $false })
    $Box.Controls.Add($g)
    return $g
}

function New-SettingsConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Settings' -Text 'Settings'
    $script:Gui['SettingControls'] = [ordered]@{}
    $script:Gui['SettingsDirty'] = $false

    # Fill control first, then the docked edges (WinForms docks the last-added control first).
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.AutoScroll = $true; $body.BackColor = 'White'
    $tab.Controls.Add($body)

    # ---- 1. the pre-action confirmations ----
    $b1 = New-SettingsBox -Body $body -Title 'Before any change: the pre-action confirmations' -Y 10 -Height 262
    $null = New-SettingsNote -Box $b1 -Y 24 -Height 34 -Text 'Yes/No pop-ups naming the servers, asked before every OS patch install, software install / update and removal (and a command that may change a server, if set below) - No stops the change. Tick Ask for each product used here; Add step for any other product or task (a backup job, a monitoring window ...).'
    $grid = New-SettingsGrid -Box $b1 -Y 62 -Height 150
    $colAsk = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn; $colAsk.HeaderText = 'Ask'; $colAsk.Width = 45
    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colName.HeaderText = 'Step (product)'; $colName.Width = 180; $colName.MaxInputLength = 60
    $colQ = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colQ.HeaderText = 'Question - Yes goes on, No stops the change'; $colQ.AutoSizeMode = 'Fill'; $colQ.MaxInputLength = 400
    $colNo = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colNo.HeaderText = 'After a No, the pop-up says'; $colNo.Width = 290; $colNo.MaxInputLength = 300
    $grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colAsk, $colName, $colQ, $colNo))
    $script:Gui['SettingsChecksGrid'] = $grid
    $b1.Controls.Add((New-GuiButton -Text 'Add step' -X 12 -Y 220 -W 110 -H 30 -ReadOnly -Tip 'A new confirmation at the end of the list: name it, write the question' -OnClick { Add-SettingsCheckStep }))
    $b1.Controls.Add((New-GuiButton -Text 'Remove step' -X 127 -Y 220 -W 110 -H 30 -ReadOnly -Tip 'Removes the selected step (Undo unsaved changes brings it back)' -OnClick { Remove-SettingsCheckStep }))
    $b1.Controls.Add((New-GuiButton -Text 'Move up' -X 242 -Y 220 -W 90 -H 30 -ReadOnly -Tip 'Asked earlier' -OnClick { Move-SettingsCheckStep -By -1 }))
    $b1.Controls.Add((New-GuiButton -Text 'Move down' -X 337 -Y 220 -W 90 -H 30 -ReadOnly -Tip 'Asked later' -OnClick { Move-SettingsCheckStep -By 1 }))
    foreach ($ctl in $b1.Controls) { if ($ctl -is [System.Windows.Forms.Button]) { $ctl.Font = New-Object System.Drawing.Font('Segoe UI', 9) } }

    # ---- 2. change records ----
    $b2 = New-SettingsBox -Body $body -Title 'Change records: what is recorded for each action' -Y 282 -Height 316
    $regular = New-Object System.Drawing.Font('Segoe UI', 9)
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Change management system:'; $l.Location = New-Object System.Drawing.Point(12, 31); $l.AutoSize = $true; $l.Font = $regular; $b2.Controls.Add($l)
    $combo = New-Object System.Windows.Forms.ComboBox; $combo.DropDownStyle = 'DropDown'; $combo.Location = New-Object System.Drawing.Point(200, 28); $combo.Width = 200; $combo.Font = $regular; $combo.MaxLength = 60
    $combo.Add_TextChanged({ Set-SettingsDirty })
    $script:Gui['Tips'].SetToolTip($combo, 'Written into every change record, so it is not picked each time. Empty = typed or picked in the form.')
    $b2.Controls.Add($combo); $script:Gui['SettingsSystemCombo'] = $combo
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Systems offered in the form (; between):'; $l.Location = New-Object System.Drawing.Point(430, 31); $l.AutoSize = $true; $l.Font = $regular; $b2.Controls.Add($l)
    $sys = New-Object System.Windows.Forms.TextBox; $sys.Location = New-Object System.Drawing.Point(680, 28); $sys.Width = 345; $sys.Font = $regular
    $sys.Add_TextChanged({ Set-SettingsDirty })
    $b2.Controls.Add($sys); $script:Gui['SettingsSystemsBox'] = $sys
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Must be filled in:'; $l.Location = New-Object System.Drawing.Point(12, 64); $l.AutoSize = $true; $l.Font = $regular; $b2.Controls.Add($l)
    $script:Gui['SettingsFieldBoxes'] = [ordered]@{}
    $x = 200
    foreach ($f in $script:ChangeFieldNames.Keys) {
        $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $script:ChangeFieldNames[$f]; $cb.AutoSize = $true; $cb.Location = New-Object System.Drawing.Point($x, 62); $cb.Font = $regular
        $cb.Add_CheckedChanged({ Set-SettingsDirty })
        $b2.Controls.Add($cb); $script:Gui['SettingsFieldBoxes'][$f] = $cb
        $x += 150
    }
    $null = New-SettingsNote -Box $b2 -Y 92 -Height 34 -Text 'Per action: "Change record required" = the form, every time; "Change record, or maintenance" = the form with a tick for a maintenance activity that needs no change (recorded as MAINTENANCE); "Not recorded" = no form and no change-log row - the running log still has every step.'
    $pg = New-SettingsGrid -Box $b2 -Y 130 -Height 176
    $colA = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colA.HeaderText = 'Action'; $colA.Width = 200; $colA.ReadOnly = $true
    $colR = New-Object System.Windows.Forms.DataGridViewComboBoxColumn; $colR.HeaderText = 'Recording'; $colR.Width = 230; $colR.FlatStyle = 'Flat'
    [void]$colR.Items.AddRange([object[]]@($script:ChangePolicyNames.Values))
    $colC = New-Object System.Windows.Forms.DataGridViewTextBoxColumn; $colC.HeaderText = 'What it covers'; $colC.AutoSizeMode = 'Fill'; $colC.ReadOnly = $true
    $pg.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colA, $colR, $colC))
    foreach ($a in $script:ChangeActions.Keys) { [void]$pg.Rows.Add([object[]]@($a, $script:ChangePolicyNames['Required'], $script:ChangeActions[$a])) }
    $script:Gui['SettingsPolicyGrid'] = $pg

    # ---- 3 to 5: the simple values, two to a line ----
    $y = 608
    foreach ($sec in @(@('Log', 'The running log and the log files'), @('Results', 'Saved results: every console remembers its last check'), @('Safety', 'Warnings and safety limits'), @('Software', 'The Software console'), @('Commands', 'The Commands console'), @('Health', 'Health warning thresholds (Health console)'), @('Security', 'The Security console: GPO recommendations'))) {
        $specs = @($script:SettingSpecs | Where-Object { $_.Section -eq $sec[0] })
        $box = New-SettingsBox -Body $body -Title $sec[1] -Y $y -Height (26 + [math]::Ceiling((Get-SettingRowSlots -Specs $specs) / 2) * 30 + 8)
        $null = Add-SettingRows -Box $box -Specs $specs
        $y += $box.Height + 10
    }
    if ($script:Gui['SettingControls']['TrellixInUse']) { $script:Gui['SettingControls']['TrellixInUse'].Add_CheckedChanged({ Update-TrellixSettingRows }) }
    $foot = New-Object System.Windows.Forms.Label
    $foot.Text = 'Changed in lib\01-Config.ps1 only (not here): the integrity guards RequireValidSignature and AllowUnknownTargetBuild, the WinRM port and timeouts, the folders. Every save is written to the log with who saved it.'
    $foot.Location = New-Object System.Drawing.Point(12, $y); $foot.Size = New-Object System.Drawing.Size(1035, 36); $foot.ForeColor = 'DimGray'
    $body.Controls.Add($foot)

    # ---- toolbar ----
    $toolbar = New-ConsoleToolbar -Tab $tab -Height 70
    $toolbar.Controls.Add((New-GuiButton -Text 'Save settings' -X 8 -Y 8 -W 130 -H 34 -Colour 'LightGreen' -Tip 'Shows what changes, then saves it in settings\settings.json and uses it at once' -OnClick { Invoke-GuiAction -Name 'Save settings' -Action { Invoke-SettingsSave } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Undo unsaved changes' -X 143 -Y 8 -W 165 -H 34 -ReadOnly -Tip 'The page shows the settings in use again' -OnClick { Invoke-GuiAction -Name 'Undo settings changes' -ReadOnly -Action { Set-SettingsForm -Values (Get-SettingsLive) } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Restore defaults...' -X 313 -Y 8 -W 140 -H 34 -Tip 'Fills the page with the defaults of lib\01-Config.ps1 - saved only with Save settings' -OnClick { Invoke-GuiAction -Name 'Restore default settings' -Action { Restore-SettingsDefaults } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Open settings folder' -X 458 -Y 8 -W 150 -H 34 -ReadOnly -Tip 'settings\ in Explorer' -OnClick {
        Invoke-GuiAction -Name 'Open settings folder' -ReadOnly -Action {
            $folder = Split-Path -Path $script:Config.SettingsFile -Parent
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
        } }))
    $dirty = New-Object System.Windows.Forms.Label
    $dirty.Text = 'UNSAVED CHANGES'; $dirty.ForeColor = 'DarkRed'; $dirty.AutoSize = $true; $dirty.Visible = $false
    $dirty.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold); $dirty.Location = New-Object System.Drawing.Point(620, 16)
    $toolbar.Controls.Add($dirty); $script:Gui['SettingsDirtyLabel'] = $dirty
    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(10, 48); $status.Size = New-Object System.Drawing.Size(1040, 18); $status.ForeColor = 'DimGray'; $status.AutoEllipsis = $true
    $toolbar.Controls.Add($status); $script:Gui['SettingsStatus'] = $status

    $null = New-ConsoleBanner -Tab $tab -Console 'Settings' -Title 'SETTINGS' -Subtitle 'what this toolkit asks, records and logs - saved in settings\settings.json'
    $body.BringToFront()
    Set-SettingsForm -Values (Get-SettingsLive)
}
