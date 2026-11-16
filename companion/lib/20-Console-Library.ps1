# =====================================================================
#  20-Console-Library.ps1  -  THE LIBRARY CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The upper grid: one row per product and target (a Windows build, the
#  ESXi line, "any") - what the library holds, what the source has, and
#  the verdict: Current (green), Download (amber), Held by a rule (blue),
#  failed or changed (red), not checked (grey).  The lower grid: every
#  file in the library with the manifest's facts.  The buttons: Check
#  for updates (asks the sources, changes nothing), Download ticked,
#  Check and download (the unattended run, by hand), Tick all and
#  Untick all (the ticks Download ticked reads), Verify library,
#  Remove file, Report, the folder, Help.
# =====================================================================

$script:LibraryColumns = @(
    @{ Name = 'Item'; Width = 300 }, @{ Name = 'Verdict'; Width = 110 }, @{ Name = 'In library'; Width = 150 }, @{ Name = 'Latest found'; Width = 220 }
    @{ Name = 'Size'; Width = 80 }, @{ Name = 'Published'; Width = 90 }, @{ Name = 'Verified'; Width = 160 }, @{ Name = 'Source'; Width = 90 }, @{ Name = 'Checked'; Width = 130 }, @{ Name = 'Reason'; Width = 240; Fill = $true })
$script:LibraryFileColumns = @(
    @{ Name = 'File'; Width = 360 }, @{ Name = 'Folder'; Width = 150 }, @{ Name = 'Product'; Width = 180 }, @{ Name = 'For'; Width = 120 }, @{ Name = 'KB / version'; Width = 120 }
    @{ Name = 'Size'; Width = 80 }, @{ Name = 'State'; Width = 200 }, @{ Name = 'Signer'; Width = 150 }, @{ Name = 'Downloaded'; Width = 130 }, @{ Name = 'SHA256'; Width = 200; Fill = $true })

function Get-LibraryGridRows {
    # The grid's rows: Item = "<product> for <target>" (unique, the tick key), the verdict word, the rest from Get-LibraryRows.
    return @(Get-LibraryRows | ForEach-Object {
        $item = '{0} for {1}' -f $_.Product, $_.For
        $suffix = ''; if ($_.Candidate -and $_.Key -like '*#*') { $suffix = ([string]$_.Key -split '#', 2)[1] }   # the KB, or the file where two files carry one KB
        if ($suffix) { $item += ' - ' + $suffix }
        [pscustomobject]@{ Item = $item; Verdict = $_.Verdict; 'In library' = $_.'In library'; 'Latest found' = $_.'Latest found'; Size = $_.Size; Published = $_.Published; Verified = $_.Verified; Source = $_.Source; Checked = $_.Checked; Reason = $_.Reason; Light = $_.Light; Row = $_ }
    })
}

function Update-LibraryGrids {
    $grid = $script:Gui['LibraryGrid']; if (-not $grid) { return }
    $rows = @(Get-LibraryGridRows)
    Set-GridRows -Grid $grid -Rows $rows -RowColour { param($r) Get-LightColour $r.Light } -ToolTipProperty 'Reason'
    $counts = @{}; foreach ($r in $rows) { $counts[$r.Verdict] = 1 + [int]$counts[$r.Verdict] }
    $parts = @(); foreach ($v in @('Current', 'Download', 'Unverified', 'Held', 'Stale', 'Check failed', 'Download failed', 'Changed', 'Not checked', 'Not set up', 'By hand', 'Off')) { if ($counts[$v]) { $parts += ('{0} {1}' -f $counts[$v], $v.ToLower()) } }
    $script:Gui['LibraryHeader'].Info.Text = ('{0} row(s): {1}   -   {2}' -f $rows.Count, ($parts -join ', '), (Get-EnvironmentText))
    $files = @(Get-LibraryFileRows)
    Set-GridRows -Grid $script:Gui['LibraryFileGrid'] -Rows $files -RowColour { param($r) Get-LightColour $r.Light } -ToolTipProperty 'State' -NoKeepChecks
    $bytes = 0; foreach ($f in $files) { $bytes += [int64]$f.Row.SizeBytes }
    $script:Gui['LibraryFileHeader'].Info.Text = ('{0} file(s), {1} in {2}' -f $files.Count, (Format-ByteSize $bytes), $script:Config.LibraryFolder)
}

