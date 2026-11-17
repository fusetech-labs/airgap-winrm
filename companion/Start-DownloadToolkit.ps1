# =====================================================================
#  Start-DownloadToolkit.ps1  -  THE ENTRY POINT  (PowerShell 5.1, WinForms)
# ---------------------------------------------------------------------
#  Sysadmin Download Toolkit: the companion of the Sysadmin WinRM Toolkit for the side
#  that HAS internet.  It fetches the newest appropriate update of every product in
#  data\products.psd1 - Windows and .NET cumulative updates from the Microsoft Update
#  Catalog, VMware Tools from the VMware package site, any product with a fixed link -
#  checks every file (size, the catalogue's own hash, the Authenticode signature, a
#  SHA256 of its own) and keeps the library in the folders the WinRM toolkit reads:
#  patches\Windows, patches\DotNet and software\<package>.  Only the latest file of each
#  product stays (the Settings tab decides how many older ones).
#    Library     - what the library holds, what is newer, download, verify, prune, report
#    Products    - every product with its tick (fetched or left alone) and its source as a
#                  link to click; the installer links a person gives
#    Schedule    - this tool as a scheduled task: register, watch, run now
#    Settings    - what this site runs (the Windows builds, the .NET lines, the ESXi line, so
#                  the wrong update is never fetched), folders, limits, the task, the log
#    About       - version, support, the scripts' signatures
#
#  HOW TO RUN  (from this file - .ps1 execution must be allowed on the PC; an ordinary user account is enough:
#  nothing is installed, nothing asks for elevation)
#    A) Normal:     powershell.exe -ExecutionPolicy Bypass -File .\Start-DownloadToolkit.ps1
#    B) Unattended: powershell.exe -ExecutionPolicy Bypass -File .\Start-DownloadToolkit.ps1 -Unattended
#       (what the scheduled task runs: check every product, download what is missing, verify, prune,
#        write settings\last-run.json and a report; exit code 0 = nothing failed)
#    C) Functions only, no window (fault finding):  $NoGui = $true; . .\Start-DownloadToolkit.ps1
#    D) From text, where PowerShell refuses the file ("... is not digitally signed"), in a PowerShell window:
#         Set-Location '<this folder>'
#         . ([scriptblock]::Create((Get-Content -Raw .\Start-DownloadToolkit.ps1)))
#       The execution policy checks script FILES; text given to PowerShell at the prompt is not a file.  Started
#       this way the launcher reads its building blocks as text too, the log and the About tab say so, and a task
#       registered from that session starts the same way.  ($NoGui = $true first: the functions without the window.)
#       Look first whether the files only carry the "downloaded" mark - then this is enough, and A) works:
#         Get-ChildItem -Recurse -Filter *.ps1 | Unblock-File
#    E) Where PowerShell is in ConstrainedLanguage mode (application control) or scripts are blocked altogether,
#       this tool cannot run: open simple\Simple-Companion.html in a browser.  The simple companion keeps the
#       versions a site has deployed, links every product to the place it is published, and checks each file
#       fetched by hand - without PowerShell.
#
#  Beside the WinRM toolkit (this folder inside its folder) the library IS that toolkit's patches\ and
#  software\ folders.  Copied elsewhere, the library is library\ in this folder - carry it over.
#  TRUST BOUNDARY: the files this tool downloads are installed on servers by the WinRM toolkit.
#  Keep this folder writable only by the operators, and read the log after every run.
# =====================================================================
#Requires -Version 5.1
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
param([switch]$Unattended)

# 1. Language mode: WinForms and .NET need FullLanguage.  This tool runs as an ordinary user: it installs nothing, asks
#    for no elevation and signs nothing, so where application control restricts scripts the answer is another PC - or
#    the simple companion, which needs a browser and no PowerShell.
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    throw "PowerShell is in $($ExecutionContext.SessionState.LanguageMode) mode: application control on this PC does not trust these scripts, and the tool cannot work in that mode. Run it on a PC with internet access where application control does not restrict PowerShell scripts - or open simple\Simple-Companion.html in a browser: the simple companion is made for a PC like this one."
}

