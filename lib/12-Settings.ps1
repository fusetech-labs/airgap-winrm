# =====================================================================
#  12-Settings.ps1  -  THE SETTINGS THE OPERATOR CHANGES IN THE WINDOW
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  lib\01-Config.ps1 holds the defaults.  The Settings tab
#  (60-Console-Settings.ps1) saves what the operator changes in
#  settings\settings.json, and at start-up Import-ToolkitSettings lays
#  those values over the defaults.
#    - Only the keys in $script:SettingSpecs can be set this way, and each
#      value is checked against its spec first (type, range, plain ASCII).
#      A value that does not fit - a hand edit gone wrong - is skipped with
#      a warning in the log and the default stays.
#    - The file holds only what differs from the defaults, so a default
#      changed in a later version still reaches every value not set here.
#    - Every save is written to the log, value by value, with who saved it.
#  settings\*.json is git-ignored: it describes YOUR environment.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  12-Settings.ps1
#  New 2026-10-21.  Nothing here talks to a server.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# Every setting the Settings tab offers, in the order it shows them.  Type: bool, int (Min..Max), text (MaxLen),
# list (texts), fields (ChangeRequiredFields), policy (ChangePolicy), checks (SafetyChecks).  Section = its box.
$script:SettingSpecs = @(
    @{ Key = 'SafetyChecks';         Section = 'Checks'; Type = 'checks'; Label = 'Pre-action confirmations' }
    @{ Key = 'ChangeSystem';         Section = 'Change'; Type = 'text'; MaxLen = 60; Label = 'Change management system' }
    @{ Key = 'ChangeSystems';        Section = 'Change'; Type = 'list'; MaxLen = 60; Label = 'Systems offered in the change record form' }
    @{ Key = 'ChangeRequiredFields'; Section = 'Change'; Type = 'fields'; Label = 'Must be filled in' }
    @{ Key = 'ChangePolicy';         Section = 'Change'; Type = 'policy'; Label = 'Recording per action' }
    @{ Key = 'LogShowCmd';           Section = 'Log'; Type = 'bool'; Label = 'Show the command lines (CMD) in the running log' }
    @{ Key = 'LogShowWhy';           Section = 'Log'; Type = 'bool'; Label = 'Show the reasoning lines (WHY) in the running log' }
    @{ Key = 'MaxLogBoxChars';       Section = 'Log'; Type = 'int'; Min = 100000; Max = 20000000; Label = 'The running log keeps about this many characters' }
    @{ Key = 'LogKeepDays';          Section = 'Log'; Type = 'int'; Min = 0; Max = 3650; Label = 'Delete log files older than (days, 0 = keep all)'; Tip = 'The tool''s own Patcher-yyyymmdd.log files last written longer ago than this are deleted when the settings are saved and at every start. Nothing else in the logs folder is touched.' }
    @{ Key = 'KeepResults';          Section = 'Results'; Type = 'bool'; Label = 'Keep every check result in state\ and show it at the next start'; Tip = 'Ticked (the default): the last result of every collector is written to state\servers\<server>.xml after each check and loaded at the next start, so every console shows what it knew and the Last checked cell says how old that is. Unticked: nothing is written and the window starts empty. The files hold host names, account names and findings - the folder is git-ignored and is for the operators only.' }
    @{ Key = 'ResultFreshDays';      Section = 'Results'; Type = 'int'; Min = 1; Max = 365; Label = 'Last checked is green up to (days)'; Tip = 'The Last checked cell of every console: green while the result is at most this many days old.' }
    @{ Key = 'ResultStaleDays';      Section = 'Results'; Type = 'int'; Min = 1; Max = 3650; Label = 'Last checked is amber up to (days), red beyond'; Tip = 'Older than the green limit and at most this many days: amber. Older still: red. A check that failed keeps the last good result and its age; the WinRM cell (or the Worst / Top red text) says the latest attempt failed.' }
    @{ Key = 'ResultsKeepDays';      Section = 'Results'; Type = 'int'; Min = 0; Max = 3650; Label = 'Delete saved results not written for (days, 0 = keep all)'; Tip = 'A results file in state\servers\ that no check or import has written for this many days is deleted at start-up: a server taken out of the lists does not stay on disk for ever.' }
    @{ Key = 'MinFreeGB';            Section = 'Safety'; Type = 'int'; Min = 1; Max = 500; Label = 'Refuse an install when C: has less free than (GB)' }
    @{ Key = 'WarnFreeGB';           Section = 'Safety'; Type = 'int'; Min = 1; Max = 1000; Label = 'Warning colour when C: has less free than (GB)' }
    @{ Key = 'InstallTimeoutMin';    Section = 'Safety'; Type = 'int'; Min = 10; Max = 1440; Label = 'Stop watching an OS patch install after (min)'; Tip = 'The install carries on as a task on the server after that; a status check records the result.' }
    @{ Key = 'AutoCheckInstalls';    Section = 'Safety'; Type = 'bool'; Label = 'Auto-check status after PATCH IT! (the box starts ticked)'; Tip = 'The Auto-check box above PATCH IT! starts ticked: the tool keeps asking the installing servers until they finish. Untick it on the tab to come back later; tick it again to watch again.' }
    @{ Key = 'SoftwareTimeoutMin';   Section = 'Software'; Type = 'int'; Min = 5; Max = 1440; Label = 'Report a software install UNKNOWN after (min)' }
    @{ Key = 'MaxSoftwareColumns';   Section = 'Software'; Type = 'int'; Min = 1; Max = 20; Label = 'Packages shown at once (columns, installer list)' }
    @{ Key = 'CommandTimeoutSec';    Section = 'Commands'; Type = 'int'; Min = 10; Max = 3600; Label = 'Stop a command still running after (seconds)' }
    @{ Key = 'CommandMaxOutputKB';   Section = 'Commands'; Type = 'int'; Min = 16; Max = 4096; Label = 'Keep at most this much of each answer (KB)' }
    @{ Key = 'CommandAskSafety';     Section = 'Commands'; Type = 'bool'; Label = 'A command that may change: the pre-action confirmations too' }
    @{ Key = 'TreatPendingFileRenameAsReboot'; Section = 'Safety'; Type = 'bool'; Label = 'Count PendingFileRenameOperations alone as a pending reboot' }
    @{ Key = 'CleanupStaging';       Section = 'Safety'; Type = 'bool'; Label = 'Delete the copied file on the server after a successful install' }
    @{ Key = 'RequireSolidcoreUpdateMode'; Section = 'Safety'; Type = 'bool'; Label = 'Block OS patch installs and reboots while Trellix Solidcore is enforcing'; Tip = 'Trellix Solidcore must say Update (or Disabled) now and on reboot, else every KB shows Blocked: Solidcore and the Reboot button asks separately. Software installs do not read the Solidcore mode.' }
    @{ Key = 'OnePatchPerRun';       Section = 'Safety'; Type = 'bool'; Label = 'One patch per server per run - the next one waits for the reboot' }
    @{ Key = 'SilentServerSec';      Section = 'Safety'; Type = 'int'; Min = 30; Max = 1800; Label = 'Give up on a server that has not answered a check after (seconds)'; Tip = 'Every read-only check (status, health, security, inventory ...): a server that has not answered this long after its turn began is shown as unreachable with that reason, and the other servers carry on. A down or wedged server, or one the account gets no answer from, no longer holds the whole check. A check with a time limit of its own (Impact, Analysis, a command at its own setting) gives each server that long instead. Never applied to an install or to a command that may change a server.' }
    @{ Key = 'TrellixInUse';         Section = 'Safety'; Type = 'bool'; Label = 'Trellix is used here (its columns, buttons and checks)'; Tip = 'Ticked (the default): the Solidcore and Trellix Agent columns, the "Stop the Trellix Agent services first" boxes, the Start / Stop Trellix Agent buttons, the agent warnings and the Trellix pre-action confirmation. Unticked, for a site without Trellix: all of those go, at once. The Solidcore guard stays - it acts only where Solidcore is found on a server.' }
    @{ Key = 'StopTrellixAgentForInstall'; Section = 'Safety'; Type = 'bool'; Label = 'Stop the Trellix Agent services before an install'; Tip = 'The box "Stop the Trellix Agent services first" on the O/S Patching and Software tabs starts unticked; ticked, masvc and macmnsvc are set to Disabled and stopped before PATCH IT! and INSTALL / UPDATE. Tick it where the agent blocks installs.' }
    @{ Key = 'OperatorName';         Section = 'Safety'; Type = 'text'; MaxLen = 30; Required = $true; Label = 'Operator name (window title and banner, from the next start)' }
    @{ Key = 'DiskWarnPercent';      Section = 'Health'; Type = 'int'; Min = 1; Max = 90; Label = 'Disk: Warn below this % free' }
    @{ Key = 'DiskFailGB';           Section = 'Health'; Type = 'int'; Min = 1; Max = 500; Label = 'Disk: Fail below this many GB free (and below the Warn %)'; Tip = 'Critical needs both limits crossed: under this many GB free and under the Warn percentage. A small volume is judged by its percentage (a 4 GB volume can never hold 5 GB free); a large one is not critical while it still holds the GB.' }
    @{ Key = 'DiskSmallVolumeGB';    Section = 'Health'; Type = 'int'; Min = 0; Max = 100; Label = 'Disk: a volume smaller than this is listed, not judged (GB)'; Tip = 'A recovery or system partition that was given a drive letter is a fixed volume too; under this size it is listed in the evidence and never sets the verdict or moves the disk dial. 0 = judge every volume.' }
    @{ Key = 'MemoryWarnPercent';    Section = 'Health'; Type = 'int'; Min = 1; Max = 90; Label = 'Memory: Warn below this % free' }
    @{ Key = 'MemoryFailPercent';    Section = 'Health'; Type = 'int'; Min = 1; Max = 90; Label = 'Memory: Fail below this % free' }
    @{ Key = 'CpuWarnPercent';       Section = 'Health'; Type = 'int'; Min = 1; Max = 100; Label = 'Processor: Warn at or above this % busy' }
    @{ Key = 'CpuFailPercent';       Section = 'Health'; Type = 'int'; Min = 1; Max = 100; Label = 'Processor: Fail at or above this % busy' }
    @{ Key = 'CpuSampleSeconds';     Section = 'Health'; Type = 'int'; Min = 1; Max = 30; Label = 'Processor: sample the load for (seconds)' }
    @{ Key = 'UptimeWarnDays';       Section = 'Health'; Type = 'int'; Min = 1; Max = 3650; Label = 'Uptime: Warn after this many days' }
    @{ Key = 'EventErrorWarn';       Section = 'Health'; Type = 'int'; Min = 1; Max = 100000; Label = 'Event log: Warn above this many errors' }
    @{ Key = 'EventWindowHours';     Section = 'Health'; Type = 'int'; Min = 1; Max = 720; Label = 'Event log: look back this many hours' }
    @{ Key = 'LogonFailWarn';        Section = 'Health'; Type = 'int'; Min = 1; Max = 100000; Label = 'Failed logons from one source: Warn at or above' }
    @{ Key = 'LogonFailFail';        Section = 'Health'; Type = 'int'; Min = 1; Max = 100000; Label = 'Failed logons from one source: Fail at or above' }
    @{ Key = 'TaskFailDays';         Section = 'Health'; Type = 'int'; Min = 1; Max = 90; Label = 'Scheduled task failures: look back (days)' }
    @{ Key = 'CertExpiryDays';       Section = 'Health'; Type = 'int'; Min = 1; Max = 365; Label = 'Certificates: Warn this many days before expiry' }
    @{ Key = 'TimeOffsetFailSec';    Section = 'Health'; Type = 'int'; Min = 1; Max = 3600; Label = 'Time: Fail above this offset (seconds)' }
    @{ Key = 'DormantMonths';        Section = 'Health'; Type = 'int'; Min = 1; Max = 120; Label = 'Software: dormant after this many months unused' }
    @{ Key = 'UnknownStaleMonths';   Section = 'Health'; Type = 'int'; Min = 1; Max = 120; Label = 'Unknown software: Stale after (months)' }
    @{ Key = 'UnknownAgeingMonths';  Section = 'Health'; Type = 'int'; Min = 1; Max = 240; Label = 'Unknown software: Ageing after (months)' }
    @{ Key = 'GpoStaleHours';        Section = 'Health'; Type = 'int'; Min = 2; Max = 720; Label = 'Group Policy: Warn when not refreshed for (hours)' }
    @{ Key = 'ScriptSearchFolders';  Section = 'Health'; Type = 'list'; MaxLen = 200; Label = 'Scripts scan: folders (empty = every fixed drive)'; Tip = 'Scripts and tasks (ticked) walks these folders on each server for .ps1 and .psm1 files; empty, every fixed drive. A folder on the skip list is never entered; junctions are never followed.' }
    @{ Key = 'ScriptSearchSkip';     Section = 'Health'; Type = 'list'; MaxLen = 200; Label = 'Scripts scan: folders skipped (name or path part)'; Tip = 'A folder name, or a path part such as ProgramData\Microsoft, matched at any depth; * matches part of a name. Windows, Program Files and AppData are skipped at start: vendor modules and caches are not the scripts an administrator wrote.' }
    @{ Key = 'ScriptSearchSeconds';  Section = 'Health'; Type = 'int'; Min = 10; Max = 1800; Label = 'Scripts scan: time budget per server (seconds)'; Tip = 'The walk stops when the budget is spent (each script is analysed as it is found); the report says PARTIAL and what was left. A server with a very large disk needs more.' }
    @{ Key = 'MinLogicalProcessors'; Section = 'Health'; Type = 'int'; Min = 1; Max = 256; Label = 'Hardware: Warn below this many logical processors' }
    @{ Key = 'MinMemoryGB';          Section = 'Health'; Type = 'int'; Min = 1; Max = 4096; Label = 'Hardware: Warn below this much memory (GB)' }
    @{ Key = 'MinCpuScore';          Section = 'Health'; Type = 'int'; Min = 0; Max = 1000; Label = 'Hardware: Warn below this speed score (0 = show only)'; Tip = 'The Health collector sorts four million integers for about a second on one processor of the server; the score is millions sorted a second. A 3.2 GHz Xeon E5 v4 core scores about 12, a 2 GHz core on a busy host well under 6. Run a few checks, read the Speed column, then set the line where patching became too slow.' }
    @{ Key = 'ImpactDays';           Section = 'Security'; Type = 'int'; Min = 1; Max = 365; Label = 'Impact checks look back this many days' }
)

