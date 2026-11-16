# =====================================================================
#  12-Settings.ps1  -  THE SETTINGS THE OPERATOR CHANGES IN THE WINDOW
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  lib\01-Config.ps1 holds the defaults.  The Settings tab saves what the
#  operator changes in settings\settings.json; at start-up
#  Import-ToolkitSettings lays those values over the defaults.  Only the
#  keys in $script:SettingSpecs can be set this way, each checked against
#  its spec (type, range, plain ASCII); the file holds only what differs
#  from the defaults; every save is logged value by value with who saved it.
# =====================================================================

# Type: bool, int (Min..Max), text (MaxLen, [Pattern], [Required]), path (a rooted folder path), choice (Choices).
# Section = its box.  Wide = the row takes a whole line (a long text box).
$script:SettingSpecs = @(
    @{ Key = 'LibraryFolder';        Section = 'Library'; Type = 'path'; MaxLen = 200; Required = $true; Wide = $true; Label = 'Library folder (patches\ and software\ are kept inside it)'; Tip = 'Where the library lives: the WinRM toolkit folder when this tool sits inside it (then a download lands straight in its patches\ and software\), library\ in this folder otherwise, or any folder you name - a USB drive to carry across. The folders are made on the first download.' }
    @{ Key = 'KeepPrevious';         Section = 'Library'; Type = 'int'; Min = 0; Max = 12; Label = 'Older files of a product kept beside the newest (0 = the latest only)'; Tip = 'After a download the earlier files of the same product and build are deleted beyond this number. Every file in the library becomes a column in the WinRM toolkit, so keep it small. A file the manifest does not know (placed by hand) is never deleted.' }
    @{ Key = 'RequireValidSignature'; Section = 'Library'; Type = 'bool'; Label = 'A download must be Authenticode-signed by its product''s signer'; Tip = 'Off, a download is kept with only its size and the published hash checked. The WinRM toolkit checks the signature again on its side and refuses an unsigned file, so leave this on.' }
    @{ Key = 'VerifyEveryStart';     Section = 'Library'; Type = 'bool'; Label = 'Hash every library file again at every run'; Tip = 'Check and download, and every unattended run, hash every file the manifest knows and flag one that changed or was truncated. A few seconds per gigabyte.' }
    @{ Key = 'DownloadTimeoutMin';   Section = 'Downloads'; Type = 'int'; Min = 5; Max = 1440; Label = 'Give up on one download after (minutes)' }
    @{ Key = 'DownloadRetries';      Section = 'Downloads'; Type = 'int'; Min = 0; Max = 10; Label = 'Try a failed download again this many times' }
    @{ Key = 'MaxDownloadMB';        Section = 'Downloads'; Type = 'int'; Min = 10; Max = 65536; Label = 'Refuse a file the source announces as bigger than (MB)' }
    @{ Key = 'CatalogMonthsBack';    Section = 'Downloads'; Type = 'int'; Min = 0; Max = 12; Label = 'Update Catalog: look back this many months for a release'; Tip = 'The cumulative update is searched for this month first, then earlier months, until one is found. Not every month has a .NET release.' }
    @{ Key = 'UseSystemProxy';       Section = 'Downloads'; Type = 'bool'; Label = 'Use the proxy Windows is configured with (Internet Options)'; Tip = 'The system proxy with the logged-on user''s credentials. Unticked, the tool connects directly.' }
    @{ Key = 'TaskTime';             Section = 'Schedule'; Type = 'text'; MaxLen = 5; Required = $true; Pattern = '^([01]\d|2[0-3]):[0-5]\d$'; Label = 'The task runs at (HH:mm, local time)' }
    @{ Key = 'TaskDays';             Section = 'Schedule'; Type = 'choice'; Choices = @('Daily', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'); Label = 'The task runs'; Tip = 'Every day, or once a week on the day named. Patch Tuesday is the second Tuesday of the month (US time): a daily task has the files by Wednesday morning.' }
    @{ Key = 'TaskLogon';            Section = 'Schedule'; Type = 'choice'; Choices = @('Interactive', 'S4U'); Label = 'The task logs on as you with this logon type'; Tip = 'Interactive: runs only while you are logged on, with your full session, and needs no extra right. S4U: runs whether or not you are logged on, stores no password, but has no network credentials (no proxy password, no network drive for the library), and Windows may refuse it to an account that may not log on as a batch job. Register the task again after a change.' }
    @{ Key = 'LogShowCmd';           Section = 'Log'; Type = 'bool'; Label = 'Show the request and command lines (CMD) in the running log' }
    @{ Key = 'LogShowWhy';           Section = 'Log'; Type = 'bool'; Label = 'Show the reasoning lines (WHY) in the running log' }
    @{ Key = 'MaxLogBoxChars';       Section = 'Log'; Type = 'int'; Min = 100000; Max = 20000000; Label = 'The running log keeps about this many characters' }
    @{ Key = 'LogKeepDays';          Section = 'Log'; Type = 'int'; Min = 0; Max = 3650; Label = 'Delete log files older than (days, 0 = keep all)' }
    @{ Key = 'OperatorName';         Section = 'Log'; Type = 'text'; MaxLen = 30; Required = $true; Label = 'Operator name (window title and banner, from the next start)' }
)

function Get-SettingSpec { param([string]$Key) return @($script:SettingSpecs | Where-Object { $_.Key -eq $Key })[0] }

function Test-SettingText {
    param([string]$Text, [int]$Max)
    return ($Text.Length -le $Max -and $Text -notmatch '[^\x20-\x7E]')
}

function ConvertTo-SettingValue {
    # A value from the window or from settings.json, checked against its spec.  Throws with the reason when it does not fit.
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
            if ($t -and $Spec.Pattern -and $t -notmatch $Spec.Pattern) { throw ("'{0}' is not in the form the setting needs" -f $t) }
            return $t
        }
        'path' {
            $t = ([string]$Value).Trim().TrimEnd('\')
            if (-not $t) { throw 'must not be empty' }
            if (-not (Test-SettingText $t $Spec.MaxLen)) { throw ('must be a plain path of at most {0} characters' -f $Spec.MaxLen) }
            if (-not [System.IO.Path]::IsPathRooted($t) -or $t -match '[<>"|?*]') { throw "must be a full folder path (D:\Library, \\server\share\library)" }
            return $t
        }
        'choice' {
            $t = ([string]$Value).Trim()
            $hit = @($Spec.Choices | Where-Object { $_ -ieq $t })[0]
            if (-not $hit) { throw ('must be one of {0}' -f ($Spec.Choices -join ', ')) }
            return [string]$hit
        }
        default { throw ('unknown setting type {0}' -f $Spec.Type) }
    }
}

function ConvertTo-SettingJson { param($Spec, $Value) return (ConvertTo-Json -InputObject $Value -Depth 5 -Compress) }

function Format-SettingValue {
    param($Spec, $Value)
    $t = switch ($Spec.Type) { 'bool' { if ($Value) { 'yes' } else { 'no' } } default { [string]$Value } }
    if (-not $t) { return '(none)' }
    return $t
}

function Get-SettingsDefaults {
    if (-not $script:SettingsDefaults) {
        $d = @{}
        foreach ($s in $script:SettingSpecs) {
            try { $d[$s.Key] = ConvertTo-SettingValue -Spec $s -Value $script:Config[$s.Key] }
            catch { throw ("lib\01-Config.ps1: {0} = '{1}' {2} - correct it there" -f $s.Key, $script:Config[$s.Key], $_.Exception.Message) }
        }
        $script:SettingsDefaults = $d
    }
    return $script:SettingsDefaults
}

function Import-ToolkitSettings {
    # Start-up: lays settings\settings.json over the defaults; a value that does not fit is skipped with a warning.
    $null = Get-SettingsDefaults
    $path = $script:Config.SettingsFile
    $script:SettingsInfo = [pscustomobject]@{ Path = $path; Exists = $false; Saved = ''; SavedBy = ''; Applied = @(); Problems = @() }
    if (-not (Test-Path -LiteralPath $path)) { return }
    $script:SettingsInfo.Exists = $true
    $doc = $null
    try { $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop }
    catch { $script:SettingsInfo.Problems += ('unreadable: ' + (Get-ShortError $_)); Write-PatchLog "SETTINGS: $path could not be read ($(Get-ShortError $_)) - the defaults of lib\01-Config.ps1 apply" 'WARN'; return }
    if ($null -eq $doc -or -not ($doc -is [psobject] -and $doc.PSObject.Properties['Settings'])) { $script:SettingsInfo.Problems += 'no Settings block - the defaults apply'; Write-PatchLog "SETTINGS: $path holds no settings - the defaults of lib\01-Config.ps1 apply" 'WARN'; return }
    $script:SettingsInfo.Saved = [string]$doc.Saved; $script:SettingsInfo.SavedBy = [string]$doc.SavedBy
    if ($doc.Settings) {
        $good = @{}
        foreach ($p in $doc.Settings.PSObject.Properties) {
            $spec = Get-SettingSpec $p.Name
            if (-not $spec) { $script:SettingsInfo.Problems += ('{0}: not a setting of this version - ignored' -f $p.Name); continue }
            try { $good[$spec.Key] = ConvertTo-SettingValue -Spec $spec -Value $p.Value }
            catch { $script:SettingsInfo.Problems += ('{0}: {1} - the default stays' -f $p.Name, $_.Exception.Message) }
        }
        foreach ($w in @(Get-SettingsWeakening -New $good)) { Write-PatchLog "SETTINGS: $w (settings.json weakens a safeguard against the defaults of lib\01-Config.ps1)" 'WARN' }
        foreach ($k in @($good.Keys)) { $script:Config[$k] = $good[$k]; $script:SettingsInfo.Applied += $k }
    }
    foreach ($m in $script:SettingsInfo.Problems) { Write-PatchLog "SETTINGS: $m ($path)" 'WARN' }
    if (@($script:SettingsInfo.Applied).Count -gt 0) { Write-PatchLog ("Settings: {0} value(s) from {1} (saved {2} by {3}): {4}" -f @($script:SettingsInfo.Applied).Count, $path, $script:SettingsInfo.Saved, $script:SettingsInfo.SavedBy, (@($script:SettingsInfo.Applied) -join ', ')) 'INFO' }
}

function Get-SettingsPreview {
    # What saving $Values would do: every value checked (the first that does not fit throws, naming it), the changes
    # against the live settings, and the changes that weaken a safeguard.
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
        if ((ConvertTo-SettingJson $s $script:Config[$s.Key]) -cne (ConvertTo-SettingJson $s $new[$s.Key])) { $changes += ('{0}: {1}  ->  {2}' -f $s.Label, (Format-SettingValue $s $script:Config[$s.Key]), (Format-SettingValue $s $new[$s.Key])) }
    }
    return [pscustomobject]@{ New = $new; Changes = $changes; Weaker = @(Get-SettingsWeakening -New $new); Notes = @(Get-SettingsNotes -New $new) }
}

