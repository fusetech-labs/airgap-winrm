# =====================================================================
#  03-Groups.ps1  -  READ THE SERVER LISTS (PatchGroup-A.txt etc.)
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Rules for a group file (any *.txt in the root folder):
#    * one server name per line (short name or FQDN)
#    * blank lines are ignored
#    * anything after a # is a comment:   SRV-APP01   # finance app
#    * the file name (without .txt) becomes the group name
#    * "; winrm: no" after a name (or "# winrm: no" for the whole file): the server is never called over WinRM -
#      its results come from its own self-check (14-State.ps1), imported on the O/S Patching tab
#  A .txt file that contains lines that do not look like host names is
#  ignored, so a README or other text file is never mistaken for a list.
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  03-Groups.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (see CODE-REVIEW.md).  Changed here:
#  R-06 Get-UniqueNames de-duplicates case-insensitively (Select-Object
#  -Unique is case-sensitive in 5.1) and warns when two entries look like
#  the same server (short name vs FQDN); R-26 IP addresses are warned
#  about because they force NTLM instead of Kerberos.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ____CF__________________________   Date : ___30-10-2026___________
#  Verdict    : [X] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

function Test-LooksLikeHostname {
    param([string]$Text)
    # RFC 1123: dot-separated labels of 1-63 letters, digits and inner dashes, 253 characters at most.  A looser
    # test let "srv01..corp.local" through, and Invoke-Command refuses the whole batch over one such name.
    if (-not $Text -or $Text.Length -gt 253) { return $false }
    foreach ($label in ($Text -split '\.')) { if ($label -notmatch '^[A-Za-z0-9]([A-Za-z0-9\-]{0,61}[A-Za-z0-9])?$') { return $false } }
    return $true
}

function Get-UniqueNames {
    # Case-INsensitive de-duplication that keeps the original order.  (Select-Object -Unique
    # treats SRV01 and srv01 as two different servers in PowerShell 5.1 - that would mean two
    # concurrent installs on one box.)
    param([string[]]$Names)
    $seen = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    $out = @()
    foreach ($n in @($Names)) {
        if (-not $n) { continue }
        $t = $n.Trim()
        if ($t -and $seen.Add($t)) { $out += $t }
    }
    return $out
}

function Test-ThisComputer {
    # Is this name the toolkit PC itself?  localhost, 127.0.0.1, ::1, the computer name or its FQDN - compared as text,
    # so a box that shares the short name in another domain stays another box.  The toolkit PC can be a managed server
    # like any other (its own WinRM listener, the account an administrator on it): the status check says so in the log,
    # and the reboot takes it last, after its own Yes, with a longer countdown - the toolkit closes with the restart
    # (field test 2026-11: the server running the toolkit has to be patched too).
    param([string]$Name)
    $t = ([string]$Name).Trim().TrimEnd('.')
    if (-not $t) { return $false }
    if (-not $script:ThisComputerNames) {
        $names = @('localhost', '127.0.0.1', '::1', $env:COMPUTERNAME)
        try { $ip = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties(); if ($ip.DomainName) { $names += ($ip.HostName + '.' + $ip.DomainName) } } catch { }
        $script:ThisComputerNames = @($names | Where-Object { $_ })
    }
    foreach ($n in $script:ThisComputerNames) { if ($t -ieq $n) { return $true } }
    return $false
}

function Get-ThisComputerFqdn {
    # This computer's name as a self-check or a spoke writes it: the FQDN when it has a DNS domain, else the computer name.
    try { $ip = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties(); if ($ip.DomainName) { return ($ip.HostName + '.' + $ip.DomainName).ToLower() } } catch { }
    return $env:COMPUTERNAME.ToLower()
}

function Get-ThisComputerDomain {
    # The DNS domain of this computer ('' in a workgroup): a results file names it so two SRV01s in two domains stay two boxes.
    try { $ip = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties(); return ([string]$ip.DomainName).ToLower() } catch { return '' }
}

