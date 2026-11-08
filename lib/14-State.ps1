# =====================================================================
#  14-State.ps1  -  SAVED RESULTS, IMPORTED RESULTS, THE SELF-CHECK AND THE SPOKE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Every console paints from one table, $script:Results[<collector>][<server>].  This file keeps that table on
#  disk and brings it back:
#    state\servers\<server>.xml   one file per server (name as typed in the group file): the last GOOD result of
#                                 every collector, plus the latest failed attempt, written with Export-Clixml after
#                                 each check (a short timer flushes while the window is open) and read again at the
#                                 next start and at every Reload.  Import-Clixml only ever builds property bags -
#                                 a file cannot run anything here.
#    "Last checked"               every console's grid shows the date and time of the result it paints and colours
#                                 that one cell by age (ResultFreshDays green, ResultStaleDays amber, red beyond).
#                                 A check that fails keeps the good result and its age; the WinRM cell (or the
#                                 Worst / Top red text) says the latest attempt failed.
#    "; winrm: no"                a server so marked in its group file is never called over WinRM by any console or
#                                 action.  It checks itself: Start-WinRMToolkit.ps1 -SelfCheck on the server runs
#                                 every collector there, over no network, and writes its one results file - into the
#                                 hub's state\servers share, or carried over and taken in with "Import results".
#                                 The hub writes a ready copy of itself for such a server (Copy for a server:
#                                 state\server-copies\<server>-local-winrm\ with settings\spoke.json filled in, INSTRUCTIONS.txt and, when
#                                 asked, Run-SelfCheck.ps1).
#    the spoke                    Start-WinRMToolkit.ps1 -Spoke: the whole window on a server the hub cannot reach,
#                                 checking and patching the computer it runs on from the hub's patches\ and
#                                 software\ (a share or a copy), its results file written where the hub reads it.
#  The results files hold host names, account names and findings: state\ is git-ignored and for the operators only.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  14-State.ps1
#  New 2026-11-05 (field test: domain controllers that refuse WinRM while RDP works; results that vanished when the
#  window closed).  Nothing here talks to a server: the self-check runs on the computer it is on.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ______________cf________________   Date : _____8-11-26_________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  The file per server
# ---------------------------------------------------------------------
function Get-StateFolder {
    # Where the results files live: state\servers\ under the root folder, or the results folder a spoke or a
    # self-check was given (the hub's share), or what the Settings tab's folder line says.
    return [string]$script:Config.StateFolder
}

function Get-StateFilePath {
    # state\servers\<server>.xml - the name as typed in the group file, lower case, anything a file name cannot hold replaced
    param([Parameter(Mandatory = $true)][string]$Server)
    $leaf = (([string]$Server).Trim().ToLower() -replace '[^a-z0-9\.\-_]', '_')
    if (-not $leaf) { $leaf = 'server' }
    return (Join-Path (Get-StateFolder) ($leaf + '.xml'))
}

function Get-PersistedCollectors {
    # Every collector's table is kept except a command's answer (the Commands console shows the last answer of a session only)
    return @($script:Results.Keys | Where-Object { $_ -ne 'Command' } | Sort-Object)
}

function Set-ResultFailure {
    # A check that failed while the table holds a good result: the good result stays, marked with this attempt
    param([Parameter(Mandatory = $true)]$Result, [string]$Reason, [datetime]$At = (Get-Date))
    $Result | Add-Member -NotePropertyName LastAttempt -NotePropertyValue $At -Force
    $Result | Add-Member -NotePropertyName LastError -NotePropertyValue $Reason -Force
}

function Get-ResultFailure {
    # The error of the latest failed attempt on a result that still holds good data, else ''
    param($Result)
    if ($Result -and $Result.PSObject.Properties['LastError'] -and $Result.LastError) { return [string]$Result.LastError }
    return ''
}

function Test-ResultCurrent {
    # Good data AND the latest attempt succeeded: what an action may rely on (a grid paints older data too)
    param($Result)
    return [bool]($Result -and $Result.Reachable -and -not (Get-ResultFailure $Result))
}

function Get-ActionResult {
    # What an action (an install, a reboot, a plan) may act on: the stored result when its latest attempt succeeded; a
    # stand-in "unreachable" object when the latest attempt failed - the data is shown, never acted on; $null when none
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][string]$Server)
    $r = Get-CollectorResult -Name $Name -Server $Server
    if (-not $r) { return $null }
    $err = Get-ResultFailure $r
    if (-not $err) { return $r }
    $at = Get-Date
    if ($r.PSObject.Properties['LastAttempt'] -and ($r.LastAttempt -is [datetime])) { $at = $r.LastAttempt }
    return [pscustomobject]@{ Computer = $Server; Reachable = $false; Error = ('the latest check failed: ' + $err + ' (the window shows the result of ' + (Format-LastChecked $r.Checked) + ')'); Checked = $at }
}

function New-ServerStateDocument {
    # What the file holds: the good result of every collector, the latest failed attempt of the others, and who wrote it.
    # $null when the table knows nothing about the server.
    param([Parameter(Mandatory = $true)][string]$Server)
    $results = @{}; $attempts = @{}; $any = $false; $computer = ''
    foreach ($c in (Get-PersistedCollectors)) {
        $r = $script:Results[$c][$Server]
        if ($null -eq $r) { continue }
        $any = $true
        if ($r.Reachable) {
            $results[$c] = $r
            if (-not $computer -and $r.PSObject.Properties['Computer'] -and $r.Computer) { $computer = [string]$r.Computer }
        } else {
            $attempts[$c] = @{ At = $r.Checked; Error = [string]$r.Error }
        }
    }
    if (-not $any) { return $null }
    $domain = ''
    if (Test-ThisComputer -Name $Server) { $domain = Get-ThisComputerDomain }
    elseif ($Server.Contains('.')) { $domain = $Server.Substring($Server.IndexOf('.') + 1).ToLower() }
    return [pscustomobject]@{
        Format = 1; Tool = $script:Config.ToolName; Version = $script:Config.ToolVersion
        WrittenBy = (Get-OperatorIdentity); WrittenOn = $env:COMPUTERNAME; WrittenAt = (Get-Date)
        Server = $Server; Computer = $computer; Domain = $domain
        Results = $results; Attempts = $attempts
    }
}

function Save-ServerState {
    # Writes the server's file (a .part first, then one move: a reader never sees half a file).  $true when written.
    param([Parameter(Mandatory = $true)][string]$Server)
    $doc = New-ServerStateDocument -Server $Server
    if (-not $doc) { return $false }
    $folder = Get-StateFolder
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $path = Get-StateFilePath -Server $Server
    $part = $path + '.part'
    $doc | Export-Clixml -LiteralPath $part -Depth 8 -Encoding UTF8 -Force
    Move-Item -LiteralPath $part -Destination $path -Force
    $script:StateSeen[$path.ToLower()] = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks   # written here: a reload need not read it back
    return $true
}

function Set-StateDirty {
    # A server whose results changed: its file is written by the next flush (Save-DirtyStates)
    param([string[]]$Server)
    if (-not $script:Config.KeepResults) { return }
    foreach ($s in @($Server)) { if ($s) { $script:StateDirty[$s] = $true } }
}

function Save-DirtyStates {
    # Writes the files of the servers marked dirty: all of them (-All: at the end of a self-check, when the window closes,
    # without a window), or for about $MaxMs at a time (the window's timer, so a 300-server check never freezes the grid).
    # A folder that cannot be written is said once per session; the window keeps showing what it knows.
    param([switch]$All, [int]$MaxMs = 300)
    if ($script:StateDirty.Count -eq 0) { return 0 }
    if (-not $script:Config.KeepResults) { $script:StateDirty.Clear(); return 0 }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $done = 0
    foreach ($s in @($script:StateDirty.Keys)) {
        try { $null = Save-ServerState -Server $s }
        catch {
            if (-not $script:StateWriteWarned) {
                $script:StateWriteWarned = $true
                Write-PatchLog ("Saved results not written to {0} ({1}) - the window still shows them; the next start will not" -f (Get-StateFolder), (Get-ShortError $_)) 'WARN'
            }
        }
        $script:StateDirty.Remove($s); $done++
        if (-not $All -and $watch.ElapsedMilliseconds -gt $MaxMs) { break }
    }
    return $done
}

