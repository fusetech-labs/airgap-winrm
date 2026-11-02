# =====================================================================
#  45-Security-Gpo.ps1  -  GPO RECOMMENDATIONS AND THEIR IMPACT
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  For every Security check that has a Group Policy answer
#  (data\gpo-guidance.psd1), on every audited server:
#    1. where it stands: MISSING from Group Policy, a GPO sets a WEAKER
#       value, compliant but NOT ENFORCED by any GPO, or ENFORCED - read
#       from the server's Resultant Set of Policy (collector 'Gpo',
#       lib\13-GroupPolicy.ps1)
#    2. what applying it could break (the guidance's Impact text), and
#       whether that would be FELT on this server: the impact checks
#       ($script:ImpactProbes) look for current use - SMB1 clients, NTLMv1
#       or Basic logons, TLS services, LSA plug-ins, PowerShell 2.0 starts,
#       ASR and AppLocker audit hits ...  Collector 'Impact', read-only.
#    3. one word per server, with its colour: Impact found (red - current
#       use, keep the server out), Check first (amber - the check cannot
#       tell, or there is no check), No impact found / expected (blue),
#       Not checked / Not read (grey); Enforced (green) = a GPO sets it.
#       Green is kept for "in place", so no impact is blue.
#    The value each server has NOW is shown beside it ("not set - Windows
#       default: ..." when nothing sets it; the guidance's Default).
#  The Security console's "GPO recommendations" page shows one row per
#  setting across the servers shown; "GPO plan..." groups them into the
#  recommended GPOs with the servers ready for each and the ones to hold.
#  Nothing here changes a server or a GPO: it recommends.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  45-Security-Gpo.ps1
#  New 2026-10-22.  RemoteImpactScript runs ON the servers.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# The impact checks.  Remote = answered by RemoteImpactScript on the server; the others from what the Settings,
# SecurityPolicy, Health and Status collectors already read.
$script:ImpactProbes = [ordered]@{
    Smb1Sessions       = @{ Remote = $true;  Title = 'SMB1 clients connected now' }
    Smb1Audit          = @{ Remote = $true;  Title = 'SMB1 access log' }
    Smb1Outbound       = @{ Remote = $true;  Title = 'SMB1 connections from this server' }
    SmbClients         = @{ Remote = $true;  Title = 'SMB clients connected now' }
    SmbOutbound        = @{ Remote = $true;  Title = 'SMB connections from this server' }
    NtlmV1Logons       = @{ Remote = $true;  Title = 'LM / NTLMv1 logons' }
    AnonymousLogons    = @{ Remote = $true;  Title = 'anonymous network logons' }
    CleartextLogons    = @{ Remote = $true;  Title = 'Basic (clear-text) logons' }
    BuiltinAdminLogons = @{ Remote = $true;  Title = 'built-in Administrator used remotely' }
    GuestLogons        = @{ Remote = $true;  Title = 'Guest logons' }
    RdpLogons          = @{ Remote = $true;  Title = 'Remote Desktop logons' }
    TlsListeners       = @{ Remote = $true;  Title = 'TLS services listening' }
    NetbtSessions      = @{ Remote = $true;  Title = 'NetBIOS sessions and WINS' }
    PsV2Use            = @{ Remote = $true;  Title = 'PowerShell 2.0 starts' }
    NetFx2Use          = @{ Remote = $true;  Title = 'programs on .NET 2.0 - 3.5' }
    LsaPlugins         = @{ Remote = $true;  Title = 'non-Windows LSA packages' }
    VbsCapable         = @{ Remote = $true;  Title = 'virtualization based security available' }
    AsrAudit           = @{ Remote = $true;  Title = 'ASR audit hits' }
    UsbStorage         = @{ Remote = $true;  Title = 'removable storage present' }
    AppLockerAudit     = @{ Remote = $true;  Title = 'AppLocker audit hits' }
    TrustedHostsList   = @{ Remote = $true;  Title = 'WinRM TrustedHosts in use' }
    Listeners          = @{ Remote = $true;  Title = 'listening TCP ports' }
    SecurityLogSize    = @{ Remote = $false; Title = 'Security log size' }
    LockoutRisk        = @{ Remote = $false; Title = 'accounts failing to log on' }
    RightHolders       = @{ Remote = $false; Title = 'accounts that would lose the right' }
    DiskForLogs        = @{ Remote = $false; Title = 'free space on C:' }
}

function Get-GpoGuidance {
    # data\gpo-guidance.psd1: Gpos (the recommended GPOs) and Settings (one entry per check).
    $d = Import-ToolData -Name 'gpo-guidance.psd1'
    if (-not $d) { return [pscustomobject]@{ AsOf = ''; Gpos = @(); Settings = @() } }
    return [pscustomobject]@{ AsOf = [string]$d.AsOf; Gpos = @($d.Gpos); Settings = @($d.Settings) }
}

