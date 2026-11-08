# =====================================================================
#  11-ChangeLog.ps1  -  CHANGE RECORDS FOR EVERYTHING THAT CHANGES A SERVER
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Before an OS patch install, a reboot, a software install / update, a
#  software removal or a typed command that may change a server (Commands
#  tab), the operator records the change it belongs to: the
#  reference from the change system (a Jira key, a ServiceNow CHG number
#  ...), who approved it, the window and a note.  The record is kept in
#  two places so it stays with the servers:
#     changes\change-log.csv (here)  one row per server per action, with
#                                    the result - shown on each server's
#                                    details page and in the Change log
#                                    window, filterable, exportable
#     on the server itself           the Application event the tool
#                                    writes (900 patch, 910 software, 920
#                                    reboot, 930 command, 940 Trellix
#                                    Agent services) and
#                                    C:\PatchStaging\change-log.txt
#  The CSV is append-only: rows are added, never edited by the tool.
#  The Settings tab decides, per action, whether a change record is
#  required, may be replaced by a "maintenance activity - no change
#  required" tick, or is not recorded at all (ChangePolicy); which fields
#  must be filled in (ChangeRequiredFields, the reference by default); and
#  the change system written into every record (ChangeSystem).
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  11-ChangeLog.ps1
#  New 2026-10-20.  Nothing here runs on a server: the remote scripts in
#  06-Install.ps1 and 50-Console-Software.ps1 receive the change text as
#  a plain argument.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

$script:ChangeLogColumns = @('Time', 'Server', 'Action', 'Item', 'ChangeRef', 'ChangeSystem', 'ApprovedBy', 'Window', 'Notes', 'Operator', 'Result')

# The actions that ask for a change record (the keys of ChangePolicy) and what each covers - the Settings tab lists them.
$script:ChangeActions = [ordered]@{
    'OS patch install'          = 'O/S Patching: PATCH IT! (Windows and .NET updates)'
    'OS patch stage'            = 'O/S Patching: STAGE ONLY (copies patch files, installs nothing)'
    'Reboot'                    = 'Reboot (ticked) (both consoles)'
    'Software install / update' = 'Software: INSTALL / UPDATE'
    'Software removal'          = 'Software: UNINSTALL (ticked products)'
    'Software stage'            = 'Software: STAGE ONLY (copies installers, installs nothing)'
    'Trellix Agent services'    = 'Both consoles: Start / Stop Trellix Agent (ticked) - the two agent services to Automatic and running, or Disabled and stopped'
    'Command (may change)'      = 'Commands: a typed command that is not read-only'
}
$script:ChangePolicyNames = [ordered]@{ Required = 'Change record required'; Maintenance = 'Change record, or maintenance'; NotRecorded = 'Not recorded' }
$script:ChangeFieldNames = [ordered]@{ Ref = 'Change reference'; ApprovedBy = 'Approved by'; Window = 'Change window'; Notes = 'Notes' }

function Get-ChangeLogPath {
    return (Join-Path $script:Config.ChangeLogFolder 'change-log.csv')
}

function Test-ChangeLogWritable {
    # '' when changes\change-log.csv can take a row now, else why not (Request-ChangeRecord asks before anything changes).
    # Opened for append and closed again: nothing is written.
    $path = Get-ChangeLogPath
    try {
        $folder = Split-Path -Path $path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null }
        if (Test-Path -LiteralPath $path) {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
            $fs.Close()
        } else {
            # no file yet: Write-ChangeLog creates it with its header - here only the folder is tried (an empty file would lose the header)
            $probe = Join-Path $folder ('.write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            [System.IO.File]::WriteAllText($probe, '')
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }
        return ''
    } catch { return ('changes\change-log.csv cannot be written: ' + $_.Exception.Message) }
}

function Get-ChangePolicy {
    # How an action is recorded (ChangePolicy, Settings tab): Required, Maintenance (a change record, or ticked as a
    # maintenance activity that needs no change) or NotRecorded.  An action the settings do not name needs a record.
    param([string]$Action)
    $v = ''
    if ($script:Config.ChangePolicy) { $v = [string]$script:Config.ChangePolicy[$Action] }
    if ($script:ChangePolicyNames.Contains($v)) { return $v }
    return 'Required'
}