function Get-SettingSpec {
    param([string]$Key)
    return @($script:SettingSpecs | Where-Object { $_.Key -eq $Key })[0]
}

function Test-SettingText {
    # Plain printable ASCII of at most $Max characters: what may go into a pop-up, a log line or a CSV field.
    param([string]$Text, [int]$Max)
    return ($Text.Length -le $Max -and $Text -notmatch '[^\x20-\x7E]')
}

function ConvertTo-SettingValue {
    # A value from the window or from settings.json, checked against its spec and turned into the type 01-Config.ps1
    # uses.  Throws with the reason when it does not fit.  Lists come back whole (a one-item list stays a list).
    param($Spec, $Value)
    switch ($Spec.Type) {
        'bool' {
            if ($Value -is [bool]) { return $Value }
            if ([string]$Value -in 'true', 'false') { return ([string]$Value -eq 'true') }
            throw 'must be true or false'
        }
        'int' {
            $n = 0
            if (-not [int]::TryParse([string]$Value, [ref]$n)) { throw 'must be a whole number' }
            if ($n -lt $Spec.Min -or $n -gt $Spec.Max) { throw ('must be between {0} and {1}' -f $Spec.Min, $Spec.Max) }
            return $n
        }
        'text' {
            $t = ([string]$Value).Trim()
            if (-not $t -and $Spec.Required) { throw 'must not be empty' }
            if (-not (Test-SettingText $t $Spec.MaxLen)) { throw ('must be plain unaccented text (letters A-Z, digits, punctuation) of at most {0} characters' -f $Spec.MaxLen) }
            return $t
        }
        'list' {
            $items = @(@($Value) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            foreach ($i in $items) { if (-not (Test-SettingText $i $Spec.MaxLen)) { throw ("'{0}' is not plain text of at most {1} characters" -f $i, $Spec.MaxLen) } }
            return , [string[]]$items
        }
        'fields' {
            $items = @(@($Value) | ForEach-Object { [string]$_ } | Where-Object { $_ })
            foreach ($i in $items) { if (-not $script:ChangeFieldNames.Contains($i)) { throw ("'{0}' is not a change record field ({1})" -f $i, (@($script:ChangeFieldNames.Keys) -join ', ')) } }
            return , [string[]]@($script:ChangeFieldNames.Keys | Where-Object { $items -contains $_ })   # the form's order, each once
        }
        'policy' {
            # every action this version knows, from the defaults; the value may name some or all of them
            $base = $script:Config.ChangePolicy
            if ($script:SettingsDefaults -and $script:SettingsDefaults['ChangePolicy']) { $base = $script:SettingsDefaults['ChangePolicy'] }
            $out = [ordered]@{}
            foreach ($a in $script:ChangeActions.Keys) { $out[$a] = 'Required'; if ($base -and $script:ChangePolicyNames.Contains([string]$base[$a])) { $out[$a] = [string]$base[$a] } }
            $pairs = @()
            if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { $pairs += , @([string]$k, [string]$Value[$k]) } }
            elseif ($Value -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $Value.PSObject.Properties) { $pairs += , @([string]$p.Name, [string]$p.Value) } }
            else { throw 'must name a recording rule per action' }
            foreach ($pr in $pairs) {
                if (-not $script:ChangeActions.Contains($pr[0])) { continue }   # an action this version does not have
                if (-not $script:ChangePolicyNames.Contains($pr[1])) { throw ("'{0}' for '{1}' is not one of {2}" -f $pr[1], $pr[0], (@($script:ChangePolicyNames.Keys) -join ', ')) }
                $out[$pr[0]] = $pr[1]
            }
            return $out
        }
        'checks' {
            $list = @()
            foreach ($c in @($Value)) {
                if (-not $c) { continue }
                $name = ([string]$c.Name).Trim(); $q = ([string]$c.Question).Trim(); $ifNo = ([string]$c.IfNo).Trim()
                if (-not $name) { throw 'every step needs a name' }
                if (-not (Test-SettingText $name 60)) { throw ("step '{0}': the name must be plain text of at most 60 characters" -f $name) }
                if (-not $q) { throw ("step '{0}' needs the question to ask" -f $name) }
                if (-not (Test-SettingText $q 400)) { throw ("step '{0}': the question must be plain text of at most 400 characters" -f $name) }
                if (-not (Test-SettingText $ifNo 300)) { throw ("step '{0}': the If No text must be plain text of at most 300 characters" -f $name) }
                # Enabled must be a real yes/no: a hand edit of "yes" or 1 must not switch the confirmation off in silence; a
                # step without the field is asked (never off by omission)
                $on = $true
                if ($c.PSObject.Properties['Enabled'] -and $null -ne $c.Enabled) {
                    $on = $c.Enabled
                    if ($on -isnot [bool]) { if ([string]$on -in 'true', 'false') { $on = ([string]$on -eq 'true') } else { throw ("step '{0}': Enabled must be true or false" -f $name) } }
                }
                $list += [pscustomobject]@{ Name = $name; Enabled = [bool]$on; Question = $q; IfNo = $ifNo }
            }
            $twice = @($list | Group-Object { $_.Name.ToLower() } | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group[0].Name })
            if ($twice.Count -gt 0) { throw ('two steps are called {0}' -f ($twice -join ', ')) }
            return , @($list)
        }
        default { throw ('unknown setting type {0}' -f $Spec.Type) }
    }
}

