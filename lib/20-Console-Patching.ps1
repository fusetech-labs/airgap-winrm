# =====================================================================
#  20-Console-Patching.ps1  -  THE O/S PATCHING CONSOLE (tab 1)
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Everything the version 1 window did, in its own file:
#    - the server grid with one column per patch file (Get-PatchVerdict)
#    - the patch list, PATCH IT!, Reboot, Test WinRM, credentials, log
#  plus, new in version 2:
#    - the Inventory collector: products from the Uninstall registry keys,
#      roles and features, .NET Framework and runtimes, SQL Server instances,
#      Exchange, services, processes and scheduled tasks (shared with Health)
#    - the Software grid: every product on every server with a currency
#      verdict (Current / Behind / Stale / Ageing / End of life / Unknown) from
#      data\known-apps.psd1 and from the fleet itself
#    - "Roles" and "Software behind" columns, and the Report button
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  20-Console-Patching.ps1  (new file in version 2)
# ---------------------------------------------------------------------
#  Grid, verdict, install and reboot code moved from 07-Gui.ps1 unchanged.
#  New: RemoteInventoryScript, Get-ServerInventory, software currency, report.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

function Get-ShortOsName {
    # "Microsoft Windows Server 2022 Standard" -> "2022 Std"
    param([string]$Caption)
    if (-not $Caption) { return '' }
    $year = ''
    if ($Caption -match '(20\d\d)') { $year = $Matches[1] }
    $edition = ''
    if ($Caption -match 'Datacenter') { $edition = 'DC' } elseif ($Caption -match 'Standard') { $edition = 'Std' }
    return ("$year $edition").Trim()
}

function Get-PatchCellText {
    # What to show in a KB column for one server.  The decision is Get-PatchVerdict (04-Patches.ps1),
    # the SAME function the install plan uses, so the grid can never promise what the plan refuses.
    param($Status, $Patch, [string]$Server = '')
    return (Get-PatchVerdict -Status $Status -Patch $Patch -Server $Server).Cell
}

function Get-CheckedServers {
    return @(Get-GridChecked -Grid $script:Gui['ServerList'])
}

function Get-CheckedPatches {
    $list = $script:Gui['PatchList']
    $picked = @()
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        if ($list.GetItemChecked($i)) { $picked += $script:Patches[$i] }
    }
    return $picked
}

function Update-PatchList {
    $list = $script:Gui['PatchList']
    # ticks are kept by file path across repaints (any button repaints; the ticks used to vanish)
    $keep = @{}; $old = @($script:Gui['PatchListPaths'])
    for ($i = 0; $i -lt $list.Items.Count -and $i -lt $old.Count; $i++) { if ($list.GetItemChecked($i)) { $keep[[string]$old[$i]] = $true } }
    $list.Items.Clear()
    $paths = @()
    foreach ($p in $script:Patches) {
        # short and scannable: "KB5126655  Windows  584.6 MB  Server 2022"; the grid column and the details window carry the rest
        $line = '{0}  {1}  {2} MB' -f $p.KB, $p.PatchType, $p.SizeMB
        # a .NET rollup: ".NET 4.8  Server 2022" (the build read from inside its cab), or ".NET 4.8 (windows10.0 line)" when it was not
        if ($p.PSObject.Properties['DotNetLine'] -and $p.DotNetLine) { $line += '  .NET ' + $p.DotNetLine }
        if ($p.TargetBuild -gt 0 -or ($p.PSObject.Properties['TargetBuilds'] -and @($p.TargetBuilds).Count -gt 0)) { $line += '  ' + $p.TargetOs }
        elseif ($p.PSObject.Properties['OsFamily'] -and $p.OsFamily) { $line += ' (' + $p.OsFamily + ' line)' }
        elseif ($p.OsLine) { $line += '  ' + $p.OsLine + ' ?' } else { $line += '  OS unknown' }
        if ($p.Type -ne 'msu') { $line += '  (' + $p.Type + ')' }
        # what the package is, when the manifest inside said: the install order goes by it (servicing stack, cumulative, other)
        if ($p.PSObject.Properties['Kind'] -and $p.Kind -in 'cumulative', 'servicing stack') { $line += '  ' + $p.Kind }
        if ($p.PSObject.Properties['Kind'] -and $p.Kind -eq 'dynamic update') { $line += '  - DYNAMIC UPDATE, not for a running server' }
        if (-not $p.Installable) { $line += '  - by hand' }
        if ($p.Signature -ne 'Valid') { $line += '  - UNSIGNED / ' + $p.Signature }
        [void]$list.Items.Add($line, [bool]$keep[[string]$p.FullName]); $paths += [string]$p.FullName
    }
    $script:Gui['PatchListPaths'] = $paths
    $script:Gui['PatchFolderLabel'].Text = 'Folder: ' + $script:Config.PatchFolder + "`r`n" + 'Sub-folders: Windows and DotNet are installed by the tool; SQL, Exchange and Other are reported only.'
}

function Update-ServerList {
    # Rebuilds the grid from $script:Groups + $script:Patches + $script:ServerStatus (+ Inventory when present).
    $lv = $script:Gui['ServerList']
    $wasChecked = @(Get-CheckedServers)
    # the software verdicts first: if they throw, the grid has not been touched yet
    $groupRows = @(Get-GroupRows -Combo $script:Gui['GroupCombo'])
    $behindCount = @{}
    foreach ($row in @(Get-SoftwareRows -Servers @(Get-UniqueNames ($groupRows | ForEach-Object { $_.Server })))) { if ($row.Verdict -in 'Behind', 'Stale', 'Ageing', 'End of life') { $behindCount[$row.Server] = 1 + [int]$behindCount[$row.Server] } }
    $lv.BeginUpdate()
    $script:GridProgrammatic = $true; $script:Gui['PatchRebuilding'] = $true   # restored ticks are the tool's, not clicks
    try {
    $lv.Items.Clear()
    $lv.Columns.Clear()
    [void]$lv.Columns.Add('Server', 170)
    [void]$lv.Columns.Add('Group', 110)
    [void]$lv.Columns.Add('WinRM', 75)
    [void]$lv.Columns.Add('OS', 70)
    [void]$lv.Columns.Add('Build', 95)
    [void]$lv.Columns.Add('Pending reboot', 175)
    [void]$lv.Columns.Add('Up (d)', 55)
    [void]$lv.Columns.Add('Free C: GB', 75)
    $trellix = Test-TrellixInUse   # off (Settings tab, a site without Trellix): no Solidcore and Trellix Agent columns
    if ($trellix) {
        [void]$lv.Columns.Add('Solidcore', 150)   # Trellix Solidcore: the mode now and on reboot (empty when it is not on the server)
        [void]$lv.Columns.Add('Trellix Agent', 130)   # the two ePO agent services: Running (Auto), STOPPED (Disabled) in orange, MIXED (empty when not on the server)
    }
    $blankStatus = 9; if (-not $trellix) { $blankStatus = 7 }   # the status cells of a server not checked yet: WinRM to Newest hotfixes
    [void]$lv.Columns.Add('Newest hotfixes (same day)', 230)
    foreach ($p in $script:Patches) { [void]$lv.Columns.Add($p.KB, 125) }
    $rolesColumn = $lv.Columns.Add('Roles', 160); $rolesColumn.Tag = 'fill:160'   # takes the spare width on a wide window
    [void]$lv.Columns.Add('Software behind', 110)
    [void]$lv.Columns.Add('Checked at', 80)

    foreach ($gr in $groupRows) {
        $name = $gr.Server
        $s = $script:ServerStatus[$name]
        $flag = Get-InstallFlag -Server $name   # an OS patch run handed to the server and not recorded yet: cyan row, INSTALLING cells (purple = ended without a result)
        $inv = Get-CollectorResult -Name 'Inventory' -Server $name
        $item = New-Object System.Windows.Forms.ListViewItem($name)
        [void]$item.SubItems.Add($gr.Group)
        if (-not $s) {
            foreach ($i in 1..$blankStatus) { [void]$item.SubItems.Add('') }
            foreach ($p in $script:Patches) { [void]$item.SubItems.Add((Get-PatchCellText -Status $null -Patch $p -Server $name)) }
            [void]$item.SubItems.Add(''); [void]$item.SubItems.Add(''); [void]$item.SubItems.Add('')
            $item.BackColor = 'White'
            if ($flag) { $item.BackColor = $(if ([string]$flag.State -eq 'unknown') { 'Thistle' } else { 'LightCyan' }) }
        } elseif (-not $s.Reachable) {
            [void]$item.SubItems.Add('FAILED')
            foreach ($i in 1..($blankStatus - 1)) { [void]$item.SubItems.Add('') }
            foreach ($p in $script:Patches) { [void]$item.SubItems.Add((Get-PatchCellText -Status $s -Patch $p -Server $name)) }
            [void]$item.SubItems.Add(''); [void]$item.SubItems.Add('')
            [void]$item.SubItems.Add($s.Checked.ToString('HH:mm:ss'))
            $item.BackColor = 'LightGray'
            if ($flag) { $item.BackColor = $(if ([string]$flag.State -eq 'unknown') { 'Thistle' } else { 'LightCyan' }) }
            $item.ToolTipText = $s.Error
        } else {
            [void]$item.SubItems.Add('OK')
            [void]$item.SubItems.Add((Get-ShortOsName $s.Caption))
            [void]$item.SubItems.Add($s.Build)
            [void]$item.SubItems.Add((Get-PendingRebootText -Status $s))
            [void]$item.SubItems.Add([string]$s.UptimeDays)
            [void]$item.SubItems.Add([string]$s.FreeGB)
            $agent = Get-TrellixAgentInfo -Status $s
            if ($trellix) {
                [void]$item.SubItems.Add((Get-SolidcoreText -Status $s))
                [void]$item.SubItems.Add($agent.Text)
            }
            [void]$item.SubItems.Add($s.LastHotFix)
            # green = every file that applies to this server is installed - the same rule as the report: a file for another
            # Windows build ("Blocked: wrong OS"), a "By hand" type and a Dynamic Update (for no running server) do not apply,
            # and at least one file must apply
            $anyReady = $false; $allInstalled = $true; $applicable = 0
            foreach ($p in $script:Patches) {
                $cell = Get-PatchCellText -Status $s -Patch $p -Server $name
                [void]$item.SubItems.Add($cell)
                if ($cell -like 'READY*') { $anyReady = $true }
                if ($cell -in 'By hand', 'Blocked: wrong OS', 'Not applicable', 'Blocked: dynamic update') { continue }
                $applicable++
                if ($cell -notlike 'Installed*') { $allInstalled = $false }
            }
            if ($applicable -eq 0) { $allInstalled = $false }
            $roles = ''; $behind = ''
            if ($inv -and $inv.Reachable) {
                $roles = (Get-RoleSummary -Inventory $inv)
                $behind = [string][int]$behindCount[$name]
            }
            [void]$item.SubItems.Add($roles)
            [void]$item.SubItems.Add($behind)
            [void]$item.SubItems.Add($s.Checked.ToString('HH:mm:ss'))
            if ($flag) { $item.BackColor = $(if ([string]$flag.State -eq 'unknown') { 'Thistle' } else { 'LightCyan' }) }
            elseif ($s.PendingReboot) { $item.BackColor = 'MistyRose' }
            elseif ($anyReady)    { $item.BackColor = 'LemonChiffon' }
            elseif ($allInstalled) { $item.BackColor = 'Honeydew' }
            else { $item.BackColor = 'White' }
            $agentWarn = ($trellix -and $agent.State -in 'stopped', 'mixed', 'unknown')
            if ($s.FreeGB -lt $script:Config.WarnFreeGB -or $agentWarn) {
                $item.UseItemStyleForSubItems = $false; foreach ($si in $item.SubItems) { $si.BackColor = $item.BackColor }   # per-cell style: keep the row colour in every cell
                if ($s.FreeGB -lt $script:Config.WarnFreeGB) { $item.SubItems[7].ForeColor = 'Red' }
                if ($agentWarn) { $item.SubItems[9].BackColor = 'NavajoWhite' }   # orange = a warning: the agent services are off, ePO hears nothing from this server
            }
        }
        if ($wasChecked -contains $name) { $item.Checked = $true }
        [void]$lv.Items.Add($item)
    }
    } finally { $lv.EndUpdate(); $script:GridProgrammatic = $false; $script:Gui['PatchRebuilding'] = $false }
    Resize-GridFillColumn -Grid $lv
    $script:Gui['CountLabel'].Text = ('{0} server row(s) shown, {1} ticked' -f $lv.Items.Count, (Get-CheckedServers).Count)
}