function Read-GroupFile {
    # One group file -> a group object, or $null when the file is not a server list.
    #   server lines:   name[; key: value[; key: value ...]][  # comment]      e.g.  srv-web01.corp.local; soe: Web tier
    #   directives:     # class: <name>   # soe: <name>   # winrm: no      (group-wide fallbacks for lines without their own)
    # Per-line keys live in Attributes[<name, lower case>] = @{ key = value }; 'soe', 'class' and 'winrm' are the ones the
    # consoles read today (Get-ServerAttribute); any other key is kept for later use.
    param([string]$Path)
    $file = Get-Item -LiteralPath $Path
    $servers = @(); $attributes = @{}; $withOwn = 0
    $odd = New-Object System.Collections.Generic.List[string]; $lineNo = 0
    $class = ''      # "# class: internet-facing"  -> patch timeframes and application control expectations
    $soe = ''        # "# soe: Web tier"           -> the SOE standard this group is compared against
    $winrm = ''      # "# winrm: no"               -> no server of this file is called over WinRM (self-check results)
    foreach ($raw in @(Get-Content -LiteralPath $file.FullName)) {
        $lineNo++
        if ($raw -match '^\s*#\s*(class|soe|winrm)\s*:\s*(.+?)\s*$') {      # directives live in comment lines
            $val = ($Matches[2] -replace '\s+#.*$', '').Trim()
            if ($Matches[1] -eq 'class') { $class = $val } elseif ($Matches[1] -eq 'winrm') { $winrm = $val } else { $soe = $val }
            continue
        }
        $line = ($raw -split '#')[0].Trim()          # drop comments and whitespace
        if (-not $line) { continue }                  # skip blank lines
        $parts = @($line -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -eq 0) { continue }          # a line of semicolons only
        $name = $parts[0]
        if (-not (Test-LooksLikeHostname $name)) { $odd.Add(('line {0}: ''{1}''' -f $lineNo, $line)); continue }
        $own = @{}; $badPart = $false
        for ($i = 1; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -match '^([A-Za-z][A-Za-z0-9_\-]*)\s*:\s*(.*)$') {
                $v = $Matches[2].Trim()
                if ($v) { $own[$Matches[1].ToLower()] = $v }
            } else { $badPart = $true; break }
        }
        if ($badPart) { $odd.Add(('line {0}: ''{1}''' -f $lineNo, $line)); continue }
        $servers += $name
        if ($own.Count -gt 0) {
            $key = $name.ToLower()
            if (-not $attributes.ContainsKey($key)) { $attributes[$key] = @{} }
            foreach ($k in $own.Keys) { $attributes[$key][$k] = $own[$k] }
            $withOwn++
        }
    }
    if ($odd.Count -gt 0) {
        # a file that is mostly not host names (a note left in the root folder) is not a server list; a list with a few odd
        # lines is a list - those lines are skipped and named, the servers stay in the window
        if ($servers.Count -eq 0 -or $odd.Count -gt $servers.Count) {
            Write-PatchLog "Ignoring $($file.Name) - not a server list ($($odd.Count) line(s) are not host names, $($servers.Count) are; first odd line: $($odd[0]))" 'WARN'
            return $null
        }
        Write-PatchLog (("$($file.Name): {0} line(s) skipped, not a host name (letters, digits, dots, dashes): " -f $odd.Count) + ((@($odd) | Select-Object -First 5) -join '; ')) 'WARN'
    }
    $servers = @(Get-UniqueNames $servers)
    $group = [pscustomobject]@{
        Name       = $file.BaseName
        File       = $file.FullName
        Servers    = $servers
        Class      = $class
        Soe        = $soe
        Winrm      = $winrm
        Attributes = $attributes
    }
    $extra = ''
    if ($class) { $extra += ", class: $class" }
    if ($soe) { $extra += ", SOE standard: $soe" }
    if ($winrm) { $extra += ", winrm: $winrm" }
    if ($withOwn -gt 0) { $extra += (", {0} line(s) with their own settings" -f $withOwn) }
    Write-PatchLog ("Group '{0}' loaded with {1} server(s) from {2}{3}" -f $file.BaseName, $servers.Count, $file.Name, $extra) 'INFO'
    $noWinrm = @($servers | Where-Object { $own = $attributes[$_.ToLower()]; (Test-WinrmOffValue $(if ($own -and $own['winrm']) { $own['winrm'] } else { $winrm })) })
    if ($noWinrm.Count -gt 0) { Write-PatchLog ("  -> {0} server(s) marked 'winrm: no' - never called over WinRM; their results come from their own self-check (Import results on the O/S Patching tab): {1}" -f $noWinrm.Count, ($noWinrm -join ', ')) 'INFO' }
    foreach ($s in $servers) {
        if ($s -match '^\d{1,3}(\.\d{1,3}){3}$') {
            Write-PatchLog "  -> '$s' is an IP address: WinRM cannot use Kerberos for it and will fall back to NTLM, which needs TrustedHosts on this PC. Use the server's FQDN instead." 'WARN'
        }
    }
    if ($servers.Count -eq 0) {
        Write-PatchLog "  -> $($file.Name) has no servers yet. Open it in Notepad and add one name per line." 'WARN'
    }
    return $group
}

