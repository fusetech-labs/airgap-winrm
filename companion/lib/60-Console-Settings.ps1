# =====================================================================
#  60-Console-Settings.ps1  -  THE SETTINGS CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  One page, five boxes, saved together with "Save settings".  First
#  the site: the Windows builds the servers run, the architecture, the
#  .NET Framework lines in use, the ESXi line and the VMware Tools rule,
#  a site name - so the wrong update is never fetched.  They are saved
#  in settings\environment.json (lib\03-Products.ps1 checks every field;
#  the Products console saves its ticks and links in the same file).
#  Then the settings proper, saved in settings\settings.json: the
#  library (folder, how many older files stay, the signature rule),
#  downloads (limits, proxy, how far back the catalogue is searched),
#  the scheduled task (time, days, logon type) and the running log.
#  lib\12-Settings.ps1 checks and saves those and logs every change with
#  who made it.  Save shows the changes first and says which of them
#  weaken a safeguard.
# =====================================================================

$script:SiteFieldLabels = [ordered]@{
    WindowsBuilds   = 'Windows builds'
    Architecture    = 'Architecture'
    DotNetLines     = '.NET Framework lines'
    EsxiVersion     = 'ESXi version'
    VMwareToolsRule = 'VMware Tools rule'
    VMwareToolsPin  = 'Pinned VMware Tools version'
    Site            = 'Site name'
}

function Set-SettingsDirty {
    if ($script:Gui['SettingsFilling']) { return }
    $script:Gui['SettingsDirty'] = $true
    $script:Gui['SettingsDirtyLabel'].Visible = $true
}

function Update-SettingsStatus {
    $info = $script:SettingsInfo
    $text = 'Settings: none saved yet - the defaults of lib\01-Config.ps1 apply.'
    if ($info -and $info.Exists) {
        $text = ('Settings: saved {0} by {1}, {2} value(s) differ from the defaults.' -f $info.Saved, $info.SavedBy, @($info.Applied).Count)
        if (@($info.Problems).Count -gt 0) { $text += (' {0} value(s) in the file were skipped - see the log.' -f @($info.Problems).Count) }
    }
    $site = $script:EnvironmentInfo
    if ($site -and $site.Exists) {
        $text += ('   This site: saved {0} by {1}.' -f $site.Saved, $site.SavedBy)
        if (@($site.Problems).Count -gt 0) { $text += (' {0} value(s) in the file were skipped - see the log.' -f @($site.Problems).Count) }
    } else { $text += '   This site: not saved yet - the defaults apply.' }
    $script:Gui['SettingsStatus'].Text = $text
    $script:Gui['Tips'].SetToolTip($script:Gui['SettingsStatus'], $text)
}

function Update-SitePinRow {
    # The pinned version can be typed only while the rule is "pin"
    $c = $script:Gui['SiteControls']
    $rule = @($script:VMwareToolsRules.Keys)[[math]::Max(0, $c['VMwareToolsRule'].SelectedIndex)]
    $c['VMwareToolsPin'].Enabled = ($rule -eq 'pin')
}

function Set-SiteForm {
    # The first box filled from an environment (the one in use, or the defaults)
    param($Values)
    $c = $script:Gui['SiteControls']
    $was = [bool]$script:Gui['SettingsFilling']
    $script:Gui['SettingsFilling'] = $true
    try {
        foreach ($b in $script:BuildNames.Keys) { $c[('Build:' + $b)].Checked = (@($Values.WindowsBuilds) -contains [int]$b) }
        $c['Architecture'].SelectedItem = [string]$Values.Architecture
        foreach ($l in $script:DotNetLineChoices) { $c[('Line:' + $l)].Checked = (@($Values.DotNetLines) -contains $l) }
        $c['EsxiVersion'].Text = [string]$Values.EsxiVersion
        $c['VMwareToolsRule'].SelectedIndex = [math]::Max(0, @($script:VMwareToolsRules.Keys).IndexOf([string]$Values.VMwareToolsRule))
        $c['VMwareToolsPin'].Text = [string]$Values.VMwareToolsPin
        $c['Site'].Text = [string]$Values.Site
    } finally { $script:Gui['SettingsFilling'] = $was }
    Update-SitePinRow
}

