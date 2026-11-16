# =====================================================================
#  05-Sources.ps1  -  WHERE THE FILES COME FROM
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  One adapter per Source of data\products.psd1, each turning a target
#  (product x build / ESXi line / any) into CANDIDATES: what the newest
#  appropriate file is, where it is, how big, and what hash the source
#  itself publishes for it.
#    catalog       the Microsoft Update Catalog: a search per month (every
#                  page of it), the rows read from the page, the download
#                  links asked for as the Download button does - every
#                  file the update has (Server 2025: the update and its
#                  checkpoint); the file name carries the SHA1 of the
#                  file, and so does the link's digest; a SHA256 comes
#                  with the files of the newer delivery service
#    vmware-tools  packages.vmware.com/tools: the version map (which Tools
#                  each ESXi line ships), the releases index, the x64 folder
#    url           a fixed link (always the current version): size and date
#                  from the headers, the version read from inside the file
#                  after the download
#    index         a vendor index page: a regular expression picks the
#                  links and their versions; an optional checksum page;
#                  the link may come from a template (FileUrl) or from a
#                  page of the file's own (FilePage: a link with a token)
#    edge          Microsoft's Edge list for administrators (JSON): the
#                  newest Stable release, its MSI and its SHA256
#    manual        a link the operator gives on the Products tab (a
#                  vendor whose page is read by a person): the file and
#                  the vendor's checksum file beside it
#  Everything read is text; nothing from a page is ever run.
# =====================================================================

function Get-ToolkitToday {
    # The day the month rules work from: the clock, unless $script:TodayOverride names another day.
    if ($script:TodayOverride) { return [datetime]$script:TodayOverride }
    return (Get-Date)
}

function Get-CatalogMonths {
    # This month and the earlier ones the Settings tab allows, newest first: "2026-11", "2026-10", ...
    $n = [math]::Max(0, [int]$script:Config.CatalogMonthsBack)
    $today = Get-ToolkitToday
    return @(for ($i = 0; $i -le $n; $i++) { $today.AddMonths(-$i).ToString('yyyy-MM') })
}

function Get-PatchTuesday {
    # The second Tuesday of a month: the day Microsoft publishes the month's cumulative updates.
    param([datetime]$Month)
    $first = New-Object datetime($Month.Year, $Month.Month, 1)
    $toTuesday = (([int][System.DayOfWeek]::Tuesday - [int]$first.DayOfWeek) + 7) % 7
    return $first.AddDays($toTuesday + 7)
}

function Get-CatalogExpectedMonth {
    # The newest month that must have a cumulative update by now: this month once Patch Tuesday is CatalogStaleDays
    # behind (time for the release to reach the catalogue, and for the time zones), else the month before.
    $today = (Get-ToolkitToday).Date
    $grace = 3; if ($null -ne $script:Config.CatalogStaleDays) { $grace = [math]::Max(0, [int]$script:Config.CatalogStaleDays) }
    if ($today -ge (Get-PatchTuesday -Month $today).AddDays($grace)) { return $today.ToString('yyyy-MM') }
    return $today.AddMonths(-1).ToString('yyyy-MM')
}

function Get-CatalogStaleText {
    # Why a product that gets an update every month looks out of date: the newest month the search found is older than
    # the month that must exist by now.  The usual cause is on Microsoft's side - a title or a classification that
    # changed - and then this tool needs an update, so the text says so.  '' when nothing is out of date.
    param([string]$FoundMonth, [string]$Kb = '')
    $expected = Get-CatalogExpectedMonth
    if ([string]::CompareOrdinal($FoundMonth, $expected) -ge 0) { return '' }
    $due = Get-PatchTuesday -Month ([datetime]::ParseExact($expected + '-01', 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture))
    $days = [int]((Get-ToolkitToday).Date - $due).TotalDays
    return ('no {0} cumulative update was found, though Patch Tuesday was {1}, {2} day(s) ago - the newest found is {3}{4}. Microsoft may have changed how the Update Catalog names or classifies its updates, and this tool may need an update: compare with {5} (a build that gets no more updates: untick it on the Settings tab)' -f $expected, $due.ToString('yyyy-MM-dd'), $days, $FoundMonth, $(if ($Kb) { ' (' + $Kb + ')' } else { '' }), $script:Config.ReleaseInfoUrl)
}

function Select-NewestCatalogRow {
    # The newest of the cumulative updates one month has: the monthly security release, and an out-of-band release
    # after it that includes it.  By the OS build in the title where every title carries one (Server 2025:
    # "(26100.33828)"), else by the catalogue's date; the higher KB number settles a tie.
    param([object[]]$Rows)
    $keyed = @(foreach ($r in @($Rows)) {
        $build = [int64]-1; $bm = [regex]::Match([string]$r.Title, '\((\d+)\.(\d+)\)\s*$'); if ($bm.Success) { $build = [int64]$bm.Groups[1].Value * 1000000 + [int64]$bm.Groups[2].Value }
        $number = [int64]0; if ([string]$r.KB -match '(\d+)') { $number = [int64]$Matches[1] }
        $when = [datetime]::MinValue; if ($r.Updated) { $when = [datetime]$r.Updated }
        [pscustomobject]@{ Row = $r; Build = $build; Number = $number; When = $when }
    })
    if ($keyed.Count -eq 0) { return $null }
    if (@($keyed | Where-Object { $_.Build -lt 0 }).Count -eq 0) { return @($keyed | Sort-Object Build, Number -Descending)[0].Row }
    return @($keyed | Sort-Object When, Number -Descending)[0].Row
}

