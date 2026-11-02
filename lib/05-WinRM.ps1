# =====================================================================
#  05-WinRM.ps1  -  TALKING TO THE SERVERS OVER WinRM (TCP 5985, or 5986 over HTTPS)
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Three kinds of call are used, from "no auth" to "full auth":
#    Test-WSMan      -> anonymous "identify" request. Proves the port and
#                       the WinRM service are alive. No credentials needed
#                       (this is why winrm get/enumerate worked without auth).
#    Invoke-Command  -> runs a script block ON the server. Uses your current
#                       Kerberos login, or $script:Credential if you set one.
#    New-PSSession   -> a persistent connection used for copying files
#                       (Copy-FileToSession) and the install job.
#
#  Credentials are ONLY asked for in the foreground, with Get-Credential,
#  when a server says "Access is denied" or when you click "Set credentials".
#  Use FQDNs in the group files so Kerberos can find the service; never set
#  TrustedHosts=* to "fix" an authentication error.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  05-WinRM.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (see CODE-REVIEW.md).  Fixed here:
#  R-05 status now reports servicing-in-progress and the extra reboot
#  keys (RebootInProgress, PostRebootReporting, UpdateExeVolatile,
#  computer rename); R-06 names de-duplicated case-insensitively; R-08
#  job wait loops treated any non-Running state as finished; R-17
#  -LiteralPath for file-derived paths; R-21 copy gave up after five
#  halvings with a misleading error; R-22 remote SHA256 computed even
#  when sizes differed; R-23 a corrupt staged file was left behind after
#  a failed verification; R-24 credential prompt could open behind the
#  GUI (form is re-activated afterwards).
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ____CF__________________________   Date : ___30-10-2026___________
#  Verdict    : [X] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] read every function   [x] ran a status check   [x] ran a copy
#               [x] compared with CODE-REVIEW.md
#  Comments   :
#    - Note that New-PSSesssion or Invoke-Commmand may be blocked on a production
#  network, check GPOs and session configuration permissions if you get "Access is
#  denied" or "The WS-Management service cannot process the request" errors.
#    - Worked successfully in test environment.
# =====================================================================

