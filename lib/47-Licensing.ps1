# =====================================================================
#  47-Licensing.ps1  -  LICENSING: MODELS, ACTIVATION, KMS, RD LICENSING, RD SESSION HOSTS
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  The Licensing collector runs with every software check (Check software), every Security audit and the
#  self-check.  On every server, read-only: the hardware the licensing models count on (sockets, cores, physical or
#  virtual, a Hyper-V host's virtual machines) and the OS edition; the activation state of Windows (and Office,
#  where installed) and its channel (KMS client, MAK, Active Directory, retail, OEM, evaluation); on a KMS host the
#  service's counts; on an RD Licensing server every CAL key pack (installed, issued, available) and the issued
#  licences; on an RD Session Host the licensing mode, the licence servers and the grace days left.  SQL Server and
#  Exchange editions come from the Inventory collector.
#  Get-LicensingModelRows turns that into the licensing model that applies to each product on each server and the
#  count it is driven by (Windows Server per core or per processor, Standard's two VMs per core set, Datacenter's
#  unlimited, the per-VM option, Essentials per server; SQL Server per core or Server + CAL by edition; Exchange
#  server + CALs; RDS CALs; Office by channel; KMS or direct activation).  The Software report carries the models,
#  one row per server and the totals of the servers shown; the Licensing button of the Software console shows the
#  same as a page; four Security checks (SEC-LIC-01..04) light the Security grid.  Nothing changes on any server.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  47-Licensing.ps1
#  New 2026-11-06 (owner's ask: licensing where it can be obtained - RDS, KMS, the models: core and VM counts, KMS
#  or direct - reported with the software checks, with totals).  The counting rules are Microsoft's published ones
#  for the current products; the agreement decides (Software Assurance, subscriptions, SPLA): verify with the
#  reseller before buying or reconciling.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _________cf_____________________   Date : _____8-11-26_________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  LICENSING collector - RUNS ON THE SERVER.  Strings with | between the fields, so the result travels and is kept
#  as plain text (Export-Clixml).  Every read is wrapped: what cannot be read lands in Errors, never fails the rest.
# ---------------------------------------------------------------------
$script:RemoteLicensingScript = {
    $ErrorActionPreference = 'Continue'
    $errors = @()
    $toDate = { param($d) if ($d -is [datetime]) { return $d.ToString('yyyy-MM-dd') }; if ($d) { return [string]$d }; return '' }
    # a CIM uint32 can hold 4294967295 ("not applicable"): every number is read as int64, never cast to int (first run 2026-11-06)
    $toNum = { param($v) $n = [int64]-1; if ($null -ne $v) { try { $n = [int64]$v } catch { } }; return $n }
    # 1. the hardware the licensing models count on, and the OS edition
    $hw = @(); $os = @(); $vms = @()
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $cpus = @(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop)
        $sockets = $cpus.Count; $cores = 0; $logical = 0
        foreach ($cpu in $cpus) { $nc = & $toNum $cpu.NumberOfCores; if ($nc -gt 0) { $cores += $nc }; $nl = & $toNum $cpu.NumberOfLogicalProcessors; if ($nl -gt 0) { $logical += $nl } }
        $model = [string]$cs.Model; $maker = [string]$cs.Manufacturer
        $virtual = ($model -match 'Virtual|VMware|KVM|QEMU|Xen|HVM|Nutanix|Parallels|Google Compute|Standard PC' -or $maker -match 'VMware|Xen|QEMU|innotek|Parallels|Nutanix')
        $hvPresent = $false; if ($cs.PSObject.Properties['HypervisorPresent']) { $hvPresent = [bool]$cs.HypervisorPresent }
        $hw += 'Manufacturer=' + $maker; $hw += 'Model=' + $model; $hw += 'Virtual=' + $virtual; $hw += 'HypervisorPresent=' + $hvPresent
        $hw += 'Sockets=' + [string]$sockets; $hw += 'Cores=' + [string]$cores; $hw += 'LogicalProcessors=' + [string]$logical
        $hw += 'CpuName=' + $(if ($cpus.Count -gt 0) { ([string]$cpus[0].Name).Trim() } else { '' })
    } catch { $errors += 'hardware: ' + $_.Exception.Message }
    try {
        $osi = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $cap = [string]$osi.Caption
        $edition = 'Other'
        if ($cap -match 'Datacenter') { $edition = 'Datacenter' } elseif ($cap -match 'Essentials') { $edition = 'Essentials' } elseif ($cap -match 'Standard') { $edition = 'Standard' } elseif ($cap -match 'Evaluation') { $edition = 'Evaluation' } elseif ($cap -match 'Windows 1[01]|Windows 7|Windows 8') { $edition = 'Client' }
        if ($cap -match 'Evaluation') { $edition += ' (evaluation)' }
        $os += 'Caption=' + $cap; $os += 'Version=' + [string]$osi.Version; $os += 'Sku=' + [string]$osi.OperatingSystemSKU; $os += 'Edition=' + $edition
    } catch { $errors += 'operating system: ' + $_.Exception.Message }
    # 2. activation: every product with a key (Windows; Office where installed) - status, channel, grace days, KMS host
    $products = @()
    try {
        foreach ($p in @(Get-CimInstance -ClassName SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL" -ErrorAction Stop)) {
            $app = 'Other'
            if ([string]$p.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f') { $app = 'Windows' } elseif ([string]$p.ApplicationID -eq '0ff1ce15-a989-479d-af46-f275c6370663') { $app = 'Office' }
            $status = 'Unknown'
            switch (& $toNum $p.LicenseStatus) { 0 { $status = 'Unlicensed' } 1 { $status = 'Licensed' } 2 { $status = 'Initial grace' } 3 { $status = 'Additional grace' } 4 { $status = 'Non-genuine grace' } 5 { $status = 'Notification' } 6 { $status = 'Extended grace' } }
            $desc = [string]$p.Description
            $channel = ''
            if ($desc -match 'VOLUME_KMSCLIENT') { $channel = 'KMS client' } elseif ($desc -match 'VOLUME_KMS') { $channel = 'KMS host key' } elseif ($desc -match 'VOLUME_MAK') { $channel = 'MAK' } elseif ($desc -match 'TIMEBASED_EVAL') { $channel = 'Evaluation' } elseif ($desc -match 'OEM') { $channel = 'OEM' } elseif ($desc -match 'RETAIL') { $channel = 'Retail' }
            if ((& $toNum $p.VLActivationType) -eq 1) { $channel = 'Active Directory' }
            $graceDays = ''; $graceMin = & $toNum $p.GracePeriodRemaining; if ($graceMin -ge 0 -and $graceMin -lt 4000000000) { $graceDays = [string][int64]($graceMin / 1440) }
            $kmsHost = [string]$p.KeyManagementServiceMachine; if (-not $kmsHost) { $kmsHost = [string]$p.DiscoveredKeyManagementServiceMachineName }
            if ($kmsHost -and $p.KeyManagementServicePort) { $kmsHost += ':' + [string]$p.KeyManagementServicePort }
            $products += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}' -f $app, $p.Name, $status, $channel, $graceDays, $p.PartialProductKey, $kmsHost, $p.LicenseFamily
        }
    } catch { $errors += 'activation: ' + $_.Exception.Message }
    # 3. the roles that matter (Win32_ServerFeature: every Windows Server, no module needed); the exact names - the RSAT
    #    tools ("Remote Desktop Licensing Diagnoser") are not the role (seen on the dev PC)
    $roles = @()
    try {
        foreach ($f in @(Get-CimInstance -ClassName Win32_ServerFeature -ErrorAction Stop)) {
            $fname = ([string]$f.Name).Trim()
            if ($fname -eq 'Remote Desktop Licensing') { $roles += 'RD Licensing' }
            elseif ($fname -eq 'Remote Desktop Session Host') { $roles += 'RD Session Host' }
            elseif ($fname -eq 'Remote Desktop Connection Broker') { $roles += 'RD Connection Broker' }
            elseif ($fname -eq 'Remote Desktop Gateway') { $roles += 'RD Gateway' }
            elseif ($fname -eq 'Remote Desktop Web Access') { $roles += 'RD Web Access' }
            elseif ($fname -eq 'Volume Activation Services') { $roles += 'Volume Activation Services' }
            elseif ($fname -eq 'Hyper-V') { $roles += 'Hyper-V' }
        }
    } catch { $errors += 'roles: ' + $_.Exception.Message }
    # 4. a Hyper-V host: its virtual machines (their Windows Server guests are licensed through this host)
    $vmTotal = 0; $vmRunning = 0
    if ($roles -contains 'Hyper-V') {
        try {
            foreach ($vm in @(Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName Msvm_ComputerSystem -Filter "Caption='Virtual Machine'" -ErrorAction Stop)) {
                $state = 'other'
                switch (& $toNum $vm.EnabledState) { 2 { $state = 'running' } 3 { $state = 'off' } 6 { $state = 'saved' } 9 { $state = 'paused' } }
                $vmTotal++; if ($state -eq 'running') { $vmRunning++ }
                if ($vms.Count -lt 200) { $vms += '{0}|{1}' -f $vm.ElementName, $state }
            }
        } catch { $errors += 'Hyper-V virtual machines: ' + $_.Exception.Message }
    }
    $hw += 'VmCount=' + [string]$vmTotal; $hw += 'VmRunning=' + [string]$vmRunning
    # 5. KMS host: the licensing service's counts (IsKeyManagementServiceMachine = 1 on a host)
    $kms = @()
    try {
        $svc = Get-CimInstance -ClassName SoftwareLicensingService -ErrorAction Stop
        $isHost = $false
        if ($svc.PSObject.Properties['IsKeyManagementServiceMachine']) { $isHost = ((& $toNum $svc.IsKeyManagementServiceMachine) -eq 1) }
        if ($isHost -or ($roles -contains 'Volume Activation Services')) {
            if ($isHost) { $roles += 'KMS host' }
            $read = { param($o, $n) if ($o.PSObject.Properties[$n]) { return [string]$o.$n }; return '' }
            foreach ($pair in @(@('Port', 'KeyManagementServiceListeningPort'), @('CurrentCount', 'KeyManagementServiceCurrentCount'), @('RequiredClientCount', 'RequiredClientCount'), @('TotalRequests', 'KeyManagementServiceTotalRequests'), @('LicensedRequests', 'KeyManagementServiceLicensedRequests'), @('FailedRequests', 'KeyManagementServiceFailedRequests'), @('UnlicensedRequests', 'KeyManagementServiceUnlicensedRequests'), @('OOBGraceRequests', 'KeyManagementServiceOOBGraceRequests'), @('OOTGraceRequests', 'KeyManagementServiceOOTGraceRequests'), @('NotificationRequests', 'KeyManagementServiceNotificationRequests'), @('DnsPublishing', 'KeyManagementServiceDnsPublishing'))) {
                $kms += ('{0}={1}' -f $pair[0], (& $read $svc $pair[1]))
            }
        }
    } catch { $errors += 'KMS: ' + $_.Exception.Message }
    # 6. RD Licensing server: the key packs (installed / issued / available) and the issued licences
    $packs = @(); $issued = @(); $issuedBy = @{}; $lsActivation = ''
    $tryPacks = ($roles -contains 'RD Licensing')
    if (-not $tryPacks) { try { $null = Get-CimClass -ClassName Win32_TSLicenseKeyPack -ErrorAction Stop; $tryPacks = $true } catch { } }
    if ($tryPacks) {
        try {
            foreach ($k in @(Get-CimInstance -ClassName Win32_TSLicenseKeyPack -ErrorAction Stop)) {
                $type = 'Type ' + [string]$k.KeyPackType
                switch (& $toNum $k.KeyPackType) { 0 { $type = 'Unknown' } 1 { $type = 'Retail purchase' } 2 { $type = 'Volume purchase' } 3 { $type = 'Concurrent' } 4 { $type = 'Temporary' } 5 { $type = 'Open purchase' } 6 { $type = 'Built-in' } }
                $ptype = 'Product type ' + [string]$k.ProductType
                switch (& $toNum $k.ProductType) { 0 { $ptype = 'Per device' } 1 { $ptype = 'Per user' } 2 { $ptype = 'Built-in' } }
                $total = & $toNum $k.TotalLicenses; $totalText = [string]$total; if ($total -ge 4000000000 -or $total -lt 0) { $totalText = 'unlimited' }
                $avail = & $toNum $k.AvailableLicenses; $availText = [string]$avail; if ($avail -ge 4000000000 -or $avail -lt 0) { $availText = 'unlimited' }
                $packs += '{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}' -f $k.KeyPackId, $k.Description, $type, $ptype, $k.ProductVersion, $totalText, $k.IssuedLicenses, $availText, (& $toDate $k.ExpirationDate)
            }
        } catch { $errors += 'RD Licensing key packs: ' + $_.Exception.Message }
        try {
            $count = 0
            foreach ($l in @(Get-CimInstance -ClassName Win32_TSIssuedLicense -ErrorAction Stop)) {
                $st = 'Status ' + [string]$l.LicenseStatus
                switch (& $toNum $l.LicenseStatus) { 1 { $st = 'Temporary' } 2 { $st = 'Active' } 3 { $st = 'Upgrade' } 4 { $st = 'Revoked' } 5 { $st = 'Pending' } 6 { $st = 'Concurrent' } }
                $key = '{0}|{1}' -f $l.KeyPackId, $st
                if (-not $issuedBy.ContainsKey($key)) { $issuedBy[$key] = 0 }
                $issuedBy[$key]++
                $count++
                if ($count -le 300) { $issued += '{0}|{1}|{2}|{3}|{4}|{5}' -f $l.KeyPackId, $st, $l.sIssuedToComputer, $l.sIssuedToUser, (& $toDate $l.IssueDate), (& $toDate $l.ExpirationDate) }
            }
        } catch { $errors += 'RD Licensing issued licences: ' + $_.Exception.Message }
        try {
            $ls = Get-CimInstance -ClassName Win32_TSLicenseServer -ErrorAction Stop
            $act = Invoke-CimMethod -InputObject $ls -MethodName GetActivationStatus -ErrorAction Stop
            $lsActivation = 'Not activated'; if ((& $toNum $act.ActivationStatus) -eq 0) { $lsActivation = 'Activated' }
        } catch { $errors += 'RD Licensing server activation: ' + $_.Exception.Message }
    }
    $issuedCounts = @(foreach ($k in $issuedBy.Keys) { '{0}|{1}' -f $k, $issuedBy[$k] })
    # 7. RD Session Host: the licensing mode, the licence servers and the grace days left
    $rdsh = @()
    try {
        $tss = Get-CimInstance -Namespace 'root\cimv2\TerminalServices' -ClassName Win32_TerminalServiceSetting -ErrorAction Stop
        $mode = 'Type ' + [string]$tss.LicensingType
        switch (& $toNum $tss.LicensingType) { 0 { $mode = 'Personal (unlicensed)' } 1 { $mode = 'Remote Desktop for Administration' } 2 { $mode = 'Per device' } 4 { $mode = 'Per user' } 5 { $mode = 'Not configured' } }
        $serverMode = & $toNum $tss.TerminalServerMode   # 1 = application server, the RD Session Host role
        if ($serverMode -eq 1 -and ($roles -notcontains 'RD Session Host')) { $roles += 'RD Session Host' }
        $lsList = ''
        try { $specified = Invoke-CimMethod -InputObject $tss -MethodName GetSpecifiedLicenseServerList -ErrorAction Stop; $lsList = (@($specified.SpecifiedLSList) -join ', ') } catch { }
        $grace = ''
        if ($serverMode -eq 1) { try { $gp = Invoke-CimMethod -InputObject $tss -MethodName GetGracePeriodDays -ErrorAction Stop; $grace = [string]$gp.DaysLeft } catch { $grace = 'could not read: ' + $_.Exception.Message } }
        $policySource = ''; if ($tss.PSObject.Properties['PolicySourceLicensingType']) { $policySource = [string]$tss.PolicySourceLicensingType }
        $rdsh += 'ServerMode=' + [string]$serverMode
        $rdsh += 'Mode=' + $mode
        $rdsh += 'LicensingType=' + [string]$tss.LicensingType
        $rdsh += 'PolicySource=' + $policySource
        $rdsh += 'LicenseServers=' + $lsList
        $rdsh += 'GraceDaysLeft=' + $grace
    } catch { $errors += 'RD Session Host settings: ' + $_.Exception.Message }
    [pscustomobject]@{ Computer = $env:COMPUTERNAME; Hardware = $hw; Os = $os; Vms = $vms; Products = $products; Roles = @($roles | Select-Object -Unique); Kms = $kms; Packs = $packs; IssuedCounts = $issuedCounts; Issued = $issued; LicenseServerActivation = $lsActivation; Rdsh = $rdsh; Errors = $errors }
}