function ConvertFrom-CatalogSearchPage {
    # The rows of a catalog search page: Id (the update id), Title, Products, Classification, Updated, SizeBytes.
    param([string]$Html)
    $rows = @()
    foreach ($m in [regex]::Matches($Html, '(?s)<tr id="(?<id>[0-9a-f]{8}-[0-9a-f-]{27})_R\d+"[^>]*>(?<row>.*?)</tr>')) {
        $id = $m.Groups['id'].Value; $row = $m.Groups['row'].Value
        $cell = { param([int]$n) $c = [regex]::Match($row, ('(?s)_C{0}_R\d+"[^>]*>(?<v>.*?)</td>' -f $n)); if (-not $c.Success) { return '' }; $t = $c.Groups['v'].Value -replace '<[^>]+>', ' '; return ([System.Net.WebUtility]::HtmlDecode($t) -replace '\s+', ' ').Trim() }
        $title = & $cell 1
        $size = 0; $sm = [regex]::Match($row, '_originalSize">\s*(\d+)\s*<'); if ($sm.Success) { $size = [int64]$sm.Groups[1].Value }
        $updated = $null; $dt = & $cell 4
        if ($dt) { try { $updated = [datetime]::ParseExact($dt, 'M/d/yyyy', [System.Globalization.CultureInfo]::InvariantCulture) } catch { $updated = $null } }
        $kb = ''; $km = [regex]::Match($title, '\((KB\d+)\)(\s*\(\d+\.\d+\))?\s*$'); if ($km.Success) { $kb = $km.Groups[1].Value }   # a Server 2025 title ends "(KB5131080) (26100.33822)"
        $rows += [pscustomobject]@{ Id = $id; Title = $title; KB = $kb; Products = (& $cell 2); Classification = (& $cell 3); Updated = $updated; SizeBytes = $size }
    }
    return $rows
}

function Get-CatalogErrorNumber {
    # The catalogue answers a busy moment with a page of its own ("[Error number: 8DDD0010]") and HTTP 200, not with an
    # HTTP error: '' for a real page, else the number - the caller tries again.
    param([string]$Html)
    $m = [regex]::Match([string]$Html, 'Error number:\s*(8DDD[0-9A-Fa-f]{4})')
    if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    return ''
}

function Get-CatalogPage {
    # One catalogue page (-Fields: a form post, else a GET), read again when the catalogue sends its error page.
    param([Parameter(Mandatory = $true)][string]$Url, [hashtable]$Fields = $null)
    $tries = Get-WebTries
    for ($attempt = 1; ; $attempt++) {
        if ($Fields) { $html = Invoke-WebPost -Url $Url -Fields $Fields } else { $html = Get-WebText -Url $Url }
        $number = Get-CatalogErrorNumber -Html $html
        if (-not $number) { return $html }
        $why = ('the catalog answered with its error page (error number {0})' -f $number)
        if ($attempt -ge $tries) { throw ("{0}, {1} time(s) - it is busy: check again later ({2})" -f $why, $tries, $Url) }
        Wait-WebRetry -Attempt $attempt -Tries $tries -Why $why
    }
}

function Search-UpdateCatalog {
    # Every row of a search.  The catalogue shows 25 rows a page, and a search by a long product name is wide (the Server
    # 2025 name brings dynamic updates and other months too: 26 rows on 2026-11-11), so a full page is followed by the
    # next (&p=1 ...) - the wanted row must never be lost to the page break.  At most CatalogMaxPages pages.
    param([Parameter(Mandatory = $true)][string]$Query)
    $base = '{0}/Search.aspx?q={1}' -f $script:Config.CatalogUrl.TrimEnd('/'), [uri]::EscapeDataString($Query)
    $maxPages = 4; if ($script:Config.CatalogMaxPages) { $maxPages = [math]::Max(1, [int]$script:Config.CatalogMaxPages) }
    $rows = @(); $seen = @{}; $pages = 0
    for ($page = 0; $page -lt $maxPages; $page++) {
        $url = $base; if ($page -gt 0) { $url = $base + '&p=' + $page }
        $pageRows = @(ConvertFrom-CatalogSearchPage -Html (Get-CatalogPage -Url $url))
        $pages++
        $new = 0
        foreach ($r in $pageRows) { if (-not $seen.ContainsKey($r.Id)) { $seen[$r.Id] = $true; $rows += $r; $new++ } }
        if ($pageRows.Count -lt 25 -or $new -eq 0) { break }
    }
    Write-PatchLog ("catalog: '{0}' - {1} row(s){2}" -f $Query, $rows.Count, $(if ($pages -gt 1) { ' on ' + $pages + ' pages' } else { '' })) 'INFO'
    return $rows
}

function ConvertFrom-CatalogDownloadPage {
    # The download dialog's answer: one entry per file - Url, FileName, Sha1 (the digest, base64 in the page, hex here) and
    # Sha256 (the page's sha256, base64 too; given for the files of the newer delivery service - Server 2025 - and empty
    # for the others, seen 2026-11-11).
    param([string]$Html)
    $files = @{}
    foreach ($m in [regex]::Matches($Html, "downloadInformation\[\d+\]\.files\[(?<i>\d+)\]\.(?<k>\w+)\s*=\s*'(?<v>[^']*)'")) {
        $i = [int]$m.Groups['i'].Value
        if (-not $files.ContainsKey($i)) { $files[$i] = @{ Url = ''; FileName = ''; Sha1 = ''; Sha256 = '' } }
        $v = $m.Groups['v'].Value
        switch ($m.Groups['k'].Value) {
            'url'      { $files[$i].Url = $v }
            'fileName' { $files[$i].FileName = $v }
            'digest'   { try { $files[$i].Sha1 = ([System.BitConverter]::ToString([Convert]::FromBase64String($v)) -replace '-', '').ToLower() } catch { } }
            { $_ -in 'sha256', 'sha' } { if ($v -match '^[0-9a-fA-F]{64}$') { $files[$i].Sha256 = $v.ToLower() } elseif ($v -match '^[A-Za-z0-9+/=]{40,}$') { try { $h = ([System.BitConverter]::ToString([Convert]::FromBase64String($v)) -replace '-', '').ToLower(); if ($h.Length -eq 64) { $files[$i].Sha256 = $h } } catch { } } }
        }
    }
    return @($files.Keys | Sort-Object | ForEach-Object { [pscustomobject]$files[$_] } | Where-Object { $_.Url })
}

