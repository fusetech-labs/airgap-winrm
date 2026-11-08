# =====================================================================
#  40-Console-Security.ps1  -  THE SECURITY CONSOLE (tab 3): ISM AUDIT
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  What it does, per server, read-only:
#    collectors  Status, Inventory, Agents, Settings (30-Console-Health.ps1)
#                + SecurityPolicy (this file): auditpol and secedit output
#    checks      data-driven one-value checks from data\security-settings.psd1
#                (audit policy, account policy, security options, user rights,
#                hardening keys) + code checks below (application control,
#                antivirus/EDR, firewall, LAPS, local administrators, service
#                accounts, event forwarding, OS support, patch timeframes)
#                + "not assessable from the server" controls, listed honestly
#    profile     security\profile.json: classification (which ISM controls
#                apply), Essential Eight maturity target; internet-facing is per server (group-file line)
#    tailoring   security\tailoring.json: risk decisions per check and scope
#                (disable / downgrade / threshold) with reason, owner, dates
#    lights      Red   = Fail inside the maturity target, or Severity High
#                Amber = other Fail, any Warn, or an overdue risk acceptance
#                Green = Pass        Grey = not applicable / not assessable / accepted
#  Views: by server, by control, raw settings, GPO recommendations
#  (45-Security-Gpo.ps1), tailoring.  Report: all five.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  40-Console-Security.ps1  (new in version 2)
#  2026-10-22: AUDIT also runs the Group Policy collector (13-GroupPolicy.ps1);
#  the GPO recommendations page, the details section and the report section.
# ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  Catalogue, expected settings, profile, tailoring
# ---------------------------------------------------------------------
function Get-IsmCatalogue {
    # Id -> @{ Id; Section; Topic; Rev; Updated; ML; NC; OS; P; S; TS; Text }  from data\ism-catalogue.psd1.
    # Import-ToolData hands back the same object until the file changes; the lookup table is rebuilt only then.
    $d = Import-ToolData -Name 'ism-catalogue.psd1'
    if (-not $script:IsmCatalogue -or -not [object]::ReferenceEquals($script:IsmCatalogueSource, $d)) {
        $script:IsmCatalogue = @{}
        $script:IsmCatalogueSource = $d
        if ($d) {
            foreach ($c in $d.Controls) { $script:IsmCatalogue[$c.Id] = $c }
            # the ISM release the controls come from: the catalogue's Release, else read off its Source ("... (September 2026).xlsx")
            $rel = ''
            try { if ($d -is [hashtable]) { if ($d.ContainsKey('Release')) { $rel = [string]$d['Release'] } } elseif ($d.PSObject.Properties['Release']) { $rel = [string]$d.Release } } catch { $rel = '' }
            if (-not $rel -and [string]$d.Source -match '\(([A-Za-z]+ \d{4})\)') { $rel = $Matches[1] }
            if (-not $rel) { $rel = 'unknown release' }
            $script:IsmRelease = $rel
            $script:IsmCatalogueInfo = "ISM release $rel ($($d.Count) controls, catalogue generated $($d.Generated))"
        } else { $script:IsmRelease = 'no catalogue'; $script:IsmCatalogueInfo = 'no catalogue - data\ism-catalogue.psd1 is missing' }
    }
    return $script:IsmCatalogue
}

function Get-IsmRelease {
    # The ISM release the catalogue - and so every Security check - is modelled on ("September 2026").  Named on the
    # console, the pages and every security report (owner's ask 2026-11-09): a new ISM release means a new catalogue and
    # code updates for the checks it adds or changes, and the reader must know which release a rating was made against.
    $null = Get-IsmCatalogue
    return [string]$script:IsmRelease
}

function Get-IsmCatalogueInfo {
    # "ISM release September 2026 (1143 controls, catalogue generated 2026-10-19)" - the long form, for the reports
    $null = Get-IsmCatalogue
    return [string]$script:IsmCatalogueInfo
}

function Get-IsmText {
    param([string]$Id)
    $c = (Get-IsmCatalogue)[$Id]
    if ($c) { return $c.Text }
    return ''
}

function Get-SecuritySettingsTable {
    # The entries become checks when the tool starts (Register-SecuritySettingChecks), so an edit to this file
    # needs a restart to change the checks; the Settings view and the report read the current file.
    $d = Import-ToolData -Name 'security-settings.psd1'
    if ($d) { return $d }
    return @{ AsOf = 'n/a'; Settings = @() }
}

function Get-SecurityProfilePath { return (Join-Path $script:Config.SecurityFolder 'profile.json') }
function Get-TailoringPath { return (Join-Path $script:Config.SecurityFolder 'tailoring.json') }

function Read-CachedJson {
    # The profile and the tailoring file are consulted for every check row, so they are read once and
    # re-read only when the file changes on disk (the sysadmin may edit them in Notepad while the tool runs).
    param([string]$Path, [scriptblock]$Default)
    if (-not $script:JsonCache) { $script:JsonCache = @{} }
    $hit = $script:JsonCache[$Path]
    $now = [datetime]::UtcNow
    # looked at on disk at most every 2 seconds: 500 servers x 112 checks would otherwise stat the file 56,000 times
    if ($hit -and ($now - $hit.Seen).TotalSeconds -lt 2) { return $hit.Object }
    $stamp = 'missing'
    if (Test-Path -LiteralPath $Path) { $stamp = [string](Get-Item -LiteralPath $Path).LastWriteTimeUtc.Ticks }
    if ($hit -and $hit.Stamp -eq $stamp) { $hit.Seen = $now; return $hit.Object }
    $obj = $null
    if ($stamp -ne 'missing') { $obj = Read-ToolJson -Path $Path }
    if (-not $obj) { $obj = & $Default }
    $script:JsonCache[$Path] = @{ Stamp = $stamp; Object = $obj; Seen = $now }
    Clear-SecurityRowCache
    return $obj
}

function Clear-JsonCache { $script:JsonCache = @{}; Clear-SecurityRowCache }

function Clear-SecurityRowCache { Clear-CheckRowCache }   # the shared check-row cache in 10-Checks.ps1

function Get-SecurityProfile {
    $p = Read-CachedJson -Path (Get-SecurityProfilePath) -Default { [pscustomobject]@{ classification = 'PROTECTED'; maturityTarget = 2; note = 'defaults - set the classification and the Essential Eight target on the Security profile tab of the Security console' } }
    # internet-facing is a per-server setting on the group-file line ("; class: internet-facing"), not part of the profile
    # a hand-trimmed file may lack a property: assigning it would throw ("property cannot be found"), so add what is missing
    foreach ($pair in @(@('classification', 'PROTECTED'), @('maturityTarget', 2), @('note', ''))) { if (-not $p.PSObject.Properties[$pair[0]]) { $p | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force } }
    return $p
}

function Save-SecurityProfile {
    param($SecurityProfile)
    # the cached object was edited in place, so the cache is dropped whether or not the write succeeds
    try { Save-ToolJson -Object $SecurityProfile -Path (Get-SecurityProfilePath) } finally { Clear-JsonCache }
    Write-PatchLog ("Security profile saved by {0}: classification {1}, Essential Eight target ML{2}" -f (Get-OperatorIdentity), $SecurityProfile.classification, $SecurityProfile.maturityTarget) 'OK'
}

function Get-ClassificationColumn {
    # ISM applicability columns of the catalogue: NC (non-classified, which includes plain OFFICIAL),
    # OS (OFFICIAL: Sensitive), P (PROTECTED), S (SECRET), TS (TOP SECRET).
    param([string]$Classification)
    switch -Regex ($Classification) {
        '^TOP' { return 'TS' }
        '^SECRET' { return 'S' }
        '^PROTECTED' { return 'P' }
        'Sensitive' { return 'OS' }
        default { return 'NC' }
    }
}

function Get-ServerClass {
    # The class in force: the server's own "; class:" entry on its group-file line, else the group's "# class:" directive.
    # 'internet-facing' switches on the shorter patch timeframe and ML2 application control; anything else is a member.
    param([string]$Name)
    return (Get-ServerAttribute -Name $Name -Key 'class')
}

function Get-SecurityTailoring {
    $t = Read-CachedJson -Path (Get-TailoringPath) -Default { [pscustomobject]@{ rules = @() } }
    if (-not $t.PSObject.Properties['rules'] -or $null -eq $t.rules) { $t | Add-Member -NotePropertyName rules -NotePropertyValue @() -Force }
    $t.rules = @($t.rules)
    return $t
}

function Save-SecurityTailoring {
    param($Tailoring)
    $Tailoring.rules = @($Tailoring.rules)
    try { Save-ToolJson -Object $Tailoring -Path (Get-TailoringPath) } finally { Clear-JsonCache }
    Write-PatchLog ("Tailoring saved by {0}: {1} rule(s)" -f (Get-OperatorIdentity), @($Tailoring.rules).Count) 'OK'
}

function New-TailoringRule {
    param([string]$Check, [string]$Scope = 'all', [string]$Action = 'disable', [string]$Value = '', [string]$Reason = '', [string]$By = '', [string]$Date = '', [string]$Review = '')
    if (-not $By) { $By = Get-OperatorIdentity }
    if (-not $Date) { $Date = Get-Date -Format 'yyyy-MM-dd' }
    if (-not $Review) { $Review = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd') }
    if ($Scope -match '^(group|server):(.+)$') { $Scope = $Matches[1].ToLower() + ':' + $Matches[2] } elseif ($Scope -match '^all$') { $Scope = 'all' }   # the kind in lower case, as the editor expects
    return [pscustomobject]@{ check = $Check; scope = $Scope; action = $Action; value = $Value; reason = $Reason; by = $By; date = $Date; review = $Review }
}

function Get-TailoringRules {
    # Rules that apply to one check on one server: scope 'all', 'group:<name>' or 'server:<name>'.
    # Most specific first (server, then group, then all), so a server's own rule wins over a fleet-wide one.
    # A server in more than one group gets the rules of each of its groups.
    # The server's rules are sorted into an index once and kept in the check-row cache under "Tailoring|<server>", so it
    # goes whenever the server's rows go (a new audit, a profile, tailoring, data-file or group change): every check row,
    # every settings row and every expected value asks for them - a pass over every rule each time was most of a cold row.
    param([string]$Id, [string]$Server)
    if (-not $script:CheckRowCache) { $script:CheckRowCache = @{} }
    $key = 'Tailoring|' + $Server
    $idx = $script:CheckRowCache[$key]
    if (-not $idx) {
        $idx = @{}
        $groupNames = @(foreach ($sg in @(Get-ServerGroups -Name $Server)) { [string]$sg.Name })
        foreach ($r in @((Get-SecurityTailoring).rules)) {
            $chk = [string]$r.check; if (-not $chk) { continue }
            $scope = [string]$r.scope
            $rank = -1   # 0 = the server's own rule, 1 = one of its groups', 2 = everyone's: most specific first
            if (-not $scope -or $scope -eq 'all') { $rank = 2 }
            elseif ($scope -match '^group:(.+)$') { if (@($groupNames) -contains $Matches[1]) { $rank = 1 } }
            elseif ($scope -match '^server:(.+)$') { if ($Server -ieq $Matches[1]) { $rank = 0 } }
            if ($rank -lt 0) { continue }
            if (-not $idx.ContainsKey($chk)) { $idx[$chk] = @{ 0 = (New-Object System.Collections.Generic.List[object]); 1 = (New-Object System.Collections.Generic.List[object]); 2 = (New-Object System.Collections.Generic.List[object]) } }
            $idx[$chk][$rank].Add($r)
        }
        $script:CheckRowCache[$key] = $idx
    }
    if (-not $idx.ContainsKey($Id)) { return @() }
    $e = $idx[$Id]
    return @($e[0].ToArray() + $e[1].ToArray() + $e[2].ToArray())
}

function Test-TailoringOverdue {
    # A rule is overdue when its review date has passed - or when it has no readable review date at all: a risk
    # decision without a review date never expires, which is exactly what the review date is there to prevent.
    param($Rule)
    $review = [string]$Rule.review
    if (-not $review) { return $true }
    try { return ([datetime]::ParseExact($review, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture) -lt (Get-Date).Date) } catch { return $true }
}

function Get-TailoredExpected {
    # The expected value a threshold rule sets for this server (most specific rule first).  An overdue threshold no
    # longer relaxes the check: the table's value applies again until the rule is reviewed.
    param([string]$Id, [string]$Server, [string]$Default)
    # an empty value is no threshold: it compared every server against "" and turned a compliant one red (R6-E-M6)
    foreach ($r in (Get-TailoringRules -Id $Id -Server $Server)) { if ([string]$r.action -eq 'threshold' -and $null -ne $r.value -and ([string]$r.value).Trim() -and -not (Test-TailoringOverdue -Rule $r)) { return [string]$r.value } }
    return $Default
}

# ---------------------------------------------------------------------
#  SecurityPolicy collector - RUNS ON THE SERVER.  Needs an administrator
#  (auditpol and secedit refuse otherwise); the failure is reported, not fatal.
#  Lines:  Audit:<subcategory>=<Inclusion Setting>
#          Sec:<name>=<value>           secedit [System Access]
#          Right:<privilege>=<sids>     secedit [Privilege Rights]
#          Reg:<leaf>=<value>           secedit [Registry Values]
# ---------------------------------------------------------------------
$script:RemoteSecurityPolicyScript = {
    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]
    $errors = @()
    try {
        $csv = (& auditpol.exe /get /category:* /r 2>&1) | Where-Object { $_ -and $_ -notmatch '^\s*$' } | ConvertFrom-Csv
        $n = 0
        foreach ($row in $csv) { if ($row.Subcategory) { $lines.Add("Audit:$($row.Subcategory)=$($row.'Inclusion Setting')"); $n++ } }
        if ($n -eq 0) { $errors += 'auditpol returned no rows (run as an administrator?)' }
    } catch { $errors += 'auditpol: ' + $_.Exception.Message }
    $tmp = Join-Path $env:TEMP ('secpol-' + [guid]::NewGuid().ToString('N') + '.inf')
    try {
        $null = & secedit.exe /export /cfg "$tmp" /quiet 2>&1
        if (Test-Path -LiteralPath $tmp) {
            $section = ''
            foreach ($line in (Get-Content -LiteralPath $tmp)) {
                if ($line -match '^\[(.+)\]\s*$') { $section = $Matches[1]; continue }
                if ($line -match '^([^=]+?)\s*=\s*(.*)$') {
                    $k = $Matches[1].Trim(); $v = $Matches[2].Trim()
                    switch ($section) {
                        'System Access'    { $lines.Add("Sec:$k=$v") }
                        'Privilege Rights' { $lines.Add("Right:$k=$v") }
                        'Registry Values'  { $leaf = ($k -split '\\')[-1]; $val = ($v -replace '^\d+,', '') -replace '^"(.*)"$', '$1'; $lines.Add("Reg:$leaf=$val") }
                        'Event Audit'      { $lines.Add("LegacyAudit:$k=$v") }
                    }
                }
            }
        } else { $errors += 'secedit export produced no file (run as an administrator?)' }
    } catch { $errors += 'secedit: ' + $_.Exception.Message }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }   # the export holds the whole local policy - never left behind
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Lines = $lines.ToArray(); Count = $lines.Count; Errors = $errors }
}

