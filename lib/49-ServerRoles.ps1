# =====================================================================
#  49-ServerRoles.ps1  -  SQL SERVER AND CERTIFICATE SERVICES: HEALTH AND SECURITY
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The Roles collector runs on every server, with every Health check, every Security audit and the self-check.
#  It looks for two roles and reads each from the server itself - the registry, the services, the access lists of
#  folders, the Application log, the certificate store, the web server's configuration file.  Read-only.
#    SQL Server             every instance: its services and their accounts, how it listens, whether connections are
#                           encrypted and with which certificate, its logon mode and logon auditing, who may reach
#                           its data, log and backup folders, its errors and its backups as the Application log
#                           records them.  NOTHING is asked of the instance itself: no connection is made to it.
#    Certificate Services   the certification authority of the server: its service, when the next revocation list
#                           is due, its own certificate, the provider that holds its key, its request flags, its
#                           auditing, who may manage it, web enrolment.
#  A server with neither answers that at once.  The checks: H-SQL-01..03 and H-CA-01..03 (Health), SEC-SQL-01..07
#  and SEC-CA-01..06 (Security), each Security check with its ISM control.  A value that was not read is Amber
#  with the reason, never a pass; on a server without the role the checks are not applicable.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  49-ServerRoles.ps1
#  New 2026-11-18 (owner's ask: what the Health and Security consoles can say of a database server without going
#  into the instance, and of a certification authority).  Certificate Services is read as its configuration is
#  documented: no certification authority was at hand to read one.
#  Field test needed: a certification authority (enterprise and stand-alone, with and without web enrolment, with
#  a hardware security module), a SQL Server with several instances and one listening on chosen addresses.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _____cf_________________________   Date : ____19-11-2026_______
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  ROLES collector - RUNS ON THE SERVER.  "SQL.Key=Value" and "CA.Key=Value" lines, like the Settings collector's
#  (the checks read them from the same table).  SQL.Read and CA.Read say how it went: None (the role is not on the
#  server), OK, or ERROR: <reason>.  A list is rows with ; between them and | between a row's fields.
#    SQL.Inst       name|instance id|version|edition|logon mode|logon audit|listens|named pipes|force encryption|
#                   certificate|hidden|engine service|agent service
#                   (certificate: none, missing, or days left,signature,key bits,subject)
#    SQL.Services   service|state|start type|account           SQL.Dirs   instance|kind|folder|closed, open, missing, not read
#    SQL.Acl        instance|kind|folder|who (rights)          one row for each principal that stands for nearly everybody
#    SQL.Errors     instance|error events|the most frequent|how many of them report damaged pages (823, 824, 825)
#    SQL.Backups    instance|database backups|log backups|failed backups|days since the last database backup
#    CA.Managers    name|identifier|rights                     CA.WebEnrolment   absent, or present|SSL flags|token checking
# ---------------------------------------------------------------------
$script:RemoteRolesScript = {
    param([int]$WindowHours = 24, [int]$BackupDays = 7)
    $ErrorActionPreference = 'Continue'
    $lines = New-Object System.Collections.Generic.List[string]
    $now = Get-Date
    function Add-S([string]$k, $v) { if ($null -eq $v) { $v = '' }; if ($v -is [array]) { $v = ($v -join ';') }; $lines.Add(('{0}={1}' -f $k, (([string]$v) -replace '[\r\n]+', ' '))) }
    function Get-RV([string]$path, [string]$name) { try { return (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name } catch { return $null } }
    function Get-Why($e) { $x = $e.Exception; while ($x.InnerException) { $x = $x.InnerException }; return (([string]$x.Message) -replace '\s+', ' ').Trim() }
    # a value as one field of a row: the characters that separate rows, fields and key from value taken out
    function Get-Field($v) { return (([string]$v) -replace '[|;=\r\n]', ' ').Trim() }
    function Get-SidName([string]$sid) { try { return [string](New-Object System.Security.Principal.SecurityIdentifier $sid).Translate([System.Security.Principal.NTAccount]).Value } catch { return $sid } }
    # everybody, or nearly: Everyone, Authenticated Users, Anonymous, BUILTIN\Users and Guests, a domain's Domain Users, Guests and Computers
    function Test-BroadSid([string]$sid) { return (@('S-1-1-0', 'S-1-5-11', 'S-1-5-7', 'S-1-5-4', 'S-1-5-2', 'S-1-5-32-545', 'S-1-5-32-546') -contains $sid -or $sid -match '^S-1-5-21-.+-(513|514|515)$') }   # the same list as in the Settings and Directory collectors and in Test-BroadPrincipalSid
    function Get-CertState([string]$thumb) {
        # a certificate of the computer's own store by its thumbprint: 'none' (no thumbprint), 'missing', or
        # days left,signature algorithm,key bits,subject
        $t = ($thumb -replace '[^0-9A-Fa-f]', '').ToUpper()
        if (-not $t) { return 'none' }
        $cert = $null; try { $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $t) -ErrorAction Stop } catch { }
        if (-not $cert) { return 'missing' }
        $bits = ''; try { $bits = [string]$cert.PublicKey.Key.KeySize } catch { }
        return ('{0},{1},{2},{3}' -f [int][math]::Floor(($cert.NotAfter - $now).TotalDays), ((Get-Field $cert.SignatureAlgorithm.FriendlyName) -replace ',', ' '), $bits, ((Get-Field $cert.Subject) -replace '\s+', ' '))
    }

    # ---- SQL Server: every instance, from the registry, the services, the folders' access lists and the Application log ----
    $sqlRoot = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server'
    $instNames = $null; try { $instNames = Get-ItemProperty -LiteralPath ($sqlRoot + '\Instance Names\SQL') -ErrorAction Stop } catch { }
    # (the five properties PowerShell adds to a registry key are left out by name: an instance may well be called PS-something)
    $inst = @(); if ($instNames) { $inst = @($instNames.PSObject.Properties | Where-Object { @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider') -notcontains $_.Name -and [string]$_.Value }) }
    if ($inst.Count -eq 0) { Add-S 'SQL.Read' 'None' }
    else {
        try {
            $rows = @(); $dirs = @(); $acl = @(); $aclErr = @(); $errs = @(); $baks = @(); $evErr = @()
            $svc = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Where-Object { [string]$_.Name -match '^(MSSQLSERVER|MSSQL\$.+|SQLSERVERAGENT|SQLAgent\$.+|SQLBrowser)$' } | Sort-Object Name)
            # how far back the Application log reaches: a backup older than that cannot be on record in it
            $reach = ''
            try { $first = @(Get-WinEvent -LogName 'Application' -Oldest -MaxEvents 1 -ErrorAction Stop)[0]; if ($first) { $reach = [int][math]::Floor(($now - $first.TimeCreated).TotalDays) } } catch { }
            foreach ($p in $inst) {
                $name = [string]$p.Name; $id = [string]$p.Value
                $base = $sqlRoot + '\' + $id; $srv = $base + '\MSSQLServer'; $net = $srv + '\SuperSocketNetLib'
                $engine = 'MSSQLSERVER'; $agent = 'SQLSERVERAGENT'
                if ($name -ne 'MSSQLSERVER') { $engine = 'MSSQL$' + $name; $agent = 'SQLAgent$' + $name }
                $version = Get-RV ($base + '\Setup') 'PatchLevel'; if (-not $version) { $version = Get-RV ($base + '\Setup') 'Version' }
                # where it listens: not over TCP, on every address, or on the addresses chosen
                $listen = 'TCP off'
                if ([string](Get-RV ($net + '\Tcp') 'Enabled') -eq '1') {
                    if ([string](Get-RV ($net + '\Tcp') 'ListenOnAllIPs') -ne '0') {
                        $port = ([string](Get-RV ($net + '\Tcp\IPAll') 'TcpPort')).Trim()
                        if (-not $port) { $port = ('dynamic ' + [string](Get-RV ($net + '\Tcp\IPAll') 'TcpDynamicPorts')).Trim() }
                        $listen = 'TCP on every address, port ' + $port
                    } else {
                        $ips = @()
                        foreach ($k in @(Get-ChildItem -LiteralPath ($net + '\Tcp') -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'IP*' -and $_.PSChildName -ne 'IPAll' })) {
                            $ip = Get-ItemProperty -LiteralPath $k.PSPath
                            if ([string]$ip.Enabled -eq '1') { $ips += ('{0} port {1}' -f $ip.IpAddress, $(if ([string]$ip.TcpPort) { $ip.TcpPort } else { 'dynamic' })) }
                        }
                        $listen = 'TCP on ' + $(if ($ips.Count -gt 0) { $ips -join ', ' } else { 'no address' })
                    }
                }
                $rows += ((@($name, $id, $version, (Get-RV ($base + '\Setup') 'Edition'), (Get-RV $srv 'LoginMode'), (Get-RV $srv 'AuditLevel'), $listen, (Get-RV ($net + '\Np') 'Enabled'), (Get-RV $net 'ForceEncryption'), (Get-CertState ([string](Get-RV $net 'Certificate'))), (Get-RV $net 'HideInstance'), $engine, $agent) | ForEach-Object { Get-Field $_ }) -join '|')

                # the folders the instance keeps its data, its logs and its backups in: who, of nearly everybody, may reach them
                $data = [string](Get-RV $srv 'DefaultData')
                if (-not $data) { $dataRoot = [string](Get-RV ($base + '\Setup') 'SQLDataRoot'); if ($dataRoot) { $data = $dataRoot.TrimEnd('\') + '\DATA' } }
                $seen = @{}
                foreach ($pair in @(@('data', $data), @('log', [string](Get-RV $srv 'DefaultLog')), @('backup', [string](Get-RV $srv 'BackupDirectory')))) {
                    $dir = ([string]$pair[1]).TrimEnd('\')
                    if (-not $dir -or $seen.ContainsKey($dir.ToLower())) { continue }
                    $seen[$dir.ToLower()] = $true
                    if (-not (Test-Path -LiteralPath $dir)) { $dirs += ('{0}|{1}|{2}|missing' -f (Get-Field $name), $pair[0], (Get-Field $dir)); continue }
                    try {
                        $open = @()
                        foreach ($rule in @((Get-Acl -LiteralPath $dir -ErrorAction Stop).GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
                            $sid = [string]$rule.IdentityReference.Value
                            if ([string]$rule.AccessControlType -ne 'Allow' -or -not (Test-BroadSid $sid)) { continue }
                            $rights = ([string]$rule.FileSystemRights) -replace ',\s*Synchronize', ''
                            # rights given as generic bits print as a number
                            switch ($rights) { '268435456' { $rights = 'FullControl' } '-536805376' { $rights = 'Modify' } '-1610612736' { $rights = 'ReadAndExecute' } }
                            if ($rights -match '^-?\d+$') { $rights = 'special rights' }
                            $open += ('{0} ({1})' -f (Get-SidName $sid), $rights)
                        }
                        $dirs += ('{0}|{1}|{2}|{3}' -f (Get-Field $name), $pair[0], (Get-Field $dir), $(if ($open.Count -gt 0) { 'open' } else { 'closed' }))
                        foreach ($o in @($open | Select-Object -Unique)) { $acl += ('{0}|{1}|{2}|{3}' -f (Get-Field $name), $pair[0], (Get-Field $dir), (Get-Field $o)) }
                    } catch { $dirs += ('{0}|{1}|{2}|not read' -f (Get-Field $name), $pair[0], (Get-Field $dir)); $aclErr += ('{0}: {1}' -f $dir, (Get-Why $_)) }
                }

                # the Application log: the instance's own errors of the last hours, and its backups of the last days
                try {
                    $found = @()
                    try { $found = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $engine; Level = 1, 2; StartTime = $now.AddHours(-$WindowHours) } -MaxEvents 500 -ErrorAction Stop) } catch { if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
                    $top = @($found | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 5 | ForEach-Object { 'error {0} x {1}' -f $_.Name, $_.Count })
                    $errs += ('{0}|{1}|{2}|{3}' -f (Get-Field $name), $found.Count, ($top -join ', '), @($found | Where-Object { @(823, 824, 825) -contains [int]$_.Id }).Count)
                    # database backups and failures in one read, log backups in another: an instance that backs its logs up every
                    # few minutes writes thousands of those, and they must not push the nightly backup out of what is read
                    $done = @(); $logs = @()
                    try { $done = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $engine; Id = 18264, 3041; StartTime = $now.AddDays(-$BackupDays) } -MaxEvents 5000 -ErrorAction Stop) } catch { if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
                    try { $logs = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = $engine; Id = 18265; StartTime = $now.AddDays(-$BackupDays) } -MaxEvents 2000 -ErrorAction Stop) } catch { if ([string]$_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { throw } }
                    $full = @($done | Where-Object { [int]$_.Id -eq 18264 } | Sort-Object TimeCreated -Descending)
                    $last = ''; if ($full.Count -gt 0) { $last = [int][math]::Floor(($now - $full[0].TimeCreated).TotalDays) }
                    $baks += ('{0}|{1}|{2}|{3}|{4}' -f (Get-Field $name), $full.Count, $logs.Count, @($done | Where-Object { [int]$_.Id -eq 3041 }).Count, $last)
                } catch { $evErr += ('{0}: {1}' -f $name, (Get-Why $_)) }
            }
            Add-S 'SQL.Inst' ($rows -join ';')
            Add-S 'SQL.Services' ((@($svc | ForEach-Object { '{0}|{1}|{2}|{3}' -f (Get-Field $_.Name), $_.State, $_.StartMode, (Get-Field $_.StartName) })) -join ';')
            Add-S 'SQL.Dirs' ($dirs -join ';'); Add-S 'SQL.Acl' ($acl -join ';')
            Add-S 'SQL.Acl.Read' $(if ($aclErr.Count -gt 0) { 'ERROR: ' + (Get-Field ($aclErr -join ' / ')) } else { 'OK' })
            Add-S 'SQL.Errors' ($errs -join ';'); Add-S 'SQL.Backups' ($baks -join ';')
            Add-S 'SQL.Events.Read' $(if ($evErr.Count -gt 0) { 'ERROR: ' + (Get-Field ($evErr -join ' / ')) } else { 'OK' })
            Add-S 'SQL.WindowHours' $WindowHours; Add-S 'SQL.BackupDays' $BackupDays; Add-S 'SQL.LogReachDays' $reach
            Add-S 'SQL.Read' 'OK'
        } catch { Add-S 'SQL.Read' ('ERROR: ' + (Get-Why $_)) }
    }

    # ---- Certificate Services: this server's certification authority, from its configuration in the registry ----
    $caRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration'
    $caName = [string](Get-RV $caRoot 'Active')
    if (-not $caName) { Add-S 'CA.Read' 'None' }
    else {
        try {
            $ca = $caRoot + '\' + $caName
            Add-S 'CA.Name' (Get-Field $caName)
            Add-S 'CA.Type' (Get-RV $ca 'CAType')   # 0 enterprise root, 1 enterprise subordinate, 3 stand-alone root, 4 stand-alone subordinate
            $service = @(Get-CimInstance -ClassName Win32_Service -Filter "Name='CertSvc'" -ErrorAction SilentlyContinue)[0]
            Add-S 'CA.Service' $(if ($service) { '{0}|{1}' -f $service.State, $service.StartMode } else { 'missing' })
            # the request flags of the policy module in use (EDITF_ATTRIBUTESUBJECTALTNAME2 = 0x00040000 among them)
            $module = [string](Get-RV ($ca + '\PolicyModules') 'Active'); if (-not $module) { $module = 'CertificateAuthority_MicrosoftDefault.Policy' }
            Add-S 'CA.EditFlags' (Get-RV ($ca + '\PolicyModules\' + $module) 'EditFlags')
            Add-S 'CA.AuditFilter' (Get-RV $ca 'AuditFilter')         # 127 = all seven kinds of event
            Add-S 'CA.InterfaceFlags' (Get-RV $ca 'InterfaceFlags')   # 0x200 = requests must come encrypted
            Add-S 'CA.Provider' (Get-Field (Get-RV ($ca + '\CSP') 'Provider'))
            Add-S 'CA.HashAlgorithm' (Get-Field (Get-RV ($ca + '\CSP') 'CNGHashAlgorithm'))
            # when the next revocation list is due (a time kept as eight bytes): hours from now, below zero = overdue
            foreach ($pair in @(@('CrlNextHours', 'CRLNextPublish'), @('CrlDeltaNextHours', 'CRLDeltaNextPublish'))) {
                # (a binary value comes back from a function as its bytes one by one: counted, then put together again)
                $raw = @(Get-RV $ca $pair[1]); $hours = ''
                if ($raw.Count -eq 8 -and $raw[0] -is [byte]) { $ticks = [BitConverter]::ToInt64([byte[]]$raw, 0); if ($ticks -gt 0) { $hours = [int][math]::Floor(([datetime]::FromFileTimeUtc($ticks) - $now.ToUniversalTime()).TotalHours) } }
                Add-S ('CA.' + $pair[0]) $hours
            }
            Add-S 'CA.CrlDeltaUnits' (Get-RV $ca 'CRLDeltaPeriodUnits')   # 0 = no delta lists are published
            # its own certificate: the newest of the ones it has had
            $hashes = @(Get-RV $ca 'CACertHash' | Where-Object { [string]$_ -match '[0-9A-Fa-f]' })
            Add-S 'CA.Cert' $(if ($hashes.Count -gt 0) { Get-CertState ([string]$hashes[-1]) } else { 'none' })
            # who may manage the certification authority (1) and who may issue and manage certificates (2)
            $sdBytes = @(Get-RV $ca 'Security')
            if ($sdBytes.Count -ge 20 -and $sdBytes[0] -is [byte]) {
                $who = @()
                $sd = New-Object System.Security.AccessControl.RawSecurityDescriptor ([byte[]]$sdBytes, 0)
                foreach ($ace in @($sd.DiscretionaryAcl)) {
                    if ([string]$ace.AceType -notlike 'AccessAllowed*') { continue }
                    $rights = @()
                    if ($ace.AccessMask -band 1) { $rights += 'manage the CA' }
                    if ($ace.AccessMask -band 2) { $rights += 'issue and manage certificates' }
                    if ($rights.Count -eq 0) { continue }
                    $sid = [string]$ace.SecurityIdentifier.Value
                    $who += ('{0}|{1}|{2}' -f (Get-Field (Get-SidName $sid)), $sid, ($rights -join ' + '))
                }
                Add-S 'CA.Managers' ($who -join ';'); Add-S 'CA.Managers.Read' 'OK'
            } else { Add-S 'CA.Managers.Read' 'ERROR: the access list of the certification authority is not in its configuration' }
            # web enrolment: the CertSrv application of the web server, whether it demands SSL and checks the channel's token
            $web = 'absent'
            $cfgPath = Join-Path $env:windir 'System32\inetsrv\config\applicationHost.config'
            if (Test-Path -LiteralPath $cfgPath) {
                $cfgText = (@(Get-Content -LiteralPath $cfgPath -ErrorAction Stop)) -join "`n"
                if ($cfgText -match '(?i)<application\s+path="/CertSrv"') {
                    $ssl = ''; $token = ''
                    $loc = [regex]::Match($cfgText, '(?is)<location\s+path="[^"]*/CertSrv"[^>]*>(.*?)</location>')
                    if ($loc.Success) {
                        $m1 = [regex]::Match($loc.Groups[1].Value, '(?i)<access\s[^>]*sslFlags="([^"]*)"'); if ($m1.Success) { $ssl = $m1.Groups[1].Value }
                        $m2 = [regex]::Match($loc.Groups[1].Value, '(?i)<extendedProtection\s[^>]*tokenChecking="([^"]*)"'); if ($m2.Success) { $token = $m2.Groups[1].Value }
                    }
                    $web = ('present|{0}|{1}' -f (Get-Field $ssl), (Get-Field $token))
                }
            }
            Add-S 'CA.WebEnrolment' $web
            Add-S 'CA.Read' 'OK'
        } catch { Add-S 'CA.Read' ('ERROR: ' + (Get-Why $_)) }
    }
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Lines = $lines.ToArray(); Count = $lines.Count }
}

# ---------------------------------------------------------------------
#  THE COLLECTOR'S CALL, AND WHAT THE CHECKS READ FROM IT
# ---------------------------------------------------------------------
function Get-ServerRoles {
    # The Roles collector on every server named: a server with neither role answers that at once.
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = {
        param($r)
        $t = ConvertTo-SettingsTable -LineSets @(, @($r.Lines))
        $say = { param($state, $some) if ($state -eq 'None') { 'none' } elseif ($state -eq 'OK') { $some } else { 'not read (' + $state + ')' } }
        $n = @(([string]$t['SQL.Inst']) -split ';' | Where-Object { $_ }).Count
        return ('SQL Server: {0}; certification authority: {1}' -f (& $say ([string]$t['SQL.Read']) ('{0} instance(s)' -f $n)), (& $say ([string]$t['CA.Read']) ([string]$t['CA.Name'])))
    }
    return (Invoke-Collector -Name 'Roles' -ScriptBlock $script:RemoteRolesScript -ComputerName $ComputerName -ArgumentList @([int]$script:Config.EventWindowHours, [int]$script:Config.SqlBackupMaxDays) -Summary $summary)
}

function Get-RoleGate {
    # What a role's check answers when there is nothing to judge: the role is not on the server (not applicable), or it
    # was not read (Amber with the reason - never a pass).  $null when the role was read: the check goes on.
    param($S, [ValidateSet('SQL', 'CA')][string]$Role)
    $state = [string]$S[$Role + '.Read']
    if ($state -eq 'None') { return (NotApplicable $(if ($Role -eq 'SQL') { 'no SQL Server instance on this server' } else { 'not a certification authority' })) }
    $what = $(if ($Role -eq 'SQL') { 'SQL Server' } else { 'the certification authority' })
    if ($state -like 'ERROR:*') { return (Warn ('{0} could not be read - {1}' -f $what, $state.Substring(6).Trim())) }
    if ($state -ne 'OK') { return (Warn ('{0} was not read - check the server again' -f $what)) }
    return $null
}

function Get-RoleRows {
    # The rows of one of the collector's lists, each as its fields; a row with fewer fields than expected is left out
    param($S, [string]$Key, [int]$Fields = 1)
    return @(foreach ($row in @(([string]$S[$Key]) -split ';' | Where-Object { $_ })) { $f = @($row -split '\|'); if ($f.Count -ge $Fields) { , $f } })
}

function Get-SqlInstances {
    # The SQL Server instances of a server from its merged settings table ($c.S)
    param($S)
    return @(foreach ($f in @(Get-RoleRows -S $S -Key 'SQL.Inst' -Fields 13)) {
        [pscustomobject]@{ Name = $f[0]; Id = $f[1]; Version = $f[2]; Edition = $f[3]; LoginMode = $f[4]; AuditLevel = $f[5]; Listen = $f[6]; NamedPipes = $f[7]; ForceEncryption = $f[8]; Certificate = $f[9]; Hidden = $f[10]; Engine = $f[11]; Agent = $f[12] }
    })
}

function Get-RoleCertificate {
    # A certificate as the collector describes it ('none', 'missing', or days left,signature,key bits,subject) -> State
    # ('none', 'missing', 'ok'), Days, Signature, Bits, Subject, and Problems: what is wrong with it as a certificate
    param([string]$Text)
    $o = [pscustomobject]@{ State = 'ok'; Days = 0; Signature = ''; Bits = 0; Subject = ''; Problems = @() }
    if ($Text -eq 'none' -or $Text -eq 'missing' -or -not $Text) { $o.State = $(if ($Text) { $Text } else { 'none' }); return $o }
    $f = @($Text -split ',', 4)
    $days = 0; if (-not [int]::TryParse($f[0], [ref]$days)) { $o.State = 'missing'; return $o }
    $o.Days = $days
    if ($f.Count -ge 2) { $o.Signature = $f[1] }
    $bits = 0; if ($f.Count -ge 3 -and [int]::TryParse($f[2], [ref]$bits)) { $o.Bits = $bits }
    if ($f.Count -ge 4) { $o.Subject = $f[3] }
    $bad = @()
    if ($days -lt 0) { $bad += ('expired {0} day(s) ago' -f (-$days)) }
    if ($o.Signature -match '(?i)sha1|md5') { $bad += ('signed with {0}' -f $o.Signature) }
    if ($o.Signature -match '(?i)RSA' -and $bits -gt 0 -and $bits -lt 2048) { $bad += ('an RSA key of {0} bits' -f $bits) }
    $o.Problems = $bad
    return $o
}

# ---------------------------------------------------------------------
#  HEALTH: SQL SERVER (H-SQL-01..03)
# ---------------------------------------------------------------------
New-Check -Id 'H-SQL-01' -Console 'Health' -Group 'SQL Server' -Title 'SQL Server: every instance is running' -Severity 'High' -Needs 'Roles' `
    -Why 'An instance that is down takes every application that uses it down with it; an Agent that is down runs no backup and no maintenance job, and nobody is told.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $svc = @{}; foreach ($f in @(Get-RoleRows -S $c.S -Key 'SQL.Services' -Fields 4)) { $svc[$f[0]] = $f }
        $instances = @(Get-SqlInstances -S $c.S)
        $down = @(); $soft = @(); $items = @()
        foreach ($i in $instances) {
            foreach ($pair in @(@('engine', $i.Engine), @('Agent', $i.Agent))) {
                $s = $svc[$pair[1]]
                if (-not $s) { if ($pair[0] -eq 'engine') { $down += ('{0}: its service {1} was not found' -f $i.Name, $pair[1]) }; continue }
                $items += ('{0}, {1}: {2} (start type {3})' -f $i.Name, $pair[0], $s[1], $s[2])
                if ($s[1] -eq 'Running' -or $s[2] -eq 'Disabled') { continue }
                if ($s[2] -eq 'Auto') { $down += ('{0}, {1}: {2}' -f $i.Name, $pair[0], $s[1]) } else { $soft += ('{0}, {1}: {2}' -f $i.Name, $pair[0], $s[1]) }
            }
        }
        if ($down.Count -gt 0) { return (Fail ('not running: {0}' -f ($down -join '; ')) -Items $items) }
        if ($soft.Count -gt 0) { return (Warn ('not running, and not set to start by itself: {0}' -f ($soft -join '; ')) -Items $items) }
        return (Pass ('{0} instance(s), every service that starts by itself is running' -f $instances.Count) -Items $items)
    } -Fix 'Start the service on the server (services.msc, or Start-Service <name>) and read the instance''s error log and the Application log for why it stopped. A service that is meant to stay off: set it to Disabled, and the check leaves it alone.'

New-Check -Id 'H-SQL-02' -Console 'Health' -Group 'SQL Server' -Title 'SQL Server: no errors in the Application log' -Severity 'High' -Needs 'Roles' `
    -Why 'SQL Server writes its serious errors to the Application log: a database that ran out of room, a failed job step, a damaged page (errors 823, 824 and 825 - the disk or the file is at fault and the data may be lost).' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $state = [string]$c.S['SQL.Events.Read']
        if ($state -ne 'OK') { return (Warn ('the Application log could not be read for SQL Server{0}' -f $(if ($state -like 'ERROR:*') { ' - ' + $state.Substring(6).Trim() } else { ' - check the server again' }))) }
        $hours = [string]$c.S['SQL.WindowHours']
        $bad = @(); $some = @(); $items = @()
        foreach ($f in @(Get-RoleRows -S $c.S -Key 'SQL.Errors' -Fields 4)) {
            if ([int]$f[1] -eq 0) { continue }
            $items += ('{0}: {1} error event(s){2} - {3}' -f $f[0], $f[1], $(if ([int]$f[1] -ge 500) { ' or more' } else { '' }), $f[2])
            if ([int]$f[3] -gt 0) { $bad += $f[0] } else { $some += $f[0] }
        }
        if ($bad.Count -gt 0) { return (Fail ('damaged pages reported (error 823, 824 or 825) in the last {0} h on: {1}' -f $hours, ($bad -join ', ')) -Items $items) }
        if ($some.Count -gt 0) { return (Warn ('SQL Server errors in the Application log in the last {0} h on: {1}' -f $hours, ($some -join ', ')) -Items $items) }
        return (Pass ('no SQL Server error in the Application log in the last {0} h' -f $hours))
    } -Fix 'Event Viewer > Application, source MSSQLSERVER (or MSSQL$<instance>): the event number is SQL Server''s error number, and the instance''s error log has what led up to it. Errors 823, 824 and 825: check the disk and the storage path at once, run DBCC CHECKDB on the database named, and have a backup from before the damage at hand.'

New-Check -Id 'H-SQL-03' -Console 'Health' -Group 'SQL Server' -Title 'SQL Server: backups are on record' -Severity 'High' -Needs 'Roles' `
    -Why 'SQL Server writes every backup, and every backup that failed, to the Application log. An instance with no backup on record for days is one nobody is backing up - or one whose backup job stopped.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $state = [string]$c.S['SQL.Events.Read']
        if ($state -ne 'OK') { return (Warn ('the Application log could not be read for SQL Server{0}' -f $(if ($state -like 'ERROR:*') { ' - ' + $state.Substring(6).Trim() } else { ' - check the server again' }))) }
        $days = [string]$c.S['SQL.BackupDays']
        $reach = 0; $reachKnown = [int]::TryParse([string]$c.S['SQL.LogReachDays'], [ref]$reach)
        $failed = @(); $none = @(); $items = @()
        foreach ($f in @(Get-RoleRows -S $c.S -Key 'SQL.Backups' -Fields 5)) {
            $items += ('{0}: {1} database backup(s), {2} log backup(s), {3} failed{4}' -f $f[0], $f[1], $f[2], $f[3], $(if ($f[4] -ne '') { ('; the last database backup {0} day(s) ago' -f $f[4]) } else { '' }))
            if ([int]$f[3] -gt 0) { $failed += $f[0] }
            if ([int]$f[1] -eq 0) { $none += $f[0] }
        }
        if ($items.Count -eq 0) { return (Warn 'the backups of SQL Server were not read - check the server again') }
        if ($failed.Count -gt 0) { return (Fail ('a backup failed in the last {0} days on: {1}' -f $days, ($failed -join ', ')) -Items $items) }
        if ($none.Count -gt 0) {
            # a log that does not reach back that far cannot show the backup: said, not held against the instance as a missing one
            if ($reachKnown -and $reach -lt [int]$days) { return (Warn ('no database backup on record for: {0} - the Application log reaches back {1} day(s) only' -f ($none -join ', '), $reach) -Items $items) }
            return (Warn ('no database backup on record in the last {0} days for: {1}' -f $days, ($none -join ', ')) -Items $items)
        }
        return (Pass ('every instance has a database backup on record in the last {0} days' -f $days) -Items $items)
    } -Fix 'Find the backup job (SQL Server Agent > Jobs, a maintenance plan, or the backup product) and why it did not run or failed: the job history and the Application log (event 3041) say. A backup taken by a product that snapshots the server is on record too. An instance that needs no backup - a scratch instance - is recorded in the tailoring. The days are SqlBackupMaxDays on the Settings tab.'

# ---------------------------------------------------------------------
#  SECURITY: THE DATABASE SERVER (SEC-SQL-01..07).  Read from the server, not from the instance: what is decided
#  inside it - who is a sysadmin, whether sa is disabled, what the audit covers - is not judged here.
# ---------------------------------------------------------------------
New-Check -Id 'SEC-SQL-01' -Console 'Security' -Group 'Database server' -Title 'SQL Server services run as their own accounts, without administrator rights' -Ism 'ISM-1249', 'ISM-1250' -Severity 'High' -Needs 'Roles' `
    -Why 'Whoever gets a command run by the database engine runs it as the engine''s service account. As LocalSystem or an administrator that is the whole server; as the service''s own account it is the database files and little else.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $admins = @()
        $la = Get-LocalAccounts -Settings $c.S
        if ($la.Read -eq 'OK') { $g = @($la.Groups | Where-Object { $_.Sid -eq 'S-1-5-32-544' })[0]; if ($g) { $admins = @($g.Members) } }
        $computer = [string]$la.Computer
        $bad = @(); $shared = @(); $items = @()
        foreach ($f in @(Get-RoleRows -S $c.S -Key 'SQL.Services' -Fields 4)) {
            if ($f[0] -eq 'SQLBrowser' -or $f[2] -eq 'Disabled') { continue }
            $account = [string]$f[3]
            $items += ('{0}: {1}' -f $f[0], $(if ($account) { $account } else { 'account not read' }))
            # the account as the local Administrators group would list it: .\name is this computer's own
            $asMember = $account; if ($account -like '.\*' -and $computer) { $asMember = $computer + $account.Substring(1) }
            if ($account -match '(?i)^(LocalSystem|NT AUTHORITY\\SYSTEM)$') { $bad += ('{0} runs as LocalSystem' -f $f[0]) }
            elseif (@($admins | Where-Object { $_ -ieq $asMember }).Count -gt 0) { $bad += ('{0} runs as {1}, a member of the local Administrators group' -f $f[0], $account) }
            elseif ($account -match '(?i)^NT AUTHORITY\\(LocalService|NetworkService|Local Service|Network Service)$') { $shared += ('{0} runs as {1}' -f $f[0], $account) }
        }
        if ($items.Count -eq 0) { return (Warn 'the SQL Server services were not read - check the server again') }
        if ($bad.Count -gt 0) { return (Fail ($bad -join '; ') -Items $items) }
        if ($shared.Count -gt 0) { return (Warn (($shared -join '; ') + ' - an account every such service on the server shares, not one of its own') -Items $items) }
        $note = ''; if ($la.Read -ne 'OK') { $note = ' (whether an account is a local administrator was not read on this server)' }
        return (Pass ('{0} service(s), none as LocalSystem or as a listed member of the local Administrators group{1}' -f $items.Count, $note) -Items $items)
    } -Fix 'SQL Server Configuration Manager > SQL Server Services > the service > Log On: a group managed service account, or the service''s own virtual account (NT Service\MSSQLSERVER) - never LocalSystem, never an administrator. Change it there, not in services.msc: Configuration Manager also gives the new account its rights on the files and the registry. A change - use a change record; the service restarts.'

New-Check -Id 'SEC-SQL-02' -Console 'Security' -Group 'Database server' -Title 'SQL Server listens only the ways it is used' -Ism 'ISM-1247' -Severity 'Medium' -Needs 'Roles' `
    -Why 'Each way in is one more to defend. Named Pipes is rarely needed beside TCP, and the SQL Server Browser tells anybody who asks which instances there are and on which ports.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $instances = @(Get-SqlInstances -S $c.S)
        $pipes = @($instances | Where-Object { $_.NamedPipes -eq '1' } | ForEach-Object { $_.Name })
        $items = @($instances | ForEach-Object { '{0}: {1}; Named Pipes {2}{3}' -f $_.Name, $_.Listen, $(if ($_.NamedPipes -eq '1') { 'on' } else { 'off' }), $(if ($_.Hidden -eq '1') { '; hidden from the Browser' } else { '' }) })
        $browser = @(Get-RoleRows -S $c.S -Key 'SQL.Services' -Fields 4 | Where-Object { $_[0] -eq 'SQLBrowser' })[0]
        $browserOn = [bool]($browser -and $browser[1] -eq 'Running')
        if ($browser) { $items += ('SQL Server Browser: {0} (start type {1})' -f $browser[1], $browser[2]) }
        $found = @()
        if ($pipes.Count -gt 0) { $found += ('Named Pipes is on for: {0}' -f ($pipes -join ', ')) }
        # the Browser serves named instances and dynamic ports; a server with the default instance on a fixed port has no use for it
        if ($browserOn -and @($instances | Where-Object { $_.Name -ne 'MSSQLSERVER' -or $_.Listen -match 'dynamic' }).Count -eq 0) { $found += 'the SQL Server Browser is running, and the only instance is the default one on a fixed port' }
        if ($found.Count -gt 0) { return (Warn (($found -join '; ') + ' - confirm it is needed') -Items $items) }
        return (Pass ('{0} instance(s): no way in beyond the ones in use' -f $instances.Count) -Items $items)
    } -Fix 'SQL Server Configuration Manager > SQL Server Network Configuration > Protocols for <instance>: disable Named Pipes where every client connects over TCP, and under TCP/IP > IP Addresses listen only on the addresses the clients reach (or on 127.0.0.1 where every client is on the server). SQL Server Browser: stop and disable it where no named instance or dynamic port needs it. Each is a change - use a change record; the instance restarts.'

New-Check -Id 'SEC-SQL-03' -Console 'Security' -Group 'Database server' -Title 'SQL Server connections are encrypted, with a certificate of its own' -Ism 'ISM-1277' -Severity 'Medium' -Needs 'Roles' `
    -Why 'Without Force Encryption a client may connect in clear text, and what it reads and writes crosses the network readable. Without a certificate of its own the instance makes one up at each start that no client can check.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $open = @(); $weak = @(); $made = @(); $items = @()
        foreach ($i in @(Get-SqlInstances -S $c.S)) {
            $cert = Get-RoleCertificate -Text $i.Certificate
            $say = 'no certificate chosen'
            if ($cert.State -eq 'missing') { $say = 'its certificate is not in the computer''s store' } elseif ($cert.State -eq 'ok') { $say = ('certificate {0}, {1} day(s) left, {2}{3}' -f $cert.Subject, $cert.Days, $cert.Signature, $(if ($cert.Bits) { ', ' + $cert.Bits + ' bits' } else { '' })) }
            $items += ('{0}: Force Encryption {1}; {2}' -f $i.Name, $(if ($i.ForceEncryption -eq '1') { 'on' } else { 'off' }), $say)
            if ($i.ForceEncryption -ne '1') { $open += $i.Name; continue }
            if ($cert.State -eq 'missing' -or @($cert.Problems).Count -gt 0) { $weak += ('{0} ({1})' -f $i.Name, $(if ($cert.State -eq 'missing') { 'certificate missing' } else { $cert.Problems -join ', ' })) }
            elseif ($cert.State -eq 'none') { $made += $i.Name }
        }
        if ($items.Count -eq 0) { return (Warn 'the SQL Server instances were not read - check the server again') }
        if ($open.Count -gt 0) { return (Fail ('Force Encryption is off, a client may connect in clear text: {0}' -f ($open -join ', ')) -Items $items) }
        if ($weak.Count -gt 0) { return (Fail ('encrypted, with a certificate that does not hold: {0}' -f ($weak -join '; ')) -Items $items) }
        if ($made.Count -gt 0) { return (Warn ('encrypted with a certificate the instance makes up at each start, which no client can check: {0}' -f ($made -join ', ')) -Items $items) }
        return (Pass 'every instance forces encryption, each with a valid certificate of its own' -Items $items)
    } -Fix 'Give the server a certificate from your certification authority (server authentication, the server''s name as the clients use it). SQL Server Configuration Manager > SQL Server Network Configuration > Protocols for <instance> > Properties: Certificate = that certificate, Flags > Force Encryption = Yes. A change - use a change record; the instance restarts, and a client that does not trust the authority no longer connects.'

New-Check -Id 'SEC-SQL-04' -Console 'Security' -Group 'Database server' -Title 'SQL Server data, log and backup folders are closed to ordinary users' -Ism 'ISM-1256' -Severity 'High' -Needs 'Roles' `
    -Why 'A database file or a backup that an ordinary account can read is the whole database, outside every permission set inside it: copy the file, attach or restore it elsewhere.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $dirs = @(Get-RoleRows -S $c.S -Key 'SQL.Dirs' -Fields 4)
        if ($dirs.Count -eq 0) { return (Warn 'the folders of SQL Server were not read - check the server again') }
        $open = @(Get-RoleRows -S $c.S -Key 'SQL.Acl' -Fields 4 | ForEach-Object { '{0}, {1} folder {2}: {3}' -f $_[0], $_[1], $_[2], $_[3] })
        $unread = @($dirs | Where-Object { $_[3] -eq 'not read' } | ForEach-Object { '{0}, {1} folder {2}' -f $_[0], $_[1], $_[2] })
        $items = @($dirs | ForEach-Object { '{0}, {1} folder {2}: {3}' -f $_[0], $_[1], $_[2], $_[3] })
        if ($open.Count -gt 0) { return (Fail ('{0} folder(s) of SQL Server can be reached by nearly everybody' -f @($dirs | Where-Object { $_[3] -eq 'open' }).Count) -Items $open) }
        if ($unread.Count -gt 0) { return (Warn ('the access list could not be read for: {0}' -f ($unread -join '; ')) -Items $items) }
        return (Pass ('{0} folder(s), none open to Everyone, Authenticated Users, Users or Domain Users' -f @($dirs | Where-Object { $_[3] -eq 'closed' }).Count) -Items $items)
    } -Fix 'On the folder (Properties > Security > Advanced): stop it inheriting from the drive, and leave the instance''s service account, SYSTEM and Administrators. Do the same where the backups are copied to. A change - use a change record; check that the backup job and the instance still reach the folder.'

New-Check -Id 'SEC-SQL-05' -Console 'Security' -Group 'Database server' -Title 'No web server on the database server' -Ism 'ISM-1269' -Severity 'Medium' -Needs 'Roles', 'Inventory' `
    -Why 'A web server is what the outside world talks to, and where it is broken into first. On the database server, that break-in is already at the data.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $features = @($c.Inventory.Features | ForEach-Object { [string]$_ })
        if ($features.Count -eq 0 -or @(@($features) -match '^ERROR\|').Count -gt 0) { return (Warn 'the roles and features of the server were not read') }
        if (@(@($features) -match '^Web-Server\|').Count -gt 0) { return (Fail ('the Web Server (IIS) role is installed beside {0} SQL Server instance(s)' -f @(Get-SqlInstances -S $c.S).Count)) }
        return (Pass 'the Web Server (IIS) role is not installed on this server')
    } -Fix 'Move the web application to a server of its own, or the database to one. Where a product needs both on one server, record why in the tailoring. Reporting Services since 2017 brings its own web listener and does not install the Web Server role.'