function ConvertTo-SettingJson {
    # One value as compact JSON - how two values are compared (a one-item list and its item must not look alike).
    param($Spec, $Value)
    if ($Spec.Type -in 'list', 'fields', 'checks') { return (ConvertTo-Json -InputObject @($Value) -Depth 5 -Compress) }
    return (ConvertTo-Json -InputObject $Value -Depth 5 -Compress)
}

function Format-SettingValue {
    # One value as the log and the confirmation show it.
    param($Spec, $Value)
    $t = switch ($Spec.Type) {
        'bool'   { if ($Value) { 'yes' } else { 'no' } }
        'checks' { (@($Value) | ForEach-Object { '{0} ({1})' -f $_.Name, $(if ($_.Enabled) { 'asked' } else { 'off' }) }) -join ', ' }
        'policy' { (@($Value.Keys) | ForEach-Object { '{0}: {1}' -f $_, $script:ChangePolicyNames[[string]$Value[$_]] }) -join '; ' }
        'fields' { (@($Value) | ForEach-Object { $script:ChangeFieldNames[[string]$_] }) -join ', ' }
        'list'   { @($Value) -join ', ' }
        default  { [string]$Value }
    }
    if (-not $t) { return '(none)' }
    return $t
}

function Get-SettingsDefaults {
    # The defaults of 01-Config.ps1 as they were before settings.json was laid over them (copied once, at start-up).
    if (-not $script:SettingsDefaults) {
        $d = @{}
        foreach ($s in $script:SettingSpecs) {
            # a default edited by hand in lib\01-Config.ps1 that does not fit its spec: say which, or the start-up throws a bare "must be between"
            try { $d[$s.Key] = ConvertTo-SettingValue -Spec $s -Value $script:Config[$s.Key] }
            catch { throw ("lib\01-Config.ps1: {0} = '{1}' {2} - correct it there" -f $s.Key, $script:Config[$s.Key], $_.Exception.Message) }
        }
        $script:SettingsDefaults = $d
    }
    return $script:SettingsDefaults
}

