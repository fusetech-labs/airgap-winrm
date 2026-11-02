# =====================================================================
#  02-Logging.ps1  -  ONE FUNCTION THAT WRITES EVERYWHERE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Every message goes to three places so nothing is ever lost:
#    1. logs\Patcher-YYYYMMDD.log   (permanent record, open it in Notepad)
#    2. the PowerShell console       (colour coded, stays open behind the GUI)
#    3. the log box inside the GUI   (once the GUI exists)
#
#  Levels:  INFO  = normal chatter        OK    = something succeeded
#           WARN  = look at this          ERROR = something failed
#           CMD   = the exact command we are about to run (copy/paste it to
#                   reproduce by hand)   WHY   = explains the reasoning
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  02-Logging.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (see CODE-REVIEW.md).  Changed here:
#  R-18 audit trail - Get-OperatorIdentity is stamped on the session
#  header, every INSTALL / CONFIRM / RESULT / REBOOT line and the event
#  written on the target server.  No password or token is ever logged.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ____CF__________________________   Date : ___30-10-2026___________
#  Verdict    : [X] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

function Get-OperatorIdentity {
    # "CORP\operator" or "CORP\operator (WinRM as CORP\svc-patching)" when alternate credentials are set.
    $who = $script:Operator
    if (-not $who) { $who = "$env:USERDOMAIN\$env:USERNAME" }
    if ($script:Credential -and $script:Credential.UserName -ne $who) { $who += " (WinRM as $($script:Credential.UserName))" }
    return $who
}

function Write-PatchLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'CMD', 'WHY')][string]$Level = 'INFO'
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    # 1. File (the folder is created on first use)
    try {
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) {
            New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null
        }
        Add-Content -LiteralPath (Get-PatchLogPath) -Value $line -ErrorAction Stop   # -LiteralPath: the root folder may hold [ ]
    } catch {
        Write-Host "Could not write to log file: $($_.Exception.Message)" -ForegroundColor Red
        # said once in the window too (below): an audit log that is not being written must not look normal there
        if (-not $script:LogFileBroken) { $script:LogFileBroken = ('LOG FILE NOT WRITTEN ({0}): {1} - the window and the console still show every line; fix the folder and start the tool again' -f (Get-PatchLogPath), $_.Exception.Message) }
    }

    # 2. Console
    $consoleColour = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'CMD'   { 'Cyan' }
        'WHY'   { 'DarkGray' }
        default { 'White' }
    }
    Write-Host $line -ForegroundColor $consoleColour

    # 3. GUI log box (only if the GUI has been built and is still open).  The Settings tab may leave the command (CMD)
    #    and reasoning (WHY) lines out of the window; the file and the console above always have every line.
    $box = $script:Gui['LogBox']
    $hidden = ($Level -eq 'CMD' -and $script:Config.LogShowCmd -eq $false) -or ($Level -eq 'WHY' -and $script:Config.LogShowWhy -eq $false)
    if ($box -and -not $box.IsDisposed -and -not $hidden) {
        $guiColour = switch ($Level) {
            'OK'    { 'Green' }
            'WARN'  { 'DarkOrange' }
            'ERROR' { 'Red' }
            'CMD'   { 'RoyalBlue' }
            'WHY'   { 'Gray' }
            default { 'Black' }
        }
        # a long run on a big fleet must not slow the window down: past the cap the older half of the text is dropped
        if ($box.TextLength -gt [int]$script:Config.MaxLogBoxChars) { $box.Select(0, [int]($box.TextLength / 2)); $box.SelectedText = "... (older lines dropped from the window; the log file has them all)`r`n" }
        $box.SelectionStart  = $box.TextLength
        $box.SelectionLength = 0
        $box.SelectionColor  = [System.Drawing.Color]::FromName($guiColour)
        $box.AppendText($line + "`r`n")
        if ($script:LogFileBroken -and -not $script:LogFileBrokenShown) {
            $script:LogFileBrokenShown = $true
            $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0; $box.SelectionColor = [System.Drawing.Color]::Red
            $box.AppendText($script:LogFileBroken + "`r`n")
        }
        $box.ScrollToCaret()
        # Let the window repaint so the operator sees progress while we are busy.
        [System.Windows.Forms.Application]::DoEvents()
    } elseif ($null -eq $box -and $Level -in 'WARN', 'ERROR') {
        # before the window exists (settings.json problems, a safeguard switched off at start-up): kept, and replayed into
        # the log box as soon as Show-ToolkitGui has built it - the console window is often behind or minimised
        $script:PreGuiLines += , @($Level, $line)
    }
}

function Get-PatchLogPath {
    # Today's log file, e.g. logs\Patcher-20261013.log
    return (Join-Path $script:Config.LogFolder ('Patcher-{0}.log' -f (Get-Date -Format 'yyyyMMdd')))
}

function Remove-OldPatchLogs {
    # LogKeepDays (Settings tab): at start-up the tool's own log files (Patcher-yyyyMMdd.log) last written longer ago
    # than that are deleted.  0 = every log file is kept.  Nothing else in the folder is touched.
    $days = [int]$script:Config.LogKeepDays
    if ($days -le 0 -or -not (Test-Path -LiteralPath $script:Config.LogFolder)) { return }
    $cut = (Get-Date).Date.AddDays(-$days)
    $old = @(Get-ChildItem -LiteralPath $script:Config.LogFolder -Filter 'Patcher-*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Patcher-\d{8}\.log$' -and $_.LastWriteTime -lt $cut })
    if ($old.Count -eq 0) { return }
    $removed = 0; $kept = @()
    foreach ($f in $old) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch { $kept += $f.Name } }
    Write-PatchLog ("Removed {0} of {1} log file(s) last written before {2} (LogKeepDays = {3}, Settings tab){4}" -f $removed, $old.Count, $cut.ToString('yyyy-MM-dd'), $days, $(if ($kept.Count -gt 0) { '; could not remove: ' + ($kept -join ', ') } else { '' })) $(if ($kept.Count -gt 0) { 'WARN' } else { 'INFO' })
}