# ---------------------------------------------------------------------
#  This script block is sent to each server and RUNS THERE.
#  It must be self contained: no functions or variables from this tool
#  exist on the remote side, only what is passed via -ArgumentList.
# ---------------------------------------------------------------------
$script:RemoteStatusScript = {
    param([bool]$TreatPfroAsReboot, [string]$Staging = '')
    $ErrorActionPreference = 'Stop'

    # Operating system, build and last boot
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $ubr = $cv.UBR
    if (-not $ubr) { $ubr = 0 }

    # Hardware: the Software console deploys VMware Tools to VMware virtual machines only
    $hw = $null
    try { $hw = Get-CimInstance -ClassName Win32_ComputerSystem } catch { }

    # Free space on C: (patches need room to stage and install)
    $disk = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"

    # Installed updates, read TWO ways:
    #  1. Get-HotFix (Win32_QuickFixEngineering): only the CBS packages still present.  Each new
    #     cumulative update supersedes the previous one, which then drops off this list, so a
    #     well patched server shows only a handful of entries here.  This is the primary source.
    #  2. Windows Update Agent history (the same list as Settings > Update history): every
    #     install the server has ever done, including superseded, failed and Defender updates.
    #     Read offline from the local WUA database via COM - nothing goes to the internet.
    # Nested objects get flattened to text by remoting, so both lists are sent as ready-made lines.
    $hotfixes = @(Get-HotFix)
    $withDate = @($hotfixes | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn)
    # "Newest hotfixes" = EVERY Get-HotFix entry from the most recent install date.  The cumulative
    # update and the .NET cumulative update normally land on the same day, so one KB alone would be
    # misleading.  The Build number (UBR) is the real patch level; this column is only a hint.
    $lastText = 'none'
    if ($withDate.Count -gt 0) {
        $newestDate = $withDate[-1].InstalledOn.Date
        $sameDay = @($withDate | Where-Object { $_.InstalledOn.Date -eq $newestDate } | ForEach-Object { $_.HotFixID } | Sort-Object -Unique)
        $more = ''
        if ($sameDay.Count -gt 3) { $more = ' +{0}' -f ($sameDay.Count - 3) }
        $lastText = '{0}{1} ({2:yyyy-MM-dd})' -f (@($sameDay | Select-Object -First 3) -join ' + '), $more, $newestDate
    }
    $hotfixLines = @($hotfixes | Sort-Object InstalledOn -Descending | ForEach-Object {
        $d = 'unknown date'
        if ($_.InstalledOn) { $d = $_.InstalledOn.ToString('yyyy-MM-dd') }
        '{0,-10}  {1,-12}  {2,-24}  {3}' -f $_.HotFixID, $d, $(if ($_.Description) { $_.Description } else { '-' }), $_.InstalledBy   # '-': a blank column would merge
    })

    $historyLines = @()
    $historyInstalled = @()
    $historyCount = 0
    $historyError = ''
    try {
        $wuSession  = New-Object -ComObject 'Microsoft.Update.Session'
        $wuSearcher = $wuSession.CreateUpdateSearcher()
        $historyCount = [int]$wuSearcher.GetTotalHistoryCount()
        if ($historyCount -gt 0) {
            $take = [math]::Min($historyCount, 80)
            $seen = @{}
            foreach ($entry in $wuSearcher.QueryHistory(0, $take)) {
                if (-not $entry.Title) { continue }
                $kb = ''
                if ($entry.Title -match '(?i)(KB\d{6,7})') { $kb = $Matches[1].ToUpper() }
                $result = 'Code ' + $entry.ResultCode
                switch ([int]$entry.ResultCode) {
                    1 { $result = 'In progress' }
                    2 { $result = 'Succeeded' }
                    3 { $result = 'Succeeded w/errors' }
                    4 { $result = 'Failed' }
                    5 { $result = 'Aborted' }
                }
                $op = 'Install'
                if ([int]$entry.Operation -eq 2) { $op = 'Uninstall' }
                $when = ''
                if ($entry.Date) { $when = ([datetime]$entry.Date).ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
                # '-' for an empty field: the reader splits on two or more spaces, so a blank column would merge into its neighbour
                $historyLines += '{0,-16}  {1,-9}  {2,-18}  {3,-10}  {4}' -f $(if ($when) { $when } else { '-' }), $op, $result, $(if ($kb) { $kb } else { '-' }), $entry.Title
                # newest entry per KB decides whether it counts as installed
                if ($kb -and -not $seen.ContainsKey($kb)) {
                    $seen[$kb] = $true
                    if ($op -eq 'Install' -and $result -like 'Succeeded*') { $historyInstalled += $kb }
                }
            }
        }
    } catch {
        $historyError = $_.Exception.Message
    }

    # Pending reboot - the HARD flags, every one of them counted:
    $reasons = @()
    $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    foreach ($k in 'RebootPending', 'PackagesPending', 'RebootInProgress') { if (Test-Path -LiteralPath "$cbs\$k") { $reasons += "CBS:$k" } }
    foreach ($k in 'RebootRequired', 'PostRebootReporting') { if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\$k") { $reasons += "WU:$k" } }
    $vol = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Updates' -Name UpdateExeVolatile -ErrorAction SilentlyContinue).UpdateExeVolatile
    if ($vol -and $vol -ne 0) { $reasons += 'UpdateExeVolatile' }
    $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    $wantedName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
    if ($activeName -and $wantedName -and $activeName -ne $wantedName) { $reasons += 'ComputerRename' }
    # PendingFileRenameOperations (PFRO): a list of files Windows must rename/delete at the next boot
    # because they were locked.  Installers and anti-virus products add to it all the time and it is
    # often left behind, so on its own it is a WEAK sign.  Shown, but not counted, unless the operator
    # sets TreatPendingFileRenameAsReboot = $true in 01-Config.ps1.
    $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    $pfroPresent = [bool]$pfro
    $pfroEntries = @()
    if ($pfroPresent) {
        $pfroEntries = @($pfro | Where-Object { $_ } | ForEach-Object { $_ -replace '^\\\?\?\\', '' } | Select-Object -First 15)
    }
    if ($pfroPresent -and $TreatPfroAsReboot) { $reasons += 'PendingFileRenameOperations' }

    # The toolkit's own software runs since the last boot whose installer asked for a reboot (exit 3010 / 1641): the
    # reboot was suppressed, and an installer that does so often sets none of the flags above.  The run left a result
    # file per item in <staging>\software.  Kept apart from PendingReboot on purpose: the reboot is due, but it must not
    # block the OS patches - they go first and the one reboot finishes both.
    # A removal since the last boot that did not ask for a reboot still leaves the reboot ADVISED (non-critical): an
    # uninstaller often leaves a service marked for deletion or files to delete at the next start, which only a reboot
    # finishes.  Advised blocks nothing and never reboots anything; the reboot stays the operator's own step.
    $swReboot = @(); $swAdvised = @(); $swLate = @()
    if ($Staging) {
        $swDir = $Staging.TrimEnd('\') + '\software'
        foreach ($f in @(Get-ChildItem -LiteralPath $swDir -Filter 'result-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $os.LastBootUpTime } | Sort-Object LastWriteTime)) {
            $h = @{}
            foreach ($l in @(Get-Content -LiteralPath $f.FullName -TotalCount 12 -ErrorAction SilentlyContinue)) { if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
            if ($h['RebootRequired'] -eq 'True') { $swReboot += ('{0} (exit {1})' -f $h['Item'], $h['ExitCode']) }
            elseif ($h['Kind'] -eq 'uninstall' -and $h['Success'] -eq 'True') { $swAdvised += ([string]$h['Item'] -replace '^Remove ', '') }
        }
        # a software task that outlived the tool's watch (SoftwareTimeoutMin) has no result file until the next software run
        # on this server collects it: its exit code goes back as SoftwareLate (the toolkit PC adds it to its change log), and
        # a 3010 since the last boot is a pending reboot just the same (read only; nothing is written here, R6-C03)
        try {
            foreach ($t in @(Get-ScheduledTask -TaskPath '\WinRMToolkit\' -ErrorAction Stop | Where-Object { $_.TaskName -like 'WRT-*' -and [string]$_.State -ne 'Running' })) {
                if (Test-Path -LiteralPath ($swDir + '\result-' + $t.TaskName + '.txt')) { continue }
                $ti = $t | Get-ScheduledTaskInfo -ErrorAction Stop
                if (-not $ti.LastRunTime -or [int64]$ti.LastTaskResult -in 267009, 267011) { continue }   # still finishing, or never ran
                $item = $t.TaskName
                $meta = $swDir + '\task-' + $t.TaskName + '.txt'
                if (Test-Path -LiteralPath $meta) { $hit = @(Get-Content -LiteralPath $meta -ErrorAction SilentlyContinue | Where-Object { $_ -like 'Item=*' }); if ($hit.Count -gt 0) { $item = $hit[0].Substring(5) } }
                $swLate += ('{0}|{1}|{2}' -f $t.TaskName, [int64]$ti.LastTaskResult, ($item -replace '\|', '/'))
                if ($ti.LastRunTime -le $os.LastBootUpTime -or [int64]$ti.LastTaskResult -notin 3010, 1641) { continue }
                $swReboot += ('{0} (exit {1}, finished after the tool stopped watching)' -f $item, $ti.LastTaskResult)
            }
        } catch { }
        # the same task once a later software run's sweep has collected it: that sweep writes the result file with Late=True
        # (dated when the task ran), so the exit code still reaches the toolkit PC - which adds only what its change log lacks
        foreach ($f in @(Get-ChildItem -LiteralPath $swDir -Filter 'result-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) })) {
            $h = @{}
            foreach ($l in @(Get-Content -LiteralPath $f.FullName -TotalCount 14 -ErrorAction SilentlyContinue)) { if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
            if ($h['Late'] -eq 'True' -and $h['TaskName'] -and $h['ExitCode']) { $swLate += ('{0}|{1}|{2}' -f $h['TaskName'], $h['ExitCode'], ([string]$h['Item'] -replace '\|', '/')) }
        }
    }

    # Is somebody servicing this box RIGHT NOW?  (another admin, Windows Update, a previous run)
    # dism.exe / wusa.exe present = yes.  TiWorker.exe alone is NOT enough: it idles for minutes after routine
    # maintenance, so it only counts while it is actually burning CPU (sampled over 2 s), and the Windows
    # Update agent is asked directly whether it is installing.  Same block in RemoteInstallScript/RemoteRebootScript.
    $busy = @(Get-Process -Name dism, wusa -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    $ti = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
    if ($ti.Count -gt 0) {
        $cpu1 = 0.0; foreach ($p in $ti) { try { if ($p.CPU) { $cpu1 += $p.CPU } } catch { } }
        Start-Sleep -Seconds 2
        $cpu2 = 0.0; foreach ($p in @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)) { try { if ($p.CPU) { $cpu2 += $p.CPU } } catch { } }
        if (($cpu2 - $cpu1) -ge 0.25) { $busy += ('TiWorker busy ({0:N1} s CPU in 2 s)' -f ($cpu2 - $cpu1)) }
    }
    try { if ((New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateInstaller().IsBusy) { $busy += 'Windows Update agent installing' } } catch { }
    # the toolkit's own install or software task (another operator's run, or a software install that outlived its watch):
    # expand.exe runs before dism.exe does, and a task of the tool's folder that is Running is an install in progress
    if (@(Get-Process -Name expand -ErrorAction SilentlyContinue).Count -gt 0) { $busy += 'expand.exe unpacking an update' }
    try { $tk = @(Get-ScheduledTask -TaskPath '\WinRMToolkit\' -ErrorAction Stop | Where-Object { [string]$_.State -eq 'Running' } | ForEach-Object { $_.TaskName }); if ($tk.Count -gt 0) { $busy += ('toolkit task running: ' + ($tk -join ', ')) } } catch { }

    # Trellix Solidcore (Application Control).  A Solidifier that is ENFORCING ("Enabled") when the server reboots rolls
    # the update back: poqexec.exe applies the pending operations at boot and its writes are denied (field test, October
    # 2026: CBS.log full of poqexec errors, the patch gone after the reboot).  "sadmin status" is the one command the CLI
    # still answers in lockdown; its lines are sent as they are and read on the operator side (Get-SolidcoreInfo).
    # Read-only: the tool never changes the mode - the Update Mode task in ePO does that.
    $scPresent = $false; $scLines = @(); $scError = ''
    $sadmin = $null
    foreach ($p in @("$env:ProgramFiles\McAfee\Solidcore\sadmin.exe", "$env:ProgramFiles\Trellix\Solidcore\sadmin.exe", 'C:\Program Files\McAfee\Solidcore\sadmin.exe')) { if (-not $sadmin -and (Test-Path -LiteralPath $p)) { $sadmin = $p } }
    if ($sadmin) {
        $scPresent = $true
        try {
            # a native command's stderr under $ErrorActionPreference = 'Stop' would end the whole status check: Continue inside
            $scLines = @(& { $ErrorActionPreference = 'Continue'; & $sadmin status 2>&1 } | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() } | Select-Object -First 40)
            if ($scLines.Count -eq 0) { $scError = 'sadmin status printed nothing' }
        } catch { $scError = 'sadmin status failed: ' + $_.Exception.Message }
    } elseif (Get-Service -Name scsrvc -ErrorAction SilentlyContinue) { $scPresent = $true; $scError = 'the Solidcore service (scsrvc) exists but sadmin.exe was not found under Program Files' }

    # The Trellix Agent (ePO agent): masvc "Trellix Agent Service" and macmnsvc "Trellix Agent Common Services".  The field
    # test (October 2026) found an OS patch install only completes with both Disabled and stopped, so the tool shows
    # their state (the Trellix Agent column; stopped = a warning, ePO hears nothing from the server) and can set them to
    # Disabled + stopped before an install and to Automatic + running after the reboot (06-Install, RemoteTrellixAgentScript).
    #   TrellixAgentLines 'Name|DisplayName|State|StartMode'   (empty = the agent is not on the server)
    #   TrellixAgentError  why the services could not be read (then the state is unknown, never "not on the server")
    $taLines = @(); $taError = ''
    try { foreach ($ws in @(Get-CimInstance -ClassName Win32_Service -Filter "Name='masvc' OR Name='macmnsvc'" -ErrorAction Stop)) { $taLines += '{0}|{1}|{2}|{3}' -f $ws.Name, $ws.DisplayName, $ws.State, $ws.StartMode } } catch { $taError = 'the services could not be read: ' + $_.Exception.Message }

    # OS patch runs the toolkit handed to this server as tasks (06-Install): the run markers, the tasks and the result
    # files of the last 14 days, so a status check finishes the record of a run the operator left to itself.
    #   PatchRuns    'Stamp|TaskState|LastResult|Started|Finished'
    #   PatchResults 'Stamp|KB|When|Success|RebootRequired|ExitCode|Message|File'
    $patchRuns = @(); $patchResults = @(); $patchRunsError = ''   # the error text when the run records could not be read: "no record" is then not known
    if ($Staging -and (Test-Path -LiteralPath $Staging)) {
        try {
            $taskStates = @{}
            $tasksUnread = $false   # the task list could not be read: every run says 'unread' (still running, as far as anyone knows), never 'absent'
            try {
                foreach ($tk in @(Get-ScheduledTask -TaskPath '\WinRMToolkit\' -ErrorAction Stop | Where-Object { $_.TaskName -like 'OSPatch-*' })) {
                    $tkLast = ''; try { $tkLast = [string]($tk | Get-ScheduledTaskInfo -ErrorAction Stop).LastTaskResult } catch { $tkLast = '?' }
                    $taskStates[$tk.TaskName.Substring(8)] = @([string]$tk.State, $tkLast)
                }
            } catch { if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound') { $tasksUnread = $true } }   # no \WinRMToolkit\ folder yet = no tasks
            foreach ($rf in @(Get-ChildItem -LiteralPath $Staging -Filter 'run-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) })) {
                $st = $rf.BaseName.Substring(4)
                $started = ''; $finished = ''
                foreach ($l in @(Get-Content -LiteralPath $rf.FullName -ErrorAction SilentlyContinue)) { if ($l -match '^Started=(.*)$') { $started = $Matches[1] } elseif ($l -match '^Finished=(.*)$') { $finished = $Matches[1] } }
                $ts = 'absent'; $tkLast = ''; if ($taskStates.ContainsKey($st)) { $ts = $taskStates[$st][0]; $tkLast = $taskStates[$st][1] } elseif ($tasksUnread) { $ts = 'unread' }
                # a finished run's task has done its work: removed here (the result files and the run marker are the record)
                if ($finished -and $ts -notin 'Running', 'absent', 'unread') { try { Unregister-ScheduledTask -TaskName ('OSPatch-' + $st) -TaskPath '\WinRMToolkit\' -Confirm:$false -ErrorAction Stop; $ts = 'removed' } catch { } }
                $patchRuns += '{0}|{1}|{2}|{3}|{4}' -f $st, $ts, $tkLast, $started, $finished
            }
            foreach ($rf in @(Get-ChildItem -LiteralPath $Staging -Filter 'result-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-14) })) {
                $h = @{}
                foreach ($l in @(Get-Content -LiteralPath $rf.FullName -ErrorAction SilentlyContinue)) { if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
                if (-not $h['Run']) { continue }
                $patchResults += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $h['Run'], $h['KB'], $h['When'], $h['Success'], $h['RebootRequired'], $h['ExitCode'], ([string]$h['Message'] -replace '\|', '/'), $h['File']
            }
        } catch { $patchRunsError = $_.Exception.Message }
    }
    # patch files already on the server (STAGE ONLY, or kept by an earlier run): "name|bytes", so the grid says READY (staged)
    $staged = @()
    if ($Staging -and (Test-Path -LiteralPath $Staging)) { foreach ($sf in @(Get-ChildItem -LiteralPath $Staging -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msu', '.cab' })) { $staged += '{0}|{1}' -f $sf.Name, $sf.Length } }

    [pscustomobject]@{
        Computer      = $env:COMPUTERNAME
        DnsDomain     = $(try { [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().DomainName } catch { '' })
        Manufacturer  = $(if ($hw) { [string]$hw.Manufacturer } else { '' })
        Model         = $(if ($hw) { [string]$hw.Model } else { '' })
        Caption       = $os.Caption
        Build         = '{0}.{1}' -f $cv.CurrentBuildNumber, $ubr
        LastBoot      = $os.LastBootUpTime
        UptimeDays    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
        FreeGB        = [math]::Round($disk.FreeSpace / 1GB, 1)
        PendingReboot = ($reasons.Count -gt 0)
        RebootReasons = ($reasons -join ', ')
        SoftwareRebootPending = ($swReboot.Count -gt 0)
        SoftwareRebootReasons = ($swReboot -join '; ')
        RebootAdvised = ($swAdvised.Count -gt 0)
        RebootAdvisedReasons = ($swAdvised -join '; ')
        SoftwareLate  = $swLate
        PfroPresent   = $pfroPresent
        PfroEntries   = $pfroEntries
        PfroCount     = @($pfro | Where-Object { $_ }).Count
        ServicingActive  = ($busy.Count -gt 0)
        ServicingReasons = ($busy -join ', ')
        SolidcorePresent = $scPresent
        SolidcoreLines   = $scLines
        SolidcoreError   = $scError
        TrellixAgentLines = $taLines
        TrellixAgentError = $taError
        PatchRuns     = $patchRuns; PatchRunsError = $patchRunsError
        PatchResults  = $patchResults
        StagedFiles   = $staged
        HotFixIDs     = @($hotfixes | ForEach-Object { $_.HotFixID })
        HotFixLines   = $hotfixLines
        HistoryInstalledKBs = $historyInstalled
        HistoryLines  = $historyLines
        HistoryCount  = $historyCount
        HistoryError  = $historyError
        LastHotFix    = $lastText
        PSVersion     = $PSVersionTable.PSVersion.ToString()
    }
}

function New-PatcherSessionOption {
    # OpenTimeout = how long to wait for a server that does not answer before giving up.
    return (New-PSSessionOption -OpenTimeout ($script:Config.OpenTimeoutSec * 1000))
}

function Test-WinRMUseSsl {
    # WinRMPort 5986 is the HTTPS listener: every call then goes with -UseSSL, and PowerShell checks the server's
    # certificate the normal way - it must chain to a CA this PC trusts and carry the name in the group file. Nothing is
    # skipped (no SkipCACheck, no SkipCNCheck): a certificate problem is an error to read, not one to silence.
    return ([int]$script:Config.WinRMPort -eq 5986)
}

function Get-WinRMPortText {
    # '5985' or '5986 (HTTPS)' - for the window title, tips, help pages and messages
    if (Test-WinRMUseSsl) { return ('{0} (HTTPS)' -f $script:Config.WinRMPort) }
    return ([string]$script:Config.WinRMPort)
}

function Get-WinRMSchemeText {
    # 'HTTP' or 'HTTPS' - the transport the port setting selects
    if (Test-WinRMUseSsl) { return 'HTTPS' }
    return 'HTTP'
}

function Get-WinRMCallText {
    # what a CMD log line shows after the computer name: '-Port 5985' or '-Port 5986 -UseSSL'
    if (Test-WinRMUseSsl) { return ('-Port {0} -UseSSL' -f $script:Config.WinRMPort) }
    return ('-Port {0}' -f $script:Config.WinRMPort)
}

function Get-ConnectionArgs {
    # A "splat" hashtable so every WinRM call is built the same way: @conn
    $splat = @{
        Port          = $script:Config.WinRMPort
        SessionOption = (New-PatcherSessionOption)
    }
    if (Test-WinRMUseSsl) { $splat['UseSSL'] = $true }
    if ($script:Credential) { $splat['Credential'] = $script:Credential }
    return $splat
}

function Get-PatcherCredential {
    # Foreground credential prompt (Windows dialog), running as the logged-on user.
    # The dialog belongs to the console window, which can sit BEHIND the GUI - the status bar says so,
    # and the GUI is brought back to the front afterwards.
    param([string]$Reason = 'alternate credentials for WinRM')
    Write-PatchLog "Prompting for credentials in the foreground: $Reason  (look for the Windows credential dialog - it may be behind this window)" 'WHY'
    Set-GuiStatus 'Credential prompt open - it may be behind this window'
    $cred = Get-Credential -Message "$($script:Config.ToolName) - $Reason" -UserName "$env:USERDOMAIN\"
    $form = $script:Gui['Form']
    if ($form -and -not $form.IsDisposed) { try { $form.Activate() } catch { } }
    if ($cred -and $cred.UserName -and $cred.UserName -ne "$env:USERDOMAIN\") {
        $script:Credential = $cred
        Write-PatchLog "Credentials stored in memory for $($cred.UserName) (never written to disk) by $env:USERDOMAIN\$env:USERNAME" 'OK'
        return $true
    }
    Write-PatchLog 'Credential prompt cancelled - still using the current Windows login' 'WARN'
    return $false
}

function Clear-PatcherCredential {
    $script:Credential = $null
    Write-PatchLog 'Stored credentials cleared - back to the current Windows login' 'INFO'
}

function Test-ServerWinRM {
    # The "no authentication" check. Good first step when a server shows as unreachable.
    param([Parameter(Mandatory = $true)][string]$ComputerName)
    if (Test-ThisComputer -Name $ComputerName) { Write-PatchLog "$ComputerName is this computer: the toolkit runs its work here, without a WinRM call to itself - nothing to test" 'OK'; return $true }
    Write-PatchLog "Test-WSMan -ComputerName $ComputerName $(Get-WinRMCallText)" 'CMD'
    try {
        $r = Test-WSMan -ComputerName $ComputerName -Port $script:Config.WinRMPort -UseSSL:(Test-WinRMUseSsl) -ErrorAction Stop
        Write-PatchLog "$ComputerName answers on WinRM (stack $($r.ProductVersion))" 'OK'
        return $true
    } catch {
        Write-PatchLog "$ComputerName did NOT answer on $(Get-WinRMPortText): $(Get-ShortError $_)" 'ERROR'
        return $false
    }
}

function Get-ShortError {
    # The exception message in full, but on ONE line (PowerShell's own multi-line
    # "+ CategoryInfo" noise is left out) so the log stays easy to read and grep.
    param($ErrorRecord)
    $msg = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $msg = $ErrorRecord.Exception.Message }
    elseif ($ErrorRecord -is [System.Exception]) { $msg = $ErrorRecord.Message }
    else { $msg = [string]$ErrorRecord }
    $lines = @($msg -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return ($lines -join ' | ')
}

function Get-ErrorLocation {
    # "file.ps1: line 123" for a caught error: the first line of its script stack trace.
    param($ErrorRecord)
    if ($ErrorRecord.ScriptStackTrace) { return (($ErrorRecord.ScriptStackTrace -split "`r?`n")[0] -replace '^at ', '') }
    return ''
}

function New-UnreachableStatus {
    # Same shape as the remote object so the GUI never trips over a missing property.
    param([string]$ComputerName, [string]$Reason)
    return [pscustomobject]@{
        Computer = $ComputerName; Manufacturer = ''; Model = ''; Caption = ''; Build = ''; LastBoot = $null; UptimeDays = $null
        FreeGB = $null; PendingReboot = $false; RebootReasons = ''; SoftwareRebootPending = $false; SoftwareRebootReasons = ''; RebootAdvised = $false; RebootAdvisedReasons = ''; SoftwareLate = @(); PfroPresent = $false; PfroEntries = @(); PfroCount = 0
        ServicingActive = $false; ServicingReasons = ''; SolidcorePresent = $false; SolidcoreLines = @(); SolidcoreError = ''; TrellixAgentLines = @(); TrellixAgentError = ''; PatchRuns = @(); PatchRunsError = ''; PatchResults = @(); StagedFiles = @()
        HotFixIDs = @(); HotFixLines = @(); HistoryInstalledKBs = @(); HistoryLines = @(); HistoryCount = 0; HistoryError = ''
        LastHotFix = ''; PSVersion = ''
        Reachable = $false; Error = $Reason; Checked = (Get-Date)
    }
}

function Wait-PatcherJob {
    # Waits for a job while keeping the GUI alive (DoEvents) and the status bar ticking.
    # "Finished" means Completed / Failed / Stopped / Disconnected - NotStarted, Blocked and
    # Suspending (robust-connection retries after a network blip) are still "in progress".
    # -Stoppable (read-only collectors only): the "Stop waiting" button on the status bar gives up on the servers that
    # have not answered, and each server has its own budget: one that has not answered $SilentAfterSec after its turn
    # began (a throttled child starts later than the first wave) is given up on its own while the others carry on - a
    # wedged WMI call, a half-dead server or an account that never gets an answer must not hold a 35-server check for
    # ten minutes (field test 2026-11).  Nothing is ever stopped on an install job.
    param($Job, [string]$Activity = 'Working', [int]$TimeoutSec = 3600, [switch]$Stoppable, [int]$SilentAfterSec = 0)
    $finished = @('Completed', 'Failed', 'Stopped', 'Disconnected')
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $button = $null; $lent = $null
    if ($null -eq $script:Gui) { $script:Gui = @{} }   # functions-only use (no window): the flags below still need a table
    $script:Gui['WaitStopped'] = $false   # this wait's own "Stop waiting" (Invoke-Collector reads it for the reason text)
    if ($Stoppable -and $script:Gui['StopButton']) {
        $button = $script:Gui['StopButton']
        # an install watch (Watch-PatchRuns) may own the button as "Let the servers go": a read-only check running alongside
        # borrows it and hands it back as it was - neither hidden, nor with this check's stop turned into "let them go" (R6-00)
        if ($script:Gui['StopOwner']) { $lent = @{ Text = $button.Text; Tip = $button.ToolTipText; Enabled = $button.Enabled; Stop = [bool]$script:Gui['StopRequested'] } }
        $script:Gui['StopRequested'] = $false; $button.Enabled = $true; $button.Text = 'Stop waiting'; $button.ToolTipText = 'Give up on the servers that have not answered yet (read-only checks only; nothing is changed on them)'; $button.Visible = $true
    }
    $turnBegan = @{}   # child job -> seconds on the watch when it was first seen running (NotStarted = still queued for a slot)
    try {
        while ($finished -notcontains $Job.State -and $watch.Elapsed.TotalSeconds -lt $TimeoutSec) {
            $open = @($Job.ChildJobs | Where-Object { $finished -notcontains $_.State })
            Set-GuiStatus ('{0} ... {1}s{2}' -f $Activity, [int]$watch.Elapsed.TotalSeconds, $(if ($Stoppable -and $open.Count -gt 0 -and $open.Count -lt @($Job.ChildJobs).Count) { ' - waiting for ' + $open.Count } else { '' }))
            if ($Stoppable -and $script:Gui['StopRequested']) {
                $script:Gui['WaitStopped'] = $true
                Write-PatchLog ("{0}: stopped by {1} - {2} server(s) had not answered: {3}" -f $Activity, (Get-OperatorIdentity), $open.Count, (@($open | ForEach-Object { $_.Location }) -join ', ')) 'WARN'
                foreach ($c in $open) { Stop-Job -Job $c -ErrorAction SilentlyContinue }
                break
            }
            if ($Stoppable -and $SilentAfterSec -gt 0) {
                $now = $watch.Elapsed.TotalSeconds
                $late = @()
                foreach ($c in $open) {
                    if ($c.State -eq 'NotStarted') { continue }
                    $key = [string]$c.InstanceId
                    if (-not $turnBegan.ContainsKey($key)) { $turnBegan[$key] = $now; continue }
                    if ($now - $turnBegan[$key] -ge $SilentAfterSec) { $late += $c }
                }
                if ($late.Count -gt 0) {
                    Write-PatchLog ("{0}: {1} server(s) have not answered {2} s after their turn began - giving up on them, the others carry on: {3}" -f $Activity, $late.Count, $SilentAfterSec, (@($late | ForEach-Object { $_.Location }) -join ', ')) 'WARN'
                    foreach ($c in $late) { Stop-Job -Job $c -ErrorAction SilentlyContinue }
                }
            }
            Start-Sleep -Milliseconds 300
        }
    } finally {
        if ($button) {
            if ($lent) { $button.Text = $lent.Text; $button.ToolTipText = $lent.Tip; $button.Enabled = $lent.Enabled; $script:Gui['StopRequested'] = $lent.Stop }
            else { $button.Visible = $false }
        }
    }
    if ($finished -notcontains $Job.State) {
        Write-PatchLog "$Activity timed out after $TimeoutSec s - stopping the job" 'ERROR'
        Stop-Job -Job $Job
    }
}

function Set-GuiStatus {
    # Updates the status bar text if the GUI exists; harmless from the console.
    param([string]$Text)
    $label = $script:Gui['StatusLabel']
    if ($label -and -not $label.IsDisposed) {   # a window closed under a running step (functions-only use after the GUI): nothing to update
        $label.Text = $Text
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Set-GuiProgress {
    # Patch-o-meter: -Percent 0..100 shows a real bar, -Marquee goes back to "busy, unknown length".
    param([int]$Percent = -1, [switch]$Marquee)
    $bar = $script:Gui['Progress']
    if (-not $bar -or $bar.IsDisposed) { return }
    if ($Marquee) { $bar.Style = 'Marquee'; return }
    $bar.Style = 'Continuous'
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $bar.Value = $Percent
    [System.Windows.Forms.Application]::DoEvents()
}

function Invoke-Collector {
    # THE fan-out engine.  Runs one self-contained script block on many servers at once (one child job
    # per server, up to MaxParallel), stores each server's result under $script:Results[$Name][$server]
    # with Reachable / Error / Checked added, and returns the array of results.  Every console uses it:
    # the O/S Patching console through Get-ServerStatus, the Health and Security consoles directly.
    param(
        [Parameter(Mandatory = $true)][string]$Name,              # collector name, e.g. Status, Inventory, Settings
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,  # runs ON the server; must be self contained
        [Parameter(Mandatory = $true)][string[]]$ComputerName,
        [object[]]$ArgumentList = @(),
        [int]$TimeoutSec = 600,
        [scriptblock]$Summary,        # optional: formats the per-server OK log line, receives the result
        [scriptblock]$Unreachable,    # optional: builds the "unreachable" object, receives (name, reason)
        [switch]$NoRetry,             # internal: stops the "prompt for credentials and retry" loop
        [int]$SilentAfterSec = -1,    # internal (the retry): the first call's per-server silence budget; -1 = worked out below
        [switch]$NoStop               # a command that may change a server: no "Stop waiting" button and no giving up on a server
    )                                 # that is slower than the others - only the time limit ends it (and says it may have run)
    $names = @(Get-UniqueNames $ComputerName)
    if ($names.Count -eq 0) { return @() }
    if (-not $script:Results.ContainsKey($Name)) { $script:Results[$Name] = @{} }
    $store = $script:Results[$Name]
    # one malformed name makes Invoke-Command refuse the WHOLE batch: such names are reported on their own
    $invalid = @($names | Where-Object { -not (Test-LooksLikeHostname $_) })
    $early = @()
    foreach ($bad in $invalid) {
        $why = 'not a valid host name (letters, digits and inner dashes between single dots)'
        if ($Unreachable) { $r0 = & $Unreachable $bad $why } else { $r0 = [pscustomobject]@{ Computer = $bad; Reachable = $false; Error = $why; Checked = (Get-Date) } }
        $store[$bad] = $r0; $early += $r0
        Write-PatchLog "$bad FAILED ($Name): $why" 'ERROR'
    }
    $names = @($names | Where-Object { Test-LooksLikeHostname $_ })
    if ($names.Count -eq 0) { return $early }

    $who  = 'current login'
    if ($script:Credential) { $who = $script:Credential.UserName }

    # A read-only action running alongside an install keeps its hands off the servers being installed on.
    if ($script:Gui['NestedBusy'] -and $script:InstallTargets) {
        $targetLabels = @($script:InstallTargets | ForEach-Object { ([string]$_ -split '\.')[0].ToLower() })
        $skip = @($names | Where-Object { $targetLabels -contains (($_ -split '\.')[0].ToLower()) })   # SRV01 and srv01.corp.local are one box
        if ($skip.Count -gt 0) {
            Write-PatchLog ("{0}: skipping {1} - an install is running there; collect again when it has finished" -f $Name, ($skip -join ', ')) 'WHY'
            $names = @($names | Where-Object { $skip -notcontains $_ })
            if ($names.Count -eq 0) { return @() }
        }
    }
    # The toolkit PC itself in the list (Test-ThisComputer): the same script block runs HERE, as a local background job -
    # no WinRM call to itself, so this PC needs no listener and no loopback rights (field test 2026-11: the server that
    # runs the toolkit is patched too).  Every other name fans out over WinRM as before.
    $asked = @($names)
    $localNames = @($names | Where-Object { Test-ThisComputer -Name $_ })
    $names = @($names | Where-Object { $localNames -notcontains $_ })
    $localJob = $null
    if ($localNames.Count -gt 0) {
        Write-PatchLog ("Start-Job  ({0} collector on this computer - {1} - as {2}; no WinRM call to itself)" -f $Name, ($localNames -join ','), (Get-OperatorIdentity)) 'CMD'
        $localCall = @{ ScriptBlock = $ScriptBlock }
        if ($ArgumentList.Count -gt 0) { $localCall['ArgumentList'] = $ArgumentList }
        $localJob = Start-Job @localCall
    }
    # a collector only reads: the operator may stop waiting, and a server that has not answered SilentServerSec (Settings
    # tab) after its turn began is given up on its own, the others carry on (it is reported unreachable with that reason).
    # A collector that asks for a limit of its own (-TimeoutSec: Impact 900 s, Analysis 300 s, a command at CommandTimeoutSec)
    # is given that long per server instead - a slow but working server is not a wedged one (review 2026-11-03)
    $silentSec = $SilentAfterSec
    if ($silentSec -lt 0) {
        $silentSec = [int]$script:Config.SilentServerSec
        if ($PSBoundParameters.ContainsKey('TimeoutSec')) { $silentSec = $TimeoutSec }
    }
    if ($NoStop) { $silentSec = 0 }
    $silentWhy = 'SilentServerSec on the Settings tab'
    if ($silentSec -ne [int]$script:Config.SilentServerSec) { $silentWhy = "the $Name collector's own limit" }
    $job = $null
    if ($names.Count -gt 0) {
        $conn = Get-ConnectionArgs
        Write-PatchLog ("Invoke-Command -ComputerName {0} {1} -AsJob  ({2} collector, as {3})" -f ($names -join ','), (Get-WinRMCallText), $Name, $who) 'CMD'
        $call = @{
            ComputerName  = $names
            ScriptBlock   = $ScriptBlock
            ThrottleLimit = $script:Config.MaxParallel
            AsJob         = $true
            ErrorAction   = 'SilentlyContinue'
        }
        if ($ArgumentList.Count -gt 0) { $call['ArgumentList'] = $ArgumentList }
        $job = Invoke-Command @call @conn
        # one limit covers the whole fan-out: with more servers than MaxParallel the later ones wait for a free slot, so
        # the limit grows with the number of waves (an upper bound, not an expected time)
        $waves = [math]::Max(1, [math]::Ceiling($names.Count / [double][math]::Max(1, $script:Config.MaxParallel)))
        $TimeoutSec = [int]($TimeoutSec * $waves)
        Wait-PatcherJob -Job $job -Activity ("{0}: {1} server(s)" -f $Name, $names.Count) -TimeoutSec $TimeoutSec -Stoppable:(-not $NoStop) -SilentAfterSec $silentSec
    }
    if ($localJob) { Wait-PatcherJob -Job $localJob -Activity ("{0}: this computer" -f $Name) -TimeoutSec $TimeoutSec -Stoppable:(-not $NoStop) -SilentAfterSec $silentSec }

    # every answer under the name it was asked by: a remote child by its Location, the local job once per alias of this
    # computer in the list (localhost and the name are one box: one run, a row for each)
    $answers = @()
    if ($job) { foreach ($child in $job.ChildJobs) { $errs = @(); $o = Receive-Job -Job $child -ErrorAction SilentlyContinue -ErrorVariable errs; $answers += [pscustomobject]@{ Child = $child; Server = [string]$child.Location; Out = $o; Errors = @($errs) } } }
    if ($localJob) { $child = $localJob.ChildJobs[0]; $errs = @(); $o = Receive-Job -Job $child -ErrorAction SilentlyContinue -ErrorVariable errs; foreach ($alias in $localNames) { $answers += [pscustomobject]@{ Child = $child; Server = $alias; Out = $o; Errors = @($errs) } } }
    $results = @($early)
    $denied  = @()
    try {   # whatever a summary or unreachable block throws, the jobs are removed and every answer read so far is kept
        foreach ($answer in $answers) {
            $child = $answer.Child; $server = $answer.Server; $out = $answer.Out; $jobErrors = @($answer.Errors)
            $result = $null
            # Only a real result object counts (every Remote*Script returns one with a Computer property);
            # a stray string in the output stream must never be mistaken for the result.
            $objects = @($out | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Computer'] })
            if ($objects.Count -gt 0) {
                $result = $objects[-1]
                $result | Add-Member -NotePropertyName Reachable -NotePropertyValue $true  -Force
                $result | Add-Member -NotePropertyName Error     -NotePropertyValue ''     -Force
                $result | Add-Member -NotePropertyName Checked   -NotePropertyValue (Get-Date) -Force
                $sumText = ''
                if ($Summary) { try { $sumText = [string](& $Summary $result) } catch { $sumText = ('collected (the summary line failed: {0})' -f (Get-ShortError $_)) } } else { $sumText = "$Name collected" }
                Write-PatchLog ("{0}: {1}" -f $server, $sumText) 'OK'
            } else {
                $reason = 'no data returned'
                if ($jobErrors.Count -gt 0) { $reason = Get-ShortError $jobErrors[0] }
                elseif ($child.State -eq 'Stopped') { $reason = $(if ($script:Gui['WaitStopped']) { 'given up: the operator stopped waiting' } elseif ($silentSec -gt 0) { "no answer within $silentSec s of its turn - given up ($silentWhy; the server is down, wedged, or the account gets no answer from it)" } else { "no answer within $TimeoutSec s - given up" }) }
                elseif ($child.JobStateInfo.Reason) { $reason = Get-ShortError $child.JobStateInfo.Reason }
                elseif ($out) { $first = ([string]($out | Select-Object -First 1)) -replace '\s+', ' '; $reason = 'unexpected output instead of a result object: ' + $first.Substring(0, [Math]::Min(80, $first.Length)) }
                if ($Unreachable) { try { $result = & $Unreachable $server $reason } catch { $result = $null } }
                if (-not $result) { $result = [pscustomobject]@{ Computer = $server; Reachable = $false; Error = $reason; Checked = (Get-Date) } }
                # out of time, not stopped by the operator: the Commands console tells the operator a command that long needs its own console
                if ($child.State -eq 'Stopped' -and -not $script:Gui['WaitStopped']) { $result | Add-Member -NotePropertyName TimedOut -NotePropertyValue $true -Force }
                if ($reason -match 'Access is denied') { $denied += $server }
                Write-PatchLog "$server FAILED ($Name): $reason" 'ERROR'
            }
            $store[$server] = $result
            $results += $result
        }
    } finally { foreach ($j in @($job, $localJob)) { if ($j) { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue } } }
    Clear-CheckRowCache -Servers @($store.Keys | Where-Object { $asked -contains $_ })   # only these servers' rows are stale now

    # Access denied with the current login?  Ask once (foreground) and retry just those servers - but never
    # from a read-only action running alongside an install: the install's remaining sessions would silently
    # switch to the new account.
    if ($denied.Count -gt 0 -and -not $NoRetry -and -not $script:Credential -and $script:Gui['NestedBusy']) {
        Write-PatchLog ("{0} server(s) refused the current login; the credential prompt is not offered while '{1}' is running - set credentials first, or retry afterwards" -f $denied.Count, $script:Gui['BusyName']) 'WARN'
    } elseif ($denied.Count -gt 0 -and -not $NoRetry -and -not $script:Credential) {
        Write-PatchLog ("{0} server(s) refused the current login - offering a credential prompt" -f $denied.Count) 'WHY'
        if (Get-PatcherCredential -Reason "access denied on $($denied -join ', ')") {
            $retried = Invoke-Collector -Name $Name -ScriptBlock $ScriptBlock -ComputerName $denied -ArgumentList $ArgumentList -TimeoutSec $TimeoutSec -SilentAfterSec $silentSec -NoStop:$NoStop -Summary $Summary -Unreachable $Unreachable -NoRetry
            # replace the "denied" placeholders by name as typed (a reachable result carries the server's own NetBIOS name)
            $results = @($results | Where-Object { $denied -notcontains $_.Computer }) + @($retried)
        }
    }
    Set-GuiStatus "$Name finished"
    return $results
}

function Get-ServerStatus {
    # The O/S Patching console's status check = the Status collector.  Results land in $script:ServerStatus
    # (which IS $script:Results['Status']).  Kept as a named function because everything in the Patching
    # console calls it and because the log line it writes is the one operators read most.
    param(
        [Parameter(Mandatory = $true)][string[]]$ComputerName,
        [switch]$NoRetry
    )
    $summary = {
        param($s)
        $flag = 'no reboot pending'
        if ($s.PendingReboot -or $s.SoftwareRebootPending) { $flag = 'PENDING REBOOT (' + (Get-PendingRebootText -Status $s).Substring(5) + ')' }
        elseif ($s.RebootAdvised) { $flag = 'reboot advised (removed ' + $s.RebootAdvisedReasons + ')' }
        if ($s.ServicingActive) { $flag += ", SERVICING ACTIVE ($($s.ServicingReasons))" }
        if ($s.PSObject.Properties['SolidcorePresent'] -and $s.SolidcorePresent) { $flag += ', Solidcore ' + (Get-SolidcoreText -Status $s) }
        $ta = Get-TrellixAgentInfo -Status $s
        if ($ta.Present -and (Test-TrellixInUse)) { $flag += ', Trellix Agent ' + $ta.Text }
        return ("build {0}, {1} GB free, up {2} d, {3}, newest hotfixes {4}" -f $s.Build, $s.FreeGB, $s.UptimeDays, $flag, $s.LastHotFix)
    }
    $unreachable = { param($n, $reason) New-UnreachableStatus -ComputerName $n -Reason $reason }
    $callStart = Get-Date
    $out = Invoke-Collector -Name 'Status' -ScriptBlock $script:RemoteStatusScript -ComputerName $ComputerName -ArgumentList @($script:Config.TreatPendingFileRenameAsReboot, $script:Config.RemoteStaging) -Summary $summary -Unreachable $unreachable -NoRetry:$NoRetry
    # an OS patch run left to itself (06-Install): what the server reported finishes its record, or says it is still going.
    # Only servers this call really read: a check running alongside an install skips the servers being installed, and
    # their stored status (from before the launch) knows nothing of the run - it would read as "no record" (R6-01)
    $fresh = @(@($ComputerName) | Where-Object { $st = $script:ServerStatus[$_]; $st -and $st.Reachable -and $st.Checked -is [datetime] -and $st.Checked -ge $callStart })
    # the toolkit PC itself in the list: a managed server like any other, worked without a WinRM call to itself - said once
    # per check, so nobody wonders
    foreach ($self in @($fresh | Where-Object { Test-ThisComputer -Name $_ })) { Write-PatchLog "$self is this computer, the toolkit PC: checked and patched like any other managed server, with every step run here instead of over WinRM; its reboot comes last, with a 60 s countdown, and closes the toolkit with it" 'WHY' }
    try { Update-InstallFlagsFromStatus -Servers $fresh } catch { Write-PatchLog "The open install runs could not be matched against the status: $(Get-ShortError $_)" 'WARN' }
    # a software item the tool stopped waiting for, finished since: its real result goes into the change log on this PC (50-Console-Software)
    try { Update-SoftwareLateResults -Servers $fresh } catch { Write-PatchLog "Late software results could not be added to the change log: $(Get-ShortError $_)" 'WARN' }
    # the Trellix Agent services stopped (by the tool before an install, or by hand): ePO hears nothing from such a server
    # until they run again - the warning in the log at every check; the scan buttons add a pop-up (Show-TrellixAgentWarning)
    $agentOff = @(Get-TrellixStoppedServers -Servers $fresh)
    if ($agentOff.Count -gt 0) { Write-PatchLog ("TRELLIX AGENT services stopped or disabled on {0} server(s): {1} - ePO gets no reports from them; when the patching and the reboot are done, tick them and press 'Start Trellix Agent (ticked)'" -f $agentOff.Count, ($agentOff -join ', ')) 'WARN' }
    return $out
}

function Get-PendingRebootText {
    # The "Pending reboot" cell, the same in every console: Windows' own hard flags, then the toolkit's software runs
    # since the last boot whose installer asked for a reboot (3010 / 1641, the reboot suppressed).  Only the first
    # blocks OS patches; both make the reboot due.  Then, non-critical, "advised": a removal since the last boot.
    param($Status)
    $parts = @()
    if ($Status.PendingReboot) { $parts += [string]$Status.RebootReasons }
    if ($Status.SoftwareRebootPending) { $parts += ('software: ' + $Status.SoftwareRebootReasons) }
    if ($parts.Count -gt 0) { return ('YES: ' + ($parts -join '; ')) }
    # non-critical: a product was removed since the last boot - the reboot finishes its clean-up
    if ($Status.RebootAdvised) { return ('advised: removed ' + $Status.RebootAdvisedReasons) }
    if ($Status.PfroPresent) { return 'no (PFRO only, ignored)' }
    return 'no'
}

function Get-CollectorResult {
    # The last result of one collector for one server, or $null.
    param([string]$Name, [string]$Server)
    if (-not $script:Results.ContainsKey($Name)) { return $null }
    return $script:Results[$Name][$Server]
}

function ConvertTo-SettingsTable {
    # Collectors send settings as "Key=Value" text lines (remoting flattens nested objects).  This turns
    # one or more such line arrays into a case-insensitive hashtable the checks can read.
    param([string[][]]$LineSets)
    $t = @{}
    foreach ($lines in $LineSets) {
        foreach ($line in @($lines)) {
            if ($line -match '^([^=]+)=(.*)$') { $t[$Matches[1].Trim()] = $Matches[2] }
        }
    }
    return $t
}

# =====================================================================
#  COPYING A FILE OVER WinRM - IN SLICES
# ---------------------------------------------------------------------
#  Every WinRM request has to fit inside the server's "MaxEnvelopeSizekb"
#  (default 500 KB).  Copy-Item -ToSession in PowerShell 5.1 sends bigger
#  requests than that and fails with "...exceeded the configured
#  MaxEnvelopeSize quota".  So we do it ourselves: read the file in slices,
#  Base64 each slice (that makes it 37% bigger), send it as an argument to a
#  tiny script block that appends it on the server.  The slice size is worked
#  out from the server's own MaxEnvelopeSizekb (500 -> 224 KB slices), the
#  copy can resume, and the result is verified with a SHA256 hash on both sides.
# =====================================================================

# RUNS ON THE TARGET SERVER: what is there already, and how big may a request be?
$script:RemoteFileInfoScript = {
    param([string]$Path, [bool]$WithHash)
    $r = [pscustomobject]@{ Exists = $false; Length = -1; Hash = ''; EnvelopeKB = 500 }
    if (Test-Path -LiteralPath $Path) {
        $r.Exists = $true
        $r.Length = (Get-Item -LiteralPath $Path).Length
        if ($WithHash) { $r.Hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
    }
    # How big may one request be?  Try the WSMan provider, then winrm.cmd, else assume the default 500.
    $kb = 0
    try { $kb = [int](Get-Item -Path 'WSMan:\localhost\MaxEnvelopeSizekb' -ErrorAction Stop).Value } catch { }
    if ($kb -le 0) {
        try {
            $line = @(& winrm.cmd get winrm/config 2>$null | Where-Object { $_ -match 'MaxEnvelopeSizekb\s*=\s*(\d+)' })
            if ($line.Count -gt 0 -and $line[0] -match 'MaxEnvelopeSizekb\s*=\s*(\d+)') { $kb = [int]$Matches[1] }
        } catch { }
    }
    if ($kb -le 0) { $kb = 500 }
    $r.EnvelopeKB = $kb
    return $r
}

# RUNS ON THE TARGET SERVER: appends one slice (Create on the first slice) and returns the new length.
$script:RemoteWriteSliceScript = {
    param([string]$Path, [string]$Base64, [bool]$FirstSlice)
    $bytes = [System.Convert]::FromBase64String($Base64)
    $mode = [System.IO.FileMode]::Append
    if ($FirstSlice) {
        $mode = [System.IO.FileMode]::Create
        $folder = Split-Path -Path $Path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    }
    $fs = New-Object System.IO.FileStream($Path, $mode, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Close() }
    return (Get-Item -LiteralPath $Path).Length
}

# RUNS ON THE TARGET SERVER: throws away a staged file that failed verification.
$script:RemoteDeleteScript = {
    param([string]$Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function New-ToolkitSession {
    # The session an install, a staging copy or a software run works through: a PSSession over WinRM - or, for the
    # toolkit PC itself (Test-ThisComputer), a LOCAL session: a marker that Invoke-RemoteBlock, Copy-FileToSession and
    # Close-ToolkitSession recognise and serve on this PC, with no WinRM call to itself (field test 2026-11).
    param([Parameter(Mandatory = $true)][string]$ComputerName, [string]$Prefix = '')
    if (Test-ThisComputer -Name $ComputerName) {
        Write-PatchLog ("{0}{1} is this computer: no session - the staging, the launch and the checks run here" -f $Prefix, $ComputerName) 'WHY'
        return [pscustomobject]@{ ComputerName = $ComputerName; Local = $true; State = 'Opened' }
    }
    $conn = Get-ConnectionArgs
    Write-PatchLog ("{0}New-PSSession -ComputerName {1} {2}" -f $Prefix, $ComputerName, (Get-WinRMCallText)) 'CMD'
    return (New-PSSession -ComputerName $ComputerName @conn -ErrorAction Stop)
}

function Test-LocalSession {
    # A local session marker from New-ToolkitSession (this computer), as opposed to a PSSession or nothing
    param($Session)
    return [bool]($Session -and $Session.PSObject.Properties['Local'] -and $Session.Local)
}

function Close-ToolkitSession {
    param($Session)
    if ($Session -and -not (Test-LocalSession -Session $Session)) { Remove-PSSession -Session $Session -ErrorAction SilentlyContinue }
}

function Invoke-RemoteBlock {
    # Runs a script block inside the session - or here when there is no session or the session is this computer's
    # local one (which also lets the copy logic be tested on one machine, see the Code Tour).
    param($Session, [scriptblock]$ScriptBlock, [object[]]$ArgumentList)
    if ($Session -and -not (Test-LocalSession -Session $Session)) { return (Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop) }
    return (& $ScriptBlock @ArgumentList)
}

function Invoke-ToolkitCommand {
    # One script block on one server, answered at once (the reboot, the Trellix Agent services): over WinRM, or here
    # when the server is this computer - the block itself does not know the difference.
    param([Parameter(Mandatory = $true)][string]$ComputerName, [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [string]$Explain = '')
    if (Test-ThisComputer -Name $ComputerName) {
        Write-PatchLog ("{0} is this computer: run here, no WinRM call{1}" -f $ComputerName, $(if ($Explain) { ' (' + $Explain + ')' } else { '' })) 'CMD'
        return (& $ScriptBlock @ArgumentList)
    }
    $conn = Get-ConnectionArgs
    Write-PatchLog ("Invoke-Command -ComputerName {0} {1}{2}" -f $ComputerName, (Get-WinRMCallText), $(if ($Explain) { ' (' + $Explain + ')' } else { '' })) 'CMD'
    return (Invoke-Command -ComputerName $ComputerName @conn -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop)
}

function Copy-FileToSession {
    param(
        [Parameter(Mandatory = $true)][string]$Path,          # local file
        [Parameter(Mandatory = $true)][string]$Destination,   # full path on the server
        $Session,                                              # PSSession; $null = a local copy, no session
        [int]$SliceKB = 0,                                     # 0 = derive from the server's MaxEnvelopeSizekb
        [string]$LocalHash = ''                                # SHA256 if already known (saves hashing a big file again)
    )
    $local = Get-Item -LiteralPath $Path
    $label = 'local'
    if ($Session) { $label = $Session.ComputerName }
    $totalMB = [math]::Round($local.Length / 1MB, 1)
    if (-not $LocalHash) { $LocalHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }

    # 1. Is it already there?  Only hash the remote file when the sizes match (hashing a partial file is wasted work).
    $info = Invoke-RemoteBlock -Session $Session -ScriptBlock $script:RemoteFileInfoScript -ArgumentList $Destination, $false
    $offset = 0
    if ($info.Exists -and $info.Length -eq $local.Length) {
        Set-GuiStatus "$label - $($local.Name) already staged, checking its hash..."
        $info = Invoke-RemoteBlock -Session $Session -ScriptBlock $script:RemoteFileInfoScript -ArgumentList $Destination, $true
        if ($LocalHash -eq $info.Hash) {
            Write-PatchLog "$label - $($local.Name) is already there and the SHA256 matches - no copy needed" 'OK'
            return $true
        }
        Write-PatchLog "$label - a file of the same size is there but its hash differs - copying again from the start" 'WARN'
    } elseif ($info.Exists -and $info.Length -gt 0 -and $info.Length -lt $local.Length) {
        $offset = $info.Length
        Write-PatchLog ("{0} - a partial copy ({1} MB) is there - resuming from that point (the final hash check catches a bad one)" -f $label, [math]::Round($offset / 1MB, 1)) 'INFO'
    }

    # this computer (a local session): a plain file copy - no slices, no envelope; the same verification below
    $completed = $false
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-LocalSession -Session $Session) {
        Set-GuiStatus "$label - copying $($local.Name) ($totalMB MB) on this computer..."
        Write-PatchLog ("Copy-Item -LiteralPath '{0}' -Destination '{1}'   (this computer: a plain copy, {2} MB)" -f $Path, $Destination, $totalMB) 'CMD'
        $destDir = Split-Path -Path $Destination -Parent
        if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Copy-Item -LiteralPath $Path -Destination $Destination -Force
        $offset = 0; $completed = $true
    }
    if (-not $completed) {
    # 2. Slice size: 65% of the envelope, shrunk by the Base64 overhead, rounded to 16 KB.
    if ($SliceKB -le 0) {
        $SliceKB = [int]([math]::Floor($info.EnvelopeKB * 0.65 / 1.37 / 16) * 16)
        if ($SliceKB -lt 32) { $SliceKB = 32 }
        if ($SliceKB -gt 4096) { $SliceKB = 4096 }
    }
    $trips = [math]::Ceiling(($local.Length - $offset) / ($SliceKB * 1024))
    # the tool sizes its slices to whatever the server allows; it never suggests changing the server's WinRM configuration
    Write-PatchLog ("{0} - MaxEnvelopeSizekb on the server is {1}, so {2} MB goes over in {3} KB slices = {4} round trips" -f $label, $info.EnvelopeKB, $totalMB, $SliceKB, $trips) 'WHY'

    # 3. Send the slices.  If the server still says the request is too big, halve the slice and carry on.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastTick = -10
    $completed = $false
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $fs.Position = $offset
            $sent = $offset
            $first = ($offset -eq 0)
            $buffer = New-Object byte[] ($SliceKB * 1024)
            while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $b64 = [System.Convert]::ToBase64String($buffer, 0, $read)
                $remoteLength = Invoke-RemoteBlock -Session $Session -ScriptBlock $script:RemoteWriteSliceScript -ArgumentList $Destination, $b64, $first
                $first = $false
                $sent += $read
                if ([long]$remoteLength -ne $sent) { throw "The server reports $remoteLength bytes but $sent were sent - aborting the copy" }
                if ($watch.Elapsed.TotalSeconds - $lastTick -ge 2) {
                    $lastTick = $watch.Elapsed.TotalSeconds
                    $rate = 0
                    if ($watch.Elapsed.TotalSeconds -gt 0) { $rate = [math]::Round(($sent - $offset) / 1MB / $watch.Elapsed.TotalSeconds, 1) }
                    Set-GuiStatus ("Copying {0} to {1}: {2} / {3} MB  ({4} MB/s)" -f $local.Name, $label, [math]::Round($sent / 1MB), $totalMB, $rate)
                    Set-GuiProgress -Percent ([int](100 * $sent / $local.Length))
                }
            }
            $completed = $true
            break
        } catch {
            $msg = Get-ShortError $_
            if ($msg -match 'MaxEnvelopeSize' -and $SliceKB -gt 32) {
                $SliceKB = [int]($SliceKB / 2)
                $again = Invoke-RemoteBlock -Session $Session -ScriptBlock $script:RemoteFileInfoScript -ArgumentList $Destination, $false
                $offset = 0
                if ($again.Exists -and $again.Length -gt 0) { $offset = $again.Length }
                Write-PatchLog ("{0} - the server rejected a slice as too big; retrying with {1} KB slices from {2} MB (attempt {3})" -f $label, $SliceKB, [math]::Round($offset / 1MB, 1), ($attempt + 1)) 'WARN'
            } else {
                throw
            }
        } finally {
            $fs.Close()
        }
    }
    }   # end of the WinRM slice copy
    Set-GuiProgress -Marquee
    if (-not $completed) { throw "$label - the server kept rejecting even small slices (last size $SliceKB KB); what is copied so far stays and the next attempt resumes from it" }

    # 4. Verify: size and SHA256 must match on both sides.  A bad copy is deleted so the next run starts clean.
    Set-GuiStatus "$label - verifying the copy (SHA256)..."
    $final = Invoke-RemoteBlock -Session $Session -ScriptBlock $script:RemoteFileInfoScript -ArgumentList $Destination, $true
    if ($final.Length -ne $local.Length -or $final.Hash -ne $LocalHash) {
        Invoke-RemoteBlock -Session $Session -ScriptBlock $script:RemoteDeleteScript -ArgumentList $Destination | Out-Null
        throw "Copy verification FAILED on $label - size $($final.Length) vs $($local.Length), hash match = $($final.Hash -eq $LocalHash). The staged file was deleted; run the install again."
    }
    $secs = [math]::Round($watch.Elapsed.TotalSeconds)
    $rate = 0
    if ($secs -gt 0) { $rate = [math]::Round(($local.Length - $offset) / 1MB / $secs, 1) }
    Write-PatchLog ("{0} - copy finished: {1} MB in {2} s ({3} MB/s), SHA256 verified" -f $label, $totalMB, $secs, $rate) 'OK'
    return $true
}