function Remove-ServerResults {
    # The "Clear saved data (ticked)" button: every collector's result for the servers goes from the table, their results files
    # go from state\servers\, and the consoles show them as not checked until the next check (owner's ask, 2026-11-06).  The
    # servers themselves are not touched.  Returns @{ Servers; Files }.
    param([string[]]$Servers)
    $names = @(Get-UniqueNames @($Servers)); $files = 0
    foreach ($s in $names) {
        foreach ($c in @($script:Results.Keys)) { $t = $script:Results[$c]; if ($t -is [hashtable] -and $t.ContainsKey($s)) { $t.Remove($s) } }
        if ($script:StateDirty.ContainsKey($s)) { $script:StateDirty.Remove($s) }
        # every file of this server: the one written under the name as typed, and one a self-check or a spoke wrote under
        # the server's own name with its domain (srv01.corp.local.xml for SRV01) - the import maps them by label the same way
        $label = ((((([string]$s).Trim().ToLower()) -replace '[^a-z0-9\.\-_]', '_') -split '\.')[0])
        $folder = Get-StateFolder
        if ($label -and (Test-Path -LiteralPath $folder)) {
            foreach ($f in @(Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File -ErrorAction SilentlyContinue | Where-Object { (($_.BaseName -split '\.')[0]).ToLower() -eq $label })) {
                try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $files++ } catch { Write-PatchLog ("{0}: the results file {1} was not deleted: {2}" -f $s, $f.Name, (Get-ShortError $_)) 'WARN' }
                $script:StateSeen.Remove($f.FullName.ToLower())
            }
        }
    }
    Clear-CheckRowCache
    if (Get-Command -Name 'Clear-SecurityRowCache' -ErrorAction SilentlyContinue) { Clear-SecurityRowCache }
    $script:SoftwareRowCache = $null
    Write-PatchLog ("Saved data cleared for {0} server(s) ({1} results file(s) deleted) - not checked until the next check: {2}" -f $names.Count, $files, ($names -join ', ')) 'OK'
    return @{ Servers = $names; Files = $files }
}

function Remove-OldServerStates {
    # ResultsKeepDays: a file no check or import has written for that long goes (a server taken out of the lists)
    $days = [int]$script:Config.ResultsKeepDays
    $folder = Get-StateFolder
    if ($days -le 0 -or -not (Test-Path -LiteralPath $folder)) { return 0 }
    $limit = (Get-Date).AddDays(-$days)
    $old = @(Get-ChildItem -LiteralPath $folder -Filter '*.xml' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limit })
    foreach ($f in $old) { try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop } catch { Write-PatchLog ("Old results file not deleted: {0} ({1})" -f $f.Name, (Get-ShortError $_)) 'WARN' } }
    if ($old.Count -gt 0) { Write-PatchLog ("{0} saved results file(s) not written for {1} days deleted from {2} (ResultsKeepDays, Settings tab)" -f $old.Count, $days, $folder) 'INFO' }
    return $old.Count
}

# ---------------------------------------------------------------------
#  Reading the files back: at start-up, at every Reload, and the Import results button
# ---------------------------------------------------------------------
function Read-ServerStateFile {
    # One file as a document, or $null with the reason logged.  Import-Clixml builds property bags only - nothing runs.
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $doc = Import-Clixml -LiteralPath $Path -ErrorAction Stop
    } catch { Write-PatchLog ("Results file not readable: {0} ({1})" -f $Path, (Get-ShortError $_)) 'WARN'; return $null }
    if (-not $doc -or -not $doc.PSObject.Properties['Format'] -or [int]$doc.Format -ne 1 -or -not $doc.PSObject.Properties['Results'] -or -not $doc.PSObject.Properties['Server'] -or -not $doc.Server) {
        Write-PatchLog ("Results file skipped - not a results file of this toolkit: {0}" -f $Path) 'WARN'; return $null
    }
    if ($null -eq $doc.Results) { $doc.Results = @{} }
    if (-not $doc.PSObject.Properties['Attempts'] -or $null -eq $doc.Attempts) { $doc | Add-Member -NotePropertyName Attempts -NotePropertyValue @{} -Force }
    return $doc
}

function Resolve-StateServerNames {
    # The names in the loaded groups this file is about: the name it was written under, the server's own name, or that
    # name with its domain - and a short name typed for a server whose file names its domain (SRV01 = srv01.corp.local).
    # Empty when no group lists it (the results are kept under the file's own name and show once a group names it).
    param([Parameter(Mandatory = $true)]$Doc)
    $typed = @(Get-UniqueNames @(foreach ($g in @($script:Groups)) { @($g.Servers) }))
    $server = ([string]$Doc.Server).Trim().ToLower()
    $computer = ''; if ($Doc.PSObject.Properties['Computer']) { $computer = ([string]$Doc.Computer).Trim().ToLower() }
    $domain = ''; if ($Doc.PSObject.Properties['Domain']) { $domain = ([string]$Doc.Domain).Trim().ToLower().TrimStart('.') }
    $fqdn = ''; if ($computer -and $domain) { $fqdn = $computer + '.' + $domain }
    $serverLabel = ($server -split '\.')[0]; $serverDomain = ''; if ($server.Length -gt $serverLabel.Length) { $serverDomain = $server.Substring($serverLabel.Length + 1) }
    $hits = @()
    foreach ($t in $typed) {
        $tl = $t.ToLower()
        if ($tl -eq $server -or ($computer -and $tl -eq $computer) -or ($fqdn -and $tl -eq $fqdn)) { $hits += $t; continue }
        $label = ($tl -split '\.')[0]; $tDomain = ''; if ($tl.Length -gt $label.Length) { $tDomain = $tl.Substring($label.Length + 1) }
        # the same label, and no domain on either side that says otherwise
        if ($computer -and $label -eq $computer -and (-not $tDomain -or -not $domain -or $tDomain -eq $domain)) { $hits += $t; continue }
        if ($label -eq $serverLabel -and (-not $tDomain -or -not $serverDomain -or $tDomain -eq $serverDomain)) { $hits += $t; continue }
    }
    return @(Get-UniqueNames $hits)
}

function Merge-StateDocument {
    # Lays a document over the table for the given names, collector by collector: the newer result wins, so a partial
    # run never wipes a fuller one, and a failed attempt newer than the good data marks it (Set-ResultFailure).
    # Returns @{ Taken = @(<collector> ...); Skipped = @(...) }.
    param([Parameter(Mandatory = $true)]$Doc, [Parameter(Mandatory = $true)][string[]]$Names)
    $taken = @(); $skipped = @()
    $results = $Doc.Results; $attempts = $Doc.Attempts
    foreach ($c in @($results.Keys | Sort-Object)) {
        $r = $results[$c]
        if (-not $r -or -not $r.PSObject.Properties['Checked'] -or -not ($r.Checked -is [datetime])) { continue }
        if (-not $script:Results.ContainsKey($c)) { $script:Results[$c] = @{} }
        $tookOne = $false
        foreach ($n in $Names) {
            $have = $script:Results[$c][$n]
            if ($have -and $have.Reachable -and ($have.Checked -is [datetime]) -and $have.Checked -ge $r.Checked) { continue }   # what is here is as new or newer
            $copy = $r
            if ($Names.Count -gt 1) { $copy = $r.PSObject.Copy() }   # two aliases of one box: each its own object, so a later mark touches one row only
            if ($have -and -not $have.Reachable -and ($have.Checked -is [datetime]) -and $have.Checked -gt $r.Checked) { Set-ResultFailure -Result $copy -Reason ([string]$have.Error) -At $have.Checked }
            elseif ($have -and $have.Reachable -and $have.PSObject.Properties['LastAttempt'] -and ($have.LastAttempt -is [datetime]) -and $have.LastAttempt -gt $r.Checked) { Set-ResultFailure -Result $copy -Reason (Get-ResultFailure $have) -At $have.LastAttempt }
            $script:Results[$c][$n] = $copy
            $tookOne = $true
        }
        if ($tookOne) { $taken += $c } else { $skipped += $c }
    }
    foreach ($c in @($attempts.Keys | Sort-Object)) {
        if ($results.ContainsKey($c)) { continue }   # the good result above already carries what matters
        $a = $attempts[$c]
        if (-not $a -or -not ($a.At -is [datetime])) { continue }
        if (-not $script:Results.ContainsKey($c)) { $script:Results[$c] = @{} }
        $tookOne = $false
        foreach ($n in $Names) {
            $have = $script:Results[$c][$n]
            if ($have -and ($have.Checked -is [datetime]) -and $have.Checked -ge $a.At) {
                # good data here, older than that failed attempt: mark it, unless a later attempt is already on it
                if ($have.Reachable -and -not ($have.PSObject.Properties['LastAttempt'] -and ($have.LastAttempt -is [datetime]) -and $have.LastAttempt -ge $a.At)) { Set-ResultFailure -Result $have -Reason ([string]$a.Error) -At $a.At; $tookOne = $true }
                continue
            }
            if ($have -and $have.Reachable) { Set-ResultFailure -Result $have -Reason ([string]$a.Error) -At $a.At; $tookOne = $true; continue }
            $script:Results[$c][$n] = [pscustomobject]@{ Computer = $n; Reachable = $false; Error = [string]$a.Error; Checked = $a.At }
            $tookOne = $true
        }
        if ($tookOne) { $taken += $c } else { $skipped += $c }
    }
    return @{ Taken = $taken; Skipped = $skipped }
}