function ConvertFrom-FixedWidthLines {
    # The status collector sends its hotfix and history lists as fixed-width text lines (two or more spaces
    # between columns).  This turns them into objects; the last column takes whatever is left (titles have spaces).
    param([string[]]$Lines, [string[]]$Columns)
    $rows = @()
    foreach ($line in @($Lines)) {
        if (-not $line) { continue }
        $f = @([string]$line -split '\s{2,}' | Where-Object { $_ -ne '' })
        $o = [ordered]@{}
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            if ($i -eq $Columns.Count - 1) { $o[$Columns[$i]] = (@($f | Select-Object -Skip $i) -join ' ') } elseif ($i -lt $f.Count) { $o[$Columns[$i]] = $f[$i] } else { $o[$Columns[$i]] = '' }
        }
        $rows += [pscustomobject]$o
    }
    return $rows
}

function Get-ServerDetailsHtml {
    # The double-click page for one server: status, every patch file's verdict, both update lists, inventory.
    param([string]$Name)
    $s = $script:ServerStatus[$Name]
    $facts = @(, @('Checked', $s.Checked.ToString('yyyy-MM-dd HH:mm:ss')))   # the comma keeps the pair as ONE element (@(@(a, b)) would flatten it)
    if (-not $s.Reachable) { return (New-DetailsHtml -Title "Server: $Name" -Console 'Patching' -Subtitle ('unreachable: ' + $s.Error) -Facts $facts) }
    $facts += @(
        @('OS', [string]$s.Caption), @('Build', [string]$s.Build), @('Last boot', [string]$s.LastBoot), @('Up', "$($s.UptimeDays) d"), @('Free on C', "$($s.FreeGB) GB"),
        @('Pending reboot', (Get-PendingRebootText -Status $s)),
        @('Servicing active', $(if ($s.ServicingActive) { 'YES - ' + $s.ServicingReasons } else { 'no' })))
    if (Test-TrellixInUse) {
        $facts += @(
            @('Trellix Solidcore', $(if ($s.PSObject.Properties['SolidcorePresent'] -and $s.SolidcorePresent) { Get-SolidcoreText -Status $s } else { 'not on this server' })),
            @('Trellix Agent', $(if ((Get-TrellixAgentInfo -Status $s).Present) { (Get-TrellixAgentText -Status $s) + ' (masvc, macmnsvc)' } else { 'not on this server' })))
    }
    $facts += @(@('Newest hotfixes', [string]$s.LastHotFix), @('PowerShell', [string]$s.PSVersion), @('Answered as', [string]$s.Computer))
    $verdicts = @()
    foreach ($p in $script:Patches) {
        $v = Get-PatchVerdict -Status $s -Patch $p -Server $Name
        $light = 'Grey'; if ($v.Cell -like 'READY*') { $light = 'Amber' } elseif ($v.Cell -like 'Installed*') { $light = 'Green' } elseif ($v.Cell -like 'Blocked*') { $light = 'Red' }
        $verdicts += [pscustomobject]@{ Light = $light; KB = $p.KB; Type = $p.PatchType; Verdict = $v.Cell; Reason = $v.Reason; File = $p.Name }
    }
    $software = @(Get-SoftwareRows -Servers @($Name) | ForEach-Object { [pscustomobject]@{ Light = $(switch ($_.Verdict) { 'Behind' { 'Amber' } 'Stale' { 'Amber' } 'Ageing' { 'Amber' } 'End of life' { 'Red' } 'Current' { 'Green' } default { 'Grey' } }); Verdict = $_.Verdict; Product = $_.Product; Version = $_.Version; Publisher = $_.Publisher; Installed = $_.Installed; Reason = $_.Reason } })
    $sections = @(
        @{ Heading = 'How to read this page'; Lines = @(
            'Build is the real patch level: the number after the dot (the UBR) changes with every cumulative update and only moves AFTER the reboot that finishes the install. The Microsoft update-history page lists it next to each KB, e.g. "KB5122882 (OS Build 20348.5622)".',
            'Newest hotfixes = every Get-HotFix entry from the most recent install date; the cumulative update and the .NET cumulative update normally land on the same day, so several KBs share that date.',
            'Pending reboot is YES only for the hard signs (CBS RebootPending, PackagesPending and RebootInProgress; WU RebootRequired and PostRebootReporting; UpdateExeVolatile; a pending computer rename). PendingFileRenameOperations alone is a weak sign and is not counted unless TreatPendingFileRenameAsReboot is set in lib\01-Config.ps1. "software: ..." = a Software console install or removal since the last boot ended with exit 3010 (reboot suppressed): the reboot is due, but it does not block patches - install them first and one reboot finishes both.',
            'Servicing active = dism.exe or wusa.exe running, TiWorker.exe actually using CPU, or the Windows Update agent installing. It blocks installs and reboots and usually clears within a few minutes - check again.') },
        @{ Heading = 'Patch files in patches\ against this server'; Rows = $verdicts; Columns = @('Light', 'KB', 'Type', 'Verdict', 'Reason', 'File'); Note = 'The same verdict the grid shows; READY means the file would be installed by PATCH IT!, "By hand" means the tool only reports that patch type.' },
        @{ Heading = 'Pending file rename operations'; Lines = @($s.PfroEntries); Note = ('{0} entries, the first {1} shown. Files Windows will rename or delete at the next boot because they were locked. Installers and anti-virus products add to this list constantly, so on its own it is a weak sign: temp or AV files = ignore; Windows\WinSxS or servicing files = reboot.' -f $s.PfroCount, @($s.PfroEntries).Count) },
        @{ Heading = 'Installed hotfixes (Get-HotFix)'; Rows = (ConvertFrom-FixedWidthLines -Lines $s.HotFixLines -Columns @('KB', 'Installed', 'Type', 'Installed by')); Columns = @('KB', 'Installed', 'Type', 'Installed by'); Note = 'Only CBS packages still present on the box. Each cumulative update supersedes the previous one, which then drops off this list, so a well patched server shows only a handful. This is the primary "is KB x installed?" source because it reflects what is on disk now.' },
        @{ Heading = ('Windows Update history, newest first{0}' -f $(if ([int]$s.HistoryCount -gt @($s.HistoryLines).Count) { ' - the latest of {0}' -f $s.HistoryCount } else { '' })); Rows = (ConvertFrom-FixedWidthLines -Lines $s.HistoryLines -Columns @('Date', 'Operation', 'Result', 'KB', 'Title')); Columns = @('Date', 'Operation', 'Result', 'KB', 'Title'); Note = $(if ($s.HistoryError) { 'COULD NOT READ THE HISTORY: ' + $s.HistoryError } elseif ([int]$s.HistoryCount -eq 0) { 'Read, and empty: the Windows Update agent has installed nothing on this server, or its history was cleared. Updates installed with DISM or wusa - as this tool does - are not recorded here; Get-HotFix above lists them.' } else { 'The same list as Settings > Update history: every install attempt, including superseded updates, Defender definitions and failures. A KB whose newest entry is a successful Install counts as "Installed (history)" in the grid even when Get-HotFix no longer lists it.' }) })
    $inv = Get-CollectorResult -Name 'Inventory' -Server $Name
    if ($inv -and $inv.Reachable) {
        # each line in parentheses: a comma binds tighter than +, so 'a' + 'b', 'c' + 'd' would be ONE string (field finding 2026-10-29)
        $sections += @{ Heading = ('Inventory (collected {0})' -f $inv.Checked.ToString('HH:mm:ss')); Lines = @(
            ('.NET Framework: ' + $inv.NetFramework + ' (release ' + $inv.NetRelease + ')'),
            ('.NET runtimes: ' + $(if (@($inv.NetRuntimes).Count -gt 0) { @($inv.NetRuntimes) -join ', ' } else { 'none' })),
            ('SQL Server: ' + $(if (@($inv.SqlInstances).Count -gt 0) { @($inv.SqlInstances) -join ' ; ' } else { 'none' })),
            ('Exchange: ' + $(if ($inv.Exchange) { $inv.Exchange } else { 'none' })),
            ('Roles and features: ' + (Get-RoleSummary -Inventory $inv -Full))) }
        $sections += @{ Heading = 'Software'; Rows = $software; Columns = @('Light', 'Verdict', 'Product', 'Version', 'Publisher', 'Installed', 'Reason'); Note = ('Verdicts against data\known-apps.psd1 and the rest of the fleet: Current; Behind (a newer version is known or runs elsewhere); Stale (nothing newer and older than the release cadence, or a product the catalogue does not know installed over {0} months ago - updates are likely waiting); Ageing (an unknown product installed over {1} months ago - updates probably waiting, or no longer maintained: a cessation risk); End of life; Unknown (not in the catalogue, installed less than {0} months ago).' -f $script:Config.UnknownStaleMonths, $script:Config.UnknownAgeingMonths) }
    } else {
        $sections += @{ Heading = 'Inventory'; Lines = @(); Note = 'not collected yet - tick "Inventory (roles + software)" on the toolbar and check status' }
    }
    $sections += Get-ChangeLogSection -Server $Name
    return (New-DetailsHtml -Title "Server: $Name" -Subtitle 'status, patch verdicts, both update lists, the inventory and the change log' -Console 'Patching' -Facts $facts -Sections $sections)
}