function Get-ServerLicensing {
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $summary = { param($r) $w = @($r.Products | Where-Object { $_ -like 'Windows|*' }); $text = 'no Windows licence read'; if ($w.Count -gt 0) { $f = [string]$w[0] -split '\|'; $text = ('Windows {0}, {1}' -f $f[2], $(if ($f[3]) { $f[3] } else { 'channel unknown' })) }; $hwText = ''; foreach ($line in @($r.Hardware)) { if ([string]$line -match '^(Sockets|Cores|Virtual)=(.*)$') { $hwText += ' ' + $Matches[1].ToLower() + ' ' + $Matches[2] } }; ('{0};{1}; roles: {2}{3}{4}' -f $text, $hwText, $(if (@($r.Roles).Count -gt 0) { @($r.Roles) -join ', ' } else { 'none that licence' }), $(if (@($r.Packs).Count -gt 0) { '; ' + @($r.Packs).Count + ' RDS CAL pack(s)' } else { '' }), $(if (@($r.Errors).Count -gt 0) { '; could not read: ' + (@($r.Errors) -join '; ') } else { '' })) }
    return (Invoke-Collector -Name 'Licensing' -ScriptBlock $script:RemoteLicensingScript -ComputerName $ComputerName -Summary $summary)
}

# ---------------------------------------------------------------------
#  Reading the result on the hub
# ---------------------------------------------------------------------
function ConvertFrom-LicensingResult {
    # The collector's strings as objects: Hardware and Os (name -> value), Vms (Name, State), Products (Application, Name,
    # Status, Channel, GraceDays, PartialKey, KmsHost, Family), Windows (the Windows entry), Office (its entries), Roles,
    # Kms (name -> value), Packs (KeyPackId, Description, Type, ProductType, Version, Total, Issued, Available, Expires),
    # IssuedCounts ('pack|status' -> count), Rdsh (name -> value), LicenseServerActivation, Errors.  Empty when the
    # result is missing or unreachable.
    param($Result)
    $o = [ordered]@{ Hardware = @{}; Os = @{}; Vms = @(); Products = @(); Windows = $null; Office = @(); Roles = @(); Kms = @{}; Packs = @(); IssuedCounts = @{}; Rdsh = @{}; LicenseServerActivation = ''; Errors = @() }
    if (-not $Result -or -not $Result.Reachable) { return [pscustomobject]$o }
    $pairs = { param($lines, $map) foreach ($line in @($lines)) { if ([string]$line -match '^([A-Za-z]+)=(.*)$') { $map[$Matches[1]] = $Matches[2] } } }
    if ($Result.PSObject.Properties['Hardware']) { & $pairs $Result.Hardware $o.Hardware }
    if ($Result.PSObject.Properties['Os']) { & $pairs $Result.Os $o.Os }
    if ($Result.PSObject.Properties['Vms']) { foreach ($line in @($Result.Vms)) { $f = [string]$line -split '\|'; if ($f.Count -ge 2) { $o.Vms += [pscustomobject]@{ Name = $f[0]; State = $f[1] } } } }
    foreach ($line in @($Result.Products)) {
        $f = [string]$line -split '\|'
        if ($f.Count -lt 8) { continue }
        $o.Products += [pscustomobject]@{ Application = $f[0]; Name = $f[1]; Status = $f[2]; Channel = $f[3]; GraceDays = $f[4]; PartialKey = $f[5]; KmsHost = $f[6]; Family = $f[7] }
    }
    $win = @($o.Products | Where-Object { $_.Application -eq 'Windows' }); if ($win.Count -gt 0) { $o.Windows = $win[0] }
    $o.Office = @($o.Products | Where-Object { $_.Application -eq 'Office' })
    $o.Roles = @($Result.Roles | ForEach-Object { [string]$_ } | Where-Object { $_ })
    & $pairs $Result.Kms $o.Kms
    foreach ($line in @($Result.Packs)) {
        $f = [string]$line -split '\|'
        if ($f.Count -lt 9) { continue }
        $o.Packs += [pscustomobject]@{ KeyPackId = $f[0]; Description = $f[1]; Type = $f[2]; ProductType = $f[3]; Version = $f[4]; Total = $f[5]; Issued = $f[6]; Available = $f[7]; Expires = $f[8] }
    }
    foreach ($line in @($Result.IssuedCounts)) { $f = [string]$line -split '\|'; if ($f.Count -ge 3) { $o.IssuedCounts[$f[0] + '|' + $f[1]] = [int]$f[2] } }
    & $pairs $Result.Rdsh $o.Rdsh
    if ($Result.PSObject.Properties['LicenseServerActivation']) { $o.LicenseServerActivation = [string]$Result.LicenseServerActivation }
    $o.Errors = @($Result.Errors | ForEach-Object { [string]$_ } | Where-Object { $_ })
    return [pscustomobject]$o
}