New-Check -Id 'SEC-SQL-06' -Console 'Security' -Group 'Database server' -Title 'SQL Server accepts Windows logons only' -Ism 'ISM-1260' -Severity 'Medium' -Needs 'Roles' `
    -Why 'In mixed mode the instance keeps logins and passwords of its own - sa, the account every SQL Server has, among them. With Windows logons only, none of them can log on, whatever state they are in.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $instances = @(Get-SqlInstances -S $c.S)
        $mixed = @($instances | Where-Object { $_.LoginMode -eq '2' } | ForEach-Object { $_.Name })
        $unknown = @($instances | Where-Object { $_.LoginMode -notin '1', '2' } | ForEach-Object { $_.Name })
        if ($mixed.Count -gt 0) { return (Warn ('SQL Server logins can log on (mixed mode) on: {0} - whether sa is disabled or renamed, and what passwords the logins have, is decided inside the instance, where the toolkit does not look' -f ($mixed -join ', '))) }   # a finding: none of the words that mean "the value was not read" (Test-UnreadEvidence) may stand in it
        if ($unknown.Count -gt 0) { return (Warn ('the logon mode was not read for: {0}' -f ($unknown -join ', '))) }
        return (Pass ('{0} instance(s), each with Windows logons only: sa and every other SQL Server login cannot log on' -f $instances.Count))
    } -Fix 'SQL Server Management Studio > the server > Properties > Security > Server authentication: Windows Authentication mode, once no application logs on with a SQL Server login. Where one must: disable or rename sa, and give every login a password under the password policy (CHECK_POLICY). A change - use a change record; the instance restarts.'

New-Check -Id 'SEC-SQL-07' -Console 'Security' -Group 'Database server' -Title 'SQL Server records logons, failed and successful' -Ism 'ISM-1537' -Severity 'Medium' -Needs 'Roles' `
    -Why 'The ISM has database logons and logoffs logged. SQL Server records only failed logons unless told otherwise - so who did log on, and when, is not on record.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'SQL'; if ($gate) { return $gate }
        $words = @{ '0' = 'none'; '1' = 'successful logons only'; '2' = 'failed logons only'; '3' = 'failed and successful logons' }
        $instances = @(Get-SqlInstances -S $c.S)
        $items = @($instances | ForEach-Object { '{0}: {1}' -f $_.Name, $(if ($words.ContainsKey([string]$_.AuditLevel)) { $words[[string]$_.AuditLevel] } else { 'not read' }) })
        $none = @($instances | Where-Object { $_.AuditLevel -eq '0' } | ForEach-Object { $_.Name })
        $part = @($instances | Where-Object { $_.AuditLevel -in '1', '2' } | ForEach-Object { $_.Name })
        $unknown = @($instances | Where-Object { $_.AuditLevel -notin '0', '1', '2', '3' } | ForEach-Object { $_.Name })
        if ($none.Count -gt 0) { return (Fail ('no logon is recorded on: {0}' -f ($none -join ', ')) -Items $items) }
        if ($part.Count -gt 0) { return (Warn ('only part of the logons is recorded on: {0}' -f ($part -join ', ')) -Items $items) }
        if ($unknown.Count -gt 0) { return (Warn ('logon auditing was not read for: {0}' -f ($unknown -join ', ')) -Items $items) }
        return (Pass ('{0} instance(s), each recording failed and successful logons - what else the instance audits is set inside it and is not read' -f $instances.Count) -Items $items)
    } -Fix 'SQL Server Management Studio > the server > Properties > Security > Login auditing: Both failed and successful logins (the instance restarts). The other events the ISM names - changes to logins and roles, to the structure of a database, what its administrators do - need a server audit set up inside the instance, written to the Security or the Application log so that it is collected with the rest.'