function Import-ServerStates {
    # Reads every results file of the state folder into the table: at start-up, and at every Reload (then only the files
    # written since - a spoke or a self-check that writes into the hub's share is picked up that way).  -Force reads all.
    # -Progress is told before each file is read (its number, the count, its name): the "Loading last data" box of the
    # first open counts them off with it.  Returns @{ Files; Skipped (unchanged since last read); Servers; Taken; Oldest;
    # Newest } for the log line.
    param([string]$Folder = '', [switch]$Force, [scriptblock]$Progress)
    if (-not $Folder) { $Folder = Get-StateFolder }
    $out = @{ Files = 0; Skipped = 0; Servers = 0; Taken = 0; Oldest = $null; Newest = $null; Unlisted = @() }
    if (-not (Test-Path -LiteralPath $Folder)) { return $out }
    $files = @(Get-ChildItem -LiteralPath $Folder -Filter '*.xml' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($script:SpokeMode) {
        # a spoke reads only this computer's file: the folder is the hub's share with the whole fleet's files (review 2026-11-08)
        $mine = ([string]$env:COMPUTERNAME).ToLower()
        $files = @($files | Where-Object { (($_.BaseName -split '\.')[0]).ToLower() -eq $mine })
    }
    $anyTaken = $false; $n = 0
    foreach ($f in $files) {
        $n++
        $key = $f.FullName.ToLower()
        if (-not $Force -and $script:StateSeen.ContainsKey($key) -and $script:StateSeen[$key] -eq $f.LastWriteTimeUtc.Ticks) { $out.Skipped++; continue }
        if ($Progress) { try { & $Progress $n $files.Count $f.Name } catch { } }
        $doc = Read-ServerStateFile -Path $f.FullName
        if (-not $doc) { continue }   # not marked as seen: a file that could not be read (being written, a share hiccup) is tried again at the next Reload
        $script:StateSeen[$key] = $f.LastWriteTimeUtc.Ticks
        $out.Files++
        $names = @(Resolve-StateServerNames -Doc $doc)
        if ($names.Count -eq 0) { $names = @([string]$doc.Server); $out.Unlisted += [string]$doc.Server }
        $m = Merge-StateDocument -Doc $doc -Names $names
        if (@($m.Taken).Count -gt 0) {
            $anyTaken = $true; $out.Servers++; $out.Taken += @($m.Taken).Count
            $when = $null; if ($doc.PSObject.Properties['WrittenAt'] -and ($doc.WrittenAt -is [datetime])) { $when = $doc.WrittenAt }
            if ($when) { if ($null -eq $out.Oldest -or $when -lt $out.Oldest) { $out.Oldest = $when }; if ($null -eq $out.Newest -or $when -gt $out.Newest) { $out.Newest = $when } }
            Write-PatchLog ("Saved results of {0} loaded ({1}; written {2} by {3} on {4})" -f ($names -join ', '), (@($m.Taken) -join ', '), $(if ($when) { $when.ToString('yyyy-MM-dd HH:mm') } else { '?' }), [string]$doc.WrittenBy, [string]$doc.WrittenOn) 'INFO'
        }
    }
    if ($anyTaken) {
        Clear-CheckRowCache
        if (Get-Command -Name 'Clear-SecurityRowCache' -ErrorAction SilentlyContinue) { Clear-SecurityRowCache }
        $script:SoftwareRowCache = $null
    }
    if ($out.Unlisted.Count -gt 0) { Write-PatchLog ("{0} results file(s) name a server no group file lists ({1}) - kept, shown once a group names it" -f $out.Unlisted.Count, (@($out.Unlisted | Select-Object -First 8) -join ', ')) 'WARN' }
    return $out
}

function Import-SavedResults {
    # What the window reads at its first open (behind the "Loading last data" box, Show-SavedResultsLoading in
    # 07-Gui.ps1) and at every Reload (Initialize-ToolkitData): the old files pruned once, then Import-ServerStates, and
    # one log line on what came in.  -Progress goes through to Import-ServerStates.  Nothing while KeepResults is off.
    param([scriptblock]$Progress)
    if (-not $script:Config.KeepResults) { return $null }
    if (-not $script:Gui['StateLoaded'] -and -not $script:SpokeMode) { $null = Remove-OldServerStates }   # a spoke never prunes the hub's share
    $loaded = Import-ServerStates -Progress $Progress
    if ($loaded.Files -gt 0) { Write-PatchLog ("Saved results: {0} file(s) read, {1} server(s) and {2} result(s) taken into the window (written {3} to {4})" -f $loaded.Files, $loaded.Servers, $loaded.Taken, $(if ($loaded.Oldest) { $loaded.Oldest.ToString('yyyy-MM-dd HH:mm') } else { '?' }), $(if ($loaded.Newest) { $loaded.Newest.ToString('yyyy-MM-dd HH:mm') } else { '?' })) 'INFO' }
    elseif (-not $script:Gui['StateLoaded'] -and $loaded.Skipped -gt 0) { Write-PatchLog ("Saved results: the {0} file(s) in {1} were read earlier in this session and have not changed" -f $loaded.Skipped, (Get-StateFolder)) 'INFO' }
    elseif (-not $script:Gui['StateLoaded']) { Write-PatchLog ("No saved results yet in {0} - every console starts empty until a check runs" -f (Get-StateFolder)) 'INFO' }
    $script:Gui['StateLoaded'] = $true
    return $loaded
}

function Import-ResultsFile {
    # The Import results button: one or more results files from anywhere (a self-check carried over from a server the
    # hub cannot reach).  Each is laid over the table (the newer result per collector wins) and the server's own file in
    # state\servers\ is rewritten from the result.  Returns one row per file for the pop-up and the log.
    param([Parameter(Mandatory = $true)][string[]]$Path)
    $rows = @()
    foreach ($p in @($Path)) {
        $row = [pscustomobject]@{ File = (Split-Path -Leaf $p); Server = ''; Loaded = ''; Skipped = ''; Note = '' }
        $rows += $row
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { $row.Note = 'file not found'; continue }
        $doc = Read-ServerStateFile -Path $p
        if (-not $doc) { $row.Note = 'not a results file of this toolkit (the log says why)'; continue }
        $names = @(Resolve-StateServerNames -Doc $doc)
        if ($names.Count -eq 0) { $names = @([string]$doc.Server); $row.Note = 'no group file lists this server - kept under its own name; it shows once a group names it' }
        $row.Server = ($names -join ', ')
        $m = Merge-StateDocument -Doc $doc -Names $names
        $row.Loaded = (@($m.Taken) -join ', '); $row.Skipped = (@($m.Skipped) -join ', ')
        if (@($m.Skipped).Count -gt 0 -and -not $row.Note) { $row.Note = 'skipped = what is here is as new or newer' }
        $when = '?'; if ($doc.PSObject.Properties['WrittenAt'] -and ($doc.WrittenAt -is [datetime])) { $when = $doc.WrittenAt.ToString('yyyy-MM-dd HH:mm') }
        Write-PatchLog ("Results file {0} (written {1} by {2} on {3}): {4} -> {5}{6}" -f $row.File, $when, [string]$doc.WrittenBy, [string]$doc.WrittenOn, $row.Server, $(if ($row.Loaded) { 'loaded ' + $row.Loaded } else { 'nothing loaded' }), $(if ($row.Skipped) { '; skipped ' + $row.Skipped } else { '' })) $(if ($row.Loaded) { 'OK' } else { 'WARN' })
        if (@($m.Taken).Count -gt 0) { Set-StateDirty -Server $names }
    }
    if (@($rows | Where-Object { $_.Loaded }).Count -gt 0) {
        Clear-CheckRowCache
        if (Get-Command -Name 'Clear-SecurityRowCache' -ErrorAction SilentlyContinue) { Clear-SecurityRowCache }
        $script:SoftwareRowCache = $null
        $null = Save-DirtyStates -All
    }
    return $rows
}

# ---------------------------------------------------------------------
#  "Last checked": the cell every console shows, coloured by age
# ---------------------------------------------------------------------
function Format-LastChecked {
    # 'yyyy-MM-dd HH:mm', or '' - a result from days ago must not read like one from this morning
    param($Checked)
    if ($Checked -is [datetime]) { return $Checked.ToString('yyyy-MM-dd HH:mm') }
    return ''
}

function Get-ResultAgeText {
    # '12 min', '3 h', '2 d 4 h' - for the tool tip
    param($Checked)
    if (-not ($Checked -is [datetime])) { return '' }
    $span = (Get-Date) - $Checked
    if ($span.TotalMinutes -lt 1) { return 'just now' }
    if ($span.TotalHours -lt 1) { return ('{0} min' -f [int]$span.TotalMinutes) }
    if ($span.TotalDays -lt 1) { return ('{0} h' -f [int]$span.TotalHours) }
    return ('{0} d {1} h' -f [int][math]::Floor($span.TotalDays), $span.Hours)
}

function Get-ResultAgeColour {
    # The cell colour: green up to ResultFreshDays, amber up to ResultStaleDays, red beyond ('' without a date).  The same
    # three colours as the impact cells of the GPO recommendations, so a cell reads the same on every console.
    param($Checked)
    if (-not ($Checked -is [datetime])) { return '' }
    $days = ((Get-Date) - $Checked).TotalDays
    if ($days -le [double]$script:Config.ResultFreshDays) { return 'PaleGreen' }
    if ($days -le [double]$script:Config.ResultStaleDays) { return 'Khaki' }
    return 'LightCoral'
}

function Get-LastCheckedTip {
    # 'checked 2026-11-05 09:12 (3 h ago)', plus the latest failed attempt when there is one, plus where self-check data came from
    param($Result, [string]$Server = '')
    if (-not $Result -or -not $Result.PSObject.Properties['Checked'] -or -not ($Result.Checked -is [datetime])) { return '' }
    $text = 'checked ' + (Format-LastChecked $Result.Checked) + ' (' + (Get-ResultAgeText $Result.Checked) + ' ago)'
    $err = Get-ResultFailure $Result
    if ($err) { $at = ''; if ($Result.PSObject.Properties['LastAttempt'] -and ($Result.LastAttempt -is [datetime])) { $at = ' at ' + (Format-LastChecked $Result.LastAttempt) }; $text += ('; the latest attempt' + $at + ' failed: ' + $err + ' - the data shown is from the check above') }
    if ($Server -and (Test-RemoteDisabled -Name $Server)) { $text += "; marked 'winrm: no' in the group file - the data comes from the server's own self-check (Import results)" }
    return $text
}

function Get-ConsoleCollectors {
    # The collectors a console's rows and checks rely on, beyond what every check button gathers (Status and Inventory come
    # with every button, so they can never be the gap).  A row is complete only when each has a result for the server.
    # Probes is left out (there is no result at all when no SOE standard has a registry or file item); Analysis, Impact and
    # Command are asked for by hand.
    param([string]$Console)
    switch ($Console) {
        'Patching' { return @('Status') }
        'Software' { return @('Status', 'Inventory', 'SoftwareState') }
        'Health'   { return @('Health', 'Agents', 'Settings', 'Gpo') }
        'Security' { return @('Settings', 'SecurityPolicy') }
    }
    return @()
}

function Get-ConsoleCoverage {
    # What a console's row for a server may claim (field finding 2026-11-06: one console's check fills part of another's
    # table - every button collects Status and Inventory, a Health check collects the Settings an audit reads - and a row
    # built from that passed for a finished check).  Complete = every collector of Get-ConsoleCollectors has a result,
    # reachable or a failed attempt ("never asked" is the gap; a refused call shows as such); Missing = the ones never
    # collected; Checked = the OLDEST time among the results present, so a row is never fresher than its weakest input.
    # A row short of one says PARTIAL, is lit grey and counts for nothing on the dashboards; what was collected stays.
    param([string]$Console, [string]$Server)
    $missing = @(); $present = @(); $oldest = $null
    foreach ($n in @(Get-ConsoleCollectors -Console $Console)) {
        $r = Get-CollectorResult -Name $n -Server $Server
        if (-not $r) { $missing += $n; continue }
        $present += $n
        if ($r.PSObject.Properties['Checked'] -and ($r.Checked -is [datetime])) { if ($null -eq $oldest -or $r.Checked -lt $oldest) { $oldest = $r.Checked } }
    }
    return [pscustomobject]@{ Console = $Console; Server = $Server; Complete = ($missing.Count -eq 0); Missing = $missing; Present = $present; Checked = $oldest }
}

function Get-PartialRowText {
    # The words a partial row shows in its status text: what was never collected and the button that collects it
    param($Coverage, [string]$Button)
    return ('PARTIAL: ' + (@($Coverage.Missing) -join ', ') + ' not collected yet - press ' + $Button + '; what another console collected is kept, not judged')
}

# ---------------------------------------------------------------------
#  The self-check: every collector on the computer it runs on, over no network, one results file
# ---------------------------------------------------------------------
function Get-SelfCheckSteps {
    # The collectors a self-check runs, in order, each through the function its console uses (Invoke-Collector runs the
    # script block here as a local job - no WinRM call to itself).  Impact (the GPO recommendations) and a failure analysis
    # are asked for by hand on the hub; a command never runs by itself.
    return @(
        @{ Name = 'Status';         Run = { param($n) Get-ServerStatus -ComputerName $n -NoRetry } }
        @{ Name = 'Inventory';      Run = { param($n) Get-ServerInventory -ComputerName $n } }
        @{ Name = 'SoftwareState';  Run = { param($n) Get-ServerSoftwareState -ComputerName $n } }
        @{ Name = 'Health';         Run = { param($n) Get-ServerHealth -ComputerName $n } }
        @{ Name = 'Agents';         Run = { param($n) Get-ServerAgents -ComputerName $n } }
        @{ Name = 'Settings';       Run = { param($n) Get-ServerSettings -ComputerName $n } }
        @{ Name = 'Probes';         Run = { param($n) Get-ServerProbes -ComputerName $n -Probes @(Get-SoeProbeList) } }
        @{ Name = 'SecurityPolicy'; Run = { param($n) Get-ServerSecurityPolicy -ComputerName $n } }
        @{ Name = 'Gpo';            Run = { param($n) Get-ServerGpo -ComputerName $n } }
        @{ Name = 'Licensing';      Run = { param($n) Get-ServerLicensing -ComputerName $n } }
    )
}

function Invoke-SelfCheck {
    # Start-WinRMToolkit.ps1 -SelfCheck [-ResultsFolder <folder>] [-Only Status,Health]: no window; the server list is this
    # computer; every collector runs here; the one results file is written and the outcome returned (the launcher turns
    # it into the exit code: 0 = every collector answered and the file was written).
    param([string]$ResultsFolder = '', [string[]]$Only = @())
    $name = Get-ThisComputerFqdn
    if ($ResultsFolder) { $script:Config.StateFolder = $ResultsFolder }
    $script:Config.KeepResults = $true
    $script:Groups = @([pscustomobject]@{ Name = 'This computer'; File = ''; Servers = @($name); Class = ''; Soe = ''; Winrm = ''; Attributes = @{} })
    $script:GroupIndex = $null
    Write-PatchLog ("=== SELF-CHECK of {0} by {1}: every collector runs on this computer, over no network; the results file goes to {2} ===" -f $name, (Get-OperatorIdentity), (Get-StateFolder)) 'INFO'
    $steps = @(Get-SelfCheckSteps)
    if (@($Only).Count -gt 0) { $steps = @($steps | Where-Object { @($Only) -contains $_.Name }) }
    $outcome = @()
    foreach ($st in $steps) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = $false; $err = ''
        try {
            $null = & $st.Run $name
            $r = Get-CollectorResult -Name $st.Name -Server $name
            if ($r -and $r.Reachable) { $ok = $true } elseif ($r) { $err = [string]$r.Error } else { $err = 'no result' }
        } catch { $err = Get-ShortError $_ }
        $outcome += [pscustomobject]@{ Collector = $st.Name; Ok = $ok; Error = $err; Seconds = [math]::Round($watch.Elapsed.TotalSeconds, 1) }
        if ($ok) { Write-PatchLog ("Self-check {0}: done in {1} s" -f $st.Name, [math]::Round($watch.Elapsed.TotalSeconds, 1)) 'OK' } else { Write-PatchLog ("Self-check {0}: FAILED - {1}" -f $st.Name, $err) 'ERROR' }
    }
    Set-StateDirty -Server $name
    $null = Save-DirtyStates -All
    $file = Get-StateFilePath -Server $name
    $written = Test-Path -LiteralPath $file
    $failed = @($outcome | Where-Object { -not $_.Ok })
    if ($written) { Write-PatchLog ("Self-check results file written: {0} ({1} KB; {2} of {3} collectors answered)" -f $file, [int]((Get-Item -LiteralPath $file).Length / 1KB), ($outcome.Count - $failed.Count), $outcome.Count) $(if ($failed.Count -eq 0) { 'OK' } else { 'WARN' }) }
    else { Write-PatchLog ("Self-check results file NOT written: {0} (the folder could not be written - see the warning above)" -f $file) 'ERROR' }
    return [pscustomobject]@{ Computer = $name; File = $file; Written = $written; Steps = $outcome; Ok = ($written -and $failed.Count -eq 0) }
}

