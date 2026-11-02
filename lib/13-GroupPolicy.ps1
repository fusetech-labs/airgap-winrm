# =====================================================================
#  13-GroupPolicy.ps1  -  WHAT GROUP POLICY DOES ON A SERVER
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  One read-only collector ('Gpo') that both the Health and the Security
#  console use:
#    - the GPOs of the last computer policy run, in the order they were
#      applied, each with where it is linked and whether it applied or was
#      filtered out (security filtering, WMI filter, disabled)
#    - every client-side extension's last run and its result code, and the
#      time of the last successful refresh
#    - Group Policy errors and warnings in the System and Group Policy logs
#    - the secure channel to the domain (Test-ComputerSecureChannel)
#    - the Resultant Set of Policy (root\rsop\computer, needs an
#      administrator): which GPO sets which value - administrative
#      templates, security options, account policy, user rights, legacy
#      audit - and the advanced audit policy Group Policy applied
#  Health reads the first four (checks H-GPO-01..03, the Group Policy
#  page); Security reads the last to tell a setting MISSING from Group
#  Policy from one a GPO sets to a weaker value (45-Security-Gpo.ps1).
#  Nothing here changes a server: registry and WMI reads, event queries.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  13-GroupPolicy.ps1
#  New 2026-10-22.  RemoteGpoScript runs ON the servers.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  RUNS ON THE SERVER.  Returns flat text lines (remoting depth 1):
#    Gpos        Name|GPOID|LinkedAt|Version|AccessDenied|WmiFilterPass|Disabled   (application order)
#    Extensions  Name|Guid|Status|LastRun
#    Events      Log|Id|Level|Time|Message                (Level 1 critical, 2 error, 3 warning)
#    Rsop        R|<key>\<value>|<data>|<GPO>  administrative templates
#                S|<KeyName>|<setting>|<GPO>   account policy, guest / administrator account
#                V|<path>|<data>|<GPO>         security options (registry values)
#                U|<right>|<accounts>|<GPO>    user rights
#                A|<category>|S=..,F=..|<GPO>  legacy audit policy
#                D|<subcategory>|<setting>|    advanced audit policy applied by Group Policy
#                G|<GPO>|<extension guids>     which client-side extensions each GPO carries
# ---------------------------------------------------------------------
$script:RemoteGpoScript = {
    param([int]$WindowHours, [int]$MaxSettings)
    $ErrorActionPreference = 'Continue'
    $errors = @()
    # a DWORD read from the registry may arrive as a negative Int32 or as a larger number; FILETIME halves, versions and
    # status codes need the unsigned 32-bit value
    $u32 = { param($v) if ($null -eq $v) { return [uint32]0 }; $n = [int64]$v; if ($n -lt 0) { $n += 4294967296L }; return [uint32]($n -band 0xFFFFFFFFL) }
    $joined = $false; $joinedKnown = $false; $domain = ''; $site = ''; $dn = ''
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop; $joined = [bool]$cs.PartOfDomain; $domain = [string]$cs.Domain; $joinedKnown = $true } catch { $errors += 'computer system: ' + $_.Exception.Message }
    $state = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine'
    try { $st = Get-ItemProperty -LiteralPath $state -ErrorAction Stop; $site = [string]$st.'Site-Name'; $dn = [string]$st.'Distinguished-Name' } catch { if ($joined) { $errors += 'policy state: ' + $_.Exception.Message } }
    # WMI not answering (itself a common cause of policy failures) is not "a workgroup machine": the computer's own policy
    # state names its domain object when a domain policy applied; with nothing to go on, Joined is $null = unknown (R6-D03)
    if (-not $joinedKnown) {
        if ($dn -match '(?i)(^|,)DC=') { $joined = $true; $domain = ((@($dn -split ',' | Where-Object { $_ -match '^(?i)DC=' } | ForEach-Object { $_.Substring(3) })) -join '.') }
        else { $joined = $null }
    }

    # the GPOs of the last computer policy run, in the order they were applied (0 = the local policy)
    $gpos = @()
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath "$state\GPO-List" -ErrorAction Stop | Sort-Object { [int]$_.PSChildName })) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath
            $gpos += '{0}|{1}|{2}|{3}|{4}|{5}|{6}' -f ([string]$p.DisplayName -replace '\|', '/'), $p.GPOID, ([string]$p.SOM -replace '\|', '/'), (& $u32 $p.Version), [int]$p.AccessDenied, [int]$p.WQLFilterPass, [int]$p.'GPO-Disabled'
        }
    } catch { if ($joined) { $errors += 'GPO list: ' + $_.Exception.Message } }

    # every client-side extension's last run; {00000000-...} is the core of Group Policy: its end time = the last refresh
    $exts = @(); $last = ''; $ageHours = ''
    try {
        foreach ($k in @(Get-ChildItem -LiteralPath "$state\Extension-List" -ErrorAction Stop)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath
            $guid = $k.PSChildName
            $end = $null
            if ($null -ne $p.EndTimeHi) { try { $end = [datetime]::FromFileTime(([int64](& $u32 $p.EndTimeHi) -shl 32) -bor [int64](& $u32 $p.EndTimeLo)) } catch { } }
            if ($guid -eq '{00000000-0000-0000-0000-000000000000}') {
                if ($end) { $last = $end.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture); $ageHours = [math]::Round(((Get-Date) - $end).TotalHours, 1) }
                continue
            }
            $name = ''
            try { $name = [string](Get-ItemProperty -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\GPExtensions\$guid" -ErrorAction Stop).'(default)' } catch { }
            if (-not $name) { $name = $guid }
            $exts += '{0}|{1}|{2}|{3}' -f ($name -replace '\|', '/'), $guid, (& $u32 $p.Status), $(if ($end) { $end.ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) } else { '' })
        }
    } catch { if ($joined) { $errors += 'extension list: ' + $_.Exception.Message } }

    # Group Policy errors and warnings in the window: the System log, then the Group Policy log (that one needs an administrator)
    $events = @()
    $start = (Get-Date).AddHours(-$WindowHours)
    foreach ($pair in @(@('System', @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-GroupPolicy'; Level = 1, 2, 3; StartTime = $start }), @('Group Policy', @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; Level = 1, 2, 3; StartTime = $start }))) {
        try {
            foreach ($e in @(Get-WinEvent -FilterHashtable $pair[1] -MaxEvents 40 -ErrorAction Stop)) {
                $events += '{0}|{1}|{2}|{3}|{4}' -f $pair[0], $e.Id, $e.Level, $e.TimeCreated.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture), (((([string]$e.Message) -split "`r?`n")[0]) -replace '\|', '/')
            }
        } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $errors += ('{0} log: {1}' -f $pair[0], $_.Exception.Message) } }
    }

    $sc = ''
    if ($joined) { try { $sc = [string](Test-ComputerSecureChannel -ErrorAction Stop) } catch { $sc = 'ERROR: ' + $_.Exception.Message } }

    # the Resultant Set of Policy: which GPO sets which value (winning setting only: precedence 1)
    $rsop = New-Object System.Collections.Generic.List[string]
    $rsopError = ''; $rsopTruncated = $false
    $ns = 'root\rsop\computer'
    try {
        $names = @{}
        foreach ($g in @(Get-CimInstance -Namespace $ns -ClassName RSOP_GPO -ErrorAction Stop)) {
            $names[[string]$g.id] = [string]$g.name
            $rsop.Add(('G|{0}|{1}' -f ([string]$g.name -replace '\|', '/'), (@($g.extensionIds) -join ';')))
        }
        $gpoName = { param($id) $n = $names[[string]$id]; if ($n) { return ($n -replace '\|', '/') }; return [string]$id }
        foreach ($s in @(Get-CimInstance -Namespace $ns -ClassName RSOP_RegistryPolicySetting -Filter 'precedence=1' -ErrorAction Stop)) {
            if ($rsop.Count -ge $MaxSettings) { $rsopTruncated = $true; break }
            if ($s.deleted -or -not $s.valueName -or [string]$s.valueName -like '[*][*]*') { continue }   # **del., **DeleteValues, **DelVals., **DeleteKeys, **SecureKey: policy markers, not values
            $b = [byte[]]$s.value; $val = ''
            switch ([int]$s.valueType) {
                1 { if ($b) { $val = [Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0) } }
                2 { if ($b) { $val = [Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0) } }
                4 { if ($b -and $b.Length -ge 4) { $val = [string][BitConverter]::ToUInt32($b, 0) } }
                7 { if ($b) { $val = (@([Text.Encoding]::Unicode.GetString($b).TrimEnd([char]0) -split [char]0) -join ';') } }
                11 { if ($b -and $b.Length -ge 8) { $val = [string][BitConverter]::ToUInt64($b, 0) } }
                default { $val = '(binary)' }
            }
            $rsop.Add(('R|{0}\{1}|{2}|{3}' -f $s.registryKey, $s.valueName, ($val -replace '[\r\n|]', ' '), (& $gpoName $s.GPOID)))
        }
        foreach ($cls in 'RSOP_SecuritySettingNumeric', 'RSOP_SecuritySettingBoolean', 'RSOP_SecuritySettingString') {
            foreach ($s in @(Get-CimInstance -Namespace $ns -ClassName $cls -Filter 'precedence=1' -ErrorAction SilentlyContinue)) { $rsop.Add(('S|{0}|{1}|{2}' -f $s.KeyName, ([string]$s.Setting -replace '[\r\n|]', ' '), (& $gpoName $s.GPOID))) }
        }
        foreach ($s in @(Get-CimInstance -Namespace $ns -ClassName RSOP_RegistryValue -Filter 'precedence=1' -ErrorAction SilentlyContinue)) { $rsop.Add(('V|{0}|{1}|{2}' -f $s.Path, ([string]$s.Data -replace '[\r\n|]', ' '), (& $gpoName $s.GPOID))) }
        foreach ($s in @(Get-CimInstance -Namespace $ns -ClassName RSOP_UserPrivilegeRight -Filter 'precedence=1' -ErrorAction SilentlyContinue)) { $rsop.Add(('U|{0}|{1}|{2}' -f $s.UserRight, ((@($s.AccountList) -join ',') -replace '\|', '/'), (& $gpoName $s.GPOID))) }
        foreach ($s in @(Get-CimInstance -Namespace $ns -ClassName RSOP_AuditPolicy -Filter 'precedence=1' -ErrorAction SilentlyContinue)) { $rsop.Add(('A|{0}|S={1},F={2}|{3}' -f $s.Category, $s.Success, $s.Failure, (& $gpoName $s.GPOID))) }
    } catch { $rsopError = $_.Exception.Message }
    # no RSoP data at all on a domain member is not "nothing is set": RSoP logging is off by policy, or not yet written
    if (-not $rsopError -and $joined -and $rsop.Count -eq 0) { $rsopError = 'RSoP holds no data (RSoP logging turned off by policy, or no computer policy run recorded yet)' }
    # the advanced audit policy Group Policy applied lands in this file (RSoP has no class for it)
    try {
        $csv = Join-Path $env:windir 'security\audit\audit.csv'
        if (Test-Path -LiteralPath $csv) { foreach ($r in @(Import-Csv -LiteralPath $csv)) { if ($r.Subcategory) { $rsop.Add(('D|{0}|{1}|' -f $r.Subcategory, $r.'Inclusion Setting')) } } }
    } catch { }

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Joined = $joined; Domain = $domain; Site = $site; DN = $dn; WindowHours = $WindowHours
        Gpos = $gpos; Extensions = $exts; LastRefresh = $last; RefreshAgeHours = $ageHours; Events = $events; SecureChannel = $sc
        Rsop = $rsop.ToArray(); RsopError = $rsopError; RsopTruncated = $rsopTruncated; Errors = $errors
    }
}