function Get-CatalogDownload {
    # The file(s) behind one update id, as the catalog's Download button gets them.
    param([Parameter(Mandatory = $true)][string]$UpdateId)
    $url = '{0}/DownloadDialog.aspx' -f $script:Config.CatalogUrl.TrimEnd('/')
    $fields = @{ updateIDs = ('[{{"size":0,"updateID":"{0}","uidInfo":"{0}"}}]' -f $UpdateId); updateIDsBlockedForImport = ''; wsusApiPresent = ''; contentImport = ''; sku = ''; serverName = ''; ssl = ''; portNumber = ''; version = '' }
    $html = Get-CatalogPage -Url $url -Fields $fields
    $files = @(ConvertFrom-CatalogDownloadPage -Html $html)
    if ($files.Count -eq 0) { throw "the catalog gave no download link for update $UpdateId" }
    return $files
}

function ConvertTo-CatalogFileCandidates {
    # The files the catalogue lists for one Windows update, as candidates.  One file: the update itself.  Several (Server
    # 2025: the month's cumulative update AND the checkpoint cumulative update it builds on, KB5043080): one candidate
    # per file.  The file that carries the title's KB is the update; every other is a prerequisite that DISM needs
    # beside it on a server that has not had it - fetched too, and kept in a slot of its own so the monthly update never
    # prunes it.  The order of the files in the page is not relied on.  The row's size is the total, so each file's own
    # size is asked from its link (-SizeOf is what asks it).
    param($Target, $Row, [object[]]$Files, [string]$Month, [scriptblock]$SizeOf = { param($u) (Get-WebHead -Url $u).Length }, [string]$Note = '')
    $published = $(if ($Row.Updated) { $Row.Updated.ToString('yyyy-MM-dd') } else { '' })
    $what = ('the {0} {1} for {2} ({3})' -f $Month, $Target.Product.Name.ToLower(), $Target.For, $Row.Classification)
    if ($Note) { $what += '; ' + $Note }   # e.g. which other cumulative updates the month has
    $list = @($Files)
    if ($list.Count -eq 1) {
        $f = $list[0]
        return @(New-Candidate -Target $Target -Values @{ Title = $Row.Title; KB = $Row.KB; SizeBytes = $Row.SizeBytes; Published = $published; Classification = $Row.Classification; UpdateId = $Row.Id; Reason = $what; Version = $Month; Url = $f.Url; FileName = $f.FileName; Sha1 = $f.Sha1; Sha256 = $f.Sha256 })
    }
    $main = ''
    if ($Row.KB) { $hit = @($list | Where-Object { $_.FileName -match ('(?i)-' + [regex]::Escape($Row.KB) + '-') }); if ($hit.Count -ge 1) { $main = $hit[0].FileName } }
    if (-not $main) { Write-PatchLog ("{0}: the catalog lists {1} files and none carries {2} in its name - every one is fetched" -f $Row.Title, $list.Count, $Row.KB) 'WARN' }
    $out = @(); $n = 0
    foreach ($f in $list) {
        $n++
        $kb = $Row.KB; if ($f.FileName -match '(?i)-(kb\d+)-') { $kb = $Matches[1].ToUpper() }
        $size = [int64]0; try { $size = [int64](& $SizeOf $f.Url) } catch { $size = 0 }
        $values = @{ Title = $Row.Title; KB = $kb; SizeBytes = $size; Published = $published; Classification = $Row.Classification; UpdateId = $Row.Id; Url = $f.Url; FileName = $f.FileName; Sha1 = $f.Sha1; Sha256 = $f.Sha256 }
        if ($main -and $f.FileName -ieq $main) { $values.Version = $Month; $values.Reason = ('{0}; the catalog lists {1} files for it' -f $what, $list.Count) }
        elseif ($main) { $values.Version = 'checkpoint'; $values.Slot = ('prerequisite-' + $kb); $values.Reason = ('a checkpoint cumulative update the catalog lists with {0}: DISM needs it beside the update on a server that has not had it' -f $Row.KB) }
        else { $values.Version = $Month; $values.Slot = ('file' + $n); $values.Reason = ('{0}; file {1} of {2}' -f $what, $n, $list.Count) }
        $out += New-Candidate -Target $Target -Values $values
    }
    return @($out | Sort-Object { $_.Version -eq 'checkpoint' }, KB)
}

function Test-CatalogFileHash {
    # The file name carries the SHA1 too (windows10.0-kb5126655-x64_8053239c....msu): it and the link's digest must agree.
    param($Candidate)
    $nm = [regex]::Match($Candidate.FileName, '_([0-9a-f]{40})\.(msu|cab|exe)$')
    if (-not $nm.Success) { return }
    if ($Candidate.Sha1 -and $nm.Groups[1].Value -ne $Candidate.Sha1) { throw ("{0}: the SHA1 in the file name ({1}) and the link's digest ({2}) disagree - not fetched" -f $Candidate.KB, $nm.Groups[1].Value, $Candidate.Sha1) }
    if (-not $Candidate.Sha1) { $Candidate.Sha1 = $nm.Groups[1].Value }
}

function Get-DotNetLinesFromFileName {
    # windows10.0-kb5127687-x64-ndp48_....msu -> 4.8; -ndp481 -> 4.8.1; -ndp472 -> 4.7.2.  Empty when the name has no ndp token.
    param([string]$FileName)
    if ($FileName -notmatch '(?i)-ndp(\d{2,3})[_.-]') { return @() }
    return @(, (([string]$Matches[1]).ToCharArray() -join '.'))
}

function Get-CatalogTitlePattern {
    param($Target)
    return $Target.Product.TitleMatch.Replace('{product}', [regex]::Escape($Target.CatalogProduct)).Replace('{arch}', [regex]::Escape($script:Environment.Architecture))
}

function Select-CatalogRows {
    # The rows of one search that are the product for this target: the title pattern, one of the product's
    # classifications (it may name several), nothing excluded.
    param($Target, [object[]]$Rows)
    $pattern = Get-CatalogTitlePattern -Target $Target
    $p = $Target.Product
    $classes = @($p.Classification | Where-Object { $_ })
    $out = @()
    foreach ($r in @($Rows)) {
        if ($r.Title -notmatch $pattern) { continue }
        if ($p.Exclude -and $r.Title -match $p.Exclude) { continue }
        if ($classes.Count -gt 0 -and $classes -notcontains $r.Classification) { continue }
        $out += $r
    }
    return $out
}

