# =====================================================================
#  50-Console-Software.ps1  -  THE SOFTWARE CONSOLE (deploy, update, remove)
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Third-party software, handled the way OS patches are:
#    - a catalogue, data\software-packages.psd1: what may be deployed, how
#      (the exact silent command line, the reboot always suppressed), where
#      (VMware Tools on VMware virtual machines only) and in which modes
#      (Install, Update, Uninstall)
#    - installer files in software\<package Id>\, vetted here: version,
#      Authenticode signer named in the catalogue, SHA256
#    - STAGE ONLY copies an installer ahead of the change window; INSTALL /
#      UPDATE runs it with the reboot suppressed, so one reboot ("Reboot
#      ticked servers") finishes both the OS patches and the software
#    - UNINSTALL removes ticked products (MSI product code, or the product's
#      own QuietUninstallString) - never a protected product, never one the
#      server's SOE standard requires
#  Every install, update and removal goes through: a fresh check, the plan,
#  the change record (11-ChangeLog.ps1), the pre-action confirmations
#  (Settings tab: snapshot, Trellix ...), a re-check - and for a removal
#  one more confirmation.
#
#  ON THE SERVER each item runs as a one-shot scheduled task (SYSTEM, in
#  the task folder \WinRMToolkit\) instead of inside the WinRM session:
#    - the VMware Tools installer replaces the network driver; the WinRM
#      connection drops, the task does not
#    - installers get a full SYSTEM token, not a network logon
#  The tasks of one run are queued and started one at a time (Windows
#  Installer runs one install at a time - exit 1618 otherwise); each poll
#  collects finished items, writes the server's own record (Application
#  event 910, C:\PatchStaging\change-log.txt, a result file) and starts the
#  next.  If the tool goes away, nothing new starts on its own.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  50-Console-Software.ps1  (new 2026-10-20)
# ---------------------------------------------------------------------
#  Field test needed: a VMware Tools update on a test VM (the network drop,
#  exit 3010, the DisplayVersion format), an MSI install and removal, a
#  removal through a QuietUninstallString, a run that times out.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _______cf_______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] the safety pop-ups answered No   [-] change record cancelled
#               [x] a protected product refused       [x] ran against a test VM
#  Comments   :
#    -
# =====================================================================

# Shown by the "Where do I get software?" button and in the Code Tour.  Edit freely.
$script:SoftwareHowTo = @'
WHERE TO FIND SOFTWARE UPDATES  (on a machine that has internet, then copy the files into software\<package>\)

The Software console deploys only what data\software-packages.psd1 describes: the folder, the file pattern, the
signer and the exact silent command line of each package. The reboot is always suppressed, so it can be taken
together with the OS patches ("Reboot (ticked)").

A. VMWARE TOOLS - DEPLOYED BY THIS TOOL, NOT BY VCENTER
   1. Download - NO BROADCOM ACCOUNT NEEDED. Every release is published openly at
      https://packages.vmware.com/tools/releases/ - open the version folder, then windows, then x64.
   2. Example, VMware Tools 12.5.4:
      https://packages.vmware.com/tools/releases/12.5.4/windows/x64/
      - take the .exe in that folder, VMware-tools-12.5.4-24964629-x64.exe (the 64-bit Windows installer). The
      newest release is always in https://packages.vmware.com/tools/releases/latest/windows/x64/
   3. ESXi hosts: the release notes do not list ESXi versions; they point to the Broadcom Product Interoperability
      Matrix, https://interopmatrix.broadcom.com (VMware Tools against VMware vSphere ESXi). VMware Tools is upgraded
      independently of vSphere, but only the matrix says whether a release is supported on your hosts.
   4. Windows: read the release notes of the release you deploy. For 12.5.4 they say: 64-bit Windows from Windows 7
      SP1 / Windows Server 2008 R2 SP1 on, and the Microsoft Visual C++ 2015-2022 Redistributable (x86 and x64)
      version 14.40.33816 is a prerequisite - installing or upgrading is not supported without it. Minimum VMware
      Tools per Windows Server version (Broadcom KB 313371): 2016 and 2019 - 10.1.0; 2022 - 10.3.5 (12.0.0
      recommended); 2025 - 11.3.0 (12.5.0 recommended). The Windows version must also be supported on your ESXi
      version: the VMware Compatibility Guide, guest operating systems.
   5. Copy the file into software\VMwareTools\ and press "Reload lists + packages". Keep the file name: the version
      is read from it (VMware-tools-12.5.4-24964629-x64.exe gives 12.5.4.24964629; older releases end -x86_64.exe
      and are read the same way). The tool checks that the file is signed by VMware or Broadcom and shows its SHA256
      (hover the installer's row);
      a file that fails is listed as BLOCKED with the reason. If your change process wants a checksum,
      Get-FileHash <file> -Algorithm SHA256 gives the same value.
   6. Stop vSphere upgrading the Tools of these VMs, or vCenter and this tool take turns: VM > Edit Settings > VM
      Options > VMware Tools > untick "Check and upgrade VMware Tools before each power on", and leave the VMs out
      of any vSphere Lifecycle Manager VMware Tools remediation.
   7. The command line comes from data\software-packages.psd1: the installer with /S /v and the MSI options /qn
      REBOOT=R and a log file, plus ADDLOCAL=ALL for a new install. REBOOT=R suppresses the reboot. Exit 3010 means
      a reboot completes it: take it with the OS patches.
   8. The installer may replace the VMXNET3 network driver, so the connection can drop for a few seconds. The
      install runs as a SYSTEM task on the server and carries on; the tool reconnects to read the result.
   9. The tool never removes VMware Tools (without it the VM loses its paravirtual network and storage drivers).

B. ANY OTHER PRODUCT - AN MSI WHERE THE VENDOR OFFERS ONE
   1. Get the vendor's MSI, or an .exe with a documented silent switch AND a no-reboot switch, from the vendor
      portal. Check its SHA256 against the vendor's.
   2. Put the file in any folder under software\ (any name, spaces fine, e.g. software\Google Chrome\) and press
      Reload lists + packages. It shows as * NEW in a yellow box under the installer list.
   3. Press Register... next to it. The form is filled from the file: name, version
      source, file pattern, the signer to trust, and names the fleet's inventory has seen for Match. For an .exe,
      give the vendor's silent switches - they must suppress the reboot (REBOOT=R, REBOOT=ReallySuppress or
      /norestart) or the form refuses. Install, Update and Uninstall start ticked: leave Uninstall ticked unless the
      product must never be removed (unticked, UNINSTALL refuses it - right for VMware Tools, wrong for an ordinary
      application). The preview shows the exact command lines; Register writes the package into
      data\software-packages.psd1.
   4. Later versions dropped into the same folder are picked up by the file pattern - no new registration.
   5. To change a registration later, press Edit... next to any of its installers in the installer list: the same
      form, filled from the entry. Save changes rewrites only that entry; its comments are kept.

