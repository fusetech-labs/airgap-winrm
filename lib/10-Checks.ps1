# =====================================================================
#  10-Checks.ps1  -  THE CHECK MODEL, VERDICTS, LIGHTS AND JSON FILES
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  A "check" is one question asked of one server: is PowerShell 2.0 removed?
#  is the Logon audit subcategory on?  is W32Time running?  Each check is a
#  small object made by New-Check: an Id, the console it belongs to, a title,
#  ISM references, the Essential Eight maturity level, a severity, which
#  collector results it needs, a -Test script block, and the fix text.
#
#  Invoke-Checks runs every check of a console against one server's collector
#  results and returns one row per check with a Verdict, a Light (Red / Amber /
#  Green / Grey), the Evidence and the Fix.  The grids, the details windows,
#  the reports and the Code Tour all read those rows - one source of truth.
#
#  Verdict helpers used INSIDE -Test blocks:  Pass, Warn, Fail, NotApplicable,
#  NotAssessable (short names on purpose - a check should read like a sentence).
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  10-Checks.ps1  (new in version 2)
# ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

$script:Checks = @()

function New-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Console,     # Health, Security
        [string]$Group = '',                                 # grouping shown in grids and reports
        [Parameter(Mandatory = $true)][string]$Title,
        [string[]]$Ism = @(),                                # ISM identifiers, e.g. 'ISM-1621'
        [int]$ML = 0,                                        # Essential Eight maturity level (0 = not an E8 control)
        [string]$Severity = 'Medium',                        # High / Medium / Low  (High fails are Red regardless of ML)
        [string[]]$Needs = @(),                              # collector names whose results must be present and reachable
        [Parameter(Mandatory = $true)][scriptblock]$Test,    # param($c) -> a verdict object (see Pass / Fail ...)
        [string]$Fix = '',
        [string]$Why = '',
        [string]$Applies = 'all',                            # 'all', 'dc', 'member', 'internet-facing' (NotApplicable otherwise)
        $Data = $null                                        # anything the -Test block needs to know about itself: it reads $c.Check.Data
    )
    # A duplicate id would let one definition silently replace another (a data-file entry could shadow a code
    # check), so it is a hard error: the tool refuses to start until the id is unique again.
    if ($script:Checks | Where-Object { $_.Id -eq $Id }) { throw "Check id $Id is defined twice (data\security-settings.psd1 and/or the console code) - every id must be unique; fix it and start the tool again" }
    $script:Checks += [pscustomobject]@{
        Id = $Id; Console = $Console; Group = $Group; Title = $Title; Ism = $Ism; ML = $ML; Severity = $Severity
        Needs = $Needs; Test = $Test; Fix = $Fix; Why = $Why; Applies = $Applies; Data = $Data
    }
}

function Get-Checks {
    param([string]$Console)
    return @($script:Checks | Where-Object { $_.Console -eq $Console })
}

# ---- verdict helpers: a -Test block returns one of these ----
# A verdict: the text is the summary; -Items are the separate findings behind it (one line each on the details
# pages and in the HTML reports; joined after the summary wherever the row is a single string: grids, CSV, log).
function Pass          { param([string]$Evidence = '', [string[]]$Items = @()) return [pscustomobject]@{ Verdict = 'Pass';          Evidence = $Evidence; Items = @($Items) } }
function Warn          { param([string]$Evidence = '', [string[]]$Items = @()) return [pscustomobject]@{ Verdict = 'Warn';          Evidence = $Evidence; Items = @($Items) } }
function Fail          { param([string]$Evidence = '', [string[]]$Items = @()) return [pscustomobject]@{ Verdict = 'Fail';          Evidence = $Evidence; Items = @($Items) } }
function NotApplicable { param([string]$Evidence = '', [string[]]$Items = @()) return [pscustomobject]@{ Verdict = 'NotApplicable'; Evidence = $Evidence; Items = @($Items) } }
function NotAssessable { param([string]$Evidence = '', [string[]]$Items = @()) return [pscustomobject]@{ Verdict = 'NotAssessable'; Evidence = $Evidence; Items = @($Items) } }