function New-Candidate {
    # The one shape every adapter returns.
    param($Target, [hashtable]$Values)
    $c = [ordered]@{ Key = $Target.Key; ProductId = $Target.Product.Id; ProductName = $Target.Product.Name; Source = $Target.Product.Source; Target = $Target.Target; For = $Target.For
        Title = ''; KB = ''; Version = ''; Lines = @(); FileName = ''; Url = ''; SizeBytes = [int64]0; Published = ''; Classification = ''; UpdateId = ''
        Sha1 = ''; Sha256 = ''; RemoteStamp = ''; Slot = ''; FreshFrom = ''; Stale = ''; Folder = (Get-ProductLibraryFolder -Product $Target.Product); Verdict = 'Appropriate'; Reason = ''; Found = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }   # Slot: Get-PruneSlot in 06-Library.ps1; Stale: Get-CatalogStaleText
    foreach ($k in $Values.Keys) { $c[$k] = $Values[$k] }
    return [pscustomobject]$c
}

function Get-CatalogCandidates {
    # The newest cumulative update of this product for this build: the months searched newest first until one is found.
    # A .NET month may hold several rollups (3.5 and 4.8 / 3.5 and 4.8.1 / 3.5, 4.7.2 and 4.8): those that fit the
    # .NET lines in use are candidates, the others are listed as held, so the operator sees why they were left.
    param($Target)
    $p = $Target.Product
    $arch = [string]$script:Environment.Architecture
    foreach ($month in Get-CatalogMonths) {
        $query = $p.Query.Replace('{month}', $month).Replace('{product}', $Target.CatalogProduct).Replace('{arch}', $arch)
        $rows = @(Select-CatalogRows -Target $Target -Rows @(Search-UpdateCatalog -Query $query) | Where-Object { $_.Title -like ($month + ' *') })
        if ($rows.Count -eq 0) { Write-PatchLog ("{0} for {1}: nothing for {2} - looking at the month before" -f $p.Name, $Target.For, $month) 'WHY'; continue }
        $out = @()
        if ($p.Lines) {
            # a .NET entry: one candidate per FILE.  "3.5, 4.8 and 4.8.1" for Server 2022 is one entry with an ndp48 file and
            # an ndp481 file, each its own KB; only the files for the lines in use are fetched.  An entry whose title names
            # no line in use is held without asking for its files.
            # Several entries of a month can reference the same file (Server 2019: "3.5, 4.7.2 and 4.8" holds the files of
            # "3.5 and 4.7.2" and "3.5 and 4.8"), so the files are collected first and each is judged once, by the ndp token in
            # its name or else by the title of the narrowest entry that lists it.
            $inUse = @($Target.Lines)
            $pairs = @(); $held = @(); $kbLines = @{}
            foreach ($r in @($rows | Sort-Object Updated -Descending)) {
                $m = [regex]::Match($r.Title, (Get-CatalogTitlePattern -Target $Target))
                $covered = @(Get-DotNetLinesFromTitle -Text $m.Groups['lines'].Value)
                $kbLines[$r.KB] = $covered   # an entry's own KB names its lines: a file without an ndp token is labelled by the entry that shares its KB
                $published = $(if ($r.Updated) { $r.Updated.ToString('yyyy-MM-dd') } else { '' })
                if (@($covered | Where-Object { $inUse -contains $_ }).Count -eq 0) {
                    $held += New-Candidate -Target $Target -Values @{ Title = $r.Title; KB = $r.KB; Lines = $covered; SizeBytes = $r.SizeBytes; Published = $published; Classification = $r.Classification; UpdateId = $r.Id; Verdict = 'Not for this environment'; Reason = ('covers .NET {0}, but the environment runs {1} (Settings tab)' -f ($covered -join ', '), ($inUse -join ', ')); Version = $month }
                    continue
                }
                $files = @(Get-CatalogDownload -UpdateId $r.Id)
                foreach ($f in $files) { $pairs += [pscustomobject]@{ Row = $r; Covered = $covered; File = $f; Count = $files.Count; Published = $published } }
            }
            foreach ($g in @($pairs | Group-Object { $_.File.FileName.ToLower() })) {
                $best = @($g.Group | Sort-Object { $_.Covered.Count })[0]   # the narrowest entry names the file's own lines
                $f = $best.File; $r = $best.Row
                $kb = $r.KB; if ($f.FileName -match '(?i)-(kb\d+)-') { $kb = $Matches[1].ToUpper() }
                $fileLines = @(Get-DotNetLinesFromFileName -FileName $f.FileName)
                if ($fileLines.Count -eq 0) { if ($kbLines.ContainsKey($kb)) { $fileLines = @($kbLines[$kb]) } else { $fileLines = @($best.Covered) } }
                $size = [int64]0; if ($best.Count -eq 1) { $size = $r.SizeBytes } else { try { $size = (Get-WebHead -Url $f.Url).Length } catch { $size = 0 } }
                $others = @($g.Group | Where-Object { $_.Row.KB -ne $r.KB } | ForEach-Object { $_.Row.KB } | Select-Object -Unique)
                $fits = Test-DotNetLinesFit -Covered $fileLines -InUse $inUse
                $verdict = 'Appropriate'; $reason = ('covers .NET {0}; the environment runs {1}{2}' -f ($fileLines -join ', '), ($inUse -join ', '), $(if ($others.Count -gt 0) { ' (also part of ' + ($others -join ', ') + ')' } else { '' }))
                if (-not $fits) { $verdict = 'Not for this environment'; $reason = ('covers .NET {0}, but the environment runs {1} (Settings tab)' -f ($fileLines -join ', '), ($inUse -join ', ')) }
                $c = New-Candidate -Target $Target -Values @{ Title = $r.Title; KB = $kb; Lines = $fileLines; SizeBytes = $size; Published = $best.Published; Classification = $r.Classification; UpdateId = $r.Id; Verdict = $verdict; Reason = $reason; Version = $month; Url = $f.Url; FileName = $f.FileName; Sha1 = $f.Sha1; Sha256 = $f.Sha256 }
                Test-CatalogFileHash -Candidate $c
                $out += $c
            }
            # a held entry whose file is already listed under its own KB (as part of a wider entry) is not listed twice
            $seenKb = @($out | ForEach-Object { $_.KB })
            foreach ($h in $held) { if ($seenKb -notcontains $h.KB) { $out += $h } }
            return @($out | Sort-Object { $_.Verdict -ne 'Appropriate' }, KB)
        } else {
            # a month may hold more than one cumulative update: the monthly security release and an out-of-band release
            # after it.  Each is cumulative, so the newest includes the others and is the one to have.
            $r = Select-NewestCatalogRow -Rows $rows
            $note = ''
            if ($rows.Count -gt 1) {
                $others = @($rows | Where-Object { $_.Id -ne $r.Id } | ForEach-Object { '{0} ({1}, {2})' -f $_.KB, $(if ($_.Updated) { $_.Updated.ToString('yyyy-MM-dd') } else { 'no date' }), $_.Classification })
                $note = ('the newest of the {0} cumulative updates of {1}: it includes {2}' -f $rows.Count, $month, ($others -join ' and '))
                Write-PatchLog ("{0} for {1}: {2} cumulative updates for {3} - the newest ({4}) is taken; it includes {5}" -f $p.Name, $Target.For, $rows.Count, $month, $r.KB, ($others -join ' and ')) 'WHY'
            }
            # the download link, file name and the catalog's own hashes of every file the update has
            $out = @(ConvertTo-CatalogFileCandidates -Target $Target -Row $r -Files @(Get-CatalogDownload -UpdateId $r.Id) -Month $month -Note $note)
            foreach ($c in $out) { Test-CatalogFileHash -Candidate $c }
            # a product that gets an update every month: an older month than there must be by now is said on the row
            if ($p.Monthly) {
                $stale = Get-CatalogStaleText -FoundMonth $month -Kb $r.KB
                if ($stale) {
                    foreach ($c in @($out | Where-Object { $_.Version -ne 'checkpoint' })) { $c.Stale = $stale }
                    Write-PatchLog ("{0} for {1}: {2}" -f $p.Name, $Target.For, $stale) 'WARN'
                }
            }
        }
        return $out
    }
    throw ("nothing found for {0} in the last {1} month(s): the search was '{2}' - check the catalogue name of the build in data\products.psd1, or raise CatalogMonthsBack on the Settings tab. Microsoft may have changed how the Update Catalog names or classifies its updates, and this tool may need an update: compare with {3}" -f $Target.For, (Get-CatalogMonths).Count, $p.Query.Replace('{month}', (Get-CatalogMonths)[-1]).Replace('{product}', $Target.CatalogProduct).Replace('{arch}', $arch), $script:Config.ReleaseInfoUrl)
}