function ConvertTo-LicenceNumber {
    # A count the collector wrote: a number, or $null for 'unlimited' and anything else
    param([string]$Text)
    $n = 0; if ([int64]::TryParse([string]$Text, [ref]$n)) { return $n }
    return $null
}

function Get-PackTotals {
    # Installed / Issued / Available over the real key packs (not the built-in one; a temporary pack has no fixed total, its
    # issued licences count, and they are counted again as Temporary - clients on them have no permanent CAL)
    param([object[]]$Packs)
    $t = [ordered]@{ Installed = 0; Issued = 0; Available = 0; Temporary = 0; Unlimited = $false }
    foreach ($p in @($Packs)) {
        if ($p.Type -eq 'Built-in' -or $p.ProductType -eq 'Built-in') { continue }
        $total = ConvertTo-LicenceNumber $p.Total; $issued = ConvertTo-LicenceNumber $p.Issued; $avail = ConvertTo-LicenceNumber $p.Available
        if ($null -ne $total) { $t.Installed += $total } elseif ($p.Type -ne 'Temporary') { $t.Unlimited = $true }
        if ($null -ne $issued) { $t.Issued += $issued; if ($p.Type -eq 'Temporary') { $t.Temporary += $issued } }
        if ($null -ne $avail) { $t.Available += $avail }
    }
    return [pscustomobject]$t
}

function Get-ActivationColour {
    # The Activation cell: green = licensed (in place), amber = a grace period, red = unlicensed or in notification
    param([string]$Status)
    if ($Status -eq 'Licensed') { return 'PaleGreen' }
    if ($Status -in 'Initial grace', 'Additional grace', 'Extended grace', 'Non-genuine grace') { return 'Khaki' }
    if ($Status -in 'Unlicensed', 'Notification') { return 'LightCoral' }
    return ''
}

function Get-RdshLicensingColour {
    # The RDSH licensing cell: green = per user or per device with a licence server named, amber = a mode without a licence
    # server, red = not configured or personal (the grace period runs out, then clients are refused)
    param($Rdsh)
    $type = ConvertTo-LicenceNumber ([string]$Rdsh['LicensingType'])
    if ($type -in 2, 4) { if ([string]$Rdsh['LicenseServers']) { return 'PaleGreen' }; return 'Khaki' }
    return 'LightCoral'
}

function Format-NameList {
    # A few names in a cell or a report line, never hundreds
    param([string[]]$Names, [int]$Max = 12)
    $n = @($Names)
    if ($n.Count -le $Max) { return ($n -join ', ') }
    return ((@($n | Select-Object -First $Max) -join ', ') + (' +{0} more' -f ($n.Count - $Max)))
}

function Get-SqlEditionRows {
    # The SQL Server instances of a server from its inventory: 'instance|version|patch level|edition' -> objects
    param($Inventory)
    $rows = @()
    if (-not $Inventory -or -not $Inventory.Reachable) { return $rows }
    foreach ($i in @($Inventory.SqlInstances)) {
        $f = [string]$i -split '\|'
        if ($f.Count -ge 4) { $rows += [pscustomobject]@{ Instance = $f[0]; Version = $f[1]; Patch = $f[2]; Edition = $f[3] } } else { $rows += [pscustomobject]@{ Instance = [string]$i; Version = ''; Patch = ''; Edition = 'edition unknown' } }
    }
    return $rows
}

function Get-LicensingHardwareText {
    # 'physical, 2 sockets x 10 cores (20)' or 'VM, 4 vCPU' from the collector's hardware lines
    param($Hardware)
    $sockets = ConvertTo-LicenceNumber ([string]$Hardware['Sockets']); $cores = ConvertTo-LicenceNumber ([string]$Hardware['Cores'])
    if ($null -eq $cores) { return '' }
    if ([string]$Hardware['Virtual'] -eq 'True') { return ('VM, {0} vCPU' -f $cores) }
    if ($null -eq $sockets -or $sockets -lt 1) { $sockets = 1 }
    return ('physical, {0} socket(s) x {1} cores ({2})' -f $sockets, [int][math]::Ceiling($cores / $sockets), $cores)
}