function Get-ServerSecurityPolicy {
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = { param($r) ('{0} policy values read{1}' -f $r.Count, $(if (@($r.Errors).Count -gt 0) { ' - ' + (@($r.Errors) -join '; ') } else { '' })) }
    return (Invoke-Collector -Name 'SecurityPolicy' -ScriptBlock $script:RemoteSecurityPolicyScript -ComputerName $ComputerName -Summary $summary)
}

function Invoke-SecurityAudit {
    # Everything the Security checks need, freshly collected.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    Get-ServerStatus -ComputerName $ComputerName | Out-Null
    Get-ServerInventory -ComputerName $ComputerName | Out-Null
    Get-ServerAgents -ComputerName $ComputerName | Out-Null
    Get-ServerSettings -ComputerName $ComputerName | Out-Null
    Get-ServerSecurityPolicy -ComputerName $ComputerName | Out-Null
    Get-ServerGpo -ComputerName $ComputerName | Out-Null   # which GPO sets what: the GPO recommendations page (45-Security-Gpo.ps1)
    Get-ServerLicensing -ComputerName $ComputerName | Out-Null   # activation, KMS, RD Licensing CALs, RD Session Hosts: the SEC-LIC checks (47-Licensing.ps1; reported by the Software console)
    Clear-SecurityRowCache
}

# ---------------------------------------------------------------------
#  One-value checks from data\security-settings.psd1
# ---------------------------------------------------------------------
function Get-ExpectedForClassification {
    # The table's expected value for the network's classification: ExpectedAt = @{ S = '17'; TS = '20' } on an entry
    # replaces Expected on a SECRET or TOP SECRET network (the ISM asks more of higher classifications); else Expected.
    param($Def)
    $exp = [string]$Def.Expected
    $at = $null; if ($Def.PSObject.Properties['ExpectedAt'] -or ($Def -is [hashtable] -and $Def.ContainsKey('ExpectedAt'))) { $at = $Def.ExpectedAt }
    if ($at) {
        $col = Get-ClassificationColumn -Classification ([string](Get-SecurityProfile).classification)
        if ($col -and $at.Contains($col) -and $null -ne $at[$col]) { $exp = [string]$at[$col] }
    }
    return $exp
}