function Get-ReleaseNotesHtml {
    # The "Release notes" lines of a details page: each address once, as a link, with what it belongs to.  '' when
    # there is none - a product whose vendor publishes no release notes simply has no such section.
    param($Links)   # an ordered dictionary: address -> what it belongs to
    if (-not $Links -or $Links.Count -eq 0) { return '' }
    return ('<ul>' + ((@($Links.Keys) | ForEach-Object { '<li>' + (ConvertTo-HtmlSafe ([string]$Links[$_])) + ': ' + (Get-HtmlLink -Url ([string]$_)) + '</li>' }) -join '') + '</ul>')
}

function Get-LibraryRowDetailsHtml {
    # The page behind a double-click on a product row: why the row says what it says, the vendor's release notes as a
    # link (of the candidate and of what the library holds), the candidate, the library files of the product.
    param($Row)
    $r = $Row.Row
    $facts = @(@('Product', $r.Product), @('For', $r.For), @('Verdict', $r.Verdict), @('Source', $r.Source), @('Checked', $(if ($r.Checked) { $r.Checked } else { 'not yet' })))
    $sections = @(@{ Heading = 'Why'; Lines = @($r.Reason) })
    $c = $r.Candidate
    $product = Get-Product -Id (([string]$r.Key -split '\|')[0])
    $links = [ordered]@{}
    if ($c) {
        $address = Get-ReleaseNotesUrl -Product $product -Version ([string]$c.Version) -Kb ([string]$c.KB)
        if ($address) { $links[$address] = ('{0} - the latest found' -f $(if ($c.KB) { $c.KB } elseif ($c.Version) { $c.Version } else { $r.Product })) }
    }
    foreach ($f in @($r.Files)) {
        $address = [string]$f.ReleaseNotes
        if (-not $address) { continue }
        if ($links.Contains($address)) { if ($links[$address] -notmatch 'in the library') { $links[$address] += ', and in the library' } }
        else { $links[$address] = ('{0} - in the library' -f $(if ($f.KB) { $f.KB } elseif ($f.Version) { $f.Version } else { $f.File })) }
    }
    if ($links.Count -eq 0) { $address = Get-ReleaseNotesUrl -Product $product; if ($address) { $links[$address] = ('{0} - every version' -f $r.Product) } }   # a page that covers every version needs no check first
    $notes = Get-ReleaseNotesHtml -Links $links
    if ($notes) { $sections += @{ Heading = 'Release notes'; Html = $notes } }
    if ($c) {
        $cand = @(
            [pscustomobject]@{ Item = 'Title'; Value = $c.Title }
            [pscustomobject]@{ Item = 'KB / version'; Value = $(if ($c.KB) { '{0} ({1})' -f $c.KB, $c.Version } else { $c.Version }) }
            [pscustomobject]@{ Item = '.NET lines covered'; Value = ($c.Lines -join ', ') }
            [pscustomobject]@{ Item = 'File'; Value = $c.FileName }
            [pscustomobject]@{ Item = 'Size'; Value = $(if ($c.SizeBytes -gt 0) { '{0} ({1} bytes)' -f (Format-ByteSize $c.SizeBytes), $c.SizeBytes } else { '' }) }
            [pscustomobject]@{ Item = 'Published'; Value = $c.Published }
            [pscustomobject]@{ Item = 'Classification'; Value = $c.Classification }
            [pscustomobject]@{ Item = 'Download link'; Value = $c.Url }
            [pscustomobject]@{ Item = 'Hash the source publishes'; Value = $(if ($c.Sha1 -and $c.Sha256) { 'SHA1 ' + $c.Sha1 + ' and SHA256 ' + $c.Sha256 } elseif ($c.Sha1) { 'SHA1 ' + $c.Sha1 } elseif ($c.Sha256) { 'SHA256 ' + $c.Sha256 } else { 'none - the signature, the size and a SHA256 of our own are the checks' }) }
            [pscustomobject]@{ Item = 'Goes to'; Value = $c.Folder }
            [pscustomobject]@{ Item = 'Rule'; Value = $c.Reason })
        $sections += @{ Heading = 'What the source has'; Rows = @($cand | Where-Object { $_.Value }); Columns = @('Item', 'Value') }
    }
    $files = @($r.Files | ForEach-Object { [pscustomobject]@{ Light = $_.Light; File = $_.File; 'KB / version' = $(if ($_.KB) { $_.KB } else { $_.Version }); Size = $_.Size; State = $_.State; Signer = $_.Signer; Downloaded = $_.Downloaded; SHA256 = $_.Sha256; Source = $_.Source } })
    $sections += @{ Heading = 'In the library for this product'; Rows = $files; Columns = @('Light', 'File', 'KB / version', 'Size', 'State', 'Signer', 'Downloaded', 'SHA256', 'Source') }
    return (New-DetailsHtml -Title $Row.Item -Subtitle ('{0} - {1}' -f $r.Verdict, $r.Reason) -Console 'Library' -Facts $facts -Sections $sections)
}