function New-SelfCheckPackage {
    # Writes Run-SelfCheck.ps1 (a short launcher of the self-check, the results folder baked in) and INSTRUCTIONS.txt (the
    # steps, and a scheduled-task line) for the servers marked "winrm: no" - into state\selfcheck\, or with -Folder into
    # the copy New-ServerCopy makes (then -ScriptOnly: the copy has its own instructions).  The script needs the toolkit
    # folder beside it on the server: the collectors are the toolkit's own, never copied out, so a self-check always
    # matches the hub's version.
    param([string[]]$Servers = @(), [string]$ResultsFolder = '', [string]$Folder = '', [switch]$ScriptOnly)
    if (@($Servers).Count -eq 0) { $Servers = @(Get-RemoteDisabledServers) }
    $pkgFolder = $Folder
    if (-not $pkgFolder) { $pkgFolder = Join-Path $script:RootFolder 'state\selfcheck' }
    if (-not (Test-Path -LiteralPath $pkgFolder)) { New-Item -ItemType Directory -Path $pkgFolder -Force | Out-Null }
    $scriptPath = Join-Path $pkgFolder 'Run-SelfCheck.ps1'
    $notesPath = Join-Path $pkgFolder 'INSTRUCTIONS.txt'
    $when = Get-Date -Format 'yyyy-MM-dd HH:mm'; $who = Get-OperatorIdentity
    $forList = 'any server marked winrm: no'; if (@($Servers).Count -gt 0) { $forList = (@($Servers) -join ', ') }
    $where = $ResultsFolder; if (-not $where) { $where = 'state\servers\ inside the copy of the toolkit on the server' }
    $literal = $ResultsFolder -replace "'", "''"
    $code = @(
        '# =====================================================================',
        '#  Run-SelfCheck.ps1  -  THE SELF-CHECK OF A SERVER THE HUB CANNOT REACH OVER WinRM',
        ('#  {0} {1} - written {2} by {3} on {4}' -f $script:Config.ToolName, $script:Config.ToolVersion, $when, $who, $env:COMPUTERNAME),
        ('#  For: {0}' -f $forList),
        '# ---------------------------------------------------------------------',
        '#  Put this file in the root of a copy of the toolkit folder ON THAT SERVER (next to Start-WinRMToolkit.ps1) and run',
        '#  it there as an administrator:',
        '#      powershell.exe -ExecutionPolicy Bypass -File .\Run-SelfCheck.ps1',
        '#  It runs every check of the toolkit on the computer it is on - status, inventory, software state, health, agents,',
        '#  settings, configuration points, security policy, Group Policy - over no network, and writes ONE results file,',
        '#  <computer name>.xml, into the results folder below.  The hub shows that file in every console after',
        '#  "Import results" (O/S Patching tab), or at its next Reload when the results folder is the hub''s own',
        '#  state\servers share.  INSTRUCTIONS.txt beside this file has the steps and a scheduled-task line.',
        '#  Exit code 0 = every collector answered and the file was written.',
        '# =====================================================================',
        ("param([string]`$ResultsFolder = '{0}')" -f $literal),
        '$launcher = Join-Path $PSScriptRoot ''Start-WinRMToolkit.ps1''',
        'if (-not (Test-Path -LiteralPath $launcher)) { Write-Host "Start-WinRMToolkit.ps1 is not next to this file: copy the toolkit folder (lib\, data\, settings\, soe\, security\) here first" -ForegroundColor Red; exit 2 }',
        '& $launcher -SelfCheck -ResultsFolder $ResultsFolder',
        'exit $LASTEXITCODE'
    )
    $notes = @(
        'AIRGAP WINRM TOOLKIT - SELF-CHECK FOR A SERVER THE HUB CANNOT REACH OVER WinRM',
        ('Written {0} by {1} on {2} for: {3}' -f $when, $who, $env:COMPUTERNAME, $forList),
        '',
        'These servers are marked "winrm: no" in their group file: the hub never calls them over WinRM. Each of them checks',
        'itself with Run-SelfCheck.ps1 and hands the hub one results file, <computer name>.xml, which every console shows',
        'with the date and time of the check in its Last checked cell.',
        '',
        '1. Copy the toolkit folder to the server: lib\, data\, settings\, soe\ and security\ at least (patches\ and',
        '   software\ are not needed for a check; copy them too, or point at the hub''s share, when the server is to be',
        '   patched from that copy with Start-WinRMToolkit.ps1 -Spoke).',
        '2. Put Run-SelfCheck.ps1 (this folder) in the root of that copy, next to Start-WinRMToolkit.ps1.',
        '3. On the server, as an administrator:',
        '       powershell.exe -ExecutionPolicy Bypass -File .\Run-SelfCheck.ps1',
        '   Where application control or an AllSigned policy runs signed scripts only, sign the copy''s scripts with',
        '   Sign-Toolkit.ps1 first (README, Code signing); Run-SelfCheck.ps1 is written by the hub and carries no signature.',
        ('4. The run writes <computer name>.xml into the results folder: {0}' -f $where),
        '   The copy''s logs\Patcher-<date>.log says what each collector found. Exit code 0 = every collector answered.',
        '5. Bring the file to the hub: "Import results" on the O/S Patching tab takes one or more files. When the results',
        '   folder is the hub''s own state\servers share (give its path as -ResultsFolder, or set it in the first line of',
        '   Run-SelfCheck.ps1), the hub picks the file up at its next Reload instead.',
        '',
        'Every night, as a scheduled task (registered on the server by an administrator; the task runs as SYSTEM, so a',
        'results folder on a share must let the computer account write to it):',
        '    schtasks /Create /TN "Airgap WinRM Toolkit self-check" /SC DAILY /ST 06:00 /RU SYSTEM /RL HIGHEST /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"<copy>\Run-SelfCheck.ps1\""',
        '(replace <copy> with the folder the toolkit was copied to)',
        '',
        'The results file holds host names, account names (failed logons, local administrators) and findings: treat it as',
        'internal, like a report.'
    )
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($scriptPath, (($code -join "`r`n") + "`r`n"), $enc)
    if ($ScriptOnly) { $notesPath = '' } else { [System.IO.File]::WriteAllText($notesPath, (($notes -join "`r`n") + "`r`n"), $enc) }
    Write-PatchLog ("Self-check script written: {0}{1} for {2} (results folder: {3})" -f $scriptPath, $(if ($ScriptOnly) { '' } else { ' and INSTRUCTIONS.txt' }), $forList, $where) 'OK'
    return [pscustomobject]@{ Folder = $pkgFolder; Script = $scriptPath; Instructions = $notesPath; Servers = @($Servers); ResultsFolder = $ResultsFolder }
}