function Import-ToolkitSettings {
    # Start-up: lays settings\settings.json over the defaults of 01-Config.ps1.  No file = the defaults; a value that
    # does not fit its spec is skipped with a warning (its default stays); an unreadable file changes nothing.
    $null = Get-SettingsDefaults
    $path = $script:Config.SettingsFile
    $script:SettingsInfo = [pscustomobject]@{ Path = $path; Exists = $false; Saved = ''; SavedBy = ''; Applied = @(); Problems = @() }
    if (-not (Test-Path -LiteralPath $path)) { return }
    $script:SettingsInfo.Exists = $true
    $doc = $null
    try { $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop }
    catch { $script:SettingsInfo.Problems += ('unreadable: ' + (Get-ShortError $_)); Write-PatchLog "SETTINGS: $path could not be read ($(Get-ShortError $_)) - the defaults of lib\01-Config.ps1 apply" 'WARN'; return }
    # an empty file, "null", or a document without a Settings block parses without an error and would pass as "nothing differs"
    if ($null -eq $doc -or -not ($doc -is [psobject] -and $doc.PSObject.Properties['Settings'])) { $script:SettingsInfo.Problems += 'no Settings block (an empty file, or not written by the Settings tab) - the defaults apply'; Write-PatchLog "SETTINGS: $path holds no settings (empty, or not written by the Settings tab) - the defaults of lib\01-Config.ps1 apply" 'WARN'; return }
    $script:SettingsInfo.Saved = [string]$doc.Saved; $script:SettingsInfo.SavedBy = [string]$doc.SavedBy
    if ($doc.Settings) {
        $good = @{}
        foreach ($p in $doc.Settings.PSObject.Properties) {
            $spec = Get-SettingSpec $p.Name
            if (-not $spec) { $script:SettingsInfo.Problems += ('{0}: not a setting of this version - ignored' -f $p.Name); continue }
            try { $good[$spec.Key] = ConvertTo-SettingValue -Spec $spec -Value $p.Value }
            catch { $script:SettingsInfo.Problems += ('{0}: {1} - the default stays' -f $p.Name, $_.Exception.Message) }
        }
        # a valid value that weakens a safeguard is applied - the file is the operator's - but never in silence: judged
        # against the defaults, which $script:Config still holds at this point
        foreach ($w in @(Get-SettingsWeakening -New $good)) { Write-PatchLog "SETTINGS: $w (settings.json weakens a safeguard against the defaults of lib\01-Config.ps1)" 'WARN' }
        foreach ($n in @(Get-SettingsNotes -New $good)) { Write-PatchLog "SETTINGS: $n" 'WARN' }
        foreach ($k in @($good.Keys)) { $script:Config[$k] = $good[$k]; $script:SettingsInfo.Applied += $k }
    }
    foreach ($m in $script:SettingsInfo.Problems) { Write-PatchLog "SETTINGS: $m ($path)" 'WARN' }
    if (@($script:SettingsInfo.Applied).Count -gt 0) { Write-PatchLog ("Settings: {0} value(s) from {1} (saved {2} by {3}): {4}" -f @($script:SettingsInfo.Applied).Count, $path, $script:SettingsInfo.Saved, $script:SettingsInfo.SavedBy, (@($script:SettingsInfo.Applied) -join ', ')) 'INFO' }
}