function Get-LibraryFileDetailsHtml {
    param($Row)
    $f = $Row.Row
    $e = $f.Entry
    $rows = @(
        [pscustomobject]@{ Item = 'File'; Value = $f.Path }
        [pscustomobject]@{ Item = 'Product'; Value = $(if ($f.ProductName) { '{0} ({1})' -f $f.ProductName, $f.Product } else { 'not a product of data\products.psd1' }) }
        [pscustomobject]@{ Item = 'For'; Value = $f.For }
        [pscustomobject]@{ Item = 'KB / version'; Value = $(if ($f.KB) { '{0} {1}' -f $f.KB, $f.Version } else { $f.Version }) }
        [pscustomobject]@{ Item = '.NET lines'; Value = ($f.Lines -join ', ') }
        [pscustomobject]@{ Item = 'Size'; Value = ('{0} ({1} bytes)' -f $f.Size, $f.SizeBytes) }
        [pscustomobject]@{ Item = 'State'; Value = $f.State }
        [pscustomobject]@{ Item = 'SHA256'; Value = $f.Sha256 }
        [pscustomobject]@{ Item = 'SHA1'; Value = $(if ($e) { [string]$e.Sha1 } else { '' }) }
        [pscustomobject]@{ Item = 'Checked at the download'; Value = $(if ($e) { [string]$e.Checks } else { '' }) }
        [pscustomobject]@{ Item = 'Signature'; Value = $(if ($e) { '{0}, {1}' -f $e.Signature, $e.Signer } else { '' }) }
        [pscustomobject]@{ Item = 'Downloaded'; Value = $(if ($e) { '{0} by {1}' -f $e.Downloaded, $e.DownloadedBy } else { $f.Downloaded + ' (file date; placed by hand)' }) }
        [pscustomobject]@{ Item = 'Verified'; Value = $(if ($e) { [string]$e.Verified } else { '' }) }
        [pscustomobject]@{ Item = 'Download link'; Value = $f.Source }
        [pscustomobject]@{ Item = 'Published'; Value = $f.Published })
    $sections = @()
    $links = [ordered]@{}
    if ($f.ReleaseNotes) { $links[[string]$f.ReleaseNotes] = [string]$(if ($f.KB) { $f.KB } elseif ($f.Version) { $f.Version } else { $f.File }) }
    $notes = Get-ReleaseNotesHtml -Links $links
    if ($notes) { $sections += @{ Heading = 'Release notes'; Html = $notes } }
    $sections += @{ Heading = 'The file'; Rows = @($rows | Where-Object { $_.Value }); Columns = @('Item', 'Value') }
    return (New-DetailsHtml -Title $f.File -Subtitle $f.State -Console 'Library' -Facts @(@('Folder', $f.Folder), @('State', $f.State)) -Sections $sections)
}

function Invoke-LibraryCheckTicked {
    # Check for updates: with no row ticked, every product that is fetched; with ticks, only the ticked rows.  A row is
    # one product for one target (a Windows build, the ESXi line), so a tick on "... for Server 2022" asks the source
    # about Server 2022 alone.  A ticked row that is Off is left out: its product is not fetched at all.
    $ticked = @(Get-GridCheckedRows -Grid $script:Gui['LibraryGrid'])
    if ($ticked.Count -eq 0) { $null = Invoke-LibraryCheck; return }
    $keys = @($ticked | ForEach-Object { [string]$_.Row.Key -replace '#.*$', '' } | Select-Object -Unique)   # the rows of one target (two .NET rollups) share its key
    $targets = @(Get-AllTargets | Where-Object { $keys -contains $_.Key })
    $wanted = @($targets | Where-Object { [bool]$_.Product.Enabled })
    $off = $targets.Count - $wanted.Count
    if ($wanted.Count -eq 0) { Show-GuiNotice 'Every ticked row is Off (its product is not ticked on the Products tab): nothing to check. Untick all to check every product.'; return }
    Write-PatchLog ("Check for updates: the {0} ticked row(s) only{1} - untick all to check every product" -f $wanted.Count, $(if ($off -gt 0) { ' ({0} ticked row(s) are Off and left out)' -f $off } else { '' })) 'INFO'
    foreach ($group in @($wanted | Group-Object { [string]$_.Product.Id })) { $null = Get-ProductCandidates -Product $group.Group[0].Product -Targets @($group.Group) }
    Set-GuiStatus 'Check finished'
}

