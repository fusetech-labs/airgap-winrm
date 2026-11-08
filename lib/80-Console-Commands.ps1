# =====================================================================
#  80-Console-Commands.ps1  -  THE COMMANDS CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  One PowerShell command, typed or picked from the cheat sheet, run on
#  the ticked servers; every server's answer underneath, one after the
#  other.  Made for an investigation: one short command, read the answer,
#  take what it shows into the next command.
#  Before anything runs, Get-CommandRisk reads the command with the
#  PowerShell parser (it is never run here):
#    read-only    Get- and Test- commands, the ones that only sort, pick
#                 or format (Where-Object, Select-Object ...) and known
#                 read-only tools (ipconfig, sc.exe qc ...): runs at once
#    may change   anything else: a change record (Settings tab, "Command
#                 (may change)"), a confirmation naming the command and
#                 the servers, then recorded like every change (change
#                 log, event 930 and change-log.txt on the server)
#    refused      a restart (the Reboot button does that, with its checks)
#                 and commands that wait for someone at the server's screen
#  The cheat sheet is data\command-cheatsheet.psd1.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  80-Console-Commands.ps1
#  New 2026-10-22.  RemoteCommandScript runs ON the servers: the typed
#  command, as the operator's account, in a WinRM session (no profile).
#  Get-CommandRisk is a guard rail, not a sandbox: it lets through as
#  read-only only what it can show to be read-only, and everything else
#  waits for a change record and a confirmation.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _____cf_________________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [x] a read-only command   [x] a command that may change   [x] the cheat sheet
#  Comments   :
#    -
# =====================================================================

# ---------------------------------------------------------------------
#  What counts as read-only.  A list of what is known to only read - never a
#  list of what is dangerous: a command not named here MAY CHANGE a server.
# ---------------------------------------------------------------------
# every Get- and Test- command reads (exceptions below) ...
$script:CommandReadOnlyVerbs = @('Get', 'Test')
# ... and these sort, pick, measure, format or convert what they are given
$script:CommandReadOnlyNames = @('ForEach-Object', 'Where-Object', 'Select-Object', 'Select-String', 'Select-Xml', 'Sort-Object', 'Group-Object',
    'Measure-Object', 'Measure-Command', 'Compare-Object', 'Format-Table', 'Format-List', 'Format-Wide', 'Format-Custom', 'Format-Hex',
    'Out-String', 'Out-Null', 'Out-Default', 'Out-Host', 'Write-Output', 'Write-Host', 'Join-Path', 'Split-Path', 'Resolve-Path', 'Resolve-DnsName',
    'ConvertTo-Json', 'ConvertTo-Csv', 'ConvertTo-Html', 'ConvertTo-Xml', 'ConvertFrom-Json', 'ConvertFrom-Csv', 'ConvertFrom-StringData', 'New-TimeSpan')
# Get- and Test- commands that do more than read
$script:CommandNotReadOnly = @{ 'Get-WindowsUpdateLog' = 'Get-WindowsUpdateLog writes a log file'; 'Get-ClusterLog' = 'Get-ClusterLog writes log files'
    'Get-ClusterDiagnosticInfo' = 'Get-ClusterDiagnosticInfo writes a zip file'; 'Test-Cluster' = 'Test-Cluster runs the cluster validation (storage tests can take disks offline) and writes a report'
    'Test-ClusterResourceFailure' = 'Test-ClusterResourceFailure simulates a failure: the role fails over'
    'Get-Certificate' = 'Get-Certificate requests a certificate from a CA and installs it in the store'
    'Get-StorageDiagnosticInfo' = 'Get-StorageDiagnosticInfo writes diagnostic files (and can take a live dump)'
    'Get-SDDCDiagnosticInfo' = 'Get-SDDCDiagnosticInfo writes diagnostic files and a zip'
    'Get-NetView' = 'Get-NetView writes a folder of network diagnostics'
    'Get-GPResultantSetOfPolicy' = 'Get-GPResultantSetOfPolicy writes a report file'
    'Get-GPOReport' = 'Get-GPOReport writes a report file with -Path (the path can be given without the name)'
    'Test-SRTopology' = 'Test-SRTopology puts test load on the volumes and writes a report'
    # PSWindowsUpdate (a module often installed on servers) - its own aliases are not in the alias table
    'Get-WindowsUpdate' = 'Get-WindowsUpdate (PSWindowsUpdate) installs, downloads or hides updates (-Install, -Download, -Hide, -AutoReboot)'
    'Get-WUInstall' = 'Get-WUInstall (PSWindowsUpdate) installs updates'; 'Get-WUList' = 'Get-WUList (PSWindowsUpdate) installs updates with -Install'
    'Get-WUUninstall' = 'Get-WUUninstall (PSWindowsUpdate) removes an update'; 'Get-WURebootStatus' = 'Get-WURebootStatus (PSWindowsUpdate) restarts the server with -AutoReboot'
    'Get-WUOfflineMSU' = 'Get-WUOfflineMSU (PSWindowsUpdate) downloads update files'; 'Get-WUJob' = 'Get-WUJob (PSWindowsUpdate) deletes jobs with -ClearExpired'
    'Test-DbaLastBackup' = 'Test-DbaLastBackup (dbatools) restores the last backup of every database and drops it again' }
# refused outright, with what to do instead
$script:CommandRefused = @{
    'Restart-Computer' = 'a restart goes through "Reboot (ticked)" (O/S Patching or Software tab): it checks that no servicing is running and records the change'
    'Stop-Computer'    = 'a shutdown is not done from this tool'
    'shutdown'         = 'a restart goes through "Reboot (ticked)" (O/S Patching or Software tab): it checks that no servicing is running and records the change'
    'Read-Host'        = 'it waits for someone at the server''s screen - nobody is there, it would only time out'
    'Get-Credential'   = 'it waits for someone at the server''s screen - nobody is there, it would only time out'
    'Out-GridView'     = 'it opens a window on the server - nobody is there to see it'
    'Show-Command'     = 'it opens a window on the server - nobody is there to see it'
    'pause'            = 'it waits for someone at the server''s screen - nobody is there, it would only time out'
    'notepad'          = 'it opens a window on the server - nobody is there to see it, it would only time out'
    'regedit'          = 'it opens a window on the server - read the registry with Get-ItemProperty'
    'mmc'              = 'it opens a window on the server - nobody is there to see it'
}
# a parameter that turns a Get- or Test- command into a change.  PowerShell binds any unambiguous prefix (-R, -Re ...),
# so a typed parameter that is a prefix of one of these counts too - a false "may change" only costs a confirmation
$script:CommandChangingParameters = @('Repair', 'ForceBootstrap')
# methods that only read or compute (a call to any other method may change something: .Delete(), .Kill(), .StopService() ...).
# Format and Replace are not here: other objects have them too (Win32_Volume.Format() formats the volume, [IO.File]::Replace
# and FileInfo.Replace move files) - Get-CommandRisk lets them through only on a string ([string]::Format, 'a-b'.Replace(...))
$script:CommandSafeMethods = @('ToString', 'Split', 'Trim', 'TrimStart', 'TrimEnd', 'Substring', 'ToLower', 'ToUpper', 'Contains', 'StartsWith',
    'EndsWith', 'IndexOf', 'LastIndexOf', 'PadLeft', 'PadRight', 'GetType', 'Equals', 'CompareTo', 'Round', 'Floor', 'Ceiling', 'Abs', 'Max', 'Min',
    'Parse', 'TryParse', 'Join', 'IsNullOrEmpty', 'IsNullOrWhiteSpace', 'Exists', 'ReadAllText', 'ReadAllLines', 'GetHostName', 'GetHostEntry',
    'GetHostAddresses', 'Combine', 'GetFileName', 'GetDirectoryName', 'GetExtension', 'GetFileNameWithoutExtension', 'Match', 'Matches', 'IsMatch',
    'Escape', 'FromFileTime', 'FromFileTimeUtc', 'GetEnvironmentVariable', 'ToShortDateString', 'ToLongDateString', 'ToShortTimeString', 'ToLocalTime',
    'ToUniversalTime', 'AddDays', 'AddHours', 'AddMinutes', 'AddSeconds', 'AddMonths', 'AddYears', 'Subtract', 'GetValue', 'GetValueNames',
    'GetSubKeyNames', 'GetNameInfo', 'GetCertHashString', 'ContainsKey', 'ContainsValue', 'Where', 'ForEach')