# ---------------------------------------------------------------------
#  VMware Tools
# ---------------------------------------------------------------------
function ConvertFrom-VMwareVersionMap {
    # packages.vmware.com/tools/versions: "13349  esx/9.1.1  25677323  13.1.5  25544008" (the ESXi build is missing on esx/0.0 rows).
    param([string]$Text)
    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $m = [regex]::Match($line, '^\s*(?<code>\d+)\s+esx/(?<esx>\S+)\s+(?:(?<esxbuild>\d+)\s+)?(?<tools>\d+\.\d+\.\d+)\s+(?<toolsbuild>\d+)\s*$')
        if (-not $m.Success) { continue }
        $esx = $m.Groups['esx'].Value; if ($esx -eq '0.0') { $esx = '' }
        $rows += [pscustomobject]@{ Code = [int]$m.Groups['code'].Value; Esx = $esx; EsxBuild = $m.Groups['esxbuild'].Value; Tools = $m.Groups['tools'].Value; ToolsBuild = $m.Groups['toolsbuild'].Value }
    }
    return $rows
}

function Get-VMwareToolsVersionMap {
    $text = Get-WebText -Url ($script:Config.VMwareToolsUrl.TrimEnd('/') + '/versions')
    $rows = @(ConvertFrom-VMwareVersionMap -Text $text)
    if ($rows.Count -eq 0) { throw 'the VMware version map could not be read (no rows)' }
    return $rows
}

function ConvertFrom-FolderIndex {
    # The links of a plain folder listing (href="12.5.4/", href="VMware-tools-12.5.4-24964629-x64.exe").
    param([string]$Html)
    return @([regex]::Matches($Html, 'href="(?<h>[^"?#]+)"') | ForEach-Object { [System.Net.WebUtility]::HtmlDecode($_.Groups['h'].Value) } | Where-Object { $_ -and $_ -ne '../' -and $_ -ne '/' })
}

function Get-VMwareToolsReleases {
    # Every version folder of packages.vmware.com/tools/releases/, newest first.
    $html = Get-WebText -Url ($script:Config.VMwareToolsUrl.TrimEnd('/') + '/releases/')
    $v = @(ConvertFrom-FolderIndex -Html $html | Where-Object { $_ -match '^\d+\.\d+\.\d+/$' } | ForEach-Object { $_.TrimEnd('/') })
    if ($v.Count -eq 0) { throw 'the VMware releases index lists no versions' }
    return @($v | Sort-Object { ConvertTo-VersionObject $_ } -Descending)
}

function Get-VMwareToolsCandidates {
    param($Target)
    $p = $Target.Product
    $map = Get-VMwareToolsVersionMap
    $wanted = Get-VMwareToolsWanted -Map $map
    if ($wanted.Mode -eq 'none') { throw $wanted.Reason }
    $releases = Get-VMwareToolsReleases
    $version = ''
    switch ($wanted.Mode) {
        'exact'  { if ($releases -contains $wanted.Version) { $version = $wanted.Version } else { throw ("VMware Tools {0} is not on the package site ({1}): the newest there is {2}" -f $wanted.Version, $wanted.Reason, $releases[0]) } }
        'line'   { $version = @($releases | Where-Object { $_ -like ($wanted.Line + '.*') })[0]; if (-not $version) { throw ("no {0}.x release on the package site ({1})" -f $wanted.Line, $wanted.Reason) } }
        'latest' { $version = $releases[0] }
    }
    $archFolder = 'x64'; if ($script:Environment.Architecture -eq 'arm64') { $archFolder = 'arm' }
    $folderUrl = '{0}/releases/{1}/windows/{2}/' -f $script:Config.VMwareToolsUrl.TrimEnd('/'), $version, $archFolder
    $links = @(ConvertFrom-FolderIndex -Html (Get-WebText -Url $folderUrl) | Where-Object { $_ -notmatch '/$' -and $_ -like $p.FilePattern })
    if ($links.Count -eq 0) { throw ("no file matching '{0}' in {1}" -f $p.FilePattern, $folderUrl) }
    $file = $links[0]
    $head = Get-WebHead -Url ($folderUrl + $file)
    $ver = Get-RegexVersion -Text $file -Pattern ([string]$p.VersionRegex); if (-not $ver) { $ver = $version }
    return @(New-Candidate -Target $Target -Values @{ Title = ('VMware Tools {0} for Windows {1}' -f $version, $archFolder); Version = $ver; FileName = $file; Url = ($folderUrl + $file); SizeBytes = $head.Length; Published = $head.LastModified; RemoteStamp = ('{0}|{1}' -f $head.Length, $head.LastModified); Reason = $wanted.Reason })
}

