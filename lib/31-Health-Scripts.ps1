# =====================================================================
#  31-Health-Scripts.ps1  -  SCRIPTS AND SCHEDULED TASKS: WHAT RUNS ON A SERVER, FROM WHERE, AND WHAT IT DOES
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  "Scripts and tasks (ticked)" on the Health console runs the Scripts collector on the ticked servers.  On each
#  server, read-only: every scheduled task outside \Microsoft\ (state, author, the account and run level, the
#  triggers in words, the action, the script it runs, last run and result), and every PowerShell script (.ps1,
#  .psm1) under the folders named on the Settings tab (every fixed drive when none is named).  Each script is parsed
#  with PowerShell's own parser, never run: its functions, what it does (web requests, Active Directory, SQL, mail,
#  files, services, remoting ...), the scripts it calls, and what should be looked at (a password in clear, an
#  encoded command, code downloaded and run, a folder every user can write to, a task's script that is missing).
#  The walk is bounded (owner's concern 2026-11-06: slow or stalling searches): an explicit stack instead of
#  recursion, every folder read in its own try (no access = one line in the report, the walk carries on),
#  junctions and symbolic links never followed, Windows / Program Files / AppData and the like skipped by rule, each
#  script analysed as it is found, and a time budget per server (ScriptSearchSeconds) after which the result says
#  PARTIAL and what was left (every script listed is complete).
#  The report (reports\Scripts-<date>.html + CSV) and the server's Health page carry the result; it is saved in
#  state\servers\ like every collector's.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  31-Health-Scripts.ps1
#  New 2026-11-06 (owner's ask: a Health button that finds the PowerShell scripts and scheduled tasks on the ticked
#  servers and reports their functions and operations; the example it replaces searched a whole drive with
#  Get-ChildItem -Recurse and regexes).  The walk is bounded (a try per folder, no reparse points, skip rules, a time
#  budget), the scripts are parsed and never run, a password's line is named and never its value.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : __________cf____________________   Date : _____8-11-26_________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   : *has come across from previous script locator coding project.
#    -
# =====================================================================

# the scheduled-task folders never listed: the OS's own
$script:ScriptTaskSkipPaths = @('\Microsoft\*')