# tools that are not PowerShell commands: read-only when the arguments match Allow ('' = any) and not Deny, or - Words - when
# Test-CommandToolWords passes them word by word (a tool that takes a switch or verb anywhere on the line, or abbreviated).
# Every argument must be a constant first (Get-CommandRisk): klist ('pur' + 'ge') is worked out only when it runs.
$script:CommandReadOnlyTools = [ordered]@{
    'hostname'   = @{ Allow = ''; Deny = '' }
    'whoami'     = @{ Allow = ''; Deny = '' }
    'quser'      = @{ Allow = ''; Deny = '' }
    'qwinsta'    = @{ Allow = ''; Deny = '' }
    'query'      = @{ Allow = '^(user|session|process)\b'; Deny = '' }
    'systeminfo' = @{ Allow = ''; Deny = '' }
    'tasklist'   = @{ Allow = ''; Deny = '' }
    'driverquery' = @{ Allow = ''; Deny = '' }
    'getmac'     = @{ Allow = ''; Deny = '' }
    'netstat'    = @{ Allow = ''; Deny = '' }
    'ipconfig'   = @{ Allow = '^((/all|/displaydns|/allcompartments)\s*)*$'; Deny = '' }
    'route'      = @{ Words = $true }                                         # -f or /f anywhere clears the gateway routes first
    'arp'        = @{ Words = $true }                                         # -s and -d anywhere change the cache
    'nslookup'   = @{ Allow = '\S'; Deny = '' }                              # with no argument it waits for typed input
    'ping'       = @{ Allow = '\S'; Deny = '(^|\s)[-/]t' }                    # -t pings until stopped (no other ping switch starts with t)
    'tracert'    = @{ Allow = '\S'; Deny = '' }
    'pathping'   = @{ Allow = '\S'; Deny = '' }
    'w32tm'      = @{ Allow = '^/(query|tz|stripchart|monitor)\b'; Deny = '(^|\s)/(config|resync|register|unregister|debug)\b' }
    'sc'         = @{ Allow = '^(\\\\\S+\s+)?(query|queryex|qc|qdescription|qfailure|qfailureflags|qsidtype|qprivs|qtriggerinfo|qpreferrednode|qmanagedaccount|qprotection|enumdepend|getdisplayname|getkeyname|showsid|sdshow)\b'; Deny = '' }
    'winrm'      = @{ Allow = '^(get|g|enumerate|enum|e|identify|id)\b'; Deny = '[&|<>^%!]' }   # winrm is winrm.cmd: cmd.exe acts on & | < > ^ % in its arguments
    'auditpol'   = @{ Allow = '^/(get|list)\b'; Deny = '(^|\s)/(set|remove|clear|backup|restore|resourcesacl)\b' }
    'gpresult'   = @{ Allow = '^((/r|/v|/z|/scope\s+(user|computer)|/user\s+\S+)\s*)+$'; Deny = '' }
    'wevtutil'   = @{ Allow = '^(qe|query-events|gl|get-log|el|enum-logs|gli|get-loginfo|ep|enum-publishers|gp|get-publisher)\b'; Deny = '' }
    'reg'        = @{ Allow = '^query\b'; Deny = '' }
    'dism'       = @{ Words = $true }                                         # /logpath: writes where it is told, and a path can hold /get-
    'klist'      = @{ Allow = '^(-l[ih]\s+(0x)?[0-9a-f]+(\s+|$))*((tickets|tgt|sessions|kcd_cache|query_bind)|get\s+\S+(\s+-kdcoptions\s+(0x)?[0-9a-f]+)?)?$'; Deny = '' }   # purge, purge_bind and add_bind change the ticket cache
    'schtasks'   = @{ Allow = '^/query\b'; Deny = '(^|\s)/(create|delete|run|end|change)\b' }
    'netsh'      = @{ Words = $true }                                         # takes abbreviations (a rule = add rule); wfp's show writes files
    'certutil'   = @{ Words = $true }                                         # -store's third argument is an output file; -f overwrites it
    'fsutil'     = @{ Allow = '^(fsinfo|volume\s+diskfree)\b'; Deny = '' }
    'bcdedit'    = @{ Allow = '^/enum\b'; Deny = '(^|\s)/(set|deletevalue|delete|create|createstore|copy|import|export|default|displayorder|bootsequence|toolsdisplayorder|timeout|bootems|ems|emssettings|bootdebug|debug|dbgsettings|hypervisorsettings|eventsettings|event|mirror|clean)\b' }
    'net'        = @{ Allow = '^(start|session|use|accounts|view|share(\s+[^=\s]+)?|config\s+(server|workstation)|statistics\s+(server|workstation)|localgroup(\s+("[^"]*"|\S+))?|user(\s+("[^"]*"|\S+))?(\s+/domain)?)\s*$'; Deny = '' }
}
# netsh is read-only only as "netsh <these words ...> show ...": every word before show a context.  wfp is not here (its show
# commands write XML files), nor ras diagnostics (show ... writes a report)
$script:CommandNetshContexts = @('advfirewall', 'firewall', 'consec', 'mainmode', 'monitor', 'interface', 'int', 'ipv4', 'ipv6', 'ip', 'tcp', 'udp',
    'portproxy', 'teredo', 'isatap', '6to4', 'httpstunnel', 'http', 'winhttp', 'winsock', 'wlan', 'lan', 'ras', 'trace', 'namespace', 'branchcache',
    'bridge', 'mbn', 'netio', 'rpc', 'ipsec', 'static', 'dynamic', 'dnsclient', 'routing')
# a cast, -as, a typed variable or parameter converts to the type - for most types that runs a constructor ([IO.StreamWriter]'C:\x'
# opens the file for writing and empties it).  These types only make a value.  Lower case, without System.
$script:CommandValueTypes = @('string', 'char', 'bool', 'boolean', 'switch', 'management.automation.switchparameter', 'byte', 'sbyte', 'int', 'int16',
    'int32', 'int64', 'long', 'short', 'uint16', 'uint32', 'uint64', 'ushort', 'uint', 'ulong', 'single', 'float', 'double', 'decimal', 'bigint',
    'numerics.biginteger', 'datetime', 'datetimeoffset', 'timespan', 'version', 'guid', 'ipaddress', 'net.ipaddress', 'uri', 'regex',
    'text.regularexpressions.regex', 'xml', 'xml.xmldocument', 'array', 'object', 'psobject', 'management.automation.psobject', 'pscustomobject',
    'management.automation.pscustomobject', 'hashtable', 'collections.hashtable', 'ordered', 'collections.specialized.ordereddictionary',
    'collections.arraylist', 'void', 'ref', 'management.automation.psreference', 'cultureinfo', 'globalization.cultureinfo')
# ... and generic collections of them ([System.Collections.Generic.List[string]])
$script:CommandValueGenerics = @('collections.generic.list', 'collections.generic.hashset', 'collections.generic.dictionary',
    'collections.generic.sorteddictionary', 'collections.generic.queue', 'collections.generic.stack')
# static properties of these types (and of the value types) are values: [Environment]::MachineName.  [IO.StreamWriter]::Null is a
# live writer, and comparing one with a path (-eq, -contains, Where-Object, Sort-Object ...) converts the path to a writer.
$script:CommandStaticTypes = @('environment', 'math', 'text.encoding', 'timezoneinfo', 'io.path', 'microsoft.win32.registry', 'bitconverter',
    'dbnull', 'intptr')
# PowerShell's own parameter and validation attributes (any other attribute is code that runs when a value is set)
$script:CommandSafeAttributes = @('parameter', 'cmdletbinding', 'alias', 'allownull', 'allowemptystring', 'allowemptycollection', 'validatenotnull',
    'validatenotnullorempty', 'validateset', 'validaterange', 'validatelength', 'validatepattern', 'validatecount', 'validatescript', 'outputtype',
    'supportswildcards', 'psdefaultvalue', 'argumentcompleter')
# variables that change what later commands do: $PSDefaultParameterValues = @{ 'Test-ComputerSecureChannel:Repair' = $true } makes a
# plain Test-ComputerSecureChannel repair; the preference variables, $OFS, the session and native-argument settings, Log*Event
$script:CommandBehaviourVariablePattern = '^(PSDefaultParameterValues|\w+Preference|OFS|PSSession\w+|PSEmailServer|PSNativeCommand\w+|Log\w+Event)$'
# reading Win32_Product (or a class that includes it) makes Windows Installer check every MSI product and repair the ones it finds
# damaged; Get-WmiObject, Get-CimInstance and Get-CimAssociatedInstance reaching one may change.  The values of these parameters
# never name the class.
$script:CommandWmiRepairPattern = '(?i)\b(Win32_Product\w*|CIM_Product\w*|Win32_Software\w*|CIM_Software\w*|Win32_\w*SoftwareElement\w*|Win32_\w*SoftwareFeature\w*)\b'
$script:CommandWmiValueParameters = @('Filter', 'Property', 'ComputerName', 'Namespace', 'CimSession', 'Credential', 'OperationTimeoutSec',
    'Impersonation', 'Authentication', 'Authority', 'Locale', 'ThrottleLimit')
# a cheat-sheet placeholder: <name>, <path>, <id> ...  Outside quotes it can only be a placeholder (it is not valid PowerShell);
# inside quotes '<html>' is real text, so there only these words count - the shipped cheat sheet's, plus any the sheet adds
# (Get-CommandCheatSheet)
$script:CommandPlaceholderPattern = '(?i)<[a-z][a-z0-9 _-]{0,30}>'
$script:CommandPlaceholderWords = @('name', 'path', 'id', 'folder', 'file', 'text', 'host', 'port')

function Get-CommandTypeKey {
    # A type name as the lists above hold it: lower case, without "System." ([System.String] and [string] are one type).
    param([string]$Name)
    return ($Name.Trim().ToLowerInvariant() -replace '^system\.', '')
}

function Test-CommandValueType {
    # True when converting to this type only makes a value (CommandValueTypes, and arrays and generic collections of them).
    # Takes the parser's type name, or the text of one ('x' -as 'int').
    param($TypeName)
    if ($TypeName -is [string]) {
        $n = $TypeName.Trim(); while ($n.EndsWith('[]')) { $n = $n.Substring(0, $n.Length - 2) }
        return ($script:CommandValueTypes -contains (Get-CommandTypeKey $n))
    }
    if ($TypeName -is [System.Management.Automation.Language.ArrayTypeName]) { return (Test-CommandValueType $TypeName.ElementType) }
    if ($TypeName -is [System.Management.Automation.Language.GenericTypeName]) {
        if ($script:CommandValueGenerics -notcontains (Get-CommandTypeKey $TypeName.TypeName.FullName)) { return $false }
        foreach ($g in @($TypeName.GenericArguments)) { if (-not (Test-CommandValueType $g)) { return $false } }
        return $true
    }
    return ($null -ne $TypeName -and $script:CommandValueTypes -contains (Get-CommandTypeKey ([string]$TypeName.FullName)))
}

function Test-CommandStringValue {
    # True when an expression can only give a string (or strings): a quoted string, -f, -join, -replace, a [string] cast,
    # .ToString(), [string]::Format/Join/Concat, [regex]::Replace, or a string method of one of these.  A variable or a property
    # could be any object - (Get-Item x).Replace(a, b) is FileInfo.Replace and moves files.
    param($Expression)
    $x = $Expression
    while ($x -is [System.Management.Automation.Language.ParenExpressionAst]) {
        $p = $x.Pipeline
        if (-not ($p -is [System.Management.Automation.Language.PipelineAst] -and $p.PipelineElements.Count -eq 1 -and $p.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst])) { return $false }
        $x = $p.PipelineElements[0].Expression
    }
    if ($x -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $x -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return $true }
    if ($x -is [System.Management.Automation.Language.BinaryExpressionAst]) { return ([string]$x.Operator -in 'Format', 'Join', 'Ireplace', 'Creplace') }
    if ($x -is [System.Management.Automation.Language.UnaryExpressionAst]) { return ([string]$x.TokenKind -eq 'Join') }
    if ($x -is [System.Management.Automation.Language.ConvertExpressionAst]) { return ((Get-CommandTypeKey $x.Type.TypeName.FullName) -in 'string', 'string[]') }
    if ($x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $x.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $mn = $x.Member.Value
        if ($x.Static) {
            if ($x.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst]) { return $false }
            $tk = Get-CommandTypeKey $x.Expression.TypeName.FullName
            return (($tk -eq 'string' -and $mn -in 'Format', 'Join', 'Concat') -or ($tk -in 'regex', 'text.regularexpressions.regex' -and $mn -eq 'Replace'))
        }
        if ($mn -eq 'ToString') { return $true }
        if ($mn -in 'Trim', 'TrimStart', 'TrimEnd', 'ToLower', 'ToUpper', 'ToLowerInvariant', 'ToUpperInvariant', 'Substring', 'PadLeft', 'PadRight', 'Replace') { return (Test-CommandStringValue $x.Expression) }
    }
    return $false
}