function Get-LicensingRows {
    # One row per server for the Software report and the Licensing page: the hardware the models count on, what the
    # Licensing collector found, and the SQL Server and Exchange editions from the Inventory.  Cells: Activation, RDSH
    # licensing and RDS CALs by their state (green = in place).
    param([string[]]$Servers)
    $rows = @()
    foreach ($name in @($Servers)) {
        $r = Get-CollectorResult -Name 'Licensing' -Server $name
        $inv = Get-CollectorResult -Name 'Inventory' -Server $name
        $g = Get-ServerGroup -Name $name
        $sql = (@(Get-SqlEditionRows -Inventory $inv | ForEach-Object { '{0} {1}' -f $_.Instance, $_.Edition }) -join '; ')
        $exch = ''; if ($inv -and $inv.Reachable) { $exch = [string]$inv.Exchange }
        $row = [ordered]@{ Server = $name; Group = $(if ($g) { $g.Name } else { '' }); 'Last checked' = ''; Edition = ''; Hardware = ''; VMs = ''; Activation = ''; Channel = ''; 'KMS host' = ''; Roles = ''; 'KMS counts' = ''; 'RDSH licensing' = ''; 'RDS CALs' = ''; 'SQL Server' = $sql; Exchange = $exch; Tip = ''; Cells = @{} }
        if (-not $r) { $row.Activation = 'not collected'; $row.Tip = 'press Check software (or AUDIT): the Licensing collector runs with it'; $rows += [pscustomobject]$row; continue }
        $row.'Last checked' = Format-LastChecked $r.Checked
        $row.Cells['Last checked'] = Get-ResultAgeColour $r.Checked
        if (-not $r.Reachable) { $row.Activation = 'unreachable'; $row.Tip = [string]$r.Error; $rows += [pscustomobject]$row; continue }
        $lic = ConvertFrom-LicensingResult -Result $r
        $row.Edition = [string]$lic.Os['Edition']
        $row.Hardware = Get-LicensingHardwareText -Hardware $lic.Hardware
        if ($lic.Roles -contains 'Hyper-V') { $row.VMs = ('{0} ({1} running)' -f $lic.Hardware['VmCount'], $lic.Hardware['VmRunning']) }
        if ($lic.Windows) {
            $w = $lic.Windows
            if (-not $row.Edition) { $row.Edition = (([string]$w.Name -replace '^Windows\(R\),?\s*', '') -replace '\s+edition$', '') }
            $row.Activation = $w.Status; if ($w.Status -ne 'Licensed' -and $w.GraceDays) { $row.Activation += (' ({0} days left)' -f $w.GraceDays) }
            $row.Channel = $w.Channel; $row.'KMS host' = $w.KmsHost
            $row.Cells['Activation'] = Get-ActivationColour -Status $w.Status
        } else { $row.Activation = 'no Windows licence read' }
        if (@($lic.Office).Count -gt 0) { $row.Activation += ('; Office: ' + ((@($lic.Office) | ForEach-Object { $_.Status }) -join ', ')) }
        $row.Roles = (@($lic.Roles) -join '; ')
        if ($lic.Kms.Count -gt 0) { $row.'KMS counts' = ('current {0} of {1} needed; {2} requests, {3} licensed, {4} failed' -f $lic.Kms['CurrentCount'], $lic.Kms['RequiredClientCount'], $lic.Kms['TotalRequests'], $lic.Kms['LicensedRequests'], $lic.Kms['FailedRequests']) }
        if ([string]$lic.Rdsh['ServerMode'] -eq '1') {
            $row.'RDSH licensing' = [string]$lic.Rdsh['Mode']
            if ([string]$lic.Rdsh['LicenseServers']) { $row.'RDSH licensing' += ' via ' + $lic.Rdsh['LicenseServers'] }
            $graceLeft = ConvertTo-LicenceNumber ([string]$lic.Rdsh['GraceDaysLeft'])
            if ($null -ne $graceLeft -and $graceLeft -gt 0) { $row.'RDSH licensing' += (' - grace: {0} days left' -f $graceLeft) }
            $row.Cells['RDSH licensing'] = Get-RdshLicensingColour -Rdsh $lic.Rdsh
        }
        if (@($lic.Packs).Count -gt 0 -or ($lic.Roles -contains 'RD Licensing')) {
            $t = Get-PackTotals -Packs $lic.Packs
            $row.'RDS CALs' = ('{0} installed, {1} issued, {2} available{3}{4}' -f $(if ($t.Unlimited) { 'unlimited' } else { $t.Installed }), $t.Issued, $t.Available, $(if ($t.Temporary -gt 0) { '; ' + $t.Temporary + ' temporary' } else { '' }), $(if ($lic.LicenseServerActivation) { ' (' + $lic.LicenseServerActivation.ToLower() + ')' } else { '' }))
            $calColour = 'PaleGreen'
            if ($t.Temporary -gt 0 -or ($t.Available -eq 0 -and -not $t.Unlimited)) { $calColour = 'Khaki' }
            if ($lic.LicenseServerActivation -eq 'Not activated') { $calColour = 'LightCoral' }
            $row.Cells['RDS CALs'] = $calColour
        }
        $row.Tip = (@($lic.Errors) -join '; ')
        $rows += [pscustomobject]$row
    }
    # a server never called over WinRM (winrm: no): its name cell grey, in every console
    foreach ($r in $rows) { if (Test-RemoteDisabled -Name $r.Server) { $r.Cells['Server'] = 'LightGray' } }
    return $rows
}

$script:LicensingColumns = @('Server', 'Group', 'Last checked', 'Edition', 'Hardware', 'VMs', 'Activation', 'Channel', 'KMS host', 'Roles', 'KMS counts', 'RDSH licensing', 'RDS CALs', 'SQL Server', 'Exchange')
$script:LicensingModelColumns = @('Server', 'Product', 'Model', 'Basis', 'Needed', 'Activation', 'Notes')
# The counting rules (Microsoft Product Terms and licensing guides, checked 2026-11) as headed groups of short points: a
# section of the Software report, the Licensing page and a server's page (ConvertTo-GroupListHtml) - never one paragraph
$script:LicensingRulesHeading = 'Licensing counting rules (Microsoft Product Terms and licensing guides, checked 2026-11)'
$script:LicensingRules = @(
    @{ Heading = 'Windows Server 2016 and later: Standard and Datacenter (per core)'; Lines = @(
        'Every physical core of the server is licensed.',
        'Minimums: 8 core licences per processor and 16 per server.',
        'Sold in 2-core and 16-core packs.',
        'Standard: two OSEs (VMs) per fully licensed server; every further two VMs need every core licensed again.',
        'Datacenter: any number of VMs on the licensed host.',
        'A VM licensed on its own: one licence per virtual core, 8 at least; needs Software Assurance or a subscription.'
    ) },
    @{ Heading = 'Windows Server Essentials'; Lines = @(
        'Per server: one processor with up to 10 cores.',
        'Up to 25 users and 50 devices, no CALs needed.',
        'OEM only.'
    ) },
    @{ Heading = 'Windows Server 2012 R2 and older'; Lines = @(
        'Per processor: one licence covers two physical processors.'
    ) },
    @{ Heading = 'Windows Server CALs'; Lines = @(
        'Per user or per device, for everyone and everything that uses the server.',
        'An RDS CAL is an additive CAL: it sits on top of the Windows Server CAL.',
        'CALs cannot be read from a server: count them from the agreement.'
    ) },
    @{ Heading = 'SQL Server'; Lines = @(
        'Enterprise: per core only.',
        'Standard: per core, or Server + CAL.',
        'Per core: every core, 4 per physical processor at least and 4 per VM at least; sold in 2-core packs.',
        'A VM licensed on its own needs Software Assurance or a subscription (SQL Server 2022).',
        'Enterprise with Software Assurance on every physical core of a host covers any number of VMs on it.',
        'Web: per core, for hosting providers only.',
        'Express, Developer (not for production) and Evaluation (180 days) carry no licence.'
    ) },
    @{ Heading = 'Exchange Server'; Lines = @(
        'A server licence per server, plus a CAL per user or per device.'
    ) },
    @{ Heading = 'Remote Desktop Services'; Lines = @(
        'RDS CALs are per user or per device, on top of the Windows Server CAL.',
        'A session host runs 120 days without a licence server (the grace period).',
        'A temporary per-device CAL lasts 90 days.'
    ) },
    @{ Heading = 'KMS activation'; Lines = @(
        'A KMS host starts activating once enough distinct machines have asked it: 25 for Windows clients, 5 for servers or Office.'
    ) },
    @{ Heading = 'Office'; Lines = @(
        'Volume licences: per device.',
        'Microsoft 365: per user.'
    ) },
    @{ Heading = 'The agreement decides'; Lines = @(
        'Software Assurance, subscriptions, SPLA, licence mobility and the Flexible Virtualization Benefit change what a licence covers.',
        'Verify with the reseller before buying or reconciling.'
    ) }
)
# under a models table: where the rules are, and the caveat
$script:LicensingRulesNote = 'Needed follows the rules under "Licensing counting rules" (every physical core, the per-processor and per-server minimums, the VMs each edition permits). The agreement decides: verify with the reseller before buying or reconciling.'
# the sources, for the report and the page - Microsoft's own, not reachable from an air-gapped network (owner's ask 2026-11-06)
$script:LicensingReferences = @(
    'Windows Server licensing (FAQ, core licensing, virtual machines, CALs): https://www.microsoft.com/licensing/product-licensing/windows-server',
    'Windows Server licensing guide: https://aka.ms/WindowsServerLicensingGuide',
    'Licensing Windows Server for use with virtualization technologies: https://aka.ms/WindowsServerVirtualizationLicensing',
    'Introduction to Microsoft core licensing models: https://aka.ms/Corelicensingmodels',
    'Microsoft server base and additive CALs: https://aka.ms/Brief-BaseAdditiveCAL',
    'Flexible Virtualization Benefit guide: https://aka.ms/FlexibleVirtualizationBenefitGuide',
    'Product Terms, Windows Server Standard: https://www.microsoft.com/licensing/terms/productoffering/WindowsServerStandard',
    'Product Terms, Windows Server Datacenter: https://www.microsoft.com/licensing/terms/productoffering/WindowsServerDatacenter',
    'Windows Server pricing and editions (Essentials limits): https://www.microsoft.com/windows-server/pricing',
    'Comparison of Windows Server editions: https://learn.microsoft.com/windows-server/get-started/editions-comparison',
    'SQL Server 2022 pricing and licensing: https://www.microsoft.com/sql-server/sql-server-2022-pricing',
    'SQL Server 2022 licensing guide (PDF): https://download.microsoft.com/download/9/3/d/93d32de6-f268-45ed-ba25-2f9a6756b6af/SQL_Server_2022_Licensing_guide.pdf',
    'Product Terms, SQL Server: https://www.microsoft.com/licensing/terms/productoffering/SQLServer',
    'Product Terms, Exchange Server: https://www.microsoft.com/licensing/terms/productoffering/ExchangeServer',
    'License your RDS deployment with client access licenses (CALs): https://learn.microsoft.com/windows-server/remote/remote-desktop-services/rds-client-access-license',
    'Key Management Services (KMS) activation planning: https://learn.microsoft.com/windows-server/get-started/kms-activation-planning'
)