function Invoke-LibraryDownloadTicked {
    # Download ticked: the ticked rows that say Download are fetched, and the ticked rows that say Unverified - a file
    # placed by hand under the candidate's name - are checked where they lie, after one Yes that lists both.  Tick all
    # ticks every row, so a ticked row that says something else is the usual case: it is left alone, and one log line
    # counts them.
    $grid = $script:Gui['LibraryGrid']
    $ticked = @(Get-GridCheckedRows -Grid $grid)
    if ($ticked.Count -eq 0) { Show-GuiNotice 'Tick the rows to download first (Tick all ticks every row).'; return }
    $todo = @($ticked | Where-Object { $_.Row.Verdict -eq 'Download' -and $_.Row.Candidate })
    $inPlace = @($ticked | Where-Object { $_.Row.Verdict -eq 'Unverified' -and $_.Row.Candidate -and $_.Row.PlacedFile })
    $skipped = @($ticked | Where-Object { $todo -notcontains $_ -and $inPlace -notcontains $_ })
    if ($skipped.Count -gt 0) {
        $kinds = @($skipped | Group-Object { [string]$_.Verdict } | ForEach-Object { '{0} {1}' -f $_.Count, $_.Name.ToLower() })
        Write-PatchLog ("{0} ticked row(s) left alone, they say neither Download nor Unverified: {1}" -f $skipped.Count, ($kinds -join ', ')) 'INFO'
    }
    if ($todo.Count + $inPlace.Count -eq 0) {
        $unchecked = @($ticked | Where-Object { $_.Verdict -eq 'Not checked' }).Count
        Show-GuiNotice ('None of the ticked rows says Download or Unverified: nothing to do.' + $(if ($unchecked -gt 0) { " Not checked yet: $unchecked - press Check for updates first." } else { '' }))
        return
    }
    $asks = @()
    if ($todo.Count -gt 0) {
        $bytes = 0; foreach ($t in $todo) { $bytes += [int64]$t.Row.Candidate.SizeBytes }
        $asks += ("Download {0} file(s), {1}, into {2}?`n`n" -f $todo.Count, (Format-ByteSize $bytes), $script:Config.LibraryFolder) + (($todo | ForEach-Object { '- {0}: {1} ({2})' -f $_.Item, $_.Row.Candidate.FileName, (Format-ByteSize $_.Row.Candidate.SizeBytes) }) -join "`n")
    }
    if ($inPlace.Count -gt 0) { $asks += ("Check {0} file(s) placed by hand where they lie? Nothing is fetched, and a file that does not pass is left alone.`n`n" -f $inPlace.Count) + (($inPlace | ForEach-Object { '- {0}: {1}' -f $_.Item, $_.Row.PlacedFile.File }) -join "`n") }
    $text = ($asks -join "`n`n") + "`n`nEvery file is checked (size, the published hash, the signature) before it counts; older files of the same product are then removed (KeepPrevious on the Settings tab)."
    if ((Show-PatcherMessage -Title 'Download' -Buttons 'YesNo' -Icon 'Question' -Text $text) -ne 'Yes') { Write-PatchLog 'Download not started (answered No)' 'INFO'; return }
    $ok = 0; $bad = 0; $okPlaced = 0
    foreach ($t in $inPlace) { $res = Confirm-PlacedFile -Candidate $t.Row.Candidate -File $t.Row.PlacedFile; if ($res.Success) { $okPlaced++ } else { $bad++ } }
    foreach ($t in $todo) { $res = Invoke-CandidateDownload -Candidate $t.Row.Candidate; if ($res.Success) { $ok++ } else { $bad++ } }
    Write-PatchLog ("Download finished: {0} fetched and verified, {1}{2} failed" -f $ok, $(if ($inPlace.Count -gt 0) { '{0} placed by hand verified where they lie, ' -f $okPlaced } else { '' }), $bad) $(if ($bad -gt 0) { 'WARN' } else { 'OK' })
}

function Invoke-LibraryFileRemove {
    $grid = $script:Gui['LibraryFileGrid']
    $row = Get-GridSelectedRow -Grid $grid
    if (-not $row) { Show-GuiNotice 'Select a file in the lower grid first.'; return }
    if (-not (Test-GuiDialogAllowed 'The Remove question')) { return }
    $a = Show-PatcherMessage -Title 'Remove file' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("Delete this file from the library?`n`n{0}`n{1}, {2}`n`nThe WinRM toolkit will no longer see it. Check for updates lists it again if the source still has it." -f $row.Path, $row.Size, $row.State)
    if ($a -ne 'Yes') { Write-PatchLog 'Remove file: answered No' 'INFO'; return }
    Remove-LibraryFile -Path $row.Path
}