function Get-SettingsPreview {
    # What saving $Values (key -> value, from the window) would do: every value checked against its spec (the first
    # that does not fit throws, naming it), the changes against the live settings, and the changes that weaken a
    # safeguard (a confirmation no longer asked, an action recorded less, a field no longer required, the confirmations
    # no longer asked before a command that may change a server).
    param([hashtable]$Values)
    $new = @{}
    foreach ($s in $script:SettingSpecs) {
        if (-not $Values.ContainsKey($s.Key)) { continue }
        try { $new[$s.Key] = ConvertTo-SettingValue -Spec $s -Value $Values[$s.Key] }
        catch { throw ('{0}: {1}' -f $s.Label, $_.Exception.Message) }
    }
    $changes = @()
    foreach ($s in $script:SettingSpecs) {
        if (-not $new.ContainsKey($s.Key)) { continue }
        if ((ConvertTo-SettingJson $s $script:Config[$s.Key]) -cne (ConvertTo-SettingJson $s $new[$s.Key])) {
            $changes += ('{0}: {1}  ->  {2}' -f $s.Label, (Format-SettingValue $s $script:Config[$s.Key]), (Format-SettingValue $s $new[$s.Key]))
        }
    }
    return [pscustomobject]@{ New = $new; Changes = $changes; Weaker = @(Get-SettingsWeakening -New $new); Notes = @(Get-SettingsNotes -New $new) }
}

