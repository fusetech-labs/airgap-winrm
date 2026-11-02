# =====================================================================
#  Start-WinRMToolkit.ps1  -  THE ENTRY POINT  (PowerShell 5.1, WinForms)
# ---------------------------------------------------------------------
#  Sysadmin WinRM Toolkit: five consoles over one WinRM engine.
#    O/S Patching - patch status and installs (Windows + .NET updates), reboots, roles, software currency
#    Software     - third-party software: stage, install / update (reboot suppressed), remove
#    Health       - services, tasks, failed logons, dormant software, SOE standards
#    Security     - ISM audit with a security profile, tailoring and traffic lights
#  plus the Commands tab (one command on the ticked servers, with a cheat sheet), the Code Tour,
#  Settings (confirmations, change records, log, thresholds) and About tabs.
#
#  HOW TO RUN  (from this file - .ps1 execution must be allowed on the PC)
#    A) Normal:   right-click this file -> "Run with PowerShell", or
#                 powershell.exe -ExecutionPolicy Bypass -File .\Start-WinRMToolkit.ps1
#       Where the execution policy is AllSigned, or application control (AppLocker, WDAC and similar)
#       only trusts signed scripts, sign the scripts first: Sign-Toolkit.ps1 (README, "Code signing").
#    B) Functions only, no window (fault finding):  $NoGui = $true; . .\Start-WinRMToolkit.ps1
#
#  Run it as the user who is an administrator on the target servers; it never
#  elevates itself and every credential prompt appears in the foreground.
#  TRUST BOUNDARY: everything in this folder runs as YOU on EVERY server.  Keep the
#  folder writable only by the operators (not on an open share).
# =====================================================================
#Requires -Version 5.1
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  Start-WinRMToolkit.ps1
# ---------------------------------------------------------------------
#  Version 1 review (as Start-OfflinePatcher.ps1, see CODE-REVIEW.md): R-25, R-27, R-29, R-30, R-33.
#  Version 2: renamed; loads the new building blocks (09, 10, 20, 30, 40).  2026-10-19: the
#  old-name shim was removed.  2026-10-21: the all-in-one text and its paste mode were retired
#  (requirement dropped); the tool runs from its files only.  Later the same day: 12-Settings, the
#  Settings and About consoles, the saved settings applied at start-up, log retention, and the
#  ConstrainedLanguage message points at code signing (Sign-Toolkit.ps1).  2026-10-22: the Commands
#  console (80-Console-Commands.ps1).
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ______________________________   Date : ______________
#  Verdict    : [ ] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# 1. Language mode.  Application control (AppLocker / WDAC script rules and similar) runs a script it does not trust
#    in ConstrainedLanguage: no Add-Type, no WinForms, no .NET.  A script the policy trusts - signed with a certificate
#    it allows - runs in FullLanguage.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw "PowerShell is in $($ExecutionContext.SessionState.LanguageMode) mode: application control on this PC does not trust these scripts. This tool needs FullLanguage: sign every .ps1 with a certificate the policy trusts (Sign-Toolkit.ps1, README 'Code signing'), or run it from a PC that application control does not restrict."
}

# 2. Root folder = the folder this file is in.  $PSScriptRoot is empty only when the code does not come from a
#    file (pasted into a console), which is not supported.
if (-not $PSScriptRoot) { throw 'Run Start-WinRMToolkit.ps1 as a file: powershell.exe -File .\Start-WinRMToolkit.ps1 (or . .\Start-WinRMToolkit.ps1 after $NoGui = $true). Pasting the code into a console is not supported.' }
$script:RootFolder = $PSScriptRoot

# 3. Load the building blocks - an explicit list in load order; any other .ps1 in lib\ is reported, never run.
$script:LibFiles = @('01-Config.ps1', '02-Logging.ps1', '03-Groups.ps1', '04-Patches.ps1', '05-WinRM.ps1', '06-Install.ps1',
                     '07-Gui.ps1', '08-CodeTour.ps1', '09-Reports.ps1', '10-Checks.ps1', '11-ChangeLog.ps1', '12-Settings.ps1', '13-GroupPolicy.ps1',
                     '20-Console-Patching.ps1', '21-Patching-Analysis.ps1', '30-Console-Health.ps1', '40-Console-Security.ps1', '45-Security-Gpo.ps1', '46-Security-Compliance.ps1', '50-Console-Software.ps1',
                     '60-Console-Settings.ps1', '70-Console-About.ps1', '80-Console-Commands.ps1')
$libFolder = Join-Path $script:RootFolder 'lib'
if (-not (Test-Path -LiteralPath $libFolder)) {
    throw "Cannot find the 'lib' folder next to Start-WinRMToolkit.ps1 ('$script:RootFolder'). Copy the whole tool folder."
}
foreach ($name in $script:LibFiles) {
    $path = Join-Path $libFolder $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing building block: $path" }
    Write-Host "Loading $name" -ForegroundColor DarkGray
    . $path
}
$extra = @(Get-ChildItem -LiteralPath $libFolder -Filter '*.ps1' | Where-Object { $script:LibFiles -notcontains $_.Name })
foreach ($e in $extra) { Write-Host "NOT loaded (not part of the tool): lib\$($e.Name) - remove it or add it to the list in Start-WinRMToolkit.ps1" -ForegroundColor Yellow }

# 4. Hello (console + log file), the operator's settings over the defaults, then the window.
Write-Host $script:Banner -ForegroundColor Cyan
Write-PatchLog ("=== SESSION START by {0} on {1} (PID {2}, PowerShell {3}, {4} {5}) root {6} ===" -f (Get-OperatorIdentity), $env:COMPUTERNAME, $PID, $PSVersionTable.PSVersion, $script:Config.ToolName, $script:Config.ToolVersion, $script:RootFolder) 'INFO'
Import-ToolkitSettings
Remove-OldPatchLogs
if ($NoGui) {
    Write-Host 'NoGui mode: functions are loaded. Try  Get-PatchGroups ; Get-PatchFiles ; Get-ServerStatus -ComputerName SRV01' -ForegroundColor Yellow
} else {
    try {
        Show-ToolkitGui
    } finally {
        if ($script:Credential) { Clear-PatcherCredential }
    }
}
