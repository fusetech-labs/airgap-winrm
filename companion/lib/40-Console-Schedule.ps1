# =====================================================================
#  40-Console-Schedule.ps1  -  THE SCHEDULE CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  This tool as a scheduled task on this PC: registered or not, when it
#  runs, as whom, what it runs, the Task Scheduler's last result, and the
#  outcome of the last run as the tool itself recorded it (downloaded,
#  failed, the report, the log).  Register / Remove / Run now / Refresh.
#  The time, days and logon type are on the Settings tab.
# =====================================================================

function Update-ScheduleGrid {
    $grid = $script:Gui['ScheduleGrid']; if (-not $grid) { return }
    $rows = @()
    try { $rows = @(Get-ScheduleRows) } catch { $rows = @([pscustomobject]@{ Item = 'Problem'; Value = ('the task could not be read: ' + (Get-ShortError $_)); Light = 'Red' }) }
    Set-GridRows -Grid $grid -Rows $rows -RowColour { param($r) Get-LightColour $r.Light } -ToolTipProperty 'Value' -NoKeepChecks
    $s = @($rows | Where-Object { $_.Item -eq 'Registered' })[0]
    $script:Gui['ScheduleHeader'].Info.Text = ('{0} - would run {1}' -f $(if ($s) { $s.Value } else { '' }), (Get-TaskScheduleText))
}

function Invoke-ScheduleRegister {
    if (-not (Test-GuiDialogAllowed 'The Register question')) { return }
    $state = Get-DownloadTaskState
    $text = ("{0} the task {1}{2}?`n`nRuns:      {3}`nAs:        {4}\{5} ({6})`nCommand:   powershell.exe {7}`nLibrary:   {8}`n`nThe task runs this tool with -Unattended: it checks every product, downloads what is missing, verifies the library and writes settings\last-run.json and a report. The time, days and logon type are on the Settings tab." -f $(if ($state.Registered) { 'Replace' } else { 'Register' }), $script:Config.TaskFolder, $script:Config.TaskName, (Get-TaskScheduleText), $env:USERDOMAIN, $env:USERNAME, $script:Config.TaskLogon, (Get-TaskArguments), $script:Config.LibraryFolder)
    if ((Show-PatcherMessage -Title 'Register task' -Buttons 'YesNo' -Icon 'Question' -Text $text) -ne 'Yes') { Write-PatchLog 'Register task: answered No' 'INFO'; return }
    $null = Register-DownloadTask
}

function Invoke-ScheduleRemove {
    if (-not (Test-GuiDialogAllowed 'The Remove question')) { return }
    $state = Get-DownloadTaskState
    if (-not $state.Registered) { Show-GuiNotice 'The task is not registered.'; return }
    if ((Show-PatcherMessage -Title 'Remove task' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("Remove the task {0}{1}?`n`nThe library stays; nothing runs by itself any more." -f $script:Config.TaskFolder, $script:Config.TaskName)) -ne 'Yes') { Write-PatchLog 'Remove task: answered No' 'INFO'; return }
    $null = Unregister-DownloadTask
}

function Invoke-ScheduleRunNow {
    if (-not (Test-GuiDialogAllowed 'The Run now question')) { return }
    $state = Get-DownloadTaskState
    if (-not $state.Registered) { Show-GuiNotice 'Register the task first - or press Check and download on the Library tab to run the same job in this window.'; return }
    if ((Show-PatcherMessage -Title 'Run now' -Buttons 'YesNo' -Icon 'Question' -Text "Start the task now?`n`nIt runs hidden, as the task does at its scheduled time, and writes the same log file. Press Refresh to follow it; the Library tab shows the result after the run (Check for updates).") -ne 'Yes') { Write-PatchLog 'Run now: answered No' 'INFO'; return }
    Start-DownloadTask
}

function Open-ScheduleLastReport {
    $lr = Read-LastRun
    if ($lr -and $lr.Report -and (Test-Path -LiteralPath $lr.Report)) { Start-Process $lr.Report; return }
    Show-GuiNotice 'No report from a run yet (every run writes one into reports\).'
}