function Get-LightForVerdict {
    # Default light mapping (the Security console overrides it with the profile and tailoring):
    #   Fail = Red, Warn = Amber, Pass = Green, Error = Amber (a broken check must stay visible), NotCollected = Grey (the
    #   collector was never asked on this server), else Grey
    param([string]$Verdict)
    switch ($Verdict) {
        'Fail' { return 'Red' }
        'Warn' { return 'Amber' }
        'Error' { return 'Amber' }
        'NotCollected' { return 'Grey' }
        'Pass' { return 'Green' }
        default { return 'Grey' }
    }
}

function Test-UnreadEvidence {
    # Does a Warn row say the value was NOT READ (the collector could not get it) rather than "read, and not right"?
    # The one test the compliance figures (46) and the GPO recommendations (45) share, so an unread value is left out
    # of the percentages and gets no GPO recommended - never "not compliant" on a guess.  The texts come from
    # Test-SettingRule ("was not collected", "could not read") and the code checks ("could not be read", "not read").
    param([string]$Evidence)
    return ([string]$Evidence -match 'not collected|could not( be)? read|not readable|\bnot read\b')
}

function Invoke-Checks {
    # Runs all checks of one console for one server.
    #   $Resolve (optional) is called with each finished row and may change Verdict / Light / Note
    #   (the Security console passes its profile-and-tailoring resolver).
    param(
        [Parameter(Mandatory = $true)][string]$Console,
        [Parameter(Mandatory = $true)][string]$Server,
        [scriptblock]$Resolve
    )
    $rows = @()
    # The context handed to every -Test block: one property per collector result, S = merged settings table,
    # Check = the check being run (so a data-driven test can read its own definition from $c.Check.Data).
    # Tests are plain script blocks on purpose: a closure (GetNewClosure) runs in its own module scope and
    # cannot see the toolkit's functions, so a check must get what it needs through $c instead.
    $c = [pscustomobject]@{ Server = $Server; Status = $null; Inventory = $null; Health = $null; Agents = $null; Settings = $null; SecurityPolicy = $null; Gpo = $null; Impact = $null; Licensing = $null; S = @{}; Check = $null }
    foreach ($name in 'Status', 'Inventory', 'Health', 'Agents', 'Settings', 'SecurityPolicy', 'Gpo', 'Impact', 'Licensing') {
        $c.$name = Get-CollectorResult -Name $name -Server $Server
    }
    $sets = @()
    if ($c.Settings -and $c.Settings.Reachable) { $sets += , @($c.Settings.Lines) }
    if ($c.SecurityPolicy -and $c.SecurityPolicy.Reachable) { $sets += , @($c.SecurityPolicy.Lines) }
    if ($sets.Count -gt 0) { $c.S = ConvertTo-SettingsTable -LineSets $sets }
    $class = Get-ServerAttribute -Name $Server -Key 'class'   # "; class: ..." on the server's line, else the group's "# class:"
    # The Security console can also mark groups as internet-facing in its profile.
    if (Get-Command -Name Get-ServerClass -ErrorAction SilentlyContinue) { $class = Get-ServerClass -Name $Server }
    # Domain controller?  The Settings collector says so directly (Win32_ComputerSystem.DomainRole); the
    # Inventory's feature list is the fallback when only that collector has run.
    $isDc = ([string]$c.S['IsDomainController'] -eq 'True')
    if (-not $isDc -and $c.Inventory -and $c.Inventory.Reachable) { $isDc = @($c.Inventory.Features -match '^AD-Domain-Services\|').Count -gt 0 }

    foreach ($chk in (Get-Checks -Console $Console)) {
        $verdict = 'Error'; $evidence = ''; $items = @()
        $c.Check = $chk
        $missing = @($chk.Needs | Where-Object { $r = $c.$_; (-not $r) -or (-not $r.Reachable) })
        if ($missing.Count -gt 0) {
            $never = @($missing | Where-Object { -not $c.$_ })
            if ($never.Count -eq $missing.Count) {
                # never asked on this server (another console's check filled the rest of the table): no verdict and grey -
                # not a finding, not an amber error (2026-11-06); a collector that ran and was refused stays Error below
                $verdict = 'NotCollected'; $evidence = 'not collected yet: ' + ($never -join ', ')
            } else {
                $evidence = "collector not available: " + ($missing -join ', ')
                $r0 = $c.($missing[0])
                if ($r0 -and $r0.Error) { $evidence += " ($($r0.Error))" }
            }
        } elseif ($chk.Applies -eq 'dc' -and -not $isDc) {
            $verdict = 'NotApplicable'; $evidence = 'not a domain controller'
        } elseif ($chk.Applies -eq 'member' -and $isDc) {
            $verdict = 'NotApplicable'; $evidence = 'domain controller'
        } elseif ($chk.Applies -eq 'internet-facing' -and $class -ne 'internet-facing') {
            $verdict = 'NotApplicable'; $evidence = "group class is '$class', not internet-facing"
        } else {
            try {
                $res = & $chk.Test $c
                if ($res -and $res.PSObject.Properties['Verdict']) { $verdict = $res.Verdict; $evidence = [string]$res.Evidence; if ($res.PSObject.Properties['Items']) { $items = @($res.Items | Where-Object { "$_" -ne '' }) } }
                else { $verdict = 'Error'; $evidence = 'the test returned no verdict (code error in the check)' }
            } catch {
                $verdict = 'Error'; $evidence = 'check threw: ' + (Get-ShortError $_)
            }
        }
        # Summary = the check's own text; Evidence = summary + the findings joined, so every single-string consumer
        # (grids, CSV, log) still sees everything; Items = the findings for one-per-line rendering.
        $summary = $evidence
        if ($items.Count -gt 0) { if ($summary) { $evidence = $summary + ': ' + ($items -join '; ') } else { $evidence = ($items -join '; ') } }
        $row = [pscustomobject]@{
            Server = $Server; Id = $chk.Id; Console = $chk.Console; Group = $chk.Group; Title = $chk.Title
            Ism = ($chk.Ism -join ' '); ML = $chk.ML; Severity = $chk.Severity
            Verdict = $verdict; Light = (Get-LightForVerdict $verdict); Evidence = $evidence; Summary = $summary; Items = $items; Fix = $chk.Fix; Why = $chk.Why; Note = ''
        }
        if ($Resolve) { $row = & $Resolve $row }
        $rows += $row
    }
    return $rows
}

