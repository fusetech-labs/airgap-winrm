# =====================================================================
#  01-Config.ps1  -  SETTINGS AND SHARED STATE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Everything an operator might want to tweak lives in $script:Config.
#  These are the defaults: the Settings tab saves the operator's changes
#  in settings\settings.json and lib\12-Settings.ps1 lays them over the
#  defaults at start-up.
#  Everything the tool remembers while it runs (credentials, last known
#  server status, loaded lists) lives in the other $script: variables
#  below.  From the console you can inspect any of them at any time,
#  for example:   $Config        $ServerStatus        $Patches
#
#  NOTE: "$script:" simply means "a variable shared by all the files of
#  this tool".  When the launcher is dot-sourced in a console ($NoGui)
#  it is the same as a normal global variable.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  01-Config.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (see CODE-REVIEW.md).  Changed here:
#  new settings RequireValidSignature and AllowUnknownTargetBuild (R-09,
#  R-11); $script:Operator for the audit trail (R-18).  R-25 (a second
#  Invoke-Expression run in the same console kept the OLD root folder) was
#  fixed in the all-in-one header, retired 2026-10-21 with the paste mode.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : __CF____________________________   Date : ___30-10-2026___________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# The launcher sets $script:RootFolder before loading this file.
# If somebody loads this file on its own, fall back to the current folder.
if (-not $script:RootFolder) { $script:RootFolder = (Get-Location).Path }