# ---------------------------------------------------------------------
#  A fixed link, and an index page
# ---------------------------------------------------------------------
function Get-UrlCandidates {
    param($Target)
    $p = $Target.Product
    $head = Get-WebHead -Url $p.Url
    $name = ''
    try { $name = [System.IO.Path]::GetFileName(([uri]$head.Url).LocalPath) } catch { }
    if (-not $name) { try { $name = [System.IO.Path]::GetFileName(([uri]$p.Url).LocalPath) } catch { } }
    if (-not $name) { throw "the link $($p.Url) names no file" }
    return @(New-Candidate -Target $Target -Values @{ Title = ('{0} - the current file behind the link' -f $p.Name); FileName = $name; Url = $p.Url; SizeBytes = $head.Length; Published = $head.LastModified; RemoteStamp = ('{0}|{1}' -f $head.Length, $head.LastModified); Reason = 'a fixed link always serves the current version; the version is read from inside the file after the download' })
}

function Expand-ProductTemplate {
    # {version}, {file} and {url} filled into a link or a pattern of data\products.psd1.  -Regex: the values are escaped
    # first, for use inside a regular expression.
    param([string]$Template, [string]$Version = '', [string]$File = '', [string]$Url = '', [switch]$Regex)
    $v = $Version; $f = $File; $u = $Url
    if ($Regex) { $v = [regex]::Escape($Version); $f = [regex]::Escape($File); $u = [regex]::Escape($Url) }
    return ([string]$Template).Replace('{version}', $v).Replace('{file}', $f).Replace('{url}', $u)
}

function Select-IndexVersion {
    # LinkRegex over a page (HTML, a checksum list, a JSON answer): every match with its groups "file" (the link) and
    # "version"; the newest version wins.  $null when nothing matches.  No web: it works on the text it is given.
    param([string]$Text, [string]$LinkRegex)
    $hits = @()
    foreach ($m in [regex]::Matches([string]$Text, $LinkRegex)) {
        $file = ''; if ($m.Groups['file'].Success) { $file = [System.Net.WebUtility]::HtmlDecode($m.Groups['file'].Value) }
        $ver = ''; if ($m.Groups['version'].Success) { $ver = $m.Groups['version'].Value }
        if (-not $file -and -not $ver) { continue }
        $hits += [pscustomobject]@{ File = $file; Version = $ver; V = (ConvertTo-VersionObject $ver) }
    }
    if ($hits.Count -eq 0) { return $null }
    return @($hits | Sort-Object V -Descending)[0]
}

function Resolve-FilePageLink {
    # The download link on a file's own page (WinSCP: the link carries a token that lives for minutes): FilePageRegex,
    # {version} filled in, group "file".  Read at the check and again just before the download.
    param($Product, [string]$Text, [string]$Version, [string]$PageUrl)
    $m = [regex]::Match([string]$Text, (Expand-ProductTemplate -Template $Product.FilePageRegex -Version $Version -Regex))
    if (-not $m.Success -or -not $m.Groups['file'].Success) { throw ("no download link on {0} (FilePageRegex in data\products.psd1)" -f $PageUrl) }
    return ([uri]::new([uri]$PageUrl, [System.Net.WebUtility]::HtmlDecode($m.Groups['file'].Value))).AbsoluteUri
}

function Get-PublishedSha256 {
    # The SHA256 a vendor publishes for a file.  ChecksumUrl ({version}, {file}, {url} filled in) is a text page, a JSON
    # answer or the file's own page; ChecksumRegex (group "hash") or else the first 64-hex word on the line that names
    # the file gives the hash.  '' when the product has no ChecksumUrl; it throws when it has one and no hash is found -
    # a product that promises a hash must give one.  $Pages: pages already read in this check (url -> text).
    param($Product, [string]$Version, [string]$FileName, [string]$Url, [hashtable]$Pages = @{})
    if (-not $Product.ChecksumUrl) { return '' }
    $cu = Expand-ProductTemplate -Template $Product.ChecksumUrl -Version $Version -File $FileName -Url $Url
    if ($Pages.ContainsKey($cu)) { $ct = [string]$Pages[$cu] } else { $ct = Get-WebText -Url $cu }
    $sha = ''
    if ($Product.ChecksumRegex) { $cm = [regex]::Match($ct, (Expand-ProductTemplate -Template $Product.ChecksumRegex -Version $Version -File $FileName -Regex)); if ($cm.Success) { $sha = $cm.Groups['hash'].Value } }
    else { foreach ($line in ($ct -split "`r?`n")) { if ($line -match [regex]::Escape($FileName) -and $line -match '\b([0-9a-fA-F]{64})\b') { $sha = $Matches[1]; break } } }
    if (-not $sha) { throw ("no SHA256 for {0} on {1}" -f $FileName, $cu) }
    return $sha.ToLower()
}