# 2. Root folder = the folder this file is in.  Started from text (HOW TO RUN, D) there is no file to ask: the current
#    folder must be the tool's own.
$script:StartedFromText = (-not $PSScriptRoot)
if ($script:StartedFromText) {
    $here = (Get-Location -PSProvider FileSystem).ProviderPath
    if (-not (Test-Path -LiteralPath (Join-Path $here 'Start-DownloadToolkit.ps1')) -or -not (Test-Path -LiteralPath (Join-Path $here 'lib\01-Config.ps1'))) {
        throw "Started from text, and the current folder ('$here') is not the tool's folder. Go there first - Set-Location '<the folder of Start-DownloadToolkit.ps1>' - and run the same line again."
    }
    $script:RootFolder = $here
} else {
    $script:RootFolder = $PSScriptRoot
}

# 3. Load the building blocks - an explicit list in load order; any other .ps1 in lib\ is reported, never run.
#    Started as a file, each is loaded as a file and the execution policy checks it.  Started from text, each is read
#    and run as text, as the launcher itself was: the same files, the same list, the same order.
$script:LibFiles = @('01-Config.ps1', '02-Logging.ps1', '03-Products.ps1', '04-Web.ps1', '05-Sources.ps1', '06-Library.ps1',
                     '07-Gui.ps1', '09-Reports.ps1', '10-Task.ps1', '12-Settings.ps1',
                     '20-Console-Library.ps1', '30-Console-Products.ps1', '40-Console-Schedule.ps1', '60-Console-Settings.ps1', '70-Console-About.ps1')
$libFolder = Join-Path $script:RootFolder 'lib'
if (-not (Test-Path -LiteralPath $libFolder)) { throw "Cannot find the 'lib' folder next to Start-DownloadToolkit.ps1 ('$script:RootFolder'). Copy the whole tool folder." }
foreach ($name in $script:LibFiles) {
    $path = Join-Path $libFolder $name
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing building block: $path" }
    Write-Host "Loading $name" -ForegroundColor DarkGray
    if ($script:StartedFromText) { . ([scriptblock]::Create([System.IO.File]::ReadAllText($path))) } else { . $path }
}
$extra = @(Get-ChildItem -LiteralPath $libFolder -Filter '*.ps1' | Where-Object { $script:LibFiles -notcontains $_.Name })
foreach ($e in $extra) { Write-Host "NOT loaded (not part of the tool): lib\$($e.Name) - remove it or add it to the list in Start-DownloadToolkit.ps1" -ForegroundColor Yellow }

# 4. Hello (console + log file), the operator's settings and environment over the defaults, then the window or the run.
Write-Host $script:Banner -ForegroundColor Cyan
Write-PatchLog ("=== SESSION START by {0} on {1} (PID {2}, PowerShell {3}, {4} {5}{6}) root {7} ===" -f (Get-OperatorIdentity), $env:COMPUTERNAME, $PID, $PSVersionTable.PSVersion, $script:Config.ToolName, $script:Config.ToolVersion, $(if ($Unattended) { ', unattended' } else { '' }), $script:RootFolder) 'INFO'
if ($script:StartedFromText) { Write-PatchLog ("STARTED FROM TEXT: the launcher and its {0} building blocks were read from their files and run as text, which the execution policy ({1} in effect) does not check" -f $script:LibFiles.Count, (Get-ExecutionPolicy)) 'WARN' }
Import-ToolkitSettings
Import-Environment
Remove-OldPatchLogs
Write-PatchLog ("Library folder: {0}  ({1})" -f $script:Config.LibraryFolder, (Get-LibraryPlaceText)) 'INFO'
if ($Unattended) {
    $run = Invoke-LibraryRun -Unattended
    Write-PatchLog ("=== UNATTENDED RUN {0}: {1} ===" -f $run.Outcome, $run.Summary) $(if ($run.ExitCode -eq 0) { 'OK' } else { 'ERROR' })
    if ($MyInvocation.InvocationName -ne '.') { exit $run.ExitCode }
} elseif ($NoGui) {
    Write-Host 'NoGui mode: functions are loaded. Try  Get-LibraryRows ; Get-ProductCandidates -Product (Get-Product VMwareTools) ; Invoke-LibraryRun' -ForegroundColor Yellow
} else {
    Show-ToolkitGui
}