# ---------------------------------------------------------------------
#  HEALTH: THE CERTIFICATION AUTHORITY (H-CA-01..03)
# ---------------------------------------------------------------------
New-Check -Id 'H-CA-01' -Console 'Health' -Group 'Certification authority' -Title 'Certificate Services is running' -Severity 'High' -Needs 'Roles' `
    -Why 'While the service is down no certificate is issued or renewed and no revocation list is published - and the lists already out run towards their expiry.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $f = @(([string]$c.S['CA.Service']) -split '\|')
        if ($f[0] -eq 'missing' -or $f.Count -lt 2) { return (Fail ('the service of certification authority {0} was not found' -f $c.S['CA.Name'])) }
        if ($f[0] -ne 'Running') { return (Fail ('Certificate Services is {0} (start type {1}) - certification authority {2}' -f $f[0], $f[1], $c.S['CA.Name'])) }
        return (Pass ('Certificate Services is running - certification authority {0}' -f $c.S['CA.Name']))
    } -Fix 'Start the service (Certification Authority console > the CA > All Tasks > Start Service, or Start-Service CertSvc) and read the Application log, source CertificationAuthority, for why it stopped: its own certificate expired, the key not reachable, the database out of room.'

New-Check -Id 'H-CA-02' -Console 'Health' -Group 'Certification authority' -Title 'The next revocation list is not overdue' -Severity 'High' -Needs 'Roles' `
    -Why 'A certificate is checked against the revocation list of the authority that issued it. Once the list out there has expired and no new one was published, every such check fails - logons with smart cards, TLS, signed code.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $hours = 0; if (-not [int]::TryParse([string]$c.S['CA.CrlNextHours'], [ref]$hours)) { return (Warn 'when the next revocation list is due was not read') }
        $text = $(if ($hours -ge 0) { 'the next revocation list is due in {0} h' -f $hours } else { 'the next revocation list was due {0} h ago and has not been published' -f (-$hours) })
        $delta = 0
        if ([string]$c.S['CA.CrlDeltaUnits'] -ne '0' -and [int]::TryParse([string]$c.S['CA.CrlDeltaNextHours'], [ref]$delta)) { $text += $(if ($delta -ge 0) { '; the next delta list in {0} h' -f $delta } else { '; the next delta list was due {0} h ago' -f (-$delta) }) }
        if ($hours -lt 0) { return (Fail $text) }
        if ($delta -lt 0) { return (Warn $text) }
        return (Pass $text)
    } -Fix 'Certification Authority console > Revoked Certificates > All Tasks > Publish (or certutil -CRL on the server). If it fails: the Application log, source CertificationAuthority, says why - most often a publication place that cannot be written to. An offline root publishes by hand: its list is due when the root is next switched on.'