function Get-IndexCandidates {
    # LinkRegex runs over the index page with named groups: file (the link) and version.  The newest version is taken.
    # Where the link is not on that page:  FileUrl is a template for it ({version}: Firefox ESR - a version list, the
    # files elsewhere);  FilePage is a page of the file's own that holds the link (WinSCP - FilePageRegex picks it).
    # ChecksumUrl / ChecksumRegex give the SHA256 the download must have (Get-PublishedSha256).
    param($Target)
    $p = $Target.Product
    $pages = @{}
    $pages[[string]$p.IndexUrl] = Get-WebText -Url $p.IndexUrl
    $best = Select-IndexVersion -Text $pages[[string]$p.IndexUrl] -LinkRegex $p.LinkRegex
    if (-not $best) { throw ("nothing on {0} matches LinkRegex '{1}'" -f $p.IndexUrl, $p.LinkRegex) }
    $fresh = ''
    if ($p.FilePage) {
        $fresh = Expand-ProductTemplate -Template $p.FilePage -Version $best.Version -File $best.File
        $pages[$fresh] = Get-WebText -Url $fresh
        $url = Resolve-FilePageLink -Product $p -Text $pages[$fresh] -Version $best.Version -PageUrl $fresh
    } elseif ($p.FileUrl) {
        $url = Expand-ProductTemplate -Template $p.FileUrl -Version $best.Version -File $best.File
    } else {
        if (-not $best.File) { throw ("LinkRegex of product '{0}' needs a group 'file' (or the product a FileUrl or FilePage)" -f $p.Id) }
        $url = ([uri]::new([uri]$p.IndexUrl, $best.File)).AbsoluteUri
    }
    $name = [System.IO.Path]::GetFileName(([uri]$url).LocalPath)
    $size = [int64]0; $published = ''
    try { $head = Get-WebHead -Url $url; $size = [math]::Max([int64]0, [int64]$head.Length); $published = $head.LastModified }
    catch { if (-not $fresh) { throw }; Write-PatchLog ("{0}: the link's size could not be asked ({1}) - the published hash decides" -f $p.Name, (Get-ShortError $_)) 'WHY' }   # a link with a token may refuse HEAD
    $sha = Get-PublishedSha256 -Product $p -Version $best.Version -FileName $name -Url $url -Pages $pages
    return @(New-Candidate -Target $Target -Values @{ Title = ('{0} {1}' -f $p.Name, $best.Version); Version = $best.Version; FileName = $name; Url = $url; FreshFrom = $fresh; SizeBytes = $size; Published = $published; Sha256 = $sha; RemoteStamp = ('{0}|{1}' -f $size, $published); Reason = ('the newest version on {0}' -f $p.IndexUrl) })
}

# ---------------------------------------------------------------------
#  Microsoft Edge: the enterprise API
# ---------------------------------------------------------------------
function ConvertFrom-JsonText {
    # JSON of any size as nested dictionaries and arrays (ConvertFrom-Json gives up at 2 MB in Windows PowerShell 5.1)
    param([string]$Text)
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    return $serializer.DeserializeObject($Text)
}

function Select-EdgeRelease {
    # Out of the Edge enterprise API's answer: the newest release of a channel for Windows and an architecture that has an
    # MSI - version, link, hash and algorithm, size, date.  $null when there is none.  No web: it works on the answer it is given.
    param($Products, [string]$Channel = 'Stable', [string]$Architecture = 'x64')
    $prod = @(@($Products) | Where-Object { $_ -and [string]$_['Product'] -ieq $Channel })[0]
    if (-not $prod) { return $null }
    $best = $null; $bestV = $null
    foreach ($r in @($prod['Releases'])) {
        if (-not $r -or [string]$r['Platform'] -ine 'Windows' -or [string]$r['Architecture'] -ine $Architecture) { continue }
        $v = ConvertTo-VersionObject ([string]$r['ProductVersion']); if (-not $v) { continue }
        $msi = @(@($r['Artifacts']) | Where-Object { $_ -and [string]$_['ArtifactName'] -ieq 'msi' })[0]; if (-not $msi) { continue }
        if (-not $bestV -or $v -gt $bestV) { $bestV = $v; $best = [pscustomobject]@{ Version = [string]$r['ProductVersion']; Url = [string]$msi['Location']; Hash = [string]$msi['Hash']; Algorithm = [string]$msi['HashAlgorithm']; SizeBytes = [int64]$msi['SizeInBytes']; Published = ([string]$r['PublishedTime'] -replace 'T.*$', '') } }
    }
    return $best
}

function Get-EdgeCandidates {
    # The newest Stable release for Windows in Microsoft's own list for administrators, with the SHA256 it publishes.
    # The link's file name is the same for every version, so the version goes into the library's file name.
    param($Target)
    $p = $Target.Product
    $api = Get-ProductSourceUrl -Product $p
    $channel = [string]$p.Channel; if (-not $channel) { $channel = 'Stable' }
    $arch = [string]$script:Environment.Architecture
    $rel = Select-EdgeRelease -Products (ConvertFrom-JsonText -Text (Get-WebText -Url $api)) -Channel $channel -Architecture $arch
    if (-not $rel) { throw ("the Edge list ({0}) names no {1} release for Windows {2} with an MSI" -f $api, $channel, $arch) }
    if ($rel.Algorithm -ine 'SHA256' -or $rel.Hash -notmatch '^[0-9A-Fa-f]{64}$') { throw ("the Edge list gives no SHA256 for {0} (it says '{1}') - not fetched without one" -f $rel.Version, $rel.Algorithm) }
    $base = [System.IO.Path]::GetFileNameWithoutExtension(([uri]$rel.Url).LocalPath); if (-not $base) { $base = 'MicrosoftEdgeEnterprise' }
    return @(New-Candidate -Target $Target -Values @{ Title = ('{0} {1}' -f $p.Name, $rel.Version); Version = $rel.Version; FileName = ('{0}-{1}.msi' -f $base, $rel.Version); Url = $rel.Url; SizeBytes = $rel.SizeBytes; Published = $rel.Published; Sha256 = $rel.Hash.ToLower(); Reason = ('the newest {0} release for Windows {1} in Microsoft''s Edge list for administrators' -f $channel, $arch) })
}