function Clear-CheckRowCache {
    # Forget cached check rows: for -Servers only (a collector just stored their results), else all of them (a profile,
    # tailoring, data-file or group change).  The software verdicts are not touched: Get-SoftwareRows keeps its own stamp.
    param([string[]]$Servers)
    if (-not $Servers -or -not $script:CheckRowCache) { $script:CheckRowCache = @{}; return }
    $drop = @{}; foreach ($s in $Servers) { if ($s) { $drop[$s.ToLower()] = $true } }
    foreach ($key in @($script:CheckRowCache.Keys)) { $srv = ($key -split '\|', 2)[1]; if ($srv -and $drop.ContainsKey($srv.ToLower())) { $script:CheckRowCache.Remove($key) } }
}

function Test-ToolFilesChanged {
    # Once per repaint: has any data\*.psd1, soe\*.json or security\*.json changed (a Notepad edit) since the last look?
    # Then the cached verdicts are stale.  One directory listing per folder, not one stat per check row.
    $parts = @()
    foreach ($pair in @(@($script:Config.DataFolder, '*.psd1'), @($script:Config.SoeFolder, '*.json'), @($script:Config.SecurityFolder, '*.json'))) {
        if (-not $pair[0] -or -not (Test-Path -LiteralPath $pair[0])) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $pair[0] -Filter $pair[1] -File -ErrorAction SilentlyContinue)) { $parts += '{0}={1}' -f $f.Name, $f.LastWriteTimeUtc.Ticks }
    }
    $stamp = ($parts | Sort-Object) -join '|'
    $changed = ($null -ne $script:ToolFilesStamp -and $stamp -ne $script:ToolFilesStamp)
    $script:ToolFilesStamp = $stamp
    return $changed
}