function Get-LicensingModelRows {
    # One row per licensable product per server: the licensing model that applies and the count it is driven by - what a
    # licence reconciliation needs beside the activation state.  Figures are what the server shows; the rules are in
    # $script:LicensingRulesNote.
    param([string[]]$Servers)
    $rows = @()
    foreach ($name in @(Get-UniqueNames @($Servers))) {
        $r = Get-CollectorResult -Name 'Licensing' -Server $name
        $inv = Get-CollectorResult -Name 'Inventory' -Server $name
        if (-not $r -or -not $r.Reachable) { continue }
        $lic = ConvertFrom-LicensingResult -Result $r
        $hw = $lic.Hardware; $os = $lic.Os
        $sockets = ConvertTo-LicenceNumber ([string]$hw['Sockets']); $cores = ConvertTo-LicenceNumber ([string]$hw['Cores'])
        if ($null -eq $sockets -or $sockets -lt 1) { $sockets = 1 }
        if ($null -eq $cores -or $cores -lt 0) { $cores = 0 }
        $virtual = ([string]$hw['Virtual'] -eq 'True')
        $coresPerSocket = [int][math]::Ceiling($cores / $sockets)
        $where = Get-LicensingHardwareText -Hardware $hw; if (-not $where) { $where = 'hardware not read' }
        $channel = ''; if ($lic.Windows) { $channel = $lic.Windows.Channel }
        $how = 'channel unknown'
        if ($channel -in 'KMS client', 'Active Directory') { $how = 'volume, ' + $channel } elseif ($channel -eq 'MAK') { $how = 'volume, MAK (direct)' } elseif ($channel) { $how = 'direct, ' + $channel }
        if ($lic.Windows -and $lic.Windows.Status -ne 'Licensed') { $how += ' - ' + $lic.Windows.Status }
        $calNote = 'Windows Server CALs per user or device as well (not readable: count by hand)'
        $edition = [string]$os['Edition']; $version = [string]$os['Version']
        $major = 0; if ($version -match '^(\d+)\.') { $major = [int]$Matches[1] }
        $modern = ($major -ge 10)   # Windows Server 2016 and later: per core
        $vmCount = ConvertTo-LicenceNumber ([string]$hw['VmCount']); $hyperv = ($lic.Roles -contains 'Hyper-V')
        $base = $edition -replace ' \(evaluation\)$', ''
        if ($edition -match 'evaluation') {
            $rows += [pscustomobject]@{ Server = $name; Product = 'Windows Server ' + $base + ' (evaluation)'; Model = 'Evaluation: no licence; convert the edition before its clock runs out'; Basis = $where; Needed = 'none yet'; Activation = $how; Notes = 'dism /online /Set-Edition, then activate' }
        } elseif ($base -in 'Standard', 'Datacenter') {
            if (-not $modern) {
                $rows += [pscustomobject]@{ Server = $name; Product = 'Windows Server ' + $base + ' (2012 R2 or older)'; Model = 'Per processor (one licence per two processors)'; Basis = $where; Needed = ('{0} processor licence(s)' -f [int][math]::Ceiling($sockets / 2)); Activation = $how; Notes = 'Standard: 2 VMs per licence; Datacenter: unlimited. ' + $calNote }
            } elseif ($virtual) {
                $perVm = [math]::Max(8, $cores)
                $rows += [pscustomobject]@{ Server = $name; Product = 'Windows Server ' + $base; Model = 'Per core through the host, or per virtual machine'; Basis = $where; Needed = ('per VM: {0} core licences (one per virtual core, 8 at least; Software Assurance or a subscription); through the host: Standard permits 2 VMs per fully licensed server, Datacenter any number' -f $perVm); Activation = $how; Notes = $calNote }
            } else {
                $coreLic = [math]::Max(16, $sockets * [math]::Max(8, $coresPerSocket))
                $sets = 1; $vmNote = ''
                if ($base -eq 'Standard' -and $hyperv -and $null -ne $vmCount -and $vmCount -gt 2) { $sets = [int][math]::Ceiling($vmCount / 2); $vmNote = ('; {0} VMs on this host, Standard permits 2 per fully licensed server: the cores licensed {1} times' -f $vmCount, $sets) }
                elseif ($hyperv -and $null -ne $vmCount) { $vmNote = ('; {0} VMs on this host' -f $vmCount) + $(if ($base -eq 'Datacenter') { ', any number under Datacenter' } else { '' }) }
                $rows += [pscustomobject]@{ Server = $name; Product = 'Windows Server ' + $base; Model = 'Per core (every physical core; 16 per server and 8 per processor at least; 2-core and 16-core packs)'; Basis = $where; Needed = ('{0} core licences ({1} two-core packs){2}' -f ($coreLic * $sets), ($coreLic * $sets / 2), $vmNote); Activation = $how; Notes = $calNote }
            }
        } elseif ($base -eq 'Essentials') {
            $rows += [pscustomobject]@{ Server = $name; Product = 'Windows Server Essentials'; Model = 'Per server (one processor, up to 10 cores; 25 users and 50 devices; no CALs; OEM only)'; Basis = $where; Needed = '1 server licence'; Activation = $how; Notes = $(if ($sockets -gt 1 -or $cores -gt 10) { 'more than one processor or 10 cores: Essentials does not cover this hardware' } else { '' }) }
        } elseif ($base -eq 'Client') {
            $rows += [pscustomobject]@{ Server = $name; Product = [string]$os['Caption']; Model = 'Per device (a client operating system)'; Basis = $where; Needed = '1 licence'; Activation = $how; Notes = '' }
        } elseif ($edition) {
            $rows += [pscustomobject]@{ Server = $name; Product = [string]$os['Caption']; Model = 'See the product terms'; Basis = $where; Needed = ''; Activation = $how; Notes = '' }
        }
        foreach ($s in @(Get-SqlEditionRows -Inventory $inv)) {
            $ed = [string]$s.Edition
            $need = $(if ($virtual) { [math]::Max(4, $cores) } else { $sockets * [math]::Max(4, $coresPerSocket) })
            $product = 'SQL Server ' + $ed + ' (' + $s.Instance + ')'
            $vmNoteSql = ''; if ($virtual) { $vmNoteSql = '; licensing this VM on its own needs Software Assurance or a subscription (SQL Server 2022), or license every physical core of its host' }
            if ($ed -match 'Enterprise') { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'Per core (every core; 4 per processor or per VM at least; 2-core packs)'; Basis = $where; Needed = ('{0} core licences' -f $need); Activation = ''; Notes = 'Enterprise is per core only; with Software Assurance on every physical core of a host, any number of VMs' + $vmNoteSql } }
            elseif ($ed -match 'Standard') { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'Per core, or Server + CAL'; Basis = $where; Needed = ('{0} core licences, or 1 server licence + a CAL per user or device' -f $need); Activation = ''; Notes = 'the agreement decides which' + $vmNoteSql } }
            elseif ($ed -match 'Web') { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'Per core (hosting providers, SPLA)'; Basis = $where; Needed = ('{0} core licences' -f $need); Activation = ''; Notes = '' } }
            elseif ($ed -match 'Express') { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'Free (Express)'; Basis = ''; Needed = 'none'; Activation = ''; Notes = '' } }
            elseif ($ed -match 'Developer') { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'Free for development and test only'; Basis = ''; Needed = 'none'; Activation = ''; Notes = 'not for production' } }
            elseif ($ed -match 'Evaluation') { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'Evaluation (180 days)'; Basis = ''; Needed = 'none yet'; Activation = ''; Notes = 'convert before it expires' } }
            else { $rows += [pscustomobject]@{ Server = $name; Product = $product; Model = 'See the product terms'; Basis = $where; Needed = ''; Activation = ''; Notes = '' } }
        }
        if ($inv -and $inv.Reachable -and $inv.Exchange) { $rows += [pscustomobject]@{ Server = $name; Product = 'Exchange Server (' + [string]$inv.Exchange + ')'; Model = 'Server licence + CALs (Standard CAL per user or device; Enterprise CAL additive)'; Basis = '1 server'; Needed = '1 server licence + a CAL per mailbox user or device (count by hand)'; Activation = ''; Notes = '' } }
        if ([string]$lic.Rdsh['ServerMode'] -eq '1') { $rows += [pscustomobject]@{ Server = $name; Product = 'Remote Desktop Services (Session Host)'; Model = ('RDS CAL per user or per device (' + [string]$lic.Rdsh['Mode'] + ')'); Basis = 'every user or device that connects'; Needed = 'one RDS CAL each - see the licence server''s packs'; Activation = $(if ([string]$lic.Rdsh['LicenseServers']) { 'licence server ' + $lic.Rdsh['LicenseServers'] } else { 'no licence server specified' }); Notes = '' } }
        if (@($lic.Packs).Count -gt 0) {
            $t = Get-PackTotals -Packs $lic.Packs
            $rows += [pscustomobject]@{ Server = $name; Product = 'RD Licensing server'; Model = 'RDS CAL packs installed here'; Basis = ((@($lic.Packs | Where-Object { $_.Type -ne 'Built-in' -and $_.ProductType -ne 'Built-in' } | ForEach-Object { '{0} {1} ({2}): {3} total, {4} issued, {5} available' -f $_.Version, $_.ProductType, $_.Type, $_.Total, $_.Issued, $_.Available })) -join '; '); Needed = ('{0} installed, {1} issued, {2} available{3}' -f $(if ($t.Unlimited) { 'unlimited' } else { $t.Installed }), $t.Issued, $t.Available, $(if ($t.Temporary -gt 0) { '; ' + $t.Temporary + ' temporary' } else { '' })); Activation = $(if ($lic.LicenseServerActivation) { 'licence server ' + $lic.LicenseServerActivation.ToLower() } else { '' }); Notes = '' }
        }
        foreach ($o in @($lic.Office)) {
            $model = $o.Channel
            if ($o.Channel -in 'KMS client', 'MAK', 'Active Directory') { $model = 'Volume licence, per device (' + $o.Channel + ')' } elseif ($o.Name -match '365|O365') { $model = 'Microsoft 365 subscription, per user' } elseif ($o.Channel) { $model = $o.Channel + ', per device' }
            $rows += [pscustomobject]@{ Server = $name; Product = $o.Name; Model = $model; Basis = 'this device or its user'; Needed = '1 licence'; Activation = $o.Status + $(if ($o.Channel) { ', ' + $o.Channel } else { '' }); Notes = $(if ($o.Status -ne 'Licensed') { 'not activated: licence or sign-in missing' } else { '' }) }
        }
        if ($lic.Roles -contains 'KMS host') { $rows += [pscustomobject]@{ Server = $name; Product = 'KMS host'; Model = 'Volume activation service (the host key covers its clients)'; Basis = ('current count {0} of {1} needed' -f $lic.Kms['CurrentCount'], $lic.Kms['RequiredClientCount']); Needed = 'no licence of its own'; Activation = ''; Notes = ('{0} requests, {1} licensed' -f $lic.Kms['TotalRequests'], $lic.Kms['LicensedRequests']) } }
    }
    return $rows
}