function Get-SettingsNotes {
    # Things worth saying about the values about to be used, without refusing them (the operator's call): a Warn level
    # above its Fail level never shows, so the amber zone of the dial is empty.
    param([hashtable]$New)
    $notes = @()
    $pick = { param([string]$k) if ($New.ContainsKey($k)) { $New[$k] } else { $script:Config[$k] } }
    foreach ($pair in @(@('CpuWarnPercent', 'CpuFailPercent', 'ge', 'processor'), @('LogonFailWarn', 'LogonFailFail', 'ge', 'failed logons'))) {
        $w = [double](& $pick $pair[0]); $f = [double](& $pick $pair[1])
        if ($w -ge $f) { $notes += ('{0}: the Warn level ({1}) is at or above the Fail level ({2}) - a warning will never show, only a failure' -f $pair[3], $w, $f) }
    }
    # (memory is "free percent": the Warn level must sit ABOVE the Fail level; not in the loop above - @(@('a','b','c'))
    #  flattens to three strings, so the pair would have been read letter by letter)
    $mw = [double](& $pick 'MemoryWarnPercent'); $mf = [double](& $pick 'MemoryFailPercent')
    if ($mw -le $mf) { $notes += ('memory: the Warn level ({0}% free) is at or below the Fail level ({1}% free) - a warning will never show, only a failure' -f $mw, $mf) }
    if ((& $pick 'WarnFreeGB') -le (& $pick 'MinFreeGB')) { $notes += ('disk: the warning colour starts at {0} GB, at or below the refusal at {1} GB - installs are refused before the colour warns' -f (& $pick 'WarnFreeGB'), (& $pick 'MinFreeGB')) }
    return $notes
}

