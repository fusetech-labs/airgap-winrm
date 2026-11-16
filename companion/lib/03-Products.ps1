# =====================================================================
#  03-Products.ps1  -  WHAT TO FETCH, FOR WHICH ENVIRONMENT, AND THE RULES
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  data\products.psd1 names every product: where it comes from (Source),
#  where it goes in the library (PatchType or Folder) and who must have
#  signed it (Signers).  settings\environment.json holds the site's
#  parameters (the first box of the Settings tab): the Windows builds in
#  use, the .NET lines, the ESXi line and the VMware Tools rule - and the
#  Products tab's ticks and links.  The two together make
#  the TARGETS: one row of the Library grid per product per thing it is
#  for (a Windows build, a .NET line set, an ESXi line, or "any").
#  Nothing here goes online: the sources are in lib\05-Sources.ps1.
# =====================================================================

$script:BuildNames = @{ 14393 = 'Server 2016'; 17763 = 'Server 2019'; 20348 = 'Server 2022'; 26100 = 'Server 2025' }
$script:DotNetLineChoices = @('4.7.2', '4.8', '4.8.1')
$script:VMwareToolsRules = [ordered]@{
    shipped = 'the version the ESXi line ships (exactly that release)'
    line    = 'the newest release of the version line the ESXi line ships (12.5.x for ESXi 8.0)'
    latest  = 'the newest release there is (check the Broadcom interoperability matrix first)'
    pin     = 'one version, typed in the box'
}

# ---------------------------------------------------------------------
#  The environment (the site's parameters)
# ---------------------------------------------------------------------
function Get-EnvironmentDefaults {
    return [ordered]@{
        WindowsBuilds   = @(17763, 20348)       # the builds the servers run (Server 2019, Server 2022)
        Architecture    = 'x64'
        DotNetLines     = @('4.8', '4.8.1')     # the .NET Framework lines in use (a rollup that covers only other lines is not fetched)
        EsxiVersion     = '8.0'                 # the ESXi line the VMs run on (7.0, 8.0, 9.0 ...): decides the VMware Tools version
        VMwareToolsRule = 'line'                # shipped | line | latest | pin  (see $script:VMwareToolsRules)
        VMwareToolsPin  = ''                    # the version when the rule is pin, e.g. 12.5.4
        Site            = ''                    # a name for the reports (optional)
        ManualLinks     = [ordered]@{}          # product id -> the installer link given by hand (products with Source = 'manual': Splunk Universal Forwarder)
        Products        = [ordered]@{}          # product id -> on / off where the site's tick differs from Enabled in data\products.psd1 (the Products tab's tick boxes)
    }
}

function Get-EnvironmentValueText {
    # One environment value as text, for the "what changes" list and the log (a list joined, the links as id = link,
    # the product ticks as id = on / off)
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) { return (@(foreach ($k in $Value.Keys) { $v = $Value[$k]; if ($v -is [bool]) { $v = $(if ($v) { 'on' } else { 'off' }) }; '{0} = {1}' -f $k, $v }) -join '; ') }
    return (@($Value) -join ', ')
}