New-Check -Id 'H-CA-03' -Console 'Health' -Group 'Certification authority' -Title 'The certification authority''s own certificate is not about to expire' -Severity 'High' -Needs 'Roles' `
    -Why 'No certificate outlives the one that signed it. An authority whose certificate has months left issues certificates of months, and when it expires everything it issued stops being trusted the same day.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $cert = Get-RoleCertificate -Text ([string]$c.S['CA.Cert'])
        if ($cert.State -ne 'ok') { return (Warn ('the certificate of certification authority {0} was not read ({1})' -f $c.S['CA.Name'], $(if ($cert.State -eq 'missing') { 'it is not in the computer''s store' } else { 'its configuration names none' }))) }
        # renewing an authority takes its parent and a plan: named six times as early as any other certificate
        $warnDays = 6 * [int]$script:Config.CertExpiryDays
        $text = ('{0}: {1} day(s) left' -f $cert.Subject, $cert.Days)
        if ($cert.Days -lt 0) { return (Fail ('{0}: expired {1} day(s) ago' -f $cert.Subject, (-$cert.Days))) }
        if ($cert.Days -lt $warnDays) { return (Warn ($text + (' (named from {0} days on)' -f $warnDays))) }
        return (Pass $text)
    } -Fix 'Renew the certification authority''s certificate (Certification Authority console > the CA > All Tasks > Renew CA Certificate) well before the certificates it issues would run past its end: a subordinate needs its parent to sign, an offline root needs switching on.'

# ---------------------------------------------------------------------
#  SECURITY: THE CERTIFICATION AUTHORITY (SEC-CA-01..06).  The certificate templates it publishes are the directory's:
#  SEC-AD-30..33 judge them, on the PDC emulator of the forest root domain (48-Directory.ps1).
# ---------------------------------------------------------------------
New-Check -Id 'SEC-CA-01' -Console 'Security' -Group 'Certification authority' -Title 'A request cannot name another subject through an attribute' -Ism 'ISM-1944' -Severity 'High' -Needs 'Roles' `
    -Why 'With EDITF_ATTRIBUTESUBJECTALTNAME2 set, anybody who may enrol for any logon certificate adds the name of a domain administrator to the request - and gets a certificate that logs on as that administrator.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $flags = [int64]0; if (-not [int64]::TryParse([string]$c.S['CA.EditFlags'], [ref]$flags)) { return (Warn 'the request flags of the certification authority were not read') }
        if ($flags -band 0x00040000) { return (Fail 'EDITF_ATTRIBUTESUBJECTALTNAME2 is set: a request may carry any subject alternative name') }
        return (Pass 'EDITF_ATTRIBUTESUBJECTALTNAME2 is not set')
    } -Fix 'On the certification authority: certutil -setreg policy\EditFlags -EDITF_ATTRIBUTESUBJECTALTNAME2, then restart Certificate Services. A change - use a change record. A template that needs another name in its certificates says so itself, with approval (SEC-AD-30).'