function Get-LicensingTotals {
    # The servers shown in numbers, for the Software report and the Licensing page: Item | Count | Detail (the names).
    # Physical and virtual servers, Hyper-V hosts and their VMs, the core licences the models call for by product, Windows
    # by activation state and channel, Office, KMS hosts with their counts, RD Licensing servers and every CAL pack
    # summed over the servers, RD Session Hosts by licensing state, SQL Server by edition, Exchange.
    param([string[]]$Servers)
    $rows = @(); $collected = 0
    $byStatus = @{}; $byChannel = @{}; $office = @{}; $kmsHosts = @(); $lsServers = @(); $packSum = [ordered]@{}; $rdshOk = @(); $rdshBad = @(); $sqlEd = @{}; $exch = @()
    $physical = @(); $virtualOnes = @(); $hvHosts = @(); $vmTotal = 0
    $names = @(Get-UniqueNames @($Servers))
    foreach ($name in $names) {
        $inv = Get-CollectorResult -Name 'Inventory' -Server $name
        foreach ($s in @(Get-SqlEditionRows -Inventory $inv)) { if (-not $sqlEd.ContainsKey($s.Edition)) { $sqlEd[$s.Edition] = @() }; $sqlEd[$s.Edition] += ('{0} ({1})' -f $name, $s.Instance) }
        if ($inv -and $inv.Reachable -and $inv.Exchange) { $exch += ('{0} ({1})' -f $name, $inv.Exchange) }
        $r = Get-CollectorResult -Name 'Licensing' -Server $name
        if (-not $r -or -not $r.Reachable) { continue }
        $collected++
        $lic = ConvertFrom-LicensingResult -Result $r
        if ($lic.Hardware.Count -gt 0) { if ([string]$lic.Hardware['Virtual'] -eq 'True') { $virtualOnes += $name } else { $physical += ('{0} ({1})' -f $name, (Get-LicensingHardwareText -Hardware $lic.Hardware)) } }
        if ($lic.Roles -contains 'Hyper-V') { $vmc = ConvertTo-LicenceNumber ([string]$lic.Hardware['VmCount']); if ($null -ne $vmc) { $vmTotal += $vmc }; $hvHosts += ('{0} ({1} VMs)' -f $name, $lic.Hardware['VmCount']) }
        if ($lic.Windows) {
            $st = [string]$lic.Windows.Status; if (-not $byStatus.ContainsKey($st)) { $byStatus[$st] = @() }; $byStatus[$st] += $name
            $ch = [string]$lic.Windows.Channel; if (-not $ch) { $ch = 'unknown' }; if (-not $byChannel.ContainsKey($ch)) { $byChannel[$ch] = @() }; $byChannel[$ch] += $name
        }
        foreach ($o in @($lic.Office)) { $st = [string]$o.Status; if (-not $office.ContainsKey($st)) { $office[$st] = @() }; $office[$st] += ('{0} ({1})' -f $name, $o.Name) }
        if ($lic.Roles -contains 'KMS host') { $kmsHosts += ('{0}: current {1} of {2} needed, {3} requests' -f $name, $lic.Kms['CurrentCount'], $lic.Kms['RequiredClientCount'], $lic.Kms['TotalRequests']) }
        if (@($lic.Packs).Count -gt 0 -or ($lic.Roles -contains 'RD Licensing')) {
            $lsServers += ($name + $(if ($lic.LicenseServerActivation) { ' (' + $lic.LicenseServerActivation.ToLower() + ')' } else { '' }))
            foreach ($p in @($lic.Packs)) {
                if ($p.Type -eq 'Built-in' -or $p.ProductType -eq 'Built-in') { continue }
                $key = '{0} - {1} ({2})' -f $p.Version, $p.ProductType, $p.Type
                if (-not $packSum.Contains($key)) { $packSum[$key] = @{ Installed = 0; Issued = 0; Available = 0; Unlimited = $false; Servers = @() } }
                $total = ConvertTo-LicenceNumber $p.Total; $issued = ConvertTo-LicenceNumber $p.Issued; $avail = ConvertTo-LicenceNumber $p.Available
                if ($null -ne $total) { $packSum[$key].Installed += $total } elseif ($p.Type -ne 'Temporary') { $packSum[$key].Unlimited = $true }
                if ($null -ne $issued) { $packSum[$key].Issued += $issued }
                if ($null -ne $avail) { $packSum[$key].Available += $avail }
                if ($packSum[$key].Servers -notcontains $name) { $packSum[$key].Servers += $name }
            }
        }
        if ([string]$lic.Rdsh['ServerMode'] -eq '1') {
            $type = ConvertTo-LicenceNumber ([string]$lic.Rdsh['LicensingType']); $graceLeft = ConvertTo-LicenceNumber ([string]$lic.Rdsh['GraceDaysLeft'])
            if ($type -in 2, 4 -and [string]$lic.Rdsh['LicenseServers']) { $rdshOk += ('{0} ({1})' -f $name, $lic.Rdsh['Mode']) }
            else { $rdshBad += ('{0} ({1}{2})' -f $name, $lic.Rdsh['Mode'], $(if ($null -ne $graceLeft -and $graceLeft -gt 0) { ', grace ' + $graceLeft + ' days left' } else { '' })) }
        }
    }
    $rows += [pscustomobject]@{ Item = 'Servers with licensing collected'; Count = $collected; Detail = ('of {0} shown' -f $names.Count) }
    $rows += [pscustomobject]@{ Item = 'Physical servers'; Count = $physical.Count; Detail = (Format-NameList $physical) }
    $rows += [pscustomobject]@{ Item = 'Virtual machines'; Count = $virtualOnes.Count; Detail = (Format-NameList $virtualOnes) }
    $rows += [pscustomobject]@{ Item = 'Hyper-V hosts'; Count = $hvHosts.Count; Detail = ((Format-NameList $hvHosts) + $(if ($hvHosts.Count -gt 0) { ' - ' + $vmTotal + ' VMs in all' } else { '' })) }
    # the core licences the models call for, summed by product over the physical servers (a VM's count is its own option)
    $needBy = [ordered]@{}
    foreach ($m in @(Get-LicensingModelRows -Servers $names)) {
        if ([string]$m.Needed -match '^(\d+) core licences') { if (-not $needBy.Contains($m.Product)) { $needBy[$m.Product] = @{ Count = 0; Servers = @() } }; $needBy[$m.Product].Count += [int]$Matches[1]; $needBy[$m.Product].Servers += $m.Server }
    }
    foreach ($product in @($needBy.Keys)) { $rows += [pscustomobject]@{ Item = 'Core licences needed: ' + $product; Count = $needBy[$product].Count; Detail = ('{0} server(s): {1}' -f @($needBy[$product].Servers).Count, (Format-NameList $needBy[$product].Servers)) } }
    foreach ($st in 'Licensed', 'Initial grace', 'Additional grace', 'Extended grace', 'Non-genuine grace', 'Notification', 'Unlicensed', 'Unknown') { if ($byStatus.ContainsKey($st)) { $rows += [pscustomobject]@{ Item = 'Windows: ' + $st; Count = @($byStatus[$st]).Count; Detail = (Format-NameList $byStatus[$st]) } } }
    foreach ($ch in @($byChannel.Keys | Sort-Object)) { $rows += [pscustomobject]@{ Item = 'Windows channel: ' + $ch; Count = @($byChannel[$ch]).Count; Detail = (Format-NameList $byChannel[$ch]) } }
    foreach ($st in @($office.Keys | Sort-Object)) { $rows += [pscustomobject]@{ Item = 'Office: ' + $st; Count = @($office[$st]).Count; Detail = (Format-NameList $office[$st]) } }
    $rows += [pscustomobject]@{ Item = 'KMS hosts'; Count = $kmsHosts.Count; Detail = ($kmsHosts -join '; ') }
    $rows += [pscustomobject]@{ Item = 'RD Licensing servers'; Count = $lsServers.Count; Detail = (Format-NameList $lsServers) }
    foreach ($key in @($packSum.Keys)) {
        $t = $packSum[$key]
        $rows += [pscustomobject]@{ Item = 'RDS CALs: ' + $key; Count = $(if ($t.Unlimited) { 'unlimited' } else { $t.Installed }); Detail = ('{0} issued, {1} available - {2}' -f $t.Issued, $t.Available, (Format-NameList $t.Servers)) }
    }
    $rows += [pscustomobject]@{ Item = 'RD Session Hosts: licensed'; Count = $rdshOk.Count; Detail = (Format-NameList $rdshOk) }
    $rows += [pscustomobject]@{ Item = 'RD Session Hosts: not configured or in grace'; Count = $rdshBad.Count; Detail = (Format-NameList $rdshBad) }
    foreach ($ed in @($sqlEd.Keys | Sort-Object)) { $rows += [pscustomobject]@{ Item = 'SQL Server: ' + $ed; Count = @($sqlEd[$ed]).Count; Detail = (Format-NameList $sqlEd[$ed]) } }
    $rows += [pscustomobject]@{ Item = 'Exchange'; Count = $exch.Count; Detail = (Format-NameList $exch) }
    return $rows
}