function Test-EnvironmentValue {
    # One field of the environment checked; throws with the reason.  Returns the value in its proper type.
    param([string]$Key, $Value)
    switch ($Key) {
        'WindowsBuilds' {
            $b = @(@($Value) | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
            foreach ($x in $b) { if (-not $script:BuildNames.ContainsKey($x)) { throw ("build {0} is not a Windows Server build this tool knows ({1})" -f $x, (@($script:BuildNames.Keys | Sort-Object) -join ', ')) } }
            if ($b.Count -eq 0) { throw 'tick at least one Windows build' }
            return , [int[]]$b
        }
        'Architecture' { $a = ([string]$Value).Trim().ToLower(); if ($a -notin 'x64', 'arm64') { throw 'the architecture must be x64 or arm64' }; return $a }
        'DotNetLines' {
            $l = @(@($Value) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Sort-Object -Unique)
            foreach ($x in $l) { if ($x -notin $script:DotNetLineChoices) { throw (".NET line '{0}' is not one of {1}" -f $x, ($script:DotNetLineChoices -join ', ')) } }
            return , [string[]]$l
        }
        'EsxiVersion' { $v = ([string]$Value).Trim(); if ($v -and $v -notmatch '^\d+\.\d+(u\d+|p\d+|\.\d+)?$') { throw "the ESXi version must look like 8.0, 8.0u3 or 9.0 (got '$v')" }; return $v }
        'VMwareToolsRule' { $r = ([string]$Value).Trim().ToLower(); if (-not $script:VMwareToolsRules.Contains($r)) { throw ("the VMware Tools rule must be one of {0}" -f (@($script:VMwareToolsRules.Keys) -join ', ')) }; return $r }
        'VMwareToolsPin' { $p = ([string]$Value).Trim(); if ($p -and $p -notmatch '^\d+\.\d+\.\d+$') { throw "the pinned VMware Tools version must look like 12.5.4 (got '$p')" }; return $p }
        'Site' { $s = ([string]$Value).Trim(); if ($s.Length -gt 60 -or $s -match '[^\x20-\x7E]') { throw 'the site name must be plain text of at most 60 characters' }; return $s }
        'ManualLinks' {
            # id -> link, from the page (a hashtable) or from the file (an object).  An empty link is no entry; a link for
            # something that is not a product with Source = 'manual' is dropped; a link of the wrong shape is refused.
            $pairs = @()
            if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { $pairs += , @([string]$k, [string]$Value[$k]) } }
            elseif ($Value) { foreach ($prop in $Value.PSObject.Properties) { $pairs += , @([string]$prop.Name, [string]$prop.Value) } }
            $links = [ordered]@{}
            foreach ($pair in $pairs) {
                $link = $pair[1].Trim(); if (-not $link) { continue }
                $prod = Get-Product -Id $pair[0]
                if (-not $prod -or $prod.Source -ne 'manual') { continue }
                try { $null = Test-ManualLink -Product $prod -Link $link } catch { throw ('{0}: {1}' -f $prod.Name, $_.Exception.Message) }
                $links[[string]$prod.Id] = $link
            }
            return $links
        }
        'Products' {
            # id -> on / off, as the Products tab's tick boxes give it (a hashtable) or the file holds it (an object).
            # Only a product whose tick differs from its Enabled in data\products.psd1 is kept, so the file's own choice
            # applies to everything nobody touched; an id that is not a product is dropped.
            $pairs = @()
            if ($Value -is [System.Collections.IDictionary]) { foreach ($k in @($Value.Keys)) { $pairs += , @([string]$k, $Value[$k]) } }
            elseif ($Value) { foreach ($prop in $Value.PSObject.Properties) { $pairs += , @([string]$prop.Name, $prop.Value) } }
            $inFile = @{}; $spelling = @{}
            foreach ($known in @(Get-Products)) { $inFile[[string]$known.Id] = [bool]$known.EnabledInFile; $spelling[[string]$known.Id] = [string]$known.Id }
            $state = [ordered]@{}
            foreach ($pair in $pairs) {
                if (-not $inFile.ContainsKey($pair[0])) { continue }
                $on = $pair[1]; if ($on -is [string]) { $on = ($on -match '^(?i:true|yes|on|1)$') } else { $on = [bool]$on }
                if ($on -ne $inFile[$pair[0]]) { $state[$spelling[$pair[0]]] = $on }
            }
            return $state
        }
        default { throw "unknown environment field $Key" }
    }
}