# ---------------------------------------------------------------------
#  RUNS ON THE SERVER: every remote impact check, one line each
#  (Name|Level|Evidence; Level = InUse, Review, Clear or Unknown).
#  Read-only: sessions, listening ports, registry, event-log queries.
# ---------------------------------------------------------------------
$script:RemoteImpactScript = {
    param([int]$Days, [int]$MaxEvents)
    $ErrorActionPreference = 'Continue'
    $out = New-Object System.Collections.Generic.List[string]
    $add = { param([string]$Name, [string]$Level, [string]$Evidence) $out.Add(('{0}|{1}|{2}' -f $Name, $Level, (($Evidence -replace '[\r\n]+', ' ') -replace '\|', '/'))) }
    $top = { param($Items, [int]$Take = 5) @($Items | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending | Select-Object -First $Take | ForEach-Object { '{0} ({1}x)' -f $_.Name, $_.Count }) -join ', ' }
    $since = 'TimeCreated[timediff(@SystemTime) <= {0}]' -f ([int64]$Days * 86400000)
    $noMatch = 'NoMatchingEventsFound*'

    # ---- the Security log: how far back it reaches, and whether logons are audited at all ----
    $secError = ''; $oldest = ''; $hasLogons = $false
    try { $oldest = (Get-WinEvent -LogName Security -Oldest -MaxEvents 1 -ErrorAction Stop).TimeCreated.ToString('yyyy-MM-dd') } catch { $secError = $_.Exception.Message }
    if (-not $secError) { try { $hasLogons = (@(Get-WinEvent -LogName Security -FilterXPath "*[System[(EventID=4624) and $since]]" -MaxEvents 1 -ErrorAction Stop).Count -gt 0) } catch { if ($_.FullyQualifiedErrorId -notlike $noMatch) { $secError = $_.Exception.Message } } }
    $span = ''; if ($oldest) { $span = ' (the Security log goes back to ' + $oldest + ')' }
    $logons = {
        # logon events (4624) matching one condition on their data
        param([string]$Name, [string]$Data, [string]$What, [string]$FoundLevel)
        if ($secError) { & $add $Name 'Unknown' ('the Security log could not be read: ' + $secError); return }
        $ev = @()
        try { $ev = @(Get-WinEvent -LogName Security -FilterXPath ("*[System[(EventID=4624) and {0}]] and *[EventData[{1}]]" -f $since, $Data) -MaxEvents $MaxEvents -ErrorAction Stop) }
        catch { if ($_.FullyQualifiedErrorId -notlike $noMatch) { & $add $Name 'Unknown' ('query failed: ' + $_.Exception.Message); return } }
        if ($ev.Count -gt 0) {
            $who = & $top @($ev | ForEach-Object { $p = $_.Properties; $src = [string]$p[11].Value; if (-not $src -or $src -eq '-') { $src = [string]$p[18].Value }; '{0}\{1} from {2}' -f $p[6].Value, $p[5].Value, $src })
            & $add $Name $FoundLevel ('{0}{1} {2} in {3} day(s): {4}' -f $ev.Count, $(if ($ev.Count -ge $MaxEvents) { '+' } else { '' }), $What, $Days, $who)
        } elseif (-not $hasLogons) { & $add $Name 'Unknown' ('no logon event (4624) at all in {0} day(s): logon auditing is off or the log is too small, so earlier use cannot be seen' -f $Days) }
        else { & $add $Name 'Clear' ('no {0} in {1} day(s){2}' -f $What, $Days, $span) }
    }
    & $logons 'NtlmV1Logons' "(Data[@Name='LmPackageName']='NTLM V1' or Data[@Name='LmPackageName']='LM')" 'LM / NTLMv1 logon(s)' 'InUse'
    & $logons 'AnonymousLogons' "Data[@Name='TargetUserSid']='S-1-5-7' and Data[@Name='LogonType']='3'" 'anonymous network logon(s)' 'Review'
    & $logons 'CleartextLogons' "Data[@Name='LogonType']='8'" 'clear-text (Basic) logon(s)' 'InUse'
    & $logons 'RdpLogons' "Data[@Name='LogonType']='10'" 'Remote Desktop logon(s)' 'Review'
    $adminSid = ''; $guestSid = ''; $sidError = ''
    try {
        $adminSid = [string](@(Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE '%-500'" -ErrorAction Stop)[0].SID)
        $guestSid = [string](@(Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE '%-501'" -ErrorAction Stop)[0].SID)
    } catch { $sidError = $_.Exception.Message }   # a lookup that failed is not "no Guest account" (R6-E-L1)
    if ($adminSid) { & $logons 'BuiltinAdminLogons' ("Data[@Name='TargetUserSid']='{0}' and (Data[@Name='LogonType']='3' or Data[@Name='LogonType']='10')" -f $adminSid) 'network or RDP logon(s) with the built-in Administrator' 'Review' }
    else { & $add 'BuiltinAdminLogons' 'Unknown' 'the built-in Administrator account was not found' }
    if ($guestSid) { & $logons 'GuestLogons' ("Data[@Name='TargetUserSid']='{0}'" -f $guestSid) 'Guest logon(s)' 'InUse' }
    elseif ($sidError) { & $add 'GuestLogons' 'Unknown' ('the local accounts could not be listed: ' + $sidError) }
    else { & $add 'GuestLogons' 'Clear' 'no local Guest account' }

    # ---- SMB: who is connected now, and over which dialect ----
    try {
        $ss = @(Get-SmbSession -ErrorAction Stop)
        $v1 = @($ss | Where-Object { [string]$_.Dialect -like '1*' })
        if ($v1.Count -gt 0) { & $add 'Smb1Sessions' 'InUse' ('{0} client(s) connected over SMB1 now: {1}' -f $v1.Count, ((@($v1 | ForEach-Object { $_.ClientComputerName }) | Select-Object -Unique) -join ', ')) }
        else { & $add 'Smb1Sessions' 'Clear' ('{0} SMB session(s) open now, none on SMB1 (only the sessions open now are seen)' -f $ss.Count) }
        $old = @($ss | Where-Object { [string]$_.Dialect -notlike '3*' })
        if ($ss.Count -eq 0) { & $add 'SmbClients' 'Clear' 'no SMB client connected now' }
        elseif ($old.Count -eq 0) { & $add 'SmbClients' 'Clear' ('{0} SMB session(s) open now, all SMB 3.x - these clients sign' -f $ss.Count) }
        else { & $add 'SmbClients' 'Review' ('{0} session(s) on SMB 1 / 2 now - confirm each client can sign: {1}' -f $old.Count, ((@($old | ForEach-Object { '{0} (SMB {1})' -f $_.ClientComputerName, $_.Dialect }) | Select-Object -Unique) -join ', ')) }
    } catch { foreach ($n in 'Smb1Sessions', 'SmbClients') { & $add $n 'Unknown' ('SMB sessions not readable: ' + $_.Exception.Message) } }
    try {
        $cfg = Get-SmbServerConfiguration -ErrorAction Stop
        if (-not $cfg.EnableSMB1Protocol) { & $add 'Smb1Audit' 'Clear' 'SMB1 is already off on this server' }
        elseif (-not $cfg.AuditSmb1Access) { & $add 'Smb1Audit' 'Unknown' 'SMB1 access auditing (AuditSmb1Access) is off, so earlier SMB1 use cannot be seen - only the sessions open now' }
        else {
            $ev = @()
            try { $ev = @(Get-WinEvent -LogName 'Microsoft-Windows-SMBServer/Audit' -FilterXPath "*[System[(EventID=3000) and $since]]" -MaxEvents $MaxEvents -ErrorAction Stop) } catch { if ($_.FullyQualifiedErrorId -notlike $noMatch) { throw } }
            if ($ev.Count -gt 0) { & $add 'Smb1Audit' 'InUse' ('{0} SMB1 access(es) in {1} day(s): {2}' -f $ev.Count, $Days, (& $top @($ev | ForEach-Object { if ($_.Message -match 'Client Address:\s*(\S+)') { $Matches[1] } }))) }
            else { & $add 'Smb1Audit' 'Clear' ('SMB1 access is audited and nobody used it in {0} day(s)' -f $Days) }
        }
    } catch { & $add 'Smb1Audit' 'Unknown' ('not readable: ' + $_.Exception.Message) }
    try {
        $cn = @(Get-SmbConnection -ErrorAction Stop)
        $v1 = @($cn | Where-Object { [string]$_.Dialect -like '1*' })
        if ($v1.Count -gt 0) { & $add 'Smb1Outbound' 'InUse' ('this server is connected over SMB1 to: ' + ((@($v1 | ForEach-Object { $_.ServerName }) | Select-Object -Unique) -join ', ')) }
        else { & $add 'Smb1Outbound' 'Clear' ('{0} outgoing SMB connection(s) now, none on SMB1' -f $cn.Count) }
        $old = @($cn | Where-Object { [string]$_.Dialect -notlike '3*' })
        if ($cn.Count -eq 0) { & $add 'SmbOutbound' 'Clear' 'no outgoing SMB connection now' }
        elseif ($old.Count -eq 0) { & $add 'SmbOutbound' 'Clear' ('{0} outgoing SMB connection(s) now, all SMB 3.x' -f $cn.Count) }
        else { & $add 'SmbOutbound' 'Review' ('connected over SMB 1 / 2 to: {0} - confirm they can sign' -f ((@($old | ForEach-Object { '{0} (SMB {1})' -f $_.ServerName, $_.Dialect }) | Select-Object -Unique) -join ', ')) }
    } catch { foreach ($n in 'Smb1Outbound', 'SmbOutbound') { & $add $n 'Unknown' ('SMB connections not readable: ' + $_.Exception.Message) } }

    # ---- listening services ----
    $procName = { param($Id) try { (Get-Process -Id $Id -ErrorAction Stop).ProcessName } catch { '?' } }
    try {
        $listen = @(Get-NetTCPConnection -State Listen -ErrorAction Stop | Where-Object { $_.LocalAddress -notin '127.0.0.1', '::1' } | Sort-Object LocalPort -Unique)
        $tlsPorts = @{ 443 = 'HTTPS'; 636 = 'LDAPS'; 3269 = 'global catalog over TLS'; 1433 = 'SQL Server'; 5986 = 'WinRM HTTPS'; 8443 = 'HTTPS'; 4443 = 'HTTPS'; 9443 = 'HTTPS'; 993 = 'IMAPS'; 995 = 'POP3S'; 465 = 'SMTPS'; 587 = 'SMTP'; 990 = 'FTPS' }
        $tls = @($listen | Where-Object { $tlsPorts.ContainsKey([int]$_.LocalPort) } | ForEach-Object { '{0} {1} ({2})' -f $_.LocalPort, $tlsPorts[[int]$_.LocalPort], (& $procName $_.OwningProcess) })
        if ($tls.Count -gt 0) { & $add 'TlsListeners' 'Review' ('TLS services listening: {0} - their clients must be able to use TLS 1.2 (Remote Desktop is fine)' -f ($tls -join ', ')) }
        else { & $add 'TlsListeners' 'Clear' 'no TLS service listening apart from Remote Desktop' }
        $all = @($listen | Select-Object -First 30 | ForEach-Object { '{0} ({1})' -f $_.LocalPort, (& $procName $_.OwningProcess) })
        & $add 'Listeners' 'Review' ('{0} listening TCP port(s): {1} - each one clients need must have an allow rule before inbound is blocked' -f $listen.Count, ($all -join ', '))
    } catch { foreach ($n in 'TlsListeners', 'Listeners') { & $add $n 'Unknown' ('listening ports not readable: ' + $_.Exception.Message) } }
    try {
        $nb = @(Get-NetTCPConnection -State Established -LocalPort 139 -ErrorAction SilentlyContinue)
        $wins = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction Stop | Where-Object { $_.WINSPrimaryServer } | ForEach-Object { $_.WINSPrimaryServer })
        if ($nb.Count -gt 0) { & $add 'NetbtSessions' 'InUse' ('{0} connection(s) on NetBIOS port 139 now, from {1}' -f $nb.Count, ((@($nb | ForEach-Object { $_.RemoteAddress }) | Select-Object -Unique) -join ', ')) }
        elseif ($wins.Count -gt 0) { & $add 'NetbtSessions' 'Review' ('WINS server(s) configured: {0} - something may still rely on NetBIOS names' -f (($wins | Select-Object -Unique) -join ', ')) }
        else { & $add 'NetbtSessions' 'Clear' 'no connection on NetBIOS port 139 now and no WINS server configured' }
    } catch { & $add 'NetbtSessions' 'Unknown' ('not readable: ' + $_.Exception.Message) }

    # ---- programs and components ----
    try {
        $ev = @()
        try { $ev = @(Get-WinEvent -LogName 'Windows PowerShell' -FilterXPath "*[System[(EventID=400) and $since]]" -MaxEvents $MaxEvents -ErrorAction Stop) } catch { if ($_.FullyQualifiedErrorId -notlike $noMatch) { throw } }
        $v2 = @($ev | Where-Object { $_.Message -match 'EngineVersion=2\.' })
        if ($v2.Count -gt 0) { & $add 'PsV2Use' 'InUse' ('PowerShell 2.0 started {0} time(s) in {1} day(s): {2}' -f $v2.Count, $Days, (& $top @($v2 | ForEach-Object { if ($_.Message -match 'HostApplication=([^\r\n]+)') { $h = $Matches[1].Trim(); if ($h.Length -gt 100) { $h.Substring(0, 100) + '...' } else { $h } } }) 3)) }
        else { & $add 'PsV2Use' 'Clear' ('no PowerShell 2.0 start in {0} day(s) ({1} PowerShell start(s) logged)' -f $Days, $ev.Count) }
    } catch { & $add 'PsV2Use' 'Unknown' ('the Windows PowerShell log could not be read: ' + $_.Exception.Message) }
    try {
        $clr2 = @(@(& tasklist.exe /m mscorwks.dll /fo csv /nh 2>$null) | ConvertFrom-Csv -Header Image, Pid, Modules | Where-Object { $_.Image -like '*.exe' } | ForEach-Object { $_.Image } | Select-Object -Unique)
        if ($clr2.Count -gt 0) { & $add 'NetFx2Use' 'InUse' ('running on .NET 2.0 - 3.5 now: ' + ($clr2 -join ', ')) }
        else { & $add 'NetFx2Use' 'Clear' 'no running program uses .NET 2.0 - 3.5 (a program that runs only now and then is not seen)' }
    } catch { & $add 'NetFx2Use' 'Unknown' ('tasklist failed: ' + $_.Exception.Message) }
    try {
        $lsa = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -ErrorAction Stop
        $known = @('msv1_0', 'kerberos', 'schannel', 'wdigest', 'tspkg', 'pku2u', 'cloudap', 'negoexts', 'livessp', 'scecli', 'rassfm', 'msoidssp', 'negotiate')
        $pkgs = @(@($lsa.'Authentication Packages') + @($lsa.'Notification Packages') + @($lsa.'Security Packages') + @((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\OSConfig' -ErrorAction SilentlyContinue).'Security Packages'))
        $extra = @($pkgs | ForEach-Object { ([string]$_).Trim('"', ' ').ToLower() } | Where-Object { $_ -and $known -notcontains $_ } | Select-Object -Unique)
        if ($extra.Count -gt 0) { & $add 'LsaPlugins' 'Review' ('LSA loads packages that are not part of Windows: {0} - ask their vendor whether they are signed for LSA protection' -f ($extra -join ', ')) }
        else { & $add 'LsaPlugins' 'Clear' 'only Windows'' own LSA packages are loaded' }
    } catch { & $add 'LsaPlugins' 'Unknown' ('not readable: ' + $_.Exception.Message) }
    try {
        $dg = Get-CimInstance -Namespace 'root\Microsoft\Windows\DeviceGuard' -ClassName Win32_DeviceGuard -ErrorAction Stop
        $avail = @($dg.AvailableSecurityProperties)
        if ($avail -contains 1) { & $add 'VbsCapable' 'Clear' ('virtualization based security can run here (available properties: {0})' -f ($avail -join ', ')) }
        else { & $add 'VbsCapable' 'Review' 'virtualization based security is not available: the hardware (or the VM) does not offer virtualisation support, so the setting would have no effect until it does' }
    } catch { & $add 'VbsCapable' 'Unknown' ('not readable: ' + $_.Exception.Message) }
    try {
        $pref = Get-MpPreference -ErrorAction Stop
        $audit = @(@($pref.AttackSurfaceReductionRules_Actions) | Where-Object { [int]$_ -eq 2 }).Count
        $ev = @()
        try { $ev = @(Get-WinEvent -LogName 'Microsoft-Windows-Windows Defender/Operational' -FilterXPath "*[System[(EventID=1122) and $since]]" -MaxEvents $MaxEvents -ErrorAction Stop) } catch { if ($_.FullyQualifiedErrorId -notlike $noMatch) { throw } }
        if ($ev.Count -gt 0) { & $add 'AsrAudit' 'InUse' ('{0} audit hit(s) in {1} day(s) - block mode would have stopped: {2}' -f $ev.Count, $Days, (& $top @($ev | ForEach-Object { if ($_.Message -match 'Process Name:\s*([^\r\n]+)') { $Matches[1].Trim() } }) 3)) }
        elseif ($audit -eq 0) { & $add 'AsrAudit' 'Unknown' 'no attack surface reduction rule is in audit mode, so what block mode would stop cannot be seen - run the rules in audit (2) first' }
        else { & $add 'AsrAudit' 'Clear' ('{0} rule(s) in audit mode, no hit in {1} day(s)' -f $audit, $Days) }
    } catch { & $add 'AsrAudit' 'Unknown' ('Defender not readable: ' + $_.Exception.Message) }
    try {
        $usb = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop | Where-Object { $_.InterfaceType -eq 'USB' } | ForEach-Object { $_.Model })
        $cd = @(Get-CimInstance -ClassName Win32_CDROMDrive -ErrorAction SilentlyContinue | ForEach-Object { '{0} {1}' -f $_.Drive, $_.Caption })
        if ($usb.Count -gt 0) { & $add 'UsbStorage' 'Review' ('USB disk(s) attached: ' + ($usb -join ', ')) }
        elseif ($cd.Count -gt 0) { & $add 'UsbStorage' 'Review' ('a CD / DVD drive is present - "deny all" blocks it too (an ISO mounted to the VM): ' + ($cd -join ', ')) }
        else { & $add 'UsbStorage' 'Clear' 'no USB disk and no CD / DVD drive' }
    } catch { & $add 'UsbStorage' 'Unknown' ('not readable: ' + $_.Exception.Message) }
    try {
        $modes = @()
        try { $x = [xml](Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop); $modes = @($x.AppLockerPolicy.RuleCollection | ForEach-Object { [string]$_.EnforcementMode }) } catch { }
        $ev = @()
        # "no events" is the one failure that means nothing happened; any other failure to read a log is not "Clear" (R6-E-L1)
        $logError = ''
        foreach ($lg in 'Microsoft-Windows-AppLocker/EXE and DLL', 'Microsoft-Windows-AppLocker/MSI and Script') { try { $ev += @(Get-WinEvent -LogName $lg -FilterXPath "*[System[(EventID=8003 or EventID=8006) and $since]]" -MaxEvents $MaxEvents -ErrorAction Stop) } catch { if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') { $logError = $lg + ': ' + $_.Exception.Message } } }
        if ($ev.Count -eq 0 -and $logError -and $modes -contains 'AuditOnly') { throw ('an AppLocker log could not be read - ' + $logError) }
        if ($ev.Count -gt 0) { & $add 'AppLockerAudit' 'InUse' ('{0} audit hit(s) in {1} day(s) - enforcement would block: {2}' -f $ev.Count, $Days, (& $top @($ev | ForEach-Object { ([string]$_.Message -split ' was allowed')[0] }) 3)) }
        elseif ($modes -notcontains 'AuditOnly') { & $add 'AppLockerAudit' 'Unknown' 'AppLocker is not in audit mode, so what enforcement would block cannot be seen - audit first' }
        else { & $add 'AppLockerAudit' 'Clear' ('AppLocker in audit mode: nothing would have been blocked in {0} day(s)' -f $Days) }
    } catch { & $add 'AppLockerAudit' 'Unknown' ('not readable: ' + $_.Exception.Message) }
    try {
        $th = [string](Get-Item -LiteralPath 'WSMan:\localhost\Client\TrustedHosts' -ErrorAction Stop).Value
        if ($th) { & $add 'TrustedHostsList' 'Review' ('remoting from this server trusts: ' + $th) } else { & $add 'TrustedHostsList' 'Clear' 'TrustedHosts is empty' }
    } catch { & $add 'TrustedHostsList' 'Unknown' ('not readable: ' + $_.Exception.Message) }

    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Days = $Days; Probes = $out.ToArray(); SecurityLogFrom = $oldest }
}

function Get-ServerImpact {
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = { param($r) $l = @($r.Probes | ForEach-Object { ($_ -split '\|')[1] }); ('{0} impact check(s): {1} in use, {2} to review, {3} unknown, {4} clear' -f $l.Count, @($l | Where-Object { $_ -eq 'InUse' }).Count, @($l | Where-Object { $_ -eq 'Review' }).Count, @($l | Where-Object { $_ -eq 'Unknown' }).Count, @($l | Where-Object { $_ -eq 'Clear' }).Count) }
    return (Invoke-Collector -Name 'Impact' -ScriptBlock $script:RemoteImpactScript -ComputerName $ComputerName -ArgumentList @([int]$script:Config.ImpactDays, [int]$script:Config.MaxEvents) -Summary $summary -TimeoutSec 900)
}

function Get-ServerSettingsTable {
    # The Settings and SecurityPolicy values of one server as one table (what the checks read).
    param([string]$Server)
    $sets = @()
    $a = Get-CollectorResult -Name 'Settings' -Server $Server; if ($a -and $a.Reachable) { $sets += , @($a.Lines) }
    $b = Get-CollectorResult -Name 'SecurityPolicy' -Server $Server; if ($b -and $b.Reachable) { $sets += , @($b.Lines) }
    if ($sets.Count -eq 0) { return @{} }
    return (ConvertTo-SettingsTable -LineSets $sets)
}

function Get-ImpactProbeResult {
    # One impact check on one server: @{ Level = InUse / Review / Clear / Unknown / NotCollected; Evidence }.
    param([string]$Server, [string]$Probe, $Entry, [hashtable]$Values)
    $spec = $script:ImpactProbes[$Probe]
    if (-not $spec) { return [pscustomobject]@{ Level = 'Unknown'; Evidence = "no impact check called '$Probe' (data\gpo-guidance.psd1)" } }
    if ($spec.Remote) {
        $r = Get-CollectorResult -Name 'Impact' -Server $Server
        if (-not $r) { return [pscustomobject]@{ Level = 'NotCollected'; Evidence = 'not checked yet - press "Check impact"' } }
        if (-not $r.Reachable) { return [pscustomobject]@{ Level = 'NotCollected'; Evidence = 'impact check failed: ' + $r.Error } }
        $line = @($r.Probes | Where-Object { ([string]$_ -split '\|')[0] -eq $Probe })[0]
        if (-not $line) { return [pscustomobject]@{ Level = 'Unknown'; Evidence = 'the server did not answer this check' } }
        $f = [string]$line -split '\|', 3
        return [pscustomobject]@{ Level = $f[1]; Evidence = $f[2] }
    }
    if ($null -eq $Values) { $Values = Get-ServerSettingsTable -Server $Server }
    switch ($Probe) {
        'SecurityLogSize' {
            $mb = 0
            if (-not [int]::TryParse([string]$Values['EventLog.Security.MaxMB'], [ref]$mb)) { return [pscustomobject]@{ Level = 'Unknown'; Evidence = 'the Security log size was not read' } }
            if ($mb -ge 192) { return [pscustomobject]@{ Level = 'Clear'; Evidence = "the Security log is $mb MB" } }
            return [pscustomobject]@{ Level = 'Review'; Evidence = "the Security log is only $mb MB: more audit events roll it over sooner (SEC-LOG-02 asks for 192 MB)" }
        }
        'LockoutRisk' {
            $h = Get-CollectorResult -Name 'Health' -Server $Server
            if (-not $h -or -not $h.Reachable) { return [pscustomobject]@{ Level = 'Unknown'; Evidence = 'failed logons not read - run "Check health" on the Health tab' } }
            $bad = @(ConvertFrom-PipeLines -Lines $h.LogonFailures -Columns @('Count', 'Account', 'Source', 'Type', 'Last') | Where-Object { [int]$_.Count -ge 5 })
            if ($bad.Count -eq 0) { return [pscustomobject]@{ Level = 'Clear'; Evidence = ('no account failed 5 times or more in {0} h' -f $h.WindowHours) } }
            return [pscustomobject]@{ Level = 'Review'; Evidence = ('these would lock out: ' + ((@($bad | Select-Object -First 5 | ForEach-Object { '{0} ({1} failures from {2})' -f $_.Account, $_.Count, $_.Source })) -join ', ')) }
        }
        'RightHolders' {
            $def = @((Get-SecuritySettingsTable).Settings | Where-Object { $_.Id -eq $Entry.Check })[0]
            if (-not $def) { return [pscustomobject]@{ Level = 'Unknown'; Evidence = 'no expected value for this right' } }
            if (-not $Values.ContainsKey([string]$def.Key)) { return [pscustomobject]@{ Level = 'Clear'; Evidence = 'no account holds it' } }
            $allowed = @([string]$def.Expected -split ';' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
            $lose = @([string]$Values[[string]$def.Key] -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $allowed -notcontains $_.ToLower() })
            if ($lose.Count -eq 0) { return [pscustomobject]@{ Level = 'Clear'; Evidence = 'no account would lose it' } }
            return [pscustomobject]@{ Level = 'Review'; Evidence = ('would lose the right: ' + ($lose -join ', ')) }
        }
        'DiskForLogs' {
            $s = $script:ServerStatus[$Server]
            $gb = 0.0
            if ($s) { $gb = ConvertTo-HealthNumber $s.FreeGB }   # invariant: a comma-decimal PC read 9.5 as 95 (R6-E-L2)
            if (-not $s -or $null -eq $gb) { return [pscustomobject]@{ Level = 'Unknown'; Evidence = 'free space on C: not read' } }
            if ($gb -lt 10) { return [pscustomobject]@{ Level = 'Review'; Evidence = ('C: has only {0} GB free' -f $gb) } }
            return [pscustomobject]@{ Level = 'Clear'; Evidence = ('C: has {0} GB free' -f $gb) }
        }
    }
    return [pscustomobject]@{ Level = 'Unknown'; Evidence = "impact check '$Probe' has no local rule" }
}

# The colour of the Impact cell - the only coloured cell on the page.  Blue = no impact found: green is kept for
# "Enforced", so a colour never suggests a setting is already in place when it is not.
$script:ImpactCellColours = @{ Red = 'LightCoral'; Amber = 'Khaki'; Grey = 'Gainsboro'; Blue = 'LightSkyBlue'; Green = 'PaleGreen' }

# Well-known accounts in user-right values (secedit lists SIDs)
$script:WellKnownSids = @{
    'S-1-1-0' = 'Everyone'; 'S-1-5-6' = 'SERVICE'; 'S-1-5-7' = 'ANONYMOUS LOGON'; 'S-1-5-9' = 'Enterprise Domain Controllers'; 'S-1-5-11' = 'Authenticated Users'
    'S-1-5-19' = 'LOCAL SERVICE'; 'S-1-5-20' = 'NETWORK SERVICE'; 'S-1-5-113' = 'Local account'; 'S-1-5-114' = 'Local account and member of Administrators'
    'S-1-5-32-544' = 'Administrators'; 'S-1-5-32-545' = 'Users'; 'S-1-5-32-546' = 'Guests'; 'S-1-5-32-550' = 'Print Operators'; 'S-1-5-32-551' = 'Backup Operators'
    'S-1-5-32-555' = 'Remote Desktop Users'; 'S-1-5-32-568' = 'IIS_IUSRS'
}

function Format-SidList {
    # "*S-1-5-32-544,*S-1-5-21-...-1105" -> "Administrators, S-1-5-21-...-1105"
    param([string]$Text)
    return ((@($Text -split '[,;]') | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object { $sid = $_.TrimStart('*'); if ($script:WellKnownSids[$sid]) { $script:WellKnownSids[$sid] } else { $sid } }) -join ', ')
}

function Get-ImpactVerdict {
    # Would applying this entry be felt on this server?  @{ Light; Impact; Text; Found }:
    #   Red   'Impact found'        a check found current use
    #   Amber 'Check first'         a check could not tell or found something to review; or there is no check and the
    #                               guidance says Review
    #   Blue  'No impact found'     every check found no sign of use
    #         'No impact expected'  there is no check and the guidance expects none (or little)
    #   Grey  'Not checked'         the impact checks have not run on this server yet
    # Text = every check's answer; Found = the answers that decided it (what the page shows).
    param([string]$Server, $Entry, [hashtable]$Values)
    $probes = @(@($Entry.Probes) | Where-Object { $_ })
    if ($probes.Count -eq 0) {
        switch ([string]$Entry.Expect) {
            'None' { return [pscustomobject]@{ Light = 'Blue'; Impact = 'No impact expected'; Text = 'no impact expected'; Found = 'none expected' } }
            'Low' { $t = 'low: ' + [string]$Entry.Impact; return [pscustomobject]@{ Light = 'Blue'; Impact = 'No impact expected'; Text = $t; Found = $t } }
            default { $t = 'no automatic check - ' + [string]$Entry.Impact; return [pscustomobject]@{ Light = 'Amber'; Impact = 'Check first'; Text = $t; Found = $t } }
        }
    }
    $answers = @(foreach ($p in $probes) {
        $r = Get-ImpactProbeResult -Server $Server -Probe $p -Entry $Entry -Values $Values
        $title = $p; if ($script:ImpactProbes[$p]) { $title = $script:ImpactProbes[$p].Title }
        [pscustomobject]@{ Level = $r.Level; Line = ('{0}: {1}' -f $title, $r.Evidence); Evidence = [string]$r.Evidence }
    })
    $text = (@($answers | ForEach-Object { $_.Line }) -join '; ')
    $levels = @($answers | ForEach-Object { $_.Level })
    # Found: the evidence alone (each check's answer already says what it looked at); Text keeps the check names too
    $pick = { param([string[]]$Want) (@($answers | Where-Object { $_.Level -in $Want } | ForEach-Object { $_.Evidence }) -join '; ') }
    if ($levels -contains 'InUse') { return [pscustomobject]@{ Light = 'Red'; Impact = 'Impact found'; Text = $text; Found = (& $pick @('InUse')) } }
    if ($levels -contains 'NotCollected') { return [pscustomobject]@{ Light = 'Grey'; Impact = 'Not checked'; Text = $text; Found = (& $pick @('NotCollected')) } }   # "not checked yet - press Check impact", or why the check failed
    if ($levels -contains 'Review' -or $levels -contains 'Unknown') { return [pscustomobject]@{ Light = 'Amber'; Impact = 'Check first'; Text = $text; Found = (& $pick @('Review', 'Unknown')) } }
    return [pscustomobject]@{ Light = 'Blue'; Impact = 'No impact found'; Text = $text; Found = $text }
}

function Get-GuidedNow {
    # The value a guided setting has on one server now, in words: the value, "not set - Windows default: ...", the
    # accounts of a user right, or a code check's own summary; "(GPO: <name>)" when a GPO sets it.
    param($Entry, $Row, [hashtable]$Values, $Def, $Source, [bool]$CleanPolicy)
    $now = ''
    if ($Def -and $Def.Key) {
        $key = [string]$Def.Key
        if ($Values.ContainsKey($key)) { $now = [string]$Values[$key] }
        elseif ($key -like 'Right:*' -and $CleanPolicy) { $now = '(no account)' }
        else { $now = '(not read)' }
        if ($now -in 'NotConfigured', '') { $now = 'not set' + $(if ($Entry.Default) { ' - ' + [string]$Entry.Default } else { '' }) }
        elseif ($key -like 'Right:*' -and $now -ne '(no account)') { $now = Format-SidList $now }
    } else {
        $now = [string]$Row.Summary
    }
    if ($now.Length -gt 140) { $now = $now.Substring(0, 140) + '...' }
    if ($Source -and $Source.SetBy) { $now += ' (GPO: ' + $Source.SetBy + ')' }
    return $now
}

function Get-GpoGapRows {
    # One audited server: one row per check that has guidance - where it stands against Group Policy, its value now and
    # the impact of closing the gap.  Status: Missing from GPO / Weaker in GPO / Not enforced / Enforced / Not compliant /
    # Compliant / Not read.
    param([string]$Server)
    if (-not (Test-SecurityCollected -Server $Server)) { return @() }
    # kept in the check-row cache under "GpoGaps|<server>": every repaint and every keystroke in Find asked for these rows
    # again (90 settings x a scan of the server's RSoP each).  Cleared with the server's rows: a new audit, impact check or
    # Group Policy read (Invoke-Collector), a profile, tailoring or data-file change.
    if (-not $script:CheckRowCache) { $script:CheckRowCache = @{} }
    $cacheKey = 'GpoGaps|' + $Server
    if ($script:CheckRowCache.ContainsKey($cacheKey)) { return @($script:CheckRowCache[$cacheKey]) }
    $rows = @(Get-GpoGapRowsFresh -Server $Server)
    $script:CheckRowCache[$cacheKey] = $rows
    return $rows
}

function Get-GpoGapRowsFresh {
    # Get-GpoGapRows without the cache: the rows worked out from the server's check rows, Group Policy and impact results.
    param([string]$Server)
    $checks = @{}; foreach ($r in (Get-SecurityRows -Server $Server)) { $checks[$r.Id] = $r }
    $defs = @{}; foreach ($d in @((Get-SecuritySettingsTable).Settings)) { $defs[[string]$d.Id] = $d }
    $g = Get-CollectorResult -Name 'Gpo' -Server $Server
    $sp = Get-CollectorResult -Name 'SecurityPolicy' -Server $Server
    $clean = [bool]($sp -and $sp.Reachable -and @($sp.Errors).Count -eq 0 -and @($sp.Lines).Count -gt 0)
    $values = Get-ServerSettingsTable -Server $Server
    $why = ''
    if (-not $g) { $why = 'Group Policy not read yet - AUDIT again' }
    elseif (-not $g.Reachable) { $why = 'Group Policy not readable: ' + $g.Error }
    elseif ($null -eq $g.Joined) { $why = 'domain membership could not be read - AUDIT again' }
    elseif (-not $g.Joined) { $why = 'not a domain member: set it in the local policy (or join the domain)' }
    elseif ($g.RsopError) { $why = 'which GPO sets what (RSoP) was not readable - an administrator is needed: ' + $g.RsopError }
    $out = @()
    foreach ($e in @((Get-GpoGuidance).Settings)) {
        $r = $checks[[string]$e.Check]
        if (-not $r -or $r.Verdict -in 'NotApplicable', 'NotAssessable') { continue }   # not for this server, or not a server setting
        # a recorded risk decision hides the recommendation only while it is in date: an overdue one counts as not compliant
        # in the figures, so it is a gap here too (R6-E-M5)
        if ($r.Verdict -eq 'RiskAccepted' -and [string]$r.Tailoring -notmatch 'review overdue') { continue }
        $compliant = ($r.Verdict -eq 'Pass')
        $specs = @(@($e.Rsop) | Where-Object { $_ })
        $src = Get-GpoSettingSource -Server $Server -Specs $specs
        $now = Get-GuidedNow -Entry $e -Row $r -Values $values -Def $defs[[string]$e.Check] -Source $src -CleanPolicy $clean
        $note = ''
        # a value the audit could not read is not a known gap: no GPO is recommended for it until it is read
        $unread = ($r.Verdict -eq 'Error' -or ($r.Verdict -eq 'Warn' -and (Test-UnreadEvidence -Evidence $r.Evidence)))   # the one test the compliance figures use too
        if ($unread) {
            $status = 'Not read'; $note = $why
            $impact = [pscustomobject]@{ Light = 'Grey'; Impact = 'Not read'; Text = 'the audit could not read this value here (an administrator is needed for auditpol, secedit and some logs)'; Found = 'the audit could not read it here' }
        } else {
            if ($specs.Count -eq 0) { $status = $(if ($compliant) { 'Compliant' } else { 'Not compliant' }); $note = 'not visible in Group Policy results (a feature, firmware, or Group Policy Preferences)' }
            elseif (-not $src.Known) { $status = $(if ($compliant) { 'Compliant' } else { 'Not compliant' }); $note = $why }
            elseif ($src.SetBy) { $status = $(if ($compliant) { 'Enforced' } else { 'Weaker in GPO' }) }
            else { $status = $(if ($compliant) { 'Not enforced' } else { 'Missing from GPO' }) }
            if ($status -in 'Enforced', 'Compliant') { $impact = [pscustomobject]@{ Light = 'Green'; Impact = $status; Text = 'compliant'; Found = 'compliant' } }
            elseif ($compliant) { $impact = [pscustomobject]@{ Light = 'Blue'; Impact = 'No impact found'; Text = 'already compliant here: enforcing it with a GPO changes nothing on this server'; Found = 'already compliant - enforcing it changes nothing' } }
            else { $impact = Get-ImpactVerdict -Server $Server -Entry $e -Values $values }
        }
        $out += [pscustomobject]@{
            Server = $Server; Id = $r.Id; Title = $r.Title; Verdict = $r.Verdict; Status = $status; Gap = ($status -notin 'Enforced', 'Compliant', 'Not read'); Compliant = $compliant   # not read is no known gap: no GPO on a guess (R6-E-M1)
            Now = $now; 'Set by' = $src.SetBy; 'GPO value' = $src.Value; Gpo = [string]$e.Gpo; Path = [string]$e.Path; Value = [string]$e.Value; 'What could break' = [string]$e.Impact
            Light = $impact.Light; Impact = $impact.Impact; Found = $impact.Found; 'Impact evidence' = $impact.Text; Evidence = $r.Evidence; Note = $note
        }
    }
    return $out
}

function Get-WorstImpactLight {
    # Red beats Grey (not checked: it could be red) beats Amber beats Blue beats Green: one server decides the row.
    param([string[]]$Lights)
    foreach ($l in 'Red', 'Grey', 'Amber', 'Blue', 'Green') { if ($Lights -contains $l) { return $l } }
    return 'Grey'
}

function Join-Limited {
    # Items joined with '; ', cut with "(+N more)" so a grid cell stays readable.
    param([string[]]$Items, [int]$Max = 3)
    $list = @($Items | Where-Object { $_ })
    if ($list.Count -le $Max) { return ($list -join '; ') }
    return ((@($list | Select-Object -First $Max) -join '; ') + ('; (+{0} more)' -f ($list.Count - $Max)))
}

function Get-GpoGapSummaryRows {
    # The GPO recommendations page: one row per setting across the servers shown (only settings with a gap, unless -All),
    # in the order of the recommended GPOs, so they can be worked through one GPO at a time.
    param([string[]]$Servers, [switch]$All, [object[]]$GapRows = $null)
    $perServer = $GapRows; if ($null -eq $perServer) { $perServer = @(foreach ($s in $Servers) { Get-GpoGapRows -Server $s }) }
    $guide = Get-GpoGuidance
    $order = @{}; $i = 0; foreach ($gp in @($guide.Gpos)) { $order[[string]$gp.Name] = $i; $i++ }
    $out = @()
    $n = 0
    foreach ($e in @($guide.Settings)) {
        $n++
        $mine = @($perServer | Where-Object { $_.Id -eq $e.Check })
        if ($mine.Count -eq 0) { continue }
        $gaps = @($mine | Where-Object { $_.Gap })
        $unreadHere = @($mine | Where-Object { $_.Status -eq 'Not read' })   # shown and counted, but no gap: no GPO on a guess (R6-E-M1)
        if ($gaps.Count -eq 0 -and $unreadHere.Count -eq 0 -and -not $All) { continue }
        $count = { param($st) @($mine | Where-Object { $_.Status -eq $st }).Count }
        $parts = @()
        foreach ($pair in @(@('Missing from GPO', 'missing on {0}'), @('Weaker in GPO', 'weaker in a GPO on {0}'), @('Not compliant', 'not compliant on {0}'), @('Not enforced', 'not enforced on {0}'), @('Not read', 'not read on {0}'))) { $c = & $count $pair[0]; if ($c -gt 0) { $parts += ($pair[1] -f $c) } }
        # no gap anywhere: "Enforced" only when a GPO sets it somewhere; a setting Group Policy cannot see (a feature, firmware)
        # that is simply right everywhere is "Compliant"
        $anyEnforced = @($mine | Where-Object { $_.Status -eq 'Enforced' }).Count -gt 0
        if ($parts.Count -eq 0) { $parts += $(if ($anyEnforced) { 'enforced on all {0}' -f $mine.Count } else { 'compliant on all {0}' -f $mine.Count }) }
        $serversOf = { param([string[]]$Lights) @($gaps | Where-Object { $_.Light -in $Lights } | ForEach-Object { $_.Server }) }
        $light = 'Green'; if ($gaps.Count -gt 0) { $light = Get-WorstImpactLight -Lights @($gaps | ForEach-Object { $_.Light }) }
        $decisive = @($gaps | Where-Object { $_.Light -eq $light })
        $word = 'Enforced'; $details = 'enforced by Group Policy on every server shown'
        if (-not $anyEnforced) { $word = 'Compliant'; $details = 'compliant on every server shown (not a Group Policy setting, or not visible in its results)' }
        # no known gap, but not read on every server: grey, never green on a guess - the unread servers decide the row
        if ($light -eq 'Green' -and $unreadHere.Count -gt 0) { $light = 'Grey'; $decisive = $unreadHere }
        switch ($light) {
            'Red' { $word = 'Impact found'; $details = Join-Limited -Items @($decisive | ForEach-Object { '{0}: {1}' -f $_.Server, $_.Found }) }
            'Amber' { $word = 'Check first'; $details = Join-Limited -Items @($decisive | Group-Object Found | ForEach-Object { '{0} ({1})' -f $_.Name, (@($_.Group | ForEach-Object { $_.Server }) -join ', ') }) -Max 2 }
            'Grey' {
                if (@($decisive | Where-Object { $_.Impact -eq 'Not checked' }).Count -gt 0) { $word = 'Not checked'; $details = ('impact not checked on {0} server(s) - press Check impact' -f @($decisive | Where-Object { $_.Impact -eq 'Not checked' }).Count) }
                else { $word = 'Not read'; $details = ('the audit could not read the value on {0} server(s) - an administrator is needed' -f $decisive.Count) }
            }
            'Blue' {
                $word = 'No impact found'
                $expected = @($decisive | Where-Object { $_.Impact -eq 'No impact expected' })
                $found = @($decisive | Where-Object { $_.Impact -eq 'No impact found' -and -not $_.Compliant })
                $already = @($decisive | Where-Object { $_.Compliant })
                if ($expected.Count -eq $decisive.Count) { $word = 'No impact expected'; $details = [string]$decisive[0].Found }
                else {
                    $bits = @()
                    if ($found.Count -gt 0) { $bits += ('no sign of use on {0} server(s)' -f $found.Count) }
                    if ($expected.Count -gt 0) { $bits += ('no impact expected on {0}' -f $expected.Count) }
                    if ($already.Count -gt 0) { $bits += ('already compliant on {0} - enforcing it changes nothing' -f $already.Count) }
                    $details = $bits -join '; '
                }
            }
        }
        if ($details.Length -gt 400) { $details = $details.Substring(0, 400) + '...' }
        # the value now: one line per distinct value, with how many servers have it when they differ
        $basis = $gaps; if ($basis.Count -eq 0) { $basis = $mine }
        $nowGroups = @($basis | Group-Object Now)
        $nowText = $(if ($nowGroups.Count -eq 1) { [string]$nowGroups[0].Name } else { (@($nowGroups | Sort-Object Count -Descending | ForEach-Object { '{0} [{1}]' -f $_.Name, $_.Count }) -join '; ') })
        $cellColour = [string]$script:ImpactCellColours[$light]
        $out += [pscustomobject]@{
            Impact = $word; Light = $light; Cells = @{ Impact = $cellColour }; Id = [string]$e.Check; Setting = $mine[0].Title; Now = $nowText; 'Recommended value' = [string]$e.Value
            'Recommended GPO' = [string]$e.Gpo; Gaps = ($parts -join ', '); 'Impact details' = $details
            'No impact on' = ((& $serversOf @('Blue')) -join ', '); 'Check first on' = ((& $serversOf @('Amber')) -join ', '); 'Impact found on' = ((& $serversOf @('Red')) -join ', ')
            'Not checked on' = ((& $serversOf @('Grey')) -join ', '); Where = [string]$e.Path; 'What could break' = [string]$e.Impact
            SortKey = ('{0:d3}-{1:d4}' -f $(if ($order.ContainsKey([string]$e.Gpo)) { $order[[string]$e.Gpo] } else { 999 }), $n)
        }
    }
    return @($out | Sort-Object SortKey)
}

function Get-GpoGapDetailsHtml {
    # The page's double-click: one setting, every server - its value now, which GPO sets it, and what the impact checks found.
    param([string]$Id, [string[]]$Servers)
    $e = @((Get-GpoGuidance).Settings | Where-Object { $_.Check -eq $Id })[0]
    if (-not $e) { return (New-DetailsHtml -Title "GPO recommendation $Id" -Console 'Security' -Subtitle 'no guidance for this check in data\gpo-guidance.psd1') }
    $rows = @(foreach ($s in $Servers) {
        $r = @(Get-GpoGapRows -Server $s | Where-Object { $_.Id -eq $Id })[0]
        if (-not $r) { [pscustomobject]@{ Light = 'Grey'; Impact = ''; Server = $s; Status = $(if (Test-SecurityCollected -Server $s) { 'not applicable or risk accepted' } else { 'not audited' }); Now = ''; 'What the impact checks found' = ''; Note = '' }; continue }
        [pscustomobject]@{ Light = $r.Light; Impact = $r.Impact; Server = $s; Status = $r.Status; Now = $r.Now; 'What the impact checks found' = $r.'Impact evidence'; Note = $r.Note }
    })
    $probes = @(@($e.Probes) | Where-Object { $_ } | ForEach-Object { if ($script:ImpactProbes[$_]) { $script:ImpactProbes[$_].Title } else { $_ } })
    $facts = @(@('Recommended GPO', [string]$e.Gpo), @('Recommended value', [string]$e.Value), @('Impact checks', $(if ($probes.Count -gt 0) { $probes -join ', ' } else { 'none - expected impact: ' + [string]$e.Expect })))
    if ($e.Default) { $facts += , @('When not set', [string]$e.Default) }
    $chk = @(Get-Checks -Console 'Security' | Where-Object { $_.Id -eq $Id })[0]
    return (New-DetailsHtml -Title ('{0}  {1}' -f $Id, $(if ($chk) { $chk.Title } else { '' })) -Subtitle 'one recommended setting across the servers shown' -Console 'Security' -Facts $facts -Sections @(
        @{ Heading = 'Where to set it'; Text = [string]$e.Path },
        @{ Heading = 'What could break'; Text = [string]$e.Impact },
        @{ Heading = 'Servers'; Rows = $rows; Columns = @('Impact', 'Server', 'Status', 'Now', 'What the impact checks found', 'Note'); Note = 'Impact: Impact found (red) = current use found here - keep this server out of the GPO (security filtering) until it is resolved; Check first (amber) = a check could not tell, or there is no automatic check; No impact found / expected (blue) = no sign it would be felt here; Not checked / Not read (grey); Enforced (green) = a GPO already sets it. Status: Missing from GPO = no GPO sets it; Weaker in GPO = a GPO sets another value (change that GPO); Not enforced = compliant here, nothing keeps it so.' }))
}

function Get-GpoPlanHtml {
    # "GPO plan...": the gaps grouped into the recommended GPOs, each with the servers it can go to and the ones to keep out.
    param([string[]]$Servers)
    $all = @(foreach ($s in $Servers) { Get-GpoGapRows -Server $s })
    $sum = @(Get-GpoGapSummaryRows -GapRows $all)
    $audited = @($Servers | Where-Object { Test-SecurityCollected -Server $_ })
    $facts = @(@('Servers audited', ('{0} of {1}' -f $audited.Count, @($Servers).Count)), @('Settings with a gap', $sum.Count),
        @('No impact found / expected', @($sum | Where-Object { $_.Light -eq 'Blue' }).Count), @('Check first', @($sum | Where-Object { $_.Light -eq 'Amber' }).Count),
        @('Impact found', @($sum | Where-Object { $_.Light -eq 'Red' }).Count), @('Not checked / not read', @($sum | Where-Object { $_.Light -eq 'Grey' }).Count))
    $approach = @(
        'One GPO per area (below), named "Server Baseline - <area>", linked to the OU that holds the member servers - not to the domain root, and not added to the Default Domain Policy (that one is for password and lockout policy of domain accounts). Domain controllers get their own baseline, linked to the Domain Controllers OU.',
        'Start with the settings marked "No impact found" or "No impact expected": no impact check found anything they would break. Then "Check first", after reading what the checks found. "Impact found": keep the servers named out of the GPO (security filtering - Deny "Apply group policy" for a group holding them - or a separate OU) until the dependency is gone, and record that as a tailoring rule with a review date.',
        'Pilot first: link the GPO to a pilot OU, or security-filter it to a pilot group of servers; gpupdate /force, AUDIT again on this console, then widen the scope.',
        'A GPO edit is a change: raise it under change management. Back the GPO up (Backup-GPO) before and after.',
        'Settings with no administrative template (TLS, some SMB settings) go into Group Policy Preferences > Registry items in the same GPO; features and firmware are not Group Policy at all - change them in the server build (SOE) or with a change-managed script.',
        'Microsoft''s Security Compliance Toolkit baselines and ASD''s hardening guidance are the reference: their GPO backups can be imported into these GPOs (GPMC: Import Settings) and trimmed to what is below.',
        'After applying: AUDIT again - the rows move to "Enforced", and the Health console''s Group Policy page shows whether every server applied the new GPO without errors.')
    $sections = @(@{ Heading = 'The approach'; Lines = $approach })
    foreach ($g in @((Get-GpoGuidance).Gpos)) {
        $mine = @($sum | Where-Object { $_.'Recommended GPO' -eq $g.Name })
        if ($mine.Count -eq 0) { continue }
        $gapServers = @($all | Where-Object { $_.Gpo -eq $g.Name -and $_.Gap } | ForEach-Object { $_.Server } | Select-Object -Unique)
        $keepOut = @($mine | Where-Object { $_.'Impact found on' } | ForEach-Object { $_.'Impact found on' -split ', ' } | Select-Object -Unique)
        $note = [string]$g.Note + ('  Servers with a gap: {0}.' -f ($gapServers -join ', '))
        if ($keepOut.Count -gt 0) { $note += ('  Keep out until resolved (impact found): {0}.' -f ($keepOut -join ', ')) }
        $sections += @{ Heading = $g.Name; Note = $note; Rows = $mine; Columns = @('Impact', 'Id', 'Setting', 'Now', 'Recommended value', 'Gaps', 'Impact details', 'No impact on', 'Check first on', 'Impact found on', 'Where', 'What could break') }
    }
    return (New-DetailsHtml -Title 'GPO plan' -Subtitle 'the Security gaps of the servers shown, grouped into the recommended GPOs, with their impact' -Console 'Security' -Facts $facts -Sections $sections)
}

function Update-SecurityGpoGrid {
    # The GPO recommendations page.
    param([string[]]$Servers)
    $grid = $script:Gui['GpoGapGrid']
    if (-not $grid) { return }
    $rows = @(Get-GpoGapSummaryRows -Servers $Servers -All:([bool]$script:Gui['GpoGapAll'].Checked))
    $pickGpo = [string]$script:Gui['GpoGapGpoCombo'].SelectedItem
    if ($pickGpo -and $pickGpo -notlike '(*') { $rows = @($rows | Where-Object { $_.'Recommended GPO' -eq $pickGpo }) }
    $q = ([string]$script:Gui['GpoGapFilter'].Text).Trim()
    if ($q) { $rows = @($rows | Where-Object { ($_.Id + ' ' + $_.Setting + ' ' + $_.'Recommended GPO' + ' ' + $_.Where + ' ' + $_.Now).IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }) }
    # only the Impact cell carries a colour: the word says it, the rest of the row stays plain
    Set-GridRows -Grid $grid -Rows $rows -NoKeepChecks -CellColourProperty 'Cells' -ToolTipProperty 'What could break'
    $audited = @($Servers | Where-Object { Test-SecurityCollected -Server $_ }).Count
    $impact = @($Servers | Where-Object { Get-CollectorResult -Name 'Impact' -Server $_ }).Count
    $next = ''; if ($audited -gt 0 -and $impact -lt $audited) { $next = ' - press Check impact' }
    $script:Gui['GpoGapCount'].Text = ('{0} setting(s): {1} impact found, {2} check first, {3} no impact, {4} not checked or not read  |  {5} of {6} server(s) audited, impact checked on {7}{8}' -f $rows.Count, @($rows | Where-Object { $_.Light -eq 'Red' }).Count, @($rows | Where-Object { $_.Light -eq 'Amber' }).Count, @($rows | Where-Object { $_.Light -eq 'Blue' }).Count, @($rows | Where-Object { $_.Light -eq 'Grey' }).Count, $audited, @($Servers).Count, $impact, $next)
}

function Get-SecurityShownServers {
    return @(Get-UniqueNames (Get-GroupRows -Combo $script:Gui['SecurityGroupCombo'] | ForEach-Object { $_.Server }))
}

function New-SecurityGpoPage {
    # The Security console's "GPO recommendations" page (built by New-SecurityConsole).
    param($Page)
    $grid = New-ConsoleGrid -NoCheckBoxes -Columns @(@{ Name = 'Impact'; Width = 125 }, @{ Name = 'Id'; Width = 85 }, @{ Name = 'Setting'; Width = 260 }, @{ Name = 'Now'; Width = 260 }, @{ Name = 'Recommended value'; Width = 200 }, @{ Name = 'Recommended GPO'; Width = 220 }, @{ Name = 'Gaps'; Width = 170 }, @{ Name = 'Impact details'; Width = 380 }, @{ Name = 'Where'; Width = 400; Fill = $true })
    $grid.Add_DoubleClick({
        if ($script:Gui['Busy']) { Write-PatchLog 'Busy - details are available again when the current action finishes' 'WARN'; return }
        if ($this.SelectedItems.Count -gt 0) { $row = $this.SelectedItems[0].Tag; Show-DetailsWindow -Title "GPO recommendation $($row.Id)" -Html (Get-GpoGapDetailsHtml -Id $row.Id -Servers (Get-SecurityShownServers)) }
    })
    $bar = New-Object System.Windows.Forms.Panel; $bar.Dock = 'Top'; $bar.Height = 64
    $fl = New-Object System.Windows.Forms.Label; $fl.Text = 'Find:'; $fl.Location = New-Object System.Drawing.Point(8, 14); $fl.AutoSize = $true
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Location = New-Object System.Drawing.Point(46, 10); $filter.Width = 150
    $script:Gui['Tips'].SetToolTip($filter, 'Part of a setting, its id, its value now, the GPO or the path')
    # the grid follows the box a third of a second after the last keystroke, not on every one
    $filterTimer = New-Object System.Windows.Forms.Timer; $filterTimer.Interval = 300
    $filterTimer.Add_Tick({ $this.Stop(); Update-SecurityGpoGrid -Servers (Get-SecurityShownServers) })
    $script:Gui['GpoGapFilterTimer'] = $filterTimer
    $filter.Add_TextChanged({ $t = $script:Gui['GpoGapFilterTimer']; $t.Stop(); $t.Start() })
    $gl = New-Object System.Windows.Forms.Label; $gl.Text = 'GPO:'; $gl.Location = New-Object System.Drawing.Point(208, 14); $gl.AutoSize = $true
    $gpoCombo = New-Object System.Windows.Forms.ComboBox; $gpoCombo.Location = New-Object System.Drawing.Point(244, 10); $gpoCombo.Width = 260; $gpoCombo.DropDownStyle = 'DropDownList'
    [void]$gpoCombo.Items.Add('(every recommended GPO)')
    foreach ($gp in @((Get-GpoGuidance).Gpos)) { [void]$gpoCombo.Items.Add([string]$gp.Name) }
    $gpoCombo.SelectedIndex = 0
    $script:Gui['Tips'].SetToolTip($gpoCombo, 'Work through one GPO at a time: only the settings that belong in it')
    $gpoCombo.Add_SelectedIndexChanged({ Update-SecurityGpoGrid -Servers (Get-SecurityShownServers) })
    $showAll = New-Object System.Windows.Forms.CheckBox; $showAll.Text = 'Show settings already enforced'; $showAll.Location = New-Object System.Drawing.Point(516, 12); $showAll.AutoSize = $true
    $showAll.Add_CheckedChanged({ Update-SecurityGpoGrid -Servers (Get-SecurityShownServers) })
    $bar.Controls.AddRange(@($fl, $filter, $gl, $gpoCombo, $showAll))
    $bar.Controls.Add((New-GuiButton -Text 'Check impact (ticked or all)' -X 730 -Y 5 -W 200 -H 32 -Colour 'LightCoral' -ReadOnly -Tip 'Reads Group Policy and runs the impact checks on the servers ticked on the Servers page (all shown if none): SMB1 and SMB clients, NTLMv1 / Basic / anonymous logons, TLS services, LSA packages, PowerShell 2.0, ASR and AppLocker audit hits ... Read-only. Servers not audited yet are audited first.' -OnClick {
        Invoke-GuiAction -Name 'GPO impact check' -ReadOnly -Action {
            $servers = @(Get-GridChecked -Grid $script:Gui['SecurityGrid'])
            if ($servers.Count -eq 0) { $servers = @(Get-GridAllKeys -Grid $script:Gui['SecurityGrid']) }
            if ($servers.Count -eq 0) { Show-GuiNotice 'No servers in the list.'; return }
            $new = @($servers | Where-Object { -not (Test-SecurityCollected -Server $_) })
            if ($new.Count -gt 0) { Write-PatchLog ('{0} server(s) not audited yet - auditing them first: {1}' -f $new.Count, ($new -join ', ')) 'WHY'; Invoke-SecurityAudit -ComputerName $new }
            Get-ServerGpo -ComputerName $servers | Out-Null
            Get-ServerImpact -ComputerName $servers | Out-Null
            Clear-SecurityRowCache
            $rows = @(Get-GpoGapSummaryRows -Servers $servers)
            Write-PatchLog ('GPO impact check by {0}: {1} server(s), {2} setting(s) with a gap - {3} impact found, {4} check first, {5} no impact' -f (Get-OperatorIdentity), $servers.Count, $rows.Count, @($rows | Where-Object { $_.Light -eq 'Red' }).Count, @($rows | Where-Object { $_.Light -eq 'Amber' }).Count, @($rows | Where-Object { $_.Light -eq 'Blue' }).Count) 'INFO'
        } }))
    $bar.Controls.Add((New-GuiButton -Text 'GPO plan...' -X 935 -Y 5 -W 110 -H 32 -ReadOnly -Tip 'The gaps grouped into the recommended GPOs: what to set where, the servers each can go to and the ones to keep out - and the approach' -OnClick {
        Invoke-GuiAction -Name 'GPO plan' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The GPO plan')) { return }
            Show-DetailsWindow -Title 'GPO plan' -Html (Get-GpoPlanHtml -Servers (Get-SecurityShownServers))
        } }))
    $count = New-Object System.Windows.Forms.Label; $count.Location = New-Object System.Drawing.Point(8, 42); $count.AutoSize = $true; $count.ForeColor = 'DimGray'
    $bar.Controls.Add($count)
    # no explainer text on the page: what the rows and the Impact column mean is the tool tip of the count and of the page tab
    $script:Gui['Tips'].SetToolTip($count, $Page.ToolTipText)
    $Page.Controls.Add($grid); $Page.Controls.Add($bar); $grid.BringToFront()
    $script:Gui['GpoGapGrid'] = $grid; $script:Gui['GpoGapFilter'] = $filter; $script:Gui['GpoGapAll'] = $showAll; $script:Gui['GpoGapCount'] = $count; $script:Gui['GpoGapGpoCombo'] = $gpoCombo
}