function Get-LicensingDetailSections {
    # The sections of a server's licensing page, and the short one the Security audit page carries
    param([string]$Server, [switch]$Short)
    $r = Get-CollectorResult -Name 'Licensing' -Server $Server
    if (-not $r) { return @(@{ Heading = 'Licensing'; Lines = @(); Note = 'not collected yet - press Check software (or AUDIT): the Licensing collector runs with it' }) }
    if (-not $r.Reachable) { return @(@{ Heading = 'Licensing'; Lines = @('unreachable: ' + [string]$r.Error) }) }
    $lic = ConvertFrom-LicensingResult -Result $r
    $sections = @()
    $lines = @()
    $hwText = Get-LicensingHardwareText -Hardware $lic.Hardware
    if ($hwText) { $lines += ('Hardware: {0}{1}{2}' -f $hwText, $(if ([string]$lic.Hardware['CpuName']) { ', ' + $lic.Hardware['CpuName'] } else { '' }), $(if ($lic.Roles -contains 'Hyper-V') { '; Hyper-V host with ' + $lic.Hardware['VmCount'] + ' VMs (' + $lic.Hardware['VmRunning'] + ' running)' } else { '' })) }
    if ([string]$lic.Os['Caption']) { $lines += ('Operating system: {0} ({1})' -f $lic.Os['Caption'], $lic.Os['Version']) }
    foreach ($p in @($lic.Products)) { $lines += ('{0}: {1} - {2}{3}{4}{5}' -f $p.Application, $p.Name, $p.Status, $(if ($p.Channel) { ', ' + $p.Channel } else { '' }), $(if ($p.Status -ne 'Licensed' -and $p.GraceDays) { ', ' + $p.GraceDays + ' days left' } else { '' }), $(if ($p.KmsHost) { ', KMS host ' + $p.KmsHost } else { '' })) }
    if (@($lic.Products).Count -eq 0) { $lines += 'no licence with a product key was read' }
    $lines += ('Roles: ' + $(if (@($lic.Roles).Count -gt 0) { @($lic.Roles) -join ', ' } else { 'none that licence' }))
    if ([string]$lic.Rdsh['ServerMode'] -eq '1') { $lines += ('RD Session Host licensing: {0}{1}{2}' -f $lic.Rdsh['Mode'], $(if ([string]$lic.Rdsh['LicenseServers']) { ' via ' + $lic.Rdsh['LicenseServers'] } else { ', no licence server specified' }), $(if ([string]$lic.Rdsh['GraceDaysLeft']) { '; grace days left: ' + $lic.Rdsh['GraceDaysLeft'] } else { '' })) }
    if ($lic.Kms.Count -gt 0) { $lines += ('KMS host: current count {0} of {1} needed; {2} requests ({3} licensed, {4} failed, {5} unlicensed, {6} initial grace, {7} additional grace, {8} notification); DNS publishing {9}; port {10}' -f $lic.Kms['CurrentCount'], $lic.Kms['RequiredClientCount'], $lic.Kms['TotalRequests'], $lic.Kms['LicensedRequests'], $lic.Kms['FailedRequests'], $lic.Kms['UnlicensedRequests'], $lic.Kms['OOBGraceRequests'], $lic.Kms['OOTGraceRequests'], $lic.Kms['NotificationRequests'], $lic.Kms['DnsPublishing'], $lic.Kms['Port']) }
    if (@($lic.Packs).Count -gt 0) { $t = Get-PackTotals -Packs $lic.Packs; $lines += ('RD Licensing: {0} installed, {1} issued, {2} available{3}{4}' -f $(if ($t.Unlimited) { 'unlimited' } else { $t.Installed }), $t.Issued, $t.Available, $(if ($t.Temporary -gt 0) { '; ' + $t.Temporary + ' temporary' } else { '' }), $(if ($lic.LicenseServerActivation) { '; licence server ' + $lic.LicenseServerActivation.ToLower() } else { '' })) }
    if (@($lic.Errors).Count -gt 0) { $lines += ('Could not read: ' + (@($lic.Errors) -join '; ')) }
    $sections += @{ Heading = ('Licensing (collected {0})' -f $r.Checked.ToString('yyyy-MM-dd HH:mm:ss')); Lines = $lines }
    if ($Short) { return $sections }
    $models = @(Get-LicensingModelRows -Servers @($Server))
    if ($models.Count -gt 0) {
        $sections += @{ Heading = 'Licensing models'; Rows = $models; Columns = @('Product', 'Model', 'Basis', 'Needed', 'Activation', 'Notes'); Note = $script:LicensingRulesNote }
        $sections += @{ Heading = $script:LicensingRulesHeading; Groups = $script:LicensingRules }
    }
    if (@($lic.Packs).Count -gt 0) { $sections += @{ Heading = 'RDS CAL key packs'; Rows = @($lic.Packs); Columns = @('KeyPackId', 'Description', 'Type', 'ProductType', 'Version', 'Total', 'Issued', 'Available', 'Expires'); Note = 'The built-in pack is the licence server''s own; a temporary pack holds clients without a permanent CAL.' } }
    $issuedRows = @(foreach ($line in @($r.Issued)) { $f = [string]$line -split '\|'; if ($f.Count -ge 6) { [pscustomobject]@{ Pack = $f[0]; Status = $f[1]; Computer = $f[2]; User = $f[3]; Issued = $f[4]; Expires = $f[5] } } })
    if ($issuedRows.Count -gt 0) { $sections += @{ Heading = ('Issued RDS CALs (the first {0})' -f $issuedRows.Count); Rows = $issuedRows; Columns = @('Pack', 'Status', 'Computer', 'User', 'Issued', 'Expires') } }
    if (@($lic.Vms).Count -gt 0) { $sections += @{ Heading = ('Virtual machines on this host (the first {0})' -f @($lic.Vms).Count); Rows = @($lic.Vms); Columns = @('Name', 'State') } }
    return $sections
}