function Get-CheckRows {
    # Invoke-Checks with a cache: the grids, the details windows and the reports all ask for the same rows,
    # and a console repaints after every action.  The cache is cleared whenever a collector stores new
    # results (Invoke-Collector) and whenever the Security profile or tailoring changes - the only things a
    # verdict depends on.
    param([Parameter(Mandatory = $true)][string]$Console, [Parameter(Mandatory = $true)][string]$Server, [scriptblock]$Resolve)
    if (-not $script:CheckRowCache) { $script:CheckRowCache = @{} }
    $key = "$Console|$Server"
    if ($script:CheckRowCache.ContainsKey($key)) { return @($script:CheckRowCache[$key]) }
    if ($Resolve) { $rows = @(Invoke-Checks -Console $Console -Server $Server -Resolve $Resolve) } else { $rows = @(Invoke-Checks -Console $Console -Server $Server) }
    $script:CheckRowCache[$key] = $rows
    return $rows
}

function Get-LightCounts {
    # Red / Amber / Green / Grey totals for a set of rows.
    param([object[]]$Rows)
    $t = [ordered]@{ Red = 0; Amber = 0; Green = 0; Grey = 0 }
    foreach ($r in @($Rows)) { if ($t.Contains($r.Light)) { $t[$r.Light]++ } }
    return $t
}

function Get-WorstLight {
    param([object[]]$Rows)
    $c = Get-LightCounts -Rows $Rows
    if ($c.Red -gt 0) { return 'Red' }
    if ($c.Amber -gt 0) { return 'Amber' }
    if ($c.Green -gt 0) { return 'Green' }
    return 'Grey'
}

function Get-LightColour {
    # Row background per light (WinForms colour names).
    param([string]$Light)
    switch ($Light) {
        'Red'   { return 'MistyRose' }
        'Amber' { return 'LemonChiffon' }
        'Green' { return 'Honeydew' }
        'Blue'  { return 'AliceBlue' }   # GPO recommendations: no impact found (green there means "already enforced")
        default { return 'WhiteSmoke' }
    }
}

# ---------------------------------------------------------------------
#  JSON files: SOE standards, the security profile, the tailoring file.
#  JSON because PowerShell 5.1 reads and writes it natively and the
#  sysadmin can edit it in Notepad.  Depth 10 so nested items survive.
# ---------------------------------------------------------------------
function Read-ToolJson {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-PatchLog "Could not read $Path as JSON: $(Get-ShortError $_)" 'ERROR'
        return $null
    }
}

function Save-ToolJson {
    param([Parameter(Mandatory = $true)]$Object, [Parameter(Mandatory = $true)][string]$Path)
    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $json = $Object | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-PatchLog "Saved $Path" 'INFO'
}

function ConvertTo-VersionObject {
    # The first numeric group of a version text as a [version]: '10' -> 10.0, 'v2.1' -> 2.1, '24.08' -> 24.8,
    # '1.2.3.4.5' -> 1.2.3.4, '10.7.2 (x64)' -> 10.7.2.  $null when there is nothing numeric to compare.
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(\.\d+)*')
    if (-not $m.Success) { return $null }
    $parts = @($m.Value -split '\.' | Select-Object -First 4)
    while ($parts.Count -lt 4) { $parts += '0' }   # pad to 4 parts: [version]'10.7' would otherwise sort below '10.7.0'
    try { return [version](($parts | ForEach-Object { [string][int]$_ }) -join '.') } catch { return $null }
}