function Get-LibraryHelpHtml {
    $verdicts = New-HelpTable -Headers @('Verdict', 'Means', 'What to do') -Rows @(
        , @((Get-HelpCell 'Current' (Get-LightColour 'Green')), 'The newest appropriate file of the product is in the library and its hashes still match.', 'Nothing. Carry the library over when the month''s files are all green.')
        , @((Get-HelpCell 'Download' (Get-LightColour 'Amber')), 'The source has a newer or missing file that fits the environment.', 'Tick it and press Download ticked, or Check and download for everything at once.')
        , @((Get-HelpCell 'Unverified' (Get-LightColour 'Amber')), 'A file with the name the source gives is in the library, but a person placed it there: nothing has compared it with the source. Red: it was compared and did not pass.', 'Tick it and press Download ticked, or run Check and download: the file is checked where it lies (size, the published hash, the signature) and recorded when it passes; nothing is fetched. When it is red, remove it (Remove file) and download.')
        , @((Get-HelpCell 'Held' (Get-LightColour 'Blue')), 'The source has it, but a rule says no: a .NET rollup for lines not in use, a VMware Tools release outside the ESXi line.', 'Nothing, unless the first box of the Settings tab is wrong - then change it there and check again.')
        , @((Get-HelpCell 'Stale' (Get-LightColour 'Red')), 'Patch Tuesday of this month is some days behind and the check still found only an older month''s cumulative update. Microsoft has most likely changed how the Update Catalog names or classifies its updates, and this tool then needs an update. A run with such a row fails.', 'Compare with Microsoft''s release list (the reason names its address). Look for a newer version of this tool, or correct TitleMatch / Classification in data\products.psd1. A build that gets no more updates: untick it on the Settings tab.')
        , @((Get-HelpCell 'Check failed' (Get-LightColour 'Red')), 'The source could not be read: no internet, a proxy, a changed page, a product name the catalogue does not know.', 'Read the reason (hover, or double-click). Fix the connection or data\products.psd1, check again.')
        , @((Get-HelpCell 'Download failed' (Get-LightColour 'Red')), 'The file arrived but failed a check - wrong size, wrong hash, unsigned or signed by someone else - and was deleted; or the connection broke. Nothing that was already in the library is touched.', 'Read the reason. A hash or signature failure means the source served something other than the catalogue describes: do not fetch it by hand.')
        , @((Get-HelpCell 'Changed' (Get-LightColour 'Red')), 'A library file no longer matches the hash recorded when it was verified.', 'Remove it (Remove file) and download it again.')
        , @((Get-HelpCell 'Not checked' (Get-LightColour 'Grey')), 'No check has run in this session.', 'Press Check for updates.')
        , @((Get-HelpCell 'Not set up' (Get-LightColour 'Grey')), 'The environment names no build, .NET line or ESXi version for this product, or the catalogue name of a build is missing.', 'Nothing, when the site does not use the product: no ESXi version or no .NET line is a choice and never fails a run. Otherwise the first box of the Settings tab, or data\products.psd1 (CatalogProducts) - a missing catalogue name does fail a run.')
        , @((Get-HelpCell 'By hand' (Get-LightColour 'Grey')), 'A product whose installer link a person gives (Splunk Universal Forwarder): none is given yet. Not a failure.', 'Find the installer on the vendor''s page (the row names it), paste its link on the Products tab and save; the tool then fetches the file and checks it against the vendor''s checksum file.')
        , @((Get-HelpCell 'Off' (Get-LightColour 'Grey')), 'The product is not ticked on the Products tab.', 'Tick it there and save when the product is part of the SOE.'))
    $buttons = New-HelpTable -Headers @('Button', 'Does', 'Changes the library?') -Rows @(
        , @((Get-HelpButton 'Check for updates' 'lightskyblue'), 'Asks the sources what the newest appropriate file is (the Update Catalog per build, the VMware package site, each link) and fills the Latest found column. With no row ticked every product is asked; with ticks, only the ticked rows (a ticked row that is Off is left out). Not available while a download runs.', 'No - it only looks.')
        , @((Get-HelpButton 'Download ticked' 'steelblue'), 'Fetches the ticked rows that say Download, and checks the ticked rows that say Unverified where they lie, after a Yes that lists the files and sizes. A file arrives in a folder of its own (_incoming) and takes its place only when it has passed every check; then the older files of the same product are removed.', 'Yes.')
        , @(((Get-HelpButton 'Tick all') + ' ' + (Get-HelpButton 'Untick all')), 'Ticks, or clears the tick of, every row at once. A tick narrows Check for updates to the ticked rows, and picks the rows for Download ticked (only those that say Download or Unverified).', 'No.')
        , @((Get-HelpButton 'Check and download' 'steelblue'), 'What the scheduled task does: check everything, check what says Unverified where it lies, download what says Download, hash the library again, write settings\last-run.json and a report.', 'Yes.')
        , @((Get-HelpButton 'Verify library'), 'Hashes every file the manifest knows again and flags one that changed or was truncated. The log shows the Get-FileHash command for each file and the SHA256 it gave, then how many files and how much data were hashed. A file placed by hand has no recorded hash, so it is not checked; the log names those.', 'Only the manifest''s verified stamps.')
        , @((Get-HelpButton 'Remove file' 'lightcoral'), 'Deletes the file selected in the lower grid, after a Yes.', 'Yes.')
        , @((Get-HelpButton 'Report'), 'This page as HTML and CSV in reports\.', 'No.')
        , @((Get-HelpButton 'Open library folder'), 'The library in Explorer.', 'No.'))
    $notes = @'
WHAT A CHECK DOES

  * Windows cumulative update: the Update Catalog is searched for "<month> Cumulative Update for <the build's catalogue name> for x64-based Systems", this month first and then earlier months (CatalogMonthsBack on the Settings tab). A month may hold more than one cumulative update: the monthly security release of Patch Tuesday and, some months, an out-of-band release after it. Each is cumulative, so the newest of the month includes the others and is the one taken; the row's reason names the ones it includes. The optional preview ("Cumulative Update Preview") is left.
  * A cumulative update comes every month. When Patch Tuesday is some days behind and only an older month is found, the row says Stale and a run fails: Microsoft has most likely changed how the catalogue names or classifies its updates, and this tool needs an update. The reason names Microsoft's own release list to compare with.
  * The download link is asked for as the catalogue's own Download button asks, and the link's digest, the SHA1 in the file name and the file itself must all agree.
  * Server 2025: the catalogue lists two files for the month's update - the update itself and the checkpoint cumulative update it builds on (KB5043080). Both are candidates: the checkpoint is fetched once and stays beside every later monthly update, because DISM needs it there on a server that has not had it.
  * Server 2016: the servicing stack still comes as a file of its own, one a month ("<month> Servicing Stack Update for Windows Server 2016 ..."); it has its own row, and the WinRM toolkit installs it before the cumulative update. Server 2019 and later carry it inside the cumulative update.
  * Every page of a search is read (the catalogue shows 25 rows a page), and a page read that fails for a moment - no answer in time, HTTP 5xx, the catalogue's own "error number 8DDD0010" page - is tried again as often as a download is (Settings tab).
  * .NET Framework cumulative update: the same search for ".NET Framework". A month may offer several rollups per build (3.5 and 4.8 / 3.5 and 4.8.1 / 3.5, 4.7.2 and 4.8); one that covers only lines ticked on the Settings tab is a candidate, one that covers a line not in use is Held.
  * VMware Tools: the version map on the package site says which Tools each ESXi line ships. The ESXi version and the rule on the Settings tab pick the version (that exact release, the newest of its line, the newest there is, or a pinned one); the x64 installer of that release is the candidate.
  * A fixed link (Source url): the link always serves the current version, so the size and date of the link are compared with what was fetched last; a change means a new version. The version is read from inside the file after the download and becomes part of the file name.
  * An index page (Source index): a regular expression in data\products.psd1 picks the links and their versions; the newest wins; a checksum page, when the vendor has one, gives the SHA256 the download must have. The page may be HTML, a checksum list or a JSON answer. PuTTY, OpenSSH, Wireshark (stable releases only: an even minor number) and Notepad++ are read this way. Firefox ESR: Mozilla's version list names the version and the link is built from it. WinSCP: the link sits on the file's own page with a token that lives for minutes, so that page is read again just before the download.
  * Microsoft Edge (Source edge): Microsoft's list for administrators names the newest Stable release for Windows, its MSI and its SHA256.
  * A link given by hand (Source manual; Splunk Universal Forwarder): the tool reads no vendor page. The link pasted on the Products tab is fetched and compared with the vendor's checksum file beside it. Without a link the row says By hand, and that is not a failure.

WHAT A DOWNLOAD CHECKS

  * A file arrives in _incoming\ inside its product's folder and is checked there. It takes its place in the library only when all of the following has passed; one that fails is deleted from _incoming, and nothing that was already in the library is touched.
  * One download may take as long as "Give up on one download after" on the Settings tab says, a connection that sends nothing for two minutes is dropped and tried again, and the size limit of the Settings tab holds whether or not the server announces a size.

  1. The size the source announced, byte for byte.
  2. The hash the source publishes: the catalogue's SHA1 (twice: in the link's digest and in the file name) and the SHA256 it gives for the files of its newer delivery service (Server 2025), a vendor's SHA256. A mismatch deletes the file and the row goes red - the file is not what the catalogue describes. What was compared is kept with the file ("size; SHA1 and SHA256 published by the source; signed by Microsoft Corporation"); a source that publishes no hash says so there.
  3. The Authenticode signature: Valid, and the signer's organisation starts with one of the product's Signers (Microsoft Corporation, VMware or Broadcom, Google LLC ...). The WinRM toolkit checks this again before an install.
  4. A SHA256 of its own, recorded in library-manifest.json and CHECKSUMS.txt in the library folder, so the other side can check the file by hand (Get-FileHash, certutil -hashfile) and so a later change on disk is noticed.