function Get-LicensingDetailsHtml {
    # One server's licences in full: the page behind a double-click, and the Licensing window's server links
    param([string]$Server)
    $row = @(Get-LicensingRows -Servers @($Server))[0]
    $facts = @(@('Edition', $row.Edition), @('Hardware', $row.Hardware), @('Activation', $row.Activation), @('Channel', $row.Channel), @('KMS host', $row.'KMS host'), @('Roles', $row.Roles), @('SQL Server', $row.'SQL Server'), @('Exchange', $row.Exchange))
    return (New-DetailsHtml -Title "Licensing: $Server" -Subtitle 'the licensing models, activation, KMS, RD Licensing CALs, RD Session Host licensing' -Console 'Software' -Facts $facts -Sections @(Get-LicensingDetailSections -Server $Server))
}

function Get-LicensingReportHtml {
    # The Licensing button of the Software console: the models, one row per server and the totals of the servers shown, as
    # a page (the same tables the Software report carries)
    param([string[]]$Servers)
    $names = @(Get-UniqueNames @($Servers))
    $rows = @(Get-LicensingRows -Servers $names)
    $collected = @($rows | Where-Object { $_.Activation -notin 'not collected', 'unreachable' }).Count
    $facts = @(@('Servers shown', [string]$names.Count), @('Licensing collected', ('{0} (Check software or AUDIT collects it)' -f $collected)))
    $sections = @(
        @{ Heading = 'Licensing models (per server and product)'; Rows = @(Get-LicensingModelRows -Servers $names); Columns = $script:LicensingModelColumns; Note = $script:LicensingRulesNote },
        @{ Heading = 'Totals of the servers shown'; Rows = @(Get-LicensingTotals -Servers $names); Columns = @('Item', 'Count', 'Detail') },
        @{ Heading = 'Servers'; Rows = $rows; Columns = $script:LicensingColumns; Note = 'Activation: the state of the Windows licence (then Office). Double-click a server on the Software grid, or open its page from the O/S Patching grid, for its licences in full.' },
        @{ Heading = $script:LicensingRulesHeading; Groups = $script:LicensingRules },
        @{ Heading = 'References (Microsoft; not reachable from an air-gapped network)'; Lines = @($script:LicensingReferences) }
    )
    return (New-DetailsHtml -Title 'Licensing' -Subtitle 'the licensing models, activation, KMS, RD Licensing CALs, RD Session Hosts - of the servers shown' -Console 'Software' -Facts $facts -Sections $sections)
}

# ---------------------------------------------------------------------
#  The checks: four lights in the Security grid (Group 'Licensing', no ISM control of their own)
# ---------------------------------------------------------------------
New-Check -Id 'SEC-LIC-01' -Console 'Security' -Group 'Licensing' -Title 'Windows is activated (licensed)' -Severity 'Medium' -Needs 'Licensing' `
    -Fix 'Activate Windows: a KMS host or Active Directory based activation for a volume licence, a MAK key otherwise (slmgr /ipk, slmgr /ato). An evaluation edition must be converted (dism /online /Set-Edition) before its clock runs out.' `
    -Why 'Past its grace period a server enters notification mode; an evaluation edition shuts down every hour. Activation is also what a licence audit asks for first.' `
    -Test {
        param($c)
        $lic = ConvertFrom-LicensingResult -Result $c.Licensing
        if (-not $lic.Windows) { return (NotAssessable ('no Windows licence entry read' + $(if (@($lic.Errors).Count -gt 0) { ' (' + (@($lic.Errors) -join '; ') + ')' } else { '' }))) }
        $w = $lic.Windows
        $text = '{0}, {1}{2}' -f $w.Status, $(if ($w.Channel) { $w.Channel } else { 'channel unknown' }), $(if ($w.KmsHost) { ' via ' + $w.KmsHost } else { '' })
        if ($w.Status -eq 'Licensed') { return (Pass $text) }
        if ($w.Status -in 'Initial grace', 'Additional grace', 'Extended grace') { return (Warn ($text + ' - ' + $w.GraceDays + ' days left')) }
        return (Fail $text)
    }

New-Check -Id 'SEC-LIC-02' -Console 'Security' -Group 'Licensing' -Title 'RD Session Host licensing is configured' -Severity 'High' -Needs 'Licensing' `
    -Fix 'Set the licensing mode (per user or per device) and name the licence server: Server Manager > Remote Desktop Services > Deployment, or the Group Policy "Set the Remote Desktop licensing mode" and "Use the specified Remote Desktop license servers".' `
    -Why 'An RD Session Host without a licensing mode and a licence server runs on a 120-day grace period; when it ends, every connection but the administrator''s is refused.' `
    -Test {
        param($c)
        $lic = ConvertFrom-LicensingResult -Result $c.Licensing
        if ([string]$lic.Rdsh['ServerMode'] -ne '1' -and ($lic.Roles -notcontains 'RD Session Host')) { return (NotApplicable 'not an RD Session Host') }
        if ($lic.Rdsh.Count -eq 0) { return (NotAssessable ('RD Session Host settings not read' + $(if (@($lic.Errors).Count -gt 0) { ' (' + (@($lic.Errors) -join '; ') + ')' } else { '' }))) }
        $type = ConvertTo-LicenceNumber ([string]$lic.Rdsh['LicensingType']); $mode = [string]$lic.Rdsh['Mode']; $ls = [string]$lic.Rdsh['LicenseServers']
        $graceLeft = ConvertTo-LicenceNumber ([string]$lic.Rdsh['GraceDaysLeft'])
        $graceText = ''; if ($null -ne $graceLeft -and $graceLeft -gt 0) { $graceText = ' - grace period: ' + $graceLeft + ' days left, then clients are refused' }
        if ($type -in 2, 4) {
            if ($ls) { return (Pass ($mode + ' via ' + $ls)) }
            return (Warn ($mode + ', but no licence server is specified' + $graceText))
        }
        return (Fail ($mode + $graceText))
    }

New-Check -Id 'SEC-LIC-03' -Console 'Security' -Group 'Licensing' -Title 'RD Licensing: CALs available, none temporary, server activated' -Severity 'Medium' -Needs 'Licensing' `
    -Fix 'Install more CALs on the licence server (Remote Desktop Licensing Manager), or move users to a pack that has some; activate the licence server. Clients on temporary CALs get a permanent one at their next logon once a pack has them.' `
    -Why 'A licence server with no CAL available hands out temporary CALs for 90 days and then refuses; an unactivated licence server issues temporary CALs only.' `
    -Test {
        param($c)
        $lic = ConvertFrom-LicensingResult -Result $c.Licensing
        if (@($lic.Packs).Count -eq 0 -and ($lic.Roles -notcontains 'RD Licensing')) { return (NotApplicable 'not an RD Licensing server') }
        if (@($lic.Packs).Count -eq 0) { return (NotAssessable ('RD Licensing key packs not read' + $(if (@($lic.Errors).Count -gt 0) { ' (' + (@($lic.Errors) -join '; ') + ')' } else { '' }))) }
        $t = Get-PackTotals -Packs $lic.Packs
        $text = '{0} installed, {1} issued, {2} available' -f $(if ($t.Unlimited) { 'unlimited' } else { $t.Installed }), $t.Issued, $t.Available
        if ($lic.LicenseServerActivation -eq 'Not activated') { return (Fail ('the licence server is not activated: temporary CALs only (' + $text + ')')) }
        $items = @()
        if ($t.Temporary -gt 0) { $items += ('{0} temporary CAL(s) issued - clients without a permanent CAL' -f $t.Temporary) }
        $empty = @($lic.Packs | Where-Object { $_.Type -notin 'Built-in', 'Temporary' -and $_.ProductType -ne 'Built-in' -and (ConvertTo-LicenceNumber $_.Available) -eq 0 } | ForEach-Object { $_.Description })
        if ($empty.Count -gt 0) { $items += ('no CAL available in: ' + ($empty -join ', ')) }
        if ($items.Count -gt 0) { return (Warn $text -Items $items) }
        return (Pass $text)
    }

New-Check -Id 'SEC-LIC-04' -Console 'Security' -Group 'Licensing' -Title 'KMS host: activation threshold reached' -Severity 'Low' -Needs 'Licensing' `
    -Fix 'Nothing to change on the host: the count rises as distinct clients contact it (25 for Windows clients, 5 for servers). Until then its clients stay in their grace period; point them at a host that has reached the count, or use Active Directory based activation.' `
    -Why 'A KMS host activates no client until enough distinct machines have asked it; its own count is the first thing to check when clients will not activate.' `
    -Test {
        param($c)
        $lic = ConvertFrom-LicensingResult -Result $c.Licensing
        if ($lic.Roles -notcontains 'KMS host') { return (NotApplicable 'not a KMS host') }
        $cur = ConvertTo-LicenceNumber ([string]$lic.Kms['CurrentCount']); $need = ConvertTo-LicenceNumber ([string]$lic.Kms['RequiredClientCount'])
        if ($null -eq $cur -or $null -eq $need) { return (NotAssessable 'the KMS counts were not read') }
        $text = 'current count {0} of {1}; {2} requests, {3} licensed' -f $cur, $need, $lic.Kms['TotalRequests'], $lic.Kms['LicensedRequests']
        if ($cur -ge $need) { return (Pass $text) }
        return (Warn ($text + ' - clients do not activate until ' + $need + ' distinct machines have contacted the host'))
    }