New-Check -Id 'SEC-CA-02' -Console 'Security' -Group 'Certification authority' -Title 'The certification authority''s key is held by a hardware security module' -Ism 'ISM-1957' -Severity 'High' -Needs 'Roles' `
    -Why 'Whoever copies the key of a certification authority issues certificates in its name for as long as it is trusted, and nothing shows it. In a hardware security module the key cannot be copied; in software it is a file an administrator can export.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $provider = [string]$c.S['CA.Provider']
        if (-not $provider) { return (Warn 'the provider that holds the key of the certification authority was not read') }
        # Windows' own providers keep the key in software, on the disk of the server
        if ($provider -match '(?i)^Microsoft (Software Key Storage|Strong Cryptographic|Enhanced Cryptographic|Enhanced RSA and AES Cryptographic|Base Cryptographic|RSA SChannel Cryptographic) Provider') { return (Fail ('the key is held in software, by ''{0}''' -f $provider)) }
        return (Pass ('the key is held by ''{0}'' - not one of Windows'' own software providers; confirm it is the hardware security module''s' -f $provider))
    } -Fix 'Moving the key of a certification authority into a hardware security module is a project: install the module and its key storage provider, then migrate the key or - cleaner - renew the authority''s certificate with a new key made in the module. Until then, record the decision in the tailoring and keep the server as closely held as a domain controller.'

New-Check -Id 'SEC-CA-03' -Console 'Security' -Group 'Certification authority' -Title 'Web enrolment is absent, or demands HTTPS and Extended Protection' -Ism 'ISM-2130' -Severity 'High' -Needs 'Roles' `
    -Why 'The web enrolment pages take a logon over the web. Without HTTPS and Extended Protection, a logon captured from any computer can be relayed to them - and a domain controller''s relayed logon gets a certificate that is the domain.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $web = [string]$c.S['CA.WebEnrolment']
        if ($web -eq 'absent') { return (Pass 'web enrolment (the CertSrv web application) is not on this server') }
        $f = @($web -split '\|')
        if ($f[0] -ne 'present' -or $f.Count -lt 3) { return (Warn 'whether web enrolment is on this server was not read') }
        $missing = @()
        if ($f[1] -notmatch '(?i)\bSsl\b') { $missing += 'it does not demand HTTPS (SSL flags: {0})' -f $(if ($f[1]) { $f[1] } else { 'none' }) }
        if ($f[2] -ne 'Require') { $missing += 'Extended Protection is not required (token checking: {0})' -f $(if ($f[2]) { $f[2] } else { 'not set' }) }
        if ($missing.Count -gt 0) { return (Fail ('web enrolment is on this server: {0}' -f ($missing -join '; '))) }
        return (Pass 'web enrolment is on this server, demanding HTTPS with Extended Protection required - confirm it is still needed')
    } -Fix 'Not needed: remove the role services (Certification Authority Web Enrollment, Certificate Enrollment Web Service). Needed: IIS Manager > Default Web Site > CertSrv > SSL Settings: Require SSL; Authentication > Windows Authentication > Advanced Settings: Extended Protection = Required, and take NTLM off the providers where Kerberos will do. A change - use a change record.'