function Get-ToolkitUncPath {
    # A folder of this PC as the servers see it: \\<this computer's FQDN>\<drive>$\<rest>, through the administrative
    # share (D:\Toolkit\state\servers -> \\hub.corp.local\d$\Toolkit\state\servers).  A UNC path, or no path, comes back
    # as it is.  The default answer of the Copy for a server dialog; the operator changes it to a share of their own.
    param([string]$Path)
    $p = [string]$Path
    if (-not $p -or $p.StartsWith('\\')) { return $p }
    if ($p -match '^([A-Za-z]):\\?(.*)$') { return ('\\{0}\{1}$\{2}' -f (Get-ThisComputerFqdn), $Matches[1].ToLower(), $Matches[2]) }
    return $p
}

function Get-ServerCopyItems {
    # What a copy for a server carries, as paths under the root folder: the scripts, the catalogues, the SOE and security
    # standards, the pictures of the Code Tour, the manuals and licence - never the patches, the installers, the group
    # files (host names), the results, logs, reports, change records or signing requests: the copy makes its own, and
    # the server reads patches\ and software\ from the hub folder.  This toolkit's settings file goes in separately.
    return @{
        Files   = @('Start-WinRMToolkit.ps1', 'Sign-Toolkit.ps1', 'README.txt', 'README.md', 'LICENSE', 'COMMERCIAL.md', 'SECURITY.md', 'CHANGELOG.md', 'settings\README.txt')
        Folders = @('lib', 'data', 'soe', 'security', 'images')
    }
}