function Import-Environment {
    # Start-up: settings\environment.json over the defaults; a value that does not fit is skipped with a warning.
    $env = Get-EnvironmentDefaults
    $script:EnvironmentInfo = [pscustomobject]@{ Path = $script:Config.EnvironmentFile; Exists = $false; Saved = ''; SavedBy = ''; Problems = @() }
    $path = $script:Config.EnvironmentFile
    if (Test-Path -LiteralPath $path) {
        $script:EnvironmentInfo.Exists = $true
        $doc = $null
        try { $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop } catch { $script:EnvironmentInfo.Problems += ('unreadable: ' + (Get-ShortError $_)) }
        if ($doc -and $doc.PSObject.Properties['Environment'] -and $doc.Environment) {
            $script:EnvironmentInfo.Saved = [string]$doc.Saved; $script:EnvironmentInfo.SavedBy = [string]$doc.SavedBy
            foreach ($p in $doc.Environment.PSObject.Properties) {
                if (-not $env.Contains($p.Name)) { $script:EnvironmentInfo.Problems += ('{0}: not a field of this version - ignored' -f $p.Name); continue }
                try { $env[$p.Name] = Test-EnvironmentValue -Key $p.Name -Value $p.Value } catch { $script:EnvironmentInfo.Problems += ('{0}: {1} - the default stays' -f $p.Name, $_.Exception.Message) }
            }
        } elseif ($doc) { $script:EnvironmentInfo.Problems += 'no Environment block - the defaults apply' }
        foreach ($m in $script:EnvironmentInfo.Problems) { Write-PatchLog "ENVIRONMENT: $m ($path)" 'WARN' }
    }
    $script:Environment = $env
    if ($script:EnvironmentInfo.Exists -and $script:EnvironmentInfo.Problems.Count -eq 0) { Write-PatchLog ("Environment: {0} (saved {1} by {2}) - {3}" -f $path, $script:EnvironmentInfo.Saved, $script:EnvironmentInfo.SavedBy, (Get-EnvironmentText)) 'INFO' }
    else { Write-PatchLog ("Environment: the defaults - {0}. Set what this site runs on the Settings tab before the first download." -f (Get-EnvironmentText)) 'WARN' }
    $script:Candidates = @{}; $script:Checked = @{}; $script:Results = @{}
    return $env
}

function Save-Environment {
    # The Save of the Settings tab's first box and of the Products tab (each gives its own fields, the others stay): every field checked (nothing saved when one does not fit), written, applied, logged.
    param([hashtable]$Values)
    $new = [ordered]@{}
    foreach ($k in (Get-EnvironmentDefaults).Keys) {
        $v = $script:Environment[$k]; if ($Values.ContainsKey($k)) { $v = $Values[$k] }
        try { $new[$k] = Test-EnvironmentValue -Key $k -Value $v } catch { throw ('{0}: {1}' -f $k, $_.Exception.Message) }
    }
    if ($new.VMwareToolsRule -eq 'pin' -and -not $new.VMwareToolsPin) { throw 'VMware Tools: the rule is "pin" but no version is typed' }
    $who = Get-OperatorIdentity; $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $doc = [ordered]@{ Tool = ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion); Saved = $when; SavedBy = $who; Note = 'Written by the Settings tab (what this site runs) and the Products tab (the ticks, the links given by hand). The Library console fetches only what fits them.'; Environment = $new }
    $path = $script:Config.EnvironmentFile
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $part = $path + '.part'
    [System.IO.File]::WriteAllText($part, (ConvertTo-Json -InputObject $doc -Depth 6), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $part -Destination $path -Force
    $changes = @()
    foreach ($k in $new.Keys) { $a = Get-EnvironmentValueText $script:Environment[$k]; $b = Get-EnvironmentValueText $new[$k]; if ($a -cne $b) { $changes += ('{0}: {1}  ->  {2}' -f $k, $(if ($a) { $a } else { '(none)' }), $(if ($b) { $b } else { '(none)' })) } }
    $script:Environment = $new
    $script:EnvironmentInfo = [pscustomobject]@{ Path = $path; Exists = $true; Saved = $when; SavedBy = $who; Problems = @() }
    $script:Candidates = @{}; $script:Checked = @{}; $script:Results = @{}   # what fits may have changed: every row is "Not checked" again
    if ($changes.Count -eq 0) { Write-PatchLog "Environment saved by $who ($path) - nothing changed" 'INFO' }
    else { Write-PatchLog ("ENVIRONMENT CHANGED by {0} ({1}):" -f $who, $path) 'OK'; foreach ($c in $changes) { Write-PatchLog ('   ' + $c) 'INFO' } }
    return $changes
}

function Get-EnvironmentText {
    # One line: "Server 2019, Server 2022 x64; .NET 4.8, 4.8.1; ESXi 8.0 (line)"
    $e = $script:Environment
    $builds = @(@($e.WindowsBuilds) | ForEach-Object { Get-BuildName $_ }) -join ', '
    $vm = 'no ESXi line (VMware Tools not fetched)'
    if ($e.EsxiVersion) { $vm = ('ESXi {0} ({1}{2})' -f $e.EsxiVersion, $e.VMwareToolsRule, $(if ($e.VMwareToolsRule -eq 'pin') { ' ' + $e.VMwareToolsPin } else { '' })) }
    return ('{0} {1}; .NET {2}; {3}' -f $builds, $e.Architecture, $(if (@($e.DotNetLines).Count -gt 0) { @($e.DotNetLines) -join ', ' } else { 'none' }), $vm)
}