function New-ChangeRecord {
    # -Maintenance: a maintenance activity that needs no change (the reference reads MAINTENANCE).  -NotRecorded: the
    # Settings tab says this action is not recorded - Write-ChangeLog then writes nothing.
    param([string]$Ref, [string]$System = '', [string]$ApprovedBy = '', [string]$Window = '', [string]$Notes = '', [switch]$Maintenance, [switch]$NotRecorded)
    $r = $Ref.Trim()
    if ($Maintenance) { $r = 'MAINTENANCE' }
    return [pscustomobject]@{ Ref = $r; System = $System.Trim(); ApprovedBy = $ApprovedBy.Trim(); Window = $Window.Trim(); Notes = $Notes.Trim(); Maintenance = [bool]$Maintenance; Recorded = (-not $NotRecorded); Operator = (Get-OperatorIdentity); Created = (Get-Date) }
}

function Format-ChangeText {
    # One line for event logs, result files and the server's change-log.txt: "CHG0012345 (ServiceNow; approved by J Smith; window Sat 22:00-02:00)".
    param($Record)
    if (-not $Record) { return 'no change record' }
    if ($Record.PSObject.Properties['Recorded'] -and -not $Record.Recorded) { return 'no change record (not recorded for this action - Settings tab)' }
    $parts = @()
    if ($Record.PSObject.Properties['Maintenance'] -and $Record.Maintenance) { $parts += 'maintenance activity, no change required' }
    if ($Record.System) { $parts += $Record.System }
    if ($Record.ApprovedBy) { $parts += 'approved by ' + $Record.ApprovedBy }
    if ($Record.Window) { $parts += 'window ' + $Record.Window }
    $text = [string]$Record.Ref
    if (-not $text) { $text = '(no reference)' }
    if ($parts.Count -gt 0) { $text += ' (' + ($parts -join '; ') + ')' }
    # no line breaks or pipes (the server's change-log.txt is pipe-separated) and no double quotes: the text travels to
    # shutdown.exe's /c comment, and PowerShell 5.1 hands a native command an argument's quotes unescaped
    return (($text -replace '[\r\n|]', ' ') -replace '"', "'")
}

function ConvertTo-CsvField {
    # One quoted CSV field.  A value starting with = + - @ gets an apostrophe so it cannot run as a formula in Excel
    # (a ticket title is typed by people); a value that is wholly a number is left alone.
    param([string]$Value)
    $v = [string]$Value -replace '[\r\n]+', ' '
    if ($v -match '^[=+\-@\t]' -and $v -notmatch '^-?\d+([.,]\d+)*$') { $v = "'" + $v }
    return ('"' + $v.Replace('"', '""') + '"')
}

function Write-ChangeLog {
    # Appends one row per server to changes\change-log.csv.  -Result says where the action stands: 'approved - starting',
    # 'aborted at the safety checks', 'Installed - reboot required', 'FAILED: ...'.  An action the Settings tab marks
    # "Not recorded" writes nothing here (the running log still has every step).
    param($Record, [string[]]$Server, [string]$Action, [string]$Item = '', [string]$Result = '', [string]$Operator = '')
    if ($Record -and $Record.PSObject.Properties['Recorded'] -and -not $Record.Recorded) { return }
    $path = Get-ChangeLogPath
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path -LiteralPath $path)) { [void]$sb.AppendLine((($script:ChangeLogColumns | ForEach-Object { '"' + $_ + '"' }) -join ',')) }
    $when = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)   # ':' would be the culture's separator
    # -Operator: the one who launched the run, when a later status check (by anyone) records how it ended
    $op = $Operator; if (-not $op) { $op = Get-OperatorIdentity }
    foreach ($s in @($Server)) {
        $vals = @($when, $s, $Action, $Item, $Record.Ref, $Record.System, $Record.ApprovedBy, $Record.Window, $Record.Notes, $op, $Result)
        [void]$sb.AppendLine((($vals | ForEach-Object { ConvertTo-CsvField ([string]$_) }) -join ','))
    }
    try {
        [System.IO.File]::AppendAllText($path, $sb.ToString(), (New-Object System.Text.UTF8Encoding $true))
    } catch {
        # a change record that cannot be written is an error worth seeing, but it must not leave an install half-reported
        Write-PatchLog "CHANGE LOG NOT WRITTEN ($path): $(Get-ShortError $_)" 'ERROR'
        return
    }
    Write-PatchLog ("CHANGE {0} | {1} | {2} {3} | {4}" -f (Format-ChangeText $Record), (@($Server) -join ', '), $Action, $Item, $Result) 'INFO'
}

