# =====================================================================
#  04-Patches.ps1  -  FIND AND VET THE PATCH FILES IN \patches
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The tool is fully offline: you download the .msu (or .cab) files from
#  the Microsoft Update Catalog on a machine that has internet, then
#  drop them into the "patches" folder next to the launcher.
#
#  For every file the tool works out, once, and caches in patches\_info:
#    KB number     from the FILE NAME  (windows10.0-kb5122882-x64_....msu -> KB5122882)
#    Target build  from INSIDE the file (expand.exe reads one small XML)   -> 20348 = Server 2022
#    Signature     Get-AuthenticodeSignature: must be Valid and signed by Microsoft
#    SHA256        used to verify the copy on the server and again right before DISM
#  Get-PatchVerdict at the bottom is THE decision "can this KB go on this
#  server?" - the grid cells and the install plan both call it.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  04-Patches.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (see CODE-REVIEW.md).  Fixed here:
#  R-09 no Authenticode check of the .msu; R-11 OS guard failed open when
#  the build could not be read and the _info cache ignored a replaced
#  file; R-12 grid and plan used two different rule orders (now one
#  function, Get-PatchVerdict); R-17 -Path used on file-derived names
#  (now -LiteralPath); R-20 two files with the same KB were not flagged.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ___CF__________________________   Date : ___30-10-2026___________
#  Verdict    : [X] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] read every function   [x] ran Get-PatchFiles on a real .msu
#               [x] compared with CODE-REVIEW.md
#  Comments   :
#    -
#    -
# =====================================================================

# Shown by the "Where do I get patches?" button and in the Code Tour.  Edit freely.
$script:PatchHowTo = @'
WHERE TO FIND MICROSOFT PATCHES  (do this on a machine that has internet, then copy the files over)

The tool installs Windows and .NET Framework updates (.msu / .cab files) itself. For the other products it
reports the installed level so you can see what is missing; those installers are run by hand for now.

A. WINDOWS SERVER CUMULATIVE UPDATE (LCU) - the monthly patch
   1. KB number: search "Windows Server 2022 update history" or open https://support.microsoft.com/help/5005454
      (Server 2019: help/4464619, Server 2016: help/4000825, Server 2025: help/5045836). The list is newest first,
      e.g. "September 8, 2026 - KB5122882 (OS Build 20348.5622)". Take the top entry WITHOUT the word "Preview".
      The OS Build number is what the Build column in the grid shows, so you can see who is already current.
      Numbers only, per version: https://learn.microsoft.com/windows/release-health/windows-server-release-info
   2. Download: the history article links to the Microsoft Update Catalog under "How to get this update", or open
      https://www.catalog.update.microsoft.com and search the KB. Server 2022 is listed as "Cumulative Update for
      Microsoft server operating system version 21H2 for x64-based Systems"; Server 2025 is "version 24H2";
      Server 2019 and 2016 are listed by name. Click Download, save the .msu, KEEP THE FILE NAME.
   3. The servicing stack update (SSU) is bundled inside the LCU for 2019/2022/2025 - one file is enough.

B. .NET FRAMEWORK CUMULATIVE UPDATE - separate KB, same day as the LCU
   Catalog search: ".NET Framework" "Windows Server 2022" (or the KB from the history page; the LCU article lists
   it under ".NET Framework updates"). File names look like windows10.0-kb5126050-x64-ndp481_....msu. One file
   per .NET line (4.8 / 4.8.1); the tool installs these the same way as the LCU.

C. .NET RUNTIME (.NET 6 / 8 / 9, formerly .NET Core) - not a KB
   https://dotnet.microsoft.com/download/dotnet - pick the version line the grid reports, download the Windows
   x64 "Runtime" (or "Hosting Bundle" for IIS) installer (.exe). The tool reports installed runtimes and marks
   end-of-life lines; install by hand: <file>.exe /install /quiet /norestart

D. SQL SERVER CUMULATIVE UPDATE (CU) and SECURITY UPDATE (GDR)
   https://learn.microsoft.com/sql/database-engine/install-windows/latest-updates-for-microsoft-sql-server
   lists the latest CU and GDR per version (2016/2017/2019/2022) with build numbers. Compare with the build the
   grid reports (also SELECT @@VERSION on the instance). Download the CU .exe from the KB article; install by
   hand: SQLServer20xx-KBnnnnnnn-x64.exe /quiet /action=Patch /IAcceptSQLServerLicenseTerms /AllInstances

E. EXCHANGE SERVER SECURITY UPDATE (SU) and CUMULATIVE UPDATE (CU)
   https://learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates gives the build per CU/SU.
   SUs come from the Microsoft Download Center (search "Exchange Server 2019 security update <month>"); CUs are
   ISO images. Install by hand on the Exchange server, SU: <file>.exe /passive (run elevated); CU: setup from the ISO.

F. OTHER MICROSOFT COMPONENTS
   Defender platform/engine updates: catalog search "KB4052623" (platform) - normally delivered with definitions.
   Visual C++ runtimes, SQL ODBC/OLE DB drivers, Edge: vendor pages; the grid reports installed versions.

G. DRIVERS AND FIRMWARE: from the hardware or hypervisor vendor. VMware Tools and other third-party software: the
   Software tab, button "Where do I get software?" (the tool deploys them with the reboot suppressed).

SANITY CHECKS BEFORE YOU START
   * File name starts with windows10.0-kb... for Server 2016/2019/2022 (windows11.0-kb... = Server 2025); the
     tool reads the real target build from inside the file and blocks a mismatch.
   * Press "Reload lists + patches"; the new KB column appears, the patch list shows the OS the file is for,
     and "UNSIGNED" if the Microsoft signature is not valid - do not use such a file.
'@