function Get-ServerCopiesFolder { return (Join-Path $script:RootFolder 'state\server-copies') }

function Get-ServerCopyFolderName {
    # The folder a copy for one server lives in: <server as typed, lower case, file-safe>-local-winrm (owner's naming,
    # 2026-11-06); "server-local-winrm" when no server is named
    param([string]$Server)
    $leaf = (([string]$Server).Trim().ToLower() -replace '[^a-z0-9\.\-_]', '_')
    if (-not $leaf) { $leaf = 'server' }
    return ($leaf + '-local-winrm')
}

function New-ServerCopies {
    # The "Copy for a server" button: one copy per server marked "winrm: no" (or per name in -Servers), each in its own
    # folder <server>-local-winrm under state\server-copies\ (or -Parent), each with its own INSTRUCTIONS.txt and, when
    # asked, its own Run-SelfCheck.ps1.  No server named: one copy, server-local-winrm.  Returns @{ Folder (the parent);
    # Copies (one New-ServerCopy result each) }.
    param([string[]]$Servers = @(), [string]$HubFolder = '', [string]$ResultsFolder = '', [switch]$IncludeSelfCheck, [string]$Parent = '')
    if (@($Servers).Count -eq 0) { $Servers = @(Get-RemoteDisabledServers) }
    if (-not $Parent) { $Parent = Get-ServerCopiesFolder }
    $copies = @()
    if (@($Servers).Count -eq 0) {
        $copies += New-ServerCopy -Folder (Join-Path $Parent (Get-ServerCopyFolderName -Server '')) -HubFolder $HubFolder -ResultsFolder $ResultsFolder -IncludeSelfCheck:$IncludeSelfCheck
    } else {
        foreach ($s in @(Get-UniqueNames @($Servers))) {
            $copies += New-ServerCopy -Folder (Join-Path $Parent (Get-ServerCopyFolderName -Server $s)) -HubFolder $HubFolder -ResultsFolder $ResultsFolder -IncludeSelfCheck:$IncludeSelfCheck -Servers @($s)
        }
    }
    return @{ Folder = $Parent; Copies = $copies }
}