function Get-SettingsWeakening {
    # The changes in $New (key -> converted value) that weaken a safeguard against what is in force now: a confirmation no
    # longer asked, an action recorded less, a field no longer required, the confirmations no longer asked before a
    # command that may change a server.  Used by the Save preview (then No is the default) and at start-up, where "in
    # force now" is still the defaults of lib\01-Config.ps1, so a hand-edited settings.json cannot switch a safeguard
    # off in silence.
    param([hashtable]$New)
    $weaker = @()
    if ($New.ContainsKey('SafetyChecks')) {
        $now = @(@($New['SafetyChecks']) | Where-Object { $_.Enabled } | ForEach-Object { $_.Name })
        foreach ($c in @(@($script:Config.SafetyChecks) | Where-Object { $_ -and $_.Enabled })) { if ($now -notcontains $c.Name) { $weaker += ("the '{0}' confirmation is no longer asked" -f $c.Name) } }
    }
    if ($New.ContainsKey('ChangePolicy')) {
        $rank = @{ Required = 2; Maintenance = 1; NotRecorded = 0 }
        foreach ($a in $script:ChangeActions.Keys) {
            $was = [string]$script:Config.ChangePolicy[$a]; $is = [string]$New['ChangePolicy'][$a]
            if ($rank.ContainsKey($was) -and $rank.ContainsKey($is) -and $rank[$is] -lt $rank[$was]) { $weaker += ("'{0}': {1} -> {2}" -f $a, $script:ChangePolicyNames[$was], $script:ChangePolicyNames[$is]) }
        }
    }
    if ($New.ContainsKey('CommandAskSafety') -and $script:Config.CommandAskSafety -and -not $New['CommandAskSafety']) { $weaker += 'the pre-action confirmations are no longer asked before a command that may change a server' }
    if ($New.ContainsKey('ChangeRequiredFields')) {
        foreach ($f in @($script:Config.ChangeRequiredFields)) { if (@($New['ChangeRequiredFields']) -notcontains $f) { $weaker += ('{0} is no longer required in a change record' -f $script:ChangeFieldNames[[string]$f]) } }
    }
    if ($New.ContainsKey('RequireSolidcoreUpdateMode') -and $script:Config.RequireSolidcoreUpdateMode -and -not $New['RequireSolidcoreUpdateMode']) { $weaker += 'OS patch installs and reboots are no longer blocked while Trellix Solidcore is enforcing' }
    if ($New.ContainsKey('TreatPendingFileRenameAsReboot') -and $script:Config.TreatPendingFileRenameAsReboot -and -not $New['TreatPendingFileRenameAsReboot']) { $weaker += 'PendingFileRenameOperations no longer counts as a pending reboot: an install is no longer blocked by it (applies at the next status check)' }
    # a lower free-disk refusal lets an install start on a fuller system drive (R6-C15)
    if ($New.ContainsKey('MinFreeGB') -and [int]$New['MinFreeGB'] -lt [int]$script:Config.MinFreeGB) { $weaker += ('an install is refused only below {0} GB free on C: (was {1} GB)' -f $New['MinFreeGB'], $script:Config.MinFreeGB) }
    if ($New.ContainsKey('DiskSmallVolumeGB') -and [int]$New['DiskSmallVolumeGB'] -gt [int]$script:Config.DiskSmallVolumeGB) { $weaker += ('a volume smaller than {0} GB is no longer judged by the disk space check (was {1} GB)' -f $New['DiskSmallVolumeGB'], $script:Config.DiskSmallVolumeGB) }
    if ($New.ContainsKey('OnePatchPerRun') -and $script:Config.OnePatchPerRun -and -not $New['OnePatchPerRun']) { $weaker += 'several patches may go into one server in one run again (the second one lands on the first one''s pending reboot)' }
    if ($New.ContainsKey('TrellixInUse') -and $script:Config.TrellixInUse -and -not $New['TrellixInUse']) {
        $w = 'Trellix is no longer treated as in use: the Trellix Agent services are not stopped before an install, the Trellix confirmation is not asked, and the Trellix columns, boxes, buttons and warnings go (the Solidcore guard stays)'
        # the reminders go with the switch: a server whose agent services are stopped now (by the tool before an install, or by hand)
        # would stay silent to ePO with nothing saying so - named here, while the switch is still on and the function still looks
        $off = @(Get-TrellixStoppedServers -Servers @($script:ServerStatus.Keys))
        if ($off.Count -gt 0) { $w += (' - AND the Trellix Agent services are STOPPED or DISABLED on {0} server(s) at the last check ({1}): start them first (Start Trellix Agent (ticked)), or ePO hears nothing from them' -f $off.Count, (@($off | Sort-Object | Select-Object -First 10) -join ', ')) }
        $weaker += $w
    }
    if ($New.ContainsKey('StopTrellixAgentForInstall') -and $script:Config.StopTrellixAgentForInstall -and -not $New['StopTrellixAgentForInstall']) { $weaker += 'the Trellix Agent services are no longer stopped before an install (the box on the tabs starts unticked; the field test saw installs fail with them running)' }
    return $weaker
}