function Get-PatchFiles {
    # Returns one object per usable patch file:
    #   Name, FullName, KB, SizeMB, Type, PatchType, Installable, OsLine, TargetBuild, TargetOs, Signature, Signer, Hash
    # PatchType comes from the sub-folder (patches\Windows, patches\DotNet, patches\SQL ...).  Files left in the
    # root of patches\ count as Windows so the version 1 layout keeps working.
    if (-not (Test-Path -LiteralPath $script:Config.PatchFolder)) {
        New-Item -ItemType Directory -Path $script:Config.PatchFolder -Force | Out-Null
        Write-PatchLog "Created empty patch folder $($script:Config.PatchFolder)" 'WARN'
    }
    foreach ($typeName in $script:Config.PatchTypes.Keys) {
        $sub = Join-Path $script:Config.PatchFolder $typeName
        if (-not (Test-Path -LiteralPath $sub)) { New-Item -ItemType Directory -Path $sub -Force | Out-Null }
    }

    $patches = @()
    $candidates = @()
    foreach ($f in (Get-ChildItem -LiteralPath $script:Config.PatchFolder -File)) { $candidates += [pscustomobject]@{ File = $f; PatchType = 'Windows' } }
    foreach ($typeName in $script:Config.PatchTypes.Keys) {
        $sub = Join-Path $script:Config.PatchFolder $typeName
        foreach ($f in (Get-ChildItem -LiteralPath $sub -File -ErrorAction SilentlyContinue)) { $candidates += [pscustomobject]@{ File = $f; PatchType = $typeName } }
    }
    $installableExt = @('.msu', '.cab')
    $reportExt      = @('.msu', '.cab', '.exe', '.msp', '.iso', '.zip')

    $seenNames = @{}
    foreach ($c in ($candidates | Sort-Object { $_.PatchType }, { $_.File.Name })) {
        $file = $c.File
        if ($file.Name -ieq 'README.txt') { continue }
        # one name, one staging path on the server: a second file with the same name (another sub-folder) is skipped
        if ($seenNames.ContainsKey($file.Name.ToLower())) { Write-PatchLog ("Skipping '{0}\{1}' - a file with the same name is already listed from {2}; both would land on the same staging path" -f $c.PatchType, $file.Name, $seenNames[$file.Name.ToLower()]) 'WARN'; continue }
        $seenNames[$file.Name.ToLower()] = $c.PatchType
        $mode = $script:Config.PatchTypes[$c.PatchType]
        $installable = ($mode -eq 'install')
        if ($installable -and $file.Extension -notin $installableExt) {
            Write-PatchLog "Skipping '$($c.PatchType)\$($file.Name)' - only .msu/.cab can be installed by the tool; put other installers in patches\Other" 'WARN'
            continue
        }
        if (-not $installable -and $file.Extension -notin $reportExt) { continue }
        $kb = ''
        if ($file.Name -match '(?i)(KB\d{6,7})') { $kb = $Matches[1].ToUpper() }
        if (-not $kb -and $installable) {
            Write-PatchLog "Skipping '$($file.Name)' - no KB number in the file name. Rename it to include e.g. KB5034770" 'WARN'
            continue
        }
        if (-not $kb) { $kb = [System.IO.Path]::GetFileNameWithoutExtension($file.Name); if ($kb.Length -gt 28) { $kb = $kb.Substring(0, 28) } }
        # "windows10.0-kb..." = Server 2016/2019/2022 line, "windows11.0-kb..." = Windows 11 / Server 2025 line
        $osLine = ''
        if ($file.Name -match '(?i)^(windows\d+\.\d+)') { $osLine = $Matches[1].ToLower() }
        Write-PatchLog ("Patch found [{0}]: {1}  ({2} MB, {3})" -f $c.PatchType, $kb, [math]::Round($file.Length / 1MB, 1), $file.Name) 'INFO'

        if ($installable) {
            $info = Get-PatchFileInfo -Path $file.FullName
        } else {
            # Hand-installed types: signature still checked (it is cheap insurance), no build or hash needed.
            $sigStatus = 'Unknown'; $signer = ''
            try { $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName -ErrorAction Stop; $sigStatus = [string]$sig.Status; if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject } } catch { }
            $info = [pscustomobject]@{ TargetBuild = 0; Signature = $sigStatus; Signer = $signer; Hash = ''; Source = 'n/a'; Family = ''; DotNet = ''; Kind = ''; Builds = @() }
        }
        # a .NET Framework rollup: the .NET line from inside the file, else from its name ("-ndp481")
        $dotNetLine = [string]$info.DotNet
        if (-not $dotNetLine -and $file.Name -match '(?i)-ndp(\d{2,3})') { $dotNetLine = ConvertTo-DotNetLine -Digits $Matches[1] }
        $patches += [pscustomobject]@{
            Name        = $file.Name
            FullName    = $file.FullName
            KB          = $kb
            SizeMB      = [math]::Round($file.Length / 1MB, 1)
            Type        = $file.Extension.TrimStart('.').ToLower()
            PatchType   = $c.PatchType
            Installable = $installable
            OsLine      = $osLine
            OsFamily    = [string]$info.Family      # 'windows10.0' for a .NET rollup (else '')
            DotNetLine  = $dotNetLine               # '4.8.1' for a .NET rollup (else '')
            TargetBuild = $info.TargetBuild
            TargetBuilds = @($info.Builds | ForEach-Object { [int]$_ })   # several builds one file is for (22H2 / 23H2 share a rollup): TargetBuild stays 0
            TargetOs    = $(if ($info.TargetBuild -gt 0) { Get-OsNameForBuild -Build $info.TargetBuild } elseif (@($info.Builds).Count -gt 0) { @($info.Builds | ForEach-Object { Get-OsNameForBuild -Build $_ }) -join ' / ' } else { 'unknown' })
            Signature   = $info.Signature
            Signer      = $info.Signer
            Hash        = $info.Hash
            Kind        = [string]$info.Kind        # cumulative / servicing stack / dotnet / dynamic update / other / '' (Get-PatchKindFromText)
        }
        if ($installable -and $info.Signature -ne 'Valid') {
            Write-PatchLog "  -> $kb signature is '$($info.Signature)' (signer: '$($info.Signer)'). It will show as 'Blocked: signature' unless RequireValidSignature is turned off in 01-Config.ps1" 'WARN'
        }
        if ($installable -and [string]$info.Kind -eq 'dynamic update') {
            Write-PatchLog "  -> $kb is a Dynamic Update (a Safe OS package for setup media and the recovery environment), not an update for a running server: it shows as 'Blocked: dynamic update'. The cumulative update carries what the server needs - delete the file, or move it to patches\Other" 'WARN'
        }
        $fileBuilds = @($info.Builds | ForEach-Object { [int]$_ })
        if ($installable -and $info.TargetBuild -eq 0 -and $fileBuilds.Count -gt 0) {
            Write-PatchLog "  -> $kb is one file for several Windows builds ($(@($fileBuilds | ForEach-Object { Get-OsNameForBuild -Build $_ }) -join ' / ')): READY on a server with one of them, 'Blocked: wrong OS' on any other" 'INFO'
        } elseif ($installable -and $info.TargetBuild -eq 0 -and $info.Family -and $info.DotNet) {
            Write-PatchLog "  -> $kb is a .NET Framework $($info.DotNet) rollup for the $($info.Family) line: no Windows build inside - each server's .NET line decides (Not applicable, or READY). DISM takes a rollup for another build as an empty wrapper and calls that success, so the install checks afterwards that the KB is on the server" 'INFO'
        } elseif ($installable -and $info.TargetBuild -eq 0) {
            Write-PatchLog "  -> $kb target build could not be read from inside the file. It will show as 'Blocked: OS unknown' unless AllowUnknownTargetBuild is turned on" 'WARN'
        }
    }

    # Two files with one KB (e.g. the .NET CU for 4.8 and 4.8.1) get two identical columns - say so.
    foreach ($group in ($patches | Group-Object KB | Where-Object { $_.Count -gt 1 })) {
        Write-PatchLog ("  -> {0} appears {1} times ({2}). Both columns show the same state; each file is still installed separately." -f $group.Name, $group.Count, (($group.Group | ForEach-Object { $_.Name }) -join ', ')) 'WARN'
    }
    if ($patches.Count -eq 0) {
        Write-PatchLog "No .msu/.cab files in $($script:Config.PatchFolder) - status checks still work, installs need a file" 'WARN'
    }
    $script:Patches = $patches
    return $patches
}