function Test-GroupFileName {
    # A *.txt in the root folder is a server list unless it is a manual: README.txt, the INSTRUCTIONS.txt a copy for a
    # server carries (read as a list, its 28 lines were "not host names" in the log - field finding 2026-11-06), or a
    # CHECKSUMS.txt written beside patches\ and software\ (a group of 0 servers otherwise)
    param([string]$Name)
    return ([string]$Name -notin 'README.txt', 'INSTRUCTIONS.txt', 'CHECKSUMS.txt')
}

function Get-PatchGroups {
    # Returns one object per group:  Name, File, Servers (array of strings), Class, Soe, Winrm, Attributes (Read-GroupFile).
    # A spoke (Start-WinRMToolkit.ps1 -Spoke, 14-State.ps1) has one group, "This computer", with its own name: it checks and
    # patches the computer it runs on, from the hub's patches and software, and never calls another server.
    $groups = @()
    if ($script:SpokeMode) {
        $groups += [pscustomobject]@{ Name = 'This computer'; File = ''; Servers = @((Get-ThisComputerFqdn)); Class = ''; Soe = ''; Winrm = ''; Attributes = @{} }
        Write-PatchLog ("Spoke: the server list is this computer, {0} - the group files of the hub are not read here" -f (Get-ThisComputerFqdn)) 'INFO'
        $script:Groups = $groups
        return $groups
    }
    $files  = @(Get-ChildItem -LiteralPath $script:RootFolder -Filter '*.txt' -File | Where-Object { Test-GroupFileName -Name $_.Name } | Sort-Object Name)   # -LiteralPath: a folder name may hold [ ]; README.txt is the manual, never a list
    foreach ($file in $files) {
        $g = Read-GroupFile -Path $file.FullName
        if ($g) { $groups += $g }
    }
    if ($groups.Count -eq 0) {
        Write-PatchLog "No group files found in $script:RootFolder - create e.g. PatchGroup-A.txt with one server per line" 'WARN'
    }
    # Same server written two ways (SRV01 and srv01.corp.local) across the groups?  Say so - the
    # install itself also de-duplicates by the server's real name after the status check.
    $byLabel = @{}
    foreach ($g in $groups) {
        foreach ($s in $g.Servers) {
            $label = ($s -split '\.')[0].ToLower()
            if (-not $byLabel.ContainsKey($label)) { $byLabel[$label] = @() }
            if ($byLabel[$label] -notcontains $s) { $byLabel[$label] += $s }
        }
    }
    foreach ($label in $byLabel.Keys) {
        if ($byLabel[$label].Count -gt 1) { Write-PatchLog ("  -> '{0}' is listed as {1} - probably the same server; it will be patched once" -f $label, ($byLabel[$label] -join ' and ')) 'WARN' }
    }
    $script:Groups = $groups
    return $groups
}

