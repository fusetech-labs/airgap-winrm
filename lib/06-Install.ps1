# =====================================================================
#  06-Install.ps1  -  INSTALLING A PATCH OVER WinRM
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The flow (see Install-PatchOnServers at the bottom):
#    1. Fresh status check of the chosen servers (never trust old data)
#    2. Build a plan: which KB goes to which server, and why not
#    3. Show the plan                          -> OK / Cancel
#   3b. The change record (11-ChangeLog.ps1)   -> Cancel = abort
#    4. SAFETY POP-UP 1: VMware snapshot taken? -> No = abort
#    5. SAFETY POP-UP 2: Trellix Solidcore in Update Mode? -> No = abort
#    6. Status check AGAIN (the pop-ups may have been open for a while);
#       the Trellix Agent services set to Disabled and stopped on each server (the box on the tab);
#       then per server: PSSession, locked-down C:\PatchStaging, slice copy
#    7. Hand the install to each server as a one-shot SYSTEM task (it outlives this session); flag the run
#    8. Watch while Auto-check is ticked (GUI stays alive, progress at every check), record each result;
#       untick / 'Let the servers go' / the timeout leave the rest to a later status check
#    9. Fresh status check again so the grid shows the new truth
#
#  WHY DISM AND NOT WUSA?  wusa.exe refuses to run inside a remote
#  (WinRM) session - it fails with "access denied"/exit code 5.  DISM is
#  happy to run remotely, so we unpack the .msu with expand.exe and feed
#  the .cab inside it to  dism /Online /Add-Package.
#
#  RULE FOR EVERY POP-UP IN THIS FILE: a MessageBox RETURNS a value.  If
#  that value is not captured it leaks into the function's output and a
#  "return $false" silently becomes "@('OK', $false)" = true.  So every
#  pop-up whose answer we do not need is written as  $null = Show-...
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  06-Install.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (two reviewers, see CODE-REVIEW.md).
#  Findings fixed in this file: R-01 safety pop-up "No" did not abort
#  (MessageBox result leaked into the return value); R-02 "nothing to do"
#  reported as a failed install; R-03 Reboot button had no pending-reboot
#  or servicing guard; R-04 timeout killed DISM mid-install; R-05 stale
#  status at install time + no servicing guard on the server; R-06 same
#  server twice (case / FQDN); R-07 staging folder writable by Users and
#  no hash re-check before expand; R-10 per-package results; R-13 KB in
#  failure rows; R-14 sessions leaked on error; R-15 reboot reported as
#  failed; R-16 pop-ups taller than the screen; R-19 remote path built
#  with local Join-Path; R-20 two files with one KB shared a folder.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ____CF__________________________   Date : ___30-10-2026___________
#  Verdict    : [X] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] read every function   [x] ran it against a test server
#               [x] compared with CODE-REVIEW.md   [x] safety pop-ups answered No
#  Comments   :
#    -
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  RUNS ON THE TARGET SERVER before anything is copied: makes sure the
#  staging folder is a real folder owned by admins, with an ACL that
#  ordinary users cannot write to (C:\ lets Users create folders).
# ---------------------------------------------------------------------
$script:RemoteStagingScript = {
    param([string]$Staging)
    # Owner and ACL are judged by SID, not by name: "CORP\systems.support" contains "SYSTEM" but is no system account.
    $allowedOwners = @('S-1-5-32-544', 'S-1-5-18', 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')   # Administrators, SYSTEM, TrustedInstaller
    $checkFolder = {
        param([string]$Path)
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "$Path is a junction or symbolic link - refusing to use it" }
        if (-not $item.PSIsContainer) { throw "$Path exists but is a file" }
        $acl = Get-Acl -LiteralPath $Path
        $ownerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        if ($allowedOwners -notcontains $ownerSid) { throw "$Path is owned by '$($acl.Owner)' ($ownerSid), not by Administrators or SYSTEM - refusing to use it" }
    }
    if (Test-Path -LiteralPath $Staging) { & $checkFolder $Staging }
    else {
        New-Item -ItemType Directory -Path $Staging -Force | Out-Null
        & $checkFolder $Staging    # again after creating it: someone may have created it in between
    }
    # A fresh, protected DACL with exactly two entries - SYSTEM and Administrators, full control, inherited by every file
    # and sub-folder.  (icacls /grant:r kept any other explicit entry, so a leftover "Everyone: Modify" survived.)
    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in $system, $admins) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $sid, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    $acl.SetOwner($admins)
    (Get-Item -LiteralPath $Staging -Force).SetAccessControl($acl)
    # read it back: protected, owned by an allowed SID, and no entry for anyone else
    $now = Get-Acl -LiteralPath $Staging
    $ownerNow = $now.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    $others = @($now.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { $_.IdentityReference.Value -notin 'S-1-5-18', 'S-1-5-32-544' })
    if (-not $now.AreAccessRulesProtected -or $allowedOwners -notcontains $ownerNow -or $others.Count -gt 0) {
        throw ("could not lock down {0}: protected={1}, owner {2}, other entries: {3}" -f $Staging, $now.AreAccessRulesProtected, $ownerNow, (($others | ForEach-Object { $_.IdentityReference.Value }) -join ', '))
    }
    return "$Staging ready (owner $($now.Owner), ACL = SYSTEM + Administrators only, inheritance from C:\ removed)"
}