# Known Windows builds (the number BEFORE the dot in 20348.5622) -> friendly names.
$script:BuildNames = @{
    14393 = 'Server 2016'; 17763 = 'Server 2019'; 20348 = 'Server 2022'; 26100 = 'Server 2025 / Win11 24H2'
    19041 = 'Windows 10 2004'; 19042 = 'Windows 10 20H2'; 19043 = 'Windows 10 21H1'; 19044 = 'Windows 10 21H2'; 19045 = 'Windows 10 22H2'
    22000 = 'Windows 11 21H2'; 22621 = 'Windows 11 22H2'; 22631 = 'Windows 11 23H2'
}

function Get-OsNameForBuild {
    param([int]$Build)
    if ($Build -le 0) { return 'unknown' }
    if ($script:BuildNames.ContainsKey($Build)) { return $script:BuildNames[$Build] }
    return "build $Build"
}

function Get-PatchFileInfo {
    # Target build + signature + SHA256 of one file, cached in patches\_info\<file>.txt.
    # The cache is only trusted when the file's size and last-write time still match (a replaced
    # file with the same name is read again).  Reading takes a few seconds for a 600 MB file.
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    $infoFolder = $script:Config.PatchInfoFolder
    if (-not (Test-Path -LiteralPath $infoFolder)) { New-Item -ItemType Directory -Path $infoFolder -Force | Out-Null }
    $stamp = '{0}|{1}' -f $file.Length, $file.LastWriteTimeUtc.Ticks
    $cache = Join-Path $infoFolder ($file.Name + '.txt')

    if (Test-Path -LiteralPath $cache) {
        $h = @{}
        foreach ($line in (Get-Content -LiteralPath $cache)) { if ($line -match '^([A-Za-z]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
        # Reader=5: the cache also holds the OS family, the .NET line, the kind of package and the builds a .NET rollup is for
        # (read from inside its cab; older entries are read again)
        if ($h['Stamp'] -eq $stamp -and $h['Hash'] -and $h.ContainsKey('TargetBuild') -and $h.ContainsKey('Signature') -and $h['Reader'] -eq '5') {
            return [pscustomobject]@{ TargetBuild = [int]$h['TargetBuild']; Signature = $h['Signature']; Signer = $h['Signer']; Hash = $h['Hash']; Source = $h['Source']; Family = [string]$h['Family']; DotNet = [string]$h['DotNet']; Kind = [string]$h['Kind']
                                      Builds = @([string]$h['Builds'] -split ';' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }) }
        }
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $build = Read-PatchTargetBuild -Path $file.FullName
    # Signature: must be Valid AND signed by Microsoft.  Works offline (the Microsoft roots are in Windows).
    $sigStatus = 'Unknown'; $signer = ''
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $file.FullName -ErrorAction Stop
        $sigStatus = [string]$sig.Status
        if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        if ($sigStatus -eq 'Valid' -and $signer -notmatch 'O=Microsoft Corporation') { $sigStatus = 'ValidButNotMicrosoft' }
    } catch {
        $sigStatus = 'CheckFailed: ' + (Get-ShortError $_)
    }
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    $secs = [math]::Round($watch.Elapsed.TotalSeconds, 1)
    Write-PatchLog ("  -> {0}: target build {1} = {2} (from {3}); {4}; signature {5}; SHA256 {6}...  ({7} s, cached in patches\_info)" -f $file.Name, $build.Build, (Get-OsNameForBuild -Build $build.Build), $build.Source, $(if ($build.Kind) { 'a ' + $build.Kind + ' package' } else { 'kind of package not read' }), $sigStatus, $hash.Substring(0, 12), $secs) 'INFO'

    @("Stamp=$stamp", "TargetBuild=$($build.Build)", "TargetOs=$(Get-OsNameForBuild -Build $build.Build)", "Builds=$(@($build.Builds) -join ';')", "Source=$($build.Source)", "Family=$($build.Family)", "DotNet=$($build.DotNet)", "Kind=$($build.Kind)",
      "Signature=$sigStatus", "Signer=$signer", "Hash=$hash", "File=$($file.Name)", "Read=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", 'Reader=5') | Set-Content -LiteralPath $cache
    return [pscustomobject]@{ TargetBuild = $build.Build; Signature = $sigStatus; Signer = $signer; Hash = $hash; Source = $build.Source; Family = [string]$build.Family; DotNet = [string]$build.DotNet; Kind = [string]$build.Kind; Builds = @($build.Builds) }
}

function Get-PatchKindFromText {
    # What kind of package the manifest inside a file names (the .xml of an .msu, the update.mum of a .cab):
    #   cumulative       the monthly LCU: Package_for_RollupFix (the older .msu layout), or "Multiple_Packages" - the
    #                    2022 / 2025 layout, whose _uup.xml names the servicing stack cab AND the big cab that holds
    #                    the rollup as Multiple_Packages (read off a real KB5126655, 2026-10).  Checked first: the
    #                    servicing stack named beside it is inside this very file
    #   servicing stack  Package_for_ServicingStack alone - a separate SSU: goes before the cumulative update it prepares for
    #   dotnet           Package_for_DotNetRollup - a .NET Framework rollup
    #   dynamic update   Package_for_SafeOSDU - a Safe OS Dynamic Update: a package for setup media and the recovery
    #                    environment (WinRE), not for a running server.  Installed on one it stages, and the reboot undoes
    #                    it (field test 2026-11: it went first, being the smallest file, and was rolled back)
    #   other            any other Package_for_KB... (a standalone fix, the Secure Boot DBX update ...)
    #   ''               nothing recognisable
    param([string]$Text)
    if ($Text -match 'Package_for_RollupFix|name="Multiple_Packages"') { return 'cumulative' }
    if ($Text -match 'Package_for_ServicingStack') { return 'servicing stack' }
    if ($Text -match 'Package_for_DotNetRollup') { return 'dotnet' }
    if ($Text -match 'Package_for_SafeOS') { return 'dynamic update' }
    if ($Text -match 'Package_for_KB\d+') { return 'other' }
    return ''
}

function Read-PatchTargetBuild {
    # Which Windows build does this file target?  Read OFFLINE from inside the file with
    # expand.exe (part of Windows), in well under a second.
    #   .msu : the small .xml inside names every package with its version, e.g. 20348.5614.1.3;
    #          pkgProperties.txt has Installer Version="10.0.20348.1960"; the bundled servicing
    #          stack cab is called SSU-20348.xxxx-x64.cab.  Any of the three gives the build.
    #   .cab : update.mum inside carries the package version.
    #   .NET : a .NET Framework rollup (windows10.0-kb...-ndp481.msu) names NO Windows build in its outer files: pkgProperties
    #          says Applies to="Windows 10.0" (the whole line) and the .xml names Package_for_DotNetRollup_481.  The build is
    #          in the update.mum INSIDE its cab: the <parent> editions the rollup is for (10.0.20348.1 = Server 2022) - two
    #          expands, the cab out of the msu and update.mum out of the cab.  DISM does NOT refuse a rollup for another
    #          build: it installs the wrapper with every part skipped and returns 0 (field 2026-11, KB5127687 on a Server
    #          2019 toolkit PC), so the build has to be known here.  The file is also listed by its .NET line and OS family.
    # Returns @{ Build = <int, 0 = unknown>; Source = <where it was read from>; Family = 'windows10.0' or ''; DotNet = '4.8.1' or '';
    #            Builds = every build the file is for when there are several (22H2 / 23H2 share a rollup; Build stays 0 then);
    #            Kind = what the manifest names (Get-PatchKindFromText: cumulative / servicing stack / dotnet / dynamic update / other / '') }
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Get-Item -LiteralPath $Path
    $build = 0
    $how = ''
    $family = ''; $dotNet = ''; $kind = ''; $builds = @()
    $temp = Join-Path $script:Config.PatchInfoFolder ('tmp-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    # Windows' own expand.exe by its full path: a Git for Windows or MSYS install puts a GNU "expand" (a text tool) on
    # the PATH ahead of System32 on some operator PCs, and every file then reads as "not found" (seen 2026-10-29)
    $expand = Join-Path $env:SystemRoot 'System32\expand.exe'
    try {
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        if ($file.Extension -eq '.msu') {
            Write-PatchLog "expand.exe -F:*.xml `"$($file.FullName)`" `"$temp`"   (pulls one small file out of the MSU to read the target build)" 'CMD'
            $null = & $expand -F:*.xml "$($file.FullName)" "$temp" 2>&1
            $null = & $expand -F:*pkgProperties.txt "$($file.FullName)" "$temp" 2>&1
            foreach ($xml in @(Get-ChildItem -LiteralPath $temp -Filter '*.xml' -ErrorAction SilentlyContinue)) {
                $text = Get-Content -LiteralPath $xml.FullName -Raw
                foreach ($m in [regex]::Matches($text, 'version="(\d{5})\.\d+\.\d+\.\d+"')) {
                    if ($build -eq 0) { $build = [int]$m.Groups[1].Value; $how = $xml.Name }
                }
                if (-not $kind) { $kind = Get-PatchKindFromText -Text $text }
            }
            if ($build -eq 0) {
                foreach ($props in @(Get-ChildItem -LiteralPath $temp -Filter '*pkgProperties.txt' -ErrorAction SilentlyContinue)) {
                    $text = Get-Content -LiteralPath $props.FullName -Raw
                    if ($text -match 'Installer Version="10\.0\.(\d{5})\.') { $build = [int]$Matches[1]; $how = $props.Name }
                }
            }
            if ($build -eq 0) {
                $listing = (& $expand -D "$($file.FullName)" 2>&1) | Out-String
                if ($listing -match 'SSU-(\d{5})\.') { $build = [int]$Matches[1]; $how = 'SSU cab name' }
            }
            if ($build -eq 0) {
                # the update.mum inside the cab (a .NET rollup): the <parent> editions name the build the file is for
                Write-PatchLog "expand.exe -F:*.cab `"$($file.FullName)`" `"$temp`"   (the outer files name no build: reading the update.mum inside the cab)" 'CMD'
                $null = & $expand -F:*.cab "$($file.FullName)" "$temp" 2>&1
                foreach ($cab in @(Get-ChildItem -LiteralPath $temp -Filter '*.cab' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch '^WSUSSCAN' } | Sort-Object Length -Descending)) {
                    $inner = Join-Path $temp ('mum-' + $cab.BaseName)
                    New-Item -ItemType Directory -Path $inner -Force | Out-Null
                    $null = & $expand -F:update.mum "$($cab.FullName)" "$inner" 2>&1
                    $mum = Join-Path $inner 'update.mum'
                    if (-not (Test-Path -LiteralPath $mum)) { continue }
                    $text = Get-Content -LiteralPath $mum -Raw
                    if (-not $kind) { $kind = Get-PatchKindFromText -Text $text }
                    $found = @()
                    foreach ($el in [regex]::Matches($text, '<assemblyIdentity\b[^>]*>')) { if ($el.Value -match 'name="Microsoft-Windows-' -and $el.Value -match 'version="10\.0\.(\d{5})\.') { $found += [int]$Matches[1] } }
                    $found = @($found | Sort-Object -Unique)
                    if ($found.Count -gt 0) {
                        $builds = $found
                        if ($found.Count -eq 1) { $build = $found[0] }
                        $how = ('update.mum inside {0}: the parent editions are at build {1}' -f $cab.Name, ($found -join ' / '))
                        break
                    }
                }
            }
            if ($build -eq 0 -or $kind -eq 'dotnet') {
                foreach ($props in @(Get-ChildItem -LiteralPath $temp -Filter '*pkgProperties.txt' -ErrorAction SilentlyContinue)) {
                    $text = Get-Content -LiteralPath $props.FullName -Raw
                    if ($text -match 'Applies to="Windows (\d+\.\d+)"') { $family = 'windows' + $Matches[1] }
                }
                foreach ($xml in @(Get-ChildItem -LiteralPath $temp -Filter '*.xml' -ErrorAction SilentlyContinue)) {
                    $text = Get-Content -LiteralPath $xml.FullName -Raw
                    if ($text -match 'Package_for_DotNetRollup_?(\d{2,3})') { $dotNet = ConvertTo-DotNetLine -Digits $Matches[1] }
                }
                # the 4.8 rollup names its package without the digits: the cab inside (...-NDP48.cab) and the catalogue's own
                # file name (...-x64-ndp48_...msu) carry the line too
                if (-not $dotNet) {
                    $listing = (& $expand -D "$($file.FullName)" 2>&1) | Out-String
                    if ($listing -match '(?i)-NDP(\d{2,3})\.cab') { $dotNet = ConvertTo-DotNetLine -Digits $Matches[1] }
                    elseif ($file.Name -match '(?i)-ndp(\d{2,3})') { $dotNet = ConvertTo-DotNetLine -Digits $Matches[1] }
                }
                if ($build -eq 0 -and $builds.Count -eq 0) {
                    if ($family -and $dotNet) { $how = ('pkgProperties: a .NET Framework {0} rollup for the {1} line (no build inside)' -f $dotNet, $family) }
                    elseif ($family) { $how = ('pkgProperties: Applies to the {0} line (no build inside)' -f $family); $family = '' }   # only a .NET rollup is let through on the family alone
                }
            }
        } else {
            Write-PatchLog "expand.exe -F:update.mum `"$($file.FullName)`" `"$temp`"" 'CMD'
            $null = & $expand -F:update.mum "$($file.FullName)" "$temp" 2>&1
            $mum = Join-Path $temp 'update.mum'
            if (Test-Path -LiteralPath $mum) {
                $text = Get-Content -LiteralPath $mum -Raw
                if ($text -match 'version="(\d{5})\.\d+\.\d+\.\d+"') { $build = [int]$Matches[1]; $how = 'update.mum' }
                $kind = Get-PatchKindFromText -Text $text
            } else {
                # no update.mum: not a package DISM can add - a Setup Dynamic Update (setup files for installation media) or
                # some other archive; said so here, so the log and the patch list do not call it an unreadable build
                $how = 'no update.mum inside - not a Windows update package (a Setup Dynamic Update is setup files for installation media)'
            }
        }
    } catch {
        Write-PatchLog "Could not read the target build of $($file.Name): $(Get-ShortError $_)" 'WARN'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($build -eq 0 -and -not $how) { $how = 'not found' }
    return @{ Build = $build; Source = $how; Family = $family; DotNet = $dotNet; Kind = $kind; Builds = @($builds) }
}

function ConvertTo-DotNetLine {
    # '481' -> '4.8.1', '48' -> '4.8', '472' -> '4.7.2' (the digits a .NET rollup package and its file name carry)
    param([string]$Digits)
    if (-not $Digits) { return '' }
    return (($Digits.ToCharArray() | ForEach-Object { [string]$_ }) -join '.')
}

function Test-PatchOsMismatch {
    # $true when the file is for a different Windows build than the server runs.
    #   Best    : TargetBuild read from inside the file  vs  the server's build (20348 = 2022, 17763 = 2019)
    #   Fallback: the file-name line - "windows10.0" = Server 2016/2019/2022, "windows11.0" = Win11 / Server 2025
    #             (cannot tell 2019 from 2022 - that is why an unknown build is blocked by default)
    param($Status, $Patch)
    if (-not $Status.Build) { return $false }
    $major = 0
    [void][int]::TryParse(($Status.Build -split '\.')[0], [ref]$major)
    if ($major -eq 0) { return $false }
    if ($Patch.TargetBuild -gt 0) {
        $a = $Patch.TargetBuild; $b = $major
        if ($a -in 22621, 22631 -and $b -in 22621, 22631) { return $false }   # Win11 22H2/23H2 share packages
        return ($a -ne $b)
    }
    # one file for several builds (read from the update.mum inside a .NET rollup): the server's must be among them
    if ($Patch.PSObject.Properties['TargetBuilds'] -and @($Patch.TargetBuilds).Count -gt 0) { return (-not (@($Patch.TargetBuilds | ForEach-Object { [int]$_ }) -contains $major)) }
    if (-not $Patch.OsLine) { return $false }
    if ($Patch.OsLine -eq 'windows10.0' -and $major -ge 22000) { return $true }
    if ($Patch.OsLine -eq 'windows11.0' -and $major -lt 22000) { return $true }
    return $false
}

function Get-OsMismatchText {
    # Human wording for the plan and the log.
    param($Status, $Patch)
    if ($Patch.TargetBuild -gt 0) {
        return ("wrong OS - file is for {0} (build {1}), server is build {2}" -f $Patch.TargetOs, $Patch.TargetBuild, $Status.Build)
    }
    if ($Patch.PSObject.Properties['TargetBuilds'] -and @($Patch.TargetBuilds).Count -gt 0) {
        return ("wrong OS - file is for {0} (builds {1}), server is build {2}" -f $Patch.TargetOs, (@($Patch.TargetBuilds) -join ' / '), $Status.Build)
    }
    return ("wrong OS line - file is '{0}', server build is {1}" -f $Patch.OsLine, $Status.Build)
}

function Get-PatchVerdict {
    # THE single "can this KB go on this server?" decision.  The grid cell (Get-PatchCellText)
    # and the install plan (New-PatchPlan) both call it, so they can never disagree.
    # Order: not checked / unreachable / already installed / pending reboot / busy servicing /
    #        low disk / bad signature / OS unknown / wrong OS / READY (or READY (staged) when the file is on the server);
    #        an open install run on the server comes first of all, a .NET line the server does not run right after "by hand"
    param($Status, $Patch, [string]$Server = '')
    $v = [pscustomobject]@{ Go = $false; Cell = ''; Reason = '' }
    # an OS patch run the tool handed to this server and has not recorded yet (06-Install): the run's own KBs say so,
    # nothing else goes in meanwhile - before anything else, because the flag needs no status (also after a restart)
    if ($Server) {
        $flag = Get-InstallFlag -Server $Server
        if ($flag) {
            $mine = (@($flag.KBs | ForEach-Object { [string]$_ }) -contains [string]$Patch.KB)
            if ([string]$flag.State -eq 'unknown') {
                if ($mine) { $v.Cell = 'RUN UNKNOWN'; $v.Reason = ('the install run {0} started {1} by {2} ended without a result: {3} - press "Analyse a failure (ticked)"' -f $flag.Stamp, $flag.Started, $flag.Operator, $flag.Note) }
                else { $v.Cell = 'Blocked: run unknown'; $v.Reason = ('an install run on this server ({0}) ended without a result - analyse it first' -f $flag.Stamp) }
            } else {
                if ($mine) { $v.Cell = ('INSTALLING ({0} min)' -f (Get-InstallFlagMinutes -Flag $flag)); $v.Reason = ('installing since {0} by {1} (run {2}, a SYSTEM task on the server) - a status check records the result' -f $flag.Started, $flag.Operator, $flag.Stamp) }
                else { $v.Cell = 'Blocked: installing'; $v.Reason = ('run {0} is installing {1} on this server - wait for it' -f $flag.Stamp, (@($flag.KBs) -join ', ')) }
            }
            return $v
        }
    }
    if (-not $Status)                                 { $v.Cell = 'not checked';         $v.Reason = 'not checked yet'; return $v }
    if (-not $Status.Reachable)                       { $v.Cell = '?';                   $v.Reason = 'unreachable - see log'; return $v }
    if ($Status.HotFixIDs -contains $Patch.KB)        { $v.Cell = 'Installed';           $v.Reason = 'already installed'; return $v }
    # A cumulative update the server has already passed: Get-HotFix no longer lists it (the newer one replaced it),
    # but the build says so.  data\product-patches.psd1 gives the build each listed KB brings (Get-KnownPatchBuild).
    $known = Get-KnownPatchBuild -KB $Patch.KB
    $srvMajor = 0; $srvUbr = -1; if ([string]$Status.Build -match '^(\d+)\.(\d+)$') { $srvMajor = [int]$Matches[1]; $srvUbr = [int]$Matches[2] }
    if ($known -and $known.Build -eq $srvMajor -and $srvUbr -ge $known.UBR) { $v.Cell = 'Installed (build)'; $v.Reason = ('the server build {0} is at or above this update''s {1}.{2} - a later cumulative update already contains it' -f $Status.Build, $known.Build, $known.UBR); return $v }
    # the update history keeps a 'Succeeded' entry even after the update was removed again: the build has the last word
    $historyStale = ($known -and $known.Build -eq $srvMajor -and $srvUbr -ge 0 -and $srvUbr -lt $known.UBR)
    if ($Status.HistoryInstalledKBs -contains $Patch.KB -and -not $historyStale) { $v.Cell = 'Installed (history)'; $v.Reason = 'already installed (per Windows Update history)'; return $v }
    if ($Patch.PSObject.Properties['Installable'] -and -not $Patch.Installable) { $v.Cell = 'By hand'; $v.Reason = "$($Patch.PatchType) files are not installed by the tool - apply by hand, see the help text"; return $v }
    # a Safe OS Dynamic Update is for setup media and the recovery environment: on a running server it stages, and the
    # reboot undoes it (field test 2026-11) - the cumulative update of the same month carries what the server needs
    if ($Patch.PSObject.Properties['Kind'] -and [string]$Patch.Kind -eq 'dynamic update') { $v.Cell = 'Blocked: dynamic update'; $v.Reason = 'a Dynamic Update (Safe OS package for setup media and WinRE), not an update for a running server - the reboot would undo it; the cumulative update covers the server. Delete the file or move it to patches\Other'; return $v }
    # a .NET Framework rollup is for one .NET line: a server that runs another (the Inventory knows) does not take it
    if ($Server -and $Patch.PSObject.Properties['DotNetLine'] -and $Patch.DotNetLine) {
        $inv = Get-CollectorResult -Name 'Inventory' -Server $Server
        if ($inv -and $inv.Reachable -and $inv.PSObject.Properties['NetFramework'] -and $inv.NetFramework -and [string]$inv.NetFramework -ne [string]$Patch.DotNetLine) {
            $v.Cell = 'Not applicable'; $v.Reason = ('the file is for .NET Framework {0}; this server has {1} (inventory) - download the update for {1}' -f $Patch.DotNetLine, $inv.NetFramework); return $v
        }
    }
    if ($Status.PendingReboot)                        { $v.Cell = 'Blocked: reboot';     $v.Reason = "pending reboot ($($Status.RebootReasons)) - reboot first"; return $v }
    if ($Status.ServicingActive)                      { $v.Cell = 'Blocked: servicing';  $v.Reason = "servicing already running on the server ($($Status.ServicingReasons)) - wait and re-check"; return $v }
    # Trellix Solidcore enforcing at the reboot rolls the update back (poqexec.exe is denied); unreadable = fail closed
    if ($script:Config.RequireSolidcoreUpdateMode) {
        $sc = Get-SolidcoreInfo -Status $Status
        if ($sc.State -eq 'enforcing') { $v.Cell = 'Blocked: Solidcore'; $v.Reason = "Trellix Solidcore is enforcing ($(Get-SolidcoreText -Status $Status)) - the update would be rolled back when poqexec.exe runs at the reboot; wait for the Update Mode task, then check status again"; return $v }
        if ($sc.State -eq 'unknown')   { $v.Cell = 'Blocked: Solidcore'; $v.Reason = "Trellix Solidcore is on the server but its mode could not be read ($($sc.Error)) - run sadmin status on the server"; return $v }
    }
    if ($Status.FreeGB -lt $script:Config.MinFreeGB)  { $v.Cell = 'Blocked: disk';       $v.Reason = "low disk ($($Status.FreeGB) GB free on C:)"; return $v }
    if ($script:Config.RequireValidSignature -and $Patch.Signature -ne 'Valid') { $v.Cell = 'Blocked: signature'; $v.Reason = "file signature is '$($Patch.Signature)' - not a valid Microsoft-signed package"; return $v }
    $hasFamily = ($Patch.PSObject.Properties['OsFamily'] -and $Patch.OsFamily)   # a .NET rollup whose build was not read: the line (10.0 / 11.0) is known
    $hasBuilds = ($Patch.PSObject.Properties['TargetBuilds'] -and @($Patch.TargetBuilds).Count -gt 0)   # one file for several builds (22H2 / 23H2)
    if ($Patch.TargetBuild -le 0 -and -not $hasFamily -and -not $hasBuilds -and -not $script:Config.AllowUnknownTargetBuild) { $v.Cell = 'Blocked: OS unknown'; $v.Reason = 'target build could not be read from inside the file - see patches\_info and the log'; return $v }
    # the server side of the same guard: a build that could not be read must not pass as "no mismatch"
    $srvBuild = 0; [void][int]::TryParse(([string]$Status.Build -split '\.')[0], [ref]$srvBuild)
    if ($srvBuild -le 0) { $v.Cell = 'Blocked: OS unknown'; $v.Reason = "the server's Windows build could not be read ('$($Status.Build)') - check the status log"; return $v }
    if (Test-PatchOsMismatch -Status $Status -Patch $Patch) { $v.Cell = 'Blocked: wrong OS'; $v.Reason = (Get-OsMismatchText -Status $Status -Patch $Patch); return $v }
    $v.Go = $true; $v.Cell = 'READY'; $v.Reason = 'ready'
    # a .NET rollup whose build could not be read from inside: DISM does not refuse a rollup for another build - it goes in as
    # an empty wrapper with exit 0 (field 2026-11) - so the install checks afterwards that the KB is on the server
    if ($Patch.TargetBuild -le 0 -and $hasFamily -and -not $hasBuilds) { $v.Reason = ('ready - a .NET Framework {0} package for the {1} line; its Windows build could not be read, and DISM takes a .NET rollup for another build as an empty wrapper (exit 0, nothing installed) - the install checks afterwards that the KB is on the server' -f $Patch.DotNetLine, $Patch.OsFamily) }
    # a copy of the file already on the server (STAGE ONLY, or kept by an earlier run): same name and size - the install's
    # copy step checks the hash and skips the transfer
    if ($Status.PSObject.Properties['StagedFiles']) {
        foreach ($sf in @($Status.StagedFiles)) {
            $parts = [string]$sf -split '\|'
            if ($parts.Count -ge 2 -and $parts[0] -eq [string]$Patch.Name -and [math]::Round(([double]$parts[1]) / 1MB, 1) -eq [double]$Patch.SizeMB) { $v.Cell = 'READY (staged)'; $v.Reason = 'ready - the file is already on the server (STAGE ONLY); PATCH IT! checks its hash and skips the copy'; break }
        }
    }
    if ($historyStale -and $Status.HistoryInstalledKBs -contains $Patch.KB) { $v.Reason = ('ready - the update history lists it as installed, but the build {0} is below its {1}.{2} (removed again?)' -f $Status.Build, $known.Build, $known.UBR) }
    return $v
}

function Get-SolidcoreInfo {
    # Trellix Solidcore (Application Control) as the status check read it.  The raw "sadmin status" lines are parsed
    # here, on the operator side, so the rule sits in one testable place:
    #   Present   : sadmin.exe (or the scsrvc service) exists on the server
    #   Mode      : the "Solidifier:" line - Enabled (enforcing), Update (Update Mode) or Disabled
    #   OnReboot  : the "Solidifier on reboot:" line - the mode the pending operations run under at the next boot
    #   State     : '' = not on the server; 'ok' = Update or Disabled now AND on reboot; 'enforcing' = Enabled now or on
    #               reboot (the update would be rolled back at the boot); 'unknown' = present but not readable
    param($Status)
    $info = [pscustomobject]@{ Present = $false; Mode = ''; OnReboot = ''; Cli = ''; Epo = ''; Error = ''; State = ''; Lines = @() }
    if (-not $Status -or -not $Status.PSObject.Properties['SolidcorePresent'] -or -not $Status.SolidcorePresent) { return $info }
    $info.Present = $true; $info.Error = [string]$Status.SolidcoreError; $info.Lines = @($Status.SolidcoreLines | ForEach-Object { [string]$_ })
    foreach ($l in $info.Lines) {
        if ($l -match '(?i)solidifier on reboot\s*:\s*(.+?)\s*$') { $info.OnReboot = $Matches[1] }
        elseif ($l -match '(?i)solidifier\s*:\s*(.+?)\s*$') { $info.Mode = $Matches[1] }
        elseif ($l -match '(?i)cli access\s*:\s*(.+?)\s*$') { $info.Cli = $Matches[1] }
        elseif ($l -match '(?i)epo managed\s*:\s*(.+?)\s*$') { $info.Epo = $Matches[1] }
    }
    if (-not $info.Mode -and -not $info.Error) { $info.Error = 'no "Solidifier:" line in the sadmin status output' }
    # the mode ON REBOOT is the one the update is applied under: without it the guard knows half and fails closed (R6-B05)
    if ($info.Mode -and -not $info.OnReboot -and -not $info.Error) { $info.Error = 'no "Solidifier on reboot:" line in the sadmin status output' }
    if ($info.Error -or -not $info.Mode) { $info.State = 'unknown'; return $info }
    $info.State = 'ok'
    foreach ($m in @($info.Mode, $info.OnReboot)) { if ($m -and $m -notmatch '(?i)update|disabled') { $info.State = 'enforcing' } }
    return $info
}

function Get-SolidcoreText {
    # The Solidcore cell of the grid and the status line: '' when Solidcore is not on the server, else "now, on reboot".
    param($Status)
    $i = Get-SolidcoreInfo -Status $Status
    if (-not $i.Present) { return '' }
    if ($i.State -eq 'unknown') { return 'could not be read' }
    $later = $i.OnReboot; if (-not $later) { $later = '?' }
    if ($i.State -eq 'enforcing') { return ('ENFORCING: {0} now, {1} on reboot' -f $i.Mode, $later) }
    return ('{0} now, {1} on reboot' -f $i.Mode, $later)
}

function Test-TrellixInUse {
    # TrellixInUse (Settings tab): off where Trellix is not used - its columns, boxes, buttons, warnings and confirmation go.
    return [bool]$script:Config.TrellixInUse
}

function Get-TrellixAgentInfo {
    # The Trellix Agent (ePO agent) services as the status check read them - masvc "Trellix Agent Service" and macmnsvc
    # "Trellix Agent Common Services", one 'Name|DisplayName|State|StartMode' line each (TrellixAgentLines).  Read here,
    # on the operator side, so the rule sits in one testable place:
    #   Present  : at least one of the two services exists on the server
    #   State    : '' = not on the server; 'unknown' = the services could not be read (TrellixAgentError);
    #              'running' = every service Running and Auto (the normal state); 'stopped' = every
    #              service Stopped and Disabled (what the tool sets before an install); 'mixed' = anything else (one of
    #              each, Running but Manual or Disabled, Stopped but Automatic ...) - it would not come back at a boot
    #   Text     : the grid cell - 'Running (Auto)', 'STOPPED (Disabled)', 'MIXED: masvc Running/Auto, macmnsvc Stopped/Disabled'
    # The field test (October 2026) found an OS patch install only completes with both Disabled and stopped; stopped is
    # still shown as a warning, because ePO hears nothing from the server until they run again.
    param($Status)
    $info = [pscustomobject]@{ Present = $false; State = ''; Text = ''; Services = @() }
    if (-not $Status -or -not $Status.PSObject.Properties['TrellixAgentLines']) { return $info }
    # the services could not be read: unknown, never "not on the server" - the install's stop step must not pass on it (R6-11)
    if ($Status.PSObject.Properties['TrellixAgentError'] -and $Status.TrellixAgentError) { $info.Present = $true; $info.State = 'unknown'; $info.Text = 'could not be read'; return $info }
    foreach ($l in @($Status.TrellixAgentLines)) {
        $p = [string]$l -split '\|'
        if ($p.Count -ge 4 -and $p[0]) { $info.Services += [pscustomobject]@{ Name = $p[0]; DisplayName = $p[1]; State = $p[2]; StartMode = $p[3] } }
    }
    if ($info.Services.Count -eq 0) { return $info }
    $info.Present = $true
    $n = $info.Services.Count
    $running = @($info.Services | Where-Object { $_.State -eq 'Running' -and $_.StartMode -eq 'Auto' }).Count
    $stopped = @($info.Services | Where-Object { $_.State -eq 'Stopped' }).Count
    $disabled = @($info.Services | Where-Object { $_.StartMode -eq 'Disabled' }).Count
    if ($running -eq $n) {
        $info.State = 'running'
        $info.Text = 'Running (Auto)'
    } elseif ($stopped -eq $n -and $disabled -eq $n) {
        $info.State = 'stopped'
        $info.Text = 'STOPPED (Disabled)'
    } else {
        $info.State = 'mixed'
        $info.Text = 'MIXED: ' + (@($info.Services | ForEach-Object { '{0} {1}/{2}' -f $_.Name, $_.State, $_.StartMode }) -join ', ')
    }
    return $info
}

function Get-TrellixAgentText {
    # The Trellix Agent cell of the grid and the status line: '' when the agent is not on the server.
    param($Status)
    return (Get-TrellixAgentInfo -Status $Status).Text
}

function Get-KnownPatchBuild {
    # The build a Windows cumulative update brings, from data\product-patches.psd1 (Windows = this month per build;
    # WindowsHistory = earlier months, optional).  $null when the KB is not listed or its UBR is not filled in.
    param([string]$KB)
    if (-not $KB) { return $null }
    $pp = Import-ToolData -Name 'product-patches.psd1'
    if (-not $pp) { return $null }
    foreach ($e in @($pp.Windows) + @($pp.WindowsHistory)) {
        if ($e -and [string]$e.KB -ieq $KB -and [int]$e.UBR -gt 0 -and [int]$e.Build -gt 0) { return [pscustomobject]@{ Build = [int]$e.Build; UBR = [int]$e.UBR } }
    }
    return $null
}
