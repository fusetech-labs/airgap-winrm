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
#    C) On a server the hub cannot reach over WinRM (lib\14-State.ps1):
#         -SelfCheck [-ResultsFolder <folder>] [-Only Status,Health]   no window: every collector runs on this
#               computer and ONE results file, <computer>.xml, is written for the hub (exit code 0 = all answered)
#         -Spoke [-HubFolder <folder>] [-ResultsFolder <folder>]       the window, working on this computer only,
#               with the hub's patches\ and software\ and its results file where the hub reads it (asked at start)
#       The hub writes such a copy, ready to carry: "Copy for a server" on its O/S Patching toolbar
#       (one state\server-copies\<server>-local-winrm\ per marked server).
#       That copy starts as the spoke by itself (settings\spoke.json marks it): a plain start is enough there.
#
#  Run it as the user who is an administrator on the target servers; it never
#  elevates itself and every credential prompt appears in the foreground.
#  TRUST BOUNDARY: everything in this folder runs as YOU on EVERY server.  Keep the
#  folder writable only by the operators (not on an open share).
# =====================================================================
#Requires -Version 5.1
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
param(
    [switch]$SelfCheck,            # no window: the self-check of this computer, one results file (14-State.ps1)
    [switch]$Spoke,                # the window on a server the hub cannot reach: this computer only, the hub's folders
    [string]$HubFolder = '',       # -Spoke: the hub's toolkit folder (a share or a copy, holding patches\ and software\); asked for when empty
    [string]$ResultsFolder = '',   # -SelfCheck / -Spoke: where the results file goes (the hub's state\servers share); empty = state\servers here
    [string[]]$Only = @()          # -SelfCheck: only these collectors (a quick trial: -Only Status)
)

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
$script:SpokeMode = [bool]$Spoke   # read by Get-PatchGroups (this computer is the only server) and the window title

# 3. Load the building blocks - an explicit list in load order; any other .ps1 in lib\ is reported, never run.
$script:LibFiles = @('01-Config.ps1', '02-Logging.ps1', '03-Groups.ps1', '04-Patches.ps1', '05-WinRM.ps1', '06-Install.ps1',
                     '07-Gui.ps1', '08-CodeTour.ps1', '09-Reports.ps1', '10-Checks.ps1', '11-ChangeLog.ps1', '12-Settings.ps1', '13-GroupPolicy.ps1', '14-State.ps1',
                     '20-Console-Patching.ps1', '21-Patching-Analysis.ps1', '30-Console-Health.ps1', '31-Health-Scripts.ps1', '40-Console-Security.ps1', '45-Security-Gpo.ps1', '46-Security-Compliance.ps1', '47-Licensing.ps1', '50-Console-Software.ps1',
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
# A copy for a server (written by "Copy for a server" on the hub; settings\spoke.json says so) starts as the spoke by
# itself, so a plain start - a double-click - is enough on the server.  -SelfCheck and $NoGui are what they are.
if (-not $Spoke -and -not $SelfCheck -and -not $NoGui -and (Test-ServerCopyFolder)) {
    $Spoke = $true; $script:SpokeMode = $true
    Write-PatchLog 'This folder is a copy for a server (settings\spoke.json): starting as the spoke - this computer only, the hub''s patches and software' 'INFO'
}
if ($SelfCheck) {
    # 5a. The self-check (no window): every collector on this computer, one results file, the exit code for a scheduled task.
    # A copy for a server carries the results folder the hub baked in (settings\spoke.json): used unless one was typed
    $selfArgs = @{ Only = $Only }
    if ($PSBoundParameters.ContainsKey('ResultsFolder') -and $ResultsFolder) { $selfArgs['ResultsFolder'] = $ResultsFolder }
    else { $savedSpoke = Read-SpokeSettings; if ($savedSpoke.ResultsFolder) { $selfArgs['ResultsFolder'] = $savedSpoke.ResultsFolder } }
    $outcome = Invoke-SelfCheck @selfArgs
    foreach ($st in @($outcome.Steps)) { Write-Host ("  {0,-15} {1}" -f $st.Collector, $(if ($st.Ok) { 'ok  ({0} s)' -f $st.Seconds } else { 'FAILED - ' + $st.Error })) -ForegroundColor $(if ($st.Ok) { 'Green' } else { 'Red' }) }
    Write-Host ("Self-check of {0}: {1}" -f $outcome.Computer, $(if ($outcome.Ok) { 'every collector answered; results file ' + $outcome.File } elseif ($outcome.Written) { 'results file written (' + $outcome.File + ') but a collector failed - see the log' } else { 'the results file was NOT written - see the log' })) -ForegroundColor $(if ($outcome.Ok) { 'Green' } else { 'Yellow' })
    if ($outcome.Ok) { exit 0 } elseif ($outcome.Written) { exit 1 } else { exit 3 }
}
if ($Spoke -and -not $NoGui) {
    # 5b. The spoke: the hub's folders and the results folder, asked for (the saved answers offered) before the window opens
    # -ResultsFolder goes through only when the operator typed it: an empty one would hide the saved answer (the copy's
    # results folder did not come across on the server, field finding 2026-11-06)
    $spokeArgs = @{ HubFolder = $HubFolder }
    if ($PSBoundParameters.ContainsKey('ResultsFolder')) { $spokeArgs['ResultsFolder'] = $ResultsFolder }
    if (-not (Initialize-SpokeMode @spokeArgs)) { Write-Host 'Spoke start cancelled.' -ForegroundColor Yellow; return }
}
if ($NoGui) {
    Write-Host 'NoGui mode: functions are loaded. Try  Get-PatchGroups ; Get-PatchFiles ; Get-ServerStatus -ComputerName SRV01' -ForegroundColor Yellow
} else {
    try {
        Show-ToolkitGui
    } finally {
        if ($script:Credential) { Clear-PatcherCredential }
    }
}