function Get-ServerGpo {
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = {
        param($r)
        if ($null -eq $r.Joined) { return ('domain membership could not be read: ' + (@($r.Errors) -join '; ')) }
        if (-not $r.Joined) { return 'not a domain member - local policy only' }
        $applied = @(Get-GpoRows -Result $r | Where-Object { $_.Applied -and $_.GPO -ne 'Local Group Policy' }).Count
        $failed = @($r.Extensions | Where-Object { ($_ -split '\|')[2] -ne '0' }).Count
        $rs = 'RSoP: ' + @($r.Rsop).Count + ' setting(s)'; if ($r.RsopError) { $rs = 'RSoP not readable (' + $r.RsopError + ')' }
        return ('{0} GPO(s) applied, {1} extension(s) failing, last refresh {2}, secure channel {3}; {4}' -f $applied, $failed, $r.LastRefresh, $r.SecureChannel, $rs)
    }
    return (Invoke-Collector -Name 'Gpo' -ScriptBlock $script:RemoteGpoScript -ComputerName $ComputerName -ArgumentList @([int]$script:Config.EventWindowHours, [int]$script:Config.MaxRsopSettings) -Summary $summary)
}

function Get-GpoRows {
    # The GPOs of one server's last computer policy run, in application order: Order, GPO, Status, Applied, LinkedAt, Version.
    param([string]$Server = '', $Result = $null)
    $g = $Result; if (-not $g) { $g = Get-CollectorResult -Name 'Gpo' -Server $Server }
    if (-not $g -or ($g.PSObject.Properties['Reachable'] -and -not $g.Reachable)) { return @() }
    $rows = @(); $i = 0
    foreach ($line in @($g.Gpos)) {
        $f = [string]$line -split '\|'
        if ($f.Count -lt 7) { continue }
        $status = 'Applied'
        if ($f[6] -eq '1') { $status = 'Not applied: GPO disabled' } elseif ($f[4] -eq '1') { $status = 'Not applied: security filtering' } elseif ($f[5] -eq '0') { $status = 'Not applied: WMI filter' }
        $link = $f[2] -replace '^LDAP://', ''
        if ($f[0] -eq 'Local Group Policy') { $link = 'this server (local)' }
        # a GPO's version: the low half counts computer-side edits, the high half user-side ones
        $ver = 0L; $version = $f[3]; if ([int64]::TryParse($f[3], [ref]$ver)) { $version = 'computer {0}, user {1}' -f ($ver -band 0xFFFFL), (($ver -shr 16) -band 0xFFFFL) }
        $rows += [pscustomobject]@{ Order = $i; GPO = $f[0]; Status = $status; Applied = ($status -eq 'Applied'); LinkedAt = $link; Version = $version; Id = $f[1] }
        $i++
    }
    return $rows
}