function Get-ChangeLogRows {
    # The change log, newest first; -Server keeps one server's rows (short and full names both match).
    param([string]$Server = '')
    $path = Get-ChangeLogPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $rows = @(Import-Csv -LiteralPath $path)
    if ($Server) {
        $label = ($Server -split '\.')[0]
        $rows = @($rows | Where-Object { $_.Server -ieq $Server -or (($_.Server -split '\.')[0]) -ieq $label })
    }
    [array]::Reverse($rows)
    return $rows
}

function Get-ChangeLogSection {
    # The "Change log" section of a server's details page.
    param([string]$Server)
    $rows = @(Get-ChangeLogRows -Server $Server)
    return @{ Heading = 'Change log (changes\change-log.csv)'; Rows = $rows; Columns = @('Time', 'Action', 'Item', 'ChangeRef', 'ChangeSystem', 'ApprovedBy', 'Window', 'Operator', 'Result', 'Notes'); Note = 'Every install, removal, reboot and command that may change the server this tool made, with the change it belonged to. The server keeps the same record in its Application log (events 900 patch / 910 software / 920 reboot / 930 command) and in C:\PatchStaging\change-log.txt.' }
}

function Show-ChangeLogWindow {
    # The Change log button: every record, newest first, with the filter box of the details window.
    if (-not (Test-GuiDialogAllowed 'The change log')) { return }
    $rows = @(Get-ChangeLogRows)
    $facts = @(@('File', (Get-ChangeLogPath)), @('Rows', $rows.Count))
    $html = New-DetailsHtml -Title 'Change log' -Subtitle 'every install, removal, reboot and command that may change a server, with its change record - newest first' -Console 'Patching' -Facts $facts -Sections @(
        @{ Heading = ''; Rows = $rows; Columns = @('Time', 'Server', 'Action', 'Item', 'ChangeRef', 'ChangeSystem', 'ApprovedBy', 'Window', 'Operator', 'Result', 'Notes') })
    Show-DetailsWindow -Title 'Change log' -Html $html
}

function Get-ChangeRecordGaps {
    # The required fields (ChangeRequiredFields, Settings tab) a record leaves empty, by their names in the form.  A
    # maintenance activity needs no change reference.
    param($Record)
    $gaps = @()
    foreach ($f in @($script:Config.ChangeRequiredFields)) {
        if (-not $script:ChangeFieldNames.Contains([string]$f)) { continue }
        if ($f -eq 'Ref' -and $Record.Maintenance) { continue }
        if (-not ([string]$Record.$f).Trim()) { $gaps += $script:ChangeFieldNames[[string]$f] }
    }
    return $gaps
}