$script:RemoteScriptsScript = {
    param([string[]]$Folders, [string[]]$Skip, [int]$BudgetSec, [string[]]$TaskSkipPaths)
    $ErrorActionPreference = 'Continue'
    $total = [System.Diagnostics.Stopwatch]::StartNew()
    $maxScripts = 3000; $maxFileBytes = 1048576; $maxSkipped = 300; $maxFunctions = 30; $maxSigned = 500
    $errors = @()
    # one cell of a "a|b|c" line: no pipes, no line breaks
    $cell = { param($s) (([string]$s) -replace '[\r\n\t|]+', ' ').Trim() }
    $why = { param($er) $x = $er.Exception; if ($x -and $x.InnerException) { $x = $x.InnerException }
        if ($x -is [System.UnauthorizedAccessException]) { 'access denied' } elseif ($x -is [System.IO.PathTooLongException]) { 'path too long' } elseif ($x -is [System.IO.DirectoryNotFoundException]) { 'gone while walking' } elseif ($x) { $x.GetType().Name } else { 'error' } }
    $lineOf = { param($t, $idx) ([regex]::Matches($t.Substring(0, $idx), "`n")).Count + 1 }
    # script paths in a command line or a script: quoted (spaces allowed) or bare; a flag inside the quotes is dropped
    $pathsIn = { param($t, $exts)
        $rx = '(?i)"([^"\r\n]+\.(?:' + $exts + '))"|''([^''\r\n]+\.(?:' + $exts + '))''|((?:[A-Za-z]:\\|\\\\|\.\\|%[^%]+%\\|\$\w+\\)[^"''\s;&|]+\.(?:' + $exts + '))'
        $outp = @()
        foreach ($pm in [regex]::Matches([string]$t, $rx)) {
            $v = $pm.Groups[1].Value; if (-not $v) { $v = $pm.Groups[2].Value }; if (-not $v) { $v = $pm.Groups[3].Value }
            if (-not $v) { continue }
            $start = [regex]::Match($v, '(?i)(?:[A-Za-z]:\\|\\\\|\.\\|%[^%]+%\\|\$\w+\\)')
            if ($start.Success -and $start.Index -gt 0) { $v = $v.Substring($start.Index) }
            $outp += $v.Trim()
        }
        return @($outp)
    }

    # ---- what a script does: command names (from the parser) -> a short label ----
    $cats = @(
        @{ Name = 'web requests';         Match = '^(invoke-webrequest|invoke-restmethod|curl|wget|iwr|irm|bitsadmin|start-bitstransfer)$' },
        @{ Name = 'Active Directory';     Match = '^(get|set|new|remove|add|move|enable|disable|search|unlock|reset|rename)-ad[a-z]|^(dsquery|dsget|dsadd|dsmod|dsrm|ldifde|csvde|adfind|repadmin|nltest)$' },
        @{ Name = 'SQL';                  Match = '^(invoke-sqlcmd|sqlcmd|bcp|osql|invoke-dbaquery|invoke-dbadiagnosticquery)$' },
        @{ Name = 'email';                Match = '^(send-mailmessage|send-mailkitmessage|blat|send-emailmessage)$' },
        @{ Name = 'file operations';      Match = '^(copy-item|move-item|remove-item|rename-item|robocopy|xcopy|copy|move|del|erase|rmdir|rd|compress-archive|expand-archive|7z|7za)$' },
        @{ Name = 'runs programs';        Match = '^(start-process|invoke-expression|iex|start-job|cmd|wscript|cscript|psexec|invoke-item|msiexec|rundll32)$' },
        @{ Name = 'exports data';         Match = '^(export-csv|export-clixml|out-file|set-content|add-content|convertto-html|export-excel|tee-object)$' },
        @{ Name = 'modules';              Match = '^(import-module|add-pssnapin|add-type)$' },
        @{ Name = 'services';             Match = '^(get|start|stop|restart|set|new|remove|suspend|resume)-service$|^sc$' },
        @{ Name = 'processes';            Match = '^(get-process|stop-process|wait-process|taskkill|tasklist)$' },
        @{ Name = 'backup or restore';    Match = '^(backup-|restore-|wbadmin$|vssadmin$|checkpoint-computer$|export-vm$|import-vm$)' },
        @{ Name = 'registry';             Match = '^(get|set|new|remove|rename)-itemproperty$|^(reg|regedit)$' },
        @{ Name = 'scheduled tasks';      Match = '-scheduledtask|^schtasks$' },
        @{ Name = 'remoting';             Match = '^(invoke-command|new-pssession|enter-pssession|new-cimsession|winrs|winrm)$' },
        @{ Name = 'WMI or CIM';           Match = '^(get-wmiobject|get-ciminstance|invoke-wmimethod|invoke-cimmethod|set-wmiinstance|wmic)$' },
        @{ Name = 'credentials';          Match = '^(get-credential|convertto-securestring|convertfrom-securestring|cmdkey|runas)$' },
        @{ Name = 'event logs';           Match = '^(get-winevent|get-eventlog|write-eventlog|clear-eventlog|limit-eventlog|wevtutil)$' },
        @{ Name = 'shares and drives';    Match = '^(new|remove|get|set|grant|revoke)-smb(share|shareaccess|mapping)$|^(net|net1|new-psdrive|mountvol|diskpart)$' },
        @{ Name = 'shutdown or restart';  Match = '^(restart-computer|stop-computer|shutdown)$' },
        @{ Name = 'accounts and groups';  Match = '-(localuser|localgroupmember|localgroup|aduser|adgroupmember|adgroup|adcomputer|adaccountpassword|adserviceaccount)$' },
        @{ Name = 'network and firewall'; Match = '-netfirewall|^netsh$|-netipaddress$|-dnsclient|-netadapter|-netroute$|^route$|^ipconfig$' },
        @{ Name = 'certificates';         Match = '-certificate$|^certutil$|-pfxcertificate$|-selfsignedcertificate$|^certreq$' },
        @{ Name = 'virtual machines';     Match = '^(get|set|new|start|stop|remove|restart|suspend|resume|checkpoint|restore|export|import|move)-vm(snapshot|switch|harddiskdrive|networkadapter|processor|memory|checkpoint)?$|^connect-viserver$|-vmhost$|^get-datastore$|^get-vievent$|^get-snapshot$' },
        @{ Name = 'cloud (Azure, Microsoft 365, AWS)'; Match = '^(connect-azaccount|connect-azuread|connect-mggraph|connect-msolservice|connect-exchangeonline|connect-sposervice|connect-microsoftteams)$|^[a-z]+-az[a-z]|^[a-z]+-mg[a-z]|-msol[a-z]|^[a-z]+-(ec2|s3|iam|ssm|cfn)[a-z]' },
        @{ Name = 'Exchange';             Match = '-mailbox|-distributiongroup$|-transportrule$|-mailboxdatabase$|-receiveconnector$|-sendconnector$' },
        @{ Name = 'IIS';                  Match = '-web(site|apppool|binding|application|configurationproperty)$|^(appcmd|iisreset)$' },
        @{ Name = 'DNS or DHCP';          Match = '-dnsserver|-dhcpserver' },
        @{ Name = 'updates and features'; Match = '-windowsupdate|-wulist$|^(wusa|dism)$|-windowsfeature$|-windowsoptionalfeature$|-windowscapability$' },
        @{ Name = 'printers';             Match = '-printer(port|driver)?$' },
        @{ Name = 'Group Policy';         Match = '^(gpupdate|gpresult)$|-gpo$|-gplink$|-gpregistryvalue$' }
    )
    $typeCats = @(
        @{ Name = 'web requests';     Match = '(?i)\b(System\.Net\.)?(WebClient|HttpClient|HttpWebRequest)\b|Net\.Sockets' },
        @{ Name = 'SQL';              Match = '(?i)SqlClient|SqlConnection|OleDb|OdbcConnection|System\.Data\.' },
        @{ Name = 'email';            Match = '(?i)Net\.Mail|SmtpClient' },
        @{ Name = 'Active Directory'; Match = '(?i)DirectoryServices|DirectoryEntry|DirectorySearcher|ADSI' }
    )
    # a password written into the script: the flag names the line, never the value
    $secretRx = @(
        '(?im)^[^\r\n#]*ConvertTo-SecureString\s+(?:-String\s+)?(["''])[^"''\r\n$]{1,}\1[^\r\n]*-AsPlainText',
        '(?im)^[^\r\n#]*-AsPlainText[^\r\n]*ConvertTo-SecureString\s+(?:-String\s+)?(["''])[^"''\r\n$]{1,}\1',
        '(?im)^[^\r\n#]*\$\w*(?:password|passwd|pwd|secret|apikey|api_key|token)\w*\s*=\s*(["''])[^"''\r\n$]{3,}\1',
        '(?im)^[^\r\n#]*\s-(?:Password|Pwd|Secret|ApiKey|Token)\s+(["''])[^"''\r\n$]{3,}\1'
    )

    # ---- which users may write into a folder (cached per folder): a script every user can change ----
    $aclCache = @{}
    $writersRx = '^(Everyone|BUILTIN\\Users|NT AUTHORITY\\Authenticated Users|NT AUTHORITY\\INTERACTIVE|Users|.*\\Domain Users)$'
    $writeMask = [int][System.Security.AccessControl.FileSystemRights]'Write, Modify, FullControl, CreateFiles, WriteData, AppendData, ChangePermissions, TakeOwnership'
    $writeMask = $writeMask -bor 0x40000000 -bor 0x10000000   # GENERIC_WRITE, GENERIC_ALL
    $folderOpen = { param($folder)
        if ($aclCache.ContainsKey($folder)) { return $aclCache[$folder] }
        $open = ''
        try {
            $acl = Get-Acl -LiteralPath $folder -ErrorAction Stop
            $who = @()
            foreach ($rule in $acl.Access) {
                if ($rule.AccessControlType -ne 'Allow') { continue }
                $id = [string]$rule.IdentityReference
                if ($id -notmatch $writersRx) { continue }
                if (([int]$rule.FileSystemRights -band $writeMask) -ne 0) { $who += $id }
            }
            if ($who.Count -gt 0) { $open = (@($who | Select-Object -Unique) -join ', ') }
        } catch { $open = '' }
        $aclCache[$folder] = $open
        return $open
    }

    # ---- one script: parsed, never run ----
    $analyse = { param($file, $checkSignature)
        $res = @{ Functions = @(); Operations = @(); Calls = @(); Flags = @(); Signed = ''; Purpose = ''; Error = ''; SizeKB = ''; Modified = '' }
        $text = ''
        try {
            $fi = New-Object System.IO.FileInfo $file
            $res.SizeKB = [math]::Round($fi.Length / 1KB, 1); $res.Modified = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
            if ($fi.Length -gt $maxFileBytes) { $res.Error = ('not analysed: {0} KB is over the 1 MB cap' -f [int]($fi.Length / 1KB)); return $res }
            $text = [System.IO.File]::ReadAllText($file)
        } catch { $res.Error = 'could not read: ' + (& $why $_); return $res }
        if ($file -notmatch '(?i)\.(ps1|psm1)$') { $res.Signed = '' }   # a batch file a task runs: no Authenticode signature to read
        elseif ($checkSignature) {
            try {
                $sig = Get-AuthenticodeSignature -LiteralPath $file -ErrorAction Stop; $res.Signed = [string]$sig.Status
                if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate) {
                    $cn = [regex]::Match([string]$sig.SignerCertificate.Subject, '^CN=(?:"([^"]+)"|([^,]+))')   # a quoted CN holds a comma: CN="Chocolatey Software, Inc."
                    $who = $cn.Groups[1].Value; if (-not $who) { $who = $cn.Groups[2].Value }; if (-not $who) { $who = [string]$sig.SignerCertificate.Subject }
                    $res.Signed = 'Valid (' + $who.Trim() + ')'
                }
            } catch { $res.Signed = '' }
        } else { $res.Signed = 'not checked' }
        # what it is for: .SYNOPSIS, else the first comment line near the top
        $m = [regex]::Match($text, '(?im)^\s*\.SYNOPSIS\s*\r?\n\s*([^\r\n]+)')
        if ($m.Success) { $res.Purpose = $m.Groups[1].Value.Trim() } else {
            # the first comment line near the top that says something: not one that only repeats the file name or draws a rule
            $leafName = [System.IO.Path]::GetFileName($file); $stem = [System.IO.Path]::GetFileNameWithoutExtension($file)
            foreach ($m2 in [regex]::Matches($text, '(?m)^\s*#(?!requires|!)\s*([^\r\n]{3,})')) {
                if ($m2.Index -ge 600) { break }
                $cand = $m2.Groups[1].Value.Trim(' ', '#', '-', '=', '*')
                if ($cand.Length -lt 3 -or $cand -ieq $leafName -or $cand -ieq $stem) { continue }
                $res.Purpose = $cand; break
            }
        }
        if ($res.Purpose.Length -gt 120) { $res.Purpose = $res.Purpose.Substring(0, 117) + '...' }
        $names = @{}
        $tokens = $null; $perr = $null; $ast = $null
        try { $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$perr) } catch { $ast = $null }
        if ($ast) {
            foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) { $res.Functions += $fn.Name }
            foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)) {
                $cmdName = $c.GetCommandName()
                if (-not $cmdName) { continue }
                $leaf = (($cmdName -replace '^.*[\\/]', '') -replace '\.exe$', '').ToLower()
                $names[$leaf] = $true
                $ctext = $c.Extent.Text
                if ($cmdName -match '(?i)\.(ps1|psm1|bat|cmd)$') { $res.Calls += $cmdName }
                if ($leaf -match '^(powershell|pwsh|start-process|cmd|invoke-expression|iex)$') {
                    foreach ($pv in @(& $pathsIn $ctext 'ps1|bat|cmd')) { $res.Calls += $pv }
                }
                if ($leaf -match '^(powershell|pwsh)$' -and $ctext -match '(?i)\s-(e|ec|enc|encodedcommand)\s') { $res.Flags += 'encoded command' }
            }
        } else {
            $res.Error = 'not parsed as PowerShell'
            foreach ($fm in [regex]::Matches($text, '(?im)^\s*function\s+([\w\-\.:]+)')) { $res.Functions += $fm.Groups[1].Value }
        }
        foreach ($cat in $cats) { if (@(@($names.Keys) -match $cat.Match).Count -gt 0) { $res.Operations += $cat.Name } }
        foreach ($tc in $typeCats) { if ($res.Operations -notcontains $tc.Name -and $text -match $tc.Match) { $res.Operations += $tc.Name } }
        foreach ($rx in $secretRx) { $sm = [regex]::Match($text, $rx); if ($sm.Success) { $res.Flags += ('password in clear (line {0})' -f (& $lineOf $text $sm.Index)); break } }
        if ($text -match '(?i)(DownloadString|DownloadFile|Invoke-WebRequest|Invoke-RestMethod|\biwr\b|\birm\b)' -and $text -match '(?i)(Invoke-Expression|\biex\b)') { $res.Flags += 'downloads and runs code' }
        if ($text -match '(?i)FromBase64String' -and $text -match '(?i)(Invoke-Expression|\biex\b)') { $res.Flags += 'runs decoded code' }
        return $res
    }

    # ---- the scripts a task action runs (a batch file followed into the .ps1 it calls) ----
    $scriptsIn = { param($exe, $argText, $wd)
        $outp = @()
        $resolve = { param($p) $q = [System.Environment]::ExpandEnvironmentVariables(([string]$p).Trim().Trim('"', "'"))
            if ($q -match '^\.\\' -and $wd) { $q = Join-Path $wd ($q -replace '^\.\\', '') } elseif ($q -notmatch '^([A-Za-z]:\\|\\\\)' -and $wd) { $q = Join-Path $wd $q }
            $q }
        if ($exe -match '(?i)\.(ps1|bat|cmd)$') { $outp += (& $resolve $exe) }
        elseif ($exe -match '(?i)(^|\\)(powershell|pwsh)(\.exe)?$') {
            foreach ($pv in @(& $pathsIn $argText 'ps1')) { $outp += (& $resolve $pv) }
            $fm = [regex]::Match($argText, '(?i)-f(?:ile)?\s+"?([^"\s]+\.ps1)"?')
            if ($fm.Success -and $fm.Groups[1].Value -notmatch '^([A-Za-z]:\\|\\\\|\.\\)') { $outp += (& $resolve $fm.Groups[1].Value) }
        } elseif ($exe -match '(?i)(^|\\)cmd(\.exe)?$') {
            foreach ($pv in @(& $pathsIn $argText 'bat|cmd|ps1')) { $outp += (& $resolve $pv) }
        }
        $more = @()
        foreach ($p in $outp) {
            if ($p -match '(?i)\.(bat|cmd)$' -and (Test-Path -LiteralPath $p)) {
                try { $bt = [System.IO.File]::ReadAllText($p); foreach ($pv in @(& $pathsIn $bt 'ps1')) { $more += [System.Environment]::ExpandEnvironmentVariables($pv) } } catch { }
            }
        }
        return @(@($outp) + @($more) | Select-Object -Unique)
    }

    # ---- a trigger in words ----
    $trigText = { param($tr)
        $cls = ''; try { $cls = [string]$tr.CimClass.CimClassName } catch { $cls = '' }
        $start = ''
        if ($tr.StartBoundary) { $sb = [string]$tr.StartBoundary; $tm = [regex]::Match($sb, 'T(\d\d:\d\d)'); if ($tm.Success) { $start = $tm.Groups[1].Value } else { $start = $sb } }
        $text = ''
        if ($cls -match 'Daily') { $n = 1; try { $n = [int]$tr.DaysInterval } catch { $n = 1 }; if ($n -gt 1) { $text = "every $n days at $start" } else { $text = "daily at $start" } }
        elseif ($cls -match 'Weekly') {
            $dow = @(); $mask = 0; try { $mask = [int]$tr.DaysOfWeek } catch { $mask = 0 }
            $dnames = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'); for ($b = 0; $b -lt 7; $b++) { if ($mask -band (1 -shl $b)) { $dow += $dnames[$b] } }
            $text = 'weekly ' + ($dow -join ',') + " at $start"
        }
        elseif ($cls -match 'Boot') { $text = 'at startup' }
        elseif ($cls -match 'Logon') { $text = 'at logon'; if ($tr.UserId) { $text += ' of ' + $tr.UserId } }
        elseif ($cls -match 'Idle') { $text = 'on idle' }
        elseif ($cls -match 'Event') { $text = 'on an event' }
        elseif ($cls -match 'Registration') { $text = 'on registration' }
        elseif ($cls -match 'SessionState') { $text = 'on a session change' }
        elseif ($cls -match 'Time') { $text = "once at $start" }
        elseif ($cls) { $text = ($cls -replace '^MSFT_Task', '') -replace 'Trigger$', '' } else { $text = 'trigger' }
        $rep = ''; try { if ($tr.Repetition -and $tr.Repetition.Interval) { $rep = ', repeat every ' + (([string]$tr.Repetition.Interval) -replace '^PT', '').ToLower() } } catch { $rep = '' }
        $off = ''; try { if ($tr.PSObject.Properties['Enabled'] -and $tr.Enabled -eq $false) { $off = ' (disabled)' } } catch { $off = '' }
        return ($text + $rep + $off)
    }

    # ---- 1. the scheduled tasks ----
    $taskRecs = @(); $taskTotal = 0
    $taskScriptMap = @{}                                                 # script path (lower case) -> the tasks that run it
    $taskScripts = New-Object System.Collections.Generic.List[string]    # scripts run by tasks: analysed even outside the folders
    $hasModule = [bool](Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)
    if ($hasModule) {
        try {
            $allTasks = @(Get-ScheduledTask -ErrorAction Stop)
            $taskTotal = $allTasks.Count
            foreach ($t in $allTasks) {
                $tp = [string]$t.TaskPath
                $skipIt = $false; foreach ($sp in @($TaskSkipPaths)) { if ($sp -and $tp -like $sp) { $skipIt = $true; break } }
                if ($skipIt) { continue }
                $author = [string]$t.Author
                if ($author -match '^(Microsoft|Microsoft Corporation|\$\(@%)') { continue }   # the OS's own outside \Microsoft\ (a localised author reads $(@%SystemRoot%...))
                $info = $null; try { $info = $t | Get-ScheduledTaskInfo -ErrorAction Stop } catch { $info = $null }
                $runAs = ''; $level = ''
                if ($t.Principal) { $runAs = [string]$t.Principal.UserId; if (-not $runAs) { $runAs = [string]$t.Principal.GroupId }; $level = [string]$t.Principal.RunLevel }
                $trig = @(); foreach ($tr in @($t.Triggers)) { if ($tr) { $trig += (& $trigText $tr) } }
                if ($trig.Count -eq 0) { $trig = @('no trigger') }
                $actions = @(); $scriptsOf = @(); $flags = @()
                foreach ($a in @($t.Actions)) {
                    if (-not $a) { continue }
                    if (-not $a.PSObject.Properties['Execute'] -or -not $a.Execute) { $actions += 'COM handler'; continue }
                    $exe = [System.Environment]::ExpandEnvironmentVariables(([string]$a.Execute).Trim().Trim('"'))
                    $argText = [string]$a.Arguments
                    $actions += ($exe + ' ' + $argText).Trim()
                    foreach ($sp in @(& $scriptsIn $exe $argText ([string]$a.WorkingDirectory))) { $scriptsOf += $sp }
                    if ($argText -match '(?i)\s-(e|ec|enc|encodedcommand)\s') { $flags += 'encoded command' }
                }
                $scriptCells = @()
                foreach ($sp in @($scriptsOf | Select-Object -Unique)) {
                    if (-not (Test-Path -LiteralPath $sp)) { $scriptCells += ($sp + ' (not found)'); $flags += 'script not found'; continue }
                    $key = $sp.ToLower()
                    if (-not $taskScriptMap.ContainsKey($key)) { $taskScriptMap[$key] = @() }
                    $taskScriptMap[$key] += ($tp + $t.TaskName)
                    $scriptCells += $sp
                    if (-not $taskScripts.Contains($sp)) { $taskScripts.Add($sp) }
                }
                $last = ''; $result = ''; $next = ''
                if ($info) {
                    if ($info.LastRunTime -and $info.LastRunTime.Year -gt 1999) { $last = $info.LastRunTime.ToString('yyyy-MM-dd HH:mm') }
                    $code = [int64]$info.LastTaskResult; if ($code -lt 0) { $code += 4294967296 }; $result = ('0x{0:X}' -f $code)
                    if ($info.NextRunTime) { $next = $info.NextRunTime.ToString('yyyy-MM-dd HH:mm') }
                }
                $taskRecs += @{ Path = $tp; Name = [string]$t.TaskName; State = [string]$t.State; Author = $author; RunAs = $runAs; Level = $level; Triggers = ($trig -join '; '); Action = ($actions -join '; '); Scripts = ($scriptCells -join '; '); ScriptPaths = @($scriptsOf | Select-Object -Unique); Last = $last; Result = $result; Next = $next; Flags = @($flags) }
            }
        } catch { $errors += 'tasks: ' + $_.Exception.Message }
    } else {
        # no ScheduledTasks module (an old server): schtasks' own listing, fewer fields
        try {
            $csv = @(schtasks.exe /query /fo csv /v 2>$null | Where-Object { $_ -and $_ -notmatch '^"HostName"' })
            $header = '"HostName","TaskName","Next Run Time","Status","Logon Mode","Last Run Time","Last Result","Author","Task To Run","Start In","Comment","Scheduled Task State","Idle Time","Power Management","Run As User","Delete Task If Not Rescheduled","Stop Task If Runs X Hours and X Mins","Schedule","Schedule Type","Start Time","Start Date","End Date","Days","Months","Repeat: Every","Repeat: Until: Time","Repeat: Until: Duration","Repeat: Stop If Still Running"'
            $rows = @(ConvertFrom-Csv -InputObject (@($header) + $csv))
            $taskTotal = $rows.Count
            foreach ($row in $rows) {
                $tp = [string]$row.TaskName; $nm = $tp -replace '^.*\\', ''; $tp = $tp -replace '[^\\]+$', ''
                $skipIt = $false; foreach ($sp in @($TaskSkipPaths)) { if ($sp -and $tp -like $sp) { $skipIt = $true; break } }
                if ($skipIt -or ([string]$row.Author) -match '^(Microsoft|Microsoft Corporation|\$\(@%)') { continue }
                $cmdLine = [string]$row.'Task To Run'
                $exe = $cmdLine; $argText = ''
                $qm = [regex]::Match($cmdLine, '^"([^"]+)"\s*(.*)$'); if ($qm.Success) { $exe = $qm.Groups[1].Value; $argText = $qm.Groups[2].Value } elseif ($cmdLine -match '^(\S+)\s+(.*)$') { $exe = $cmdLine -replace '^(\S+)\s+.*$', '$1'; $argText = $cmdLine -replace '^\S+\s+', '' }
                $exe = [System.Environment]::ExpandEnvironmentVariables($exe)
                $scriptsOf = @(& $scriptsIn $exe $argText ([string]$row.'Start In'))
                $flags = @(); $scriptCells = @()
                foreach ($sp in @($scriptsOf | Select-Object -Unique)) {
                    if (-not (Test-Path -LiteralPath $sp)) { $scriptCells += ($sp + ' (not found)'); $flags += 'script not found'; continue }
                    $key = $sp.ToLower(); if (-not $taskScriptMap.ContainsKey($key)) { $taskScriptMap[$key] = @() }; $taskScriptMap[$key] += ($tp + $nm); $scriptCells += $sp
                    if (-not $taskScripts.Contains($sp)) { $taskScripts.Add($sp) }
                }
                $taskRecs += @{ Path = $tp; Name = $nm; State = [string]$row.'Scheduled Task State'; Author = [string]$row.Author; RunAs = [string]$row.'Run As User'; Level = ''; Triggers = (([string]$row.'Schedule Type') + ' ' + ([string]$row.'Start Time') + ' ' + ([string]$row.Days)).Trim(); Action = $cmdLine; Scripts = ($scriptCells -join '; '); ScriptPaths = @($scriptsOf | Select-Object -Unique); Last = [string]$row.'Last Run Time'; Result = [string]$row.'Last Result'; Next = [string]$row.'Next Run Time'; Flags = @($flags) }
            }
        } catch { $errors += 'tasks (schtasks): ' + $_.Exception.Message }
    }

    # ---- 2. the walk: an explicit stack, each folder in its own try, junctions never followed, a budget ----
    $roots = @()
    $wanted = @(@($Folders) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if ($wanted.Count -eq 0) {
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) { try { if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $roots += $d.RootDirectory.FullName } } catch { } }
    } else {
        foreach ($w in $wanted) { $full = [System.Environment]::ExpandEnvironmentVariables($w); if (Test-Path -LiteralPath $full -PathType Container) { $roots += $full } else { $errors += ('folder not found: ' + $w) } }
    }
    $skipParts = @()
    foreach ($p in @($Skip)) { $tx = ([string]$p).Trim().Trim('\'); if (-not $tx) { continue }; $skipParts += ([regex]::Escape($tx) -replace '\\\*', '[^\\]*') }
    $skipRx = $null
    if ($skipParts.Count -gt 0) { $skipRx = New-Object System.Text.RegularExpressions.Regex -ArgumentList ('\\(' + ($skipParts -join '|') + ')(\\|$)'), ([System.Text.RegularExpressions.RegexOptions]::IgnoreCase) }
    $found = New-Object System.Collections.Generic.List[string]
    $foundSet = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([System.StringComparer]::OrdinalIgnoreCase)
    $skipped = New-Object System.Collections.Generic.List[string]
    $skippedTotal = 0; $excluded = 0; $foldersWalked = 0; $filesSeen = 0; $partial = ''
    $reparse = [System.IO.FileAttributes]::ReparsePoint; $dirAttr = [System.IO.FileAttributes]::Directory
    # ---- one script into the result, the moment the walk finds it: a spent budget leaves complete rows, not a list of
    #      scripts "not analysed" (the first scan of a developer's PC: 3,000 found, 2,500 unanalysed) ----
    $scriptLines = New-Object System.Collections.Generic.List[string]
    $stat = @{ Analysed = 0 }   # a hashtable, so the count survives the script block's own scope
    $scriptFlags = @{}          # path (lower case) -> the flags, for the task rows
    $emit = { param($file, $source)
        $folder = [System.IO.Path]::GetDirectoryName($file)
        # the signature is read for the first 500 scripts (Get-AuthenticodeSignature costs more than the parse) and always for a task's
        $a = & $analyse $file (($stat.Analysed -lt $maxSigned) -or $source -eq 'task')
        $stat.Analysed++
        $open = & $folderOpen $folder
        $flags = @($a.Flags)
        if ($open) { $flags += ('folder writable by ' + $open) }
        $flags = @($flags | Select-Object -Unique)
        $scriptFlags[$file.ToLower()] = ($flags -join '; ')
        $tasksOf = @(); $key = $file.ToLower(); if ($taskScriptMap.ContainsKey($key)) { $tasksOf = @($taskScriptMap[$key]) }
        $fns = @($a.Functions)
        if ($fns.Count -gt $maxFunctions) { $fnText = (($fns[0..($maxFunctions - 1)]) -join ', ') + (' ... (+{0} more)' -f ($fns.Count - $maxFunctions)) } else { $fnText = ($fns -join ', ') }
        $scriptLines.Add(((@($file, [System.IO.Path]::GetFileName($file), $folder, $a.SizeKB, $a.Modified, $a.Signed, $a.Purpose, $fnText, (@($a.Operations) -join ', '), (@($a.Calls | Select-Object -Unique) -join '; '), ($flags -join '; '), ($tasksOf -join '; '), $source, $a.Error) | ForEach-Object { & $cell $_ }) -join '|'))
    }
    # two stacks popped together: the folder and the root it descends from - the skip rules read the path BELOW the root,
    # so a root chosen under AppData or Program Files is still walked
    $stack = New-Object System.Collections.Generic.Stack[string]
    $rootStack = New-Object System.Collections.Generic.Stack[string]
    for ($i = $roots.Count - 1; $i -ge 0; $i--) { $stack.Push($roots[$i]); $rootStack.Push($roots[$i].TrimEnd('\')) }
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stack.Count -gt 0) {
        if ($watch.Elapsed.TotalSeconds -ge $BudgetSec) { $partial = ('the time budget of {0} s ran out with {1} folder(s) still to walk' -f $BudgetSec, $stack.Count); break }
        $dir = $stack.Pop(); $rootDir = $rootStack.Pop(); $foldersWalked++
        # one enumeration per folder; the attributes come with it, so the reparse check costs no second call
        $entries = @()
        try { $entries = @((New-Object System.IO.DirectoryInfo $dir).GetFileSystemInfos()) } catch { $skippedTotal++; if ($skipped.Count -lt $maxSkipped) { $skipped.Add($dir + '|' + (& $why $_)) }; continue }
        $subs = New-Object System.Collections.Generic.List[string]
        foreach ($e in $entries) {
            if (($e.Attributes -band $dirAttr) -ne 0) {
                if (($e.Attributes -band $reparse) -ne 0) { continue }   # a junction or symbolic link: never followed
                $subs.Add($e.FullName)
            } else {
                $filesSeen++
                if ($e.Extension -eq '.ps1' -or $e.Extension -eq '.psm1') { if ($foundSet.Add($e.FullName)) { $found.Add($e.FullName); & $emit $e.FullName 'search' } }
            }
        }
        for ($i = $subs.Count - 1; $i -ge 0; $i--) {   # pushed in reverse so they are walked in name order
            $s = $subs[$i]
            $below = $s; if ($s.Length -gt $rootDir.Length) { $below = '\' + $s.Substring($rootDir.Length).TrimStart('\') }
            if ($skipRx -and $skipRx.IsMatch($below)) { $excluded++; continue }
            $stack.Push($s); $rootStack.Push($rootDir)
        }
        if ($found.Count -ge $maxScripts) { $partial = ('stopped at {0} scripts (the cap) with {1} folder(s) still to walk' -f $maxScripts, $stack.Count); break }
    }

    # ---- 3. the scripts tasks run that the walk did not reach (outside the folders, or beyond the budget): the few a task runs are always analysed ----
    foreach ($file in @($taskScripts | Where-Object { -not $foundSet.Contains($_) } | Select-Object -Unique)) { & $emit $file 'task' }
    # the task rows, now that their scripts are known
    $taskLines = @()
    foreach ($rec in $taskRecs) {
        $flags = @($rec.Flags)
        foreach ($sp in @($rec.ScriptPaths)) {
            $sf = ''; if ($scriptFlags.ContainsKey($sp.ToLower())) { $sf = $scriptFlags[$sp.ToLower()] }
            if (-not $sf) { continue }
            if ($sf -match 'password in clear') { $flags += 'its script has a password in clear' }
            if ($sf -match 'downloads and runs|decoded code') { $flags += 'its script downloads or decodes and runs code' }
            if ($sf -match 'folder writable by') {
                $elevated = ($rec.Level -eq 'Highest' -or $rec.RunAs -match '(?i)SYSTEM|LocalService|NetworkService|Administrator')
                if ($elevated) { $flags += 'elevated run from a folder all users can write to' } else { $flags += 'its script sits in a folder all users can write to' }
            }
        }
        $taskLines += (@($rec.Path, $rec.Name, $rec.State, $rec.Author, $rec.RunAs, $rec.Level, $rec.Triggers, $rec.Action, $rec.Scripts, $rec.Last, $rec.Result, $rec.Next, ((@($flags) | Select-Object -Unique) -join '; ')) | ForEach-Object { & $cell $_ }) -join '|'
    }

    [pscustomobject]@{
        Computer = $env:COMPUTERNAME; Roots = @($roots); SkipRules = @($Skip); BudgetSec = $BudgetSec
        Tasks = @($taskLines); TasksTotal = $taskTotal; Scripts = @($scriptLines)
        Skipped = @($skipped); SkippedTotal = $skippedTotal; Excluded = $excluded
        FoldersWalked = $foldersWalked; FilesSeen = $filesSeen; ScriptsFound = $found.Count; ScriptsAnalysed = $stat.Analysed
        Seconds = [math]::Round($total.Elapsed.TotalSeconds, 1); Partial = $partial; Errors = @($errors)
    }
}

function Get-ServerScripts {
    # The Scripts collector on the servers named: the folders, the skip list and the budget from the Settings tab (Health)
    param([Parameter(Mandatory = $true)][string[]]$ComputerName)
    $budget = [int]$script:Config.ScriptSearchSeconds
    if ($budget -lt 1) { $budget = 60 }
    $summary = { param($r) ('{0} task(s) of {1} listed, {2} script(s) in {3} folder(s) walked ({4} not readable), {5} s{6}' -f @($r.Tasks).Count, $r.TasksTotal, $r.ScriptsFound, $r.FoldersWalked, $r.SkippedTotal, $r.Seconds, $(if ($r.Partial) { ' - PARTIAL: ' + $r.Partial } else { '' })) }
    $folders = [string[]]@(@($script:Config.ScriptSearchFolders) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $skip = [string[]]@(@($script:Config.ScriptSearchSkip) | ForEach-Object { [string]$_ } | Where-Object { $_ })
    return (Invoke-Collector -Name 'Scripts' -ScriptBlock $script:RemoteScriptsScript -ComputerName $ComputerName -ArgumentList @($folders, $skip, $budget, [string[]]$script:ScriptTaskSkipPaths) -Summary $summary -TimeoutSec ($budget + 240))
}

# ---------------------------------------------------------------------
#  The rows: the tables of the report and of a server's Health page
# ---------------------------------------------------------------------
$script:ScriptTaskColumns = @('Path', 'Task', 'State', 'Author', 'Run as', 'Run level', 'Triggers', 'Action', 'Scripts', 'Last run', 'Last result', 'Next run', 'Flags')
$script:ScriptFileColumns = @('Path', 'Name', 'Folder', 'Size KB', 'Modified', 'Signed', 'Purpose', 'Functions', 'Operations', 'Calls', 'Flags', 'Tasks', 'Found by', 'Note')
# The page shows fewer columns than the CSV, laid out in fixed widths (a 3,000-row table of long paths next to short
# dates must not squeeze the dates to one word a line): the task's folder and name as one, the account with its run
# level, a script's name and folder; the CSV keeps the full path and how the script was found.  A report adds Server.
$script:ScriptTaskPageColumns = @('Scheduled task', 'State', 'Author', 'Runs as', 'Triggers', 'Action', 'Scripts', 'Last run', 'Last result', 'Next run', 'Flags')
$script:ScriptFilePageColumns = @('Name', 'Folder', 'Size KB', 'Modified', 'Signed', 'Purpose', 'Functions', 'Operations', 'Calls', 'Flags', 'Tasks', 'Note')
$script:ScriptTaskNoWrap = @('State', 'Last run', 'Last result', 'Next run')
$script:ScriptFileNoWrap = @('Size KB', 'Modified')
$script:ScriptTaskSoftBreak = @('Server', 'Scheduled task', 'Author', 'Runs as', 'Action', 'Scripts')
$script:ScriptFileSoftBreak = @('Server', 'Name', 'Folder', 'Calls', 'Tasks')
$script:ScriptTaskWidths = @{ Server = '7%'; 'Scheduled task' = '14%'; State = '58px'; Author = '7%'; 'Runs as' = '8%'; Triggers = '10%'; Action = '16%'; Scripts = '11%'; 'Last run' = '112px'; 'Last result' = '80px'; 'Next run' = '112px'; Flags = '10%' }
$script:ScriptFileWidths = @{ Server = '6%'; Name = '10%'; Folder = '12%'; 'Size KB' = '50px'; Modified = '112px'; Signed = '84px'; Purpose = '12%'; Functions = '12%'; Operations = '9%'; Calls = '7%'; Flags = '8%'; Tasks = '6%'; Note = '6%' }

function Get-ScriptsFlagLight {
    # The row colour a flag earns: red = look at it now, amber = worth a look, nothing = plain.  A script's folder being
    # writable by every user is a note on its own (a data drive's default rights make it common - 431 of 491 scripts on
    # one PC); it colours a row only through the task that runs the script from there (the task's own flag).
    param([string]$Flags, [string]$Note = '')
    $rest = @(($Flags -split ';\s*') | Where-Object { $_ -and $_ -notmatch '^folder writable by' })
    if (($rest -join '; ') -match 'password in clear|downloads and runs|downloads or decodes|decoded code|elevated run from a folder') { return 'Red' }
    if ($rest.Count -gt 0) { return 'Amber' }
    if ($Note -match 'not analysed|not parsed|could not read') { return 'Grey' }
    return ''
}

function Get-ScriptTaskRows {
    # The scheduled tasks of one server (none when the scan has not run or failed)
    param([string]$Server)
    $r = Get-CollectorResult -Name 'Scripts' -Server $Server
    if (-not $r -or -not $r.Reachable) { return @() }
    return @(ConvertFrom-PipeLines -Lines @($r.Tasks) -Columns $script:ScriptTaskColumns | ForEach-Object {
        $runs = [string]$_.'Run as'; if ($_.'Run level') { $runs = ($runs + ' (' + ([string]$_.'Run level').ToLower() + ')').Trim() }
        $_ | Add-Member -NotePropertyName Server -NotePropertyValue $Server -PassThru |
            Add-Member -NotePropertyName 'Scheduled task' -NotePropertyValue ([string]$_.Path + [string]$_.Task) -PassThru |
            Add-Member -NotePropertyName 'Runs as' -NotePropertyValue $runs -PassThru |
            Add-Member -NotePropertyName Light -NotePropertyValue (Get-ScriptsFlagLight -Flags $_.Flags) -PassThru })
}

function Get-ScriptFileRows {
    # The PowerShell scripts of one server
    param([string]$Server)
    $r = Get-CollectorResult -Name 'Scripts' -Server $Server
    if (-not $r -or -not $r.Reachable) { return @() }
    return @(ConvertFrom-PipeLines -Lines @($r.Scripts) -Columns $script:ScriptFileColumns | ForEach-Object {
        if ($_.'Found by' -eq 'task' -and -not $_.Note) { $_.Note = 'outside the folders searched; found through its task' }
        $_ | Add-Member -NotePropertyName Server -NotePropertyValue $Server -PassThru | Add-Member -NotePropertyName Light -NotePropertyValue (Get-ScriptsFlagLight -Flags $_.Flags -Note $_.Note) -PassThru })
}

function Get-ScriptsSkippedRows {
    # The folders the walk could not read on one server
    param([string]$Server)
    $r = Get-CollectorResult -Name 'Scripts' -Server $Server
    if (-not $r -or -not $r.Reachable) { return @() }
    return @(ConvertFrom-PipeLines -Lines @($r.Skipped) -Columns @('Folder', 'Reason') | ForEach-Object { $_ | Add-Member -NotePropertyName Server -NotePropertyValue $Server -PassThru })
}

function Get-ScriptsScanText {
    # One phrase for the state of a server's scan (a kept scan whose latest attempt failed says so)
    param($Result)
    if (-not $Result) { return 'not scanned' }
    if (-not $Result.Reachable) { return 'failed: ' + $Result.Error }
    $text = 'complete'; if ($Result.Partial) { $text = 'PARTIAL: ' + $Result.Partial }
    $kept = Get-ResultFailure $Result
    if ($kept) { $text += ' (the latest attempt failed: ' + $kept + '; this is the earlier scan)' }
    return $text
}

function Get-ScriptsSummaryRows {
    # One row per server: what the scan covered and what it flagged
    param([string[]]$Servers)
    $rows = @()
    foreach ($name in @(Get-UniqueNames @($Servers))) {
        $r = Get-CollectorResult -Name 'Scripts' -Server $name
        $g = Get-ServerGroup -Name $name
        $row = [ordered]@{ Server = $name; Group = $(if ($g) { $g.Name } else { '' }); 'Last checked' = ''; Tasks = ''; Scripts = ''; Flagged = ''; 'Folders walked' = ''; 'No access' = ''; Scan = (Get-ScriptsScanText -Result $r); Seconds = ''; 'Folders searched' = ''; Light = 'Grey' }
        if ($r) { $row.'Last checked' = Format-LastChecked $r.Checked }
        if ($r -and $r.Reachable) {
            $tasks = @(Get-ScriptTaskRows -Server $name); $files = @(Get-ScriptFileRows -Server $name)
            $red = @(@($tasks) + @($files) | Where-Object { $_.Light -eq 'Red' }).Count
            $amber = @(@($tasks) + @($files) | Where-Object { $_.Light -eq 'Amber' }).Count
            $row.Tasks = [string]$tasks.Count; $row.Scripts = [string]$files.Count; $row.Flagged = [string]($red + $amber)
            $row.'Folders walked' = [string]$r.FoldersWalked; $row.'No access' = [string]$r.SkippedTotal; $row.Seconds = [string]$r.Seconds
            $row.'Folders searched' = (@($r.Roots) -join ', ')
            $row.Light = $(if ($red -gt 0) { 'Red' } elseif ($amber -gt 0 -or $r.Partial -or (Get-ResultFailure $r)) { 'Amber' } else { 'Green' })
        } elseif ($r) { $row.Light = 'Red' }
        $rows += [pscustomobject]$row
    }
    return $rows
}

function Get-ScriptsScanNote {
    # The scan's rules in one line, for the report and the page
    $where = 'every fixed drive'; if (@($script:Config.ScriptSearchFolders | Where-Object { $_ }).Count -gt 0) { $where = (@($script:Config.ScriptSearchFolders) -join ', ') }
    return ('Folders searched: {0}; skipped by rule: {1}; time budget {2} s per server (Settings tab, Health). Tasks under \Microsoft\ and the OS''s own are left out. Scripts are parsed, never run.' -f $where, (@($script:Config.ScriptSearchSkip) -join ', '), [int]$script:Config.ScriptSearchSeconds)
}

function Export-ScriptsReport {
    # reports\Scripts-<date>.html + CSV: the scan per server, every task, every script, the folders not read.  A script
    # file named in a task's Scripts cell or a script's Calls cell is a link that filters the page by that file name
    # (owner's ask 2026-11-09: no copying a name into the filter box); a server's Health page has no filter box, so none there.
    param([string[]]$Servers)
    $names = @(Get-UniqueNames @($Servers))
    $summary = @(Get-ScriptsSummaryRows -Servers $names)
    $tasks = @(); $files = @(); $skips = @()
    foreach ($s in $names) { $tasks += @(Get-ScriptTaskRows -Server $s); $files += @(Get-ScriptFileRows -Server $s); $skips += @(Get-ScriptsSkippedRows -Server $s) }
    return (Export-ConsoleReport -Console 'Health' -Prefix 'Scripts' -Title 'Scripts and scheduled tasks report' -Summary $summary -SummaryColumns @('Server', 'Group', 'Last checked', 'Tasks', 'Scripts', 'Flagged', 'Folders walked', 'No access', 'Scan', 'Seconds', 'Folders searched', 'Light') -Notes @((Get-ScriptsScanNote)) -Sections @(
        @{ Name = 'Scheduled tasks'; Rows = $tasks; Columns = (@('Server') + $script:ScriptTaskColumns + @('Light')); PageColumns = (@('Server') + $script:ScriptTaskPageColumns); NoWrap = $script:ScriptTaskNoWrap; Widths = $script:ScriptTaskWidths; SoftBreak = $script:ScriptTaskSoftBreak; FilterLinks = @('Scripts') },
        @{ Name = 'PowerShell scripts'; Rows = $files; Columns = (@('Server') + $script:ScriptFileColumns + @('Light')); PageColumns = (@('Server') + $script:ScriptFilePageColumns); NoWrap = $script:ScriptFileNoWrap; Widths = $script:ScriptFileWidths; SoftBreak = $script:ScriptFileSoftBreak; FilterLinks = @('Calls') },
        @{ Name = 'Folders not read (no access)'; Rows = $skips; Columns = @('Server', 'Folder', 'Reason') }))
}

function Get-ScriptsDetailSections {
    # The scan on a server's Health page (nothing when it has not run)
    param([string]$Server)
    $r = Get-CollectorResult -Name 'Scripts' -Server $Server
    if (-not $r) { return @() }
    if (-not $r.Reachable) { return @(@{ Heading = 'Scripts and scheduled tasks'; Lines = @('the last scan failed: ' + $r.Error) }) }
    $head = ('Scripts and scheduled tasks (scanned {0}: {1} folder(s) walked, {2} not readable, {3} s; {4})' -f $r.Checked.ToString('yyyy-MM-dd HH:mm:ss'), $r.FoldersWalked, $r.SkippedTotal, $r.Seconds, (Get-ScriptsScanText -Result $r))
    $sections = @(
        @{ Heading = $head; Rows = @(Get-ScriptTaskRows -Server $Server); Columns = $script:ScriptTaskPageColumns; NoWrap = $script:ScriptTaskNoWrap; Widths = $script:ScriptTaskWidths; SoftBreak = $script:ScriptTaskSoftBreak; Note = ('Folders searched: ' + (@($r.Roots) -join ', ') + '. Tasks under \Microsoft\ and the OS''s own are left out.') },
        @{ Heading = 'PowerShell scripts'; Rows = @(Get-ScriptFileRows -Server $Server); Columns = $script:ScriptFilePageColumns; NoWrap = $script:ScriptFileNoWrap; Widths = $script:ScriptFileWidths; SoftBreak = $script:ScriptFileSoftBreak })
    $skips = @(Get-ScriptsSkippedRows -Server $Server)
    if ($skips.Count -gt 0) { $sections += @{ Heading = 'Folders not read (no access)'; Rows = $skips; Columns = @('Folder', 'Reason') } }
    if (@($r.Errors).Count -gt 0) { $sections += @{ Heading = 'Scan errors'; Lines = @($r.Errors) } }
    return $sections
}