function Format-GpoStatus {
    # An extension's result code in words: 0 = OK, else the Windows message for the code ("The specified domain either does not exist ...").
    param([string]$Code)
    $n = 0L
    if (-not [int64]::TryParse($Code, [ref]$n) -or $n -eq 0) { return 'OK' }
    $n = $n -band 0xFFFFFFFFL
    $signed = [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$n), 0)   # an HRESULT above 0x7FFFFFFF is a negative Int32
    $text = ''
    try { $text = (New-Object System.ComponentModel.Win32Exception($signed)).Message } catch { }
    return ('error {0} (0x{1:X8}){2}' -f $n, $n, $(if ($text -and $text -notmatch '^Unknown error') { ': ' + $text } else { '' }))
}

function Get-GpoExtensionRows {
    # One server's client-side extensions: Extension, Result, LastRun, Failed.
    param([string]$Server)
    $g = Get-CollectorResult -Name 'Gpo' -Server $Server
    if (-not $g -or -not $g.Reachable) { return @() }
    return @(foreach ($line in @($g.Extensions)) {
        $f = [string]$line -split '\|'
        if ($f.Count -lt 4) { continue }
        [pscustomobject]@{ Extension = $f[0]; Result = (Format-GpoStatus $f[2]); LastRun = $f[3]; Failed = ($f[2] -ne '0'); Guid = $f[1] }
    })
}