function Get-SiteFormValues {
    $c = $script:Gui['SiteControls']
    $v = @{}
    $v['WindowsBuilds'] = @(foreach ($b in @($script:BuildNames.Keys | Sort-Object)) { if ($c[('Build:' + $b)].Checked) { [int]$b } })
    $v['Architecture'] = [string]$c['Architecture'].SelectedItem
    $v['DotNetLines'] = @(foreach ($l in $script:DotNetLineChoices) { if ($c[('Line:' + $l)].Checked) { $l } })
    $v['EsxiVersion'] = [string]$c['EsxiVersion'].Text
    $v['VMwareToolsRule'] = @($script:VMwareToolsRules.Keys)[[math]::Max(0, $c['VMwareToolsRule'].SelectedIndex)]
    $v['VMwareToolsPin'] = [string]$c['VMwareToolsPin'].Text
    $v['Site'] = [string]$c['Site'].Text
    return $v
}

function Get-SiteChangeLines {
    # What saving the first box would change against the environment in use.  Every field is checked first: the one that
    # does not fit throws, naming it.
    param([hashtable]$Values)
    $new = [ordered]@{}
    foreach ($k in $script:SiteFieldLabels.Keys) {
        if (-not $Values.ContainsKey($k)) { continue }
        try { $new[$k] = Test-EnvironmentValue -Key $k -Value $Values[$k] } catch { throw ('{0}: {1}' -f $script:SiteFieldLabels[$k], $_.Exception.Message) }
    }
    if ($new.Contains('VMwareToolsRule') -and $new.VMwareToolsRule -eq 'pin' -and -not $new.VMwareToolsPin) { throw 'VMware Tools: the rule is "pin" but no version is typed' }
    $lines = @()
    foreach ($k in $new.Keys) {
        $a = Get-EnvironmentValueText $script:Environment[$k]; $b = Get-EnvironmentValueText $new[$k]
        if ($a -cne $b) { $lines += ('{0}: {1}  ->  {2}' -f $script:SiteFieldLabels[$k], $(if ($a) { $a } else { '(none)' }), $(if ($b) { $b } else { '(none)' })) }
    }
    return $lines
}

function Set-SettingsForm {
    # The page filled with $Values, and the first box with the site as it is saved (-KeepSite leaves that box as it is)
    param([hashtable]$Values, [switch]$KeepSite)
    $script:Gui['SettingsFilling'] = $true
    try {
        foreach ($key in @($script:Gui['SettingControls'].Keys)) {
            $ctl = $script:Gui['SettingControls'][$key]; $v = $Values[$key]
            if ($ctl -is [System.Windows.Forms.CheckBox]) { $ctl.Checked = [bool]$v }
            elseif ($ctl -is [System.Windows.Forms.NumericUpDown]) { $ctl.Value = [decimal]([math]::Max([double]$ctl.Minimum, [math]::Min([double]$ctl.Maximum, [double]$v))) }
            elseif ($ctl -is [System.Windows.Forms.ComboBox]) { $ctl.SelectedItem = [string]$v; if ($ctl.SelectedIndex -lt 0 -and $ctl.Items.Count -gt 0) { $ctl.SelectedIndex = 0 } }
            else { $ctl.Text = [string]$v }
        }
        if (-not $KeepSite) { Set-SiteForm -Values $script:Environment }
    } finally { $script:Gui['SettingsFilling'] = $false }
    $script:Gui['SettingsDirty'] = $false
    $script:Gui['SettingsDirtyLabel'].Visible = $false
    Update-SettingsStatus
}

function Get-SettingsLive {
    $v = @{}
    foreach ($s in $script:SettingSpecs) { $v[$s.Key] = $script:Config[$s.Key] }
    return $v
}

function Get-SettingsFormValues {
    $v = @{}
    foreach ($key in @($script:Gui['SettingControls'].Keys)) {
        $ctl = $script:Gui['SettingControls'][$key]
        if ($ctl -is [System.Windows.Forms.CheckBox]) { $v[$key] = $ctl.Checked }
        elseif ($ctl -is [System.Windows.Forms.NumericUpDown]) { $v[$key] = [int]$ctl.Value }
        elseif ($ctl -is [System.Windows.Forms.ComboBox]) { $v[$key] = [string]$ctl.SelectedItem }
        else { $v[$key] = [string]$ctl.Text }
    }
    return $v
}