$script:Config = @{
    # ---- Identity ----
    ToolName       = 'Sysadmin WinRM Toolkit'   # banner, window title, reports
    ToolVersion    = '2.2'
    SourceUrl      = 'https://github.com/fusetech-labs/airgap-winrm'   # the About tab shows it to copy; the tool never opens it
    Author         = 'Chris Fryer'                       # the About tab
    SupportEmail   = 'products@fusetech.com.au'          # the About tab shows it to copy; the tool sends no mail
    Website        = 'https://fusetech.com.au'           # the publisher's site, shown on the About tab; the tool never opens it

    # ---- Folders (relative to the root folder = where the launcher lives) ----
    PatchFolder    = Join-Path $script:RootFolder 'patches'   # one sub-folder per patch type (see PatchTypes)
    PatchInfoFolder = Join-Path $script:RootFolder 'patches\_info'   # cache: which build each file targets
    SoftwareInfoFolder = Join-Path $script:RootFolder 'software\_info'   # a spoke's own vetting cache (the hub's is read, never written)
    LogFolder      = $(if ($script:LogFolderOverride) { $script:LogFolderOverride } else { Join-Path $script:RootFolder 'logs' })   # one log file per day ($script:LogFolderOverride, when set before this loads, wins)
    ReportFolder   = Join-Path $script:RootFolder 'reports'   # HTML + CSV reports (git-ignored: host names)
    DataFolder     = Join-Path $script:RootFolder 'data'      # shipped catalogues (*.psd1), refreshed offline
    SoeFolder      = Join-Path $script:RootFolder 'soe'       # SOE standards (*.json), written by the tool
    SecurityFolder = Join-Path $script:RootFolder 'security'  # profile.json + tailoring.json
    SoftwareFolder = Join-Path $script:RootFolder 'software'  # one sub-folder per package of data\software-packages.psd1 (installers)
    ChangeLogFolder = Join-Path $script:RootFolder 'changes'  # change-log.csv: the change record of every install, removal and reboot (git-ignored)
    StateFolder    = Join-Path $script:RootFolder 'state\servers'   # one <server>.xml per server: the last result of every collector (14-State.ps1; git-ignored: host names, accounts, findings)
    SettingsFile   = $(if ($script:SettingsFileOverride) { $script:SettingsFileOverride } else { Join-Path $script:RootFolder 'settings\settings.json' })   # what the Settings tab saved (git-ignored); $script:SettingsFileOverride, when set before this loads, wins
    DefaultSoeStandard = 'default'   # soe\default.json applies to every group without a "# soe: <name>" line in its file

    # ---- Patch types = sub-folders of patches\.  'install' = the tool installs them (MSU/CAB via DISM),
    #      'report' = the tool only reports the installed level and the file is applied by hand. ----
    PatchTypes     = [ordered]@{ Windows = 'install'; DotNet = 'install'; SQL = 'report'; Exchange = 'report'; Other = 'report' }

    # ---- Console colours (tab header + banner) and the names shown for them (the key is used inside the tool) ----
    ConsoleColours = @{ Patching = 'MidnightBlue'; Software = 'DarkCyan'; Health = 'DarkGreen'; Security = 'DarkRed'; Commands = 'Black';     Tour = 'DimGray'; Settings = 'DarkSlateGray'; About = 'SteelBlue' }
    ConsoleText    = @{ Patching = 'Gold';         Software = 'White';    Health = 'White';     Security = 'Gold';    Commands = 'LimeGreen'; Tour = 'White';   Settings = 'White';         About = 'White' }
    ConsoleNames   = @{ Patching = 'O/S Patching'; Tour = 'Code Tour' }   # any console not listed is shown by its key
    BrandColour    = 'DodgerBlue'   # the Fusetech blue of the logo's F: the frame round the window, the window icon and the favicon of every HTML page

    # =================================================================
    #  Most values below are DEFAULTS that the Settings tab can change (the list is $script:SettingSpecs in
    #  lib\12-Settings.ps1); what is saved there (settings\settings.json) is laid over them at start-up.
    # =================================================================

    # ---- Before any change: the pre-action confirmations (Confirm-SafetyChecks), asked in this order before every OS
    #      patch install, software install / update and removal.  Each must be answered Yes or nothing changes.
    #      Enabled = $false = not asked (the product is not used here). ----
    SafetyChecks = @(
        [pscustomobject]@{ Name = 'VMware snapshot'; Enabled = $true; Question = 'Has a VMware SNAPSHOT been taken of every server below?'; IfNo = 'Take the snapshots first, then come back.' }
        [pscustomobject]@{ Name = 'Trellix Solidcore Update Mode'; Enabled = $true; Question = 'Is TRELLIX SOLIDCORE in UPDATE MODE on every server below, and will it still be when they reboot? (The Solidcore column shows what each server says.)'; IfNo = 'Run the Solidcore Update Mode task first (the status check shows the mode), then come back.' }
        [pscustomobject]@{ Name = 'Airlock'; Enabled = $false; Question = 'Does AIRLOCK allow this change on every server below (the installers trusted, or the server temporarily in audit mode)?'; IfNo = 'Allow the change in Airlock first, then come back.' }
    )

    # ---- Change records (lib\11-ChangeLog.ps1) ----
    ChangeSystem         = ''      # the change management system written into every change record ('' = typed or picked each time)
    ChangeSystems        = @('Jira', 'ServiceNow', 'Cherwell', 'Ivanti', 'Other')   # offered in the change record form
    ChangeRequiredFields = @('Ref')   # what must be filled in before anything changes a server: Ref (the change reference), ApprovedBy, Window, Notes
    # per action: Required = a change record; Maintenance = a change record, or ticked as a maintenance activity that needs
    # no change; NotRecorded = no form and no change-log row (the running log still has every step)
    ChangePolicy         = [ordered]@{ 'OS patch install' = 'Required'; 'OS patch stage' = 'NotRecorded'; 'Reboot' = 'Required'; 'Software install / update' = 'Required'; 'Software removal' = 'Required'; 'Software stage' = 'NotRecorded'; 'Trellix Agent services' = 'Maintenance'; 'Command (may change)' = 'Required' }

    # ---- The running log (bottom of the window) and the log files ----
    LogShowCmd           = $true   # the window shows the command lines (CMD); the log file always has them
    LogShowWhy           = $true   # ... and the reasoning lines (WHY)
    LogKeepDays          = 0       # log files older than this many days are deleted at start-up; 0 = every log file is kept

    # ---- Saved results (lib\14-State.ps1): every collector's last result per server, kept in state\servers\ and loaded
    #      at the next start, so every console shows what it knew; the "Last checked" cell says how old that is ----
    KeepResults          = $true   # off = nothing is written to state\ (the window forgets everything when it closes)
    ResultFreshDays      = 1       # "Last checked" is green when the result is at most this many days old ...
    ResultStaleDays      = 3       # ... amber up to this many days, red beyond
    ResultsKeepDays      = 180     # a saved results file not written for this many days is deleted at start-up (0 = keep every file)

    # ---- Software deployment (lib\50-Console-Software.ps1) ----
    SoftwareTimeoutMin  = 45       # an installer still running after this long is reported UNKNOWN (it keeps running on the server)
    MaxSoftwareColumns  = 6        # a big library: the Software console shows at most this many packages - as grid columns and in the
                                   # installer list; the Software library window picks which, and an "All packages" column counts the rest
    SoftwarePollSec     = 15       # how often a running install / removal is asked for its state

    # ---- The Commands console (lib\80-Console-Commands.ps1) ----
    CommandTimeoutSec   = 120      # a command still running after this long is stopped (per wave of MaxParallel servers)
    CommandMaxOutputKB  = 256      # each server's answer is cut at this size
    CommandAskSafety    = $false   # a command that may change a server always asks for a change record and a confirmation;
                                   # $true = the pre-action confirmations (VMware snapshot ...) as well

    # ---- Health thresholds ----
    DiskWarnPercent      = 10      # free space below this percent = Warn
    DiskFailGB           = 5       # free space below this many GB, when also below DiskWarnPercent = Fail (a volume
                                   # that cannot hold the GB is judged by its percentage; a large one is not red while it still holds the GB)
    DiskSmallVolumeGB    = 2       # a volume smaller than this (a recovery or system partition given a letter) is listed, not judged
    UptimeWarnDays       = 60
    EventErrorWarn       = 50      # System + Application errors in the window
    EventWindowHours     = 24
    LogonFailWindowHours = 24      # failed logons (4625) looked at over this window
    LogonFailWarn        = 10      # from one source
    LogonFailFail        = 50
    MaxEvents            = 5000    # cap per event query so a busy server cannot stall the check
    TaskFailDays         = 7       # scheduled task failures within this many days count
    ScriptSearchFolders  = @()     # Scripts and tasks (Health): the folders walked for .ps1 / .psm1 files; empty = every fixed drive
    ScriptSearchSkip     = @('Windows', 'Windows.old', 'Program Files', 'Program Files (x86)', 'ProgramData\Microsoft', 'ProgramData\Package Cache', '$Recycle.Bin', 'System Volume Information', 'AppData', 'WindowsApps', 'Documents\WindowsPowerShell\Modules', 'Documents\PowerShell\Modules', '.vscode', 'node_modules', '.git')   # folder names or path parts never entered: vendor modules (the profiles' module folders too), caches, the profiles' app data
    ScriptSearchSeconds  = 60      # the walk stops here, per server (each script is analysed as it is found); the result then says PARTIAL and what was left
    DormantMonths        = 12      # software installed longer ago than this, with nothing using it
    UnknownStaleMonths   = 6       # a product NOT in known-apps.psd1, installed longer ago than this: updates are likely waiting (Stale)
    UnknownAgeingMonths  = 12      # ... and longer ago than this: probably unmaintained or unsupported, a cessation risk (Ageing)
    CertExpiryDays       = 30
    TimeOffsetFailSec    = 5
    MemoryWarnPercent    = 10      # free physical memory below this percent = Warn
    MemoryFailPercent    = 3       # ... below this percent = Fail
    CpuWarnPercent       = 80      # processor busy at or above this percent (averaged over CpuSampleSeconds) = Warn
    CpuFailPercent       = 95      # ... at or above this percent = Fail
    CpuSampleSeconds     = 3       # the Health check reads the processor load once a second for this many seconds
    GpoStaleHours        = 24      # Group Policy not refreshed for longer than this = Warn (H-GPO-02), 7 x this = Fail
    # Hardware fit for patching (H-HW-01): below any of these = Warn.  Microsoft's minimum installs Windows; it does not
    # patch it in a sensible time (field test 2026-11: 2 vCPU / 4 GB on a 2 GHz host spent the window at 100% processor)
    MinLogicalProcessors = 4       # logical processors (vCPUs) a server should have
    MinMemoryGB          = 8       # physical memory in GB
    MinCpuScore          = 6       # the one-thread speed score the Health collector measures (million integers sorted a second,
                                   # about one second of one processor): a 3.2 GHz Xeon E5 v4 core scores about 12, a 2 GHz
                                   # core on a busy host well under 6.  0 = the score is shown but not judged
    MaxRsopSettings      = 3000    # cap on the administrative-template settings read from a server's Resultant Set of Policy

    # ---- Security console: GPO recommendations (lib\45-Security-Gpo.ps1) ----
    ImpactDays           = 30      # the impact checks look this far back in the event logs (SMB1 clients, NTLMv1 logons ...)

    MaxProducts          = 500     # inventory cap per server
    MaxSoftwareGridRows  = 1500    # the O/S Patching software grid shows at most this many rows (0.5 ms a row to draw; big fleets: tick fewer servers)
    MaxConfigColumns     = 25      # the Security "Server config" page compares at most this many servers side by side
    MaxReportRowsPerSection = 5000 # an HTML report table longer than this is cut (the CSV keeps every row) so a browser still opens it
    MaxLogBoxChars       = 1500000 # the log window keeps about this much text; older lines drop off (the log file keeps everything)

    # ---- WinRM ----
    WinRMPort      = 5985        # the HTTP listener. 5986 = WinRM over HTTPS: every call then goes with -UseSSL and the server's certificate is checked (README, Requirements)
    OpenTimeoutSec = 20          # give up on a silent server after this many seconds
    MaxParallel    = 16          # how many servers are checked at the same time
    SilentServerSec = 180        # a read-only check gives up on a server that has not answered this many seconds after its turn began (a check with a limit of its own - Impact, Analysis, Commands - uses that instead)
                                 # (it shows as unreachable with that reason, the other servers carry on); never applied to an install
                                 # or to a command that may change a server.  Settings tab.

    # ---- Remote staging (on the target server) ----
    RemoteStaging  = 'C:\PatchStaging'   # patch files are copied here before install
    CleanupStaging = $true               # delete the copied file after a successful install
    ProgressEverySec = 45                # while DISM runs, read CBS.log progress this often (one summary line)
    ProgressDetailEveryMin = 5           # ... and one line PER SERVER this often (always, when 3 servers or fewer)
    InstallTimeoutMin = 120              # stop watching an install after this long (it carries on as a task on the server; a status check records it)
    AutoCheckInstalls = $true            # after PATCH IT!: keep asking the servers until they finish (the box on the O/S Patching tab; untick to come back later)

    # ---- Safety thresholds ----
    MinFreeGB      = 5           # refuse to install when C: has less free space than this
    WarnFreeGB     = 10          # show a warning colour below this
    TreatPendingFileRenameAsReboot = $false  # PendingFileRenameOperations is noisy; off by default
    RequireSolidcoreUpdateMode = $true   # Trellix Solidcore on a server must say Update (or Disabled) now AND on reboot, else installs and reboots are blocked
    OnePatchPerRun = $true               # one patch per server per run; the next one waits for the reboot (a second package on top of a 3010 failed in the field)
    StopTrellixAgentForInstall = $false   # the box on the O/S Patching and Software tabs starts unticked (owner's choice 2026-11-06; tick it where the agent blocks installs); ticked, the two Trellix Agent services (masvc, macmnsvc) are set to
                                         # Disabled and stopped on each server before an install (the field test found the install only completes without them);
                                         # "Start Trellix Agent (ticked)" sets them to Automatic and starts them again after the reboot
    TrellixInUse = $true                 # Trellix runs on these servers: the Solidcore and Trellix Agent columns, the agent boxes and buttons, the agent
                                         # warnings and the Trellix pre-action confirmation.  Off (Settings tab) where Trellix is not used: all of
                                         # those go.  The Solidcore guard stays - it acts only where Solidcore is found on a server
    AnalysisHoursBack = 72              # "Analyse a failure" reads the server's logs this far back

    # ---- Fun ----
    OperatorName   = 'sys-admin'   # shown in the window title, the banner, the welcome line and a quip
                                   # ("<name>'s Patch Palace") - put the operator's first name here

    # =================================================================
    #  Not on the Settings tab (changed here by hand only): the integrity guards below, the WinRM port and
    #  timeouts, the folders, the query windows and intervals (LogonFailWindowHours, MaxEvents, SoftwarePollSec,
    #  ProgressEverySec, ProgressDetailEveryMin, MaxRsopSettings, AnalysisHoursBack), DefaultSoeStandard and the fleet caps above.
    # =================================================================
    RequireValidSignature  = $true    # a patch must be Authenticode-signed by Microsoft (checked here AND on the server)
    AllowUnknownTargetBuild = $false  # a file whose target build cannot be read is blocked (cannot tell 2019 from 2022)
}