function Get-GpoEventRows {
    param([string]$Server)
    $g = Get-CollectorResult -Name 'Gpo' -Server $Server
    if (-not $g -or -not $g.Reachable) { return @() }
    return @(foreach ($line in @($g.Events)) {
        $f = [string]$line -split '\|', 5
        if ($f.Count -lt 5) { continue }
        [pscustomobject]@{ Log = $f[0]; Id = $f[1]; Level = $(switch ($f[2]) { '1' { 'Critical' } '2' { 'Error' } '3' { 'Warning' } default { $f[2] } }); Time = $f[3]; Message = $f[4] }
    })
}

function Get-GpoSettingSource {
    # Which GPO sets a setting on one server, from its RSoP lines.  $Specs: 'R:<key>\<value>', 'S:<KeyName>', 'V:<path>',
    # 'U:<right>', 'A:<category>', 'D:<subcategory>' (any of them).  Returns @{ Known; SetBy; Value } - Known = $false when
    # the RSoP could not be read (not an administrator, not collected, not a domain member), so "not set" is not claimed.
    param([string]$Server = '', [string[]]$Specs, $Result = $null)
    $g = $Result; if (-not $g) { $g = Get-CollectorResult -Name 'Gpo' -Server $Server }
    $out = [pscustomobject]@{ Known = $false; SetBy = ''; Value = '' }
    if (-not $g -or ($g.PSObject.Properties['Reachable'] -and -not $g.Reachable) -or -not $g.Joined -or $g.RsopError) { return $out }
    $lines = @($g.Rsop)
    if ($lines.Count -eq 0) { return $out }   # an empty RSoP is not knowledge: "missing from Group Policy" would be a guess
    $out.Known = $true
    # one index per result ("kind|key" -> the line's fields), built on first use and kept with the server: 90 guided
    # settings x every server x a scan of up to 3000 lines was most of a repaint of the GPO page
    $index = $null
    if ($Server) {
        if (-not $script:RsopIndexCache) { $script:RsopIndexCache = @{} }
        $hit = $script:RsopIndexCache[$Server]
        if ($hit -and [object]::ReferenceEquals($hit.Result, $g)) { $index = $hit.Index }
    }
    if (-not $index) {
        $index = @{}
        foreach ($line in $lines) {
            $f = [string]$line -split '\|'
            if ($f.Count -lt 3) { continue }
            $have = $f[1].Trim().ToLower()
            if ($f[0] -eq 'D') { $have = ($have -replace '^audit ', '') -replace '^pnp activity$', 'plug and play events' }
            $k = $f[0] + '|' + $have
            if (-not $index.ContainsKey($k)) { $index[$k] = $f }   # the first line wins, as the scan did
        }
        # the advanced audit policy file does not say which GPO: name the GPOs that carry the audit extension
        $audit = @($lines | Where-Object { $_ -like 'G|*' -and $_ -match '(?i)\{F3CCC681-B74C-4060-9F26-CD84525DCA2A\}' } | ForEach-Object { ($_ -split '\|')[1] })
        $index['|auditBy'] = $(if ($audit.Count -gt 0) { $audit -join ', ' } else { 'advanced audit policy' })
        if ($Server) { $script:RsopIndexCache[$Server] = @{ Result = $g; Index = $index } }
    }
    foreach ($spec in @($Specs)) {
        if (-not $spec -or $spec -notmatch '^([RSVUAD]):(.+)$') { continue }
        $kind = $Matches[1]; $want = $Matches[2].Trim().ToLower()
        $f = $index[$kind + '|' + $want]
        if (-not $f) { continue }
        $by = ''; if ($f.Count -ge 4) { $by = $f[3] }
        if ($kind -eq 'D') { $by = [string]$index['|auditBy'] }
        $out.SetBy = $by; $out.Value = $f[2]
        return $out
    }
    # the registry settings were cut at MaxRsopSettings: a registry setting not found may sit past the cut - not known (R6-D13)
    if ($g.PSObject.Properties['RsopTruncated'] -and $g.RsopTruncated -and @($Specs | Where-Object { [string]$_ -like 'R:*' }).Count -gt 0) { $out.Known = $false }
    return $out
}