function Invoke-SettingsSave {
    # The settings go to settings\settings.json, the first box (the site) to settings\environment.json: one question, and
    # nothing is saved when a value of either does not fit.
    $values = Get-SettingsFormValues
    $site = Get-SiteFormValues
    try { $siteLines = @(Get-SiteChangeLines -Values $site); $preview = Get-SettingsPreview -Values $values }
    catch { $null = Show-PatcherMessage -Text ("Nothing was saved:`n`n{0}" -f $_.Exception.Message) -Title 'Settings not saved' -Icon 'Warning'; return }
    $settingLines = @($preview.Changes)
    if (($siteLines.Count + $settingLines.Count) -eq 0) { Write-PatchLog 'Settings: nothing to save - the page shows the settings in use' 'INFO'; Set-SettingsForm -Values (Get-SettingsLive); return }
    $text = "Save these changes?`n`n" + ((@($siteLines + $settingLines) | ForEach-Object { '- ' + $_ }) -join "`n")
    if ($siteLines.Count -gt 0) { $text += "`n`nThe Library tab fetches only what fits the site: check for updates again afterwards." }
    $weaker = @($preview.Weaker)
    if ($weaker.Count -gt 0) { $text += "`n`nTHESE WEAKEN A SAFEGUARD:`n" + (($weaker | ForEach-Object { '! ' + $_ }) -join "`n") }
    $notes = @($preview.Notes)
    if ($notes.Count -gt 0) { $text += "`n`nWORTH KNOWING (saved as you set them):`n" + (($notes | ForEach-Object { '- ' + $_ }) -join "`n") }
    $answer = Show-PatcherMessage -Title 'Save settings' -Buttons 'YesNo' -Icon $(if ($weaker.Count -gt 0) { 'Warning' } else { 'Question' }) -Default $(if ($weaker.Count -gt 0) { 'Button2' } else { 'Button1' }) -Text $text
    if ($answer -ne 'Yes') { Write-PatchLog 'Settings not saved (answered No) - the page still shows the unsaved changes' 'INFO'; return }
    if ($siteLines.Count -gt 0) { $null = Save-Environment -Values $site }
    if ($settingLines.Count -gt 0) { $null = Save-ToolkitSettings -Values $values }
    Set-SettingsForm -Values (Get-SettingsLive)
    foreach ($k in @($script:Gui['RefreshByConsole'].Keys)) { $script:Gui['Stale'][$k] = $true }
    Remove-OldPatchLogs
}

function Restore-SettingsDefaults {
    $a = Show-PatcherMessage -Title 'Restore defaults' -Buttons 'YesNo' -Icon 'Question' -Default 'Button2' -Text "Fill the page with the defaults of lib\01-Config.ps1?`n`nThe first box - what this site runs - stays as it is. Nothing is saved until you press Save settings; Undo unsaved changes goes back to the settings in use."
    if ($a -ne 'Yes') { return }
    Set-SettingsForm -Values (Get-SettingsDefaults) -KeepSite
    Set-SettingsDirty
}

function Get-SettingsHelpHtml {
    $notes = @'
THIS SITE: WHAT THE MANAGED SERVERS RUN

The Download Toolkit never guesses what a site runs. Every product is fetched for the targets named in the first box and for nothing else: a Windows build that is not ticked gets no cumulative update, a .NET rollup that covers a line not ticked is held, a VMware Tools release outside the ESXi line is held. Set them once, save, and the Library tab shows one row per product and target. Which products are fetched at all is ticked on the Products tab.

WINDOWS

  * Tick every build the managed servers run (the number before the dot in 17763.1234: Server 2019 is 17763, Server 2022 is 20348). The WinRM toolkit's O/S Patching grid shows the build of every server.
  * The architecture is x64 for every Windows Server; arm64 only for an ARM fleet.
  * The Update Catalog names Server 2022 "Microsoft server operating system version 21H2": the names per build are in data\products.psd1 (CatalogProducts).

.NET FRAMEWORK

  * Tick the lines installed on the servers (the WinRM toolkit's O/S Patching grid shows each server's .NET line). A month's .NET rollup for Server 2019 comes as "3.5 and 4.8", "3.5 and 4.8.1" and "3.5, 4.7.2 and 4.8": with 4.8 and 4.8.1 ticked the first two are fetched and the third is held.
  * 3.5 rides along in every rollup and is not a line to tick.

VMWARE TOOLS

  * The ESXi version is the line the VMs run on: 7.0, 8.0, 8.0u3, 9.0. The version map on the VMware package site says which Tools each line ships (ESXi 8.0 patches ship 12.5.x, ESXi 9.x ships 13.x). Empty = VMware Tools is not fetched.
  * The rule: "shipped" takes exactly the release the ESXi line ships; "line" takes the newest release of that version line (12.5.4 for ESXi 8.0); "latest" takes the newest release there is - check it against the Broadcom product interoperability matrix first; "pin" takes the version typed in the box.
  * A newer Tools line usually supports older ESXi, but a site that follows the vSphere release stays with "line".

THE OTHER BOXES

  * The library: where the files are kept, how many superseded files stay, and whether a file must carry a valid signature.
  * Downloads: the size limit, the retries, the proxy, and how far back the Update Catalog is searched.
  * The scheduled task: its time, days and logon type. Register the task again on the Schedule tab after a change.
  * The log: the running log, the log files and the operator's name.
  * Every setting says what it does in the tip over it.

SAVING

  * Save settings shows what changes first and says which changes weaken a safeguard. Nothing is saved when one value does not fit.
  * The first box is saved in settings\environment.json (with the ticks and links of the Products tab); the others in settings\settings.json. Every save is written to the log with who saved it.
  * Undo unsaved changes shows what is in use again. Restore defaults fills the settings with the defaults of lib\01-Config.ps1 and leaves the first box as it is.
'@
    return (New-DetailsHtml -Title 'Help: the Settings console' -Subtitle 'what this site runs, and how the tool behaves' -Console 'Settings' -Sections @(@{ Heading = ''; Html = (ConvertTo-HtmlFromNotes -Text $notes) }))
}