# ---- Shared runtime state (filled in while the tool runs) ----
$script:Operator     = "$env:USERDOMAIN\$env:USERNAME"   # who is running the tool - goes into every audit line
$script:Credential   = $null   # PSCredential entered by the operator (kept in memory only, cleared when the GUI closes)
$script:Results      = @{}     # collector name -> hashtable (server name -> last result object).  See Invoke-Collector.
$script:Results['Status'] = @{}
$script:ServerStatus = $script:Results['Status']   # the O/S Patching console's view of the Status collector (same hashtable)
$script:Groups       = @()     # output of Get-PatchGroups
$script:Patches      = @()     # output of Get-PatchFiles
$script:Gui          = @{}     # hashtable of WinForms controls, filled by Show-ToolkitGui
# caches and one-shot state that a second dot-sourced run in the same console must not inherit (same class as R-25)
$script:SettingsDefaults = $null   # 12-Settings: the defaults as copied at start-up
$script:SoftwareRowCache = $null; $script:CheckRowCache = $null; $script:ToolFilesStamp = $null   # verdict and data caches, keyed on stamps
$script:PreGuiLines = @()          # WARN / ERROR lines logged before the window exists: replayed into the log box when it is built
$script:StateDirty = @{}           # 14-State: servers whose results changed and are not written to state\ yet (name as typed -> $true)
$script:StateSeen = @{}            # 14-State: the results files read so far (path -> last-write ticks), so a reload re-reads only what changed
if ($null -eq $script:SpokeMode) { $script:SpokeMode = $false }   # Start-WinRMToolkit.ps1 -Spoke: this copy checks and patches the computer it runs on, from a hub's folders
$script:LogFileBroken = ''; $script:LogFileBrokenShown = $false   # 02-Logging: the log file cannot be written - said once in the window
$script:InstallOutcomeSink = $null # 06-Install: while set, results a status check records go here instead of their own pop-up

$script:Banner = @'
   _____   _   _   ____    _____   _____   _____    ____   _   _     _          _      ____    ____
  |  ___| | | | | / ___|  | ____| |_   _| | ____|  / ___| | | | |   | |        / \    | __ )  / ___|
  | |_    | | | | \___ \  |  _|     | |   |  _|   | |     | |_| |   | |       / _ \   |  _ \  \___ \
  |  _|   | |_| |  ___) | | |___    | |   | |___  | |___  |  _  |   | |___   / ___ \  | |_) |  ___) |
  |_|      \___/  |____/  |_____|   |_|   |_____|  \____| |_| |_|   |_____| /_/   \_\ |____/  |____/
   Sysadmin WinRM Toolkit: patching, software, health, security and commands over WinRM (5985, or 5986 over HTTPS)
'@