New-Check -Id 'SEC-CA-04' -Console 'Security' -Group 'Certification authority' -Title 'The certification authority records what it is asked and what is changed' -Ism 'ISM-2132' -Severity 'Medium' -Needs 'Roles' `
    -Why 'A certificate issued in another name looks like any other afterwards. Only the record of the request - who asked, for what, and whether the authority or a template was changed just before - shows it.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $filter = 0; if (-not [int]::TryParse([string]$c.S['CA.AuditFilter'], [ref]$filter)) { return (Warn 'the audit filter of the certification authority was not read') }
        $kinds = @(@(1, 'start and stop'), @(2, 'backup and restore'), @(4, 'requests issued and managed'), @(8, 'revocations and list publication'), @(16, 'changes to its security'), @(32, 'key storage and retrieval'), @(64, 'changes to its configuration'))
        $off = @(foreach ($kind in $kinds) { if (-not ($filter -band [int]$kind[0])) { [string]$kind[1] } })
        # the authority's events reach the Security log only where the audit policy lets them
        $policy = [string]$c.S['Audit:Certification Services']
        $note = ''
        # worded without "not read": the note also ends a finding below, which must count as one (Test-UnreadEvidence)
        if (-not $policy) { $note = '; whether the audit policy passes them on (subcategory Certification Services) is not known here' }
        elseif ($policy -ne 'Success and Failure') { $off += ('the audit policy passes on ''{0}'' only (subcategory Certification Services)' -f $policy) }
        if ($filter -eq 0) { return (Fail 'the certification authority records nothing (audit filter 0)') }
        if ($off.Count -gt 0) { return (Warn ('not recorded: {0}{1}' -f ($off -join '; '), $note)) }
        return (Pass ('every kind of event is recorded (audit filter {0}){1} - that the events are collected centrally is not read here' -f $filter, $note))
    } -Fix 'Certification Authority console > the CA > Properties > Auditing: tick every box (certutil -setreg CA\AuditFilter 127, then restart the service). GPO: Advanced Audit Policy > Object Access > Audit Certification Services = Success and Failure. Then have the Security log of the server collected with the others.'

New-Check -Id 'SEC-CA-05' -Console 'Security' -Group 'Certification authority' -Title 'Only administrators manage the certification authority' -Ism 'ISM-1508' -ML 3 -Severity 'High' -Needs 'Roles' `
    -Why 'Whoever may manage the authority can switch its safeguards off; whoever may issue and manage certificates can approve a request in any name. Either is a way to a certificate that logs on as a domain administrator.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $state = [string]$c.S['CA.Managers.Read']
        if ($state -ne 'OK') { return (Warn ('who may manage the certification authority was not read{0}' -f $(if ($state -like 'ERROR:*') { ' - ' + $state.Substring(6).Trim() } else { '' }))) }
        $broad = @(); $other = @(); $items = @()
        foreach ($f in @(Get-RoleRows -S $c.S -Key 'CA.Managers' -Fields 3)) {
            $items += ('{0}: {1}' -f $f[0], $f[2])
            $sid = [string]$f[1]
            if (Test-BroadPrincipalSid -Sid $sid) { $broad += $f[0] }
            # the administrators of the server, of the domain and of the forest, and the system itself
            elseif (@('S-1-5-32-544', 'S-1-5-18') -notcontains $sid -and $sid -notmatch '^S-1-5-21-.+-(512|519)$') { $other += $f[0] }
        }
        if ($broad.Count -gt 0) { return (Fail ('nearly everybody may manage the certification authority or its certificates: {0}' -f ($broad -join ', ')) -Items $items) }
        if ($other.Count -gt 0) { return (Warn ('{0} account(s) or group(s) beside the administrators may manage the certification authority or its certificates - confirm each: {1}' -f $other.Count, ($other -join ', ')) -Items $items) }
        return (Pass ('{0} holder(s) of management rights, each an administrators'' group' -f $items.Count) -Items $items)
    } -Fix 'Certification Authority console > the CA > Properties > Security: leave "Manage CA" and "Issue and Manage Certificates" to the administrators of the authority; an account that only requests certificates needs "Request Certificates" and nothing more. A group kept on purpose - certificate managers of your own - is recorded in the tailoring.'