C. WHICH PRODUCTS NEED ATTENTION
   The inventory list on the Software tab (and the O/S Patching console's software grid) marks products Behind,
   Stale, Ageing or End of life against data\known-apps.psd1 and the rest of the fleet. For the vendor's current
   version use its release notes or download page, and record it as Latest in known-apps.psd1 so every server is
   judged against it.

D. REMOVING SOFTWARE
   Tick products in the inventory list, then UNINSTALL. An MSI product is removed with msiexec /x <product code>
   /qn /norestart REBOOT=ReallySuppress; another product with its own QuietUninstallString, with that
   uninstaller's no-restart switches added (Inno Setup /NORESTART /SUPPRESSMSGBOXES, WiX bundles /norestart).
   An uninstaller with no known switch shows "quiet (may restart)" and the plan warns. Never removed: products
   with neither, protected products (ProtectedProducts in software-packages.psd1, or a package without
   Uninstall - Edit... ticks it) and products the server's SOE standard requires. "dormant" in the Use column =
   installed long ago and nothing on the server uses its folder (no service, process or task): confirm with the
   owner first. After a removal the server reads "advised: removed ..." until its next reboot: plan that reboot
   as its own step - it finishes what the uninstaller left for the next start.

SANITY CHECKS
   * One version per package per run. The plan shows the installed version, the target and why a server is
     skipped before anything is asked.
   * Every install, update, removal and reboot asks for a change reference. It is kept in changes\change-log.csv
     and on the server: Application event 910 (920 for a reboot) and C:\PatchStaging\change-log.txt.
   * After a run the inventory is read again. A version that has not moved yet may mean the installer is still
     finishing - press Check again in a few minutes.
'@
# the Code Tour (08-CodeTour.ps1, loaded before this file) shows this text as topic S3
foreach ($tourEntry in @($script:CodeTour)) { if ([string]$tourEntry.Title -like 'S3.*') { $tourEntry.Explain = $script:SoftwareHowTo } }

# ---------------------------------------------------------------------
#  The catalogue and the installer files
# ---------------------------------------------------------------------
function Get-SoftwareCatalogue {
    $d = Import-ToolData -Name 'software-packages.psd1'
    if ($d) { return $d }
    # Unreadable: the protection list is gone with it, so Get-ProductProtection protects every product until it can be read
    return @{ AsOf = 'n/a'; Packages = @(); ProtectedProducts = @(); Unreadable = $true }
}

function Test-SignerAllowed {
    # Does the O= (organisation) of a certificate subject START with one of the package's Signers?  "O=VMware, Inc." and
    # O="VMware, Inc." both match 'VMware'.  The subject is split into its parts first (X500DistinguishedName), so an
    # "O=" inside another part's quoted value (a CN of 'x, O=VMware') is never taken for the organisation.
    # The remote run script repeats this exact test on the server.
    param([string]$Subject, [object[]]$Signers)
    $orgs = @()
    try { $orgs = @((New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName $Subject).Format($true) -split "`r?`n" | Where-Object { $_ -match '^O=' } | ForEach-Object { ($_.Substring(2).Trim() -replace '^"(.*)"$', '$1') }) } catch { $orgs = @() }
    foreach ($s in @($Signers)) { foreach ($o in $orgs) { if ($s -and $o.StartsWith([string]$s, [System.StringComparison]::OrdinalIgnoreCase)) { return $true } } }
    return $false
}

function Get-SignerOrg {
    # "CN=..., O=""VMware, Inc."", L=..." -> "VMware, Inc."
    param([string]$Subject)
    if ($Subject -match '(^|,\s*)O="([^"]+)"') { return $Matches[2] }
    if ($Subject -match '(^|,\s*)O=([^,]+)') { return $Matches[2].Trim() }
    return ''
}

function Test-RebootSuppressed {
    param([string]$Arguments)
    return ([string]$Arguments -match '(?i)REBOOT=(R|ReallySuppress)\b|/norestart\b')
}

function Test-RebootForced {
    # An argument that makes an installer restart the server: REBOOT= with anything but R / ReallySuppress (msiexec takes
    # the LAST value of a property, so one after the tool's own REBOOT=ReallySuppress wins), or a force/prompt-restart
    # switch.  Reboots come from the Reboot button only (R6-C02).
    param([string]$Arguments)
    foreach ($m in [regex]::Matches([string]$Arguments, '(?i)\bREBOOT\s*=\s*"?([A-Za-z]*)')) { if ($m.Groups[1].Value -notmatch '^(?i)(R|ReallySuppress)$') { return $true } }
    return ([string]$Arguments -match '(?i)(^|\s)[/-](forcerestart|promptrestart|forcereboot|reboot)(\s|$)')
}

function Get-SoftwareArguments {
    # The arguments of one mode, straight from the catalogue (an MSI gets its fixed part on the server).
    param($Package, [string]$Mode)
    if ([string]$Package.Installer -eq 'msi') { return [string]$Package.Arguments }
    if ($Mode -eq 'Update' -and $Package.UpdateArguments) { return [string]$Package.UpdateArguments }
    if ($Mode -eq 'Install' -and $Package.InstallArguments) { return [string]$Package.InstallArguments }
    return [string]$Package.Arguments
}

function Get-MsiProperty {
    # One value from an .msi's Property table (ProductVersion, ProductCode ...) through the Windows Installer COM object.
    param([string]$Path, [string]$Property)
    $msiApp = $null; $db = $null; $view = $null; $rec = $null
    try {
        $msiApp = New-Object -ComObject WindowsInstaller.Installer
        $db = $msiApp.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $msiApp, @($Path, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property = '$Property'"))
        [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
        $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($rec) { return [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
        return ''
    } catch { return '' }
    finally {
        if ($view) { try { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) } catch { } }
        foreach ($com in @($rec, $view, $db, $msiApp)) { if ($com) { try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($com) } catch { } } }
    }
}

function Get-SoftwareFileVersion {
    # The version an installer file brings: from its name (VersionRegex, groups joined by dots), from inside the .msi, or the .exe's ProductVersion.
    param($Package, $File)
    switch ([string]$Package.VersionFrom) {
        'msi' { return (Get-MsiProperty -Path $File.FullName -Property 'ProductVersion') }
        'file' { $m = [regex]::Match([string]$File.VersionInfo.ProductVersion, '\d+(\.\d+){0,3}'); if ($m.Success) { return $m.Value }; return '' }
        default {
            if (-not $Package.VersionRegex) { return '' }
            $m = [regex]::Match($File.Name, [string]$Package.VersionRegex, 'IgnoreCase')
            if (-not $m.Success -or $m.Groups.Count -lt 2) { return '' }
            return ((@(1..($m.Groups.Count - 1) | ForEach-Object { $m.Groups[$_].Value } | Where-Object { $_ })) -join '.')
        }
    }
}

function Get-SoftwarePackageBlock {
    # Why a file cannot be deployed, or '' when it can.  Checked on this PC; the server repeats hash, signer and version.
    param($Package, $Info)
    $inst = [string]$Package.Installer
    if ($inst -notin 'exe', 'msi') { return "Installer must be 'exe' or 'msi' (is '$inst')" }
    $modes = @($Package.Modes)
    if ($modes -notcontains 'Install' -and $modes -notcontains 'Update') { return 'the catalogue allows neither Install nor Update for this package' }
    if (-not $Info.Version) { return 'version not readable (file name does not match VersionRegex, or no version inside the file)' }
    if ($null -eq (ConvertTo-VersionObject $Info.Version)) { return "version '$($Info.Version)' is not a version number" }
    # AllowUnsigned: a real true/false only ('false' in quotes would read as true and switch the check off, R6-C06), and it
    # accepts a file without a signature - never one changed after it was signed (R6-C05)
    if ($null -ne $Package.AllowUnsigned -and $Package.AllowUnsigned -isnot [bool]) { return ("AllowUnsigned must be `$true or `$false (is '{0}')" -f $Package.AllowUnsigned) }
    if ($Info.Signature -eq 'HashMismatch') { return 'signature HashMismatch: the file was changed after it was signed' }
    foreach ($field in 'Arguments', 'InstallArguments', 'UpdateArguments') { if (Test-RebootForced ([string]$Package.$field)) { return ("the {0} would restart the server ({1}) - reboots come from the Reboot button only" -f $field, [string]$Package.$field) } }
    if (-not $Package.AllowUnsigned) {
        if ($Info.Signature -ne 'Valid') { return "signature $($Info.Signature)" }
        if (-not (Test-SignerAllowed -Subject $Info.Signer -Signers @($Package.Signers))) { return ("signed by '{0}', not by {1} (Signers in software-packages.psd1)" -f (Get-SignerOrg $Info.Signer), (@($Package.Signers) -join ' / ')) }
    }
    if ($inst -eq 'exe') {
        foreach ($mode in @('Install', 'Update')) {
            if ($modes -notcontains $mode) { continue }
            $a = Get-SoftwareArguments -Package $Package -Mode $mode
            if (-not (Test-RebootSuppressed $a)) { return "the $mode arguments do not suppress the reboot (REBOOT=R, REBOOT=ReallySuppress or /norestart)" }
        }
    }
    # a hand-written entry: without Match nothing on a server ever matches, so the installer would run over a copy already there;
    # an Id that is a column of the server grid would overwrite that column's cell
    if (-not ([string]$Package.Match).Trim()) { return 'Match is empty: the product name as Programs and Features shows it (* = any text)' }
    if ([string]$Package.Id -in $script:SoftwareFixedColumns) { return ("the Id '{0}' is a column name of the server grid - rename the package" -f $Package.Id) }
    return ''
}

function Get-SoftwarePackageFolder {
    # A package's folder under software\: its Folder field when the catalogue has one (any folder name, spaces and
    # sub-folders "Vendor\Product" allowed, '' = software\ itself), else its Id.
    param($Package)
    if ($Package -is [System.Collections.IDictionary]) { if ($Package.Contains('Folder')) { return ([string]$Package['Folder']).Trim().Trim('\') } }
    elseif ($Package.PSObject.Properties['Folder']) { return ([string]$Package.Folder).Trim().Trim('\') }
    return ([string]$Package.Id).Trim()
}

function Test-SoftwareFolderName {
    # '' when a relative folder can be used under software\, else why not.  Spaces are fine; only what Windows itself
    # refuses is refused.
    param([string]$Folder)
    if ($Folder -eq '') { return '' }
    if (($Folder -split '\\')[0] -ieq '_info') { return "software\_info is the tool's own cache folder" }
    foreach ($part in ($Folder -split '\\')) {
        if (-not $part.Trim()) { return 'it has an empty part between \ signs' }
        if ($part -match '[/:*?"<>|]') { return "'$part' holds a character Windows does not allow in a folder name (/ : * ? `" < > |)" }
        if ($part -in '.', '..') { return "'$part' is not a folder name" }
        if ($part -ne $part.TrimEnd(' ', '.')) { return "'$part' ends with a space or a dot, which Windows drops" }
    }
    return ''
}

function Get-SoftwareStageName {
    # The package's own sub-folder in C:\PatchStaging\software on a server: its Id with anything but letters, digits, . - _
    # turned into _ ("Google Chrome" -> Google_Chrome), so two installers both called setup.exe never share a path there.
    param([string]$Id)
    $n = ([string]$Id -replace '[^A-Za-z0-9._-]', '_').Trim('.')
    if (-not $n) { $n = 'package' }
    return $n
}

function Get-SoftwarePackageFiles {
    # Scans software\ - every folder, any name, any depth - and sorts what it finds:
    #   offered  (returned, $script:SoftwareFiles) files a package claims (its folder + FilePattern), vetted, newest version
    #            first per package: Id, Name, Folder, File, FullName, Length, SizeMB, Version, Signature, Signer, Hash,
    #            Blocked ('' = usable), Package
    #   detected ($script:SoftwareDetected) .msi / .exe files no package claims yet - the Register button turns one into a
    #            package; until then the installer list shows them as NEW
    #   notes    ($script:SoftwareNotOffered) what cannot be used at all, and why
    # Hash, signature and version are computed once per file version (name, size, time) and kept in
    # software\_info\vetting-cache.json, so a big library is read in full once, not at every start (Read-SoftwareVettingCache).
    $cat = Get-SoftwareCatalogue
    $root = $script:Config.SoftwareFolder
    if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Path $root -Force | Out-Null }
    $root = (Get-Item -LiteralPath $root).FullName.TrimEnd('\')
    $infoDir = Join-Path $root '_info'
    if (-not $script:SoftwareFileCache) { $script:SoftwareFileCache = Read-SoftwareVettingCache }
    $script:SoftwareVerdictCache = @{}   # the files may have changed: every verdict is worked out again
    $vetted = 0; $seenKeys = New-Object System.Collections.Generic.List[string]
    $found = New-Object System.Collections.Generic.List[object]
    $notOffered = New-Object System.Collections.Generic.List[string]
    $claimed = @{}
    $ids = @{}
    foreach ($pkg in @($cat.Packages)) {
        if (-not $pkg) { continue }
        $id = ([string]$pkg.Id).Trim()
        if (-not $id) { $notOffered.Add(("package '{0}' has no Id - give it one in data\software-packages.psd1" -f $pkg.Name)); continue }
        if ($ids.ContainsKey($id.ToLower())) { $notOffered.Add(("two packages share the Id '{0}' - the second is ignored; rename one in data\software-packages.psd1" -f $id)); continue }
        $ids[$id.ToLower()] = $true
        $rel = Get-SoftwarePackageFolder -Package $pkg
        $why = Test-SoftwareFolderName $rel
        if ($why) { $notOffered.Add(("package {0}: its folder '{1}' cannot be used - {2}" -f $id, $rel, $why)); continue }
        $folder = $root; if ($rel) { $folder = Join-Path $root $rel }
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
        foreach ($f in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like [string]$pkg.FilePattern })) {
            $claimed[$f.FullName.ToLower()] = $id
            $key = '{0}|{1}|{2}' -f $f.FullName.ToLower(), $f.Length, $f.LastWriteTimeUtc.Ticks
            $seenKeys.Add($key)
            # the version depends on the package's VersionFrom / VersionRegex too: an edited package reads it again
            $spec = '{0}|{1}' -f $pkg.VersionFrom, $pkg.VersionRegex
            $info = $script:SoftwareFileCache[$key]
            $fresh = $false
            if (-not $info) {
                Set-GuiStatus "Vetting $($f.Name) (SHA256, signature) ..."
                $sigStatus = 'Unknown'; $signer = ''
                try { $sig = Get-AuthenticodeSignature -LiteralPath $f.FullName -ErrorAction Stop; $sigStatus = [string]$sig.Status; if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject } } catch { }
                $info = @{ Hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; Signature = $sigStatus; Signer = $signer; Version = (Get-SoftwareFileVersion -Package $pkg -File $f); Spec = $spec }
                $script:SoftwareFileCache[$key] = $info
                $fresh = $true; $vetted++
            } elseif ([string]$info.Spec -ne $spec) {
                $info.Version = Get-SoftwareFileVersion -Package $pkg -File $f; $info.Spec = $spec
                $fresh = $true; $vetted++
            }
            $block = Get-SoftwarePackageBlock -Package $pkg -Info $info
            $found.Add([pscustomobject]@{ Id = $id; Name = [string]$pkg.Name; Folder = $rel; File = $f.Name; FullName = $f.FullName; Length = $f.Length; SizeMB = [math]::Round($f.Length / 1MB, 1); Version = [string]$info.Version; Signature = $info.Signature; Signer = $info.Signer; Hash = $info.Hash; Blocked = $block; Package = $pkg })
            # one line per file only when it is new to the tool or blocked - a big library would bury the log at every reload
            if ($block) { Write-PatchLog ("Software [{0}]: {1} version {2} - BLOCKED: {3}" -f $id, $f.Name, $info.Version, $block) 'WARN' }
            elseif ($fresh) { Write-PatchLog ("Software found [{0}]: {1} version {2} ({3} MB)" -f $id, $f.Name, $info.Version, [math]::Round($f.Length / 1MB, 1)) 'INFO' }
        }
    }
    # everything else under software\ that is an installer: NEW, ready to register (field report 2026-10-21: an installer
    # in a folder no package named was skipped without a word)
    $detected = New-Object System.Collections.Generic.List[object]
    foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Recurse -ErrorAction SilentlyContinue)) {
        if ($claimed.ContainsKey($f.FullName.ToLower())) { continue }
        if ($f.FullName.StartsWith($infoDir + '\', [System.StringComparison]::OrdinalIgnoreCase)) { continue }   # the tool's own cache
        $rel = $f.DirectoryName.Substring($root.Length).Trim('\')
        $ext = $f.Extension.ToLower()
        $shown = $f.Name; if ($rel) { $shown = $rel + '\' + $f.Name }
        if ($ext -in '.msi', '.exe') {
            $reason = 'not registered yet'
            $owner = @(@($cat.Packages) | Where-Object { $_ -and (Get-SoftwarePackageFolder -Package $_) -ieq $rel })
            if ($owner.Count -gt 0) { $reason = ("in the folder of package {0}, but its FilePattern '{1}' does not match this name" -f ([string]$owner[0].Id).Trim(), $owner[0].FilePattern) }
            $detected.Add([pscustomobject]@{ Folder = $rel; File = $f.Name; FullName = $f.FullName; Length = $f.Length; SizeMB = [math]::Round($f.Length / 1MB, 1); Extension = $ext; Reason = $reason })
            Write-PatchLog ("Software NEW: software\{0} ({1} MB) - {2}; select it in the Software tab and press Register" -f $shown, [math]::Round($f.Length / 1MB, 1), $reason) 'INFO'
        } elseif ($ext -in '.msp', '.msix', '.appx', '.msixbundle', '.zip', '.iso', '.cab', '.msu', '.7z') {
            $notOffered.Add(("software\{0} - the Software console runs .msi and .exe installers only ({1} is not one; OS patches go in patches\)" -f $shown, $ext))
        }
    }
    foreach ($note in $notOffered) { Write-PatchLog ("Software NOT offered: " + $note) 'WARN' }
    $script:SoftwareNotOffered = @($notOffered.ToArray())
    $script:SoftwareDetected = @($detected.ToArray())
    # newest first within each package: the first usable file of a package is the one offered by default
    $list = @($found.ToArray())
    if ($list.Count -gt 1) { $list = @($list | Sort-Object @{ Expression = { $_.Id } }, @{ Expression = { ConvertTo-VersionObject $_.Version }; Descending = $true }) }
    $script:SoftwareFiles = $list
    # the cache keeps the files still there; it is rewritten only when something was vetted or has gone
    $stale = @($script:SoftwareFileCache.Keys | Where-Object { -not $seenKeys.Contains($_) })
    foreach ($k in $stale) { $script:SoftwareFileCache.Remove($k) }
    if ($vetted -gt 0 -or $stale.Count -gt 0) { Save-SoftwareVettingCache }
    $packages = @($list | ForEach-Object { $_.Id } | Select-Object -Unique).Count
    Write-PatchLog ("Software library: {0} installer(s) of {1} package(s){2}{3}{4}" -f $list.Count, $packages, $(if ($vetted -gt 0) { ", $vetted vetted now (SHA256, signature)" } else { '' }), $(if (@($list | Where-Object { $_.Blocked }).Count -gt 0) { ', ' + @($list | Where-Object { $_.Blocked }).Count + ' blocked' } else { '' }), $(if ($detected.Count -gt 0) { ', ' + $detected.Count + ' NEW to register' } else { '' })) 'INFO'
    return $list
}

function Get-SoftwareVettingCachePath {
    return (Join-Path (Join-Path $script:Config.SoftwareFolder '_info') 'vetting-cache.json')
}

function Read-SoftwareVettingCache {
    # The vetting of earlier sessions - SHA256, signature, signer and version per file (path, size, time): a big
    # software\ folder is read in full once, not at every start.  Only a speed-up: before anything runs, the copy is
    # checked against the SHA256 and the server checks the SHA256 and the signature of the staged file itself.
    $map = @{}
    $p = Get-SoftwareVettingCachePath
    if (-not (Test-Path -LiteralPath $p)) { return $map }
    try {
        foreach ($e in @(([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).Files)) {
            if ($e -and $e.Key -and $e.Hash) { $map[[string]$e.Key] = @{ Hash = [string]$e.Hash; Signature = [string]$e.Signature; Signer = [string]$e.Signer; Version = [string]$e.Version; Spec = [string]$e.Spec } }
        }
    } catch { Write-PatchLog "Software vetting cache unreadable ($(Get-ShortError $_)) - every installer is vetted again" 'WARN' }
    return $map
}

function Save-SoftwareVettingCache {
    $p = Get-SoftwareVettingCachePath
    $files = @(foreach ($k in @($script:SoftwareFileCache.Keys | Sort-Object)) {
        $e = $script:SoftwareFileCache[$k]
        [pscustomobject]@{ Key = $k; Hash = $e.Hash; Signature = $e.Signature; Signer = $e.Signer; Version = $e.Version; Spec = $e.Spec }
    })
    try {
        $dir = Split-Path -Path $p -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $doc = [ordered]@{ Note = 'Written by the Software console: the vetting of every installer, so it is not read again at every start. Safe to delete.'; Files = $files }
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject $doc -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    } catch { Write-PatchLog "Software vetting cache not written ($(Get-ShortError $_)) - the next start vets every installer again" 'WARN' }
}

# ---------------------------------------------------------------------
#  REGISTERING A NEW PACKAGE.  An installer dropped into any folder under
#  software\ shows as NEW in the installer list.  "Register selected
#  installer" reads the file, fills a form with what it found (name,
#  version source, file pattern, signer, the fleet's names for Match),
#  checks every field with the same rules the scan applies, and writes one
#  entry at the end of the Packages list in data\software-packages.psd1 -
#  the rest of that file, comments included, stays as it was.
#  Not automatic on purpose: registering decides which signer is trusted and
#  which command line runs as SYSTEM on the servers; a person confirms that
#  once per product.
# ---------------------------------------------------------------------
function ConvertTo-AsciiText {
    # Catalogue text stays printable ASCII (PowerShell 5.1 reads a file without a BOM as ANSI): anything else becomes $Replacement.
    param([string]$Text, [string]$Replacement = '')
    return [regex]::Replace([string]$Text, '[^\x20-\x7E]', $Replacement)
}

function Get-SoftwareFileFacts {
    # What an installer says about itself: the signature and its signer, and the product name, version and maker
    # (from inside an .msi, or the version resource of an .exe).
    param([string]$Path)
    $facts = [ordered]@{ Path = $Path; Kind = ([System.IO.Path]::GetExtension($Path)).TrimStart('.').ToLower(); Signature = 'Unknown'; Signer = ''; Org = ''; ProductName = ''; ProductVersion = ''; Manufacturer = '' }
    try { $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop; $facts.Signature = [string]$sig.Status; if ($sig.SignerCertificate) { $facts.Signer = $sig.SignerCertificate.Subject; $facts.Org = Get-SignerOrg $facts.Signer } } catch { }
    if ($facts.Kind -eq 'msi') {
        $facts.ProductName = Get-MsiProperty -Path $Path -Property 'ProductName'
        $facts.ProductVersion = Get-MsiProperty -Path $Path -Property 'ProductVersion'
        $facts.Manufacturer = Get-MsiProperty -Path $Path -Property 'Manufacturer'
    } elseif ($facts.Kind -eq 'exe') {
        try { $vi = (Get-Item -LiteralPath $Path).VersionInfo; $facts.ProductName = [string]$vi.ProductName; $facts.ProductVersion = [string]$vi.ProductVersion; $facts.Manufacturer = [string]$vi.CompanyName } catch { }
    }
    foreach ($k in 'ProductName', 'ProductVersion', 'Manufacturer') { $facts[$k] = ([string]$facts[$k]).Trim() }
    return [pscustomobject]$facts
}

function Get-SoftwareNamePattern {
    # From an installer's file name: FilePattern (the version-like parts as *) and VersionRegex (the same parts captured).
    #   VMware-tools-12.5.4-24964629-x64.exe   -> 'VMware-tools-*-*-x64.exe', 12.5.4 + 24964629
    #   googlechromestandaloneenterprise64.msi -> 'googlechromestandaloneenterprise64*.msi', no version in the name
    # Version-like = digits with dots, or a run of four or more digits (a build); "x64" stays as it is.
    param([string]$FileName)
    $tokens = [regex]::Matches($FileName, '\d+(?:\.\d+)+|\d{4,}')
    if ($tokens.Count -eq 0) {
        $ext = [System.IO.Path]::GetExtension($FileName)
        return [pscustomobject]@{ FilePattern = ([System.Management.Automation.WildcardPattern]::Escape([System.IO.Path]::GetFileNameWithoutExtension($FileName)) + '*' + $ext); VersionRegex = '' }
    }
    $pattern = New-Object System.Text.StringBuilder
    $regex = New-Object System.Text.StringBuilder
    [void]$regex.Append('^')
    $pos = 0
    foreach ($t in $tokens) {
        $lit = $FileName.Substring($pos, $t.Index - $pos)
        [void]$pattern.Append([System.Management.Automation.WildcardPattern]::Escape($lit)).Append('*')
        [void]$regex.Append([regex]::Escape($lit))
        if ($t.Value.Contains('.')) { [void]$regex.Append('(\d+(?:\.\d+)*)') } else { [void]$regex.Append('(\d+)') }
        $pos = $t.Index + $t.Length
    }
    $tail = $FileName.Substring($pos)
    [void]$pattern.Append([System.Management.Automation.WildcardPattern]::Escape($tail))
    [void]$regex.Append([regex]::Escape($tail)).Append('$')
    return [pscustomobject]@{ FilePattern = $pattern.ToString(); VersionRegex = $regex.ToString() }
}

function Get-FleetProductNames {
    # Product names from the collected inventories that share a word with $Hint.  The Register form offers them for Match,
    # because Match must be the name Programs and Features shows - not always the name inside the installer.
    param([string]$Hint)
    if (-not $script:Results.ContainsKey('Inventory')) { return @() }
    $word = @(([string]$Hint -split '[^A-Za-z0-9]+') | Where-Object { $_.Length -ge 3 })[0]
    if (-not $word) { return @() }
    $names = @{}
    foreach ($srv in @($script:Results['Inventory'].Keys)) {
        $inv = $script:Results['Inventory'][$srv]
        if (-not $inv -or -not $inv.Reachable) { continue }
        foreach ($line in @($inv.Products)) { $n = ([string]$line -split '\|')[0]; if ($n -like "*$word*") { $names[$n] = $true } }
    }
    return @($names.Keys | Sort-Object | Select-Object -First 20)
}

function New-SoftwarePackageDraft {
    # The Register form's starting point for one NEW installer: every field filled from the file, nothing written yet.
    param($Detected, $Facts)
    $cat = Get-SoftwareCatalogue
    $taken = @{}
    foreach ($p in @($cat.Packages)) { if ($p) { $taken[([string]$p.Id).Trim().ToLower()] = $true } }
    $name = ((ConvertTo-AsciiText $Facts.ProductName ' ') -replace '\s+', ' ').Trim()
    if (-not $name -and $Detected.Folder) { $name = (([string]$Detected.Folder) -split '\\')[-1] }
    if (-not $name) { $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$Detected.File) }
    $id = ($name -replace "'", '').Trim()
    $stem = $id; $n = 2
    while ($taken.ContainsKey($id.ToLower())) { $id = '{0} {1}' -f $stem, $n; $n++ }
    $np = Get-SoftwareNamePattern -FileName $Detected.File
    $kind = ([string]$Detected.Extension).TrimStart('.').ToLower()
    # the version: an .msi carries it; an .exe named with a dotted version (12.5.4) gives it in its name; a bare run of
    # digits in the name (7z2409, Agent-20261001) is a build or a date, not the version the server will show, so the
    # file's own ProductVersion is preferred whenever it is readable
    $versionFrom = 'name'
    $dottedInName = [regex]::IsMatch([string]$Detected.File, '\d+(?:\.\d+)+')
    if ($kind -eq 'msi') { $versionFrom = 'msi' } elseif ($Facts.ProductVersion -and (-not $np.VersionRegex -or -not $dottedInName)) { $versionFrom = 'file' }
    $match = ((ConvertTo-AsciiText $Facts.ProductName '*') -replace '\*+', '*').Trim()   # a (R) or (TM) sign becomes a wildcard
    if (-not $match) { $match = $name + '*' }
    $signers = @(); if ($Facts.Signature -eq 'Valid' -and $Facts.Org) { $signers = @(ConvertTo-AsciiText $Facts.Org '*') }
    return [ordered]@{ Id = $id; Name = $name; Folder = [string]$Detected.Folder; Match = $match; FilePattern = $np.FilePattern; VersionFrom = $versionFrom; VersionRegex = $np.VersionRegex
        Installer = $kind; Arguments = ''; InstallArguments = ''; UpdateArguments = ''; Modes = @('Install', 'Update', 'Uninstall'); Requires = ''; Signers = $signers; AllowUnsigned = $false; Note = '' }
}

function Test-SoftwarePackageDraft {
    # Everything that must hold before a draft becomes a package: the catalogue rules (a free Id, a usable folder, plain
    # ASCII) and the scan's own vetting (Get-SoftwarePackageBlock) of this very file.  Returns Problems and the Version the
    # file would be offered as.
    # -OriginalId: the package being edited - its own Id does not count as taken
    param($Draft, $Detected, $Facts, [string]$OriginalId = '')
    $problems = New-Object System.Collections.Generic.List[string]
    $cat = Get-SoftwareCatalogue
    $id = ([string]$Draft.Id).Trim()
    if (-not $id) { $problems.Add('Package Id is empty') }
    elseif (@(@($cat.Packages) | Where-Object { $_ -and ([string]$_.Id).Trim() -ieq $id -and ([string]$_.Id).Trim() -ine $OriginalId.Trim() }).Count -gt 0) { $problems.Add("a package with the Id '$id' already exists - choose another Id") }
    if ($id -and $id -in $script:SoftwareFixedColumns) { $problems.Add("the Id '$id' is a column name of the server grid - choose another") }
    if (-not ([string]$Draft.Name).Trim()) { $problems.Add('Name is empty') }
    if (-not ([string]$Draft.Match).Trim()) { $problems.Add('Match is empty: give the product name as Programs and Features shows it (* = any text)') }
    $why = Test-SoftwareFolderName ([string]$Draft.Folder)
    if ($why) { $problems.Add("folder: $why") }
    if (-not ([string]$Draft.FilePattern).Trim()) { $problems.Add('FilePattern is empty') }
    elseif ($Detected.File -and [string]$Detected.File -notlike [string]$Draft.FilePattern) { $problems.Add(("FilePattern '{0}' does not match the file {1}" -f $Draft.FilePattern, $Detected.File)) }
    foreach ($k in 'Id', 'Name', 'Match', 'FilePattern', 'VersionRegex', 'Arguments', 'InstallArguments', 'UpdateArguments', 'Requires', 'Note') { if ([string]$Draft[$k] -match '[^\x20-\x7E]') { $problems.Add("$k holds characters outside plain ASCII (curly quotes, symbols) - type them plainly") } }
    foreach ($s in @($Draft.Signers)) { if ([string]$s -match '[^\x20-\x7E]') { $problems.Add('a signer holds characters outside plain ASCII') } }
    $version = ''
    $regexOk = $true
    if ($Draft.VersionFrom -eq 'name') { try { $null = [regex]::new([string]$Draft.VersionRegex) } catch { $regexOk = $false; $problems.Add('VersionRegex is not a valid regular expression') } }
    if ($Detected.FullName) {   # no file (a package edited from the library window): the fields are checked, the file is vetted when one turns up
        if ($regexOk) { try { $version = [string](Get-SoftwareFileVersion -Package $Draft -File (Get-Item -LiteralPath $Detected.FullName)) } catch { $version = '' } }
        $block = Get-SoftwarePackageBlock -Package $Draft -Info @{ Version = $version; Signature = $Facts.Signature; Signer = $Facts.Signer }
        if ($block) { $problems.Add($block) }
    }
    return [pscustomobject]@{ Problems = @($problems.ToArray()); Version = $version }
}

# the server grid's own columns: a package Id with one of these names would overwrite that cell (Server is the row's key)
$script:SoftwareFixedColumns = @('Server', 'Group', 'WinRM', 'All packages', 'Hardware', 'Pending reboot', 'Trellix Agent', 'Staged', 'Toolkit task', 'Products', 'Checked at', 'Colour', 'Tip', 'Cells')

# the package fields the Register / Edit form shows; any other field in an entry is carried along unchanged
$script:SoftwarePackageFields = @('Id', 'Name', 'Folder', 'Match', 'FilePattern', 'VersionFrom', 'VersionRegex', 'Installer', 'Arguments', 'InstallArguments', 'UpdateArguments', 'Modes', 'Requires', 'Signers', 'AllowUnsigned', 'Note')

function ConvertTo-SoftwarePackageText {
    # One package as data-file text, the way a person would write it: one field per line, single-quoted, ASCII.  Fields the
    # form does not know (added by hand) are carried along as they were.  For an edit, Get-SoftwarePackageEntry gives
    # -Order (the entry's own field order, kept) and -Notes (hand-written comments, put back next to their fields).
    param($Draft, [string[]]$Comment = @(), [object[]]$Notes = @(), [string[]]$Order = @(), [hashtable]$Raw = @{})
    $q = { param($s) "'" + ((ConvertTo-AsciiText ([string]$s) '?') -replace "'", "''") + "'" }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('        @{')
    foreach ($c in @($Comment)) { if ($c) { $lines.Add('            # ' + (ConvertTo-AsciiText $c '?')) } }
    $fields = New-Object System.Collections.Generic.List[object]
    foreach ($k in 'Id', 'Name', 'Folder', 'Match', 'FilePattern', 'VersionFrom') { $fields.Add(@($k, (& $q $Draft[$k]))) }
    if ($Draft.VersionFrom -eq 'name') { $fields.Add(@('VersionRegex', (& $q $Draft.VersionRegex))) }
    $fields.Add(@('Installer', (& $q $Draft.Installer)))
    if ($Draft.Installer -eq 'msi') { $fields.Add(@('Arguments', (& $q $Draft.Arguments))) }
    else {
        if ($Draft.InstallArguments) { $fields.Add(@('InstallArguments', (& $q $Draft.InstallArguments))) }
        if ($Draft.UpdateArguments) { $fields.Add(@('UpdateArguments', (& $q $Draft.UpdateArguments))) }
    }
    $fields.Add(@('Modes', ('@(' + ((@($Draft.Modes) | Where-Object { $_ } | ForEach-Object { & $q $_ }) -join ', ') + ')')))
    if ($Draft.Requires) { $fields.Add(@('Requires', (& $q $Draft.Requires))) }
    $fields.Add(@('Signers', ('@(' + ((@($Draft.Signers) | Where-Object { $_ } | ForEach-Object { & $q $_ }) -join ', ') + ')')))
    if ($Draft.AllowUnsigned) { $fields.Add(@('AllowUnsigned', '$true')) }
    if ($Draft.Note) { $fields.Add(@('Note', (& $q $Draft.Note))) }
    foreach ($k in @($Draft.Keys)) {
        if ($script:SoftwarePackageFields -contains $k) { continue }
        $v = $Draft[$k]
        # a hand-written field: its own text when the entry was read (an edit), else written from the value - and only a
        # value this writer can put back faithfully (a nested table or a list of tables would come out as its type name)
        if ($Raw -and $Raw.ContainsKey($k)) { $text = [string]$Raw[$k] }
        elseif ($v -is [bool]) { $text = '$' + ([string]$v).ToLower() }
        elseif ($v -is [array]) { foreach ($el in $v) { if ($el -isnot [string] -and $el -isnot [ValueType]) { throw "field '$k' holds a list of tables - the Software tab cannot rewrite it; edit data\software-packages.psd1 by hand" } }; $text = '@(' + ((@($v) | ForEach-Object { & $q $_ }) -join ', ') + ')' }
        elseif ($v -is [int] -or $v -is [long] -or $v -is [double]) { $text = [string]$v }
        elseif ($null -eq $v -or $v -is [string]) { $text = & $q $v }
        else { throw "field '$k' is not a text, number, yes/no or list of texts - the Software tab cannot rewrite it; edit data\software-packages.psd1 by hand" }
        $fields.Add(@($k, $text))
    }
    if (@($Order).Count -gt 0) {
        # the entry's own order; a field it did not have goes after the field before it in the standard order
        $rank = @{}; for ($i = 0; $i -lt $Order.Count; $i++) { if (-not $rank.ContainsKey($Order[$i])) { $rank[$Order[$i]] = [double]$i } }
        $last = -1.0; $pos = 0
        $keyed = foreach ($pair in $fields) {
            $r = $last + 0.5
            if ($rank.ContainsKey($pair[0])) { $r = $rank[$pair[0]]; $last = $r }
            [pscustomobject]@{ Rank = $r; Pos = $pos; Pair = $pair }
            $pos++
        }
        $fields = @($keyed | Sort-Object Rank, Pos | ForEach-Object { , $_.Pair })
    }
    $noteLines ={ param($nt) @(([string]$nt.Text -split "\r?\n") | ForEach-Object { ConvertTo-AsciiText ($_ -replace "`t", '    ') '?' }) }
    $placed = @{}
    foreach ($pair in $fields) {
        foreach ($nt in @(@($Notes) | Where-Object { $_ -and -not $_.Trailing -and [string]$_.Key -ieq $pair[0] })) { foreach ($l in (& $noteLines $nt)) { $lines.Add('            ' + $l.TrimStart()) } }
        $line = ('            {0,-16} = {1}' -f $pair[0], $pair[1])
        $tail = @(@($Notes) | Where-Object { $_ -and $_.Trailing -and [string]$_.Key -ieq $pair[0] } | ForEach-Object { (& $noteLines $_) -join ' ' })
        if ($tail.Count -gt 0) { $line += '   ' + ($tail -join ' ') }
        $lines.Add($line)
        $placed[[string]$pair[0]] = $true
    }
    # comments after the last field, or on a field the edit dropped (VersionRegex once the version comes from the msi)
    foreach ($nt in @($Notes)) { if ($nt -and -not $placed.ContainsKey([string]$nt.Key)) { foreach ($l in (& $noteLines $nt)) { $lines.Add('            ' + $l.TrimStart()) } } }
    $lines.Add('        }')
    return ($lines.ToArray() -join "`r`n")
}

function Get-SoftwareCatalogueParts {
    # The catalogue's text parsed: its tokens (comments included) and the Packages = @( ... ) list.
    param([string]$Text)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw ("data\software-packages.psd1 does not parse (line {0}: {1}) - fix that first" -f $errors[0].Extent.StartLineNumber, $errors[0].Message) }
    $top = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.HashtableAst] }, $false)
    $pair = @($top.KeyValuePairs | Where-Object { $_.Item1 -is [System.Management.Automation.Language.ConstantExpressionAst] -and [string]$_.Item1.Value -ieq 'Packages' })[0]
    if (-not $pair) { throw 'data\software-packages.psd1 has no "Packages = @( ... )" list' }
    $arr = $pair.Item2.Find({ param($n) $n -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true)
    if (-not $arr) { throw 'Packages in data\software-packages.psd1 is not an @( ... ) list' }
    return [pscustomobject]@{ Tokens = @($tokens); Packages = $arr }
}

function Get-SoftwarePackageEntry {
    # Where one package's @{ ... } sits in the catalogue's text, and its comments: the ones the Software tab wrote
    # ("registered ..." / "edited ...") and the ones written by hand, each with the field it belongs to - an edit
    # rewrites the entry and puts both back.
    param([string]$Text, [string]$Id)
    $parts = Get-SoftwareCatalogueParts -Text $Text
    foreach ($st in @($parts.Packages.SubExpression.Statements)) {
        $expr = $null
        if ($st -is [System.Management.Automation.Language.PipelineAst]) { $expr = $st.GetPureExpression() }
        if ($expr -isnot [System.Management.Automation.Language.HashtableAst]) { continue }
        $idPair = @($expr.KeyValuePairs | Where-Object { $_.Item1 -is [System.Management.Automation.Language.ConstantExpressionAst] -and [string]$_.Item1.Value -ieq 'Id' })[0]
        if (-not $idPair) { continue }
        $value = $idPair.Item2
        if ($value -is [System.Management.Automation.Language.PipelineAst]) { $value = $value.GetPureExpression() }
        if (-not ($value -is [System.Management.Automation.Language.ConstantExpressionAst]) -or ([string]$value.Value).Trim() -ine $Id.Trim()) { continue }
        $pairs = @($expr.KeyValuePairs)
        $ours = New-Object System.Collections.Generic.List[string]
        $notes = New-Object System.Collections.Generic.List[object]
        # a hand-written field is kept as its own text, comments inside it included: those must not be added again as notes,
        # or every edit doubles them (R6-C12)
        $rawSpans = @($pairs | Where-Object { $script:SoftwarePackageFields -notcontains [string]$_.Item1.Value } | ForEach-Object { , @($_.Item2.Extent.StartOffset, $_.Item2.Extent.EndOffset) })
        foreach ($tok in @($parts.Tokens | Where-Object { [string]$_.Kind -eq 'Comment' -and $_.Extent.StartOffset -gt $expr.Extent.StartOffset -and $_.Extent.EndOffset -lt $expr.Extent.EndOffset })) {
            $inside = $false; foreach ($span in $rawSpans) { if ($tok.Extent.StartOffset -ge $span[0] -and $tok.Extent.EndOffset -le $span[1]) { $inside = $true } }
            if ($inside) { continue }
            $plain = $tok.Text.TrimStart('#').Trim()
            if ($plain -match '^(registered|edited) in the Software tab') { $ours.Add($plain); continue }
            # a hand-written comment stays with its field: on the field's own line(s) it trails the field, on a line of its
            # own it leads the next field; after the last field it stays at the end
            $line = $tok.Extent.StartLineNumber
            $at = @($pairs | Where-Object { $_.Item1.Extent.StartLineNumber -le $line -and $_.Item2.Extent.EndLineNumber -ge $line })[0]
            $trailing = ($null -ne $at) -and $tok.Text -notmatch "`n"
            if (-not $at) { $at = @($pairs | Where-Object { $_.Item1.Extent.StartOffset -gt $tok.Extent.StartOffset })[0] }
            $notes.Add([pscustomobject]@{ Key = $(if ($at) { [string]$at.Item1.Value } else { '' }); Text = $tok.Text; Trailing = $trailing })
        }
        $raw = @{}; foreach ($pr in $pairs) { $k = [string]$pr.Item1.Value; if ($script:SoftwarePackageFields -notcontains $k) { $raw[$k] = $pr.Item2.Extent.Text } }   # hand-written fields: their text, kept as it is
        return [pscustomobject]@{ Raw = $raw; Start = $expr.Extent.StartOffset; End = $expr.Extent.EndOffset; Keys = @($pairs | ForEach-Object { [string]$_.Item1.Value }); OwnComments = @($ours.ToArray()); HandNotes = @($notes.ToArray()); HandComments = $notes.Count }
    }
    return $null
}

function Save-SoftwareCatalogueText {
    # Writes the catalogue's new text, reads it back with PowerShell's own data-file reader and runs $Check on the result;
    # on any doubt the original text goes back and the error is thrown.  Then the caches that would hide the change go.
    param([string]$Path, [string]$Before, [string]$After, [scriptblock]$Check, [string]$What)
    [System.IO.File]::WriteAllText($Path, ($After -replace "`r?`n", "`r`n"), (New-Object System.Text.UTF8Encoding $false))
    try {
        # read back the way Import-ToolData reads it: PowerShell's own loader gives up near 200 packages ("Cannot generate a
        # Windows PowerShell object"), so every Register / Edit was refused past that size (R6-C11)
        $back = $null
        try { $back = Import-PowerShellDataFile -LiteralPath $Path } catch { $back = $null }
        if ($null -eq $back) { $back = Import-DataFileSafely -Path $Path }
        $problem = & $Check $back
        if ($problem) { throw $problem }
    } catch {
        [System.IO.File]::WriteAllText($Path, $Before, (New-Object System.Text.UTF8Encoding $false))
        throw ("{0} not written, data\software-packages.psd1 left as it was: {1}" -f $What, (Get-ShortError $_))
    }
    if ($script:DataCache) { $script:DataCache.Remove($Path) }   # Import-ToolData's 2-second memo must not hide the change
    $script:ProtectionMemo = $null
}

function Add-SoftwarePackage {
    # Writes a checked draft into the catalogue: the new entry goes at the end of the Packages list, the rest of the file
    # (comments, hand-written entries) stays exactly as it was.
    param($Draft, [string]$From = '', [string]$Path = '')
    if (-not $Path) { $Path = Join-Path $script:Config.DataFolder 'software-packages.psd1' }
    $before = [System.IO.File]::ReadAllText($Path)
    $arr = (Get-SoftwareCatalogueParts -Text $before).Packages
    $close = $arr.Extent.EndOffset - 1
    $lineStart = $before.LastIndexOf("`n", $close) + 1
    $comment = 'registered in the Software tab on ' + (Get-Date -Format 'yyyy-MM-dd')
    if ($From) { $comment += ' from ' + $From }
    $block = ConvertTo-SoftwarePackageText -Draft $Draft -Comment @($comment)
    if ($before.Substring($lineStart, $close - $lineStart).Trim() -eq '') { $after = $before.Substring(0, $lineStart) + "`r`n" + $block + "`r`n" + $before.Substring($lineStart) }
    else { $after = $before.Substring(0, $close) + "`r`n" + $block + "`r`n    " + $before.Substring($close) }   # "Packages = @()" on one line
    $newId = ([string]$Draft.Id).Trim()
    Save-SoftwareCatalogueText -Path $Path -Before $before -After $after -What 'registration' -Check {
        param($back)
        if (@(@($back.Packages) | Where-Object { $_ -and ([string]$_.Id).Trim() -ieq $newId }).Count -ne 1) { 'the new entry is not in the file after writing' }
    }
    Write-PatchLog ("REGISTERED software package '{0}' by {1}: folder software\{2}, pattern {3}, version from {4}, signer {5}, modes {6}" -f $Draft.Id, (Get-OperatorIdentity), $Draft.Folder, $Draft.FilePattern, $Draft.VersionFrom, $(if ($Draft.AllowUnsigned) { 'unsigned allowed' } else { @($Draft.Signers) -join ' / ' }), (@($Draft.Modes) -join ', ')) 'OK'
}

function Update-SoftwarePackage {
    # Rewrites one registered package (the Edit... button): its @{ ... } is replaced in place, everything else in the file
    # stays as it was.  Its field order and comments are kept - hand-written ones next to their fields - and an "edited"
    # line is added.
    param($Draft, [string]$OriginalId, [string]$Path = '')
    if (-not $Path) { $Path = Join-Path $script:Config.DataFolder 'software-packages.psd1' }
    $before = [System.IO.File]::ReadAllText($Path)
    $entry = Get-SoftwarePackageEntry -Text $before -Id $OriginalId
    if (-not $entry) { throw "package '$OriginalId' is not in data\software-packages.psd1 any more - press Reload lists + packages" }
    # "registered ..." stays; the latest "edited ..." replaces the one before (every edit is in the log)
    $comments = @($entry.OwnComments | Where-Object { $_ -notlike 'edited in the Software tab*' }) + @('edited in the Software tab on ' + (Get-Date -Format 'yyyy-MM-dd'))
    $block = (ConvertTo-SoftwarePackageText -Draft $Draft -Comment $comments -Notes $entry.HandNotes -Order $entry.Keys -Raw $entry.Raw).TrimStart()   # the entry's own indentation stays in front of it
    $after = $before.Substring(0, $entry.Start) + $block + $before.Substring($entry.End)
    $newId = ([string]$Draft.Id).Trim(); $oldId = $OriginalId.Trim()
    Save-SoftwareCatalogueText -Path $Path -Before $before -After $after -What 'change' -Check {
        param($back)
        if (@(@($back.Packages) | Where-Object { $_ -and ([string]$_.Id).Trim() -ieq $newId }).Count -ne 1) { 'the edited entry is not in the file after writing' }
        elseif ($newId -ine $oldId -and @(@($back.Packages) | Where-Object { $_ -and ([string]$_.Id).Trim() -ieq $oldId }).Count -gt 0) { 'the old entry is still in the file' }
    }
    $renamed = ''; if ($newId -ine $oldId) { $renamed = " (was '$oldId')" }
    Write-PatchLog ("EDITED software package '{0}'{1} by {2}: pattern {3}, version from {4}, signer {5}, modes {6}" -f $newId, $renamed, (Get-OperatorIdentity), $Draft.FilePattern, $Draft.VersionFrom, $(if ($Draft.AllowUnsigned) { 'unsigned allowed' } else { @($Draft.Signers) -join ' / ' }), (@($Draft.Modes) -join ', ')) 'OK'
}

function ConvertTo-SoftwarePackageDraft {
    # A registered package as a form draft: every field the form edits (defaults where the entry leaves one out), and any
    # other field carried along unchanged.
    param($Package)
    $modes = @(); if ($Package.Modes) { $modes = @($Package.Modes) }
    $signers = @(); if ($Package.Signers) { $signers = @($Package.Signers) }
    $d = [ordered]@{ Id = ([string]$Package.Id).Trim(); Name = [string]$Package.Name; Folder = (Get-SoftwarePackageFolder -Package $Package); Match = [string]$Package.Match
        FilePattern = [string]$Package.FilePattern; VersionFrom = [string]$Package.VersionFrom; VersionRegex = [string]$Package.VersionRegex; Installer = [string]$Package.Installer
        Arguments = [string]$Package.Arguments; InstallArguments = [string]$Package.InstallArguments; UpdateArguments = [string]$Package.UpdateArguments
        Modes = $modes; Requires = [string]$Package.Requires; Signers = $signers; AllowUnsigned = [bool]$Package.AllowUnsigned; Note = [string]$Package.Note }
    if (-not $d.VersionFrom) { $d.VersionFrom = 'name' }
    if ($d.Installer -eq 'exe' -and $d.Arguments) {
        # an .exe entry with one Arguments for both modes: the form shows it in both boxes
        if (-not $d.InstallArguments) { $d.InstallArguments = $d.Arguments }
        if (-not $d.UpdateArguments) { $d.UpdateArguments = $d.Arguments }
        $d.Arguments = ''
    }
    foreach ($k in @($Package.Keys)) { if (-not $d.Contains($k)) { $d[$k] = $Package[$k] } }
    return $d
}

function Edit-SoftwarePackage {
    # An installer's own Edit... button (-FullName), or the library window's Edit package... (-Id - also for a package
    # whose folder holds no matching installer any more): the registration in the same form as Register, filled from
    # the entry; Save changes rewrites that entry (Update-SoftwarePackage), then the scan runs again.
    param([string]$FullName = '', [string]$Id = '')
    $file = $null
    if ($FullName) {
        $file = @(@($script:SoftwareFiles) | Where-Object { $_.FullName -eq $FullName })[0]
        if (-not $file) { $null = Show-PatcherMessage -Text ("This installer is no longer in the list:`n`n{0}`n`nPress Reload lists + packages." -f $FullName) -Title 'Edit software package' -Icon 'Information'; return }
    } elseif ($Id) { $file = @(@($script:SoftwareFiles) | Where-Object { [string]$_.Id -eq $Id.Trim() })[0] }
    $pkg = $null
    if ($file) { $pkg = $file.Package } elseif ($Id) { $pkg = @(@((Get-SoftwareCatalogue).Packages) | Where-Object { $_ -and ([string]$_.Id).Trim() -ieq $Id.Trim() })[0] }
    if (-not $pkg) { $null = Show-PatcherMessage -Text ("Package '{0}' was not found in data\software-packages.psd1 - press Reload lists + packages." -f $Id) -Title 'Edit software package' -Icon 'Warning'; return }
    $entry = Get-SoftwarePackageEntry -Text ([System.IO.File]::ReadAllText((Join-Path $script:Config.DataFolder 'software-packages.psd1'))) -Id ([string]$pkg.Id)
    if (-not $entry) { $null = Show-PatcherMessage -Text ("Package '{0}' was not found in data\software-packages.psd1 - press Reload lists + packages." -f $pkg.Id) -Title 'Edit software package' -Icon 'Warning'; return }
    $extra = @(@($pkg.Keys) | Where-Object { $script:SoftwarePackageFields -notcontains $_ })
    $notice = ''
    if ($extra.Count -gt 0) { $notice = ('this entry has field(s) the form does not show ({0}): Save changes keeps them as they are' -f ($extra -join ', ')) }
    if ($file) {
        Set-GuiStatus "Reading $($file.File) (signature, product name, version) ..."
        $facts = Get-SoftwareFileFacts -Path $file.FullName
        $det = [pscustomobject]@{ Folder = $file.Folder; File = $file.File; FullName = $file.FullName; Length = $file.Length; SizeMB = $file.SizeMB; Extension = ([System.IO.Path]::GetExtension($file.File)).ToLower(); Reason = 'registered' }
    } else {
        # no file to read: the form checks the fields; the file is vetted when one turns up
        $facts = [pscustomobject]@{ ProductName = ''; ProductVersion = ''; Signature = ''; Signer = ''; Org = '' }
        $det = [pscustomobject]@{ Folder = (Get-SoftwarePackageFolder -Package $pkg); File = ''; FullName = ''; Length = 0; SizeMB = 0; Extension = ('.' + [string]$pkg.Installer); Reason = 'registered' }
        $notice = ('no installer in software\{0} matches this package''s FilePattern - the form checks the fields only{1}' -f $det.Folder, $(if ($notice) { '; ' + $notice } else { '' }))
    }
    $draft = ConvertTo-SoftwarePackageDraft -Package $pkg
    $result = Show-SoftwareRegisterDialog -Detected $det -Facts $facts -Draft $draft -OriginalId ([string]$pkg.Id) -Notice $notice
    if (-not $result) { Write-PatchLog "Edit of package '$($pkg.Id)' cancelled - nothing written" 'INFO'; return }
    Update-SoftwarePackage -Draft $result -OriginalId ([string]$pkg.Id)
    Get-SoftwarePackageFiles | Out-Null
}

function Get-SoftwareCommandPreview {
    # The command lines a draft would run on a server, for the Register form (built like RemoteSoftwareRunScript builds them).
    param($Draft, $Detected)
    $file = $script:Config.RemoteStaging.TrimEnd('\') + '\software\' + (Get-SoftwareStageName $Draft.Id) + '\' + $(if ($Detected.File) { $Detected.File } else { '<installer>' })
    $log = $script:Config.RemoteStaging.TrimEnd('\') + '\software\sw-<run>-<n>.log'
    $out = @()
    foreach ($mode in @('Install', 'Update')) {
        if (@($Draft.Modes) -notcontains $mode) { continue }
        if ($Draft.Installer -eq 'msi') { $out += ('{0,-10} msiexec.exe /i "{1}" /qn /norestart REBOOT=ReallySuppress /l*v "{2}" {3}' -f ($mode + ':'), $file, $log, $Draft.Arguments).TrimEnd() }
        else { $out += ('{0,-10} "{1}" {2}' -f ($mode + ':'), $file, ((Get-SoftwareArguments -Package $Draft -Mode $mode).Replace('{log}', $log).Replace('{file}', $file))) }
    }
    if (@($Draft.Modes) -contains 'Uninstall') { $out += ('{0,-10} msiexec.exe /x <product code from the server> /qn /norestart REBOOT=ReallySuppress, or the product''s own QuietUninstallString' -f 'Uninstall:') }
    return $out
}

function Show-SoftwareRegisterDialog {
    # The Register form, and the Edit form (-OriginalId: the package being edited).  Every field is filled from the
    # installer or the entry; the preview underneath shows the command lines that would run, whether the product may be
    # removed, and anything that stops the save - updated as you type.  Returns the checked draft, or $null.
    param($Detected, $Facts, $Draft, [string]$OriginalId = '', [string]$Notice = '')
    $kind = [string]$Draft.Installer
    $editing = [bool]$OriginalId
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $(if ($editing) { 'Edit software package - ' + $OriginalId } else { 'Register software - ' + $Detected.File })
    $dlg.Size = New-Object System.Drawing.Size(780, 820); $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $c = @{}
    $where = [string]$Detected.File; if ($Detected.Folder) { $where = $Detected.Folder + '\' + $Detected.File }
    $signText = [string]$Facts.Signature; if ($Facts.Org) { $signText += ', signed by ' + $Facts.Org }
    $inside = (@($Facts.ProductName, $Facts.ProductVersion) | Where-Object { $_ }) -join ' '
    if ($Facts.Manufacturer) { $inside += ' (' + $Facts.Manufacturer + ')' }
    if (-not $inside) { $inside = 'nothing - fill the fields in by hand' }
    $info = New-Object System.Windows.Forms.Label
    $info.Location = New-Object System.Drawing.Point(12, 10); $info.Size = New-Object System.Drawing.Size(740, 54)
    $info.Text = ("software\{0}  ({1} MB)`r`nSignature: {2}`r`nThe file says: {3}" -f $where, $Detected.SizeMB, $signText, $inside)
    $dlg.Controls.Add($info)
    $lay = @{ Y = 72 }
    $add = {
        param([string]$Key, [string]$Caption, $Control, [int]$Width = 520, [string]$Tip = '')
        $l = New-Object System.Windows.Forms.Label; $l.Text = $Caption; $l.Location = New-Object System.Drawing.Point(12, ($lay.Y + 4)); $l.Size = New-Object System.Drawing.Size(215, 20)
        $Control.Location = New-Object System.Drawing.Point(232, $lay.Y); $Control.Width = $Width
        if ($Tip) { $script:Gui['Tips'].SetToolTip($Control, $Tip); $script:Gui['Tips'].SetToolTip($l, $Tip) }
        $dlg.Controls.Add($l); $dlg.Controls.Add($Control); $c[$Key] = $Control; $c[$Key + 'Label'] = $l
        $lay.Y += 30
    }
    $tb = { param([string]$Value) $t = New-Object System.Windows.Forms.TextBox; $t.Text = $Value; $t }
    & $add 'Name' 'Name (shown in the window):' (& $tb $Draft.Name)
    & $add 'Id' 'Package Id (unique, spaces fine):' (& $tb $Draft.Id) 520 'The key of the package: its grid column and its folder on the servers (C:\PatchStaging\software\<Id>).'
    $folderBox = & $tb ('software\' + $Draft.Folder); $folderBox.ReadOnly = $true
    & $add 'Folder' 'Folder on this PC:' $folderBox 520 'Where the installer is. The package reads every file in this folder that matches the file pattern.'
    $matchBox = New-Object System.Windows.Forms.ComboBox; $matchBox.DropDownStyle = 'DropDown'
    foreach ($nm in @(Get-FleetProductNames -Hint $Draft.Name)) { [void]$matchBox.Items.Add($nm) }
    $matchBox.Text = [string]$Draft.Match
    & $add 'Match' 'Name in Programs and Features:' $matchBox 520 'How "installed? which version?" is answered: the DisplayName in the Uninstall registry, * = any text. The list offers names the fleet inventory has seen.'
    & $add 'Pattern' 'Installer file pattern:' (& $tb $Draft.FilePattern) 520 'Which files in the folder are this package. * = any text, so the next version of the file is picked up without registering again.'
    $vf = New-Object System.Windows.Forms.ComboBox; $vf.DropDownStyle = 'DropDownList'
    if ($kind -eq 'msi') { [void]$vf.Items.Add('msi') }
    foreach ($v in 'name', 'file') { [void]$vf.Items.Add($v) }
    if ($vf.Items.Contains([string]$Draft.VersionFrom)) { $vf.SelectedItem = [string]$Draft.VersionFrom } else { $vf.SelectedIndex = 0 }
    & $add 'VersionFrom' 'Version read from:' $vf 90 'msi = the ProductVersion inside the .msi; file = the .exe''s ProductVersion; name = the regular expression on the file name.'
    $rx = & $tb $Draft.VersionRegex; $rx.Location = New-Object System.Drawing.Point(330, ($lay.Y - 30)); $rx.Width = 422
    $script:Gui['Tips'].SetToolTip($rx, 'Only for "name": the capture groups, joined with dots, are the version.')
    $dlg.Controls.Add($rx); $c['Regex'] = $rx
    $modeY = $lay.Y
    $ml = New-Object System.Windows.Forms.Label; $ml.Text = 'Allowed on servers:'; $ml.Location = New-Object System.Drawing.Point(12, ($modeY + 4)); $ml.AutoSize = $true; $dlg.Controls.Add($ml)
    $x = 232
    foreach ($m in 'Install', 'Update', 'Uninstall') {
        $cb = New-Object System.Windows.Forms.CheckBox; $cb.Text = $m; $cb.AutoSize = $true; $cb.Location = New-Object System.Drawing.Point($x, ($modeY + 2)); $cb.Checked = (@($Draft.Modes) -contains $m)
        $script:Gui['Tips'].SetToolTip($cb, $(switch ($m) { 'Install' { 'INSTALL may put it on servers that do not have it' } 'Update' { 'UPDATE may replace an older version on a server' } default { 'UNINSTALL may remove the product from servers. Unticked = the product is protected: the tool never removes it (right for VMware Tools; wrong for an ordinary application whose old version must go first).' } }))
        $dlg.Controls.Add($cb); $c['Mode' + $m] = $cb; $x += 100
    }
    $lay.Y += 30
    $req = New-Object System.Windows.Forms.ComboBox; $req.DropDownStyle = 'DropDown'
    foreach ($v in '(any server)', 'VMware*') { [void]$req.Items.Add($v) }
    $req.Text = $(if ($Draft.Requires) { [string]$Draft.Requires } else { '(any server)' })
    & $add 'Requires' 'Only on hardware (manufacturer):' $req 200 'Win32_ComputerSystem.Manufacturer must match, e.g. VMware* = VMware virtual machines only.'
    & $add 'Signers' 'Trusted signer(s):' (& $tb (@($Draft.Signers) -join '; ')) 520 'The O= of the Authenticode signer must start with one of these - checked here and again on the server before it runs. Several: separate them with ;'
    $uns = New-Object System.Windows.Forms.CheckBox; $uns.Text = 'Allow it unsigned (an internal package; the SHA256 is still checked)'; $uns.AutoSize = $true
    $uns.Location = New-Object System.Drawing.Point(232, $lay.Y); $uns.Enabled = ([string]$Facts.Signature -ne 'Valid'); $uns.Checked = [bool]$Draft.AllowUnsigned
    $dlg.Controls.Add($uns); $c['Unsigned'] = $uns; $lay.Y += 30
    if ($kind -eq 'exe') {
        $preset = New-Object System.Windows.Forms.ComboBox; $preset.DropDownStyle = 'DropDownList'
        foreach ($v in '(pick a common installer type, or type the vendor''s switches below)', 'InstallShield with an MSI inside:  /s /v"/qn REBOOT=R /l*v {log}"', 'Inno Setup:  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG={log}', 'WiX / Burn bundle:  /quiet /norestart /log {log}') { [void]$preset.Items.Add($v) }
        $preset.SelectedIndex = 0
        & $add 'Preset' 'Silent switches - a starting point:' $preset 520 'Common conventions, not guarantees: use the switches the vendor documents. The reboot must be suppressed or the package is refused.'
        & $add 'Args1' 'Install arguments:' (& $tb $Draft.InstallArguments) 520 '{log} = the installer log path on the server.'
        & $add 'Args2' 'Update arguments:' (& $tb $Draft.UpdateArguments) 520 '{log} = the installer log path on the server.'
    } else {
        & $add 'Args1' 'Extra MSI properties (optional):' (& $tb $Draft.Arguments) 520 'Added after msiexec /i <file> /qn /norestart REBOOT=ReallySuppress /l*v <log>, e.g. ADDLOCAL=ALL.'
    }
    & $add 'Note' 'Note (owner, source, caveats):' (& $tb $Draft.Note)
    $pv = New-Object System.Windows.Forms.TextBox; $pv.Multiline = $true; $pv.ReadOnly = $true; $pv.ScrollBars = 'Vertical'; $pv.WordWrap = $true
    $pv.Font = New-Object System.Drawing.Font('Consolas', 8.5); $pv.BackColor = 'White'
    $pv.Location = New-Object System.Drawing.Point(12, ($lay.Y + 6)); $pv.Size = New-Object System.Drawing.Size(740, (720 - $lay.Y - 6))
    $dlg.Controls.Add($pv); $c['Preview'] = $pv
    $okText = 'Register'; $hintText = 'Writes one entry into data\software-packages.psd1'
    if ($editing) { $okText = 'Save changes'; $hintText = 'Rewrites this entry in data\software-packages.psd1' }
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = $okText; Width = 120 }, @{ Text = 'Cancel'; Result = 'Cancel' }) -Hint $hintText
    $dlg.CancelButton = $bar.Buttons[1]

    # the form's reading of itself, and the preview; the handlers run while ShowDialog holds this function on the stack
    $read = {
        $d = [ordered]@{}
        $d.Id = $c['Id'].Text.Trim(); $d.Name = $c['Name'].Text.Trim(); $d.Folder = [string]$Detected.Folder; $d.Match = $c['Match'].Text.Trim(); $d.FilePattern = $c['Pattern'].Text.Trim()
        $d.VersionFrom = [string]$c['VersionFrom'].SelectedItem; $d.VersionRegex = $c['Regex'].Text.Trim()
        $d.Installer = $kind; $d.Arguments = ''; $d.InstallArguments = ''; $d.UpdateArguments = ''
        if ($kind -eq 'msi') { $d.Arguments = $c['Args1'].Text.Trim() } else { $d.InstallArguments = $c['Args1'].Text.Trim(); $d.UpdateArguments = $c['Args2'].Text.Trim() }
        $d.Modes = @(foreach ($m in 'Install', 'Update', 'Uninstall') { if ($c['Mode' + $m].Checked) { $m } })
        $d.Requires = $c['Requires'].Text.Trim(); if ($d.Requires -eq '(any server)') { $d.Requires = '' }
        $d.Signers = @($c['Signers'].Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $d.AllowUnsigned = [bool]$c['Unsigned'].Checked
        $d.Note = $c['Note'].Text.Trim()
        foreach ($k in @($Draft.Keys)) { if (-not $d.Contains($k)) { $d[$k] = $Draft[$k] } }
        $d
    }
    $refresh = {
        $d = & $read
        $c['Regex'].Enabled = ($d.VersionFrom -eq 'name')
        $t = Test-SoftwarePackageDraft -Draft $d -Detected $Detected -Facts $Facts -OriginalId $OriginalId
        $text = New-Object System.Collections.Generic.List[string]
        if ($Notice) { $text.Add('NOTE: ' + $Notice); $text.Add('') }
        $text.Add(('Offered as:   {0} {1}' -f $d.Name, $(if ($t.Version) { $t.Version } else { '(version not readable)' })))
        # what the fleet already has for this Match: the operator sees at once whether "the version" counts the same way
        # (7z2409 against 24.09 would offer an update for ever)
        $seen = @(); try { $seen = @(Get-SoftwareRows -Servers @(Get-GridAllKeys -Grid $script:Gui['SoftwareServerGrid']) | Where-Object { $_.Product -like [string]$d.Match } | ForEach-Object { [string]$_.Version } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First 4) } catch { $seen = @() }
        if ($seen.Count -gt 0) {
            $text.Add(('Installed:    {0} (from the last inventory)' -f ($seen -join ', ')))
            $shape = { param([string]$v) $m = [regex]::Match($v, '\d+(\.\d+)*'); if ($m.Success) { @($m.Value -split '\.').Count } else { 0 } }
            if ($t.Version -and (& $shape $t.Version) -ne (& $shape $seen[0])) { $text.Add('              WARNING: the file''s version and the installed version are written differently - check that Version from compares like with like') }
        }
        $text.Add(('On a server:  {0}\software\{1}\{2}, run as a one-shot SYSTEM task' -f $script:Config.RemoteStaging.TrimEnd('\'), (Get-SoftwareStageName $d.Id), $(if ($Detected.File) { $Detected.File } else { '<installer>' })))
        $text.Add(('Allowed on:   {0}' -f $(if ($d.Requires) { "'" + $d.Requires + "' machines only" } else { 'any server' })))
        $text.Add(('Trusted:      {0}' -f $(if ($d.AllowUnsigned) { 'unsigned allowed (a signed file that was changed is still refused; the copy on the server must match this file''s SHA256)' } else { 'files signed by ' + (@($d.Signers) -join ' / ') })))
        $text.Add(('Removal:      {0}' -f $(if (@($d.Modes) -contains 'Uninstall') { 'allowed - UNINSTALL may remove it (MSI product code, or the product''s quiet uninstall string)' } else { 'NOT allowed - the product is protected: UNINSTALL refuses it' })))
        $text.Add('')
        foreach ($l in @(Get-SoftwareCommandPreview -Draft $d -Detected $Detected)) { $text.Add($l) }
        $text.Add('')
        if (@($t.Problems).Count -eq 0) { $text.Add(('READY - press {0}.' -f $okText)); $c['Preview'].ForeColor = 'DarkGreen' }
        else { $text.Add('NOT READY:'); foreach ($p in @($t.Problems)) { $text.Add('  - ' + $p) }; $c['Preview'].ForeColor = 'DarkRed' }
        $c['Preview'].Text = ($text.ToArray() -join "`r`n")
        $t
    }
    $timer = New-Object System.Windows.Forms.Timer; $timer.Interval = 350
    $timer.Add_Tick({ $this.Stop(); $null = & $refresh })
    foreach ($k in @($c.Keys)) {
        $ctl = $c[$k]
        if ($ctl -is [System.Windows.Forms.TextBox] -and $k -ne 'Preview') { $ctl.Add_TextChanged({ $timer.Stop(); $timer.Start() }) }
        elseif ($ctl -is [System.Windows.Forms.ComboBox] -and $k -ne 'Preset') { $ctl.Add_TextChanged({ $timer.Stop(); $timer.Start() }); $ctl.Add_SelectedIndexChanged({ $timer.Stop(); $timer.Start() }) }
        elseif ($ctl -is [System.Windows.Forms.CheckBox]) { $ctl.Add_CheckedChanged({ $timer.Stop(); $timer.Start() }) }
    }
    if ($c.ContainsKey('Preset')) {
        $c['Preset'].Add_SelectedIndexChanged({
            $v = [string]$this.SelectedItem
            if ($this.SelectedIndex -gt 0 -and $v -match ':\s+(.+)$') { $c['Args1'].Text = $Matches[1]; $c['Args2'].Text = $Matches[1] }
        })
    }
    $bar.Buttons[0].Add_Click({
        $t = & $refresh
        if (@($t.Problems).Count -gt 0) { return }
        $dlg.Tag = (& $read)
        $dlg.DialogResult = 'OK'
        $dlg.Close()
    })
    $null = & $refresh
    $answer = $dlg.ShowDialog($script:Gui['Form'])
    $result = $null
    if ($answer -eq 'OK') { $result = $dlg.Tag }
    $timer.Dispose(); $dlg.Dispose()
    return $result
}

function Register-SoftwareInstaller {
    # A NEW installer's own Register... button: that installer through the Register form into the catalogue - then the scan
    # runs again and the installer is offered like any other.
    param([string]$FullName)
    $pick = @(@($script:SoftwareDetected) | Where-Object { $_.FullName -eq $FullName })[0]
    if (-not $pick) {
        $null = Show-PatcherMessage -Text ("This installer is no longer NEW (moved, removed or registered meanwhile):`n`n{0}`n`nPress Reload lists + packages." -f $FullName) -Title 'Register software' -Icon 'Information'
        return
    }
    Set-GuiStatus "Reading $($pick.File) (signature, product name, version) ..."
    $facts = Get-SoftwareFileFacts -Path $pick.FullName
    $draft = New-SoftwarePackageDraft -Detected $pick -Facts $facts
    $result = Show-SoftwareRegisterDialog -Detected $pick -Facts $facts -Draft $draft
    if (-not $result) { Write-PatchLog "Registration of $($pick.File) cancelled - nothing written" 'INFO'; return }
    $from = $pick.File; if ($pick.Folder) { $from = $pick.Folder + '\' + $pick.File }
    Add-SoftwarePackage -Draft $result -From $from
    Get-SoftwarePackageFiles | Out-Null
}

# ---------------------------------------------------------------------
#  SOFTWARE STATE collector - RUNS ON THE SERVER, read-only: hardware,
#  staged installers, the toolkit's tasks, Windows Installer busy, and the
#  server's own change record.
# ---------------------------------------------------------------------
$script:RemoteSoftwareStateScript = {
    param([string]$Staging)
    $ErrorActionPreference = 'Continue'
    $cs = $null
    try { $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop } catch { }
    $swDir = $Staging.TrimEnd('\') + '\software'
    $staged = @()
    if (Test-Path -LiteralPath $swDir) {
        # each package stages into its own sub-folder (software\<package>\<installer>): the path relative to software\ is the name
        $staged = @(Get-ChildItem -LiteralPath $swDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.msi', '.msp' } | ForEach-Object { '{0}|{1}|{2}' -f $_.FullName.Substring($swDir.Length + 1), $_.Length, $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm') })
    }
    $tasks = @()
    try {
        foreach ($t in @(Get-ScheduledTask -TaskPath '\WinRMToolkit\' -ErrorAction Stop)) {
            $ti = $null
            try { $ti = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
            $code = ''; $last = ''
            if ($ti) { $code = [string][int64]$ti.LastTaskResult; if ($ti.LastRunTime -and $ti.LastRunTime.Year -gt 2000) { $last = $ti.LastRunTime.ToString('yyyy-MM-dd HH:mm') } }
            $label = ''
            $meta = $swDir + '\task-' + $t.TaskName + '.txt'
            if (Test-Path -LiteralPath $meta) { $hit = @(Get-Content -LiteralPath $meta | Where-Object { $_ -like 'Item=*' }); if ($hit.Count -gt 0) { $label = $hit[0].Substring(5) } }
            $tasks += '{0}|{1}|{2}|{3}|{4}' -f $t.TaskName, $t.State, $code, $last, ($label -replace '\|', '/')
        }
    } catch { }
    $msiBusy = $false
    try { $mtx = $null; if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mtx)) { $msiBusy = $true; $mtx.Close() } } catch { $msiBusy = $true }
    $tail = @()
    $cl = $Staging.TrimEnd('\') + '\change-log.txt'
    if (Test-Path -LiteralPath $cl) { $tail = @(Get-Content -LiteralPath $cl -Tail 25 -ErrorAction SilentlyContinue) }
    $make = ''; $model = ''
    if ($cs) { $make = [string]$cs.Manufacturer; $model = [string]$cs.Model }
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Manufacturer = $make; Model = $model; Staged = $staged; Tasks = $tasks; MsiBusy = $msiBusy; ServerChangeLog = $tail }
}

function Get-ServerSoftwareState {
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = { param($r) ('{0} {1}, {2} staged installer(s), {3} toolkit task(s){4}' -f $r.Manufacturer, $r.Model, @($r.Staged).Count, @($r.Tasks).Count, $(if ($r.MsiBusy) { ', Windows Installer busy' } else { '' })) }
    return (Invoke-Collector -Name 'SoftwareState' -ScriptBlock $script:RemoteSoftwareStateScript -ComputerName $ComputerName -ArgumentList @($script:Config.RemoteStaging) -Summary $summary)
}

function Update-SoftwareFacts {
    # What the plan needs, fresh: status (reachability, duplicates), inventory (installed versions), software state (hardware, tasks).
    param([string[]]$ComputerName, [switch]$NoStatus)
    if (-not $NoStatus) { Get-ServerStatus -ComputerName $ComputerName | Out-Null }
    Get-ServerInventory -ComputerName $ComputerName | Out-Null
    Get-ServerSoftwareState -ComputerName $ComputerName | Out-Null
}

function Get-ServerManufacturer {
    param([string]$Server)
    $st = Get-CollectorResult -Name 'SoftwareState' -Server $Server
    if ($st -and $st.Reachable -and $st.Manufacturer) { return [string]$st.Manufacturer }
    $s = $script:ServerStatus[$Server]
    if ($s -and $s.Reachable -and $s.PSObject.Properties['Manufacturer'] -and $s.Manufacturer) { return [string]$s.Manufacturer }
    return ''
}

function Get-ServerTaskRows {
    # The toolkit's scheduled tasks on one server, from the SoftwareState collector.
    param([string]$Server)
    $st = Get-CollectorResult -Name 'SoftwareState' -Server $Server
    if (-not $st -or -not $st.Reachable) { return @() }
    return @(ConvertFrom-PipeLines -Lines @($st.Tasks) -Columns @('Task', 'State', 'LastResult', 'LastRun', 'Item'))
}

# ---------------------------------------------------------------------
#  Verdicts: one function per decision, used by the grid, the plan and the report alike
# ---------------------------------------------------------------------
function Get-SoftwareVerdict {
    # THE decision "what would INSTALL / UPDATE do with this installer file on this server?" (the Software twin of
    # Get-PatchVerdict).  Returns Cell, Go, Mode ('Install' / 'Update' / ''), Reason, Light, Installed, Staged.
    # -Products: the server's rows of Get-SoftwareRows when the caller already has them (a grid of hundreds of servers)
    param([string]$Server, $PackageFile, [object[]]$Products = $null)
    $pkg = $PackageFile.Package
    $modes = @($pkg.Modes)
    $cell = 'not checked'; $go = $false; $mode = ''; $reason = 'not checked yet - press Check'; $light = 'Grey'; $have = ''; $staged = $false
    $inv = Get-CollectorResult -Name 'Inventory' -Server $Server
    $st = Get-CollectorResult -Name 'SoftwareState' -Server $Server
    if ($inv -and -not $inv.Reachable) { $cell = '?'; $reason = 'unreachable: ' + $inv.Error }
    elseif ($inv) {
        $best = $null
        if ($null -eq $Products) { $Products = @(Get-SoftwareRows -Servers @($Server)) }
        foreach ($p in $Products) {
            if ($p.Product -notlike [string]$pkg.Match) { continue }
            if (-not $best -or ((ConvertTo-VersionObject $p.Version) -gt (ConvertTo-VersionObject $best.Version))) { $best = $p }
        }
        if ($best) { $have = [string]$best.Version }
        $make = Get-ServerManufacturer -Server $Server
        if ($PackageFile.Blocked) { $cell = 'Blocked: file'; $reason = 'the installer file is blocked: ' + $PackageFile.Blocked; $light = 'Red' }
        elseif ($pkg.Requires -and -not $make) { $cell = 'not checked'; $reason = ("the hardware has not been read yet - press Check (this package needs a '{0}' machine)" -f $pkg.Requires) }
        elseif ($pkg.Requires -and $make -notlike [string]$pkg.Requires) { $cell = 'N/A (hardware)'; $reason = ("this package is for '{0}' machines; this one is '{1}'" -f $pkg.Requires, $make) }
        elseif ($best) {
            # installed is decided on the name: a product without a DisplayVersion is still installed - never INSTALL over it (R6-C09)
            $a = ConvertTo-VersionObject $have; $b = ConvertTo-VersionObject $PackageFile.Version
            # a DisplayVersion that is not a version number ("build 7", "2024 Update 3") must not win as "newer"; amber, so
            # it never counts as current in the row colour, the summary or the library (R6-C08)
            if (-not $have) { $cell = 'Installed ?'; $reason = "installed, but its version is not recorded - it cannot be compared with the file's '$($PackageFile.Version)'"; $light = 'Amber' }
            elseif ($null -eq $a -or $null -eq $b -or $have -notmatch '^\s*[vV]?\d') { $cell = "Installed $have ?"; $reason = "the installed version '$have' cannot be compared with the file's '$($PackageFile.Version)'"; $light = 'Amber' }
            elseif ($a -gt $b) { $cell = "Newer $have"; $reason = "a newer version than the file ($($PackageFile.Version)) is installed"; $light = 'Green' }
            elseif ($a -eq $b) { $cell = "Installed $have"; $reason = 'the file''s version is installed'; $light = 'Green' }
            elseif ($modes -contains 'Update') { $cell = 'UPDATE -> ' + $PackageFile.Version; $go = $true; $mode = 'Update'; $light = 'Amber'; $reason = "installed $have, the file brings $($PackageFile.Version)" }
            else { $cell = 'Behind'; $reason = "installed $have is older than $($PackageFile.Version), but software-packages.psd1 does not allow Update for this package"; $light = 'Amber' }
        } elseif ($modes -contains 'Install') { $cell = 'INSTALL ' + $PackageFile.Version; $go = $true; $mode = 'Install'; $light = 'Amber'; $reason = 'not installed; the package allows a new install' }
        else { $cell = 'Not installed'; $reason = 'not installed, and the package allows Update only' }
        if ($st -and $st.Reachable) {
            $running = @(); if (@($st.Tasks).Count -gt 0) { $running = @(Get-ServerTaskRows -Server $Server | Where-Object { $_.State -eq 'Running' }) }
            if ($go -and $running.Count -gt 0) { $go = $false; $cell = 'Task running'; $reason = 'a toolkit task is running on the server: ' + (($running | ForEach-Object { "$($_.Task) $($_.Item)" }) -join ', '); $light = 'Grey' }
            $stagedAs = (Get-SoftwareStageName $PackageFile.Id) + '\' + $PackageFile.File
            foreach ($line in @($st.Staged)) { $f = ([string]$line) -split '\|'; if ($f[0] -ieq $stagedAs -and [int64]$f[1] -eq [int64]$PackageFile.Length) { $staged = $true } }
            if ($staged -and $go) { $cell += ' (staged)' }
        }
    }
    return [pscustomobject]@{ Cell = $cell; Go = $go; Mode = $mode; Reason = $reason; Light = $light; Installed = $have; Staged = $staged }
}

function Get-SoftwareLibraryFiles {
    # One installer per package, for every package in software\: the ticked file of that package when exactly one is
    # ticked, else the newest usable one, else the newest.  The All packages column, the library window and the report
    # use the whole list; the grid columns show only the packages chosen (Get-SoftwareGridFiles).
    $ticked = @(Get-CheckedSoftwareFiles)
    $pick = @()
    foreach ($g in @(@($script:SoftwareFiles) | Where-Object { $_ } | Group-Object Id)) {
        $t = @($ticked | Where-Object { $_.Id -eq $g.Name })
        if ($t.Count -eq 1) { $pick += $t[0]; continue }
        $usable = @($g.Group | Where-Object { -not $_.Blocked })
        if ($usable.Count -gt 0) { $pick += $usable[0] } else { $pick += $g.Group[0] }
    }
    return $pick
}

function Get-SoftwareGridFiles {
    # The grid's package columns: the packages shown (Get-SoftwareShownIds), in that order.
    $lib = @(Get-SoftwareLibraryFiles)
    return @(foreach ($id in @(Get-SoftwareShownIds)) { $lib | Where-Object { $_.Id -eq $id } | Select-Object -First 1 })
}

# ---------------------------------------------------------------------
#  A big library: the console shows at most MaxSoftwareColumns packages - as grid columns and in the installer list -
#  and the "All packages" column counts what every package would do.  The operator picks the packages shown in the
#  Software library window; the choice is kept in settings\software-shown.json.
# ---------------------------------------------------------------------
function Get-SoftwarePackageIds {
    # Every package with at least one installer file, by name.
    return @(@($script:SoftwareFiles) | Where-Object { $_ } | ForEach-Object { $_.Id } | Select-Object -Unique | Sort-Object)
}

function Get-SoftwareShownPath {
    return (Join-Path (Split-Path -Path $script:Config.SettingsFile -Parent) 'software-shown.json')
}

function Get-SoftwareShownIds {
    # The packages the console shows: every one while the library has no more than MaxSoftwareColumns; else the
    # operator's choice (saved), topped up to nothing more than the limit, or - nothing chosen yet - the first by name.
    $all = @(Get-SoftwarePackageIds)
    $max = [Math]::Max(1, [int]$script:Config.MaxSoftwareColumns)
    if ($all.Count -le $max) { return $all }
    if ($null -eq $script:SoftwareShown) {
        $script:SoftwareShown = @()
        $p = Get-SoftwareShownPath
        if (Test-Path -LiteralPath $p) {
            try { $script:SoftwareShown = @(([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).Packages | ForEach-Object { [string]$_ } | Where-Object { $_ }) }
            catch { Write-PatchLog "The packages chosen for the Software console could not be read ($(Get-ShortError $_)) - the first $max by name are shown" 'WARN' }
        }
    }
    $pick = @(@($script:SoftwareShown) | Where-Object { $all -contains $_ } | Select-Object -First $max)
    if ($pick.Count -eq 0) { $pick = @($all | Select-Object -First $max) }
    return $pick
}

function Set-SoftwareShownIds {
    # The library window's choice: kept for the session and in settings\software-shown.json (git-ignored).  Ticks on
    # installers of packages no longer shown are dropped - INSTALL acts only on what the list shows.
    param([string[]]$Ids)
    $max = [Math]::Max(1, [int]$script:Config.MaxSoftwareColumns)
    $script:SoftwareShown = @(@($Ids) | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $max)
    $p = Get-SoftwareShownPath
    try {
        $dir = Split-Path -Path $p -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($p, (ConvertTo-Json -InputObject ([ordered]@{ Note = 'The packages the Software console shows (Software library window).'; Packages = @($script:SoftwareShown) }) -Depth 3), (New-Object System.Text.UTF8Encoding $false))
    } catch { Write-PatchLog "The packages chosen could not be saved ($(Get-ShortError $_)) - they apply to this session" 'WARN' }
    Write-PatchLog ("Software console shows: {0} (chosen by {1})" -f ($script:SoftwareShown -join ', '), (Get-OperatorIdentity)) 'INFO'
}

function Get-SoftwareVerdictCached {
    # Get-SoftwareVerdict, remembered until the server is checked again or the file or its package changes: the All
    # packages column and the library window ask for every package on every server, and a big library times hundreds of
    # servers adds up.  A new scan of software\ empties the cache.
    param([string]$Server, $PackageFile, [object[]]$Products)
    if (-not $script:SoftwareVerdictCache -or $script:SoftwareVerdictCache.Count -gt 200000) { $script:SoftwareVerdictCache = @{} }
    $s = $script:ServerStatus[$Server]; $inv = Get-CollectorResult -Name 'Inventory' -Server $Server; $st = Get-CollectorResult -Name 'SoftwareState' -Server $Server
    $pkg = $PackageFile.Package
    $key = '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $Server.ToLower(), $(if ($s) { $s.Checked.Ticks } else { 0 }), $(if ($inv) { $inv.Checked.Ticks } else { 0 }), $(if ($st) { $st.Checked.Ticks } else { 0 }), $PackageFile.FullName, $PackageFile.Version, $PackageFile.Blocked, (@($pkg.Modes) -join ','), $pkg.Match, $pkg.Requires
    $v = $script:SoftwareVerdictCache[$key]
    if (-not $v) { $v = Get-SoftwareVerdict -Server $Server -PackageFile $PackageFile -Products $Products; $script:SoftwareVerdictCache[$key] = $v }
    return $v
}

function Get-SoftwareCellColour {
    # One package cell: green when that version (or newer) is installed, yellow when INSTALL / UPDATE would act, pink when
    # the installer is blocked; '' = the row's colour.
    param($Verdict)
    if ($Verdict.Light -eq 'Green') { return 'PaleGreen' }
    if ($Verdict.Go) { return 'LemonChiffon' }
    if ($Verdict.Light -eq 'Red') { return 'MistyRose' }
    return ''
}

function Get-SoftwareSummary {
    # What every package would do on one server, from its verdicts: the All packages cell, its colour, and the list of
    # what is to do (for the row's tooltip).
    param([object[]]$Verdicts)
    $todo = @(); $updates = 0; $installs = 0; $current = 0; $blocked = 0; $behind = 0; $checked = $false
    foreach ($v in @($Verdicts)) {
        if ($v.Verdict.Cell -eq '?') { return [pscustomobject]@{ Text = '?'; Colour = ''; Todo = @(); Go = $false; Current = 0; Behind = 0; Checked = $false } }
        if ($v.Verdict.Cell -ne 'not checked') { $checked = $true }
        if ($v.Verdict.Go) { $todo += ('{0}: {1}' -f $v.Id, $v.Verdict.Cell); if ($v.Verdict.Mode -eq 'Update') { $updates++ } else { $installs++ } }
        elseif ($v.Verdict.Light -eq 'Green') { $current++ }
        elseif ($v.Verdict.Light -eq 'Red') { $blocked++ }
        elseif ($v.Verdict.Light -eq 'Amber') { $behind++ }   # an older version the package may not update, or one that cannot be compared: not current
    }
    $total = @($Verdicts).Count
    $text = 'not checked'; $colour = ''
    if ($checked) {
        if ($todo.Count -gt 0) {
            $parts = @(); if ($updates) { $parts += "$updates UPDATE" }; if ($installs) { $parts += "$installs INSTALL" }
            $text = ('{0} to do ({1})' -f $todo.Count, ($parts -join ', ')); $colour = 'LemonChiffon'
        } else {
            # green only when nothing is behind: "1 of 3 current" with two behind is not a green cell
            $text = ('{0} of {1} current' -f $current, $total)
            if ($behind -gt 0) { $text += (', {0} behind' -f $behind); $colour = 'LemonChiffon' } elseif ($current -gt 0) { $colour = 'PaleGreen' }
        }
        if ($blocked) { $text += (', {0} blocked' -f $blocked) }
    }
    return [pscustomobject]@{ Text = $text; Colour = $colour; Todo = $todo; Go = ($todo.Count -gt 0); Current = $current; Behind = $behind; Checked = $checked }
}

function Get-SoftwareLibraryRows {
    # One row per package for the Software library window: its newest usable installer and what it would do on the
    # servers given - how many to UPDATE, to INSTALL, already current, not checked - and the newest version deployed.
    # Light: Amber = the library holds a newer version than some servers have (or a new install), Green = current on
    # every server checked, Red = the installer is blocked, Grey = not checked yet.
    param([string[]]$Servers)
    $null = Get-SoftwareRows -Servers $Servers
    $byServer = @{}; if ($script:SoftwareRowCache) { $byServer = $script:SoftwareRowCache.ByServer }
    $shown = @(Get-SoftwareShownIds)
    $rows = @()
    foreach ($f in @(Get-SoftwareLibraryFiles)) {
        $upd = 0; $ins = 0; $cur = 0; $none = 0; $behind = 0; $deployed = ''
        foreach ($srv in @($Servers)) {
            $mine = @(); $list = $byServer[$srv.ToLower()]; if ($list) { $mine = $list.ToArray() }
            $v = Get-SoftwareVerdictCached -Server $srv -PackageFile $f -Products $mine
            if ($v.Go -and $v.Mode -eq 'Update') { $upd++ } elseif ($v.Go) { $ins++ } elseif ($v.Light -eq 'Green') { $cur++ } elseif ($v.Light -eq 'Amber') { $behind++ } elseif ($v.Cell -eq 'not checked') { $none++ }
            if ($v.Installed -and (-not $deployed -or (ConvertTo-VersionObject $v.Installed) -gt (ConvertTo-VersionObject $deployed))) { $deployed = [string]$v.Installed }
        }
        $light = 'Grey'; $status = 'not checked yet'
        if ($f.Blocked) { $light = 'Red'; $status = 'installer blocked: ' + $f.Blocked }
        elseif ($upd + $ins -gt 0) { $light = 'Amber'; $status = $(if ($upd -gt 0) { ('newer than deployed on {0} server(s)' -f $upd) } else { 'not installed yet' }) }
        elseif ($behind -gt 0) { $light = 'Amber'; $status = ('behind on {0} server(s) - Update not allowed for this package, or the versions cannot be compared' -f $behind) }
        elseif ($cur -gt 0) { $light = 'Green'; $status = 'current on every server checked' }
        $files = @(@($script:SoftwareFiles) | Where-Object { $_.Id -eq $f.Id }).Count
        $rows += [pscustomobject]@{ Package = $f.Id; Shown = ($shown -contains $f.Id); Version = $f.Version; Files = $files; Update = $upd; Install = $ins; Current = $cur; 'Not checked' = $none; Deployed = $deployed; Status = $status; Light = $light; Todo = ($upd + $ins) }
    }
    # a registered package whose folder holds no matching installer any more still protects its product and holds its Id:
    # it is listed too, so it can be seen and edited (Edit package... in this window) rather than haunt the catalogue
    $listed = @{}; foreach ($r in $rows) { $listed[([string]$r.Package).ToLower()] = $true }
    foreach ($p in @((Get-SoftwareCatalogue).Packages)) {
        if (-not $p -or -not $p.Id -or $listed.ContainsKey(([string]$p.Id).Trim().ToLower())) { continue }
        $rows += [pscustomobject]@{ Package = ([string]$p.Id).Trim(); Shown = $false; Version = ''; Files = 0; Update = 0; Install = 0; Current = 0; 'Not checked' = 0; Deployed = ''; Status = ('no installer file matches in software\{0} - drop one in, or Edit package... here' -f (Get-SoftwarePackageFolder -Package $p)); Light = 'Grey'; Todo = -1 }
    }
    # most to do first, then by name
    return @($rows | Sort-Object @{ Expression = { $_.Todo }; Descending = $true }, @{ Expression = { $_.Package } })
}

function Show-SoftwareLibrary {
    # The Software library window: every package with what it would do on the servers shown, coloured; tick the ones the
    # console should show (at most MaxSoftwareColumns) - as grid columns and in the installer list.
    if (-not (Test-GuiDialogAllowed 'The software library')) { return }
    $servers = @(Get-GridAllKeys -Grid $script:Gui['SoftwareServerGrid'])
    $rows = @(Get-SoftwareLibraryRows -Servers $servers)
    $max = [Math]::Max(1, [int]$script:Config.MaxSoftwareColumns)
    $script:Gui['LibMax'] = $max
    $script:Gui['LibRows'] = $rows
    $script:Gui['LibTicks'] = @{}; foreach ($r in $rows) { if ($r.Shown) { $script:Gui['LibTicks'][$r.Package] = $true } }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = ('Software library - {0} package(s) in the catalogue, {1} with an installer file ({2} file(s))' -f $rows.Count, @(Get-SoftwarePackageIds).Count, @($script:SoftwareFiles).Count)   # the button counts the ones with a file
    $dlg.Size = New-Object System.Drawing.Size(1100, 640); $dlg.StartPosition = 'CenterParent'; $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9); $dlg.MinimizeBox = $false
    $top = New-Object System.Windows.Forms.Panel; $top.Dock = 'Top'; $top.Height = 86
    $intro = New-Object System.Windows.Forms.Label; $intro.Location = New-Object System.Drawing.Point(10, 6); $intro.Size = New-Object System.Drawing.Size(1060, 50)
    $intro.Text = ('Tick up to {0} packages to show as columns of the server grid and in the installer list (MaxSoftwareColumns, Settings tab); the All packages column counts every package. Counts are over the {1} server(s) shown in the console. Yellow = the library holds a newer version than some servers have, or a new install; green = current on every server checked; red = installer blocked; grey = not checked yet.' -f $max, $servers.Count)
    $fl = New-Object System.Windows.Forms.Label; $fl.Text = 'Filter:'; $fl.Location = New-Object System.Drawing.Point(10, 61); $fl.AutoSize = $true
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Location = New-Object System.Drawing.Point(55, 58); $filter.Width = 220
    $count = New-Object System.Windows.Forms.Label; $count.Location = New-Object System.Drawing.Point(290, 61); $count.AutoSize = $true; $count.ForeColor = 'DimGray'
    $top.Controls.AddRange(@($intro, $fl, $filter, $count))
    $script:Gui['LibCount'] = $count
    $grid = New-ConsoleGrid -Columns @(@{ Name = 'Package'; Width = 230 }, @{ Name = 'Version'; Width = 130 }, @{ Name = 'Files'; Width = 45 }, @{ Name = 'Update'; Width = 60 }, @{ Name = 'Install'; Width = 60 }, @{ Name = 'Current'; Width = 60 }, @{ Name = 'Not checked'; Width = 85 }, @{ Name = 'Deployed'; Width = 130 }, @{ Name = 'Status'; Width = 250; Fill = $true })
    $script:Gui['LibGrid'] = $grid
    # a tick past the limit is refused; every tick is kept by package while the filter changes the rows shown
    $grid.Add_ItemCheck({
        if ($script:Gui['LibFilling']) { return }
        $name = [string]$this.Items[$_.Index].Text
        $on = @($script:Gui['LibTicks'].Keys | Where-Object { $script:Gui['LibTicks'][$_] }).Count
        # only a NEW tick counts against the limit: the list re-applies its ticks when it is first drawn on screen
        if ($_.NewValue -eq 'Checked' -and -not $script:Gui['LibTicks'][$name] -and $on -ge $script:Gui['LibMax']) { $_.NewValue = 'Unchecked'; $script:Gui['LibCount'].Text = ('at most {0} - untick one first' -f $script:Gui['LibMax']); return }
        $script:Gui['LibTicks'][$name] = ($_.NewValue -eq 'Checked')
        Update-SoftwareLibraryCount
    })
    $filter.Add_TextChanged({ Update-SoftwareLibraryGrid -Filter $this.Text })
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = 'Most needed'; Width = 110 }, @{ Text = 'Untick all'; Width = 90 }, @{ Text = 'Edit package...'; Width = 120 }, @{ Text = 'Show ticked'; Result = 'OK'; Width = 110 }, @{ Text = 'Cancel'; Result = 'Cancel' }) -Hint 'Most needed = the packages with the most servers to update or install'
    $bar.Buttons[0].Add_Click({
        $script:Gui['LibTicks'] = @{}
        foreach ($r in @($script:Gui['LibRows'] | Select-Object -First $script:Gui['LibMax'])) { $script:Gui['LibTicks'][$r.Package] = $true }
        Update-SoftwareLibraryGrid -Filter $script:Gui['LibFilter'].Text
    })
    $bar.Buttons[1].Add_Click({ $script:Gui['LibTicks'] = @{}; Update-SoftwareLibraryGrid -Filter $script:Gui['LibFilter'].Text })
    # Edit package...: the selected row's registration, with or without an installer file; the rows are read again afterwards
    $bar.Buttons[2].Add_Click({
        $sel = $script:Gui['LibGrid'].SelectedItems
        if ($sel.Count -eq 0) { $script:Gui['LibCount'].Text = 'select a package first'; return }
        Edit-SoftwarePackage -Id ([string]$sel[0].Text)
        $script:Gui['LibRows'] = @(Get-SoftwareLibraryRows -Servers @(Get-GridAllKeys -Grid $script:Gui['SoftwareServerGrid']))
        Update-SoftwareLibraryGrid -Filter $script:Gui['LibFilter'].Text
    })
    $script:Gui['LibFilter'] = $filter
    $dlg.Controls.Add($grid); $dlg.Controls.Add($top); $grid.BringToFront()
    $dlg.AcceptButton = $null; $dlg.CancelButton = $bar.Buttons[4]
    Update-SoftwareLibraryGrid -Filter ''
    $answer = $dlg.ShowDialog($script:Gui['Form'])
    $dlg.Dispose()
    if ($answer -ne 'OK') { return }
    $pick = @(@($rows | Where-Object { $script:Gui['LibTicks'][$_.Package] }) | ForEach-Object { $_.Package })
    if ($pick.Count -eq 0) { Write-PatchLog 'Software library: nothing ticked - the packages shown stay as they were' 'WARN'; return }
    # the console shows them by name, as the library lists them by need
    Set-SoftwareShownIds -Ids @($pick | Sort-Object)
    Update-SoftwarePackageList
    Update-SoftwareServerGrid
}

function Update-SoftwareLibraryGrid {
    # The library window's rows matching the filter (plain text, package name), ticked from the kept ticks.
    param([string]$Filter = '')
    $grid = $script:Gui['LibGrid']
    $q = $Filter.Trim()
    $rows = @($script:Gui['LibRows'] | Where-Object { -not $q -or $_.Package.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $script:Gui['LibFilling'] = $true
    try {
        Set-GridRows -Grid $grid -Rows $rows -RowColour { param($row) Get-LightColour $row.Light } -ToolTipProperty 'Status' -NoKeepChecks
        $script:GridProgrammatic = $true   # the tool's own ticks pass the box-only rule (Set-GridTickOnBoxOnly)
        foreach ($it in $grid.Items) { if ($script:Gui['LibTicks'][$it.Text]) { $it.Checked = $true } }
    } finally { $script:GridProgrammatic = $false; $script:Gui['LibFilling'] = $false }
    Update-SoftwareLibraryCount
}

function Update-SoftwareLibraryCount {
    $on = @($script:Gui['LibTicks'].Keys | Where-Object { $script:Gui['LibTicks'][$_] }).Count
    $script:Gui['LibCount'].Text = ('{0} of at most {1} ticked; {2} of {3} package(s) listed' -f $on, $script:Gui['LibMax'], $script:Gui['LibGrid'].Items.Count, @($script:Gui['LibRows']).Count)
}

function Get-SoeStandardForSoftware {
    # Read-SoeStandard with a 2-second memo: the inventory list asks once per product row.
    param([string]$Name)
    if (-not $script:SoeMemo) { $script:SoeMemo = @{} }
    $hit = $script:SoeMemo[$Name]
    if ($hit -and ([datetime]::UtcNow - $hit.Seen).TotalSeconds -lt 2) { return $hit.Std }
    $std = $null
    try { $std = Read-SoeStandard -Name $Name } catch { $std = $null }
    $script:SoeMemo[$Name] = @{ Seen = [datetime]::UtcNow; Std = $std }
    return $std
}

function Get-ProductProtection {
    # Why UNINSTALL must not touch this product on this server, or ''.  Memoised for 2 s per (standard, product): the
    # inventory list asks for every row it shows, and a fleet repeats the same products on every server.
    param([string]$Server, [string]$Product)
    $now = [datetime]::UtcNow
    if (-not $script:ProtectionMemo -or ($now - $script:ProtectionMemo.Since).TotalSeconds -gt 2) { $script:ProtectionMemo = @{ Catalogue = (Get-SoftwareCatalogue); Since = $now; Map = @{}; Std = @{} } }
    $cat = $script:ProtectionMemo.Catalogue
    # the server's standard, once per memo (the default standard costs a file check)
    $srvKey = $Server.ToLower()
    if (-not $script:ProtectionMemo.Std.ContainsKey($srvKey)) { $script:ProtectionMemo.Std[$srvKey] = [string](Get-SoeStandardNameForServer -Server $Server) }
    $stdName = $script:ProtectionMemo.Std[$srvKey]
    $memoKey = $stdName + '|' + $Product
    if ($script:ProtectionMemo.Map.ContainsKey($memoKey)) { return $script:ProtectionMemo.Map[$memoKey] }
    $why = ''
    # protection that cannot be read protects everything: a hand edit that breaks the catalogue, or a server's SOE standard
    # that is named but missing or broken, must never turn VMware Tools or the security agents into removable products (R6-C01)
    if ($cat.Unreadable) { $why = 'protected: data\software-packages.psd1 could not be read (see the log) - nothing is removed until it can be' }
    foreach ($p in @($cat.ProtectedProducts)) { if ($why) { break }; if ($p -and $Product -like [string]$p) { $why = "protected: matches '$p' (ProtectedProducts in data\software-packages.psd1)"; break } }
    if (-not $why) { foreach ($pkg in @($cat.Packages)) { if ($pkg -and $pkg.Match -and $Product -like [string]$pkg.Match -and @($pkg.Modes) -notcontains 'Uninstall') { $why = "package '$($pkg.Id)' in software-packages.psd1 does not allow Uninstall"; break } } }
    if (-not $why -and $stdName) {
        $std = Get-SoeStandardForSoftware -Name $stdName
        if (-not $std) { $why = "protected: the server's SOE standard '$stdName' could not be read (soe\$stdName.json missing or not valid JSON) - nothing is removed until it can be" }
        elseif (@($std.items | Where-Object { [string]$_.type -eq 'agent' }).Count -gt 0 -and (Get-SoeAgentRules).AsOf -eq 'n/a') { $why = 'protected: data\soe-agents.psd1 could not be read, so the SOE agent items cannot be matched - nothing is removed until it can be' }
        if ($std -and -not $why) {
            $agents = @((Get-SoeAgentRules).Agents)
            foreach ($it in @($std.items)) {
                $req = $true; if ($it.PSObject.Properties['required'] -and $null -ne $it.required) { $req = [bool]$it.required }
                if (-not $req) { continue }
                if ([string]$it.type -eq 'software' -and $it.name -and $Product -like [string]$it.name) { $why = "required by the server's SOE standard '$stdName' (software item '$($it.name)')"; break }
                if ([string]$it.type -eq 'agent' -and $it.name) {
                    $rule = @($agents | Where-Object { [string]$_.Name -ieq [string]$it.name })[0]
                    if ($rule) { foreach ($pat in @(([string]$rule.Products) -split ';' | Where-Object { $_ })) { if ($Product -like $pat) { $why = "required by the server's SOE standard '$stdName' (agent '$($it.name)')" } } }
                    if ($why) { break }
                }
            }
        }
    }
    $script:ProtectionMemo.Map[$memoKey] = $why
    return $why
}

function Get-ServerUseMap {
    # For one server: every product install folder (lower case) -> what runs from it ('service X', 'process', 'task Y'),
    # or '' when nothing does.  Built once per inventory collection: services' paths, running processes, task actions.
    param([string]$Server)
    $inv = Get-CollectorResult -Name 'Inventory' -Server $Server
    if (-not $inv -or -not $inv.Reachable) { return $null }
    if (-not $script:UseMapCache) { $script:UseMapCache = @{} }
    $key = $Server.ToLower()
    $hit = $script:UseMapCache[$key]
    if ($hit -and $hit.Ticks -eq $inv.Checked.Ticks) { return $hit.Map }
    $uses = New-Object System.Collections.Generic.List[object]
    # (the parentheses matter: a comma binds tighter than +, so 'service ' + $a, $b would be one joined string)
    foreach ($l in @($inv.Services)) { $f = ([string]$l) -split '\|'; if ($f.Count -ge 6) { $uses.Add(@(('service ' + $f[0]), $f[5].ToLower())) } }
    foreach ($l in @($inv.Processes)) { $uses.Add(@('process', ([string]$l).ToLower())) }
    foreach ($l in @($inv.Tasks)) { $f = ([string]$l) -split '\|'; if ($f.Count -ge 6) { $uses.Add(@(('task ' + $f[1]), $f[5].ToLower())) } }
    $text = (@($uses.ToArray() | ForEach-Object { $_[1] })) -join "`n"
    $map = @{}
    foreach ($l in @($inv.Products)) {
        $f = ([string]$l) -split '\|'
        if ($f.Count -lt 5) { continue }
        $loc = $f[4].TrimEnd('\').ToLower()
        if ($loc.Length -lt 8 -or $map.ContainsKey($loc)) { continue }
        $by = ''
        if ($text.Contains($loc)) { $by = 'in use'; foreach ($u in $uses) { if ($u[1].Contains($loc)) { $by = 'in use (' + $u[0] + ')'; break } } }
        $map[$loc] = $by
    }
    $script:UseMapCache[$key] = @{ Ticks = $inv.Checked.Ticks; Map = $map }
    return $map
}

function Get-ProductUse {
    # 'in use (service X)' / 'dormant' / '' for one product row - the same rule as Health check H-SW-01: installed over
    # DormantMonths ago and no service, process or task points into its install folder.
    param($Row)
    $loc = ([string]$Row.Location).TrimEnd('\').ToLower()
    if ($loc.Length -lt 8) { return '' }
    $map = Get-ServerUseMap -Server $Row.Server
    if (-not $map) { return '' }
    $by = $map[$loc]
    if ($by) { return $by }
    $when = [datetime]::MinValue
    if ([datetime]::TryParseExact([string]$Row.Installed, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$when)) {
        if (((Get-Date) - $when).TotalDays / 30.4 -ge $script:Config.DormantMonths) { return 'dormant' }
    }
    return ''
}

function Get-RemovalLeftovers {
    # What still points into a removed product's install folder on one server, from a FRESH inventory: services (their
    # program path) and scheduled tasks (their action).  An uninstaller that does not remove its own service leaves it
    # registered (field case 2026-10-22: an Inno Setup uninstaller left its product's service behind).
    # $null = no install folder known, nothing to look for; an empty list = nothing left behind.
    param([string]$Server, [string]$Location)
    $loc = ([string]$Location).Trim().TrimEnd('\').ToLower()
    if ($loc.Length -lt 8) { return $null }
    $inv = Get-CollectorResult -Name 'Inventory' -Server $Server
    if (-not $inv -or -not $inv.Reachable) { return $null }
    $inside = $loc + '\'   # the folder itself, not a sibling that starts with the same name
    $left = @()
    foreach ($l in @($inv.Services)) { $f = ([string]$l) -split '\|'; if ($f.Count -ge 6 -and $f[5].ToLower().Contains($inside)) { $left += ('service {0} ({1}, {2})' -f $f[0], $f[3], $f[2]) } }
    foreach ($l in @($inv.Tasks)) { $f = ([string]$l) -split '\|'; if ($f.Count -ge 6 -and $f[5].ToLower().Contains($inside)) { $left += ('scheduled task {0}{1}' -f $f[0], $f[1]) } }
    return , @($left)
}

function Get-UninstallVerdict {
    # THE decision "may UNINSTALL remove this product from this server, and how?" - the inventory list's Removal column
    # and the removal plan both call it.  Returns Go, Method ('MSI' / 'quiet string' / ''), Cell, Reason, and MayRestart:
    # a removal never restarts a server where the tool knows the uninstaller's no-restart switch (MSI, Inno Setup, WiX
    # bundles); any other uninstaller may restart it by itself, and the plan says so before anything runs.
    param($Row)
    $why = Get-ProductProtection -Server $Row.Server -Product $Row.Product
    if ($why) { $cell = 'Protected'; if ($why -like 'required by*') { $cell = 'SOE' }; return [pscustomobject]@{ Go = $false; Method = ''; Cell = $cell; Reason = $why; MayRestart = $false } }
    if (-not $Row.PSObject.Properties['KeyName'] -or -not $Row.KeyName) { return [pscustomobject]@{ Go = $false; Method = ''; Cell = 'Check again'; Reason = 'the inventory predates the uninstall details - press Check'; MayRestart = $false } }
    if ([string]$Row.Msi -eq '1' -and [string]$Row.KeyName -match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') { return [pscustomobject]@{ Go = $true; Method = 'MSI'; Cell = 'MSI'; Reason = ('msiexec /x {0} /qn /norestart REBOOT=ReallySuppress - no restart' -f $Row.KeyName); MayRestart = $false } }
    $quiet = [string]$Row.Quiet
    $switches = @{ 'msiexec' = '/norestart REBOOT=ReallySuppress'; 'Inno Setup' = '/NORESTART /SUPPRESSMSGBOXES'; 'WiX bundle' = '/norestart' }
    if ($switches.ContainsKey($quiet)) { return [pscustomobject]@{ Go = $true; Method = 'quiet string'; Cell = 'quiet string'; Reason = ('the product''s own QuietUninstallString ({0} uninstaller), with {1} added - no restart' -f $quiet, $switches[$quiet]); MayRestart = $false } }
    if ($quiet -and $quiet -ne '0') { return [pscustomobject]@{ Go = $true; Method = 'quiet string'; Cell = 'quiet (may restart)'; Reason = 'the product''s own QuietUninstallString - an uninstaller with no known no-restart switch: it MAY RESTART THE SERVER by itself. Remove it by hand in a reboot window if that is not acceptable.'; MayRestart = $true } }
    return [pscustomobject]@{ Go = $false; Method = ''; Cell = 'by hand'; Reason = 'neither an MSI product code nor a QuietUninstallString: remove it by hand (Programs and Features) in a change window'; MayRestart = $false }
}

# ---------------------------------------------------------------------
#  RUNS ON THE SERVER: guards once, then every item checked and queued as a
#  one-shot SYSTEM task in \WinRMToolkit\; the first one is started.  The
#  command line is built here from the catalogue's fields only.
# ---------------------------------------------------------------------
$script:RemoteSoftwareRunScript = {
    param([object[]]$Items, [string]$RunId, [string]$Staging, [string]$Operator, [string]$ChangeText, [int]$MinFreeGB)
    $ErrorActionPreference = 'Stop'
    $taskFolder = '\WinRMToolkit\'
    $swDir = $Staging.TrimEnd('\') + '\software'
    $note = {
        # the server keeps its own change record: one line in C:\PatchStaging\change-log.txt and Application event 910.
        # Change / By: an earlier run's task collected late is filed under ITS change and operator, not this run's
        param([string]$What, [string]$Label, [string]$Result, [string]$Kind, [string]$Change = '', [string]$By = '')
        $chg = $Change; if (-not $chg) { $chg = $ChangeText }
        $who = $By; if (-not $who) { $who = $Operator }
        $line = '{0} | {1} | {2} | change {3} | by {4} | {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $What, $Label, $chg, $who, $Result
        try { Add-Content -LiteralPath ($Staging.TrimEnd('\') + '\change-log.txt') -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('OfflinePatcher')) { New-EventLog -LogName Application -Source 'OfflinePatcher' -ErrorAction Stop }
            Write-EventLog -LogName Application -Source 'OfflinePatcher' -EventId 910 -EntryType $Kind -Message ('WinRM Toolkit software change on {0}: {1}' -f $env:COMPUTERNAME, $line) -ErrorAction Stop
        } catch { }
    }
    $toVersion = { param([string]$Text) $m = [regex]::Match([string]$Text, '\d+(\.\d+)*'); if (-not $m.Success) { return $null }; $p = @($m.Value.Split('.') | Select-Object -First 4); while ($p.Count -lt 4) { $p += '0' }; try { return [version](($p | ForEach-Object { [string][int64]$_ }) -join '.') } catch { return $null } }
    $keys = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    # NO RESTART FROM A REMOVAL: the switches that keep a product's own uninstaller from restarting the server (or from
    # waiting on a message box nobody can answer).  The same block is in RemoteInventoryScript, which tells the operator
    # beforehand; the two must stay the same.  Kind '' = an uninstaller with no known no-restart switch.
    $noRestart = {
        param([string]$UninstallExe, [string]$UninstallArgs)
        $leaf = [System.IO.Path]::GetFileName($UninstallExe)
        if ($leaf -match '(?i)^msiexec(\.exe)?$') { return @{ Kind = 'msiexec'; Add = @('/norestart', 'REBOOT=ReallySuppress') } }
        if ($leaf -match '(?i)^unins\d{3}\.exe$') { return @{ Kind = 'Inno Setup'; Add = @('/NORESTART', '/SUPPRESSMSGBOXES') } }
        if ($UninstallExe -match '(?i)\\Package Cache\\' -and $UninstallArgs -match '(?i)(^|\s)[/-]uninstall(\s|$)') { return @{ Kind = 'WiX bundle'; Add = @('/norestart') } }
        return @{ Kind = ''; Add = @() }
    }

    # ---- guards, once ----
    $guard = ''
    $existing = @()
    $taskReadError = ''
    try { $existing = @(Get-ScheduledTask -TaskPath $taskFolder -ErrorAction Stop) } catch { if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound') { $taskReadError = $_.Exception.Message }; $existing = @() }   # no folder yet = no tasks
    try {
        # the task list could not be read: "nothing running, nothing queued" would be a guess - refuse (R6-C07)
        if ($taskReadError) { throw "the toolkit's tasks could not be read ($taskReadError) - try again" }
        $running = @($existing | Where-Object { [string]$_.State -eq 'Running' })
        if ($running.Count -gt 0) { throw ('a toolkit task is still running here ({0}) - wait for it to finish' -f (($running | ForEach-Object { $_.TaskName }) -join ', ')) }
        # a queue of another run that is less than 3 hours old: another operator (or another window) is still working here
        foreach ($t in @($existing | Where-Object { $_.TaskName -like 'WRT-*' -and $_.TaskName -notlike "$RunId-*" })) {
            $ti = $null; try { $ti = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
            $metaPath = $swDir + '\task-' + $t.TaskName + '.txt'
            $created = $null
            if (Test-Path -LiteralPath $metaPath) { foreach ($l in @(Get-Content -LiteralPath $metaPath)) { if ($l -like 'Created=*') { try { $created = [datetime]::ParseExact($l.Substring(8), 'yyyy-MM-dd HH:mm:ss', $null) } catch { } } } }
            if ($ti -and [int64]$ti.LastTaskResult -eq 267011 -and $created -and ((Get-Date) - $created).TotalHours -lt 3) { throw "another toolkit run is still queued on this server ($($t.TaskName)) - wait for it to finish" }
        }
        $busy = @(Get-Process -Name dism, wusa -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
        $tiw = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
        if ($tiw.Count -gt 0) {
            $cpu1 = 0.0; foreach ($p in $tiw) { try { if ($p.CPU) { $cpu1 += $p.CPU } } catch { } }
            Start-Sleep -Seconds 2
            $cpu2 = 0.0; foreach ($p in @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)) { try { if ($p.CPU) { $cpu2 += $p.CPU } } catch { } }
            if (($cpu2 - $cpu1) -ge 0.25) { $busy += ('TiWorker busy ({0:N1} s CPU in 2 s)' -f ($cpu2 - $cpu1)) }
        }
        try { if ((New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateInstaller().IsBusy) { $busy += 'Windows Update agent installing' } } catch { }
        if ($busy.Count -gt 0) { throw "servicing is running on the server ($($busy -join ', ')) - try again in a few minutes" }
        $msiBusy = $false
        try { $mtx = $null; if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mtx)) { $msiBusy = $true; $mtx.Close() } } catch { $msiBusy = $true }
        if ($msiBusy) { throw 'Windows Installer is busy with another install (Global\_MSIExecute) - try again in a few minutes' }
        $free = [math]::Round((Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'").FreeSpace / 1GB, 1)
        if ($free -lt $MinFreeGB) { throw "only $free GB free on C: (MinFreeGB is $MinFreeGB)" }
        if ($swDir -match '\s') { throw "the staging path '$swDir' contains a space - installer log paths must not" }
    } catch { $guard = $_.Exception.Message }

    # ---- software tasks left by an earlier run (finished, or queued and abandoned): recorded and removed.  Only WRT-*:
    #      the OS patch engine's OSPatch-<stamp> tasks are its own record and its own to remove (R6-C18) ----
    if (-not $guard) {
        foreach ($t in @($existing | Where-Object { $_.TaskName -like 'WRT-*' -and $_.TaskName -notlike "$RunId-*" -and [string]$_.State -ne 'Running' })) {
            $ti = $null; try { $ti = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
            $code = $null; if ($ti) { $code = [int64]$ti.LastTaskResult }
            if ($code -eq 267009) { continue }   # 0x41301 "currently running" while the state says otherwise: still finishing - left alone, as the poll leaves it
            # the task's own record (its item, kind, change and operator from task-<name>.txt): the result file and the server's
            # change line carry THOSE, not this run's change reference
            $meta = @{}; $metaPath = $swDir + '\task-' + $t.TaskName + '.txt'
            if (Test-Path -LiteralPath $metaPath) { foreach ($l in @(Get-Content -LiteralPath $metaPath)) { if ($l -match '^([^=]+)=(.*)$') { $meta[$Matches[1]] = $Matches[2] } } }
            $taskItem = [string]$meta['Item']; if (-not $taskItem) { $taskItem = $t.TaskName }
            $ownChange = [string]$meta['Change']; if (-not $ownChange) { $ownChange = 'unknown (an earlier run)' }
            $ownOperator = [string]$meta['Operator']; if (-not $ownOperator) { $ownOperator = 'unknown' }
            if ($code -eq 267011) { & $note 'Software task removed' $taskItem 'never started (its run ended before its turn) - nothing changed' 'Warning' $ownChange $ownOperator }
            else {
                # finished after its run stopped watching: the result file the poll would have written, so a 3010 stays a pending
                # reboot and the next status check hands the exit code to the toolkit PC's change log (Late=True); dated when the
                # task ran, so a reboot since then clears it like any other
                $ok = ($code -in 0, 3010, 1641); $rebootNeeded = ($code -in 3010, 1641)
                $resultPath = $swDir + '\result-' + $t.TaskName + '.txt'
                try {
                    @("TaskName=$($t.TaskName)", 'Late=True', "Index=$($meta['Index'])", "Kind=$($meta['Kind'])", "Item=$taskItem", "When=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Operator=$ownOperator", "Change=$ownChange", "ExitCode=$code", "Success=$ok", "RebootRequired=$rebootNeeded", "Message=finished after the tool stopped watching, exit $code (collected by a later run)") | Set-Content -LiteralPath $resultPath
                    if ($ti.LastRunTime -and $ti.LastRunTime -gt [datetime]'2000-01-01') { (Get-Item -LiteralPath $resultPath).LastWriteTime = $ti.LastRunTime }
                } catch { }
                & $note 'Software task collected late' $taskItem "finished earlier, exit $code" $(if ($ok) { 'Information' } else { 'Error' }) $ownChange $ownOperator
            }
            try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $taskFolder -Confirm:$false -ErrorAction Stop } catch { }
            Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
        }
    }

    # ---- each item: checked, its command built, queued ----
    $out = @()
    $n = 0
    foreach ($it in @($Items)) {
        $n++
        $r = [ordered]@{ Computer = $env:COMPUTERNAME; Index = $n; Kind = [string]$it.Kind; Item = [string]$it.Label; Accepted = $false; TaskName = ''; Message = '' }
        try {
            if ($guard) { throw $guard }
            $exe = ''; $arg = ''; $mayRestart = $false
            $log = '{0}\sw-{1}-{2:d2}.log' -f $swDir, $RunId, $n
            if ([string]$it.Kind -eq 'install') {
                $file = [string]$it.File
                if (-not (Test-Path -LiteralPath $file)) { throw "staged file not found: $file - stage it first" }
                $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if ($hash -ne [string]$it.Hash) { throw "the staged file's SHA256 differs from the package ($hash) - refusing to run it" }
                $sig = Get-AuthenticodeSignature -LiteralPath $file
                # AllowUnsigned accepts a file without a signature - never one changed after it was signed (R6-C05)
                if ([string]$sig.Status -eq 'HashMismatch') { throw 'signature HashMismatch on the server: the file was changed after it was signed - refusing to run it' }
                if ($null -ne $it.AllowUnsigned -and $it.AllowUnsigned -isnot [bool]) { throw "AllowUnsigned must be true or false (is '$($it.AllowUnsigned)')" }
                if (-not $it.AllowUnsigned) {
                    $subject = ''; if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
                    if ([string]$sig.Status -ne 'Valid') { throw "signature check failed on the server: $($sig.Status)" }
                    # the organisation part(s) of the subject, as Test-SignerAllowed reads them on the operator PC
                    $okSigner = $false; $orgs = @()
                    try { $orgs = @((New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName $subject).Format($true) -split "`r?`n" | Where-Object { $_ -match '^O=' } | ForEach-Object { ($_.Substring(2).Trim() -replace '^"(.*)"$', '$1') }) } catch { $orgs = @() }
                    foreach ($s in @($it.Signers)) { foreach ($o in $orgs) { if ($s -and $o.StartsWith([string]$s, [System.StringComparison]::OrdinalIgnoreCase)) { $okSigner = $true } } }
                    if (-not $okSigner) { throw "signed by '$subject', not by $(@($it.Signers) -join ' / ')" }
                }
                if ($it.Requires) {
                    $make = [string](Get-CimInstance -ClassName Win32_ComputerSystem).Manufacturer
                    if ($make -notlike [string]$it.Requires) { throw "this package needs a '$($it.Requires)' machine; this one is '$make'" }
                }
                $have = ''; $found = $false
                foreach ($root in $keys) {
                    foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object { Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue })) {
                        if ($k.DisplayName -and ([string]$k.DisplayName).Trim() -like [string]$it.Match) { $found = $true; if ($k.DisplayVersion) { $have = [string]$k.DisplayVersion } }
                    }
                }
                $want = & $toVersion ([string]$it.Version)
                # installed is decided on the name: an entry without a DisplayVersion is still an installed copy (R6-C09)
                if ([string]$it.Mode -eq 'Install' -and $found) { throw ("already installed ({0}) - Install is for servers without it" -f $(if ($have) { $have } else { 'no version recorded' })) }
                if ([string]$it.Mode -eq 'Update') {
                    if (-not $found) { throw 'not installed - Update needs it installed' }
                    if (-not $have) { throw 'installed, but its version is not recorded - it cannot be compared; update it by hand' }
                    $now = & $toVersion $have
                    if ($now -and $want -and $now -ge $want) { throw "already at $have" }
                }
                if ([string]$it.Installer -eq 'msi') {
                    $exe = "$env:SystemRoot\System32\msiexec.exe"
                    $arg = ('/i "{0}" /qn /norestart REBOOT=ReallySuppress /l*v "{1}" {2}' -f $file, $log, [string]$it.Arguments).Trim()
                } else {
                    $exe = $file
                    $arg = ([string]$it.Arguments).Replace('{log}', $log).Replace('{file}', $file)
                }
            } elseif ([string]$it.Kind -eq 'uninstall') {
                $keyName = [string]$it.KeyName
                if (-not $keyName -or $keyName -match '[\\/]' -or $keyName -match '\.\.') { throw "not a usable uninstall key name: '$keyName'" }
                # the hive the inventory found it in: one key name can be in both (7-Zip x64 and x86 both use "7-Zip");
                # none named (an older inventory) = the 64-bit hive first, as before
                $roots = $keys
                if ([string]$it.Hive -eq '64') { $roots = @($keys[0]) } elseif ([string]$it.Hive -eq '32') { $roots = @($keys[1]) } elseif ([string]$it.Hive) { throw "not a usable hive: '$($it.Hive)'" }
                $k = $null
                foreach ($root in $roots) { $k = Get-ItemProperty -LiteralPath ($root + '\' + $keyName) -ErrorAction SilentlyContinue; if ($k) { break } }
                if (-not $k) { throw 'not installed any more (its uninstall key is gone)' }
                $shown = ([string]$k.DisplayName).Trim() -replace '\|', '/'
                if ($shown -ne [string]$it.Name) { throw "the uninstall key now belongs to '$shown', not '$($it.Name)' - refusing" }
                if ([int]$k.WindowsInstaller -eq 1 -and $keyName -match '^\{[0-9A-Fa-f]{8}-([0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}\}$') {
                    $exe = "$env:SystemRoot\System32\msiexec.exe"
                    $arg = '/x {0} /qn /norestart REBOOT=ReallySuppress /l*v "{1}"' -f $keyName, $log
                } elseif ($k.QuietUninstallString) {
                    $q = [string]$k.QuietUninstallString
                    if ($q -match '^\s*"([^"]+)"\s*(.*)$') { $exe = $Matches[1]; $arg = $Matches[2] }
                    elseif ($q -match '^\s*(.+?\.exe)(\s+(.*))?$') { $exe = $Matches[1]; $arg = [string]$Matches[3] }
                    else { throw "cannot read the QuietUninstallString: $q" }
                    if ($exe -match '(?i)^msiexec(\.exe)?$') { $exe = "$env:SystemRoot\System32\msiexec.exe" }
                    # a removal never restarts the server: the uninstaller's own no-restart switches, where it has known ones
                    # (the reboot is the operator's separate step, under its own change record)
                    $rule = & $noRestart $exe $arg
                    # a switch of the opposite meaning already in the string (REBOOT=Force, /forcerestart, /promptrestart) goes first
                    if ($rule.Kind) { $arg = (($arg -replace '(?i)(^|\s)REBOOT=\S+', ' ') -replace '(?i)(^|\s)/(forcerestart|promptrestart|restart)(\s|$)', ' ').Trim() -replace '\s{2,}', ' ' }
                    foreach ($sw in @($rule.Add)) { if ($arg -notmatch ('(?i)(^|\s)' + [regex]::Escape(($sw -split '=')[0]))) { $arg = ($arg + ' ' + $sw).Trim() } }
                    if (-not (Test-Path -LiteralPath $exe)) { throw "the uninstaller named in QuietUninstallString is missing: $exe" }
                    if (-not $rule.Kind) { $mayRestart = $true }
                } else { throw 'no silent uninstall (neither an MSI product code nor a QuietUninstallString)' }
            } else { throw "unknown item kind '$($it.Kind)'" }

            # ---- queue it: a one-shot SYSTEM task, not started yet (the poll starts the items one at a time) ----
            if (-not (Test-Path -LiteralPath $swDir)) { New-Item -ItemType Directory -Path $swDir -Force | Out-Null }
            $name = '{0}-{1:d2}' -f $RunId, $n
            $desc = ('WinRM Toolkit {0}: {1} | change {2} | by {3}' -f $it.Kind, $it.Label, $ChangeText, $Operator)
            if ($desc.Length -gt 900) { $desc = $desc.Substring(0, 900) }
            $action = New-ScheduledTaskAction -Execute $exe -Argument $arg
            $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskName $name -TaskPath $taskFolder -Action $action -Principal $principal -Settings $settings -Description $desc -Force | Out-Null
            @("Created=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "RunId=$RunId", "Index=$n", "Kind=$($it.Kind)", "Item=$($it.Label)", "Log=$log", "File=$($it.File)", "Change=$ChangeText", "Operator=$Operator", "Command=$exe $arg") | Set-Content -LiteralPath ($swDir + '\task-' + $name + '.txt')
            $r.Accepted = $true; $r.TaskName = $name; $r.Message = "queued as task $taskFolder$name : $exe $arg"
            if ($mayRestart) { $r.Message += '  (an uninstaller with no known no-restart switch: it may restart the server by itself)' }
            & $note ('Software ' + $it.Mode) $it.Label 'START (queued)' 'Information'
        } catch { $r.Message = $_.Exception.Message }
        $out += [pscustomobject]$r
    }
    $first = @($out | Where-Object { $_.Accepted }) | Select-Object -First 1
    if ($first) {
        # the tasks exist whatever happens here: a start that fails is reported, and the next poll starts the first queued item
        try { Start-ScheduledTask -TaskPath $taskFolder -TaskName $first.TaskName -ErrorAction Stop } catch { $first.Message += ('  (queued; the first start failed: {0} - the next poll starts it)' -f $_.Exception.Message) }
    }
    return $out
}

# ---------------------------------------------------------------------
#  RUNS ON THE SERVER, every SoftwarePollSec: the state of each task of one
#  run.  A finished task is recorded on the server (result file, event 910,
#  change-log.txt) and removed; then the next queued one is started.
#  -AbandonQueued (the run timed out) removes the tasks that never started.
# ---------------------------------------------------------------------
$script:RemoteSoftwarePollScript = {
    param([string]$RunId, [string]$Staging, [string]$Operator, [string]$ChangeText, [bool]$Cleanup, [bool]$AbandonQueued)
    $ErrorActionPreference = 'Stop'
    $taskFolder = '\WinRMToolkit\'
    $swDir = $Staging.TrimEnd('\') + '\software'
    $note = {
        param([string]$What, [string]$Label, [string]$Result, [string]$Kind)
        $line = '{0} | {1} | {2} | change {3} | by {4} | {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $What, $Label, $ChangeText, $Operator, $Result
        try { Add-Content -LiteralPath ($Staging.TrimEnd('\') + '\change-log.txt') -Value $line -Encoding UTF8 -ErrorAction Stop } catch { }
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('OfflinePatcher')) { New-EventLog -LogName Application -Source 'OfflinePatcher' -ErrorAction Stop }
            Write-EventLog -LogName Application -Source 'OfflinePatcher' -EventId 910 -EntryType $Kind -Message ('WinRM Toolkit software change on {0}: {1}' -f $env:COMPUTERNAME, $line) -ErrorAction Stop
        } catch { }
    }
    $explain = @{ 0 = 'OK'; 3010 = 'OK - reboot required (3010): suppressed, take it with the OS patches'; 1641 = 'OK, BUT the installer started a restart itself (1641) - the no-restart switches did not hold: the server is rebooting now'
        1602 = 'cancelled (1602)'; 1603 = 'fatal error during installation (1603) - see the log'; 1605 = 'not installed (1605)'; 1618 = 'another installation was in progress (1618) - run it again'
        1619 = 'the package could not be opened (1619)'; 1625 = 'blocked by policy (1625)'; 1633 = 'wrong platform for this package (1633)'; 1638 = 'another version is already installed (1638)'
        1639 = 'invalid command line (1639) - check the arguments in software-packages.psd1'; 267014 = 'the task was stopped after its 2-hour limit (0x41306)' }
    $tasks = @()
    # the Task Scheduler not answering is NOT "no tasks": the poll must fail (and be asked again), or every queued item
    # would be reported gone and never started.  Only a missing task folder is an empty list.
    try { $tasks = @(Get-ScheduledTask -TaskPath $taskFolder -ErrorAction Stop | Where-Object { $_.TaskName -like "$RunId-*" } | Sort-Object TaskName) }
    catch { if ([string]$_.CategoryInfo.Category -eq 'ObjectNotFound') { $tasks = @() } else { throw ('the Task Scheduler did not answer: ' + $_.Exception.Message) } }
    $out = @(); $anyRunning = $false; $queued = @()
    foreach ($t in $tasks) {
        $meta = @{}
        $metaPath = $swDir + '\task-' + $t.TaskName + '.txt'
        if (Test-Path -LiteralPath $metaPath) { foreach ($l in @(Get-Content -LiteralPath $metaPath)) { if ($l -match '^([^=]+)=(.*)$') { $meta[$Matches[1]] = $Matches[2] } } }
        $ti = $null; try { $ti = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { }
        $code = $null; if ($ti) { $code = [int64]$ti.LastTaskResult }
        $state = 'Done'
        if ([string]$t.State -eq 'Running') { $state = 'Running'; $anyRunning = $true }
        elseif ($null -eq $code) { $state = 'Unread'; $anyRunning = $true }   # its state could not be read this time: nothing else is started on a guess
        elseif ($code -eq 267009) { $state = 'Running'; $anyRunning = $true }  # 0x41301 "currently running" while the state says otherwise: finishing
        elseif ($code -eq 267011) { $state = 'Queued' }                      # 0x41303 never run
        $r = [ordered]@{ Computer = $env:COMPUTERNAME; TaskName = $t.TaskName; Index = [int]$meta['Index']; Kind = [string]$meta['Kind']; Item = [string]$meta['Item']; State = $state; ExitCode = $null; Success = $false; RebootRequired = $false; Message = ''; LogTail = @() }
        if ($state -eq 'Unread') { $r.Message = 'task state could not be read - asking again' }
        elseif ($state -eq 'Running') {
            $r.Message = 'running'
            if ($ti -and $ti.LastRunTime) { $r.Message = 'running for {0:N0} min' -f ((Get-Date) - $ti.LastRunTime).TotalMinutes }
            if ($meta['Log'] -and (Test-Path -LiteralPath $meta['Log'])) { $r.Message += (', log {0:N0} KB' -f ((Get-Item -LiteralPath $meta['Log']).Length / 1KB)) }
        } elseif ($state -eq 'Done') {
            $r.ExitCode = $code
            $r.Success = ($code -in 0, 3010, 1641)
            $r.RebootRequired = ($code -in 3010, 1641)
            if ($code -ge -2147483648 -and $code -le 2147483647) { $r.Message = $explain[[int]$code] }   # the table's keys are Int32; a uint32 HRESULT is not in it
            if (-not $r.Message) { $r.Message = 'exit {0} (0x{1:X8})' -f $code, ($code -band 0xFFFFFFFF) }
            if (-not $r.Success) { $r.Message = 'FAILED: ' + $r.Message }
            if ($meta['Log'] -and (Test-Path -LiteralPath $meta['Log'])) {
                if (-not $r.Success) { $r.LogTail = @(Get-Content -LiteralPath $meta['Log'] -Tail 400 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'error|failed|Return value 3' } | Select-Object -Last 8) }
                $r.Message += ' (log ' + $meta['Log'] + ')'
            }
            $resultPath = $swDir + '\result-' + $t.TaskName + '.txt'
            try { (@("TaskName=$($t.TaskName)", "Index=$($r.Index)", "Kind=$($r.Kind)", "Item=$($r.Item)", "When=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Operator=$Operator", "Change=$ChangeText", "ExitCode=$code", "Success=$($r.Success)", "RebootRequired=$($r.RebootRequired)", "Message=$($r.Message)") + @($r.LogTail | ForEach-Object { "Log=$_" })) | Set-Content -LiteralPath $resultPath } catch { }
            $kindOfEntry = 'Information'; if (-not $r.Success -or $code -eq 1641) { $kindOfEntry = 'Error' }   # 1641: the installer is restarting the server by itself - that is an error event, whatever the product did
            & $note ('Software ' + $r.Kind) $r.Item ('RESULT ' + $r.Message) $kindOfEntry
            try { Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $taskFolder -Confirm:$false -ErrorAction Stop } catch { }
            Remove-Item -LiteralPath $metaPath -Force -ErrorAction SilentlyContinue
            if ($Cleanup -and $r.Success -and $meta['File'] -and (Test-Path -LiteralPath $meta['File'])) {
                $stillNeeded = $false
                foreach ($other in $tasks) { if ($other.TaskName -ne $t.TaskName -and (Test-Path -LiteralPath ($swDir + '\task-' + $other.TaskName + '.txt'))) { if (@(Get-Content -LiteralPath ($swDir + '\task-' + $other.TaskName + '.txt')) -contains ('File=' + $meta['File'])) { $stillNeeded = $true } } }
                if (-not $stillNeeded) { Remove-Item -LiteralPath $meta['File'] -Force -ErrorAction SilentlyContinue }
            }
        } else { $queued += $t }
        $out += [pscustomobject]$r
    }
    if ($AbandonQueued) {
        foreach ($q in $queued) {
            try { Unregister-ScheduledTask -TaskName $q.TaskName -TaskPath $taskFolder -Confirm:$false -ErrorAction Stop } catch { }
            $row = @($out | Where-Object { $_.TaskName -eq $q.TaskName })[0]
            $row.State = 'Abandoned'; $row.Message = 'NOT STARTED - the run timed out before its turn; nothing was changed for this item'
            & $note ('Software ' + $row.Kind) $row.Item $row.Message 'Warning'
            Remove-Item -LiteralPath ($swDir + '\task-' + $q.TaskName + '.txt') -Force -ErrorAction SilentlyContinue
        }
    } elseif (-not $anyRunning -and $queued.Count -gt 0) {
        # the next item - not while any other MSI install holds the Windows Installer mutex
        $msiBusy = $false
        try { $mtx = $null; if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mtx)) { $msiBusy = $true; $mtx.Close() } } catch { $msiBusy = $true }
        $row = @($out | Where-Object { $_.TaskName -eq $queued[0].TaskName })[0]
        if ($msiBusy) { $row.Message = 'waiting: Windows Installer is busy' }
        else { Start-ScheduledTask -TaskPath $taskFolder -TaskName $queued[0].TaskName; $row.State = 'Running'; $row.Message = 'started' }
    }
    # results written by an earlier poll whose answer never arrived (the connection dropped at that moment)
    foreach ($f in @(Get-ChildItem -LiteralPath $swDir -Filter "result-$RunId-*.txt" -ErrorAction SilentlyContinue)) {
        $tn = $f.BaseName.Substring(7)
        if (@($out | Where-Object { $_.TaskName -eq $tn }).Count -gt 0) { continue }
        $h = @{}; $tail = @()
        foreach ($l in @(Get-Content -LiteralPath $f.FullName)) { if ($l -match '^Log=(.*)$') { $tail += $Matches[1] } elseif ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
        $out += [pscustomobject]@{ Computer = $env:COMPUTERNAME; TaskName = $tn; Index = [int]$h['Index']; Kind = [string]$h['Kind']; Item = [string]$h['Item']; State = 'Done'; ExitCode = $h['ExitCode']; Success = ($h['Success'] -eq 'True'); RebootRequired = ($h['RebootRequired'] -eq 'True'); Message = [string]$h['Message']; LogTail = $tail }
    }
    return $out
}

# ---------------------------------------------------------------------
#  The runs (operator side)
# ---------------------------------------------------------------------
function New-SoftwareResult {
    param([string]$Server, [string]$Item, [string]$Kind, [bool]$Success, [string]$Message, [bool]$RebootRequired = $false, $ExitCode = $null)
    return [pscustomobject]@{ Server = $Server; Item = $Item; Kind = $Kind; Success = $Success; RebootRequired = $RebootRequired; ExitCode = $ExitCode; Message = $Message }
}

function Open-SoftwareSession {
    # A session with the staging folder and its software sub-folder locked down (RemoteStagingScript: admin-owned, SYSTEM + Administrators only).
    # A local session (this computer, no WinRM call to itself) when the server is the toolkit PC: New-ToolkitSession.
    param([string]$Server)
    $sess = New-ToolkitSession -ComputerName $Server
    try {
        foreach ($folder in @($script:Config.RemoteStaging, ($script:Config.RemoteStaging.TrimEnd('\') + '\software'))) {
            $ready = Invoke-RemoteBlock -Session $sess -ScriptBlock $script:RemoteStagingScript -ArgumentList $folder
            Write-PatchLog "$Server - $ready" 'INFO'
        }
    } catch { Close-ToolkitSession -Session $sess; throw }
    return $sess
}

function Get-SoftwareRunArguments {
    # The argument list of RemoteSoftwareRunScript, built in ONE place so every caller sends exactly the same list.
    # Every value is computed here as an expression: written straight into a command's argument list, [int]$x.Y is not a
    # cast but text ("[int]System.Collections.Hashtable.MinFreeGB") - the field failure of 2026-10-21.
    param([object[]]$Items, [string]$RunId, [string]$Operator, [string]$ChangeText)
    return , @([object[]]$Items, $RunId, [string]$script:Config.RemoteStaging, $Operator, $ChangeText, [int]$script:Config.MinFreeGB)
}

function Get-SoftwarePollArguments {
    # The argument list of RemoteSoftwarePollScript (see Get-SoftwareRunArguments).
    param([string]$RunId, [string]$Operator, [string]$ChangeText, [bool]$Abandon = $false)
    return , @($RunId, [string]$script:Config.RemoteStaging, $Operator, $ChangeText, [bool]$script:Config.CleanupStaging, $Abandon)
}

function Invoke-SoftwarePoll {
    # One poll of one server; reconnects a dropped session.  $null = no answer this round (the tasks carry on there).
    param([string]$Server, [hashtable]$Sessions, [string]$RunId, [string]$ChangeText, [string]$Operator, [switch]$Abandon)
    if (-not $script:SoftwarePollFails) { $script:SoftwarePollFails = @{} }
    $sess = $Sessions[$Server]
    try {
        if (-not $sess -or [string]$sess.State -ne 'Opened') {
            Close-ToolkitSession -Session $sess
            $sess = New-ToolkitSession -ComputerName $Server
            $Sessions[$Server] = $sess
            Write-PatchLog "$Server - reconnected" 'INFO'
        }
        $pollArgs = Get-SoftwarePollArguments -RunId $RunId -Operator $Operator -ChangeText $ChangeText -Abandon ([bool]$Abandon)
        $rows = @(Invoke-RemoteBlock -Session $sess -ScriptBlock $script:RemoteSoftwarePollScript -ArgumentList $pollArgs | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['TaskName'] })
        $script:SoftwarePollFails[$Server] = 0
        return , $rows
    } catch {
        $fails = 1 + [int]$script:SoftwarePollFails[$Server]; $script:SoftwarePollFails[$Server] = $fails
        if ($fails -eq 1 -or $fails % 20 -eq 0) { Write-PatchLog ("{0} - no answer ({1}); the task carries on there - asking again (attempt {2})" -f $Server, (Get-ShortError $_), $fails) 'WARN' }
        Close-ToolkitSession -Session $sess
        $Sessions[$Server] = $null
        return $null
    }
}

function Invoke-SoftwareRun {
    # The second half of an install and a removal: per server the run script (guards, items queued as SYSTEM tasks, the
    # first started), then polls until every item has a result or SoftwareTimeoutMin has passed.  Each result goes to the
    # log and to changes\change-log.csv; the server records it itself (event 910, change-log.txt).
    param([hashtable]$Sessions, [hashtable]$ItemsByServer, $Change, [string]$Action)
    $who = Get-OperatorIdentity
    $changeText = Format-ChangeText $Change
    $runId = 'WRT-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $results = New-Object System.Collections.Generic.List[object]
    $waiting = @{}
    $absorb = {
        # one poll row -> a result (once per task)
        param([string]$Srv, $Hit)
        if (-not $waiting[$Srv].ContainsKey($Hit.TaskName)) { return }
        $waiting[$Srv].Remove($Hit.TaskName)
        $lvl = 'ERROR'; if ($Hit.Success) { $lvl = 'OK' } elseif ($Hit.State -eq 'Abandoned') { $lvl = 'WARN' }
        if ($Hit.ExitCode -eq 1641) { $lvl = 'WARN' }   # the product went in, but the installer is restarting the server by itself
        Write-PatchLog ("RESULT {0}  {1}  exit {2}  -> {3}   (by {4})" -f $Srv, $Hit.Item, $Hit.ExitCode, $Hit.Message, $who) $lvl
        foreach ($d in @($Hit.LogTail)) { Write-PatchLog "    $d" 'CMD' }
        $results.Add((New-SoftwareResult -Server $Srv -Item $Hit.Item -Kind $Hit.Kind -Success ([bool]$Hit.Success) -Message $Hit.Message -RebootRequired ([bool]$Hit.RebootRequired) -ExitCode $Hit.ExitCode))
        Write-ChangeLog -Record $Change -Server $Srv -Action $Action -Item $Hit.Item -Result $Hit.Message
    }
    foreach ($c in @($ItemsByServer.Keys)) {
        $list = [object[]]@($ItemsByServer[$c])
        $waiting[$c] = @{}
        try {
            Write-PatchLog ("Invoke-Command -Session [{0}] (RemoteSoftwareRunScript run {1}: guards, {2} item(s) queued as SYSTEM tasks in \WinRMToolkit\, the first started)" -f $c, $runId, $list.Count) 'CMD'
            $runArgs = Get-SoftwareRunArguments -Items $list -RunId $runId -Operator $who -ChangeText $changeText
            $rows = @(Invoke-RemoteBlock -Session $Sessions[$c] -ScriptBlock $script:RemoteSoftwareRunScript -ArgumentList $runArgs | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Accepted'] })
            foreach ($r in $rows) {
                if ($r.Accepted) { $waiting[$c][$r.TaskName] = $r.Item; Write-PatchLog ("{0} - {1}: {2}" -f $c, $r.Item, $r.Message) 'INFO' }
                else {
                    $msg = 'refused on the server: ' + $r.Message
                    Write-PatchLog "RESULT $c  $($r.Item)  -> $msg" 'ERROR'
                    $results.Add((New-SoftwareResult -Server $c -Item $r.Item -Kind $r.Kind -Success $false -Message $msg))
                    Write-ChangeLog -Record $Change -Server $c -Action $Action -Item $r.Item -Result $msg
                }
            }
        } catch {
            $err = Get-ShortError $_
            # the answer may be lost AFTER the tasks were queued and the first one started (a dropped session): the server is
            # asked once for this run's tasks before anything is recorded as "could not start" (R6-C17)
            $seen = @(Invoke-SoftwarePoll -Server $c -Sessions $Sessions -RunId $runId -ChangeText $changeText -Operator $who | Where-Object { $_ -and $_.TaskName })
            if ($seen.Count -gt 0) {
                Write-PatchLog ("{0} - the run call lost its answer ({1}), but the server holds {2} task(s) of run {3}: they are followed like the rest" -f $c, $err, $seen.Count, $runId) 'WARN'
                foreach ($row in $seen) { $waiting[$c][[string]$row.TaskName] = [string]$row.Item }
                foreach ($row in $seen) { if ($row.State -in 'Done', 'Abandoned') { & $absorb $c $row } }
                continue
            }
            $msg = 'could not start: ' + $err
            Write-PatchLog "$c - $msg" 'ERROR'
            foreach ($it in $list) { $results.Add((New-SoftwareResult -Server $c -Item $it.Label -Kind $it.Kind -Success $false -Message $msg)); Write-ChangeLog -Record $Change -Server $c -Action $Action -Item $it.Label -Result $msg }
        }
    }
    $open = @($waiting.Keys | Where-Object { $waiting[$_].Count -gt 0 })
    if ($open.Count -gt 0) { Write-PatchLog ("{0} server(s) working; each item runs as a task on the server, one at a time. The tool asks every {1} s and records each result as it arrives. Leave this window open (read-only buttons still work)." -f $open.Count, $script:Config.SoftwarePollSec) 'WHY' }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPoll = -1000; $lastSummary = 0
    $lastState = @{}   # "server|task" -> the state the last answered poll reported, so a timeout can tell "still running" from "never started"
    while (@($waiting.Keys | Where-Object { $waiting[$_].Count -gt 0 }).Count -gt 0 -and $watch.Elapsed.TotalMinutes -lt $script:Config.SoftwareTimeoutMin) {
        $busy = @($waiting.Keys | Where-Object { $waiting[$_].Count -gt 0 })
        $shown = ($busy | Select-Object -First 6) -join ', '; if ($busy.Count -gt 6) { $shown += ' ...' }
        Set-GuiStatus ('{0}: {1} server(s) working [{2}] ... {3} min {4} s' -f $Action, $busy.Count, $shown, [int][math]::Floor($watch.Elapsed.TotalMinutes), $watch.Elapsed.Seconds)
        if ($watch.Elapsed.TotalSeconds - $lastPoll -ge $script:Config.SoftwarePollSec) {
            $lastPoll = $watch.Elapsed.TotalSeconds
            $states = @{}
            foreach ($c in $busy) {
                $rows = Invoke-SoftwarePoll -Server $c -Sessions $Sessions -RunId $runId -ChangeText $changeText -Operator $who
                if ($null -eq $rows) { $states['no answer'] = 1 + [int]$states['no answer']; continue }
                foreach ($row in $rows) {
                    if ($row.State -in 'Done', 'Abandoned') { & $absorb $c $row } else { $states[$row.State] = 1 + [int]$states[$row.State]; $lastState[$c + '|' + $row.TaskName] = [string]$row.State }
                }
                # a task the server no longer knows and no result file for it: say so rather than wait for ever
                $known = @($rows | ForEach-Object { $_.TaskName })
                foreach ($tn in @($waiting[$c].Keys | Where-Object { $known -notcontains $_ })) {
                    $msg = "UNKNOWN - the server lists its toolkit tasks but not $tn, and no result file was left (removed by hand?). Check Application event 910 and C:\PatchStaging\change-log.txt there"
                    & $absorb $c ([pscustomobject]@{ TaskName = $tn; Item = $waiting[$c][$tn]; Kind = ''; State = 'Done'; ExitCode = $null; Success = $false; RebootRequired = $false; Message = $msg; LogTail = @() })
                }
            }
            if ($watch.Elapsed.TotalSeconds - $lastSummary -ge 120 -and $states.Count -gt 0) {
                $lastSummary = $watch.Elapsed.TotalSeconds
                Write-PatchLog ('{0} min: {1}; {2} result(s) so far' -f [int]$watch.Elapsed.TotalMinutes, (($states.Keys | Sort-Object | ForEach-Object { "$($states[$_]) $_" }) -join ', '), $results.Count) 'INFO'
            }
        }
        Start-Sleep -Milliseconds 400
    }
    # out of time: queued items are withdrawn (nothing changed for them); a running one carries on and is reported UNKNOWN
    foreach ($c in @($waiting.Keys | Where-Object { $waiting[$_].Count -gt 0 })) {
        # the abandon poll removes the queued tasks on the server; a server that does not answer keeps them, and a queued task
        # less than 3 hours old refuses the next run there - so this poll is tried three times, and the message says what is left
        $rows = $null
        for ($attempt = 1; $attempt -le 3 -and $null -eq $rows; $attempt++) { $rows = Invoke-SoftwarePoll -Server $c -Sessions $Sessions -RunId $runId -ChangeText $changeText -Operator $who -Abandon; if ($null -eq $rows -and $attempt -lt 3) { Start-Sleep -Seconds 5 } }
        $withdrawn = ($null -ne $rows)
        if ($rows) { foreach ($row in $rows) { if ($row.State -in 'Done', 'Abandoned') { & $absorb $c $row } } }
        foreach ($tn in @($waiting[$c].Keys)) {
            if ([string]$lastState[$c + '|' + $tn] -eq 'Queued') {
                # it was still waiting its turn when time ran out: nothing started it, and nothing will
                $left = $(if ($withdrawn) { 'task \WinRMToolkit\{0} is withdrawn' -f $tn } else { "the server did not answer, so task \WinRMToolkit\{0} is still queued there: a new software run on this server is refused for up to 3 hours unless the task is removed (Commands tab: Unregister-ScheduledTask -TaskPath '\WinRMToolkit\' -TaskName '{0}' -Confirm:`$false)" -f $tn })
                & $absorb $c ([pscustomobject]@{ TaskName = $tn; Item = $waiting[$c][$tn]; Kind = ''; State = 'Abandoned'; ExitCode = $null; Success = $false; RebootRequired = $false; Message = ("not started - still queued behind an item that had not finished after {0} min; nothing changed on the server ({1})" -f $script:Config.SoftwareTimeoutMin, $left); LogTail = @() })
                continue
            }
            $msg = ("UNKNOWN - still running after {0} min. It carries on as task \WinRMToolkit\{1} on the server: once it has finished, Check adds its result to this change log (an exit 3010 shows as a pending reboot), and the next software run on that server records it there (event 910, {2}\change-log.txt)" -f $script:Config.SoftwareTimeoutMin, $tn, $script:Config.RemoteStaging)
            & $absorb $c ([pscustomobject]@{ TaskName = $tn; Item = $waiting[$c][$tn]; Kind = ''; State = 'Done'; ExitCode = $null; Success = $false; RebootRequired = $false; Message = $msg; LogTail = @() })
        }
    }
    return @($results.ToArray())
}

function Get-SoftwareExitText {
    # An installer's exit code in words; a failure starts with FAILED:.  The same table as RemoteSoftwarePollScript's
    # $explain - the two must stay the same.
    param([int64]$Code)
    $explain = @{ 0 = 'OK'; 3010 = 'OK - reboot required (3010): suppressed, take it with the OS patches'; 1641 = 'OK, BUT the installer started a restart itself (1641) - the no-restart switches did not hold: the server is rebooting now'
        1602 = 'cancelled (1602)'; 1603 = 'fatal error during installation (1603) - see the log'; 1605 = 'not installed (1605)'; 1618 = 'another installation was in progress (1618) - run it again'
        1619 = 'the package could not be opened (1619)'; 1625 = 'blocked by policy (1625)'; 1633 = 'wrong platform for this package (1633)'; 1638 = 'another version is already installed (1638)'
        1639 = 'invalid command line (1639) - check the arguments in software-packages.psd1'; 267014 = 'the task was stopped after its 2-hour limit (0x41306)' }
    $text = ''
    if ($Code -ge [int]::MinValue -and $Code -le [int]::MaxValue) { $text = $explain[[int]$Code] }
    if (-not $text) { $text = 'exit {0} (0x{1:X8})' -f $Code, ($Code -band 0xFFFFFFFF) }
    if ($Code -notin 0, 3010, 1641) { $text = 'FAILED: ' + $text }
    return $text
}

function Update-SoftwareLateResults {
    # After a status check (Get-ServerStatus): an item the tool stopped waiting for (SoftwareTimeoutMin) is "UNKNOWN - still
    # running" in changes\change-log.csv.  When the server reports its task finished (SoftwareLate: no result file yet - the
    # next software run on that server collects it there), the real result is added to the change log on this PC, only
    # while the newest row for that item on that server is still that UNKNOWN - so once.  Nothing is written on the server.
    param([string[]]$Servers)
    foreach ($s in @($Servers)) {
        $st = $script:ServerStatus[$s]
        if (-not $st -or -not $st.Reachable -or -not $st.PSObject.Properties['SoftwareLate']) { continue }
        $late = @($st.SoftwareLate | Where-Object { $_ })
        if ($late.Count -eq 0) { continue }
        $rows = @(Get-ChangeLogRows -Server $s)   # newest first
        foreach ($line in $late) {
            $f = [string]$line -split '\|'
            if ($f.Count -lt 2 -or $f[1] -notmatch '^-?\d+$') { continue }
            $marker = ' \WinRMToolkit\' + $f[0] + ' '
            $unknown = @($rows | Where-Object { ([string]$_.Result).StartsWith('UNKNOWN - still running') -and ([string]$_.Result).Contains($marker) })[0]
            if (-not $unknown) { continue }
            $newest = @($rows | Where-Object { $_.Action -eq $unknown.Action -and $_.Item -eq $unknown.Item })[0]
            if (-not [object]::ReferenceEquals($newest, $unknown)) { continue }   # recorded already, or the item has a newer row
            $code = [int64]$f[1]
            $text = (Get-SoftwareExitText -Code $code) + ' - finished after the tool stopped watching (read at a status check)'
            $lvl = 'ERROR'; if ($code -in 0, 3010) { $lvl = 'OK' } elseif ($code -eq 1641) { $lvl = 'WARN' }
            Write-PatchLog ("RESULT {0}  {1}  exit {2}  -> {3}" -f $unknown.Server, $unknown.Item, $code, $text) $lvl
            $record = [pscustomobject]@{ Ref = $unknown.ChangeRef; System = $unknown.ChangeSystem; ApprovedBy = $unknown.ApprovedBy; Window = $unknown.Window; Notes = $unknown.Notes; Recorded = $true }
            Write-ChangeLog -Record $record -Server $unknown.Server -Action $unknown.Action -Item $unknown.Item -Result $text -Operator ([string]$unknown.Operator)   # the run's operator, not whoever pressed Check
        }
    }
}

function New-SoftwarePlan {
    # One row per (server, installer file): Go, Mode, From, Reason - from Get-SoftwareVerdict, so the plan never differs from the grid.
    param([string[]]$ComputerName, [object[]]$Files)
    $plan = New-Object System.Collections.Generic.List[object]   # 500 servers x 20 files: never += in a loop
    foreach ($c in $ComputerName) {
        foreach ($f in $Files) {
            $v = Get-SoftwareVerdict -Server $c -PackageFile $f
            $plan.Add([pscustomobject]@{ Computer = $c; Id = $f.Id; Name = $f.Name; Version = $f.Version; From = $v.Installed; File = $f; Mode = $v.Mode; Go = $v.Go; Staged = $v.Staged; Reason = $v.Reason; Cell = $v.Cell })
        }
    }
    return @($plan.ToArray())
}

function Format-SoftwarePlan {
    param([object[]]$Plan)
    return (($Plan | ForEach-Object {
        $what = 'skip'; if ($_.Go) { $what = $_.Mode }
        $from = $_.From; if (-not $from) { $from = '-' }
        '{0,-34} {1,-14} {2,-8} {3} -> {4}   {5}' -f $_.Computer, $_.Id, $what, $from, $_.Version, $_.Reason
    }) -join "`n")
}

function Install-SoftwareOnServers {
    # INSTALL / UPDATE, and STAGE ONLY with -StageOnly.  The steps of PATCH IT!: fresh facts, the plan, the change record,
    # the pre-action confirmations, a re-check; then per server the locked staging folder, the verified copy and the run.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName, [Parameter(Mandatory = $true)][object[]]$Files, [switch]$StageOnly)
    $action = 'Software install'; if ($StageOnly) { $action = 'Software stage' }
    $targets = @(Get-UniqueNames $ComputerName)
    $twice = @($Files | Group-Object Id | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
    if ($twice.Count -gt 0) { $null = Show-PatcherMessage -Text ("Tick one version per package - more than one is ticked for: {0}" -f ($twice -join ', ')) -Icon 'Warning'; return @() }
    $blocked = @($Files | Where-Object { $_.Blocked })
    if ($blocked.Count -gt 0) { $null = Show-PatcherMessage -Text ("These files are blocked and cannot be used:`n`n{0}" -f (($blocked | ForEach-Object { "$($_.File): $($_.Blocked)" }) -join "`n")) -Icon 'Warning'; return @() }
    $who = Get-OperatorIdentity
    Write-PatchLog ("=== {0} REQUESTED by {1}: {2} on {3} ===" -f $action.ToUpper(), $who, (($Files | ForEach-Object { "$($_.Id) $($_.Version)" }) -join ', '), ($targets -join ', ')) 'INFO'
    Write-PatchLog 'Pre-flight: fresh status, inventory and software state, so the plan is built on what the servers say now' 'WHY'
    Update-SoftwareFacts -ComputerName $targets
    $who = Get-OperatorIdentity
    $targets = @(Remove-DuplicateServers $targets)
    $plan = @(New-SoftwarePlan -ComputerName $targets -Files $Files)
    foreach ($p in $plan) { $lvl = 'WARN'; if ($p.Go) { $lvl = 'INFO' }; Write-PatchLog ("Plan: {0}  {1} {2}  -> {3}" -f $p.Computer, $p.Id, $p.Version, $p.Cell) $lvl }
    $todo = @($plan | Where-Object { $_.Go })
    if ($todo.Count -eq 0) { $null = Show-PatcherMessage -Text 'Nothing to do - every server is current, not applicable, blocked or unreachable. The log has the reason per server.' -Title 'Nothing to do'; return @() }
    $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
    $how = "Each installer is copied to $($script:Config.RemoteStaging)\software (SHA256 verified), then run on the server as a one-shot SYSTEM task, one item at a time, with the reboot suppressed. Exit 3010 = a reboot completes it: take it with the OS patches (Reboot (ticked))."
    foreach ($g in @($todo | Group-Object Id)) { $note = [string]$g.Group[0].File.Package.Note; if ($note) { $how += "`n" + $g.Group[0].Name + ': ' + $note } }
    if ($StageOnly) { $how = "STAGE ONLY: the installers are copied to $($script:Config.RemoteStaging)\software on each server and verified (SHA256). Nothing is installed; INSTALL / UPDATE later uses the staged copy." }
    $stopAgent = ((-not $StageOnly) -and (Test-TrellixStopOn -Console 'Software'))   # read once: the plan the operator approves is what happens (R6-B07)
    if ($stopAgent) { $how += "`n`nTrellix Agent: the services masvc and macmnsvc are set to Disabled and stopped on each server before the install (the box on the tab). Start them again after the reboot with 'Start Trellix Agent (ticked)'." }
    $ok = Show-PatcherMessage -Title 'The plan' -Buttons 'OKCancel' -Icon 'Question' -Text ("This is what will happen (rows with Install / Update go ahead, 'skip' rows do not):`n`n{0}`n`n{1}`n`nContinue?" -f (Format-SoftwarePlan $plan), $how)
    if ($ok -ne 'OK') { Write-PatchLog "$who cancelled at the plan screen" 'WARN'; return @() }

    $results = @()
    $change = $null
    if ($StageOnly) {
        # staging changes no installed software; whether it is recorded is the Settings tab's call ('Not recorded' by default)
        $change = Request-ChangeRecord -Action 'Software stage' -Servers $goServers -Items (($todo | ForEach-Object { "$($_.Id) $($_.Version)" } | Select-Object -Unique) -join ', ')
        if (-not $change) { return @() }
    } else {
        $change = Request-ChangeRecord -Action 'Software install / update' -Servers $goServers -Items (($todo | ForEach-Object { "$($_.Id) $($_.Version)" } | Select-Object -Unique) -join ', ')
        if (-not $change) { return @() }
        $confirmed = Confirm-SafetyChecks -Servers $goServers -Activity 'The software change'
        if ($confirmed -isnot [bool] -or $confirmed -ne $true) { Write-ChangeLog -Record $change -Server $goServers -Action $action -Item (($todo | ForEach-Object { $_.Id } | Select-Object -Unique) -join ', ') -Result 'aborted at the safety checks - nothing changed'; return @() }
        Write-PatchLog 'Re-checking the servers now that the pop-ups are answered (they may have been open a while)' 'WHY'
        Update-SoftwareFacts -ComputerName $goServers -NoStatus
        $recheck = @(New-SoftwarePlan -ComputerName $goServers -Files $Files)
        $still = @()
        foreach ($p in $todo) {
            $now = @($recheck | Where-Object { $_.Computer -eq $p.Computer -and $_.Id -eq $p.Id })[0]
            if ($now -and $now.Go) { $still += $now } else { Write-PatchLog ("Dropped {0} {1} - no longer ready: {2}" -f $p.Computer, $p.Id, $now.Reason) 'WARN' }
        }
        $todo = $still
        $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
        if ($todo.Count -eq 0) { $null = Show-PatcherMessage -Text 'Every server changed while the pop-ups were open. Nothing was installed - see the log.' -Title 'Nothing to do' -Icon 'Warning'; return @() }
        foreach ($c in $goServers) { Write-ChangeLog -Record $change -Server $c -Action $action -Item ((@($todo | Where-Object { $_.Computer -eq $c }) | ForEach-Object { "$($_.Name) $($_.Version) ($($_.Mode))" }) -join ', ') -Result 'approved - starting' }
        # the Trellix Agent (the box on the tab, ticked by default): the two agent services set to Disabled and stopped on each
        # server first, under this change record; a server where that fails is dropped (fail closed - untick the box to go on)
        if ($stopAgent) {
            $agentRows = @(Invoke-TrellixAgentChange -ComputerName $goServers -Mode stop -Change $change -Action $action)
            $agentFailed = @($agentRows | Where-Object { -not $_.Success } | ForEach-Object { $_.Server })
            foreach ($c in $agentFailed) {
                $why = [string]@($agentRows | Where-Object { $_.Server -eq $c })[0].Message
                foreach ($p in @($todo | Where-Object { $_.Computer -eq $c })) { $label = '{0} {1} ({2})' -f $p.Name, $p.Version, $p.Mode; $results += New-SoftwareResult -Server $c -Item $label -Kind 'install' -Success $false -Message ('not installed - ' + $why); Write-ChangeLog -Record $change -Server $c -Action $action -Item $label -Result ('not installed - ' + $why) }
            }
            $todo = @($todo | Where-Object { $agentFailed -notcontains $_.Computer })
            $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
            if ($todo.Count -eq 0) { $null = Show-PatcherMessage -Text 'The Trellix Agent services could not be stopped on any server, so nothing was installed - the log has the error per server. Untick "Stop the Trellix Agent services first" to install with the agent running.' -Title 'Nothing to do' -Icon 'Warning'; return $results }
        }
    }

    $sessions = @{}
    $itemsByServer = @{}
    $script:InstallTargets = $goServers
    try {
        $n = 0
        foreach ($c in $goServers) {
            $n++
            $mine = @($todo | Where-Object { $_.Computer -eq $c })
            try {
                Write-PatchLog ("[{0}/{1}] {2}: staging {3}" -f $n, $goServers.Count, $c, (($mine | ForEach-Object { $_.File.File }) -join ', ')) 'INFO'
                $sess = Open-SoftwareSession -Server $c
                $sessions[$c] = $sess
                $items = @()
                foreach ($p in $mine) {
                    # its own sub-folder per package: two installers called setup.exe must not share one staged path
                    $dest = $script:Config.RemoteStaging.TrimEnd('\') + '\software\' + (Get-SoftwareStageName $p.Id) + '\' + $p.File.File
                    Write-PatchLog ("Copy-FileToSession -Path '{0}' -Destination '{1}' -Session [{2}]   ({3} MB)" -f $p.File.FullName, $dest, $c, $p.File.SizeMB) 'CMD'
                    Copy-FileToSession -Path $p.File.FullName -Destination $dest -Session $sess -LocalHash $p.File.Hash | Out-Null
                    $label = '{0} {1} ({2})' -f $p.Name, $p.Version, $p.Mode
                    if ($StageOnly) {
                        $results += New-SoftwareResult -Server $c -Item $label -Kind 'stage' -Success $true -Message "staged in $dest (SHA256 verified)"
                        Write-ChangeLog -Record $change -Server $c -Action $action -Item $label -Result "staged in $dest (SHA256 verified)"
                        continue
                    }
                    $pkg = $p.File.Package
                    $items += @{ Kind = 'install'; Label = $label; Mode = $p.Mode; File = $dest; Hash = $p.File.Hash; Installer = [string]$pkg.Installer; Arguments = (Get-SoftwareArguments -Package $pkg -Mode $p.Mode); Signers = @($pkg.Signers); AllowUnsigned = [bool]$pkg.AllowUnsigned; Match = [string]$pkg.Match; Version = $p.Version; Requires = [string]$pkg.Requires }
                }
                if ($items.Count -gt 0) { $itemsByServer[$c] = $items }
            } catch {
                $msg = 'staging failed: ' + (Get-ShortError $_)
                Write-PatchLog "$c - $msg" 'ERROR'
                foreach ($p in $mine) {
                    $label = '{0} {1} ({2})' -f $p.Name, $p.Version, $p.Mode
                    # a package already staged before a later one failed keeps its "staged" record - not also "failed" (R6-C10)
                    if (@($results | Where-Object { $_.Server -eq $c -and $_.Item -eq $label -and $_.Success }).Count -gt 0) { continue }
                    $results += New-SoftwareResult -Server $c -Item $label -Kind $(if ($StageOnly) { 'stage' } else { 'install' }) -Success $false -Message $msg
                    if ($change) { Write-ChangeLog -Record $change -Server $c -Action $action -Item $label -Result $msg }
                }
            }
        }
        if (-not $StageOnly -and $itemsByServer.Count -gt 0) { $results += @(Invoke-SoftwareRun -Sessions $sessions -ItemsByServer $itemsByServer -Change $change -Action $action) }
    } finally {
        foreach ($s in @($sessions.Values)) { Close-ToolkitSession -Session $s }
        $script:InstallTargets = @()
    }
    # with the status: an exit 3010 shows as a pending reboot straight away, not at the next Check
    Update-SoftwareFacts -ComputerName $goServers
    $good = @($results | Where-Object { $_.Success }).Count; $bad = @($results | Where-Object { -not $_.Success }).Count; $reb = @($results | Where-Object { $_.RebootRequired }).Count
    Write-PatchLog ("=== {0} FINISHED (by {1}): {2} ok, {3} failed/unknown, {4} need a reboot ===" -f $action.ToUpper(), $who, $good, $bad, $reb) 'INFO'
    return $results
}

function Get-RemovalLabel {
    # The item label of a removal - the product and version, and the hive when it is the 32-bit one: a product installed in
    # both hives under one name and version is two items, which the results, the checks and the change log must tell apart
    param($Row)
    $label = 'Remove {0} {1}' -f $Row.Product, $Row.Version
    if ([string]$Row.Hive -eq '32') { $label += ' (32-bit)' }
    return $label
}

function Get-UninstallPlan {
    # Ticked inventory rows -> plan rows, judged on the FRESH inventory: the product must still be there under the same key
    # in the same hive (a row from an inventory older than the hive field matches either).
    param([object[]]$Rows)
    $plan = @()
    foreach ($row in $Rows) {
        # no fresh inventory (the server did not answer the pre-flight) is not "gone": said as such
        $invRow = Get-CollectorResult -Name 'Inventory' -Server $row.Server
        if (-not $invRow -or -not $invRow.Reachable) { $plan += [pscustomobject]@{ Server = $row.Server; Product = $row.Product; Version = $row.Version; KeyName = $row.KeyName; Hive = [string]$row.Hive; Go = $false; Method = ''; Use = ''; Reason = ('inventory not read: ' + $(if ($invRow) { [string]$invRow.Error } else { 'not checked' })); MayRestart = $false; Location = '' }; continue }
        $fresh = @(Get-SoftwareRows -Servers @($row.Server) | Where-Object { $_.Product -eq $row.Product -and [string]$_.KeyName -eq [string]$row.KeyName -and (-not [string]$row.Hive -or [string]$_.Hive -eq [string]$row.Hive) })[0]
        if (-not $fresh) { $plan += [pscustomobject]@{ Server = $row.Server; Product = $row.Product; Version = $row.Version; KeyName = $row.KeyName; Hive = [string]$row.Hive; Go = $false; Method = ''; Use = ''; Reason = 'no longer installed (fresh inventory)'; MayRestart = $false; Location = '' }; continue }
        $v = Get-UninstallVerdict -Row $fresh
        $plan += [pscustomobject]@{ Server = $fresh.Server; Product = $fresh.Product; Version = $fresh.Version; KeyName = $fresh.KeyName; Hive = [string]$fresh.Hive; Go = $v.Go; Method = $v.Method; Use = (Get-ProductUse -Row $fresh); Reason = $v.Reason; MayRestart = [bool]$v.MayRestart; Location = [string]$fresh.Location }
    }
    return $plan
}

function Uninstall-SoftwareOnServers {
    # UNINSTALL (ticked products): fresh inventory, the plan, the change record, the pre-action confirmations, one more
    # confirmation for the removal itself, a re-check, then the run (no copy - the server uninstalls from its own registry).
    param([Parameter(Mandatory = $true)][object[]]$Rows)
    $action = 'Software removal'
    $servers = @(Get-UniqueNames ($Rows | ForEach-Object { $_.Server }))
    $who = Get-OperatorIdentity
    Write-PatchLog ("=== SOFTWARE REMOVAL REQUESTED by {0}: {1} product(s) on {2} ===" -f $who, $Rows.Count, ($servers -join ', ')) 'INFO'
    Update-SoftwareFacts -ComputerName $servers
    $who = Get-OperatorIdentity
    $kept = @(Remove-DuplicateServers $servers)
    $plan = @(Get-UninstallPlan -Rows @($Rows | Where-Object { $kept -contains $_.Server }))
    foreach ($p in $plan) { $lvl = 'WARN'; if ($p.Go) { $lvl = 'INFO' }; Write-PatchLog ("Plan: {0}  remove {1} {2}  -> {3}" -f $p.Server, $p.Product, $p.Version, $p.Reason) $lvl }
    $todo = @($plan | Where-Object { $_.Go })
    if ($todo.Count -eq 0) { $null = Show-PatcherMessage -Text 'Nothing to remove - every ticked product is protected, required by the SOE standard, has no silent uninstall, or is gone. The log has the reason per product.' -Title 'Nothing to do'; return @() }
    $planText = ($plan | ForEach-Object { $what = 'skip'; if ($_.Go) { $what = $_.Method }; '{0,-30} {1,-12} {2} {3}   {4}{5}' -f $_.Server, $what, $_.Product, $_.Version, $_.Reason, $(if ($_.Use) { '   [' + $_.Use.ToUpper() + ']' } else { '' }) }) -join "`n"
    $ok = Show-PatcherMessage -Title 'The removal plan' -Buttons 'OKCancel' -Icon 'Question' -Text ("This is what will be REMOVED (rows marked skip are left alone):`n`n{0}`n`nEach removal runs on its server as a one-shot SYSTEM task, one at a time, and never restarts the server where the uninstaller has a known no-restart switch (MSI, Inno Setup, WiX bundles - added by the tool). After a removal the server shows 'reboot advised' until it restarts: plan that reboot as its own step.`n`nContinue?" -f $planText)
    if ($ok -ne 'OK') { Write-PatchLog "$who cancelled at the removal plan" 'WARN'; return @() }
    $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Server }))
    $change = Request-ChangeRecord -Action 'Software removal' -Servers $goServers -Items (($todo | ForEach-Object { $_.Product } | Select-Object -Unique) -join ', ')
    if (-not $change) { return @() }
    $confirmed = Confirm-SafetyChecks -Servers $goServers -Activity 'The removal'
    if ($confirmed -isnot [bool] -or $confirmed -ne $true) { Write-ChangeLog -Record $change -Server $goServers -Action $action -Item 'removal' -Result 'aborted at the safety checks - nothing changed'; return @() }
    $inUse = @($todo | Where-Object { $_.Use -like 'in use*' })
    $mayRestart = @($todo | Where-Object { $_.MayRestart })
    $warn = "REMOVE these products?`n`n" + (($todo | ForEach-Object { '{0,-30} {1} {2}{3}{4}' -f $_.Server, $_.Product, $_.Version, $(if ($_.Use -like 'in use*') { '   <- ' + $_.Use.ToUpper() } else { '' }), $(if ($_.MayRestart) { '   <- MAY RESTART THE SERVER' } else { '' }) }) -join "`n") + "`n`nThe tool cannot undo a removal: putting it back needs the vendor's installer, its configuration and its licence."
    if ($inUse.Count -gt 0) { $warn += "`n`n$($inUse.Count) of them are IN USE by a service, process or scheduled task on the server: that will stop working." }
    if ($mayRestart.Count -gt 0) { $warn += "`n`n$($mayRestart.Count) of them use an uninstaller with no known no-restart switch: it MAY RESTART THE SERVER by itself. Answer No and remove those by hand in a reboot window if that is not acceptable." }
    $warn += "`n`nAnswer No and nothing is removed."
    $q = Show-PatcherMessage -Title 'CONFIRM REMOVAL (last question)' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text $warn
    if ($q -ne 'Yes') { Write-PatchLog "ABORTED - $who did not confirm the removal (answer: $q)" 'ERROR'; Write-ChangeLog -Record $change -Server $goServers -Action $action -Item 'removal' -Result 'aborted at the removal confirmation - nothing changed'; return @() }
    Write-PatchLog "Confirmed by ${who}: remove $($todo.Count) product(s)" 'OK'
    Write-PatchLog 'Re-checking the inventory now that the pop-ups are answered' 'WHY'
    Update-SoftwareFacts -ComputerName $goServers -NoStatus
    $recheck = @(Get-UninstallPlan -Rows $todo)
    $todo = @($recheck | Where-Object { $_.Go })
    foreach ($p in @($recheck | Where-Object { -not $_.Go })) { Write-PatchLog ("Dropped {0} {1} - {2}" -f $p.Server, $p.Product, $p.Reason) 'WARN' }
    $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Server }))
    if ($todo.Count -eq 0) { $null = Show-PatcherMessage -Text 'Every product changed while the pop-ups were open. Nothing was removed - see the log.' -Title 'Nothing to do' -Icon 'Warning'; return @() }
    foreach ($c in $goServers) { Write-ChangeLog -Record $change -Server $c -Action $action -Item ((@($todo | Where-Object { $_.Server -eq $c }) | ForEach-Object { "$($_.Product) $($_.Version)" }) -join ', ') -Result 'approved - starting' }

    $results = @()
    $sessions = @{}
    $itemsByServer = @{}
    $script:InstallTargets = $goServers
    try {
        foreach ($c in $goServers) {
            $mine = @($todo | Where-Object { $_.Server -eq $c })
            try {
                $sessions[$c] = Open-SoftwareSession -Server $c
                $itemsByServer[$c] = @($mine | ForEach-Object { @{ Kind = 'uninstall'; Label = (Get-RemovalLabel -Row $_); Mode = 'Uninstall'; Name = $_.Product; Version = $_.Version; KeyName = $_.KeyName; Hive = $_.Hive } })
            } catch {
                $msg = 'could not connect: ' + (Get-ShortError $_)
                Write-PatchLog "$c - $msg" 'ERROR'
                foreach ($p in $mine) { $label = Get-RemovalLabel -Row $p; $results += New-SoftwareResult -Server $c -Item $label -Kind 'uninstall' -Success $false -Message $msg; Write-ChangeLog -Record $change -Server $c -Action $action -Item $label -Result $msg }
            }
        }
        if ($itemsByServer.Count -gt 0) { $results += @(Invoke-SoftwareRun -Sessions $sessions -ItemsByServer $itemsByServer -Change $change -Action $action) }
    } finally {
        foreach ($s in @($sessions.Values)) { Close-ToolkitSession -Session $s }
        $script:InstallTargets = @()
    }
    Update-SoftwareFacts -ComputerName $goServers
    # an exit code is the uninstaller's word, not the server's: a product still in the fresh inventory under the same
    # uninstall key was NOT removed (a quiet uninstaller that hands over to a copy of itself in TEMP exits 0 at once) (R6-C04)
    foreach ($r in @($results | Where-Object { $_.Success })) {
        $p = @($todo | Where-Object { $_.Server -eq $r.Server -and (Get-RemovalLabel -Row $_) -eq $r.Item })[0]
        if (-not $p) { continue }
        $invNow = Get-CollectorResult -Name 'Inventory' -Server $r.Server
        if (-not $invNow -or -not $invNow.Reachable -or -not ($invNow.Checked -is [datetime]) -or ((Get-Date) - $invNow.Checked).TotalMinutes -gt 10) {
            # only the inventory read just now counts; without one the result stands on the exit code alone, and says so
            $r.Message += ' (NOT VERIFIED: the inventory could not be read after the run - press Check later)'
            Write-ChangeLog -Record $change -Server $r.Server -Action $action -Item $r.Item -Result 'removed per the uninstaller''s exit code - not verified, the inventory could not be read after the run'
            continue
        }
        $still = @(Get-SoftwareRows -Servers @($r.Server) | Where-Object { $_.Product -eq $p.Product -and [string]$_.KeyName -eq [string]$p.KeyName -and (-not [string]$p.Hive -or [string]$_.Hive -eq [string]$p.Hive) })
        if ($still.Count -eq 0) { continue }
        $r.Success = $false
        $r.Message = ('NOT REMOVED - the uninstaller ended with exit {0}, but the product is still installed (fresh inventory); it may still be finishing on its own - press Check later, or remove it by hand' -f $r.ExitCode)
        Write-PatchLog ("RESULT {0}  {1}  -> {2}" -f $r.Server, $r.Item, $r.Message) 'ERROR'
        Write-ChangeLog -Record $change -Server $r.Server -Action $action -Item $r.Item -Result $r.Message
    }
    # what an uninstaller left behind: services and tasks still pointing into the product's folder (fresh inventory).
    # Reported - in the log, the change record and the finished pop-up - never deleted by the tool.
    foreach ($r in @($results | Where-Object { $_.Success })) {
        $p = @($todo | Where-Object { $_.Server -eq $r.Server -and (Get-RemovalLabel -Row $_) -eq $r.Item })[0]
        if (-not $p) { continue }
        $left = Get-RemovalLeftovers -Server $r.Server -Location $p.Location
        if ($null -eq $left) { Write-PatchLog ("{0} - {1}: no install folder recorded, so leftovers (services, tasks) were not looked for" -f $r.Server, $p.Product) 'WHY'; continue }
        if (@($left).Count -eq 0) { continue }
        $r | Add-Member -NotePropertyName LeftBehind -NotePropertyValue @($left) -Force
        Write-PatchLog ("{0} - {1} removed, but its uninstaller LEFT BEHIND: {2} - remove by hand under a change record (Commands tab), or ask the vendor" -f $r.Server, $p.Product, (@($left) -join '; ')) 'WARN'
        Write-ChangeLog -Record $change -Server $r.Server -Action $action -Item $r.Item -Result ('left behind by the uninstaller: ' + (@($left) -join '; '))
    }
    $good = @($results | Where-Object { $_.Success }).Count; $bad = @($results | Where-Object { -not $_.Success }).Count
    Write-PatchLog ("=== SOFTWARE REMOVAL FINISHED (by {0}): {1} removed, {2} failed/unknown ===" -f $who, $good, $bad) 'INFO'
    return $results
}

# ---------------------------------------------------------------------
#  The window: package list, server grid, inventory list
# ---------------------------------------------------------------------
function Get-CheckedSoftwareFiles {
    # The installers ticked in the installer list (ticks are kept by file path in $script:Gui['SoftwareTicks']) - only of
    # the packages shown: INSTALL never acts on a tick the operator cannot see.
    $ticks = $script:Gui['SoftwareTicks']
    if (-not $ticks) { return @() }
    $shown = @(Get-SoftwareShownIds)
    return @(@($script:SoftwareFiles) | Where-Object { $_ -and $ticks[[string]$_.FullName] -and $shown -contains $_.Id })
}

function Update-SoftwarePackageList {
    # The installer list: one row per installer of the packages shown - a tick box (deploy this one), its package,
    # version, size and signer (or, in dark red, why it is blocked), and its own Edit... button that opens the package's
    # registration.  Rebuilt only when the installers or the packages shown change; ticks are kept by file path.
    $box = $script:Gui['SoftwarePackageRows']
    $shown = @(Get-SoftwareShownIds)
    $total = @(Get-SoftwarePackageIds).Count
    $files = @(@($script:SoftwareFiles) | Where-Object { $_ -and $shown -contains $_.Id })
    $ticks = $script:Gui['SoftwareTicks']
    $present = @{}; foreach ($f in $files) { $present[[string]$f.FullName] = $true }
    foreach ($k in @($ticks.Keys)) { if (-not $present.ContainsKey($k)) { $ticks.Remove($k) } }   # gone, or its package no longer shown: no longer ticked
    $libButton = $script:Gui['SoftwareLibraryButton']
    if ($libButton) {
        $libButton.Text = $(if ($total -gt $shown.Count) { 'Library: {0} of {1} shown...' -f $shown.Count, $total } else { 'Software library ({0})...' -f $total })
    }
    $sig = (@($files | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.FullName, $_.Version, $_.Blocked, $_.Id }) -join ';')
    if ($box -and -not ($script:Gui.ContainsKey('SoftwareRowsSig') -and $script:Gui['SoftwareRowsSig'] -eq $sig)) {
        $script:Gui['SoftwareRowsSig'] = $sig
        $script:Gui['SoftwarePackageRebuilding'] = $true
        $box.SuspendLayout()
        try {
            foreach ($old in @($box.Controls)) { $old.Dispose() }
            $w = $box.ClientSize.Width
            if ($files.Count -gt 3) { $w -= [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }
            if ($files.Count -eq 0) {
                $empty = New-Object System.Windows.Forms.Label
                $empty.Text = 'No installers yet. Put one in any folder under software\, then press Reload lists + packages.'
                $empty.ForeColor = 'DimGray'; $empty.Location = New-Object System.Drawing.Point(6, 6); $empty.Size = New-Object System.Drawing.Size(($w - 12), 40)
                $box.Controls.Add($empty)
            }
            $y = 2
            foreach ($f in $files) {
                $text = '{0}  {1}  {2} MB' -f $f.Id, $f.Version, $f.SizeMB
                if ($f.Blocked) { $text += '  - BLOCKED: ' + $f.Blocked } else { $text += '  - ' + (Get-SignerOrg $f.Signer) }
                $where = [string]$f.File; if ($f.Folder) { $where = $f.Folder + '\' + $f.File }
                # the SHA256 too: the how-to promises it, and a change process may want it (R6-C13)
                $tip = ("software\{0}`r`n{1}`r`nSHA256 {3}`r`nEdit... opens the registration of package '{2}' (modes, arguments, signer, Match ...)." -f $where, $text, $f.Id, $(if ($f.Hash) { $f.Hash } else { 'not read' }))
                $cb = New-Object System.Windows.Forms.CheckBox
                $cb.Location = New-Object System.Drawing.Point(5, ($y + 5)); $cb.Size = New-Object System.Drawing.Size(15, 15); $cb.Tag = [string]$f.FullName
                $cb.Checked = [bool]$ticks[[string]$f.FullName]
                $cb.Add_CheckedChanged({ if ($script:Gui['SoftwarePackageRebuilding']) { return }; $script:Gui['SoftwareTicks'][[string]$this.Tag] = $this.Checked; $script:Gui['SoftwareColumnTimer'].Stop(); $script:Gui['SoftwareColumnTimer'].Start() })
                $lbl = New-Object System.Windows.Forms.Label
                $lbl.Text = $text; $lbl.AutoEllipsis = $true; $lbl.Tag = [string]$f.FullName; $lbl.Anchor = 'Top, Left, Right'
                $lbl.ForeColor = $(if ($f.Blocked) { 'DarkRed' } else { 'Black' })
                $lbl.Location = New-Object System.Drawing.Point(24, ($y + 5)); $lbl.Size = New-Object System.Drawing.Size(($w - 24 - 72), 18)
                # a click on the text ticks the box too, like a list
                $lbl.Add_Click({ $want = [string]$this.Tag; foreach ($other in $this.Parent.Controls) { if ($other -is [System.Windows.Forms.CheckBox] -and [string]$other.Tag -eq $want) { $other.Checked = -not $other.Checked } } })
                $btn = New-Object System.Windows.Forms.Button
                $btn.Text = 'Edit...'; $btn.Tag = [string]$f.FullName; $btn.Anchor = 'Top, Right'; $btn.BackColor = 'Gainsboro'; $btn.UseVisualStyleBackColor = $false
                $btn.Location = New-Object System.Drawing.Point(($w - 68), ($y + 1)); $btn.Size = New-Object System.Drawing.Size(64, 24)
                # like Register...: the click only records the job, the timer opens the form after the click has finished
                $btn.Add_Click({ $script:Gui['SoftwareRegisterPending'] = @{ Kind = 'edit'; FullName = [string]$this.Tag }; $script:Gui['SoftwareRegisterTimer'].Stop(); $script:Gui['SoftwareRegisterTimer'].Start() })
                foreach ($ctl in $cb, $lbl, $btn) { $script:Gui['Tips'].SetToolTip($ctl, $tip) }
                $box.Controls.AddRange(@($cb, $lbl, $btn))
                $y += 27
            }
        } finally { $box.ResumeLayout(); $script:Gui['SoftwarePackageRebuilding'] = $false }
    }
    $cat = Get-SoftwareCatalogue
    $label = $script:Gui['SoftwareFolderLabel']
    $plain = ('Folder: {0}   Catalogue: data\software-packages.psd1 ({1} package(s), as of {2})' -f $script:Config.SoftwareFolder, @($cat.Packages | Where-Object { $_ }).Count, $cat.AsOf)
    $odd = @($script:SoftwareNotOffered)
    if ($odd.Count -gt 0) {
        # each note reads "what - how to fix it": the label has room for the what, the tooltip and the log carry the how.
        # Dark red, not orange: light orange on white was hard to read (field report 2026-10-21)
        $label.Text = ('NOT USABLE: {0}  (hover for the fix{1})' -f ($odd[0] -split ' - ', 2)[0], $(if ($odd.Count -gt 1) { (', +{0} more' -f ($odd.Count - 1)) } else { '' }))
        $label.ForeColor = 'DarkRed'
        $script:Gui['Tips'].SetToolTip($label, ((@($odd | ForEach-Object { 'NOT USABLE: ' + $_ }) + @('', $plain)) -join "`r`n"))
    } else { $label.Text = $plain; $label.ForeColor = 'DimGray'; $script:Gui['Tips'].SetToolTip($label, $plain) }
    Update-SoftwareNewPanel
}

function Update-SoftwareNewPanel {
    # The yellow box under the installer list: one row per NEW installer - bold "* NEW" and its folder's name, the file and
    # its size underneath, and its own Register button.  Hidden when nothing is new; the controls underneath move down by
    # its height.  Rebuilt only when the set of NEW files changes.
    $box = $script:Gui['SoftwareNewPanel']
    if (-not $box) { return }
    $new = @($script:SoftwareDetected)
    $sig = (@($new | ForEach-Object { $_.FullName + '|' + $_.Length }) -join ';')
    if ($script:Gui.ContainsKey('SoftwareNewSig') -and $script:Gui['SoftwareNewSig'] -eq $sig) { return }
    $script:Gui['SoftwareNewSig'] = $sig
    $height = 0
    $box.SuspendLayout()
    try {
        foreach ($old in @($box.Controls)) { $old.Dispose() }
        if ($new.Count -gt 0) {
            $w = $box.ClientSize.Width
            if ($new.Count -gt 3) { $w -= [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth }   # the box scrolls: leave room for the bar
            $bold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
            $head = New-Object System.Windows.Forms.Label
            $head.Text = ('New installers ({0}) - register before deploying:' -f $new.Count)
            $head.Font = $bold; $head.ForeColor = 'Black'; $head.AutoEllipsis = $true; $head.Anchor = 'Top, Left, Right'
            $head.Location = New-Object System.Drawing.Point(6, 5); $head.Size = New-Object System.Drawing.Size(($w - 12), 18)
            $box.Controls.Add($head)
            $y = 28
            foreach ($d in $new) {
                $name = [string]$d.File; if ($d.Folder) { $name = ([string]$d.Folder -split '\\')[-1] }
                $where = [string]$d.File; if ($d.Folder) { $where = $d.Folder + '\' + $d.File }
                $tip = ("software\{0}  ({1} MB)`r`n{2}`r`nRegister... opens a form filled from the file; nothing is written until you press Register in it." -f $where, $d.SizeMB, $d.Reason)
                $title = New-Object System.Windows.Forms.Label
                $title.Text = ('* NEW   {0}   {1} MB' -f $name, $d.SizeMB); $title.Font = $bold; $title.ForeColor = 'Black'; $title.AutoEllipsis = $true; $title.Anchor = 'Top, Left, Right'
                $title.Location = New-Object System.Drawing.Point(6, $y); $title.Size = New-Object System.Drawing.Size(($w - 110), 18)
                $file = New-Object System.Windows.Forms.Label
                $file.Text = [string]$d.File; $file.ForeColor = 'Black'; $file.AutoEllipsis = $true; $file.Anchor = 'Top, Left, Right'
                $file.Location = New-Object System.Drawing.Point(20, ($y + 18)); $file.Size = New-Object System.Drawing.Size(($w - 124), 18)
                $btn = New-Object System.Windows.Forms.Button
                $btn.Text = 'Register...'; $btn.Tag = [string]$d.FullName; $btn.Anchor = 'Top, Right'; $btn.BackColor = 'Gainsboro'; $btn.UseVisualStyleBackColor = $false
                $btn.Location = New-Object System.Drawing.Point(($w - 98), ($y + 5)); $btn.Size = New-Object System.Drawing.Size(90, 28)
                # the click only records which installer: the timer opens the form after the click has finished (the
                # registration rebuilds this box, button included)
                $btn.Add_Click({ $script:Gui['SoftwareRegisterPending'] = @{ Kind = 'register'; FullName = [string]$this.Tag }; $script:Gui['SoftwareRegisterTimer'].Stop(); $script:Gui['SoftwareRegisterTimer'].Start() })
                foreach ($ctl in $title, $file, $btn) { $script:Gui['Tips'].SetToolTip($ctl, $tip) }
                $box.Controls.AddRange(@($title, $file, $btn))
                $y += 44
            }
            $height = 28 + ([math]::Min($new.Count, 3) * 44) + 2
        }
        $box.Height = $height
        $box.Visible = ($height -gt 0)
    } finally { $box.ResumeLayout() }
    $shift = 0; if ($height -gt 0) { $shift = $height + 8 }
    # from their design places, less any hidden band above them (the Trellix box and buttons, Set-PanelBandShown)
    foreach ($pair in @($script:Gui['SoftwareBelowNew'])) { if ($pair) { $pair[0].Top = $pair[1] + $shift + (Get-PanelBandOffset -Panel $pair[0].Parent -DesignTop $pair[1]) } }
}

function Update-SoftwareServerGrid {
    # One row per server: a column per package shown (at most MaxSoftwareColumns) - green where that version is
    # installed, yellow where INSTALL / UPDATE would act - and, when the library holds more packages than that, an "All
    # packages" column that counts what every package would do.  The row is yellow when anything at all is to do.
    $lv = $script:Gui['SoftwareServerGrid']
    if (-not $lv) { return }
    $groupRows = @(Get-GroupRows -Combo $script:Gui['SoftwareGroupCombo'])
    $libFiles = @(Get-SoftwareLibraryFiles)
    $colFiles = @(Get-SoftwareGridFiles)
    $summaryCol = ($libFiles.Count -gt $colFiles.Count)
    # All packages, then the package columns, right after WinRM: they are the point of the tab and must be visible at the
    # default width - All packages first, so six wide package columns never push it out of view
    $columns = @(@{ Name = 'Server'; Width = 170 }, @{ Name = 'Group'; Width = 100 }, @{ Name = 'WinRM'; Width = 60 })
    if ($summaryCol) { $columns += @{ Name = 'All packages'; Width = 190 } }
    foreach ($f in $colFiles) { $columns += @{ Name = $f.Id; Width = 210 } }
    $columns += @(@{ Name = 'Hardware'; Width = 150 }, @{ Name = 'Pending reboot'; Width = 140 }, @{ Name = 'Trellix Agent'; Width = 130 }, @{ Name = 'Staged'; Width = 60 }, @{ Name = 'Toolkit task'; Width = 160 }, @{ Name = 'Products'; Width = 70 })
    if (-not (Test-TrellixInUse)) { $columns = @($columns | Where-Object { $_.Name -ne 'Trellix Agent' }) }   # Settings tab: Trellix not used here
    $columns += @{ Name = 'Checked at'; Width = 80; Fill = $true }
    $sig = (($columns | ForEach-Object { $_.Name }) -join '|')
    if ($script:Gui['SoftwareGridColumns'] -ne $sig) { Set-GridColumns -Grid $lv -Columns $columns; $script:Gui['SoftwareGridColumns'] = $sig }
    # every server's product rows in one call (Get-SoftwareRows keeps them indexed by server), not one call per cell
    $null = Get-SoftwareRows -Servers @(Get-UniqueNames ($groupRows | ForEach-Object { $_.Server }))
    $byServer = @{}; if ($script:SoftwareRowCache) { $byServer = $script:SoftwareRowCache.ByServer }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($gr in $groupRows) {
        $name = $gr.Server
        $s = $script:ServerStatus[$name]
        $inv = Get-CollectorResult -Name 'Inventory' -Server $name
        $st = Get-CollectorResult -Name 'SoftwareState' -Server $name
        $o = [ordered]@{ Server = $name; Group = $gr.Group; WinRM = ''; Hardware = ''; 'Pending reboot' = ''; 'Trellix Agent' = ''; Staged = ''; 'Toolkit task' = ''; Products = ''; 'Checked at' = ''; Colour = 'White'; Tip = ''; Cells = @{} }
        $anyGo = $false; $allCurrent = ($libFiles.Count -gt 0); $anyCurrent = $false   # green needs a package really in place, not "N/A (hardware)" alone
        $unreachable = (($s -and -not $s.Reachable) -or ($inv -and -not $inv.Reachable))
        if ($unreachable) {
            $o.WinRM = 'FAILED'; $o.Colour = 'LightGray'
            $o.Tip = $(if ($s -and -not $s.Reachable) { $s.Error } else { $inv.Error })
        } elseif ($s -or $inv -or $st) {
            $o.WinRM = 'OK'
            $make = Get-ServerManufacturer -Server $name
            if ($make -like 'VMware*') { $o.Hardware = 'VMware VM' } elseif ($make) { $o.Hardware = ($make + ' ' + $(if ($st) { $st.Model } else { '' })).Trim() }
            if ($s -and $s.Reachable) {
                $o.'Pending reboot' = Get-PendingRebootText -Status $s
                # the two ePO agent services: orange when stopped or disabled (the tool sets them so before an install) - ePO hears nothing
                $agent = Get-TrellixAgentInfo -Status $s
                $o.'Trellix Agent' = $agent.Text
                if ($agent.State -in 'stopped', 'mixed', 'unknown') { $o.Cells['Trellix Agent'] = 'NavajoWhite' }
            }
            if ($st -and $st.Reachable) {
                $o.Staged = [string]@($st.Staged).Count
                $tr = @(Get-ServerTaskRows -Server $name)
                if ($tr.Count -gt 0) { $o.'Toolkit task' = (($tr | ForEach-Object { '{0} {1}' -f $_.State, $_.Item }) -join '; ') }
            }
            if ($inv -and $inv.Reachable) { $o.Products = [string]@($inv.Products).Count }
            $when = [datetime]::MinValue
            foreach ($x in $s, $inv, $st) { if ($x -and $x.Checked -and $x.Checked -gt $when) { $when = $x.Checked } }
            if ($when -gt [datetime]::MinValue) { $o.'Checked at' = $when.ToString('HH:mm:ss') }
        }
        $mineRows = @(); $list = $byServer[$name.ToLower()]; if ($list) { $mineRows = $list.ToArray() }
        # every package's verdict (cached until the server is checked again); the columns show the ones chosen
        $all = @(foreach ($f in $libFiles) { [pscustomobject]@{ Id = $f.Id; Verdict = (Get-SoftwareVerdictCached -Server $name -PackageFile $f -Products $mineRows) } })
        foreach ($x in $all) {
            if ($x.Verdict.Go) { $anyGo = $true }
            if ($x.Verdict.Light -eq 'Green') { $anyCurrent = $true }
            if ($x.Verdict.Light -ne 'Green' -and $x.Verdict.Cell -ne 'N/A (hardware)') { $allCurrent = $false }
        }
        foreach ($f in $colFiles) {
            $v = @($all | Where-Object { $_.Id -eq $f.Id })[0].Verdict
            $o[$f.Id] = $v.Cell
            $c = Get-SoftwareCellColour $v; if ($c) { $o.Cells[$f.Id] = $c }
        }
        if ($summaryCol) {
            $sum = Get-SoftwareSummary -Verdicts $all
            $o['All packages'] = $sum.Text
            if ($sum.Colour) { $o.Cells['All packages'] = $sum.Colour }
            if ($sum.Todo.Count -gt 0 -and -not $unreachable) { $o.Tip = ('To do: ' + (@($sum.Todo | Select-Object -First 10) -join '; ') + $(if ($sum.Todo.Count -gt 10) { ('; +{0} more' -f ($sum.Todo.Count - 10)) } else { '' })) }
        }
        if (-not $unreachable) {
            if ($o.'Toolkit task' -like '*Running*') { $o.Colour = 'LightCyan' }
            elseif ($anyGo) { $o.Colour = 'LemonChiffon' }
            elseif ($inv -and $allCurrent -and $anyCurrent) { $o.Colour = 'Honeydew' }
        } else { $o.Cells = @{} }   # a grey row stays grey
        $rows.Add([pscustomobject]$o)
    }
    $script:Gui['SoftwareRebuilding'] = $true
    try { Set-GridRows -Grid $lv -Rows @($rows.ToArray()) -RowColour { param($row) $row.Colour } -ToolTipProperty 'Tip' -CellColourProperty 'Cells' } finally { $script:Gui['SoftwareRebuilding'] = $false }
    $script:Gui['SoftwareCount'].Text = ('{0} server row(s) shown, {1} ticked' -f $lv.Items.Count, $lv.CheckedItems.Count)
}

function Start-SoftwareInventoryRefresh {
    # a one-shot 300 ms timer: "Tick all" on hundreds of servers becomes one rebuild of the inventory list
    if (-not $script:Gui['SoftwareInvTimer']) {
        $t = New-Object System.Windows.Forms.Timer; $t.Interval = 300
        $t.Add_Tick({ $this.Stop(); Update-SoftwareInventoryGrid })
        $script:Gui['SoftwareInvTimer'] = $t
    }
    $script:Gui['SoftwareInvTimer'].Stop(); $script:Gui['SoftwareInvTimer'].Start()
}

function Get-SoftwareInvKey {
    param($Row)
    return ('{0}|{1}|{2}|{3}|{4}' -f ([string]$Row.Server).ToLower(), $Row.Product, $Row.Version, $Row.KeyName, $Row.Hive)
}

function Update-SoftwareInventoryGrid {
    # The products of the ticked servers (else every server shown).  By default only what needs attention (Behind,
    # Stale, Ageing, End of life, dormant); "Show all products" lists everything.  Capped at MaxSoftwareGridRows.
    $grid = $script:Gui['SoftwareInvGrid']
    if (-not $grid) { return }
    $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid']); $scope = ('{0} ticked server(s)' -f $servers.Count)
    if ($servers.Count -eq 0) { $servers = @(Get-GridAllKeys -Grid $script:Gui['SoftwareServerGrid']); $scope = ('all {0} server(s) shown' -f $servers.Count) }
    $all = @(Get-SoftwareRows -Servers $servers)
    $showAll = ($script:Gui['SoftwareInvAll'] -and $script:Gui['SoftwareInvAll'].Checked)
    $q = ([string]$script:Gui['SoftwareInvFilter'].Text).Trim()
    $pick = New-Object System.Collections.Generic.List[object]
    $cut = (Get-Date).AddDays(-30.4 * $script:Config.DormantMonths); $when = [datetime]::MinValue
    $curServer = $null; $curMap = $null
    foreach ($r in $all) {
        if ($q -and ($r.Product + ' ' + $r.Publisher + ' ' + $r.Server).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $use = ''
        if (-not $showAll -and $r.Verdict -notin 'Behind', 'Stale', 'Ageing', 'End of life') {
            # dormant (the Get-ProductUse rule, inline: this loop sees every product of every server): an old install date,
            # a real install folder, and nothing on the server running from it
            if (-not [datetime]::TryParseExact([string]$r.Installed, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$when) -or $when -gt $cut) { continue }
            $loc = ([string]$r.Location).TrimEnd('\').ToLower()
            if ($loc.Length -lt 8) { continue }
            if ($r.Server -ne $curServer) { $curServer = $r.Server; $curMap = Get-ServerUseMap -Server $r.Server }
            if (-not $curMap -or $curMap[$loc]) { continue }
            $use = 'dormant'
        }
        $pick.Add([pscustomobject]@{ Row = $r; Use = $use })
    }
    $items = @($pick.ToArray())
    if ($items.Count -gt 1) {
        $rank = @{ 'End of life' = '0'; 'Behind' = '1'; 'Stale' = '2'; 'Ageing' = '3'; 'Unknown' = '4'; 'Current' = '5' }
        $keys = New-Object string[] $items.Count
        for ($i = 0; $i -lt $items.Count; $i++) { $rk = $rank[[string]$items[$i].Row.Verdict]; if (-not $rk) { $rk = '9' }; $keys[$i] = $rk + '|' + $items[$i].Row.Server + '|' + $items[$i].Row.Product }
        [Array]::Sort($keys, $items, [System.StringComparer]::OrdinalIgnoreCase)
    }
    $cap = [int]$script:Config.MaxSoftwareGridRows; $capped = $false
    if ($cap -gt 0 -and $items.Count -gt $cap) { $items = @($items[0..($cap - 1)]); $capped = $true }
    $rows = foreach ($x in $items) {
        $r = $x.Row
        $use = $x.Use; if (-not $use) { $use = Get-ProductUse -Row $r }
        $rv = Get-UninstallVerdict -Row $r
        [pscustomobject]@{ Server = $r.Server; Product = $r.Product; Version = $r.Version; Publisher = $r.Publisher; Installed = $r.Installed; Verdict = $r.Verdict; Use = $use; Removal = $rv.Cell; Reason = ($r.Reason + ' | removal: ' + $rv.Reason); KeyName = $r.KeyName; Msi = $r.Msi; Quiet = $r.Quiet; Hive = $r.Hive; Location = $r.Location }
    }
    $ticked = @{}; foreach ($it in @($grid.CheckedItems)) { if ($it.Tag) { $ticked[(Get-SoftwareInvKey $it.Tag)] = $true } }
    $colour = { param($row) if ($row.Removal -in 'Protected', 'SOE') { 'Gainsboro' } elseif ($row.Use -eq 'dormant') { 'NavajoWhite' } else { switch ($row.Verdict) { 'Behind' { 'LemonChiffon' } 'Stale' { 'LemonChiffon' } 'Ageing' { 'NavajoWhite' } 'End of life' { 'MistyRose' } 'Current' { 'Honeydew' } default { 'White' } } } }
    $script:Gui['SoftwareInvRebuilding'] = $true
    try {
        Set-GridRows -Grid $grid -Rows @($rows) -RowColour $colour -ToolTipProperty 'Reason' -NoKeepChecks
        if ($ticked.Count -gt 0) { $script:GridProgrammatic = $true; try { foreach ($it in $grid.Items) { if ($ticked.ContainsKey((Get-SoftwareInvKey $it.Tag))) { $it.Checked = $true } } } finally { $script:GridProgrammatic = $false } }
    } finally { $script:Gui['SoftwareInvRebuilding'] = $false }
    Update-SoftwareInvLabel -Total $all.Count -Scope $scope -ShowAll $showAll -Capped $capped
}

function Update-SoftwareInvLabel {
    param([int]$Total = -1, [string]$Scope = '', [bool]$ShowAll = $false, [bool]$Capped = $false)
    $grid = $script:Gui['SoftwareInvGrid']
    if ($Total -ge 0) { $script:Gui['SoftwareInvState'] = @{ Total = $Total; Scope = $Scope; ShowAll = $ShowAll; Capped = $Capped } }
    $st = $script:Gui['SoftwareInvState']; if (-not $st) { return }
    if ($st.Total -eq 0) { $script:Gui['SoftwareInvLabel'].Text = 'nothing collected yet - press Check on the toolbar'; return }
    # the ticked count first: it is what the UNINSTALL button acts on, and the end of a long line is cut on a narrow window
    $text = ('{0} ticked for removal - {1} of {2} products on {3} ({4})' -f $grid.CheckedItems.Count, $grid.Items.Count, $st.Total, $st.Scope, $(if ($st.ShowAll) { 'all' } else { 'needing attention or dormant; "Show all products" for the rest' }))
    if ($st.Capped) { $text = ('first {0} rows only - tick fewer servers or filter.  ' -f $script:Config.MaxSoftwareGridRows) + $text }
    $script:Gui['SoftwareInvLabel'].Text = $text
}

function Get-SoftwareDetailsHtml {
    param([string]$Name)
    $st = Get-CollectorResult -Name 'SoftwareState' -Server $Name
    $inv = Get-CollectorResult -Name 'Inventory' -Server $Name
    $facts = @()
    if ($st -and $st.Reachable) { $facts += , @('Checked', $st.Checked.ToString('yyyy-MM-dd HH:mm:ss')); $facts += , @('Hardware', ('{0} {1}' -f $st.Manufacturer, $st.Model)); $facts += , @('Windows Installer', $(if ($st.MsiBusy) { 'busy' } else { 'idle' })) }
    $status = $script:ServerStatus[$Name]
    if ($status -and $status.Reachable) { if (Test-TrellixInUse) { $facts += , @('Trellix Agent', $(if ((Get-TrellixAgentInfo -Status $status).Present) { (Get-TrellixAgentText -Status $status) + ' (masvc, macmnsvc)' } else { 'not on this server' })) } }
    elseif ($st) { $facts += , @('Checked', $st.Checked.ToString('yyyy-MM-dd HH:mm:ss')); $facts += , @('State', ('unreachable: ' + $st.Error)) }
    $verdicts = @()
    foreach ($f in @($script:SoftwareFiles)) {
        $v = Get-SoftwareVerdict -Server $Name -PackageFile $f
        $verdicts += [pscustomobject]@{ Light = $v.Light; Package = $f.Id; File = $f.File; Version = $f.Version; Installed = $v.Installed; Verdict = $v.Cell; Reason = $v.Reason }
    }
    $sections = @(
        @{ Heading = 'Installer files in software\ against this server'; Rows = $verdicts; Columns = @('Light', 'Package', 'Version', 'Installed', 'Verdict', 'Reason', 'File'); Note = 'The same verdict as the grid (Get-SoftwareVerdict). INSTALL / UPDATE rows are what the button would do; (staged) = the file is already in C:\PatchStaging\software\<package>\ with the same size.' })
    if ($st -and $st.Reachable) {
        $sections += @{ Heading = 'Staged installers on the server'; Rows = @(ConvertFrom-PipeLines -Lines @($st.Staged) -Columns @('File', 'Bytes', 'Copied')); Columns = @('File', 'Bytes', 'Copied') }
        $sections += @{ Heading = 'Toolkit tasks on the server (\WinRMToolkit\)'; Rows = @(Get-ServerTaskRows -Server $Name); Columns = @('Task', 'State', 'LastResult', 'LastRun', 'Item'); Note = 'Normally empty: a task is removed as soon as its result is recorded. LastResult 267011 = queued, never started; 267009 = running.' }
        $sections += @{ Heading = 'The server''s own change record (C:\PatchStaging\change-log.txt, newest 25 lines)'; Lines = @($st.ServerChangeLog); Note = 'Written on the server by every install, removal and reboot this tool makes; the same lines are in its Application log (OfflinePatcher events 900 patch, 910 software, 920 reboot).' }
    }
    $sections += Get-ChangeLogSection -Server $Name
    if ($inv -and $inv.Reachable) {
        $prod = @(Get-SoftwareRows -Servers @($Name) | ForEach-Object { $rv = Get-UninstallVerdict -Row $_; [pscustomobject]@{ Light = $_.Light; Product = $_.Product; Version = $_.Version; Publisher = $_.Publisher; Installed = $_.Installed; Verdict = $_.Verdict; Use = (Get-ProductUse -Row $_); Removal = $rv.Cell; Reason = $_.Reason } })
        $sections += @{ Heading = ('Products (inventory {0})' -f $inv.Checked.ToString('HH:mm:ss')); Rows = $prod; Columns = @('Light', 'Product', 'Version', 'Publisher', 'Installed', 'Verdict', 'Use', 'Removal', 'Reason'); Note = 'Removal: MSI or quiet string = UNINSTALL can remove it; by hand = no silent uninstall; Protected / SOE = never removed by the tool. Use: in use = a service, process or task points into its folder; dormant = installed over DormantMonths ago and nothing uses it.' }
    }
    return (New-DetailsHtml -Title "Software: $Name" -Subtitle 'installer verdicts, staged files, toolkit tasks, the change record and the products' -Console 'Software' -Facts $facts -Sections $sections)
}

function Show-SoftwareDetails {
    param([string]$Name)
    if (-not (Get-CollectorResult -Name 'SoftwareState' -Server $Name) -and -not (Get-CollectorResult -Name 'Inventory' -Server $Name)) { Show-GuiNotice "$Name has not been checked yet. Tick it and press 'Check software (ticked)'."; return }
    Show-DetailsWindow -Title "Software: $Name" -Html (Get-SoftwareDetailsHtml -Name $Name)
}

function Get-SoftwareHelpHtml {
    $sections = @()
    $mock = New-MockGrid -TrellixColumns -Headers @('Server', 'Group', 'WinRM', 'All packages', 'VMwareTools', 'Google Chrome', 'Hardware', 'Pending reboot', 'Trellix Agent', 'Staged', 'Toolkit task', 'Products', 'Checked at') -Rows @(
        @{ Colour = 'white'; Cells = @('server-a', 'Group-1', '', 'not checked', 'not checked', 'not checked', '', '', '', '', '', '', '') },
        @{ Colour = 'lightgray'; Cells = @('server-b', 'Group-1', 'FAILED', '?', '?', '?', '', '', '', '', '', '', '') },
        @{ Colour = 'lemonchiffon'; CellColours = @{ 5 = 'palegreen' }; Cells = @('server-c', 'Group-2', 'OK', '2 to do (1 UPDATE, 1 INSTALL)', 'UPDATE -> 12.5.0.24276846 (staged)', 'Installed 156.0.8078.48', 'VMware VM', 'YES: CBS:RebootPending', 'Running (Auto)', '1', '', '84', '10:02:11') },
        @{ Colour = 'lightcyan'; CellColours = @{ 5 = 'palegreen'; 8 = 'navajowhite' }; Cells = @('server-d', 'Group-2', 'OK', '1 to do (1 UPDATE)', 'Task running', 'Installed 156.0.8078.48', 'VMware VM', 'no', 'STOPPED (Disabled)', '1', 'Running VMware Tools 12.5.0.24276846 (Update)', '79', '10:02:12') },
        @{ Colour = 'honeydew'; CellColours = @{ 3 = 'palegreen'; 4 = 'palegreen'; 5 = 'palegreen'; 8 = 'navajowhite' }; Cells = @('server-e', 'Group-3', 'OK', '12 of 12 current', 'Installed 12.5.0.24276846', 'Newer 157.0.1.2', 'VMware VM', 'YES: software: VMware Tools 12.5.0.24276846 (Update) (exit 3010)', 'STOPPED (Disabled)', '0', '', '91', '10:02:12') },
        @{ Colour = 'lemonchiffon'; CellColours = @{ 5 = 'palegreen' }; Cells = @('server-f', 'Group-3', 'OK', '1 to do (1 INSTALL)', 'N/A (hardware)', 'Installed 156.0.8078.48', 'HPE ProLiant DL380 Gen10', 'no', 'Running (Auto)', '0', '', '120', '10:02:13') })
    $rows = New-HelpTable -TrellixRows -Headers @('Row colour', 'It means') -Rows @(
        @((Get-HelpSwatch 'white' 'White'), 'Not checked yet, or nothing to do and not everything current.'),
        @((Get-HelpSwatch 'lightgray' 'Grey'), 'WinRM gave no answer or refused the login (hover for the reason).'),
        @((Get-HelpSwatch 'lemonchiffon' 'Yellow'), 'At least one package - shown as a column or not - would INSTALL or UPDATE (hover the row for the list).'),
        @((Get-HelpSwatch 'lightcyan' 'Light blue'), 'A toolkit task is running on the server right now.'),
        @((Get-HelpSwatch 'honeydew' 'Green'), 'Every package that applies is at or above the file''s version.'),
        @((Get-HelpSwatch 'palegreen' 'Green cell'), 'In any row: that package''s version (or a newer one) is installed. A yellow cell is what INSTALL / UPDATE would do.'),
        @((Get-HelpSwatch 'navajowhite' 'Orange cell'), 'The Trellix Agent cell only, in any row: the two ePO agent services (masvc, macmnsvc) are stopped or disabled - set so by INSTALL / UPDATE or PATCH IT! with the box ticked, or by hand. ePO hears nothing from the server meanwhile; a scan warns about it. After the install and the reboot, tick the server and press "Start Trellix Agent (ticked)". "Running (Auto)" is the normal state; empty = the agent is not on the server.'))
    $sections += @{ Heading = 'The server grid: one example row per colour'; Note = ('One column per package shown - at most {0} (MaxSoftwareColumns, Settings tab), chosen in the Software library window - with the ticked version of it, else the newest usable file. When the library holds more packages than that, All packages counts what every package would do on the server. Double-click a row for its page: every package''s verdict, staged files, tasks, the server''s own change record and the products. Pending reboot "YES: software: ..." = an install or removal since the server''s last boot ended with exit 3010 (reboot suppressed): Reboot (ticked) counts it as pending, and the OS patches are not blocked by it.' -f $script:Config.MaxSoftwareColumns); Html = ($mock + $rows) }
    $sections += @{ Heading = 'Package cells: every value'; Note = 'The grid, the plan and the report all use Get-SoftwareVerdict, so the grid never promises what the plan refuses.'; Html = (New-HelpTable -Headers @('Cell', 'It means', 'Next step') -Rows @(
        @((Get-HelpCell 'not checked'), 'No inventory yet, or the hardware has not been read (a package with Requires).', 'Press Check.'),
        @((Get-HelpCell '?' 'lightgray'), 'The server could not be reached.', 'Fix WinRM first.'),
        @((Get-HelpCell 'INSTALL 12.5.0.24276846' 'lemonchiffon'), 'Not installed; the package allows a new install.', 'Tick server and file, INSTALL / UPDATE.'),
        @((Get-HelpCell 'UPDATE -> 12.5.0.24276846' 'lemonchiffon'), 'An older version is installed; the package allows Update.', 'Tick server and file, INSTALL / UPDATE.'),
        @((Get-HelpCell 'UPDATE -> 12.5.0.24276846 (staged)' 'lemonchiffon'), 'As above, and the installer is already on the server (C:\PatchStaging\software\<package>\, same name and size): no copy needed in the window.', 'INSTALL / UPDATE in the change window.'),
        @((Get-HelpCell 'Installed 12.5.0.24276846' 'palegreen'), 'The file''s version is installed.', 'Nothing.'),
        @((Get-HelpCell 'Newer 13.0.0.24696409' 'palegreen'), 'A newer version than the file is installed.', 'Nothing (or put the newer installer in the folder).'),
        @((Get-HelpCell '2 to do (1 UPDATE, 1 INSTALL)' 'lemonchiffon'), 'All packages: what every package of the library would do on this server - shown as a column or not. Hover the row for the list; ", 1 blocked" counts installers that failed vetting.', 'Software library... to show those packages, then tick their installers.'),
        @((Get-HelpCell '12 of 12 current' 'palegreen'), 'All packages: every package that applies is installed at the file''s version or newer.', 'Nothing.'),
        @((Get-HelpCell 'Behind'), 'Older version installed, but the package does not allow Update.', 'Edit... next to its installer and tick Update, if an update is wanted.'),
        @((Get-HelpCell 'Not installed'), 'Not installed and the package allows Update only.', 'Nothing.'),
        @((Get-HelpCell 'N/A (hardware)' 'whitesmoke'), 'The package is for other hardware (VMware Tools: VMware virtual machines only).', 'Nothing.'),
        @((Get-HelpCell 'Blocked: file' 'mistyrose'), 'The installer file failed vetting: version unreadable, signature not valid, signer not in Signers, or no reboot suppression in its arguments.', 'Hover its row in the installer list; fix the file, or Edit... the package.'),
        @((Get-HelpCell 'Task running'), 'A toolkit task is running on the server.', 'Wait for it; Check again.'))) }
    $sections += @{ Heading = 'The inventory list (bottom): what can be removed'; Html = (New-HelpTable -Headers @('Column / value', 'It means') -Rows @(
        @((Get-HelpCell 'Ageing' 'navajowhite'), 'Verdict: the same currency verdict as the O/S Patching software grid (Current, Behind, Stale, Ageing, End of life, Unknown).'),
        @((Get-HelpCell 'dormant' 'navajowhite'), ('Use: installed over {0} months ago (DormantMonths) and no service, process or scheduled task points into its folder - the H-SW-01 rule. A candidate for removal: confirm with the owner.' -f $script:Config.DormantMonths)),
        @((Get-HelpCell 'in use (service Foo)'), 'Use: something on the server runs from its folder. Removing it stops that.'),
        @((Get-HelpCell 'MSI'), 'Removal: msiexec /x <product code> /qn /norestart REBOOT=ReallySuppress.'),
        @((Get-HelpCell 'quiet string'), 'Removal: the product''s own QuietUninstallString, with its no-restart switches added by the tool (msiexec: /norestart REBOOT=ReallySuppress; Inno Setup: /NORESTART /SUPPRESSMSGBOXES; WiX bundles: /norestart) - no restart.'),
        @((Get-HelpCell 'quiet (may restart)'), 'Removal: the product''s own QuietUninstallString, from an uninstaller with no known no-restart switch - it MAY RESTART THE SERVER by itself. The removal plan and the last confirmation say so; remove it by hand in a reboot window if that is not acceptable. (An inventory from before 2026-10-22 shows every quiet string this way until the server is checked again.)'),
        @((Get-HelpCell 'by hand'), 'Removal: no silent uninstall known - the tool will not remove it.'),
        @((Get-HelpCell 'Protected' 'gainsboro'), 'Removal: never - ProtectedProducts in software-packages.psd1, or a package that does not allow Uninstall (VMware Tools). For a package you registered: Edit... next to its installer and tick Uninstall.'),
        @((Get-HelpCell 'SOE' 'gainsboro'), 'Removal: never - the server''s SOE standard requires it (a required software or agent item).'))) }
    $sections += @{ Heading = 'The buttons'; Note = ('Blue asks the servers (read-only). {0} change a server; STAGE ONLY (steel blue) copies files onto the servers without installing; green saves on this PC; grey works on this PC only.' -f $(if (Test-TrellixInUse) { 'Red, coral, khaki and the two wheat-coloured Trellix Agent buttons' } else { 'Red, coral and khaki' })); Html = (New-HelpTable -TrellixRows -Headers @('Button', 'What it does', 'Warnings before anything changes') -Rows @(
        @(((Get-HelpButton 'Check software (ticked)' 'lightskyblue') + ' ' + (Get-HelpButton 'Check software (all shown)' 'lightskyblue')), 'Status, inventory and the software state (hardware, staged files, toolkit tasks, the server''s change record). A server whose Trellix Agent services are stopped is named in a warning.', 'none - read-only, works during an install'),
        @(('<span class="btn">&#9745; Stop the Trellix Agent services first</span>'), 'A tick box above STAGE ONLY, on by default (StopTrellixAgentForInstall on the Settings tab). Ticked: right after the re-check, INSTALL / UPDATE sets the two Trellix Agent services (masvc, macmnsvc) to Disabled and stops them on each server, under the install''s change record, before anything is copied - the field test (October 2026) saw installs fail and roll back with the agent running. A server where that fails is not installed; untick the box to install with the agent running. STAGE ONLY and UNINSTALL never touch the services.', 'part of INSTALL / UPDATE'),
        @((Get-HelpButton 'STAGE ONLY  (ticked installers, ticked servers)' 'lightsteelblue'), 'Copies the ticked installers to C:\PatchStaging\software on the ticked servers and verifies them. Nothing is installed.', 'the plan'),
        @((Get-HelpButton 'INSTALL / UPDATE  (ticked installers, ticked servers)' 'tomato'), 'Fresh check, then the ticked installers on the ticked servers, the reboot suppressed.', 'the plan, the change record, the pre-action confirmations (Settings tab), a re-check'),
        @((Get-HelpButton 'UNINSTALL (ticked products)' 'lightcoral'), 'Removes the products ticked in the inventory list.', 'the plan, the change record, the pre-action confirmations (Settings tab), a last confirmation naming every product, a re-check'),
        @((Get-HelpButton 'Reboot (ticked)' 'khaki'), 'The O/S Patching console''s reboot: pending servers by default, refused while servicing runs.', 'Yes/No per set, the change record'),
        @(((Get-HelpButton 'Start Trellix Agent (ticked)' 'wheat') + ' ' + (Get-HelpButton 'Stop Trellix Agent (ticked)' 'wheat')), 'The two agent services on the ticked servers by hand: Start = Automatic and running (after the install and the reboot - the agent reports to ePO again), Stop = Disabled and stopped. Fresh status first; servers without the agent or already in that state are skipped; Start is refused while an OS patch run is still open on the server. Each server keeps its own record (Application event 940, C:\PatchStaging\change-log.txt).', 'a Yes/No naming the servers (No is the default), the change record of ''Trellix Agent services'' (a change record or a maintenance activity by default)'),
        @((Get-HelpButton 'Register...'), 'Next to each * NEW installer in the yellow box under the installer list (a .msi or .exe in any folder under software\ that no package claims yet): a form filled from the file, checked as you type, written into data\software-packages.psd1. Uninstall starts ticked: unticked, the product is protected and UNINSTALL refuses it.', 'none - nothing touches a server'),
        @((Get-HelpButton 'Software library...'), ('Above the installer list: every package with what its newest installer would do on the servers shown - how many to update, to install, already current, and the newest version deployed. Yellow = the library holds a newer version than some servers have (or a new install), green = current everywhere checked, red = installer blocked. Tick up to {0} to show as grid columns and in the installer list; Most needed ticks the ones with the most to do. The choice is kept (settings\software-shown.json).' -f $script:Config.MaxSoftwareColumns), 'none - nothing touches a server'),
        @((Get-HelpButton 'Edit...'), 'Next to each installer in the installer list: its package in the same form, filled from the entry. Save changes rewrites only that entry in data\software-packages.psd1 (its comments and any field the form does not show are kept).', 'none - nothing touches a server'),
        @((Get-HelpButton 'Change log'), 'Every install, removal and reboot this tool made, with its change record (changes\change-log.csv).', 'none'),
        @((Get-HelpButton 'Where do I get software?'), 'Download and silent-install notes, VMware Tools first.', 'none'),
        @((Get-HelpButton 'Report (HTML + CSV)'), 'reports\Software-<date>.html and .csv: package verdicts, removal candidates, the change log.', 'none'))) }
    $sections += @{ Heading = 'What happens on the server'; Lines = @(
        'The run script checks, once: no toolkit task running, nothing servicing (dism, busy TiWorker, Windows Update), Windows Installer idle, enough free disk.',
        'Then per item: the staged file''s SHA256 and signer again, the hardware again, the installed version again - then the command line is built from software-packages.psd1 and queued as a one-shot SYSTEM task in \WinRMToolkit\.',
        ('The tool asks every {0} s. A finished item is recorded on the server (result file, Application event 910, C:\PatchStaging\change-log.txt) and the next one starts. Exit 0, 3010 and 1641 count as success; 3010 = reboot with the OS patches.' -f $script:Config.SoftwarePollSec),
        ('After {0} min (SoftwareTimeoutMin) the items that never started are withdrawn and a running one is reported UNKNOWN: it carries on; Check shows its state and exit code in the Toolkit task column (an exit 3010 counts as a pending reboot) and, once it has finished, adds its real result to the change log on this PC (once); the next software run on that server records it there (event 910, change-log.txt).' -f $script:Config.SoftwareTimeoutMin),
        'If the window is closed or the connection is lost, nothing new starts on its own; the next run records what was left behind.') }
    return (New-DetailsHtml -Title 'Software console: what the rows, cells and buttons mean' -Subtitle 'every example is drawn the way the window draws it' -Console 'Software' -Facts @(@('Packages', @((Get-SoftwareCatalogue).Packages | Where-Object { $_ }).Count), @('Installer files', @($script:SoftwareFiles).Count), @('Decision functions', 'Get-SoftwareVerdict, Get-UninstallVerdict')) -Sections $sections)
}

function Export-SoftwareReport {
    $servers = @(Get-GridAllKeys -Grid $script:Gui['SoftwareServerGrid'])
    # lists, not +=: 500 servers x 20 packages plus their removal candidates is tens of thousands of rows
    $summary = New-Object System.Collections.Generic.List[object]; $verdicts = New-Object System.Collections.Generic.List[object]; $removal = New-Object System.Collections.Generic.List[object]
    # every package of the library, not only the ones shown as columns: the report is the record
    $files = @(Get-SoftwareLibraryFiles)
    $null = Get-SoftwareRows -Servers $servers
    $byServer = @{}; if ($script:SoftwareRowCache) { $byServer = $script:SoftwareRowCache.ByServer }
    foreach ($name in $servers) {
        $st = Get-CollectorResult -Name 'SoftwareState' -Server $name
        $lights = @(); $mine = @()
        $light = 'Grey'; $state = 'not checked'
        $mineRows = @(); $list = $byServer[$name.ToLower()]; if ($list) { $mineRows = $list.ToArray() }
        foreach ($f in $files) {
            $v = Get-SoftwareVerdictCached -Server $name -PackageFile $f -Products $mineRows
            $mine += [pscustomobject]@{ Id = $f.Id; Verdict = $v }
            $lights += $v.Light
            $verdicts.Add([pscustomobject]@{ Server = $name; Package = $f.Id; File = $f.File; Version = $f.Version; Installed = $v.Installed; Verdict = $v.Cell; Reason = $v.Reason; Light = $v.Light })
        }
        $anyGo = @($mine | Where-Object { $_.Verdict.Go }).Count -gt 0
        if ($lights -contains 'Red') { $light = 'Red'; $state = 'installer blocked' } elseif ($lights -contains 'Amber') { $light = 'Amber'; $state = $(if ($anyGo) { 'install or update ready' } else { 'behind - Update not allowed, or the versions cannot be compared' }) } elseif ($lights -contains 'Green') { $light = 'Green'; $state = 'current for the installers present' }
        if ($st -and -not $st.Reachable) { $light = 'Grey'; $state = 'unreachable: ' + $st.Error }
        $sum = Get-SoftwareSummary -Verdicts $mine
        $summary.Add([pscustomobject]@{ Server = $name; Light = $light; State = $state; Hardware = (Get-ServerManufacturer -Server $name); Staged = $(if ($st -and $st.Reachable) { @($st.Staged).Count } else { '' }); Packages = $sum.Text; 'To do' = ($sum.Todo -join '; ') })
        foreach ($r in $mineRows) {
            $use = Get-ProductUse -Row $r
            if ($use -ne 'dormant' -and $r.Verdict -notin 'Ageing', 'End of life') { continue }
            $rv = Get-UninstallVerdict -Row $r
            $removal.Add([pscustomobject]@{ Server = $name; Product = $r.Product; Version = $r.Version; Installed = $r.Installed; Verdict = $r.Verdict; Use = $use; Removal = $rv.Cell; Reason = $rv.Reason; Light = $r.Light })
        }
    }
    $summary = @($summary.ToArray()); $verdicts = @($verdicts.ToArray()); $removal = @($removal.ToArray())
    $log = @(Get-ChangeLogRows | Where-Object { $label = ([string]$_.Server -split '\.')[0]; @($servers | Where-Object { ($_ -split '\.')[0] -ieq $label }).Count -gt 0 })
    $notes = @(('Installer files: ' + ((@($script:SoftwareFiles) | ForEach-Object { "$($_.Id) $($_.Version)$(if ($_.Blocked) { ' [blocked]' })" }) -join ', ')), ('Catalogue: data\software-packages.psd1 as of ' + (Get-SoftwareCatalogue).AsOf))
    return (Export-ConsoleReport -Console 'Software' -Title 'Software report' -Summary $summary -SummaryColumns @('Server', 'Light', 'State', 'Hardware', 'Staged', 'Packages', 'To do') -Notes $notes -Sections @(
        @{ Name = 'Package verdicts'; Rows = $verdicts; Columns = @('Server', 'Package', 'Version', 'Installed', 'Verdict', 'Reason', 'File', 'Light') },
        @{ Name = 'Removal candidates (dormant, ageing, end of life)'; Rows = $removal; Columns = @('Server', 'Product', 'Version', 'Installed', 'Verdict', 'Use', 'Removal', 'Reason', 'Light') },
        @{ Name = 'Change log'; Rows = $log; Columns = $script:ChangeLogColumns }))
}

# ---------------------------------------------------------------------
#  The tab
# ---------------------------------------------------------------------
function New-SoftwareConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Software' -Text 'Software'

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Horizontal'
    $tab.Controls.Add($split)

    # ---- server grid (top) ----
    $lv = New-ConsoleGrid -Columns @(@{ Name = 'Server'; Width = 170 })
    $lv.Add_DoubleClick({
        if ($script:Gui['Busy']) { Write-PatchLog 'Busy - the details window is available again when the current action finishes' 'WARN'; return }
        if ($this.SelectedItems.Count -gt 0) { Show-SoftwareDetails -Name $this.SelectedItems[0].Text }
    })
    $lv.Add_ItemChecked({ if ($script:Gui['SoftwareRebuilding']) { return }; $script:Gui['SoftwareCount'].Text = ('{0} server row(s) shown, {1} ticked' -f $this.Items.Count, $this.CheckedItems.Count); Start-SoftwareInventoryRefresh })
    $head = New-GridHeader -Heading 'SERVERS' -Detail '0 server row(s) shown, 0 ticked' -Tip 'One column per package; tick with the checkbox; double-click a row for its page'
    $split.Panel1.Controls.Add($lv); $split.Panel1.Controls.Add($head.Panel); $lv.BringToFront()
    $script:Gui['SoftwareServerGrid'] = $lv; $script:Gui['SoftwareCount'] = $head.Info

    # ---- inventory list (bottom): heading, a filter strip, the grid ----
    $invPanel = New-Object System.Windows.Forms.Panel; $invPanel.Dock = 'Fill'
    $invHead = New-GridHeader -Heading 'INSTALLED SOFTWARE  (tick products to remove)' -Detail 'nothing collected yet - press Check on the toolbar' -Tip 'The products of the ticked servers (else all shown). Removal says whether UNINSTALL may remove it and how; Use says whether anything on the server runs from its folder. Grey rows are protected (never removed); orange rows are ageing or dormant.'
    $strip = New-Object System.Windows.Forms.Panel; $strip.Dock = 'Top'; $strip.Height = 30
    $fl = New-Object System.Windows.Forms.Label; $fl.Text = 'Filter:'; $fl.Location = New-Object System.Drawing.Point(6, 8); $fl.AutoSize = $true
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Location = New-Object System.Drawing.Point(50, 4); $filter.Width = 220
    $script:Gui['Tips'].SetToolTip($filter, 'Part of a product, publisher or server name (plain text)')
    $filter.Add_TextChanged({ Start-SoftwareInventoryRefresh })
    $invAll = New-Object System.Windows.Forms.CheckBox; $invAll.Text = 'Show all products'; $invAll.AutoSize = $true; $invAll.Location = New-Object System.Drawing.Point(285, 6)
    $script:Gui['Tips'].SetToolTip($invAll, 'Unticked: only products needing attention (Behind, Stale, Ageing, End of life) or dormant. Ticked: every product.')
    $invAll.Add_CheckedChanged({ Update-SoftwareInventoryGrid })
    $strip.Controls.AddRange(@($fl, $filter, $invAll))   # no colour key on the panel: the heading's tool tip and the Help page carry it
    $invGrid = New-ConsoleGrid -Columns @(@{ Name = 'Server'; Width = 150 }, @{ Name = 'Product'; Width = 280 }, @{ Name = 'Version'; Width = 105 }, @{ Name = 'Publisher'; Width = 150 }, @{ Name = 'Installed'; Width = 80 }, @{ Name = 'Verdict'; Width = 80 }, @{ Name = 'Use'; Width = 150 }, @{ Name = 'Removal'; Width = 85 }, @{ Name = 'Reason'; Width = 380; Fill = $true })
    $invGrid.Add_ItemChecked({ if ($script:Gui['SoftwareInvRebuilding']) { return }; Update-SoftwareInvLabel })
    $invPanel.Controls.Add($invGrid); $invPanel.Controls.Add($strip); $invPanel.Controls.Add($invHead.Panel); $invGrid.BringToFront()
    $split.Panel2.Controls.Add($invPanel)
    $script:Gui['SoftwareInvGrid'] = $invGrid; $script:Gui['SoftwareInvLabel'] = $invHead.Info; $script:Gui['SoftwareInvFilter'] = $filter; $script:Gui['SoftwareInvAll'] = $invAll

    # ---- right panel: installer files + the buttons ----
    $divider = New-Object System.Windows.Forms.Splitter
    $divider.Dock = 'Right'; $divider.Width = 6; $divider.BackColor = 'Gainsboro'; $divider.MinSize = 320; $divider.MinExtra = 500
    $tab.Controls.Add($divider)
    $right = New-Object System.Windows.Forms.Panel
    $right.Dock = 'Right'; $right.Width = 420; $right.Padding = New-Object System.Windows.Forms.Padding(8); $right.AutoScroll = $true
    $tab.Controls.Add($right)
    $script:Gui['RightPanels'] += $right   # the window's first size shows every control of it (Set-ToolkitStartSize)
    $lblP = New-Object System.Windows.Forms.Label
    $lblP.Text = 'Installers (tick the version to deploy):'; $lblP.Location = New-Object System.Drawing.Point(10, 8); $lblP.AutoSize = $true
    $right.Controls.Add($lblP)
    # a big library: the list shows at most MaxSoftwareColumns packages; the library window picks which, and shows them all
    $libBtn = New-GuiButton -Text 'Software library...' -X 235 -Y 3 -W 170 -H 24 -ReadOnly -Tip 'Every package with what it would do on the servers shown (yellow = newer than deployed); tick the ones to show here and as grid columns' -OnClick {
        Invoke-GuiAction -Name 'Software library' -ReadOnly -Action { Show-SoftwareLibrary } }
    $libBtn.Anchor = 'Top, Right'   # stays at the right edge when the divider widens the panel
    $right.Controls.Add($libBtn); $script:Gui['SoftwareLibraryButton'] = $libBtn
    # the installer list: one row per installer - tick box, details, its own Edit... (Update-SoftwarePackageList)
    $pkgRows = New-Object System.Windows.Forms.Panel
    $pkgRows.Location = New-Object System.Drawing.Point(10, 30); $pkgRows.Size = New-Object System.Drawing.Size(395, 90)
    $pkgRows.BorderStyle = 'FixedSingle'; $pkgRows.BackColor = 'White'; $pkgRows.AutoScroll = $true
    $script:Gui['SoftwareTicks'] = @{}
    # a tick redraws the package columns a moment later (one redraw for several quick ticks)
    $colTimer = New-Object System.Windows.Forms.Timer; $colTimer.Interval = 200
    $colTimer.Add_Tick({ $this.Stop(); Update-SoftwareServerGrid })
    $script:Gui['SoftwareColumnTimer'] = $colTimer
    $right.Controls.Add($pkgRows)
    $script:Gui['SoftwarePackageRows'] = $pkgRows
    $lblFolder = New-Object System.Windows.Forms.Label
    $lblFolder.Location = New-Object System.Drawing.Point(10, 124); $lblFolder.Size = New-Object System.Drawing.Size(395, 34); $lblFolder.ForeColor = 'Gray'
    $right.Controls.Add($lblFolder)
    $script:Gui['SoftwareFolderLabel'] = $lblFolder
    # NEW installers: one row each, with its own Register button, in a yellow box filled by Update-SoftwareNewPanel; the
    # controls underneath move down by the box's height (it is hidden when nothing is new)
    $newPanel = New-Object System.Windows.Forms.Panel
    $newPanel.Location = New-Object System.Drawing.Point(10, 162); $newPanel.Size = New-Object System.Drawing.Size(395, 0)
    $newPanel.BackColor = 'LightYellow'; $newPanel.BorderStyle = 'FixedSingle'; $newPanel.AutoScroll = $true; $newPanel.Visible = $false
    $right.Controls.Add($newPanel)
    $script:Gui['SoftwareNewPanel'] = $newPanel
    # a row's Register... / Edit... only records the job: the form opens a moment later, after the click has finished,
    # because saving rebuilds the rows - and with them the very button that was clicked
    $regTimer = New-Object System.Windows.Forms.Timer; $regTimer.Interval = 50
    $regTimer.Add_Tick({
        $this.Stop()
        $job = $script:Gui['SoftwareRegisterPending']; $script:Gui['SoftwareRegisterPending'] = $null
        if (-not $job) { return }
        if ($job.Kind -eq 'edit') { Invoke-GuiAction -Name 'Edit software package' -Action { Edit-SoftwarePackage -FullName $job.FullName } }
        else { Invoke-GuiAction -Name 'Register software' -Action { Register-SoftwareInstaller -FullName $job.FullName } }
    })
    $script:Gui['SoftwareRegisterTimer'] = $regTimer

    $right.Controls.Add((New-GuiButton -Text 'Open software folder' -X 10 -Y 162 -W 135 -ReadOnly -Tip 'Opens the \software folder in Explorer' -OnClick {
        Invoke-GuiAction -Name 'Open software folder' -ReadOnly -Action { Invoke-Item -LiteralPath $script:Config.SoftwareFolder } }))
    $right.Controls.Add((New-GuiButton -Text 'Change log' -X 150 -Y 162 -W 85 -ReadOnly -Tip 'Every install, removal and reboot with its change record (changes\change-log.csv)' -OnClick {
        Invoke-GuiAction -Name 'Change log' -ReadOnly -Action { Show-ChangeLogWindow } }))
    $right.Controls.Add((New-GuiButton -Text 'Where do I get software?' -X 240 -Y 162 -W 165 -ReadOnly -Tip 'Download and silent-install notes, VMware Tools first' -OnClick {
        Invoke-GuiAction -Name 'Software how-to' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The how-to window')) { return }
            $page = New-DetailsHtml -Title 'Where do I get software?' -Subtitle 'do this on a machine that has internet, then copy the files into the software sub-folders' -Console 'Software' -Sections @(@{ Heading = ''; Html = (ConvertTo-HtmlFromNotes -Text $script:SoftwareHowTo) })
            Show-DetailsWindow -Title 'Finding and downloading software' -Html $page } }))

    # the Trellix Agent (field test, October 2026): ticked, INSTALL / UPDATE sets the two ePO agent services to Disabled and
    # stops them on each server before the install; the two wheat buttons under the Reboot row start or stop them by hand
    $agentBox = New-Object System.Windows.Forms.CheckBox; $agentBox.Text = 'Stop the Trellix Agent services first'; $agentBox.AutoSize = $true; $agentBox.Checked = [bool]$script:Config.StopTrellixAgentForInstall
    $agentBox.Font = $script:Gui['Form'].Font; $agentBox.Location = New-Object System.Drawing.Point(10, 200)
    $script:Gui['Tips'].SetToolTip($agentBox, 'Ticked (the default): INSTALL / UPDATE sets the Trellix Agent services masvc and macmnsvc to Disabled and stops them on each server before the install, under the install''s change record - the field test saw installs fail and roll back with the agent running. A server where that fails is not installed. The Trellix Agent column then shows STOPPED (Disabled) in orange: after the reboot, press "Start Trellix Agent (ticked)". Unticked: the services are left as they are. STAGE ONLY and UNINSTALL never touch them.')
    $right.Controls.Add($agentBox); $script:Gui['TrellixStopBoxSoftware'] = $agentBox
    $right.Controls.Add((New-GuiButton -Text 'STAGE ONLY  (ticked installers, ticked servers)' -X 10 -Y 228 -W 395 -H 34 -Colour 'LightSteelBlue' -Tip 'Copies and verifies the installers in C:\PatchStaging\software ahead of the change window' -OnClick {
        Invoke-GuiAction -Name 'Stage software' -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid']); $files = @(Get-CheckedSoftwareFiles)
            if ($servers.Count -eq 0 -or $files.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server and one installer first.' -Icon 'Warning'; return }
            $r = @(Install-SoftwareOnServers -ComputerName $servers -Files $files -StageOnly | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Success'] })
            if ($r.Count -gt 0) { $null = Show-PatcherMessage -Title 'Staging finished' -Text ("Staged: {0}`nFailed: {1}`n`nDetails are in the log." -f @($r | Where-Object { $_.Success }).Count, @($r | Where-Object { -not $_.Success }).Count) }
        } }))
    $btnInstall = New-GuiButton -Text 'INSTALL / UPDATE  (ticked installers, ticked servers)' -X 10 -Y 268 -W 395 -H 52 -Colour 'Tomato' -Tip 'Fresh check, the plan, the change record, the pre-action confirmations - then the installers run with the reboot suppressed' -OnClick {
        Invoke-GuiAction -Name 'Software install' -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid']); $files = @(Get-CheckedSoftwareFiles)
            if ($servers.Count -eq 0 -or $files.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server and one installer first.' -Icon 'Warning'; return }
            $r = @(Install-SoftwareOnServers -ComputerName $servers -Files $files | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Success'] })
            if ($r.Count -gt 0) { $null = Show-PatcherMessage -Title 'Software run finished' -Text ("Installed OK: {0}`nFailed or unknown: {1}`nNeed a reboot: {2}`n`nThe reboot was suppressed: take it with the OS patches ('Reboot (ticked)'). Details are in the log and the change log." -f @($r | Where-Object { $_.Success }).Count, @($r | Where-Object { -not $_.Success }).Count, @($r | Where-Object { $_.RebootRequired }).Count) }
        } }
    $btnInstall.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $right.Controls.Add($btnInstall)
    $right.Controls.Add((New-GuiButton -Text 'UNINSTALL  (ticked products)' -X 10 -Y 326 -W 395 -H 40 -Colour 'LightCoral' -Tip 'The removal plan, the change record, the pre-action confirmations and a last confirmation naming every product' -OnClick {
        Invoke-GuiAction -Name 'Software removal' -Action {
            $rows = @($script:Gui['SoftwareInvGrid'].CheckedItems | ForEach-Object { $_.Tag } | Where-Object { $_ })
            if ($rows.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one product in the inventory list first.' -Icon 'Warning'; return }
            $r = @(Uninstall-SoftwareOnServers -Rows $rows | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Success'] })
            if ($r.Count -gt 0) {
                $leftText = ''
                $leftRows = @($r | Where-Object { $_.PSObject.Properties['LeftBehind'] -and @($_.LeftBehind).Count -gt 0 })
                if ($leftRows.Count -gt 0) { $leftText = "`n`nLEFT BEHIND by the uninstaller (the tool does not delete them - remove by hand under a change record, e.g. on the Commands tab):`n" + (($leftRows | ForEach-Object { '{0}: {1}' -f $_.Server, (@($_.LeftBehind) -join '; ') }) -join "`n") }
                $null = Show-PatcherMessage -Title 'Removal finished' -Text ("Removed: {0}`nFailed or unknown: {1}`nNeed a reboot: {2}{3}`n`nEvery server shows 'reboot advised' until it restarts. Details are in the log and the change log." -f @($r | Where-Object { $_.Success }).Count, @($r | Where-Object { -not $_.Success }).Count, @($r | Where-Object { $_.RebootRequired }).Count, $leftText)
            }
        } }))
    $right.Controls.Add((New-GuiButton -Text 'Reboot (ticked)' -X 10 -Y 372 -W 395 -H 34 -Colour 'Khaki' -Tip 'The O/S Patching console''s reboot: fresh status, pending servers by default, a change record, refused while servicing runs' -OnClick {
        Invoke-GuiAction -Name 'Reboot' -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid'])
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            Restart-PatchedServers -ComputerName $servers
        } }))
    $right.Controls.Add((New-GuiButton -Text 'Start Trellix Agent (ticked)' -X 10 -Y 412 -W 195 -H 30 -Colour 'Wheat' -Tip 'After the install and the reboot: sets the Trellix Agent services masvc and macmnsvc to Automatic and starts them on the ticked servers - fresh status, a Yes/No naming the servers, the change record. The agent reports to ePO again from then on.' -OnClick {
        Invoke-GuiAction -Name 'Trellix Agent start' -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid'])
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            $null = Set-TrellixAgentOnServers -ComputerName $servers -Mode start
        } }))
    $right.Controls.Add((New-GuiButton -Text 'Stop Trellix Agent (ticked)' -X 210 -Y 412 -W 195 -H 30 -Colour 'Wheat' -Tip 'By hand, what the box above STAGE ONLY does before an install: sets the Trellix Agent services masvc and macmnsvc to Disabled and stops them on the ticked servers - fresh status, a Yes/No naming the servers, the change record. ePO hears nothing from them until they are started again.' -OnClick {
        Invoke-GuiAction -Name 'Trellix Agent stop' -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid'])
            if ($servers.Count -eq 0) { $null = Show-PatcherMessage -Text 'Tick at least one server first.' -Icon 'Warning'; return }
            $null = Set-TrellixAgentOnServers -ComputerName $servers -Mode stop
        } }))
    $right.Controls.Add((New-GuiButton -Text 'Report (HTML + CSV)' -X 10 -Y 448 -W 195 -H 30 -ReadOnly -Tip 'reports\Software-<date>.html and .csv for the servers shown' -OnClick {
        Invoke-GuiAction -Name 'Software report' -ReadOnly -Action { Show-ReportDone -Report (Export-SoftwareReport) } }))
    $right.Controls.Add((New-GuiButton -Text 'Open reports folder' -X 210 -Y 448 -W 195 -H 30 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Open reports folder' -ReadOnly -Action { Open-ReportFolder } }))
    $right.Controls.Add((New-GuiButton -Text 'Today''s log' -X 10 -Y 484 -W 195 -H 30 -ReadOnly -Tip 'Opens logs\Patcher-YYYYMMDD.log in Notepad' -OnClick {
        Invoke-GuiAction -Name 'Open log' -ReadOnly -Action {
            if (-not (Test-Path -LiteralPath (Get-PatchLogPath))) { Write-PatchLog 'Log file created' 'INFO' }
            Start-Process notepad.exe -ArgumentList ('"{0}"' -f (Get-PatchLogPath)) } }))
    $right.Controls.Add((New-GuiButton -Text 'Help' -X 210 -Y 484 -W 195 -H 30 -ReadOnly -Tip 'A page with an example of every row colour, cell and button' -OnClick {
        Invoke-GuiAction -Name 'Software help' -ReadOnly -Action { Show-ConsoleHelp -Console 'Software' -Html (Get-SoftwareHelpHtml) } }))
    # no explainer text on the panel: the Help page has every colour and step with an example, the tool tips the rest
    foreach ($c in $right.Controls) { if ($c.Width -ge 390) { $c.Anchor = 'Top, Left, Right' } }
    Register-PanelButtonRows -Panel $right -Name 'SoftwareRight'   # the two- and three-button rows follow the width too
    # the Trellix box and buttons: a band each, taken away - the gap closed - while Trellix is not in use (Update-TrellixShown)
    Add-PanelBand -Panel $right -Controls @($script:Gui['TrellixStopBoxSoftware']) -Height 20 -Kind 'Trellix'   # STAGE ONLY then 6 px under the folder buttons (they end at 202)
    Add-PanelBand -Panel $right -Controls @($right.Controls | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -like '*Trellix Agent (ticked)' }) -Height 36 -Kind 'Trellix'
    $below = @(); foreach ($c in $right.Controls) { if ($c.Top -ge 162 -and -not [object]::ReferenceEquals($c, $newPanel)) { $below += , @($c, $c.Top) } }
    $script:Gui['SoftwareBelowNew'] = $below

    # ---- toolbar ----
    $toolbar = New-ConsoleToolbar -Tab $tab
    $combo = New-GroupPicker -Toolbar $toolbar -OnChange { Update-SoftwareServerGrid; Update-SoftwareInventoryGrid }
    $script:Gui['SoftwareGroupCombo'] = $combo
    $toolbar.Controls.Add((New-GuiButton -Text 'Reload lists + packages' -X 235 -Y 8 -W 150 -Tip 'Re-reads the group files, the patches and the software folders and the catalogue' -OnClick {
        Invoke-GuiAction -Name 'Reload' -Action { Initialize-ToolkitData } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Check software (ticked)' -X 390 -Y 8 -W 150 -Colour 'LightSkyBlue' -ReadOnly -Tip 'Status, inventory and software state of the ticked servers. Works during an install.' -OnClick {
        Invoke-GuiAction -Name 'Software check' -ReadOnly -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SoftwareServerGrid'])
            if ($servers.Count -eq 0) { Show-GuiNotice 'Tick at least one server first (or use "Check software (all shown)").'; return }
            Update-SoftwareFacts -ComputerName $servers
            Show-TrellixAgentWarning -Servers $servers   # the agent services off on a server: the warning the scan owes
        } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Check software (all shown)' -X 545 -Y 8 -W 165 -Colour 'LightSkyBlue' -ReadOnly -Tip 'Works during an install.' -OnClick {
        Invoke-GuiAction -Name 'Software check' -ReadOnly -Action {
            $all = @(Get-GridAllKeys -Grid $script:Gui['SoftwareServerGrid'])
            if ($all.Count -eq 0) { Show-GuiNotice 'No servers in the list. Add names to a group file (*.txt) and reload.'; return }
            Update-SoftwareFacts -ComputerName $all
            Show-TrellixAgentWarning -Servers $all
        } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Tick all' -X 720 -Y 8 -W 70 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['SoftwareServerGrid'] -Checked $true; $g = $script:Gui['SoftwareServerGrid']; $script:Gui['SoftwareCount'].Text = ('{0} server row(s) shown, {1} ticked' -f $g.Items.Count, $g.CheckedItems.Count); Start-SoftwareInventoryRefresh }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Untick all' -X 795 -Y 8 -W 80 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['SoftwareServerGrid'] -Checked $false; $g = $script:Gui['SoftwareServerGrid']; $script:Gui['SoftwareCount'].Text = ('{0} server row(s) shown, {1} ticked' -f $g.Items.Count, $g.CheckedItems.Count); Start-SoftwareInventoryRefresh }))

    # ---- banner ----
    $null = New-ConsoleBanner -Tab $tab -Console 'Software' -Title ("{0}'S SOFTWARE SHED" -f $script:Config.OperatorName.ToUpper()) -Subtitle 'deploy, update, remove - the reboot waits for the OS patches'
    $split.BringToFront()
    $script:Gui['SoftwareSplit'] = $split
    $tab.Add_Resize({ try { $s = $script:Gui['SoftwareSplit']; $s.SplitterDistance = [int]($s.Height * 0.5) } catch { } })

    Register-ConsoleRefresher -Console 'Software' -Refresh { Update-SoftwarePackageList; Update-SoftwareServerGrid; Update-SoftwareInventoryGrid }
}