function Get-GpoSummaryText {
    # The Health grid's GPO cell: "9 applied", "9 applied, 1 failing", "trust broken", "workgroup", "stale 3 d".
    param([string]$Server)
    $g = Get-CollectorResult -Name 'Gpo' -Server $Server
    if (-not $g) { return '' }
    if (-not $g.Reachable) { return '?' }
    if ($null -eq $g.Joined) { return 'membership not read' }
    if (-not $g.Joined) { return 'workgroup' }
    if ([string]$g.SecureChannel -eq 'False') { return 'trust broken' }
    $applied = @(Get-GpoRows -Server $Server | Where-Object { $_.Applied -and $_.GPO -ne 'Local Group Policy' }).Count
    $parts = @('{0} applied' -f $applied)
    $failed = @(Get-GpoExtensionRows -Server $Server | Where-Object { $_.Failed }).Count
    if ($failed -gt 0) { $parts += ('{0} failing' -f $failed) }
    $age = 0.0
    $age = ConvertTo-HealthNumber $g.RefreshAgeHours   # invariant: a de-DE PC read 17.5 as 175 (R6-D02)
    if ($null -ne $age -and [string]$g.RefreshAgeHours -and $age -gt [double]$script:Config.GpoStaleHours) { $parts += ('stale {0:n0} h' -f $age) }
    return ($parts -join ', ')
}