function Get-SettingsNotes {
    param([hashtable]$New)
    $notes = @()
    if ($New.ContainsKey('KeepPrevious') -and [int]$New['KeepPrevious'] -gt 0) { $notes += ('{0} older file(s) of each product stay in the library: each one is a column in the WinRM toolkit' -f $New['KeepPrevious']) }
    if ($New.ContainsKey('LibraryFolder') -and $New['LibraryFolder'] -ne $script:Config.LibraryFolder) { $notes += 'the library folder changes: the files already fetched stay where they are; check again afterwards' }
    foreach ($k in 'TaskTime', 'TaskDays', 'TaskLogon') { if ($New.ContainsKey($k) -and [string]$New[$k] -ne [string]$script:Config[$k]) { $notes += 'the task settings change: register the task again on the Schedule tab for them to take effect'; break } }
    return $notes
}

function Get-SettingsWeakening {
    param([hashtable]$New)
    $weaker = @()
    if ($New.ContainsKey('RequireValidSignature') -and $script:Config.RequireValidSignature -and -not $New['RequireValidSignature']) { $weaker += 'a download is no longer refused for a missing or wrong Authenticode signature (the WinRM toolkit will still refuse the file)' }
    if ($New.ContainsKey('VerifyEveryStart') -and $script:Config.VerifyEveryStart -and -not $New['VerifyEveryStart']) { $weaker += 'the library files are no longer hashed again at every run: a file changed on disk goes unnoticed until the WinRM toolkit checks it' }
    if ($New.ContainsKey('MaxDownloadMB') -and [int]$New['MaxDownloadMB'] -gt [int]$script:Config.MaxDownloadMB) { $weaker += ('a file up to {0} MB is accepted (was {1} MB)' -f $New['MaxDownloadMB'], $script:Config.MaxDownloadMB) }
    return $weaker
}