function New-SiteBox {
    # The first box of the page: what this site runs.  Returns the box.
    param($Body, [int]$At)
    $script:Gui['SiteControls'] = [ordered]@{}
    $regular = New-Object System.Drawing.Font('Segoe UI', 9)
    $builds = @($script:BuildNames.Keys | Sort-Object)
    $buildRows = [int][math]::Max(1, [math]::Ceiling($builds.Count / 4))
    $first = 26 + ($buildRows - 1) * 24   # the last line of builds: the other rows follow 30 apart
    $box = New-SettingsBox -Body $Body -Title 'This site: what the managed servers run' -Y $At -Height ($first + 128)
    $newLabel = { param([string]$Text, [int]$X, [int]$Y1) $l = New-Object System.Windows.Forms.Label; $l.Text = $Text; $l.Font = $regular; $l.AutoSize = $true; $l.Location = New-Object System.Drawing.Point($X, ($Y1 + 4)); $box.Controls.Add($l) }
    $newTick = { param([string]$Key, [string]$Text, [int]$X, [int]$Y1, [int]$W, [string]$Tip) $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $Text; $cb.Font = $regular; $cb.Location = New-Object System.Drawing.Point($X, $Y1); $cb.Size = New-Object System.Drawing.Size($W, 24); $cb.Add_CheckedChanged({ Set-SettingsDirty }); $box.Controls.Add($cb); $script:Gui['SiteControls'][$Key] = $cb; $script:Gui['Tips'].SetToolTip($cb, $Tip) }
    $newText = { param([string]$Key, [int]$X, [int]$Y1, [int]$W, [int]$Max, [string]$Tip) $t = New-Object System.Windows.Forms.TextBox; $t.Font = $regular; $t.Location = New-Object System.Drawing.Point($X, $Y1); $t.Width = $W; $t.MaxLength = $Max; $t.Add_TextChanged({ Set-SettingsDirty }); $box.Controls.Add($t); $script:Gui['SiteControls'][$Key] = $t; $script:Gui['Tips'].SetToolTip($t, $Tip) }

    # ---- Windows: the builds, four to a line, and the architecture ----
    & $newLabel 'Windows builds:' 10 26
    for ($i = 0; $i -lt $builds.Count; $i++) {
        $b = $builds[$i]
        & $newTick ('Build:' + $b) ('{0} ({1})' -f $script:BuildNames[$b], $b) (160 + ($i % 4) * 160) (26 + [math]::Floor($i / 4) * 24) 155 'Tick every build the managed servers run: an update is fetched for these builds and no others'
    }
    & $newLabel 'Architecture:' 820 26
    $arch = New-Object System.Windows.Forms.ComboBox
    $arch.DropDownStyle = 'DropDownList'; $arch.Font = $regular; $arch.Location = New-Object System.Drawing.Point(905, 26); $arch.Width = 115
    [void]$arch.Items.AddRange([object[]]@('x64', 'arm64')); $arch.Add_SelectedIndexChanged({ Set-SettingsDirty })
    $box.Controls.Add($arch); $script:Gui['SiteControls']['Architecture'] = $arch
    $script:Gui['Tips'].SetToolTip($arch, 'x64 for every Windows Server; arm64 only for an ARM fleet')

    # ---- .NET Framework: the lines in use ----
    $rowY = $first + 30
    & $newLabel '.NET Framework lines:' 10 $rowY
    $x = 160
    foreach ($l in $script:DotNetLineChoices) { & $newTick ('Line:' + $l) $l $x $rowY 75 'Tick the lines in use: a rollup that covers a line not ticked is held. 3.5 rides along in every rollup.'; $x += 80 }

    # ---- VMware Tools: the ESXi line, the rule, the pinned version ----
    $rowY = $first + 60
    & $newLabel 'ESXi version:' 10 $rowY
    & $newText 'EsxiVersion' 160 $rowY 90 12 '7.0, 8.0, 8.0u3, 9.0 ... - empty = VMware Tools is not fetched'
    & $newLabel 'VMware Tools rule:' 275 $rowY
    $rule = New-Object System.Windows.Forms.ComboBox
    $rule.DropDownStyle = 'DropDownList'; $rule.Font = $regular; $rule.Location = New-Object System.Drawing.Point(395, $rowY); $rule.Width = 625
    foreach ($k in $script:VMwareToolsRules.Keys) { [void]$rule.Items.Add(('{0} - {1}' -f $k, $script:VMwareToolsRules[$k])) }
    $rule.Add_SelectedIndexChanged({ Set-SettingsDirty; Update-SitePinRow })
    $box.Controls.Add($rule); $script:Gui['SiteControls']['VMwareToolsRule'] = $rule
    $script:Gui['Tips'].SetToolTip($rule, 'Which VMware Tools release is taken for the ESXi line')

    # ---- the site's name, and the pinned version under the rule it belongs to ----
    $rowY = $first + 90
    & $newLabel 'Pinned version:' 820 $rowY
    & $newText 'VMwareToolsPin' 930 $rowY 90 12 'The one version to take while the rule is "pin", for example 12.5.4'
    & $newLabel 'Site name (reports):' 10 $rowY
    & $newText 'Site' 160 $rowY 300 60 'A name for the reports (optional)'
    return $box
}