function Get-BuildName { param([int]$Build) if ($script:BuildNames.ContainsKey($Build)) { return $script:BuildNames[$Build] }; return "build $Build" }

# ---------------------------------------------------------------------
#  The products (data\products.psd1)
# ---------------------------------------------------------------------
function Import-ToolData {
    # Reads a data\*.psd1 file (values only, never code), once per file version.  $null (and a log line) when missing.
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path $script:Config.DataFolder $Name
    if (-not $script:DataCache) { $script:DataCache = @{} }
    $hit = $script:DataCache[$path]
    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $hit -or $hit.Stamp -ne 'missing') { Write-PatchLog "Data file missing: $path" 'WARN' }
        $script:DataCache[$path] = @{ Stamp = 'missing'; Data = $null }
        return $null
    }
    $stamp = [string](Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    if ($hit -and $hit.Stamp -eq $stamp) { return $hit.Data }
    try {
        $data = Import-PowerShellDataFile -LiteralPath $path
        $script:DataCache[$path] = @{ Stamp = $stamp; Data = $data }
        return $data
    } catch {
        Write-PatchLog "Data file unreadable: $path - $(Get-ShortError $_)" 'ERROR'
        $script:DataCache[$path] = @{ Stamp = $stamp; Data = $null }
        return $null
    }
}