function Get-CommandVariableIssue {
    # Why setting the variable of this name (as written: $env:PATH, ${C:\file}, $global:x) may change something; '' when it only
    # sets a variable of the command's own.  env: changes what a later command runs (PATH picks the program, PSModulePath the
    # module), function: and alias: replace a command, any other drive is a provider path (a file, a registry value).
    param([string]$Name)
    $n = $Name -replace '^(global|script|local|private|using|workflow|variable):', ''
    if ($n.Contains(':')) {
        $drive = ($n -split ':', 2)[0]
        if ($drive -eq 'env') { return 'sets an environment variable (PATH picks the program a later command runs)' }
        if ($drive -in 'function', 'alias') { return ('replaces a command (the {0}: drive)' -f $drive.ToLowerInvariant()) }
        return ('writes to the {0}: drive' -f $drive)
    }
    if ($n -match $script:CommandBehaviourVariablePattern) { return 'changes what later commands do' }
    return ''
}

function Get-CommandSetIssue {
    # Why assigning to this target may change something; '' when it only sets a variable of the command's own.  A property or an
    # element is set on the real object ((Get-Item x).Attributes = ...); [T]$x and [ValidateX()]$x are the variable they wrap
    # (the type is checked with every cast); $a, $b = ... is each of its parts.
    param($Target)
    if ($Target -is [System.Management.Automation.Language.AttributedExpressionAst]) { return (Get-CommandSetIssue $Target.Child) }
    if ($Target -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        foreach ($part in @($Target.Elements)) { $r = Get-CommandSetIssue $part; if ($r) { return $r } }
        return ''
    }
    if ($Target -is [System.Management.Automation.Language.MemberExpressionAst] -or $Target -is [System.Management.Automation.Language.IndexExpressionAst]) { return ('{0} = ... sets a property' -f $Target.Extent.Text) }
    if ($Target -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $r = Get-CommandVariableIssue -Name $Target.VariablePath.UserPath
        if ($r) { return ('{0} = ... {1}' -f $Target.Extent.Text, $r) }
        return ''
    }
    return ('{0} = ... cannot be checked' -f $Target.Extent.Text)
}

function Test-CommandToolWords {
    # The tools that take a switch or a verb anywhere on the line, or abbreviated, read word by word: only the read-only shapes
    # pass.  route print /f flushes the gateway routes; arp -a -s adds an entry; netsh ... firewall a rule adds a rule (and a
    # quoted "x show" is not the verb); certutil -store's third argument is a file it writes; dism's /logpath: writes anywhere.
    param([string]$Tool, [string[]]$Words)
    $w = @($Words)
    if ($Tool -eq 'route') {
        # route [-4|-6|-p] print [filter]
        if (@($w | Where-Object { $_ -match '^[-/]' -and $_ -notmatch '^[-/][46p]$' }).Count -gt 0) { return $false }
        $plain = @($w | Where-Object { $_ -notmatch '^[-/]' })
        return ($plain.Count -ge 1 -and $plain.Count -le 2 -and $plain[0] -eq 'print' -and ($plain.Count -eq 1 -or $plain[1] -match '^(?=.*[0-9*])[0-9a-f.:*]+$'))
    }
    if ($Tool -eq 'arp') {
        # arp -a|-g [inet_addr] [-N if_addr] [-v]
        $shown = $false; $addresses = 0
        foreach ($x in $w) {
            if ($x -match '^[-/][ag]$') { $shown = $true }
            elseif ($x -match '^[-/][nv]$') { }
            elseif ($x -match '^\d{1,3}(\.\d{1,3}){3}$') { $addresses++ }
            else { return $false }
        }
        return ($shown -and $addresses -le 2)
    }
    if ($Tool -eq 'netsh') {
        # netsh <context ...> show|sho|sh ...: no global option (-f, -r, -c ...), no file= or report after it
        $i = 0
        while ($i -lt $w.Count -and $script:CommandNetshContexts -contains $w[$i]) { $i++ }
        if ($i -ge $w.Count -or $w[$i] -notin 'show', 'sho', 'sh') { return $false }
        foreach ($x in @($w | Select-Object -Skip ($i + 1))) { if ($x -match '^[-/]' -or $x -match '^(file|filename|tracefile|output|destination)=' -or $x -eq 'wlanreport') { return $false } }
        return $true
    }
    if ($Tool -eq 'certutil') {
        # certutil [-user|-enterprise|-v ...] -store [store [certId]] | -hashfile file [algorithm]
        $verbs = 0; $plain = 0
        foreach ($x in $w) {
            if ($x -match '^[-/](store|hashfile)$') { $verbs++ }
            elseif ($x -match '^[-/](user|enterprise|v|gmt|seconds)$') { }
            elseif ($x -match '^[-/]') { return $false }
            else { $plain++ }
        }
        return ($verbs -eq 1 -and $plain -le 2)
    }
    if ($Tool -eq 'dism') {
        # one /get-... with /online or /image:, and the options that name what to read
        $verbs = 0
        foreach ($x in $w) {
            if ($x -match '^/get-[a-z]+$') { $verbs++ }
            elseif ($x -match '^/(online|english)$' -or $x -match '^/(image|format|packagename|packagepath|featurename|capabilityname|driver|index|name|wimfile|imagefile):.') { }
            else { return $false }
        }
        return ($verbs -eq 1)
    }
    return $false
}

function Get-CommandAliasMap {
    # Alias -> command, read once - from a PowerShell with NO profile, because that is what the remote session has: an
    # alias the operator's own profile redefined (Set-Alias rm Get-Item) must not make "rm" look harmless.  When that
    # child process cannot run, this session's aliases are used, minus any whose target is not a Verb-Noun command.
    if (-not $script:CommandAliasMap) {
        $map = @{}
        try {
            $lines = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command 'Get-Alias | ForEach-Object { $_.Name + [char]9 + $_.Definition }' 2>$null)
            foreach ($l in $lines) { $f = [string]$l -split "`t", 2; if ($f.Count -eq 2 -and $f[0]) { $map[$f[0]] = $f[1] } }
        } catch { $map = @{} }
        if ($map.Count -lt 50) { $map = @{}; foreach ($a in @(Get-Alias)) { if ([string]$a.Definition -match '^[A-Za-z]+-[A-Za-z0-9]+$') { $map[$a.Name] = [string]$a.Definition } } }
        $script:CommandAliasMap = $map
    }
    return $script:CommandAliasMap
}