function Get-GpoFleetRows {
    # The Group Policy page, top: one row per GPO across the servers shown - where it applies, where it is filtered out.
    param([string[]]$Servers)
    $by = [ordered]@{}
    foreach ($s in $Servers) {
        foreach ($r in @(Get-GpoRows -Server $s)) {
            if ($r.GPO -eq 'Local Group Policy') { continue }
            if (-not $by.Contains($r.GPO)) { $by[$r.GPO] = @{ Link = @{}; Applied = @(); Not = @() } }
            $by[$r.GPO].Link[$r.LinkedAt] = $true
            if ($r.Applied) { $by[$r.GPO].Applied += $s } else { $by[$r.GPO].Not += ('{0} ({1})' -f $s, ($r.Status -replace '^Not applied: ', '')) }
        }
    }
    return @(foreach ($name in $by.Keys) {
        $e = $by[$name]
        [pscustomobject]@{ GPO = $name; 'Linked at' = (@($e.Link.Keys) -join '; '); Applied = $e.Applied.Count; 'Not applied' = $e.Not.Count; 'Applied on' = ($e.Applied -join ', '); 'Not applied on' = ($e.Not -join ', ') }
    })
}

function Get-GpoFleetDetailsHtml {
    # The Group Policy page's double-click: one GPO, every server shown - applied, filtered out, or not linked to it.
    param([string]$Gpo, [string[]]$Servers)
    $rows = @(foreach ($s in $Servers) {
        $g = Get-CollectorResult -Name 'Gpo' -Server $s
        if (-not $g -or -not $g.Reachable) { [pscustomobject]@{ Light = 'Grey'; Server = $s; Status = 'not collected'; 'Linked at' = ''; Version = '' }; continue }
        $r = @(Get-GpoRows -Server $s | Where-Object { $_.GPO -eq $Gpo })[0]
        if (-not $r) { [pscustomobject]@{ Light = 'Grey'; Server = $s; Status = 'not in scope (not linked to this server''s OU, site or domain)'; 'Linked at' = ''; Version = '' }; continue }
        [pscustomobject]@{ Light = $(if ($r.Applied) { 'Green' } else { 'Grey' }); Server = $s; Status = $r.Status; 'Linked at' = $r.LinkedAt; Version = $r.Version }
    })
    $applied = @($rows | Where-Object { $_.Status -eq 'Applied' }).Count
    return (New-DetailsHtml -Title "GPO: $Gpo" -Subtitle 'where it applies among the servers shown' -Console 'Health' -Facts @(@('Applied on', "$applied of $($rows.Count)")) -Sections @(
        @{ Heading = 'Servers'; Rows = $rows; Columns = @('Light', 'Server', 'Status', 'Linked at', 'Version'); Note = 'Green = applied in the last computer policy run. A GPO that is filtered out by security filtering on purpose (meant for users, or for other computers) is normal; a version that differs between servers means some have not refreshed since the GPO changed.' }))
}