function Request-ChangeRecord {
    # Asks for the change record of one action (a modal form) and returns it, or $null when the operator cancels -
    # then nothing happens.  The Settings tab decides per action (Get-ChangePolicy): Required = this form;
    # Maintenance = this form with a "maintenance activity - no change required" tick; NotRecorded = no form, and a
    # record that Write-ChangeLog does not write.  $script:PresetChangeRecord (console use, no window) answers without the form.
    param([string]$Action, [string[]]$Servers, [string]$Items = '')
    $policy = Get-ChangePolicy -Action $Action
    if ($policy -eq 'NotRecorded') {
        Write-PatchLog "$Action - no change record asked: the Settings tab marks this action 'Not recorded' (this log keeps every step)" 'WHY'
        return (New-ChangeRecord -Ref '' -NotRecorded)
    }
    # the record must be writable BEFORE anything changes: a change-log.csv held open by Excel took no rows, and the change
    # went ahead with only an ERROR line in the running log (R6-C16).  Cancel = nothing happens.
    $notWritable = Test-ChangeLogWritable
    if ($notWritable) {
        Write-PatchLog "$Action - stopped before anything changed: $notWritable" 'ERROR'
        $null = Show-PatcherMessage -Title 'The change log cannot be written' -Icon 'Error' -Text ("{0}`n`nNothing has been changed. Close the file (Excel holds it open while it shows it) and try again." -f $notWritable)
        return $null
    }
    if ($script:PresetChangeRecord) { return $script:PresetChangeRecord }
    $last = $script:LastChangeRecord
    $required = @(@($script:Config.ChangeRequiredFields) | Where-Object { $script:ChangeFieldNames.Contains([string]$_) })
    while ($true) {
        $dlg = New-ToolkitDialogForm
        $dlg.Text = 'Change record - ' + $Action
        $dlg.Size = New-Object System.Drawing.Size(640, 500); $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $intro = New-Object System.Windows.Forms.Label; $intro.Location = New-Object System.Drawing.Point(12, 10); $intro.Size = New-Object System.Drawing.Size(600, 74)
        $req = 'Fields marked * must be filled in.'
        if ($required.Count -eq 0) { $req = 'Every field is optional (Settings tab).' }
        $intro.Text = ("{0} on {1} server(s): {2}`r`n{3}`r`nThe record goes into changes\change-log.csv with the result, and onto each server (its event log and C:\PatchStaging\change-log.txt)." -f $Action, @($Servers).Count, $(if ($Items.Length -gt 160) { $Items.Substring(0, 160) + '...' } else { $Items }), $req)
        $dlg.Controls.Add($intro)
        $fields = @{}
        $y = 92
        foreach ($spec in @(@('Ref', 'Change reference (Jira key, CHG number ...)'), @('System', 'Change system'), @('ApprovedBy', 'Approved by'), @('Window', 'Change window'), @('Notes', 'Notes'))) {
            $l = New-Object System.Windows.Forms.Label; $l.Text = $spec[1] + $(if ($required -contains $spec[0]) { ' *:' } else { ':' }); $l.Location = New-Object System.Drawing.Point(12, ($y + 3)); $l.AutoSize = $true
            if ($spec[0] -eq 'System') {
                $box = New-Object System.Windows.Forms.ComboBox; $box.DropDownStyle = 'DropDown'
                foreach ($v in @($script:Config.ChangeSystems)) { if ($v) { [void]$box.Items.Add([string]$v) } }
            } else { $box = New-Object System.Windows.Forms.TextBox }
            $box.Location = New-Object System.Drawing.Point(270, $y); $box.Width = 340
            if ($spec[0] -eq 'Notes') { $box.Multiline = $true; $box.Height = 70; $box.ScrollBars = 'Vertical' }
            # the last record is offered again (one change window is typed once) - but never its MAINTENANCE marker
            if ($last -and $last.PSObject.Properties[$spec[0]] -and -not ($spec[0] -eq 'Ref' -and $last.Maintenance)) { $box.Text = [string]$last.($spec[0]) }
            $dlg.Controls.Add($l); $dlg.Controls.Add($box); $fields[$spec[0]] = $box
            $y += 34
        }
        # the change system of the Settings tab is filled in every time
        if ($script:Config.ChangeSystem) { $fields['System'].Text = [string]$script:Config.ChangeSystem }
        $maint = $null
        if ($policy -eq 'Maintenance') {
            $maint = New-Object System.Windows.Forms.CheckBox
            $maint.Text = 'Maintenance activity - no change required'; $maint.AutoSize = $true
            if ($script:Gui['Tips']) { $script:Gui['Tips'].SetToolTip($maint, 'Recorded as MAINTENANCE: no change reference needed; the other fields marked * still are') }
            $maint.Location = New-Object System.Drawing.Point(270, ($y + 40)); $maint.Tag = $fields['Ref']
            $maint.Add_CheckedChanged({ $this.Tag.Enabled = -not $this.Checked })
            if ($last -and $last.Maintenance) { $maint.Checked = $true }
            $dlg.Controls.Add($maint)
        }
        $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = 'Record and continue'; Result = 'OK'; Width = 150 }, @{ Text = 'Cancel'; Result = 'Cancel' }) -Hint 'Cancel = nothing is changed'
        $dlg.AcceptButton = $null; $dlg.CancelButton = $bar.Buttons[1]   # Enter must not approve a change by accident
        $dlg.ActiveControl = $fields['Ref']
        $answer = $dlg.ShowDialog($script:Gui['Form'])
        $isMaint = ($maint -and $maint.Checked)
        $rec = New-ChangeRecord -Ref $fields['Ref'].Text -System $fields['System'].Text -ApprovedBy $fields['ApprovedBy'].Text -Window $fields['Window'].Text -Notes $fields['Notes'].Text -Maintenance:$isMaint
        $dlg.Dispose()
        if ($answer -ne 'OK') { Write-PatchLog "$Action cancelled at the change record - nothing was changed" 'WARN'; return $null }
        $gaps = @(Get-ChangeRecordGaps -Record $rec)
        if ($gaps.Count -gt 0) {
            $null = Show-PatcherMessage -Text ("Fill in before anything changes a server:`n`n{0}`n`n(Required fields are set on the Settings tab.)" -f ($gaps -join "`n")) -Title 'Change record incomplete' -Icon 'Warning'
            $last = $rec
            continue
        }
        if ($rec.Maintenance) { Write-PatchLog "$Action recorded as a MAINTENANCE activity (no change required) by $(Get-OperatorIdentity)" 'WARN' }
        $script:LastChangeRecord = $rec
        return $rec
    }
}