function Save-ToolkitSettings {
    # The Settings tab's Save: $Values are checked (Get-SettingsPreview - nothing is saved when one does not fit),
    # written to settings\settings.json - only what differs from the defaults - applied to $script:Config at once,
    # and logged value by value with who saved them.  Returns the change lines.
    param([hashtable]$Values)
    $preview = Get-SettingsPreview -Values $Values
    $defaults = Get-SettingsDefaults
    $keep = [ordered]@{}
    foreach ($s in $script:SettingSpecs) {
        $v = $script:Config[$s.Key]; if ($preview.New.ContainsKey($s.Key)) { $v = $preview.New[$s.Key] }
        if ((ConvertTo-SettingJson $s $v) -cne (ConvertTo-SettingJson $s $defaults[$s.Key])) {
            if ($s.Type -in 'list', 'fields', 'checks') { $keep[$s.Key] = @($v) } else { $keep[$s.Key] = $v }
        }
    }
    $who = Get-OperatorIdentity; $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $doc = [ordered]@{ Tool = ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion); Saved = $when; SavedBy = $who
        Note = 'Written by the Settings tab. Only the values that differ from the defaults in lib\01-Config.ps1 are here.'; Settings = $keep }
    $path = $script:Config.SettingsFile
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    # written beside it first, then moved over it: a half-written file never replaces a good one
    $part = $path + '.part'
    [System.IO.File]::WriteAllText($part, (ConvertTo-Json -InputObject $doc -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $part -Destination $path -Force
    foreach ($k in @($preview.New.Keys)) { $script:Config[$k] = $preview.New[$k] }
    $script:SettingsInfo = [pscustomobject]@{ Path = $path; Exists = $true; Saved = $when; SavedBy = $who; Applied = @($keep.Keys); Problems = @() }
    if (@($preview.Changes).Count -eq 0) { Write-PatchLog "Settings saved by $who ($path) - nothing changed" 'INFO' }
    else {
        Write-PatchLog ("SETTINGS CHANGED by {0} ({1}):" -f $who, $path) 'OK'
        foreach ($c in $preview.Changes) { Write-PatchLog ('   ' + $c) 'INFO' }
    }
    return $preview.Changes
}
