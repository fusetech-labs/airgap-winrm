# =====================================================================
#  48-Directory.ps1  -  DOMAIN CONTROLLERS AND THE DOMAIN: HEALTH AND SECURITY
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The Directory collector runs on a domain controller only, with every Health check, every Security audit and the
#  self-check (so a domain controller that refuses WinRM is read by its own local copy, into the same results file).
#  Read-only, and with what every domain controller has: ADSI (LDAP, to the directory on the computer it runs on),
#  the registry, WMI and dcdiag.exe.  No PowerShell module is loaded - not the ActiveDirectory one, not any other.
#    on every domain controller   its dcdiag tests, its inbound replication (as the directory itself records it),
#                                 SYSVOL and NETLOGON, the directory's services, the five operations master roles
#                                 as this server sees them, LDAP signing, certificate mapping, the Print Spooler
#    once per domain              on the domain controller that holds the PDC emulator role: the accounts, groups,
#                                 delegation, trusts, permissions and Group Policy Preferences of the domain
#    once per forest              on the PDC emulator of the forest root domain: the Recycle Bin, the certificate
#                                 templates the certification authorities publish
#  Every read reaches the directory of the server it runs on - never another domain controller - so a WinRM session
#  needs no second hop.  dcdiag alone talks to the operations masters; over WinRM a test of that kind can fail for
#  that reason, and the check says so.
#  The checks: H-AD-01..10 (Health), SEC-ADC-01..04 (the domain controller) and SEC-AD-01..33 (the domain), each
#  Security check with its ISM control.  A read that failed is Amber with the reason, never a pass.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  48-Directory.ps1
#  New 2026-11-18 (owner's ask: a domain controller and domain health and security check without the Active
#  Directory module, working from the local copy on a domain controller that refuses WinRM).  The account sweeps
#  read every user and computer object of the domain once: on a large domain they take time, and a security
#  monitor may report them as directory enumeration - they come from the domain controller itself.
#  Field test needed: a domain controller over WinRM and from its local copy, a read-only domain controller, a
#  forest with a certification authority, a server in another language (dcdiag's text is translated).
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ______cf________________________   Date : ___19-11-2026________
#  Verdict    : [ ] Approved   [x] Approved with comments   [ ] Changes required
#  Comments   :    checked the max objects limit doesnt prevent a complete directory read where objects exceed the max
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  DIRECTORY collector - RUNS ON THE DOMAIN CONTROLLER.  "AD.Key=Value" lines, like the Settings collector's (the
#  checks read them from the same table).  A list travels as AD.<Key> (the first -ListMax names, ; between them)
#  with AD.<Key>.Count beside it; a read that failed as AD.<Key>=ERROR: <reason>.  Each read is a step of its own:
#  one that fails, or that the time budget no longer allows, costs only itself.
# ---------------------------------------------------------------------
$script:RemoteDirectoryScript = {
    param([int]$MaxObjects = 20000, [int]$ListMax = 40, [int]$DcdiagSec = 150, [int]$BudgetSec = 240, [int]$InactiveDays = 45, [int]$ComputerPasswordDays = 30)
    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $now = (Get-Date).ToUniversalTime()
    $ctx = @{ Cut = $false; IsPdc = $false; IsRoot = $false; DomainSid = ''; SpnUsers = @{} }
    $ldap = 'LDAP://localhost/'
    function Add-S([string]$k, $v) { if ($null -eq $v) { $v = '' }; if ($v -is [array]) { $v = ($v -join ';') }; $lines.Add(('AD.{0}={1}' -f $k, (([string]$v) -replace '[\r\n]+', ' '))) }
    function Add-List([string]$k, $names, [bool]$cut = $false) {
        $all = @($names | Where-Object { "$_" -ne '' })
        Add-S ($k + '.Count') $all.Count
        if ($cut) { Add-S ($k + '.Cut') 'True' }
        Add-S $k ((@($all | Select-Object -First $ListMax | ForEach-Object { ([string]$_) -replace '[;=]', '_' }) -join ';'))
    }
    function Get-RV([string]$path, [string]$name) { try { return (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { return $null } }
    function Get-Why($e) { $x = $e.Exception; while ($x.InnerException) { $x = $x.InnerException }; return (([string]$x.Message) -replace '\s+', ' ').Trim() }
    function Invoke-Step([string]$key, [scriptblock]$body) {
        if ($watch.Elapsed.TotalSeconds -gt $BudgetSec) { Add-S $key ('ERROR: not read - the time this collector allows itself ({0} s) was used up before this read' -f $BudgetSec); return }
        try { & $body } catch { Add-S $key ('ERROR: ' + (Get-Why $_)) }
    }
    function Get-Entry([string]$dn) { return (New-Object System.DirectoryServices.DirectoryEntry ($ldap + ($dn -replace '/', '\/'))) }
    function Find-Dir([string]$base, [string]$filter, [string[]]$props, [string]$scope = 'Subtree', [bool]$dacl = $false) {
        # one paged search of the directory on this server; at most -MaxObjects rows ($ctx.Cut says the limit was reached)
        $entry = Get-Entry $base
        $s = New-Object System.DirectoryServices.DirectorySearcher $entry
        $s.Filter = $filter; $s.SearchScope = $scope; $s.PageSize = 500; $s.CacheResults = $false
        foreach ($p in $props) { [void]$s.PropertiesToLoad.Add($p) }
        if ($dacl) { $s.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl }
        $rows = New-Object System.Collections.ArrayList
        $found = $s.FindAll()
        try { foreach ($r in $found) { if ($rows.Count -ge $MaxObjects) { $ctx.Cut = $true; break }; [void]$rows.Add($r.Properties) } } finally { $found.Dispose(); $s.Dispose(); $entry.Dispose() }
        return $rows
    }
    function Get-V($p, [string]$name) { if ($p -and $p.Contains($name) -and $p[$name].Count -gt 0) { return $p[$name][0] }; return $null }
    function Get-Days($fileTime) { if ($null -eq $fileTime) { return $null }; $t = [int64]$fileTime; if ($t -le 0) { return $null }; return [int][math]::Floor(($now - [datetime]::FromFileTimeUtc($t)).TotalDays) }
    function ConvertTo-SidText($bytes) { return (New-Object System.Security.Principal.SecurityIdentifier ([byte[]]$bytes), 0).Value }
    function ConvertTo-SidFilter([string]$sid) { $x = New-Object System.Security.Principal.SecurityIdentifier $sid; $b = New-Object byte[] $x.BinaryLength; $x.GetBinaryForm($b, 0); return (($b | ForEach-Object { '\' + $_.ToString('x2') }) -join '') }
    function ConvertTo-FilterDn([string]$dn) { return $dn.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29') }
    function Get-Sam($rows) { return @($rows | ForEach-Object { [string](Get-V $_ 'samaccountname') } | Where-Object { $_ } | Sort-Object) }
    function Get-Rid($p) { $b = Get-V $p 'objectsid'; if ($null -eq $b) { return '' }; return ((ConvertTo-SidText $b) -split '-')[-1] }
    # nearly everybody, by identifier (a name is translated on a server in another language): Everyone, Authenticated Users,
    # Anonymous, INTERACTIVE, NETWORK, BUILTIN\Users and Guests, a domain's Domain Users, Guests and Computers.  The same
    # list as in the Settings and Roles collectors and in Test-BroadPrincipalSid (10-Checks.ps1): one principal is broad
    # for every check or for none
    function Test-BroadSid([string]$sid) { return (@('S-1-1-0', 'S-1-5-11', 'S-1-5-7', 'S-1-5-4', 'S-1-5-2', 'S-1-5-32-545', 'S-1-5-32-546') -contains $sid -or $sid -match '^S-1-5-21-.+-(513|514|515)$') }
    function Get-Security($p) { $sd = New-Object System.DirectoryServices.ActiveDirectorySecurity; $sd.SetSecurityDescriptorBinaryForm([byte[]](Get-V $p 'ntsecuritydescriptor')); return @($sd.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | Where-Object { [string]$_.AccessControlType -eq 'Allow' }) }
    $done = { [pscustomobject]@{ Computer = $env:COMPUTERNAME; Lines = $lines.ToArray(); Count = $lines.Count } }

    # ---- a domain controller?  The directory answers on this computer, or there is nothing to read ----
    $role = -1; try { $role = [int]([wmi]("Win32_ComputerSystem.Name='{0}'" -f $env:COMPUTERNAME)).DomainRole } catch { }
    if ($role -ge 0 -and $role -lt 4) { Add-S 'Read' 'NotDomainController'; return (& $done) }
    $rootDse = $null; $dcHost = ''; $domainDn = ''; $configDn = ''; $schemaDn = ''; $rootDn = ''; $domainDns = ''
    try {
        $rootDse = New-Object System.DirectoryServices.DirectoryEntry ($ldap + 'RootDSE')
        $dcHost = [string]$rootDse.Properties['dnsHostName'].Value
        $domainDn = [string]$rootDse.Properties['defaultNamingContext'].Value
        $configDn = [string]$rootDse.Properties['configurationNamingContext'].Value
        $schemaDn = [string]$rootDse.Properties['schemaNamingContext'].Value
        $rootDn = [string]$rootDse.Properties['rootDomainNamingContext'].Value
        if (-not $domainDn) { throw 'the directory did not answer on this computer (LDAP, localhost)' }
        if ($dcHost) { $ldap = 'LDAP://' + $dcHost + '/' }
        $domainDns = (@($domainDn -split ',' | ForEach-Object { $_ -replace '^DC=', '' }) -join '.')
        $ctx.IsRoot = ($domainDn -ieq $rootDn)
        Add-S 'Read' 'OK'
        Add-S 'Dc' $dcHost; Add-S 'Domain' $domainDns; Add-S 'IsRootDomain' $ctx.IsRoot
        Add-S 'ForestRoot' (@($rootDn -split ',' | ForEach-Object { $_ -replace '^DC=', '' }) -join '.')
        Add-S 'Level.Domain' $rootDse.Properties['domainFunctionality'].Value
        Add-S 'Level.Forest' $rootDse.Properties['forestFunctionality'].Value
        Add-S 'Level.Dc' $rootDse.Properties['domainControllerFunctionality'].Value
        Add-S 'IsGc' $rootDse.Properties['isGlobalCatalogReady'].Value
        $siteMatch = [regex]::Match([string]$rootDse.Properties['serverName'].Value, ',CN=Servers,CN=([^,]+),CN=Sites,')
        if ($siteMatch.Success) { Add-S 'Site' $siteMatch.Groups[1].Value }
        # how this script was started: a WinRM session is a network logon (dcdiag's reach to other servers depends on it)
        $session = 'local'; try { if (@([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups | Where-Object { $_.Value -eq 'S-1-5-2' }).Count -gt 0) { $session = 'network' } } catch { }
        Add-S 'Session' $session
        Add-S 'InactiveDays' $InactiveDays; Add-S 'ComputerPasswordDays' $ComputerPasswordDays
    } catch { Add-S 'Read' ('ERROR: ' + (Get-Why $_)); return (& $done) }

    # ---- the operations master roles, as this server knows them ----
    Invoke-Step 'Fsmo' {
        $holders = @(); $pdc = ''
        foreach ($pair in @(@('PDC emulator', $domainDn), @('RID master', ('CN=RID Manager$,CN=System,' + $domainDn)), @('Infrastructure master', ('CN=Infrastructure,' + $domainDn)), @('Schema master', $schemaDn), @('Domain naming master', ('CN=Partitions,' + $configDn)))) {
            $owner = [string](Get-Entry $pair[1]).Properties['fSMORoleOwner'].Value
            $name = ''
            if (-not $owner) { $name = 'NONE' }
            elseif ($owner -match '0ADEL:') { $name = 'DELETED' }   # the holder was removed from the directory: the role waits to be seized
            else { try { $name = [string](Get-Entry ($owner.Substring($owner.IndexOf(',') + 1))).Properties['dNSHostName'].Value } catch { }; if (-not $name) { $name = 'UNKNOWN' } }
            $holders += ($pair[0] + '|' + $name)
            if ($pair[0] -eq 'PDC emulator') { $pdc = $name }
        }
        $ctx.IsPdc = [bool]($pdc -and $dcHost -and $pdc -ieq $dcHost)
        Add-S 'Fsmo' ($holders -join ';'); Add-S 'Pdc' $pdc; Add-S 'IsPdc' $ctx.IsPdc
    }
    Invoke-Step 'DcList' {
        # a domain controller's account carries 8192 (SERVER_TRUST_ACCOUNT); a read-only one carries 67108864 (PARTIAL_SECRETS_ACCOUNT) instead
        $rows = @(Find-Dir $domainDn '(&(objectCategory=computer)(|(userAccountControl:1.2.840.113556.1.4.803:=8192)(userAccountControl:1.2.840.113556.1.4.803:=67108864)))' @('dnshostname', 'operatingsystem', 'primarygroupid'))
        Add-List 'DcList' @($rows | ForEach-Object { '{0}|{1}{2}' -f (Get-V $_ 'dnshostname'), (Get-V $_ 'operatingsystem'), $(if ([string](Get-V $_ 'primarygroupid') -eq '521') { ' (read-only)' } else { '' }) } | Sort-Object)
    }

    # ---- this server: the settings, services and shares a domain controller stands on ----
    Invoke-Step 'Local' {
        $np = 'HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters'
        Add-S 'LdapSigning' (Get-RV $np 'LDAPServerIntegrity')              # 2 = signing required
        Add-S 'LdapChannelBinding' (Get-RV $np 'LdapEnforceChannelBinding')   # 2 = always
        Add-S 'CertMapping' (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Services\Kdc' 'StrongCertificateBindingEnforcement')
        Add-S 'SysvolReady' (Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' 'SysvolReady')
        $db = [string](Get-RV $np 'DSA Database file')
        if ($db -and (Test-Path -LiteralPath $db)) {
            $drive = New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($db))
            Add-S 'Database' ('{0}|{1}|{2}' -f $db, [math]::Round((Get-Item -LiteralPath $db).Length / 1GB, 2), [math]::Round($drive.AvailableFreeSpace / 1GB, 1))
        }
        $tomb = [string](Get-Entry ('CN=Directory Service,CN=Windows NT,CN=Services,' + $configDn)).Properties['tombstoneLifetime'].Value
        if (-not $tomb) { $tomb = '60' }   # not set: the directory's own default
        Add-S 'TombstoneDays' $tomb
        Add-S 'Local' 'OK'
    }
    Invoke-Step 'Services' {
        $q = "SELECT Name,State,StartMode FROM Win32_Service WHERE Name='NTDS' OR Name='Netlogon' OR Name='Kdc' OR Name='DNS' OR Name='DFSR' OR Name='NtFrs' OR Name='W32Time' OR Name='ADWS' OR Name='IsmServ' OR Name='Spooler'"
        Add-S 'Services' ((@(([wmisearcher]$q).Get() | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.State, $_.StartMode } | Sort-Object)) -join ';')
    }
    Invoke-Step 'Shares' {
        Add-S 'Shares' ((@(([wmisearcher]"SELECT Name FROM Win32_Share WHERE Name='SYSVOL' OR Name='NETLOGON'").Get() | ForEach-Object { ([string]$_.Name).ToUpper() } | Sort-Object)) -join ';')
        # SYSVOL under DFS Replication: 4 = normal, 5 = in error, 2 = the first synchronisation; nothing = not under DFSR (FRS)
        $state = ''
        try { $f = New-Object System.Management.ManagementObjectSearcher 'root\MicrosoftDFS', "SELECT State FROM DfsrReplicatedFolderInfo WHERE ReplicatedFolderName='SYSVOL Share'"; foreach ($o in $f.Get()) { $state = [string]$o.State } } catch { }
        Add-S 'Sysvol.DfsrState' $state
    }

    # ---- inbound replication, as the directory records it for each partition this server holds ----
    Invoke-Step 'Repl' {
        $rows = @()
        foreach ($nc in @($rootDse.Properties['namingContexts'])) {
            $e = Get-Entry ([string]$nc)
            $e.RefreshCache(@('msDS-NCReplInboundNeighbors'))
            foreach ($x in @($e.Properties['msDS-NCReplInboundNeighbors'])) {
                $t = [string]$x
                $src = [regex]::Match($t, '<pszSourceDsaDN>(.*?)</pszSourceDsaDN>').Groups[1].Value
                $partner = $src; $m = [regex]::Match($src, '^CN=NTDS Settings[^,]*,CN=([^,]+),'); if ($m.Success) { $partner = $m.Groups[1].Value }
                if ($src -match '0ADEL:') { $partner = ($partner -replace '\\0ADEL:.*$', '') + ' (removed from the directory)' }
                $hours = 'never'; $when = [datetime]::MinValue
                $stamp = [regex]::Match($t, '<ftimeLastSyncSuccess>(.*?)</').Groups[1].Value
                if ([datetime]::TryParse($stamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$when) -and $when.Year -gt 1970) { $hours = [int][math]::Floor(($now - $when).TotalHours) }
                $rows += ('{0}|{1}|{2}|{3}|{4}' -f $partner, ((([string]$nc -split ',')[0]) -replace '^(DC|CN)=', ''), [regex]::Match($t, '<cNumConsecutiveSyncFailures>(\d+)<').Groups[1].Value, $hours, [regex]::Match($t, '<dwLastSyncResult>(\d+)<').Groups[1].Value)
            }
        }
        # the failing and the oldest first: the list is cut at -ListMax
        Add-List 'Repl' @($rows | Sort-Object @{ Expression = { [int](($_ -split '\|')[2]) }; Descending = $true }, @{ Expression = { $h = ($_ -split '\|')[3]; if ($h -eq 'never') { 999999 } else { [int]$h } }; Descending = $true })
    }

    # ---- dcdiag: the directory's own tests of this server (the System event log test left out: every error of the hour) ----
    Invoke-Step 'Dcdiag.Read' {
        $exe = Join-Path $env:SystemRoot 'System32\dcdiag.exe'
        if (-not (Test-Path -LiteralPath $exe)) { throw 'dcdiag.exe is not on this computer' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe; $psi.Arguments = '/skip:SystemLog'; $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync(); $errTask = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($DcdiagSec * 1000)) { try { $p.Kill() } catch { }; throw ('dcdiag did not finish within {0} s and was stopped' -f $DcdiagSec) }
        $p.WaitForExit()
        $text = [string]$outTask.Result; $null = $errTask.Result
        $found = [regex]::Matches($text, '\.{5,}\s+(\S+)\s+(passed|failed)\s+test\s+(\S+)')
        if ($found.Count -eq 0) { throw 'dcdiag ran, but its answer was not understood (on a server in another language its text is translated)' }
        $rows = @(); $failed = @()
        foreach ($m in $found) {
            $test = $m.Groups[3].Value
            $rows += ('{0}|{1}|{2}' -f $test, $m.Groups[2].Value, $m.Groups[1].Value)
            if ($m.Groups[2].Value -eq 'failed') {
                # what dcdiag printed for the test: from its "Starting test" line to its verdict
                $detail = ''; $from = $text.LastIndexOf(('Starting test: ' + $test), $m.Index)
                if ($from -ge 0) { $detail = (($text.Substring($from, $m.Index - $from) -replace '^Starting test: \S+', '') -replace '\s+', ' ').Trim() }
                if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + ' ...' }
                $failed += ('{0} ({1}): {2}' -f $test, $m.Groups[1].Value, $detail)
            }
        }
        Add-S 'Dcdiag' ($rows -join ';'); Add-List 'Dcdiag.Failed' $failed; Add-S 'Dcdiag.Read' 'OK'
    }

    # ---- once per domain: on the domain controller that holds the PDC emulator role ----
    if ($ctx.IsPdc) {
        $U = '(objectCategory=person)(objectClass=user)'
        $enabledOnly = '(!(userAccountControl:1.2.840.113556.1.4.803:=2))'
        $flag = { param($bit) ('(userAccountControl:1.2.840.113556.1.4.803:={0})' -f $bit) }
        $addFound = { param([string]$key, [string]$filter) $ctx.Cut = $false; $rows = @(Find-Dir $domainDn $filter @('samaccountname')); Add-List $key (Get-Sam $rows) $ctx.Cut }

        Invoke-Step 'Policy' {
            $h = @(Find-Dir $domainDn '(objectClass=*)' @('minpwdlength', 'maxpwdage', 'pwdproperties', 'pwdhistorylength', 'lockoutthreshold', 'ms-ds-machineaccountquota', 'objectsid') 'Base')[0]
            $ctx.DomainSid = ConvertTo-SidText (Get-V $h 'objectsid')
            $props = [int](Get-V $h 'pwdproperties')
            $maxAge = [int64](Get-V $h 'maxpwdage'); $maxDays = 0; if ($maxAge -lt 0 -and $maxAge -gt [int64]::MinValue) { $maxDays = [int][math]::Round([math]::Abs($maxAge) / 864000000000) }
            Add-S 'Policy' ('MinLength|{0};MaxAgeDays|{1};History|{2};LockoutThreshold|{3};Complexity|{4}' -f (Get-V $h 'minpwdlength'), $maxDays, (Get-V $h 'pwdhistorylength'), (Get-V $h 'lockoutthreshold'), [bool]($props -band 1))
            Add-S 'ReversiblePolicy' ([bool]($props -band 16))
            Add-S 'MachineAccountQuota' ([string](Get-V $h 'ms-ds-machineaccountquota'))
        }
        Invoke-Step 'Backup.Days' {
            # the stamp a backup leaves on the partition (what repadmin /showbackup reads)
            $e = Get-Entry $domainDn
            $e.RefreshCache(@('msDS-ReplAttributeMetaData'))
            $stamp = ''
            foreach ($x in @($e.Properties['msDS-ReplAttributeMetaData'])) { $t = [string]$x; if ($t -match '<pszAttributeName>dSASignature</pszAttributeName>') { $stamp = [regex]::Match($t, '<ftimeLastOriginatingChange>(.*?)</').Groups[1].Value } }
            $when = [datetime]::MinValue; $days = 'never'
            if ($stamp -and [datetime]::TryParse($stamp, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$when) -and $when.Year -gt 1970) { $days = [int][math]::Floor(($now - $when).TotalDays) }
            Add-S 'Backup.Days' $days
        }
        Invoke-Step 'Rid' {
            $r = @(Find-Dir ('CN=RID Manager$,CN=System,' + $domainDn) '(objectClass=*)' @('ridavailablepool') 'Base')[0]
            $v = [int64](Get-V $r 'ridavailablepool')
            Add-S 'Rid' ('{0}|{1}' -f ($v -shr 32), ($v -band 0xFFFFFFFFL))
        }
        Invoke-Step 'NoPreAuth' { & $addFound 'NoPreAuth' ('(&' + $U + $enabledOnly + (& $flag 4194304) + ')') }
        Invoke-Step 'Reversible' { & $addFound 'Reversible' ('(&' + $U + (& $flag 128) + ')') }
        Invoke-Step 'NoPassword' { & $addFound 'NoPassword' ('(&' + $U + $enabledOnly + (& $flag 32) + ')') }
        Invoke-Step 'UserPassword' { & $addFound 'UserPassword' ('(&' + $U + '(|(userPassword=*)(unixUserPassword=*)))') }
        Invoke-Step 'PasswordText' { & $addFound 'PasswordText' ('(&' + $U + '(|(description=*pass*)(description=*pwd*)(info=*pass*)(info=*pwd*)(comment=*pass*)(comment=*pwd*)))') }
        Invoke-Step 'SidHistory' { & $addFound 'SidHistory' ('(&' + $U + '(sIDHistory=*))') }
        Invoke-Step 'SpnUsers' {
            $ctx.Cut = $false
            $rows = @(Find-Dir $domainDn ('(&' + $U + $enabledOnly + '(servicePrincipalName=*)(!(sAMAccountName=krbtgt)))') @('samaccountname', 'msds-supportedencryptiontypes'))
            foreach ($r in $rows) { $ctx.SpnUsers[([string](Get-V $r 'samaccountname')).ToLower()] = $true }
            Add-List 'SpnUsers' (Get-Sam $rows) $ctx.Cut
            # 0x08 and 0x10 = AES128 and AES256; an account without them gets tickets encrypted with RC4
            Add-List 'SpnNoAes' (Get-Sam @($rows | Where-Object { (([int64](Get-V $_ 'msds-supportedencryptiontypes')) -band 0x18) -eq 0 })) $ctx.Cut
        }
        Invoke-Step 'DuplicateSpn' {
            $ctx.Cut = $false
            $owner = @{}; $dup = @{}
            foreach ($r in @(Find-Dir $domainDn '(servicePrincipalName=*)' @('samaccountname', 'serviceprincipalname'))) {
                $who = [string](Get-V $r 'samaccountname')
                foreach ($spn in @($r['serviceprincipalname'])) {
                    $k = ([string]$spn).ToLower()
                    if ($owner.ContainsKey($k)) { if ($owner[$k] -ne $who) { if (-not $dup.ContainsKey($k)) { $dup[$k] = @($owner[$k]) }; if ($dup[$k] -notcontains $who) { $dup[$k] += $who } } } else { $owner[$k] = $who }
                }
            }
            Add-List 'DuplicateSpn' @($dup.Keys | Sort-Object | ForEach-Object { '{0} ({1})' -f $_, ($dup[$_] -join ', ') }) $ctx.Cut
        }
        Invoke-Step 'UserDelegation' {
            $ctx.Cut = $false
            $rows = @(Find-Dir $domainDn ('(&' + $U + $enabledOnly + (& $flag 524288) + ')') @('samaccountname', 'serviceprincipalname'))
            Add-List 'UserDelegation' (Get-Sam $rows) $ctx.Cut
            Add-List 'UserDelegationNoSpn' (Get-Sam @($rows | Where-Object { -not $_.Contains('serviceprincipalname') })) $ctx.Cut
        }
        # besides the domain controllers, the read-only ones too: Windows itself marks a read-only domain controller as trusted to delegate
        $notDc = '(!' + (& $flag 8192) + ')(!' + (& $flag 67108864) + ')'
        Invoke-Step 'ComputerDelegation' { & $addFound 'ComputerDelegation' ('(&(objectCategory=computer)' + (& $flag 524288) + $notDc + ')') }
        Invoke-Step 'ComputerDelegationToServices' { & $addFound 'ComputerDelegationToServices' ('(&(objectCategory=computer)' + $notDc + '(|(msDS-AllowedToDelegateTo=*)' + (& $flag 16777216) + '))') }
        Invoke-Step 'InactiveUsers' {
            $ctx.Cut = $false
            $cutoff = $now.AddDays(-$InactiveDays)
            $rows = @(Find-Dir $domainDn ('(&' + $U + $enabledOnly + '(|(lastLogonTimestamp<=' + $cutoff.ToFileTimeUtc() + ')(!(lastLogonTimestamp=*))))') @('samaccountname', 'lastlogontimestamp', 'whencreated', 'objectsid'))
            $out = @()
            foreach ($r in $rows) {
                if ((Get-Rid $r) -eq '500') { continue }   # the built-in Administrator has a check of its own
                $d = Get-Days (Get-V $r 'lastlogontimestamp')
                if ($null -ne $d) { $out += [pscustomobject]@{ Days = [int]$d; Text = ('{0} ({1} days)' -f (Get-V $r 'samaccountname'), $d) } }
                else { $made = Get-V $r 'whencreated'; if ($made -is [datetime] -and $made.ToUniversalTime() -lt $cutoff) { $out += [pscustomobject]@{ Days = 99999; Text = ('{0} (never logged on)' -f (Get-V $r 'samaccountname')) } } }
            }
            Add-List 'InactiveUsers' @($out | Sort-Object Days -Descending | ForEach-Object { $_.Text }) $ctx.Cut
        }
        Invoke-Step 'DisabledInGroups' {
            $ctx.Cut = $false
            # Guest, krbtgt and DefaultAccount are disabled and in a group as Windows makes them
            $rows = @(Find-Dir $domainDn ('(&' + $U + (& $flag 2) + '(memberOf=*))') @('samaccountname', 'objectsid') | Where-Object { @('501', '502', '503') -notcontains (Get-Rid $_) })
            Add-List 'DisabledInGroups' (Get-Sam $rows) $ctx.Cut
        }
        Invoke-Step 'StaleComputers' {
            $ctx.Cut = $false
            $rows = @(Find-Dir $domainDn ('(&(objectCategory=computer)' + $enabledOnly + '(pwdLastSet<=' + $now.AddDays(-$ComputerPasswordDays).ToFileTimeUtc() + '))') @('samaccountname', 'pwdlastset'))
            Add-List 'StaleComputers' @($rows | ForEach-Object { $d = Get-Days (Get-V $_ 'pwdlastset'); [pscustomobject]@{ Days = $(if ($null -eq $d) { 99999 } else { [int]$d }); Text = ('{0} ({1})' -f (Get-V $_ 'samaccountname'), $(if ($null -eq $d) { 'never changed' } else { "$d days" })) } } | Sort-Object Days -Descending | ForEach-Object { $_.Text }) $ctx.Cut
        }
        Invoke-Step 'Krbtgt.PasswordDays' {
            $k = @(Find-Dir $domainDn '(&(objectCategory=person)(sAMAccountName=krbtgt))' @('pwdlastset'))[0]
            Add-S 'Krbtgt.PasswordDays' (Get-Days (Get-V $k 'pwdlastset'))
        }
        Invoke-Step 'Admin500' {
            if (-not $ctx.DomainSid) { throw 'the identifier of the domain was not read' }
            $a = @(Find-Dir $domainDn ('(objectSid=' + (ConvertTo-SidFilter ($ctx.DomainSid + '-500')) + ')') @('samaccountname', 'pwdlastset', 'lastlogontimestamp', 'useraccountcontrol'))[0]
            Add-S 'Admin500' ('{0}|{1}|{2}|{3}' -f (Get-V $a 'samaccountname'), [int](-not (([int64](Get-V $a 'useraccountcontrol')) -band 2)), (Get-Days (Get-V $a 'pwdlastset')), (Get-Days (Get-V $a 'lastlogontimestamp')))
        }
        Invoke-Step 'Trusts' {
            Add-List 'Trusts' @(Find-Dir ('CN=System,' + $domainDn) '(objectClass=trustedDomain)' @('name', 'trustdirection', 'trusttype', 'trustattributes') | ForEach-Object { '{0}|{1}|{2}|{3}' -f (Get-V $_ 'name'), (Get-V $_ 'trustdirection'), (Get-V $_ 'trusttype'), (Get-V $_ 'trustattributes') } | Sort-Object)
        }
        Invoke-Step 'PreWin2000' {
            $g = @(Find-Dir $domainDn ('(objectSid=' + (ConvertTo-SidFilter 'S-1-5-32-554') + ')') @('member'))[0]
            $wellKnown = @{ 'S-1-5-11' = 'Authenticated Users'; 'S-1-1-0' = 'Everyone'; 'S-1-5-7' = 'Anonymous Logon' }
            $rows = @()
            foreach ($dn in @($g['member'] | Where-Object { $_ })) {
                $name = (([string]$dn -split ',')[0]) -replace '^CN=', ''; $kind = 'other domain'
                try {
                    $o = @(Find-Dir ([string]$dn) '(objectClass=*)' @('samaccountname', 'objectclass', 'objectsid') 'Base')[0]
                    $classes = @($o['objectclass'] | ForEach-Object { [string]$_ })
                    if ($classes -contains 'foreignSecurityPrincipal') { $sid = ConvertTo-SidText (Get-V $o 'objectsid'); $kind = 'well-known'; if ($wellKnown.ContainsKey($sid)) { $name = $wellKnown[$sid] } else { $name = $sid; $kind = 'other domain' } }
                    elseif ($classes -contains 'computer') { $kind = 'computer'; $name = [string](Get-V $o 'samaccountname') }
                    elseif ($classes -contains 'user') { $kind = 'user'; $name = [string](Get-V $o 'samaccountname') }
                    elseif ($classes -contains 'group') { $kind = 'group'; $name = [string](Get-V $o 'samaccountname') }
                } catch { }
                $rows += ($name + '|' + $kind)
            }
            Add-List 'PreWin2000' $rows
        }
        Invoke-Step 'Priv' {
            if (-not $ctx.DomainSid) { throw 'the identifier of the domain was not read' }
            $d = $ctx.DomainSid
            # 'high' = the groups that own the domain; 'priv' = the ones a step away from it
            $groups = @(@(($d + '-512'), 'high'), @('S-1-5-32-544', 'high'), @('S-1-5-32-548', 'priv'), @('S-1-5-32-549', 'priv'), @('S-1-5-32-551', 'priv'), @('S-1-5-32-550', 'priv'), @(($d + '-520'), 'priv'), @(($d + '-526'), 'priv'))
            if ($ctx.IsRoot) { $groups += , @(($d + '-519'), 'high'); $groups += , @(($d + '-518'), 'high'); $groups += , @(($d + '-527'), 'priv') }
            $found = @()
            foreach ($g in $groups) { $hit = @(Find-Dir $domainDn ('(objectSid=' + (ConvertTo-SidFilter $g[0]) + ')') @('distinguishedname', 'samaccountname', 'member')); if ($hit.Count -gt 0) { $found += , @($hit[0], $g[1]) } }
            foreach ($hit in @(Find-Dir $domainDn '(&(objectCategory=group)(sAMAccountName=DnsAdmins))' @('distinguishedname', 'samaccountname', 'member'))) { $found += , @($hit, 'priv') }
            # who is in Protected Users (members of members too)
            $protected = @{}
            $pu = @(Find-Dir $domainDn ('(objectSid=' + (ConvertTo-SidFilter ($d + '-525')) + ')') @('distinguishedname'))
            if ($pu.Count -gt 0) { foreach ($m in @(Find-Dir $domainDn ('(&(objectCategory=person)(memberOf:1.2.840.113556.1.4.1941:=' + (ConvertTo-FilterDn ([string](Get-V $pu[0] 'distinguishedname'))) + '))') @('samaccountname'))) { $protected[([string](Get-V $m 'samaccountname')).ToLower()] = $true } }
            Add-S 'ProtectedUsersGroup' ($pu.Count -gt 0)
            $computersSid = ConvertTo-SidFilter ($d + '-515')
            $acct = @{}; $counts = @(); $foreign = @(); $computersIn = @()
            foreach ($pair in $found) {
                $grp = $pair[0]; $gname = [string](Get-V $grp 'samaccountname'); $gdn = ConvertTo-FilterDn ([string](Get-V $grp 'distinguishedname'))
                $members = @(Find-Dir $domainDn ('(&(|(objectCategory=person)(objectCategory=computer)(objectClass=msDS-GroupManagedServiceAccount)(objectClass=msDS-ManagedServiceAccount))(memberOf:1.2.840.113556.1.4.1941:=' + $gdn + '))') @('samaccountname', 'objectclass', 'useraccountcontrol', 'serviceprincipalname', 'lastlogontimestamp', 'pwdlastset', 'objectsid'))
                $counts += ('{0}|{1}|{2}' -f $gname, $pair[1], $members.Count)
                foreach ($m in $members) {
                    $sam = [string](Get-V $m 'samaccountname'); $k = $sam.ToLower()
                    if (-not $acct.ContainsKey($k)) {
                        $classes = @($m['objectclass'] | ForEach-Object { [string]$_ })
                        $class = 'user'
                        if ($classes -contains 'msDS-GroupManagedServiceAccount' -or $classes -contains 'msDS-ManagedServiceAccount') { $class = 'service' }
                        elseif ($classes -contains 'computer') { $class = 'computer' }
                        elseif ($m.Contains('serviceprincipalname') -and $k -ne 'krbtgt') { $class = 'service' }
                        $uac = [int64](Get-V $m 'useraccountcontrol')
                        $acct[$k] = @{ Sam = $sam; Class = $class; Enabled = [int](-not ($uac -band 2)); High = 0; Protected = [int]$protected.ContainsKey($k); NoDelegation = [int][bool]($uac -band 1048576); Logon = (Get-Days (Get-V $m 'lastlogontimestamp')); Pwd = (Get-Days (Get-V $m 'pwdlastset')); Rid = (Get-Rid $m); Groups = @() }
                    }
                    if ($pair[1] -eq 'high') { $acct[$k].High = 1 }
                    $acct[$k].Groups += $gname
                }
                # a direct member that is not an object of this domain: a group or an account of another one
                # (its domain is the DC= part at the end of its name, compared whole: in the forest root a child domain's name ends
                # with the root's too)
                foreach ($dn in @($grp['member'] | Where-Object { $_ })) {
                    $memberDomain = [regex]::Match([string]$dn, '(?i)((?:,DC=[^,]+)+)$').Groups[1].Value.TrimStart(',')
                    if ($memberDomain -ine $domainDn -or ([string]$dn) -like '*,CN=ForeignSecurityPrincipals,*') { $foreign += ('{0}: {1}{2}' -f $gname, ((([string]$dn -split ',')[0]) -replace '^CN=', ''), $(if ($memberDomain -and $memberDomain -ine $domainDn) { ' of ' + ((@($memberDomain -split ',' | ForEach-Object { $_ -replace '^(?i)DC=', '' })) -join '.') } else { '' })) }
                }
                if (@(Find-Dir $domainDn ('(&(objectSid=' + $computersSid + ')(memberOf:1.2.840.113556.1.4.1941:=' + $gdn + '))') @('cn')).Count -gt 0) { $computersIn += $gname }
            }
            $rows = @($acct.Values | Sort-Object { -$_.High }, { $_.Sam } | Select-Object -First 200 | ForEach-Object { '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}' -f $_.Sam, $_.Class, $_.Enabled, $_.High, $_.Protected, $_.NoDelegation, $_.Logon, $_.Pwd, $_.Rid, ($_.Groups -join ',') })
            Add-S 'Priv.Count' $acct.Count; Add-S 'Priv' ($rows -join ';')
            Add-S 'PrivGroups' ($counts -join ';'); Add-List 'PrivForeign' $foreign; Add-List 'DomainComputersIn' $computersIn
        }
        Invoke-Step 'DcSync' {
            # who may replicate every secret of the domain: "Replicating Directory Changes All" on the domain itself (or every
            # extended right, or full control) - beyond the holders Windows puts there
            $head = @(Find-Dir $domainDn '(objectClass=*)' @('ntsecuritydescriptor') 'Base' $true)[0]
            $all = [guid]'1131f6ad-9c07-11d1-f79f-00c04fc2dcd2'
            $usual = @('S-1-5-18', 'S-1-5-9', 'S-1-5-32-544'); $usualRid = @('512', '516', '519', '498')
            $rows = @(); $seen = @{}
            foreach ($rule in (Get-Security $head)) {
                if (-not ($rule.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight)) { continue }
                if ($rule.ObjectType -ne $all -and $rule.ObjectType -ne [guid]::Empty) { continue }
                if ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly) { continue }   # for the objects below, not for the domain itself
                $sid = [string]$rule.IdentityReference.Value
                if ($seen.ContainsKey($sid)) { continue }; $seen[$sid] = $true
                if ($usual -contains $sid -or ($sid -like 'S-1-5-21-*' -and $usualRid -contains ($sid -split '-')[-1])) { continue }
                $name = $sid; $kind = 'unknown'
                $o = @(Find-Dir $domainDn ('(objectSid=' + (ConvertTo-SidFilter $sid) + ')') @('samaccountname', 'objectclass'))
                if ($o.Count -gt 0) { $name = [string](Get-V $o[0] 'samaccountname'); $classes = @($o[0]['objectclass'] | ForEach-Object { [string]$_ }); if ($classes -contains 'computer') { $kind = 'computer' } elseif ($classes -contains 'user') { $kind = 'user' } elseif ($classes -contains 'group') { $kind = 'group' } }
                else { try { $name = (New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { } }
                $broadSid = [int](Test-BroadSid $sid)   # nearly everybody, by identifier
                $rows += ('{0}|{1}|{2}|{3}' -f $name, $kind, [int]$ctx.SpnUsers.ContainsKey($name.ToLower()), $broadSid)
            }
            Add-List 'DcSync' $rows
        }
        Invoke-Step 'DomainComputersWrite' {
            if (-not $ctx.DomainSid) { throw 'the identifier of the domain was not read' }
            $ctx.Cut = $false
            $computers = $ctx.DomainSid + '-515'
            # create, delete, write a property, change the permissions or the owner
            $writes = 1 -bor 2 -bor 32 -bor 64 -bor 65536 -bor 262144 -bor 524288
            $rows = @(); $n = 0
            foreach ($o in @(Find-Dir $domainDn '(|(objectCategory=organizationalUnit)(objectClass=domainDNS)(cn=AdminSDHolder)(objectCategory=builtinDomain))' @('distinguishedname', 'ntsecuritydescriptor') 'Subtree' $true)) {
                $n++
                $hit = @(Get-Security $o | Where-Object { [string]$_.IdentityReference.Value -eq $computers -and ([int]$_.ActiveDirectoryRights -band $writes) })
                if ($hit.Count -gt 0) { $rows += ('{0}: {1}' -f ((([string](Get-V $o 'distinguishedname')) -split ',')[0] -replace '^(OU|CN|DC)=', ''), ((@($hit | ForEach-Object { [string]$_.ActiveDirectoryRights } | Select-Object -Unique)) -join ' / ')) }
            }
            Add-S 'DomainComputersWrite.Scanned' $n
            Add-List 'DomainComputersWrite' $rows $ctx.Cut
        }
        Invoke-Step 'GppPasswords' {
            # a password in Group Policy Preferences is written into SYSVOL, where every account can read and decrypt it
            $sysvol = [string](Get-RV 'HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters' 'SysVol')
            if (-not $sysvol) { throw 'the SYSVOL folder is not named in the registry of this server' }
            $policies = Join-Path (Join-Path $sysvol $domainDns) 'Policies'
            if (-not (Test-Path -LiteralPath $policies)) { throw ('the Policies folder of SYSVOL was not found ({0})' -f $policies) }
            $hits = @(); $n = 0
            foreach ($f in @(Get-ChildItem -LiteralPath $policies -Recurse -File -Filter '*.xml' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Preferences\\' -and $_.Length -lt 5MB })) {
                $n++
                if ([System.IO.File]::ReadAllText($f.FullName) -match 'cpassword="[^"]+"') { $hits += $f.FullName.Substring($policies.Length + 1) }
            }
            Add-S 'GppPasswords.Scanned' $n
            Add-List 'GppPasswords' $hits
        }

        # ---- once per forest: on the PDC emulator of its root domain ----
        if ($ctx.IsRoot) {
            Invoke-Step 'RecycleBin' {
                $binOn = $false
                try { $binOn = (@((Get-Entry ('CN=Recycle Bin Feature,CN=Optional Features,CN=Directory Service,CN=Windows NT,CN=Services,' + $configDn)).Properties['msDS-EnabledFeatureBL'] | Where-Object { $_ }).Count -gt 0) } catch { }
                Add-S 'RecycleBin' $binOn
            }
            Invoke-Step 'Templates' {
                $pki = 'CN=Public Key Services,CN=Services,' + $configDn
                $published = @{}; $cas = @()
                foreach ($ca in @(Find-Dir ('CN=Enrollment Services,' + $pki) '(objectClass=pKIEnrollmentService)' @('cn', 'dnshostname', 'certificatetemplates') 'OneLevel')) {
                    $cas += ('{0}|{1}' -f ((([string](Get-V $ca 'cn')) -replace '\|', '/')), (Get-V $ca 'dnshostname'))
                    foreach ($t in @($ca['certificatetemplates'] | Where-Object { $_ })) { $published[([string]$t).ToLower()] = $true }
                }
                Add-List 'Cas' $cas
                $auth = @('1.3.6.1.5.5.7.3.2', '1.3.6.1.5.2.3.4', '1.3.6.1.4.1.311.20.2.2', '2.5.29.37.0')   # client authentication, PKINIT, smart card logon, any purpose
                $enrol = @([guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55', [guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2', [guid]::Empty)
                $ekuNames = @{ '1.3.6.1.5.5.7.3.2' = 'client authentication'; '1.3.6.1.5.2.3.4' = 'Kerberos logon (PKINIT)'; '1.3.6.1.4.1.311.20.2.2' = 'smart card logon'; '2.5.29.37.0' = 'any purpose' }
                $reviewDays = 90   # the ISM has the templates reviewed every three months: the ones changed since are named
                $risky = @(); $subject = @(); $writable = @(); $logonList = @(); $changed = @(); $n = 0
                foreach ($t in @(Find-Dir ('CN=Certificate Templates,' + $pki) '(objectClass=pKICertificateTemplate)' @('cn', 'mspki-certificate-name-flag', 'mspki-enrollment-flag', 'mspki-ra-signature', 'pkiextendedkeyusage', 'whenchanged', 'ntsecuritydescriptor') 'OneLevel' $true)) {
                    $n++
                    $name = [string](Get-V $t 'cn')
                    $stamp = Get-V $t 'whenchanged'
                    if ($stamp -is [datetime]) { $age = [int][math]::Floor(($now - $stamp.ToUniversalTime()).TotalDays); if ($age -le $reviewDays) { $changed += ('{0} ({1} day(s) ago)' -f $name, $age) } }
                    # everybody, or nearly (Test-BroadSid)
                    $broad = @(Get-Security $t | Where-Object { Test-BroadSid ([string]$_.IdentityReference.Value) })
                    if (@($broad | Where-Object { [int]$_.ActiveDirectoryRights -band (32 -bor 262144 -bor 524288) }).Count -gt 0) { $writable += $name }
                    if (-not $published.ContainsKey($name.ToLower())) { continue }
                    $ekus = @($t['pkiextendedkeyusage'] | Where-Object { $_ } | ForEach-Object { [string]$_ })
                    $logon = ($ekus.Count -eq 0) -or (@($ekus | Where-Object { $auth -contains $_ }).Count -gt 0)
                    # a published template whose certificates are good for logging on: named, with the usages that make it so
                    if ($logon) { $logonList += ('{0} ({1})' -f $name, $(if ($ekus.Count -eq 0) { 'no usage named: any purpose' } else { (@($ekus | Where-Object { $auth -contains $_ } | ForEach-Object { $ekuNames[$_] }) -join ', ') })) }
                    if (-not (([int64](Get-V $t 'mspki-certificate-name-flag')) -band 1)) { continue }   # 1 = the requester supplies the subject
                    $approval = [bool]((([int64](Get-V $t 'mspki-enrollment-flag')) -band 2) -or (([int64](Get-V $t 'mspki-ra-signature')) -gt 0))
                    $open = (@($broad | Where-Object { ($_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight) -and $enrol -contains $_.ObjectType }).Count -gt 0)
                    if ($logon -and $open -and -not $approval) { $risky += $name } else { $subject += ('{0} (approval {1}, open to all {2}, logon {3})' -f $name, $(if ($approval) { 'yes' } else { 'no' }), $(if ($open) { 'yes' } else { 'no' }), $(if ($logon) { 'yes' } else { 'no' })) }
                }
                Add-S 'Templates.Count' $n
                Add-List 'TemplatesRisky' $risky; Add-List 'TemplatesSubject' $subject; Add-List 'TemplatesWritable' $writable
                Add-List 'TemplatesLogon' ($logonList | Sort-Object); Add-List 'TemplatesChanged' ($changed | Sort-Object); Add-S 'TemplatesReviewDays' $reviewDays
                Add-S 'Templates' 'OK'
            }
        }
    }
    Add-S 'Seconds' ([int]$watch.Elapsed.TotalSeconds)
    return (& $done)
}

# ---------------------------------------------------------------------
#  THE COLLECTOR'S CALL, AND WHAT THE CHECKS READ FROM IT
# ---------------------------------------------------------------------
function Test-DomainControllerKnown {
    # 'Yes' / 'No' / '' (not known yet): the Settings collector says so directly; the Inventory's roles are the fallback
    param([Parameter(Mandatory = $true)][string]$Server)
    $st = Get-CollectorResult -Name 'Settings' -Server $Server
    if ($st -and $st.Reachable) { foreach ($l in @($st.Lines)) { if ([string]$l -like 'IsDomainController=*') { if ([string]$l -eq 'IsDomainController=True') { return 'Yes' }; return 'No' } } }
    $inv = Get-CollectorResult -Name 'Inventory' -Server $Server
    if ($inv -and $inv.Reachable -and @($inv.Features).Count -gt 0 -and @(@($inv.Features) -match '^ERROR\|').Count -eq 0) { if (@(@($inv.Features) -match '^AD-Domain-Services\|').Count -gt 0) { return 'Yes' }; return 'No' }
    return ''
}

function Get-ServerDirectory {
    # The Directory collector, on the domain controllers among the names only (what the Settings or Inventory collector
    # said of each server decides: collect one of them first).  A server known not to be one gets its answer here, without
    # a call.  A server marked "winrm: no" is never called and keeps what its own local copy wrote.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $dcs = @(); $plain = @(); $unknown = @()
    foreach ($n in @(Get-UniqueNames $ComputerName)) {
        $known = Test-DomainControllerKnown -Server $n
        # this computer says so itself: a self-check asked for the Directory alone, or one whose Settings read failed, would
        # otherwise end with no result at all and be reported as a failed collector on a healthy server
        if (-not $known -and (Test-ThisComputer -Name $n)) { try { $known = $(if ([int](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).DomainRole -ge 4) { 'Yes' } else { 'No' }) } catch { $known = '' } }
        # a server that answered its status check and still is not known (its Settings read failed): named below.  One that did
        # not answer at all has been reported as unreachable already
        if (-not $known -and -not (Test-RemoteDisabled -Name $n)) { $st = Get-CollectorResult -Name 'Status' -Server $n; if ($st -and $st.Reachable) { $unknown += $n } }
        if ($known -eq 'Yes') { $dcs += $n }
        elseif ($known -eq 'No' -and -not (Test-RemoteDisabled -Name $n)) {
            if (-not $script:Results.ContainsKey('Directory')) { $script:Results['Directory'] = @{} }
            $script:Results['Directory'][$n] = [pscustomobject]@{ Computer = $n; Lines = @('AD.Read=NotDomainController'); Count = 1; Reachable = $true; Error = ''; Checked = (Get-Date) }
            $plain += $n
        }
    }
    if ($plain.Count -gt 0) { Clear-CheckRowCache -Servers $plain; Set-StateDirty -Server $plain }
    # left out, and said so: without it such a server's directory checks stay "not collected yet" and nothing tells why
    if ($unknown.Count -gt 0) { Write-PatchLog ("Directory: {0} server(s) left out - whether they are domain controllers is not known yet (their Settings or Inventory answer says so; check them again): {1}{2}" -f $unknown.Count, (@($unknown | Select-Object -First 5) -join ', '), $(if ($unknown.Count -gt 5) { ' ...' } else { '' })) 'WARN' }
    if ($dcs.Count -eq 0) { return @() }
    $summary = {
        param($r)
        $t = ConvertTo-SettingsTable -LineSets @(, @($r.Lines))
        if ([string]$t['AD.Read'] -ne 'OK') { return ('the directory was not read: ' + [string]$t['AD.Read']) }
        $unread = @($r.Lines | Where-Object { [string]$_ -match '^AD\.[^=]+=ERROR:' }).Count
        return ('domain {0}, {1}; {2} values read in {3} s{4}' -f $t['AD.Domain'], $(if ([string]$t['AD.IsPdc'] -eq 'True') { 'the PDC emulator - the domain is read here' } else { 'the domain is read on its PDC emulator ' + [string]$t['AD.Pdc'] }), $r.Count, $t['AD.Seconds'], $(if ($unread -gt 0) { " - $unread read(s) failed" } else { '' }))
    }
    $c = $script:Config
    return (Invoke-Collector -Name 'Directory' -ScriptBlock $script:RemoteDirectoryScript -ComputerName $dcs -ArgumentList @([int]$c.DirectoryMaxObjects, 40, 150, 240, [int]$c.DomainAccountInactiveDays, [int]$c.ComputerPasswordMaxAgeDays) -Summary $summary -TimeoutSec 480)
}

function Get-DirectoryFact {
    # One value or list of the Directory collector from a server's merged settings table ($c.S, key without "AD.").
    #   Unread   '' when it was read, else why not - the check answers Amber with it, never a pass
    #   Value    the text;  Names / Count  the list and how many there are in all;  More  said when the list is cut
    #   Cut      the sweep behind the list stopped at DirectoryMaxObjects objects: what it found is real, the rest was not looked at
    param($S, [Parameter(Mandatory = $true)][string]$Key)
    $o = [pscustomobject]@{ Unread = ''; Value = ''; Names = @(); Count = 0; More = ''; Cut = $false }
    $state = [string]$S['AD.Read']
    if ($state -like 'ERROR:*') { $o.Unread = 'the directory could not be read - ' + $state.Substring(6).Trim(); return $o }
    $full = 'AD.' + $Key
    if (-not $S.ContainsKey($full)) { $o.Unread = 'was not read - check the server again (collected from version 2.3 on)'; return $o }
    $v = [string]$S[$full]
    if ($v -like 'ERROR:*') { $o.Unread = 'could not be read - ' + $v.Substring(6).Trim(); return $o }
    $o.Value = $v
    $o.Names = @($v -split ';' | Where-Object { $_ })
    $o.Count = $o.Names.Count
    $n = 0; if ([int]::TryParse([string]$S[$full + '.Count'], [ref]$n)) { $o.Count = $n }
    if ($o.Count -gt $o.Names.Count) { $o.More = (' (the first {0} are listed)' -f $o.Names.Count) }
    if ([string]$S[$full + '.Cut'] -eq 'True') { $o.Cut = $true; $o.More += ' - the read stopped at DirectoryMaxObjects objects: there may be more' }
    return $o
}

function Get-DirectoryPrivileged {
    # The accounts in the privileged groups of the domain, from the collector's Priv rows: Sam, Class ('user', 'service',
    # 'computer'), Enabled, High (in a group that owns the domain), Protected (in Protected Users), NoDelegation, LogonDays
    # and PasswordDays ($null = never or not known), Rid, Groups.  Unread as Get-DirectoryFact.
    param($S)
    $f = Get-DirectoryFact -S $S -Key 'Priv'
    $out = [pscustomobject]@{ Unread = $f.Unread; Accounts = @(); More = '' }
    if ($f.Unread) { return $out }
    $number = { param($t) if ([string]$t -match '^\d+$') { [int]$t } else { $null } }
    $rows = @()
    foreach ($line in $f.Names) {
        $p = $line -split '\|'
        if ($p.Count -lt 10) { continue }
        $rows += [pscustomobject]@{ Sam = $p[0]; Class = $p[1]; Enabled = ($p[2] -eq '1'); High = ($p[3] -eq '1'); Protected = ($p[4] -eq '1'); NoDelegation = ($p[5] -eq '1'); LogonDays = (& $number $p[6]); PasswordDays = (& $number $p[7]); Rid = $p[8]; Groups = @($p[9] -split ',' | Where-Object { $_ }) }
    }
    $out.Accounts = $rows
    if ($f.Count -gt $rows.Count) { $out.More = (' (the first {0} of {1} privileged accounts are judged)' -f $rows.Count, $f.Count) }
    return $out
}

# ---------------------------------------------------------------------
#  ON THE HEALTH TAB: the sections of a domain controller's details page (double-click its row) and the tables of
#  the Health report.  All of it from the collector's saved answer - no server is asked again.  The grid has no
#  column of its own for the directory: its checks count in the row's Red / Amber / Green like any other.
# ---------------------------------------------------------------------
# dcdiag's three event log tests fail on any warning of the last day: to read, not an outage (H-AD-01 answers Amber)
$script:DcdiagEventTests = @('FrsEvent', 'DFSREvent', 'KccEvent')
$script:DirectoryLevelNames = @{ '0' = 'Windows 2000'; '1' = 'Windows Server 2003 interim'; '2' = 'Windows Server 2003'; '3' = 'Windows Server 2008'; '4' = 'Windows Server 2008 R2'; '5' = 'Windows Server 2012'; '6' = 'Windows Server 2012 R2'; '7' = 'Windows Server 2016'; '10' = 'Windows Server 2025' }
# the Directory fact of the details page names a red or amber check by one word
$script:DirectoryCellWords = @{ 'H-AD-02' = 'replication'; 'H-AD-03' = 'SYSVOL'; 'H-AD-04' = 'services'; 'H-AD-05' = 'roles'; 'H-AD-06' = 'backup'; 'H-AD-07' = 'RID pool'; 'H-AD-08' = 'time source'; 'H-AD-09' = 'level'; 'H-AD-10' = 'Recycle Bin' }

function Get-DirectoryLevelName {
    # A functional level by its name ('7' = Windows Server 2016), or 'level N' for one this version does not know
    param($Level)
    if ($script:DirectoryLevelNames.ContainsKey([string]$Level)) { return $script:DirectoryLevelNames[[string]$Level] }
    return ('level ' + [string]$Level)
}

function Get-DirectoryTable {
    # The Directory collector's answer for one server as a table (read with Get-DirectoryFact), or $null: not collected,
    # the call failed, the directory did not answer there, or the server is not a domain controller.
    param([string]$Server)
    $d = Get-CollectorResult -Name 'Directory' -Server $Server
    if (-not $d -or -not $d.Reachable) { return $null }
    $t = ConvertTo-SettingsTable -LineSets @(, @($d.Lines))
    if ([string]$t['AD.Read'] -ne 'OK') { return $null }
    return $t
}

function Get-DirectoryDcdiagRows {
    # dcdiag's tests on one domain controller, a row each, the failed ones first: Test, Result (passed / failed), On (what
    # it was run against: the server, a partition, the forest) and, for a failed one, what dcdiag printed.
    param($Table)
    if (-not $Table) { return @() }
    $tests = Get-DirectoryFact -S $Table -Key 'Dcdiag'
    if ($tests.Unread) { return @() }
    $said = @{}
    foreach ($line in @((Get-DirectoryFact -S $Table -Key 'Dcdiag.Failed').Names)) { if ([string]$line -match '^(\S+) \(([^)]*)\): (.*)$') { $said[$Matches[1] + '|' + $Matches[2]] = $Matches[3] } }
    $rows = @()
    foreach ($line in $tests.Names) {
        $f = $line -split '\|'; if ($f.Count -lt 3) { continue }
        $light = 'Green'; if ($f[1] -ne 'passed') { $light = 'Red'; if ($script:DcdiagEventTests -contains $f[0]) { $light = 'Amber' } }
        $rows += [pscustomobject]@{ Light = $light; Test = $f[0]; Result = $f[1]; On = $f[2]; 'What dcdiag said' = [string]$said[$f[0] + '|' + $f[2]] }
    }
    return @(@($rows | Where-Object { $_.Result -ne 'passed' }) + @($rows | Where-Object { $_.Result -eq 'passed' }))
}

function Get-DirectoryReplicationRows {
    # The inbound replication links of one domain controller, a row each (the collector lists the failing and the oldest
    # first): Partner, Partition, Last success, Failures in a row, Last result.
    param($Table)
    if (-not $Table) { return @() }
    $r = Get-DirectoryFact -S $Table -Key 'Repl'
    if ($r.Unread) { return @() }
    $max = [int]$script:Config.DirectoryReplicationMaxHours
    $rows = @()
    foreach ($line in $r.Names) {
        $f = $line -split '\|'; if ($f.Count -lt 5) { continue }
        $hours = 0; $known = [int]::TryParse($f[3], [ref]$hours)
        $light = 'Green'
        if ([int]$f[2] -gt 0) { $light = 'Red' } elseif (-not $known -or $hours -gt $max) { $light = 'Amber' }
        $rows += [pscustomobject]@{ Light = $light; Partner = $f[0]; Partition = $f[1]; 'Last success' = $(if ($known) { '{0} h ago' -f $hours } else { 'never' }); 'Failures in a row' = $f[2]; 'Last result' = $(if ($f[4] -eq '0') { 'ok' } else { 'error ' + $f[4] }) }
    }
    return $rows
}

function Get-DirectoryDcdiagScore {
    # 'dcdiag 29/29' (passed of run), or 'dcdiag not read'
    param($Table)
    if (-not $Table -or (Get-DirectoryFact -S $Table -Key 'Dcdiag.Read').Unread) { return 'dcdiag not read' }
    $tests = @((Get-DirectoryFact -S $Table -Key 'Dcdiag').Names)
    return ('dcdiag {0}/{1}' -f @($tests | Where-Object { ($_ -split '\|')[1] -eq 'passed' }).Count, $tests.Count)
}

function Get-DirectorySummaryText {
    # The Directory fact at the head of a domain controller's Health page (the grid has no column for it).  '' for a
    # server that is not a domain controller; 'not read' for one whose directory was not collected; else dcdiag's score
    # and, by a word each, what else of its domain controller and domain checks is red or amber, the red first, two named
    # and the rest counted: "dcdiag 29/29", "dcdiag 27/29; replication, backup +2".  The sections below it name every one.
    param([string]$Server, [object[]]$Checks)
    $mine = @($Checks | Where-Object { [string]$_.Id -like 'H-AD-*' -and [string]$_.Verdict -ne 'NotApplicable' })
    if ($mine.Count -eq 0) { return '' }
    $t = Get-DirectoryTable -Server $Server
    if (-not $t) { return 'not read' }
    $text = Get-DirectoryDcdiagScore -Table $t
    $also = @($mine | Where-Object { [string]$_.Light -in 'Red', 'Amber' -and $script:DirectoryCellWords.ContainsKey([string]$_.Id) } | Sort-Object @{ Expression = { [string]$_.Light -ne 'Red' } }, @{ Expression = { [string]$_.Id } } | ForEach-Object { $script:DirectoryCellWords[[string]$_.Id] })
    if ($also.Count -gt 0) { $text += '; ' + (@($also | Select-Object -First 2) -join ', '); if ($also.Count -gt 2) { $text += (' +{0}' -f ($also.Count - 2)) } }
    return $text
}

function Get-DirectoryDetailsSections {
    # The domain controller part of a server's Health page: what the Directory collector read there - the server's place
    # in the domain, dcdiag test by test, every inbound replication link, the role holders, the services, the domain's
    # other domain controllers.  Nothing for a server that is not a domain controller.
    param([string]$Server)
    $d = Get-CollectorResult -Name 'Directory' -Server $Server
    $isDc = (Test-DomainControllerKnown -Server $Server) -eq 'Yes'
    $read = ''
    if ($d -and $d.Reachable) { $all = ConvertTo-SettingsTable -LineSets @(, @($d.Lines)); $read = [string]$all['AD.Read'] }
    if ($read -eq 'NotDomainController') { return @() }
    if ($read) { $isDc = $true }
    if (-not $isDc) { return @() }
    if (-not $d) { return @(@{ Heading = 'Domain controller'; Lines = @($(if (Test-RemoteDisabled -Name $Server) { 'the directory was not read yet - run the copy on the server again: its self-check reads it from version 2.3 on' } else { 'the directory was not read yet - press "Check health (ticked or all)"' })) }) }
    if (-not $d.Reachable) { return @(@{ Heading = 'Domain controller'; Lines = @('the directory was not read: ' + [string]$d.Error) }) }
    $t = Get-DirectoryTable -Server $Server
    if (-not $t) { return @(@{ Heading = 'Domain controller'; Lines = @('the directory did not answer on this server: ' + ($read -replace '^ERROR:\s*', '')) }) }
    $me = [string]$t['AD.Dc']
    $roles = @((Get-DirectoryFact -S $t -Key 'Fsmo').Names | ForEach-Object { $f = $_ -split '\|'; if ($f.Count -ge 2) { [pscustomobject]@{ Role = $f[0]; Holder = $f[1]; Here = $(if ($me -and $f[1] -ieq $me) { 'this server' } else { '' }) } } })
    $held = @($roles | Where-Object { $_.Here } | ForEach-Object { $_.Role })
    $facts = @(
        [pscustomobject]@{ Item = 'Domain'; Value = ('{0} (forest root {1})' -f $t['AD.Domain'], $t['AD.ForestRoot']) },
        [pscustomobject]@{ Item = 'Site'; Value = [string]$t['AD.Site'] },
        [pscustomobject]@{ Item = 'Global catalog'; Value = $(if ([string]$t['AD.IsGc'] -ieq 'True') { 'yes' } else { 'no' }) },
        [pscustomobject]@{ Item = 'Functional level'; Value = ('domain {0}, forest {1}' -f (Get-DirectoryLevelName $t['AD.Level.Domain']), (Get-DirectoryLevelName $t['AD.Level.Forest'])) },
        [pscustomobject]@{ Item = 'Roles held here'; Value = $(if ($held.Count -gt 0) { $held -join ', ' } else { 'none' }) },
        [pscustomobject]@{ Item = 'The domain is read on'; Value = $(if ([string]$t['AD.IsPdc'] -eq 'True') { 'this server (its PDC emulator)' } else { [string]$t['AD.Pdc'] + ' (its PDC emulator)' }) })
    $db = ([string]$t['AD.Database']) -split '\|'
    if ($db.Count -ge 3) { $facts += [pscustomobject]@{ Item = 'Database'; Value = ('{0}: {1} GB, {2} GB free on its volume' -f $db[0], $db[1], $db[2]) } }
    $facts += [pscustomobject]@{ Item = 'Read'; Value = ((@((Format-LastChecked $d.Checked), $(if ([string]$t['AD.Seconds']) { 'in {0} s' -f $t['AD.Seconds'] }), $(if ([string]$t['AD.Session'] -eq 'network') { 'over WinRM' } else { 'on the server itself' })) | Where-Object { $_ }) -join ', ') }
    $sections = @(@{ Heading = 'Domain controller'; Rows = $facts; Columns = @('Item', 'Value') })
    $state = Get-DirectoryFact -S $t -Key 'Dcdiag.Read'
    if ($state.Unread) { $sections += @{ Heading = 'Domain controller: dcdiag'; Lines = @('dcdiag ' + $state.Unread) } }
    else { $sections += @{ Heading = 'Domain controller: dcdiag'; Rows = @(Get-DirectoryDcdiagRows -Table $t); Columns = @('Light', 'Test', 'Result', 'On', 'What dcdiag said'); Note = ('dcdiag /skip:SystemLog as it ran on the server at the check: {0} passed.' -f (Get-DirectoryDcdiagScore -Table $t).Replace('dcdiag ', '').Replace('/', ' of ')) } }
    $repl = Get-DirectoryFact -S $t -Key 'Repl'
    if ($repl.Unread) { $sections += @{ Heading = 'Domain controller: inbound replication'; Lines = @('replication ' + $repl.Unread) } }
    else { $sections += @{ Heading = 'Domain controller: inbound replication'; Rows = @(Get-DirectoryReplicationRows -Table $t); Columns = @('Light', 'Partner', 'Partition', 'Last success', 'Failures in a row', 'Last result'); Note = ('Every partition this server holds, from each partner it replicates from{0}.' -f $repl.More) } }
    $sections += @{ Heading = 'Domain controller: operations master roles'; Rows = $roles; Columns = @('Role', 'Holder', 'Here') }
    # the Print Spooler is the Security console's matter (SEC-ADC-02): not a service the directory stands on
    $sections += @{ Heading = 'Domain controller: services'; Rows = @((Get-DirectoryFact -S $t -Key 'Services').Names | ForEach-Object { $f = $_ -split '\|'; if ($f.Count -ge 3 -and $f[0] -ne 'Spooler') { [pscustomobject]@{ Light = $(if ($f[1] -eq 'Running') { 'Green' } elseif ($f[2] -eq 'Auto') { 'Red' } else { 'Grey' }); Service = $f[0]; State = $f[1]; Start = $f[2] } } }); Columns = @('Light', 'Service', 'State', 'Start') }
    $dcs = Get-DirectoryFact -S $t -Key 'DcList'
    if (-not $dcs.Unread) { $sections += @{ Heading = 'Domain controllers of the domain'; Rows = @($dcs.Names | ForEach-Object { $f = $_ -split '\|'; [pscustomobject]@{ 'Domain controller' = $f[0]; 'Operating system' = $(if ($f.Count -ge 2) { $f[1] } else { '' }) } }); Columns = @('Domain controller', 'Operating system'); Note = ('{0} in {1}{2}.' -f $dcs.Count, $t['AD.Domain'], $dcs.More) } }
    return $sections
}

function Get-DirectoryReportSections {
    # The Health report's tables for the domain controllers among the servers: one row per domain controller, then
    # dcdiag test by test and every inbound replication link.  Empty when none of the servers is a domain controller.
    param([string[]]$Servers)
    $dcRows = @(); $tests = @(); $links = @()
    foreach ($s in @($Servers)) {
        $t = Get-DirectoryTable -Server $s
        if (-not $t) { continue }
        $checks = @(Get-CheckRows -Console 'Health' -Server $s | Where-Object { [string]$_.Id -like 'H-AD-*' -and [string]$_.Verdict -ne 'NotApplicable' })
        $dd = @(Get-DirectoryDcdiagRows -Table $t); $rp = @(Get-DirectoryReplicationRows -Table $t)
        $dcRows += [pscustomobject]@{
            Server = $s; Light = (Get-WorstLight -Rows $checks); Domain = [string]$t['AD.Domain']; Site = [string]$t['AD.Site']
            'PDC emulator' = $(if ([string]$t['AD.IsPdc'] -eq 'True') { 'yes' } else { 'no' }); 'Global catalog' = $(if ([string]$t['AD.IsGc'] -ieq 'True') { 'yes' } else { 'no' })
            dcdiag = (Get-DirectoryDcdiagScore -Table $t).Replace('dcdiag ', ''); 'Failed tests' = ((@($dd | Where-Object { $_.Result -ne 'passed' } | ForEach-Object { $_.Test } | Select-Object -Unique)) -join ', ')
            'Replication links' = $rp.Count; 'Links failing' = @($rp | Where-Object { $_.Light -eq 'Red' }).Count; 'Links late' = @($rp | Where-Object { $_.Light -eq 'Amber' }).Count
            Findings = ((@($checks | Where-Object { [string]$_.Light -in 'Red', 'Amber' } | ForEach-Object { [string]$_.Title })) -join '; ')
        }
        foreach ($r in $dd) { $tests += [pscustomobject]@{ Server = $s; Light = $r.Light; Test = $r.Test; Result = $r.Result; On = $r.On; 'What dcdiag said' = $r.'What dcdiag said' } }
        foreach ($r in $rp) { $links += [pscustomobject]@{ Server = $s; Light = $r.Light; Partner = $r.Partner; Partition = $r.Partition; 'Last success' = $r.'Last success'; 'Failures in a row' = $r.'Failures in a row'; 'Last result' = $r.'Last result' } }
    }
    if ($dcRows.Count -eq 0) { return @() }
    return @(
        @{ Name = 'Domain controllers'; Rows = $dcRows; Columns = @('Server', 'Domain', 'Site', 'PDC emulator', 'Global catalog', 'dcdiag', 'Failed tests', 'Replication links', 'Links failing', 'Links late', 'Findings', 'Light') },
        @{ Name = 'Domain controllers dcdiag'; Rows = $tests; Columns = @('Server', 'Test', 'Result', 'On', 'What dcdiag said', 'Light') },
        @{ Name = 'Domain controllers replication'; Rows = $links; Columns = @('Server', 'Partner', 'Partition', 'Last success', 'Failures in a row', 'Last result', 'Light') })
}

# One test for the checks that are "this list must be empty".  The check's -Data: Key (the collector's list), None (the
# words of a pass), Found (the words of a finding; {0} = how many, {1} = the collector's value named by DaysKey),
# Verdict ('Fail', or 'Warn' for a list to confirm), What (named when the list was not read), NeedsKey and NeedsText (a
# list that must not be empty for the check to apply, and the words when it is).
$script:DirectoryListTest = {
    param($c)
    $d = $c.Check.Data
    $l = Get-DirectoryFact -S $c.S -Key $d.Key
    if ($l.Unread) { return (Warn ('{0}: {1}' -f $d.What, $l.Unread)) }
    if ($d.NeedsKey) { $need = Get-DirectoryFact -S $c.S -Key $d.NeedsKey; if (-not $need.Unread -and $need.Count -eq 0) { return (NotApplicable $d.NeedsText) } }
    $days = ''; if ($d.DaysKey) { $days = [string]$c.S['AD.' + $d.DaysKey] }
    # nothing found by a sweep that stopped at the limit is not "none": the objects after the limit were not looked at
    # (every object with a service principal name - each computer has some - is more than 20,000 in a large domain)
    if ($l.Count -eq 0 -and $l.Cut) { return (Warn ('{0}: none among the objects read, but the read stopped at DirectoryMaxObjects objects and the rest was not read - raise DirectoryMaxObjects (Settings tab, Security) and check again' -f $d.What)) }
    if ($l.Count -eq 0) { return (Pass ($d.None -f 0, $days)) }
    $text = ($d.Found -f $l.Count, $days) + $l.More
    if ($d.Verdict -eq 'Warn') { return (Warn $text -Items $l.Names) }
    return (Fail $text -Items $l.Names)
}

# ---------------------------------------------------------------------
#  HEALTH: THE DOMAIN CONTROLLER (H-AD-01..06) AND THE DOMAIN (H-AD-07..10)
# ---------------------------------------------------------------------
New-Check -Id 'H-AD-01' -Console 'Health' -Group 'Domain controller' -Title 'dcdiag: every test passes' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'dcdiag is the directory''s own test of a domain controller: that it is advertised, that its services, its replication, its SYSVOL and its role holders answer. A domain controller that fails one logs users on late or not at all.' `
    -Test {
        param($c)
        $state = Get-DirectoryFact -S $c.S -Key 'Dcdiag.Read'
        if ($state.Unread) { return (Warn ('dcdiag: ' + $state.Unread)) }
        $tests = @((Get-DirectoryFact -S $c.S -Key 'Dcdiag').Names)
        $bad = @($tests | Where-Object { ($_ -split '\|')[1] -eq 'failed' } | ForEach-Object { ($_ -split '\|')[0] } | Select-Object -Unique)
        if ($bad.Count -eq 0) { return (Pass ('{0} dcdiag test(s), all passed' -f $tests.Count)) }
        $items = @((Get-DirectoryFact -S $c.S -Key 'Dcdiag.Failed').Names)
        $text = ('{0} of {1} dcdiag test(s) failed: {2}' -f $bad.Count, $tests.Count, ($bad -join ', '))
        if ([string]$c.S['AD.Session'] -eq 'network') { $text += ' (read over WinRM: a test that has to reach another domain controller can fail for that reason alone - the local copy on the server settles it)' }
        # the three event log tests fail on any warning of the last day: to read, not an outage
        if (@($bad | Where-Object { $script:DcdiagEventTests -notcontains $_ }).Count -eq 0) { return (Warn $text -Items $items) }
        return (Fail $text -Items $items)
    } -Fix 'On the domain controller: dcdiag /v /test:<the test> prints the detail. Replications and KccEvent: repadmin /showrepl; SysVolCheck and DFSREvent: the DFS Replication event log; Services: start the service it names; KnowsOfRoleHolders and RidManager: the role holder it names must be reachable.'

New-Check -Id 'H-AD-02' -Console 'Health' -Group 'Domain controller' -Title 'Replication: every partner is up to date' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'A domain controller that stops replicating keeps answering with what it knew: old passwords, old group memberships, old Group Policy. Left longer than the tombstone lifetime it has to be rebuilt.' `
    -Test {
        param($c)
        $r = Get-DirectoryFact -S $c.S -Key 'Repl'
        if ($r.Unread) { return (Warn ('replication: ' + $r.Unread)) }
        $max = [int]$script:Config.DirectoryReplicationMaxHours
        if ($r.Count -eq 0) {
            $dcs = Get-DirectoryFact -S $c.S -Key 'DcList'
            if (-not $dcs.Unread -and $dcs.Count -le 1) { return (Pass 'the only domain controller of its domain: it has no replication partner') }
            return (Warn 'no inbound replication partner - a domain controller of a domain with others replicates from at least one')
        }
        $failing = @(); $late = @(); $oldest = 0; $partners = @{}
        foreach ($row in $r.Names) {
            $f = $row -split '\|'; if ($f.Count -lt 5) { continue }
            $partners[$f[0]] = $true
            if ([int]$f[2] -gt 0) { $failing += ('{0}, partition {1}: {2} failure(s) in a row, error {3}, last success {4}' -f $f[0], $f[1], $f[2], $f[4], $(if ($f[3] -eq 'never') { 'never' } else { $f[3] + ' h ago' })) }
            elseif ($f[3] -eq 'never') { $late += ('{0}, partition {1}: never replicated yet' -f $f[0], $f[1]) }
            elseif ([int]$f[3] -gt $max) { $late += ('{0}, partition {1}: last success {2} h ago' -f $f[0], $f[1], $f[3]) }
            elseif ([int]$f[3] -gt $oldest) { $oldest = [int]$f[3] }
        }
        if ($failing.Count -gt 0) { return (Fail ('{0} of {1} inbound replication link(s) failing{2}' -f $failing.Count, $r.Count, $r.More) -Items @($failing + $late)) }
        if ($late.Count -gt 0) { return (Warn ('{0} of {1} inbound replication link(s) not replicated within {2} h{3}' -f $late.Count, $r.Count, $max, $r.More) -Items $late) }
        return (Pass ('{0} inbound replication link(s) from {1} partner(s), each replicated within {2} h (the oldest {3} h ago)' -f $r.Count, $partners.Count, $max, $oldest))
    } -Fix 'On the domain controller: repadmin /showrepl names the error; repadmin /syncall /AdeP tries again. The usual causes: DNS (the partner''s name does not resolve), a firewall between the sites, the time more than five minutes apart, a partner that was removed without being demoted.'

New-Check -Id 'H-AD-03' -Console 'Health' -Group 'Domain controller' -Title 'SYSVOL and NETLOGON are shared and replicating' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'Group Policy and the logon scripts are files in SYSVOL. A domain controller without the two shares is not offered to clients; one whose SYSVOL does not replicate applies old policy.' `
    -Test {
        param($c)
        $sh = Get-DirectoryFact -S $c.S -Key 'Shares'
        if ($sh.Unread) { return (Warn ('the shares: ' + $sh.Unread)) }
        $missing = @('NETLOGON', 'SYSVOL' | Where-Object { $sh.Names -notcontains $_ })
        $ready = [string]$c.S['AD.SysvolReady']; $dfsr = [string]$c.S['AD.Sysvol.DfsrState']
        $how = 'replicated by DFS Replication, state normal'
        if ($missing.Count -gt 0) { return (Fail ('not shared on this domain controller: {0}' -f ($missing -join ', '))) }
        if ($ready -ne '1') { return (Fail ('SYSVOL is shared, but not marked ready (SysvolReady = {0}): the first synchronisation did not finish' -f $(if ($ready) { $ready } else { 'not set' }))) }
        if ($dfsr -eq '5') { return (Fail 'SYSVOL is shared, but DFS Replication reports it IN ERROR') }
        if ($dfsr -eq '') {
            $frs = @((Get-DirectoryFact -S $c.S -Key 'Services').Names | Where-Object { $_ -like 'NtFrs|Running|*' }).Count -gt 0
            if ($frs) { return (Warn 'SYSVOL and NETLOGON are shared; SYSVOL still replicates with the File Replication Service (FRS), which Windows Server no longer supports') }
            return (Pass 'SYSVOL and NETLOGON are shared and SYSVOL is ready (its replication state was not reported)')
        }
        if ($dfsr -ne '4') { return (Warn ('SYSVOL and NETLOGON are shared; DFS Replication reports SYSVOL in state {0} ({1})' -f $dfsr, $(switch ($dfsr) { '0' { 'not initialised' } '1' { 'initialised' } '2' { 'the first synchronisation' } '3' { 'recovering' } default { 'not normal' } }))) }
        return (Pass ('SYSVOL and NETLOGON are shared, SYSVOL is ready, {0}' -f $how))
    } -Fix 'The DFS Replication event log on the domain controller says why. A SYSVOL in error after an unexpected shutdown waits for: wmic /namespace:\\root\microsoftdfs path dfsrVolumeConfig call ResumeReplication (Microsoft KB 2846759). A domain still on FRS: migrate SYSVOL with dfsrmig.'

New-Check -Id 'H-AD-04' -Console 'Health' -Group 'Domain controller' -Title 'The directory''s services are running' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'A domain controller is these services: the directory itself (NTDS), Netlogon, the Kerberos key distribution centre, DNS where it serves the zone, DFS Replication for SYSVOL, the time service.' `
    -Test {
        param($c)
        $sv = Get-DirectoryFact -S $c.S -Key 'Services'
        if ($sv.Unread) { return (Warn ('the services: ' + $sv.Unread)) }
        $state = @{}; $items = @()
        foreach ($row in $sv.Names) { $f = $row -split '\|'; if ($f.Count -ge 3 -and $f[0] -ne 'Spooler') { $state[$f[0]] = $f; $items += ('{0}: {1} ({2})' -f $f[0], $f[1], $f[2]) } }
        $down = @()
        foreach ($need in 'NTDS', 'Netlogon', 'Kdc') { if (-not $state.ContainsKey($need)) { $down += ($need + ' (not found)') } elseif ($state[$need][1] -ne 'Running') { $down += ('{0} ({1})' -f $need, $state[$need][1]) } }
        # the others count where they are set to start by themselves: DNS, DFSR and ADWS are not on every domain controller
        foreach ($name in @($state.Keys | Where-Object { @('NTDS', 'Netlogon', 'Kdc') -notcontains $_ })) { if ($state[$name][2] -eq 'Auto' -and $state[$name][1] -ne 'Running') { $down += ('{0} ({1})' -f $name, $state[$name][1]) } }
        $db = ([string]$c.S['AD.Database']) -split '\|'
        if ($db.Count -ge 3) { $items += ('the database {0}: {1} GB, {2} GB free on its volume' -f $db[0], $db[1], $db[2]) }
        if ($down.Count -gt 0) { return (Fail ('not running: {0}' -f ($down -join ', ')) -Items $items) }
        return (Pass ('{0} directory service(s) present, each one that starts by itself is running' -f $state.Count) -Items $items)
    } -Fix 'Start the service on the domain controller (services.msc, or Start-Service <name>) and read the Directory Service, DNS Server and DFS Replication event logs for why it stopped.'

New-Check -Id 'H-AD-05' -Console 'Health' -Group 'Domain controller' -Title 'The five operations master roles have a holder' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'One domain controller issues the RID pools, one is the time and password authority (PDC emulator), one changes the schema, one adds domains. A role whose holder was removed or lost stops that work until it is seized.' `
    -Test {
        param($c)
        $fs = Get-DirectoryFact -S $c.S -Key 'Fsmo'
        if ($fs.Unread) { return (Warn ('the role holders: ' + $fs.Unread)) }
        $bad = @(); $items = @()
        foreach ($row in $fs.Names) {
            $f = $row -split '\|'; if ($f.Count -lt 2) { continue }
            $items += ('{0}: {1}' -f $f[0], $f[1])
            if (@('NONE', 'DELETED', 'UNKNOWN') -contains $f[1]) { $bad += ('{0} ({1})' -f $f[0], $(switch ($f[1]) { 'NONE' { 'no holder recorded' } 'DELETED' { 'its holder was removed from the directory' } default { 'its holder could not be named' } })) }
        }
        if ($items.Count -lt 5) { return (Warn ('only {0} of the five role holders were read' -f $items.Count) -Items $items) }
        if ($bad.Count -gt 0) { return (Fail ('without a usable holder: {0}' -f ($bad -join '; ')) -Items $items) }
        return (Pass 'each of the five roles has a holder, as this domain controller knows them' -Items $items)
    } -Fix 'netdom query fsmo shows the holders. A holder that is gone for good: seize the role on another domain controller (Move-ADDirectoryServerOperationMasterRole -Force, or ntdsutil roles) and never bring the old holder back.'

New-Check -Id 'H-AD-06' -Console 'Health' -Group 'Domain' -Title 'The directory is backed up' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'A backup of a domain controller''s system state is the only way back from a deleted OU or a corrupted directory. One older than the tombstone lifetime can no longer be restored.' `
    -Test {
        param($c)
        $b = Get-DirectoryFact -S $c.S -Key 'Backup.Days'
        if ($b.Unread) { return (Warn ('the last backup: ' + $b.Unread)) }
        $max = [int]$script:Config.DirectoryBackupMaxDays
        $tomb = 180; $t = 0; if ([int]::TryParse([string]$c.S['AD.TombstoneDays'], [ref]$t) -and $t -gt 0) { $tomb = $t }
        if ($b.Value -eq 'never') { return (Fail 'the directory has no record of a backup of the domain partition') }
        $days = [int]$b.Value
        if ($days -gt $tomb) { return (Fail ('the domain partition was last backed up {0} days ago: older than the tombstone lifetime of {1} days, it cannot be restored' -f $days, $tomb)) }
        if ($days -gt $max) { return (Warn ('the domain partition was last backed up {0} days ago (expected within {1})' -f $days, $max)) }
        return (Pass ('the domain partition was last backed up {0} day(s) ago' -f $days))
    } -Fix 'Back up the system state of at least one domain controller of each domain every day (Windows Server Backup: wbadmin start systemstatebackup, or a backup product that is aware of the directory). The date is the directory''s own record: a snapshot the directory was not told about does not move it.'

New-Check -Id 'H-AD-07' -Console 'Health' -Group 'Domain' -Title 'The RID pool is not running out' -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'Every account, group and computer of a domain takes one relative identifier, and they are never given back. A domain that runs out can create nothing more.' `
    -Test {
        param($c)
        $r = Get-DirectoryFact -S $c.S -Key 'Rid'
        if ($r.Unread) { return (Warn ('the RID pool: ' + $r.Unread)) }
        $f = $r.Value -split '\|'
        $total = [int64]0; $next = [int64]0
        if ($f.Count -lt 2 -or -not [int64]::TryParse($f[0], [ref]$total) -or -not [int64]::TryParse($f[1], [ref]$next) -or $total -le 0) { return (Warn ('the RID pool was not read (''{0}'')' -f $r.Value)) }
        $used = [math]::Round(100.0 * $next / $total, 1).ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $text = ('{0} of {1} identifiers issued ({2} %)' -f $next, $total, $used)
        if ((100.0 * $next / $total) -ge 95) { return (Fail $text) }
        if ((100.0 * $next / $total) -ge 80) { return (Warn $text) }
        return (Pass $text)
    } -Fix 'Find what creates objects in bulk (a provisioning script in a loop, a domain controller that keeps asking for new pools) and stop it. Microsoft: "Managing RID Issuance" describes the ceiling and how to raise it.'

New-Check -Id 'H-AD-08' -Console 'Health' -Group 'Domain' -Title 'The forest''s PDC emulator takes its time from an outside source' -Severity 'Medium' -Needs 'Directory', 'Settings' -Applies 'forest' `
    -Why 'Every computer of the forest takes its time from a domain controller, and they all follow the PDC emulator of the root domain. If that one follows only its own clock, the whole forest drifts with it - and Kerberos refuses five minutes.' `
    -Test {
        param($c)
        $type = [string]$c.S['Time.Type']; $src = [string]$c.S['Time.Source']
        if (-not $type -or $type -eq 'NotConfigured') { return (Warn 'the time service''s type was not read') }
        $text = ('time type {0}, source {1}' -f $type, $(if ($src) { $src } else { 'not read' }))
        if ($src -match '(?i)Local CMOS Clock|Free-running System Clock') { return (Warn ($text + ' - the forest follows this server''s own clock')) }
        if (@('NTP', 'AllSync') -notcontains $type) { return (Warn ($text + ' - the PDC emulator of the root domain is expected to be set to named time servers (NTP)')) }
        return (Pass $text)
    } -Fix 'On the PDC emulator of the forest root domain: w32tm /config /manualpeerlist:"<your time servers>" /syncfromflags:manual /reliable:yes /update, then restart the Windows Time service. Every other domain controller stays on the domain hierarchy (NT5DS).'

New-Check -Id 'H-AD-09' -Console 'Health' -Group 'Domain' -Title 'The domain functional level allows today''s protections' -Severity 'Low' -Needs 'Directory' -Applies 'domain' `
    -Why 'The Protected Users group, authentication policies and Kerberos armouring protect accounts only from the Windows Server 2012 R2 domain functional level on. A domain kept at an older level has them in name only.' `
    -Test {
        param($c)
        $lv = Get-DirectoryFact -S $c.S -Key 'Level.Domain'
        if ($lv.Unread) { return (Warn ('the functional level: ' + $lv.Unread)) }
        $text = ('domain {0}, forest {1}; this domain controller could run {2}' -f (Get-DirectoryLevelName $lv.Value), (Get-DirectoryLevelName $c.S['AD.Level.Forest']), (Get-DirectoryLevelName $c.S['AD.Level.Dc']))
        $n = 0; if (-not [int]::TryParse($lv.Value, [ref]$n)) { return (Warn ('the functional level was read as ''{0}''' -f $lv.Value)) }
        if ($n -lt 6) { return (Warn ($text + ' - below Windows Server 2012 R2')) }
        return (Pass $text)
    } -Fix 'When every domain controller of the domain runs Windows Server 2012 R2 or later: Active Directory Domains and Trusts > the domain > Raise Domain Functional Level. It cannot be lowered again: confirm that no older domain controller is left first.'

New-Check -Id 'H-AD-10' -Console 'Health' -Group 'Domain' -Title 'The Active Directory Recycle Bin is on' -Severity 'Low' -Needs 'Directory' -Applies 'forest' `
    -Why 'With the Recycle Bin an account or an OU deleted by mistake comes back with its group memberships in a minute. Without it the way back is a restore of a domain controller from backup.' `
    -Test {
        param($c)
        $rb = Get-DirectoryFact -S $c.S -Key 'RecycleBin'
        if ($rb.Unread) { return (Warn ('the Recycle Bin: ' + $rb.Unread)) }
        if ($rb.Value -eq 'True') { return (Pass 'the Recycle Bin is enabled for the forest') }
        return (Warn 'the Recycle Bin is not enabled for the forest')
    } -Fix 'Active Directory Administrative Center > the forest root domain > Enable Recycle Bin (the forest functional level must be Windows Server 2008 R2 or later). It cannot be switched off again.'

# ---------------------------------------------------------------------
#  SECURITY: THE DOMAIN CONTROLLER ITSELF (SEC-ADC-01..04)
# ---------------------------------------------------------------------
New-Check -Id 'SEC-ADC-01' -Console 'Security' -Group 'Domain controller' -Title 'LDAP signing is required' -Ism 'ISM-1929' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'Without signing, whoever sits between a client and the domain controller can change an LDAP request on its way - and relay somebody else''s logon to the directory.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'Local'
        if ($l.Unread) { return (Warn ('the LDAP settings: ' + $l.Unread)) }
        $sign = [string]$c.S['AD.LdapSigning']; $bind = [string]$c.S['AD.LdapChannelBinding']
        $binding = ('channel binding: {0}' -f $(switch ($bind) { '2' { 'always' } '1' { 'when supported' } '0' { 'never' } default { 'not set' } }))
        if ($sign -eq '2') { return (Pass ('LDAP signing is required (LDAPServerIntegrity = 2); ' + $binding)) }
        return (Fail ('LDAP signing is not required (LDAPServerIntegrity = {0}); {1}' -f $(if ($sign) { $sign } else { 'not set' }), $binding))
    } -Fix 'GPO on the Domain Controllers OU: Security Options > Domain controller: LDAP server signing requirements = Require signing (and Domain controller: LDAP server channel binding token requirements = Always). First find the clients that bind unsigned: event 2889 in the Directory Service log, after setting "16 LDAP Interface Events" to 2.'

New-Check -Id 'SEC-ADC-02' -Console 'Security' -Group 'Domain controller' -Title 'The Print Spooler is disabled' -Ism 'ISM-1828' -Severity 'High' -Needs 'Directory' -Applies 'dc' `
    -Why 'A running Print Spooler lets any domain account make the domain controller authenticate to a computer of its choosing; with a server trusted for delegation there, that hands over the domain.' `
    -Test {
        param($c)
        $sv = Get-DirectoryFact -S $c.S -Key 'Services'
        if ($sv.Unread) { return (Warn ('the services: ' + $sv.Unread)) }
        $sp = @($sv.Names | Where-Object { $_ -like 'Spooler|*' })
        if ($sp.Count -eq 0) { return (Pass 'no Print Spooler service on this domain controller') }
        $f = $sp[0] -split '\|'
        if ($f[2] -eq 'Disabled' -and $f[1] -ne 'Running') { return (Pass 'the Print Spooler is disabled and stopped') }
        return (Fail ('the Print Spooler is {0}, start type {1}' -f $f[1].ToLower(), $f[2]))
    } -Fix 'GPO on the Domain Controllers OU: System Services > Print Spooler = Disabled (or Stop-Service Spooler; Set-Service Spooler -StartupType Disabled). Printer pruning in the directory stops with it: move that task to a print server.'

New-Check -Id 'SEC-ADC-03' -Console 'Security' -Group 'Domain controller' -Title 'The domain controller serves the directory only' -Ism 'ISM-1926' -Severity 'Medium' -Needs 'Directory', 'Inventory' -Applies 'dc' `
    -Why 'Every other role on a domain controller is more code running where the keys of the domain are kept, and more people with a reason to log on there.' `
    -Test {
        param($c)
        $features = @($c.Inventory.Features | ForEach-Object { [string]$_ })
        if ($features.Count -eq 0 -or @(@($features) -match '^ERROR\|').Count -gt 0) { return (Warn 'the roles and features of the server were not read') }
        $other = [ordered]@{ 'Web-Server' = 'Web Server (IIS)'; 'DHCP' = 'DHCP Server'; 'Print-Services' = 'Print and Document Services'; 'RDS-RD-Server' = 'Remote Desktop Session Host'; 'Hyper-V' = 'Hyper-V'
            'ADCS-Cert-Authority' = 'Certification Authority'; 'ADFS-Federation' = 'Federation Services'; 'WDS' = 'Windows Deployment Services'; 'Fax' = 'Fax Server'; 'NPAS' = 'Network Policy Server'
            'UpdateServices' = 'WSUS'; 'SMTP-Server' = 'SMTP Server'; 'FS-NFS-Service' = 'Server for NFS'; 'Web-Ftp-Server' = 'FTP Server'; 'RemoteAccess' = 'Remote Access'; 'ADLDS' = 'Lightweight Directory Services'; 'ADRMS' = 'Rights Management Services' }
        $found = @()
        foreach ($k in $other.Keys) { if (@($features | Where-Object { $_ -like ($k + '|*') }).Count -gt 0) { $found += $other[$k] } }
        if ($found.Count -eq 0) { return (Pass ('{0} roles and features installed, none of them another server role' -f $features.Count)) }
        return (Warn ('{0} other role(s) on this domain controller - each to move, or to record with its reason' -f $found.Count) -Items $found)
    } -Fix 'Move the role to a member server and remove it here (Remove-WindowsFeature, in a change window). DNS and the file services SYSVOL needs belong to a domain controller; a role that must stay is recorded in the tailoring, with its reason.'

New-Check -Id 'SEC-ADC-04' -Console 'Security' -Group 'Domain controller' -Title 'Certificates are mapped to accounts strongly' -Ism 'ISM-1943' -Severity 'Medium' -Needs 'Directory' -Applies 'dc' `
    -Why 'A certificate that names its account only by a name the requester chose lets one account log on as another. Strong mapping ties the certificate to the account''s identifier.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'Local'
        if ($l.Unread) { return (Warn ('the certificate mapping setting: ' + $l.Unread)) }
        $v = [string]$c.S['AD.CertMapping']
        if ($v -eq '2') { return (Pass 'strong certificate mapping is enforced (StrongCertificateBindingEnforcement = 2)') }
        if ($v -eq '1') { return (Warn 'strong certificate mapping is in compatibility mode (StrongCertificateBindingEnforcement = 1): a weakly mapped certificate still logs on') }
        if ($v -eq '0') { return (Fail 'strong certificate mapping is switched off (StrongCertificateBindingEnforcement = 0)') }
        return (Pass 'StrongCertificateBindingEnforcement is not set: Windows enforces strong mapping by itself from the February 2025 security update on')
    } -Fix 'Remove the value StrongCertificateBindingEnforcement under HKLM\SYSTEM\CurrentControlSet\Services\Kdc on every domain controller (or set it to 2) once event 39 in the System log no longer names a certificate in use (Microsoft KB 5014754).'

# ---------------------------------------------------------------------
#  SECURITY: THE DOMAIN (SEC-AD-01..29), judged once, on its PDC emulator
# ---------------------------------------------------------------------
function New-DirectoryListCheck {
    # One "this list must be empty" check of the domain (or, with -Applies 'forest', of the forest)
    param([string]$Id, [string]$Title, [string[]]$Ism, [string]$Severity, [hashtable]$Data, [string]$Why, [string]$Fix, [int]$ML = 0, [string]$Applies = 'domain')
    New-Check -Id $Id -Console 'Security' -Group 'Domain' -Title $Title -Ism $Ism -ML $ML -Severity $Severity -Needs 'Directory' -Applies $Applies -Data $Data -Test $script:DirectoryListTest -Why $Why -Fix $Fix
}

New-DirectoryListCheck 'SEC-AD-01' 'Every account needs Kerberos pre-authentication' 'ISM-1836' 'High' @{ Key = 'NoPreAuth'; What = 'the accounts without pre-authentication'; None = 'no enabled user account is excused from Kerberos pre-authentication'; Found = '{0} enabled user account(s) do not need Kerberos pre-authentication' } `
    'For such an account anybody can ask the domain controller for a ticket encrypted with its password, and guess the password offline (AS-REP roasting).' `
    'Active Directory Users and Computers > the account > Account > untick "Do not require Kerberos preauthentication".'

New-Check -Id 'SEC-AD-02' -Console 'Security' -Group 'Domain' -Title 'No password is stored with reversible encryption' -Ism 'ISM-1840' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'A password stored with reversible encryption can be read back from the directory by whoever copies it: it is the password itself, not a hash.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'Reversible'
        if ($l.Unread) { return (Warn ('the accounts with reversible encryption: ' + $l.Unread)) }
        $policy = ([string]$c.S['AD.ReversiblePolicy'] -eq 'True')
        if ($policy) { return (Fail ('the domain''s password policy stores EVERY password with reversible encryption; {0} account(s) are set so themselves{1}' -f $l.Count, $l.More) -Items $l.Names) }
        if ($l.Count -gt 0) { return (Fail ('{0} user account(s) store their password with reversible encryption{1}' -f $l.Count, $l.More) -Items $l.Names) }
        return (Pass 'neither the domain''s password policy nor any user account stores a password with reversible encryption')
    } -Fix 'Default Domain Policy: Password Policy > Store passwords using reversible encryption = Disabled; on each account untick "Store password using reversible encryption" - then change its password, the readable copy stays until then.'

New-DirectoryListCheck 'SEC-AD-03' 'Every enabled account must have a password' @('ISM-0421', 'ISM-1557', 'ISM-0422') 'High' @{ Key = 'NoPassword'; What = 'the accounts that need no password'; None = 'no enabled user account is marked "password not required"'; Found = '{0} enabled user account(s) are marked "password not required": the password policy does not apply to them, the password may be empty' } `
    'An account marked "password not required" may have an empty password whatever the domain''s policy says.' `
    'For each account: clear the flag (in an elevated console: net user <name> /domain /passwordreq:yes), then give it a password that meets the policy.'

New-DirectoryListCheck 'SEC-AD-04' 'The userPassword attribute is not used' 'ISM-1838' 'Medium' @{ Key = 'UserPassword'; What = 'the accounts with a userPassword value'; None = 'no user account has a value in userPassword or unixUserPassword'; Found = '{0} user account(s) carry a value in userPassword or unixUserPassword' } `
    'userPassword and unixUserPassword are ordinary attributes: whatever an application wrote there - often the password in clear or a weak hash - is readable like a telephone number.' `
    'Clear the attribute on each account (Attribute Editor) and stop the application that writes it; change the password of every account that had one there.'

New-DirectoryListCheck 'SEC-AD-05' 'No password is written into an account''s description' 'ISM-1839' 'Medium' @{ Key = 'PasswordText'; What = 'the accounts whose description mentions a password'; Verdict = 'Warn'; None = 'no user account mentions a password in its description, notes or comment'; Found = '{0} user account(s) mention "pass" or "pwd" in the description, notes or comment - to read: every account of the domain can' } `
    'The description and the notes of an account can be read by every account of the domain. A password noted there for convenience is public.' `
    'Read each one; where it is a password, remove it and change the password. A description that only says "password never expires" is recorded in the tailoring.'

New-DirectoryListCheck 'SEC-AD-06' 'Only service accounts carry a service principal name' @('ISM-1832', 'ISM-1932') 'Medium' @{ Key = 'SpnUsers'; What = 'the user accounts with a service principal name'; Verdict = 'Warn'; None = 'no enabled user account carries a service principal name'; Found = '{0} enabled user account(s) carry a service principal name - each to confirm as a service account that still needs it' } `
    'For an account with a service principal name any domain account can ask for a ticket encrypted with its password and guess it offline (Kerberoasting). Each one is a target: the fewer, and the longer their passwords, the better.' `
    'A person''s account: remove the name (setspn -D). A service: move it to a group Managed Service Account, whose password is 240 random characters; until then a password of 30 characters or more (ISM-1795).'

New-DirectoryListCheck 'SEC-AD-07' 'Service accounts with a service principal name use AES' 'ISM-2010' 'Medium' @{ Key = 'SpnNoAes'; What = 'the service accounts without AES'; None = 'every enabled user account with a service principal name is set for AES'; Found = '{0} enabled account(s) with a service principal name are not set for AES: their tickets are encrypted with RC4' } `
    'A ticket encrypted with RC4 is guessed offline many times faster than one encrypted with AES.' `
    'Active Directory Users and Computers > the account > Account > tick "This account supports Kerberos AES 128 bit encryption" and "... AES 256 bit encryption", then change its password once (the AES keys are made at a password change).'

New-DirectoryListCheck 'SEC-AD-08' 'No service principal name is registered twice' 'ISM-1834' 'Medium' @{ Key = 'DuplicateSpn'; What = 'the duplicate service principal names'; None = 'no service principal name is registered on two accounts of the domain'; Found = '{0} service principal name(s) are registered on more than one account' } `
    'With a name on two accounts Kerberos cannot tell which one the service runs as: the logon fails or falls back to NTLM, and a ticket may be issued for the wrong account.' `
    'setspn -X lists them; setspn -D <name> <account> removes the name from the account that does not run the service.'

New-Check -Id 'SEC-AD-09' -Console 'Security' -Group 'Domain' -Title 'No user account is trusted for unconstrained delegation' -Ism 'ISM-1843' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'A service trusted for unconstrained delegation receives the full logon of everybody who uses it - an administrator''s included - and may act as them anywhere.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'UserDelegation'
        if ($l.Unread) { return (Warn ('the accounts trusted for delegation: ' + $l.Unread)) }
        if ($l.Count -eq 0) { return (Pass 'no enabled user account is trusted for unconstrained delegation') }
        $bare = Get-DirectoryFact -S $c.S -Key 'UserDelegationNoSpn'
        if (-not $bare.Unread -and $bare.Count -gt 0) { return (Fail ('{0} enabled user account(s) trusted for unconstrained delegation, {1} of them without a service principal name: no service can be using it ({2}){3}' -f $l.Count, $bare.Count, ($bare.Names -join ', '), $l.More) -Items $l.Names) }
        return (Warn ('{0} enabled user account(s) trusted for unconstrained delegation - each to review once a year' -f $l.Count) -Items $l.Names)
    } -Fix 'Active Directory Users and Computers > the account > Delegation > "Do not trust this user for delegation" - or, where the service needs it, "Trust this user for delegation to specified services only". An account without a service principal name: remove the trust.'

New-DirectoryListCheck 'SEC-AD-10' 'No computer besides the domain controllers is trusted for unconstrained delegation' 'ISM-1935' 'High' @{ Key = 'ComputerDelegation'; What = 'the computers trusted for unconstrained delegation'; None = 'no computer account besides the domain controllers is trusted for unconstrained delegation'; Found = '{0} computer account(s) besides the domain controllers are trusted for unconstrained delegation' } `
    'Whoever takes such a server over can make a domain controller authenticate to it, keep its ticket and act as the domain controller.' `
    'Active Directory Users and Computers > the computer > Delegation > "Do not trust this computer for delegation", or delegation to specified services only.'

New-DirectoryListCheck 'SEC-AD-11' 'No computer besides the domain controllers is trusted for delegation to services' 'ISM-1844' 'Medium' @{ Key = 'ComputerDelegationToServices'; What = 'the computers trusted for delegation to services'; None = 'no computer account besides the domain controllers is trusted for delegation to services'; Found = '{0} computer account(s) besides the domain controllers are trusted for delegation to services' } `
    'A server trusted for delegation to a service may act there as any account that uses it - with protocol transition, as any account at all.' `
    'Remove the delegation where no application needs it; where one does, record it in the tailoring with the service it reaches and its owner.'

New-DirectoryListCheck 'SEC-AD-12' 'No account carries a SID history' @('ISM-1936', 'ISM-1937') 'High' @{ Key = 'SidHistory'; What = 'the accounts with a SID history'; None = 'no user account has a value in sIDHistory'; Found = '{0} user account(s) have a value in sIDHistory' } `
    'sIDHistory gives an account the rights of another account or group without being a member of anything - nothing that lists group memberships shows it. Outside a migration it is a hiding place.' `
    'After a migration: remove the values (Set-ADUser <name> -Remove @{sIDHistory=...} from a management PC). Found outside one: treat it as an incident.'

New-Check -Id 'SEC-AD-13' -Console 'Security' -Group 'Domain' -Title 'Few accounts own the domain' -Ism 'ISM-1939' -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'Every member of Domain Admins, Enterprise Admins, Schema Admins or Administrators can read every password hash of the domain. Each one is a way in.' `
    -Test {
        param($c)
        $p = Get-DirectoryPrivileged -S $c.S
        if ($p.Unread) { return (Warn ('the privileged accounts: ' + $p.Unread)) }
        $max = [int]$script:Config.DomainAdminsMax
        $own = @($p.Accounts | Where-Object { $_.High -and $_.Enabled })
        $items = @($own | ForEach-Object { '{0} ({1})' -f $_.Sam, ($_.Groups -join ', ') })
        $groups = @((Get-DirectoryFact -S $c.S -Key 'PrivGroups').Names | ForEach-Object { $f = $_ -split '\|'; if ($f.Count -ge 3 -and $f[1] -eq 'high') { '{0}: {1}' -f $f[0], $f[2] } })
        $foreign = Get-DirectoryFact -S $c.S -Key 'PrivForeign'
        if (-not $foreign.Unread -and $foreign.Count -gt 0) { $items += @($foreign.Names | ForEach-Object { $_ + ' (from another domain: its members are judged there)' }) }
        $text = ('{0} enabled account(s) in the groups that own the domain ({1}){2}' -f $own.Count, ($groups -join '; '), $p.More)
        if ($own.Count -gt $max) { return (Warn ($text + (' - more than {0}' -f $max)) -Items $items) }
        return (Pass $text -Items $items)
    } -Fix 'Take out every account that does not administer the directory itself: delegate the task instead (reset passwords, join computers, manage one OU). Schema Admins and Enterprise Admins are empty except while they are needed.'

New-Check -Id 'SEC-AD-14' -Console 'Security' -Group 'Domain' -Title 'No service account owns the domain' -Ism 'ISM-1940' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'A service account''s password sits on every server the service runs on, and seldom changes. In Domain Admins it makes each of those servers a way to the whole domain.' `
    -Test {
        param($c)
        $p = Get-DirectoryPrivileged -S $c.S
        if ($p.Unread) { return (Warn ('the privileged accounts: ' + $p.Unread)) }
        $bad = @($p.Accounts | Where-Object { $_.High -and $_.Enabled -and $_.Class -eq 'service' })
        if ($bad.Count -eq 0) { return (Pass ('no service account in the groups that own the domain' + $p.More)) }
        return (Fail ('{0} service account(s) in the groups that own the domain{1}' -f $bad.Count, $p.More) -Items @($bad | ForEach-Object { '{0} ({1})' -f $_.Sam, ($_.Groups -join ', ') }))
    } -Fix 'Give the service the rights it needs and no more (a delegated permission, local administrator on its own servers), then take it out of the group. A backup or monitoring product that asks for Domain Admins has a documented lesser way.'

New-Check -Id 'SEC-AD-15' -Console 'Security' -Group 'Domain' -Title 'No computer account is in a privileged group' -Ism 'ISM-1941', 'ISM-1942' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'A computer account in a privileged group makes its local SYSTEM a domain administrator: whoever becomes an administrator of that one computer has the domain.' `
    -Test {
        param($c)
        $p = Get-DirectoryPrivileged -S $c.S
        if ($p.Unread) { return (Warn ('the privileged accounts: ' + $p.Unread)) }
        $bad = @($p.Accounts | Where-Object { $_.Class -eq 'computer' })
        $all = Get-DirectoryFact -S $c.S -Key 'DomainComputersIn'
        $items = @($bad | ForEach-Object { '{0} ({1})' -f $_.Sam, ($_.Groups -join ', ') })
        if (-not $all.Unread -and $all.Count -gt 0) { return (Fail ('the Domain Computers group is a member of: {0} - every computer of the domain is privileged' -f ($all.Names -join ', ')) -Items $items) }
        if ($bad.Count -gt 0) { return (Fail ('{0} computer account(s) in a privileged group{1}' -f $bad.Count, $p.More) -Items $items) }
        return (Pass ('no computer account, and not the Domain Computers group, is in a privileged group' + $p.More))
    } -Fix 'Remove the computer account from the group. A product that put it there (older Exchange versions did) has an update that no longer needs it.'

New-Check -Id 'SEC-AD-16' -Console 'Security' -Group 'Domain' -Title 'Privileged accounts are in Protected Users' -Ism 'ISM-1620' -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'A member of Protected Users cannot log on with NTLM, with DES or RC4, or be delegated, and its ticket lasts four hours: what a stolen administrator password is usually used with stops working.' `
    -Test {
        param($c)
        $p = Get-DirectoryPrivileged -S $c.S
        if ($p.Unread) { return (Warn ('the privileged accounts: ' + $p.Unread)) }
        # the built-in Administrator is the break glass account: Microsoft keeps it out, so a mistake in the group locks nobody out
        $people = @($p.Accounts | Where-Object { $_.Enabled -and $_.Class -eq 'user' -and $_.Rid -ne '500' -and $_.Sam -ne 'krbtgt' })
        $out = @($people | Where-Object { -not $_.Protected })
        if ($people.Count -eq 0) { return (Pass ('no privileged user account besides the built-in Administrator' + $p.More)) }
        if ($out.Count -eq 0) { return (Pass ('{0} privileged user account(s), each a member of Protected Users{1}' -f $people.Count, $p.More)) }
        if ([string]$c.S['AD.ProtectedUsersGroup'] -eq 'False') { return (Fail ('the domain has no Protected Users group yet (it appears when a domain controller on Windows Server 2012 R2 or later holds the PDC emulator role): {0} privileged user account(s) are without its protection{1}' -f $people.Count, $p.More) -Items @($out | ForEach-Object { '{0} ({1})' -f $_.Sam, ($_.Groups -join ', ') })) }
        return (Fail ('{0} of {1} privileged user account(s) are not in Protected Users{2}' -f $out.Count, $people.Count, $p.More) -Items @($out | ForEach-Object { '{0} ({1})' -f $_.Sam, ($_.Groups -join ', ') }))
    } -Fix 'Add the administrators'' accounts to Protected Users, one first: they must log on with Kerberos (by name, not by address) and their passwords must have been changed since the domain reached the Windows Server 2008 level. Service accounts and computers do not belong in the group.'

New-Check -Id 'SEC-AD-17' -Console 'Security' -Group 'Domain' -Title 'Privileged accounts cannot be delegated' -Ism 'ISM-1835' -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'A privileged account that may be delegated leaves its logon with every service trusted for delegation it touches.' `
    -Test {
        param($c)
        $p = Get-DirectoryPrivileged -S $c.S
        if ($p.Unread) { return (Warn ('the privileged accounts: ' + $p.Unread)) }
        $people = @($p.Accounts | Where-Object { $_.Enabled -and $_.Class -ne 'computer' -and $_.Sam -ne 'krbtgt' })
        $open = @($people | Where-Object { -not $_.NoDelegation -and -not $_.Protected })
        if ($people.Count -eq 0) { return (Pass ('no enabled privileged account' + $p.More)) }
        if ($open.Count -eq 0) { return (Pass ('{0} privileged account(s), each marked "sensitive and cannot be delegated" or a member of Protected Users{1}' -f $people.Count, $p.More)) }
        return (Fail ('{0} of {1} privileged account(s) may be delegated{2}' -f $open.Count, $people.Count, $p.More) -Items @($open | ForEach-Object { [string]$_.Sam }))
    } -Fix 'Active Directory Users and Computers > the account > Account > tick "Account is sensitive and cannot be delegated" - the built-in Administrator included.'

New-Check -Id 'SEC-AD-18' -Console 'Security' -Group 'Domain' -Title 'Privileged accounts are in use (an inactive one is disabled)' -Ism 'ISM-1648' -ML 2 -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'A privileged account nobody logs on with is access nobody would miss - or notice being used. The ISM disables privileged access after 45 days of inactivity.' `
    -Test {
        param($c)
        $p = Get-DirectoryPrivileged -S $c.S
        if ($p.Unread) { return (Warn ('the privileged accounts: ' + $p.Unread)) }
        $days = [int]$script:Config.DomainAccountInactiveDays
        $people = @($p.Accounts | Where-Object { $_.Enabled -and $_.Class -ne 'computer' -and $_.Rid -ne '500' -and $_.Sam -ne 'krbtgt' })
        $idle = @()
        foreach ($a in $people) {
            if ($null -ne $a.LogonDays) { if ($a.LogonDays -gt $days) { $idle += ('{0}: not logged on for {1} days' -f $a.Sam, $a.LogonDays) } }
            elseif ($null -eq $a.PasswordDays -or $a.PasswordDays -gt $days) { $idle += ('{0}: never logged on' -f $a.Sam) }
        }
        if ($people.Count -eq 0) { return (Pass ('no enabled privileged account besides the built-in Administrator' + $p.More)) }
        if ($idle.Count -eq 0) { return (Pass ('{0} enabled privileged account(s), each used within {1} days{2}' -f $people.Count, $days, $p.More)) }
        return (Warn ('{0} of {1} enabled privileged account(s) inactive for more than {2} days{3}' -f $idle.Count, $people.Count, $days, $p.More) -Items $idle)
    } -Fix 'Disable the account and take it out of its groups. The directory keeps the last logon to within two weeks (it copies it between domain controllers only so often): an account at 50 days may have been used at 45.'

New-DirectoryListCheck 'SEC-AD-19' 'User accounts are in use (an inactive one is disabled)' 'ISM-1404' 'Low' @{ Key = 'InactiveUsers'; What = 'the inactive accounts'; Verdict = 'Warn'; DaysKey = 'InactiveDays'; None = 'every enabled user account logged on within {1} days'; Found = '{0} enabled user account(s) have not logged on for more than {1} days' } `
    'An enabled account that has not logged on for weeks belongs to somebody who left, a project that ended or a service that was switched off. The ISM disables unprivileged access after 45 days of inactivity.' `
    'Disable the account; delete it once nothing has missed it. The directory keeps the last logon to within two weeks. An account that only ever logs on to a web application or a mailbox is recorded in the tailoring.'

New-DirectoryListCheck 'SEC-AD-20' 'A disabled account holds no group membership' 'ISM-1845' 'Low' @{ Key = 'DisabledInGroups'; What = 'the disabled accounts with group memberships'; None = 'no disabled user account is a member of a group (Guest, krbtgt and DefaultAccount aside)'; Found = '{0} disabled user account(s) are still members of groups' } `
    'A disabled account that keeps its groups gets its access back the moment somebody enables it - by mistake, or on purpose.' `
    'Remove the account from every group when it is disabled (its primary group, Domain Users, stays). Note the groups in the ticket if the person may return.'

New-Check -Id 'SEC-AD-21' -Console 'Security' -Group 'Domain' -Title 'Pre-Windows 2000 Compatible Access holds no user account' -Ism 'ISM-1846' -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'The group may read every user and group of the domain. With Everyone or Anonymous Logon in it, a computer that never logged on can list the domain.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'PreWin2000'
        if ($l.Unread) { return (Warn ('the group''s members: ' + $l.Unread)) }
        $rows = @($l.Names | ForEach-Object { $f = $_ -split '\|'; [pscustomobject]@{ Name = $f[0]; Kind = [string]$f[1] } })
        $items = @($rows | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Kind })
        $open = @($rows | Where-Object { $_.Name -in 'Everyone', 'Anonymous Logon' })
        $users = @($rows | Where-Object { $_.Kind -eq 'user' })
        if ($open.Count -gt 0) { return (Fail ('the group holds {0}: the domain can be listed without an account' -f (@($open | ForEach-Object { $_.Name }) -join ' and ')) -Items $items) }
        if ($users.Count -gt 0) { return (Fail ('the group holds {0} user account(s)' -f $users.Count) -Items $items) }
        if ($rows.Count -eq 0) { return (Pass 'the group is empty') }
        return (Pass ('the group holds no user account ({0} member(s))' -f $rows.Count) -Items $items)
    } -Fix 'Remove the user accounts, Everyone and Anonymous Logon from the group (Builtin container). Authenticated Users is what Windows puts there for a new domain; an application from before Windows 2000 is the only thing that needs more.'

New-Check -Id 'SEC-AD-22' -Console 'Security' -Group 'Domain' -Title 'Ordinary accounts cannot add computers to the domain' -Ism 'ISM-1841' -Severity 'Medium' -Needs 'Directory' -Applies 'domain' `
    -Why 'A computer account an ordinary user created is one the user controls: the first step of several ways to become an administrator of another server (delegation set on a computer account).' `
    -Test {
        param($c)
        $q = Get-DirectoryFact -S $c.S -Key 'MachineAccountQuota'
        if ($q.Unread) { return (Warn ('the machine account quota: ' + $q.Unread)) }
        if ($q.Value -eq '0') { return (Pass 'ms-DS-MachineAccountQuota is 0: only accounts given the right can add a computer') }
        return (Fail ('ms-DS-MachineAccountQuota is {0}: every account of the domain may add that many computers' -f $(if ($q.Value) { $q.Value } else { 'not set (the default of 10 applies)' })))
    } -Fix 'Set ms-DS-MachineAccountQuota on the domain object to 0 (Attribute Editor, or ADSI Edit) and give the right to join computers to a dedicated service account on the OU the computers go into (ISM-1842).'

New-Check -Id 'SEC-AD-23' -Console 'Security' -Group 'Domain' -Title 'SID filtering is on for every trust to another forest' -Ism 'ISM-1931' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'Without SID filtering an administrator of the trusted domain can put any identifier of this domain into a ticket - Domain Admins included - and this domain believes it.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'Trusts'
        if ($l.Unread) { return (Warn ('the trusts: ' + $l.Unread)) }
        if ($l.Count -eq 0) { return (Pass 'the domain has no trust') }
        $bad = @(); $items = @(); $outside = 0
        foreach ($row in $l.Names) {
            $f = $row -split '\|'; if ($f.Count -lt 4) { continue }
            $a = 0; $null = [int]::TryParse($f[3], [ref]$a)
            if ($a -band 32) { $items += ('{0}: within this forest (SID filtering does not apply)' -f $f[0]); continue }
            $outside++
            if ($a -band 8) { if ($a -band 64) { $bad += $f[0]; $items += ('{0}: forest trust, SID history allowed across it' -f $f[0]) } else { $items += ('{0}: forest trust, filtered' -f $f[0]) }; continue }
            if ($a -band 4) { $items += ('{0}: external trust, filtered (quarantined)' -f $f[0]) } else { $bad += $f[0]; $items += ('{0}: external trust, NOT filtered' -f $f[0]) }
        }
        if ($bad.Count -gt 0) { return (Fail ('{0} trust(s) without SID filtering: {1}' -f $bad.Count, ($bad -join ', ')) -Items $items) }
        if ($outside -eq 0) { return (Pass ('{0} trust(s), all to domains of this forest' -f $l.Count) -Items $items) }
        return (Pass ('{0} trust(s) to outside this forest, each filtered' -f $outside) -Items $items)
    } -Fix 'netdom trust <this domain> /domain:<the other> /quarantine:yes (an external trust), or /enablesidhistory:no (a forest trust). During a migration that needs SID history: record it in the tailoring with its end date.'

New-Check -Id 'SEC-AD-24' -Console 'Security' -Group 'Domain' -Title 'The KRBTGT password is changed' -Ism 'ISM-1847' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'Every Kerberos ticket of the domain is signed with the KRBTGT password. Whoever once copied the directory can sign tickets of their own for as long as that password stays - years, if nobody changes it.' `
    -Test {
        param($c)
        $k = Get-DirectoryFact -S $c.S -Key 'Krbtgt.PasswordDays'
        if ($k.Unread) { return (Warn ('the age of the KRBTGT password: ' + $k.Unread)) }
        $max = [int]$script:Config.KrbtgtPasswordMaxAgeDays
        $days = 0; if (-not [int]::TryParse($k.Value, [ref]$days)) { return (Warn 'the age of the KRBTGT password was not read') }
        if ($days -gt $max) { return (Fail ('the KRBTGT password was last changed {0} days ago (to change within {1})' -f $days, $max)) }
        return (Pass ('the KRBTGT password was last changed {0} days ago' -f $days))
    } -Fix 'Change it twice, with time between for every domain controller to replicate (at least the longest ticket lifetime, ten hours by default): Microsoft''s New-KrbtgtKeys.ps1 does it safely, or reset the krbtgt account''s password in Active Directory Users and Computers - once, wait a day, once more.'

New-Check -Id 'SEC-AD-25' -Console 'Security' -Group 'Domain' -Title 'The domain''s built-in Administrator password is changed' -Ism 'ISM-1953' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'The built-in Administrator of the domain is its break glass account: never locked out, known by its identifier in every domain. A password set years ago is known to everybody who administered the domain since.' `
    -Test {
        param($c)
        $a = Get-DirectoryFact -S $c.S -Key 'Admin500'
        if ($a.Unread) { return (Warn ('the built-in Administrator of the domain: ' + $a.Unread)) }
        $f = $a.Value -split '\|'
        if ($f.Count -lt 4) { return (Warn 'the built-in Administrator of the domain was not read') }
        $max = [int]$script:Config.LocalAdminPasswordMaxAgeDays
        $used = 'never logged on'; if ($f[3] -ne '') { $used = ('last logon {0} day(s) ago' -f $f[3]) }
        $text = ('{0} ({1}, {2})' -f $f[0], $(if ($f[1] -eq '1') { 'enabled' } else { 'disabled' }), $used)
        $days = 0; if (-not [int]::TryParse($f[2], [ref]$days)) { return (Warn ($text + ': the age of its password was not read')) }
        if ($days -gt $max -and $f[1] -ne '1') { return (Warn ('{0}: its password was last changed {1} days ago (to change within {2}) - disabled, so nobody logs on with it until an administrator enables it' -f $text, $days, $max)) }
        if ($days -gt $max) { return (Fail ('{0}: its password was last changed {1} days ago (to change within {2})' -f $text, $days, $max)) }
        return (Pass ('{0}: its password was last changed {1} days ago' -f $text, $days))
    } -Fix 'Give it a new random password of 30 characters or more (ISM-1795), kept sealed in the password manager or the safe, and use it for nothing but an emergency: its last logon above should be long ago.'

New-DirectoryListCheck 'SEC-AD-26' 'Computer accounts change their password' 'ISM-1955' 'Low' @{ Key = 'StaleComputers'; What = 'the computer accounts with an old password'; DaysKey = 'ComputerPasswordDays'; None = 'every enabled computer account changed its password within {1} days'; Found = '{0} enabled computer account(s) have not changed their password for more than {1} days' } `
    'A computer changes its own password every 30 days. One that has not is switched off, gone, or told not to - and its account still logs on with the old password.' `
    'A computer that is gone: disable its account, delete it later. One that is running: GPO Security Options > Domain member: Disable machine account password changes = Disabled, and Maximum machine account password age = 30.'

New-Check -Id 'SEC-AD-27' -Console 'Security' -Group 'Domain' -Title 'Only domain controllers may replicate the directory''s secrets' -Ism 'ISM-1934', 'ISM-1933' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'The right "Replicating Directory Changes All" on the domain hands out every password hash on request (DCSync). Besides the domain controllers and the administrators'' groups nobody needs it - and nothing lists who has it.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'DcSync'
        if ($l.Unread) { return (Warn ('the replication permissions: ' + $l.Unread)) }
        if ($l.Count -eq 0) { return (Pass 'only the domain controllers and the administrators'' groups hold the right to replicate the directory''s secrets') }
        # nearly everybody: the collector says so by identifier (the fourth field); a result without it is judged by name
        $rows = @($l.Names | ForEach-Object { $f = @($_ -split '\|'); [pscustomobject]@{ Name = $f[0]; Kind = [string]$f[1]; Spn = ([string]$f[2] -eq '1'); Broad = $(if ($f.Count -ge 4) { [string]$f[3] -eq '1' } else { $script:BroadPrincipals -contains ($f[0] -split '\\')[-1] }) } })
        $items = @($rows | ForEach-Object { '{0} ({1}{2})' -f $_.Name, $_.Kind, $(if ($_.Spn) { ', with a service principal name' } else { '' }) })
        $spn = @($rows | Where-Object { $_.Spn })
        $broad = @($rows | Where-Object { $_.Broad })
        if ($broad.Count -gt 0) { return (Fail ('the right to replicate the directory''s secrets is held by {0}' -f (@($broad | ForEach-Object { $_.Name }) -join ', ')) -Items $items) }
        if ($spn.Count -gt 0) { return (Fail ('{0} account(s) with a service principal name may replicate the directory''s secrets: {1}' -f $spn.Count, (@($spn | ForEach-Object { $_.Name }) -join ', ')) -Items $items) }
        return (Warn ('{0} holder(s) besides the domain controllers and the administrators'' groups - each to review every six months' -f $rows.Count) -Items $items)
    } -Fix 'Active Directory Users and Computers > the domain > Properties > Security > Advanced: remove "Replicating Directory Changes All" from every holder that is not a directory synchronisation service you run. Such a service''s account has no service principal name and a long random password.'

New-Check -Id 'SEC-AD-28' -Console 'Security' -Group 'Domain' -Title 'Domain Computers cannot change the directory' -Ism 'ISM-1938' -Severity 'High' -Needs 'Directory' -Applies 'domain' `
    -Why 'A write permission for the Domain Computers group is one for the local SYSTEM of every workstation and server: any administrator of one computer may change those objects.' `
    -Test {
        param($c)
        $l = Get-DirectoryFact -S $c.S -Key 'DomainComputersWrite'
        if ($l.Unread) { return (Warn ('the permissions of Domain Computers: ' + $l.Unread)) }
        $seen = [string]$c.S['AD.DomainComputersWrite.Scanned']
        if ($l.Count -gt 0) { return (Fail ('Domain Computers may change {0} of the {1} containers read{2}' -f $l.Count, $seen, $l.More) -Items $l.Names) }
        return (Pass ('Domain Computers holds no write permission on the domain, its organisational units, the Builtin container and AdminSDHolder ({0} containers read; the single objects in them are not){1}' -f $seen, $l.More))
    } -Fix 'Active Directory Users and Computers (Advanced Features) > the container > Properties > Security > Advanced: remove the entry for Domain Computers, or cut it down to Read.'

New-DirectoryListCheck 'SEC-AD-29' 'No password in Group Policy Preferences' @('ISM-1829', 'ISM-1930') 'High' @{ Key = 'GppPasswords'; What = 'the Group Policy Preferences files'; None = 'no Group Policy Preferences file in SYSVOL holds a password'; Found = '{0} Group Policy Preferences file(s) in SYSVOL hold a password (cpassword): every account of the domain can read and decrypt it' } `
    'A password set through Group Policy Preferences - a local account, a mapped drive, a service, a scheduled task - is written into SYSVOL encrypted with a key Microsoft published. Every account of the domain can read it.' `
    'Delete the preference item (or the whole GPO folder it is in) and change the password it held, everywhere that password is used. Local administrator passwords belong to Windows LAPS.'

# ---------------------------------------------------------------------
#  SECURITY: THE FOREST'S CERTIFICATE TEMPLATES (SEC-AD-30..31), judged on the PDC emulator of the root domain
# ---------------------------------------------------------------------
New-Check -Id 'SEC-AD-30' -Console 'Security' -Group 'Domain' -Title 'No certificate template lets the requester name the subject of a logon certificate' -Ism 'ISM-1945', 'ISM-1948' -Severity 'High' -Needs 'Directory' -Applies 'forest' `
    -Why 'A published template that lets the requester supply the subject, issues certificates good for logon, needs no approval and is open to every account gives each of them a certificate in the name of a domain administrator.' `
    -Test {
        param($c)
        $t = Get-DirectoryFact -S $c.S -Key 'Templates'
        if ($t.Unread) { return (Warn ('the certificate templates: ' + $t.Unread)) }
        $cas = Get-DirectoryFact -S $c.S -Key 'Cas'
        if (-not $cas.Unread -and $cas.Count -eq 0) { return (NotApplicable 'no certification authority is published in this forest') }
        $risky = Get-DirectoryFact -S $c.S -Key 'TemplatesRisky'; $subject = Get-DirectoryFact -S $c.S -Key 'TemplatesSubject'
        if ($risky.Count -gt 0) { return (Fail ('{0} published template(s) let any account name the subject of a logon certificate, without approval: {1}' -f $risky.Count, ($risky.Names -join ', ')) -Items @($risky.Names + $subject.Names)) }
        if ($subject.Count -gt 0) { return (Warn ('{0} published template(s) let the requester supply the subject - each to confirm (approval, who may enrol, what the certificate is good for)' -f $subject.Count) -Items $subject.Names) }
        return (Pass ('{0} template(s) read; no published one lets the requester supply the subject' -f [string]$c.S['AD.Templates.Count']))
    } -Fix 'Certificate Templates console > the template > Subject Name: "Build from this Active Directory information". Where the subject must be supplied (a web server): Issuance Requirements > CA certificate manager approval, and Security > Enroll for the one group that requests it.'

New-DirectoryListCheck 'SEC-AD-31' 'Ordinary accounts cannot change a certificate template' 'ISM-1946' 'High' @{ Key = 'TemplatesWritable'; NeedsKey = 'Cas'; NeedsText = 'no certification authority is published in this forest'; What = 'the permissions of the certificate templates'; None = 'no certificate template can be changed by Everyone, Authenticated Users, Domain Users or Domain Computers'; Found = '{0} certificate template(s) can be changed by Everyone, Authenticated Users, Domain Users or Domain Computers' } `
    'Whoever may change a template can turn it into one that issues logon certificates in any name - and then request one.' `
    'Certificate Templates console > the template > Security: leave Write, Full Control and the owner to the administrators of the certification authority.' 0 'forest'

# Two lists to go through, not verdicts: a certification authority always publishes some templates good for logon (a
# computer's, a domain controller's), and a template that changed may have changed for a good reason.
New-DirectoryListCheck 'SEC-AD-32' 'Published certificate templates good for logon are the ones needed' 'ISM-1947' 'Medium' @{ Key = 'TemplatesLogon'; Verdict = 'Warn'; NeedsKey = 'Cas'; NeedsText = 'no certification authority is published in this forest'; What = 'the usages of the published certificate templates'; None = 'no published certificate template issues certificates good for logon'; Found = '{0} published certificate template(s) issue certificates good for logon - keep the ones needed, take the usage off or unpublish the others' } `
    'A certificate with the client authentication, smart card logon or any-purpose usage logs its holder on to the domain. Every published template that carries one is a way to get such a certificate.' `
    'Certification Authority console > Certificate Templates: delete (unpublish) the templates nobody enrols for. Certificate Templates console > the template > Extensions > Application Policies: remove Client Authentication, Smart Card Logon and Any Purpose where the certificate is not for logon.' 0 'forest'

New-DirectoryListCheck 'SEC-AD-33' 'Certificate templates changed since the last review are reviewed' 'ISM-2131' 'Low' @{ Key = 'TemplatesChanged'; DaysKey = 'TemplatesReviewDays'; Verdict = 'Warn'; NeedsKey = 'Cas'; NeedsText = 'no certification authority is published in this forest'; What = 'the certificate templates changed lately'; None = 'no certificate template was changed in the last {1} days'; Found = '{0} certificate template(s) were changed in the last {1} days - review each for who may enrol, the subject and the usages' } `
    'The ISM has the templates reviewed at least every three months. A template changed since is where a way to a certificate in another name, or open enrolment, comes in.' `
    'Certificate Templates console: open each template named and compare Security, Subject Name, Issuance Requirements and Extensions with what was approved. The check gives the list; that the review took place is yours to record (tailoring).' 0 'forest'