New-Check -Id 'SEC-CA-06' -Console 'Security' -Group 'Certification authority' -Title 'Certificate requests must come encrypted' -Ism 'ISM-1246' -Severity 'Medium' -Needs 'Roles' `
    -Why 'A request sent to the authority without encryption can be relayed like any other unprotected logon: a captured logon of a computer becomes a certificate for that computer. Microsoft''s own hardening has the authority refuse such requests.' `
    -Test {
        param($c)
        $gate = Get-RoleGate -S $c.S -Role 'CA'; if ($gate) { return $gate }
        $flags = [int64]0; if (-not [int64]::TryParse([string]$c.S['CA.InterfaceFlags'], [ref]$flags)) { return (Warn 'the interface flags of the certification authority were not read') }
        if ($flags -band 0x200) { return (Pass 'IF_ENFORCEENCRYPTICERTREQUEST is set: a request that is not encrypted is refused') }
        return (Fail 'IF_ENFORCEENCRYPTICERTREQUEST is not set: the authority takes requests that are not encrypted')
    } -Fix 'On the certification authority: certutil -setreg CA\InterfaceFlags +IF_ENFORCEENCRYPTICERTREQUEST, then restart Certificate Services. A change - use a change record: a client older than Windows Vista, or a device that enrols without encryption, no longer gets a certificate.'

# ---------------------------------------------------------------------
#  ON THE HEALTH TAB: the sections of the server's details page and the tables of the Health report.  All of it
#  from the collector's saved answer.  The grid has no column for a role: its checks count in Red / Amber / Green.
# ---------------------------------------------------------------------
function Get-RolesTable {
    # The Roles collector's answer for one server as a table, or $null: not collected, or the call failed
    param([string]$Server)
    $r = Get-CollectorResult -Name 'Roles' -Server $Server
    if (-not $r -or -not $r.Reachable) { return $null }
    return (ConvertTo-SettingsTable -LineSets @(, @($r.Lines)))
}