function Get-Products {
    # Every product of data\products.psd1 as an object with every field present (missing ones empty), problems logged once.
    param([switch]$EnabledOnly)
    $d = Import-ToolData -Name 'products.psd1'
    $out = @()
    if (-not $d) { return $out }
    $seen = @{}
    foreach ($p in @($d.Products)) {
        if (-not $p) { continue }
        $o = [ordered]@{ Id = ''; Name = ''; Kind = 'software'; Source = ''; Enabled = $true; PatchType = ''; Folder = ''; FilePattern = ''; Query = ''; TitleMatch = ''; Classification = 'Security Updates'; Exclude = 'Preview|Dynamic Update'; Monthly = $false; Lines = $false; Builds = @(); Url = ''; IndexUrl = ''; LinkRegex = ''; FileUrl = ''; FilePage = ''; FilePageRegex = ''; ChecksumUrl = ''; ChecksumRegex = ''; Channel = ''; ManualPage = ''; LinkPattern = ''; LinkExample = ''; VersionFrom = 'name'; VersionRegex = ''; Signers = @(); Rule = ''; ReleaseNotes = ''; Note = '' }
        foreach ($k in @($o.Keys)) { if ($p.ContainsKey($k) -and $null -ne $p[$k]) { $o[$k] = $p[$k] } }
        $o.Signers = @($o.Signers | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $o.Builds = @($o.Builds | ForEach-Object { [int]$_ } | Where-Object { $_ -gt 0 })   # catalog: only these Windows builds (empty = every build of the environment)
        $o.Classification = @($o.Classification | ForEach-Object { [string]$_ } | Where-Object { $_ })   # catalog: one classification or several (any of them counts)
        $o.Monthly = [bool]$o.Monthly
        $problem = ''
        if (-not $o.Id) { $problem = 'a product without an Id' }
        elseif ($seen.ContainsKey($o.Id.ToLower())) { $problem = "product '$($o.Id)' is listed twice" }
        elseif ($o.Source -notin 'catalog', 'vmware-tools', 'url', 'index', 'edge', 'manual') { $problem = "product '$($o.Id)': Source must be catalog, vmware-tools, url, index, edge or manual (got '$($o.Source)')" }
        elseif ($o.Source -eq 'catalog' -and -not $script:Config.PatchTypes.Contains([string]$o.PatchType)) { $problem = "product '$($o.Id)': a catalog product needs PatchType Windows or DotNet" }
        elseif ($o.Source -eq 'catalog' -and (-not $o.Query -or -not $o.TitleMatch)) { $problem = "product '$($o.Id)': a catalog product needs Query and TitleMatch" }
        elseif ($o.Source -ne 'catalog' -and -not $o.Folder) { $problem = "product '$($o.Id)': a software product needs Folder (its folder under software\)" }
        elseif ($o.Source -eq 'url' -and -not $o.Url) { $problem = "product '$($o.Id)': a url product needs Url" }
        elseif ($o.Source -eq 'index' -and (-not $o.IndexUrl -or -not $o.LinkRegex)) { $problem = "product '$($o.Id)': an index product needs IndexUrl and LinkRegex" }
        elseif ($o.FilePage -and -not $o.FilePageRegex) { $problem = "product '$($o.Id)': FilePage needs FilePageRegex (the link on that page, group 'file')" }
        elseif ($o.Source -eq 'manual' -and $o.ManualPage -and $o.ManualPage -notmatch '^https://') { $problem = "product '$($o.Id)': ManualPage must be an https:// address" }
        elseif ($o.ReleaseNotes -and $o.ReleaseNotes -notmatch '^https://') { $problem = "product '$($o.Id)': ReleaseNotes must be an https:// address" }
        elseif ($o.Signers.Count -eq 0) { $problem = "product '$($o.Id)': Signers must name who signs its files" }
        elseif ($o.Folder -and ($o.Folder -match '[<>:"|?*]' -or $o.Folder -match '(^|\\)(\.\.|_info|_incoming)(\\|$)')) { $problem = "product '$($o.Id)': Folder '$($o.Folder)' is not a folder name the library allows" }
        if ($problem) { if (-not $script:ProductProblems) { $script:ProductProblems = @{} }; if (-not $script:ProductProblems[$problem]) { $script:ProductProblems[$problem] = $true; Write-PatchLog "products.psd1: $problem - skipped" 'WARN' }; continue }
        $seen[$o.Id.ToLower()] = $true
        if (-not $o.Name) { $o.Name = $o.Id }
        # on or off: the file's own choice, unless the site ticked otherwise on the Products tab (settings\environment.json)
        $o.Enabled = [bool]$o.Enabled
        $o['EnabledInFile'] = $o.Enabled
        $ticks = $null; if ($script:Environment) { $ticks = $script:Environment['Products'] }
        if ($ticks -and $ticks.Contains([string]$o.Id)) { $o.Enabled = [bool]$ticks[[string]$o.Id] }
        if ($EnabledOnly -and -not [bool]$o.Enabled) { continue }
        $out += [pscustomobject]$o
    }
    return $out
}

function Get-Product { param([string]$Id) return @(Get-Products | Where-Object { $_.Id -ieq $Id })[0] }

function Get-CatalogProductName {
    # The Update Catalog's name for a Windows build (data\products.psd1, CatalogProducts).
    param([int]$Build)
    $d = Import-ToolData -Name 'products.psd1'
    if ($d -and $d.CatalogProducts -and $d.CatalogProducts.Contains([string]$Build)) { return [string]$d.CatalogProducts[[string]$Build] }
    return ''
}

function Get-ReleaseNotesUrl {
    # The vendor's release notes for one version of a product, as a link for the operator to open: the product's
    # ReleaseNotes template with {version}, {major}, {minor}, {patch} (the version and its first three parts) and
    # {kb} / {kbnumber} (an update's KB5136487 / 5136487) filled in.  '' when the product names none, or when the
    # template needs a part that this version does not have.  The tool never reads the page: a person does.
    param($Product, [string]$Version = '', [string]$Kb = '')
    $template = ''; if ($Product) { $template = [string]$Product.ReleaseNotes }
    if (-not $template) { return '' }
    $parts = @(); if ($Version -match '(\d+(?:\.\d+)*)') { $parts = @($Matches[1] -split '\.') }
    $number = ''; if ($Kb -match '(\d+)') { $number = $Matches[1] }
    $values = @{ version = $Version.Trim(); major = [string]$parts[0]; minor = [string]$parts[1]; patch = [string]$parts[2]; kb = $(if ($number) { 'KB' + $number } else { '' }); kbnumber = $number }
    $url = $template
    foreach ($token in [regex]::Matches($template, '\{(\w+)\}')) {
        $name = $token.Groups[1].Value.ToLower()
        if (-not $values.ContainsKey($name) -or -not $values[$name]) { return '' }
        $url = $url.Replace($token.Value, [uri]::EscapeDataString($values[$name]))
    }
    if ($url -notmatch '^https://[^\s"<>]+$') { return '' }
    return $url
}

# ---------------------------------------------------------------------
#  The targets: product x what it is for.  Key = "<Id>|<target>".
# ---------------------------------------------------------------------
function Get-ProductTargets {
    # One target per thing a product is fetched for, from the environment: a Windows build (os products), the ESXi
    # line (VMware Tools), or "any" (a fixed link).  A product whose target the environment does not name has none.
    # Problem = why nothing can be fetched for a target; ByChoice marks the two that are the site's own decision (no
    # ESXi version, no .NET line), which a run does not count as a failure.
    param($Product)
    $e = $script:Environment
    $t = @()
    switch ($Product.Source) {
        'catalog' {
            foreach ($b in @($e.WindowsBuilds)) {
                # a product for certain builds only (the separate servicing stack update: Server 2016) has no row for the others
                if (@($Product.Builds).Count -gt 0 -and @($Product.Builds) -notcontains [int]$b) { continue }
                $name = Get-CatalogProductName -Build $b
                if (-not $name) { $t += [pscustomobject]@{ Key = ('{0}|{1}' -f $Product.Id, $b); Target = $b; For = (Get-BuildName $b); Product = $Product; Problem = "no catalogue name for build $b in data\products.psd1 (CatalogProducts)"; Lines = @() }; continue }
                $lines = @()
                if ($Product.PatchType -eq 'DotNet') { $lines = @($e.DotNetLines); if ($lines.Count -eq 0) { $t += [pscustomobject]@{ Key = ('{0}|{1}' -f $Product.Id, $b); Target = $b; For = (Get-BuildName $b); Product = $Product; Problem = 'no .NET line is ticked on the Settings tab: .NET updates are not fetched'; ByChoice = $true; Lines = @() }; continue } }
                $t += [pscustomobject]@{ Key = ('{0}|{1}' -f $Product.Id, $b); Target = $b; For = (Get-BuildName $b); Product = $Product; Problem = ''; Lines = $lines; CatalogProduct = $name }
            }
        }
        'vmware-tools' {
            if ($e.EsxiVersion) { $t += [pscustomobject]@{ Key = ('{0}|esxi' -f $Product.Id); Target = 'esxi'; For = ('ESXi {0}, {1}' -f $e.EsxiVersion, $e.VMwareToolsRule + $(if ($e.VMwareToolsRule -eq 'pin') { ' ' + $e.VMwareToolsPin } else { '' })); Product = $Product; Problem = ''; Lines = @() } }
            else { $t += [pscustomobject]@{ Key = ('{0}|esxi' -f $Product.Id); Target = 'esxi'; For = 'no ESXi line'; Product = $Product; Problem = 'no ESXi version on the Settings tab: VMware Tools is not fetched'; ByChoice = $true; Lines = @() } }
        }
        'manual' {
            # a link the operator gives on the Products tab.  Without one the row waits ("By hand") - it is not a failure:
            # the site may not use the product, or places the file in the folder itself
            $waiting = ''
            if (-not (Get-ManualLink -Product $Product)) { $waiting = ('find the installer on {0} and give its link on the Products tab - the tool then fetches it and checks it against the vendor''s checksum file (or place the file in software\{1} yourself)' -f $(if ($Product.ManualPage) { $Product.ManualPage } else { 'the vendor''s download page' }), $Product.Folder) }
            $t += [pscustomobject]@{ Key = ('{0}|any' -f $Product.Id); Target = 'any'; For = 'any'; Product = $Product; Problem = ''; Waiting = $waiting; Lines = @() }
        }
        default { $t += [pscustomobject]@{ Key = ('{0}|any' -f $Product.Id); Target = 'any'; For = 'any'; Product = $Product; Problem = ''; Lines = @() } }
    }
    return $t
}

function Get-AllTargets {
    param([switch]$EnabledOnly)
    $all = @()
    foreach ($p in @(Get-Products -EnabledOnly:$EnabledOnly)) { $all += @(Get-ProductTargets -Product $p) }
    return $all
}

# ---------------------------------------------------------------------
#  Versions and .NET line sets
# ---------------------------------------------------------------------
function Get-RegexVersion {
    # The version a product's VersionRegex reads out of a file name: its groups, numbered or named, joined with dots
    # in their order - or the whole match when the pattern has no group.  '' when there is no pattern or no match.
    param([string]$Text, [string]$Pattern)
    if (-not $Pattern) { return '' }
    $found = [regex]::Match([string]$Text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $found.Success) { return '' }
    $parts = @(for ($i = 1; $i -lt $found.Groups.Count; $i++) { if ($found.Groups[$i].Success -and $found.Groups[$i].Value) { $found.Groups[$i].Value } })
    if ($parts.Count -eq 0) { return $found.Value }
    return ($parts -join '.')
}

function ConvertTo-VersionObject {
    # '12.5.4' or '12.5.4.24964629' -> [version] with four parts, or $null when it is not a version at all.
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if ($t -notmatch '^\d+(\.\d+){0,3}') { return $null }
    $parts = @(($Matches[0] -split '\.') | ForEach-Object { [int64]$_ })
    while ($parts.Count -lt 4) { $parts += 0 }
    try { return [version]::new([int]$parts[0], [int]$parts[1], [int]$parts[2], [int][math]::Min([int]::MaxValue, $parts[3])) } catch { return $null }
}

function Get-DotNetLinesFromTitle {
    # "3.5, 4.7.2 and 4.8" -> 4.7.2, 4.8 (3.5 rides along in every rollup and is not a line the environment names)
    param([string]$Text)
    return @([regex]::Matches([string]$Text, '\d+\.\d+(\.\d+)?') | ForEach-Object { $_.Value } | Where-Object { $_ -ne '3.5' } | Select-Object -Unique)
}

function Test-DotNetLinesFit {
    # A .NET rollup fits when it covers at least one line in use and no line that is not (a rollup for 4.7.2 and 4.8
    # is not fetched for a fleet on 4.8 and 4.8.1: the WinRM toolkit would show it as a column nobody needs).
    param([string[]]$Covered, [string[]]$InUse)
    $c = @($Covered | Where-Object { $_ }); $u = @($InUse | Where-Object { $_ })
    if ($c.Count -eq 0 -or $u.Count -eq 0) { return $false }
    foreach ($x in $c) { if ($u -notcontains $x) { return $false } }
    return $true
}

function Get-VMwareToolsWanted {
    # From the environment and the version map (05-Sources: Get-VMwareToolsVersionMap): the version wanted, or the line.
    # Returns @{ Mode = 'exact' | 'line' | 'latest'; Version = '12.5.4'; Line = '12.5'; Reason }.
    param($Map)
    $e = $script:Environment
    if ($e.VMwareToolsRule -eq 'latest') { return @{ Mode = 'latest'; Version = ''; Line = ''; Reason = 'the rule is latest: the newest release there is' } }
    if ($e.VMwareToolsRule -eq 'pin') { return @{ Mode = 'exact'; Version = $e.VMwareToolsPin; Line = ''; Reason = ('pinned to {0} on the Settings tab' -f $e.VMwareToolsPin) } }
    $esx = [string]$e.EsxiVersion
    $rows = @($Map | Where-Object { $_.Esx -and ($_.Esx -eq $esx -or $_.Esx -like ($esx + '*')) })
    if ($rows.Count -eq 0) { return @{ Mode = 'none'; Version = ''; Line = ''; Reason = ("the VMware version map lists no ESXi '{0}': check the ESXi version on the Settings tab (7.0, 8.0, 9.0 ...)" -f $esx) } }
    $newest = @($rows | Sort-Object { ConvertTo-VersionObject $_.Tools } -Descending)[0]
    if ($e.VMwareToolsRule -eq 'shipped') { return @{ Mode = 'exact'; Version = $newest.Tools; Line = ''; Reason = ('ESXi {0} ships VMware Tools {1} (the newest of its line in the version map)' -f $newest.Esx, $newest.Tools) } }
    $v = ConvertTo-VersionObject $newest.Tools
    return @{ Mode = 'line'; Version = $newest.Tools; Line = ('{0}.{1}' -f $v.Major, $v.Minor); Reason = ('ESXi {0} ships VMware Tools {1}: the newest {2}.{3} release is wanted' -f $newest.Esx, $newest.Tools, $v.Major, $v.Minor) }
}