function Get-PatchingHelpHtml {
    # The Help button of the O/S Patching console: every row colour, column, KB cell, patch-list line and button,
    # each next to an example drawn the way the window draws it.  Pure text in, HTML out (no WinRM).
    $kb = 'KB5126655'
    if ($script:Patches.Count -gt 0) { $kb = [string]$script:Patches[0].KB }
    $sections = @()

    # ---- 1. the grid, one example row per colour ----
    $mock = New-MockGrid -TrellixColumns -Headers @('Server', 'Group', 'WinRM', 'OS', 'Build', 'Pending reboot', 'Up (d)', 'Free C: GB', 'Solidcore', 'Trellix Agent', 'Newest hotfixes (same day)', $kb, 'Roles', 'Software behind', 'Checked at') -Rows @(
        @{ Colour = 'white';        Cells = @('server-a', 'Group-1', '', '', '', '', '', '', '', '', '', 'not checked', '', '', '') },
        @{ Colour = 'lightgray';    Cells = @('server-b', 'Group-1', 'FAILED', '', '', '', '', '', '', '', '', '?', '', '', '09:31:02') },
        @{ Colour = 'mistyrose';    CellColours = @{ 9 = 'navajowhite' }; Cells = @('server-c', 'Group-2', 'OK', '2022 Std', '20348.5499', 'YES: CBS:RebootPending', '68.2', '51.7', 'Update now, Update on reboot', 'STOPPED (Disabled)', 'KB5127687 (2026-10-13)', 'Blocked: reboot', 'SQL, .NET 4.8.1', '1', '09:31:05') },
        @{ Colour = 'lemonchiffon'; Cells = @('server-d', 'Group-2', 'OK', '2022 Std', '20348.5499', 'no', '12.0', '41.3', '', 'Running (Auto)', 'KB5127687 (2026-10-13)', 'READY', 'IIS, .NET 4.8.1', '0', '09:31:05') },
        @{ Colour = 'honeydew';     Cells = @('server-e', 'Group-3', 'OK', '2022 Std', '20348.5761', 'no (PFRO only, ignored)', '4.9', '58.4', '', 'Running (Auto)', 'KB5126655 (2026-10-14)', 'Installed', 'FS', '2', '09:31:06') })
    $rows = New-HelpTable -TrellixRows -Headers @('Row colour', 'It means', 'Next step') -Rows @(
        @((Get-HelpSwatch 'white' 'White'), 'Not asked yet in this session - or checked, with nothing READY and not every KB installed: the KB cells say why (blocked, by hand, not applicable).', 'Not asked yet: tick it and press "Check status (ticked)", or press "Check status (all shown)". Checked: read the KB cells.'),
        @((Get-HelpSwatch 'lightgray' 'Grey'), 'WinRM gave no answer or refused the login. Hover the row for the reason; it is in the log too.', 'Press "Test WinRM port (ticked) on ticked". No answer = network, firewall or the WinRM service. Answers but "Access is denied" = set credentials with an admin account. Kerberos errors = use the FQDN in the group file.'),
        @((Get-HelpSwatch 'mistyrose' 'Pink'), 'A reboot is pending, so every KB shows "Blocked: reboot": an install on top of a pending reboot fails with 0x800F0922.', 'Reboot the server in a change window ("Reboot (ticked)"), then check status again.'),
        @((Get-HelpSwatch 'lemonchiffon' 'Yellow'), 'At least one patch file is READY: not installed yet and nothing blocks it.', 'Tick the server and the file(s) in the patch list, press PATCH IT!.'),
        @((Get-HelpSwatch 'honeydew' 'Green'), 'Every file the tool can install is already on this server.', 'Nothing. The Build column confirms the level.'),
        @((Get-HelpSwatch 'lightcyan' 'Cyan'), 'An OS patch run the tool handed to this server (a SYSTEM task) is still going, or has not been read yet: the KB cell says INSTALLING with the minutes. The note survives a restart of the tool (settings\patch-runs.json).', 'Leave Auto-check ticked and wait, or come back later and press "Check status (ticked)": it reads the result from the server and records it.'),
        @((Get-HelpSwatch 'thistle' 'Purple'), 'The run ended without a result (the task is gone, the server rebooted mid-way, the script was stopped): the KB cell says RUN UNKNOWN.', 'Press "Analyse a failure (ticked)" - it reads the server''s own logs and clears the note.'),
        @((Get-HelpSwatch 'navajowhite' 'Orange cell'), 'The Trellix Agent cell only, in any row: the two ePO agent services are stopped or disabled (set so by PATCH IT! or INSTALL / UPDATE with the box ticked, or by hand). ePO hears nothing from the server meanwhile; a scan warns about it.', 'When the patching and the reboot are done, tick the server and press "Start Trellix Agent (ticked)".'))
    $sections += @{ Heading = 'The grid: one example row per colour'; Note = 'The row colour is the summary; the KB cells say why. Double-click a row for the full page (hotfixes, update history, inventory, software). Tick only with the checkbox - clicking the text selects without ticking.'; Html = ($mock + $rows) }

    # ---- 2. the columns ----
    $sections += @{ Heading = 'The columns'; Html = (New-HelpTable -TrellixRows -Headers @('Example cell', 'What it shows') -Rows @(
        @((Get-HelpCell 'OK'), ('WinRM: OK = the server answered on TCP {0} as the current login or the stored credentials. FAILED = see the grey row above.' -f (Get-WinRMPortText))),
        @((Get-HelpCell '2022 Std'), 'OS: the Windows edition reported by the server (2016 / 2019 / 2022 / 2025, Std or DC).'),
        @((Get-HelpCell '20348.5761'), 'Build: the real patch level. 20348 = Server 2022. The number after the dot (the UBR) rises with every cumulative update and only moves after the reboot that finishes the install. The Microsoft update-history page prints it next to each KB, e.g. "KB5122882 (OS Build 20348.5622)".'),
        @((Get-HelpCell 'YES: CBS:RebootPending'), 'Pending reboot: the hard signs only - CBS:RebootPending, CBS:PackagesPending, CBS:RebootInProgress, WU:RebootRequired, WU:PostRebootReporting, UpdateExeVolatile, ComputerRename. Any of them colours the row pink.'),
        @((Get-HelpCell 'YES: software: VMware Tools 12.5.4.24964629 (Update) (exit 3010)'), 'Pending reboot after a Software console install or removal since the last boot that ended with exit 3010 (the reboot suppressed). The row is not pink and the patches are not blocked: install them, then one reboot ("Reboot (ticked)" counts it as pending) finishes both.'),
        @((Get-HelpCell 'advised: removed Example Scanner 3.0'), 'Not required: software was removed since the last boot (exit 0). A reboot finishes what an uninstaller leaves for the next start - a service marked for deletion, files that were in use. Nothing is blocked; "Reboot (ticked)" asks about these servers separately, with No as the default. Clears itself at the next boot.'),
        @((Get-HelpCell 'no (PFRO only, ignored)'), 'Only PendingFileRenameOperations is set. Installers and anti-virus leave that behind all the time, so it is shown but not counted (TreatPendingFileRenameAsReboot in lib\01-Config.ps1 turns it into a real block).'),
        @((Get-HelpCell '68.2'), 'Up (d): days since the last boot.'),
        @((Get-HelpCell '51.7'), 'Free C: GB: free space on the system drive. Red text = below WarnFreeGB; below MinFreeGB the install is refused ("Blocked: disk").'),
        @((Get-HelpCell 'Update now, Update on reboot'), 'Solidcore: what "sadmin status" on the server says - the Trellix Solidcore (Application Control) mode now and the mode on reboot. Empty = not on the server. "ENFORCING" or "could not be read" = every KB shows "Blocked: Solidcore" and the reboot button asks separately: an update applied while the Solidifier is Enabled at the boot is rolled back (poqexec.exe is denied). The tool reads the mode, never changes it - the Update Mode task in ePO does.'),
        @((Get-HelpCell 'STOPPED (Disabled)' 'navajowhite'), 'Trellix Agent: the two ePO agent services, masvc "Trellix Agent Service" and macmnsvc "Trellix Agent Common Services". "Running (Auto)" is the normal state. "STOPPED (Disabled)" in orange is what the tool sets before an install (the box above PATCH IT!, ticked by default - the field test saw installs fail and roll back with the agent running) and what a scan warns about: ePO hears nothing from the server until "Start Trellix Agent (ticked)" sets them to Automatic and starts them again. "MIXED: ..." names each service and its state. Empty = not on the server.'),
        @((Get-HelpCell 'KB5126655 + KB5126654 (2026-10-14)'), 'Newest hotfixes (same day): every Get-HotFix entry from the most recent install date. The cumulative update and the .NET cumulative update usually land on the same day, so two KBs here is normal.'),
        @((Get-HelpCell 'READY' 'lemonchiffon'), ('One column per file in the patches folder (here {0}): the verdict for that file on that server - every value is in the next table.' -f $kb)),
        @((Get-HelpCell 'IIS, SQL, .NET 4.8.1'), 'Roles: filled by a status check while "Inventory (roles + software)" is ticked on the toolbar (the default) - the roles and features that matter for patching plus the .NET Framework line.'),
        @((Get-HelpCell '2'), ('Software behind: how many products on this server are Behind, Stale, Ageing or End of life in the software grid underneath (also needs Inventory). A product the catalogue does not know counts as Stale after {0} months and Ageing after {1}.' -f $script:Config.UnknownStaleMonths, $script:Config.UnknownAgeingMonths)),
        @((Get-HelpCell '09:31:06'), 'Checked at: when this row was last refreshed from the server.'))) }

    # ---- 3. every KB cell value, in the order Get-PatchVerdict decides them ----
    $sections += @{ Heading = ('KB columns: every cell value (one column per patch file, here {0})' -f $kb); Note = 'The grid cell and the PATCH IT! pre-flight come from the same function (Get-PatchVerdict in lib\04-Patches.ps1), so the grid never promises what the install refuses.'; Html = (New-HelpTable -Headers @('Cell', 'It means', 'Next step') -Rows @(
        @((Get-HelpCell 'not checked'), 'No status yet.', 'Check status.'),
        @((Get-HelpCell '?' 'lightgray'), 'The server could not be reached, so nothing is known.', 'Fix the WinRM problem (grey row).'),
        @((Get-HelpCell 'Installed' 'honeydew'), 'Get-HotFix lists this KB: the package is on the server now.', 'Nothing.'),
        @((Get-HelpCell 'Installed (build)' 'honeydew'), 'The server''s build is at or above the build this update brings (data\product-patches.psd1 knows it): a later cumulative update already contains it.', 'Nothing.'),
        @((Get-HelpCell 'Installed (history)' 'honeydew'), 'Get-HotFix no longer lists it (a newer cumulative update replaced it) but the Windows Update history records a successful install.', 'Nothing - the Build column shows the current level.'),
        @((Get-HelpCell 'By hand' 'whitesmoke'), 'The file sits in patches\SQL, \Exchange or \Other. The tool reports those patch types but never installs them; the current level is on the server''s details page.', 'Apply with the vendor''s own installer in a change window.'),
        @((Get-HelpCell 'Not applicable' 'whitesmoke'), 'A .NET Framework update is for one .NET line (4.8.1, 4.8 ...), read from the file; this server runs another line (the inventory says which). The Windows build of such a file is read from the update.mum inside its cab (its outer files name only "Windows 10.0"), so a file for another build shows Blocked: wrong OS. DISM would not refuse it: it takes a .NET rollup for the wrong build as an empty wrapper (exit 0, nothing installed), which the install checks for afterwards.', 'Download the update for the .NET line the server runs, or leave it: nothing is blocked.'),
        @((Get-HelpCell 'Blocked: reboot' 'mistyrose'), 'A reboot is pending (pink row).', 'Reboot, then check status again.'),
        @((Get-HelpCell 'Blocked: servicing'), 'Something is servicing the server right now: TiWorker busy, or the Windows Update agent installing.', 'Wait a few minutes and check status again.'),
        @((Get-HelpCell 'Blocked: Solidcore'), 'Trellix Solidcore on the server is enforcing now or on reboot (or its mode could not be read): the update would be rolled back at the boot.', ('Run the Solidcore Update Mode task (ePO), check status again. ' + $(if (Test-TrellixInUse) { 'The Solidcore column shows what the server says; the' } else { 'The' }) + ' Settings tab can switch the guard off.')),
        @((Get-HelpCell 'Blocked: disk'), 'Free space on C: is below MinFreeGB.', 'Free space (cleanmgr, old logs, DISM /StartComponentCleanup), then check status again.'),
        @((Get-HelpCell 'Blocked: signature'), 'The file is not signed by Microsoft, or the signature could not be read.', 'Download it again from the Microsoft Update Catalog; see "Where do I get patches?".'),
        @((Get-HelpCell 'Blocked: OS unknown'), 'The target build could not be read from inside the file, so the tool will not guess.', 'Check the file (patches\_info and the log); AllowUnknownTargetBuild in lib\01-Config.ps1 overrides this, at your own risk.'),
        @((Get-HelpCell 'Blocked: wrong OS'), 'The file is built for a different Windows build than the server runs (for example a 2025 update against a 2022 server).', 'Nothing for this server; download the file for its build.'),
        @((Get-HelpCell 'Blocked: dynamic update'), 'The file is a Dynamic Update - a Safe OS package for installation media and the recovery environment (WinRE), which the catalogue lists next to the month''s cumulative update. It is not an update for a running server: installed on one it stages, and the reboot undoes it. It blocks nothing else.', 'Delete the file or move it to patches\Other; the cumulative update carries what the server needs.'),
        @((Get-HelpCell 'INSTALLING (12 min)' 'lightcyan'), 'PATCH IT! handed this KB to the server as a one-shot SYSTEM task and the result has not been read yet (cyan row). The install carries on whatever happens to this window.', 'Wait with Auto-check ticked, or press "Check status" later - today or tomorrow.'),
        @((Get-HelpCell 'Blocked: installing' 'lightcyan'), 'Another KB is installing on this server right now (the run above).', 'Wait for the result, reboot, then this one.'),
        @((Get-HelpCell 'RUN UNKNOWN' 'thistle'), 'The run ended without a result on the server (purple row): the task is gone, the server rebooted mid-way, the script was stopped, or the launch lost its answer. A later status check that finds the run still going turns it back to INSTALLING.', 'Press "Analyse a failure (ticked)": the page says what the server''s logs hold, and the note is cleared.'),
        @((Get-HelpCell 'Blocked: run unknown' 'thistle'), 'Another KB of this server''s last run ended without a result (the run above): nothing else is installed until that is looked at.', 'Press "Analyse a failure (ticked)" first.'),
        @((Get-HelpCell 'READY' 'lemonchiffon'), 'Not installed and nothing blocks it: signed, built for this server, no pending reboot, nothing servicing, enough disk.', 'Tick server and file, PATCH IT!.'),
        @((Get-HelpCell 'READY (staged)' 'lemonchiffon'), 'READY, and a copy of the file is already on the server (STAGE ONLY, or kept by an earlier run) - PATCH IT! checks its hash and skips the copy.', 'Tick server and file, PATCH IT!: the window holds the install only.'))) }

    # ---- 4. the patch list ----
    $sections += @{ Heading = 'The patch list (right-hand panel)'; Lines = @(
        'One line per file found under the patches folder, in the form  KB5126655  Windows  584.6 MB  Server 2022  - KB number, patch type (= sub-folder), size, the Windows build the file is for.',
        '"(cab)" = a .cab instead of an .msu; both install the same way.',
        '"cumulative" or "servicing stack" = what the manifest inside the file says it is; with several Windows files ticked the order is a separate servicing stack update first, the cumulative update next, other Windows files after it, then .NET - never the smallest file first.',
        '"- DYNAMIC UPDATE, not for a running server" = a Safe OS package for installation media and WinRE; the KB column shows "Blocked: dynamic update" and the file is never installed.',
        '"windows10.0 ?" or "OS unknown" = the target build could not be read from inside the file; the KB column shows "Blocked: OS unknown" until that is sorted.',
        '"- by hand" = a SQL, Exchange or Other file: listed and reported, never installed by the tool.',
        '"- UNSIGNED / <state>" = the signature check failed; the KB column shows "Blocked: signature".',
        'Tick the files to install; PATCH IT! takes the ticked files to the ticked servers, and the pre-flight repeats every verdict above before anything runs.') }

    # ---- 5. the buttons ----
    $sections += @{ Heading = 'The buttons'; Note = ('Blue asks the servers (read-only). {0} change a server; STAGE ONLY (steel blue) copies files onto the servers without installing; green saves on this PC; grey works on this PC only.' -f $(if (Test-TrellixInUse) { 'Red, khaki and the two wheat-coloured Trellix Agent buttons' } else { 'Red and khaki' })); Html = (New-HelpTable -TrellixRows -Headers @('Button', 'What it does', 'During an install') -Rows @(
        @((Get-HelpButton 'Reload lists + patches'), 'Re-reads the group files (*.txt) and the patches folders; the columns follow.', 'locked'),
        @((Get-HelpButton 'Check status (ticked)' 'lightskyblue'), 'Asks the ticked servers over WinRM for build, reboot flags, hotfixes, free disk and servicing state, then fills their rows - and the inventory too while the box next to it is ticked.', 'works'),
        @((Get-HelpButton 'Check status (all shown)' 'lightskyblue'), 'The same for every row in the list.', 'works'),
        @(('<span class="btn">&#9745; Inventory (roles + software)</span>'), 'A tick box, on by default: the two status buttons also read products, roles, features, .NET, SQL, Exchange, services and tasks, which fill the Roles and Software behind columns and the software grid underneath. Untick it for a quicker status-only check.', 'works'),
        @(((Get-HelpButton 'Set credentials') + ' ' + (Get-HelpButton 'Clear credentials')), 'Stores an admin account for this session only (never written to disk) / forgets it.', 'locked'),
        @((Get-HelpButton 'STAGE ONLY  (ticked)' 'lightsteelblue'), 'Before the window: copies the ticked patch files to C:\PatchStaging on the ticked servers (one at a time, in slices, SHA256 verified) and nothing else. Skips servers where the file is installed, cannot apply or would not fit; copies where only a reboot, servicing or the Solidcore mode blocks the install for now. Recorded per the Settings tab (''OS patch stage'': not recorded by default). The cells then say READY (staged).', 'locked'),
        @((Get-HelpButton 'PATCH IT!  (ticked KBs, ticked servers)' 'tomato'), ('Pre-flight (the verdicts above), the plan, the change record (ticket or change number, approver, window), the pre-action confirmations of the Settings tab ' + $(if (Test-TrellixInUse) { '(VMware snapshot, Trellix ...)' } else { '(VMware snapshot ...)' }) + ', then the copy to one server at a time; each server installs (DISM /Add-Package) as a SYSTEM task the moment its copy is verified, so the installs overlap.'), 'locked (one run at a time)'),
        @((Get-HelpCell 'Auto-check status every 45 s'), 'The box and the seconds field above PATCH IT!. Ticked: after the launch the tool asks the installing servers at that interval (change it any time) and records each result as it lands; the status bar shows "Let the servers go" to stop watching. Unticked, now or later: the servers install on their own as SYSTEM tasks, their rows turn cyan and say INSTALLING, and "Check status" records the results whenever you come back - also after restarting the tool. Ticked again: the servers still INSTALLING are watched again (after the action running now, if one is). A failed or unknown result offers "Analyse a failure" at once.', 'works'),
        @(('<span class="btn">&#9745; Stop the Trellix Agent services first</span>'), 'A tick box above PATCH IT!, on by default (StopTrellixAgentForInstall on the Settings tab). Ticked: right after the second status check, PATCH IT! sets the two Trellix Agent services (masvc, macmnsvc) to Disabled and stops them on each server, under the install''s change record, before anything is copied - the field test (October 2026) saw the install fail and roll back with the agent running. A server where that fails is not installed (the result says why); untick the box to install with the agent running. The Trellix Agent column then shows STOPPED (Disabled) in orange until the agent is started again.', 'locked'),
        @(((Get-HelpButton 'Start Trellix Agent (ticked)' 'wheat') + ' ' + (Get-HelpButton 'Stop Trellix Agent (ticked)' 'wheat')), 'The two agent services on the ticked servers by hand: Start = Automatic and running (after the patching and the reboot - the agent reports to ePO again), Stop = Disabled and stopped. Fresh status first; servers without the agent or already in that state are skipped; one Yes/No naming the servers (No is the default); the change record of ''Trellix Agent services'' (a change record or a maintenance activity by default, Settings tab); then a fresh status. Start is refused while an OS patch run is still open on the server. Each server keeps its own record (Application event 940, C:\PatchStaging\change-log.txt).', 'locked'),
        @((Get-HelpButton 'Reboot (ticked)' 'khaki'),('Asks, records the change, then restarts the ticked servers. Use it for pink rows and after an install that asks for it - one reboot also finishes a software update from the Software tab.' + $(if (Test-TrellixInUse) { ' A server whose Trellix Agent services are disabled is named in the log: start them when it is back.' } else { '' })), 'locked'),
        @((Get-HelpButton 'Change log'), 'changes\change-log.csv: one row per server per action (approved, aborted, each result) with the change reference. Each server keeps the same record in its Application log and C:\PatchStaging\change-log.txt.', 'works'),
        @((Get-HelpButton 'Test WinRM port (ticked)' 'lightskyblue'), ('A WinRM call to port {0} without credentials - separates network, firewall and certificate problems from login problems.' -f (Get-WinRMPortText)), 'works'),
        @((Get-HelpButton 'Analyse a failure (ticked)' 'lightskyblue'), ('After a failed or rolled-back install: reads the last {0} hours of the server''s own evidence (the tool''s result files and DISM logs, CBS.log, the Setup event log, the Windows Update history, the boot events, the Solidcore log and security-product events) and opens a page that says what the evidence points at, with a timeline. Read-only; the page is also saved in reports\.' -f $script:Config.AnalysisHoursBack), 'works'),
        @((Get-HelpButton 'Where do I get patches?'), 'The download how-to: update-history page, KB number, Microsoft Update Catalog, sub-folder.', 'works'),
        @(((Get-HelpButton 'Open patches folder') + ' ' + (Get-HelpButton 'Today''s log')), 'Opens the patches folder in Explorer / today''s log in Notepad.', 'works'),
        @(((Get-HelpButton 'Report (HTML + CSV)') + ' ' + (Get-HelpButton 'Open reports folder')), 'Writes reports\Patching-<date>.html and .csv for the rows shown / opens the folder.', 'works'),
        @((Get-HelpButton 'Help'), 'This page: every row colour, column, cell and button, each with an example.', 'works'))) }

    $sections += @{ Heading = 'While an install runs'; Lines = @(
        'Every read-only button in every console keeps working: status checks, Health checks, Security audits and reports. Details pages (double-click) open again when the run finishes.',
        'PATCH IT!, Reboot, Reload and the credential buttons stay locked until the run finishes.',
        'A pop-up that a read-only action would open is not shown while the run is watched (a line in the log says so instead), because a pop-up would pause the watch: press the button again afterwards.',
        'While the run is watched, the servers being installed are skipped by the other checks, and their rows keep the run''s state. Reboot (ticked) never reboots a server whose row says INSTALLING.') }

    return (New-DetailsHtml -Title 'O/S Patching console: what the rows, cells and buttons mean' -Subtitle 'every example is drawn the way the window draws it' -Console 'Patching' -Facts @(@('Patch files', $script:Patches.Count), @('Decision function', 'Get-PatchVerdict (lib\04-Patches.ps1)'), @('More', 'Code Tour part B (Patching)')) -Sections $sections)
}
function Show-ServerDetails {
    param([string]$Name)
    $s = $script:ServerStatus[$Name]
    if (-not $s) { Show-GuiNotice "$Name has not been checked yet. Tick it and press 'Check status'."; return }
    Show-DetailsWindow -Title "Server: $Name" -Html (Get-ServerDetailsHtml -Name $Name)
}