function Test-WinrmOffValue {
    # The values of "winrm:" that mean "never over WinRM": no, off, none, false, 0, disabled, self-check
    param([string]$Value)
    return (([string]$Value).Trim().ToLower() -in 'no', 'off', 'none', 'false', '0', 'disabled', 'self-check', 'selfcheck')
}

function Test-RemoteDisabled {
    # Is this server marked "winrm: no" (its own line, or its group file's directive)?  Such a server is never called
    # over WinRM by any console or action: its results come from its own self-check (14-State.ps1).  The toolkit PC
    # itself is never remote-disabled: its checks run here without WinRM anyway.
    param([string]$Name)
    if (Test-ThisComputer -Name $Name) { return $false }
    return (Test-WinrmOffValue (Get-ServerAttribute -Name $Name -Key 'winrm'))
}

function Get-RemoteDisabledServers {
    # The names among -Names that are marked "winrm: no"; with no -Names, every such server of every loaded group.
    param([string[]]$Names)
    if ($null -eq $Names) { $Names = @(Get-UniqueNames @(foreach ($g in @($script:Groups)) { @($g.Servers) })) }
    return @($Names | Where-Object { Test-RemoteDisabled -Name $_ })
}

function Remove-RemoteDisabledServers {
    # The names an action may work on: a server marked "winrm: no" is taken out with one log line naming the action -
    # nothing is ever sent to it, whatever its imported results say.
    param([string[]]$Names, [string]$Action = 'this action')
    $off = @(Get-RemoteDisabledServers -Names $Names)
    if ($off.Count -gt 0) { Write-PatchLog ("{0}: {1} skipped - marked 'winrm: no' in the group file (never called over WinRM; the results shown are from its own self-check)" -f $Action, ($off -join ', ')) 'WARN' }
    return @($Names | Where-Object { $off -notcontains $_ })
}

function Set-RemoteDisabledMark {
    # The "Mark winrm: no (ticked)" button's work, and its reverse: writes "; winrm: no" on each server's line in its
    # group file (Set-ServerAttribute, the way the SOE and class entries are written), or with -Clear takes the mark off -
    # the pair goes, or "; winrm: yes" is written where the file's own "# winrm: no" directive would keep the server
    # marked.  The group files are read again afterwards, so every console and action answers from the files from the
    # next press on.  A server already as asked is skipped; so is the toolkit PC (it checks itself without WinRM).
    # Returns @{ Changed; Skipped; Errors } - names, names, messages.
    param([string[]]$Servers, [switch]$Clear)
    $changed = @(); $skipped = @(); $errors = @()
    $want = -not $Clear
    foreach ($s in @(Get-UniqueNames @($Servers))) {
        if (Test-ThisComputer -Name $s) { $skipped += $s; Write-PatchLog ("{0}: no winrm mark - the toolkit PC checks itself without WinRM" -f $s) 'INFO'; continue }
        if ((Test-RemoteDisabled -Name $s) -eq $want) { $skipped += $s; continue }
        try {
            if ($want) {
                Set-ServerAttribute -Server $s -Key 'winrm' -Value 'no'
            } else {
                $g = Get-ServerGroup -Name $s
                $fileWide = ($null -ne $g -and (Test-WinrmOffValue ([string]$g.Winrm)))
                Set-ServerAttribute -Server $s -Key 'winrm' -Value $(if ($fileWide) { 'yes' } else { '' })
            }
            $changed += $s
        } catch { $errors += ('{0}: {1}' -f $s, (Get-ShortError $_)); Write-PatchLog ("{0}: the winrm mark was not written: {1}" -f $s, (Get-ShortError $_)) 'ERROR' }
    }
    if ($changed.Count -gt 0) {
        # the files decide: each group file written is read again in place, so Test-RemoteDisabled answers from it from now on
        $written = @($changed | ForEach-Object { $g = Get-ServerGroup -Name $_; if ($g -and $g.File) { [string]$g.File } } | Select-Object -Unique)
        $groups = @($script:Groups)
        for ($i = 0; $i -lt $groups.Count; $i++) {
            if ($written -notcontains [string]$groups[$i].File) { continue }
            $fresh = Read-GroupFile -Path $groups[$i].File
            if ($fresh) { $groups[$i] = $fresh }
        }
        $script:Groups = $groups; $script:GroupIndex = $null
        Clear-CheckRowCache
        if (Get-Command -Name 'Clear-SecurityRowCache' -ErrorAction SilentlyContinue) { Clear-SecurityRowCache }
        $script:SoftwareRowCache = $null
        Write-PatchLog ("{0} server(s) {1}; the group files were read again: {2}" -f $changed.Count, $(if ($want) { "now marked 'winrm: no' - never called over WinRM" } else { "no longer marked 'winrm: no' - called over WinRM from the next check" }), ($changed -join ', ')) 'INFO'
    }
    return @{ Changed = $changed; Skipped = $skipped; Errors = $errors }
}