function Get-CommandRisk {
    # Reads a command WITHOUT running it and says whether it only reads.  Returns Verdict: 'Empty', 'Fill in' (a cheat-sheet
    # <placeholder> is still there), 'Not valid' (does not parse), 'Refused', 'Read-only' or 'May change'; ReadOnly (what
    # the command would be with the placeholders filled in - the cheat sheet colours its entries by it); CanRun; Reasons;
    # Placeholder; ParseError.
    param([string]$Text)
    $t = ([string]$Text).Trim()
    $out = [pscustomobject]@{ Verdict = 'Empty'; ReadOnly = $false; CanRun = $false; Reasons = @(); Placeholder = ''; ParseError = '' }
    if (-not $t) { $out.Reasons = @('nothing typed'); return $out }
    # a <placeholder> is read as x.  Inside quotes only the cheat sheet's own words count: Select-String -Pattern '<html>' is
    # a real command.  Which marks sit inside quotes is read from the tokens of the text with every mark blanked out
    $marks = @([regex]::Matches($t, $script:CommandPlaceholderPattern))
    if ($marks.Count -gt 0) {
        $chars = $t.ToCharArray()
        foreach ($m in $marks) { for ($i = $m.Index; $i -lt $m.Index + $m.Length; $i++) { $chars[$i] = 'x' } }
        $probeTokens = $null; $probeErrors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput((-join $chars), [ref]$probeTokens, [ref]$probeErrors)
        $quoted = @($probeTokens | Where-Object { [string]$_.Kind -in 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable' })
        $filled = ''; $from = 0
        foreach ($m in $marks) {
            $inQuotes = @($quoted | Where-Object { $_.Extent.StartOffset -lt $m.Index -and $_.Extent.EndOffset -gt $m.Index }).Count -gt 0
            if ($inQuotes -and $script:CommandPlaceholderWords -notcontains $m.Value.Substring(1, $m.Length - 2)) { continue }
            if (-not $out.Placeholder) { $out.Placeholder = $m.Value }
            $filled += $t.Substring($from, $m.Index - $from) + 'x'; $from = $m.Index + $m.Length
        }
        $t = $filled + $t.Substring($from)
    }
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($t, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) {
        $out.Verdict = 'Not valid'; $out.ParseError = ('{0} (at character {1})' -f $errors[0].Message, ($errors[0].Extent.StartOffset + 1))
        $out.Reasons = @('not valid PowerShell: ' + $out.ParseError); return $out
    }
    $why = New-Object System.Collections.Generic.List[string]
    $refused = New-Object System.Collections.Generic.List[string]
    $aliases = Get-CommandAliasMap
    foreach ($c in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $name = $c.GetCommandName()
        if (-not $name) {
            # & { ... } runs a block whose commands are checked one by one; & $x and & (...) run whatever they hold.
            # & "$env:windir\System32\shutdown.exe": the text still names a refused program
            $first = $c.CommandElements[0]
            if ($first -is [System.Management.Automation.Language.ExpandableStringExpressionAst] -or $first -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $b0 = [System.IO.Path]::GetFileName(([string]$first.Value).Trim()) -replace '(?i)\.(exe|com)$', ''
                if ($script:CommandRefused.ContainsKey($b0)) { $refused.Add(('{0}: {1}' -f $first.Value, $script:CommandRefused[$b0])); continue }
            }
            if ($first -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $why.Add('a command whose name is worked out only when it runs (& $x, & (...)) cannot be checked') }
            continue
        }
        if ($c.InvocationOperator -eq 'Dot' -and $name -match '[\\/.]') { $why.Add(('{0} runs a script' -f $name)); continue }
        $resolved = $name; if ($aliases.ContainsKey($name)) { $resolved = $aliases[$name] }
        $shown = $name; if ($resolved -ne $name) { $shown = '{0} ({1})' -f $name, $resolved }
        $base = [System.IO.Path]::GetFileName($resolved) -replace '(?i)\.(exe|com)$', ''
        if ($script:CommandRefused.ContainsKey($resolved)) { $refused.Add(('{0}: {1}' -f $shown, $script:CommandRefused[$resolved])); continue }
        if ($script:CommandRefused.ContainsKey($base)) { $refused.Add(('{0}: {1}' -f $shown, $script:CommandRefused[$base])); continue }   # by path too (C:\Windows\System32\shutdown.exe)
        if ($resolved -match '^[A-Za-z]+-[A-Za-z0-9]+$') {
            # a PowerShell command (Verb-Noun)
            if ($script:CommandNotReadOnly.ContainsKey($resolved)) { $why.Add($script:CommandNotReadOnly[$resolved]); continue }
            $verb = ($resolved -split '-')[0]
            if ($script:CommandReadOnlyVerbs -notcontains $verb -and $script:CommandReadOnlyNames -notcontains $resolved) { $why.Add(('{0} is not a command that only reads' -f $shown)); continue }
            foreach ($p in @($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })) {
                foreach ($bad in $script:CommandChangingParameters) { if ($p.ParameterName -and $bad.StartsWith($p.ParameterName, [System.StringComparison]::OrdinalIgnoreCase)) { $why.Add(('{0} -{1} changes something' -f $shown, $bad)) } }
            }
            # @p splats a hashtable that may hold -Repair: the parameters are known only when it runs
            foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                if ($e -is [System.Management.Automation.Language.VariableExpressionAst] -and $e.Splatted) { $why.Add(('{0} {1}: splatted parameters cannot be checked' -f $shown, $e.Extent.Text)) }
            }
            # -OutVariable, -PipelineVariable ... set a variable: $PSDefaultParameterValues or ${C:\file} is a change.  A prefix
            # counts once it can only mean that parameter (-OutV; -O is also -OutBuffer, so it does not run)
            $els = @($c.CommandElements)
            for ($i = 1; $i -lt $els.Count; $i++) {
                $p = $els[$i]
                if ($p -isnot [System.Management.Automation.Language.CommandParameterAst] -or -not $p.ParameterName) { continue }
                $pn = $p.ParameterName
                $setsVariable = ($pn -in 'ov', 'ev', 'wv', 'iv', 'pv') -or 'PipelineVariable'.StartsWith($pn, [System.StringComparison]::OrdinalIgnoreCase)
                foreach ($vp in 'OutVariable', 'ErrorVariable', 'WarningVariable', 'InformationVariable') { if ($pn.Length -gt $vp.IndexOf('Variable') -and $vp.StartsWith($pn, [System.StringComparison]::OrdinalIgnoreCase)) { $setsVariable = $true } }
                if (-not $setsVariable) { continue }
                $val = $p.Argument
                if (-not $val -and $i + 1 -lt $els.Count) { $val = $els[$i + 1] }
                $issue = 'the variable is named only when it runs'
                if ($val -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $issue = Get-CommandVariableIssue -Name $val.Value.TrimStart('+') }
                if ($issue) { $why.Add(('{0} -{1} {2}: {3}' -f $shown, $pn, $(if ($val) { $val.Extent.Text } else { '' }), $issue)) }
            }
            if ($resolved -eq 'ForEach-Object') {
                # ForEach-Object <name> calls a method of that name on every object (ForEach-Object Delete), and so does
                # -MemberName:Delete (the name in the parameter's own argument); a name that is worked out when it runs
                # (ForEach-Object $m) cannot be checked
                foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
                    $val = $e
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) { if (-not $e.Argument) { continue }; $val = $e.Argument }
                    if ($val -is [System.Management.Automation.Language.StringConstantExpressionAst]) { if ($script:CommandSafeMethods -notcontains $val.Value) { $why.Add(('{0} {1} may call a method - read a property with Select-Object -ExpandProperty {2}' -f $shown, $e.Extent.Text, $val.Value)) } }
                    elseif ($val -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $why.Add(('{0} {1} may call a method whose name is worked out only when it runs - it cannot be checked' -f $shown, $e.Extent.Text)) }
                }
            }
            if ($resolved -in 'Get-WmiObject', 'Get-CimInstance', 'Get-CimAssociatedInstance') {
                # Win32_Product: Windows Installer checks every MSI product and repairs the damaged ones.  Named anywhere in
                # the command (Get-CimClass Win32_Product | Get-CimInstance), piped in, or a class or query worked out when it
                # runs could be it - only a filter, a property list, a computer name ... may be worked out.  Associations
                # reach it too (Win32_ComputerSystem to Win32_SoftwareElement).
                if ($t -match $script:CommandWmiRepairPattern) { $why.Add(('{0} {1}: reading it makes Windows Installer check and repair every MSI product' -f $shown, $Matches[1])) }
                if ($c.Parent -is [System.Management.Automation.Language.PipelineAst] -and -not [object]::ReferenceEquals($c.Parent.PipelineElements[0], $c)) { $why.Add(('{0} reads the classes or instances piped to it - they cannot be checked' -f $shown)) }
                $isConstant = { param($x) $x -is [System.Management.Automation.Language.ConstantExpressionAst] -or ($x -is [System.Management.Automation.Language.ArrayLiteralAst] -and @($x.Elements | Where-Object { $_ -isnot [System.Management.Automation.Language.ConstantExpressionAst] }).Count -eq 0) }
                for ($i = 1; $i -lt $els.Count; $i++) {
                    $e = $els[$i]
                    if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                        $pn = [string]$e.ParameterName
                        $valueOnly = $pn.Length -ge 2 -and @($script:CommandWmiValueParameters | Where-Object { $_.StartsWith($pn, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
                        if ($e.Argument -and -not $valueOnly -and -not (& $isConstant $e.Argument)) { $why.Add(('{0} {1}: the class it reads is worked out only when it runs' -f $shown, $e.Extent.Text)) }
                        if (-not $e.Argument -and $valueOnly -and $i + 1 -lt $els.Count -and $els[$i + 1] -isnot [System.Management.Automation.Language.CommandParameterAst]) { $i++ }
                        continue
                    }
                    if (-not (& $isConstant $e)) { $why.Add(('{0} {1}: the class it reads is worked out only when it runs' -f $shown, $e.Extent.Text)) }
                }
            }
            continue
        }
        # a tool (ipconfig, sc.exe ...): only by its bare name - a path could be any program
        if ($resolved -match '[\\/]' -or -not $script:CommandReadOnlyTools.Contains($base)) { $why.Add(('{0} is not a tool known to only read' -f $shown)); continue }
        # every argument a constant - a bare word, a quoted string without $, a number, a switch: klist ('pur' + 'ge'), $x,
        # "$x" and --% %X% (cmd-style %variables% after the stop-parsing token) are worked out only when it runs.  And no
        # double quote, control character or "x y\" inside one: PowerShell 5.1 passes those as they are, so the tool may
        # read other words than the ones checked (route 'print" "/f' reaches route as print /f); nor a switch inside a
        # quoted argument ("x /add"), in case the tool splits its command line itself
        $words = New-Object System.Collections.Generic.List[string]
        $unsure = ''
        foreach ($e in @($c.CommandElements | Select-Object -Skip 1)) {
            $v = $null
            if ($e -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $v = $e.Value }
            elseif ($e -is [System.Management.Automation.Language.ConstantExpressionAst]) { $v = $e.Extent.Text }   # a number, passed as typed
            elseif ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                $v = '-' + $e.ParameterName
                if ($e.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $v += ':' + $e.Argument.Value }
                elseif ($e.Argument -is [System.Management.Automation.Language.ConstantExpressionAst]) { $v += ':' + $e.Argument.Extent.Text }
                elseif ($e.Argument) { $v = $null }
            }
            if ($null -eq $v -or $v -eq '--%') { $unsure = 'the arguments of {0} are worked out only when it runs - they cannot be checked'; break }
            if ($v -match '["\x00-\x1f]|\s[-/]' -or ($v -match '\s' -and $v.EndsWith('\'))) { $unsure = 'an argument of {0} holds a double quote, a control character, a switch after a space or a trailing \ - the tool may read other words than the ones checked'; break }
            $words.Add($v)
        }
        if ($unsure) { $why.Add(($unsure -f $shown)); continue }
        # the arguments as the tool gets them: one with a space in double quotes
        $argText = (@($words | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' ')
        $rule = $script:CommandReadOnlyTools[$base]
        $ok = $true
        if ($rule.Words) { $ok = Test-CommandToolWords -Tool $base -Words $words.ToArray() } else {
            if ($rule.Allow -and $argText -notmatch $rule.Allow) { $ok = $false }
            if ($rule.Deny -and $argText -match $rule.Deny) { $ok = $false }
        }
        if (-not $ok) { $why.Add(('{0} {1} is not a read-only use of {0}' -f $name, $argText).Trim()) }
    }
    # method calls: only the ones that read or compute
    foreach ($m in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
        if ($m.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { $why.Add('a method whose name is worked out only when it runs cannot be checked'); continue }
        $mn = $m.Member.Value
        if ($mn -in 'Format', 'Replace') {
            # on a string they compute; Win32_Volume.Format() formats the volume, [IO.File]::Replace and FileInfo.Replace move
            # files.  Only [string]::Format, [regex]::Replace and .Replace() on what can only be a string pass
            $tk = ''; if ($m.Static -and $m.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $tk = Get-CommandTypeKey $m.Expression.TypeName.FullName }
            $ok = ($mn -eq 'Format' -and $tk -eq 'string') -or ($mn -eq 'Replace' -and ($tk -in 'regex', 'text.regularexpressions.regex' -or (-not $m.Static -and (Test-CommandStringValue $m.Expression))))
            if (-not $ok) { $why.Add(('.{0}() may change something - it only computes when called on a string' -f $mn)) }
            continue
        }
        if ($script:CommandSafeMethods -notcontains $mn) { $why.Add(('.{0}() may change something' -f $mn)); continue }
        if ($mn -in 'ForEach', 'Where') {
            # .ForEach('Kill') calls that method on every item
            foreach ($a in @($m.Arguments)) {
                if ($a -is [System.Management.Automation.Language.StringConstantExpressionAst]) { if ($script:CommandSafeMethods -notcontains $a.Value) { $why.Add((".{0}('{1}') may call a method" -f $mn, $a.Value)) } }
                elseif ($a -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $why.Add((".{0}({1}) may call a method whose name is worked out only when it runs - it cannot be checked" -f $mn, $a.Extent.Text)) }
            }
        }
    }
    # > file writes a file (> $null and 2>&1 do not)
    foreach ($r in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FileRedirectionAst] }, $true))) {
        if (-not ($r.Location -is [System.Management.Automation.Language.VariableExpressionAst] -and $r.Location.VariablePath.UserPath -eq 'null')) { $why.Add(('{0} writes a file' -f $r.Extent.Text)) }
    }
    # what a command sets: a property of an object can change the real thing ((Get-Item x).Attributes = ...), and so can a
    # variable - ${C:\file} writes the file, ${function:Get-Service} = '...' and ${alias:x} replace a command, $env:PATH picks
    # the program a later command runs, $PSDefaultParameterValues adds parameters to later commands (Get-CommandSetIssue).
    # A variable is set by =, ++/--, foreach (...), a parameter of a block, data <name> { } and [ref]
    foreach ($s in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        $r = Get-CommandSetIssue $s.Left; if ($r) { $why.Add($r) }
    }
    foreach ($u in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.UnaryExpressionAst] -and [string]$n.TokenKind -in 'PlusPlus', 'MinusMinus', 'PostfixPlusPlus', 'PostfixMinusMinus' }, $true))) {
        $r = Get-CommandSetIssue $u.Child; if ($r) { $why.Add($r) }
    }
    foreach ($f in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true))) {
        $r = Get-CommandSetIssue $f.Variable; if ($r) { $why.Add($r) }
    }
    foreach ($pa in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true))) {
        $r = Get-CommandVariableIssue -Name $pa.Name.VariablePath.UserPath; if ($r) { $why.Add(('param({0}) {1}' -f $pa.Name.Extent.Text, $r)) }
    }
    foreach ($d in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.DataStatementAst] -and $n.Variable }, $true))) {
        $r = Get-CommandVariableIssue -Name $d.Variable; if ($r) { $why.Add(('data {0} {1}' -f $d.Variable, $r)) }
    }
    foreach ($rf in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ConvertExpressionAst] -and $n.Child -is [System.Management.Automation.Language.VariableExpressionAst] }, $true))) {
        if ((Get-CommandTypeKey $rf.Type.TypeName.FullName) -in 'ref', 'management.automation.psreference') { $r = Get-CommandSetIssue $rf.Child; if ($r) { $why.Add($r) } }
    }
    # a cast, a typed variable or parameter and -as convert to the type, which for most types runs a constructor:
    # [IO.StreamWriter]'C:\x' opens the file for writing and empties it.  Only types that make a value pass (a catch [type] converts nothing)
    foreach ($tc in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeConstraintAst] -and $n.Parent -isnot [System.Management.Automation.Language.CatchClauseAst] }, $true))) {
        if (-not (Test-CommandValueType $tc.TypeName)) { $why.Add(('{0} converts to a type whose constructor may change something (only value types such as [string], [int], [datetime] are known not to)' -f $tc.Extent.Text)) }
    }
    foreach ($b in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.BinaryExpressionAst] -and [string]$n.Operator -eq 'As' }, $true))) {
        $ok = $false
        if ($b.Right -is [System.Management.Automation.Language.TypeExpressionAst]) { $ok = Test-CommandValueType $b.Right.TypeName }
        elseif ($b.Right -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $ok = Test-CommandValueType $b.Right.Value }
        if (-not $ok) { $why.Add(('-as {0} converts to a type whose constructor may change something' -f $b.Right.Extent.Text)) }
    }
    # [Environment]::MachineName is a value; [IO.StreamWriter]::Null is a live writer, and comparing one with a path (-eq,
    # -contains, Where-Object, Sort-Object ...) converts the path to a writer - the file is emptied.  A static property of any
    # other type passes only on the right of a comparison, where the left side's type decides ($_.Status -eq [...]::Running)
    foreach ($sm in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Static }, $true))) {
        $tk = ''; if ($sm.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) { $tk = Get-CommandTypeKey $sm.Expression.TypeName.FullName }
        if ($tk -and ($script:CommandValueTypes -contains $tk -or $script:CommandStaticTypes -contains $tk)) { continue }
        $up = $sm.Parent
        if ($up -is [System.Management.Automation.Language.BinaryExpressionAst] -and [object]::ReferenceEquals($up.Right, $sm) -and [string]$up.Operator -match '^([ic](eq|ne|gt|ge|lt|le|like|notlike|match|notmatch|contains|notcontains)|band|bor|bxor)$') { continue }
        $why.Add(('{0} is an object whose type is not known to hold only values' -f $sm.Extent.Text))
    }
    # an attribute is code that runs when a value is set; PowerShell's own parameter and validation attributes are known
    foreach ($at in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AttributeAst] }, $true))) {
        if ($script:CommandSafeAttributes -notcontains (Get-CommandTypeKey $at.TypeName.FullName)) { $why.Add(('{0} is an attribute whose code may change something' -f $at.Extent.Text)) }
    }
    # using module / using assembly and #requires -Modules load code (using namespace changes what a type name means); a DSC
    # configuration writes MOF files when it is run
    if ($ast.UsingStatements -and @($ast.UsingStatements).Count -gt 0) { $why.Add('using loads a module or an assembly, or changes what a type name means') }
    $req = $ast.ScriptRequirements
    if ($req -and ($req.RequiredModules -or $req.RequiresPSSnapIns -or $req.RequiredAssemblies)) { $why.Add('#requires loads a module, a snap-in or an assembly') }
    if ($ast.Find({ param($n) $n -is [System.Management.Automation.Language.ConfigurationDefinitionAst] -or $n -is [System.Management.Automation.Language.DynamicKeywordStatementAst] }, $true)) { $why.Add('a DSC configuration writes MOF files when it is run') }

    $out.Reasons = @($why | Select-Object -Unique)
    if ($refused.Count -gt 0) { $out.Verdict = 'Refused'; $out.Reasons = @($refused | Select-Object -Unique); return $out }
    $out.ReadOnly = ($why.Count -eq 0)
    if ($out.Placeholder) { $out.Verdict = 'Fill in'; return $out }
    $out.CanRun = $true
    if ($out.ReadOnly) { $out.Verdict = 'Read-only' } else { $out.Verdict = 'May change' }
    return $out
}