function Save-ToolkitSettings {
    # The Settings tab's Save: checked, written (only what differs from the defaults), applied at once, logged.
    param([hashtable]$Values)
    $preview = Get-SettingsPreview -Values $Values
    $defaults = Get-SettingsDefaults
    $keep = [ordered]@{}
    foreach ($s in $script:SettingSpecs) {
        $v = $script:Config[$s.Key]; if ($preview.New.ContainsKey($s.Key)) { $v = $preview.New[$s.Key] }
        if ((ConvertTo-SettingJson $s $v) -cne (ConvertTo-SettingJson $s $defaults[$s.Key])) { $keep[$s.Key] = $v }
    }
    $who = Get-OperatorIdentity; $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $doc = [ordered]@{ Tool = ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion); Saved = $when; SavedBy = $who
        Note = 'Written by the Settings tab. Only the values that differ from the defaults in lib\01-Config.ps1 are here.'; Settings = $keep }
    $path = $script:Config.SettingsFile
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $part = $path + '.part'
    [System.IO.File]::WriteAllText($part, (ConvertTo-Json -InputObject $doc -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $part -Destination $path -Force
    $libraryChanged = ($preview.New.ContainsKey('LibraryFolder') -and $preview.New['LibraryFolder'] -ne $script:Config.LibraryFolder)
    foreach ($k in @($preview.New.Keys)) { $script:Config[$k] = $preview.New[$k] }
    if ($libraryChanged) { $script:LibraryCache = $null; $script:Candidates = @{}; $script:Checked = @{} }
    $script:SettingsInfo = [pscustomobject]@{ Path = $path; Exists = $true; Saved = $when; SavedBy = $who; Applied = @($keep.Keys); Problems = @() }
    if (@($preview.Changes).Count -eq 0) { Write-PatchLog "Settings saved by $who ($path) - nothing changed" 'INFO' }
    else { Write-PatchLog ("SETTINGS CHANGED by {0} ({1}):" -f $who, $path) 'OK'; foreach ($c in $preview.Changes) { Write-PatchLog ('   ' + $c) 'INFO' } }
    return $preview.Changes
}