function Compare-VersionRule {
    # Compares an actual version string with a rule such as '>= 10.7.0', '= 24.08', '< 5', or '' (any).
    # Returns 'Compliant', 'Below', 'Above', 'Different' or 'Unknown'.
    param([string]$Actual, [string]$Rule)
    if (-not $Rule) { return 'Compliant' }
    if (-not $Actual) { return 'Unknown' }
    $op = '>='; $want = $Rule.Trim()
    if ($want -match '^(>=|<=|=|>|<)\s*(.+)$') { $op = $Matches[1]; $want = $Matches[2].Trim() }
    # Both sides are compared as [version] objects; a side with nothing numeric in it cannot be judged
    # (a text comparison would call '10' smaller than '9').
    $a = ConvertTo-VersionObject $Actual
    $w = ConvertTo-VersionObject $want
    if ($null -eq $a -or $null -eq $w) { return 'Unknown' }
    $cmp = $a.CompareTo($w)
    switch ($op) {
        '>=' { if ($cmp -ge 0) { return 'Compliant' } else { return 'Below' } }
        '>'  { if ($cmp -gt 0) { return 'Compliant' } else { return 'Below' } }
        '<=' { if ($cmp -le 0) { return 'Compliant' } else { return 'Above' } }
        '<'  { if ($cmp -lt 0) { return 'Compliant' } else { return 'Above' } }
        '='  { if ($cmp -eq 0) { return 'Compliant' } elseif ($cmp -lt 0) { return 'Below' } else { return 'Above' } }
    }
    return 'Unknown'
}

function Import-ToolData {
    # Reads a shipped data\*.psd1 catalogue.  Returns $null (and logs) when it is missing.  Parsed once per
    # file version: checks call this for every server, and the ISM catalogue is 400 KB.
    #
    # Import-PowerShellDataFile is PowerShell's own loader.  On PowerShell 5.1 it gives up on big files
    # ("Cannot generate a Windows PowerShell object ...") once a file holds roughly 2,000 values in total - the
    # ISM catalogue has 13,000 and a well-fed security-settings.psd1 gets there too.  Files over 100 KB, and any
    # file the standard loader refuses, are read by Import-DataFileSafely below: the same file, the same rules
    # (values only, never code), just one entry at a time.
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $script:Config.DataFolder $Name
    if (-not $script:DataCache) { $script:DataCache = @{} }
    $hit = $script:DataCache[$path]
    $now = [datetime]::UtcNow
    if ($hit -and ($now - $hit.Seen).TotalSeconds -lt 2) { return $hit.Data }
    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $hit -or $hit.Stamp -ne 'missing') { Write-PatchLog "Data file missing: $path" 'WARN' }
        $script:DataCache[$path] = @{ Stamp = 'missing'; Data = $null; Seen = $now }
        return $null
    }
    $item = Get-Item -LiteralPath $path
    $stamp = [string]$item.LastWriteTimeUtc.Ticks
    if ($hit -and $hit.Stamp -eq $stamp) { $hit.Seen = $now; return $hit.Data }
    try {
        $data = $null
        if ($item.Length -le 100KB) { try { $data = Import-PowerShellDataFile -LiteralPath $path } catch { $data = $null } }
        if ($null -eq $data) { $data = Import-DataFileSafely -Path $path }
        $script:DataCache[$path] = @{ Stamp = $stamp; Data = $data; Seen = $now }
        Clear-CheckRowCache    # a changed catalogue (benign list, agents ...) changes verdicts
        return $data
    } catch {
        Write-PatchLog "Data file unreadable: $path - $(Get-ShortError $_)" 'ERROR'
        $script:DataCache[$path] = @{ Stamp = $stamp; Data = $null; Seen = $now }   # logged once per file version
        return $null
    }
}

