# =====================================================================
#  21-Patching-Analysis.ps1  -  ANALYSE A FAILURE (O/S Patching console)
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  After a failed or rolled-back install the sysadmin needs to know WHERE
#  it broke: in the tool's own run (staging, DISM), at the reboot (the
#  pending operations poqexec.exe applies), or in a third-party control
#  (Trellix Solidcore, Endpoint Security) that denied the servicing stack.
#  The server holds the evidence in several places.  This file reads them
#  (read-only), lines them up on one timeline and says what they point at.
#    RemoteFailureAnalysisScript  runs ON the server: the tool's result
#                                 files and DISM logs, CBS.log, the Setup
#                                 event log, the Windows Update history,
#                                 boots and shutdowns, the Solidcore log,
#                                 security-product events, the state now
#    Get-FailureAnalysis          the fan-out (Invoke-Collector 'Analysis')
#    Get-FailureFindings          the rules: evidence -> findings
#    Get-FailureTimeline          every dated line from every source, sorted
#    Get-FailureAnalysisHtml      the page (details window, saved in reports\)
#    Show-FailureAnalysis         the button: collect, log, save, show
#  Field test, October 2026: an update installed (3010), was rolled back at
#  the reboot (CBS.log full of poqexec errors) and the second update of the
#  run failed on the pending reboot - with Trellix Solidcore in Update Mode
#  by ePO's account.  Nobody could say which control denied what.  This
#  page answers that from the server's own logs.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  21-Patching-Analysis.ps1
# ---------------------------------------------------------------------
#  Added 2026-10-28 after the field test (see CODE-REVIEW.md).  Not yet
#  independently reviewed.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _______cf_______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] read every function   [ ] ran it against a server after a failed install
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  RUNS ON THE TARGET SERVER.  Read-only.  Self contained on purpose.
#  Everything comes back as text lines ("a|b|c") because remoting flattens
#  nested objects; the dates are written the invariant way so the timeline
#  sorts as text.
# ---------------------------------------------------------------------
$script:RemoteFailureAnalysisScript = {
    param([string]$Staging, [int]$HoursBack, [int]$MaxLines)
    $ErrorActionPreference = 'Continue'
    if ($HoursBack -lt 1) { $HoursBack = 72 }
    if ($MaxLines -lt 50) { $MaxLines = 400 }
    $since = (Get-Date).AddHours(-$HoursBack)
    $errors = @()
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $stamp = { param($d) ([datetime]$d).ToString('yyyy-MM-dd HH:mm:ss', $inv) }
    $sinceText = & $stamp $since
    $os = $null; try { $os = Get-CimInstance -ClassName Win32_OperatingSystem } catch { $errors += 'OS: ' + $_.Exception.Message }
    $boot = $null; if ($os) { $boot = $os.LastBootUpTime }

    # 1. The tool's own records: result-*.txt per OS patch at the staging root (software results in \software, for the
    #    timeline - a software 3010 in the same window explains a reboot) and the error lines of the DISM logs.
    $results = @(); $dismLines = @()
    if ($Staging -and (Test-Path -LiteralPath $Staging)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Staging -Filter 'result-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime)) {
            $h = @{}
            foreach ($l in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) { if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
            $results += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f (& $stamp $f.LastWriteTime), $h['KB'], $h['Success'], $h['RebootRequired'], $h['ExitCode'], ([string]$h['Message'] -replace '\|', '/'), $h['File'], $h['Operator']
        }
        foreach ($f in @(Get-ChildItem -LiteralPath $Staging -Filter 'dism-*.log' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime)) {
            $hits = @(Get-Content -LiteralPath $f.FullName -Tail 600 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Error|Failed|failed|0x8' } | Select-Object -Last 12)
            foreach ($l in $hits) { $dismLines += '{0}|{1}' -f $f.Name, ($l.Trim() -replace '\|', '/') }
        }
        $swDir = $Staging.TrimEnd('\') + '\software'
        foreach ($f in @(Get-ChildItem -LiteralPath $swDir -Filter 'result-*.txt' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since } | Sort-Object LastWriteTime)) {
            $h = @{}
            foreach ($l in @(Get-Content -LiteralPath $f.FullName -TotalCount 14 -ErrorAction SilentlyContinue)) { if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
            $results += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f (& $stamp $f.LastWriteTime), ('software: ' + $h['Item']), $h['Success'], $h['RebootRequired'], $h['ExitCode'], ([string]$h['Message'] -replace '\|', '/'), $h['Kind'], $h['Operator']
        }
    }

    # 2. CBS.log, the servicing stack's own log: "YYYY-MM-DD HH:MM:SS, Error  CBS  ..." lines.  The pending operations
    #    at boot are logged as poqexec / "Startup: Primitive operations"; a rollback as "Rollback" / "revert".
    $cbs = @(); $cbsNote = ''
    $cbsPath = Join-Path $env:windir 'Logs\CBS\CBS.log'
    if (Test-Path -LiteralPath $cbsPath) {
        try {
            $all = @(Get-Content -LiteralPath $cbsPath -Tail 60000 -ErrorAction Stop)
            $first = ''; foreach ($l in $all) { if ($l -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})') { $first = $Matches[1]; break } }
            $hits = @()
            foreach ($l in $all) {
                if ($l -notmatch '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}), *(\w+)') { continue }
                if ($Matches[1] -lt $sinceText) { continue }   # the format sorts as text
                if ($Matches[2] -eq 'Error' -or $l -match 'poqexec|Startup: Primitive|Rollback|revert|Failed to|FAILED|ERROR_|0x8[0-9A-Fa-f]{7}') { $hits += ($l.Trim() -replace '\|', '/') }
            }
            if ($hits.Count -gt $MaxLines) { $cbsNote = ('{0} matching lines, the last {1} kept.' -f $hits.Count, $MaxLines); $hits = @($hits | Select-Object -Last $MaxLines) }
            $cbs = $hits
            if ($first -and $first -gt $sinceText) { $cbsNote = ($cbsNote + ' CBS.log starts at ' + $first + ' - earlier lines were rolled into CbsPersist_*.cab next to it.').Trim() }
        } catch { $errors += 'CBS.log: ' + $_.Exception.Message }
    } else { $cbsNote = 'CBS.log not found' }

    # 3. The Setup event log: Microsoft-Windows-Servicing says per package whether it reached the Installed state or
    #    failed, and at which boot.  Read by the stable parts (time, id, provider); the message carries the KB and code.
    $setup = @()
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'Setup'; StartTime = $since } -MaxEvents 300 -ErrorAction Stop | Sort-Object TimeCreated)) {
            $m = [string]$e.Message; if ($m.Length -gt 240) { $m = $m.Substring(0, 240) + '...' }
            $setup += '{0}|{1}|{2}|{3}|{4}' -f (& $stamp $e.TimeCreated), $e.Id, $e.LevelDisplayName, $e.ProviderName, (($m -replace '\s+', ' ') -replace '\|', '/')
        }
    } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $errors += 'Setup log: ' + $_.Exception.Message } }

    # 4. The Windows Update history, with the result code and HResult this time (the status check reads the same list)
    $history = @()
    try {
        $wus = New-Object -ComObject 'Microsoft.Update.Session'; $q = $wus.CreateUpdateSearcher(); $n = [int]$q.GetTotalHistoryCount()
        if ($n -gt 0) {
            foreach ($entry in $q.QueryHistory(0, [math]::Min($n, 60))) {
                if (-not $entry.Date) { continue }
                $when = ([datetime]$entry.Date).ToLocalTime()
                if ($when -lt $since) { continue }
                $kb = ''; if ($entry.Title -match '(?i)(KB\d{6,7})') { $kb = $Matches[1].ToUpper() }
                $res = 'Code ' + $entry.ResultCode
                switch ([int]$entry.ResultCode) { 1 { $res = 'In progress' } 2 { $res = 'Succeeded' } 3 { $res = 'Succeeded with errors' } 4 { $res = 'Failed' } 5 { $res = 'Aborted' } }
                $hr = ''; if ($entry.HResult) { $hr = '0x{0:X8}' -f ($entry.HResult -band 0xFFFFFFFF) }
                $op = 'Install'; if ([int]$entry.Operation -eq 2) { $op = 'Uninstall' }
                $history += '{0}|{1}|{2}|{3}|{4}|{5}' -f (& $stamp $when), $op, $res, $hr, $kb, ([string]$entry.Title -replace '\|', '/')
            }
        }
    } catch { $errors += 'update history: ' + $_.Exception.Message }

    # 5. Boots and shutdowns (System log): 6005 = a boot, 6006 = a clean shutdown, 6008 = unexpected, 1074 = who asked
    #    for the restart and why, 41 = rebooted without a clean shutdown, 1076 = the reason given after an unexpected one
    $boots = @()
    try {
        foreach ($e in @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = @(6005, 6006, 6008, 1074, 41, 1076); StartTime = $since } -MaxEvents 100 -ErrorAction Stop | Sort-Object TimeCreated)) {
            $m = [string]$e.Message; if ($m.Length -gt 200) { $m = $m.Substring(0, 200) + '...' }
            $boots += '{0}|{1}|{2}|{3}' -f (& $stamp $e.TimeCreated), $e.Id, $e.ProviderName, (($m -replace '\s+', ' ') -replace '\|', '/')
        }
    } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $errors += 'System log: ' + $_.Exception.Message } }

    # 6. Trellix Solidcore: its own log (every denied execution and write with the process and the feature that denied
    #    it; update mode begin / end), then whatever McAfee / Trellix / Solidcore / the toolkit wrote to the event logs
    $solid = @(); $solidNote = ''; $solidPath = ''
    foreach ($p in @("$env:ProgramData\McAfee\Solidcore\Logs\solidcore.log", "$env:ProgramData\Trellix\Solidcore\Logs\solidcore.log", "$env:ProgramFiles\McAfee\Solidcore\Logs\solidcore.log")) { if (-not $solidPath -and (Test-Path -LiteralPath $p)) { $solidPath = $p } }
    if ($solidPath) {
        try {
            $raw = @(Get-Content -LiteralPath $solidPath -Tail 20000 -ErrorAction Stop)
            $hits = @()
            foreach ($l in $raw) {
                if ($l -notmatch '(?i)denied|deny|blocked|prevent|violat|update mode|update_mode|begin update|end update|mode change|solidifier') { continue }
                $d = $null
                if ($l -match '^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})') { try { $d = [datetime]::ParseExact($Matches[1] + ' ' + $Matches[2], 'yyyy-MM-dd HH:mm:ss', $inv) } catch { } }
                elseif ($l -match '^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{2}:\d{2}:\d{2})') { try { $d = [datetime]::ParseExact(('{0}/{1}/{2} {3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4]), 'M/d/yyyy HH:mm:ss', $inv) } catch { } }
                if ($d -and $d -lt $since) { continue }
                $hits += ($l.Trim() -replace '\|', '/')
            }
            if ($hits.Count -gt $MaxLines) { $solidNote = ('{0} matching lines, the last {1} kept' -f $hits.Count, $MaxLines); $hits = @($hits | Select-Object -Last $MaxLines) }
            $solid = $hits
        } catch { $errors += 'Solidcore log: ' + $_.Exception.Message }
    } elseif (Get-Service -Name scsrvc -ErrorAction SilentlyContinue) { $solidNote = 'the Solidcore service exists but no solidcore.log was found under ProgramData\McAfee or ProgramData\Trellix' }
    else { $solidNote = 'Solidcore is not on this server' }
    $secEvents = @()
    try {
        $ev = @(Get-WinEvent -FilterHashtable @{ LogName = @('Application', 'System'); StartTime = $since } -MaxEvents 5000 -ErrorAction Stop | Where-Object { $_.ProviderName -match '(?i)mcafee|trellix|solidcore|endpoint security|crowdstrike|sentinel|carbon black|defender|offlinepatcher' } | Sort-Object TimeCreated | Select-Object -Last 150)
        foreach ($e in $ev) {
            $m = [string]$e.Message; if ($m.Length -gt 240) { $m = $m.Substring(0, 240) + '...' }
            $secEvents += '{0}|{1}|{2}|{3}|{4}' -f (& $stamp $e.TimeCreated), $e.ProviderName, $e.Id, $e.LevelDisplayName, (($m -replace '\s+', ' ') -replace '\|', '/')
        }
    } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $errors += 'security product events: ' + $_.Exception.Message } }

    # 7. The state now: pending reboot flags, the pending-operations file, servicing processes, the Solidcore mode
    $state = @()
    $cbsKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $flags = @(); foreach ($k in 'RebootPending', 'PackagesPending', 'RebootInProgress') { if (Test-Path -LiteralPath "$cbsKey\$k") { $flags += "CBS:$k" } }
    foreach ($k in 'RebootRequired', 'PostRebootReporting') { if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\$k") { $flags += "WU:$k" } }
    $state += 'Pending reboot flags: ' + $(if ($flags.Count -gt 0) { $flags -join ', ' } else { 'none' })
    foreach ($p in @((Join-Path $env:windir 'WinSxS\pending.xml'), (Join-Path $env:windir 'WinSxS\poqexec.log'))) {
        if (Test-Path -LiteralPath $p) { $fi = Get-Item -LiteralPath $p -Force; $state += ('{0}: present, {1} KB, written {2}' -f (Split-Path -Path $p -Leaf), [int]($fi.Length / 1KB), (& $stamp $fi.LastWriteTime)) }
        else { $state += ('{0}: absent' -f (Split-Path -Path $p -Leaf)) }
    }
    $procs = @(Get-Process -Name dism, TiWorker, TrustedInstaller, wusa, poqexec -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
    $state += 'Servicing processes now: ' + $(if ($procs.Count -gt 0) { $procs -join ', ' } else { 'none' })
    $sadmin = $null
    foreach ($p in @("$env:ProgramFiles\McAfee\Solidcore\sadmin.exe", "$env:ProgramFiles\Trellix\Solidcore\sadmin.exe")) { if (-not $sadmin -and (Test-Path -LiteralPath $p)) { $sadmin = $p } }
    if ($sadmin) {
        try { foreach ($l in @(& { $ErrorActionPreference = 'Continue'; & $sadmin status 2>&1 } | ForEach-Object { [string]$_ } | Where-Object { $_.Trim() } | Select-Object -First 12)) { $state += 'sadmin status: ' + $l.Trim() } }
        catch { $state += 'sadmin status failed: ' + $_.Exception.Message }
    }
    $state += 'Last boot: ' + $(if ($boot) { & $stamp $boot } else { 'unknown' })

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Since = $sinceText; HoursBack = $HoursBack; LastBoot = $(if ($boot) { & $stamp $boot } else { '' })
        Results = $results; DismLines = $dismLines; Cbs = $cbs; CbsNote = $cbsNote; SetupEvents = $setup; History = $history
        BootEvents = $boots; Solidcore = $solid; SolidcoreNote = $solidNote; SolidcorePath = $solidPath; SecurityEvents = $secEvents
        State = $state; Errors = $errors
    }
}

function Get-FailureAnalysis {
    # The fan-out: one Analysis result per server under $script:Results['Analysis'].
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = { param($r) ('{0} result file(s), {1} DISM error line(s), {2} CBS line(s), {3} Setup event(s), {4} Solidcore line(s), {5} security-product event(s)' -f @($r.Results).Count, @($r.DismLines).Count, @($r.Cbs).Count, @($r.SetupEvents).Count, @($r.Solidcore).Count, @($r.SecurityEvents).Count) }
    return (Invoke-Collector -Name 'Analysis' -ScriptBlock $script:RemoteFailureAnalysisScript -ComputerName $ComputerName -ArgumentList @($script:Config.RemoteStaging, [int]$script:Config.AnalysisHoursBack, 400) -TimeoutSec 300 -Summary $summary)
}

# What the common codes mean, in the words the page uses.  DISM, CBS and the update history all speak HRESULT.
$script:ServicingCodeMeaning = @{
    '0x800F0922' = 'the install failed: a pending reboot, a missing servicing stack update, or a full System Reserved partition'
    '0x800F081E' = 'not applicable: the wrong Windows build, or a missing prerequisite'
    '0x80070002' = 'a file was not found: the copy or the extract was incomplete'
    '0x80070005' = 'ACCESS DENIED: something on the server refused the file or registry operation - a third-party control (Solidcore, Endpoint Security) is the usual cause'
    '0x80070020' = 'SHARING VIOLATION: a file was held open - an on-access scanner or a backup agent'
    '0x80073712' = 'the component store is corrupt (DISM /Online /Cleanup-Image /RestoreHealth with a source, then try again)'
    '0x800F0831' = 'a package is missing from the component store: the previous cumulative update is incomplete'
    '0x800F0982' = 'a component is missing or was removed (a language pack or a feature on demand)'
    '0x80240016' = 'another install was in progress'
    '0x800F0841' = 'the package is not installed'
    '0x80070BC2' = 'installed - a reboot is required (3010): not a failure'
}

function Get-ServicingCodeText {
    # "0x800F0922 (the install failed: ...)" for the first HRESULT in a line, '' when it holds none.
    param([string]$Text)
    if ($Text -match '(0x8[0-9A-Fa-f]{7})') {
        $code = '0x' + $Matches[1].Substring(2).ToUpper()
        $m = $script:ServicingCodeMeaning[$code]
        if ($m) { return ('{0} ({1})' -f $code, $m) }
        return $code
    }
    if ($Text -match 'ERROR_ACCESS_DENIED') { return 'ERROR_ACCESS_DENIED (' + $script:ServicingCodeMeaning['0x80070005'] + ')' }
    if ($Text -match 'ERROR_SHARING_VIOLATION') { return 'ERROR_SHARING_VIOLATION (' + $script:ServicingCodeMeaning['0x80070020'] + ')' }
    return ''
}

function Get-FailureFindings {
    # The rules: the collected evidence of ONE server -> findings, worst first.  Each says where it broke (the tool's
    # run, at the boot, Solidcore, a security product, Windows Update, the state now), what was seen and what to do.
    param($Result)
    $out = New-Object System.Collections.Generic.List[object]
    $add = { param([string]$Light, [string]$Where, [string]$Finding, [string]$Evidence, [string]$Next) $out.Add([pscustomobject]@{ Light = $Light; Where = $Where; Finding = $Finding; Evidence = $Evidence; Next = $Next }) }
    if (-not $Result) { & $add 'Grey' 'Not collected' 'No analysis has been collected for this server yet' '' 'Tick the server and press "Analyse a failure (ticked)".'; return @($out) }
    if (-not $Result.Reachable) { & $add 'Grey' 'Unreachable' ('The server could not be reached: ' + $Result.Error) '' 'Fix the WinRM problem first (grey row, "Test WinRM port").'; return @($out) }
    $boot = $null; if ($Result.LastBoot) { try { $boot = [datetime]::ParseExact([string]$Result.LastBoot, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { } }
    $afterBoot = { param([string]$When) if (-not $boot) { return $false }; try { $t = [datetime]::ParseExact($When, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture); return ($t -ge $boot -and $t -le $boot.AddMinutes(45)) } catch { return $false } }

    # A. the tool's own result files: every failed install, and a second file refused on the first one's pending reboot
    $rows = @(foreach ($l in @($Result.Results)) { $f = $l -split '\|'; if ($f.Count -ge 6) { [pscustomobject]@{ When = $f[0]; KB = $f[1]; Success = ($f[2] -eq 'True'); Reboot = ($f[3] -eq 'True'); Exit = $f[4]; Message = $f[5] } } })
    $lastReboot = $null
    # the boots in the window (System 6005): a 3010 that a boot has already finished leaves nothing pending (R6-B13)
    $bootTimes = @(foreach ($l in @($Result.BootEvents)) { $f = $l -split '\|', 4; if ($f.Count -ge 4 -and $f[1] -eq '6005') { [string]$f[0] } })
    foreach ($r in $rows) {
        if ($lastReboot -and @($bootTimes | Where-Object { $_ -gt [string]$lastReboot.When -and $_ -le [string]$r.When }).Count -gt 0) { $lastReboot = $null }   # yyyy-MM-dd HH:mm:ss compares as text
        if ($r.Success) { if ($r.Reboot) { $lastReboot = $r }; continue }
        $meaning = Get-ServicingCodeText -Text ($r.Message + ' ' + $r.Exit)
        $step = 'Read the DISM log lines below; the code says what DISM hit.'
        if ($lastReboot -and $r.Message -match '(?i)pending reboot') {
            & $add 'Red' 'The tool''s run' ('{0} was refused because {1} had left a reboot pending (installed {2}, exit 3010)' -f $r.KB, $lastReboot.KB, $lastReboot.When) ('result file {0}: {1}' -f $r.When, $r.Message) 'Reboot, then install the second file. With "One patch per server per run" (Settings tab, on by default) the second file now waits for the reboot by itself.'
            continue
        }
        if ($r.Message -match '(?i)pending reboot') { $step = 'Reboot the server, check status, then install again.' }
        elseif ($meaning -match '0x80070005|0x80070020') { $step = 'A control on the server denied the operation: compare the Solidcore and security-product lines of the same minute below.' }
        elseif ($r.Message -match '(?i)hash changed|signature') { $step = 'Copy the file again (the staged copy differed from the one on this PC), or download it afresh.' }
        & $add 'Red' 'The tool''s run' ('{0} failed: {1}' -f $r.KB, $r.Message) ('result file {0}, exit {1}{2}' -f $r.When, $r.Exit, $(if ($meaning) { ' = ' + $meaning } else { '' })) $step
    }
    # B. the DISM logs' own error lines (one finding per log)
    foreach ($g in @(@($Result.DismLines) | Group-Object { ($_ -split '\|')[0] })) {
        $lines = @($g.Group | ForEach-Object { ($_ -split '\|', 2)[1] })
        $codes = @($lines | ForEach-Object { Get-ServicingCodeText -Text $_ } | Where-Object { $_ } | Select-Object -Unique)
        & $add 'Amber' 'The tool''s run (DISM log)' ('{0}: {1} error line(s){2}' -f $g.Name, $lines.Count, $(if ($codes.Count -gt 0) { ' - ' + ($codes -join '; ') } else { '' })) ($lines[-1]) 'The whole log is C:\PatchStaging\<this file> on the server.'
    }
    # C. the Setup log: a package that reached the Installed state and later failed was rolled back; a failure in the
    #    first minutes after a boot is the pending operations failing
    $setup = @(foreach ($l in @($Result.SetupEvents)) { $f = $l -split '\|', 5; if ($f.Count -ge 5) { [pscustomobject]@{ When = $f[0]; Id = $f[1]; Level = $f[2]; Provider = $f[3]; Message = $f[4] } } })
    $okKb = @{}; $okHow = @{}
    foreach ($e in $setup) {
        $kb = ''; if ($e.Message -match '(?i)(KB\d{6,7})') { $kb = $Matches[1].ToUpper() }
        if ($e.Message -match '(?i)successfully changed to the Installed state|was successfully changed') { if ($kb) { $okKb[$kb] = $e.When; $okHow[$kb] = 'installed' }; continue }
        # a 3010 package never reaches "Installed" before the boot: Windows logs "A reboot is necessary before package KB...
        # can be changed to the Installed state" instead - the field case (installed, rolled back at the boot) starts here (R6-B14)
        if ($e.Message -match '(?i)reboot is necessary before package') { if ($kb) { $okKb[$kb] = $e.When; $okHow[$kb] = 'staged, waiting for the reboot' }; continue }
        if ($e.Message -notmatch '(?i)fail|could not|error|not be installed|unsuccessful') { continue }
        $meaning = Get-ServicingCodeText -Text $e.Message
        $atBoot = & $afterBoot $e.When
        if ($kb -and $okKb.ContainsKey($kb)) {
            & $add 'Red' 'At the boot' ('{0} was ROLLED BACK: {1} at {2}, then failed at {3}{4}' -f $kb, $okHow[$kb], $okKb[$kb], $e.When, $(if ($atBoot) { ' (in the minutes after the boot at ' + $Result.LastBoot + ')' } else { '' })) ('Setup log event {0}: {1}{2}' -f $e.Id, $e.Message, $(if ($meaning) { ' = ' + $meaning } else { '' })) 'The pending operations (poqexec.exe) were denied or failed at the boot: see the CBS and Solidcore findings of the same minutes. The server runs without this update now - the grid shows it READY again.'
        } else {
            & $add $(if ($atBoot) { 'Red' } else { 'Amber' }) $(if ($atBoot) { 'At the boot' } else { 'Windows servicing' }) ('Setup log: {0}' -f $e.Message) ('event {0} at {1}{2}' -f $e.Id, $e.When, $(if ($meaning) { ' = ' + $meaning } else { '' })) 'Match the time against the CBS lines below.'
        }
    }
    # D. CBS.log: poqexec failures = the pending operations at boot; rollbacks; other errors
    $cbs = @($Result.Cbs | ForEach-Object { [string]$_ })
    $poq = @($cbs | Where-Object { $_ -match '(?i)poqexec' -and $_ -match '(?i)error|fail|0x8[0-9A-F]{7}|ERROR_' })
    if ($poq.Count -gt 0) {
        $codes = @($poq | ForEach-Object { Get-ServicingCodeText -Text $_ } | Where-Object { $_ } | Select-Object -Unique)
        & $add 'Red' 'At the boot' ('The pending operations at the boot failed (poqexec.exe): {0} CBS line(s){1}' -f $poq.Count, $(if ($codes.Count -gt 0) { ' - ' + ($codes -join '; ') } else { '' })) ($poq[0]) 'This is the step a Solidifier in Enabled mode denies (and an access-protection rule can too). The Solidcore and security-product lines of the same minutes below say which control fired - that line is what the ePO team needs.'
    }
    $rollback = @($cbs | Where-Object { $_ -match '(?i)rollback|revert' -and $_ -notmatch '(?i)poqexec' })
    if ($rollback.Count -gt 0) { & $add 'Amber' 'Windows servicing' ('CBS reports a rollback or revert: {0} line(s)' -f $rollback.Count) ($rollback[0]) 'Read the lines around it in C:\Windows\Logs\CBS\CBS.log on the server.' }
    $otherErr = @($cbs | Where-Object { $_ -match ', Error' -and $_ -notmatch '(?i)poqexec|rollback|revert' })
    if ($otherErr.Count -gt 0) {
        $codes = @($otherErr | ForEach-Object { Get-ServicingCodeText -Text $_ } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 4)
        & $add 'Amber' 'Windows servicing' ('CBS.log: {0} other error line(s){1}' -f $otherErr.Count, $(if ($codes.Count -gt 0) { ' - ' + ($codes -join '; ') } else { '' })) ($otherErr[-1]) 'Most are harmless on their own; the ones in the minutes of a failure above are not.'
    }
    # E. the Windows Update history: entries that failed
    foreach ($l in @($Result.History)) {
        $f = $l -split '\|', 6
        if ($f.Count -lt 6 -or $f[2] -notmatch '(?i)fail|abort') { continue }
        $meaning = ''; if ($f[3]) { $meaning = Get-ServicingCodeText -Text $f[3] }
        & $add 'Amber' 'Windows Update' ('Update history: {0} {1} {2}' -f $f[4], $f[1].ToLower(), $f[2].ToLower()) ('{0}{1}: {2}' -f $f[0], $(if ($meaning) { ', ' + $meaning } else { '' }), $f[5]) 'The same install seen from the Windows Update agent; the Setup log and CBS say why.'
    }
    # F. Solidcore: denials by the servicing stack are the smoking gun; other denials and the update-mode markers for context
    $solid = @($Result.Solidcore | ForEach-Object { [string]$_ })
    $denied = @($solid | Where-Object { $_ -match '(?i)denied|deny|blocked|prevent|violat' })
    $servicing = @($denied | Where-Object { $_ -match '(?i)poqexec|trustedinstaller|tiworker|dism|wusa|expand\.exe|msiexec' })
    if ($servicing.Count -gt 0) {
        $procs = @($servicing | ForEach-Object { if ($_ -match '(?i)(poqexec|trustedinstaller|tiworker|dismhost|dism|wusa|expand|msiexec)(\.exe)?') { $Matches[1].ToLower() + '.exe' } } | Select-Object -Unique)
        & $add 'Red' 'Trellix Solidcore' ('Solidcore denied {0} operation(s) by the servicing stack ({1})' -f $servicing.Count, ($procs -join ', ')) ($servicing[0]) 'The line names the feature that fired (execution control, write protection, memory protection ...). Update Mode did not cover it - this is the line for the ePO team.'
    }
    if ($denied.Count -gt $servicing.Count) { & $add 'Amber' 'Trellix Solidcore' ('Solidcore denied {0} other operation(s) in the window' -f ($denied.Count - $servicing.Count)) (@($denied | Where-Object { $servicing -notcontains $_ })[0]) 'Not the servicing stack; listed for completeness.' }
    $modes = @($solid | Where-Object { $_ -match '(?i)update mode|update_mode|begin update|end update|mode change' })
    if ($modes.Count -gt 0) { & $add 'Grey' 'Trellix Solidcore' ('{0} update-mode line(s) in the window: did the window cover the boot at {1}?' -f $modes.Count, $Result.LastBoot) ($modes[0] + $(if ($modes.Count -gt 1) { ' ... ' + $modes[-1] } else { '' })) 'An ePO Update Mode task has a duration; a reboot after it ended runs the pending operations in Enabled mode.' }
    elseif ($Result.SolidcorePath) { & $add 'Grey' 'Trellix Solidcore' 'No update-mode line in the window of the Solidcore log' $Result.SolidcorePath 'Check in ePO when the Update Mode task ran against the boot time.' }
    elseif ($Result.SolidcoreNote) { & $add 'Grey' 'Trellix Solidcore' $Result.SolidcoreNote '' '' }
    # G. security products and the toolkit's own events
    $sec = @(foreach ($l in @($Result.SecurityEvents)) { $f = $l -split '\|', 5; if ($f.Count -ge 5) { [pscustomobject]@{ When = $f[0]; Provider = $f[1]; Id = $f[2]; Level = $f[3]; Message = $f[4] } } })
    $secBad = @($sec | Where-Object { $_.Level -match '(?i)error|warning|critical' -and $_.Provider -notmatch '(?i)offlinepatcher' })
    if ($secBad.Count -gt 0) {
        $provs = @($secBad | ForEach-Object { $_.Provider } | Select-Object -Unique)
        & $add 'Amber' 'Security product' ('{0} error or warning event(s) from {1}' -f $secBad.Count, ($provs -join ', ')) ('{0} {1} {2}: {3}' -f $secBad[0].When, $secBad[0].Provider, $secBad[0].Id, $secBad[0].Message) 'Access-protection and on-access-scan denials of the servicing stack show up here when the product logs to the event log.'
    }
    # H. boots and shutdowns
    $boots = @(foreach ($l in @($Result.BootEvents)) { $f = $l -split '\|', 4; if ($f.Count -ge 4) { [pscustomobject]@{ When = $f[0]; Id = $f[1]; Provider = $f[2]; Message = $f[3] } } })
    foreach ($b in @($boots | Where-Object { $_.Id -in '6008', '41' })) { & $add 'Amber' 'At the boot' ('Unexpected shutdown or reset at {0} (event {1})' -f $b.When, $b.Id) $b.Message 'A reset in the middle of the pending operations leaves the update half applied; the next boot rolls it back.' }
    $starts = @($boots | Where-Object { $_.Id -eq '6005' })
    if ($starts.Count -gt 0) { & $add 'Grey' 'At the boot' ('{0} boot(s) in the window: {1}' -f $starts.Count, (($starts | ForEach-Object { $_.When }) -join ', ')) '' 'The pending operations of an install run at the first boot after it.' }
    foreach ($b in @($boots | Where-Object { $_.Id -eq '1074' } | Select-Object -First 3)) { & $add 'Grey' 'At the boot' ('Restart requested at {0}' -f $b.When) $b.Message '' }
    # I. the state now
    $state = @($Result.State | ForEach-Object { [string]$_ })
    $flags = @($state | Where-Object { $_ -match '^Pending reboot flags: (?!none)' })
    if ($flags.Count -gt 0) { & $add 'Amber' 'State now' 'A reboot is still pending' $flags[0] 'poqexec.exe applies the pending operations at the next boot: make sure Solidcore is in Update Mode (now AND on reboot) before that reboot.' }
    $sadminNow = ''; $sadminLater = ''
    foreach ($l in $state) { if ($l -match '(?i)solidifier on reboot\s*:\s*(.+?)\s*$') { $sadminLater = $Matches[1] } elseif ($l -match '(?i)solidifier\s*:\s*(.+?)\s*$') { $sadminNow = $Matches[1] } }
    if ($sadminNow -or $sadminLater) {
        $enforcing = @(@($sadminNow, $sadminLater) | Where-Object { $_ -and $_ -notmatch '(?i)update|disabled' })
        if ($enforcing.Count -gt 0) { & $add 'Red' 'State now' ('Solidcore is ENFORCING: {0} now, {1} on reboot' -f $sadminNow, $sadminLater) 'sadmin status' 'An install or a reboot now would be rolled back. Run the Update Mode task first.' }
        else { & $add 'Grey' 'State now' ('Solidcore: {0} now, {1} on reboot' -f $sadminNow, $sadminLater) 'sadmin status' '' }
    }
    foreach ($e in @($Result.Errors)) { & $add 'Grey' 'Could not read' ([string]$e) '' 'Run the analysis as an administrator of the server, or read that source by hand.' }
    if (@($out | Where-Object { $_.Light -in 'Red', 'Amber' }).Count -eq 0) {
        & $add 'Grey' 'Nothing found' ('Nothing in the last {0} h points at a failure: no failed result file, no DISM error, no failed Setup event, no poqexec error, no Solidcore denial' -f $Result.HoursBack) '' 'Widen the window (AnalysisHoursBack in lib\01-Config.ps1) if the failure is older, or check the dates in the timeline.'
    }
    $rank = @{ Red = 0; Amber = 1; Grey = 2 }
    return @($out | Sort-Object @{ Expression = { $rank[$_.Light] } })
}

function Get-FailureTimeline {
    # Every dated line from every source on one list, oldest first; undated Solidcore lines go last.
    param($Result)
    $rows = New-Object System.Collections.Generic.List[object]
    $put = { param([string]$When, [string]$Source, [string]$Text) $light = ''; if ($Text -match '(?i)error|fail|denied|rollback|revert|unexpected|refused') { $light = 'Amber' }; $rows.Add([pscustomobject]@{ Light = $light; Time = $When; Source = $Source; Event = $Text }) }
    if (-not $Result -or -not $Result.Reachable) { return @() }
    foreach ($l in @($Result.Results)) { $f = $l -split '\|'; if ($f.Count -ge 6) { & $put $f[0] 'Tool result file' ('{0}: {1} (success {2}, exit {3})' -f $f[1], $f[5], $f[2], $f[4]) } }
    foreach ($l in @($Result.Cbs)) { if ($l -match '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}), *(\w+)\s+(.*)$') { & $put $Matches[1] 'CBS.log' ($Matches[2] + ' ' + $Matches[3]) } }
    foreach ($l in @($Result.SetupEvents)) { $f = $l -split '\|', 5; if ($f.Count -ge 5) { & $put $f[0] 'Setup log' ('event {0} {1}: {2}' -f $f[1], $f[2], $f[4]) } }
    foreach ($l in @($Result.History)) { $f = $l -split '\|', 6; if ($f.Count -ge 6) { & $put $f[0] 'Update history' ('{0} {1} {2} {3} {4}' -f $f[1], $f[2], $f[3], $f[4], $f[5]) } }
    foreach ($l in @($Result.BootEvents)) { $f = $l -split '\|', 4; if ($f.Count -ge 4) { & $put $f[0] 'System log' ('event {0}: {1}' -f $f[1], $f[3]) } }
    foreach ($l in @($Result.SecurityEvents)) { $f = $l -split '\|', 5; if ($f.Count -ge 5) { & $put $f[0] $f[1] ('event {0} {1}: {2}' -f $f[2], $f[3], $f[4]) } }
    $undated = @()
    foreach ($l in @($Result.Solidcore)) {
        $s = [string]$l
        if ($s -match '^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})') { & $put ($Matches[1] + ' ' + $Matches[2]) 'Solidcore log' $s }
        elseif ($s -match '^(\d{1,2})/(\d{1,2})/(\d{4}) (\d{2}:\d{2}:\d{2})') { & $put ('{0}-{1:d2}-{2:d2} {3}' -f $Matches[3], [int]$Matches[1], [int]$Matches[2], $Matches[4]) 'Solidcore log' $s }
        else { $undated += $s }
    }
    $sorted = @($rows | Sort-Object Time)
    foreach ($u in $undated) { $sorted += [pscustomobject]@{ Light = ''; Time = '(no date)'; Source = 'Solidcore log'; Event = $u } }
    return $sorted
}

function Get-FailureAnalysisHtml {
    # The page: the findings first, the timeline, then every source as the server gave it.
    param([string]$Server)
    $r = Get-CollectorResult -Name 'Analysis' -Server $Server
    if (-not $r) { return (New-DetailsHtml -Title "Failure analysis: $Server" -Console 'Patching' -Subtitle 'not collected yet - tick the server and press "Analyse a failure (ticked)"') }
    if (-not $r.Reachable) { return (New-DetailsHtml -Title "Failure analysis: $Server" -Console 'Patching' -Subtitle ('unreachable: ' + $r.Error)) }
    $facts = @(, @('Collected', $r.Checked.ToString('yyyy-MM-dd HH:mm:ss')))
    $facts += @(@('Window', ('last {0} h, since {1}' -f $r.HoursBack, $r.Since)), @('Last boot', [string]$r.LastBoot), @('Answered as', [string]$r.Computer))
    $findings = @(Get-FailureFindings -Result $r)
    $timeline = @(Get-FailureTimeline -Result $r)
    $sections = @(
        @{ Heading = 'What the evidence says'; Rows = $findings; Columns = @('Light', 'Where', 'Finding', 'Evidence', 'Next'); Note = 'Red = the failure and where it happened; Amber = something that needs reading; Grey = context. "At the boot" = the pending operations poqexec.exe applies after a 3010, under the Solidcore mode "on reboot".' },
        @{ Heading = ('Timeline - every dated line from every source, oldest first ({0})' -f $timeline.Count); Rows = $timeline; Columns = @('Light', 'Time', 'Source', 'Event'); NoWrap = @('Time', 'Source') },
        @{ Heading = 'The tool''s result files on the server'; Rows = (ConvertFrom-PipeLines -Lines $r.Results -Columns @('When', 'Item', 'Success', 'Reboot', 'Exit', 'Message', 'File', 'Operator')); Columns = @('When', 'Item', 'Success', 'Reboot', 'Exit', 'Message', 'File', 'Operator'); Note = ('result-*.txt in {0} (OS patches) and its software\ folder, written by the install script itself - they survive a lost connection.' -f $script:Config.RemoteStaging) },
        @{ Heading = 'DISM log error lines'; Lines = @($r.DismLines | ForEach-Object { [string]$_ -replace '^([^|]+)\|', '$1:  ' }); Note = ('dism-*.log in {0}: the last error, failed and 0x8... lines of each log in the window.' -f $script:Config.RemoteStaging) },
        @{ Heading = ('CBS.log ({0} line(s))' -f @($r.Cbs).Count); Lines = @($r.Cbs); Note = ('C:\Windows\Logs\CBS\CBS.log: every Error line and every poqexec, Startup, rollback, revert and 0x8... line in the window. ' + $r.CbsNote).Trim() },
        @{ Heading = 'Setup event log'; Rows = (ConvertFrom-PipeLines -Lines $r.SetupEvents -Columns @('Time', 'Id', 'Level', 'Provider', 'Message')); Columns = @('Time', 'Id', 'Level', 'Provider', 'Message'); Note = 'Microsoft-Windows-Servicing: per package, whether it reached the Installed state or failed, and when.' },
        @{ Heading = 'Windows Update history'; Rows = (ConvertFrom-PipeLines -Lines $r.History -Columns @('Date', 'Operation', 'Result', 'HResult', 'KB', 'Title')); Columns = @('Date', 'Operation', 'Result', 'HResult', 'KB', 'Title') },
        @{ Heading = 'Boots and shutdowns'; Rows = (ConvertFrom-PipeLines -Lines $r.BootEvents -Columns @('Time', 'Id', 'Provider', 'Message')); Columns = @('Time', 'Id', 'Provider', 'Message'); Note = '6005 = a boot, 6006 = a clean shutdown, 6008 = unexpected, 1074 = who asked and why, 41 = reset without a clean shutdown.' },
        @{ Heading = ('Trellix Solidcore log ({0} line(s))' -f @($r.Solidcore).Count); Lines = @($r.Solidcore); Note = (($(if ($r.SolidcorePath) { $r.SolidcorePath + ': every denied, blocked, prevented and update-mode line in the window. ' } else { '' }) + [string]$r.SolidcoreNote).Trim()) },
        @{ Heading = 'Security-product and toolkit events'; Rows = (ConvertFrom-PipeLines -Lines $r.SecurityEvents -Columns @('Time', 'Provider', 'Id', 'Level', 'Message')); Columns = @('Time', 'Provider', 'Id', 'Level', 'Message'); Note = 'Application and System log entries from McAfee, Trellix, Solidcore, Endpoint Security, Defender, CrowdStrike, SentinelOne, Carbon Black and the toolkit (OfflinePatcher).' },
        @{ Heading = 'State now'; Lines = @($r.State) })
    if (@($r.Errors).Count -gt 0) { $sections += @{ Heading = 'Could not read'; Lines = @($r.Errors); Note = 'Sources the analysis could not open on the server (rights, or not there).' } }
    $sections += Get-ChangeLogSection -Server $Server
    return (New-DetailsHtml -Title "Failure analysis: $Server" -Subtitle ('what the server''s own logs say about the last {0} hours - read-only' -f $r.HoursBack) -Console 'Patching' -Facts $facts -Sections $sections)
}

function Save-FailureAnalysis {
    # The page also lands in reports\ (Analysis-<server>-<stamp>.html) so it can go into a ticket as it is.
    param([string]$Server, [string]$Html)
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    $path = Join-Path $script:Config.ReportFolder ('Analysis-{0}-{1}.html' -f ($Server -replace '[^\w.-]', '_'), (Get-Date -Format 'yyyyMMdd-HHmmss'))
    [System.IO.File]::WriteAllText($path, $Html, (New-Object System.Text.UTF8Encoding($true)))
    return $path
}

function Show-FailureAnalysis {
    # The button: collect from the ticked servers, log the red and amber findings, save and show one page per server.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $names = @(Get-UniqueNames $ComputerName)
    Write-PatchLog ("Failure analysis requested by {0} for {1}: the last {2} h of the servers' own logs, read-only" -f (Get-OperatorIdentity), ($names -join ', '), $script:Config.AnalysisHoursBack) 'WHY'
    $callStart = Get-Date
    $null = Get-FailureAnalysis -ComputerName $names
    foreach ($n in $names) {
        $r = Get-CollectorResult -Name 'Analysis' -Server $n
        if (-not $r -or -not $r.Reachable) { continue }
        # a server skipped this time (an install is running there, the analysis ran alongside it) keeps an older result:
        # never shown or saved as today's, and its run note is left alone (R6-B03)
        if (-not ($r.Checked -is [datetime]) -or $r.Checked -lt $callStart) { Write-PatchLog ('{0} - not analysed now (an install is running there); analyse it when the run has finished' -f $n) 'WARN'; continue }
        # an install run that ended without a result stays flagged until it has been looked at: this is the look
        $flag = Get-InstallFlag -Server $n
        if ($flag -and [string]$flag.State -eq 'unknown') { Clear-InstallFlag -Server ([string]$flag.Server); Write-PatchLog ('{0} - the unknown install run {1} ({2}) is cleared: analysed by {3}' -f $n, $flag.Stamp, $flag.Note, (Get-OperatorIdentity)) 'INFO' }
        foreach ($f in @(Get-FailureFindings -Result $r | Where-Object { $_.Light -in 'Red', 'Amber' })) {
            $lvl = 'WARN'; if ($f.Light -eq 'Red') { $lvl = 'ERROR' }
            Write-PatchLog ('{0} - {1}: {2}' -f $n, $f.Where, $f.Finding) $lvl
        }
        $html = Get-FailureAnalysisHtml -Server $n
        try { Write-PatchLog ('{0} - analysis page saved: {1}' -f $n, (Save-FailureAnalysis -Server $n -Html $html)) 'OK' } catch { Write-PatchLog ('{0} - the analysis page could not be saved: {1}' -f $n, (Get-ShortError $_)) 'WARN' }
        if (-not (Test-GuiDialogAllowed 'The analysis page')) { continue }
        Show-DetailsWindow -Title "Failure analysis: $n" -Html $html
    }
}