# ---------------------------------------------------------------------
#  Where a product is looked for: the one address a person can open to see the source for themselves
# ---------------------------------------------------------------------
function Get-ProductSourceUrl {
    # The page (or list) a product's files are found on: the Update Catalog, the VMware package site, the fixed link, the
    # index page, Microsoft's Edge list, or - for a link given by hand - the vendor's page the operator reads.
    param($Product)
    switch ([string]$Product.Source) {
        'catalog'      { return [string]$script:Config.CatalogUrl }
        'vmware-tools' { return [string]$script:Config.VMwareToolsUrl }
        'url'          { return [string]$Product.Url }
        'index'        { return [string]$Product.IndexUrl }
        'edge'         { if ($Product.IndexUrl) { return [string]$Product.IndexUrl }; return 'https://edgeupdates.microsoft.com/api/products?view=enterprise' }
        'manual'       { return [string]$Product.ManualPage }
    }
    return ''
}

# ---------------------------------------------------------------------
#  A link given by hand (Products tab): the site decides the version, the tool fetches and proves the file
# ---------------------------------------------------------------------
function Get-ManualLink {
    param($Product)
    $links = $script:Environment.ManualLinks
    if ($links -and $links.Contains([string]$Product.Id)) { return ([string]$links[[string]$Product.Id]).Trim() }
    return ''
}

function Test-ManualLink {
    # A link given by hand for a product: https, and the shape its LinkPattern asks for.  Throws with the reason; returns
    # the version the link names (group "version"), or ''.
    param($Product, [string]$Link)
    if ($Link -notmatch '^https://\S+$') { throw 'the link must start with https:// and hold no spaces' }
    if ($Product.LinkPattern) {
        $m = [regex]::Match($Link, [string]$Product.LinkPattern)
        if (-not $m.Success) { throw ("it is not this product's installer link - expected {0}" -f $(if ($Product.LinkExample) { $Product.LinkExample } else { 'a link matching ' + $Product.LinkPattern })) }
        if ($m.Groups['version'].Success) { return $m.Groups['version'].Value }
    }
    return ''
}

function Get-ManualCandidates {
    # The installer behind the link the operator gave: its size from the link, its SHA256 from the vendor's checksum file
    # (ChecksumUrl, usually '{url}.sha256').  The vendor's download page is never read: the operator reads it.
    param($Target)
    $p = $Target.Product
    $link = Get-ManualLink -Product $p
    if (-not $link) { throw 'no link given on the Products tab' }
    $version = Test-ManualLink -Product $p -Link $link
    $name = [System.IO.Path]::GetFileName(([uri]$link).LocalPath)
    if (-not $name) { throw "the link names no file ($link)" }
    $head = Get-WebHead -Url $link
    $sha = Get-PublishedSha256 -Product $p -Version $version -FileName $name -Url $link
    return @(New-Candidate -Target $Target -Values @{ Title = ('{0} {1}' -f $p.Name, $version).Trim(); Version = $version; FileName = $name; Url = $link; SizeBytes = [math]::Max([int64]0, [int64]$head.Length); Published = $head.LastModified; Sha256 = $sha; RemoteStamp = ('{0}|{1}' -f $head.Length, $head.LastModified); Reason = 'the installer link given by hand on the Products tab' })
}

# ---------------------------------------------------------------------
#  The check: every target of a product, the result kept in $script:Candidates / $script:Checked
# ---------------------------------------------------------------------
function Get-ProductCandidates {
    # Asks the product's source for every target (or the given ones).  A target whose check fails keeps its error
    # (the grid shows "Check failed" with the reason) and the others carry on.  Returns every candidate found.
    param([Parameter(Mandatory = $true)]$Product, [object[]]$Targets = $null)
    if ($null -eq $Targets) { $Targets = @(Get-ProductTargets -Product $Product) }
    $all = @()
    foreach ($t in @($Targets)) {
        $when = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        Clear-CandidateResults -TargetKey $t.Key   # a new check: what an earlier download of this target came to no longer counts
        if ($t.Problem) { $script:Checked[$t.Key] = @{ When = $when; Error = $t.Problem; Kind = 'setup' }; $script:Candidates[$t.Key] = @(); continue }
        if ($t.Waiting) { $script:Checked[$t.Key] = @{ When = $when; Error = ''; Kind = 'waiting' }; $script:Candidates[$t.Key] = @(); continue }   # a link to be given by hand: nothing to ask, nothing failed
        Set-GuiStatus ("Checking {0} for {1} ..." -f $Product.Name, $t.For)
        try {
            $found = switch ($Product.Source) {
                'catalog'      { @(Get-CatalogCandidates -Target $t) }
                'vmware-tools' { @(Get-VMwareToolsCandidates -Target $t) }
                'url'          { @(Get-UrlCandidates -Target $t) }
                'index'        { @(Get-IndexCandidates -Target $t) }
                'edge'         { @(Get-EdgeCandidates -Target $t) }
                'manual'       { @(Get-ManualCandidates -Target $t) }
            }
            $script:Candidates[$t.Key] = @($found)
            $script:Checked[$t.Key] = @{ When = $when; Error = ''; Kind = 'check' }
            foreach ($c in @($found)) { Write-PatchLog ("{0} for {1}: {2}{3} - {4} ({5})" -f $Product.Name, $t.For, $c.Title, $(if ($c.FileName) { ' = ' + $c.FileName + ', ' + (Format-ByteSize $c.SizeBytes) } else { '' }), $c.Verdict, $c.Reason) $(if ($c.Verdict -eq 'Appropriate') { 'OK' } else { 'WHY' }) }
            $all += @($found)
        } catch {
            $script:Candidates[$t.Key] = @()
            $script:Checked[$t.Key] = @{ When = $when; Error = (Get-ShortError $_); Kind = 'check' }
            Write-PatchLog ("{0} for {1}: CHECK FAILED - {2}" -f $Product.Name, $t.For, (Get-ShortError $_)) 'ERROR'
        }
    }
    return $all
}

function Invoke-LibraryCheck {
    # Every enabled product (or the given ones) asked for its candidates.  Returns the candidates found.
    param([object[]]$Products = $null)
    if ($null -eq $Products) { $Products = @(Get-Products -EnabledOnly) }
    $found = @()
    foreach ($p in @($Products)) { $found += @(Get-ProductCandidates -Product $p) }
    Set-GuiStatus 'Check finished'
    return $found
}