# ---------------------------------------------------------------------
#  RUNS ON THE SERVER: the command, every output stream merged and turned
#  into text there (so it reads as it would on the server's own console),
#  cut at MaxKB.  -Record (a command that may change the server): a line in
#  C:\PatchStaging\change-log.txt and Application event 930, before and after.
# ---------------------------------------------------------------------
$script:RemoteCommandScript = {
    param([string]$Text, [bool]$Record, [string]$Operator, [string]$ChangeText, [string]$Staging, [int]$MaxKB, [int]$Width)
    $note = {
        param([string]$Step, [string]$Level)
        $line = '{0} | command | {1} | change {2} | by {3} | {4}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), ($Text -replace '[\r\n|]', ' '), $ChangeText, $Operator, $Step
        try {
            if (-not (Test-Path -LiteralPath $Staging)) { New-Item -ItemType Directory -Path $Staging -Force -ErrorAction Stop | Out-Null }
            Add-Content -LiteralPath ($Staging.TrimEnd('\') + '\change-log.txt') -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch { }
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('OfflinePatcher')) { New-EventLog -LogName Application -Source 'OfflinePatcher' -ErrorAction Stop }
            Write-EventLog -LogName Application -Source 'OfflinePatcher' -EventId 930 -EntryType $Level -Message ('WinRM Toolkit command on {0}: {1}' -f $env:COMPUTERNAME, $line) -ErrorAction Stop
        } catch { }
    }
    if ($Record) { & $note 'starting' 'Information' }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $items = New-Object System.Collections.Generic.List[object]
    $failed = ''; $errors = 0; $exit = $null
    $global:LASTEXITCODE = $null
    try {
        $block = [scriptblock]::Create($Text)
        # streamed into the list, so what came out before a terminating error is kept
        & $block *>&1 | ForEach-Object { $items.Add($_) }
        if ($null -ne $global:LASTEXITCODE) { $exit = [int]$global:LASTEXITCODE }
    } catch { $failed = $_.Exception.Message }
    $shown = foreach ($i in $items) {
        if ($i -is [System.Management.Automation.ErrorRecord]) {
            # a tool's own error text (stderr) is shown as it is; a PowerShell error with ERROR: in front
            if ($i.FullyQualifiedErrorId -like 'NativeCommandError*') { [string]$i.Exception.Message } else { $errors++; 'ERROR: ' + $i.Exception.Message }
        }
        elseif ($i -is [System.Management.Automation.WarningRecord]) { 'WARNING: ' + $i.Message }
        elseif ($i -is [System.Management.Automation.VerboseRecord]) { 'VERBOSE: ' + $i.Message }
        elseif ($i -is [System.Management.Automation.DebugRecord]) { 'DEBUG: ' + $i.Message }
        elseif ($i -is [System.Management.Automation.InformationRecord]) { [string]$i.MessageData }
        else { $i }
    }
    $body = ''
    if (@($shown).Count -gt 0) { $body = (@($shown) | Out-String -Width $Width).Trim([char[]]"`r`n").TrimEnd() }
    if ($failed) { $body = ($body + "`r`nFAILED: " + $failed).Trim() }
    $truncated = $false
    $max = [Math]::Max(1, $MaxKB) * 1024
    if ($body.Length -gt $max) { $body = $body.Substring(0, $max); $truncated = $true }
    $lines = 0; if ($body) { $lines = @($body -split "`n").Count }
    $result = 'ok'
    if ($failed) { $result = 'FAILED: ' + $failed } elseif ($errors -gt 0) { $result = '{0} error(s)' -f $errors }
    if (-not $failed -and $null -ne $exit -and $exit -ne 0) { $result += ', exit code ' + $exit }
    if ($Record) { $kind = 'Information'; if ($result -ne 'ok') { $kind = 'Warning' }; & $note ('finished: ' + $result) $kind }
    return [pscustomobject]@{ Computer = $env:COMPUTERNAME; Output = $body; Lines = $lines; Errors = $errors; ExitCode = $exit; Failed = $failed; Result = $result; Seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1); Truncated = $truncated; Recorded = $Record }
}