THE LIBRARY

  * Beside the WinRM toolkit (this folder inside its folder) the library IS its patches\ and software\ folders: a verified download is a column in its O/S Patching or Software console at the next Reload. Elsewhere it is library\ in this folder, or the folder on the Settings tab: carry patches\ and software\ over.
  * Only the newest file of each product, build and .NET line stays (KeepPrevious on the Settings tab keeps more): the 4.8 and the 4.8.1 rollup of one build sit side by side, and a Server 2025 checkpoint stays beside the monthly update. A file the manifest does not know - placed by hand - is never deleted and shows as "placed by hand". When it carries the name a source gives for the current file, its row says Unverified until Download ticked or a run has checked it where it lies; it is then recorded like a download.
  * The window and the scheduled task may run at the same time: one of them at a time writes the manifest.
  * The lower grid is the library as it is; double-click a file for everything recorded about it.
  * Double-click a row of either grid for its details. Where the vendor publishes release notes, the page has them as a link - the KB article of an update, the release notes or change log of an installer - and a click opens it in your browser. The download link is shown as text only: a file fetched by hand passes none of the checks.
'@
    return (New-DetailsHtml -Title 'Help: the Library console' -Subtitle 'what the grid says, what the buttons do, what is checked' -Console 'Library' -Sections @(
        @{ Heading = 'The verdicts'; Html = $verdicts }, @{ Heading = 'The buttons'; Html = $buttons }, @{ Heading = ''; Html = (ConvertTo-HtmlFromNotes -Text $notes) }))
}

