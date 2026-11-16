# =====================================================================
#  06-Library.ps1  -  THE LIBRARY: FOLDERS, MANIFEST, VERIFICATION, PRUNING, THE RUN
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The library is the WinRM toolkit's layout: patches\Windows, patches\
#  DotNet and software\<Folder>.  Every file this tool puts there is
#  recorded in library-manifest.json (product, version, hashes, signer,
#  where it came from, when) and in CHECKSUMS.txt ("sha256  path", for a
#  check by hand on the other side).  A download is kept only when it
#  passes every check: the size the source announced, the SHA1 the
#  catalog publishes, the SHA256 a vendor publishes, and an Authenticode
#  signature by one of the product's signers.  It is checked in
#  _incoming\ and takes its place only afterwards, so a failed download
#  never touches a file that was already there.  Then the older files of
#  the same product, build and .NET line go (KeepPrevious on the
#  Settings tab); what was compared is kept with the file.  A file a
#  person placed under a candidate's name is checked where it lies and
#  recorded when it passes.  One run at a time writes the manifest.
# =====================================================================

function Get-LibraryPlaceText {
    if ($script:Config.LibraryFolder -ne $script:DefaultLibraryFolder) { return 'set on the Settings tab' }
    if ($script:BesideToolkit) { return 'the WinRM toolkit beside this folder: its own patches\ and software\' }
    return 'library\ in this folder - carry patches\ and software\ over to the WinRM toolkit'
}

function Get-ProductLibraryFolder {
    param($Product)
    if ($Product.Source -eq 'catalog') { return (Join-Path $script:Config.LibraryFolder ('patches\' + $Product.PatchType)) }
    return (Join-Path $script:Config.LibraryFolder ('software\' + $Product.Folder))
}

function Get-LibraryRelativePath {
    param([string]$Path)
    $root = $script:Config.LibraryFolder.TrimEnd('\') + '\'
    if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $Path.Substring($root.Length) }
    return $Path
}

# ---------------------------------------------------------------------
#  The manifest
# ---------------------------------------------------------------------
function Get-ManifestPath { return (Join-Path $script:Config.LibraryFolder $script:Config.ManifestName) }

function Read-LibraryManifest {
    # The entries, as hashtables keyed by relative path (lower case).  For showing, an unreadable manifest is logged and
    # treated as empty.  -ForUpdate (the caller holds the lock and is about to write the manifest back) throws instead,
    # so a damaged manifest is never replaced by an empty one.
    param([switch]$ForUpdate)
    $out = [ordered]@{}
    $path = Get-ManifestPath
    if (-not (Test-Path -LiteralPath $path)) { return $out }
    try {
        $doc = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        foreach ($f in @($doc.Files)) {
            if (-not $f -or -not $f.Path) { continue }
            $h = @{}; foreach ($p in $f.PSObject.Properties) { $h[$p.Name] = $p.Value }
            $out[([string]$f.Path).ToLower()] = $h
        }
    } catch {
        if ($ForUpdate) { throw ("the library manifest cannot be read ({0}): {1} - nothing is written over it. Repair the file, or delete it: the files stay and count as placed by hand" -f $path, (Get-ShortError $_)) }
        Write-PatchLog ("the library manifest could not be read ({0}): {1} - treated as empty; the files are still there" -f $path, (Get-ShortError $_)) 'WARN'
    }
    return $out
}

function Enter-ManifestLock {
    # One writer at a time.  The window and the scheduled task may both be running, and each reads the manifest,
    # changes it and writes it back whole: without a lock the later save drops what the other one added.  The lock is
    # a file beside the manifest, held open without sharing; Windows closes and deletes it when its holder ends,
    # however that happens, so a lock is never left behind.  Returns the lock for Exit-ManifestLock.
    param([int]$WaitSec = 60)
    $path = (Get-ManifestPath) + '.lock'
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $until = (Get-Date).AddSeconds($WaitSec)
    while ($true) {
        try { return (New-Object System.IO.FileStream($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None, 1, [System.IO.FileOptions]::DeleteOnClose)) }
        catch {
            if ((Get-Date) -ge $until) { throw ("the library manifest is held by another run of this tool (the scheduled task, or another window) and stayed busy for {0} s: {1}" -f $WaitSec, (Get-ShortError $_)) }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Exit-ManifestLock {
    param($Lock)
    if ($Lock) { try { $Lock.Dispose() } catch { } }
}

function Save-LibraryManifest {
    # The manifest and CHECKSUMS.txt written whole.  The new manifest replaces the old one in one step, so another
    # run never finds the file missing.  The caller holds the lock (Enter-ManifestLock) when it read the manifest first.
    param($Entries)
    $path = Get-ManifestPath
    $folder = Split-Path -Path $path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    $files = @(foreach ($k in $Entries.Keys) { [pscustomobject]$Entries[$k] })
    $doc = [ordered]@{ Tool = ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion); Written = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); WrittenBy = (Get-OperatorIdentity)
        Note = 'Every file the Download Toolkit recorded in this library: product, version, hashes, signer, source and date. CHECKSUMS.txt beside it lists the SHA256 of each file. Safe to delete (the files stay; the tool then treats them as placed by hand).'; Files = $files }
    $part = $path + '.part'
    [System.IO.File]::WriteAllText($part, (ConvertTo-Json -InputObject $doc -Depth 5), (New-Object System.Text.UTF8Encoding $false))
    # File.Replace swaps the two in one step where the file system can (NTFS); a USB stick or a share that cannot gets the plain move
    # ([NullString]::Value: a plain $null reaches .NET as an empty text, which Replace refuses as a backup name)
    try { if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($part, $path, [NullString]::Value) } else { [System.IO.File]::Move($part, $path) } }
    catch { Move-Item -LiteralPath $part -Destination $path -Force }
    Write-ChecksumsFile -Entries $Entries
}

function Write-ChecksumsFile {
    # "sha256  relative path" per file still present, sorted by path - the form certutil / sha256sum users expect.
    param($Entries)
    $lines = @('# {0} {1} - SHA256 of every file the tool put in this library, written {2}' -f $script:Config.ToolName, $script:Config.ToolVersion, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    $lines += '# Check one on the other side:  Get-FileHash -Algorithm SHA256 <file>   or   certutil -hashfile <file> SHA256'
    foreach ($k in @($Entries.Keys | Sort-Object)) { $e = $Entries[$k]; if ($e.Sha256 -and (Test-Path -LiteralPath (Join-Path $script:Config.LibraryFolder $e.Path))) { $lines += ('{0}  {1}' -f $e.Sha256, $e.Path) } }
    [System.IO.File]::WriteAllText((Join-Path $script:Config.LibraryFolder $script:Config.ChecksumsName), (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.ASCIIEncoding))
}

function Get-FileKey {
    param([string]$Path)
    $i = Get-Item -LiteralPath $Path
    return ('{0}|{1}|{2}' -f (Get-LibraryRelativePath $Path).ToLower(), $i.Length, $i.LastWriteTimeUtc.Ticks)
}

# ---------------------------------------------------------------------
#  Reading a file: hashes, signature, version
# ---------------------------------------------------------------------
function Get-SignerOrg {
    # "O=Microsoft Corporation" out of a certificate subject, else the CN.
    param([string]$Subject)
    if ($Subject -match '(?:^|,\s*)O=("(?<o>[^"]+)"|(?<o>[^,]+))') { return $Matches['o'].Trim() }
    if ($Subject -match '(?:^|,\s*)CN=(?<cn>[^,]+)') { return $Matches['cn'].Trim() }
    return $Subject
}

function Test-SignerAllowed {
    param([string]$Subject, [string[]]$Signers)
    $org = Get-SignerOrg -Subject $Subject
    foreach ($s in @($Signers)) { if ($s -and $org.StartsWith($s, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Get-MsiProperty {
    # ProductVersion (or another Property) from inside an .msi, through the Windows Installer object; '' when it cannot be read.
    param([string]$Path, [string]$Property = 'ProductVersion')
    $installer = $null; $db = $null; $view = $null
    try {
        $installer = New-Object -ComObject WindowsInstaller.Installer
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$Property'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($rec) { return [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, @(1)) }
        return ''
    } catch { return '' } finally {
        foreach ($o in @($view, $db, $installer)) { if ($o) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { } } }
    }
}

function Get-FileVersionText {
    # The version of a file the way the product says (VersionFrom: name | msi | file); '' when none.
    param([string]$Path, $Product)
    $name = Split-Path -Path $Path -Leaf
    switch ([string]$Product.VersionFrom) {
        'msi'  { return (Get-MsiProperty -Path $Path) }
        'file' { try { $v = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path); $t = [string]$v.ProductVersion; if (-not $t) { $t = [string]$v.FileVersion }; return ($t -replace '[,\s]+', '.').Trim('.') } catch { return '' } }
        default {
            $fromName = Get-RegexVersion -Text $name -Pattern ([string]$Product.VersionRegex)
            if ($fromName) { return $fromName }
            if ($name -match '(\d+\.\d+\.\d+(\.\d+)?)') { return $Matches[1] }
            return ''
        }
    }
}

function Get-LoggedFileHash {
    # A file's hash, lower case.  The command goes into the log first (CMD), as it could be typed, so a reader sees which
    # check ran on which file and can run it again by hand.  A file that cannot be opened throws (Get-FileHash alone
    # would only write an error and give nothing back).
    param([string]$Path, [string]$Algorithm = 'SHA256')
    Write-PatchLog ("Get-FileHash -Algorithm {0} -LiteralPath '{1}'" -f $Algorithm, $Path.Replace("'", "''")) 'CMD'
    $hash = Get-FileHash -LiteralPath $Path -Algorithm $Algorithm -ErrorAction Stop
    if (-not $hash -or -not $hash.Hash) { throw ("no {0} could be computed of {1}" -f $Algorithm, $Path) }
    return $hash.Hash.ToLower()
}

function Get-FileFacts {
    # Everything the library records about a file: Size, Sha256, Sha1, Signature (Valid / NotSigned / ...), Signer, Version, KB.
    # Each command that reads the file is in the log (CMD) before it runs.
    param([string]$Path, $Product)
    $i = Get-Item -LiteralPath $Path
    $sha256 = Get-LoggedFileHash -Path $Path
    $sha1 = ''; if ($i.Extension -in '.msu', '.cab') { $sha1 = Get-LoggedFileHash -Path $Path -Algorithm 'SHA1' }
    Write-PatchLog ("Get-AuthenticodeSignature -LiteralPath '{0}'" -f $Path.Replace("'", "''")) 'CMD'
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $signer = ''; if ($sig.SignerCertificate) { $signer = [string]$sig.SignerCertificate.Subject }
    $kb = ''; if ($i.Name -match '(?i)-(kb\d+)-') { $kb = $Matches[1].ToUpper() }
    $ver = ''; if ($Product) { $ver = Get-FileVersionText -Path $Path -Product $Product }
    return @{ Size = [int64]$i.Length; Sha256 = $sha256; Sha1 = $sha1; Signature = [string]$sig.Status; Signer = $signer; Version = $ver; KB = $kb }
}

function Test-DownloadedFile {
    # Every check a downloaded file must pass; throws naming the first that fails.  Returns the facts, with Checks = what
    # was compared with what the SOURCE published (the manifest and the log keep it, so a reader sees how far the file
    # was proven: "size; SHA1 and SHA256 published by the source; signed by Microsoft Corporation").
    param([string]$Path, $Candidate, $Product)
    $facts = Get-FileFacts -Path $Path -Product $Product
    $checks = @()
    if ($Candidate.SizeBytes -gt 0) { if ($facts.Size -ne $Candidate.SizeBytes) { throw ("size {0} bytes, the source announced {1}" -f $facts.Size, $Candidate.SizeBytes) }; $checks += 'size' }
    $hashes = @()
    if ($Candidate.Sha1) {
        if (-not $facts.Sha1) { $facts.Sha1 = Get-LoggedFileHash -Path $Path -Algorithm 'SHA1' }   # the source published one: compare whatever the file type
        if ($facts.Sha1 -ne $Candidate.Sha1) { throw ("SHA1 {0} is not the catalogue's {1}" -f $facts.Sha1, $Candidate.Sha1) }
        $hashes += 'SHA1'
    }
    if ($Candidate.Sha256) { if ($facts.Sha256 -ne $Candidate.Sha256) { throw ("SHA256 {0} is not the published {1}" -f $facts.Sha256, $Candidate.Sha256) }; $hashes += 'SHA256' }
    if ($hashes.Count -gt 0) { $checks += (($hashes -join ' and ') + ' published by the source') } else { $checks += 'no hash published by the source' }
    if ($script:Config.RequireValidSignature) {
        if ($facts.Signature -ne 'Valid') { throw ("the Authenticode signature is {0} (the WinRM toolkit refuses it too)" -f $facts.Signature) }
        if (-not (Test-SignerAllowed -Subject $facts.Signer -Signers $Product.Signers)) { throw ("signed by '{0}', not by {1} (Signers in data\products.psd1)" -f (Get-SignerOrg $facts.Signer), ($Product.Signers -join ' / ')) }
        $checks += ('signed by ' + (Get-SignerOrg $facts.Signer))
    } else { $checks += ('signature not required (' + $facts.Signature + ')') }
    $facts.Checks = ($checks -join '; ')
    return $facts
}

function Get-PruneSlot {
    # Which older files a new one replaces: those of the same product, target AND slot.  The slot is the candidate's own
    # (a Server 2025 checkpoint: 'prerequisite-KB5043080') or else its .NET lines ('4.8', '4.8.1'), so the ndp48 and the
    # ndp481 rollup of one build live side by side - each download used to delete the other - and the monthly update
    # never removes the checkpoint it needs.  $Item: a candidate or a manifest entry.
    param($Item)
    $slot = ''; $lines = @()
    if ($Item -is [System.Collections.IDictionary]) { if ($Item.Contains('Slot')) { $slot = [string]$Item['Slot'] }; if ($Item.Contains('Lines')) { $lines = @($Item['Lines']) } }
    elseif ($Item) { if ($Item.PSObject.Properties['Slot']) { $slot = [string]$Item.Slot }; if ($Item.PSObject.Properties['Lines']) { $lines = @($Item.Lines) } }
    if ($slot) { return $slot }
    return (@($lines | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object) -join '+')
}

# ---------------------------------------------------------------------
#  What the library holds
# ---------------------------------------------------------------------
function Get-LibraryFiles {
    # Every file in the library folders the products use, joined with the manifest: a file the manifest knows with the
    # same size and date is "Verified" (or "Checked" after a re-hash); one it knows that changed is "Changed"; one it does
    # not know was "placed by hand".  -Refresh re-reads the folders (the cache is keyed on the listing).
    param([switch]$Refresh)
    $products = @(Get-Products)
    $folders = [ordered]@{}
    foreach ($p in $products) { $f = Get-ProductLibraryFolder -Product $p; if (-not $folders.Contains($f)) { $folders[$f] = @() }; $folders[$f] += $p }
    $listing = @()
    foreach ($f in $folders.Keys) { if (Test-Path -LiteralPath $f) { foreach ($i in @(Get-ChildItem -LiteralPath $f -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msu', '.cab', '.exe', '.msi' })) { $listing += [pscustomobject]@{ File = $i; Products = $folders[$f] } } } }
    $stamp = (@($listing | ForEach-Object { '{0}|{1}|{2}' -f $_.File.FullName.ToLower(), $_.File.Length, $_.File.LastWriteTimeUtc.Ticks } | Sort-Object) -join ';') + '#' + (Get-ManifestStamp)
    if (-not $Refresh -and $script:LibraryCache -and $script:LibraryCache.Stamp -eq $stamp) { return $script:LibraryCache.Rows }
    $manifest = Read-LibraryManifest
    $rows = @()
    foreach ($l in $listing) {
        $i = $l.File
        $rel = Get-LibraryRelativePath $i.FullName
        $e = $manifest[$rel.ToLower()]
        $product = $null
        if ($e -and $e.Product) { $product = @($l.Products | Where-Object { $_.Id -ieq [string]$e.Product })[0] }
        if (-not $product) { $product = @($l.Products | Where-Object { -not $_.FilePattern -or $i.Name -like $_.FilePattern })[0] }
        $state = 'placed by hand'; $light = 'Grey'
        if ($e) {
            if ((Get-FileKey $i.FullName) -eq [string]$e.Key) { $state = 'Verified'; $light = 'Green'; if ($e.Verified -and $e.Verified -ne $e.Downloaded) { $state = 'Verified (checked ' + $e.Verified + ')' } }
            else { $state = 'CHANGED since it was verified'; $light = 'Red' }
        }
        $rows += [pscustomobject]@{ File = $i.Name; Path = $i.FullName; RelPath = $rel; Folder = (Split-Path -Path $rel -Parent); Product = $(if ($e -and $e.Product) { [string]$e.Product } elseif ($product) { $product.Id } else { '' }); ProductName = $(if ($product) { $product.Name } else { '' })
            Target = $(if ($e) { [string]$e.Target } else { '' }); For = $(if ($e) { [string]$e.For } else { '' }); KB = $(if ($e) { [string]$e.KB } elseif ($i.Name -match '(?i)-(kb\d+)-') { $Matches[1].ToUpper() } else { '' }); Version = $(if ($e) { [string]$e.Version } elseif ($product) { Get-FileVersionText -Path $i.FullName -Product $product } else { '' })
            Lines = $(if ($e) { @($e.Lines) } else { @() }); Size = (Format-ByteSize $i.Length); SizeBytes = [int64]$i.Length; Sha256 = $(if ($e) { [string]$e.Sha256 } else { '' }); Signer = $(if ($e) { Get-SignerOrg ([string]$e.Signer) } else { '' })
            Source = $(if ($e) { [string]$e.Url } else { '' }); Published = $(if ($e) { [string]$e.Published } else { '' }); Downloaded = $(if ($e) { [string]$e.Downloaded } else { $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') }); RemoteStamp = $(if ($e) { [string]$e.RemoteStamp } else { '' })
            State = $state; Light = $light; Entry = $e; ReleaseNotes = '' }
        $rows[-1].ReleaseNotes = Get-FileReleaseNotesUrl -Product $product -Entry $e -Kb $rows[-1].KB -Version $rows[-1].Version
    }
    $rows = @($rows | Sort-Object Folder, File)
    $script:LibraryCache = @{ Stamp = $stamp; Rows = $rows }
    return $rows
}

function Get-FileReleaseNotesUrl {
    # The release notes of a library file: the link recorded with it, else worked out from its product and its KB or
    # version.  (A version read from inside an installer may end in ".0" where the vendor writes three parts: dropped.)
    param($Product, $Entry, [string]$Kb = '', [string]$Version = '')
    if ($Entry -and $Entry.ReleaseNotes) { return [string]$Entry.ReleaseNotes }
    if (-not $Product) { return '' }
    $plain = $Version; if ($plain -match '^\d+(\.\d+){2}\.0$') { $plain = $plain -replace '\.0$', '' }
    return (Get-ReleaseNotesUrl -Product $Product -Version $plain -Kb $Kb)
}

function Get-ManifestStamp {
    $p = Get-ManifestPath
    if (Test-Path -LiteralPath $p) { return [string](Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks }
    return '0'
}

function Test-LibraryIntegrity {
    # Every file the manifest knows hashed again: a changed or truncated file is flagged (its entry marked, the row red).
    # A file placed by hand has no recorded hash to compare with, so it is not hashed: the result names those, and says
    # how many files and how much data were hashed and how long it took.  The log shows the work file by file: the
    # Get-FileHash command (CMD), then the SHA256 it gave and how it compares.  A file that cannot be read (another
    # program has it open) is a problem of its own - not verified this time - and is never called changed.
    # The hashing takes minutes and holds no lock; what it found is then written into the manifest as it is at that
    # moment, so an entry another run added meanwhile is kept.  Returns the problems found.
    $snapshot = Read-LibraryManifest
    $problems = @(); $checked = 0; $hashed = 0; $bytes = [int64]0
    $gone = @(); $changed = @{}; $good = @{}
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    foreach ($k in @($snapshot.Keys)) {
        $e = $snapshot[$k]
        $path = Join-Path $script:Config.LibraryFolder $e.Path
        if (-not (Test-Path -LiteralPath $path)) { $problems += ('{0}: gone (removed by hand?) - its manifest entry is dropped' -f $e.Path); Write-PatchLog ("LIBRARY: {0}" -f $problems[-1]) 'ERROR'; $gone += $k; continue }
        Set-GuiStatus ("Verifying {0} ..." -f $e.Path)
        $size = [int64](Get-Item -LiteralPath $path).Length; $began = $clock.Elapsed.TotalSeconds
        $sha = ''
        try { $sha = Get-LoggedFileHash -Path $path }
        catch { $problems += ('{0}: could not be read, so it was NOT verified this time ({1}) - is another program using it?' -f $e.Path, (Get-ShortError $_)); Write-PatchLog ("LIBRARY: {0}" -f $problems[-1]) 'ERROR'; continue }
        $hashed++; $bytes += $size
        if ($sha -ne [string]$e.Sha256) { $problems += ('{0}: SHA256 is {1}, the manifest says {2} - CHANGED since it was downloaded; delete it and download again' -f $e.Path, $sha, $e.Sha256); Write-PatchLog ("LIBRARY: {0}" -f $problems[-1]) 'ERROR'; $changed[$k] = $sha; continue }
        Write-PatchLog ('{0}: SHA256 {1} - the same as recorded at its download ({2}, {3:N1} s)' -f $e.Path, $sha, (Format-ByteSize $size), ($clock.Elapsed.TotalSeconds - $began)) 'OK'
        $good[$k] = @{ Key = (Get-FileKey $path); Verified = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') }; $checked++
    }
    $clock.Stop()
    if ($gone.Count + $changed.Count + $good.Count -gt 0) {
        $lock = $null
        try {
            $lock = Enter-ManifestLock
            $manifest = Read-LibraryManifest -ForUpdate
            foreach ($k in $gone) { if ($manifest.Contains($k) -and -not (Test-Path -LiteralPath (Join-Path $script:Config.LibraryFolder $manifest[$k].Path))) { $manifest.Remove($k) } }
            # only an entry that still describes the file that was hashed: one replaced meanwhile keeps its own stamps
            foreach ($k in @($changed.Keys)) { if ($manifest.Contains($k) -and [string]$manifest[$k].Sha256 -eq [string]$snapshot[$k].Sha256) { $manifest[$k].Key = 'changed|' + $changed[$k] } }
            foreach ($k in @($good.Keys)) { if ($manifest.Contains($k) -and [string]$manifest[$k].Sha256 -eq [string]$snapshot[$k].Sha256) { $manifest[$k].Key = $good[$k].Key; $manifest[$k].Verified = $good[$k].Verified } }
            Save-LibraryManifest -Entries $manifest
        } catch { $problems += ('the result of the verification could not be written into the manifest: {0}' -f (Get-ShortError $_)); Write-PatchLog ("LIBRARY: {0}" -f $problems[-1]) 'ERROR' }
        finally { Exit-ManifestLock $lock }
    }
    $script:LibraryCache = $null
    $byHand = @(Get-LibraryFiles | Where-Object { -not $_.Entry } | ForEach-Object { $_.RelPath })
    $lines = @(Get-LibraryVerifyLines -Hashed $hashed -Matching $checked -Bytes $bytes -Seconds $clock.Elapsed.TotalSeconds -Problems $problems.Count -ByHand $byHand)
    Write-PatchLog $lines[0] $(if ($problems.Count -gt 0) { 'WARN' } elseif ($hashed -gt 0) { 'OK' } else { 'INFO' })
    if ($lines.Count -gt 1) { Write-PatchLog $lines[1] 'INFO' }
    return $problems
}

function Get-LibraryVerifyLines {
    # What a verification says when it is done: line 1 = what was hashed and how it compared, line 2 (only when there
    # are any) = the files it could not check because no hash was ever recorded for them.
    param([int]$Hashed, [int]$Matching, [int64]$Bytes, [double]$Seconds, [int]$Problems, [string[]]$ByHand)
    $lines = @()
    if ($Hashed -eq 0) {
        if ($Problems -gt 0) { $lines += ('Library verified: nothing could be hashed, {0} problem(s) above' -f $Problems) }
        else { $lines += 'Library verified: nothing was hashed - the manifest lists no file (this tool has not recorded one in this library yet)' }
    } else {
        $outcome = $(if ($Matching -eq $Hashed) { 'every one matches the SHA256 recorded at its download' } else { '{0} match the SHA256 recorded at their download' -f $Matching })
        $lines += ('Library verified: {0} file(s), {1}, hashed again in {2:N1} s - {3}{4}' -f $Hashed, (Format-ByteSize $Bytes), $Seconds, $outcome, $(if ($Problems -gt 0) { ', ' + $Problems + ' problem(s) above' } else { '' }))
    }
    $names = @($ByHand | Where-Object { $_ })
    if ($names.Count -gt 0) {
        $shown = @($names | Select-Object -First 5 | ForEach-Object { Split-Path -Path $_ -Leaf })
        $lines += ('Not checked: {0} file(s) placed by hand - no hash was recorded for them, so there is nothing to compare ({1}{2})' -f $names.Count, ($shown -join ', '), $(if ($names.Count -gt $shown.Count) { ', and {0} more' -f ($names.Count - $shown.Count) } else { '' }))
    }
    return $lines
}

function Find-LibraryFileForCandidate {
    # The library file that IS this candidate, if any: the same file name (catalog, VMware, index), or for a fixed link the
    # file recorded with the same remote stamp (size + date of the link).
    param($Candidate, [object[]]$Files)
    foreach ($f in @($Files)) {
        if ($f.Product -and $f.Product -ine $Candidate.ProductId) { continue }
        if ($Candidate.Source -eq 'url') { if ($f.RemoteStamp -and $f.RemoteStamp -eq $Candidate.RemoteStamp) { return $f }; continue }
        if ($Candidate.FileName -and $f.File -ieq $Candidate.FileName) { return $f }
    }
    return $null
}

function Get-CandidateId {
    # One candidate among the several a target may have (the ndp48 and the ndp481 rollup of one build; a monthly update
    # and its checkpoint): the target's key and the file name.
    param($Candidate)
    return ('{0}#{1}' -f $Candidate.Key, $Candidate.FileName)
}

function Set-CandidateResult {
    # What the last download ('download') or the last check of a hand-placed file where it lies ('placed') came to,
    # kept per candidate so two files of one target never share a result.  An empty text = it went well.
    param($Candidate, [string]$ErrorText = '', [string]$Kind = 'download')
    $script:Results[(Get-CandidateId $Candidate)] = @{ When = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); Error = $ErrorText; Kind = $Kind }
}

function Clear-CandidateResults {
    # A new check of a target starts its candidates afresh.
    param([string]$TargetKey)
    foreach ($k in @($script:Results.Keys)) { if ($k.StartsWith($TargetKey + '#', [System.StringComparison]::OrdinalIgnoreCase)) { $script:Results.Remove($k) } }
}

# ---------------------------------------------------------------------
#  The download, the checks, the manifest entry, the pruning
# ---------------------------------------------------------------------
function Add-LibraryRecord {
    # The manifest entry of a file that passed its checks, then the pruning of the files it supersedes.  The entry is
    # saved before anything is removed, so a failure in between never leaves the library with neither file.  -By names
    # who brought the file when this tool did not fetch it.  Returns the names pruned.
    param($Candidate, $Product, $Facts, [string]$Path, [string]$Url, [string]$By = '')
    $lock = Enter-ManifestLock
    try {
        $manifest = Read-LibraryManifest -ForUpdate
        $rel = Get-LibraryRelativePath $Path
        $slot = Get-PruneSlot $Candidate
        $version = $Candidate.Version; if ($Facts.Version) { $version = $Facts.Version }
        $now = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $manifest[$rel.ToLower()] = [ordered]@{ Path = $rel; Product = $Product.Id; Target = [string]$Candidate.Target; For = $Candidate.For; Title = $Candidate.Title; KB = $(if ($Candidate.KB) { $Candidate.KB } else { $Facts.KB }); Version = $version; Lines = @($Candidate.Lines); Slot = $slot
            Size = $Facts.Size; Sha256 = $Facts.Sha256; Sha1 = $Facts.Sha1; SourceSha1 = [string]$Candidate.Sha1; SourceSha256 = [string]$Candidate.Sha256; Checks = [string]$Facts.Checks
            Signature = $Facts.Signature; Signer = $Facts.Signer; Source = $Candidate.Source; Url = $Url; Published = $Candidate.Published; RemoteStamp = $Candidate.RemoteStamp
            ReleaseNotes = (Get-ReleaseNotesUrl -Product $Product -Version ([string]$Candidate.Version) -Kb $(if ($Candidate.KB) { [string]$Candidate.KB } else { [string]$Facts.KB }))   # in the source's own spelling of the version, kept with the file
            Downloaded = $now; DownloadedBy = $(if ($By) { $By } else { Get-OperatorIdentity }); Verified = $now; Key = (Get-FileKey $Path) }
        Save-LibraryManifest -Entries $manifest
        $pruned = @(Remove-SupersededFiles -Manifest $manifest -ProductId $Product.Id -Target ([string]$Candidate.Target) -Slot $slot -Keep $rel)
        if ($pruned.Count -gt 0) { try { Save-LibraryManifest -Entries $manifest } catch { Write-PatchLog ("the manifest still lists the superseded file(s) just removed ({0}): {1} - the next verification drops them" -f ($pruned -join ', '), (Get-ShortError $_)) 'WARN' } }
        $script:LibraryCache = $null
        return $pruned
    } finally { Exit-ManifestLock $lock }
}

function Invoke-CandidateDownload {
    # One candidate fetched and checked, and only then given its place in the library.  The file arrives in _incoming\
    # inside the product's folder - this tool's own scratch folder - and is checked there.  Until it has passed every
    # check nothing in the library is touched, so a download that fails or is stopped deletes only what it brought
    # itself, never a file that was already there.  Returns @{ Success; Message; Path; Facts }.
    param([Parameter(Mandatory = $true)]$Candidate)
    $product = Get-Product -Id $Candidate.ProductId
    if (-not $product) { return @{ Success = $false; Message = "product $($Candidate.ProductId) is no longer in data\products.psd1"; Path = '' } }
    if ($Candidate.Verdict -ne 'Appropriate') { return @{ Success = $false; Message = ('not downloaded: {0} - {1}' -f $Candidate.Verdict, $Candidate.Reason); Path = '' } }
    if (-not $Candidate.Url -or -not $Candidate.FileName) { return @{ Success = $false; Message = 'no download link (check again)'; Path = '' } }
    $what = ('{0} for {1}' -f $Candidate.ProductName, $Candidate.For)
    # the name comes from the source: it must be a plain file name, never a path that leads out of the product's folder
    $leaf = [string]$Candidate.FileName
    if (-not $leaf.Trim('. ') -or $leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) {
        $why = ("the source names the file '{0}', which is not a plain file name - not downloaded" -f $leaf)
        Write-PatchLog ("DOWNLOAD FAILED {0}: {1}" -f $what, $why) 'ERROR'
        Set-CandidateResult -Candidate $Candidate -ErrorText $why
        return @{ Success = $false; Message = $why; Path = '' }
    }
    $folder = $Candidate.Folder
    $incoming = Join-Path $folder '_incoming'
    $temp = Join-Path $incoming $leaf
    $placed = ''   # where the file sits once it has passed every check
    try {
        # a link read off a page of the file's own carries a token that lives for minutes: it is read again now, and the
        # page (not the token) is what the manifest records as the source
        $url = [string]$Candidate.Url; $recorded = $url
        if ($Candidate.PSObject.Properties['FreshFrom'] -and $Candidate.FreshFrom) {
            $url = Resolve-FilePageLink -Product $product -Text (Get-WebText -Url $Candidate.FreshFrom) -Version $Candidate.Version -PageUrl $Candidate.FreshFrom
            $recorded = [string]$Candidate.FreshFrom
        }
        if (Test-Path -LiteralPath $incoming) { Remove-Item -LiteralPath $incoming -Recurse -Force -ErrorAction SilentlyContinue }   # what an interrupted run left behind
        $null = Invoke-FileDownload -Url $url -Path $temp -ExpectedBytes $Candidate.SizeBytes -What $what
        Set-GuiStatus ("Checking {0} ..." -f $leaf)
        $facts = Test-DownloadedFile -Path $temp -Candidate $Candidate -Product $product
        # it passed: now it takes its place.  A fixed link's file is named by the version read from inside it, so two
        # versions can sit side by side
        $finalPath = Join-Path $folder $leaf
        if ($Candidate.Source -eq 'url' -and $facts.Version) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf); $ext = [System.IO.Path]::GetExtension($leaf)
            $finalPath = Join-Path $folder ('{0}-{1}{2}' -f $base, ($facts.Version -replace '[^0-9A-Za-z.]', '_'), $ext)
        }
        if (Test-Path -LiteralPath $finalPath) { Remove-Item -LiteralPath $finalPath -Force -ErrorAction Stop }   # the same name: the copy just verified replaces it
        Move-Item -LiteralPath $temp -Destination $finalPath -Force -ErrorAction Stop
        $placed = $finalPath
        $pruned = @(Add-LibraryRecord -Candidate $Candidate -Product $product -Facts $facts -Path $finalPath -Url $recorded)
        $msg = ('{0}: {1} verified - {2}, SHA256 {3}; checked: {4}{5}' -f $what, (Split-Path -Path $finalPath -Leaf), (Format-ByteSize $facts.Size), $facts.Sha256, $facts.Checks, $(if ($pruned.Count -gt 0) { '; superseded and removed: ' + ($pruned -join ', ') } else { '' }))
        Write-PatchLog ('DOWNLOADED ' + $msg) 'OK'
        Set-CandidateResult -Candidate $Candidate
        return @{ Success = $true; Message = $msg; Path = $finalPath; Facts = $facts }
    } catch {
        $why = Get-ShortError $_
        if ($placed) { $why += (' - {0} passed every check and stays in the library, but could not be recorded: it counts as placed by hand until the next run checks it where it lies' -f (Split-Path -Path $placed -Leaf)) }
        elseif (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue; $why += ' - the downloaded file was deleted' }
        Write-PatchLog ("DOWNLOAD FAILED {0}: {1}" -f $what, $why) 'ERROR'
        Set-CandidateResult -Candidate $Candidate -ErrorText $why
        return @{ Success = $false; Message = $why; Path = '' }
    } finally {
        if ((Test-Path -LiteralPath $incoming) -and @(Get-ChildItem -LiteralPath $incoming -Force -ErrorAction SilentlyContinue).Count -eq 0) { Remove-Item -LiteralPath $incoming -Force -ErrorAction SilentlyContinue }
    }
}

function Confirm-PlacedFile {
    # A file placed by hand under a candidate's name, checked where it lies exactly as a download is: the size, the
    # hash the source publishes, the signature and its signer.  When it passes it is recorded in the manifest and
    # counts as verified from then on; nothing is fetched.  When it does not, it is left alone - it is the operator's
    # file - and the row says why.  Returns @{ Success; Message; Path; Facts }.
    param([Parameter(Mandatory = $true)]$Candidate, [Parameter(Mandatory = $true)]$File)
    $product = Get-Product -Id $Candidate.ProductId
    if (-not $product) { return @{ Success = $false; Message = "product $($Candidate.ProductId) is no longer in data\products.psd1"; Path = '' } }
    $what = ('{0} for {1}' -f $Candidate.ProductName, $Candidate.For)
    try {
        Set-GuiStatus ("Checking {0} where it lies ..." -f $File.File)
        $facts = Test-DownloadedFile -Path $File.Path -Candidate $Candidate -Product $product
        $facts.Checks = [string]$facts.Checks + '; placed by hand, not fetched by this tool'
        $pruned = @(Add-LibraryRecord -Candidate $Candidate -Product $product -Facts $facts -Path $File.Path -Url ([string]$Candidate.Url) -By ('{0} (placed by hand, checked where it lay)' -f (Get-OperatorIdentity)))
        $msg = ('{0}: {1} was placed by hand and is the file the source publishes - {2}, SHA256 {3}; checked: {4}{5}' -f $what, $File.File, (Format-ByteSize $facts.Size), $facts.Sha256, $facts.Checks, $(if ($pruned.Count -gt 0) { '; superseded and removed: ' + ($pruned -join ', ') } else { '' }))
        Write-PatchLog ('VERIFIED WHERE IT LIES ' + $msg) 'OK'
        Set-CandidateResult -Candidate $Candidate -Kind 'placed'
        return @{ Success = $true; Message = $msg; Path = $File.Path; Facts = $facts }
    } catch {
        $why = Get-ShortError $_
        Write-PatchLog ("NOT VERIFIED {0}: {1}, placed by hand - {2}. The file was left alone" -f $what, $File.File, $why) 'ERROR'
        Set-CandidateResult -Candidate $Candidate -ErrorText $why -Kind 'placed'
        return @{ Success = $false; Message = $why; Path = '' }
    }
}

function Remove-SupersededFiles {
    # The older files of the same product, target and slot (Get-PruneSlot) that the manifest knows, beyond KeepPrevious,
    # are deleted (the newest one, $Keep, always stays).  A file of another slot - the other .NET line's rollup, a
    # checkpoint - and a file the manifest does not know are never touched.  Returns the names removed.
    param($Manifest, [string]$ProductId, [string]$Target, [string]$Keep, [string]$Slot = '')
    $keepN = [math]::Max(0, [int]$script:Config.KeepPrevious)
    $mine = @($Manifest.Keys | Where-Object { $Manifest[$_].Product -ieq $ProductId -and [string]$Manifest[$_].Target -eq $Target -and $_ -ne $Keep.ToLower() -and (Get-PruneSlot $Manifest[$_]) -eq $Slot } | Sort-Object { [string]$Manifest[$_].Downloaded } -Descending)
    $removed = @()
    for ($i = $keepN; $i -lt $mine.Count; $i++) {
        $e = $Manifest[$mine[$i]]
        $path = Join-Path $script:Config.LibraryFolder $e.Path
        try { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }; $Manifest.Remove($mine[$i]); $removed += (Split-Path -Path $e.Path -Leaf); Write-PatchLog ("superseded: {0} removed (KeepPrevious = {1})" -f $e.Path, $keepN) 'INFO' }
        catch { Write-PatchLog ("superseded: {0} could not be removed: {1}" -f $e.Path, (Get-ShortError $_)) 'WARN' }
    }
    return $removed
}

function Remove-LibraryFile {
    # The Remove button: one file and its manifest entry (after the caller's Yes).
    param([string]$Path)
    $rel = (Get-LibraryRelativePath $Path).ToLower()
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
    $lock = Enter-ManifestLock
    try {
        $manifest = Read-LibraryManifest -ForUpdate
        if ($manifest.Contains($rel)) { $manifest.Remove($rel); Save-LibraryManifest -Entries $manifest }
    } finally { Exit-ManifestLock $lock }
    $script:LibraryCache = $null
    Write-PatchLog ("REMOVED {0} by {1}" -f $Path, (Get-OperatorIdentity)) 'OK'
}

# ---------------------------------------------------------------------
#  The grid rows and the run
# ---------------------------------------------------------------------
function Get-LibraryRows {
    # One row per target, or per candidate when a check found several (.NET rollups).  Light: Green = the newest
    # appropriate file is in the library and verified; Amber = to download, or a file placed by hand that nothing has
    # compared with the source yet; Blue = held by a rule; Red = a check or download failed, the library file changed,
    # a hand-placed file is not the one the source publishes, or the check found only an older month than there must
    # be by now (Stale); Grey = not checked yet, or the target is not set up.
    $files = @(Get-LibraryFiles)
    $rows = @()
    foreach ($t in @(Get-AllTargets)) {
        $p = $t.Product
        $checked = $script:Checked[$t.Key]
        $cands = @($script:Candidates[$t.Key] | Where-Object { $_ })
        $inLib = @($files | Where-Object { $_.Product -ieq $p.Id -and ($_.Target -eq [string]$t.Target -or -not $_.Target) })
        $libText = $(if ($inLib.Count -gt 0) { (@($inLib | ForEach-Object { if ($_.KB) { $_.KB } elseif ($_.Version) { $_.Version } else { $_.File } }) -join ', ') } else { '-' })
        $base = [ordered]@{ Key = $t.Key; Product = $p.Name; For = $t.For; 'In library' = $libText; 'Latest found' = ''; Verdict = ''; Light = 'Grey'; Verified = $(if ($inLib.Count -gt 0) { (@($inLib | ForEach-Object { $_.State } | Select-Object -Unique) -join ', ') } else { '' }); Size = ''; Published = ''; Source = $p.Source; Checked = $(if ($checked) { [string]$checked.When } else { '' }); Reason = ''; Enabled = [bool]$p.Enabled; ByChoice = [bool]$t.ByChoice; Stale = ''; Candidate = $null; PlacedFile = $null; Files = $inLib; FileName = '' }
        if (-not [bool]$p.Enabled) { $base.Verdict = 'Off'; $base.Reason = 'not ticked on the Products tab - tick it there to fetch it'; $rows += [pscustomobject]$base; continue }
        if ($t.Problem) { $base.Verdict = 'Not set up'; $base.Reason = $t.Problem; $rows += [pscustomobject]$base; continue }
        # a product whose link the operator gives by hand, and none is given: it waits - grey, never a failed run
        if ($t.Waiting) { $base.Verdict = 'By hand'; $base.Reason = $t.Waiting; if (@($inLib | Where-Object { $_.Light -eq 'Red' }).Count -gt 0) { $base.Verdict = 'Changed'; $base.Light = 'Red'; $base.Reason = 'a library file changed since it was verified' }; $rows += [pscustomobject]$base; continue }
        if (-not $checked -or (-not $checked.Error -and $cands.Count -eq 0)) { $base.Verdict = 'Not checked'; $base.Reason = 'press Check for updates'; if (@($inLib | Where-Object { $_.Light -eq 'Red' }).Count -gt 0) { $base.Verdict = 'Changed'; $base.Light = 'Red'; $base.Reason = 'a library file changed since it was verified' }; $rows += [pscustomobject]$base; continue }
        if ($checked.Error -and $cands.Count -eq 0) { $base.Verdict = 'Check failed'; $base.Light = 'Red'; $base.Reason = [string]$checked.Error; $rows += [pscustomobject]$base; continue }
        $sameKb = (@($cands | ForEach-Object { [string]$_.KB } | Select-Object -Unique).Count -lt $cands.Count)
        foreach ($c in $cands) {
            $r = [ordered]@{}; foreach ($k in $base.Keys) { $r[$k] = $base[$k] }
            $r.Candidate = $c; $r.FileName = $c.FileName
            $r.'Latest found' = $(if ($c.KB) { '{0} ({1})' -f $c.KB, $c.Version } elseif ($c.Version) { $c.Version } else { $c.Title })
            if ($c.Lines.Count -gt 0) { $r.'Latest found' += ' .NET ' + ($c.Lines -join ', ') }
            $r.Size = $(if ($c.SizeBytes -gt 0) { Format-ByteSize $c.SizeBytes } else { '' }); $r.Published = $c.Published
            if ($cands.Count -gt 1) { $r.Key = '{0}#{1}' -f $t.Key, $(if ($sameKb -and $c.FileName) { $c.FileName } else { $c.KB }) }   # by the KB; by the file where two files carry one KB
            $have = Find-LibraryFileForCandidate -Candidate $c -Files $files
            $res = $script:Results[(Get-CandidateId $c)]   # this candidate's own last download or check where it lies
            if ($c.Verdict -ne 'Appropriate') { $r.Verdict = 'Held'; $r.Light = 'Blue'; $r.Reason = $c.Reason }
            elseif ($have -and $have.Light -eq 'Red') { $r.Verdict = 'Changed'; $r.Light = 'Red'; $r.Reason = ('{0} changed since it was verified - remove it and download again' -f $have.File); $r.'In library' = $have.File }
            elseif ($have -and $have.Entry) { $r.Verdict = 'Current'; $r.Light = 'Green'; $r.Reason = ('{0} is in the library, verified {1}' -f $have.File, $have.Downloaded); $r.'In library' = $(if ($have.KB) { $have.KB } elseif ($have.Version) { $have.Version } else { $have.File }) }
            elseif ($have) {
                # placed by hand under the candidate's name: nothing has compared it with the source yet
                $r.Verdict = 'Unverified'; $r.PlacedFile = $have; $r.'In library' = $have.File
                if ($res -and $res.Error -and $res.Kind -eq 'placed') { $r.Light = 'Red'; $r.Reason = ('{0} was placed by hand and did NOT pass: {1} - remove it (Remove file), then download' -f $have.File, $res.Error) }
                else { $r.Light = 'Amber'; $r.Reason = ('{0} was placed by hand and has not been compared with the source yet - Download ticked or a run checks it where it lies (size, the published hash, the signature); nothing is fetched' -f $have.File) }
            }
            elseif ($res -and $res.Error -and $res.Kind -eq 'download') { $r.Verdict = 'Download failed'; $r.Light = 'Red'; $r.Reason = [string]$res.Error }
            else { $r.Verdict = 'Download'; $r.Light = 'Amber'; $r.Reason = ('not in the library yet: {0} ({1}) - {2}' -f $c.FileName, (Format-ByteSize $c.SizeBytes), $c.Reason) }
            # the check found only an older month than there must be by now: what the library holds is not "Current",
            # whatever else the row says
            if ($c.Stale) {
                $r.Stale = [string]$c.Stale
                if ($r.Verdict -eq 'Current') { $r.Verdict = 'Stale'; $r.Light = 'Red'; $r.Reason = ('{0}. In the library: {1}, the newest that was found' -f $c.Stale, $have.File) }
                else { $r.Reason = ('{0} | AND: {1}' -f $r.Reason, $c.Stale) }
            }
            $rows += [pscustomobject]$r
        }
    }
    return $rows
}

function Get-LibraryFileRows {
    # The lower grid: every file in the library, the manifest's facts beside it.
    return @(Get-LibraryFiles | ForEach-Object { [pscustomobject]@{ File = $_.File; Folder = $_.Folder; Product = $(if ($_.ProductName) { $_.ProductName } else { $_.Product }); For = $_.For; 'KB / version' = $(if ($_.KB) { $_.KB } else { $_.Version }); Size = $_.Size; State = $_.State; Light = $_.Light; Signer = $_.Signer; Downloaded = $_.Downloaded; SHA256 = $_.Sha256; Path = $_.Path; Row = $_ } })
}

function Invoke-LibraryRun {
    # The whole job, as the scheduled task does it and as "Check and download" does: every enabled product checked, every
    # file placed by hand under a candidate's name checked where it lies, every appropriate candidate not in the library
    # downloaded and verified, the library verified, settings\last-run.json and a report written.  Returns the outcome;
    # ExitCode 0 = nothing failed.
    param([switch]$Unattended, [switch]$NoDownload, [object[]]$Products = $null)   # -Products: only these are checked, fetched and counted (the others are left alone)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $downloaded = @(); $placed = @(); $failed = @()
    if ($null -ne $Products) { $null = Invoke-LibraryCheck -Products $Products } else { $null = Invoke-LibraryCheck }
    $rows = @(Get-LibraryRows)
    # with -Products only their rows are acted on: what an earlier check of this session found for another product stays
    # as it is (its row still says Download; this run does not fetch it and does not count it)
    $only = $null; if ($null -ne $Products) { $only = @($Products | ForEach-Object { [string]$_.Id }) }
    $mine = { param($row) ($null -eq $only) -or ($only -contains (([string]$row.Key -split '\|')[0])) }
    # a product this site does not use - no ESXi version, no .NET line ticked - is a choice (ByChoice), not a failure
    foreach ($r in @($rows | Where-Object { (& $mine $_) -and ($_.Verdict -eq 'Check failed' -or ($_.Verdict -eq 'Not set up' -and -not $_.ByChoice)) })) { $failed += ('{0} for {1}: {2}' -f $r.Product, $r.For, $r.Reason) }
    if (-not $NoDownload) {
        foreach ($r in @($rows | Where-Object { (& $mine $_) -and $_.Verdict -eq 'Unverified' -and $_.Candidate -and $_.PlacedFile })) {
            $res = Confirm-PlacedFile -Candidate $r.Candidate -File $r.PlacedFile
            if ($res.Success) { $placed += $r.PlacedFile.File } else { $failed += ('{0} for {1}: {2} was placed by hand and did not pass - {3}' -f $r.Product, $r.For, $r.PlacedFile.File, $res.Message) }
        }
        foreach ($r in @($rows | Where-Object { (& $mine $_) -and $_.Verdict -eq 'Download' -and $_.Candidate })) {
            $res = Invoke-CandidateDownload -Candidate $r.Candidate
            if ($res.Success) { $downloaded += (Split-Path -Path $res.Path -Leaf) } else { $failed += ('{0} for {1}: {2}' -f $r.Product, $r.For, $res.Message) }
        }
    }
    if ($script:Config.VerifyEveryStart -or $Unattended) { foreach ($p in @(Test-LibraryIntegrity)) { $failed += $p } }
    $rows = @(Get-LibraryRows)   # after the downloads AND the verification: the counts and the report show what they found
    # a monthly product for which only an older month was found: the library cannot be called up to date, and the run says so
    foreach ($r in @($rows | Where-Object { (& $mine $_) -and $_.Stale })) { $failed += ('{0} for {1}: {2}' -f $r.Product, $r.For, $r.Stale) }
    $current = @($rows | Where-Object { $_.Verdict -eq 'Current' }).Count
    $held = @($rows | Where-Object { $_.Verdict -eq 'Held' }).Count
    $outcome = 'OK'; if ($failed.Count -gt 0) { $outcome = 'FAILED' }
    $parts = @(('{0} downloaded' -f $downloaded.Count))
    if ($placed.Count -gt 0) { $parts += ('{0} placed by hand and verified' -f $placed.Count) }
    $parts += ('{0} failed' -f $failed.Count), ('{0} current' -f $current), ('{0} held' -f $held), ('{0} file(s) in the library' -f @(Get-LibraryFiles).Count), ('{0:N0} s' -f $sw.Elapsed.TotalSeconds)
    $summary = $parts -join ', '
    $report = $null
    try { $report = Export-LibraryReport -Rows $rows -Title ('Library run {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -Notes @(('Outcome: {0} - {1}' -f $outcome, $summary)) } catch { Write-PatchLog ("the run report could not be written: {0}" -f (Get-ShortError $_)) 'WARN' }
    $doc = [ordered]@{ Tool = ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion); When = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); By = (Get-OperatorIdentity); Unattended = [bool]$Unattended; Outcome = $outcome; Summary = $summary
        Downloaded = @($downloaded); Placed = @($placed); Failed = @($failed); Current = $current; Held = $held; Environment = (Get-EnvironmentText); Library = $script:Config.LibraryFolder; Report = $(if ($report) { $report.Html } else { '' }); Log = (Get-PatchLogPath) }
    try {
        $path = $script:Config.LastRunFile; $folder = Split-Path -Path $path -Parent
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        [System.IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $doc -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    } catch { Write-PatchLog ("last-run.json could not be written: {0}" -f (Get-ShortError $_)) 'WARN' }
    return [pscustomobject]@{ Outcome = $outcome; Summary = $summary; ExitCode = $(if ($outcome -eq 'OK') { 0 } else { 1 }); Downloaded = @($downloaded); Placed = @($placed); Failed = @($failed); Current = $current; Held = $held; Report = $report }
}
