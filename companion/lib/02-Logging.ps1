# =====================================================================
#  02-Logging.ps1  -  ONE FUNCTION THAT WRITES EVERYWHERE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Every message goes to three places so nothing is ever lost:
#    1. logs\Download-YYYYMMDD.log  (permanent record, open it in Notepad)
#    2. the PowerShell console       (colour coded, stays open behind the GUI)
#    3. the log box inside the GUI   (once the GUI exists)
#  Levels:  INFO  OK  WARN  ERROR  CMD (the exact request or command)  WHY (the reasoning)
#  The same function names as the WinRM toolkit, so an operator who knows one knows both.
# =====================================================================

function Get-OperatorIdentity {
    $who = $script:Operator
    if (-not $who) { $who = "$env:USERDOMAIN\$env:USERNAME" }
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
        if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null }
        Add-Content -LiteralPath (Get-PatchLogPath) -Value $line -ErrorAction Stop
    } catch {
        Write-Host "Could not write to log file: $($_.Exception.Message)" -ForegroundColor Red
        if (-not $script:LogFileBroken) { $script:LogFileBroken = ('LOG FILE NOT WRITTEN ({0}): {1} - the window and the console still show every line; fix the folder and start the tool again' -f (Get-PatchLogPath), $_.Exception.Message) }
    }

    # 2. Console
    $consoleColour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'CMD' { 'Cyan' } 'WHY' { 'DarkGray' } default { 'White' } }
    Write-Host $line -ForegroundColor $consoleColour

    # 3. GUI log box (only if the GUI has been built and is still open)
    $box = $script:Gui['LogBox']
    $hidden = ($Level -eq 'CMD' -and $script:Config.LogShowCmd -eq $false) -or ($Level -eq 'WHY' -and $script:Config.LogShowWhy -eq $false)
    if ($box -and -not $box.IsDisposed -and -not $hidden) {
        $guiColour = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'DarkOrange' } 'ERROR' { 'Red' } 'CMD' { 'RoyalBlue' } 'WHY' { 'Gray' } default { 'Black' } }
        if ($box.TextLength -gt [int]$script:Config.MaxLogBoxChars) { $box.Select(0, [int]($box.TextLength / 2)); $box.SelectedText = "... (older lines dropped from the window; the log file has them all)`r`n" }
        $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0
        $box.SelectionColor = [System.Drawing.Color]::FromName($guiColour)
        $box.AppendText($line + "`r`n")
        if ($script:LogFileBroken -and -not $script:LogFileBrokenShown) {
            $script:LogFileBrokenShown = $true
            $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0; $box.SelectionColor = [System.Drawing.Color]::Red
            $box.AppendText($script:LogFileBroken + "`r`n")
        }
        $box.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    } elseif ($null -eq $box -and $Level -in 'WARN', 'ERROR') {
        $script:PreGuiLines += , @($Level, $line)
    }
}

function Get-PatchLogPath {
    return (Join-Path $script:Config.LogFolder ('Download-{0}.log' -f (Get-Date -Format 'yyyyMMdd')))
}

function Remove-OldPatchLogs {
    # LogKeepDays (Settings tab): the tool's own log files last written longer ago than that are deleted.  0 = every log file is kept.
    $days = [int]$script:Config.LogKeepDays
    if ($days -le 0 -or -not (Test-Path -LiteralPath $script:Config.LogFolder)) { return }
    $cut = (Get-Date).Date.AddDays(-$days)
    $old = @(Get-ChildItem -LiteralPath $script:Config.LogFolder -Filter 'Download-*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^Download-\d{8}\.log$' -and $_.LastWriteTime -lt $cut })
    if ($old.Count -eq 0) { return }
    $removed = 0; $kept = @()
    foreach ($f in $old) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch { $kept += $f.Name } }
    Write-PatchLog ("Removed {0} of {1} log file(s) last written before {2} (LogKeepDays = {3}){4}" -f $removed, $old.Count, $cut.ToString('yyyy-MM-dd'), $days, $(if ($kept.Count -gt 0) { '; could not remove: ' + ($kept -join ', ') } else { '' })) $(if ($kept.Count -gt 0) { 'WARN' } else { 'INFO' })
}

function Get-ShortError {
    # The exception message in full, on ONE line, so the log stays easy to read and grep.  A .NET call that throws
    # arrives wrapped ('Exception calling "Read" with "3" argument(s): ...'): the message inside is the one to show.
    param($ErrorRecord)
    $msg = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $shown = $ErrorRecord.Exception
        if ($shown -is [System.Management.Automation.MethodInvocationException] -and $shown.InnerException) { $shown = $shown.InnerException }
        $msg = $shown.Message
    }
    elseif ($ErrorRecord -is [System.Exception]) { $msg = $ErrorRecord.Message }
    else { $msg = [string]$ErrorRecord }
    $lines = @($msg -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ($lines -join ' | ')
}

function Get-ErrorLocation {
    param($ErrorRecord)
    if ($ErrorRecord.ScriptStackTrace) { return (($ErrorRecord.ScriptStackTrace -split "`r?`n")[0] -replace '^at ', '') }
    return ''
}

function Get-UniqueNames {
    # Case-insensitive de-duplication that keeps the original order.
    param([string[]]$Names)
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $out = @()
    foreach ($n in @($Names)) { if (-not $n) { continue }; $t = $n.Trim(); if ($t -and $seen.Add($t)) { $out += $t } }
    return $out
}

function Format-ByteSize {
    # 612997918 -> "584.6 MB"
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int64]$Bytes)
}