function Get-GpoServerRows {
    # The Group Policy page, bottom: one row per server - domain, site, last refresh, failing extensions, errors, trust.
    param([string[]]$Servers)
    return @(foreach ($s in $Servers) {
        $g = Get-CollectorResult -Name 'Gpo' -Server $s
        if (-not $g) { [pscustomobject]@{ Server = $s; Light = 'Grey'; Domain = ''; Site = ''; 'Last refresh' = ''; GPOs = ''; 'Failing extensions' = ''; Errors = ''; 'Secure channel' = ''; Note = 'not checked - press "Check health"' }; continue }
        if (-not $g.Reachable) { [pscustomobject]@{ Server = $s; Light = 'Grey'; Domain = ''; Site = ''; 'Last refresh' = ''; GPOs = ''; 'Failing extensions' = ''; Errors = ''; 'Secure channel' = ''; Note = 'unreachable: ' + $g.Error }; continue }
        $rows = @(Get-CheckRows -Console 'Health' -Server $s | Where-Object { $_.Id -like 'H-GPO-*' })
        $failing = @(Get-GpoExtensionRows -Server $s | Where-Object { $_.Failed } | ForEach-Object { $_.Extension })
        $ev = @(Get-GpoEventRows -Server $s)
        $gpos = @(Get-GpoRows -Server $s)
        $note = ''
        if ($null -eq $g.Joined) { $note = 'domain membership could not be read' } elseif (-not $g.Joined) { $note = 'not a domain member: local policy only' } elseif ($g.RsopError) { $note = 'RSoP not readable: ' + $g.RsopError }
        [pscustomobject]@{
            Server = $s; Light = (Get-WorstLight -Rows $rows); Domain = $(if ($g.Joined) { $g.Domain } elseif ($null -eq $g.Joined) { 'not read' } else { 'workgroup' }); Site = $g.Site
            'Last refresh' = $(if ($g.LastRefresh) { '{0} ({1} h ago)' -f $g.LastRefresh, $g.RefreshAgeHours } else { '' })
            GPOs = ('{0} applied, {1} not' -f @($gpos | Where-Object { $_.Applied -and $_.GPO -ne 'Local Group Policy' }).Count, @($gpos | Where-Object { -not $_.Applied }).Count)
            'Failing extensions' = ($failing -join ', '); Errors = ('{0} error(s), {1} warning(s)' -f @($ev | Where-Object { $_.Level -in 'Critical', 'Error' }).Count, @($ev | Where-Object { $_.Level -eq 'Warning' }).Count)
            'Secure channel' = [string]$g.SecureChannel; Note = $note
        }
    })
}

function Get-GpoDetailsSections {
    # The Group Policy part of a server's Health page.
    param([string]$Server)
    $g = Get-CollectorResult -Name 'Gpo' -Server $Server
    if (-not $g -or -not $g.Reachable) { return @(@{ Heading = 'Group Policy'; Lines = @($(if ($g) { 'unreachable: ' + $g.Error } else { 'not collected yet - press "Check health"' })) }) }
    $head = 'not a domain member: only the local policy applies'
    if ($g.Joined) { $head = 'domain {0}, site {1}; last refresh {2} ({3} h ago); secure channel {4}{5}' -f $g.Domain, $g.Site, $g.LastRefresh, $g.RefreshAgeHours, $g.SecureChannel, $(if ($g.DN) { '; ' + $g.DN } else { '' }) }
    $gpoNote = 'The computer part of the last policy run, in the order the GPOs were applied (a later one wins). "Not applied: security filtering" is often deliberate (the GPO is meant for other computers or for users only).'
    if ($g.RsopError) { $gpoNote += ' The settings each GPO makes (RSoP) could not be read: ' + $g.RsopError }
    return @(
        @{ Heading = 'Group Policy: GPOs'; Note = ($head + '. ' + $gpoNote); Rows = @(Get-GpoRows -Server $Server); Columns = @('Order', 'GPO', 'Status', 'LinkedAt', 'Version') },
        @{ Heading = 'Group Policy: client-side extensions (last run)'; Rows = @(Get-GpoExtensionRows -Server $Server | ForEach-Object { $_ | Add-Member -NotePropertyName Light -NotePropertyValue $(if ($_.Failed) { 'Red' } else { 'Green' }) -PassThru -Force }); Columns = @('Light', 'Extension', 'Result', 'LastRun'); Note = 'Each extension applies one kind of setting (Registry = administrative templates, Security, Audit Policy Configuration, Group Policy Preferences ...). A failed one leaves its settings as they were.' },
        @{ Heading = 'Group Policy: errors and warnings'; Rows = @(Get-GpoEventRows -Server $Server); Columns = @('Log', 'Id', 'Level', 'Time', 'Message'); Note = ('System log (source GroupPolicy) and the Group Policy log, last {0} h.' -f $script:Config.EventWindowHours) })
}