function Request-PatchWatch {
    # The Auto-check box ticked by the operator.  A watch still running carries on (it reads the box on every pass);
    # otherwise the runs still INSTALLING are watched again - at once, or as soon as the action running now has finished.
    if ($script:Gui['StopOwner'] -eq 'install watch') { return }
    if (@(Get-OpenInstallServers).Count -eq 0) { return }
    if (-not $script:Gui['Busy']) { Start-PatchWatchAction; return }
    Write-PatchLog ("Auto-check: the servers still installing are watched again once '{0}' has finished" -f $script:Gui['BusyName']) 'INFO'
    if (-not $script:Gui['AutoCheckTimer']) {
        $t = New-Object System.Windows.Forms.Timer; $t.Interval = 1000
        $t.Add_Tick({
            $box = $script:Gui['AutoCheckBox']
            if (-not $box -or -not $box.Checked -or $script:Gui['StopOwner'] -eq 'install watch') { $this.Stop(); return }
            if ($script:Gui['Busy']) { return }
            $this.Stop()
            if (@(Get-OpenInstallServers).Count -gt 0) { Start-PatchWatchAction }
        })
        $script:Gui['AutoCheckTimer'] = $t
    }
    $script:Gui['AutoCheckTimer'].Start()
}

function Start-PatchWatchAction {
    Invoke-GuiAction -Name 'Auto-check' -Action {
        $results = @(Resume-PatchWatch | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Success'] })
        if ($results.Count -gt 0) { Show-InstallOutcome -Results $results }
    }
}

# ---------------------------------------------------------------------
#  INVENTORY - runs ON the server.  Everything is returned as text lines
#  ("a|b|c") because remoting flattens nested objects.
# ---------------------------------------------------------------------
$script:RemoteInventoryScript = {
    param([int]$MaxProducts)
    $ErrorActionPreference = 'Continue'
    # Products: both Uninstall hives, hidden system components and OS updates left out
    $products = @()
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    # NO RESTART FROM A REMOVAL: the switches that keep a product's own uninstaller from restarting the server (or from
    # waiting on a message box nobody can answer).  The same block is in RemoteSoftwareRunScript, which adds the switches;
    # the two must stay the same.  Kind '' = an uninstaller with no known no-restart switch.
    $noRestart = {
        param([string]$UninstallExe, [string]$UninstallArgs)
        $leaf = [System.IO.Path]::GetFileName($UninstallExe)
        if ($leaf -match '(?i)^msiexec(\.exe)?$') { return @{ Kind = 'msiexec'; Add = @('/norestart', 'REBOOT=ReallySuppress') } }
        if ($leaf -match '(?i)^unins\d{3}\.exe$') { return @{ Kind = 'Inno Setup'; Add = @('/NORESTART', '/SUPPRESSMSGBOXES') } }
        if ($UninstallExe -match '(?i)\\Package Cache\\' -and $UninstallArgs -match '(?i)(^|\s)[/-]uninstall(\s|$)') { return @{ Kind = 'WiX bundle'; Add = @('/norestart') } }
        return @{ Kind = ''; Add = @() }
    }
    foreach ($k in (Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue)) {
        if (-not $k.DisplayName) { continue }
        if ($k.SystemComponent -eq 1) { continue }
        if ($k.DisplayName -match '^(Update for|Security Update for|Hotfix for|Service Pack)') { continue }
        $installed = ''
        if ([string]$k.InstallDate -match '^(\d{4})(\d{2})(\d{2})$') { $installed = '{0}-{1}-{2}' -f $Matches[1], $Matches[2], $Matches[3] }
        # the quiet uninstall: '0' none; else the kind of uninstaller whose no-restart switches the tool knows
        # ('msiexec', 'Inno Setup', 'WiX bundle'), or '1' = one that may restart the server by itself
        $quiet = '0'
        if ($k.QuietUninstallString) {
            $qs = [string]$k.QuietUninstallString; $qe = ''; $qa = ''
            if ($qs -match '^\s*"([^"]+)"\s*(.*)$') { $qe = $Matches[1]; $qa = $Matches[2] } elseif ($qs -match '^\s*(.+?\.exe)(\s+(.*))?$') { $qe = $Matches[1]; $qa = [string]$Matches[3] }
            $quiet = '1'
            $kind = [string](& $noRestart $qe $qa).Kind
            if ($kind) { $quiet = $kind }
        }
        # fields 6-9 serve the Software console's UNINSTALL: the Uninstall key's name (the MSI product code for an MSI), MSI or not, the quiet
        # uninstall, and the hive it is in ('64', or '32' = WOW6432Node: one key name can be in both - 7-Zip x64 and x86 both use "7-Zip")
        $hive = '64'; if ([string]$k.PSPath -match '\\WOW6432Node\\') { $hive = '32' }
        $products += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f ($k.DisplayName.Trim() -replace '\|', '/'), ([string]$k.DisplayVersion -replace '\|', '/'), ([string]$k.Publisher -replace '\|', '/'), $installed, ([string]$k.InstallLocation -replace '\|', '/'), ([string]$k.PSChildName -replace '\|', '/'), [int]($k.WindowsInstaller -eq 1), $quiet, $hive
    }
    $allProducts = @($products | Sort-Object -Unique)
    $productsTruncated = ($allProducts.Count -gt $MaxProducts)   # said, so "absent" is never read from a cut list (R6-D12)
    $products = @($allProducts | Select-Object -First $MaxProducts)

    # Roles and features (ServerManager is present on every Windows Server)
    $features = @()
    try {
        Import-Module ServerManager -ErrorAction Stop
        $features = @(Get-WindowsFeature | Where-Object { $_.Installed } | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.DisplayName, $_.FeatureType })
    } catch { $features = @('ERROR|' + $_.Exception.Message + '|') }

    # .NET Framework 4.x from the registry release number
    $ndp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue
    $netRelease = 0; $netName = 'none'
    if ($ndp) {
        $netRelease = [int]$ndp.Release
        if ($netRelease -ge 533320) { $netName = '4.8.1' } elseif ($netRelease -ge 528040) { $netName = '4.8' } elseif ($netRelease -ge 461808) { $netName = '4.7.2' }
        elseif ($netRelease -ge 461308) { $netName = '4.7.1' } elseif ($netRelease -ge 460798) { $netName = '4.7' } elseif ($netRelease -ge 394802) { $netName = '4.6.2' } else { $netName = "4.x (release $netRelease)" }
    }
    # .NET runtimes (6 / 8 / 9) from the shared folder
    $runtimes = @()
    $shared = Join-Path $env:ProgramFiles 'dotnet\shared'
    if (Test-Path -LiteralPath $shared) {
        foreach ($fam in (Get-ChildItem -LiteralPath $shared -Directory)) { foreach ($v in (Get-ChildItem -LiteralPath $fam.FullName -Directory)) { $runtimes += '{0} {1}' -f $fam.Name, $v.Name } }
    }
    # SQL Server instances
    $sql = @()
    $inst = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction SilentlyContinue
    if ($inst) {
        foreach ($p in $inst.PSObject.Properties) {
            if ($p.Name -like 'PS*') { continue }
            $setup = Get-ItemProperty -Path ("HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\{0}\Setup" -f $p.Value) -ErrorAction SilentlyContinue
            $sql += '{0}|{1}|{2}|{3}' -f $p.Name, $setup.Version, $setup.PatchLevel, $setup.Edition
        }
    }
    # Exchange
    $exchange = ''
    $ex = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ExchangeServer\v15\Setup' -ErrorAction SilentlyContinue
    if ($ex) {
        $fv = ''
        $exe = Join-Path ([string]$ex.MsiInstallPath) 'bin\ExSetup.exe'
        if (Test-Path -LiteralPath $exe) { $fv = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }
        $exchange = '{0}.{1}.{2}.{3}|{4}' -f $ex.MsiProductMajor, $ex.MsiProductMinor, $ex.MsiBuildMajor, $ex.MsiBuildMinor, $fv
    }
    # Services, processes and scheduled tasks (used by the dormant-software and health checks)
    $services = @()
    foreach ($svc in (Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue)) {
        $services += '{0}|{1}|{2}|{3}|{4}|{5}' -f $svc.Name, ($svc.DisplayName -replace '\|', '/'), $svc.StartMode, $svc.State, ($svc.StartName -replace '\|', '/'), ($svc.PathName -replace '\|', '/')
    }
    $processes = @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Path } catch { '' } } | Where-Object { $_ } | Sort-Object -Unique | Select-Object -First 300)
    $tasks = @()
    try {
        foreach ($t in (Get-ScheduledTask -ErrorAction Stop)) {
            $info = $null
            try { $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
            $action = ''
            if ($t.Actions -and $t.Actions[0].Execute) { $action = $t.Actions[0].Execute }
            $last = ''; $result = ''
            if ($info) { if ($info.LastRunTime) { $last = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') }; $result = [string]$info.LastTaskResult }
            $tasks += '{0}|{1}|{2}|{3}|{4}|{5}' -f $t.TaskPath, $t.TaskName, $t.State, $result, $last, ($action -replace '\|', '/')
        }
    } catch { $tasks = @('ERROR|' + $_.Exception.Message + '||||') }
    $tasks = @($tasks | Select-Object -First 400)

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Products = $products; ProductCount = $products.Count; ProductsTruncated = $productsTruncated; ProductsTotal = $allProducts.Count; Features = $features
        NetFramework = $netName; NetRelease = $netRelease; NetRuntimes = $runtimes; SqlInstances = $sql; Exchange = $exchange
        Services = $services; Processes = $processes; Tasks = $tasks
    }
}

function Get-ServerInventory {
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = { param($r) ('{0} products, {1} features, .NET {2}, SQL: {3}, Exchange: {4}' -f $r.ProductCount, @($r.Features).Count, $r.NetFramework, (@($r.SqlInstances).Count), ([bool]$r.Exchange)) }
    return (Invoke-Collector -Name 'Inventory' -ScriptBlock $script:RemoteInventoryScript -ComputerName $ComputerName -ArgumentList @($script:Config.MaxProducts) -Summary $summary)
}

function Get-RoleSummary {
    # The roles that matter for patching, short: "IIS, SQL, .NET 4.8.1"
    param($Inventory, [switch]$Full)
    $names = @($Inventory.Features | ForEach-Object { ($_ -split '\|')[0] })
    if ($Full) { return ($names -join ', ') }
    $tags = @()
    $map = [ordered]@{ 'AD-Domain-Services' = 'AD DS'; 'ADCS-Cert-Authority' = 'AD CS'; 'DNS' = 'DNS'; 'DHCP' = 'DHCP'; 'Web-Server' = 'IIS'; 'Hyper-V' = 'Hyper-V'; 'RDS-RD-Server' = 'RDS'; 'UpdateServices' = 'WSUS'; 'Print-Server' = 'Print'; 'FS-FileServer' = 'File'; 'Remote-Desktop-Services' = 'RDS' }
    foreach ($k in $map.Keys) { if ($names -contains $k) { $tags += $map[$k] } }
    if (@($Inventory.SqlInstances).Count -gt 0) { $tags += 'SQL' }
    if ($Inventory.Exchange) { $tags += 'Exchange' }
    if ($Inventory.NetFramework -and $Inventory.NetFramework -ne 'none') { $tags += ".NET $($Inventory.NetFramework)" }
    return ($tags -join ', ')
}

# ---------------------------------------------------------------------
#  Software currency: data\known-apps.psd1 + the fleet itself as a baseline.
# ---------------------------------------------------------------------
function Get-KnownApps {
    # Import-ToolData parses once and re-reads only when the file changes, so this is cheap to call often.
    $d = Import-ToolData -Name 'known-apps.psd1'
    if ($d) { return $d }
    return @{ AsOf = 'n/a'; Apps = @() }
}

function Get-ProductRows {
    # One row per product per server from the Inventory results.  A List, not += (14,000 rows on a big fleet).
    param([string[]]$Servers)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($s in $Servers) {
        $inv = Get-CollectorResult -Name 'Inventory' -Server $s
        if (-not $inv -or -not $inv.Reachable) { continue }
        foreach ($line in @($inv.Products)) {
            $f = $line -split '\|'
            if ($f.Count -lt 2) { continue }
            $rows.Add([pscustomobject]@{ Server = $s; Product = $f[0]; Version = $f[1]; Publisher = $f[2]; Installed = $f[3]; Location = $f[4]; KeyName = $f[5]; Msi = $f[6]; Quiet = $f[7]; Hive = [string]$f[8] })
        }
    }
    return @($rows.ToArray())
}
function Get-SoftwareRows {
    # Currency verdict per product per server:
    #   Current / Behind (known latest or a newer version seen in the fleet) / Stale (old install, nothing newer anywhere;
    #   an unknown product after UnknownStaleMonths) / Ageing (an unknown product after UnknownAgeingMonths: probably
    #   unmaintained) / End of life / Unknown (not in known-apps.psd1 and recent).  Each row also carries its Light.
    # The whole fleet's verdicts are computed once and cached (the fleet comparison needs every server anyway); the
    # cache is dropped with the check-row cache whenever a collector stores new results, so a 500-server refresh costs
    # a filter, not a recomputation.  Inside the computation the rule lookup and every version comparison are
    # memoised: a fleet repeats the same products and versions hundreds of times.
    param([string[]]$Servers)
    $invKeys = @()
    if ($script:Results.ContainsKey('Inventory')) { $invKeys = @($script:Results['Inventory'].Keys | Sort-Object) }
    # the stamp: every inventory's time, the catalogue (a re-read one is a new object) and the two age thresholds of the Settings
    # tab, which the verdicts below bake in - a saved change re-judges at the next repaint instead of waiting for a new inventory
    $stamp = (($invKeys | ForEach-Object { $_ + '=' + [string]$script:Results['Inventory'][$_].Checked.Ticks }) -join ';') + '|' + [string](Get-KnownApps).AsOf + '|' + [System.Runtime.CompilerServices.RuntimeHelpers]::GetHashCode((Get-KnownApps)) + '|' + [string]$script:Config.UnknownStaleMonths + '|' + [string]$script:Config.UnknownAgeingMonths
    if (-not $script:SoftwareRowCache -or $script:SoftwareRowCache.Stamp -ne $stamp) {
        $known = Get-KnownApps
        $all = @(Get-ProductRows -Servers $invKeys)
        $cmpCache = @{}
        $cmp = { param($a, $r) $k = "$a|$r"; if (-not $cmpCache.ContainsKey($k)) { $cmpCache[$k] = Compare-VersionRule -Actual $a -Rule $r }; $cmpCache[$k] }
        # newest version of each product name seen anywhere in the fleet
        $fleet = @{}
        $isVersion = @{}
        foreach ($r in $all) {
            # an empty or non-numeric version never seeds the fleet best (it would make every later compare Unknown)
            $ver = [string]$r.Version
            if (-not $isVersion.ContainsKey($ver)) { $isVersion[$ver] = ($null -ne (ConvertTo-VersionObject $ver)) }
            if (-not $isVersion[$ver]) { continue }
            $key = $r.Product.ToLower()
            if (-not $fleet.ContainsKey($key)) { $fleet[$key] = $r.Version; continue }
            if ($fleet[$key] -eq $r.Version) { continue }
            if ((& $cmp $r.Version ('>= ' + $fleet[$key])) -eq 'Compliant') { $fleet[$key] = $r.Version }
        }
        $ruleFor = @{}
        $out = New-Object System.Collections.Generic.List[object]
        $now = Get-Date
        foreach ($r in $all) {
            # the install date strictly as yyyy-MM-dd: an installer that wrote yyyyddMM or 00000000 must not throw
            $instDate = [datetime]::MinValue
            $hasDate = [datetime]::TryParseExact([string]$r.Installed, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$instDate)
            if (-not $ruleFor.ContainsKey($r.Product)) {
                $found = $null
                foreach ($k in @($known.Apps)) { if ($r.Product -like $k.Match) { $found = $k; break } }
                $ruleFor[$r.Product] = $found
            }
            $rule = $ruleFor[$r.Product]
            $verdict = 'Unknown'; $reason = 'not in data\known-apps.psd1'
            $fleetBest = $fleet[$r.Product.ToLower()]
            $behindFleet = ($fleetBest -and $fleetBest -ne $r.Version -and (& $cmp $r.Version ('>= ' + $fleetBest)) -eq 'Below')
            if ($rule) {
                if ($rule.EOL) { $verdict = 'End of life'; $reason = "marked end of life in known-apps.psd1 ($($rule.Note))" }
                elseif ($rule.Latest -and (& $cmp $r.Version ('>= ' + $rule.Latest)) -eq 'Below') { $verdict = 'Behind'; $reason = "latest known $($rule.Latest) (as of $($known.AsOf))" }
                elseif ($behindFleet) { $verdict = 'Behind'; $reason = "a newer version ($fleetBest) is installed elsewhere in the fleet" }
                else {
                    $verdict = 'Current'; $reason = $(if ($rule.Latest) { 'at or above the latest known version' } else { 'no reference version in known-apps.psd1; nothing newer in the fleet' })
                    if ($rule.CadenceMonths -and $hasDate) {
                        $age = ($now - $instDate).TotalDays / 30.4
                        if ($age -gt $rule.CadenceMonths -and -not $rule.Latest) { $verdict = 'Stale'; $reason = ('installed {0:N0} months ago, product updates about every {1} months, no reference version to compare' -f $age, $rule.CadenceMonths) }
                    }
                }
            } elseif ($behindFleet) {
                $verdict = 'Behind'; $reason = "a newer version ($fleetBest) is installed elsewhere in the fleet"
            } elseif ($hasDate) {
                # the blanket rule for products the catalogue does not know: age alone says whether updates are likely waiting
                $age = ($now - $instDate).TotalDays / 30.4
                if ($age -ge $script:Config.UnknownAgeingMonths) { $verdict = 'Ageing'; $reason = ('not in known-apps.psd1, installed {0:N0} months ago, nothing newer in the fleet - updates are probably waiting, or the product is no longer maintained (a cessation risk): confirm a patch source exists or plan its removal, then add it to the catalogue' -f $age) }
                elseif ($age -ge $script:Config.UnknownStaleMonths) { $verdict = 'Stale'; $reason = ('not in known-apps.psd1, installed {0:N0} months ago, nothing newer in the fleet - updates are likely available: check the vendor page and add it to the catalogue' -f $age) }
            }
            $light = switch ($verdict) { 'Behind' { 'Amber' } 'Stale' { 'Amber' } 'Ageing' { 'Amber' } 'End of life' { 'Red' } 'Current' { 'Green' } default { 'Grey' } }
            $out.Add([pscustomobject]@{ Server = $r.Server; Product = $r.Product; Version = $r.Version; Publisher = $r.Publisher; Installed = $r.Installed; Verdict = $verdict; Reason = $reason; Location = $r.Location; Light = $light; KeyName = $r.KeyName; Msi = $r.Msi; Quiet = $r.Quiet; Hive = $r.Hive })
        }
        $byServer = @{}
        foreach ($row in $out) { $k = $row.Server.ToLower(); if (-not $byServer.ContainsKey($k)) { $byServer[$k] = New-Object System.Collections.Generic.List[object] }; $byServer[$k].Add($row) }
        $script:SoftwareRowCache = @{ Stamp = $stamp; Rows = @($out.ToArray()); ByServer = $byServer }
    }
    # an index by server: no Where-Object over the whole fleet's rows on every call
    $picked = New-Object System.Collections.Generic.List[object]; $seen = @{}
    foreach ($s in @($Servers)) { if (-not $s) { continue }; $k = $s.ToLower(); if ($seen.ContainsKey($k)) { continue }; $seen[$k] = $true; $list = $script:SoftwareRowCache.ByServer[$k]; if ($list) { $picked.AddRange($list) } }
    return @($picked.ToArray())
}

function Start-SoftwareGridRefresh {
    # Ticks change the software grid's scope; a one-shot 300 ms timer turns "Tick all" (hundreds of events) into one rebuild.
    if (-not $script:Gui['SoftwareTimer']) {
        $t = New-Object System.Windows.Forms.Timer; $t.Interval = 300
        $t.Add_Tick({ $this.Stop(); Update-SoftwareGrid })
        $script:Gui['SoftwareTimer'] = $t
    }
    $script:Gui['SoftwareTimer'].Stop(); $script:Gui['SoftwareTimer'].Start()
}

function Update-SoftwareGrid {
    # Scoped for big fleets: the ticked servers (else every server shown) and, unless "Show all verdicts" is ticked,
    # only the rows that need attention (Behind / Stale / Ageing / End of life); never more than MaxSoftwareGridRows.
    # Sorting and counting avoid the pipeline (Sort-Object over 15,000 rows costs seconds in PowerShell 5.1).
    $grid = $script:Gui['SoftwareGrid']
    if (-not $grid) { return }
    $servers = @(Get-CheckedServers); $scope = ('{0} ticked server(s)' -f $servers.Count)
    if ($servers.Count -eq 0) { $servers = @(Get-GridAllKeys -Grid $script:Gui['ServerList']); $scope = ('all {0} server(s) shown' -f $servers.Count) }
    $all = @(Get-SoftwareRows -Servers $servers)
    $showAll = ($script:Gui['SoftwareShowAll'] -and $script:Gui['SoftwareShowAll'].Checked)
    $counts = @{}; $pick = New-Object System.Collections.Generic.List[object]
    foreach ($r in $all) {
        $counts[$r.Verdict] = 1 + [int]$counts[$r.Verdict]
        if ($showAll -or $r.Verdict -in 'Behind', 'Stale', 'Ageing', 'End of life') { $pick.Add($r) }
    }
    $rows = @($pick.ToArray())
    if ($rows.Count -gt 1) {
        $keys = New-Object string[] $rows.Count
        $rank = @{ 'End of life' = '0'; 'Behind' = '1'; 'Stale' = '2'; 'Ageing' = '3'; 'Unknown' = '4'; 'Current' = '5' }   # worst first, so the row cap drops the mildest
        for ($i = 0; $i -lt $rows.Count; $i++) { $rk = $rank[[string]$rows[$i].Verdict]; if (-not $rk) { $rk = '9' }; $keys[$i] = $rk + '|' + $rows[$i].Server + '|' + $rows[$i].Product }
        [Array]::Sort($keys, $rows, [System.StringComparer]::OrdinalIgnoreCase)
    }
    $cap = [int]$script:Config.MaxSoftwareGridRows; $capped = $false
    if ($cap -gt 0 -and $rows.Count -gt $cap) { $rows = @($rows[0..($cap - 1)]); $capped = $true }
    $colour = { param($row) switch ($row.Verdict) { 'Behind' { 'LemonChiffon' } 'Stale' { 'LemonChiffon' } 'Ageing' { 'NavajoWhite' } 'End of life' { 'MistyRose' } 'Current' { 'Honeydew' } default { 'White' } } }
    Set-GridRows -Grid $grid -Rows $rows -RowColour $colour -ToolTipProperty 'Reason' -NoKeepChecks
    if ($all.Count -eq 0) { $script:Gui['SoftwareLabel'].Text = 'nothing collected yet - with "Inventory (roles + software)" ticked on the toolbar, a status check lists every product and its currency'; return }
    $summary = ('{0} behind, {1} end of life, {2} stale, {3} ageing, {4} current, {5} unknown' -f [int]$counts['Behind'], [int]$counts['End of life'], [int]$counts['Stale'], [int]$counts['Ageing'], [int]$counts['Current'], [int]$counts['Unknown'])
    $label = ('{0} of {1} products on {2} ({3}): {4}.  Known-apps table as of {5}.' -f $rows.Count, $all.Count, $scope, $(if ($showAll) { 'all verdicts' } else { 'needing attention; "Show all verdicts" for the rest' }), $summary, (Get-KnownApps).AsOf)
    if ($capped) { $label = ('first {0} rows only - tick fewer servers, or open a server''s page for its full list.  ' -f $cap) + $label }
    $script:Gui['SoftwareLabel'].Text = $label
}

function Export-PatchingReport {
    $servers = @(Get-GridAllKeys -Grid $script:Gui['ServerList'])
    $kbRows = @()
    $summary = @()
    foreach ($name in $servers) {
        $s = $script:ServerStatus[$name]
        $inv = Get-CollectorResult -Name 'Inventory' -Server $name
        $light = 'Grey'; $state = 'not checked'
        if ($s -and -not $s.Reachable) { $state = 'unreachable: ' + $s.Error }
        elseif ($s) {
            $cells = @($script:Patches | ForEach-Object { Get-PatchCellText -Status $s -Patch $_ -Server $name })
            $blocked = @($cells | Where-Object { $_ -like 'Blocked*' -and $_ -notin 'Blocked: wrong OS', 'Blocked: dynamic update' } | Select-Object -Unique)
            $applicable = @($cells | Where-Object { $_ -notin 'By hand', 'Blocked: wrong OS', 'Not applicable', 'Blocked: dynamic update' })
            if ($s.PendingReboot) { $light = 'Amber'; $state = 'pending reboot' }
            elseif (@($cells | Where-Object { $_ -like 'READY*' }).Count -gt 0) { $light = 'Amber'; $state = 'updates ready to install' }
            elseif ($blocked.Count -gt 0) { $light = 'Red'; $state = 'blocked: ' + (($blocked | ForEach-Object { $_ -replace '^Blocked: ', '' }) -join ', ') }
            elseif ($applicable.Count -gt 0 -and @($applicable | Where-Object { $_ -notlike 'Installed*' }).Count -eq 0) { $light = 'Green'; $state = 'current for the patch files present' }
            elseif ($script:Patches.Count -eq 0) { $light = 'Grey'; $state = 'reachable (no patch files to compare)' }   # nothing is known to be in place: not green
            else { $light = 'Grey'; $state = 'no installable file applies (by hand or another Windows build)' }
            # a software install's 3010 does not block patches, but the reboot is still due
            if ($s.SoftwareRebootPending -and -not $s.PendingReboot) { $state += '; reboot due after software'; if ($light -eq 'Green') { $light = 'Amber' } }
            elseif ($s.RebootAdvised -and -not $s.PendingReboot) { $state += '; reboot advised after a software removal' }
            # the agent services off: not everything is in place on this server
            if ((Test-TrellixInUse) -and (Get-TrellixAgentInfo -Status $s).State -in 'stopped', 'mixed') { $state += '; Trellix Agent ' + (Get-TrellixAgentText -Status $s) + ' - start it after the reboot'; if ($light -eq 'Green') { $light = 'Amber' } }
        }
        $runFlag = Get-InstallFlag -Server $name
        if ($runFlag) { $light = 'Amber'; $state = $(if ([string]$runFlag.State -eq 'unknown') { ('install run {0} ended without a result - analyse' -f $runFlag.Stamp) } else { ('installing {0} since {1} (run {2})' -f (@($runFlag.KBs) -join ', '), $runFlag.Started, $runFlag.Stamp) }) }
        $roles = ''; if ($inv -and $inv.Reachable) { $roles = Get-RoleSummary -Inventory $inv }
        $summary += [pscustomobject]@{ Server = $name; Light = $light; State = $state; Build = $(if ($s) { $s.Build } else { '' }); PendingReboot = $(if ($s -and $s.Reachable) { Get-PendingRebootText -Status $s } else { '' }); FreeGB = $(if ($s) { $s.FreeGB } else { '' }); Roles = $roles; NewestHotfixes = $(if ($s) { $s.LastHotFix } else { '' }) }
        foreach ($p in $script:Patches) {
            $v = Get-PatchVerdict -Status $s -Patch $p -Server $name
            $l = 'Grey'; if ($v.Cell -like 'READY*') { $l = 'Amber' } elseif ($v.Cell -like 'Installed*') { $l = 'Green' } elseif ($v.Cell -like 'Blocked*') { $l = 'Red' }
            $kbRows += [pscustomobject]@{ Server = $name; KB = $p.KB; PatchType = $p.PatchType; File = $p.Name; Verdict = $v.Cell; Reason = $v.Reason; Light = $l }
        }
    }
    $software = @(Get-SoftwareRows -Servers $servers)   # rows carry their Light already
    if ($software.Count -gt 1) { $swKeys = New-Object string[] $software.Count; for ($i = 0; $i -lt $software.Count; $i++) { $swKeys[$i] = $software[$i].Server + '|' + $software[$i].Product }; [Array]::Sort($swKeys, $software, [System.StringComparer]::OrdinalIgnoreCase) }
    $notes = @(("Patch files: " + (@($script:Patches | ForEach-Object { "$($_.KB) [$($_.PatchType)]" }) -join ', ')), ("Known-apps table as of " + (Get-KnownApps).AsOf))
    foreach ($row in $summary) {
        $st = $script:ServerStatus[$row.Server]
        $row | Add-Member -NotePropertyName Solidcore -NotePropertyValue $(if ($st -and $st.Reachable) { Get-SolidcoreText -Status $st } else { '' })
        $row | Add-Member -NotePropertyName TrellixAgent -NotePropertyValue $(if ($st -and $st.Reachable) { Get-TrellixAgentText -Status $st } else { '' })
    }
    $summaryColumns = @('Server', 'Light', 'State', 'Build', 'PendingReboot', 'Solidcore', 'TrellixAgent', 'FreeGB', 'Roles', 'NewestHotfixes')
    if (-not (Test-TrellixInUse)) { $summaryColumns = @($summaryColumns | Where-Object { $_ -notin 'Solidcore', 'TrellixAgent' }) }   # Settings tab: Trellix not used here
    return (Export-ConsoleReport -Console 'Patching' -Title 'Patching report' -Summary $summary -SummaryColumns $summaryColumns -Notes $notes -Sections @(
        @{ Name = 'Patch verdicts'; Rows = $kbRows; Columns = @('Server', 'KB', 'PatchType', 'Verdict', 'Reason', 'File', 'Light') },
        @{ Name = 'Software'; Rows = $software; Columns = @('Server', 'Product', 'Version', 'Publisher', 'Installed', 'Verdict', 'Reason', 'Light') }))
}

# ---------------------------------------------------------------------
#  The tab
# ---------------------------------------------------------------------
function New-PatchingConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Patching' -Text (Get-ConsoleName 'Patching')

    # Fill control first, then the docked edges (WinForms docks the last-added control first).
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'
    $tab.Controls.Add($split)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.View = 'Details'; $lv.CheckBoxes = $true; $lv.FullRowSelect = $true; $lv.GridLines = $true
    $lv.Dock = 'Fill'; $lv.HideSelection = $false; $lv.ShowItemToolTips = $true
    # $this = the control that raised the event; a local such as $lv is gone by the time the event fires
    $lv.Add_DoubleClick({
        if ($script:Gui['Busy']) { Write-PatchLog 'Busy - the details window is available again when the current action finishes' 'WARN'; return }
        if ($this.SelectedItems.Count -gt 0) { Show-ServerDetails -Name $this.SelectedItems[0].Text }
    })
    # a rebuild re-ticks hundreds of rows: those events are skipped (PatchRebuilding); a click counts CheckedItems directly
    $lv.Add_ItemChecked({ if ($script:Gui['PatchRebuilding']) { return }; $script:Gui['CountLabel'].Text = ('{0} server row(s) shown, {1} ticked' -f $this.Items.Count, (Get-CheckedServers).Count); Start-SoftwareGridRefresh })   # servers, as the rebuild counts them: a server in two groups is two rows, one tick
    $lv.Add_Resize({ Resize-GridFillColumn -Grid $this })
    Set-GridTickOnBoxOnly -Grid $lv
    $serverHead = New-GridHeader -Heading 'SERVERS' -Detail '0 server row(s) shown, 0 ticked' -Tip 'Tick with the checkbox; double-click a row for its full page'
    $split.Panel1.Controls.Add($lv); $split.Panel1.Controls.Add($serverHead.Panel); $lv.BringToFront()   # the heading sits above the grid (a toolbar label was clipped at the default window width)
    $script:Gui['CountLabel'] = $serverHead.Info
    $script:Gui['ServerList'] = $lv

    # software grid underneath the server grid
    $softPanel = New-Object System.Windows.Forms.Panel; $softPanel.Dock = 'Fill'
    $softHead = New-GridHeader -Heading 'SOFTWARE ON THE SERVERS SHOWN' -Detail 'nothing collected yet - with "Inventory (roles + software)" ticked, a status check lists every product and its currency' -Tip ('Verdicts against data\known-apps.psd1 and the rest of the fleet: Current / Behind / Stale / Ageing / End of life / Unknown. A product the table does not know counts as Stale after {0} months and Ageing after {1} (updates waiting, or unmaintained). Tick servers above to narrow the list; hover a row for the reason; the server''s page (double-click above) has its full list.' -f $script:Config.UnknownStaleMonths, $script:Config.UnknownAgeingMonths)
    # placed while the strip is still 200 px wide and anchored Right, so it keeps that distance from the right edge as the strip grows
    $showAll = New-Object System.Windows.Forms.CheckBox; $showAll.Text = 'Show all verdicts'; $showAll.AutoSize = $true; $showAll.Location = New-Object System.Drawing.Point(10, 4); $showAll.Anchor = 'Top, Right'
    $script:Gui['Tips'].SetToolTip($showAll, 'Unticked: only products needing attention (Behind, Stale, Ageing, End of life). Ticked: Current and Unknown rows too.')
    $showAll.Add_CheckedChanged({ Update-SoftwareGrid })
    $softHead.Panel.Controls.Add($showAll); $script:Gui['SoftwareShowAll'] = $showAll
    # the detail text stops short of the tick box (a long line ran under it) and ends in "..." when it is cut
    $softHead.Info.AutoSize = $false; $softHead.Info.AutoEllipsis = $true; $softHead.Info.Height = 18
    $softHead.Panel.Add_Resize({ $info = $script:Gui['SoftwareLabel']; $box = $script:Gui['SoftwareShowAll']; if ($info -and $box) { $info.Width = [Math]::Max(60, $box.Left - $info.Left - 8) } })
    $softGrid = New-ConsoleGrid -NoCheckBoxes -Columns @(@{ Name = 'Server'; Width = 160 }, @{ Name = 'Product'; Width = 300 }, @{ Name = 'Version'; Width = 110 }, @{ Name = 'Publisher'; Width = 160 }, @{ Name = 'Installed'; Width = 85 }, @{ Name = 'Verdict'; Width = 90 }, @{ Name = 'Reason'; Width = 420; Fill = $true })
    $softPanel.Controls.Add($softGrid); $softPanel.Controls.Add($softHead.Panel); $softGrid.BringToFront()
    $split.Panel2.Controls.Add($softPanel)
    $script:Gui['SoftwareGrid'] = $softGrid; $script:Gui['SoftwareLabel'] = $softHead.Info

    # ---- right panel: patches + the big buttons ----
    # 420 px wide so a patch line ("KB5126655  Windows  584.6 MB  Server 2022") and the folder path fit; AutoScroll
    # so the lower buttons stay reachable on a small window.
    # A Splitter docked Right, added BEFORE the panel it resizes (WinForms docks the later-added control first,
    # so the panel takes the edge and the splitter sits on the panel's inner side): drag it to resize the panel.
    $divider = New-Object System.Windows.Forms.Splitter
    $divider.Dock = 'Right'; $divider.Width = 6; $divider.BackColor = 'Gainsboro'; $divider.MinSize = 320; $divider.MinExtra = 500
    $tab.Controls.Add($divider)
    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Right'; $right.Width = 420; $right.Padding = New-Object System.Windows.Forms.Padding(8); $right.AutoScroll = $true
    $tab.Controls.Add($right)
    $script:Gui['RightPanels'] += $right   # the window's first size shows every control of it (Set-ToolkitStartSize)

    $lblP = New-Object System.Windows.Forms.Label
    $lblP.Text = 'Patches found in \patches  (tick the ones to install):'; $lblP.Location = New-Object System.Drawing.Point(10, 8); $lblP.AutoSize = $true
    $right.Controls.Add($lblP)
    $patchList = New-Object System.Windows.Forms.CheckedListBox
    $patchList.Location = New-Object System.Drawing.Point(10, 30); $patchList.Size = New-Object System.Drawing.Size(395, 150); $patchList.CheckOnClick = $true; $patchList.HorizontalScrollbar = $true
    $right.Controls.Add($patchList)
    $script:Gui['PatchList'] = $patchList
    $lblFolder = New-Object System.Windows.Forms.Label
    $lblFolder.Location = New-Object System.Drawing.Point(10, 184); $lblFolder.Size = New-Object System.Drawing.Size(395, 48); $lblFolder.ForeColor = 'Gray'
    $right.Controls.Add($lblFolder)
    $script:Gui['PatchFolderLabel'] = $lblFolder

    $right.Controls.Add((New-GuiButton -Text 'Open patches folder' -X 10 -Y 236 -W 130 -ReadOnly -Tip 'Opens the \patches folder in Explorer' -OnClick {
        Invoke-GuiAction -Name 'Open patches folder' -ReadOnly -Action { Invoke-Item -LiteralPath $script:Config.PatchFolder } }))
    $right.Controls.Add((New-GuiButton -Text 'Today''s log' -X 145 -Y 236 -W 90 -ReadOnly -Tip 'Opens logs\Patcher-YYYYMMDD.log in Notepad' -OnClick {
        Invoke-GuiAction -Name 'Open log' -ReadOnly -Action {
            if (-not (Test-Path -LiteralPath (Get-PatchLogPath))) { Write-PatchLog 'Log file created' 'INFO' }
            Start-Process notepad.exe -ArgumentList ('"{0}"' -f (Get-PatchLogPath)) } }))
    $right.Controls.Add((New-GuiButton -Text 'Where do I get patches?' -X 240 -Y 236 -W 165 -ReadOnly -Tip 'Update history page -> KB number -> Microsoft Update Catalog -> \patches' -OnClick {
        Invoke-GuiAction -Name 'Patch how-to' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The how-to window')) { return }
            $page = New-DetailsHtml -Title 'Where do I get patches?' -Subtitle 'do this on a machine that has internet, then copy the files into the patches sub-folders' -Console 'Patching' -Sections @(@{ Heading = ''; Html = (ConvertTo-HtmlFromNotes -Text $script:PatchHowTo) })
            Show-DetailsWindow -Title 'Finding and downloading patches' -Html $page } }))

    # after PATCH IT!: keep asking the servers (every N s, N changeable mid-run) or untick and come back later - the runs are
    # tasks on the servers.  The controls are placed after they are on the panel, so their widths (and the display scaling)
    # are known: a fixed position put the box over the text on a scaled screen.
    $auto = New-Object System.Windows.Forms.CheckBox; $auto.Text = 'Auto-check status every'; $auto.AutoSize = $true; $auto.Checked = [bool]$script:Config.AutoCheckInstalls
    $script:Gui['Tips'].SetToolTip($auto, 'Ticked: after PATCH IT! the tool asks the installing servers at this interval and records each result as it lands. Unticked (now or later): the servers install on their own as SYSTEM tasks, their rows say INSTALLING, and "Check status" records the results whenever you come back - today or tomorrow, also after restarting the tool. Ticked again: the servers still INSTALLING are watched again.')
    $auto.Add_Click({ if ($this.Checked) { Request-PatchWatch } })   # a click only: the Settings tab setting the box starts nothing
    $every = New-Object System.Windows.Forms.NumericUpDown; $every.Minimum = 10; $every.Maximum = 3600; $every.Value = [math]::Min(3600, [math]::Max(10, [int]$script:Config.ProgressEverySec)); $every.Width = 64
    $script:Gui['Tips'].SetToolTip($every, 'Seconds between checks - change it any time, also while a run is being watched. The default is ProgressEverySec (lib\01-Config.ps1).')
    $everyUnit = New-Object System.Windows.Forms.Label; $everyUnit.Text = 'seconds'; $everyUnit.AutoSize = $true
    $right.Controls.AddRange(@($auto, $every, $everyUnit))   # the 'come back later' part is the tool tip and the Help page: the row has no room for it
    # the window's font first: the panel is not under the form yet while the console is built, and a width measured
    # with the default font is 10 px short of the real one (the box sat on the text)
    foreach ($ctl in @($auto, $every, $everyUnit)) { $ctl.Font = $script:Gui['Form'].Font }
    $auto.Location = New-Object System.Drawing.Point(10, 288)
    $every.Location = New-Object System.Drawing.Point(($auto.Left + $auto.PreferredSize.Width + 8), 285)
    $everyUnit.Location = New-Object System.Drawing.Point(($every.Left + $every.Width + 6), 288)
    $script:Gui['AutoCheckBox'] = $auto; $script:Gui['AutoCheckEvery'] = $every
    # the Trellix Agent (field test, October 2026): ticked, PATCH IT! sets the two ePO agent services to Disabled and stops
    # them on each server before the install; the two wheat buttons under the Reboot row start or stop them by hand
    $agentBox = New-Object System.Windows.Forms.CheckBox; $agentBox.Text = 'Stop the Trellix Agent services first'; $agentBox.AutoSize = $true; $agentBox.Checked = [bool]$script:Config.StopTrellixAgentForInstall
    $agentBox.Font = $script:Gui['Form'].Font; $agentBox.Location = New-Object System.Drawing.Point(10, 314)
    $script:Gui['Tips'].SetToolTip($agentBox, 'Ticked (the default): PATCH IT! sets the Trellix Agent services masvc and macmnsvc to Disabled and stops them on each server before the install, under the install''s change record - the field test saw installs fail and roll back with the agent running. A server where that fails is not installed. The Trellix Agent column then shows STOPPED (Disabled) in orange: after the reboot, press "Start Trellix Agent (ticked)". Unticked: the services are left as they are.')
    $right.Controls.Add($agentBox); $script:Gui['TrellixStopBoxPatching'] = $agentBox
    $btnPatch = New-GuiButton -Text 'PATCH IT!  (ticked KBs, ticked servers)' -X 10 -Y 342 -W 395 -H 50 -Colour 'Tomato' -Tip 'Runs the pre-flight, shows the plan, asks for the change record, then the pre-action confirmations (Settings tab)' -OnClick {
        Invoke-GuiAction -Name 'Install' -Action {
            $servers = Get-CheckedServers; $patches = Get-CheckedPatches
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            if ($patches.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one patch first.' -Icon 'Warning'; return }
            # Only real result objects count (anything else in the output stream would be a leaked pop-up value).
            $results = @(Install-PatchOnServers -ComputerName $servers -Patches $patches | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Success'] })
            Show-InstallOutcome -Results $results
        }
    }
    $btnPatch.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
    $right.Controls.Add($btnPatch)

    $right.Controls.Add((New-GuiButton -Text 'STAGE ONLY  (ticked)' -X 10 -Y 400 -W 195 -H 34 -Colour 'LightSteelBlue' -Tip 'Copies the ticked patch files to C:\PatchStaging on the ticked servers ahead of the window and verifies them (SHA256). Nothing is installed; the cells then say READY (staged) and PATCH IT! skips the copy.' -OnClick {
        Invoke-GuiAction -Name 'Stage patches' -Action {
            $servers = Get-CheckedServers; $patches = Get-CheckedPatches
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            if ($patches.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one patch first.' -Icon 'Warning'; return }
            $null = Copy-PatchToServers -ComputerName $servers -Patches $patches
        }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Reboot (ticked)' -X 210 -Y 400 -W 195 -H 34 -Colour 'Khaki' -Tip 'Fresh status first; only servers PENDING a reboot by default; refused while DISM is running.' -OnClick {
        Invoke-GuiAction -Name 'Reboot' -Action {
            $servers = Get-CheckedServers
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            Restart-PatchedServers -ComputerName $servers
        }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Start Trellix Agent (ticked)' -X 10 -Y 440 -W 195 -H 30 -Colour 'Wheat' -Tip 'After the patching and the reboot: sets the Trellix Agent services masvc and macmnsvc to Automatic and starts them on the ticked servers - fresh status, a Yes/No naming the servers, the change record. The agent reports to ePO again from then on.' -OnClick {
        Invoke-GuiAction -Name 'Trellix Agent start' -Action {
            $servers = Get-CheckedServers
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            $null = Set-TrellixAgentOnServers -ComputerName $servers -Mode start
        }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Stop Trellix Agent (ticked)' -X 210 -Y 440 -W 195 -H 30 -Colour 'Wheat' -Tip 'By hand, what the box above PATCH IT! does before an install: sets the Trellix Agent services masvc and macmnsvc to Disabled and stops them on the ticked servers - fresh status, a Yes/No naming the servers, the change record. ePO hears nothing from them until they are started again.' -OnClick {
        Invoke-GuiAction -Name 'Trellix Agent stop' -Action {
            $servers = Get-CheckedServers
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            $null = Set-TrellixAgentOnServers -ComputerName $servers -Mode stop
        }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Test WinRM port (ticked)' -X 10 -Y 476 -W 195 -H 30 -Colour 'LightSkyBlue' -ReadOnly -Tip ('Test-WSMan on the ticked servers: is {0} open and answering? Needs no credentials. Works during an install.' -f (Get-WinRMPortText)) -OnClick {
        Invoke-GuiAction -Name 'WinRM test' -ReadOnly -Action {
            $servers = Get-CheckedServers
            if ($servers.Count -eq 0) { Show-GuiNotice 'Tick at least one server first.'; return }
            foreach ($s in $servers) { Test-ServerWinRM -ComputerName $s | Out-Null }
        }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Analyse a failure (ticked)' -X 210 -Y 476 -W 195 -H 30 -Colour 'LightSkyBlue' -ReadOnly -Tip 'After a failed or rolled-back install: reads the server''s own logs (result files, DISM, CBS, Setup events, update history, boot events, Solidcore) and says what they point at. Read-only.' -OnClick {
        Invoke-GuiAction -Name 'Failure analysis' -ReadOnly -Action {
            $servers = Get-CheckedServers
            if ($servers.Count -eq 0) { Show-GuiNotice 'Tick the server(s) whose install failed first.'; return }
            Show-FailureAnalysis -ComputerName $servers
        }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Report (HTML + CSV)' -X 10 -Y 512 -W 195 -H 30 -ReadOnly -Tip 'Writes reports\Patching-<date>.html and .csv for the servers shown' -OnClick {
        Invoke-GuiAction -Name 'Patching report' -ReadOnly -Action { Show-ReportDone -Report (Export-PatchingReport) }
    }))
    $right.Controls.Add((New-GuiButton -Text 'Open reports folder' -X 210 -Y 512 -W 195 -H 30 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Open reports folder' -ReadOnly -Action { Open-ReportFolder } }))

    $right.Controls.Add((New-GuiButton -Text 'Change log' -X 10 -Y 548 -W 195 -H 30 -ReadOnly -Tip 'Every install, removal and reboot with its change record (changes\change-log.csv), newest first' -OnClick {
        Invoke-GuiAction -Name 'Change log' -ReadOnly -Action { Show-ChangeLogWindow } }))
    $right.Controls.Add((New-GuiButton -Text 'Help' -X 210 -Y 548 -W 195 -H 30 -ReadOnly -Tip 'A page with an example of every row colour, column, KB cell and button' -OnClick {
        Invoke-GuiAction -Name 'Patching help' -ReadOnly -Action { Show-ConsoleHelp -Console 'Patching' -Html (Get-PatchingHelpHtml) } }))

    # no colour key on the panel: the Help page has every colour with an example, the tool tips the rest
    # every full-width control follows the panel when the divider is dragged
    foreach ($c in $right.Controls) { if ($c.Width -ge 390) { $c.Anchor = 'Top, Left, Right' } }
    Register-PanelButtonRows -Panel $right -Name 'PatchingRight'   # the two- and three-button rows follow the width too
    # the Trellix box and buttons: a band each, taken away - the gap closed - while Trellix is not in use (Update-TrellixShown)
    Add-PanelBand -Panel $right -Controls @($script:Gui['TrellixStopBoxPatching']) -Height 28 -Kind 'Trellix'
    Add-PanelBand -Panel $right -Controls @($right.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -like '*Trellix Agent (ticked)' }) -Height 36 -Kind 'Trellix'

    # ---- toolbar ----
    $toolbar = New-ConsoleToolbar -Tab $tab
    $combo = New-GroupPicker -Toolbar $toolbar -OnChange { Update-ServerList; Update-SoftwareGrid }
    $script:Gui['GroupCombo'] = $combo

    $toolbar.Controls.Add((New-GuiButton -Text 'Reload lists + patches' -X 235 -Y 8 -W 150 -Tip 'Re-reads the *.txt group files and the patches folders' -OnClick {
        Invoke-GuiAction -Name 'Reload' -Action { Initialize-ToolkitData }
    }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Check status (ticked)' -X 390 -Y 8 -W 150 -Colour 'LightSkyBlue' -ReadOnly -Tip 'WinRM status check of the ticked servers. Works during an install.' -OnClick {
        Invoke-GuiAction -Name 'Status check' -ReadOnly -Action {
            $servers = Get-CheckedServers
            if ($servers.Count -eq 0) { Show-GuiNotice 'Tick at least one server first (or use "Check status (all shown)").'; return }
            Get-ServerStatus -ComputerName $servers | Out-Null
            if ($script:Gui['PatchInventoryBox'].Checked) { Get-ServerInventory -ComputerName $servers | Out-Null }
            Show-TrellixAgentWarning -Servers $servers   # the agent services off on a server: the warning the scan owes
        }
    }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Check status (all shown)' -X 545 -Y 8 -W 150 -Colour 'LightSkyBlue' -ReadOnly -Tip 'Works during an install.' -OnClick {
        Invoke-GuiAction -Name 'Status check' -ReadOnly -Action {
            $all = @(Get-GridAllKeys -Grid $script:Gui['ServerList'])
            if ($all.Count -eq 0) { Show-GuiNotice 'No servers in the list. Add names to a PatchGroup-*.txt file and reload.'; return }
            Get-ServerStatus -ComputerName $all | Out-Null
            if ($script:Gui['PatchInventoryBox'].Checked) { Get-ServerInventory -ComputerName $all | Out-Null }
            Show-TrellixAgentWarning -Servers $all
        }
    }))
    # Inventory rides along with the status checks while this box is ticked (the default): one press checks everything.
    $invBox = New-Object System.Windows.Forms.CheckBox
    $invBox.Text = 'Inventory (roles + software)'; $invBox.Checked = $true; $invBox.AutoSize = $true
    $invBox.Font = New-Object System.Drawing.Font('Segoe UI', 10); $invBox.Location = New-Object System.Drawing.Point(702, 15)
    $script:Gui['Tips'].SetToolTip($invBox, 'Ticked: "Check status (ticked)" and "Check status (all shown)" also read products, roles, .NET, SQL, Exchange, services and tasks - the Roles and Software behind columns and the software grid. Untick for a quicker status-only check.')
    $toolbar.Controls.Add($invBox); $script:Gui['PatchInventoryBox'] = $invBox
    $toolbar.Controls.Add((New-GuiButton -Text 'Tick all' -X 915 -Y 8 -W 70 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['ServerList'] -Checked $true }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Untick all' -X 990 -Y 8 -W 80 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['ServerList'] -Checked $false }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Set credentials' -X 1075 -Y 8 -W 110 -Tip 'Foreground Get-Credential prompt. Only needed if your login is refused.' -OnClick { Invoke-GuiAction -Name 'Set credentials' -Action { Get-PatcherCredential -Reason 'alternate account for WinRM' | Out-Null } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Clear credentials' -X 1190 -Y 8 -W 115 -OnClick { Invoke-GuiAction -Name 'Clear credentials' -Action { Clear-PatcherCredential } }))
    # the row count sits above the grid (see the Panel1 block): on the toolbar it was clipped at the default window width

    # ---- banner ----
    $banner = New-ConsoleBanner -Tab $tab -Console 'Patching' -Title ("{0}'S PATCH PALACE" -f $script:Config.OperatorName.ToUpper()) -Subtitle (Get-RandomQuip)
    $banner.Title.Add_Click({ $script:Gui['QuipLabel'].Text = Get-RandomQuip })
    $script:Gui['QuipLabel'] = $banner.Subtitle
    $split.BringToFront()
    $script:Gui['PatchSplit'] = $split
    $tab.Add_Resize({ try { $s = $script:Gui['PatchSplit']; $s.SplitterDistance = [int]($s.Height * 0.62) } catch { } })

    Register-ConsoleRefresher -Console 'Patching' -Refresh { Update-PatchList; Update-ServerList; Update-SoftwareGrid }
}