# ---------------------------------------------------------------------
#  RUNS ON THE TARGET SERVER.  Installs each staged file in turn and
#  returns one result object per file.  Self contained on purpose.
#  Guards, in order: nothing else servicing the box, no pending reboot,
#  the staged file still has the hash we copied, the file is Microsoft
#  signed.  Only then expand + DISM.
# ---------------------------------------------------------------------
$script:RemoteInstallScript = {
    param([string[]]$RemoteFiles, [string[]]$ExpectedHashes, [bool]$Cleanup, [bool]$RequireSignature, [string]$Operator, [string]$ChangeText = '', [string]$RunStamp = '')
    $results = @()

    # Guards 1 and 2 run ONCE, before the first file.  The first package of a run (the .NET cumulative update, say)
    # may itself set RebootPending (exit 3010) and keep TiWorker busy for a while; DISM takes the next package of the
    # same run before that reboot without trouble.  Checked per file, the second file - usually the LCU - was refused.
    $preflight = ''
    try {
        # --- Guard 1: is something else servicing this box right now?  dism/wusa = yes; TiWorker only
        #     when it is actually burning CPU (it idles for minutes after routine maintenance); and the
        #     Windows Update agent is asked directly.  Same block as in RemoteStatusScript, plus the Windows Installer mutex.
        $busy = @(Get-Process -Name dism, wusa -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
        $ti = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
        if ($ti.Count -gt 0) {
            $cpu1 = 0.0; foreach ($p in $ti) { try { if ($p.CPU) { $cpu1 += $p.CPU } } catch { } }
            Start-Sleep -Seconds 2
            $cpu2 = 0.0; foreach ($p in @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)) { try { if ($p.CPU) { $cpu2 += $p.CPU } } catch { } }
            if (($cpu2 - $cpu1) -ge 0.25) { $busy += ('TiWorker busy ({0:N1} s CPU in 2 s)' -f ($cpu2 - $cpu1)) }
        }
        try { if ((New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateInstaller().IsBusy) { $busy += 'Windows Update agent installing' } } catch { }
        # the toolkit's own tasks: another run's expand.exe (it unpacks before dism.exe starts), or a task of the tool's folder that is
        # Running - a software install that outlived its watch, or a second operator's run - other than this run's own task
        if (@(Get-Process -Name expand -ErrorAction SilentlyContinue).Count -gt 0) { $busy += 'expand.exe unpacking an update' }
        try { $tk = @(Get-ScheduledTask -TaskPath '\WinRMToolkit\' -ErrorAction Stop | Where-Object { [string]$_.State -eq 'Running' -and $_.TaskName -ne ('OSPatch-' + $RunStamp) } | ForEach-Object { $_.TaskName }); if ($tk.Count -gt 0) { $busy += ('toolkit task running: ' + ($tk -join ', ')) } } catch { }
        # Windows Installer busy (another administrator's MSI install): the software run guard refuses on it, so does this (F11, O-4)
        $msiBusy = $false
        try { $mtx = $null; if ([System.Threading.Mutex]::TryOpenExisting('Global\_MSIExecute', [ref]$mtx)) { $msiBusy = $true; $mtx.Close() } } catch { $msiBusy = $true }
        if ($msiBusy) { $busy += 'Windows Installer busy (Global\_MSIExecute)' }
        if ($busy.Count -gt 0) { throw "servicing already running on the server ($($busy -join ', ')) - try again in a few minutes" }
        # --- Guard 2: pending reboot - the same hard signs as the status check (CBS, Windows Update, UpdateExeVolatile, a
        #     computer rename).  PendingFileRenameOperations is the operator's choice (TreatPendingFileRenameAsReboot) and
        #     was judged by the status check before the plan; it is not re-read here.
        $cbs = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
        $pending = @()
        foreach ($k in 'RebootPending', 'PackagesPending', 'RebootInProgress') { if (Test-Path -LiteralPath "$cbs\$k") { $pending += "CBS:$k" } }
        foreach ($k in 'RebootRequired', 'PostRebootReporting') { if (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\$k") { $pending += "WU:$k" } }
        $vol = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Updates' -Name UpdateExeVolatile -ErrorAction SilentlyContinue).UpdateExeVolatile
        if ($vol -and $vol -ne 0) { $pending += 'UpdateExeVolatile' }
        $activeName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        $wantedName = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name ComputerName -ErrorAction SilentlyContinue).ComputerName
        if ($activeName -and $wantedName -and $activeName -ne $wantedName) { $pending += 'ComputerRename' }
        if ($pending.Count -gt 0) { throw "pending reboot on the server ($($pending -join ', ')) - reboot first" }
    } catch { $preflight = $_.Exception.Message }

    for ($i = 0; $i -lt $RemoteFiles.Count; $i++) {
        $file = $RemoteFiles[$i]
        $expectedHash = ''
        if ($ExpectedHashes.Count -gt $i) { $expectedHash = $ExpectedHashes[$i] }
        $kb = 'KB?'
        if ($file -match '(?i)(KB\d{6,7})') { $kb = $Matches[1].ToUpper() }
        # Work folder/log names: KB + 6 chars from the file name, so two files with one KB never collide.
        # (SHA256 through the FIPS-validated provider: MD5.Create() throws where FIPS is enforced; a plain checksum if even that fails)
        $leafLower = (Split-Path -Path $file -Leaf).ToLower()
        try { $nameHash = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256CryptoServiceProvider).ComputeHash([System.Text.Encoding]::UTF8.GetBytes($leafLower))).Replace('-', '').Substring(0, 6) }
        catch { $sum = 0; foreach ($ch in $leafLower.ToCharArray()) { $sum = (($sum * 31) + [int]$ch) % 16777216 }; $nameHash = '{0:X6}' -f $sum }
        $tag = "$kb-$nameHash"
        $r = [ordered]@{
            Computer = $env:COMPUTERNAME; KB = $kb; File = (Split-Path -Path $file -Leaf)
            Success = $false; RebootRequired = $false; ExitCode = $null; Message = ''; Detail = @(); Packages = @()
        }
        $extract = $null
        $logPath = $null
        $applied = 0   # per file: a guard that refuses this file must not inherit the previous file's count ("PARTIAL ..." with nothing applied, R6-09)
        $stage = Split-Path -Path $file -Parent
        try {
            if ($preflight) { throw $preflight }   # guards 1 and 2 ran once, before the first file
            # --- Guard 3: the staged file is intact (closes the gap between the copy and the install)
            if (-not (Test-Path -LiteralPath $file)) { throw "Staged file not found: $file" }
            if ($expectedHash) {
                $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if ($actual -ne $expectedHash) { throw "staged file hash changed since the copy ($actual vs $expectedHash) - refusing to install" }
            }
            # --- Guard 4: Microsoft signature
            if ($RequireSignature) {
                $sig = Get-AuthenticodeSignature -LiteralPath $file
                $subject = ''
                if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
                if ($sig.Status -ne 'Valid' -or $subject -notmatch 'O=Microsoft Corporation') { throw "signature check failed: status $($sig.Status), signer '$subject'" }
                $r.Detail += "Authenticode: $($sig.Status), $subject"
            }

            $logPath = "$stage\dism-$tag.log"
            $packages = @()
            if ($file.ToLower().EndsWith('.msu')) {
                # Step A: unpack the .msu (a container holding one or more .cab files)
                $extract = "$stage\extract-$tag"
                # a leftover folder from a failed run must go completely: a cab that stayed behind would be installed with the new ones
                if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction Stop }
                New-Item -ItemType Directory -Path $extract -Force | Out-Null
                $r.Detail += "expand.exe -F:* `"$file`" `"$extract`""
                $null = & expand.exe -F:* "$file" "$extract" 2>&1
                if ($LASTEXITCODE -ne 0) { throw "expand.exe failed with exit code $LASTEXITCODE" }
                # Server 2025 / Windows 24H2 checkpoint packages hold the LCU as a .wim/.psf pair (plus AggregatedMetadata):
                # those cabs are not installable one by one - DISM installs the .msu itself, the way Microsoft documents it.
                $modern = @(Get-ChildItem -LiteralPath $extract -File | Where-Object { $_.Extension -in '.wim', '.psf' -or $_.Name -match 'AggregatedMetadata' })
                if ($modern.Count -gt 0) {
                    $packages = @($file)
                    $r.Detail += ('checkpoint-style package ({0}): DISM takes the .msu itself' -f (($modern | ForEach-Object { $_.Name }) -join ', '))
                } else {
                    # WSUSSCAN.cab is only metadata; a separate SSU (servicing stack) cab must go first.
                    $cabs = @(Get-ChildItem -LiteralPath $extract -Filter '*.cab' | Where-Object { $_.Name -notmatch '^WSUSSCAN' })
                    $packages = @($cabs | Sort-Object @{ Expression = { if ($_.Name -match 'SSU') { 0 } else { 1 } } }, Name | ForEach-Object { $_.FullName })
                    if ($packages.Count -eq 0) { throw 'No .cab file found inside the .msu' }
                }
            } else {
                $packages = @($file)
            }

            # Step B: DISM installs each package in turn.  /NoRestart = we decide when to reboot.
            $applied = 0   # packages DISM accepted (0 or 3010): only those are "earlier packages went in" when a later one fails
            foreach ($pkg in $packages) {
                $pkgName = Split-Path -Path $pkg -Leaf
                $r.Detail += "dism.exe /Online /Add-Package /PackagePath:`"$pkg`" /NoRestart /Quiet /LogPath:`"$logPath`""
                $null = & dism.exe /Online /Add-Package /PackagePath:"$pkg" /NoRestart /Quiet /LogPath:"$logPath" 2>&1
                $code = $LASTEXITCODE
                $hex = '0x{0:X8}' -f ($code -band 0xFFFFFFFF)
                $r.ExitCode = $code
                $r.Packages += "$pkgName -> exit $code ($hex)"
                switch ($hex) {
                    '0x00000000' { }
                    '0x00000BC2' { $r.RebootRequired = $true }
                    '0x800F081E' { throw "$pkgName - DISM 0x800F081E NOT APPLICABLE to this server: wrong Windows build or a missing prerequisite" }
                    '0x800F0922' { throw "$pkgName - DISM 0x800F0922 install failed. Usual causes: pending reboot, missing servicing stack update, System Reserved partition full. See $logPath" }
                    '0x80070002' { throw "$pkgName - DISM 0x80070002 file not found (was the copy complete?)" }
                    default      { throw "$pkgName - DISM returned $code ($hex). See $logPath on the server" }
                }
                $applied++
            }
            # Step B2: exit 0 without a reboot is checked against the servicing store.  DISM calls a .NET rollup for ANOTHER
            # Windows build a success: the wrapper package goes in with every part skipped as not applicable, nothing changes,
            # and Get-HotFix never lists the KB (field 2026-11: KB5127687, the Server 2022 rollup, "Installed" with exit 0 on
            # a Server 2019 toolkit PC, READY again at the next check).  The KB must be there now, where the status check looks.
            if (-not $r.RebootRequired -and $kb -ne 'KB?') {
                $seen = $false
                try { $seen = (@(Get-CimInstance -ClassName Win32_QuickFixEngineering -Filter "HotFixID='$kb'" -ErrorAction Stop).Count -gt 0) } catch { $r.Detail += "Win32_QuickFixEngineering not read: $($_.Exception.Message)" }
                if (-not $seen) {
                    try { $seen = (@(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Packages' -ErrorAction Stop | Where-Object { $_.PSChildName -match ('^Package_for_' + $kb + '[_~]') }).Count -gt 0) } catch { $r.Detail += "servicing store not read: $($_.Exception.Message)" }
                }
                # not "earlier packages went in": the wrapper installed nothing, so no PARTIAL prefix
                if (-not $seen) { $applied = 0; throw "DISM returned 0 but $kb is not on the server afterwards (not in Get-HotFix, not in the servicing store): the package is for another Windows build - DISM takes a .NET rollup for the wrong build as an empty wrapper and calls that success. Nothing was installed; get the file for this server's build" }
                $r.Detail += "$kb is on the server now (Get-HotFix / servicing store)"
            }
            $r.Success = $true
            $r.Message = 'Installed'
            if ($r.RebootRequired) { $r.Message = 'Installed - reboot required (3010)' }
            if ($packages.Count -gt 1) { $r.Message += " ($($packages.Count) packages: " + (($packages | ForEach-Object { Split-Path -Path $_ -Leaf }) -join ', ') + ')' }
        } catch {
            $r.Success = $false
            $r.Message = $_.Exception.Message
            if ($applied -gt 0) { $r.Message = "PARTIAL - earlier packages went in: " + (@($r.Packages | Select-Object -First $applied) -join '; ') + " - then: " + $r.Message }
            # Pull the interesting lines out of the DISM log so the operator does not have to go looking.
            if ($logPath -and (Test-Path -LiteralPath $logPath)) {
                $r.Detail += @(Get-Content -LiteralPath $logPath -Tail 60 | Where-Object { $_ -match 'Error|Failed|0x8' } | Select-Object -Last 8)
            }
        }

        # Step C: leave a result file on the server (survives a lost connection) and an event log entry.
        $resultPath = "$stage\result-$tag.txt"
        try {
            @("Computer=$env:COMPUTERNAME", "KB=$kb", "File=$($r.File)", "Operator=$Operator", "Change=$ChangeText", "When=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
              "Success=$($r.Success)", "RebootRequired=$($r.RebootRequired)", "ExitCode=$($r.ExitCode)", "Message=$($r.Message)", "Run=$RunStamp") + @($r.Packages | ForEach-Object { "Package=$_" }) | Set-Content -LiteralPath $resultPath
        } catch { $r.Detail += "result file not written ($resultPath): $($_.Exception.Message)" }   # the operator is told to look there after a timeout
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('OfflinePatcher')) { New-EventLog -LogName Application -Source 'OfflinePatcher' -ErrorAction Stop }
            $type = 'Information'
            if (-not $r.Success) { $type = 'Error' }
            Write-EventLog -LogName Application -Source 'OfflinePatcher' -EventId 900 -EntryType $type -Message ("WinRM Toolkit OS patch {0} on {1} by {2} -> {3} (exit {4}) - change {5}" -f $kb, $env:COMPUTERNAME, $Operator, $r.Message, $r.ExitCode, $ChangeText) -ErrorAction Stop
        } catch { $r.Detail += "event log entry not written: $($_.Exception.Message)" }
        # the server's own change record, next to the staged files (the staging folder is admin-only)
        try { Add-Content -LiteralPath "$stage\change-log.txt" -Value ('{0} | OS patch {1} | {2} | change {3} | by {4} | {5}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $kb, $r.File, $ChangeText, $Operator, $r.Message) -Encoding UTF8 -ErrorAction Stop } catch { $r.Detail += "change-log.txt not written: $($_.Exception.Message)" }

        # Step D: tidy up (only after success - on failure everything stays for investigation)
        if ($Cleanup -and $r.Success) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
            if ($extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $results += [pscustomobject]$r
    }
    return $results
}

# ---------------------------------------------------------------------
#  RUNS ON THE TARGET SERVER right after the copy: writes this run's
#  install script (built by New-InstallTaskScript: the arguments as
#  literals, then the body of RemoteInstallScript) into the staging folder
#  and starts it as a one-shot SYSTEM task.  From then on the install
#  belongs to the SERVER: the operator's session, the tool and the PC can
#  go away and DISM carries on; run-<stamp>.txt and the result files say
#  how it ended.  The same pattern as the Software console's task runs.
#  The task runs powershell -Command with the script text read from the
#  file, not -File: a GPO execution policy (AllSigned, Restricted) would
#  refuse a .ps1 file, and the folder the text sits in is admin-only.
# ---------------------------------------------------------------------
$script:RemoteInstallLaunchScript = {
    param([string]$Staging, [string]$RunStamp, [string]$ScriptText, [string]$Description)
    $ErrorActionPreference = 'Stop'
    $taskFolder = '\WinRMToolkit\'
    $name = 'OSPatch-' + $RunStamp
    $root = $Staging.TrimEnd('\')
    $scriptPath = $root + '\install-' + $RunStamp + '.ps1'
    $runPath = $root + '\run-' + $RunStamp + '.txt'
    # old runs' scripts and markers go after 30 days (the result files stay: they are the record)
    foreach ($old in @(Get-ChildItem -LiteralPath $root -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(install|run)-\d{8}-\d{6}\.(ps1|txt)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-30) })) { Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue }
    # and the tasks of earlier runs that nobody read back (a run normally loses its task at the first check after it finished)
    try {
        foreach ($old in @(Get-ScheduledTask -TaskPath $taskFolder -ErrorAction Stop | Where-Object { $_.TaskName -like 'OSPatch-*' -and $_.TaskName -ne $name -and [string]$_.State -ne 'Running' })) {
            $when = $null; try { $when = [datetime]::ParseExact($old.TaskName.Substring(8), 'yyyyMMdd-HHmmss', [System.Globalization.CultureInfo]::InvariantCulture) } catch { }
            if ($when -and $when -lt (Get-Date).AddDays(-7)) { Unregister-ScheduledTask -TaskName $old.TaskName -TaskPath $taskFolder -Confirm:$false -ErrorAction SilentlyContinue }
        }
    } catch { }
    [System.IO.File]::WriteAllText($scriptPath, $ScriptText, (New-Object System.Text.UTF8Encoding($false)))
    @("Stamp=$RunStamp", "Created=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')", "Task=$taskFolder$name", "Script=$scriptPath") | Set-Content -LiteralPath $runPath -Encoding UTF8
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '& ([scriptblock]::Create([System.IO.File]::ReadAllText(''' + $scriptPath + ''')))'
    $action = New-ScheduledTaskAction -Execute $ps -Argument ('-NoProfile -NonInteractive -Command "' + $command + '"')
    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    # 12 hours: well past InstallTimeoutMin's usual values - a limit that ends PowerShell mid-run leaves no result and may
    # leave DISM running unrecorded (a slow 2016 cumulative update with OnePatchPerRun off can pass 4 hours, R6-15)
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 12) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    if ($Description.Length -gt 900) { $Description = $Description.Substring(0, 900) }
    Register-ScheduledTask -TaskName $name -TaskPath $taskFolder -Action $action -Principal $principal -Settings $settings -Description $Description -Force | Out-Null
    Start-ScheduledTask -TaskPath $taskFolder -TaskName $name
    return ('task {0}{1} started as SYSTEM: {2}' -f $taskFolder, $name, $scriptPath)
}

# ---------------------------------------------------------------------
#  RUNS ON THE TARGET SERVER while a run is open (every auto-check tick):
#  the task's state, the run marker, the result files of these runs and
#  the CBS progress snapshot.  Lines, not objects (remoting flattens).
#    Runs    : 'Stamp|TaskState|LastResult|Started|Finished'
#    Results : 'Stamp|KB|When|Success|RebootRequired|ExitCode|Message|File'
#  The status check (RemoteStatusScript) sends the same two lists for
#  every run of the last 14 days, so a status check finishes a run too.
# ---------------------------------------------------------------------
$script:RemoteRunStateScript = {
    param([string]$Staging, [string[]]$Stamps)
    $ErrorActionPreference = 'Continue'
    $taskFolder = '\WinRMToolkit\'
    $root = $Staging.TrimEnd('\')
    $runs = @(); $results = @()
    foreach ($st in @($Stamps)) {
        $taskState = 'absent'; $last = ''
        try {
            $t = Get-ScheduledTask -TaskPath $taskFolder -TaskName ('OSPatch-' + $st) -ErrorAction Stop
            $taskState = [string]$t.State
            try { $last = [string]($t | Get-ScheduledTaskInfo -ErrorAction Stop).LastTaskResult } catch { $last = '?' }
        } catch { if ([string]$_.CategoryInfo.Category -ne 'ObjectNotFound') { $taskState = 'unread' } }
        $started = ''; $finished = ''
        $runPath = $root + '\run-' + $st + '.txt'
        if (Test-Path -LiteralPath $runPath) { foreach ($l in @(Get-Content -LiteralPath $runPath -ErrorAction SilentlyContinue)) { if ($l -match '^Started=(.*)$') { $started = $Matches[1] } elseif ($l -match '^Finished=(.*)$') { $finished = $Matches[1] } } }
        # a finished run's task has done its work: it is removed here (the result files and the run marker are the record)
        if ($finished -and $taskState -notin 'Running', 'unread', 'absent') { try { Unregister-ScheduledTask -TaskName ('OSPatch-' + $st) -TaskPath $taskFolder -Confirm:$false -ErrorAction Stop; $taskState = 'removed' } catch { } }
        $runs += '{0}|{1}|{2}|{3}|{4}' -f $st, $taskState, $last, $started, $finished
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $root -Filter 'result-*.txt' -File -ErrorAction SilentlyContinue)) {
        $h = @{}
        foreach ($l in @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)) { if ($l -match '^([^=]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }
        if (-not $h['Run'] -or @($Stamps) -notcontains $h['Run']) { continue }
        $results += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $h['Run'], $h['KB'], $h['When'], $h['Success'], $h['RebootRequired'], $h['ExitCode'], ([string]$h['Message'] -replace '\|', '/'), $h['File']
    }
    # the progress snapshot: the CBS.log percentage and the last DISM log line
    $dism = @(Get-Process -Name dism -ErrorAction SilentlyContinue)
    $ti = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
    $tiCpu = 0; if ($ti.Count -gt 0) { $tiCpu = [int]($ti | Measure-Object -Property CPU -Sum).Sum }
    $pct = ''; $stage = ''; $pctTime = ''
    $cbs = Join-Path $env:windir 'Logs\CBS\CBS.log'
    if (Test-Path -LiteralPath $cbs) {
        $line = Get-Content -LiteralPath $cbs -Tail 3000 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Percent progress: \d+' } | Select-Object -Last 1
        if ($line -match '^(\S+ \S+?),.*Stage: (\d+ out of \d+)\. Percent progress: (\d+)') { $pctTime = $Matches[1]; $stage = $Matches[2]; $pct = $Matches[3] }
    }
    $lastDism = ''
    $log = Get-ChildItem -LiteralPath $root -Filter 'dism-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
    if ($log) {
        $l = [string](Get-Content -LiteralPath $log.FullName -Tail 1 -ErrorAction SilentlyContinue)
        if ($l -match '^(\S+ \S+?),.*TID=\d+ (.*?) - \w+::') { $lastDism = '{0} {1}' -f $Matches[1], $Matches[2] } else { $lastDism = $l }
        if ($lastDism.Length -gt 140) { $lastDism = $lastDism.Substring(0, 140) + '...' }
    }
    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Runs = $runs; Results = $results
        DismRunning = ($dism.Count -gt 0); TiWorkerCpuSec = $tiCpu; Percent = $pct; Stage = $stage; PercentTime = $pctTime; LastDism = $lastDism
    }
}

function New-InstallTaskScript {
    # The text of the install script a server runs as a one-shot SYSTEM task: this run's arguments as literals, the
    # body of RemoteInstallScript (the same guards and DISM calls the session-bound install used), and the run marker's
    # Started / Finished lines around it.  Built here, in one place, as text that can be read and parsed before it is sent.
    param([string[]]$RemoteFiles, [string[]]$ExpectedHashes, [bool]$Cleanup, [bool]$RequireSignature, [string]$Operator, [string]$ChangeText, [string]$RunStamp, [string]$RunPath)
    # PowerShell also ends a single-quoted string at the typographic quotes (an "Approved by: J O'Brien" pasted from Outlook):
    # each of them is doubled as an ASCII quote, or the server's [scriptblock]::Create throws and nothing installs (R6-03)
    $quoteChars = "['" + [char]0x2018 + [char]0x2019 + [char]0x201A + [char]0x201B + ']'   # built from codes: the source stays ASCII
    $q = { param([string]$s) "'" + ([string]$s -replace $quoteChars, "''") + "'" }
    $b = { param([bool]$v) if ($v) { '$true' } else { '$false' } }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# WinRM Toolkit OS patch run ' + $RunStamp + ' - written by the tool, run by this server as a one-shot SYSTEM task so the install outlives the operator session')
    $lines.Add('$RemoteFiles = @(' + (@($RemoteFiles | ForEach-Object { & $q $_ }) -join ', ') + ')')
    $lines.Add('$ExpectedHashes = @(' + (@($ExpectedHashes | ForEach-Object { & $q $_ }) -join ', ') + ')')
    $lines.Add('$Cleanup = ' + (& $b $Cleanup))
    $lines.Add('$RequireSignature = ' + (& $b $RequireSignature))
    $lines.Add('$Operator = ' + (& $q $Operator))
    $lines.Add('$ChangeText = ' + (& $q $ChangeText))
    $lines.Add('$RunStamp = ' + (& $q $RunStamp))
    $lines.Add('$RunPath = ' + (& $q $RunPath))
    $lines.Add('Add-Content -LiteralPath $RunPath -Value (''Started='' + (Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') + '' PID='' + $PID) -Encoding UTF8')
    $lines.Add('$InstallBody = {')
    $lines.Add([string]$script:RemoteInstallScript)
    $lines.Add('}')
    $lines.Add('$RunResults = @(& $InstallBody $RemoteFiles $ExpectedHashes $Cleanup $RequireSignature $Operator $ChangeText $RunStamp)')
    $lines.Add('Add-Content -LiteralPath $RunPath -Value (''Finished='' + (Get-Date -Format ''yyyy-MM-dd HH:mm:ss'') + '' Results='' + @($RunResults).Count + '' Failed='' + @($RunResults | Where-Object { -not $_.Success }).Count) -Encoding UTF8')
    return (($lines.ToArray()) -join "`r`n") + "`r`n"
}

function Write-ProgressSummary {
    # The formatting half, separated so it can be tested without servers.
    param([object[]]$Rows, [int]$ElapsedSec, [switch]$Detail)
    if (-not $Rows -or $Rows.Count -eq 0) { return }
    $min = [int]($ElapsedSec / 60)
    $known = @($Rows | Where-Object { $null -ne $_.Percent -and $_.Percent -ne '' } | ForEach-Object { [int]$_.Percent })
    $alive = @($Rows | Where-Object { $_.DismRunning }).Count
    if ($Rows.Count -gt 1) {
        $summary = '{0} min elapsed - {1} servers installing, dism.exe alive on {2}: ' -f $min, $Rows.Count, $alive
        if ($known.Count -gt 0) {
            $stats = $known | Measure-Object -Minimum -Maximum -Average
            $summary += ('CBS progress {0}%..{1}% (avg {2}%) on {3} of them' -f $stats.Minimum, $stats.Maximum, [int]$stats.Average, $known.Count)
        } else { $summary += 'no CBS progress line yet' }
        Write-PatchLog $summary 'INFO'
    }
    if ($Detail -or $Rows.Count -le 3) {
        foreach ($r in $Rows) {
            $pctText = 'no CBS progress line yet'
            if ($null -ne $r.Percent -and $r.Percent -ne '') { $pctText = "CBS stage $($r.Stage) at $($r.Percent)% (as of $($r.PercentTime))" }
            $dismText = 'dism.exe running'
            if (-not $r.DismRunning) { $dismText = 'dism.exe not running (between packages or finishing)' }
            $name = $r.PSComputerName
            if (-not $name) { $name = $r.Computer }
            Write-PatchLog ("  {0}: {1} min - {2}, {3}, TiWorker CPU {4} s, last DISM line: {5}" -f $name, $min, $pctText, $dismText, $r.TiWorkerCpuSec, $r.LastDism) 'INFO'
        }
    }
    if ($known.Count -gt 0) { Set-GuiProgress -Percent ([int](($known | Measure-Object -Average).Average)) }
}

function Show-PatcherMessage {
    # One place for every pop-up, so they all look the same and sit on top of the GUI.
    # RETURNS the button pressed ('OK', 'Cancel', 'Yes', 'No').  Capture it, or write  $null = Show-PatcherMessage ...
    param(
        [string]$Text,
        [string]$Title = $script:Config.ToolName,
        [string]$Buttons = 'OK',          # OK, OKCancel, YesNo
        [string]$Icon = 'Information',    # Information, Warning, Error, Question
        [string]$Default = 'Button1',     # Button1 / Button2 - which button Enter selects
        [switch]$Wrap                     # prose: wrap long lines (tables and lists keep their layout without it)
    )
    Add-Type -AssemblyName System.Windows.Forms
    $lineCount = @($Text -split "`r?`n").Count
    if ($lineCount -gt 22 -or $Wrap) { return (Show-PatcherLongMessage -Text $Text -Title $Title -Buttons $Buttons -Default $Default -Wrap:$Wrap) }
    $owner = $script:Gui['Form']
    if ($owner -and -not $owner.IsDisposed) {
        return [string][System.Windows.Forms.MessageBox]::Show($owner, $Text, $Title, $Buttons, $Icon, $Default)
    }
    return [string][System.Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon, $Default)
}

function Show-PatcherLongMessage {
    # A MessageBox taller than the screen loses its buttons; long texts get a scrollable window instead.
    param([string]$Text, [string]$Title, [string]$Buttons = 'OK', [string]$Default = 'Button1', [switch]$Wrap)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = $Title; $dlg.Size = New-Object System.Drawing.Size(900, 640); $dlg.StartPosition = 'CenterParent'
    $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9); $dlg.MinimizeBox = $false; $dlg.MaximizeBox = $true
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true; $box.ReadOnly = $true; $box.Dock = 'Fill'; $box.BackColor = 'White'; $box.Text = $Text
    if ($Wrap) {
        $box.WordWrap = $true; $box.ScrollBars = 'Vertical'; $box.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    } else {
        $box.WordWrap = $false; $box.ScrollBars = 'Both'; $box.Font = New-Object System.Drawing.Font('Consolas', 9)
    }
    $labels = @('OK')
    if ($Buttons -eq 'OKCancel') { $labels = @('OK', 'Cancel') }
    if ($Buttons -eq 'YesNo') { $labels = @('Yes', 'No') }
    # the bar helper places the buttons from the dialog's real width (a hand-placed Anchor=Right button drifted off-screen)
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @($labels | ForEach-Object { @{ Text = $_ } })
    $buttonObjects = @($bar.Buttons)
    foreach ($b in $buttonObjects) {
        $b.Tag = $b.Text
        $b.Add_Click({ $dlg.Tag = $this.Tag; $dlg.Close() })
    }
    $dlg.Controls.Add($box); $box.BringToFront(); $box.Select(0, 0)
    # Default button: Button2 = the second (No / Cancel) so Enter can never approve by accident.
    $dlg.AcceptButton = $buttonObjects[0]
    if ($Default -eq 'Button2' -and $buttonObjects.Count -gt 1) { $dlg.AcceptButton = $buttonObjects[1] }
    $dlg.CancelButton = $buttonObjects[-1]
    $dlg.Tag = $labels[-1]   # closing with X = the "safe" answer (No / Cancel / OK)
    $owner = $script:Gui['Form']
    if ($owner -and -not $owner.IsDisposed) { [void]$dlg.ShowDialog($owner) } else { [void]$dlg.ShowDialog() }
    $answer = [string]$dlg.Tag
    $dlg.Dispose()
    return $answer
}

function Get-SafetyChecks {
    # The pre-action confirmations switched on (SafetyChecks, Settings tab), in the order they are asked.  A Trellix one
    # (its name says Trellix) is left out while Trellix is not in use here.
    $trellix = Test-TrellixInUse
    return @(@($script:Config.SafetyChecks) | Where-Object { $_ -and $_.Enabled -and ([string]$_.Name).Trim() -and ([string]$_.Question).Trim() -and ($trellix -or [string]$_.Name -notmatch '(?i)trellix') })
}

function Confirm-SafetyChecks {
    # THE PRE-ACTION CONFIRMATIONS: one Yes/No pop-up per product switched on in the Settings tab (VMware snapshot and
    # Trellix Solidcore Update Mode by default; Airlock and any other step when switched on), asked in that order before
    # every OS patch install, software install / update and removal.  Each must be answered Yes or nothing changes.
    # The default button is "No" so a stray Enter key can never approve a change.
    # Returns a single [bool]; every other pop-up result is discarded with $null = ...
    param([string[]]$Servers, [string]$Activity = 'Patching')
    $list = ($Servers -join "`n")
    $who = Get-OperatorIdentity
    $checks = @(Get-SafetyChecks)
    if ($checks.Count -eq 0) {
        Write-PatchLog 'No pre-action confirmation is switched on (Settings tab) - none asked' 'WARN'
        return [bool]$true
    }
    $n = 0
    foreach ($c in $checks) {
        $n++
        $name = ([string]$c.Name).Trim()
        Write-PatchLog ("Safety check {0} of {1}: asking operator to confirm '{2}'" -f $n, $checks.Count, $name) 'WHY'
        $answer = Show-PatcherMessage -Title ('SAFETY CHECK {0} of {1} - {2}' -f $n, $checks.Count, $name) -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("{0}`n`n{1}`n`nAnswer No and nothing will be changed." -f ([string]$c.Question).Trim(), $list)
        if ($answer -ne 'Yes') {
            Write-PatchLog "ABORTED - $who did not confirm '$name' (answer: $answer)" 'ERROR'
            $ifNo = ([string]$c.IfNo).Trim(); if (-not $ifNo) { $ifNo = "Confirm '$name' first, then come back." }
            $null = Show-PatcherMessage -Text "$Activity aborted. $ifNo" -Title 'Aborted' -Icon 'Error'
            return [bool]$false
        }
        Write-PatchLog "Confirmed by ${who}: '$name' for $($Servers -join ', ')" 'OK'
    }
    return [bool]$true
}

function New-PatchPlan {
    # One row per (server, patch) with Go = $true/$false and the reason.  The decision itself
    # lives in Get-PatchVerdict (04-Patches.ps1) so the grid and the plan can never disagree.
    # With OnePatchPerRun (the default) only the first ready file per server goes; the rest wait for the reboot.
    param([string[]]$ComputerName, [object[]]$Patches)
    # the order one-patch-per-run takes them in: Windows before .NET (the list itself is by sub-folder, DotNet first), and
    # among the Windows files by what the package IS (Kind, read from the manifest inside): a separate servicing stack
    # update first, the cumulative update next, anything else after it.  Size decides only among files of one kind - a
    # smaller file is not an earlier one: in the field (2026-11) a Dynamic Update went first for being the smallest and
    # the reboot undid it, the servicing stack it needed being inside the cumulative update still waiting (R6-B09)
    $rank = {
        param($p)
        $kind = ''; if ($p.PSObject.Properties['Kind']) { $kind = [string]$p.Kind }
        switch ([string]$p.PatchType) {
            'Windows' { switch ($kind) { 'servicing stack' { 0 } 'cumulative' { 1 } default { 2 } } }
            'DotNet' { 3 }
            default { 4 }
        }
    }
    $Patches = @($Patches | Sort-Object @{ Expression = { & $rank $_ } }, @{ Expression = { [double]$_.SizeMB } }, Name)
    $plan = @()
    foreach ($c in $ComputerName) {
        $s = $script:ServerStatus[$c]
        foreach ($p in $Patches) {
            $v = Get-PatchVerdict -Status $s -Patch $p -Server $c
            $plan += [pscustomobject]@{ Computer = $c; KB = $p.KB; Name = $p.Name; File = $p.FullName; Hash = $p.Hash; Go = $v.Go; Reason = $v.Reason }
        }
    }
    if ($script:Config.OnePatchPerRun) { $plan = @(Limit-PlanToOnePatch -Plan $plan) }
    return $plan
}

function Limit-PlanToOnePatch {
    # One patch per server per run.  The first package of a run that returns 3010 leaves a reboot pending; in the
    # field (October 2026, Trellix Solidcore on the servers) the second package then failed and the first was rolled
    # back at the reboot.  So the first ready file per server (New-PatchPlan's order: a separate servicing stack update,
    # the cumulative update, other Windows files, then .NET) goes, every other ready file waits with a reason.
    param([object[]]$Plan)
    $first = @{}
    foreach ($item in @($Plan)) {
        if (-not $item.Go) { continue }
        $key = ([string]$item.Computer).ToLower()
        if (-not $first.ContainsKey($key)) { $first[$key] = [string]$item.KB; continue }
        $item.Go = $false
        $item.Reason = ('waits - one patch per run: {0} goes first, reboot, then this one (OnePatchPerRun on the Settings tab)' -f $first[$key])
    }
    return @($Plan)
}

# ---------------------------------------------------------------------
#  OPEN RUNS.  An OS patch run is handed to the server as a task, so the
#  tool keeps its own note of it - the flag - in settings\patch-runs.json:
#  server, run stamp, KBs, files, the change record, who and when.  The
#  grid shows INSTALLING from the flag (also after restarting the tool);
#  Get-PatchVerdict refuses another install meanwhile; the auto-check
#  loop and every status check compare the flag with what the server says
#  (Resolve-InstallRun) and finish the record (Complete-InstallRun).  A
#  run that ended without a result stays flagged "unknown" until "Analyse
#  a failure" has looked at the server.
# ---------------------------------------------------------------------
function Get-InstallFlagPath { return (Join-Path (Split-Path -Path $script:Config.SettingsFile -Parent) 'patch-runs.json') }

function Get-InstallFlags {
    # server (lower case) -> flag; read once per session, every change saved at once (Set-InstallFlag / Clear-InstallFlag)
    if ($null -eq $script:InstallFlags) {
        $script:InstallFlags = @{}
        $saved = Read-ToolJson -Path (Get-InstallFlagPath)
        if ($saved) { foreach ($p in @($saved.PSObject.Properties)) { $f = $p.Value; if ($f -and $f.PSObject.Properties['Server'] -and $f.Server) { $script:InstallFlags[([string]$f.Server).ToLower()] = $f } } }
    }
    return $script:InstallFlags
}

function Save-InstallFlags {
    $flags = Get-InstallFlags
    $obj = [ordered]@{}
    foreach ($k in @($flags.Keys | Sort-Object)) { $obj[$k] = $flags[$k] }
    Save-ToolJson -Object $obj -Path (Get-InstallFlagPath)
}

function Get-InstallFlag {
    # The open run of a server: by its name as noted, else by the first label - SRV01 in one group file and
    # srv01.corp.local in another are one box (the same rule as the collectors' skip list), so a run noted under one
    # name blocks a second run under the other (R6-14).  A false match between two domains only blocks, never installs.
    param([string]$Server)
    if (-not $Server) { return $null }
    $flags = Get-InstallFlags
    $hit = $flags[$Server.ToLower()]
    if ($hit) { return $hit }
    $short = ($Server -split '\.')[0].ToLower()
    foreach ($k in @($flags.Keys)) { if (($k -split '\.')[0] -eq $short) { return $flags[$k] } }
    return $null
}

function Set-InstallFlag { param($Flag) (Get-InstallFlags)[([string]$Flag.Server).ToLower()] = $Flag; Save-InstallFlags }

function Clear-InstallFlag {
    param([string]$Server)
    $flags = Get-InstallFlags
    if ($flags.ContainsKey($Server.ToLower())) { $flags.Remove($Server.ToLower()); Save-InstallFlags }
}

function New-InstallFlag {
    param([string]$Server, [string]$Stamp, [string[]]$KBs, [string[]]$Files, $Change, [string]$ChangeText, [string]$Task)
    # invariant: in a format string ':' is the culture's time separator ('.' on a fi-FI PC) and Get-InstallFlagMinutes reads it back invariantly
    return [pscustomobject]@{ Server = $Server; Stamp = $Stamp; Started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture); Operator = (Get-OperatorIdentity); KBs = @($KBs); Files = @($Files); Change = $Change; ChangeText = $ChangeText; Task = $Task; State = 'installing'; Note = ''; LastSeen = '' }
}

function Get-InstallFlagMinutes { param($Flag) try { return [int]((Get-Date) - [datetime]::ParseExact([string]$Flag.Started, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)).TotalMinutes } catch { return 0 } }

function Resolve-InstallRun {
    # One open run against what the server reports (Runs: 'Stamp|TaskState|LastResult|Started|Finished', Results:
    # 'Stamp|KB|When|Success|RebootRequired|ExitCode|Message|File' - the same lines from the run-state check and from
    # the status check).  State = finished / running / unknown; Results = one object per file of the run, UNKNOWN
    # where the server left none; Message = why unknown.
    param($Flag, [string[]]$Runs, [string[]]$Results)
    $run = $null
    foreach ($l in @($Runs)) { $f = $l -split '\|', 5; if ($f.Count -ge 5 -and $f[0] -eq [string]$Flag.Stamp) { $run = [pscustomobject]@{ TaskState = $f[1]; LastResult = $f[2]; Started = $f[3]; Finished = $f[4] } } }
    $mine = @()
    foreach ($l in @($Results)) { $f = $l -split '\|', 8; if ($f.Count -ge 8 -and $f[0] -eq [string]$Flag.Stamp) { $mine += [pscustomobject]@{ KB = $f[1]; When = $f[2]; Success = ($f[3] -eq 'True'); RebootRequired = ($f[4] -eq 'True'); ExitCode = $f[5]; Message = $f[6]; File = $f[7] } } }
    $files = @($Flag.Files | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $objects = @()
    foreach ($file in $files) {
        $leaf = Split-Path -Path $file -Leaf
        $hit = @($mine | Where-Object { $_.File -eq $leaf }) | Select-Object -First 1
        if ($hit) { $objects += [pscustomobject]@{ Computer = [string]$Flag.Server; KB = $hit.KB; File = $leaf; Success = $hit.Success; RebootRequired = $hit.RebootRequired; ExitCode = $hit.ExitCode; Message = $hit.Message; Detail = @(); Packages = @() } }
    }
    $minutes = Get-InstallFlagMinutes -Flag $Flag
    $state = 'running'; $msg = ''
    if (($files.Count -gt 0 -and $objects.Count -ge $files.Count) -or ($run -and $run.Finished)) { $state = 'finished' }
    elseif (-not $run) { $state = 'unknown'; $msg = 'the server has no record of this run (no run marker, no task, no result file)' }
    elseif ($run.TaskState -in 'Running', 'unread' -or $run.LastResult -eq '267009') { $state = 'running' }
    elseif ($run.TaskState -eq 'absent') { $state = 'unknown'; $msg = 'the task is gone from the server and no result file was left' }
    elseif ($run.Started) { $state = 'unknown'; $msg = ('the task ended without writing a result (task result {0}): the server rebooted, or the script was stopped' -f $run.LastResult) }
    elseif ($minutes -ge 10) { $state = 'unknown'; $msg = ('the task never started in {0} min (state {1}, result {2})' -f $minutes, $run.TaskState, $run.LastResult) }
    if ($state -ne 'running') {
        # a file the server left no result for is reported UNKNOWN by name, never silently dropped
        foreach ($file in $files) {
            $leaf = Split-Path -Path $file -Leaf
            if (@($objects | Where-Object { $_.File -eq $leaf }).Count -gt 0) { continue }
            $why = $msg; if (-not $why) { $why = 'the run finished but the server left no result for this file' }
            $text = ('UNKNOWN - {0}. Check {1}\result-*.txt and Application event 900 on the server, or press "Analyse a failure (ticked)"' -f $why, $script:Config.RemoteStaging)
            $objects += [pscustomobject]@{ Computer = [string]$Flag.Server; KB = (Get-KBFromName $leaf); File = $leaf; Success = $false; RebootRequired = $false; ExitCode = $null; Message = $text; Detail = @(); Packages = @() }
        }
    }
    return [pscustomobject]@{ State = $state; Results = $objects; Message = $msg; Minutes = $minutes; Run = $run }
}

function Complete-InstallRun {
    # A run with an answer: RESULT lines, change-log rows, the flag cleared (finished) or kept as "unknown" so the grid
    # keeps saying so until "Analyse a failure" has looked at the server.  Returns the result objects.
    param($Flag, $Outcome)
    $who = [string]$Flag.Operator
    foreach ($r in @($Outcome.Results)) {
        $lvl = 'ERROR'; if ($r.Success) { $lvl = 'OK' }
        Write-PatchLog ("RESULT {0}  {1}  exit {2}  -> {3}   (by {4}, run {5})" -f $r.Computer, $r.KB, $r.ExitCode, $r.Message, $who, $Flag.Stamp) $lvl
        Write-ChangeLog -Record $Flag.Change -Server ([string]$Flag.Server) -Action 'OS patch install' -Item $r.KB -Result $r.Message -Operator $who   # the launcher, whoever's check reads the result
    }
    if ($Outcome.State -eq 'unknown') { $Flag.State = 'unknown'; $Flag.Note = [string]$Outcome.Message; Set-InstallFlag -Flag $Flag }
    else { Clear-InstallFlag -Server ([string]$Flag.Server) }
    return @($Outcome.Results)
}

function Get-InstallRunState {
    # One run-state snapshot per flagged server (RemoteRunStateScript), all asked at once: server (lower case) -> row.
    # A server that did not answer has no entry and is asked again next time.
    param([string[]]$Servers)
    $out = @{}
    $names = @(); $stamps = @()
    foreach ($s in @($Servers)) { $f = Get-InstallFlag -Server $s; if ($f) { $names += $s; $stamps += [string]$f.Stamp } }
    if ($names.Count -eq 0) { return $out }
    $stamps = @($stamps | Select-Object -Unique)
    try {
        if (-not $script:RunStateMisses) { $script:RunStateMisses = @{} }
        # this computer among the flagged servers: its run state is read here, no WinRM call to itself
        foreach ($self in @($names | Where-Object { Test-ThisComputer -Name $_ })) {
            $rows = @(& $script:RemoteRunStateScript $script:Config.RemoteStaging $stamps | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Runs'] })
            if ($rows.Count -gt 0) { $out[$self.ToLower()] = $rows[-1]; $script:RunStateMisses[$self.ToLower()] = 0 }
        }
        $names = @($names | Where-Object { -not (Test-ThisComputer -Name $_) })
        if ($names.Count -eq 0) { return $out }
        $conn = Get-ConnectionArgs
        $job = Invoke-Command -ComputerName $names @conn -ScriptBlock $script:RemoteRunStateScript -ArgumentList $script:Config.RemoteStaging, $stamps -AsJob -ErrorAction Stop
        Wait-PatcherJob -Job $job -Activity 'Checking the installs' -TimeoutSec (60 * [math]::Max(1, [math]::Ceiling($names.Count / 32.0)))
        foreach ($child in @($job.ChildJobs)) {
            # per server: its row, or why there is none - a server that cannot be asked (access denied, a name that no longer
            # resolves) is said so, once and then every tenth time, instead of a silent retry for InstallTimeoutMin
            $jobErrors = @()
            $rows = @(Receive-Job -Job $child -ErrorAction SilentlyContinue -ErrorVariable jobErrors | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Runs'] })
            $key = ([string]$child.Location).ToLower()
            if ($rows.Count -gt 0) {
                $row = $rows[-1]
                $name = [string]$row.PSComputerName; if (-not $name) { $name = [string]$row.Computer }; if (-not $name) { $name = [string]$child.Location }
                $out[$name.ToLower()] = $row; $script:RunStateMisses[$key] = 0
                continue
            }
            $why = 'no answer'
            if ($jobErrors.Count -gt 0) { $why = Get-ShortError $jobErrors[0] } elseif ($child.JobStateInfo.Reason) { $why = Get-ShortError $child.JobStateInfo.Reason } elseif ([string]$child.State -eq 'Stopped') { $why = 'no answer within the time limit' }
            $miss = 1 + [int]$script:RunStateMisses[$key]; $script:RunStateMisses[$key] = $miss
            if ($miss -eq 1 -or $miss % 10 -eq 0) { Write-PatchLog ("{0} - the install check got no answer ({1}); the install itself carries on there as a SYSTEM task - asked again at the next check (attempt {2})" -f $child.Location, $why, $miss) 'WARN' }
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    } catch { Write-PatchLog "The install check failed (the installs themselves are unaffected): $(Get-ShortError $_)" 'WARN' }
    return $out
}

function Test-AutoCheckOn {
    # The "Auto-check status" box on the O/S Patching tab; its default (and the answer without a window) is the setting.
    $box = $script:Gui['AutoCheckBox']
    if ($box) { return [bool]$box.Checked }
    return [bool]$script:Config.AutoCheckInstalls
}

function Get-AutoCheckSeconds {
    # The seconds field next to the box (changed any time, also mid-watch); ProgressEverySec without a window. Never under 10.
    $num = $script:Gui['AutoCheckEvery']
    if ($num) { return [math]::Max(10, [int]$num.Value) }
    return [math]::Max(10, [int]$script:Config.ProgressEverySec)
}

function Watch-PatchRuns {
    # After the launches: while "Auto-check status" is ticked, the open runs are asked every N seconds (the field next
    # to the box; N may change while this runs) and each is recorded as it finishes.  Unticking the box, "Let the
    # servers go" on the status bar or InstallTimeoutMin ends the watch: the servers keep installing, their rows say
    # INSTALLING, and the next status check - today or tomorrow, from this or a fresh session - finishes the record.
    param([string[]]$Servers)
    $open = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($Servers)) { if (Get-InstallFlag -Server $s) { $open.Add($s) } }
    $results = @()
    if ($open.Count -eq 0) { return $results }
    if (-not (Test-AutoCheckOn)) {
        Write-PatchLog ("Auto-check is off: {0} server(s) install on their own; their rows say INSTALLING until a status check reads the result (any time, also after restarting the tool)" -f $open.Count) 'INFO'
        return $results
    }
    $button = $script:Gui['StopButton']
    if ($button) { $script:Gui['StopOwner'] = 'install watch'; $script:Gui['StopRequested'] = $false; $button.Enabled = $true; $button.Text = 'Let the servers go'; $button.ToolTipText = 'Stop watching: the servers keep installing, their rows say INSTALLING, and a later status check records the results'; $button.Visible = $true }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastPoll = -100000; $lastDetail = 0
    try {
        while ($open.Count -gt 0 -and $watch.Elapsed.TotalMinutes -lt $script:Config.InstallTimeoutMin) {
            if (-not (Test-AutoCheckOn)) { Write-PatchLog ("Auto-check unticked by {0}: {1} server(s) keep installing - their rows say INSTALLING; tick it again, or 'Check status', to finish the record later" -f (Get-OperatorIdentity), $open.Count) 'WARN'; break }
            if ($button -and $script:Gui['StopRequested']) { Write-PatchLog ("Let go by {0}: {1} server(s) keep installing - their rows say INSTALLING; 'Check status' finishes the record later" -f (Get-OperatorIdentity), $open.Count) 'WARN'; break }
            $every = Get-AutoCheckSeconds
            $wait = [int][math]::Max(0, $every - ($watch.Elapsed.TotalSeconds - $lastPoll))
            Set-GuiStatus ('Installing on {0} server(s) [{1}] ... {2} min {3} s - next check in {4} s (untick Auto-check or press "Let the servers go" to come back later)' -f $open.Count, ((@($open) | Select-Object -First 6) -join ', '), [int][math]::Floor($watch.Elapsed.TotalMinutes), $watch.Elapsed.Seconds, $wait)
            if ($watch.Elapsed.TotalSeconds - $lastPoll -ge $every) {
                $lastPoll = $watch.Elapsed.TotalSeconds
                $states = Get-InstallRunState -Servers @($open)
                $running = @()
                foreach ($s in @($open)) {
                    $row = $states[$s.ToLower()]
                    if (-not $row) { continue }   # no answer this time: asked again at the next tick
                    $flag = Get-InstallFlag -Server $s
                    $outcome = Resolve-InstallRun -Flag $flag -Runs @($row.Runs) -Results @($row.Results)
                    if ($outcome.State -eq 'running') {
                        $running += $row; $flag.LastSeen = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
                        if ([string]$flag.State -eq 'unknown') { $flag.State = 'installing'; $flag.Note = ''; Set-InstallFlag -Flag $flag }   # the server says running after all
                        continue
                    }
                    $results += @(Complete-InstallRun -Flag $flag -Outcome $outcome)
                    [void]$open.Remove($s)
                }
                if ($running.Count -gt 0) {
                    $detail = $false
                    if ($watch.Elapsed.TotalSeconds - $lastDetail -ge ($script:Config.ProgressDetailEveryMin * 60)) { $detail = $true; $lastDetail = $watch.Elapsed.TotalSeconds }
                    Write-ProgressSummary -Rows $running -ElapsedSec ([int]$watch.Elapsed.TotalSeconds) -Detail:$detail
                }
            }
            if ($script:Gui['Form']) { [System.Windows.Forms.Application]::DoEvents() }
            Start-Sleep -Milliseconds 300
        }
    } finally { $script:Gui['StopOwner'] = $null; if ($button) { $button.Visible = $false; $button.Text = 'Stop waiting'; $button.ToolTipText = 'Give up on the servers that have not answered yet (read-only checks only; nothing is changed on them)' } }
    if ($open.Count -gt 0 -and $watch.Elapsed.TotalMinutes -ge $script:Config.InstallTimeoutMin) { Write-PatchLog ("Stopped watching after {0} min: {1} server(s) still installing - their rows say INSTALLING; 'Check status' finishes the record later" -f $script:Config.InstallTimeoutMin, $open.Count) 'WARN' }
    return $results
}

function Get-OpenInstallServers {
    # The servers with a run noted as still installing ('unknown' runs are already recorded: "Analyse a failure" clears them).
    $flags = Get-InstallFlags
    return @(foreach ($k in @($flags.Keys | Sort-Object)) { if ([string]$flags[$k].State -eq 'installing') { [string]$flags[$k].Server } })
}

function Resume-PatchWatch {
    # "Auto-check status" ticked again after a watch has ended (or after PATCH IT! ran with it unticked): the runs still
    # open are watched again, then a fresh status check - steps 8 and 9 of Install-PatchOnServers.  Returns the results read.
    $open = @(Get-OpenInstallServers)
    if ($open.Count -eq 0) { return @() }
    Write-PatchLog ("Auto-check ticked again by {0}: watching {1} server(s) still installing ({2})" -f (Get-OperatorIdentity), $open.Count, ($open -join ', ')) 'INFO'
    $results = @()
    $script:InstallTargets = $open    # read-only collectors running alongside skip these servers (Invoke-Collector)
    try { $results = @(Watch-PatchRuns -Servers $open) } finally { $script:InstallTargets = @() }
    $results += @(Get-ServerStatusWithRunResults -ComputerName $open)
    return $results
}

function Get-ServerStatusWithRunResults {
    # A status check whose recording of a finished run (Update-InstallFlagsFromStatus) is handed back instead of shown: the
    # caller adds it to the run's own results, so one pop-up and one INSTALL FINISHED line carry every result, with one count.
    param([string[]]$ComputerName)
    $script:InstallOutcomeSink = New-Object System.Collections.ArrayList
    try { Get-ServerStatus -ComputerName $ComputerName | Out-Null; return @($script:InstallOutcomeSink.ToArray()) }
    finally { $script:InstallOutcomeSink = $null }
}

function Show-InstallOutcome {
    # The pop-up after a run, or after a status check that finished one: the counts, and for a failed or unknown server
    # the offer to analyse it now ("Analyse a failure" reads the server's own logs).
    param([object[]]$Results, [string]$Title = 'Install finished')
    $rs = @($Results | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Success'] })
    if ($rs.Count -eq 0) { return }
    $good = @($rs | Where-Object { $_.Success }).Count
    $bad = @($rs | Where-Object { -not $_.Success })
    $reb = @($rs | Where-Object { $_.RebootRequired }).Count
    if ($bad.Count -eq 0) { Write-PatchLog ('   \o/  All installs succeeded. Nice one, {0}!' -f $script:Config.OperatorName) 'OK' }
    if (-not $script:Gui['Form'] -or -not (Test-GuiDialogAllowed 'The install result')) { return }   # no window (NoGui): the log has it
    $text = "Installed OK: {0}`nFailed or unknown: {1}`nNeed a reboot: {2}`n`nDetails are in the log. Reboot with the 'Reboot (ticked)' button when you are ready." -f $good, $bad.Count, $reb
    $agentOff = @(Get-TrellixStoppedServers -Servers @($rs | ForEach-Object { [string]$_.Computer } | Select-Object -Unique))
    if ($agentOff.Count -gt 0) { $text += "`n`nThe Trellix Agent services are stopped on {0} of these server(s): after the reboot, tick them and press 'Start Trellix Agent (ticked)'." -f $agentOff.Count }
    if ($bad.Count -eq 0) { $null = Show-PatcherMessage -Title $Title -Text $text; return }
    $servers = @($bad | ForEach-Object { [string]$_.Computer } | Select-Object -Unique)
    $a = Show-PatcherMessage -Title $Title -Buttons 'YesNo' -Icon 'Warning' -Text ($text + "`n`nFailed or unknown on: " + ($servers -join ', ') + "`n`nAnalyse the failed server(s) now? It reads their own logs (result files, DISM, CBS, Setup events, Solidcore) - read-only.")
    if ($a -eq 'Yes') { Show-FailureAnalysis -ComputerName $servers }
    else { Write-PatchLog ("Not analysed now. A server whose run ended without a result keeps RUN UNKNOWN until 'Analyse a failure (ticked)' has looked at it; one that is no longer in any group list can only be cleared by removing its entry from {0}" -f (Get-InstallFlagPath)) 'INFO' }
}

function Update-InstallFlagsFromStatus {
    # After a status check: every open run on the servers just checked is matched against what the server reported
    # (PatchRuns / PatchResults in its Status result) and finished, kept running, or marked unknown.
    param([string[]]$Servers)
    $done = @()
    foreach ($s in @($Servers)) {
        $flag = Get-InstallFlag -Server $s
        if (-not $flag) { continue }
        $st = $script:ServerStatus[$s]
        if (-not $st -or -not $st.Reachable -or -not $st.PSObject.Properties['PatchRuns']) { continue }
        # the run records could not be read on the server: "no record of this run" would be a guess, and an UNKNOWN written on it
        if ($st.PSObject.Properties['PatchRunsError'] -and $st.PatchRunsError) { Write-PatchLog ("{0} - the run records could not be read ({1}): run {2} stays as it is until the next check" -f $s, $st.PatchRunsError, $flag.Stamp) 'WARN'; continue }
        $outcome = Resolve-InstallRun -Flag $flag -Runs @($st.PatchRuns) -Results @($st.PatchResults)
        if ($outcome.State -eq 'running') {
            $flag.LastSeen = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
            if ([string]$flag.State -eq 'unknown') { $flag.State = 'installing'; $flag.Note = ''; Set-InstallFlag -Flag $flag; Write-PatchLog ("{0} - run {1} was noted as ended without a result, but the server says it is still running: INSTALLING again" -f $s, $flag.Stamp) 'WARN' }
            Write-PatchLog ("{0} - still installing: run {1} started {2} by {3} ({4} min)" -f $s, $flag.Stamp, $flag.Started, $flag.Operator, $outcome.Minutes) 'INFO'
            continue
        }
        if ([string]$flag.State -eq 'unknown' -and $outcome.State -eq 'unknown') { continue }   # already recorded; "Analyse a failure" clears it
        $done += @(Complete-InstallRun -Flag $flag -Outcome $outcome)
    }
    if ($done.Count -eq 0) { return }
    # inside PATCH IT! (step 9) or a resumed watch the caller collects these into its own pop-up and INSTALL FINISHED line
    if ($null -ne $script:InstallOutcomeSink) { $script:InstallOutcomeSink.AddRange(@($done)) } else { Show-InstallOutcome -Results $done -Title 'Install run finished (read at the status check)' }
}

function Get-PatchStagePlan {
    # STAGE ONLY: which (server, file) pairs get a copy.  A file goes where PATCH IT! would send it now, and also where
    # only a reboot, servicing or the Solidcore mode stands in the way - staging ahead of the window is the point.  Not
    # where it is installed, built for another Windows, unsigned, by hand, short of disk, or where a run is still open.
    param([string[]]$ComputerName, [object[]]$Patches)
    $plan = @()
    foreach ($c in $ComputerName) {
        $s = $script:ServerStatus[$c]
        foreach ($p in $Patches) {
            $v = Get-PatchVerdict -Status $s -Patch $p -Server $c
            $go = $v.Go
            $reason = $v.Reason
            if (-not $go -and $v.Cell -in 'Blocked: reboot', 'Blocked: servicing', 'Blocked: Solidcore') {
                # the verdict stops at the first block, so the checks after it (disk, signature, the OS the file is for) were
                # never made: judge the pair again as if only those three were lifted - a copy must still fit and still apply (R6-02)
                $rest = $s.PSObject.Copy()
                foreach ($lift in 'PendingReboot', 'ServicingActive', 'SolidcorePresent') { $rest | Add-Member -NotePropertyName $lift -NotePropertyValue $false -Force }   # also on a status without the field
                $later = Get-PatchVerdict -Status $rest -Patch $p -Server $c
                if ($later.Go) { $go = $true } else { $reason = ('{0} for now, and {1} - not copied' -f $v.Cell, $later.Reason) }
            }
            if ($go) {
                $reason = 'copy'
                if ($v.Cell -eq 'READY (staged)') { $reason = 'already there - the hash is checked, no copy' }
                elseif ($v.Cell -like 'Blocked:*') { $reason = 'copy (' + ($v.Cell -replace '^Blocked: ', '') + ' - the install waits, the copy need not)' }
            }
            $plan += [pscustomobject]@{ Computer = $c; KB = $p.KB; Name = $p.Name; File = $p.FullName; Hash = $p.Hash; Go = $go; Reason = $reason; Cell = $v.Cell }
        }
    }
    return $plan
}

function Copy-PatchToServers {
    # STAGE ONLY: the ticked files are copied to C:\PatchStaging on the ticked servers and verified (SHA256); nothing is
    # installed, and PATCH IT! later finds them there and skips the copy.  The steps: fresh status, the plan, the change
    # record ('OS patch stage', Not recorded by default: no form), per server the locked staging folder and the slice
    # copy.  No pre-action confirmations: a copy changes no installed software.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName, [Parameter(Mandatory = $true)][object[]]$Patches)
    $targets = @(Get-UniqueNames $ComputerName)
    $who = Get-OperatorIdentity
    Write-PatchLog ("=== STAGE ONLY REQUESTED by {0}: {1} to {2} ===" -f $who, (($Patches | ForEach-Object { $_.KB }) -join ', '), ($targets -join ', ')) 'INFO'
    Write-PatchLog 'Pre-flight: fresh status, so a file is not copied where it is installed, cannot apply, or would not fit' 'WHY'
    Get-ServerStatus -ComputerName $targets | Out-Null
    $who = Get-OperatorIdentity   # again: the status check may have asked for other credentials
    $targets = @(Remove-DuplicateServers $targets)
    $plan = @(Get-PatchStagePlan -ComputerName $targets -Patches $Patches)
    foreach ($item in $plan) { $lvl = 'WARN'; if ($item.Go) { $lvl = 'INFO' }; Write-PatchLog ("Stage plan: {0}  {1}  -> {2}" -f $item.Computer, $item.KB, $item.Reason) $lvl }
    $todo = @($plan | Where-Object { $_.Go })
    if ($todo.Count -eq 0) {
        $null = Show-PatcherMessage -Text 'Nothing to stage - every server/file pair is installed, not applicable, blocked for good or unreachable. See the log for the reason per server.' -Title 'Nothing to do' -Icon 'Information'
        return @()
    }
    $planText = ($plan | ForEach-Object { '{0,-36} {1,-10} {2}' -f $_.Computer, $_.KB, $_.Reason }) -join "`n"
    $ok = Show-PatcherMessage -Title 'The plan - STAGE ONLY' -Buttons 'OKCancel' -Icon 'Question' -Text ("The files are copied to {0} on each server and verified (SHA256). Nothing is installed; PATCH IT! later finds them there and skips the copy.`n`n{1}`n`nContinue?" -f $script:Config.RemoteStaging, $planText)
    if ($ok -ne 'OK') { Write-PatchLog "$who cancelled at the plan screen" 'WARN'; return @() }
    $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
    $change = Request-ChangeRecord -Action 'OS patch stage' -Servers $goServers -Items (($todo | ForEach-Object { $_.KB } | Select-Object -Unique) -join ', ')
    if (-not $change) { return @() }
    $results = @()
    $done = @{}
    $n = 0
    foreach ($c in $goServers) {
        $n++
        $sess = $null
        try {
            $sess = New-ToolkitSession -ComputerName $c -Prefix ("[{0}/{1}] " -f $n, $goServers.Count)
            $ready = Invoke-RemoteBlock -Session $sess -ScriptBlock $script:RemoteStagingScript -ArgumentList $script:Config.RemoteStaging
            Write-PatchLog "$c - $ready" 'INFO'
            foreach ($item in @($todo | Where-Object { $_.Computer -eq $c })) {
                $dest = $script:Config.RemoteStaging.TrimEnd('\') + '\' + $item.Name
                $sizeMB = [math]::Round((Get-Item -LiteralPath $item.File).Length / 1MB, 1)
                Write-PatchLog ("Copy-FileToSession -Path '{0}' -Destination '{1}' -Session [{2}]   ({3} MB, sent in WinRM-sized slices)" -f $item.File, $dest, $c, $sizeMB) 'CMD'
                Copy-FileToSession -Path $item.File -Destination $dest -Session $sess -LocalHash $item.Hash | Out-Null
                $r = New-InstallResult -Computer $c -KB $item.KB -File $item.Name -Message "staged in $dest (SHA256 verified)"
                $r.Success = $true
                $results += $r
                $done[$c + '|' + $item.Name] = $true   # by file: two files of one KB (a .NET 4.8 and 4.8.1 rollup) are two copies
                Write-ChangeLog -Record $change -Server $c -Action 'OS patch stage' -Item $item.KB -Result "staged in $dest (SHA256 verified)"
                Write-PatchLog ("STAGED {0}  {1}  -> {2} (SHA256 verified, by {3})" -f $c, $item.KB, $dest, $who) 'OK'
            }
        } catch {
            $msg = Get-ShortError $_
            Write-PatchLog "$c - staging failed: $msg" 'ERROR'
            Write-PatchLog "   failed at: $(Get-ErrorLocation $_)" 'WHY'
            foreach ($item in @($todo | Where-Object { $_.Computer -eq $c })) {
                if ($done.ContainsKey($c + '|' + $item.Name)) { continue }
                $results += New-InstallResult -Computer $c -KB $item.KB -File $item.Name -Message "staging failed: $msg"
                Write-ChangeLog -Record $change -Server $c -Action 'OS patch stage' -Item $item.KB -Result "staging failed: $msg"
            }
        } finally { Close-ToolkitSession -Session $sess }
    }
    Get-ServerStatus -ComputerName $goServers | Out-Null   # the grid now says READY (staged)
    $good = @($results | Where-Object { $_.Success }).Count
    $bad = @($results | Where-Object { -not $_.Success }).Count
    Write-PatchLog ("=== STAGE ONLY FINISHED (by {2}): {0} file(s) staged, {1} failed ===" -f $good, $bad, $who) 'INFO'
    if ($script:Gui['Form'] -and (Test-GuiDialogAllowed 'The staging result')) {
        $null = Show-PatcherMessage -Title 'Staging finished' -Icon 'Information' -Text ("Staged (copied and verified): {0}`nFailed: {1}`n`nNothing was installed. The KB cells say READY (staged); PATCH IT! skips the copy for those." -f $good, $bad)
    }
    return $results
}

function Install-PatchOnServers {
    param(
        [Parameter(Mandatory = $true)][string[]]$ComputerName,
        [Parameter(Mandatory = $true)][object[]]$Patches      # objects from Get-PatchFiles
    )
    $targets = @(Get-UniqueNames $ComputerName)
    $who = Get-OperatorIdentity
    Write-PatchLog ("=== INSTALL REQUESTED by {0}: {1} on {2} ===" -f $who, (($Patches | ForEach-Object { $_.KB }) -join ', '), ($targets -join ', ')) 'INFO'

    # 1. Fresh status, 2. plan
    Write-PatchLog 'Pre-flight: refreshing status so we never patch a server that is pending a reboot or busy' 'WHY'
    Get-ServerStatus -ComputerName $targets | Out-Null
    $who = Get-OperatorIdentity   # again: the status check may have asked for other credentials
    $targets = @(Remove-DuplicateServers $targets)
    $plan = New-PatchPlan -ComputerName $targets -Patches $Patches
    foreach ($item in $plan) {
        $lvl = 'WARN'; if ($item.Go) { $lvl = 'INFO' }
        Write-PatchLog ("Plan: {0}  {1}  -> {2}" -f $item.Computer, $item.KB, $item.Reason) $lvl
    }
    $todo = @($plan | Where-Object { $_.Go })
    if ($todo.Count -eq 0) {
        $null = Show-PatcherMessage -Text "Nothing to install - every server/patch pair is either done, blocked or unreachable. See the log for the reason per server." -Title 'Nothing to do' -Icon 'Information'
        return @()
    }

    # 3. Show the plan
    $planText = ($plan | ForEach-Object { '{0,-36} {1,-10} {2}' -f $_.Computer, $_.KB, $_.Reason }) -join "`n"
    $agentNote = ''
    $stopAgent = Test-TrellixStopOn -Console 'Patching'   # read once: the plan the operator approves is what happens (the box stays clickable meanwhile, R6-B07)
    if ($stopAgent) { $agentNote = "`nTrellix Agent: the services masvc and macmnsvc are set to Disabled and stopped on each server before the install (the box on the tab). Start them again after the reboot with 'Start Trellix Agent (ticked)'.`n" }
    $ok = Show-PatcherMessage -Title 'The plan' -Buttons 'OKCancel' -Icon 'Question' -Text @"
This is what will happen ("ready" rows are installed, the rest are skipped):

$planText
$agentNote
Continue to the safety checks?
"@
    if ($ok -ne 'OK') { Write-PatchLog "$who cancelled at the plan screen" 'WARN'; return @() }

    # 4 + 5. The pre-action confirmations (Settings tab).  Strict comparison: anything but a real $true aborts.
    $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
    # 3b. The change record (ticket / change number, approver, window): Cancel = nothing happens
    $change = Request-ChangeRecord -Action 'OS patch install' -Servers $goServers -Items (($todo | ForEach-Object { $_.KB } | Select-Object -Unique) -join ', ')
    if (-not $change) { return @() }
    $changeText = Format-ChangeText $change
    $confirmed = Confirm-SafetyChecks -Servers $goServers
    if ($confirmed -isnot [bool] -or $confirmed -ne $true) { Write-PatchLog 'Safety checks not confirmed - nothing was touched' 'WARN'; Write-ChangeLog -Record $change -Server $goServers -Action 'OS patch install' -Item (($todo | ForEach-Object { $_.KB } | Select-Object -Unique) -join ', ') -Result 'aborted at the safety checks - nothing changed'; return @() }

    # 6a. The pop-ups may have been open for a long time: check the servers AGAIN and drop any that changed.
    Write-PatchLog 'Re-checking the servers now that the safety checks are done (status may be minutes old)' 'WHY'
    Get-ServerStatus -ComputerName $goServers | Out-Null
    $recheck = New-PatchPlan -ComputerName $goServers -Patches $Patches
    $stillGo = @()
    foreach ($item in $todo) {
        $now = $recheck | Where-Object { $_.Computer -eq $item.Computer -and $_.Name -eq $item.Name } | Select-Object -First 1   # by file: one KB can be two files (R6-04)
        if ($now -and $now.Go) { $stillGo += $item } else { Write-PatchLog ("Dropped {0} {1} - no longer ready: {2}" -f $item.Computer, $item.KB, $now.Reason) 'WARN' }
    }
    $todo = $stillGo
    $recheckClock = [System.Diagnostics.Stopwatch]::StartNew()   # copies go one server at a time: a later server is checked again before its launch (7)
    $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
    foreach ($c in $goServers) { Write-ChangeLog -Record $change -Server $c -Action 'OS patch install' -Item ((@($todo | Where-Object { $_.Computer -eq $c }) | ForEach-Object { $_.KB }) -join ', ') -Result 'approved - starting' }
    if ($todo.Count -eq 0) {
        $null = Show-PatcherMessage -Text 'Every server changed state while the pop-ups were open (pending reboot, busy or unreachable). Nothing was installed - check the log and try again.' -Title 'Nothing to do' -Icon 'Warning'
        return @()
    }
    $results = @()

    # 6c. The Trellix Agent (the box on the tab, ticked by default): the two agent services are set to Disabled and stopped
    #     on each server before anything is copied - the field test saw the install fail and roll back with them running.
    #     A server where that fails is dropped (fail closed; untick the box to install with the agent running).
    if ($stopAgent) {
        $agentRows = @(Invoke-TrellixAgentChange -ComputerName $goServers -Mode stop -Change $change -Action 'OS patch install')
        $agentFailed = @($agentRows | Where-Object { -not $_.Success } | ForEach-Object { $_.Server })
        foreach ($c in $agentFailed) {
            $why = [string]@($agentRows | Where-Object { $_.Server -eq $c })[0].Message
            foreach ($item in @($todo | Where-Object { $_.Computer -eq $c })) {
                $results += New-InstallResult -Computer $c -KB $item.KB -File $item.Name -Message ('not installed - ' + $why)
                Write-ChangeLog -Record $change -Server $c -Action 'OS patch install' -Item $item.KB -Result ('not installed - ' + $why)
            }
        }
        $todo = @($todo | Where-Object { $agentFailed -notcontains $_.Computer })
        $goServers = @(Get-UniqueNames ($todo | ForEach-Object { $_.Computer }))
        if ($todo.Count -eq 0) {
            $null = Show-PatcherMessage -Text 'The Trellix Agent services could not be stopped on any server, so nothing was installed - the log has the error per server. Untick "Stop the Trellix Agent services first" to install with the agent running.' -Title 'Nothing to do' -Icon 'Warning'
            return $results
        }
    }

    # 6b + 7. Per server: session, locked staging folder, copy - and the moment that server's copy is verified the
    #         install is handed to the SERVER as a one-shot SYSTEM task (RemoteInstallLaunchScript), so it outlives this
    #         session, this tool and this PC.  Copies go one server at a time (the log stays readable); the installs
    #         overlap.  Each run is flagged in settings\patch-runs.json; step 8 watches it while Auto-check is ticked.
    $launched = @()
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $n = 0
    foreach ($c in $goServers) {
        $n++
        $sess = $null
        $launching = $false
        try {
            $sess = New-ToolkitSession -ComputerName $c -Prefix ("[{0}/{1}] " -f $n, $goServers.Count)
            $ready = Invoke-RemoteBlock -Session $sess -ScriptBlock $script:RemoteStagingScript -ArgumentList $script:Config.RemoteStaging
            Write-PatchLog "$c - $ready" 'INFO'

            $remoteFiles = @()
            $remoteHashes = @()
            $kbs = @()
            foreach ($item in @($todo | Where-Object { $_.Computer -eq $c })) {
                # Built as a string on purpose: Join-Path would check the drive letter on THIS machine.
                $dest = $script:Config.RemoteStaging.TrimEnd('\') + '\' + $item.Name
                $sizeMB = [math]::Round((Get-Item -LiteralPath $item.File).Length / 1MB, 1)
                Write-PatchLog ("Copy-FileToSession -Path '{0}' -Destination '{1}' -Session [{2}]   ({3} MB, sent in WinRM-sized slices - this takes a while)" -f $item.File, $dest, $c, $sizeMB) 'CMD'
                Copy-FileToSession -Path $item.File -Destination $dest -Session $sess -LocalHash $item.Hash | Out-Null
                $remoteFiles += $dest
                $remoteHashes += $item.Hash
                $kbs += $item.KB
            }
            # the verdicts are from the check before the copies: on a long run the 20th server's copy ends an hour later, after
            # the Update Mode window may have closed - so a server reached more than 5 minutes after that check is asked once
            # more (Solidcore mode, pending reboot, disk) and a file that is no longer ready stays staged, not installed (R6-07)
            if ($recheckClock.Elapsed.TotalMinutes -ge 5) {
                Write-PatchLog ("{0} - {1} min since the last status check: checked once more before its install starts" -f $c, [int]$recheckClock.Elapsed.TotalMinutes) 'WHY'
                Get-ServerStatus -ComputerName @($c) | Out-Null
                $fresh = @(New-PatchPlan -ComputerName @($c) -Patches $Patches)
                $keepFiles = @(); $keepHashes = @(); $keepKbs = @()
                for ($i = 0; $i -lt $remoteFiles.Count; $i++) {
                    $leaf = Split-Path -Path $remoteFiles[$i] -Leaf
                    $now = @($fresh | Where-Object { $_.Name -eq $leaf })[0]
                    if ($now -and $now.Go) { $keepFiles += $remoteFiles[$i]; $keepHashes += $remoteHashes[$i]; $keepKbs += $kbs[$i]; continue }
                    $why = 'not installed - no longer ready at its launch: ' + $(if ($now) { $now.Reason } else { 'no verdict' }) + ' (the file stays staged on the server)'
                    Write-PatchLog ("{0} {1} - {2}" -f $c, $kbs[$i], $why) 'WARN'
                    $results += New-InstallResult -Computer $c -KB $kbs[$i] -File $leaf -Message $why
                    Write-ChangeLog -Record $change -Server $c -Action 'OS patch install' -Item $kbs[$i] -Result $why
                }
                $remoteFiles = $keepFiles; $remoteHashes = $keepHashes; $kbs = $keepKbs
                if ($remoteFiles.Count -eq 0) {
                    if ((Test-TrellixInUse) -and (Get-TrellixAgentInfo -Status $script:ServerStatus[$c]).State -eq 'stopped') { Write-PatchLog "$c - nothing installed, and its Trellix Agent services stay stopped: start them with 'Start Trellix Agent (ticked)'" 'WARN' }
                    continue
                }
            }
            $runPath = $script:Config.RemoteStaging.TrimEnd('\') + '\run-' + $stamp + '.txt'
            $text = New-InstallTaskScript -RemoteFiles $remoteFiles -ExpectedHashes $remoteHashes -Cleanup $script:Config.CleanupStaging -RequireSignature $script:Config.RequireValidSignature -Operator $who -ChangeText $changeText -RunStamp $stamp -RunPath $runPath
            $desc = ('WinRM Toolkit OS patch {0} | change {1} | by {2}' -f ($kbs -join ', '), $changeText, $who)
            # the run is noted BEFORE the launch: a launch that starts the task and then loses its answer (a dropped session)
            # must still leave the run noted, or the grid says READY while the server installs (R6-06)
            Set-InstallFlag -Flag (New-InstallFlag -Server $c -Stamp $stamp -KBs $kbs -Files $remoteFiles -Change $change -ChangeText $changeText -Task ('\WinRMToolkit\OSPatch-' + $stamp))
            $launching = $true
            Write-PatchLog ("Invoke-Command -Session [{0}] RemoteInstallLaunchScript  (install-{1}.ps1 as a one-shot SYSTEM task: {2}{3})" -f $c, $stamp, ($remoteFiles -join ', '), $(if (Test-LocalSession -Session $sess) { '; this computer: the launch runs here' } else { '' })) 'CMD'
            $started = Invoke-RemoteBlock -Session $sess -ScriptBlock $script:RemoteInstallLaunchScript -ArgumentList $script:Config.RemoteStaging, $stamp, $text, $desc
            $launching = $false
            $launched += $c
            Write-PatchLog "$c - $started; the install now belongs to the server and carries on whatever happens to this session" 'OK'
        } catch {
            $msg = Get-ShortError $_
            if ($launching) {
                # the launch was sent: the task may have started before the error - the note stays, as "ended without a
                # result" until a status check reads the server (it turns INSTALLING again, or records the result)
                $launching = $false
                $open = Get-InstallFlag -Server $c
                if ($open -and [string]$open.Stamp -eq $stamp) { $open.State = 'unknown'; $open.Note = 'the launch did not answer cleanly: ' + $msg; Set-InstallFlag -Flag $open }
                Write-PatchLog "$c - the launch failed or lost its answer: $msg - the task may have started; 'Check status (ticked)' tells (the row says RUN UNKNOWN until then)" 'ERROR'
                foreach ($k in @($kbs)) {
                    $leaf = @($remoteFiles | Where-Object { (Get-KBFromName (Split-Path -Path $_ -Leaf)) -eq $k } | ForEach-Object { Split-Path -Path $_ -Leaf })[0]
                    $results += New-InstallResult -Computer $c -KB $k -File $leaf -Message "UNKNOWN - the launch failed or lost its answer ($msg); the task may have started - press Check status"
                    Write-ChangeLog -Record $change -Server $c -Action 'OS patch install' -Item $k -Result "UNKNOWN - the launch failed or lost its answer ($msg)"
                }
            } else {
                Write-PatchLog "$c - staging failed: $msg" 'ERROR'
                Write-PatchLog "   failed at: $(Get-ErrorLocation $_)" 'WHY'
                foreach ($item in @($todo | Where-Object { $_.Computer -eq $c })) {
                    $results += New-InstallResult -Computer $c -KB $item.KB -File $item.Name -Message "staging failed: $msg"
                    Write-ChangeLog -Record $change -Server $c -Action 'OS patch install' -Item $item.KB -Result "staging failed: $msg"
                }
            }
        } finally {
            # the session has done its work: the task on the server does not need it
            Close-ToolkitSession -Session $sess
        }
    }

    # 8. Watch.  While "Auto-check status" is ticked the open runs are asked every N seconds (the field next to the box)
    #    and recorded as they finish.  Unticking the box, "Let the servers go" or InstallTimeoutMin hands the rest to a
    #    later status check: the rows say INSTALLING until then (also after restarting the tool).
    if ($launched.Count -gt 0) {
        Write-PatchLog ("{0} server(s) installing as SYSTEM tasks on the servers. DISM's own log goes quiet after 'CBS session options'; real progress comes from CBS.log at every check. Auto-check is {1}: {2}" -f $launched.Count, $(if (Test-AutoCheckOn) { 'ON' } else { 'OFF' }), $(if (Test-AutoCheckOn) { ('the servers are asked every ' + (Get-AutoCheckSeconds) + ' s - untick the box or press "Let the servers go" to come back later') } else { 'press "Check status" whenever you want the results (today or tomorrow)' })) 'INFO'
        $script:InstallTargets = $launched    # read-only collectors running alongside skip these servers (Invoke-Collector)
        try { $results += @(Watch-PatchRuns -Servers $launched) } finally { $script:InstallTargets = @() }
        $stillOpen = @($launched | Where-Object { $f = Get-InstallFlag -Server $_; $f -and [string]$f.State -ne 'unknown' })
        if ($stillOpen.Count -gt 0 -and $script:Gui['Form'] -and (Test-GuiDialogAllowed 'The install note')) {
            $null = Show-PatcherMessage -Title 'Installing on the servers' -Icon 'Information' -Text ("{0} server(s) are installing on their own now (a SYSTEM task on each):`n`n{1}`n`nTheir rows say INSTALLING. Tick Auto-check again, or press 'Check status (ticked)' whenever you want the results - in an hour or tomorrow, also after restarting the tool. Each result lands in the log and the change log as it is read." -f $stillOpen.Count, ($stillOpen -join "`n"))
        }
    }

    # 9. Fresh status again so the grid tells the truth.  A run the watch let go that finished meanwhile is recorded by this
    #    check: its results join the run's, so the pop-up and the INSTALL FINISHED line below count them too
    $results += @(Get-ServerStatusWithRunResults -ComputerName $goServers)
    $good = @($results | Where-Object { $_.Success }).Count
    $bad  = @($results | Where-Object { -not $_.Success }).Count
    $reb  = @($results | Where-Object { $_.RebootRequired }).Count
    Write-PatchLog ("=== INSTALL FINISHED (by {3}): {0} ok, {1} failed/unknown, {2} need a reboot ===" -f $good, $bad, $reb, $who) 'INFO'
    return $results
}

function New-InstallResult {
    # A failure result shaped exactly like the ones the remote script returns.
    param([string]$Computer, [string]$KB, [string]$File, [string]$Message)
    return [pscustomobject]@{ Computer = $Computer; KB = $KB; File = $File; Success = $false; RebootRequired = $false; ExitCode = $null; Message = $Message; Detail = @(); Packages = @() }
}

function Get-KBFromName {
    param([string]$Name)
    if ($Name -match '(?i)(KB\d{6,7})') { return $Matches[1].ToUpper() }
    return 'KB?'
}

function Remove-DuplicateServers {
    # Two names that resolve to the SAME computer (short name + FQDN, or different case) would get two
    # concurrent installs.  After a status check we know each server's real name, so keep the first alias.
    param([string[]]$Names)
    $seen = @{}
    $keep = @()
    foreach ($n in $Names) {
        $s = $script:ServerStatus[$n]
        # only a server that answered can be recognised as another name of the same box: an unreachable alias is kept
        # (the plan skips it), so a short name that fails DNS can never hide the FQDN that works
        if (-not ($s -and $s.Reachable -and $s.Computer)) { $keep += $n; continue }
        $real = $s.Computer.ToUpper()
        if ($s.PSObject.Properties['DnsDomain'] -and $s.DnsDomain) { $real += '.' + ([string]$s.DnsDomain).ToUpper() }   # two SRV01s in two domains are two boxes
        if ($seen.ContainsKey($real)) {
            Write-PatchLog "$n is the same computer as $($seen[$real]) ($real) - skipping the duplicate" 'WARN'
            continue
        }
        $seen[$real] = $n
        $keep += $n
    }
    return $keep
}

# RUNS ON THE TARGET SERVER: refuses to reboot while servicing is active, then schedules the
# restart $DelaySec out (10 s; 60 s when the server is the toolkit PC itself, so the log and the
# change log are written before the toolkit goes down with it) with shutdown.exe, so this call
# returns before the connection is cut.
$script:RemoteRebootScript = {
    param([string]$Operator, [string]$ChangeText = '', [string]$Staging = '', [int]$DelaySec = 10)
    if ($DelaySec -lt 5) { $DelaySec = 5 }
    # Same "really servicing?" test as the status and install scripts: dism/wusa present, TiWorker actually
    # busy (CPU over 2 s), or the Windows Update agent installing.  An idle TiWorker does not block a reboot.
    # Its own block, so the check can be run on its own - nothing in it can reach shutdown.exe.
    $busyCheck = {
        $found = @(Get-Process -Name dism, wusa -ErrorAction SilentlyContinue | ForEach-Object { $_.ProcessName } | Sort-Object -Unique)
        $ti = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)
        if ($ti.Count -gt 0) {
            $cpu1 = 0.0; foreach ($p in $ti) { try { if ($p.CPU) { $cpu1 += $p.CPU } } catch { } }
            Start-Sleep -Seconds 2
            $cpu2 = 0.0; foreach ($p in @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue)) { try { if ($p.CPU) { $cpu2 += $p.CPU } } catch { } }
            if (($cpu2 - $cpu1) -ge 0.25) { $found += ('TiWorker busy ({0:N1} s CPU in 2 s)' -f ($cpu2 - $cpu1)) }
        }
        try { if ((New-Object -ComObject 'Microsoft.Update.Session').CreateUpdateInstaller().IsBusy) { $found += 'Windows Update agent installing' } } catch { }
        # the toolkit's own install or software task (it checks hashes and signatures and unpacks with expand.exe before DISM
        # starts: none of the processes above runs then) - a reboot now would cut the run in half (R6-05)
        if (@(Get-Process -Name expand -ErrorAction SilentlyContinue).Count -gt 0) { $found += 'expand.exe unpacking an update' }
        try { $tk = @(Get-ScheduledTask -TaskPath '\WinRMToolkit\' -ErrorAction Stop | Where-Object { [string]$_.State -eq 'Running' } | ForEach-Object { $_.TaskName }); if ($tk.Count -gt 0) { $found += ('toolkit task running: ' + ($tk -join ', ')) } } catch { }
        $found
    }
    $busy = @(& $busyCheck)
    if ($busy.Count -gt 0) { throw "servicing still running ($($busy -join ', ')) - NOT rebooting; try again in a few minutes" }
    $comment = "WinRM Toolkit reboot requested by $Operator - change $ChangeText"
    $comment = $comment -replace '"', "'"   # PowerShell 5.1 passes a native argument's quotes unescaped: one would split the comment into extra switches
    if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }   # shutdown.exe takes at most 512 characters
    $null = & shutdown.exe /r /t $DelaySec /d p:2:17 /c $comment 2>&1
    if ($LASTEXITCODE -ne 0) { throw "shutdown.exe returned $LASTEXITCODE" }
    # the server's own change record: Application event 920, and change-log.txt when the (locked-down) staging folder exists
    $line = '{0} | Reboot | restart in {3} s | change {1} | by {2} | scheduled' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $ChangeText, $Operator, $DelaySec
    try { if (-not [System.Diagnostics.EventLog]::SourceExists('OfflinePatcher')) { New-EventLog -LogName Application -Source 'OfflinePatcher' -ErrorAction Stop }; Write-EventLog -LogName Application -Source 'OfflinePatcher' -EventId 920 -EntryType Information -Message ("WinRM Toolkit reboot on {0}: {1}" -f $env:COMPUTERNAME, $line) -ErrorAction Stop } catch { }
    if ($Staging -and (Test-Path -LiteralPath $Staging)) { try { Add-Content -LiteralPath ($Staging.TrimEnd('\') + '\change-log.txt') -Value $line -Encoding UTF8 -ErrorAction Stop } catch { } }
    return "reboot scheduled in $DelaySec s on $env:COMPUTERNAME"
}

function Restart-PatchedServers {
    # Reboots over WinRM.  Separate button, separate confirmations, never automatic.
    # Default set = servers whose FRESH status says "pending reboot" (Windows' flags, or a software install since the last
    # boot that ended with 3010).  Anything else needs a second,
    # explicit Yes.  On the server, a reboot is refused while dism/TiWorker are still running.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $targets = @(Get-UniqueNames $ComputerName)
    $who = Get-OperatorIdentity
    Write-PatchLog "Reboot requested by $who for $($targets -join ', ') - checking status first" 'WHY'
    Get-ServerStatus -ComputerName $targets | Out-Null
    $who = Get-OperatorIdentity   # again: the status check may have asked for other credentials
    $targets = @(Remove-DuplicateServers $targets)
    $pending = @(); $advised = @(); $notPending = @(); $unreachable = @(); $installing = @()
    foreach ($c in $targets) {
        $s = $script:ServerStatus[$c]
        $runFlag = Get-InstallFlag -Server $c   # the fresh status above has recorded every run that finished: what is left is still going
        if ($runFlag -and [string]$runFlag.State -ne 'unknown') { $installing += ('{0}   (run {1}: {2}, started {3})' -f $c, $runFlag.Stamp, (@($runFlag.KBs) -join ', '), $runFlag.Started) }
        elseif (-not $s -or -not $s.Reachable) { $unreachable += $c }
        elseif ($s.PendingReboot -or $s.SoftwareRebootPending) { $pending += $c }
        elseif ($s.RebootAdvised) { $advised += $c }   # non-critical: a product was removed since the last boot
        else { $notPending += $c }
    }
    foreach ($c in $unreachable) { Write-PatchLog "$c - unreachable, not rebooting" 'WARN' }
    # an OS patch run still open on the server (INSTALLING): never rebooted from here - it would cut the install in half (R6-05)
    if ($installing.Count -gt 0) {
        foreach ($i in $installing) { Write-PatchLog "NOT rebooting $i - the install is still running there; reboot when a status check has recorded it" 'WARN' }
        if ($script:Gui['Form'] -and (Test-GuiDialogAllowed 'The reboot note')) { $null = Show-PatcherMessage -Title 'Not rebooted: still installing' -Icon 'Warning' -Text ("These servers are still installing (their rows say INSTALLING) and are left alone:`n`n{0}`n`nPress 'Check status (ticked)' when the install should be done; the reboot can follow once the result is recorded." -f ($installing -join "`n")) }
    }

    $toReboot = @()
    # this computer in a list is named as such: its restart takes the toolkit down with it (no separate question - the
    # same Yes covers it, with a 60 s countdown so the records are written first)
    $named = { param([string]$c) if (Test-ThisComputer -Name $c) { "$c   (this computer: the toolkit closes with the restart, 60 s countdown)" } else { $c } }
    if ($pending.Count -gt 0) {
        $a = Show-PatcherMessage -Title 'Reboot?' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("These servers are PENDING A REBOOT. Reboot them now?`n`n{0}" -f (@($pending | ForEach-Object { & $named $_ }) -join "`n"))
        if ($a -eq 'Yes') { $toReboot += $pending } else { Write-PatchLog "$who answered $a - pending servers not rebooted" 'WARN' }
    }
    if ($advised.Count -gt 0) {
        $list = ($advised | ForEach-Object { '{0}   (removed {1})' -f $_, $script:ServerStatus[$_].RebootAdvisedReasons }) -join "`n"
        $a = Show-PatcherMessage -Title 'Reboot advised (not required)' -Buttons 'YesNo' -Icon 'Question' -Default 'Button2' -Text ("A reboot is ADVISED, not required, for these servers: software was removed since their last boot, and a reboot finishes what an uninstaller leaves for the next start (a service marked for deletion, files in use). Reboot them now?`n`n{0}" -f $list)
        if ($a -eq 'Yes') { $toReboot += $advised } else { Write-PatchLog "$who answered $a - servers with a reboot advised after a removal are left alone" 'INFO' }
    }
    if ($notPending.Count -gt 0) {
        $a = Show-PatcherMessage -Title 'Reboot servers that are NOT pending a reboot?' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("These servers do NOT need a reboot according to their status. Reboot them anyway?`n`n{0}`n`n(Logged-on users will be disconnected.)" -f (@($notPending | ForEach-Object { & $named $_ }) -join "`n"))
        if ($a -eq 'Yes') { $toReboot += $notPending } else { Write-PatchLog "$who answered $a - servers not pending a reboot are left alone" 'INFO' }
    }
    if ($toReboot.Count -eq 0) { Write-PatchLog 'No reboot sent' 'INFO'; return }
    $agentOff = @(Get-TrellixStoppedServers -Servers $toReboot)   # named again after the reboots are sent (the status is cleared then)
    # Trellix Solidcore: the pending operations run at this boot under the "on reboot" mode.  Enforcing = the update
    # is rolled back (poqexec.exe denied), so such servers are named and need their own Yes; unreadable counts the same.
    if ($script:Config.RequireSolidcoreUpdateMode) {
        $enforcing = @($toReboot | Where-Object { (Get-SolidcoreInfo -Status $script:ServerStatus[$_]).State -in 'enforcing', 'unknown' })
        if ($enforcing.Count -gt 0) {
            $list = ($enforcing | ForEach-Object { '{0}   ({1})' -f $_, (Get-SolidcoreText -Status $script:ServerStatus[$_]) }) -join "`n"
            $a = Show-PatcherMessage -Title 'Trellix Solidcore is not in Update Mode' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("Trellix Solidcore on these servers is ENFORCING (or could not be read). At this reboot poqexec.exe applies the pending update and Solidcore denies it: the update is ROLLED BACK and the server boots without it.`n`n{0}`n`nRun the Update Mode task first (check status shows the mode). Reboot them anyway?" -f $list)
            if ($a -ne 'Yes') { $toReboot = @($toReboot | Where-Object { $enforcing -notcontains $_ }); Write-PatchLog ("$who answered $a - not rebooted while Solidcore is enforcing: " + ($enforcing -join ', ')) 'WARN' }
            else { Write-PatchLog ("$who chose to reboot while Solidcore is enforcing (the update may be rolled back): " + ($enforcing -join ', ')) 'WARN' }
            if ($toReboot.Count -eq 0) { Write-PatchLog 'No reboot sent' 'INFO'; return }
        }
    }
    $change = Request-ChangeRecord -Action 'Reboot' -Servers $toReboot -Items 'restart (finishes pending OS patches and software updates)'
    if (-not $change) { return }
    $changeText = Format-ChangeText $change

    # the toolkit PC itself (Test-ThisComputer) goes last, with shutdown.exe run here and a 60 s countdown instead of 10:
    # its restart closes the toolkit with everything on the screen, so the log and the change log are written first; the
    # open run is on record and the next status check, after the toolkit is started again, finishes it (field test 2026-11)
    $selfOnes = @($toReboot | Where-Object { Test-ThisComputer -Name $_ })
    foreach ($c in (@($toReboot | Where-Object { $selfOnes -notcontains $_ }) + @($selfOnes))) {
        $delay = 10; $selfText = ''
        if ($selfOnes -contains $c) { $delay = 60; $selfText = ' (this computer - the toolkit closes with the restart; shutdown /a cancels it)' }
        try {
            $msg = Invoke-ToolkitCommand -ComputerName $c -ScriptBlock $script:RemoteRebootScript -ArgumentList @($who, $changeText, $script:Config.RemoteStaging, $delay) -Explain "RemoteRebootScript: refuse if dism/TiWorker busy, then shutdown.exe /r /t $delay"
            Write-PatchLog "REBOOT $c - $msg$selfText (by $who)" 'OK'
            Write-ChangeLog -Record $change -Server $c -Action 'Reboot' -Result "reboot scheduled in $delay s"
            $script:ServerStatus.Remove($c)   # old status is now meaningless
        } catch {
            $err = Get-ShortError $_
            if ($err -match 'shut down|restart|connection|closed|aborted') { Write-PatchLog "REBOOT $c - the connection dropped while the reboot was being sent; it is probably rebooting: $err" 'WARN'; $script:ServerStatus.Remove($c); Write-ChangeLog -Record $change -Server $c -Action 'Reboot' -Result "probably rebooting (the connection dropped): $err" }
            else { Write-PatchLog "REBOOT $c - refused or failed: $err" 'ERROR'; Write-ChangeLog -Record $change -Server $c -Action 'Reboot' -Result "refused or failed: $err" }
        }
    }
    # the agent services the tool (or someone) disabled stay disabled through the boot: the reminder, per server
    foreach ($c in $agentOff) { if ($toReboot -contains $c) { Write-PatchLog "$c - the Trellix Agent services are Disabled and stay so through the reboot: when it is back, tick it and press 'Start Trellix Agent (ticked)'" 'WARN' } }
}

# ---------------------------------------------------------------------
#  THE TRELLIX AGENT SERVICES.  masvc "Trellix Agent Service" and macmnsvc
#  "Trellix Agent Common Services" - the ePO agent.  Field test, October
#  2026: an OS patch install only completed with both Disabled and
#  stopped; the ePO server kept no log of what the agent did, and the
#  client reports component status only, so the cause stays open (an
#  ATP policy, most likely).  Hence:
#    * the box "Stop the Trellix Agent services first" on the O/S Patching
#      and Software tabs (ticked by default: StopTrellixAgentForInstall)
#      sets both services to Disabled and stops them on each server before
#      an install; a server where that fails is not installed (fail closed
#      - untick the box to install with the agent running)
#    * the status check shows their state (the Trellix Agent column);
#      stopped or disabled = an orange cell, a WARN line and, after a scan
#      from the toolbar, a pop-up: ePO hears nothing from that server
#    * "Start Trellix Agent (ticked)" sets them to Automatic and starts them
#      again after the reboot; "Stop Trellix Agent (ticked)" is the other
#      way by hand.  Both: fresh status, Yes/No naming the servers (No is
#      the default), the change record of 'Trellix Agent services'
#  The tool reads the Solidcore mode and never changes it; these two
#  services are the only part of Trellix it touches.
# ---------------------------------------------------------------------
$script:RemoteTrellixAgentScript = {
    param([string]$Mode, [string]$Operator, [string]$ChangeText = '', [string]$Staging = '')
    # 'stop': StartupType Disabled first (so nothing starts them again, at the boot least of all), then stopped.
    # 'start': Automatic first - on both, so a dependency is startable - then started.  Each service on its own: an
    # error on one is reported and the other is still done.  Returns the state read back ('Name|DisplayName|State|
    # StartMode', the status check's line), the services changed and the errors.
    $present = @()
    foreach ($n in @('masvc', 'macmnsvc')) { if (Get-Service -Name $n -ErrorAction SilentlyContinue) { $present += $n } }
    $found = @($present)   # neither found = no agent here: the operator side skips the server instead of failing it
    $errors = @(); $changed = @()
    $startType = 'Automatic'; if ($Mode -eq 'stop') { $startType = 'Disabled' }
    # Stop-Service -Force also stops every service that depends on these two: the tool changes these two and nothing else,
    # so a running dependent outside the pair stops the whole step before anything is changed (R6-12)
    if ($Mode -eq 'stop') {
        $others = @()
        foreach ($n in $present) { try { foreach ($d in @((Get-Service -Name $n -ErrorAction Stop).DependentServices)) { if ($d.Status -ne 'Stopped' -and $d.Name -notin 'masvc', 'macmnsvc') { $others += ('{0} ({1})' -f $d.Name, $d.DisplayName) } } } catch { } }
        $others = @($others | Select-Object -Unique)
        if ($others.Count -gt 0) { $errors += ('nothing changed: these running services depend on the Trellix Agent and would stop too: {0}' -f ($others -join ', ')); $present = @() }
    }
    foreach ($n in $present) {
        try { Set-Service -Name $n -StartupType $startType -ErrorAction Stop } catch { $errors += ('{0}: start type not set to {1}: {2}' -f $n, $startType, $_.Exception.Message) }
    }
    foreach ($n in $present) {
        try {
            $svc = Get-Service -Name $n -ErrorAction Stop
            if ($Mode -eq 'stop') {
                if ($svc.Status -ne 'Stopped') { Stop-Service -Name $n -Force -ErrorAction Stop; $svc.WaitForStatus('Stopped', [timespan]::FromSeconds(90)) }
            } else {
                if ($svc.Status -ne 'Running') { Start-Service -Name $n -ErrorAction Stop; $svc.WaitForStatus('Running', [timespan]::FromSeconds(90)) }
            }
            $changed += $n
        } catch {
            $m = $_.Exception.Message
            if ($m -match '(?i)denied') { $m += ' (the agent''s self-protection may be on - an ePO policy)' }
            $errors += ('{0}: {1}' -f $n, $m)
        }
    }
    $lines = @()
    try { foreach ($ws in @(Get-CimInstance -ClassName Win32_Service -Filter "Name='masvc' OR Name='macmnsvc'" -ErrorAction Stop)) { $lines += '{0}|{1}|{2}|{3}' -f $ws.Name, $ws.DisplayName, $ws.State, $ws.StartMode } } catch { $errors += ('the state could not be read back: ' + $_.Exception.Message) }
    if ($changed.Count -gt 0) {
        # the server's own change record: Application event 940, and change-log.txt when the (locked-down) staging folder exists
        $what = 'set to Automatic and started'; if ($Mode -eq 'stop') { $what = 'set to Disabled and stopped' }
        $line = '{0} | Trellix Agent services | {1} {2} | change {3} | by {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($changed -join ', '), $what, $ChangeText, $Operator
        try { if (-not [System.Diagnostics.EventLog]::SourceExists('OfflinePatcher')) { New-EventLog -LogName Application -Source 'OfflinePatcher' -ErrorAction Stop }; Write-EventLog -LogName Application -Source 'OfflinePatcher' -EventId 940 -EntryType Information -Message ("WinRM Toolkit Trellix Agent services on {0}: {1}" -f $env:COMPUTERNAME, $line) -ErrorAction Stop } catch { }
        if ($Staging -and (Test-Path -LiteralPath $Staging)) { try { Add-Content -LiteralPath ($Staging.TrimEnd('\') + '\change-log.txt') -Value $line -Encoding UTF8 -ErrorAction Stop } catch { } }
    }
    return [pscustomobject]@{ Computer = $env:COMPUTERNAME; Mode = $Mode; Found = $found; Lines = $lines; Changed = $changed; Errors = $errors }
}

function Test-TrellixStopOn {
    # The "Stop the Trellix Agent services first" box of a console (ticked at start when StopTrellixAgentForInstall is on);
    # without a window, the setting itself.
    param([string]$Console = 'Patching')
    if (-not (Test-TrellixInUse)) { return $false }   # Trellix not used here (Settings tab): the box is hidden and nothing is stopped
    $box = $script:Gui['TrellixStopBox' + $Console]
    if ($box) { return [bool]$box.Checked }
    return [bool]$script:Config.StopTrellixAgentForInstall
}

function Get-TrellixStoppedServers {
    # Of the servers named, those whose last status says the Trellix Agent services are stopped or disabled, in any mix.
    # None while Trellix is not in use (Settings tab): the status check's WARN line, the scan pop-up, the reboot reminder and
    # the install outcome all ask here.
    param([string[]]$Servers)
    if (-not (Test-TrellixInUse)) { return @() }
    return @(@($Servers) | Where-Object { $_ -and (Get-TrellixAgentInfo -Status $script:ServerStatus[$_]).State -in 'stopped', 'mixed' })
}

function Show-TrellixAgentWarning {
    # After a scan from the toolbar (both consoles): the warning when a server's Trellix Agent services are stopped - a
    # pop-up, or a log line while another action runs (Show-GuiNotice).  Get-ServerStatus wrote the WARN line already.
    param([string[]]$Servers)
    $off = @(Get-TrellixStoppedServers -Servers $Servers)
    if ($off.Count -eq 0 -or -not $script:Gui['Form']) { return }
    $list = (@($off | Select-Object -First 25 | ForEach-Object { '{0}   ({1})' -f $_, (Get-TrellixAgentText -Status $script:ServerStatus[$_]) }) -join "`n")
    if ($off.Count -gt 25) { $list += "`n... and {0} more (the Trellix Agent column shows every one)" -f ($off.Count - 25) }
    Show-GuiNotice ("The Trellix Agent services are STOPPED or DISABLED on {0} server(s) - ePO gets no reports from them:`n`n{1}`n`nWhen the patching and the reboot are done, tick them and press 'Start Trellix Agent (ticked)'." -f $off.Count, $list)
}

function Invoke-TrellixAgentChange {
    # The remote call per server with its log and change-log rows: -Mode stop = Disabled + stopped, start = Automatic +
    # running.  A server without the agent (per its last status) or already in that state is skipped with a line each.
    # Returns one result per server: Server, Mode, Success, Skipped, Message, Lines.  The change record is the caller's
    # - the install's (the box) or the button's own (Set-TrellixAgentOnServers).
    param([string[]]$ComputerName, [ValidateSet('start', 'stop')][string]$Mode, $Change = $null, [string]$Action = 'Trellix Agent services')
    $who = Get-OperatorIdentity
    $changeText = Format-ChangeText $Change
    $want = 'running'; $what = 'set to Automatic and started'; if ($Mode -eq 'stop') { $want = 'stopped'; $what = 'set to Disabled and stopped' }
    $item = 'Trellix Agent services (masvc, macmnsvc)'
    $results = @()
    foreach ($c in @(Get-UniqueNames $ComputerName)) {
        $st = $script:ServerStatus[$c]
        $ta = Get-TrellixAgentInfo -Status $st
        if ($st -and $st.Reachable -and -not $ta.Present) { Write-PatchLog "$c - no Trellix Agent services on this server; nothing to $Mode" 'INFO'; $results += [pscustomobject]@{ Server = $c; Mode = $Mode; Success = $true; Skipped = $true; Message = 'no Trellix Agent on the server'; Lines = @() }; continue }
        if ($ta.State -eq $want) { Write-PatchLog "$c - Trellix Agent services already $($ta.Text); nothing to do" 'INFO'; $results += [pscustomobject]@{ Server = $c; Mode = $Mode; Success = $true; Skipped = $true; Message = ('already ' + $ta.Text); Lines = @($st.TrellixAgentLines) }; continue }
        try {
            $r = Invoke-ToolkitCommand -ComputerName $c -ScriptBlock $script:RemoteTrellixAgentScript -ArgumentList @($Mode, $who, $changeText, $script:Config.RemoteStaging) -Explain ("RemoteTrellixAgentScript {0}: masvc + macmnsvc {1}" -f $Mode, $what)
            $lines = @($r.Lines | ForEach-Object { [string]$_ })
            $errs = @($r.Errors | ForEach-Object { [string]$_ })
            # the status could not tell (the services unreadable, or no status yet), and the server finds neither service: no agent
            if ($r.PSObject.Properties['Found'] -and @($r.Found).Count -eq 0 -and $errs.Count -eq 0) {
                Write-PatchLog "$c - no Trellix Agent services on this server (the server says so); nothing to $Mode" 'INFO'
                $results += [pscustomobject]@{ Server = $c; Mode = $Mode; Success = $true; Skipped = $true; Message = 'no Trellix Agent on the server'; Lines = @() }
                continue
            }
            if ($st -and $st.PSObject.Properties['TrellixAgentLines']) { $st.TrellixAgentLines = $lines }   # the row shows the new state at once; the next status check reads it again
            $now = Get-TrellixAgentInfo -Status ([pscustomobject]@{ TrellixAgentLines = $lines })
            if ($errs.Count -eq 0 -and $now.State -eq $want) {
                Write-PatchLog ("TRELLIX AGENT {0} - {1} ({2}) by {3}" -f $c, $what, $now.Text, $who) 'OK'
                Write-ChangeLog -Record $Change -Server $c -Action $Action -Item $item -Result $what
                $results += [pscustomobject]@{ Server = $c; Mode = $Mode; Success = $true; Skipped = $false; Message = $what; Lines = $lines }
            } else {
                $msg = 'the Trellix Agent services could not be ' + $what
                if ($errs.Count -gt 0) { $msg += ': ' + ($errs -join '; ') } else { $msg += ' (the server reads back ' + $now.Text + ')' }
                Write-PatchLog ("TRELLIX AGENT {0} - {1}" -f $c, $msg) 'ERROR'
                Write-ChangeLog -Record $Change -Server $c -Action $Action -Item $item -Result $msg
                $results += [pscustomobject]@{ Server = $c; Mode = $Mode; Success = $false; Skipped = $false; Message = $msg; Lines = $lines }
            }
        } catch {
            $msg = 'the Trellix Agent services could not be ' + $what + ': ' + (Get-ShortError $_)
            Write-PatchLog ("TRELLIX AGENT {0} - {1}" -f $c, $msg) 'ERROR'
            Write-ChangeLog -Record $Change -Server $c -Action $Action -Item $item -Result $msg
            $results += [pscustomobject]@{ Server = $c; Mode = $Mode; Success = $false; Skipped = $false; Message = $msg; Lines = @() }
        }
    }
    return $results
}

function Set-TrellixAgentOnServers {
    # The two buttons (both consoles): fresh status, which servers it applies to, one Yes/No naming them (No is the
    # default), the change record of 'Trellix Agent services' (a change record or a maintenance activity by default), the
    # change itself, a fresh status so the grid tells the truth, then the summary.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName, [ValidateSet('start', 'stop')][string]$Mode)
    $targets = @(Get-UniqueNames $ComputerName)
    $who = Get-OperatorIdentity
    $what = 'set to Automatic and started'; $want = 'running'; if ($Mode -eq 'stop') { $what = 'set to Disabled and stopped'; $want = 'stopped' }
    Write-PatchLog ("=== TRELLIX AGENT {0} REQUESTED by {1} on {2} - checking status first ===" -f $Mode.ToUpper(), $who, ($targets -join ', ')) 'INFO'
    Get-ServerStatus -ComputerName $targets | Out-Null
    $who = Get-OperatorIdentity   # again: the status check may have asked for other credentials
    $targets = @(Remove-DuplicateServers $targets)
    $todo = @(); $skipped = @()
    foreach ($c in $targets) {
        $st = $script:ServerStatus[$c]
        if (-not $st -or -not $st.Reachable) { $skipped += "$c   (unreachable)"; continue }
        $ta = Get-TrellixAgentInfo -Status $st
        if (-not $ta.Present) { $skipped += "$c   (no Trellix Agent on the server)"; continue }
        if ($ta.State -eq $want) { $skipped += "$c   (already $($ta.Text))"; continue }
        # a run still installing keeps the agent off; a run that ended without a result (RUN UNKNOWN) is over as far as the
        # server knows - the reboot allows it, and so does this, or the services could never be started from here
        if ($Mode -eq 'start') { $openRun = Get-InstallFlag -Server $c; if ($openRun -and [string]$openRun.State -ne 'unknown') { $skipped += "$c   (an OS patch run is still open on it - let a status check record it first)"; continue } }
        $todo += $c
    }
    foreach ($s in $skipped) { Write-PatchLog "Trellix Agent ${Mode}: skipped $s" 'WARN' }
    if ($todo.Count -eq 0) { $null = Show-PatcherMessage -Title 'Nothing to do' -Icon 'Information' -Text ("No server to change:`n`n" + ($skipped -join "`n")); return @() }
    $list = ($todo | ForEach-Object { '{0}   ({1})' -f $_, (Get-TrellixAgentText -Status $script:ServerStatus[$_]) }) -join "`n"
    $note = "Start them when the patching and the reboot are done - the field test saw installs fail and roll back with the agent running."
    if ($Mode -eq 'stop') { $note = "Stopped, the agent reports nothing to ePO and takes no new policy until it runs again: start it when the patching and the reboot are done." }
    $more = ''; if ($skipped.Count -gt 0) { $more = "`n`nSkipped:`n" + ($skipped -join "`n") }
    $a = Show-PatcherMessage -Title ('Trellix Agent services: ' + $what + '?') -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("The Trellix Agent services (masvc, macmnsvc) on these servers will be {0}:`n`n{1}{2}`n`n{3}`n`nGo ahead?" -f $what, $list, $more, $note)
    if ($a -ne 'Yes') { Write-PatchLog "$who answered $a - the Trellix Agent services are left as they are" 'WARN'; return @() }
    $change = Request-ChangeRecord -Action 'Trellix Agent services' -Servers $todo -Items ('masvc, macmnsvc ' + $what)
    if (-not $change) { return @() }
    $results = @(Invoke-TrellixAgentChange -ComputerName $todo -Mode $Mode -Change $change)
    Get-ServerStatus -ComputerName $todo | Out-Null
    $good = @($results | Where-Object { $_.Success -and -not $_.Skipped }).Count
    $bad = @($results | Where-Object { -not $_.Success })
    Write-PatchLog ("=== TRELLIX AGENT {0} FINISHED (by {1}): {2} {3}, {4} failed ===" -f $Mode.ToUpper(), $who, $good, $what, $bad.Count) 'INFO'
    if ($script:Gui['Form'] -and (Test-GuiDialogAllowed 'The result')) {
        $text = "Trellix Agent services {0}: {1} server(s)`nFailed: {2}" -f $what, $good, $bad.Count
        if ($bad.Count -gt 0) { $text += "`n`n" + (($bad | ForEach-Object { '{0}: {1}' -f $_.Server, $_.Message }) -join "`n") }
        $popIcon = 'Information'; if ($bad.Count -gt 0) { $popIcon = 'Warning' }
        $null = Show-PatcherMessage -Title 'Trellix Agent services' -Icon $popIcon -Text $text
    }
    return $results
}