function New-SettingsBox {
    param($Body, [string]$Title, [int]$Y, [int]$Height)
    $box = New-Object System.Windows.Forms.GroupBox
    $box.Text = $Title; $box.Location = New-Object System.Drawing.Point(10, $Y); $box.Size = New-Object System.Drawing.Size(1040, $Height)
    $box.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
    $Body.Controls.Add($box)
    return $box
}

function Add-SettingRows {
    # Simple settings as rows in a box, two to a line (a Wide spec takes the whole line): a tick box for yes/no, a list for a
    # choice, otherwise its label and a number or text box.  Returns the y below the last row.
    param($Box, [object[]]$Specs, [int]$Top = 26)
    $regular = New-Object System.Drawing.Font('Segoe UI', 9)
    $colW = 510
    $slot = 0
    foreach ($s in $Specs) {
        $tipText = ('{0}  ({1} in lib\01-Config.ps1)' -f $s.Label, $s.Key)
        if ($s.Tip) { $tipText = ('{0}  ({1} in lib\01-Config.ps1)' -f $s.Tip, $s.Key) }
        if ($s.Wide -and ($slot % 2) -eq 1) { $slot++ }
        $x = 10 + ($slot % 2) * $colW; $y = $Top + [math]::Floor($slot / 2) * 30
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
            } elseif ($s.Type -eq 'choice') {
                $c = New-Object System.Windows.Forms.ComboBox
                $c.DropDownStyle = 'DropDownList'; [void]$c.Items.AddRange([object[]]@($s.Choices))
                $c.Add_SelectedIndexChanged({ Set-SettingsDirty })
            } else {
                $c = New-Object System.Windows.Forms.TextBox
                $c.MaxLength = $s.MaxLen
                $c.Add_TextChanged({ Set-SettingsDirty })
            }
            $c.Location = New-Object System.Drawing.Point(($x + $colW - 135), $y); $c.Width = 115
            if ($s.Wide) { $c.Location = New-Object System.Drawing.Point(($x + $colW - 135), $y); $c.Width = 115 + $colW }
        }
        $c.Font = $regular
        $script:Gui['Tips'].SetToolTip($c, $tipText)
        $Box.Controls.Add($c)
        $script:Gui['SettingControls'][$s.Key] = $c
        $slot++; if ($s.Wide) { $slot++ }
    }
    return ($Top + [math]::Ceiling($slot / 2) * 30)
}