function Get-SqlInstanceRows {
    # One row per SQL Server instance of a server, as the details page and the report show it
    param($Table, [string]$Server = '')
    if (-not $Table -or [string]$Table['SQL.Read'] -ne 'OK') { return @() }
    $svc = @{}; foreach ($f in @(Get-RoleRows -S $Table -Key 'SQL.Services' -Fields 4)) { $svc[$f[0]] = $f }
    $bak = @{}; foreach ($f in @(Get-RoleRows -S $Table -Key 'SQL.Backups' -Fields 5)) { $bak[$f[0]] = $f }
    $err = @{}; foreach ($f in @(Get-RoleRows -S $Table -Key 'SQL.Errors' -Fields 4)) { $err[$f[0]] = $f }
    $modes = @{ '1' = 'Windows only'; '2' = 'mixed' }; $audits = @{ '0' = 'none'; '1' = 'successful'; '2' = 'failed'; '3' = 'failed and successful' }
    return @(foreach ($i in @(Get-SqlInstances -S $Table)) {
        $e = $svc[$i.Engine]; $a = $svc[$i.Agent]; $b = $bak[$i.Name]; $x = $err[$i.Name]
        $cert = Get-RoleCertificate -Text $i.Certificate
        [pscustomobject]@{
            Server = $Server; Instance = $i.Name; Version = $i.Version; Edition = $i.Edition
            Engine = $(if ($e) { '{0} as {1}' -f $e[1], $e[3] } else { 'service not found' }); Agent = $(if ($a) { '{0} as {1}' -f $a[1], $a[3] } else { '' })
            Listens = ('{0}; Named Pipes {1}' -f $i.Listen, $(if ($i.NamedPipes -eq '1') { 'on' } else { 'off' }))
            Encryption = ('{0}{1}' -f $(if ($i.ForceEncryption -eq '1') { 'forced' } else { 'not forced' }), $(if ($cert.State -eq 'ok') { ', certificate with {0} day(s) left' -f $cert.Days } elseif ($cert.State -eq 'missing') { ', certificate missing' } else { ', no certificate chosen' }))
            Logons = $(if ($modes.ContainsKey([string]$i.LoginMode)) { $modes[[string]$i.LoginMode] } else { 'not read' }); 'Logon audit' = $(if ($audits.ContainsKey([string]$i.AuditLevel)) { $audits[[string]$i.AuditLevel] } else { 'not read' })
            'Errors logged' = $(if ($x) { $x[1] } else { '' }); 'Last backup' = $(if ($b -and $b[4] -ne '') { '{0} day(s) ago' -f $b[4] } elseif ($b) { 'none on record' } else { '' })
        }
    })
}

function Get-RolesDetailsSections {
    # The role part of a server's Health page: its SQL Server instances, their services and folders; its certification
    # authority.  Nothing for a server with neither.
    param([string]$Server)
    $t = Get-RolesTable -Server $Server
    if (-not $t) { return @() }
    $sections = @()
    if ([string]$t['SQL.Read'] -eq 'OK') {
        $sections += @{ Heading = 'SQL Server: instances'; Rows = @(Get-SqlInstanceRows -Table $t -Server $Server); Columns = @('Instance', 'Version', 'Edition', 'Engine', 'Agent', 'Listens', 'Encryption', 'Logons', 'Logon audit', 'Errors logged', 'Last backup'); Note = ('Read from the server - the registry, the services, the Application log (errors of the last {0} h, backups of the last {1} days). No connection is made to an instance.' -f $t['SQL.WindowHours'], $t['SQL.BackupDays']) }
        $sections += @{ Heading = 'SQL Server: folders'; Rows = @(Get-RoleRows -S $t -Key 'SQL.Dirs' -Fields 4 | ForEach-Object { $row = $_; [pscustomobject]@{ Light = $(switch ($row[3]) { 'open' { 'Red' } 'closed' { 'Green' } default { 'Amber' } }); Instance = $row[0]; Kind = $row[1]; Folder = $row[2]; 'Ordinary users' = $row[3]; Who = ((@(Get-RoleRows -S $t -Key 'SQL.Acl' -Fields 4 | Where-Object { $_[0] -eq $row[0] -and $_[2] -eq $row[2] } | ForEach-Object { $_[3] })) -join '; ') } }); Columns = @('Light', 'Instance', 'Kind', 'Folder', 'Ordinary users', 'Who') }
    } elseif ([string]$t['SQL.Read'] -like 'ERROR:*') { $sections += @{ Heading = 'SQL Server'; Lines = @('SQL Server could not be read: ' + ([string]$t['SQL.Read']).Substring(6).Trim()) } }
    if ([string]$t['CA.Read'] -eq 'OK') {
        $types = @{ '0' = 'enterprise root'; '1' = 'enterprise subordinate'; '3' = 'stand-alone root'; '4' = 'stand-alone subordinate' }
        $cert = Get-RoleCertificate -Text ([string]$t['CA.Cert'])
        $service = @(([string]$t['CA.Service']) -split '\|')
        $hours = 0; $crl = 'not read'; if ([int]::TryParse([string]$t['CA.CrlNextHours'], [ref]$hours)) { $crl = $(if ($hours -ge 0) { 'due in {0} h' -f $hours } else { 'OVERDUE by {0} h' -f (-$hours) }) }
        $web = @(([string]$t['CA.WebEnrolment']) -split '\|')
        $facts = @(
            [pscustomobject]@{ Item = 'Certification authority'; Value = ('{0} ({1})' -f $t['CA.Name'], $(if ($types.ContainsKey([string]$t['CA.Type'])) { $types[[string]$t['CA.Type']] } else { 'type not read' })) },
            [pscustomobject]@{ Item = 'Service'; Value = $(if ($service.Count -ge 2) { '{0} (start type {1})' -f $service[0], $service[1] } else { [string]$t['CA.Service'] }) },
            [pscustomobject]@{ Item = 'Its certificate'; Value = $(if ($cert.State -eq 'ok') { '{0}: {1} day(s) left, {2}{3}' -f $cert.Subject, $cert.Days, $cert.Signature, $(if ($cert.Bits) { ', ' + $cert.Bits + ' bits' } else { '' }) } else { 'not read' }) },
            [pscustomobject]@{ Item = 'Key held by'; Value = [string]$t['CA.Provider'] },
            [pscustomobject]@{ Item = 'Next revocation list'; Value = $crl },
            [pscustomobject]@{ Item = 'Web enrolment'; Value = $(if ($web[0] -eq 'present') { 'on this server (SSL flags: {0}; token checking: {1})' -f $(if ($web[1]) { $web[1] } else { 'none' }), $(if ($web[2]) { $web[2] } else { 'not set' }) } else { [string]$t['CA.WebEnrolment'] }) })
        $sections += @{ Heading = 'Certification authority'; Rows = $facts; Columns = @('Item', 'Value') }
        $sections += @{ Heading = 'Certification authority: who may manage it'; Rows = @(Get-RoleRows -S $t -Key 'CA.Managers' -Fields 3 | ForEach-Object { [pscustomobject]@{ Who = $_[0]; Rights = $_[2] } }); Columns = @('Who', 'Rights') }
    } elseif ([string]$t['CA.Read'] -like 'ERROR:*') { $sections += @{ Heading = 'Certification authority'; Lines = @('The certification authority could not be read: ' + ([string]$t['CA.Read']).Substring(6).Trim()) } }
    return $sections
}

function Get-RolesReportSections {
    # The Health report's tables for the roles among the servers: every SQL Server instance, every certification
    # authority.  A table is left out when no server has the role.
    param([string[]]$Servers)
    $sql = @(); $cas = @()
    foreach ($s in @($Servers)) {
        $t = Get-RolesTable -Server $s
        if (-not $t) { continue }
        $checks = @(Get-CheckRows -Console 'Health' -Server $s)
        foreach ($row in @(Get-SqlInstanceRows -Table $t -Server $s)) { $row | Add-Member -NotePropertyName Light -NotePropertyValue (Get-WorstLight -Rows @($checks | Where-Object { [string]$_.Id -like 'H-SQL-*' })) -Force; $sql += $row }
        if ([string]$t['CA.Read'] -eq 'OK') {
            $cert = Get-RoleCertificate -Text ([string]$t['CA.Cert'])
            $hours = 0; $crl = 'not read'; if ([int]::TryParse([string]$t['CA.CrlNextHours'], [ref]$hours)) { $crl = $(if ($hours -ge 0) { 'due in {0} h' -f $hours } else { 'overdue by {0} h' -f (-$hours) }) }
            $cas += [pscustomobject]@{ Server = $s; Light = (Get-WorstLight -Rows @($checks | Where-Object { [string]$_.Id -like 'H-CA-*' })); 'Certification authority' = [string]$t['CA.Name']; Service = (@(([string]$t['CA.Service']) -split '\|')[0]); 'Certificate days left' = $(if ($cert.State -eq 'ok') { $cert.Days } else { 'not read' }); 'Key held by' = [string]$t['CA.Provider']; 'Next revocation list' = $crl; 'Web enrolment' = (@(([string]$t['CA.WebEnrolment']) -split '\|')[0]) }
        }
    }
    $sections = @()
    if ($sql.Count -gt 0) { $sections += @{ Name = 'SQL Server instances'; Rows = $sql; Columns = @('Server', 'Instance', 'Version', 'Edition', 'Engine', 'Agent', 'Listens', 'Encryption', 'Logons', 'Logon audit', 'Errors logged', 'Last backup', 'Light') } }
    if ($cas.Count -gt 0) { $sections += @{ Name = 'Certification authorities'; Rows = $cas; Columns = @('Server', 'Certification authority', 'Service', 'Certificate days left', 'Key held by', 'Next revocation list', 'Web enrolment', 'Light') } }
    return $sections
}