function Get-ServerAttribute {
    # A server's setting by key: its own "; key: value" on the group-file line first, else the group's directive
    # ("# soe:" / "# class:" / "# winrm:") for the three keys that have one, else ''.  The FIRST group file that lists the
    # server decides - the Health and Security pages write and read that one.  A different value in a later file is a
    # conflict: said once per server, key and file in the log, so a hand-written directive is never lost in silence.
    param([string]$Name, [string]$Key)
    $groups = @(Get-ServerGroups -Name $Name)
    if ($groups.Count -eq 0) { return '' }
    $k = $Key.ToLower()
    $pick = {
        param($g)
        if ($g.PSObject.Properties['Attributes'] -and $g.Attributes) { $own = $g.Attributes[$Name.ToLower()]; if ($own -and $own[$k]) { return [string]$own[$k] } }
        if ($k -eq 'soe') { return [string]$g.Soe }
        if ($k -eq 'class') { return [string]$g.Class }
        if ($k -eq 'winrm' -and $g.PSObject.Properties['Winrm']) { return [string]$g.Winrm }
        return ''
    }
    $value = & $pick $groups[0]
    if ($groups.Count -gt 1) {
        if (-not $script:AttributeConflictSaid) { $script:AttributeConflictSaid = @{} }
        foreach ($g in @($groups | Select-Object -Skip 1)) {
            $other = & $pick $g
            if (-not $other -or $other -eq $value) { continue }
            $tag = ($Name + '|' + $k + '|' + [string]$g.Name).ToLower()
            if ($script:AttributeConflictSaid.ContainsKey($tag)) { continue }
            $script:AttributeConflictSaid[$tag] = $true
            Write-PatchLog ("{0} - {1} is '{2}' in group {3} but '{4}' in group {5}: the first group file that lists the server decides - put the value on its line there, or take it out of the other file" -f $Name, $Key, $(if ($value) { $value } else { 'not set' }), $groups[0].Name, $other, $g.Name) 'WARN'
        }
    }
    return $value
}

function Get-TextFileEncoding {
    # The encoding to write a text file back with so its bytes stay as they were: UTF-8 with BOM, ANSI, or plain UTF-8/ASCII.
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return (New-Object System.Text.UTF8Encoding $true) }
    foreach ($b in $bytes) { if ($b -ge 0x80) { return [System.Text.Encoding]::Default } }
    return (New-Object System.Text.UTF8Encoding $false)
}