function Import-DataFileSafely {
    # Reads a .psd1 data file of any size without executing it: the file is parsed into a syntax tree and
    # ConvertFrom-DataAst turns the tree into hashtables, arrays, strings, numbers and booleans.  Anything
    # else (a command, a variable other than $true/$false/$null, an expression) is refused with the line number.
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ("line {0}: {1}" -f $errors[0].Extent.StartLineNumber, $errors[0].Message) }
    $top = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $top) { throw 'the file does not start with a hashtable (@{ ... })' }
    return (ConvertFrom-DataAst -Node $top)
}

function ConvertFrom-DataAst {
    # One node of a parsed data file -> its value.  Mirrors what Import-PowerShellDataFile accepts.
    param($Node)
    if ($Node -is [System.Management.Automation.Language.PipelineAst]) {
        $expr = $Node.GetPureExpression()
        if ($null -eq $expr) { throw "line $($Node.Extent.StartLineNumber): only plain values are allowed in a data file" }
        $r = ConvertFrom-DataAst -Node $expr; if ($r -is [array]) { return , $r }; return $r   # the comma keeps an array an array
    }
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { $r = ConvertFrom-DataAst -Node $Node.Expression; if ($r -is [array]) { return , $r }; return $r }
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { $r = ConvertFrom-DataAst -Node $Node.Pipeline; if ($r -is [array]) { return , $r }; return $r }
    if ($Node -is [System.Management.Automation.Language.HashtableAst]) {
        $h = @{}
        foreach ($kv in $Node.KeyValuePairs) {
            # the common leaves (a bare key, a quoted string, a number, $true/$false) are read right here -
            # one function call per value would make the 13,000-value ISM catalogue take seconds to load
            $key = $kv.Item1
            if ($key -is [System.Management.Automation.Language.ConstantExpressionAst]) { $key = $key.Value } else { $key = ConvertFrom-DataAst -Node $key }
            $expr = $null
            if ($kv.Item2 -is [System.Management.Automation.Language.PipelineAst]) { $expr = $kv.Item2.GetPureExpression() }
            if ($expr -is [System.Management.Automation.Language.ConstantExpressionAst]) { $h[$key] = $expr.Value }
            elseif ($expr -is [System.Management.Automation.Language.VariableExpressionAst] -and $expr.VariablePath.UserPath -in 'true', 'false') { $h[$key] = ($expr.VariablePath.UserPath -eq 'true') }
            else { $h[$key] = ConvertFrom-DataAst -Node $kv.Item2 }
        }
        return $h
    }
    if ($Node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        # @( ... ): every statement's output joins the array, and an array inside unrolls one level (PowerShell's rule)
        $items = New-Object System.Collections.ArrayList
        foreach ($st in $Node.SubExpression.Statements) {
            $v = ConvertFrom-DataAst -Node $st
            if ($v -is [object[]]) { foreach ($x in $v) { [void]$items.Add($x) } } else { [void]$items.Add($v) }
        }
        return , $items.ToArray()
    }
    if ($Node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($el in $Node.Elements) { $v = ConvertFrom-DataAst -Node $el; [void]$items.Add($v) }
        return , $items.ToArray()
    }
    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) { return $Node.Value }     # 'text', 42, 1.5
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -and @($Node.NestedExpressions).Count -eq 0) { return $Node.Value }
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        switch ($Node.VariablePath.UserPath.ToLower()) { 'true' { return $true } 'false' { return $false } 'null' { return $null } }
        throw "line $($Node.Extent.StartLineNumber): variable `$$($Node.VariablePath.UserPath) is not allowed in a data file"
    }
    if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst] -and $Node.TokenKind -eq 'Minus') { return (-1 * (ConvertFrom-DataAst -Node $Node.Child)) }
    throw "line $($Node.Extent.StartLineNumber): $($Node.GetType().Name) is not allowed in a data file ($($Node.Extent.Text))"
}