function Get-ScheduleHelpHtml {
    $notes = @'
THE TASK

  * Register task creates (or replaces) one task, \WinRMToolkit\Airgap Download Toolkit, that runs this launcher with -Unattended at the time and on the days set on the Settings tab, as the account registering it. The command it runs is shown on the page: it names this folder, so a copy moved elsewhere must register again.
  * An unattended run is Check and download without a window: every enabled product checked, what is missing downloaded and verified, the library hashed again, settings\last-run.json and a report written, exit code 0 when nothing failed. The log file in logs\ has every line.
  * Run now starts the task at once, hidden; Refresh reads the Task Scheduler again. Check and download on the Library tab runs the same job in this window instead.
  * The task starts the tool the way this session was started. Started as a file, it starts the file. Started from text, because PowerShell refused the unsigned file here, it reads the launcher and runs it as text too: the Command row shows which.

THE LOGON TYPE (Settings tab)

  * Interactive (the default): the task runs only while you are logged on at its start time, with your full session - the proxy and network drives work - and needs no extra right.
  * S4U: the task runs whether or not you are logged on and no password is stored. It has no network credentials: a proxy that asks for a password, or a library on a network drive, fails under S4U. Windows gives S4U only to an account that may log on as a batch job: where it refuses, stay with Interactive.
  * Register the task again after changing the logon type.

WHAT THE PAGE SHOWS

  * Registered, Runs, Runs as, Command, Next run, Last run (Task Scheduler): the task as the Task Scheduler holds it. The last result 0 means the run completed with nothing failed; 1 means a check, download or verification failed - the report and the log say which.
  * Last run (this tool): what the run itself recorded in settings\last-run.json - every file downloaded, every failure, the report and the log file of that day. Open last report opens the report.
  * A Problem row: the task runs another copy, has no trigger, is disabled, or could not be read; it starts the file although this session had to be started from text; or it ended with 1 and the tool recorded no run, which means PowerShell did not get to run the tool.
'@
    return (New-DetailsHtml -Title 'Help: the Schedule console' -Subtitle 'this tool as a scheduled task' -Console 'Schedule' -Sections @(@{ Heading = ''; Html = (ConvertTo-HtmlFromNotes -Text $notes) }))
}

function New-ScheduleConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Schedule' -Text 'Schedule'
    $grid = New-ConsoleGrid -Columns @(@{ Name = 'Item'; Width = 230 }, @{ Name = 'Value'; Width = 400; Fill = $true }) -NoCheckBoxes
    $head = New-GridHeader -Heading 'The scheduled task' -Detail '' -Tip 'The task as the Task Scheduler holds it, and the last run as this tool recorded it'
    $tab.Controls.Add($grid); $tab.Controls.Add($head.Panel); $grid.BringToFront()
    $script:Gui['ScheduleGrid'] = $grid; $script:Gui['ScheduleHeader'] = $head

    $toolbar = New-ConsoleToolbar -Tab $tab -Height 56
    $x = 8
    $toolbar.Controls.Add((New-GuiButton -Text 'Refresh' -X $x -Y 8 -W 90 -H 40 -Colour 'LightSkyBlue' -ReadOnly -Tip 'Reads the task and the last run again' -OnClick { Invoke-GuiAction -Name 'Refresh the task' -ReadOnly -Action { Update-ScheduleGrid } })); $x += 95
    $toolbar.Controls.Add((New-GuiButton -Text 'Register task' -X $x -Y 8 -W 120 -H 40 -Colour 'LightGreen' -Tip 'Creates or replaces the task on this PC (after a Yes) with the time, days and logon type of the Settings tab' -OnClick { Invoke-GuiAction -Name 'Register task' -Action { Invoke-ScheduleRegister } })); $x += 125
    $toolbar.Controls.Add((New-GuiButton -Text 'Remove task' -X $x -Y 8 -W 110 -H 40 -Colour 'LightCoral' -Tip 'Removes the task (after a Yes); the library stays' -OnClick { Invoke-GuiAction -Name 'Remove task' -Action { Invoke-ScheduleRemove } })); $x += 115
    $toolbar.Controls.Add((New-GuiButton -Text 'Run now' -X $x -Y 8 -W 100 -H 40 -Colour 'SteelBlue' -Tip 'Starts the task at once, hidden' -OnClick { Invoke-GuiAction -Name 'Run the task now' -Action { Invoke-ScheduleRunNow } })); $x += 105
    $toolbar.Controls.Add((New-GuiButton -Text 'Open last report' -X $x -Y 8 -W 130 -H 40 -ReadOnly -Tip 'The report of the last run' -OnClick { Invoke-GuiAction -Name 'Open last report' -ReadOnly -Action { Open-ScheduleLastReport } })); $x += 135
    $toolbar.Controls.Add((New-GuiButton -Text 'Open Task Scheduler' -X $x -Y 8 -W 150 -H 40 -ReadOnly -Tip 'taskschd.msc' -OnClick { Invoke-GuiAction -Name 'Open Task Scheduler' -ReadOnly -Action { Start-Process -FilePath 'taskschd.msc' } })); $x += 155
    $toolbar.Controls.Add((New-GuiButton -Text 'Open log folder' -X $x -Y 8 -W 120 -H 40 -ReadOnly -Tip 'logs\ in Explorer: one file per day, the unattended runs included' -OnClick { Invoke-GuiAction -Name 'Open log folder' -ReadOnly -Action { if (-not (Test-Path -LiteralPath $script:Config.LogFolder)) { New-Item -ItemType Directory -Path $script:Config.LogFolder -Force | Out-Null }; Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:Config.LogFolder) } })); $x += 125
    $toolbar.Controls.Add((New-GuiButton -Text 'Help' -X $x -Y 8 -W 70 -H 40 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Schedule help' -ReadOnly -Action { Show-ConsoleHelp -Console 'Schedule' -Html (Get-ScheduleHelpHtml) } }))

    $null = New-ConsoleBanner -Tab $tab -Console 'Schedule' -Title 'SCHEDULE' -Subtitle 'this tool as a scheduled task: registered, watched, run'
    $grid.BringToFront()
    Register-ConsoleRefresher -Console 'Schedule' -Refresh { Update-ScheduleGrid }
}