function New-SettingsConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Settings' -Text 'Settings'
    $script:Gui['SettingControls'] = [ordered]@{}
    $script:Gui['SettingsDirty'] = $false
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = 'Fill'; $body.AutoScroll = $true; $body.BackColor = 'White'
    $tab.Controls.Add($body)

    $site = New-SiteBox -Body $body -At 10
    $y = 10 + $site.Height + 10
    foreach ($sec in @(@('Library', 'The library'), @('Downloads', 'Downloads'), @('Schedule', 'The scheduled task (register it again on the Schedule tab after a change)'), @('Log', 'The running log, the log files and the operator'))) {
        $specs = @($script:SettingSpecs | Where-Object { $_.Section -eq $sec[0] })
        $slots = 0; foreach ($s in $specs) { if ($s.Wide) { if ($slots % 2 -eq 1) { $slots++ }; $slots += 2 } else { $slots++ } }
        $box = New-SettingsBox -Body $body -Title $sec[1] -Y $y -Height (26 + [math]::Ceiling($slots / 2) * 30 + 8)
        $null = Add-SettingRows -Box $box -Specs $specs
        $y += $box.Height + 10
    }
    $foot = New-Object System.Windows.Forms.Label
    $foot.Text = 'Changed in lib\01-Config.ps1 only (not here): the catalogue and VMware addresses, the task name and folder, the manifest file names. Every save is written to the log with who saved it.'
    $foot.Location = New-Object System.Drawing.Point(12, $y); $foot.Size = New-Object System.Drawing.Size(1035, 36); $foot.ForeColor = 'DimGray'
    $body.Controls.Add($foot)

    $toolbar = New-ConsoleToolbar -Tab $tab -Height 70
    $toolbar.Controls.Add((New-GuiButton -Text 'Save settings' -X 8 -Y 8 -W 130 -H 34 -Colour 'LightGreen' -Tip 'Shows what changes, then saves it (settings\settings.json, and settings\environment.json for the first box) and uses it at once' -OnClick { Invoke-GuiAction -Name 'Save settings' -Action { Invoke-SettingsSave } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Undo unsaved changes' -X 143 -Y 8 -W 165 -H 34 -ReadOnly -Tip 'The page shows the settings in use again' -OnClick { Invoke-GuiAction -Name 'Undo settings changes' -ReadOnly -Action { Set-SettingsForm -Values (Get-SettingsLive) } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Restore defaults...' -X 313 -Y 8 -W 140 -H 34 -Tip 'Fills the settings with the defaults of lib\01-Config.ps1 (the first box stays) - saved only with Save settings' -OnClick { Invoke-GuiAction -Name 'Restore default settings' -Action { Restore-SettingsDefaults } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Open settings folder' -X 458 -Y 8 -W 150 -H 34 -ReadOnly -Tip 'settings\ in Explorer' -OnClick {
        Invoke-GuiAction -Name 'Open settings folder' -ReadOnly -Action {
            $folder = Split-Path -Path $script:Config.SettingsFile -Parent
            if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
            Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $folder)
        } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Help' -X 613 -Y 8 -W 70 -H 34 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Settings help' -ReadOnly -Action { Show-ConsoleHelp -Console 'Settings' -Html (Get-SettingsHelpHtml) } }))
    $dirty = New-Object System.Windows.Forms.Label
    $dirty.Text = 'UNSAVED CHANGES'; $dirty.ForeColor = 'DarkRed'; $dirty.AutoSize = $true; $dirty.Visible = $false
    $dirty.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold); $dirty.Location = New-Object System.Drawing.Point(705, 16)
    $toolbar.Controls.Add($dirty); $script:Gui['SettingsDirtyLabel'] = $dirty
    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(10, 48); $status.Size = New-Object System.Drawing.Size(1040, 18); $status.ForeColor = 'DimGray'; $status.AutoEllipsis = $true
    $toolbar.Controls.Add($status); $script:Gui['SettingsStatus'] = $status

    $null = New-ConsoleBanner -Tab $tab -Console 'Settings' -Title 'SETTINGS' -Subtitle 'what this site runs, the library, the downloads, the task and the log'
    $body.BringToFront()
    Set-SettingsForm -Values (Get-SettingsLive)
}