function Invoke-ServerCommand {
    # Runs one command on the servers (collector 'Command') and returns one row per server, in the order given:
    # @{ Server; Result } - Result $null = not run (an install is running there).  -Change: the change record of a command
    # that may change the servers; it is then recorded on each of them.
    param([string]$Text, [string[]]$Servers, $Change = $null)
    $record = ($null -ne $Change)
    $changeText = ''; if ($record) { $changeText = Format-ChangeText $Change }
    $what = 'read-only'; if ($record) { $what = 'MAY CHANGE - recorded on the servers' }
    # a server marked "winrm: no" gets no command (its row says "not run"); the last answer of the others goes, so a server
    # skipped this time shows no old answer
    $run = @(Remove-RemoteDisabledServers -Names @($Servers) -Action 'Command')
    Write-PatchLog ('Command on {0} server(s) ({1}): {2}' -f $run.Count, $what, $Text) 'CMD'
    if ($script:Results.ContainsKey('Command')) { foreach ($s in @($Servers)) { $script:Results['Command'].Remove($s) } }
    if ($run.Count -eq 0) { return @(foreach ($s in @($Servers)) { [pscustomobject]@{ Server = $s; Result = $null } }) }
    $summary = {
        param($r)
        $s = '{0} line(s) in {1} s' -f $r.Lines, $r.Seconds
        if ($r.Result -ne 'ok') { $s += ' - ' + $r.Result }
        if ($r.Truncated) { $s += (' (cut at {0} KB)' -f $script:Config.CommandMaxOutputKB) }
        return $s
    }
    $argList = @($Text, $record, (Get-OperatorIdentity), $changeText, $script:Config.RemoteStaging, [int]$script:Config.CommandMaxOutputKB, 250)
    # a command that may change a server is never cut short by "Stop waiting" or by being slower than the others (-NoStop): only
    # the time limit ends it - and a server it ended on is marked, because the command may have run there (partly or wholly)
    $null = Invoke-Collector -Name 'Command' -ScriptBlock $script:RemoteCommandScript -ComputerName $run -ArgumentList $argList -TimeoutSec ([int]$script:Config.CommandTimeoutSec) -Summary $summary -NoStop:([bool]$record)
    $rows = @(foreach ($s in @($Servers)) { [pscustomobject]@{ Server = $s; Result = (Get-CollectorResult -Name 'Command' -Server $s) } })
    if ($record) { foreach ($row in $rows) { $r = $row.Result; if ($r -and -not $r.Reachable -and $r.PSObject.Properties['TimedOut'] -and $r.TimedOut) { $r | Add-Member -NotePropertyName MayHaveRun -NotePropertyValue $true -Force } } }
    return $rows
}

function Get-CommandResultText {
    # One server's answer in a few words: the grid's "Last result" cell and the change-log row.
    param($Result)
    if (-not $Result) { return 'not run - an install is running there' }
    if ($Result.PSObject.Properties['MayHaveRun'] -and $Result.MayHaveRun) { return ('no answer in time - the command MAY HAVE RUN on this server (partly or wholly): check it before running it again (' + $Result.Error + ')') }
    if (-not $Result.Reachable) { return ('no answer: ' + $Result.Error) }
    $t = [string]$Result.Result
    if ($Result.Truncated) { $t += ' (output cut)' }
    return $t
}

function Start-CommandRun {
    # The Run button and Enter: check the command, then run it read-only at once, or - when it may change the servers -
    # after the change record, the confirmation and (Settings tab) the pre-action confirmations.
    $text = ([string]$script:Gui['CommandBox'].Text).Trim()
    $risk = Get-CommandRisk -Text $text
    switch ($risk.Verdict) {
        'Empty'     { Show-GuiNotice 'Type a command first, or pick one from the cheat sheet.'; return }
        'Fill in'   { Show-GuiNotice ("Replace {0} with a real value first." -f $risk.Placeholder); return }
        'Not valid' { Show-GuiNotice ("This is not valid PowerShell:`n`n{0}" -f $risk.ParseError); return }
        'Refused'   { Show-GuiNotice ("Not run from the Commands tab:`n`n{0}" -f ($risk.Reasons -join "`n")); return }
    }
    $servers = @(Get-GridChecked -Grid $script:Gui['CommandGrid'])
    if ($servers.Count -eq 0) { Show-GuiNotice 'Tick at least one server first.'; return }
    Add-CommandHistory -Text $text
    if ($risk.ReadOnly) {
        Invoke-GuiAction -Name 'Command (read-only)' -ReadOnly -Action { Show-CommandRun -Text $text -Rows (Invoke-ServerCommand -Text $text -Servers $servers) -Risk $risk }
        return
    }
    Invoke-GuiAction -Name 'Command (may change)' -Action {
        $action = 'Command (may change)'
        $rec = Request-ChangeRecord -Action $action -Servers $servers -Items $text
        if (-not $rec) { return }
        $q = "This command MAY CHANGE the {0} server(s) below:`n`n    {1}`n`nWhy: {2}`n`nServers:`n{3}`n`nRun it?" -f $servers.Count, $text, (@($risk.Reasons | Select-Object -First 3) -join '; '), ($servers -join "`n")
        $answer = Show-PatcherMessage -Title 'Run a command that may change the servers' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text $q
        if ($answer -ne 'Yes') { Write-PatchLog ('Command not run - {0} answered {1}: {2}' -f (Get-OperatorIdentity), $answer, $text) 'WARN'; Write-ChangeLog -Record $rec -Server $servers -Action $action -Item $text -Result 'cancelled at the confirmation'; return }
        if ($script:Config.CommandAskSafety -and -not (Confirm-SafetyChecks -Servers $servers -Activity 'The command')) { Write-ChangeLog -Record $rec -Server $servers -Action $action -Item $text -Result 'aborted at the safety checks'; return }
        Write-ChangeLog -Record $rec -Server $servers -Action $action -Item $text -Result 'approved - starting'
        $rows = @(Invoke-ServerCommand -Text $text -Servers $servers -Change $rec)
        foreach ($r in $rows) { Write-ChangeLog -Record $rec -Server $r.Server -Action $action -Item $text -Result (Get-CommandResultText -Result $r.Result) }
        Show-CommandRun -Text $text -Rows $rows -Risk $risk -Change $rec
    }
}

function Add-CommandHistory {
    # The command box remembers this session's commands, newest first (never saved: a command can hold a name or a path).
    param([string]$Text)
    $box = $script:Gui['CommandBox']; if (-not $box) { return }
    for ($i = $box.Items.Count - 1; $i -ge 0; $i--) { if ([string]$box.Items[$i] -ceq $Text) { $box.Items.RemoveAt($i) } }
    $box.Items.Insert(0, $Text)
    while ($box.Items.Count -gt 30) { $box.Items.RemoveAt($box.Items.Count - 1) }
    $box.Text = $Text
}

function Add-CommandOutputText {
    # Appends to the output pane in a colour.  Past 2 million characters the older half goes (Save output first to keep it).
    param([string]$Text, [string]$Colour = 'Gainsboro', [switch]$Bold)
    $box = $script:Gui['CommandOutput']; if (-not $box) { return }
    if ($box.TextLength -gt 2000000) { $box.Select(0, [int]($box.TextLength / 2)); $box.SelectedText = "... (older output dropped from the pane)`r`n" }
    $box.SelectionStart = $box.TextLength; $box.SelectionLength = 0
    $box.SelectionColor = [System.Drawing.Color]::FromName($Colour)
    if ($Bold) { $box.SelectionFont = $script:Gui['CommandBoldFont'] } else { $box.SelectionFont = $box.Font }
    $box.AppendText($Text)
}

