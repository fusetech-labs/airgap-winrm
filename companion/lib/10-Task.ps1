# =====================================================================
#  10-Task.ps1  -  THIS TOOL AS A SCHEDULED TASK
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The Schedule tab registers one task (\WinRMToolkit\Airgap Download
#  Toolkit) that runs this launcher with -Unattended at the time and on
#  the days of the Settings tab, as the operator who registers it.  The
#  tab watches it: the task's own state and last result from the Task
#  Scheduler, and the outcome of the last run from settings\last-run.json,
#  which every run writes.  Nothing here changes the library.
# =====================================================================

# keyed by the code as text: the Task Scheduler's codes run past what an Int32 holds
$script:TaskResultTexts = @{ '0' = 'completed - every product current or fetched'; '1' = 'exit code 1: a check, a download or a verification failed - see the log and the report'
    '267008' = 'ready'; '267009' = 'running now'; '267010' = 'disabled'; '267011' = 'has not run yet'; '267014' = 'stopped by the user'; '267015' = 'the task has no trigger'
    '2147942402' = 'the file was not found: the launcher moved?'; '2147750687' = 'already running when the next start came - the new start was skipped'
    '2147943645' = 'the account was not logged on at the start time: an Interactive task runs only while its user is logged on'
    '2147943785' = 'Windows did not let this account log on as a batch job, which an S4U task needs: choose Interactive on the Settings tab (it needs no extra right) and register again' }

function Get-TaskDayNames {
    # A weekly trigger holds its days as a bit mask (Sunday = 1, Monday = 2, Tuesday = 4 ...): the names, in week order.
    param([int]$Mask)
    $names = @()
    for ($i = 0; $i -lt 7; $i++) { if ($Mask -band (1 -shl $i)) { $names += [string][System.DayOfWeek]$i } }
    return ($names -join ', ')
}

function Get-TaskResultText {
    param([int64]$Code)
    $k = [string]$Code
    if ($script:TaskResultTexts.ContainsKey($k)) { return $script:TaskResultTexts[$k] }
    return ('result 0x{0:X8}' -f ($Code -band 0xFFFFFFFF))
}

function Get-TaskLauncherPath { return (Join-Path $script:RootFolder 'Start-DownloadToolkit.ps1') }

function Get-TaskArguments {
    return ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Unattended' -f (Get-TaskLauncherPath))
}

function Get-TaskScheduleText {
    $d = [string]$script:Config.TaskDays
    if ($d -ieq 'Daily') { return ('every day at {0}' -f $script:Config.TaskTime) }
    return ('every {0} at {1}' -f $d, $script:Config.TaskTime)
}

function Get-DownloadTask {
    return (Get-ScheduledTask -TaskName $script:Config.TaskName -TaskPath $script:Config.TaskFolder -ErrorAction SilentlyContinue)
}

function Read-LastRun {
    # settings\last-run.json, or $null.
    $p = $script:Config.LastRunFile
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return ([System.IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop) } catch { Write-PatchLog ("last-run.json could not be read: {0}" -f (Get-ShortError $_)) 'WARN'; return $null }
}

function Get-DownloadTaskState {
    # Everything the Schedule tab shows about the task and the last run.
    $t = Get-DownloadTask
    $o = [ordered]@{ Registered = $false; Name = ($script:Config.TaskFolder + $script:Config.TaskName); State = 'not registered'; LastRun = ''; LastResult = ''; LastResultCode = $null; NextRun = ''; RunsAs = ''; Logon = ''; Trigger = ''; Command = ''; PointsHere = $false; Author = ''; Enabled = $false; Problems = @() }
    if ($t) {
        $o.Registered = $true; $o.State = [string]$t.State; $o.Author = [string]$t.Author; $o.Enabled = ($t.Settings.Enabled -ne $false)
        try { $o.RunsAs = [string]$t.Principal.UserId; $o.Logon = [string]$t.Principal.LogonType } catch { }
        try { $info = Get-ScheduledTaskInfo -TaskName $script:Config.TaskName -TaskPath $script:Config.TaskFolder -ErrorAction Stop
            if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $o.LastRun = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
            if ($info.NextRunTime -and $info.NextRunTime.Year -gt 1999) { $o.NextRun = $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') }
            $o.LastResultCode = [int64]$info.LastTaskResult; $o.LastResult = Get-TaskResultText -Code $info.LastTaskResult
        } catch { $o.Problems += ('the task info could not be read: ' + (Get-ShortError $_)) }
        $trig = @($t.Triggers)
        if ($trig.Count -gt 0) {
            $tr = $trig[0]; $start = ''; try { $start = ([datetime]$tr.StartBoundary).ToString('HH:mm') } catch { $start = [string]$tr.StartBoundary }
            $days = ''; try { if ($tr.DaysOfWeek) { $days = 'every ' + (Get-TaskDayNames -Mask ([int]$tr.DaysOfWeek)) } elseif ($tr.DaysInterval) { $days = $(if ([int]$tr.DaysInterval -eq 1) { 'every day' } else { 'every ' + $tr.DaysInterval + ' days' }) } } catch { }
            $o.Trigger = ('{0} at {1}{2}' -f $days, $start, $(if ($tr.Enabled -eq $false) { ' (trigger disabled)' } else { '' })).Trim()
        } else { $o.Trigger = 'no trigger'; $o.Problems += 'the task has no trigger: it never runs by itself' }
        $acts = @($t.Actions)
        if ($acts.Count -gt 0) { $o.Command = ('{0} {1}' -f $acts[0].Execute, $acts[0].Arguments).Trim(); $o.PointsHere = ([string]$acts[0].Arguments -like ('*"' + (Get-TaskLauncherPath) + '"*')) }
        if ($o.Registered -and -not $o.PointsHere) { $o.Problems += ('the task runs another copy: ' + $o.Command + ' - register again from here to point it at this folder') }
        if (-not $o.Enabled) { $o.Problems += 'the task is disabled in the Task Scheduler' }
    }
    $o.LastRunFile = Read-LastRun
    return [pscustomobject]$o
}

function Register-DownloadTask {
    # Creates or replaces the task from the Settings tab's time, days and logon type, as the operator running this tool.
    # Nothing here needs an elevated session: the task is the operator's own, at the Limited run level.
    $time = [string]$script:Config.TaskTime
    if ($time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { throw "TaskTime '$time' is not HH:mm (Settings tab)" }
    $at = [datetime]::ParseExact($time, 'HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
    $days = [string]$script:Config.TaskDays
    if ($days -ieq 'Daily') { $trigger = New-ScheduledTaskTrigger -Daily -At $at }
    else { $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek ([System.DayOfWeek]$days) -At $at }
    # the trigger is made with a UTC start ("...Z": synchronised across time zones), which moves the task by an hour
    # when the clocks change; the start written without a zone is local time, summer and winter alike
    $trigger.StartBoundary = $at.ToString("yyyy-MM-dd'T'HH:mm:ss")
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-TaskArguments) -WorkingDirectory $script:RootFolder
    $logon = [string]$script:Config.TaskLogon; if ($logon -notin 'S4U', 'Interactive') { $logon = 'Interactive' }
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType $logon -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6) -MultipleInstances IgnoreNew -Compatibility Win8
    Write-PatchLog ("Register-ScheduledTask -TaskPath '{0}' -TaskName '{1}' -Force  ({2}, as {3}\{4} {5}; powershell.exe {6})" -f $script:Config.TaskFolder, $script:Config.TaskName, (Get-TaskScheduleText), $env:USERDOMAIN, $env:USERNAME, $logon, (Get-TaskArguments)) 'CMD'
    $task = $null
    try { $task = Register-ScheduledTask -TaskPath $script:Config.TaskFolder -TaskName $script:Config.TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description ('{0} {1}: fetches and verifies the update library for the WinRM toolkit ({2}). Registered by {3}.' -f $script:Config.ToolName, $script:Config.ToolVersion, $script:Config.LibraryFolder, (Get-OperatorIdentity)) -Force -ErrorAction Stop }
    catch {
        # an ordinary account may be refused an S4U task (it needs the right to log on as a batch job); Interactive needs nothing extra
        if ($logon -eq 'S4U') { throw ("Windows refused to register the task with the S4U logon for this account: {0}. S4U needs the right to log on as a batch job. Choose Interactive for the task logon on the Settings tab - it needs no extra right and runs while you are logged on - and register again." -f (Get-ShortError $_)) }
        throw
    }
    Write-PatchLog ("TASK REGISTERED {0}{1} by {2}: {3}, as {4} ({5})" -f $script:Config.TaskFolder, $script:Config.TaskName, (Get-OperatorIdentity), (Get-TaskScheduleText), $task.Principal.UserId, $logon) 'OK'
    if ($logon -eq 'S4U') { Write-PatchLog 'S4U: the task runs whether or not you are logged on and stores no password, but it has no network credentials - a proxy that asks for a password, or a library on a network drive, needs Interactive (Settings tab)' 'WHY' }
    else { Write-PatchLog 'Interactive: the task runs only while you are logged on at its start time, with your full session (the proxy and network drives work); it needs no extra right' 'WHY' }
    return $task
}

function Unregister-DownloadTask {
    $t = Get-DownloadTask
    if (-not $t) { Write-PatchLog 'No task to remove' 'INFO'; return $false }
    Write-PatchLog ("Unregister-ScheduledTask -TaskPath '{0}' -TaskName '{1}'" -f $script:Config.TaskFolder, $script:Config.TaskName) 'CMD'
    Unregister-ScheduledTask -TaskPath $script:Config.TaskFolder -TaskName $script:Config.TaskName -Confirm:$false -ErrorAction Stop
    Write-PatchLog ("TASK REMOVED {0}{1} by {2}" -f $script:Config.TaskFolder, $script:Config.TaskName, (Get-OperatorIdentity)) 'OK'
    return $true
}

function Start-DownloadTask {
    $t = Get-DownloadTask
    if (-not $t) { throw 'the task is not registered' }
    Write-PatchLog ("Start-ScheduledTask -TaskPath '{0}' -TaskName '{1}'" -f $script:Config.TaskFolder, $script:Config.TaskName) 'CMD'
    Start-ScheduledTask -TaskPath $script:Config.TaskFolder -TaskName $script:Config.TaskName -ErrorAction Stop
    Write-PatchLog ("TASK STARTED by {0} - it runs in its own window, hidden; watch the log file and this tab (Refresh)" -f (Get-OperatorIdentity)) 'OK'
}

function Get-ScheduleRows {
    # The facts grid of the Schedule tab: Item, Value, Light.
    $s = Get-DownloadTaskState
    $rows = @()
    $row = { param($Item, $Value, $Light = 'Grey') [pscustomobject]@{ Item = $Item; Value = [string]$Value; Light = $Light } }
    $rows += & $row 'Task' $s.Name $(if ($s.Registered) { 'Green' } else { 'Amber' })
    $rows += & $row 'Registered' $(if ($s.Registered) { 'yes - ' + $s.State + $(if (-not $s.Enabled) { ', DISABLED' } else { '' }) } else { 'no - press Register task' }) $(if ($s.Registered -and $s.Enabled) { 'Green' } elseif ($s.Registered) { 'Red' } else { 'Amber' })
    if ($s.Registered) {
        $rows += & $row 'Runs' $s.Trigger $(if ($s.Trigger -eq 'no trigger') { 'Red' } else { 'Green' })
        $rows += & $row 'Runs as' ('{0} ({1})' -f $s.RunsAs, $s.Logon) 'Green'
        $rows += & $row 'Command' $s.Command $(if ($s.PointsHere) { 'Green' } else { 'Red' })
        $rows += & $row 'Next run' $(if ($s.NextRun) { $s.NextRun } else { '-' }) $(if ($s.NextRun) { 'Green' } else { 'Amber' })
        $rows += & $row 'Last run (Task Scheduler)' $(if ($s.LastRun) { '{0} - {1}' -f $s.LastRun, $s.LastResult } else { $s.LastResult }) $(if ($null -eq $s.LastResultCode) { 'Grey' } elseif ($s.LastResultCode -eq 0) { 'Green' } elseif ($s.LastResultCode -in 267009, 267011) { 'Grey' } else { 'Red' })
    } else {
        $rows += & $row 'Would run' ((Get-TaskScheduleText) + (' as {0}\{1} ({2}) - Settings tab' -f $env:USERDOMAIN, $env:USERNAME, $script:Config.TaskLogon)) 'Grey'
        $rows += & $row 'Command' ('powershell.exe ' + (Get-TaskArguments)) 'Grey'
    }
    $lr = $s.LastRunFile
    if ($lr) {
        $rows += & $row 'Last run (this tool)' ('{0} by {1}{2}: {3} - {4}' -f $lr.When, $lr.By, $(if ($lr.Unattended) { ' (unattended)' } else { '' }), $lr.Outcome, $lr.Summary) $(if ($lr.Outcome -eq 'OK') { 'Green' } else { 'Red' })
        foreach ($d in @($lr.Downloaded)) { $rows += & $row '   downloaded' $d 'Green' }
        foreach ($d in @($lr.Placed | Where-Object { $_ })) { $rows += & $row '   placed by hand, verified' $d 'Green' }
        foreach ($f in @($lr.Failed)) { $rows += & $row '   failed' $f 'Red' }
        if ($lr.Report) { $rows += & $row '   report' $lr.Report 'Grey' }
        if ($lr.Log) { $rows += & $row '   log' $lr.Log 'Grey' }
    } else { $rows += & $row 'Last run (this tool)' 'none yet (settings\last-run.json is written by every run)' 'Grey' }
    foreach ($p in @($s.Problems)) { $rows += & $row 'Problem' $p 'Red' }
    return $rows
}