function New-LibraryConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Library' -Text 'Library'
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'
    $tab.Controls.Add($split)

    $grid = New-ConsoleGrid -Columns $script:LibraryColumns
    $grid.Add_DoubleClick({ $r = Get-GridSelectedRow -Grid $this; if ($r -and (Test-GuiDialogAllowed 'The details window')) { Show-DetailsWindow -Title $r.Item -Html (Get-LibraryRowDetailsHtml -Row $r) } })
    $head = New-GridHeader -Heading 'Products' -Detail '' -Tip 'One row per product and target. Double-click a row for the candidate, the rule and the library files of the product.'
    $split.Panel1.Controls.Add($grid); $split.Panel1.Controls.Add($head.Panel); $grid.BringToFront()
    $script:Gui['LibraryGrid'] = $grid; $script:Gui['LibraryHeader'] = $head

    $fgrid = New-ConsoleGrid -Columns $script:LibraryFileColumns -NoCheckBoxes
    $fgrid.Add_DoubleClick({ $r = Get-GridSelectedRow -Grid $this; if ($r -and (Test-GuiDialogAllowed 'The details window')) { Show-DetailsWindow -Title $r.File -Html (Get-LibraryFileDetailsHtml -Row $r) } })
    $fhead = New-GridHeader -Heading 'Library files' -Detail '' -Tip 'Every file in the library folders the products use, with what the manifest recorded. Double-click a file for its hashes and signer.'
    $split.Panel2.Controls.Add($fgrid); $split.Panel2.Controls.Add($fhead.Panel); $fgrid.BringToFront()
    $script:Gui['LibraryFileGrid'] = $fgrid; $script:Gui['LibraryFileHeader'] = $fhead
    $script:Gui['LibrarySplit'] = $split

    $toolbar = New-ConsoleToolbar -Tab $tab -Height 56
    $x = 8
    $toolbar.Controls.Add((New-GuiButton -Text 'Check for updates' -X $x -Y 8 -W 140 -H 40 -Colour 'LightSkyBlue' -Tip 'Asks the sources what the newest appropriate file is: every product, or only the ticked rows - changes nothing in the library' -OnClick { Invoke-GuiAction -Name 'Check for updates' -Action { Invoke-LibraryCheckTicked } })); $x += 145   # not -ReadOnly: it asks the sources itself, and beside a download it would hold the download up
    $toolbar.Controls.Add((New-GuiButton -Text 'Download ticked' -X $x -Y 8 -W 130 -H 40 -Colour 'SteelBlue' -Tip 'Fetches the ticked rows that say Download and checks those that say Unverified where they lie (after a Yes)' -OnClick { Invoke-GuiAction -Name 'Download ticked' -Action { Invoke-LibraryDownloadTicked } })); $x += 135
    $toolbar.Controls.Add((New-GuiButton -Text 'Check and download' -X $x -Y 8 -W 150 -H 40 -Colour 'SteelBlue' -Tip 'The whole run, as the scheduled task does it: check, download what is missing, verify, report' -OnClick { Invoke-GuiAction -Name 'Check and download' -Action { $r = Invoke-LibraryRun; Write-PatchLog ("Run {0}: {1}" -f $r.Outcome, $r.Summary) $(if ($r.ExitCode -eq 0) { 'OK' } else { 'WARN' }) } })); $x += 155
    $toolbar.Controls.Add((New-GuiButton -Text 'Tick all' -X $x -Y 8 -W 80 -H 40 -ReadOnly -Tip 'Ticks every row - Download ticked fetches those that say Download' -OnClick { Set-GridChecks -Grid $script:Gui['LibraryGrid'] -Checked $true })); $x += 85
    $toolbar.Controls.Add((New-GuiButton -Text 'Untick all' -X $x -Y 8 -W 90 -H 40 -ReadOnly -Tip 'Clears every tick' -OnClick { Set-GridChecks -Grid $script:Gui['LibraryGrid'] -Checked $false })); $x += 95
    $toolbar.Controls.Add((New-GuiButton -Text 'Verify library' -X $x -Y 8 -W 110 -H 40 -Tip 'Hashes every file the manifest knows again; a changed file goes red' -OnClick { Invoke-GuiAction -Name 'Verify library' -Action { $null = Test-LibraryIntegrity } })); $x += 115
    $toolbar.Controls.Add((New-GuiButton -Text 'Remove file' -X $x -Y 8 -W 100 -H 40 -Colour 'LightCoral' -Tip 'Deletes the file selected in the lower grid (after a Yes)' -OnClick { Invoke-GuiAction -Name 'Remove file' -Action { Invoke-LibraryFileRemove } })); $x += 105
    $toolbar.Controls.Add((New-GuiButton -Text 'Report' -X $x -Y 8 -W 80 -H 40 -ReadOnly -Tip 'This console as HTML and CSV in reports\' -OnClick { Invoke-GuiAction -Name 'Library report' -ReadOnly -Action { Show-ReportDone -Report (Export-LibraryReport) } })); $x += 85
    $toolbar.Controls.Add((New-GuiButton -Text 'Open library folder' -X $x -Y 8 -W 140 -H 40 -ReadOnly -Tip 'The library in Explorer' -OnClick { Invoke-GuiAction -Name 'Open library folder' -ReadOnly -Action { if (-not (Test-Path -LiteralPath $script:Config.LibraryFolder)) { New-Item -ItemType Directory -Path $script:Config.LibraryFolder -Force | Out-Null }; Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:Config.LibraryFolder) } })); $x += 145
    $toolbar.Controls.Add((New-GuiButton -Text 'Help' -X $x -Y 8 -W 70 -H 40 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Library help' -ReadOnly -Action { Show-ConsoleHelp -Console 'Library' -Html (Get-LibraryHelpHtml) } }))
    $quip = New-Object System.Windows.Forms.Label
    $quip.Text = Get-RandomQuip; $quip.ForeColor = 'DimGray'; $quip.AutoSize = $true; $quip.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic); $quip.Location = New-Object System.Drawing.Point(($x + 80), 20)
    $toolbar.Controls.Add($quip); $script:Gui['QuipLabel'] = $quip

    $null = New-ConsoleBanner -Tab $tab -Console 'Library' -Title 'LIBRARY' -Subtitle 'the newest appropriate update of every product, fetched and verified for the airgap'
    $split.BringToFront()
    $split.Add_SizeChanged({ try { if ($this.Height -gt 300) { $this.SplitterDistance = [int]($this.Height * 0.55) } } catch { } })
    Register-ConsoleRefresher -Console 'Library' -Refresh { Update-LibraryGrids }
}