function Show-CommandRun {
    # One run in the output pane: the command, then every server's answer under its own coloured heading.
    param([string]$Text, [object[]]$Rows, $Risk, $Change = $null)
    $box = $script:Gui['CommandOutput']; if (-not $box) { return }
    $start = $box.TextLength
    $how = 'read-only'
    if ($Change) { $how = 'MAY CHANGE - change ' + (Format-ChangeText $Change) }
    Add-CommandOutputText -Text ("PS> {0}`r`n" -f $Text) -Colour 'LimeGreen' -Bold
    Add-CommandOutputText -Text ("    {0}, {1} server(s), {2}, by {3}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), @($Rows).Count, $how, (Get-OperatorIdentity)) -Colour 'Gray'
    foreach ($row in @($Rows)) {
        $r = $row.Result
        $colour = 'LightSkyBlue'; $tail = ''
        if (-not $r -or -not $r.Reachable) { $colour = 'Silver' }
        elseif ($r.Result -ne 'ok') { $colour = 'Tomato' }
        if ($r -and $r.Reachable) { $tail = ('  ({0} line(s), {1} s{2})' -f $r.Lines, $r.Seconds, $(if ($r.Result -ne 'ok') { ', ' + $r.Result } else { '' })) }
        Add-CommandOutputText -Text ("`r`n==== {0}{1}`r`n" -f $row.Server, $tail) -Colour $colour -Bold
        if (-not $r -or -not $r.Reachable) { Add-CommandOutputText -Text ((Get-CommandResultText -Result $r) + "`r`n") -Colour 'Silver'; continue }
        if ($r.Output) { Add-CommandOutputText -Text ([string]$r.Output + "`r`n") } else { Add-CommandOutputText -Text "(no output)`r`n" -Colour 'Gray' }
        if ($r.Truncated) { Add-CommandOutputText -Text ("... cut at {0} KB (Settings tab, The Commands console) - narrow the command down: Select-Object -First 20, Where-Object ...`r`n" -f $script:Config.CommandMaxOutputKB) -Colour 'Gold' }
    }
    Add-CommandOutputText -Text ("`r`n" + ('-' * 100) + "`r`n`r`n") -Colour 'DimGray'
    # show the start of this run, not its end
    $box.SelectionStart = $start; $box.SelectionLength = 0; $box.ScrollToCaret()
    Update-CommandServerGrid
    $notice = Get-CommandSizeNotice -Rows $Rows
    if ($notice) { Show-GuiNotice $notice }
}

function Get-CommandSizeNotice {
    # An answer cut at CommandMaxOutputKB, or none within CommandTimeoutSec: this pane is for short answers, so the pop-up
    # says to run a command that big in its own PowerShell console on the server.  '' = every answer fitted.
    param([object[]]$Rows)
    $mayHaveRun = $false
    $hit = @(foreach ($row in @($Rows)) {
        $r = $row.Result
        if ($r -and $r.Reachable -and $r.Truncated) { '    {0} - cut at {1} KB' -f $row.Server, $script:Config.CommandMaxOutputKB }
        elseif ($r -and -not $r.Reachable -and $r.PSObject.Properties['TimedOut'] -and $r.TimedOut) {
            if ($r.PSObject.Properties['MayHaveRun'] -and $r.MayHaveRun) { $mayHaveRun = $true; '    {0} - no answer in time: the command may have run there' -f $row.Server }
            else { '    {0} - no answer within the time limit ({1} s, more with more servers than MaxParallel)' -f $row.Server, $script:Config.CommandTimeoutSec }
        }
    })
    if ($hit.Count -eq 0) { return '' }
    $first = ([string]$hit[0]).Trim() -replace ' - .*$', ''
    $list = @($hit | Select-Object -First 10)
    if ($hit.Count -gt 10) { $list += ('    and {0} more' -f ($hit.Count - 10)) }
    # a command that may change a server was stopped at the time limit while it ran: that is said first, before the advice
    $head = 'Too big for the Commands console:'
    if ($mayHaveRun) { $head = 'Not answered in time. A command that may change a server was stopped at the time limit while it ran - check those servers before running it again. For a command that long:' }
    return ("{0}`n`n{1}`n`nRun it in its own PowerShell console on the server:`n`n    Enter-PSSession -ComputerName {2}" -f $head, ($list -join "`n"), $first)
}

function Save-CommandOutput {
    # Save output...: the whole pane as a text file (any folder; the reports folder is offered).
    if (-not (Test-GuiDialogAllowed 'The save dialog')) { return }
    $text = [string]$script:Gui['CommandOutput'].Text
    if (-not $text.Trim()) { Show-GuiNotice 'Nothing to save yet - run a command first.'; return }
    if (-not (Test-Path -LiteralPath $script:Config.ReportFolder)) { New-Item -ItemType Directory -Path $script:Config.ReportFolder -Force | Out-Null }
    $save = New-Object System.Windows.Forms.SaveFileDialog
    try {
        $save.Title = 'Save the command output'; $save.Filter = 'Text file (*.txt)|*.txt|All files (*.*)|*.*'; $save.DefaultExt = 'txt'; $save.AddExtension = $true; $save.OverwritePrompt = $true
        $save.InitialDirectory = $script:Config.ReportFolder
        $save.FileName = 'Commands-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt'
        if ($save.ShowDialog($script:Gui['Form']) -ne 'OK') { return }
        [System.IO.File]::WriteAllText($save.FileName, ($text -replace "(?<!`r)`n", "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
        Write-PatchLog "Saved: $($save.FileName)" 'OK'
        Set-GuiStatus ('Saved: ' + $save.FileName)
    } finally { $save.Dispose() }
}

function Update-CommandRiskLabel {
    # The line under the command box says, as you type, what Run will do.
    $label = $script:Gui['CommandRiskLabel']; if (-not $label) { return }
    $risk = Get-CommandRisk -Text ([string]$script:Gui['CommandBox'].Text)
    $run = $script:Gui['CommandRunButton']
    switch ($risk.Verdict) {
        'Empty'      { $label.ForeColor = 'DimGray'; $label.Text = 'Type one command, or pick one from the cheat sheet on the right. Enter runs it on the ticked servers.' }
        'Fill in'    { $label.ForeColor = 'DarkOrange'; $label.Text = ('Replace {0} with a real value (it is selected - just type).  Then: {1}' -f $risk.Placeholder, $(if ($risk.ReadOnly) { 'read-only, runs at once.' } else { 'MAY CHANGE the servers - change record and confirmation first.' })) }
        'Not valid'  { $label.ForeColor = 'DarkRed'; $label.Text = 'Not valid PowerShell yet: ' + $risk.ParseError }
        'Refused'    { $label.ForeColor = 'DarkRed'; $label.Text = 'Not run from here: ' + ($risk.Reasons -join '; ') }
        'Read-only'  { $label.ForeColor = 'DarkGreen'; $label.Text = 'Read-only - runs at once on the ticked servers.' }
        'May change' { $label.ForeColor = 'DarkRed'; $label.Text = 'MAY CHANGE the servers - asks for a change record and a confirmation first: ' + (@($risk.Reasons | Select-Object -First 2) -join '; ') }
    }
    if ($run) {
        if ($risk.Verdict -eq 'May change') { $run.Text = 'Run - MAY CHANGE (ticked servers)'; $run.BackColor = 'Tomato' } else { $run.Text = 'Run (ticked servers)'; $run.BackColor = 'LightSkyBlue' }
    }
}

function Get-CommandCheatSheet {
    # data\command-cheatsheet.psd1 as sections of entries, each entry with what Get-CommandRisk makes of it.
    $d = Import-ToolData -Name 'command-cheatsheet.psd1'
    $out = @()
    # the sheet's own placeholder words count inside quotes too ('<path>'), wherever Get-CommandRisk meets them
    foreach ($sec in @($d.Sections)) {
        foreach ($e in @($sec.Commands)) {
            if (-not $e -or -not $e.Command) { continue }
            foreach ($m in @([regex]::Matches([string]$e.Command, $script:CommandPlaceholderPattern))) {
                $word = $m.Value.Substring(1, $m.Length - 2)
                if ($script:CommandPlaceholderWords -notcontains $word) { $script:CommandPlaceholderWords += $word }
            }
        }
    }
    foreach ($sec in @($d.Sections)) {
        if (-not $sec -or -not $sec.Name) { continue }
        $entries = @(foreach ($e in @($sec.Commands)) {
            if (-not $e -or -not $e.Command) { continue }
            $r = Get-CommandRisk -Text ([string]$e.Command)
            [pscustomobject]@{ Command = [string]$e.Command; What = [string]$e.What; ReadOnly = $r.ReadOnly; Refused = ($r.Verdict -eq 'Refused'); Section = [string]$sec.Name }
        })
        $out += [pscustomobject]@{ Name = [string]$sec.Name; Entries = $entries }
    }
    return $out
}

function Update-CommandCheatSheet {
    # Fills the tree: sections in bold, commands under them (dark red = may change); the filter keeps the commands whose
    # text or description holds what is typed.
    $tree = $script:Gui['CommandTree']; if (-not $tree) { return }
    # the sheet is rebuilt when data\command-cheatsheet.psd1 changes (Import-ToolData hands back the same object until it does)
    $sheetData = Import-ToolData -Name 'command-cheatsheet.psd1'
    if (-not $script:Gui['CommandSheet'] -or -not [object]::ReferenceEquals($script:Gui['CommandSheetSource'], $sheetData)) { $script:Gui['CommandSheet'] = @(Get-CommandCheatSheet); $script:Gui['CommandSheetSource'] = $sheetData }
    $q = ([string]$script:Gui['CommandFilter'].Text).Trim()
    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        foreach ($sec in @($script:Gui['CommandSheet'])) {
            $hits = @($sec.Entries | Where-Object { -not $q -or $_.Command.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $_.What.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or $sec.Name.IndexOf($q, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
            if ($hits.Count -eq 0) { continue }
            $sn = $tree.Nodes.Add($sec.Name)
            $sn.NodeFont = $script:Gui['CommandBoldTreeFont']; $sn.Text = $sec.Name   # the text again: a bold node keeps the width of its first text
            foreach ($e in $hits) {
                $n = $sn.Nodes.Add($e.Command)
                $n.Tag = $e; $n.ToolTipText = $e.What
                if (-not $e.ReadOnly) { $n.ForeColor = [System.Drawing.Color]::DarkRed }
            }
        }
        $tree.ExpandAll()
        if ($tree.Nodes.Count -gt 0) { $tree.Nodes[0].EnsureVisible() }
    } finally { $tree.EndUpdate() }
}

function Show-CheatSheetEntry {
    # The text under the tree: what the selected command does, and what Run would do with it.
    $node = $script:Gui['CommandTree'].SelectedNode
    $label = $script:Gui['CommandWhat']
    if (-not $node -or -not $node.Tag) { $label.Text = 'Pick a command: what it does shows here. Double-click it (or Use this command) to put it in the command box.'; return }
    $e = $node.Tag
    $how = 'Read-only: runs at once.'
    if (-not $e.ReadOnly) { $how = 'MAY CHANGE the servers: asks for a change record and a confirmation first.' }
    $fill = ''; if ($e.Command -match $script:CommandPlaceholderPattern) { $fill = '  Replace ' + $Matches[0] + ' with the real value.' }
    $label.Text = ('{0}{1}{2}{1}{3}{4}' -f $e.Command, [Environment]::NewLine, $e.What, $how, $fill)
}

function Use-CheatSheetEntry {
    # Use this command / double-click: into the command box, with the first <placeholder> selected so typing replaces it.
    # The box is focused a moment later: a double-click hands the focus back to the tree once it has finished.
    $node = $script:Gui['CommandTree'].SelectedNode
    if (-not $node -or -not $node.Tag) { return }
    $script:Gui['CommandBox'].Text = [string]$node.Tag.Command
    $script:Gui['CommandFocusTimer'].Stop(); $script:Gui['CommandFocusTimer'].Start()
}

function Select-CommandPlaceholder {
    # Focus the command box and select its first <placeholder> (or put the caret at the end).
    $box = $script:Gui['CommandBox']
    [void]$box.Focus()
    $m = [regex]::Match([string]$box.Text, $script:CommandPlaceholderPattern)
    if ($m.Success) { $box.Select($m.Index, $m.Length) } else { $box.Select(([string]$box.Text).Length, 0) }
}

function Update-CommandServerGrid {
    # The servers of the chosen group, with the answer each gave to the last command.
    $grid = $script:Gui['CommandGrid']; if (-not $grid) { return }
    $rows = @(foreach ($r in @(Get-GroupRows -Combo $script:Gui['CommandGroupCombo'])) {
        $res = Get-CollectorResult -Name 'Command' -Server $r.Server
        $text = ''; $colour = ''
        if ($res) {
            $text = '{0}  {1}' -f $res.Checked.ToString('HH:mm'), (Get-CommandResultText -Result $res)
            if (-not $res.Reachable) { $colour = 'Gainsboro' } elseif ($res.Result -ne 'ok') { $colour = 'MistyRose' } else { $colour = 'Honeydew' }
        }
        [pscustomobject]@{ Server = $r.Server; Group = $r.Group; 'Last result' = $text; Colour = $colour; Tip = $text }
    })
    Set-GridRows -Grid $grid -Rows $rows -RowColour { param($row) $row.Colour } -ToolTipProperty 'Tip'
    Update-CommandServerCount
}

function Update-CommandServerCount {
    $g = $script:Gui['CommandGrid']
    $script:Gui['CommandCount'].Text = ('{0} shown, {1} ticked' -f $g.Items.Count, $g.CheckedItems.Count)
}

function New-CommandsConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Commands' -Text 'Commands'
    $script:Gui['CommandBoldFont'] = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
    $script:Gui['CommandBoldTreeFont'] = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

    # Fill control first, then the docked edges (WinForms docks the last-added control first).
    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.FixedPanel = 'Panel1'
    $tab.Controls.Add($split)
    $script:Gui['CommandSplit'] = $split

    # ---- servers (left) ----
    $grid = New-ConsoleGrid -Columns @(@{ Name = 'Server'; Width = 150 }, @{ Name = 'Group'; Width = 90 }, @{ Name = 'Last result'; Width = 160; Fill = $true })
    $grid.Add_ItemChecked({ Update-CommandServerCount })
    $head = New-GridHeader -Heading 'SERVERS' -Detail '' -Tip 'The command runs on the ticked servers. Last result = the answer to the last command.'
    $split.Panel1.Controls.Add($grid); $split.Panel1.Controls.Add($head.Panel); $grid.BringToFront()
    $script:Gui['CommandGrid'] = $grid; $script:Gui['CommandCount'] = $head.Info

    # ---- command and output (centre) ----
    $outBox = New-Object System.Windows.Forms.RichTextBox
    $outBox.Dock = 'Fill'; $outBox.ReadOnly = $true; $outBox.WordWrap = $false; $outBox.DetectUrls = $false
    $outBox.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $outBox.ForeColor = 'Gainsboro'; $outBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:Gui['CommandOutput'] = $outBox
    $cmdBar = New-Object System.Windows.Forms.Panel; $cmdBar.Dock = 'Top'; $cmdBar.Height = 34; $cmdBar.Padding = New-Object System.Windows.Forms.Padding(6, 6, 6, 0)
    $cmdLabel = New-Object System.Windows.Forms.Label; $cmdLabel.Text = 'PS>'; $cmdLabel.Dock = 'Left'; $cmdLabel.Width = 36; $cmdLabel.TextAlign = 'MiddleLeft'; $cmdLabel.Font = New-Object System.Drawing.Font('Consolas', 10, [System.Drawing.FontStyle]::Bold)
    $box = New-Object System.Windows.Forms.ComboBox
    $box.Dock = 'Fill'; $box.DropDownStyle = 'DropDown'; $box.MaxLength = 4000; $box.Font = New-Object System.Drawing.Font('Consolas', 10)
    $script:Gui['Tips'].SetToolTip($box, 'One PowerShell command. Enter runs it on the ticked servers; the drop-down holds this session''s commands.')
    $box.Add_TextChanged({ Update-CommandRiskLabel })
    $box.Add_KeyDown({ if ($_.KeyCode -eq 'Enter' -and -not $this.DroppedDown) { $_.SuppressKeyPress = $true; Start-CommandRun } })
    $script:Gui['CommandBox'] = $box
    # -ReadOnly: a read-only command may run alongside an install (Invoke-GuiAction refuses one that may change)
    $run = New-GuiButton -Text 'Run (ticked servers)' -W 170 -H 28 -Colour 'LightSkyBlue' -ReadOnly -Tip 'Read-only commands run at once; one that may change the servers asks for a change record and a confirmation first' -OnClick { Start-CommandRun }
    $run.Dock = 'Right'
    $script:Gui['CommandRunButton'] = $run
    $cmdBar.Controls.AddRange(@($box, $cmdLabel, $run)); $box.BringToFront()
    $risk = New-Object System.Windows.Forms.Label; $risk.Dock = 'Top'; $risk.Height = 24; $risk.AutoEllipsis = $true; $risk.Padding = New-Object System.Windows.Forms.Padding(8, 4, 6, 0)
    $risk.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $script:Gui['CommandRiskLabel'] = $risk
    $outBar = New-Object System.Windows.Forms.Panel; $outBar.Dock = 'Bottom'; $outBar.Height = 38
    $outBar.Controls.Add((New-GuiButton -Text 'Clear output' -X 6 -Y 5 -W 110 -H 28 -ReadOnly -OnClick { $script:Gui['CommandOutput'].Clear() }))
    $outBar.Controls.Add((New-GuiButton -Text 'Save output...' -X 121 -Y 5 -W 110 -H 28 -ReadOnly -Tip 'The whole pane as a text file' -OnClick { Invoke-GuiAction -Name 'Save command output' -ReadOnly -Action { Save-CommandOutput } }))
    $outBar.Controls.Add((New-GuiButton -Text 'Change log' -X 236 -Y 5 -W 110 -H 28 -ReadOnly -Tip 'Every change with its change record (changes\change-log.csv) - commands that may change a server included' -OnClick { Invoke-GuiAction -Name 'Change log' -ReadOnly -Action { Show-ChangeLogWindow } }))
    $outHint = New-Object System.Windows.Forms.Label; $outHint.Text = 'Ctrl+A, Ctrl+C copies it. Each answer is formatted on its server.'
    $outHint.Location = New-Object System.Drawing.Point(356, 11); $outHint.AutoSize = $true; $outHint.ForeColor = 'DimGray'
    $outBar.Controls.Add($outHint)
    $split.Panel2.Controls.AddRange(@($outBox, $risk, $cmdBar, $outBar)); $outBox.BringToFront()

    # ---- the cheat sheet (right, behind a divider) ----
    $divider = New-Object System.Windows.Forms.Splitter
    $divider.Dock = 'Right'; $divider.Width = 6; $divider.BackColor = 'Gainsboro'; $divider.MinSize = 300; $divider.MinExtra = 500
    $tab.Controls.Add($divider)
    $right = New-Object System.Windows.Forms.Panel; $right.Dock = 'Right'; $right.Width = 440; $right.Padding = New-Object System.Windows.Forms.Padding(6, 0, 6, 6)
    $tab.Controls.Add($right)
    $sheetHead = New-GridHeader -Heading 'CHEAT SHEET' -Detail 'one command at a time - its answer feeds the next' -Tip 'data\command-cheatsheet.psd1 - add your own commands there'
    $findBar = New-Object System.Windows.Forms.Panel; $findBar.Dock = 'Top'; $findBar.Height = 30
    $findLabel = New-Object System.Windows.Forms.Label; $findLabel.Text = 'Find:'; $findLabel.Location = New-Object System.Drawing.Point(2, 8); $findLabel.AutoSize = $true
    $filter = New-Object System.Windows.Forms.TextBox; $filter.Location = New-Object System.Drawing.Point(42, 4); $filter.Width = 250
    $script:Gui['Tips'].SetToolTip($filter, 'Part of a command or of what it does (service, disk, reboot ...)')
    $filter.Add_TextChanged({ Update-CommandCheatSheet })
    $findBar.Controls.AddRange(@($findLabel, $filter))
    $script:Gui['CommandFilter'] = $filter
    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = 'Fill'; $tree.HideSelection = $false; $tree.ShowNodeToolTips = $true; $tree.Font = New-Object System.Drawing.Font('Consolas', 9)
    $tree.Add_AfterSelect({ Show-CheatSheetEntry })
    $tree.Add_NodeMouseDoubleClick({ if ($_.Node.Tag) { $this.SelectedNode = $_.Node; Use-CheatSheetEntry } })
    $script:Gui['CommandTree'] = $tree
    $whatPanel = New-Object System.Windows.Forms.Panel; $whatPanel.Dock = 'Bottom'; $whatPanel.Height = 150
    $what = New-Object System.Windows.Forms.Label; $what.Dock = 'Fill'; $what.Padding = New-Object System.Windows.Forms.Padding(2, 6, 2, 0); $what.ForeColor = 'Black'
    $script:Gui['CommandWhat'] = $what
    $use = New-GuiButton -Text 'Use this command' -W 200 -H 30 -ReadOnly -Tip 'Puts it in the command box with the first <placeholder> selected - type the real value' -OnClick { Use-CheatSheetEntry }
    $use.Dock = 'Bottom'
    $legend = New-Object System.Windows.Forms.Label; $legend.Dock = 'Bottom'; $legend.Height = 34; $legend.ForeColor = 'DimGray'
    $legend.Text = 'Black = read-only, runs at once. Dark red = may change a server: change record and confirmation first. <name> = type the real value.'
    $whatPanel.Controls.AddRange(@($what, $use, $legend)); $what.BringToFront()
    $right.Controls.AddRange(@($tree, $findBar, $sheetHead.Panel, $whatPanel)); $tree.BringToFront()
    # the box is focused after a double-click has finished (see Use-CheatSheetEntry)
    $focusTimer = New-Object System.Windows.Forms.Timer; $focusTimer.Interval = 60
    $focusTimer.Add_Tick({ $this.Stop(); Select-CommandPlaceholder })
    $script:Gui['CommandFocusTimer'] = $focusTimer

    # ---- toolbar ----
    $toolbar = New-ConsoleToolbar -Tab $tab
    $combo = New-GroupPicker -Toolbar $toolbar -OnChange { Update-CommandServerGrid }
    $script:Gui['CommandGroupCombo'] = $combo
    $toolbar.Controls.Add((New-GuiButton -Text 'Tick all' -X 235 -Y 8 -W 70 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['CommandGrid'] -Checked $true; Update-CommandServerCount }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Untick all' -X 310 -Y 8 -W 70 -ReadOnly -OnClick { Set-GridChecks -Grid $script:Gui['CommandGrid'] -Checked $false; Update-CommandServerCount }))
    $tbHint = New-Object System.Windows.Forms.Label; $tbHint.Location = New-Object System.Drawing.Point(395, 14); $tbHint.AutoSize = $true; $tbHint.ForeColor = 'DimGray'
    $tbHint.Text = 'Read-only commands run at once. Anything that may change a server asks for a change record and a confirmation, and is recorded.'
    $toolbar.Controls.Add($tbHint)

    $null = New-ConsoleBanner -Tab $tab -Console 'Commands' -Title 'COMMANDS' -Subtitle 'one command on the ticked servers - read the answer, use it in the next'
    $split.BringToFront()
    Update-CommandRiskLabel
    Show-CheatSheetEntry
    # the cheat sheet (each entry checked by Get-CommandRisk) and the divider's place when the tab is first opened
    $script:Gui['OnFirstShow']['Commands'] = {
        try { $script:Gui['CommandSplit'].SplitterDistance = 330 } catch { }
        Invoke-GuiAction -Name 'Cheat sheet' -ReadOnly -Action { Update-CommandCheatSheet }
    }
    Register-ConsoleRefresher -Console 'Commands' -Refresh { Update-CommandServerGrid }
}