function Set-ServerAttribute {
    # Writes (or removes, with an empty -Value) one "; key: value" on a server's line in its group file, so the
    # setting persists with the server list itself.  -Server finds the file through $script:Groups; -File takes a
    # path directly.  Other keys on the line, its comment and the rest of the file are kept as they are.
    param([string]$Server, [string]$Key, [string]$Value = '', [string]$File)
    if (-not $File) {
        $g = Get-ServerGroup -Name $Server
        if (-not $g) { throw "server '$Server' is not in any loaded group" }
        $File = $g.File
    }
    $k = ([string]$Key).Trim().ToLower(); $Value = ([string]$Value).Trim()
    if ($k -notmatch '^[a-z][a-z0-9_\-]*$') { throw "'$Key' is not a valid setting name" }
    if ($Value -match '[#;\r\n]') { throw "a setting value cannot contain '#', ';' or a line break" }
    $enc = Get-TextFileEncoding -Path $File
    if ($Value -match '[^\x00-\x7F]' -and $enc.WebName -eq 'utf-8' -and $enc.GetPreamble().Length -eq 0) { $enc = New-Object System.Text.UTF8Encoding $true }   # Get-Content reads UTF-8 only with a BOM
    $out = New-Object System.Collections.Generic.List[string]
    $found = $false
    foreach ($raw in @([System.IO.File]::ReadAllLines($File, $enc))) {
        $code = $raw; $comment = ''
        $hash = $raw.IndexOf('#')
        if ($hash -ge 0) { $code = $raw.Substring(0, $hash); $comment = $raw.Substring($hash) }
        $parts = @($code -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($parts.Count -eq 0 -or $parts[0] -ine $Server) { $out.Add($raw); continue }   # every line naming the server, not just the first
        $found = $true
        $pairs = New-Object System.Collections.Generic.List[string]
        $done = $false
        for ($i = 1; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -match '^([A-Za-z][A-Za-z0-9_\-]*)\s*:\s*(.*)$' -and $Matches[1].ToLower() -eq $k) {
                if ($Value -and -not $done) { $pairs.Add($k + ': ' + $Value) }
                $done = $true
            } else { $pairs.Add($parts[$i]) }
        }
        if ($Value -and -not $done) { $pairs.Add($k + ': ' + $Value) }
        $line = $parts[0]
        if ($pairs.Count -gt 0) { $line += '; ' + ($pairs -join '; ') }
        if ($comment) { $line += '  ' + $comment }
        $out.Add($line)
    }
    if (-not $found) { throw "server '$Server' has no line in $(Split-Path $File -Leaf)" }
    [System.IO.File]::WriteAllLines($File, [string[]]$out, $enc)
    $leaf = Split-Path $File -Leaf
    if ($Value) { Write-PatchLog ("{0}: '{1}; {2}: {3}' written" -f $leaf, $Server, $k, $Value) 'OK' } else { Write-PatchLog ("{0}: '{1}: ...' removed from the line of {2}" -f $leaf, $k, $Server) 'OK' }
}

function Get-ServerGroup {
    # The first group that lists this server (case-insensitive), or $null.  Used for the server's
    # class (internet-facing or not) and its SOE standard.
    param([string]$Name)
    $all = @(Get-ServerGroups -Name $Name)
    if ($all.Count -gt 0) { return $all[0] }
    return $null
}

function Get-ServerGroups {
    # Every group that lists this server, in group-file order - a server can be in more than one (a group-scoped
    # tailoring rule applies through any of them).  A name index is kept per loaded group list, so a 500-server
    # fleet answers from a hashtable instead of a scan every time.
    param([string]$Name)
    if (-not $script:GroupIndex -or -not [object]::ReferenceEquals($script:GroupIndex.Groups, $script:Groups)) {
        $script:AttributeConflictSaid = @{}   # a reloaded list may have fixed (or made) a conflict: Get-ServerAttribute says so again
        $map = @{}
        foreach ($g in @($script:Groups)) {
            foreach ($s in @($g.Servers)) {
                $k = ([string]$s).ToLower()
                if (-not $map.ContainsKey($k)) { $map[$k] = @() }
                if (-not @($map[$k] | Where-Object { [object]::ReferenceEquals($_, $g) }).Count) { $map[$k] += $g }
            }
        }
        $script:GroupIndex = @{ Groups = $script:Groups; Map = $map }
    }
    $list = $script:GroupIndex.Map[([string]$Name).ToLower()]
    if ($null -eq $list) { return @() }
    return $list
}