function New-ServerCopy {
    # The "Copy for a server" button: a ready-to-carry copy of this toolkit for a server marked "winrm: no", made afresh in
    # state\server-copies\<server>-local-winrm\ (or -Folder): the items of Get-ServerCopyItems, this toolkit's settings file, settings\spoke.json
    # filled in with the hub folder and the results folder as the server sees them (so Start-WinRMToolkit.ps1 -Spoke on
    # the server offers them), INSTRUCTIONS.txt, and with -IncludeSelfCheck Run-SelfCheck.ps1 for a scheduled check.
    # Returns Folder, Files, Bytes, Script ('' without the self-check), Instructions, HubFolder, ResultsFolder, Servers.
    param([string]$Folder = '', [string]$HubFolder = '', [string]$ResultsFolder = '', [switch]$IncludeSelfCheck, [string[]]$Servers = @())
    if (@($Servers).Count -eq 0) { $Servers = @(Get-RemoteDisabledServers) }
    if (-not $Folder) { $Folder = Join-Path (Get-ServerCopiesFolder) (Get-ServerCopyFolderName -Server $(if (@($Servers).Count -gt 0) { [string]$Servers[0] } else { '' })) }
    if (-not $HubFolder) { $HubFolder = Get-ToolkitUncPath -Path $script:RootFolder }
    if (Test-Path -LiteralPath $Folder) { Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $Folder -Force | Out-Null
    $items = Get-ServerCopyItems
    $root = [string]$script:RootFolder
    $relatives = New-Object System.Collections.Generic.List[string]
    foreach ($f in $items.Files) { if (Test-Path -LiteralPath (Join-Path $root $f) -PathType Leaf) { $relatives.Add($f) } }
    foreach ($d in $items.Folders) {
        $top = Join-Path $root $d
        if (-not (Test-Path -LiteralPath $top -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $top -Recurse -File -Force | Where-Object { $_.Name -notlike '*.part' -and $_.Name -ne 'Thumbs.db' -and $_.Name -ne 'desktop.ini' })) {
            $relatives.Add($f.FullName.Substring($root.Length).TrimStart('\'))
        }
    }
    $count = 0; $bytes = [long]0
    foreach ($rel in $relatives) {
        $src = Join-Path $root $rel; $dst = Join-Path $Folder $rel
        $dir = Split-Path -Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Copy-Item -LiteralPath $src -Destination $dst -Force
        $count++; $bytes += (Get-Item -LiteralPath $src).Length
    }
    # this toolkit's settings (products, change system, rules, thresholds) go with the copy; the spoke's folders are filled in
    $settingsDir = Join-Path $Folder 'settings'
    if (-not (Test-Path -LiteralPath $settingsDir)) { New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null }
    $live = [string]$script:Config.SettingsFile
    if ($live -and (Test-Path -LiteralPath $live -PathType Leaf)) { Copy-Item -LiteralPath $live -Destination (Join-Path $settingsDir 'settings.json') -Force; $count++; $bytes += (Get-Item -LiteralPath $live).Length }
    Save-SpokeSettings -HubFolder $HubFolder -ResultsFolder $ResultsFolder -Path (Join-Path $settingsDir 'spoke.json') -ServerCopy; $count++   # marked: the copy starts as the spoke by itself
    $scriptPath = ''
    if ($IncludeSelfCheck) { $pkg = New-SelfCheckPackage -Servers $Servers -ResultsFolder $ResultsFolder -Folder $Folder -ScriptOnly; $scriptPath = $pkg.Script; $count++ }
    $when = Get-Date -Format 'yyyy-MM-dd HH:mm'; $who = Get-OperatorIdentity
    $forList = 'a server marked winrm: no'; if (@($Servers).Count -gt 0) { $forList = (@($Servers) -join ', ') }
    $resultsText = $ResultsFolder; if (-not $resultsText) { $resultsText = "(empty: this copy's own state\servers\ - carry the file back to the hub, Import results)" }
    $notes = @(
        'AIRGAP WINRM TOOLKIT - A COPY FOR A SERVER THE HUB CANNOT REACH OVER WinRM',
        ('{0} {1} - written {2} by {3} on {4} for: {5}' -f $script:Config.ToolName, $script:Config.ToolVersion, $when, $who, $env:COMPUTERNAME, $forList),
        '',
        'This folder is the toolkit without its patches, installers, server lists and results. Carry the WHOLE folder to the',
        'server (a USB stick, a drive mapped into the RDP session, a share the server can read) and keep it together on a',
        'local disk there. Run it as an administrator of that server. Nothing in it calls any other server.',
        '',
        '1. THE WINDOW - check and patch this server from its own console:',
        '       powershell.exe -ExecutionPolicy Bypass -File .\Start-WinRMToolkit.ps1',
        '   This copy knows what it is (settings\spoke.json) and starts as the spoke by itself: a plain start, or',
        '   right-click Start-WinRMToolkit.ps1 > Run with PowerShell, is enough (-Spoke is implied).',
        '   The start asks for two folders and offers these answers (settings\spoke.json):',
        ('       Hub folder (patches\ and software\ are read from here):   {0}' -f $HubFolder),
        ('       Results folder (this server''s results file goes here):    {0}' -f $resultsText),
        '   The account running the copy must read the hub folder and write to the results folder. Where the server cannot',
        '   reach the hub''s folder, copy the hub''s patches\ and software\ into this folder and give this folder as the hub',
        '   folder; give an empty results folder to keep the results file in this copy''s state\servers\ and carry it back.',
        '',
        '2. THE SELF-CHECK - every check without a window, one results file, for a scheduled task:'
    )
    if ($scriptPath) {
        $notes += @(
            '       powershell.exe -ExecutionPolicy Bypass -File .\Run-SelfCheck.ps1',
            '   Exit code 0 = every collector answered and the file was written. Every night (registered on the server by an',
            '   administrator; the task runs as SYSTEM, so a results folder on a share must let the computer account write to it):',
            '    schtasks /Create /TN "Airgap WinRM Toolkit self-check" /SC DAILY /ST 06:00 /RU SYSTEM /RL HIGHEST /F /TR "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"<copy>\Run-SelfCheck.ps1\""',
            '   (replace <copy> with the folder this copy was put in)'
        )
    } else {
        $notes += @('   Run-SelfCheck.ps1 is not in this copy: on the hub, press Copy for a server with "Include the self-check script" ticked.')
    }
    $notes += @(
        '',
        '3. SIGNED SCRIPTS: the scripts carry the hub''s signatures. Where application control or an AllSigned policy runs',
        '   signed scripts only and this server does not trust that certificate, sign them here with Sign-Toolkit.ps1',
        '   (README.txt, step 4); Run-SelfCheck.ps1 is written by the hub and carries no signature.',
        '',
        '4. WHAT COMES BACK: the results file <computer name>.xml in the results folder shows in every console of the hub -',
        '   at its next Reload when the folder is the hub''s own state\servers share, or through Import results when the file',
        '   is carried by hand. Logs, reports and the change log stay in this copy: bring changes\change-log.csv back when',
        '   the site keeps one record.',
        '',
        'The results file holds host names, account names (failed logons, local administrators) and findings: treat it as',
        'internal, like a report.'
    )
    $notesPath = Join-Path $Folder 'INSTRUCTIONS.txt'
    [System.IO.File]::WriteAllText($notesPath, (($notes -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding $false)); $count++
    Write-PatchLog ("Copy for a server written: {0} ({1} files, {2:n1} MB) for {3}; hub folder {4}, results folder {5}{6}" -f $Folder, $count, ($bytes / 1MB), $forList, $HubFolder, $(if ($ResultsFolder) { $ResultsFolder } else { "the copy's own state\servers" }), $(if ($scriptPath) { '; Run-SelfCheck.ps1 included' } else { '' })) 'OK'
    return [pscustomobject]@{ Folder = $Folder; Files = $count; Bytes = $bytes; Script = $scriptPath; Instructions = $notesPath; HubFolder = $HubFolder; ResultsFolder = $ResultsFolder; Servers = @($Servers) }
}

# ---------------------------------------------------------------------
#  The spoke: the window on a server the hub cannot reach, working on the computer it runs on
# ---------------------------------------------------------------------
function Get-SpokeSettingsPath { return (Join-Path (Split-Path -Path $script:Config.SettingsFile -Parent) 'spoke.json') }

function Read-SpokeSettings {
    # settings\spoke.json (or -Path): the hub folder and the results folder this spoke was given last time ('' when none yet),
    # and ServerCopy - this folder was written by "Copy for a server" on the hub, so it starts as the spoke by itself
    param([string]$Path = '')
    $out = @{ HubFolder = ''; ResultsFolder = ''; ServerCopy = $false }
    $p = $Path; if (-not $p) { $p = Get-SpokeSettingsPath }
    if (-not (Test-Path -LiteralPath $p)) { return $out }
    try {
        $doc = [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
        if ($doc.PSObject.Properties['HubFolder']) { $out.HubFolder = [string]$doc.HubFolder }
        if ($doc.PSObject.Properties['ResultsFolder']) { $out.ResultsFolder = [string]$doc.ResultsFolder }
        if ($doc.PSObject.Properties['ServerCopy']) { $out.ServerCopy = [bool]$doc.ServerCopy }
    } catch { Write-PatchLog ("settings\spoke.json unreadable ({0}) - asking again" -f (Get-ShortError $_)) 'WARN' }
    return $out
}

function Save-SpokeSettings {
    # settings\spoke.json of this copy, or -Path: the one New-ServerCopy fills in for the server.  -ServerCopy marks the file
    # as a copy for a server (the launcher then starts as the spoke by itself; a spoke start passes the mark on).
    param([string]$HubFolder, [string]$ResultsFolder, [string]$Path = '', [switch]$ServerCopy)
    $p = $Path; if (-not $p) { $p = Get-SpokeSettingsPath }
    $dir = Split-Path -Path $p -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc = [ordered]@{ Note = 'Written by Start-WinRMToolkit.ps1 -Spoke: where this copy finds the hub''s patches and software, and where it writes its results file. Asked again at every spoke start, with these as the answers offered.'; HubFolder = $HubFolder; ResultsFolder = $ResultsFolder; SavedBy = (Get-OperatorIdentity); SavedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }
    if ($ServerCopy) { $doc['ServerCopy'] = $true; $doc['CopyWrittenOn'] = $env:COMPUTERNAME; $doc['CopyNote'] = 'This folder was written by "Copy for a server" on the hub: Start-WinRMToolkit.ps1 starts as the spoke by itself here.' }
    [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $doc -Depth 3), (New-Object System.Text.UTF8Encoding $false))
}

function Test-ServerCopyFolder {
    # Is this folder a copy for a server (written by "Copy for a server" on the hub)?  settings\spoke.json says so; the
    # launcher then starts as the spoke without being told - a double-click is enough on the server (field finding
    # 2026-11-06: the copy started as a hub, with no servers and an empty patches folder).
    return [bool](Read-SpokeSettings).ServerCopy
}

function Test-HubFolder {
    # '' when the folder is a toolkit folder with patches\ in it, else the reason
    param([string]$Path)
    if (-not $Path) { return 'no hub folder given' }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return ("cannot find the hub folder {0}" -f $Path) }
    if (-not (Test-Path -LiteralPath (Join-Path $Path 'patches') -PathType Container)) { return ("{0} has no patches\ folder - give the toolkit folder of the hub (a share or a copy), the one that holds patches\ and software\" -f $Path) }
    return ''
}

function Test-ResultsFolder {
    # '' when the folder exists (or could be made) and takes a file, else the reason
    param([string]$Path)
    if (-not $Path) { return '' }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null }
        $probe = Join-Path $Path ('.write-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force -ErrorAction Stop
    } catch { return ("the results folder {0} cannot be written: {1}" -f $Path, (Get-ShortError $_)) }
    return ''
}

function Set-SpokeFolders {
    # The hub's patches\ and software\ in place of this copy's own; the results file where the hub reads it.  The hub's
    # vetting caches (patches\_info, software\_info) are read and trusted - the same file by size and time - and never
    # written: what this copy vets itself goes under its own root (Get-PatchInfoCacheFolders, Get-SoftwareVettingCacheWritePath).
    # The logs, reports and change log stay here.
    param([string]$HubFolder, [string]$ResultsFolder = '')
    $script:Config.PatchFolder = Join-Path $HubFolder 'patches'
    $script:Config.SoftwareFolder = Join-Path $HubFolder 'software'
    if ($ResultsFolder) { $script:Config.StateFolder = $ResultsFolder }
    $script:SpokeHubFolder = $HubFolder; $script:SpokeResultsFolder = $ResultsFolder
    Write-PatchLog ("Spoke on {0}: patches from {1}, software from {2}, the results file to {3}; logs, reports and the change log stay in {4}" -f (Get-ThisComputerFqdn), $script:Config.PatchFolder, $script:Config.SoftwareFolder, (Get-StateFolder), $script:RootFolder) 'INFO'
}

function Show-SpokeSetupDialog {
    # Asked at every spoke start (the saved answers offered): the hub folder and the results folder.  @{ HubFolder;
    # ResultsFolder } on OK, $null on Cancel.  OK is refused with the reason while a folder does not fit.  The rows are
    # placed from the labels' measured heights (display scaling), the texts kept short (owner's ask, 2026-11-06).
    param([string]$HubFolder = '', [string]$ResultsFolder = '')
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $d = New-ToolkitDialogForm
    $d.Text = ('Spoke on {0}' -f (Get-ThisComputerFqdn))
    $d.ClientSize = New-Object System.Drawing.Size(750, 300); $d.FormBorderStyle = 'FixedDialog'; $d.StartPosition = 'CenterScreen'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $d.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $wide = New-Object System.Drawing.Size(726, 0)   # an AutoSize label wraps at this width and measures its own height
    $intro = New-Object System.Windows.Forms.Label; $intro.AutoSize = $true; $intro.MaximumSize = $wide
    $intro.Text = 'This copy checks and patches this computer only, from the hub''s folders. Nothing goes to any other server.'
    $l1 = New-Object System.Windows.Forms.Label; $l1.AutoSize = $true; $l1.MaximumSize = $wide; $l1.Text = 'Hub folder (holds patches\ and software\):'
    $hubBox = New-Object System.Windows.Forms.TextBox; $hubBox.Size = New-Object System.Drawing.Size(620, 24); $hubBox.Text = $HubFolder; $hubBox.Name = 'HubBox'
    $b1 = New-Object System.Windows.Forms.Button; $b1.Text = 'Browse...'; $b1.Size = New-Object System.Drawing.Size(95, 27)
    $b1.Add_Click({ $fb = New-Object System.Windows.Forms.FolderBrowserDialog; $fb.Description = 'The toolkit folder of the hub (holds patches\ and software\)'; $fb.ShowNewFolderButton = $false; if ($fb.ShowDialog($this.FindForm()) -eq 'OK') { $this.FindForm().Controls['HubBox'].Text = $fb.SelectedPath } })
    $l2 = New-Object System.Windows.Forms.Label; $l2.AutoSize = $true; $l2.MaximumSize = $wide; $l2.Text = 'Results folder (this computer''s results file; empty = this copy''s own state\servers):'
    $resBox = New-Object System.Windows.Forms.TextBox; $resBox.Size = New-Object System.Drawing.Size(620, 24); $resBox.Text = $ResultsFolder; $resBox.Name = 'ResultsBox'
    $b2 = New-Object System.Windows.Forms.Button; $b2.Text = 'Browse...'; $b2.Size = New-Object System.Drawing.Size(95, 27)
    $b2.Add_Click({ $fb = New-Object System.Windows.Forms.FolderBrowserDialog; $fb.Description = 'The folder the results file is written to'; if ($fb.ShowDialog($this.FindForm()) -eq 'OK') { $this.FindForm().Controls['ResultsBox'].Text = $fb.SelectedPath } })
    $note = New-Object System.Windows.Forms.Label; $note.AutoSize = $true; $note.MaximumSize = $wide; $note.ForeColor = 'DimGray'
    $note.Text = 'Kept in settings\spoke.json and offered again next time. Logs, reports and the change log stay in this copy.'
    $d.Controls.AddRange([System.Windows.Forms.Control[]]@($intro, $l1, $hubBox, $b1, $l2, $resBox, $b2, $note))
    # top to bottom from the measured heights, then the dialog takes the height it needs plus the button bar
    $y = 12
    $intro.Location = New-Object System.Drawing.Point(12, $y); $y = $intro.Bottom + 12
    $l1.Location = New-Object System.Drawing.Point(12, $y); $y = $l1.Bottom + 4
    $hubBox.Location = New-Object System.Drawing.Point(12, $y); $b1.Location = New-Object System.Drawing.Point(640, ($y - 2)); $y = $hubBox.Bottom + 12
    $l2.Location = New-Object System.Drawing.Point(12, $y); $y = $l2.Bottom + 4
    $resBox.Location = New-Object System.Drawing.Point(12, $y); $b2.Location = New-Object System.Drawing.Point(640, ($y - 2)); $y = $resBox.Bottom + 12
    $note.Location = New-Object System.Drawing.Point(12, $y); $y = $note.Bottom + 12
    $d.ClientSize = New-Object System.Drawing.Size(750, ($y + 44))
    $bar = New-DialogButtonBar -Dialog $d -Buttons @(@{ Text = 'OK'; Result = 'OK' }, @{ Text = 'Cancel'; Result = 'Cancel' })
    $d.AcceptButton = $bar.Buttons[0]; $d.CancelButton = $bar.Buttons[1]
    # OK only with folders that fit: the reason in a pop-up, the dialog stays open
    $d.Add_FormClosing({
        if ($this.DialogResult -ne 'OK') { return }
        $why = Test-HubFolder -Path $this.Controls['HubBox'].Text.Trim()
        if (-not $why) { $why = Test-ResultsFolder -Path $this.Controls['ResultsBox'].Text.Trim() }
        if ($why) { [void][System.Windows.Forms.MessageBox]::Show($this, $why, $script:Config.ToolName, 'OK', 'Warning'); $_.Cancel = $true }
    })
    $answer = $d.ShowDialog()
    $hub = $hubBox.Text.Trim(); $res = $resBox.Text.Trim()
    $d.Dispose()
    if ($answer -ne 'OK') { return $null }
    return @{ HubFolder = $hub; ResultsFolder = $res }
}

function Initialize-SpokeMode {
    # Start-WinRMToolkit.ps1 -Spoke: this computer is the only server; the hub folder and the results folder come from the
    # command line, else the dialog (with the saved answers offered), else - without a prompt - settings\spoke.json alone.
    # $false when the operator cancelled.
    param([string]$HubFolder = '', [string]$ResultsFolder = '', [switch]$NoPrompt)
    $script:SpokeMode = $true
    $saved = Read-SpokeSettings
    if (-not $HubFolder) { $HubFolder = $saved.HubFolder }
    if (-not $PSBoundParameters.ContainsKey('ResultsFolder')) { $ResultsFolder = $saved.ResultsFolder }
    if (-not $NoPrompt) {
        $answer = Show-SpokeSetupDialog -HubFolder $HubFolder -ResultsFolder $ResultsFolder
        if (-not $answer) { Write-PatchLog 'Spoke start cancelled at the folder dialog' 'WARN'; return $false }
        $HubFolder = $answer.HubFolder; $ResultsFolder = $answer.ResultsFolder
    }
    $why = Test-HubFolder -Path $HubFolder
    if (-not $why) { $why = Test-ResultsFolder -Path $ResultsFolder }
    if ($why) { throw ("Spoke: {0}" -f $why) }
    Save-SpokeSettings -HubFolder $HubFolder -ResultsFolder $ResultsFolder -ServerCopy:$saved.ServerCopy   # the copy's mark stays
    Set-SpokeFolders -HubFolder $HubFolder -ResultsFolder $ResultsFolder
    return $true
}