function Test-SettingRule {
    param($Context, $Def)
    $key = [string]$Def.Key
    $has = $Context.S.ContainsKey($key)
    $actual = ''
    if ($has) { $actual = [string]$Context.S[$key] }
    $op = [string]$Def.Op
    $expected = Get-TailoredExpected -Id $Def.Id -Server $Context.Server -Default (Get-ExpectedForClassification -Def $Def)
    if ($op -eq 'report') { if ($has) { return (Pass "$key = $actual (reported, no pass/fail)") } else { return (Warn "$key not collected") } }
    $notSet = (-not $has) -or ($actual -eq 'NotConfigured') -or ($actual -eq 'Unknown') -or ($actual -like 'ERROR:*')
    if ($notSet) {
        if ($actual -like 'ERROR:*') { return (Warn "could not read $key - $actual") }
        # 'Unknown' = the collector's query failed (a feature list DISM could not give, Device Guard not answering): the value
        # was NOT read - it is not "not configured", and no default applies to it
        if ($actual -eq 'Unknown') { return (Warn "could not read $key - the collector could not determine it") }
        # secedit exports only what is set: on a clean run a Right: or Reg: key that is absent WAS read - nobody holds the
        # right / the value is not configured.  Any other absent key was simply not collected, and that is never a Pass.
        $cleanPolicy = ($Context.SecurityPolicy -and $Context.SecurityPolicy.Reachable -and @($Context.SecurityPolicy.Errors).Count -eq 0 -and @($Context.SecurityPolicy.Lines).Count -gt 0)
        if (-not $has -and $key -like 'Right:*' -and $cleanPolicy) {
            if ($op -eq 'contains') { return (Fail "$key is assigned to no account; expected contains $expected") }
            return (Pass "$key is assigned to no account")
        }
        if (-not $has -and -not ($key -like 'Reg:*' -and $cleanPolicy)) {
            # a policy value that is missing altogether usually means auditpol / secedit refused to run (not an administrator)
            $why = 'older OS, missing module or no right to read it'
            if ($key -match '^(Audit|Sec|Right|Reg|LegacyAudit):' -and $Context.SecurityPolicy -and @($Context.SecurityPolicy.Errors).Count -gt 0) { $why = @($Context.SecurityPolicy.Errors) -join '; ' }
            return (Warn "$key was not collected ($why); expected $op $expected")
        }
        # from here the value was read, and it is not configured
        if ($Def.NotConfiguredOk) { return (Pass "$key not configured (the OS default meets the expectation)") }
        if ($op -eq 'eq' -and $expected -eq '') { return (Pass "$key is empty / not set") }
        if ($op -eq 'ne' -and $actual -ne 'Unknown') { return (Pass "$key not set / absent") }
        return (Warn "$key not configured - the OS default applies; expected $op $expected")
    }
    $num = 0.0; $isNum = [double]::TryParse($actual, [ref]$num)
    $expNum = 0.0; $expIsNum = [double]::TryParse($expected, [ref]$expNum)    # the expected value may come from a hand-written tailoring rule
    switch ($op) {
        'eq'       { if ($actual -ieq $expected) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected $expected") }
        'ne'       { if ($actual -ine $expected) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected anything but $expected") }
        'ge'       { if (-not $expIsNum) { return (Warn "expected value '$expected' for $key is not a number (check the tailoring threshold or the data file)") }; if (-not $isNum) { return (Warn "$key = '$actual' is not a number") }; if ($num -ge $expNum) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected at least $expected") }
        'le'       { if (-not $expIsNum) { return (Warn "expected value '$expected' for $key is not a number (check the tailoring threshold or the data file)") }; if (-not $isNum) { return (Warn "$key = '$actual' is not a number") }; if ($num -le $expNum) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected at most $expected") }
        'between'  {
            $lo = 0.0; $hi = 0.0; $range = @($expected -split '-')
            if ($range.Count -ne 2 -or -not [double]::TryParse($range[0], [ref]$lo) -or -not [double]::TryParse($range[1], [ref]$hi)) { return (Warn "expected range '$expected' for $key is not written as low-high") }
            if (-not $isNum) { return (Warn "$key = '$actual' is not a number") }
            if ($num -ge $lo -and $num -le $hi) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected $lo to $hi")
        }
        'in'       { $set = @($expected -split ';' | ForEach-Object { $_.Trim() }); if ($set -contains $actual) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected one of $expected") }
        'contains' { if (([string]$actual).IndexOf([string]$expected, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected to contain $expected") }
        'subset'   {
            $allowed = @($expected -split ';' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
            $members = @($actual -split '[,;]' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
            $extra = @($members | Where-Object { $allowed -notcontains $_ })
            if ($extra.Count -eq 0) { return (Pass "$key = $actual") }
            return (Fail ("{0} = {1}; not allowed: {2} (allowed: {3})" -f $key, $actual, ($extra -join ', '), $expected))
        }
        'match'    { if ($actual -match $expected) { return (Pass "$key = $actual") }; return (Fail "$key = $actual, expected to match $expected") }
    }
    return (Warn "unknown operator '$op' in security-settings.psd1 for $($Def.Id)")
}

function Register-SecuritySettingChecks {
    $table = Get-SecuritySettingsTable
    foreach ($d in @($table.Settings)) {
        $def = $d
        $needs = @('Settings')
        if ([string]$def.Key -match '^(Audit|Sec|Right|Reg|LegacyAudit):') { $needs = @('SecurityPolicy') }
        $applies = 'all'; if ($def.ContainsKey('Applies') -and $def.Applies) { $applies = [string]$def.Applies }
        $ism = @([string]$def.Ism -split '[ ,;]+' | Where-Object { $_ })
        # the table entry travels with the check as Data; the test reads it back from $c.Check.Data
        New-Check -Id $def.Id -Console 'Security' -Group ([string]$def.Group) -Title ([string]$def.Title) -Ism $ism -ML ([int]$def.ML) -Severity ([string]$def.Severity) -Needs $needs -Data $def -Fix ([string]$def.Fix) -Applies $applies -Why ("Expected: {0} {1} {2}" -f $def.Key, $def.Op, $def.Expected) `
            -Test { param($c) Test-SettingRule -Context $c -Def $c.Check.Data }
    }
}
Register-SecuritySettingChecks

# ---------------------------------------------------------------------
#  Code checks (several values, or logic the table cannot express)
# ---------------------------------------------------------------------
# ---- Controls the ISM asks for at SECRET and TOP SECRET only.  They cite controls whose catalogue columns are S / TS,
#      so Resolve-SecurityRow marks them "not applicable" on a PROTECTED (or lower) network and they come into force when
#      the Security profile says SECRET or TOP SECRET - the classification knob at work.  Their readings come from the
#      Settings collector (TLS.CipherSuites, TLS.EccCurves, Certs.RsaMinBits, Wireless.*, Bluetooth.*). ----
New-Check -Id 'SEC-CRY-02' -Console 'Security' -Group 'Cryptography' -Title 'Machine certificates use RSA keys of at least 3072 bits (SECRET and above)' -Ism 'ISM-1765' -ML 0 -Severity 'Medium' -Needs 'Settings' `
    -Why 'ISM-1765: on SECRET and TOP SECRET systems RSA keys for signatures and key transport are at least 3072 bits.' `
    -Test {
        param($c)
        $v = [string]$c.S['Certs.RsaMinBits']
        if (-not $v -or $v -eq 'Unknown' -or $v -like 'ERROR:*') { return (Warn 'the machine certificate store could not be read') }
        if ($v -eq 'none') { return (Pass 'no RSA certificate in the machine store') }
        $bits = 0; if (-not [int]::TryParse($v, [ref]$bits)) { return (Warn "the smallest RSA key size could not be read ('$v')") }
        if ($bits -ge 3072) { return (Pass "smallest RSA key in the machine store: $bits bits") }
        return (Fail "a machine certificate uses an RSA key of $bits bits (below 3072)")
    } -Fix 'Re-issue the certificate from the CA with a 3072- or 4096-bit key (certlm.msc > Personal > Certificates > All Tasks > Request New Certificate, or the template''s key size), then rebind the service that uses it.'

New-Check -Id 'SEC-CRY-03' -Console 'Security' -Group 'Cryptography' -Title 'TLS cipher suites: AES-256 with SHA-384 only (TOP SECRET)' -Ism 'ISM-1770', 'ISM-1768' -ML 0 -Severity 'Medium' -Needs 'Settings' `
    -Why 'ISM-1770 and ISM-1768: on TOP SECRET systems AES-192/256 and SHA-384/512 are used - every TLS suite the server offers must be AES-256 with SHA-384.' `
    -Test {
        param($c)
        $v = [string]$c.S['TLS.CipherSuites']
        if (-not $v -or $v -eq 'Unknown') { return (Warn 'the TLS cipher suite list could not be read (Get-TlsCipherSuite needs Server 2016 or later)') }
        $suites = @($v -split '[;\s]+' | Where-Object { $_ })
        $bad = @($suites | Where-Object { $_ -notmatch 'AES_256' -or $_ -notmatch 'SHA384' })
        if ($bad.Count -eq 0) { return (Pass ("{0} suite(s) offered, all AES-256 with SHA-384" -f $suites.Count)) }
        return (Fail ("{0} of {1} offered suite(s) are not AES-256 with SHA-384" -f $bad.Count, $suites.Count) -Items @($bad | Select-Object -First 12))
    } -Fix 'GPO: Computer Configuration > Administrative Templates > Network > SSL Configuration Settings > SSL Cipher Suite Order = the AES-256 GCM SHA384 suites only (TLS_AES_256_GCM_SHA384, TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384, TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384), or Disable-TlsCipherSuite for each of the others. Test every TLS client of the server first.'

New-Check -Id 'SEC-CRY-04' -Console 'Security' -Group 'Cryptography' -Title 'TLS cipher suites: SHA-256 or stronger, no NULL, RC4 or 3DES (SECRET)' -Ism 'ISM-1767' -ML 0 -Severity 'Medium' -Needs 'Settings' `
    -Why 'ISM-1767: on SECRET systems SHA-2 hashing uses at least 256 bits - a TLS suite with SHA-1, no encryption, RC4 or 3DES must not be offered.' `
    -Test {
        param($c)
        $v = [string]$c.S['TLS.CipherSuites']
        if (-not $v -or $v -eq 'Unknown') { return (Warn 'the TLS cipher suite list could not be read (Get-TlsCipherSuite needs Server 2016 or later)') }
        $suites = @($v -split '[;\s]+' | Where-Object { $_ })
        $bad = @($suites | Where-Object { $_ -match 'NULL|RC4|3DES|_MD5' -or $_ -match '_SHA$' })
        if ($bad.Count -eq 0) { return (Pass ("{0} suite(s) offered, all SHA-256 or stronger with real encryption" -f $suites.Count)) }
        return (Fail ("{0} of {1} offered suite(s) use SHA-1, NULL, RC4 or 3DES" -f $bad.Count, $suites.Count) -Items @($bad | Select-Object -First 12))
    } -Fix 'GPO: Computer Configuration > Administrative Templates > Network > SSL Configuration Settings > SSL Cipher Suite Order without the *_SHA, *_NULL_*, RC4 and 3DES suites, or Disable-TlsCipherSuite for each. Test every TLS client of the server first.'

New-Check -Id 'SEC-CRY-05' -Console 'Security' -Group 'Cryptography' -Title 'TLS elliptic curves: NIST P-256/P-384/P-521 only (SECRET), P-384/P-521 only (TOP SECRET)' -Ism 'ISM-1761', 'ISM-1763', 'ISM-1762', 'ISM-1764' -ML 0 -Severity 'Medium' -Needs 'Settings' `
    -Why 'ISM-1761/1763 (SECRET) and ISM-1762/1764 (TOP SECRET): ECDH and ECDSA use the NIST P-256 (SECRET only), P-384 or P-521 curves - curve25519 and the brainpool curves are not ASD-approved.' `
    -Test {
        param($c)
        $v = [string]$c.S['TLS.EccCurves']
        if (-not $v -or $v -eq 'Unknown') { return (Warn 'the TLS curve list could not be read (Get-TlsEccCurve needs Server 2016 or later)') }
        $curves = @($v -split '[;\s]+' | Where-Object { $_ })
        $col = Get-ClassificationColumn -Classification ([string](Get-SecurityProfile).classification)
        $allowed = @('NistP256', 'NistP384', 'NistP521'); if ($col -eq 'TS') { $allowed = @('NistP384', 'NistP521') }
        $bad = @($curves | Where-Object { $allowed -notcontains $_ })
        if ($bad.Count -eq 0) { return (Pass ("curves offered: {0}" -f ($curves -join ', '))) }
        return (Fail ("{0} offered curve(s) outside {1}: {2}" -f $bad.Count, ($allowed -join '/'), ($bad -join ', ')))
    } -Fix 'GPO: Computer Configuration > Administrative Templates > Network > SSL Configuration Settings > ECC Curve Order = NistP384, NistP521 (and NistP256 on SECRET), or Disable-TlsEccCurve curve25519. Test every TLS client of the server first.'

New-Check -Id 'SEC-WLS-01' -Console 'Security' -Group 'Platform protection' -Title 'No Wi-Fi or Bluetooth radio on the server (SECRET and above)' -Ism 'ISM-0225', 'ISM-0829' -ML 0 -Severity 'High' -Needs 'Settings' `
    -Why 'ISM-0225 / ISM-0829: unauthorised RF devices are kept out of SECRET and TOP SECRET areas, and measures detect them - a server with a Wi-Fi or Bluetooth radio is one.' `
    -Test {
        param($c)
        $wifi = [string]$c.S['Wireless.Adapters']; $bt = [string]$c.S['Bluetooth.Devices']; $svc = [string]$c.S['Wireless.WlanSvc']
        if (-not $wifi -or $wifi -eq 'Unknown' -or $bt -eq 'Unknown') { return (Warn 'the network adapters or the devices could not be read') }   # "could not be read": Test-UnreadEvidence keeps it out of the figures (R6-E-M2)
        $nw = 0; $nb = 0; [void][int]::TryParse($wifi, [ref]$nw); [void][int]::TryParse($bt, [ref]$nb)
        if ($nw -gt 0 -or $nb -gt 0) { return (Fail ("{0} Wi-Fi adapter(s) and {1} Bluetooth device(s) present" -f $nw, $nb)) }
        if ($svc -match '^(Automatic|Manual)/Running') { return (Warn "no radio found, but the WLAN AutoConfig service is running ($svc)") }
        return (Pass ("no Wi-Fi adapter, no Bluetooth device (WLAN service: {0})" -f $(if ($svc) { $svc } else { 'absent' })))
    } -Fix 'Remove or disable the radio in firmware or Device Manager; disable the WLAN AutoConfig service (Set-Service WlanSvc -StartupType Disabled, under a change record) or remove the Wireless LAN Service feature.'

New-Check -Id 'SEC-OS-07' -Console 'Security' -Group 'Operating system' -Title 'Operating system still supported by the vendor' -Ism 'ISM-1501' -ML 1 -Severity 'High' -Needs 'Status' `
    -Test {
        param($c)
        $major = 0; [void][int]::TryParse(($c.Status.Build -split '\.')[0], [ref]$major)
        $pp = Import-ToolData -Name 'product-patches.psd1'
        $entry = $null; if ($pp) { $entry = @($pp.WindowsSupport | Where-Object { [int]$_.Build -eq $major }) | Select-Object -First 1 }
        if (-not $entry) { return (NotAssessable "build $major is not in data\product-patches.psd1 WindowsSupport") }
        $end = [datetime]::ParseExact($entry.EndOfSupport, 'yyyy-MM-dd', $null)
        $days = [int]($end - (Get-Date)).TotalDays
        if ($days -lt 0) { return (Fail "$($entry.Name) support ended $($entry.EndOfSupport) ($(-$days) days ago)") }
        if ($days -lt 180) { return (Warn "$($entry.Name) support ends $($entry.EndOfSupport) (in $days days)") }
        return (Pass "$($entry.Name) supported until $($entry.EndOfSupport)")
    } -Fix 'Plan the upgrade or replacement before the end-of-support date (ISM-1501); Extended Security Updates are a stopgap, not compliance.'

New-Check -Id 'SEC-OS-08' -Console 'Security' -Group 'Operating system' -Title 'Latest or previous operating system release' -Ism 'ISM-1407' -ML 3 -Severity 'Medium' -Needs 'Status' `
    -Test {
        param($c)
        $major = 0; [void][int]::TryParse(($c.Status.Build -split '\.')[0], [ref]$major)
        if ($major -in 26100, 20348) { return (Pass "build $major is Server 2025 or 2022 (latest / previous release)") }
        if ($major -gt 0) { return (Fail "build $major is older than the previous Server release (2022)") }
        return (Warn 'the Windows build could not be read')   # "could not be read": not counted as non-compliant (R6-E-M2)
    } -Fix 'ISM-1407 (ML3): run the latest or the previous release of the operating system. Plan the migration.'

New-Check -Id 'SEC-OS-09' -Console 'Security' -Group 'Operating system' -Title 'Internet Explorer 11 disabled or removed' -Ism 'ISM-1654' -ML 1 -Severity 'Medium' -Needs 'Settings' `
    -Test {
        param($c)
        $feat = [string]$c.S['Feature:IE11']; $pol = [string]$c.S['IE11.DisabledByPolicy']
        if ($feat -in 'Disabled', 'DisabledWithPayloadRemoved', 'Absent') { return (Pass "IE11 feature state: $feat") }
        if ($pol -eq '1') { return (Pass 'IE11 disabled by policy (DisableInternetExplorerApp = 1)') }
        if ($feat -eq 'Unknown' -or -not $feat) { return (Warn "IE11 feature state could not be read; policy value '$pol'") }
        return (Fail "IE11 feature state $feat and not disabled by policy")
    } -Fix 'Disable-WindowsOptionalFeature -Online -FeatureName Internet-Explorer-Optional-amd64  or GPO: Admin Templates > Windows Components > Internet Explorer > Disable Internet Explorer 11 as a standalone browser = Enabled'

function Get-AppControlState {
    # Shared by the application-control checks: @{ Mode = 'Enforced'|'Audit'|'None'; Text; Scripts; Installers; Logs }
    param($c)
    $exe = [string]$c.S['AppLocker.Exe']; $msi = [string]$c.S['AppLocker.Msi']; $scr = [string]$c.S['AppLocker.Script']; $dll = [string]$c.S['AppLocker.Dll']
    $umci = [string]$c.S['DeviceGuard.UsermodeCodeIntegrity']
    $r = @{ Mode = 'None'; Text = ''; Scripts = $false; Installers = $false; Logs = $false }
    if ($umci -eq '2') { $r.Mode = 'Enforced'; $r.Text = "WDAC user-mode code integrity enforced ($($c.S['WDAC.PolicyFiles']) policy files)"; $r.Scripts = $true; $r.Installers = $true; $r.Logs = $true; return $r }
    if ($umci -eq '1') { $r.Mode = 'Audit'; $r.Text = 'WDAC user-mode code integrity in AUDIT mode'; return $r }
    # AppLocker could not be read (and WDAC is not on): Unknown, never "no application control" - the checks Warn (R6-E-M3)
    if ([string]$c.S['AppLocker.Service'] -like 'ERROR*') { $r.Mode = 'Unknown'; $r.Text = 'the application control state could not be read: ' + ([string]$c.S['AppLocker.Service']).Substring(7); return $r }
    $parts = @("Exe=$exe", "Msi=$msi", "Script=$scr", "Dll=$dll")
    $r.Text = 'AppLocker ' + ($parts -join ', ') + ", service $($c.S['AppLocker.Service'])"
    if ($exe -like 'Enabled;*' -and $exe -notlike '*;0 rules') { $r.Mode = 'Enforced' }
    elseif ($exe -like 'AuditOnly;*') { $r.Mode = 'Audit' }
    $r.Scripts = ($scr -like 'Enabled;*' -and $scr -notlike '*;0 rules')
    $r.Installers = ($msi -like 'Enabled;*' -and $msi -notlike '*;0 rules')
    $r.Logs = ([string]$c.S['AppLocker.Log.EXEandDLL'] -eq 'True')
    return $r
}

New-Check -Id 'SEC-AC-01' -Console 'Security' -Group 'Application control' -Title 'Application control on internet-facing servers' -Ism 'ISM-1490' -ML 2 -Severity 'High' -Needs 'Settings' -Applies 'internet-facing' `
    -Test { param($c) $s = Get-AppControlState $c; if ($s.Mode -eq 'Unknown') { return (Warn $s.Text) }; if ($s.Mode -eq 'Enforced') { return (Pass $s.Text) }; if ($s.Mode -eq 'Audit') { return (Warn $s.Text) }; return (Fail "no application control enforced: $($s.Text)") } `
    -Fix 'AppLocker (GPO: Security Settings > Application Control Policies > AppLocker, enforce Executable, Windows Installer, Script, DLL rules) or WDAC (Set-CIPolicy, enforced). ASD publishes recommended rules.'

New-Check -Id 'SEC-AC-02' -Console 'Security' -Group 'Application control' -Title 'Application control on servers' -Ism 'ISM-1656' -ML 3 -Severity 'Medium' -Needs 'Settings' `
    -Test { param($c) $s = Get-AppControlState $c; if ($s.Mode -eq 'Unknown') { return (Warn $s.Text) }; if ($s.Mode -eq 'Enforced') { return (Pass $s.Text) }; if ($s.Mode -eq 'Audit') { return (Warn $s.Text) }; return (Fail "no application control enforced: $($s.Text)") } `
    -Fix 'AppLocker or WDAC enforced (see SEC-AC-01). ML3 requires it on non-internet-facing servers too.'

New-Check -Id 'SEC-AC-03' -Console 'Security' -Group 'Application control' -Title 'Application control covers scripts and installers' -Ism 'ISM-1657' -ML 1 -Severity 'Medium' -Needs 'Settings' `
    -Test { param($c) $s = Get-AppControlState $c; if ($s.Mode -eq 'Unknown') { return (Warn $s.Text) }; if ($s.Mode -eq 'None') { return (Fail 'no application control at all') }; if ($s.Scripts -and $s.Installers) { return (Pass "scripts and installers covered ($($s.Mode))") }; return (Fail "scripts covered: $($s.Scripts), installers covered: $($s.Installers) - $($s.Text)") } `
    -Fix 'Add enforced AppLocker Script and Windows Installer rule collections (ISM-1657 lists executables, libraries, scripts, installers, compiled HTML, HTML applications, control panel applets).'

New-Check -Id 'SEC-AC-04' -Console 'Security' -Group 'Application control' -Title 'Application control events logged' -Ism 'ISM-1660' -ML 2 -Severity 'Low' -Needs 'Settings' `
    -Test { param($c) $s = Get-AppControlState $c; if ($s.Mode -eq 'Unknown') { return (Warn $s.Text) }; if ($s.Mode -eq 'None') { return (NotApplicable 'no application control to log') }; if ($s.Logs) { return (Pass 'AppLocker / Code Integrity event logs enabled') }; return (Warn 'AppLocker EXE and DLL log is disabled') } `
    -Fix 'wevtutil sl "Microsoft-Windows-AppLocker/EXE and DLL" /e:true  (and MSI and Script); forward both to the central log.'

New-Check -Id 'SEC-AV-01' -Console 'Security' -Group 'Malware defence' -Title 'Antivirus with real-time protection and current signatures' -Ism 'ISM-1417' -Severity 'High' -Needs 'Settings' `
    -Test {
        param($c)
        $rt = [string]$c.S['Defender.RealTime']; $age = [string]$c.S['Defender.SignatureAgeDays']; $mode = [string]$c.S['Defender.Mode']
        $agents = @(); if ($c.Agents -and $c.Agents.Reachable) { $agents = Get-AgentRows -Server $c.Server }
        $third = @($agents | Where-Object { $_.Installed -and $_.Running -and $_.Name -match 'Trellix Endpoint|CrowdStrike' })
        if ($third.Count -gt 0) { return (Pass ("{0} third-party endpoint agent(s) running" -f $third.Count) -Items @($third | ForEach-Object { "$($_.Name) $($_.Version) running" })) }
        if ($rt -eq 'True' -and $mode -ne 'Passive') {
            $a = 0
            if (-not [int]::TryParse($age, [ref]$a)) { return (Warn "Defender real-time on, but the signature age could not be read ('$age')") }
            if ($a -le 1) { return (Pass "Defender real-time on, signatures $a day(s) old, mode $mode") }
            return (Fail "Defender real-time on but signatures are $age day(s) old")
        }
        # what was not read is not "absent" (R6-E-M4): the Defender state, or the agents scan, missing = Warn, never Fail
        if ([string]$c.S['Defender.Installed'] -like 'ERROR*') { return (Warn ('the Defender state could not be read: ' + ([string]$c.S['Defender.Installed']).Substring(7))) }
        if (-not $c.Agents -or -not $c.Agents.Reachable) { return (Warn "Defender real-time protection is '$rt' (mode $mode), and the agents were not read - a third-party antivirus cannot be ruled out; check health (Agents) and audit again") }
        if ([string]$c.S['Defender.Installed'] -ne 'True') { return (Fail 'Defender not present and no third-party antivirus agent detected') }
        return (Fail "Defender real-time protection is '$rt' (mode $mode) and no third-party antivirus agent is running")
    } -Fix 'Enable real-time protection (Set-MpPreference -DisableRealtimeMonitoring $false) and signature updates, or confirm the third-party agent (data\soe-agents.psd1 names it) is installed and running.'

New-Check -Id 'SEC-AV-02' -Console 'Security' -Group 'Malware defence' -Title 'Endpoint detection and response (HIPS/EDR) present' -Ism 'ISM-1034' -Severity 'Medium' -Needs 'Settings', 'Inventory' `
    -Test {
        param($c)
        $agents = @(); if ($c.Agents -and $c.Agents.Reachable) { $agents = Get-AgentRows -Server $c.Server }
        $edr = @($agents | Where-Object { $_.Installed -and $_.Running -and $_.Name -match 'Trellix Endpoint|CrowdStrike|Rapid7|Qualys' })
        if ($edr.Count -gt 0) { return (Pass (($edr | ForEach-Object { $_.Name }) -join ', ')) }
        $sense = @($c.Inventory.Services | Where-Object { $_ -like 'Sense|*' -and $_ -like '*|Running|*' })
        if ($sense.Count -gt 0) { return (Pass 'Microsoft Defender for Endpoint (Sense) running') }
        return (Warn 'no EDR agent detected (only antivirus); ISM-1034 asks for HIPS/EDR on critical and high-value servers')
    } -Fix 'Onboard the server to Defender for Endpoint or deploy the EDR agent of your platform; add its detection rule to data\soe-agents.psd1.'

New-Check -Id 'SEC-FW-01' -Console 'Security' -Group 'Firewall' -Title 'Windows Firewall on for every profile, inbound blocked by default' -Ism 'ISM-1416' -Severity 'High' -Needs 'Settings' `
    -Test {
        param($c)
        $bad = @(); $text = @(); $unread = @()
        foreach ($p in 'Domain', 'Private', 'Public') {
            $v = [string]$c.S["Firewall.$p"]; $text += "$p $v"
            if (-not $v -or $v -like 'ERROR:*') { $unread += $p; continue }
            # DefaultInboundAction "NotConfigured" means no explicit policy - the Windows default, which is Block
            if ($v -notlike 'Enabled=True*' -or ($v -notlike '*Inbound=Block*' -and $v -notlike '*Inbound=NotConfigured*')) { $bad += $p }
        }
        if ($unread.Count -gt 0) { return (Warn ("firewall profile(s) {0} could not be read" -f ($unread -join ', ')) -Items $text) }
        if ($bad.Count -eq 0) { return (Pass 'all three profiles enabled with inbound Block' -Items $text) }
        return (Fail ("profile(s) {0} not enabled with inbound Block" -f ($bad -join ', ')) -Items $text)
    } -Fix 'GPO: Windows Defender Firewall with Advanced Security > each profile: Firewall state On, Inbound connections Block; allow only the ports the server serves.'

New-Check -Id 'SEC-CRD-01' -Console 'Security' -Group 'Credentials' -Title 'Local administrator password managed by LAPS' -Ism 'ISM-1685' -ML 2 -Severity 'High' -Needs 'Settings' -Applies 'member' `
    -Test { param($c) if ([string]$c.S['LAPS.Managed'] -eq 'True') { return (Pass "LAPS: Windows LAPS backup directory $($c.S['LAPS.Windows.BackupDirectory']) / legacy AdmPwd $($c.S['LAPS.Legacy.Enabled'])") }; return (Fail 'neither Windows LAPS nor legacy LAPS is configured') } `
    -Fix 'Deploy Windows LAPS (GPO: System > LAPS > Configure password backup directory = Active Directory) so every local administrator password is unique and rotated (ISM-1685).'

New-Check -Id 'SEC-CRD-02' -Console 'Security' -Group 'Credentials' -Title 'Local Administrators group membership' -Ism 'ISM-0445', 'ISM-1508' -ML 1 -Severity 'High' -Needs 'Settings' `
    -Test {
        param($c)
        $raw = [string]$c.S['LocalAdmins']
        if ($raw -like 'ERROR:*') { return (Warn ('the Administrators group could not be read - ' + $raw.Substring(7).Trim())) }
        $members = @(($raw -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($members.Count -eq 0) { return (Warn 'no member of the Administrators group was read (the group always holds at least the built-in Administrator)') }
        # judged on the name after the last backslash: net.exe prints NT AUTHORITY\Authenticated Users, CORP\Domain Computers ...
        $broad = @('Everyone', 'Authenticated Users', 'Users', 'Domain Users', 'Domain Computers', 'INTERACTIVE', 'NETWORK', 'ANONYMOUS LOGON', 'Guests', 'Domain Guests')
        $bad = @($members | Where-Object { $broad -contains ($_ -split '\\')[-1] })
        if ($bad.Count -gt 0) { return (Fail "broad groups in Administrators: $($bad -join ', ') (all members: $($members -join ', '))") }
        if ($members.Count -gt 10) { return (Warn "$($members.Count) members: $($members -join ', ')") }
        return (Pass "$($members.Count) members: $($members -join ', ')")
    } -Fix 'Remove broad groups; keep Administrators, the domain server-admins group and the LAPS-managed local account. Use dedicated privileged accounts (ISM-0445).'

New-Check -Id 'SEC-CRD-03' -Console 'Security' -Group 'Credentials' -Title 'Built-in Administrator renamed or disabled' -Ism 'ISM-0383' -Severity 'Medium' -Needs 'Settings' `
    -Test {
        param($c)
        $name = [string]$c.S['Administrator.Name']; $on = [string]$c.S['Administrator.Enabled']
        if (-not $name) { return (Warn 'built-in Administrator (SID -500) not read') }
        if ($on -eq 'False') { return (Pass "built-in Administrator ('$name') is disabled") }
        if ($name -ne 'Administrator') { return (Pass "built-in Administrator renamed to '$name' (enabled)") }
        return (Warn "built-in Administrator is enabled and still named 'Administrator'")
    } -Fix 'GPO: Security Options > Accounts: Rename administrator account, or Accounts: Administrator account status = Disabled (LAPS can manage a renamed account).'

New-Check -Id 'SEC-CRD-04' -Console 'Security' -Group 'Credentials' -Title 'Services do not run as plain domain user accounts' -Ism 'ISM-1619' -Severity 'Low' -Needs 'Inventory' `
    -Test {
        param($c)
        $plain = @()
        $localName = ''; if ($c.Inventory -and $c.Inventory.Computer) { $localName = [string]$c.Inventory.Computer } else { $localName = ([string]$c.Server -split '\.')[0] }
        foreach ($line in @($c.Inventory.Services)) {
            $f = $line -split '\|'; if ($f.Count -lt 5) { continue }
            $acct = $f[4]
            $isLocal = ($acct -like '.\*') -or ($localName -and $acct -like ($localName + '\*'))
            $isDomain = ($acct -match '^[^\\]+\\[^\\]+$' -and $acct -notmatch '^(NT AUTHORITY|NT SERVICE)\\' -and -not $isLocal) -or ($acct -match '^[^@\\\s]+@[^@\s]+$')
            if ($isDomain -and $acct -notmatch '\$$' -and $acct -notmatch '\$@') { $plain += "$($f[0]) ($acct)" }
        }
        if ($plain.Count -eq 0) { return (Pass 'no service runs as a plain domain user account') }
        return (Warn ("{0} service(s) on plain domain accounts (gMSA expected, ISM-1619)" -f $plain.Count) -Items $plain)
    } -Fix 'Create group Managed Service Accounts (New-ADServiceAccount) and point the services at them; a gMSA name ends with $ and needs no password management.'

New-Check -Id 'SEC-LOG-01' -Console 'Security' -Group 'Logging' -Title 'Security events forwarded to a central facility' -Ism 'ISM-0582' -Severity 'High' -Needs 'Settings' `
    -Test {
        param($c)
        $sm = [string]$c.S['EventForwarding.SubscriptionManager']
        if ($sm -and $sm -ne 'NotConfigured') { return (Pass "Windows Event Forwarding to $sm") }
        $agents = @(); if ($c.Agents -and $c.Agents.Reachable) { $agents = Get-AgentRows -Server $c.Server }
        $fwd = @($agents | Where-Object { $_.Installed -and $_.Running -and $_.Name -match 'Splunk|Monitoring Agent' })
        if ($fwd.Count -gt 0) { return (Pass (($fwd | ForEach-Object { "$($_.Name) running" }) -join ', ')) }
        if (-not $c.Agents -or -not $c.Agents.Reachable) { return (Warn 'no Windows Event Forwarding subscription, and the agents were not read - a forwarding agent cannot be ruled out (R6-E-M4)') }
        return (Fail 'no Windows Event Forwarding subscription and no forwarding agent detected')
    } -Fix 'Configure Windows Event Forwarding (GPO: Event Forwarding > Configure target Subscription Manager) or install the SIEM forwarder; add its detection rule to data\soe-agents.psd1.'

New-Check -Id 'SEC-LOG-05' -Console 'Security' -Group 'Logging' -Title 'Time service uses the domain or an NTP source' -Ism 'ISM-0988' -Severity 'Low' -Needs 'Settings' `
    -Test { param($c) $t = [string]$c.S['Time.Type']; if ($t -in 'NT5DS', 'NTP', 'AllSync') { return (Pass "W32Time type $t, source $($c.S['Time.Source'])") }; return (Warn "W32Time type '$t' (expected NT5DS for domain members or NTP)") } `
    -Fix 'w32tm /config /syncfromflags:domhier /update ; the Health console checks the actual offset.'

New-Check -Id 'SEC-PAT-01' -Console 'Security' -Group 'Patching' -Title 'Operating system patches applied within the ISM timeframe' -Ism 'ISM-1877', 'ISM-1694', 'ISM-1695', 'ISM-1696' -ML 1 -Severity 'High' -Needs 'Status' `
    -Test {
        param($c)
        $parts = $c.Status.Build -split '\.'
        $major = 0; $ubr = 0; [void][int]::TryParse($parts[0], [ref]$major); if ($parts.Count -gt 1) { [void][int]::TryParse($parts[1], [ref]$ubr) }
        $pp = Import-ToolData -Name 'product-patches.psd1'
        $ref = $null; if ($pp) { $ref = @($pp.Windows | Where-Object { [int]$_.Build -eq $major }) | Select-Object -First 1 }
        if (-not $ref -or -not $ref.Released -or [int]$ref.UBR -le 0) { return (NotAssessable "no reference cumulative update for build $major in data\product-patches.psd1 (as of $($pp.AsOf))") }
        if ($ubr -ge [int]$ref.UBR) { return (Pass "build $($c.Status.Build) is at or above $($ref.KB) ($($ref.Released))") }
        $days = [int]((Get-Date) - [datetime]::ParseExact($ref.Released, 'yyyy-MM-dd', $null)).TotalDays
        $class = Get-ServerClass -Name $c.Server
        $limit = 30; $rule = 'one month (ISM-1695/1696, non-internet-facing)'
        if ($class -eq 'internet-facing') { $limit = 14; $rule = 'two weeks (ISM-1694, internet-facing; 48 hours if an exploit exists, ISM-1877)' }
        if ($days -gt $limit) { return (Fail "$($ref.KB) released $($ref.Released), $days days ago, not installed (build $($c.Status.Build)); limit $rule") }
        return (Warn "$($ref.KB) released $($ref.Released), $days days ago, not yet installed; limit $rule")
    } -Fix 'Install the cumulative update from the O/S Patching console; tick the server as internet-facing on the Security profile tab so the shorter timeframe applies.'

foreach ($na in @(
    @('SEC-NA-01', 'Centralised event logging facility exists', 'ISM-1405', 0),
    @('SEC-NA-02', 'Administrative activities go through jump servers', 'ISM-1387', 2),
    @('SEC-NA-03', 'Privileged users use separate privileged operating environments', 'ISM-1380', 1),
    @('SEC-NA-04', 'Software register maintained', 'ISM-1493', 0),
    @('SEC-NA-05', 'Backups performed and retained', 'ISM-1511', 1),
    @('SEC-NA-06', 'Vulnerability scanner used for online services and operating systems', 'ISM-1698', 1),
    @('SEC-NA-07', 'Vulnerability scanner used for operating systems of internet-facing servers', 'ISM-1701', 1))) {
    New-Check -Id $na[0] -Console 'Security' -Group 'Not assessable from the server' -Title $na[1] -Ism $na[2] -ML $na[3] -Severity 'Low' -Needs @() `
        -Test { NotAssessable 'organisational control - record the evidence in the report or in tailoring' } `
        -Fix 'Evidence lives outside the server (SIEM, jump host design, backup system, scanner). Record it against this row in the report, or accept the gap in tailoring with a reason.'
}

# ---------------------------------------------------------------------
#  Resolver: profile applicability, tailoring, lights
# ---------------------------------------------------------------------
function Get-SecurityResolveContext {
    # What Resolve-SecurityRow reads for every row - the profile, its classification column, the ISM catalogue - fetched
    # once per server by Get-SecurityRows: three function calls per row x 122 rows x every server was a third of a cold repaint
    $prof = Get-SecurityProfile
    return @{ Profile = $prof; Column = (Get-ClassificationColumn -Classification ([string]$prof.classification)); Catalogue = (Get-IsmCatalogue) }
}

function Resolve-SecurityRow {
    param($Row, [hashtable]$Context = $null)   # $Context from Get-SecurityResolveContext; fetched here when a caller has none
    if (-not $Row.PSObject.Properties['Tailoring']) { $Row | Add-Member -NotePropertyName Tailoring -NotePropertyValue '' }
    if (-not $Context) { $Context = Get-SecurityResolveContext }
    $prof = $Context.Profile
    $col = $Context.Column
    $cat = $Context.Catalogue
    if ($Row.Ism -and $Row.Verdict -ne 'Error') {
        $ids = @($Row.Ism -split ' ' | Where-Object { $_ })
        $known = $false; $applies = $false
        foreach ($id in $ids) { $e = $cat[$id]; if ($e) { $known = $true; if ($e.$col) { $applies = $true } } }
        if ($known -and -not $applies) { $Row.Verdict = 'NotApplicable'; $Row.Light = 'Grey'; $Row.Note = "not applicable at classification $($prof.classification)"; return $Row }
    }
    # Every rule in force for this check on this server is recorded in $Row.Tailoring ("accepted; threshold 10 (review
    # overdue)") - the Servers view counts them, Server config shows them per cell, the report carries them.
    $downgrade = $false; $tokens = @()
    foreach ($rule in (Get-TailoringRules -Id $Row.Id -Server $Row.Server)) {
        $overdue = Test-TailoringOverdue -Rule $rule
        $tok = [string]$rule.action
        if ($tok -eq 'disable') { $tok = 'accepted'; if ($Row.Verdict -eq 'Pass') { $tok = 'accepted (not needed - passes)' } }   # the server was fixed since: nothing is accepted
        if ($tok -eq 'threshold') { $tok = 'threshold ' + [string]$rule.value }
        if ($overdue) { $tok += ' (review overdue)' }
        $tokens += $tok
        $Row.Tailoring = ($tokens -join '; ')
        switch ([string]$rule.action) {
            'disable' {
                if ($Row.Verdict -in 'Fail', 'Warn', 'NotAssessable') {
                    $Row.Verdict = 'RiskAccepted'; $Row.Light = 'Grey'
                    $Row.Note = "Risk accepted by $($rule.by) on $($rule.date): $($rule.reason) (review $($rule.review))"
                    if ($overdue) { $Row.Light = 'Amber'; $Row.Note += ' - REVIEW OVERDUE' }
                    return $Row
                }
            }
            'downgrade' { $downgrade = $true; $Row.Note = "downgraded to Amber by $($rule.by): $($rule.reason)"; if ($overdue) { $downgrade = $false; $Row.Note += ' - REVIEW OVERDUE, downgrade no longer applied' } }
            'threshold' { $Row.Note = "threshold tailored to $($rule.value) by $($rule.by): $($rule.reason)"; if ($overdue) { $Row.Note = "threshold $($rule.value) by $($rule.by) - REVIEW OVERDUE, the table's value applies again" } }
        }
    }
    switch ($Row.Verdict) {
        'Fail' {
            $target = 2; $parsed = 0   # a hand-edited profile may hold anything; 1..3 only, else the default
            if ([int]::TryParse([string]$prof.maturityTarget, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 3) { $target = $parsed }
            if ($Row.Severity -eq 'High' -or ($Row.ML -gt 0 -and $Row.ML -le $target)) { $Row.Light = 'Red' } else { $Row.Light = 'Amber' }
            if ($downgrade) { $Row.Light = 'Amber' }
        }
        'Warn' { $Row.Light = 'Amber' }
        'Error' { $Row.Light = 'Amber' }   # a check that could not run stays visible
        'Pass' { $Row.Light = 'Green' }
        default { $Row.Light = 'Grey' }
    }
    return $Row
}

function Get-SecurityRows {
    # All Security check rows for one server.  The three views and the report each ask for the same rows,
    # so they are kept until the next audit, refresh, or profile / tailoring change clears the cache.
    param([string]$Server)
    $ctx = Get-SecurityResolveContext   # once per server, not per row; the block below finds it up the call stack
    return (Get-CheckRows -Console 'Security' -Server $Server -Resolve { param($r) Resolve-SecurityRow -Row $r -Context $ctx })
}

function Test-SecurityCollected {
    # An audit is on record when the settings were read AND the security policy collector has a result (Get-ConsoleCoverage):
    # a Health check collects Settings too, and that alone is not an audit (field finding 2026-11-06)
    param([string]$Server)
    $s = Get-CollectorResult -Name 'Settings' -Server $Server
    return ([bool]($s -and $s.Reachable -and (Get-ConsoleCoverage -Console 'Security' -Server $Server).Complete))
}

function Get-TailoringSummary {
    # The Servers view's Tailoring cell: how many checks on this server have a rule in force, by action.
    param([object[]]$Rows)
    $hit = @($Rows | Where-Object { $_.PSObject.Properties['Tailoring'] -and $_.Tailoring })
    if ($hit.Count -eq 0) { return '' }
    $parts = @()
    foreach ($kind in 'accepted', 'downgrade', 'threshold') { $n = @($hit | Where-Object { $_.Tailoring -match $kind -and $_.Tailoring -notmatch ($kind + ' \(not needed') }).Count; if ($n) { $parts += ('{0} {1}' -f $n, $kind) } }
    $od = @($hit | Where-Object { $_.Tailoring -match 'overdue' }).Count
    $text = ('{0} check(s): {1}' -f $hit.Count, ($parts -join ', '))
    if ($od) { $text += ('; {0} review overdue' -f $od) }
    return $text
}

function Get-SecuritySummaryRows {
    param([string[]]$Servers)
    $rows = @()
    foreach ($name in $Servers) {
        $gname = (@(foreach ($sg in @(Get-ServerGroups -Name $name)) { [string]$sg.Name }) -join ', ')   # every group it is in
        $set = Get-CollectorResult -Name 'Settings' -Server $name
        $notAudited = 'not audited'; if (Test-RemoteDisabled -Name $name) { $notAudited = "not audited - marked 'winrm: no': import its self-check results (O/S Patching tab)" }
        if (-not $set) { $rows += [pscustomobject]@{ Server = $name; Group = $gname; Class = (Get-ServerClass -Name $name); Light = 'Grey'; 'Last checked' = ''; Red = ''; Amber = ''; Green = ''; Grey = ''; 'Pass rate' = ''; Tailoring = ''; 'Top red' = $notAudited; Cells = @{} }; continue }
        if (-not $set.Reachable) { $rows += [pscustomobject]@{ Server = $name; Group = $gname; Class = (Get-ServerClass -Name $name); Light = 'Grey'; 'Last checked' = (Format-LastChecked $set.Checked); Red = ''; Amber = ''; Green = ''; Grey = ''; 'Pass rate' = ''; Tailoring = ''; 'Top red' = 'unreachable: ' + $set.Error; Cells = @{ 'Last checked' = (Get-ResultAgeColour $set.Checked) } }; continue }
        # a Health check collects Settings too: without the security policy the row is PARTIAL - grey, no counts, no pass rate
        $cov = Get-ConsoleCoverage -Console 'Security' -Server $name
        if (-not $cov.Complete) { $rows += [pscustomobject]@{ Server = $name; Group = $gname; Class = (Get-ServerClass -Name $name); Light = 'Grey'; 'Last checked' = (Format-LastChecked $cov.Checked); Red = ''; Amber = ''; Green = ''; Grey = ''; 'Pass rate' = ''; Tailoring = ''; 'Top red' = (Get-PartialRowText -Coverage $cov -Button 'Security audit'); Cells = @{ 'Last checked' = 'LightGray' } }; continue }
        $checks = Get-SecurityRows -Server $name
        $c = Get-LightCounts -Rows $checks
        $assessable = $c.Red + $c.Amber + $c.Green
        $score = ''; if ($assessable -gt 0) { $score = [string][int][math]::Floor(100.0 * $c.Green / $assessable) + '%' }   # rounded down, as the compliance figures are
        $top = @($checks | Where-Object { $_.Light -eq 'Red' } | Select-Object -First 3 | ForEach-Object { $_.Title })
        $tail = Get-TailoringSummary -Rows $checks
        # the Last checked cell by its age; an audit whose latest attempt failed paints the last good one and says so first (14-State.ps1)
        $failedNow = Get-ResultFailure $set
        if ($failedNow) { $top = @(('LATEST AUDIT FAILED at ' + (Format-LastChecked $set.LastAttempt) + ': ' + $failedNow + ' - the row shows the audit of ' + (Format-LastChecked $set.Checked))) + @($top) }
        # Last checked = the oldest of the collectors the audit reads (Settings, SecurityPolicy): never fresher than its weakest input
        $rows += [pscustomobject]@{ Server = $name; Group = $gname; Class = (Get-ServerClass -Name $name); Light = (Get-WorstLight -Rows $checks); 'Last checked' = (Format-LastChecked $cov.Checked); Red = $c.Red; Amber = $c.Amber; Green = $c.Green; Grey = $c.Grey; 'Pass rate' = $score; Tailoring = $tail; 'Top red' = ($top -join '; '); Cells = @{ 'Last checked' = (Get-ResultAgeColour $cov.Checked) } }
    }
    # a server never called over WinRM (winrm: no): its name cell grey, in every console
    foreach ($r in $rows) { if (Test-RemoteDisabled -Name $r.Server) { $r.Cells['Server'] = 'LightGray' } }
    return $rows
}

function Get-SecurityControlRows {
    # One row per check across the audited servers.
    param([string[]]$Servers)
    $audited = @($Servers | Where-Object { Test-SecurityCollected -Server $_ })
    # every audited server's rows, indexed by check once: 122 checks x a pipeline over 600 rows was a second of every repaint
    $byId = @{}
    foreach ($s in $audited) {
        foreach ($r in (Get-SecurityRows -Server $s)) { $id = [string]$r.Id; if (-not $byId.ContainsKey($id)) { $byId[$id] = New-Object System.Collections.Generic.List[object] }; $byId[$id].Add($r) }
    }
    $rows = @()
    foreach ($chk in (Get-Checks -Console 'Security')) {
        $mine = @(); if ($byId.ContainsKey([string]$chk.Id)) { $mine = $byId[[string]$chk.Id].ToArray() }
        $c = Get-LightCounts -Rows $mine
        $redServers = @($mine | Where-Object { $_.Light -eq 'Red' } | ForEach-Object { $_.Server })
        $light = 'Grey'; if ($c.Red -gt 0) { $light = 'Red' } elseif ($c.Amber -gt 0) { $light = 'Amber' } elseif ($c.Green -gt 0) { $light = 'Green' }
        $rows += [pscustomobject]@{ Id = $chk.Id; Group = $chk.Group; Title = $chk.Title; ISM = ($chk.Ism -join ' '); ML = $(if ($chk.ML -gt 0) { "ML$($chk.ML)" } else { '' }); Severity = $chk.Severity; Light = $light; Red = $c.Red; Amber = $c.Amber; Green = $c.Green; Grey = $c.Grey; 'Servers red' = ($redServers -join ', ') }
    }
    return $rows
}

function Get-SecuritySettingsRows {
    # Raw values next to the expected ones, for the Settings view and the report.
    param([string[]]$Servers)
    $table = Get-SecuritySettingsTable
    # the table's expected value depends on the classification, not the server: worked out once per setting, not per cell
    $defs = @(foreach ($d in @($table.Settings)) { @{ Def = $d; Base = (Get-ExpectedForClassification -Def $d) } })
    $rows = @()
    foreach ($server in $Servers) {
        if (-not (Test-SecurityCollected -Server $server)) { continue }
        $values = @{}      # (not $S next to $s: PowerShell variable names are case-insensitive)
        $sets = @()
        $a = Get-CollectorResult -Name 'Settings' -Server $server; if ($a -and $a.Reachable) { $sets += , @($a.Lines) }
        $b = Get-CollectorResult -Name 'SecurityPolicy' -Server $server; if ($b -and $b.Reachable) { $sets += , @($b.Lines) }
        if ($sets.Count -gt 0) { $values = ConvertTo-SettingsTable -LineSets $sets }
        $verdicts = @{}
        foreach ($r in (Get-SecurityRows -Server $server)) { $verdicts[$r.Id] = $r }
        foreach ($x in $defs) {
            $d = $x.Def
            $actual = '(not collected)'
            if ($values.ContainsKey($d.Key)) { $actual = [string]$values[$d.Key] } elseif ($d.Key -like 'Right:*' -and $b -and $b.Reachable -and @($b.Errors).Count -eq 0) { $actual = '(no account holds it)' }
            $v = $verdicts[$d.Id]
            $base = [string]$x.Base
            $tailored = Get-TailoredExpected -Id $d.Id -Server $server -Default $base
            $exp = "$($d.Op) $base"; if ($tailored -ne $base) { $exp = "$($d.Op) $tailored (tailored)" }
            $rows += [pscustomobject]@{ Server = $server; Key = $d.Key; Actual = $actual; Expected = $exp; Check = $d.Id; Verdict = $(if ($v) { $v.Verdict } else { '' }); Light = $(if ($v) { $v.Light } else { 'Grey' }); Tailoring = $(if ($v) { [string]$v.Tailoring } else { '' }); Note = $(if ($v) { [string]$v.Note } else { '' }) }
        }
    }
    return $rows
}

function Get-SecurityDetailsHtml {
    # The double-click page for one server: one table per control group, the ISM wording under every red or amber row.
    param([string]$Server)
    $prof = Get-SecurityProfile
    $facts = @(@('Profile', [string]$prof.classification), @('Essential Eight target', "ML$($prof.maturityTarget)"), @('Server class', $(if (Get-ServerClass -Name $Server) { Get-ServerClass -Name $Server } else { 'member' })), @('ISM release', (Get-IsmRelease)))
    if (-not (Test-SecurityCollected -Server $Server)) { return (New-DetailsHtml -Title "Security audit: $Server" -Console 'Security' -Subtitle 'not audited yet (or unreachable) - press AUDIT' -Facts $facts) }
    $rows = Get-SecurityRows -Server $Server
    $c = Get-LightCounts -Rows $rows
    $set = Get-CollectorResult -Name 'Settings' -Server $Server
    $facts += @(@('Audited', $set.Checked.ToString('yyyy-MM-dd HH:mm:ss')), @('Lights', ('{0} red, {1} amber, {2} green, {3} grey' -f $c.Red, $c.Amber, $c.Green, $c.Grey)))
    $sections = @()
    foreach ($grp in ($rows | Group-Object Group)) {
        $table = @($grp.Group | ForEach-Object {
            $ism = $_.Ism; if ($_.ML -gt 0) { $ism += " (ML$($_.ML))" }
            $flagged = ($_.Light -in 'Red', 'Amber')
            [pscustomobject]@{ Light = $_.Light; Id = $_.Id; Check = $_.Title; ISM = $ism; Verdict = $_.Verdict; Evidence = $_.Evidence; Summary = $_.Summary; Items = $_.Items; Note = $_.Note
                'How to comply' = $(if ($flagged) { $_.Fix } else { '' }); 'The ISM says' = $(if ($flagged) { Get-IsmText -Id (($_.Ism -split ' ')[0]) } else { '' }) } })
        $sections += @{ Heading = $grp.Name; Rows = $table; Columns = @('Light', 'Id', 'Check', 'ISM', 'Verdict', 'Evidence', 'Note', 'How to comply', 'The ISM says') }
    }
    $gpoGaps = @(Get-GpoGapRows -Server $Server | Where-Object { $_.Gap })
    if ($gpoGaps.Count -gt 0) { $sections += @{ Heading = 'GPO recommendations'; Rows = $gpoGaps; Columns = @('Impact', 'Id', 'Title', 'Status', 'Now', 'Gpo', 'Value', 'Found', 'Note'); Note = 'The settings above that Group Policy does not set (or sets weaker, or does not enforce): the value now, the recommended GPO and value, and whether applying it would be felt on this server - Impact found (red), Check first (amber), No impact found / expected (blue), Not checked (grey). The whole picture is on the GPO recommendations page.' } }
    $sections += @(Get-LicensingDetailSections -Server $Server -Short)   # activation, KMS, CALs, RDSH (47-Licensing.ps1)
    $sp = Get-CollectorResult -Name 'SecurityPolicy' -Server $Server
    if ($sp -and $sp.Reachable -and @($sp.Errors).Count -gt 0) { $sections += @{ Heading = 'Policy collector errors'; Lines = @($sp.Errors); Note = 'auditpol and secedit need an administrator on the server; rows that depend on them show Amber with this reason.' } }
    return (New-DetailsHtml -Title "Security audit: $Server" -Subtitle 'every control with its evidence, the fix and the ISM wording' -Console 'Security' -Facts $facts -Sections $sections)
}

function Get-ControlDetailsHtml {
    # The Controls page double-click: one check across the servers shown.
    param([string]$Id, [string[]]$Servers)
    $chk = Get-Checks -Console 'Security' | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $chk) { return (New-DetailsHtml -Title "Control $Id" -Console 'Security' -Subtitle 'unknown check') }
    $facts = @(@('ISM', ($chk.Ism -join ' ')), @('ISM release', (Get-IsmRelease)), @('Essential Eight level', $(if ($chk.ML -gt 0) { "ML$($chk.ML)" } else { 'not an Essential Eight control' })), @('Severity', $chk.Severity), @('Group', $chk.Group), @('Collectors needed', ($chk.Needs -join ', ')), @('Applies to', $chk.Applies))
    $ismLines = @(); foreach ($ref in @($chk.Ism)) { $t = Get-IsmText -Id $ref; if ($t) { $ismLines += "$ref - $t" } }   # not $id: that is the parameter
    $perServer = @()
    foreach ($s in $Servers) {
        if (-not (Test-SecurityCollected -Server $s)) { $perServer += [pscustomobject]@{ Light = 'Grey'; Server = $s; Verdict = 'not audited'; Evidence = ''; Note = '' }; continue }
        $r = Get-SecurityRows -Server $s | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
        if ($r) { $perServer += [pscustomobject]@{ Light = $r.Light; Server = $s; Verdict = $r.Verdict; Evidence = $r.Evidence; Note = $r.Note } }
    }
    $sections = @(
        @{ Heading = 'What the ISM asks for'; Lines = $ismLines },
        @{ Heading = 'What this check looks at'; Text = $(if ($chk.Why) { $chk.Why } else { 'see the Code Tour, topic E4' }) },
        @{ Heading = 'How to comply'; Text = $chk.Fix },
        @{ Heading = 'Servers'; Rows = $perServer; Columns = @('Light', 'Server', 'Verdict', 'Evidence', 'Note') })
    return (New-DetailsHtml -Title "$($chk.Id)  $($chk.Title)" -Subtitle 'one control across the servers shown' -Console 'Security' -Facts $facts -Sections $sections)
}

function Export-SecurityReport {
    $servers = @(Get-GridAllKeys -Grid $script:Gui['SecurityGrid'])
    $prof = Get-SecurityProfile
    $summary = @(Get-SecuritySummaryRows -Servers $servers)
    $byServer = @(); foreach ($s in $servers) { if (Test-SecurityCollected -Server $s) { $byServer += Get-SecurityRows -Server $s } }
    $byControl = @(Get-SecurityControlRows -Servers $servers)
    $settings = @(Get-SecuritySettingsRows -Servers $servers)
    # a rule for a check id that no longer exists affects nothing: amber and said so, not listed as a decision in force
    $knownChecks = @{}; foreach ($c in (Get-Checks -Console 'Security')) { $knownChecks[[string]$c.Id] = $true }
    $tail = @((Get-SecurityTailoring).rules | ForEach-Object { $known = $knownChecks.ContainsKey([string]$_.check); [pscustomobject]@{ Check = $(if ($known) { $_.check } else { [string]$_.check + ' (no such check - the rule affects nothing)' }); Scope = $_.scope; Action = $_.action; Value = $_.value; Reason = $_.reason; By = $_.by; Date = $_.date; Review = $_.review; Light = $(if ($known) { 'Grey' } else { 'Amber' }) } })
    $gpoRows = @(foreach ($s in $servers) { Get-GpoGapRows -Server $s | Where-Object { $_.Gap } })
    $notes = @(
        ("Security profile: classification $($prof.classification), Essential Eight maturity target ML$($prof.maturityTarget); internet-facing servers: " + ($(if (@(Get-InternetFacingServers).Count -gt 0) { @(Get-InternetFacingServers) -join ', ' } else { 'none (tick them on the Security profile tab)' }))),
        "Lights: Red = Fail inside the maturity target or Severity High; Amber = other Fail, Warn, overdue acceptance; Green = Pass; Grey = not applicable, not assessable or risk accepted.",
        "Checks modelled on the $(Get-IsmCatalogueInfo). Expected settings table as of $((Get-SecuritySettingsTable).AsOf).")
    return (Export-ConsoleReport -Console 'Security' -Title 'Security audit report (ISM)' -Summary $summary -SummaryColumns @('Server', 'Group', 'Class', 'Light', 'Red', 'Amber', 'Green', 'Grey', 'Pass rate', 'Tailoring', 'Top red') -Notes $notes -Sections @(
        @{ Name = 'By server'; Rows = $byServer; Columns = @('Server', 'Id', 'Group', 'Title', 'Ism', 'ML', 'Severity', 'Verdict', 'Light', 'Tailoring', 'Evidence', 'Note', 'Fix') },
        @{ Name = 'By control'; Rows = $byControl; Columns = @('Id', 'Group', 'Title', 'ISM', 'ML', 'Severity', 'Light', 'Red', 'Amber', 'Green', 'Grey', 'Servers red') },
        @{ Name = 'Settings'; Rows = $settings; Columns = @('Server', 'Key', 'Actual', 'Expected', 'Check', 'Verdict', 'Tailoring', 'Light') },
        @{ Name = 'GPO recommendations'; Rows = $gpoRows; Columns = @('Server', 'Id', 'Title', 'Status', 'Now', 'Gpo', 'Value', 'Impact', 'Found', 'Impact evidence', 'Path') },
        @{ Name = 'Tailoring in force'; Rows = $tail; Columns = @('Check', 'Scope', 'Action', 'Value', 'Reason', 'By', 'Date', 'Review') }))
}

# ---------------------------------------------------------------------
#  Editors: profile, tailoring rule
# ---------------------------------------------------------------------
function Show-TailoringRuleEditor {
    param($Rule)
    $dlg = New-ToolkitDialogForm
    $dlg.Text = 'Tailoring rule (a recorded risk decision)'; $dlg.Size = New-Object System.Drawing.Size(640, 412); $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $y = 14
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = 'Check:'; $lbl.Location = New-Object System.Drawing.Point(12, $y); $lbl.AutoSize = $true
    $check = New-Object System.Windows.Forms.ComboBox; $check.Location = New-Object System.Drawing.Point(175, ($y - 3)); $check.Width = 435; $check.DropDownStyle = 'DropDownList'
    foreach ($chk in (Get-Checks -Console 'Security')) { [void]$check.Items.Add("$($chk.Id)  $($chk.Title)") }
    if ($Rule) { foreach ($i in $check.Items) { if ($i -like "$($Rule.check)  *") { $check.SelectedItem = $i } } } elseif ($check.Items.Count -gt 0) { $check.SelectedIndex = 0 }
    $y += 32
    $lbl2 = New-Object System.Windows.Forms.Label; $lbl2.Text = 'Scope:'; $lbl2.Location = New-Object System.Drawing.Point(12, $y); $lbl2.AutoSize = $true
    # kind + target instead of one flat list: a fleet of hundreds of servers is typed, not scrolled
    $kind = New-Object System.Windows.Forms.ComboBox; $kind.Location = New-Object System.Drawing.Point(175, ($y - 3)); $kind.Width = 110; $kind.DropDownStyle = 'DropDownList'
    foreach ($v in 'all', 'group', 'server') { [void]$kind.Items.Add($v) }
    $target = New-Object System.Windows.Forms.ComboBox; $target.Location = New-Object System.Drawing.Point(290, ($y - 3)); $target.Width = 320
    Set-ComboTypeAhead -Combo $target
    $script:Gui['Tips'].SetToolTip($target, 'Type part of the name - matching groups or servers are suggested.')
    $fillTarget = {
        $target.Items.Clear(); $target.Text = ''
        switch ([string]$kind.SelectedItem) {
            'group'  { foreach ($g in $script:Groups) { [void]$target.Items.Add($g.Name) }; $target.Enabled = $true }
            'server' { foreach ($s in (Get-UniqueNames (@($script:Groups) | ForEach-Object { $_.Servers }))) { [void]$target.Items.Add($s) }; $target.Enabled = $true }
            default  { $target.Enabled = $false }
        }
    }
    $kind.Add_SelectedIndexChanged($fillTarget)
    $kind.SelectedItem = 'all'
    # the kind in lower case: a hand-written "Group:Web tier" works in the resolver (-match ignores case), and the combo's
    # SelectedItem does not - left as it was, the editor would show "all" and OK would widen the rule to every server
    if ($Rule -and [string]$Rule.scope -match '^(group|server):(.+)$') { $kind.SelectedItem = $Matches[1].ToLower(); $target.Text = $Matches[2] }
    $y += 32
    $lbl3 = New-Object System.Windows.Forms.Label; $lbl3.Text = 'Action:'; $lbl3.Location = New-Object System.Drawing.Point(12, $y); $lbl3.AutoSize = $true
    $action = New-Object System.Windows.Forms.ComboBox; $action.Location = New-Object System.Drawing.Point(175, ($y - 3)); $action.Width = 200; $action.DropDownStyle = 'DropDownList'
    foreach ($v in 'disable', 'downgrade', 'threshold') { [void]$action.Items.Add($v) }
    $action.SelectedItem = $(if ($Rule) { [string]$Rule.action } else { 'disable' })
    $script:Gui['Tips'].SetToolTip($action, 'disable = risk accepted (grey); downgrade = Red becomes Amber; threshold = another expected value')
    $y += 32
    $fields = @{}
    foreach ($spec in @(@('value', 'Value (threshold only):'), @('reason', 'Reason (required):'), @('by', 'Decided by:'), @('date', 'Date (yyyy-MM-dd):'), @('review', 'Review date (yyyy-MM-dd):'))) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $spec[1]; $l.Location = New-Object System.Drawing.Point(12, $y); $l.AutoSize = $true
        $t = New-Object System.Windows.Forms.TextBox; $t.Location = New-Object System.Drawing.Point(175, ($y - 3)); $t.Width = 435
        if ($Rule -and $Rule.PSObject.Properties[$spec[0]]) { $t.Text = [string]$Rule.($spec[0]) }
        $dlg.Controls.Add($l); $dlg.Controls.Add($t); $fields[$spec[0]] = $t
        $y += 32
    }
    if (-not $Rule) { $fields['by'].Text = Get-OperatorIdentity; $fields['date'].Text = Get-Date -Format 'yyyy-MM-dd'; $fields['review'].Text = (Get-Date).AddMonths(6).ToString('yyyy-MM-dd') }
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.Location = New-Object System.Drawing.Point(420, ($y + 6)); $ok.Size = New-Object System.Drawing.Size(90, 30); $ok.DialogResult = 'OK'
    $cancel = New-Object System.Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Location = New-Object System.Drawing.Point(520, ($y + 6)); $cancel.Size = New-Object System.Drawing.Size(90, 30); $cancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($lbl, $check, $lbl2, $kind, $target, $lbl3, $action, $ok, $cancel)); $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    $result = $null
    if ($dlg.ShowDialog($script:Gui['Form']) -eq 'OK') {
        $scopeText = 'all'
        if ([string]$kind.SelectedItem -ne 'all') { $scopeText = ('{0}:{1}' -f $kind.SelectedItem, $target.Text.Trim()) }
        if ($null -eq $check.SelectedItem) { $null = Show-PatcherMessage -Text ("The rule names a check that no longer exists ('{0}'); pick a check, or remove the rule." -f $(if ($Rule) { [string]$Rule.check } else { '' })) -Icon 'Warning' }
        elseif (-not $fields['reason'].Text.Trim()) { $null = Show-PatcherMessage -Text 'A reason is required - this is a recorded risk decision.' -Icon 'Warning' }
        elseif ([string]$action.SelectedItem -eq 'threshold' -and -not $fields['value'].Text.Trim()) { $null = Show-PatcherMessage -Text 'A threshold rule needs the value it approves (Value).' -Icon 'Warning' }
        elseif (@($fields['date'].Text.Trim(), $fields['review'].Text.Trim()) | Where-Object { $_ -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not ([datetime]::TryParseExact($_, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, 'None', [ref][datetime]::MinValue)) }) { $null = Show-PatcherMessage -Text 'Date and review date must be real dates written yyyy-MM-dd, e.g. 2027-04-20.' -Icon 'Warning' }
        elseif ([string]$kind.SelectedItem -ne 'all' -and -not $target.Text.Trim()) { $null = Show-PatcherMessage -Text 'Name the group or server the rule applies to (or choose scope "all").' -Icon 'Warning' }
        else {
            $id = ([string]$check.SelectedItem -split '  ')[0]
            $result = New-TailoringRule -Check $id -Scope $scopeText -Action ([string]$action.SelectedItem) -Value $fields['value'].Text.Trim() -Reason $fields['reason'].Text.Trim() -By $fields['by'].Text.Trim() -Date $fields['date'].Text.Trim() -Review $fields['review'].Text.Trim()
        }
    }
    $dlg.Dispose()
    return $result
}

# ---------------------------------------------------------------------
#  The tab: Servers | Controls | Server config | Tailoring | Settings
# ---------------------------------------------------------------------
function Update-SecurityConfigServers {
    # The Server config page's tick list: the servers shown on the Servers page, ticks kept across refreshes.
    # A NEW list of servers (first fill, another group) starts with every server ticked when there are 8 or fewer;
    # the same list keeps whatever the user ticked - even nothing.
    param([string[]]$Servers)
    $st = $script:Gui['ConfigTicks']; if (-not $st) { return }
    $Servers = @($Servers)
    $sameNames = ((@($st.Names) -join '|') -eq ($Servers -join '|'))
    $overlap = @($Servers | Where-Object { $st.Ticks.ContainsKey($_) -and $st.Ticks[$_] }).Count
    $tickAll = ((-not $sameNames) -and $overlap -eq 0 -and $Servers.Count -le 8)
    if ($tickAll) { $st.Ticks = @{} }
    Set-TickListNames -State $st -Names $Servers -DefaultTicked $tickAll
    Update-SecurityConfigGrid
}

function Update-SecurityConfigGrid {
    # The Server config page: one row per setting, one column per ticked server, each cell coloured by its verdict
    # against data\security-settings.psd1 (tailoring included, as in the reports).  -Servers overrides the tick list
    # (the ItemCheck handler passes the state the list is about to have).
    #   "Include tailoring": each cell also names the rule in force for that server ([accepted], [threshold 10] ...),
    #   the Expected column shows a tailored value, and a row whose servers differ only in tailoring counts as a
    #   difference.  Off: the raw values only.
    #   "Differences only" keeps the rows that differ between the ticked servers that have been audited.
    param([string[]]$Servers)
    $grid = $script:Gui['SecurityConfigGrid']; if (-not $grid) { return }
    if ($null -eq $Servers) { $Servers = @(Get-TickListChecked -State $script:Gui['ConfigTicks']) }
    $Servers = @($Servers)
    $capNote = ''; $maxCols = [int]$script:Config.MaxConfigColumns
    if ($maxCols -gt 0 -and $Servers.Count -gt $maxCols) { $capNote = (' - the first {0} of {1} ticked; untick some to see others' -f $maxCols, $Servers.Count); $Servers = @($Servers[0..($maxCols - 1)]) }
    $filter = [string]$script:Gui['ConfigFilter'].Text
    $diffOnly = [bool]$script:Gui['ConfigDiffOnly'].Checked
    $withTailoring = $true; if ($script:Gui['ConfigTailoring']) { $withTailoring = [bool]$script:Gui['ConfigTailoring'].Checked }
    # every setting of the table is a row, so an un-audited server still shows the list with "(not audited)" cells
    $table = Get-SecuritySettingsTable
    $byKey = [ordered]@{}
    foreach ($d in @($table.Settings)) { if (-not $byKey.Contains($d.Key)) { $byKey[$d.Key] = @{ Expected = "$($d.Op) $(Get-ExpectedForClassification -Def $d)"; Check = $d.Id; Cells = @{} } } }
    foreach ($r in @(Get-SecuritySettingsRows -Servers $Servers)) {
        if (-not $byKey.Contains($r.Key)) { $byKey[$r.Key] = @{ Expected = $r.Expected; Check = $r.Check; Cells = @{} } }
        $byKey[$r.Key].Cells[$r.Server] = $r
    }
    $grid.BeginUpdate()
    $grid.Items.Clear(); $grid.Columns.Clear()
    [void]$grid.Columns.Add('Setting', 270); [void]$grid.Columns.Add('Expected', 170); [void]$grid.Columns.Add('Check', 90)
    for ($i = 0; $i -lt $Servers.Count; $i++) { $col = $grid.Columns.Add($Servers[$i], 190); if ($i -eq $Servers.Count - 1) { $col.Tag = 'fill:190' } }
    $shown = 0; $differ = 0; $byTailoring = 0; $tailoredRows = 0
    foreach ($key in $byKey.Keys) {
        $e = $byKey[$key]
        if ($filter -and $key.IndexOf($filter, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }   # plain text: a typed '[' is not a wildcard
        # compare only the servers that have values (a server never audited is not "different")
        $vals = @(); $tails = @(); $exps = @()
        foreach ($s in $Servers) { $c = $e.Cells[$s]; if ($c) { $vals += [string]$c.Actual; $tails += [string]$c.Tailoring; $exps += [string]$c.Expected } }
        $valueDiff = (@($vals | Select-Object -Unique).Count -gt 1)
        $tailDiff = $withTailoring -and (@($tails | Select-Object -Unique).Count -gt 1)
        $isDiff = $valueDiff -or $tailDiff
        if ($isDiff) { $differ++; if (-not $valueDiff) { $byTailoring++ } }
        if (@($tails | Where-Object { $_ }).Count -gt 0) { $tailoredRows++ }
        if ($diffOnly -and -not $isDiff) { continue }
        $item = New-Object System.Windows.Forms.ListViewItem($key)
        $item.UseItemStyleForSubItems = $false
        $expText = [string]$e.Expected
        if ($withTailoring) { $tailoredExp = @($exps | Where-Object { $_ -like '*(tailored)' } | Select-Object -Unique); if ($tailoredExp.Count -gt 0) { $expText = ('{0}; tailored on {1} server(s)' -f $e.Expected, @($exps | Where-Object { $_ -like '*(tailored)' }).Count) } }
        [void]$item.SubItems.Add($expText); [void]$item.SubItems.Add([string]$e.Check)
        $tip = @()
        foreach ($s in $Servers) {
            $c = $e.Cells[$s]
            if ($c) {
                $text = [string]$c.Actual
                if ($withTailoring -and $c.Tailoring) { $text += '  [' + $c.Tailoring + ']' }
                $sub = $item.SubItems.Add($text); $sub.BackColor = (Get-LightColour $c.Light)
                $line = ('{0}: {1}' -f $s, $c.Verdict)
                if ($withTailoring -and $c.Note) { $line += ' - ' + $c.Note }
                $tip += $line
            }
            else { $sub = $item.SubItems.Add('(not audited)'); $sub.BackColor = 'WhiteSmoke'; $sub.ForeColor = 'Gray' }
        }
        $item.ToolTipText = ($tip -join "`n")
        [void]$grid.Items.Add($item); $shown++
    }
    $grid.EndUpdate()
    Resize-GridFillColumn -Grid $grid
    $text = ('{0} setting(s) shown for {1} server(s); {2} differ between them' -f $shown, $Servers.Count, $differ)
    if ($withTailoring) { $text += ('{0}; {1} have a tailoring rule in force' -f $(if ($byTailoring) { " ($byTailoring by tailoring only)" } else { '' }), $tailoredRows) }
    $text += $capNote
    if ($Servers.Count -eq 0) { $text = 'tick one or more servers on the left' }
    $script:Gui['ConfigCount'].Text = $text
}

function Get-InternetFacingServers {
    # Every loaded server whose class in force is internet-facing (its own line, else its group's directive).
    $out = @()
    foreach ($g in @($script:Groups)) { foreach ($s in @($g.Servers)) { if ((Get-ServerClass -Name $s) -eq 'internet-facing') { $out += $s } } }
    return @(Get-UniqueNames $out)
}

function Save-SecurityProfileFromPage {
    # The Security profile page's Save button: the network profile to security\profile.json, and the internet-facing ticks onto
    # the servers' own group-file lines - only where the tick differs from the class in force.  A server whose group
    # directive ("# class: internet-facing") already gives what the tick says gets no entry of its own (an existing one
    # is removed), so removing the directive later still works; unticking such a server writes "; class: member".
    $prof = Get-SecurityProfile
    $prof.classification = [string]$script:Gui['SecProfileClass'].SelectedItem
    $prof.maturityTarget = [int]$script:Gui['SecProfileML'].SelectedItem
    $prof.note = $script:Gui['SecProfileNote'].Text
    Save-SecurityProfile -SecurityProfile $prof
    $st = $script:Gui['SecProfileTicks']; $changed = 0; $failed = 0
    foreach ($name in @($st.Names)) {
        $g = Get-ServerGroup -Name $name; if (-not $g) { continue }
        $own = ''
        if ($g.PSObject.Properties['Attributes'] -and $g.Attributes) { $a = $g.Attributes[$name.ToLower()]; if ($a -and $a['class']) { $own = [string]$a['class'] } }
        $ticked = [bool]$st.Ticks[$name]
        $groupIf = ($g.Class -eq 'internet-facing')
        if ($ticked) { $want = $(if ($groupIf) { '' } else { 'internet-facing' }) } else { $want = $(if ($groupIf) { 'member' } else { '' }) }
        if ($want -eq $own) { continue }
        try { Set-ServerAttribute -Server $name -Key 'class' -Value $want; $changed++ }
        catch { $failed++; Write-PatchLog "$name - the class entry was not written: $(Get-ShortError $_)" 'ERROR' }
    }
    if ($changed -gt 0) { Get-PatchGroups | Out-Null; Clear-CheckRowCache; Write-PatchLog ("Internet-facing setting written for {0} server line(s)" -f $changed) 'OK' }
    Update-SecurityProfilePage -Force
}

function Update-SecurityProfilePage {
    # Keeps the Security profile page in step with the files.  The tick list is rebuilt from the class in force whenever the group
    # files were (re)loaded - a hand edit plus Reload shows up here - or after a save (-Force); otherwise unsaved ticks
    # survive a repaint.  The classification and maturity boxes are reloaded when profile.json changed on disk.
    param([switch]$Force)
    $st = $script:Gui['SecProfileTicks']; if (-not $st) { return }
    $prof = Get-SecurityProfile
    $names = @(Get-UniqueNames (@($script:Groups) | ForEach-Object { $_.Servers }))
    $reloaded = -not [object]::ReferenceEquals($script:Gui['SecProfileGroupsRef'], $script:Groups)
    if ($Force -or $reloaded -or (($names -join '|') -ne (@($st.Names) -join '|'))) {
        $st.Ticks = @{}
        foreach ($s in $names) { $st.Ticks[$s] = ((Get-ServerClass -Name $s) -eq 'internet-facing') }
        Set-TickListNames -State $st -Names $names
        $script:Gui['SecProfileGroupsRef'] = $script:Groups
    }
    $path = Get-SecurityProfilePath
    $fileStamp = ''; if (Test-Path -LiteralPath $path) { $fileStamp = [string](Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks }
    if ($Force -or $fileStamp -ne [string]$script:Gui['SecProfileStamp']) {
        if ($script:Gui['SecProfileClass'].Items.Contains([string]$prof.classification)) { $script:Gui['SecProfileClass'].SelectedItem = [string]$prof.classification }
        if ($script:Gui['SecProfileML'].Items.Contains([string]$prof.maturityTarget)) { $script:Gui['SecProfileML'].SelectedItem = [string]$prof.maturityTarget }
        $script:Gui['SecProfileNote'].Text = [string]$prof.note
        $script:Gui['SecProfileStamp'] = $fileStamp
    }
    $ifs = @(Get-InternetFacingServers)
    $state = 'not saved yet - the defaults apply (PROTECTED, ML2) until you press Save settings'
    if ($fileStamp) { $state = 'saved ' + (Get-Item -LiteralPath $path).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
    $script:Gui['SecProfileStatus'].Text = ('In force: classification {0}, Essential Eight target ML{1} (security\profile.json {2}).  Internet-facing: {3}.  Checks modelled on the {4}.' -f $prof.classification, $prof.maturityTarget, $state, $(if ($ifs.Count -gt 0) { $ifs -join ', ' } else { 'no server' }), (Get-IsmCatalogueInfo))
}

function Update-SecurityGrids {
    $grid = $script:Gui['SecurityGrid']
    if (-not $grid) { return }
    $servers = @(Get-UniqueNames (Get-GroupRows -Combo $script:Gui['SecurityGroupCombo'] | ForEach-Object { $_.Server }))
    $rows = @(Get-SecuritySummaryRows -Servers $servers)
    Set-GridRows -Grid $grid -Rows $rows -RowColour { param($r) Get-LightColour $r.Light } -ToolTipProperty 'Top red' -CellColourProperty 'Cells'
    $prof = Get-SecurityProfile
    $script:Gui['SecurityCount'].Text = ('{0} server(s): {1} red, {2} amber, {3} green  |  profile {4}, target ML{5}  |  checks modelled on the ISM of {6}' -f $rows.Count, @($rows | Where-Object { $_.Light -eq 'Red' }).Count, @($rows | Where-Object { $_.Light -eq 'Amber' }).Count, @($rows | Where-Object { $_.Light -eq 'Green' }).Count, $prof.classification, $prof.maturityTarget, (Get-IsmRelease))
    Set-GridRows -Grid $script:Gui['SecurityControlGrid'] -Rows @(Get-SecurityControlRows -Servers $servers) -RowColour { param($r) Get-LightColour $r.Light } -ToolTipProperty 'Servers red' -NoKeepChecks
    Update-SecurityConfigServers -Servers $servers
    Update-SecurityGpoGrid -Servers $servers
    Update-SecurityDashboard -Servers $servers
    Update-SecurityProfilePage
    Update-TailoringGrid
}

function Update-TailoringGrid {
    $grid = $script:Gui['TailoringGrid']
    if (-not $grid) { return }
    $rows = @((Get-SecurityTailoring).rules | ForEach-Object { [pscustomobject]@{ Check = $_.check; Scope = $_.scope; Action = $_.action; Value = $_.value; Reason = $_.reason; By = $_.by; Date = $_.date; Review = $_.review; Rule = $_ } })
    Set-GridRows -Grid $grid -Rows $rows -NoKeepChecks -RowColour { param($r) if (Test-TailoringOverdue -Rule $r.Rule) { 'LemonChiffon' } else { 'White' } }
}

function New-SecurityConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Security' -Text 'Security'
    $pages = New-Object System.Windows.Forms.TabControl; $pages.Dock = 'Fill'
    $tab.Controls.Add($pages)
    $pageServers = New-Object System.Windows.Forms.TabPage; $pageServers.Text = 'Servers'
    $pageControls = New-Object System.Windows.Forms.TabPage; $pageControls.Text = 'Controls'
    $pageConfig = New-Object System.Windows.Forms.TabPage; $pageConfig.Text = 'Server config'
    $pageGpo = New-Object System.Windows.Forms.TabPage; $pageGpo.Text = 'GPO recommendations'
    $pageTailoring = New-Object System.Windows.Forms.TabPage; $pageTailoring.Text = 'Tailoring (risk decisions)'
    $pageSettings = New-Object System.Windows.Forms.TabPage; $pageSettings.Text = 'Security profile'
    $pages.TabPages.AddRange(@($pageServers, $pageControls, $pageConfig, $pageGpo, $pageTailoring, $pageSettings))
    # no explainer text on the pages: what each shows is the tool tip of its tab (and of its controls)
    $pages.ShowToolTips = $true
    $pageServers.ToolTipText = "One row per server, its checks counted by light.`nRed = a failure inside the Essential Eight target or a High-severity control; Amber = other failures, warnings, overdue risk acceptances, a check that could not run; Green = pass; Grey = not applicable at this classification, not assessable from the server, or risk accepted.`nPass rate = Green of (Red + Amber + Green): risk-accepted controls are left out, unread ones count against it.`nDouble-click a server for every check with its evidence, the ISM text and the fix.`nBelow the divider: compliance of the servers shown and of every group - there a risk-accepted control counts as compliant and an unread one is left out, so its percentage is not the Pass rate."
    $pageControls.ToolTipText = "One row per check across the servers shown on the Servers page.`nDouble-click a row for the servers that fail it and the ISM wording."
    $pageConfig.ToolTipText = "The raw audit policy, security policy and hardening values of each ticked server, one row per setting.`nEach cell coloured by its verdict against data\security-settings.psd1: green = as expected, red = not, amber = warning or unreadable, grey = not applicable.`nHover a row for the verdicts."
    $pageGpo.ToolTipText = "One row per security setting that Group Policy is missing, sets weaker, or does not enforce on the servers shown.`nImpact - would applying it break something in use? Impact found = current use on the servers named (SMB1 clients, NTLMv1 or Basic logons ...) - keep them out of the GPO until resolved; Check first = a check could not tell, or there is no automatic check; No impact found / expected = apply it; Not checked = press Check impact; Enforced (green) = a GPO already sets it.`nNow = the value on the servers today. Double-click a row for every server.`nNothing is changed: GPOs are edited in Group Policy Management, under a change record."
    $pageTailoring.ToolTipText = "A rule records a risk decision: disable = accept (grey), downgrade = Red becomes Amber, threshold = a different expected value.`nScope: all, group:<name> or server:<name>. Yellow rows have passed their review date. Double-click to edit."
    $pageSettings.ToolTipText = "The network's classification and Essential Eight target, and which servers face the internet."
    New-SecurityGpoPage -Page $pageGpo   # 45-Security-Gpo.ps1

    # ---- Servers page ----
    # no Light column (the row colour says it) and no Class column (the class is on the server's page and in the reports) - owner's ask 2026-11-06
    $grid = New-ConsoleGrid -Columns @(@{ Name = 'Server'; Width = 180 }, @{ Name = 'Group'; Width = 100 }, @{ Name = 'Last checked'; Width = 105 }, @{ Name = 'Red'; Width = 40 }, @{ Name = 'Amber'; Width = 50 }, @{ Name = 'Green'; Width = 50 }, @{ Name = 'Grey'; Width = 45 }, @{ Name = 'Pass rate'; Width = 65 }, @{ Name = 'Tailoring'; Width = 210 }, @{ Name = 'Top red'; Width = 420; Fill = $true })
    $grid.Add_DoubleClick({   # $this = the grid; a local such as $grid is gone by the time the event fires
        if ($script:Gui['Busy']) { Write-PatchLog 'Busy - details are available again when the current action finishes' 'WARN'; return }
        if ($this.SelectedItems.Count -gt 0) { $n = $this.SelectedItems[0].Text; Show-DetailsWindow -Title "Security audit: $n" -Html (Get-SecurityDetailsHtml -Server $n) }
    })
    $count = New-Object System.Windows.Forms.Label; $count.Dock = 'Top'; $count.Height = 20; $count.ForeColor = 'DimGray'; $count.Padding = New-Object System.Windows.Forms.Padding(4, 3, 0, 0)
    # the grid above a divider, the compliance dashboard below it (46-Security-Compliance.ps1); the dashboard keeps its
    # height when the window grows, the grid takes the rest
    $srvSplit = New-Object System.Windows.Forms.SplitContainer; $srvSplit.Dock = 'Fill'; $srvSplit.Orientation = 'Horizontal'; $srvSplit.FixedPanel = 'Panel2'
    $srvSplit.Panel1.Controls.Add($grid); $srvSplit.Panel1.Controls.Add($count); $grid.BringToFront()   # the row count sits above the grid
    New-SecurityDashboard -Panel $srvSplit.Panel2
    $script:Gui['SecurityServersSplit'] = $srvSplit
    $pageServers.Controls.Add($srvSplit)
    $pageServers.Add_Resize({
        # the divider's first place: the dashboard's charts in full; afterwards wherever the operator drags it
        $s = $script:Gui['SecurityServersSplit']
        # a short page (a 1366 x 768 screen) still gets a usable share - the charts scroll - never the 46-px strip a SplitContainer starts with
        if (-not $script:Gui['SecDashPlaced'] -and $s.Height -gt 200) { try { $want = $s.Height - 400; if ($want -lt 160) { $want = [int]($s.Height * 0.5) }; $s.SplitterDistance = $want; $script:Gui['SecDashPlaced'] = $true } catch { } }
    })
    $script:Gui['SecurityCount'] = $count
    $script:Gui['SecurityGrid'] = $grid
    $toolbar = New-ConsoleToolbar -Tab $pageServers
    $combo = New-GroupPicker -Toolbar $toolbar -OnChange { Update-SecurityGrids }
    $script:Gui['SecurityGroupCombo'] = $combo
    $toolbar.Controls.Add((New-GuiButton -Text 'AUDIT (ticked or all)' -X 235 -Y 8 -W 170 -Colour 'LightSkyBlue' -ReadOnly -Tip 'Status + Inventory + Agents + Settings + SecurityPolicy (auditpol, secedit) + Group Policy + Licensing collectors. Read-only, needs admin on the servers. The impact checks of the GPO recommendations run from that page (Check impact).' -OnClick {
        Invoke-GuiAction -Name 'Security audit' -ReadOnly -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SecurityGrid'])
            if ($servers.Count -eq 0) { $servers = @(Get-GridAllKeys -Grid $script:Gui['SecurityGrid']) }
            if ($servers.Count -eq 0) { Show-GuiNotice 'No servers in the list.'; return }
            Invoke-SecurityAudit -ComputerName $servers
            $rows = @(Get-SecuritySummaryRows -Servers $servers)
            Write-PatchLog ("AUDIT by {0}: {1} server(s) - {2} red, {3} amber, {4} green" -f (Get-OperatorIdentity), $servers.Count, @($rows | Where-Object { $_.Light -eq 'Red' }).Count, @($rows | Where-Object { $_.Light -eq 'Amber' }).Count, @($rows | Where-Object { $_.Light -eq 'Green' }).Count) 'INFO'
        }
    }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Tick all' -X 410 -Y 8 -W 70 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['SecurityGrid'] -Checked $true }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Untick all' -X 485 -Y 8 -W 70 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['SecurityGrid'] -Checked $false }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Report (HTML + CSV)' -X 560 -Y 8 -W 150 -ReadOnly -OnClick {
        Invoke-GuiAction -Name 'Security report' -ReadOnly -Action { Show-ReportDone -Report (Export-SecurityReport) }
    }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Open reports folder' -X 715 -Y 8 -W 140 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Open reports folder' -ReadOnly -Action { Open-ReportFolder } }))
    # the row count label sits above the grid (see the grid block); the light colours are its tool tip, as the page tab's
    $script:Gui['Tips'].SetToolTip($count, $pageServers.ToolTipText)
    $srvSplit.BringToFront()

    # ---- Controls page ----
    $cgrid = New-ConsoleGrid -NoCheckBoxes -Columns @(@{ Name = 'Id'; Width = 95 }, @{ Name = 'Group'; Width = 150 }, @{ Name = 'Title'; Width = 380 }, @{ Name = 'ISM'; Width = 150 }, @{ Name = 'ML'; Width = 40 }, @{ Name = 'Severity'; Width = 60 }, @{ Name = 'Light'; Width = 50 }, @{ Name = 'Red'; Width = 40 }, @{ Name = 'Amber'; Width = 50 }, @{ Name = 'Green'; Width = 50 }, @{ Name = 'Grey'; Width = 45 }, @{ Name = 'Servers red'; Width = 300; Fill = $true })
    $cgrid.Add_DoubleClick({
        if ($script:Gui['Busy']) { Write-PatchLog 'Busy - details are available again when the current action finishes' 'WARN'; return }
        if ($this.SelectedItems.Count -gt 0) { $id = $this.SelectedItems[0].Text; $servers = @(Get-UniqueNames (Get-GroupRows -Combo $script:Gui['SecurityGroupCombo'] | ForEach-Object { $_.Server })); Show-DetailsWindow -Title "Control $id" -Html (Get-ControlDetailsHtml -Id $id -Servers $servers) }
    })
    $pageControls.Controls.Add($cgrid); $script:Gui['SecurityControlGrid'] = $cgrid

    # ---- Server config page: one row per setting, one column per ticked server (compare, or look at one) ----
    $cfgTicks = New-TickList -Title 'Servers to show' -OnChange { Update-SecurityConfigGrid }
    $cfgBar = New-Object System.Windows.Forms.Panel; $cfgBar.Dock = 'Top'; $cfgBar.Height = 34
    $cfgFl = New-Object System.Windows.Forms.Label; $cfgFl.Text = 'Filter settings:'; $cfgFl.Location = New-Object System.Drawing.Point(8, 10); $cfgFl.AutoSize = $true
    $cfgFilter = New-Object System.Windows.Forms.TextBox; $cfgFilter.Location = New-Object System.Drawing.Point(100, 6); $cfgFilter.Width = 200
    $cfgFilter.Add_TextChanged({ Update-SecurityConfigGrid })
    $cfgDiff = New-Object System.Windows.Forms.CheckBox; $cfgDiff.Text = 'Differences only'; $cfgDiff.Location = New-Object System.Drawing.Point(315, 8); $cfgDiff.AutoSize = $true
    $cfgDiff.Add_CheckedChanged({ Update-SecurityConfigGrid })
    $cfgTail = New-Object System.Windows.Forms.CheckBox; $cfgTail.Text = 'Include tailoring'; $cfgTail.Location = New-Object System.Drawing.Point(445, 8); $cfgTail.AutoSize = $true; $cfgTail.Checked = $true
    $script:Gui['Tips'].SetToolTip($cfgTail, 'Ticked: each cell names the tailoring rule in force for that server ([accepted], [downgrade], [threshold 10]), the Expected column shows tailored values, and servers that differ only in tailoring count as different. Unticked: the raw values only.')
    $cfgTail.Add_CheckedChanged({ Update-SecurityConfigGrid })
    $cfgCount = New-Object System.Windows.Forms.Label; $cfgCount.Location = New-Object System.Drawing.Point(580, 10); $cfgCount.AutoSize = $true; $cfgCount.ForeColor = 'DimGray'
    $cfgBar.Controls.AddRange(@($cfgFl, $cfgFilter, $cfgDiff, $cfgTail, $cfgCount))
    $cfgGrid = New-ConsoleGrid -NoCheckBoxes -Columns @(@{ Name = 'Setting'; Width = 270 }, @{ Name = 'Expected'; Width = 150 }, @{ Name = 'Check'; Width = 90 })
    $script:Gui['Tips'].SetToolTip($cfgDiff, 'Keeps the rows whose values differ between the ticked servers')
    $script:Gui['Tips'].SetToolTip($cfgCount, $pageConfig.ToolTipText)
    $pageConfig.Controls.Add($cfgGrid); $pageConfig.Controls.Add($cfgBar); $pageConfig.Controls.Add($cfgTicks.Panel); $cfgGrid.BringToFront()
    $script:Gui['SecurityConfigGrid'] = $cfgGrid; $script:Gui['ConfigTicks'] = $cfgTicks; $script:Gui['ConfigFilter'] = $cfgFilter; $script:Gui['ConfigDiffOnly'] = $cfgDiff; $script:Gui['ConfigTailoring'] = $cfgTail; $script:Gui['ConfigCount'] = $cfgCount

    # ---- Security profile page: what the ratings are measured against ----
    #   box 1: the network's classification and the Essential Eight target (security\profile.json)
    #   box 2: which SERVERS face the internet - written onto each server's own group-file line ("; class: internet-facing")
    $pageSettings.AutoScroll = $true
    $prof = Get-SecurityProfile
    $box1 = New-Object System.Windows.Forms.GroupBox; $box1.Text = 'Network classification and Essential Eight target (apply to every server)'; $box1.Location = New-Object System.Drawing.Point(12, 8); $box1.Size = New-Object System.Drawing.Size(560, 84)
    # labels 24 px above their combos: an AutoSize label is 21 px tall and would hide the combo's top edge
    $pl1 = New-Object System.Windows.Forms.Label; $pl1.Text = 'Classification of the network:'; $pl1.Location = New-Object System.Drawing.Point(12, 24); $pl1.AutoSize = $true
    $pCls = New-Object System.Windows.Forms.ComboBox; $pCls.Location = New-Object System.Drawing.Point(12, 48); $pCls.Width = 220; $pCls.DropDownStyle = 'DropDownList'
    foreach ($v in 'Non-classified', 'OFFICIAL', 'OFFICIAL: Sensitive', 'PROTECTED', 'SECRET', 'TOP SECRET') { [void]$pCls.Items.Add($v) }
    if ($pCls.Items.Contains([string]$prof.classification)) { $pCls.SelectedItem = [string]$prof.classification } else { $pCls.SelectedItem = 'PROTECTED' }
    $pl2 = New-Object System.Windows.Forms.Label; $pl2.Text = 'Essential Eight maturity target:'; $pl2.Location = New-Object System.Drawing.Point(260, 24); $pl2.AutoSize = $true
    $pMl = New-Object System.Windows.Forms.ComboBox; $pMl.Location = New-Object System.Drawing.Point(260, 48); $pMl.Width = 100; $pMl.DropDownStyle = 'DropDownList'
    foreach ($v in '1', '2', '3') { [void]$pMl.Items.Add($v) }
    $pMl.SelectedItem = [string]$prof.maturityTarget; if (-not $pMl.SelectedItem) { $pMl.SelectedItem = '2' }
    $script:Gui['Tips'].SetToolTip($pCls, 'Picks the ISM catalogue column (NC / OS / P / S / TS, data\ism-catalogue.psd1): a control the ISM does not require at that level is Grey and never counts. Stored in security\profile.json.')
    $script:Gui['Tips'].SetToolTip($pMl, 'Each check''s Essential Eight level against this target: a failing control at or below it is Red, above it Amber - and any failing High-severity control is Red whatever its level. Stored in security\profile.json.')
    $box1.Controls.AddRange(@($pl1, $pCls, $pl2, $pMl))

    $box2 = New-Object System.Windows.Forms.GroupBox; $box2.Text = 'Internet-facing servers (tick the servers that face the internet)'; $box2.Location = New-Object System.Drawing.Point(12, 100); $box2.Size = New-Object System.Drawing.Size(560, 230)
    $ifTicks = New-TickList -Title 'Tick the servers that face the internet' -Width 440
    $ifTicks.Panel.Dock = 'None'; $ifTicks.Panel.Location = New-Object System.Drawing.Point(12, 20); $ifTicks.Panel.Size = New-Object System.Drawing.Size(440, 200)
    $ifTip = 'An internet-facing server gets the shorter patch timeframe (two weeks, SEC-PAT-01) and ML2 application control (SEC-AC-01). Save writes "; class: internet-facing" after the server''s name on its line in the group file (editable in Notepad); a server unticked here that its group file marks with "# class: internet-facing" gets "; class: member". The Class column on the Servers page shows what is in force.'
    foreach ($ctl in @($ifTicks.Panel) + @($ifTicks.Panel.Controls)) { $script:Gui['Tips'].SetToolTip($ctl, $ifTip) }
    $box2.Controls.AddRange(@($ifTicks.Panel))

    $pl4 = New-Object System.Windows.Forms.Label; $pl4.Text = 'Note:'; $pl4.Location = New-Object System.Drawing.Point(14, 344); $pl4.AutoSize = $true
    $pNote = New-Object System.Windows.Forms.TextBox; $pNote.Location = New-Object System.Drawing.Point(60, 341); $pNote.Width = 500; $pNote.Text = [string]$prof.note
    $pSave = New-GuiButton -Text 'Save settings' -X 580 -Y 336 -W 130 -H 32 -Colour 'LightGreen' -Tip 'Writes security\profile.json and the group-file lines, then recomputes every rating and report' -OnClick {
        Invoke-GuiAction -Name 'Security settings' -Action { Save-SecurityProfileFromPage } }   # writes group files: not read-only
    $pStatus = New-Object System.Windows.Forms.Label; $pStatus.Location = New-Object System.Drawing.Point(14, 380); $pStatus.AutoSize = $true; $pStatus.MaximumSize = New-Object System.Drawing.Size(980, 0); $pStatus.ForeColor = 'DimGray'
    $pageSettings.Controls.AddRange(@($box1, $box2, $pl4, $pNote, $pSave, $pStatus))
    $script:Gui['SecProfileClass'] = $pCls; $script:Gui['SecProfileML'] = $pMl; $script:Gui['SecProfileTicks'] = $ifTicks; $script:Gui['SecProfileNote'] = $pNote; $script:Gui['SecProfileStatus'] = $pStatus

    # ---- Tailoring page ----
    $tgrid = New-ConsoleGrid -Columns @(@{ Name = 'Check'; Width = 95 }, @{ Name = 'Scope'; Width = 180 }, @{ Name = 'Action'; Width = 80 }, @{ Name = 'Value'; Width = 80 }, @{ Name = 'Reason'; Width = 420; Fill = $true }, @{ Name = 'By'; Width = 150 }, @{ Name = 'Date'; Width = 85 }, @{ Name = 'Review'; Width = 85 })
    # Rules are matched by object identity (the grid row keeps a reference to the rule it shows), never by
    # check + scope + date - two rules may share all three.  Every handler runs through Invoke-GuiAction.
    $tgrid.Add_DoubleClick({
        Invoke-GuiAction -Name 'Edit tailoring rule' -ReadOnly -Action {
            $row = Get-GridSelectedRow -Grid $script:Gui['TailoringGrid']; if (-not $row) { return }
            if (-not (Test-GuiDialogAllowed 'The rule editor')) { return }
            $edited = Show-TailoringRuleEditor -Rule $row.Rule
            if ($edited) {
                $t = Get-SecurityTailoring
                if (@($t.rules | Where-Object { [object]::ReferenceEquals($_, $row.Rule) }).Count -eq 0) { Write-PatchLog 'That rule is no longer in tailoring.json (changed on disk?) - the grid was reloaded, try again' 'WARN'; return }
                $t.rules = @($t.rules | ForEach-Object { if ([object]::ReferenceEquals($_, $row.Rule)) { $edited } else { $_ } })
                Save-SecurityTailoring -Tailoring $t
            }
        }
    })
    $pageTailoring.Controls.Add($tgrid); $script:Gui['TailoringGrid'] = $tgrid
    $tbar = New-ConsoleToolbar -Tab $pageTailoring
    $tbar.Controls.Add((New-GuiButton -Text 'Add rule...' -X 8 -Y 8 -W 110 -ReadOnly -OnClick {
        Invoke-GuiAction -Name 'Add tailoring rule' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The rule editor')) { return }
            $r = Show-TailoringRuleEditor
            if ($r) { $t = Get-SecurityTailoring; $t.rules = @($t.rules) + $r; Save-SecurityTailoring -Tailoring $t }
        }
    }))
    $tbar.Controls.Add((New-GuiButton -Text 'Remove rules (ticked)' -X 125 -Y 8 -W 150 -ReadOnly -OnClick {
        Invoke-GuiAction -Name 'Remove tailoring rules' -ReadOnly -Action {
            $drop = @($script:Gui['TailoringGrid'].Items | Where-Object { $_.Checked } | ForEach-Object { $_.Tag.Rule })
            if ($drop.Count -eq 0) { return }
            if (-not (Test-GuiDialogAllowed 'The remove confirmation')) { return }
            if ((Show-PatcherMessage -Text "Remove $($drop.Count) rule(s)? The risk decision record goes with them." -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2') -ne 'Yes') { return }
            $t = Get-SecurityTailoring
            $t.rules = @($t.rules | Where-Object { $rr = $_; @($drop | Where-Object { [object]::ReferenceEquals($_, $rr) }).Count -eq 0 })
            Save-SecurityTailoring -Tailoring $t
        }
    }))
    $tbar.Controls.Add((New-GuiButton -Text 'Open tailoring.json' -X 280 -Y 8 -W 140 -ReadOnly -OnClick {
        Invoke-GuiAction -Name 'Open tailoring.json' -ReadOnly -Action { $p = Get-TailoringPath; if (-not (Test-Path -LiteralPath $p)) { Save-SecurityTailoring -Tailoring (Get-SecurityTailoring) }; Start-Process notepad.exe -ArgumentList ('"{0}"' -f $p) } }))
    $tbar.Controls.Add((New-GuiButton -Text 'Reload from file' -X 425 -Y 8 -W 120 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Reload tailoring' -ReadOnly -Action { Clear-JsonCache } }))
    $tgrid.BringToFront()

    $script:Gui['SecurityBanner'] = New-ConsoleBanner -Tab $tab -Console 'Security' -Title 'SECURITY CONSOLE' -Subtitle ('ISM audit, modelled on the ISM of {0} - audit policy, local security policy, hardening - profile, tailoring, traffic lights - read-only' -f (Get-IsmRelease))
    $pages.BringToFront()
    Register-ConsoleRefresher -Console 'Security' -Refresh { Update-SecurityGrids }
}
