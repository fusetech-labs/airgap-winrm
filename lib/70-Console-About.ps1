# =====================================================================
#  70-Console-About.ps1  -  THE ABOUT CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  What the toolkit is, who wrote it and where to get support, and where its
#  source lives (the GitHub link and the support address are shown to
#  copy: the tool itself never goes online or sends mail), and this copy: its
#  folder, who runs it, PowerShell's language mode and execution policy,
#  and the code signature of every script - what an AllSigned policy or
#  application control would see (Sign-Toolkit.ps1 signs them).
#  The page is built when the tab is first opened (signature checks take
#  a moment); "Check signatures again" rebuilds it.
#  Loading the scripts on this PC: what the next start meets (the Group
#  Policy execution policy, the "downloaded" mark, a network folder, the
#  signatures), and buttons that act on THIS PC only, each after a Yes:
#  unblock the scripts, self-sign them, create a signing request for a
#  certificate authority (a file to take there by hand - the tool never
#  talks to a CA), install the certificate that comes back, sign with it.
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  70-Console-About.ps1
#  New 2026-10-21.  Nothing here talks to a server.  2026-10-29: loading
#  the scripts on this PC (field test of version 1: PowerShell asked
#  before every script at the start) - the detail and the five buttons.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : _______cf_______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================

function Get-ToolkitScriptFiles {
    # The tool's own scripts - what Sign-Toolkit.ps1 signs: the launcher and lib\ (loaded at every start), then
    # Sign-Toolkit.ps1 (run by hand).  Returns @{ Path; Runs }.
    $lib = Join-Path $script:RootFolder 'lib'
    $out = @([pscustomobject]@{ Path = (Join-Path $script:RootFolder 'Start-WinRMToolkit.ps1'); Runs = $true })
    $out += @($script:LibFiles | ForEach-Object { [pscustomobject]@{ Path = (Join-Path $lib $_); Runs = $true } })
    $out += [pscustomobject]@{ Path = (Join-Path $script:RootFolder 'Sign-Toolkit.ps1'); Runs = $false }
    return $out
}

function Get-ToolkitSignatureRows {
    # The Authenticode signature of every script, as an AllSigned execution policy or application control sees it, and
    # its "downloaded" mark (Zone: 3 Internet, 4 Restricted sites; Blocked says so).  Thumbprint and Publisher (the
    # signer is in Trusted Publishers here) feed the verdict of the next start (Get-ScriptLoadVerdict).
    $rows = @()
    foreach ($f in @(Get-ToolkitScriptFiles)) {
        $r = [ordered]@{ Light = 'Grey'; File = $f.Path.Substring($script:RootFolder.Length).TrimStart('\'); Loaded = $(if ($f.Runs) { 'at start' } else { 'by hand' }); Blocked = ''; Status = 'missing'; Meaning = 'the file is not there'; SignedBy = ''; ValidUntil = ''; Timestamp = ''; Zone = 0; Thumbprint = ''; Publisher = $false }
        if (Test-Path -LiteralPath $f.Path) {
            $r.Zone = Get-ToolkitFileZone -Path $f.Path
            if ($r.Zone -ge 3) { $r.Blocked = $(if ($r.Zone -eq 3) { 'yes (Internet)' } else { 'yes (Restricted sites)' }) }
            try {
                $sig = Get-AuthenticodeSignature -LiteralPath $f.Path -ErrorAction Stop
                $r.Status = [string]$sig.Status
                if ($sig.SignerCertificate) {
                    $r.SignedBy = $sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
                    $r.ValidUntil = $sig.SignerCertificate.NotAfter.ToString('yyyy-MM-dd')
                    $r.Timestamp = $(if ($sig.TimeStamperCertificate) { 'yes' } else { 'no - invalid once the certificate expires' })
                    $r.Thumbprint = $sig.SignerCertificate.Thumbprint
                    $r.Publisher = Test-CertInStore -Thumbprint $r.Thumbprint -StoreName 'TrustedPublisher'
                }
                switch ($r.Status) {
                    'Valid'        { $r.Light = 'Green'; $r.Meaning = 'signed, and this PC trusts the certificate' }
                    'NotSigned'    { $r.Light = 'Grey';  $r.Meaning = 'not signed' }
                    'HashMismatch' { $r.Light = 'Red';   $r.Meaning = 'CHANGED after it was signed - sign again' }
                    default        { $r.Light = 'Amber'; $r.Meaning = 'signed, not trusted here: ' + [string]$sig.StatusMessage }
                }
            } catch { $r.Status = 'unreadable'; $r.Light = 'Red'; $r.Meaning = Get-ShortError $_ }
            if ($r.Blocked -and $r.Light -in 'Grey', 'Green' -and -not ($r.Status -eq 'Valid' -and $r.Publisher)) { $r.Light = 'Amber' }
        }
        $rows += [pscustomobject]$r
    }
    return $rows
}

# ---------------------------------------------------------------------
#  LOADING THE SCRIPTS ON THIS PC.  Field test of version 1: PowerShell asked before every .ps1 at the start.  What
#  decides it: the execution policy (one set by Group Policy overrides the launch command's -ExecutionPolicy Bypass),
#  the "downloaded from the internet" mark Windows puts on a download and on every file of a zip extracted from one, a
#  folder on a network path in the Internet zone, and the code signature.  Everything below acts on THIS PC only:
#  nothing talks to a server, a certificate authority or the internet - a signing request is a file the operator takes
#  to the CA by hand.
# ---------------------------------------------------------------------
$script:SelfSignName = 'WinRM Toolkit self-signed'          # the CN of every certificate "Self-sign on this PC" makes
$script:SigningRequestName = 'WinRM Toolkit code signing'   # the friendly name of a request made here (and of its key)
$script:CodeSigningOid = '1.3.6.1.5.5.7.3.3'                # enhanced key usage: Code Signing

# ---------------------------------------------------------------------
#  THE CRYPTOGRAPHY OF A SIGNING KEY against the ISM, for the network's classification (the Security profile's;
#  changeable in each dialog).  The control texts, and which classifications each control applies to, come from
#  data\ism-catalogue.psd1; the thresholds below are read off those texts (Levels is only the fallback when the
#  catalogue lacks a control).  Script signatures are SHA-256 whatever is asked: Windows PowerShell 5.1 signs a .ps1
#  with SHA-256 even when SHA-384 or SHA-512 is passed (tested on Server 2019, 2026-10-29: only the SHA-256 OID is in
#  the signature, CNG and CAPI keys alike) - so that is shown as fixed and judged, never offered as a choice.
# ---------------------------------------------------------------------
$script:CodeSigningRules = @(
    @{ Id = 'ISM-0476'; Kind = 'Key'; Min = 2048; Preferred = 3072; Levels = 'NC,OS,P' }
    @{ Id = 'ISM-1765'; Kind = 'Key'; Min = 3072; Preferred = 3072; Levels = 'S,TS' }
    @{ Id = 'ISM-1766'; Kind = 'Hash'; Min = 224; Preferred = 384; Levels = 'NC,OS,P' }
    @{ Id = 'ISM-1767'; Kind = 'Hash'; Min = 256; Preferred = 384; Levels = 'S' }
    @{ Id = 'ISM-1768'; Kind = 'Hash'; Min = 384; Preferred = 384; Levels = 'TS' }
    @{ Id = 'ISM-0477'; Kind = 'Separate'; Levels = 'NC,OS,P,S,TS' }
    @{ Id = 'ISM-1917'; Kind = 'PostQuantum'; Levels = 'NC,OS,P,S,TS' })
$script:ClassificationNames = @('Non-classified', 'OFFICIAL', 'OFFICIAL: Sensitive', 'PROTECTED', 'SECRET', 'TOP SECRET')
$script:HashBits = @{ SHA1 = 160; SHA256 = 256; SHA384 = 384; SHA512 = 512 }

function Test-CodeSigningRuleApplies {
    # Does this control apply at this classification column (NC / OS / P / S / TS)?  The catalogue says; else the rule.
    param($Rule, [string]$Column)
    $c = (Get-IsmCatalogue)[$Rule.Id]
    if ($c -and $null -ne $c[$Column]) { return [bool]$c[$Column] }
    return (@([string]$Rule.Levels -split ',') -contains $Column)
}

function Get-DefaultClassification {
    # The Security profile's classification (Security console, Security profile tab), PROTECTED when it names none of the list.
    $c = [string](Get-SecurityProfile).classification
    if ($script:ClassificationNames -contains $c) { return $c }
    return 'PROTECTED'
}

function Get-CodeSigningChoices {
    # The key sizes and certificate hashes that meet the minimum at this classification, the ISM's preferred first.
    param([string]$Classification)
    $column = Get-ClassificationColumn -Classification $Classification
    $minKey = 0; $minHash = 0
    foreach ($rule in $script:CodeSigningRules) {
        if (-not (Test-CodeSigningRuleApplies -Rule $rule -Column $column)) { continue }
        if ($rule.Kind -eq 'Key') { $minKey = [Math]::Max($minKey, [int]$rule.Min) }
        if ($rule.Kind -eq 'Hash') { $minHash = [Math]::Max($minHash, [int]$rule.Min) }
    }
    return [pscustomobject]@{ Keys = @(3072, 4096, 2048 | Where-Object { $_ -ge $minKey }); Hashes = @('SHA384', 'SHA512', 'SHA256' | Where-Object { $script:HashBits[$_] -ge $minHash }) }
}

function Get-CodeSigningCheck {
    # The ISM controls on code-signing cryptography that apply at a classification, each with the choice it judges and a
    # verdict: Green = meets the ISM's preference, Amber = meets the minimum only, Red = NOT MET, Grey = not possible yet.
    # $CertHashNote says whose the certificate's hash is: 'chosen' (self-signed), 'asked of the CA' (a request - the CA
    # signs the certificate), 'the certificate''s' (signing with one that exists).
    param([string]$Classification, [int]$KeyBits, [string]$CertHash, [string]$CertHashNote = 'chosen')
    $column = Get-ClassificationColumn -Classification $Classification
    $rows = @()
    $judge = {
        param($Ctl, [string]$AppliesTo, [string]$Choice, [int]$Value, [string]$Says, [string]$RevText)
        $light = 'Green'; $verdict = 'meets the ISM''s preference'
        if ($Value -lt [int]$Ctl.Min) { $light = 'Red'; $verdict = ('NOT MET: at least {0} bits' -f $Ctl.Min) }
        elseif ($Value -lt [int]$Ctl.Preferred) { $light = 'Amber'; $verdict = ('meets the minimum ({0}); the ISM prefers {1}' -f $Ctl.Min, $Ctl.Preferred) }
        [pscustomobject]@{ Light = $light; Control = $Ctl.Id; Rev = $RevText; AppliesTo = $AppliesTo; Choice = $Choice; Verdict = $verdict; Requirement = $Says }
    }
    foreach ($rule in $script:CodeSigningRules) {
        if (-not (Test-CodeSigningRuleApplies -Rule $rule -Column $column)) { continue }
        $c = (Get-IsmCatalogue)[$rule.Id]
        $text = '(not in data\ism-catalogue.psd1)'; $rev = ''
        if ($c) { $text = [string]$c.Text; $rev = ('rev {0}, {1}' -f $c.Rev, $c.Updated) }
        switch ($rule.Kind) {
            'Key' { $rows += & $judge $rule 'key' ('RSA {0}' -f $KeyBits) $KeyBits $text $rev }
            'Hash' {
                $bits = [int]$script:HashBits[[string]$CertHash]
                $rows += & $judge $rule ('certificate signature ({0})' -f $CertHashNote) ($CertHash -replace '^SHA', 'SHA-') $bits $text $rev
                $rows += & $judge $rule 'script signatures' 'SHA-256 (fixed by PowerShell 5.1)' 256 $text $rev
            }
            'Separate' { $rows += [pscustomobject]@{ Light = 'Green'; Control = $rule.Id; Rev = $rev; AppliesTo = 'key use'; Choice = 'signing only'; Verdict = 'meets: this key signs and never transports keys'; Requirement = $text } }
            'PostQuantum' { $rows += [pscustomobject]@{ Light = 'Grey'; Control = $rule.Id; Rev = $rev; AppliesTo = 'algorithm'; Choice = 'RSA'; Verdict = 'not possible yet: Windows code signing has no ML-DSA (due by 2030)'; Requirement = $text } }
        }
    }
    return $rows
}

function Get-ToolkitFileZone {
    # The "downloaded" mark of one file: the ZoneId in its Zone.Identifier stream, 0 = no mark.  3 = Internet, 4 =
    # Restricted sites: PowerShell asks before such a script (Unrestricted) or refuses it unsigned (RemoteSigned).
    # Windows' zone API does not read the mark of a local file (tested), so the stream itself is read.
    param([string]$Path)
    try { foreach ($l in @(Get-Content -LiteralPath $Path -Stream Zone.Identifier -ErrorAction Stop)) { if ([string]$l -match '^\s*ZoneId\s*=\s*(\d+)') { return [int]$Matches[1] } } } catch { }
    return 0
}

function Get-ToolkitFolderPlace {
    # Where this copy runs from: a local disk, or a network path with its zone.  A share in the Internet zone (a dotted
    # server name that is not in the Local intranet sites) counts as downloaded for every script in it, mark or no mark.
    $root = [string]$script:RootFolder
    $network = $root.StartsWith('\\')
    if (-not $network) { try { $network = ((New-Object System.IO.DriveInfo ([System.IO.Path]::GetPathRoot($root))).DriveType -eq 'Network') } catch { } }
    $zone = 'MyComputer'
    if ($network) { try { $zone = [string][System.Security.Policy.Zone]::CreateFromUrl($root).SecurityZone } catch { $zone = 'unknown' } }
    return [pscustomobject]@{ Network = $network; Zone = $zone; Remote = ($zone -in 'Internet', 'Untrusted') }
}

function Test-CertInStore {
    # Is this certificate (by thumbprint) in that store of this user or of this PC?
    param([string]$Thumbprint, [string]$StoreName)
    if (-not $Thumbprint) { return $false }
    foreach ($scope in 'CurrentUser', 'LocalMachine') { if (Test-Path -LiteralPath ('Cert:\{0}\{1}\{2}' -f $scope, $StoreName, $Thumbprint)) { return $true } }
    return $false
}

function Test-ToolkitAdmin {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ScriptPolicySource {
    # The execution policy a Group Policy sets (MachinePolicy before UserPolicy).  It overrides the launch command's
    # -ExecutionPolicy Bypass, so it decides the next start.  Policy '' = no Group Policy sets one.
    foreach ($e in @(Get-ExecutionPolicy -List)) { if ([string]$e.Scope -in 'MachinePolicy', 'UserPolicy' -and [string]$e.ExecutionPolicy -ne 'Undefined') { return [pscustomobject]@{ Policy = [string]$e.ExecutionPolicy; Scope = [string]$e.Scope } } }
    # no Group Policy - but an AllSigned set by hand (LocalMachine or CurrentUser) still decides "Run with PowerShell": that
    # shell verb switches to Bypass only when the effective policy is NOT AllSigned (its command is "if ((Get-ExecutionPolicy)
    # -ne 'AllSigned') { Set-ExecutionPolicy -Scope Process Bypass }"); the README's command line bypasses it
    $effective = ''; try { $effective = [string](Get-ExecutionPolicy) } catch { }
    if ($effective -eq 'AllSigned') { return [pscustomobject]@{ Policy = 'AllSigned'; Scope = 'set by hand (LocalMachine or CurrentUser): "Run with PowerShell" keeps it, the README''s command line does not' } }
    return [pscustomobject]@{ Policy = ''; Scope = '' }
}

function Get-ScriptLoadVerdict {
    # What the next start meets - the README's command or "Run with PowerShell", both Bypass unless a Group Policy sets
    # the policy - from that policy, the scripts marked as downloaded (every one, when the folder is a network path in the
    # Internet zone) and their signatures.  Returns Light and Text.
    param([string]$Policy, [object[]]$Rows, [bool]$RemoteFolder = $false)
    $run = @($Rows | Where-Object { $_.Loaded -eq 'at start' })
    $remote = @($run | Where-Object { $RemoteFolder -or $_.Zone -ge 3 })
    $fix = 'Unblock the scripts'; if ($RemoteFolder) { $fix = 'copy the folder to a local disk' }
    $say = { param([string]$Light, [string]$Text) [pscustomobject]@{ Light = $Light; Text = $Text } }
    switch ($Policy) {
        { $_ -in '', 'Bypass' } { if ($Policy) { return (& $say 'Green' 'runs without a question (Group Policy: Bypass)') }; return (& $say 'Green' 'runs without a question: no Group Policy sets the policy, so the launch command''s Bypass applies') }
        'Unrestricted' {
            # a downloaded script whose signature no longer matches its contents is refused outright ("AuthorizationManager check
            # failed" - tested on 5.1); an unsigned one, or one signed by a publisher not trusted here, is asked about
            $refused = @($remote | Where-Object { [string]$_.Status -notin 'Valid', 'NotSigned' })
            $ask = @($remote | Where-Object { [string]$_.Status -eq 'NotSigned' -or ([string]$_.Status -eq 'Valid' -and -not $_.Publisher) })
            if ($refused.Count -gt 0) { return (& $say 'Red' ('refuses {0} script(s) counted as downloaded whose signature no longer matches - sign again, or {1}' -f $refused.Count, $fix)) }
            if ($ask.Count -gt 0) { return (& $say 'Amber' ('asks before each of {0} script(s) counted as downloaded - {1}' -f $ask.Count, $fix)) }
            return (& $say 'Green' 'runs without a question')
        }
        'RemoteSigned' {
            $refused = @($remote | Where-Object { [string]$_.Status -ne 'Valid' })
            $ask = @($remote | Where-Object { [string]$_.Status -eq 'Valid' -and -not $_.Publisher })
            if ($refused.Count -gt 0) { return (& $say 'Red' ('refuses {0} script(s) counted as downloaded and not signed with a trusted certificate - {1}' -f $refused.Count, $fix)) }
            if ($ask.Count -gt 0) { return (& $say 'Amber' ('asks once to trust the publisher of {0} downloaded script(s) ([A] Always run) - or {1}' -f $ask.Count, $fix)) }
            return (& $say 'Green' 'runs without a question')
        }
        'AllSigned' {
            $refused = @($run | Where-Object { [string]$_.Status -ne 'Valid' })
            $ask = @($run | Where-Object { [string]$_.Status -eq 'Valid' -and -not $_.Publisher })
            if ($refused.Count -gt 0) { return (& $say 'Red' ('refuses {0} of the {1} scripts: not signed with a certificate this PC trusts - Self-sign on this PC, or sign with a certificate from your CA' -f $refused.Count, $run.Count)) }
            if ($ask.Count -gt 0) { return (& $say 'Amber' 'asks once to trust the publisher ([A] Always run puts it in your Trusted Publishers)') }
            return (& $say 'Green' 'runs without a question: every script signed by a trusted publisher')
        }
        default { return (& $say 'Red' ('no script runs (Group Policy: {0})' -f $Policy)) }
    }
}

function Get-ToolkitSigningCertificates {
    # Code-signing certificates with their private key on this PC (this user's and the computer's Personal store), valid today.
    $now = Get-Date
    return @(foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') { Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt $now -and $_.NotBefore -le $now } })
}

function Get-ToolkitSelfSignedTrust {
    # The certificates "Self-sign on this PC" made, in Trusted Root and Trusted Publishers of this user and of this PC
    # (a user store also lists what it inherits from the PC's).
    return @(foreach ($scope in 'CurrentUser', 'LocalMachine') {
        foreach ($store in 'Root', 'TrustedPublisher') {
            foreach ($c in @(Get-ChildItem -Path ('Cert:\{0}\{1}' -f $scope, $store) -ErrorAction SilentlyContinue | Where-Object { $_.Subject -like ('CN=' + $script:SelfSignName + '*') })) {
                [pscustomobject]@{ Scope = $scope; Store = $store; Thumbprint = $c.Thumbprint; Subject = $c.Subject; NotAfter = $c.NotAfter }
            }
        }
    })
}

function Get-ToolkitSigningRequests {
    # Requests made here ("Create a signing request") still waiting for the CA's certificate: this user's REQUEST store.
    return @(Get-ChildItem -Path 'Cert:\CurrentUser\REQUEST' -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq $script:SigningRequestName })
}

function Get-CodeSigningRows {
    # The page's certificate table: each code-signing certificate with its key here, then each toolkit self-signed
    # certificate this PC trusts (its key was deleted after the signing).
    $rows = @()
    foreach ($c in @(Get-ToolkitSigningCertificates)) {
        $rows += [pscustomobject]@{ Kind = 'with its private key'; Where = $(if ([string]$c.PSParentPath -like '*LocalMachine*') { 'this PC (Personal)' } else { 'this user (Personal)' }); Subject = $c.Subject; Issuer = $(if ($c.Subject -eq $c.Issuer) { 'self-signed' } else { $c.Issuer }); ValidUntil = $c.NotAfter.ToString('yyyy-MM-dd'); TrustedPublisher = $(if (Test-CertInStore -Thumbprint $c.Thumbprint -StoreName 'TrustedPublisher') { 'yes' } else { 'no' }); Thumbprint = $c.Thumbprint }
    }
    $trust = @(Get-ToolkitSelfSignedTrust)
    foreach ($t in @($trust | Group-Object -Property Thumbprint)) {
        $machine = @($t.Group | Where-Object { $_.Scope -eq 'LocalMachine' })
        $where = 'this user'; if ($machine.Count -gt 0) { $where = 'every user of this PC' }
        $stores = @($t.Group | ForEach-Object { $_.Store } | Select-Object -Unique)
        $first = $t.Group[0]
        $rows += [pscustomobject]@{ Kind = 'toolkit self-signed, key deleted'; Where = ('trusted for {0} ({1})' -f $where, ($stores -join ', ')); Subject = $first.Subject; Issuer = 'self-signed'; ValidUntil = $first.NotAfter.ToString('yyyy-MM-dd'); TrustedPublisher = $(if ($stores -contains 'TrustedPublisher') { 'yes' } else { 'no' }); Thumbprint = $first.Thumbprint }
    }
    return $rows
}

function Get-ScriptLoadingRows {
    # The page's "Loading the scripts on this PC": what the next start meets, and what decides it.
    param([object[]]$Signatures)
    $gpo = Get-ScriptPolicySource
    $place = Get-ToolkitFolderPlace
    $verdict = Get-ScriptLoadVerdict -Policy $gpo.Policy -Rows $Signatures -RemoteFolder $place.Remote
    $blocked = @($Signatures | Where-Object { $_.Zone -ge 3 })
    $certs = @(Get-ToolkitSigningCertificates)
    $requests = @(Get-ToolkitSigningRequests)
    $reqFiles = @(Get-ChildItem -LiteralPath (Join-Path $script:RootFolder 'signing') -Filter '*.req' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | ForEach-Object { 'signing\' + $_.Name })
    $selfSigned = @(Get-ToolkitSelfSignedTrust | ForEach-Object { $_.Thumbprint } | Select-Object -Unique)
    $folder = 'a local disk'
    if ($place.Remote) { $folder = ('a network path in the {0} zone: every script counts as downloaded - copy the folder to a local disk' -f $place.Zone) } elseif ($place.Network) { $folder = ('a network path ({0} zone)' -f $place.Zone) }
    return @(
        [pscustomobject]@{ Light = $verdict.Light; Item = 'Next start'; Value = $verdict.Text }
        [pscustomobject]@{ Light = ''; Item = 'Execution policy by Group Policy'; Value = $(if ($gpo.Policy) { '{0} ({1}) - the launch command''s -ExecutionPolicy Bypass does not override it' -f $gpo.Policy, $gpo.Scope } else { 'none' }) }
        [pscustomobject]@{ Light = $(if ($place.Remote) { 'Amber' } else { '' }); Item = 'This folder'; Value = $folder }
        [pscustomobject]@{ Light = $(if ($blocked.Count -gt 0) { 'Amber' } else { '' }); Item = 'Marked as downloaded'; Value = $(if ($blocked.Count -gt 0) { '{0} of the {1} scripts - Unblock the scripts' -f $blocked.Count, @($Signatures).Count } else { 'none' }) }
        [pscustomobject]@{ Light = ''; Item = 'Signatures'; Value = (Get-SignatureSummary -Rows $Signatures) }
        [pscustomobject]@{ Light = ''; Item = 'Code-signing certificates with their key here'; Value = $(if ($certs.Count -gt 0) { '{0} (listed below)' -f $certs.Count } else { 'none' }) }
        [pscustomobject]@{ Light = ''; Item = 'Signing requests waiting for the CA'; Value = $(if ($requests.Count -gt 0) { '{0}{1}' -f $requests.Count, $(if ($reqFiles.Count -gt 0) { ' - ' + ($reqFiles -join ', ') } else { '' }) } else { 'none' }) }
        [pscustomobject]@{ Light = ''; Item = 'Toolkit self-signed certificates trusted here'; Value = $(if ($selfSigned.Count -gt 0) { '{0} (listed below)' -f $selfSigned.Count } else { 'none' }) }
        [pscustomobject]@{ Light = ''; Item = 'Administrator'; Value = $(if (Test-ToolkitAdmin) { 'yes - Self-sign trusts its certificate for every user of this PC' } else { 'no - Self-sign trusts its certificate for this user only' }) })
}

function Add-ToolkitCertToStore {
    # A store of this user or this PC gets the certificate's PUBLIC part (no private key ever goes into Root or Trusted
    # Publishers).  Root of this user: Windows asks the operator to confirm, and a No throws.
    param($Certificate, [string]$StoreName, [string]$Scope)
    $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$Certificate.RawData)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store ($StoreName, $Scope)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { $store.Add($pub) } finally { $store.Close() }
}

function Remove-ToolkitCertFromStore {
    param([string]$Thumbprint, [string]$StoreName, [string]$Scope)
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store ($StoreName, $Scope)
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try { foreach ($c in @($store.Certificates.Find([System.Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint, $Thumbprint, $false))) { $store.Remove($c) } } finally { $store.Close() }
}

function Remove-ToolkitCertKey {
    # The certificate "Self-sign" made, out of this user's Personal store together with its private key.
    param([string]$Thumbprint)
    Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $Thumbprint) -DeleteKey -ErrorAction Stop
}

function Unblock-ToolkitScripts {
    # Removes the "downloaded" mark (the Zone.Identifier stream) from these files - the files themselves do not change.
    param([string[]]$Paths)
    $done = 0; $failed = @()
    foreach ($p in @($Paths)) {
        try {
            Unblock-File -LiteralPath $p -ErrorAction Stop
            if ((Get-ToolkitFileZone -Path $p) -eq 0) { $done++ } else { $failed += ('{0}: still marked' -f (Split-Path -Path $p -Leaf)) }
        } catch { $failed += ('{0}: {1}' -f (Split-Path -Path $p -Leaf), $_.Exception.Message) }
    }
    return [pscustomobject]@{ Done = $done; Failed = $failed }
}

function Invoke-ToolkitSign {
    # Signs the tool's scripts (or -Files) with one certificate, SHA-256 (the most Windows PowerShell 5.1 signs a script
    # with - tested; Get-CodeSigningCheck judges it against the ISM), no timestamp: the tool never goes online
    # (Sign-Toolkit.ps1 -TimestampServer takes an internal timestamp authority).  A file counts as signed when it carries
    # this certificate's signature - Valid, or signed but not trusted here yet.  Returns Signed, Total, Failed.
    param($Certificate, [string[]]$Files = @())
    if (@($Files).Count -eq 0) { $Files = @(Get-ToolkitScriptFiles | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Path }) }
    $signed = 0; $failed = @()
    foreach ($f in @($Files)) {
        try {
            $r = Set-AuthenticodeSignature -LiteralPath $f -Certificate $Certificate -HashAlgorithm SHA256 -ErrorAction Stop
            if ($r.SignerCertificate -and $r.SignerCertificate.Thumbprint -eq $Certificate.Thumbprint -and [string]$r.Status -in 'Valid', 'UnknownError', 'NotTrusted') { $signed++ }
            else { $failed += ('{0}: {1}' -f (Split-Path -Path $f -Leaf), $r.StatusMessage) }
        } catch { $failed += ('{0}: {1}' -f (Split-Path -Path $f -Leaf), $_.Exception.Message) }
    }
    return [pscustomobject]@{ Signed = $signed; Total = @($Files).Count; Failed = $failed }
}

function Invoke-ToolkitSelfSign {
    # "Self-sign on this PC": a code-signing certificate made here (RSA $KeyLength, signed with $HashAlgorithm - chosen in the
    # dialog against the ISM for the classification - key not exportable, 2 years) is trusted in
    # Trusted Root and Trusted Publishers of $Scope (LocalMachine = every user of this PC, administrators only;
    # CurrentUser = this user, and Windows asks to confirm the root certificate), every script is signed with it, and
    # its private key is deleted whatever happened - nothing else can ever be signed with it.  Trust comes first: a No
    # to Windows' question signs nothing.  After a complete signing the older toolkit certificates of $Scope go (what a
    # user store only inherits from the PC's is left to the administrator).
    param([ValidateSet('CurrentUser', 'LocalMachine')][string]$Scope, [string[]]$Files = @(), [ValidateSet(2048, 3072, 4096)][int]$KeyLength = 3072, [ValidateSet('SHA256', 'SHA384', 'SHA512')][string]$HashAlgorithm = 'SHA384')
    $out = [ordered]@{ Ok = $false; Thumbprint = ''; Signed = 0; Total = 0; Failed = @(); Removed = 0; Message = '' }
    $old = @(Get-ToolkitSelfSignedTrust | Where-Object { $_.Scope -eq $Scope })
    if ($Scope -eq 'CurrentUser') { $machine = @(Get-ToolkitSelfSignedTrust | Where-Object { $_.Scope -eq 'LocalMachine' } | ForEach-Object { $_.Thumbprint }); $old = @($old | Where-Object { $machine -notcontains $_.Thumbprint }) }
    $subject = 'CN={0} ({1} {2})' -f $script:SelfSignName, $env:COMPUTERNAME, (Get-Date -Format 'yyyy-MM-dd HHmm')
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $subject -FriendlyName $script:SelfSignName -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength $KeyLength -HashAlgorithm $HashAlgorithm -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(2) -ErrorAction Stop
    $out.Thumbprint = $cert.Thumbprint
    $added = @()
    try {
        foreach ($store in 'Root', 'TrustedPublisher') { Add-ToolkitCertToStore -Certificate $cert -StoreName $store -Scope $Scope; $added += $store }
        $s = Invoke-ToolkitSign -Certificate $cert -Files $Files
        $out.Signed = $s.Signed; $out.Total = $s.Total; $out.Failed = @($s.Failed)
        $out.Ok = ($s.Failed.Count -eq 0 -and $s.Signed -gt 0)
        if ($out.Ok) { foreach ($o in $old) { try { Remove-ToolkitCertFromStore -Thumbprint $o.Thumbprint -StoreName $o.Store -Scope $Scope; $out.Removed++ } catch { } } }
    } catch {
        $out.Message = $_.Exception.Message
        foreach ($store in $added) { try { Remove-ToolkitCertFromStore -Thumbprint $cert.Thumbprint -StoreName $store -Scope $Scope } catch { } }
    } finally {
        try { Remove-ToolkitCertKey -Thumbprint $cert.Thumbprint } catch { $out.Message = ($out.Message + '  the private key could not be deleted: ' + $_.Exception.Message).Trim() }
    }
    return [pscustomobject]$out
}

function Test-SubjectPart {
    # One part of a certificate's name: letters, digits, spaces and . - _ ' ( ) & / only, at most 64 characters.
    param([string]$Text)
    return ($Text -match "^[A-Za-z0-9 .\-_'()&/]{0,64}$")
}

function New-ToolkitSigningRequest {
    # "Create a signing request": a key made on this PC for this user (RSA $KeyLength, not exportable - it never leaves
    # this PC) and a PKCS #10 request for a code-signing certificate (certreq -new, signed with $HashAlgorithm), with a
    # text file of what to ask the CA for - including the hash to sign the certificate with, and the ISM controls of
    # $Classification with their verdicts.  Nothing is sent anywhere: the operator takes the .req file to the CA.
    # $Name: CN (required), OU, O, L, S, C.  Returns the paths and the subject.
    param([hashtable]$Name, [string]$Template = '', [string]$Folder = '', [ValidateSet(2048, 3072, 4096)][int]$KeyLength = 3072, [ValidateSet('SHA256', 'SHA384', 'SHA512')][string]$HashAlgorithm = 'SHA384', [string]$Classification = '')
    if (-not $Folder) { $Folder = Join-Path $script:RootFolder 'signing' }
    if (-not $Classification) { $Classification = Get-DefaultClassification }
    $parts = @()
    foreach ($k in 'CN', 'OU', 'O', 'L', 'S', 'C') {
        $v = ([string]$Name[$k]).Trim()
        if (-not $v) { if ($k -eq 'CN') { throw 'the common name (CN) is required' }; continue }
        if (-not (Test-SubjectPart $v)) { throw ("{0} '{1}': letters, digits, spaces and . - _ ' ( ) & / only, at most 64" -f $k, $v) }
        if ($k -eq 'C') { if ($v -notmatch '^[A-Za-z]{2}$') { throw ("C (country) '{0}': two letters, e.g. AU" -f $v) }; $v = $v.ToUpper() }
        $parts += ('{0}={1}' -f $k, $v)
    }
    $Template = ([string]$Template).Trim()
    if ($Template -and $Template -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw ("the CA template '{0}': its name without spaces (letters, digits, . _ -)" -f $Template) }
    $subject = $parts -join ','
    if (-not (Test-Path -LiteralPath $Folder)) { New-Item -ItemType Directory -Path $Folder -Force | Out-Null }
    $base = Join-Path $Folder ('code-signing-request-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $inf = $base + '.inf'; $req = $base + '.req'; $txt = $base + '.txt'
    $lines = @('[Version]', 'Signature = "$Windows NT$"', '', '[NewRequest]', ('Subject = "{0}"' -f $subject), ('FriendlyName = "{0}"' -f $script:SigningRequestName),
        ('KeyLength = {0}' -f $KeyLength), 'KeySpec = 2', 'KeyUsage = 0x80', 'MachineKeySet = FALSE', 'Exportable = FALSE', 'ProviderName = "Microsoft Enhanced RSA and AES Cryptographic Provider"', 'ProviderType = 24',
        'RequestType = PKCS10', ('HashAlgorithm = {0}' -f $HashAlgorithm), 'SMIME = FALSE', '', '[EnhancedKeyUsageExtension]', ('OID = ' + $script:CodeSigningOid))
    if ($Template) { $lines += @('', '[RequestAttributes]', ('CertificateTemplate = {0}' -f $Template)) }
    [System.IO.File]::WriteAllLines($inf, [string[]]$lines, (New-Object System.Text.ASCIIEncoding))
    $said = @(& (Join-Path $env:SystemRoot 'System32\certreq.exe') -new -q $inf $req 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $req)) { throw ('certreq -new failed (exit {0}): {1}' -f $LASTEXITCODE, (($said -join ' ') -replace '\s+', ' ').Trim()) }
    $hashName = $HashAlgorithm -replace '^SHA', 'SHA-'
    $ism = @(Get-CodeSigningCheck -Classification $Classification -KeyBits $KeyLength -CertHash $HashAlgorithm -CertHashNote 'asked of the CA')
    $detail = @(
        ('CODE-SIGNING CERTIFICATE REQUEST - {0}' -f $script:Config.ToolName), '',
        ('Request file : {0}' -f (Split-Path -Path $req -Leaf)),
        '               PKCS #10, base64 - the file to give to the certificate authority',
        ('Created      : {0} by {1} on {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm'), (Get-OperatorIdentity), $env:COMPUTERNAME),
        ('Subject      : {0}' -f $subject),
        ('Key          : RSA {0}, made on this PC for this user, not exportable - it never leaves this PC' -f $KeyLength),
        ('Request hash : {0} (the request is signed with it)' -f $hashName),
        ('Asks for     : key usage Digital Signature; enhanced key usage Code Signing ({0})' -f $script:CodeSigningOid),
        ('Template     : {0}' -f $(if ($Template) { $Template } else { 'none named - the CA decides (an AD CS enterprise CA often calls it CodeSigning)' })),
        ('Network      : {0} (the ISM controls below apply at this classification)' -f $Classification), '',
        'FOR THE CERTIFICATE AUTHORITY',
        '  Please issue a code-signing certificate for this request and return it as a .cer file (DER or base64),',
        '  or as a .p7b with its chain.  It signs the PowerShell scripts of an internal server administration tool.',
        ('  Please sign the certificate with {0} or stronger (the ISM controls below).' -f $hashName), '',
        ('ISM CHECK - {0} (data\ism-catalogue.psd1)' -f $Classification))
    foreach ($r in $ism) { $detail += @(('  {0,-9} {1,-36} {2,-34} {3}' -f $r.Control, $r.AppliesTo, $r.Choice, $r.Verdict), ('            "{0}" ({1})' -f $r.Requirement, $r.Rev)) }
    $detail += @('  Script signatures are SHA-256 whatever is asked: Windows PowerShell 5.1 signs a script with SHA-256 (tested).', '')
    $detail += @(
        'BACK ON THIS PC (the same user)',
        '  1. About tab, "Install the CA certificate...": pick the returned file.  It is joined to the key made with',
        '     this request; only this user on this PC can sign with it.',
        '  2. About tab, "Sign with a certificate...": pick it.  Every script the tool loads is signed.',
        '  3. Every PC that runs the signed copy must trust the CA (Trusted Root Certification Authorities, usually',
        '     by Group Policy).  Where the policy is AllSigned, PowerShell asks once to trust the publisher; to skip',
        '     that question, put the certificate in Trusted Publishers as well (also usually by Group Policy).', '',
        'The tool sent nothing anywhere: this request and its key exist only on this PC.')
    [System.IO.File]::WriteAllLines($txt, [string[]]$detail, (New-Object System.Text.ASCIIEncoding))
    return [pscustomobject]@{ Request = $req; Detail = $txt; Inf = $inf; Subject = $subject }
}

function Invoke-CertReqAccept {
    # certreq -accept for this user, quietly: the standard way to join a CA's certificate to the request made here (it
    # also files the CA chain of a .p7b).  Returns ExitCode and Text.
    param([string]$Path)
    $said = @(& (Join-Path $env:SystemRoot 'System32\certreq.exe') -accept -user -q $Path 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Text = (($said -join ' ') -replace '\s+', ' ').Trim() }
}

function Install-ToolkitIssuedCertificate {
    # "Install the CA certificate...": the certificate the CA returned for a request made here by this user, joined to the
    # request's key in this user's Personal store.  One that matches no request here is refused before any Windows tool
    # runs: a search for its key would reach the smart-card provider, which asks for a card (seen on the dev PC with
    # certutil -repairstore, 2026-10-29).  certreq -accept first; where it refuses (the CA's root is not trusted on this
    # PC yet - tested), the certificate is joined to the request's key directly (its known container, no search) and the
    # request's placeholder goes.  Returns the certificate with its key and how it went in.
    param([string]$Path)
    $col = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $col.Import($Path)
    $leaf = $null
    foreach ($c in @($col)) {
        $ekus = @(foreach ($ext in @($c.Extensions)) { if ($ext -is [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]) { foreach ($o in $ext.EnhancedKeyUsages) { $o.Value } } })
        if ($ekus -contains $script:CodeSigningOid) { $leaf = $c; break }
    }
    if (-not $leaf) { throw ('no code-signing certificate in {0} (enhanced key usage Code Signing, {1})' -f (Split-Path -Path $Path -Leaf), $script:CodeSigningOid) }
    $where = 'Cert:\CurrentUser\My\' + $leaf.Thumbprint
    $have = Get-Item -LiteralPath $where -ErrorAction SilentlyContinue
    if ($have -and $have.HasPrivateKey) { return [pscustomobject]@{ Certificate = $have; How = 'already installed with its key' } }
    $pubKey = [Convert]::ToBase64String($leaf.PublicKey.EncodedKeyValue.RawData)
    $pending = @(Get-ChildItem -Path 'Cert:\CurrentUser\REQUEST' -ErrorAction SilentlyContinue | Where-Object { [Convert]::ToBase64String($_.PublicKey.EncodedKeyValue.RawData) -eq $pubKey })
    if ($pending.Count -eq 0) { throw 'no signing request made on this PC by this user matches this certificate - was it made on another PC, or by another user?' }
    $accept = Invoke-CertReqAccept -Path $Path
    $how = 'certreq -accept'
    if ($accept.ExitCode -ne 0) {
        $key = $null; try { $key = $pending[0].PrivateKey } catch { }
        if (-not $key) { throw ("the request's key could not be opened on this PC (certreq -accept said: {0})" -f $accept.Text) }
        $bound = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, [byte[]]$leaf.RawData)
        $bound.PrivateKey = $key
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store ('My', 'CurrentUser')
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        try { $store.Add($bound) } finally { $store.Close() }
        # the request is answered: its placeholder goes, the key stays with the certificate
        foreach ($p in $pending) { Remove-Item -LiteralPath $p.PSPath -ErrorAction SilentlyContinue }
        $how = 'joined to the request''s key (certreq -accept had said: ' + $accept.Text + ')'
    }
    $mine = Get-Item -LiteralPath $where -ErrorAction SilentlyContinue
    if (-not $mine -or -not $mine.HasPrivateKey) { throw 'certreq -accept ran, but the certificate is not in your Personal store with its key' }
    return [pscustomobject]@{ Certificate = $mine; How = $how }
}

function Get-SignatureSummary {
    # One sentence about the scripts the tool loads at every start.
    param([object[]]$Rows)
    $run = @($Rows | Where-Object { $_.Loaded -eq 'at start' })
    $by = @{}; foreach ($r in $run) { $by[$r.Status] = 1 + [int]$by[$r.Status] }
    $signers = @($run | Where-Object { $_.SignedBy } | ForEach-Object { $_.SignedBy } | Select-Object -Unique)
    if ($by['HashMismatch']) { return ('{0} of the {1} scripts the tool loads were CHANGED after signing: an AllSigned policy refuses them - sign again.' -f $by['HashMismatch'], $run.Count) }
    if ($by['Valid'] -eq $run.Count) { return ('All {0} scripts the tool loads are signed by {1}, and this PC trusts the certificate.' -f $run.Count, ($signers -join ', ')) }
    if ($by['NotSigned'] -eq $run.Count) { return ('The {0} scripts the tool loads are not signed: fine where the execution policy allows local scripts (RemoteSigned, Bypass); where it is AllSigned, or application control trusts only signed scripts, sign them.' -f $run.Count) }
    return ('Of the {0} scripts the tool loads: {1}.' -f $run.Count, ((@($by.Keys | Sort-Object) | ForEach-Object { '{0} {1}' -f $by[$_], $_ }) -join ', '))
}

function Get-AboutHtml {
    # The About page.  $Signatures: rows of Get-ToolkitSignatureRows (built once, then reused until asked again).
    # -Actions: the signing buttons in "Loading the scripts on this PC" (the tab's view; a saved copy leaves them out).
    param([object[]]$Signatures = @(), [switch]$Actions)
    $policy = @(Get-ExecutionPolicy -List | ForEach-Object { '{0} {1}' -f $_.Scope, $_.ExecutionPolicy }) -join ', '
    $settings = 'none saved - the defaults of lib\01-Config.ps1'
    if ($script:SettingsInfo -and $script:SettingsInfo.Exists) { $settings = ('{0} (saved {1} by {2})' -f $script:SettingsInfo.Path, $script:SettingsInfo.Saved, $script:SettingsInfo.SavedBy) }
    $facts = @(@('Version', $script:Config.ToolVersion), @('Author', $script:Config.Author), @('Support', $script:Config.SupportEmail), @('Website', $script:Config.Website), @('Source code', $script:Config.SourceUrl), @('This copy', $script:RootFolder), @('Running as', (Get-OperatorIdentity)))
    $consoles = @(
        [pscustomobject]@{ Console = 'O/S Patching'; Does = 'Windows and .NET updates: which server needs which file, the plan, the install over WinRM, the reboot. Roles, software currency, SQL and Exchange levels.' }
        [pscustomobject]@{ Console = 'Software'; Does = 'Third-party software from a catalogue (VMware Tools first): stage, install / update with the reboot suppressed, remove old or dormant products.' }
        [pscustomobject]@{ Console = 'Health'; Does = 'Services, scheduled tasks, failed logons, processor, memory, disks, certificates, time, dormant software, Group Policy (what applies, errors, refresh, domain trust); SOE standards per group; a summary with processor, memory and disk dials and what needs attention.' }
        [pscustomobject]@{ Console = 'Security'; Does = 'An ISM / Essential Eight audit with a security profile, tailoring (risk decisions) and traffic lights; a compliance dashboard by group with an executive summary report; GPO recommendations with the value now and an impact check per server (impact found / check first / no impact).' }
        [pscustomobject]@{ Console = 'Commands'; Does = 'One PowerShell command on the ticked servers, with a cheat sheet of one-line commands. Read-only commands run at once; one that may change a server asks for a change record and a confirmation, and is recorded.' }
        [pscustomobject]@{ Console = 'Code Tour'; Does = 'How the code works, topic by topic, with pictures - for training and review.' }
        [pscustomobject]@{ Console = 'Settings'; Does = 'The pre-action confirmations, what each change records, the running log, warnings and thresholds.' }
        [pscustomobject]@{ Console = 'About'; Does = 'This page.' })
    $copy = @(
        [pscustomobject]@{ Item = 'PowerShell'; Value = ('{0}, {1} language mode' -f $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode) }
        [pscustomobject]@{ Item = 'Execution policy'; Value = ('{0} in effect ({1})' -f (Get-ExecutionPolicy), $policy) }
        [pscustomobject]@{ Item = 'Settings'; Value = $settings }
        [pscustomobject]@{ Item = "Today's log"; Value = (Get-PatchLogPath) }
        [pscustomobject]@{ Item = 'Change log'; Value = (Get-ChangeLogPath) }
        [pscustomobject]@{ Item = 'Computer'; Value = $env:COMPUTERNAME })
    $sections = @(
        @{ Heading = 'What it is'; Lines = @(
            ('Offline administration of Windows Servers over WinRM ({0}, port {1}): O/S patching, third-party software, health and SOE checks, and an ISM security audit - from one PowerShell 5.1 window, with no agent on the servers and no internet connection.' -f (Get-WinRMSchemeText), $script:Config.WinRMPort),
            ('Author: {0}.  Support: {1} - copy the address with the Copy support email button above.' -f $script:Config.Author, $script:Config.SupportEmail),
            ('Source code, issues and new versions: {0} - copy the link with the Copy GitHub link button above; the tool itself never connects to the internet.' -f $script:Config.SourceUrl),
            'Every install, update, removal and reboot goes through a plan, a change record and the pre-action confirmations (Settings tab), and is recorded three times: the running log, changes\change-log.csv and on the server itself (event log and C:\PatchStaging\change-log.txt). STAGE ONLY copies files without a change record by default; a typed command that may change a server, and the Trellix Agent buttons, ask for a change record and their own Yes/No (the Settings tab decides per action).') }
        @{ Heading = 'The consoles'; Rows = $consoles; Columns = @('Console', 'Does') }
        @{ Heading = 'This copy'; Rows = $copy; Columns = @('Item', 'Value') })
    if (@($Signatures).Count -gt 0) {
        $loading = ConvertTo-ReportTable -Rows @(Get-ScriptLoadingRows -Signatures $Signatures) -Columns @('Light', 'Item', 'Value')
        if ($Actions) { $loading = (Get-AboutActionsHtml) + $loading }
        $sections += @{ Heading = 'Loading the scripts on this PC'; Html = $loading }
        $sections += @{ Heading = 'Code signature of the scripts'; Note = 'Only the .ps1 files need a signature: the data files (data\*.psd1, settings, SOE and security JSON) and the script blocks sent to the servers are not checked by the execution policy.'; Rows = $Signatures; Columns = @('Light', 'File', 'Loaded', 'Blocked', 'Status', 'Meaning', 'SignedBy', 'ValidUntil', 'Timestamp') }
        $certRows = @(Get-CodeSigningRows)
        if ($certRows.Count -gt 0) { $sections += @{ Heading = 'Code-signing certificates on this PC'; Rows = $certRows; Columns = @('Kind', 'Where', 'Subject', 'Issuer', 'ValidUntil', 'TrustedPublisher', 'Thumbprint') } }
    }
    $sections += @{ Heading = 'Requirements'; Lines = @(
        'This PC: Windows PowerShell 5.1 with .NET Framework 4.x, in FullLanguage mode (application control that forces ConstrainedLanguage stops the window - signing the scripts with a certificate the policy trusts lifts that).',
        ('The servers: WinRM over {0} ({1}) from this PC, and an account that is a local administrator on them. No agent, no file shares, no internet.' -f (Get-WinRMSchemeText), $script:Config.WinRMPort)) }
    return (New-DetailsHtml -Title ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion) -Subtitle ('offline Windows Server administration over WinRM ({0} {1})' -f (Get-WinRMSchemeText), $script:Config.WinRMPort) -Console 'About' -Facts $facts -Sections $sections)
}

function Update-AboutPage {
    # Builds the page; -Recheck reads every signature again (they are read once, then reused).
    param([switch]$Recheck)
    if ($Recheck -or -not $script:Gui['AboutSignatures']) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $script:Gui['AboutSignatures'] = @(Get-ToolkitSignatureRows)
        Write-PatchLog ('About: the signatures of {0} scripts read in {1:N1} s - {2}' -f @($script:Gui['AboutSignatures']).Count, $sw.Elapsed.TotalSeconds, (Get-SignatureSummary -Rows $script:Gui['AboutSignatures'])) 'INFO'
    }
    $page = Get-AboutHtml -Signatures $script:Gui['AboutSignatures'] -Actions
    $script:Gui['AboutHtml'] = $page -replace '(?s)<!--acts-->.*?<!--/acts-->', ''   # Save page as HTML: no buttons that do nothing there
    if ($script:Gui['AboutView']) { $script:Gui['AboutView'].DocumentText = $page }
}

# ---------------------------------------------------------------------
#  The signing actions sit ON THE PAGE, in "Loading the scripts on this PC": they scroll with the status they change.
#  A click only records the action; a timer runs it a moment later, once the page's own click handling has finished
#  (the action rebuilds the page).
# ---------------------------------------------------------------------
$script:AboutActions = @(
    @{ Id = 'act-unblock'; Text = 'Unblock the scripts'; Tip = 'Removes the "downloaded from the internet" mark from the tool''s scripts (after a Yes). The files themselves do not change.' }
    @{ Id = 'act-selfsign'; Text = 'Self-sign on this PC...'; Tip = 'Makes a code-signing certificate on this PC with the key and hash you choose against the ISM, trusts it here, signs every script and deletes its private key.' }
    @{ Id = 'act-request'; Text = 'Create a signing request...'; Tip = 'A key on this PC and a request file (signing\*.req), with the key and hash you choose against the ISM and a note of what to ask your certificate authority for. Nothing is sent anywhere.' }
    @{ Id = 'act-install'; Text = 'Install the CA certificate...'; Tip = 'The certificate your CA returned for that request: joined to its key in your Personal store.' }
    @{ Id = 'act-sign'; Text = 'Sign with a certificate...'; Tip = 'Signs every script the tool loads with a code-signing certificate on this PC that holds its key, its key and hash shown against the ISM.' })

function Get-AboutActionsHtml {
    $css = '<style>.acts{margin:2px 0 12px 0;padding:8px 10px 2px 10px;background:#f4f7fb;border-left:4px solid #1f4e79}.act{font-family:"Segoe UI",Arial,sans-serif;font-size:9pt;padding:6px 14px;margin:0 8px 6px 0;border:1px solid #1f4e79;border-radius:3px;background:#ffffff;color:#1f4e79;cursor:pointer}.act:hover{background:#1f4e79;color:#ffffff}</style>'
    $buttons = ($script:AboutActions | ForEach-Object { '<button type="button" class="act" id="{0}" title="{1}">{2}</button>' -f $_.Id, (ConvertTo-HtmlSafe $_.Tip), (ConvertTo-HtmlSafe $_.Text) }) -join ''
    return ('<!--acts-->{0}<div class="acts">{1}</div><!--/acts-->' -f $css, $buttons)
}

function Register-AboutActions {
    # After each load of the page: its action buttons record their click (Request-AboutAction).
    $view = $script:Gui['AboutView']
    if (-not $view -or -not $view.Document) { return }
    foreach ($el in @($view.Document.GetElementsByTagName('button'))) {
        if ([string]$el.Id -like 'act-*') { $el.add_Click({ Request-AboutAction -Id ([string]$this.Id) }) }
    }
}

function Request-AboutAction {
    param([string]$Id)
    $script:Gui['AboutPending'] = $Id
    if (-not $script:Gui['AboutActionTimer']) {
        $t = New-Object System.Windows.Forms.Timer; $t.Interval = 50
        $t.Add_Tick({ $this.Stop(); $todo = [string]$script:Gui['AboutPending']; $script:Gui['AboutPending'] = ''; if ($todo) { Invoke-AboutAction -Id $todo } })
        $script:Gui['AboutActionTimer'] = $t
    }
    $script:Gui['AboutActionTimer'].Stop(); $script:Gui['AboutActionTimer'].Start()
}

function Invoke-AboutAction {
    # Each as a normal action: never while another runs (Invoke-GuiAction says so in the log).
    param([string]$Id)
    switch ($Id) {
        'act-unblock'  { Invoke-GuiAction -Name 'Unblock the scripts' -Action { Start-ToolkitUnblock } }
        'act-selfsign' { Invoke-GuiAction -Name 'Self-sign on this PC' -Action { Start-ToolkitSelfSign } }
        'act-request'  { Invoke-GuiAction -Name 'Create a signing request' -Action { Start-SigningRequest } }
        'act-install'  { Invoke-GuiAction -Name 'Install the CA certificate' -Action { Start-CertificateInstall } }
        'act-sign'     { Invoke-GuiAction -Name 'Sign with a certificate' -Action { Start-ToolkitSignWithCertificate } }
        default        { Write-PatchLog "About page: no action '$Id'" 'WARN' }
    }
}

# ---------------------------------------------------------------------
#  The buttons of the second toolbar row.  Each runs as a normal action (not while another runs), asks before it
#  changes anything, logs what it did and reads the page again.
# ---------------------------------------------------------------------
function Get-ToolkitScriptPaths { return @(Get-ToolkitScriptFiles | Where-Object { Test-Path -LiteralPath $_.Path } | ForEach-Object { $_.Path }) }

function Start-ToolkitUnblock {
    $rows = @(Get-ToolkitSignatureRows)
    $blocked = @($rows | Where-Object { $_.Zone -ge 3 })
    if ($blocked.Count -eq 0) { $null = Show-PatcherMessage -Title 'Unblock the scripts' -Text 'No script of the tool carries the "downloaded from the internet" mark.'; Update-AboutPage -Recheck; return }
    $q = Show-PatcherMessage -Title 'Unblock the scripts' -Buttons 'YesNo' -Icon 'Question' -Default 'Button2' -Text ("Remove the ""downloaded from the internet"" mark from {0} script(s)?`n`n{1}`n`nOnly for a copy from a source you trust. The files themselves do not change." -f $blocked.Count, (($blocked | ForEach-Object { '    ' + $_.File }) -join "`n"))
    if ($q -ne 'Yes') { Write-PatchLog "Unblock the scripts: $(Get-OperatorIdentity) answered No - nothing changed" 'WARN'; return }
    $r = Unblock-ToolkitScripts -Paths @($blocked | ForEach-Object { Join-Path $script:RootFolder $_.File })
    Write-PatchLog ('Unblock the scripts by {0}: {1} of {2} unmarked{3}' -f (Get-OperatorIdentity), $r.Done, $blocked.Count, $(if ($r.Failed.Count -gt 0) { ' - FAILED: ' + ($r.Failed -join '; ') } else { '' })) $(if ($r.Failed.Count -gt 0) { 'ERROR' } else { 'OK' })
    if ($r.Failed.Count -gt 0) { $null = Show-PatcherMessage -Title 'Unblock the scripts' -Icon 'Warning' -Text ("{0} unmarked; these were not:`n`n{1}" -f $r.Done, ($r.Failed -join "`n")) }
    Update-AboutPage -Recheck
}

function Start-ToolkitSelfSign {
    $admin = Test-ToolkitAdmin
    $scope = 'CurrentUser'; if ($admin) { $scope = 'LocalMachine' }
    $count = @(Get-ToolkitScriptPaths).Count
    $old = @(Get-ToolkitSelfSignedTrust | Where-Object { $_.Scope -eq $scope } | ForEach-Object { $_.Thumbprint } | Select-Object -Unique)
    $whom = 'every user of this PC (you run the tool as an administrator)'
    if (-not $admin) { $whom = ('{0} only - Windows then asks you to confirm the root certificate: answer Yes' -f (Get-OperatorIdentity)) }
    $text = @(
        ('Self-sign the tool''s {0} scripts on this PC:' -f $count),
        ('  1. A code-signing certificate is made here: CN={0} ({1} ...), valid 2 years, the key and hash below; its key cannot be exported.' -f $script:SelfSignName, $env:COMPUTERNAME),
        ('  2. It goes into Trusted Root Certification Authorities and Trusted Publishers for {0}.' -f $whom),
        '  3. Every script is signed with it.   4. Its private key is deleted: nothing else can ever be signed with it.',
        'After an update of the tool, self-sign again (a new certificate).')
    if ($old.Count -gt 0) { $text += ('{0} older toolkit certificate(s) are taken out of this trust when the signing succeeds{1}.' -f $old.Count, $(if (-not $admin) { ' (Windows asks for each)' } else { '' })) }
    $text += 'This PC then trusts a certificate made on it - your security team may want to know. A certificate from your CA (Create a signing request...) is the managed way.'
    $choice = Show-CodeSigningDialog -Title 'Self-sign on this PC' -Intro ($text -join "`r`n") -OkText 'Self-sign' -HashNote 'chosen'
    if (-not $choice) { Write-PatchLog "Self-sign on this PC: $(Get-OperatorIdentity) cancelled - nothing changed" 'WARN'; return }
    Write-PatchLog ('Self-sign on this PC by {0}: trust for {1}, {2} scripts, RSA {3}, certificate {4}, {5}: {6}' -f (Get-OperatorIdentity), $scope, $count, $choice.KeyBits, $choice.Hash, $choice.Classification, (Format-CodeSigningCheck -Rows $choice.Rows)) 'INFO'
    $r = Invoke-ToolkitSelfSign -Scope $scope -KeyLength $choice.KeyBits -HashAlgorithm $choice.Hash
    if ($r.Ok) {
        Write-PatchLog ('SELF-SIGNED {0} of {1} scripts with {2} (trusted for {3}, private key deleted; {4} older trust entr(ies) removed)' -f $r.Signed, $r.Total, $r.Thumbprint, $scope, $r.Removed) 'OK'
        if ($r.Message) { Write-PatchLog $r.Message 'WARN' }
        $null = Show-PatcherMessage -Title 'Self-sign on this PC' -Text ("Signed {0} of {1} scripts.`n`nCertificate {2}, trusted for {3}; its private key is deleted.{4}" -f $r.Signed, $r.Total, $r.Thumbprint, $(if ($scope -eq 'LocalMachine') { 'every user of this PC' } else { 'you' }), $(if ($r.Message) { "`n`n" + $r.Message } else { '' }))
    } else {
        $why = $r.Message; if ($r.Failed.Count -gt 0) { $why = (($r.Failed | Select-Object -First 10) -join "`n") }
        Write-PatchLog ('Self-sign on this PC FAILED: {0} of {1} signed - {2}' -f $r.Signed, $r.Total, ($why -replace "`n", '; ')) 'ERROR'
        $null = Show-PatcherMessage -Title 'Self-sign on this PC' -Icon 'Error' -Text ("Not completed: {0} of {1} scripts signed.`n`n{2}`n`nThe certificate's private key is deleted either way." -f $r.Signed, $r.Total, $why)
    }
    Update-AboutPage -Recheck
}

function New-SigningRequestForm {
    # The request dialog, not shown yet: the certificate's name (left), then the classification, key and hash with the
    # ISM controls they meet.  -Last offers what was typed before.  Returns @{ Form; Fields }.
    param($Last = $null)
    $dlg = New-ToolkitDialogForm
    $dlg.Text = 'Create a signing request'; $dlg.ClientSize = New-Object System.Drawing.Size(1000, 600); $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $region = ''; try { $region = [System.Globalization.RegionInfo]::CurrentRegion.TwoLetterISORegionName } catch { }
    $fields = @{}; $y = 14
    # the key never leaves this PC, so the name says which PC signs: it shows wherever the signer is shown (this page,
    # PowerShell's untrusted-publisher question, the CA's records) - a CA may still put a name of its own in its place
    $cn = '{0} ({1})' -f $script:SigningRequestName, $env:COMPUTERNAME
    foreach ($spec in @(@('CN', 'Common name (CN) *', $cn), @('O', 'Organisation (O)', ''), @('OU', 'Organisational unit (OU)', ''), @('L', 'City (L)', ''), @('S', 'State (S)', ''), @('C', 'Country (C, two letters)', $region), @('Template', 'CA template (optional)', ''))) {
        $l = New-Object System.Windows.Forms.Label; $l.Text = $spec[1] + ':'; $l.Location = New-Object System.Drawing.Point(12, ($y + 3)); $l.AutoSize = $true
        $box = New-Object System.Windows.Forms.TextBox; $box.Location = New-Object System.Drawing.Point(200, $y); $box.Width = 330; $box.Text = [string]$spec[2]
        if ($Last -and $Last.ContainsKey($spec[0])) { $box.Text = [string]$Last[$spec[0]] }
        $dlg.Controls.Add($l); $dlg.Controls.Add($box); $fields[$spec[0]] = $box
        $y += 32
    }
    $script:Gui['Tips'].SetToolTip($fields['Template'], 'The certificate template your CA issues code-signing certificates from (an AD CS enterprise CA: often CodeSigning). Empty: the CA decides.')
    $cls = ''; $key = 0; $hash = ''
    if ($Last) { $cls = [string]$Last['Classification']; $key = [int]$Last['KeyBits']; $hash = [string]$Last['Hash'] }
    Add-CodeSigningPanel -Dialog $dlg -Top ($y + 8) -HashNote 'asked of the CA' -Classification $cls -KeyBits $key -Hash $hash
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = 'Create the request'; Result = 'OK'; Width = 140 }, @{ Text = 'Cancel'; Result = 'Cancel' }) -Hint 'nothing is sent anywhere'
    $dlg.AcceptButton = $bar.Buttons[0]; $dlg.CancelButton = $bar.Buttons[1]; $dlg.ActiveControl = $fields['CN']
    return @{ Form = $dlg; Fields = $fields }
}

function Show-SigningRequestForm {
    # Returns what was typed and chosen (@{ CN ... Template; Classification; KeyBits; Hash; Rows }) or $null (Cancel).
    param($Last = $null)
    $made = New-SigningRequestForm -Last $Last
    $answer = $made.Form.ShowDialog($script:Gui['Form'])
    $typed = @{}; foreach ($k in @($made.Fields.Keys)) { $typed[$k] = ([string]$made.Fields[$k].Text).Trim() }
    $choice = Get-CodeSigningPanelChoice
    foreach ($k in 'Classification', 'KeyBits', 'Hash', 'Rows') { $typed[$k] = $choice.$k }
    $made.Form.Dispose()
    if ($answer -ne 'OK') { return $null }
    return $typed
}

function Start-SigningRequest {
    $typed = $null
    while ($true) {
        $typed = Show-SigningRequestForm -Last $typed
        if (-not $typed) { Write-PatchLog 'Create a signing request: cancelled - nothing made' 'INFO'; return }
        if (-not (Confirm-CodeSigningGaps -Rows $typed['Rows'] -Classification $typed['Classification'] -What 'Create the request')) { continue }
        try { $r = New-ToolkitSigningRequest -Name $typed -Template $typed['Template'] -KeyLength $typed['KeyBits'] -HashAlgorithm $typed['Hash'] -Classification $typed['Classification']; break }
        catch { $null = Show-PatcherMessage -Title 'Create a signing request' -Icon 'Warning' -Text ("Not created: {0}" -f $_.Exception.Message) }
    }
    Write-PatchLog ('SIGNING REQUEST made by {0}: {1} (subject {2}; RSA {3}, {4}; key on this PC, not exportable; {5}: {6}) - take it to your certificate authority' -f (Get-OperatorIdentity), $r.Request, $r.Subject, $typed['KeyBits'], $typed['Hash'], $typed['Classification'], (Format-CodeSigningCheck -Rows $typed['Rows'])) 'OK'
    Update-AboutPage -Recheck
    $q = Show-PatcherMessage -Title 'Create a signing request' -Buttons 'YesNo' -Icon 'Information' -Text ("Created:`n`n    {0}`n    {1}`n`nTake the .req file to your certificate authority; the .txt says what to ask for. When the certificate comes back: Install the CA certificate..., then Sign with a certificate....`n`nOpen the folder now?" -f $r.Request, $r.Detail)
    if ($q -eq 'Yes') { Start-Process -FilePath (Join-Path $env:SystemRoot 'explorer.exe') -ArgumentList ('/select,"{0}"' -f $r.Request) }
}

function Start-CertificateInstall {
    $open = New-Object System.Windows.Forms.OpenFileDialog
    try {
        $open.Title = 'The certificate your CA returned'; $open.Filter = 'Certificate (*.cer;*.crt;*.p7b;*.pem)|*.cer;*.crt;*.p7b;*.pem|All files (*.*)|*.*'
        $sign = Join-Path $script:RootFolder 'signing'; if (Test-Path -LiteralPath $sign) { $open.InitialDirectory = $sign }
        if ($open.ShowDialog($script:Gui['Form']) -ne 'OK') { return }
        $file = $open.FileName
    } finally { $open.Dispose() }
    try { $r = Install-ToolkitIssuedCertificate -Path $file }
    catch {
        Write-PatchLog ('Install the CA certificate ({0}) FAILED: {1}' -f $file, $_.Exception.Message) 'ERROR'
        $null = Show-PatcherMessage -Title 'Install the CA certificate' -Icon 'Error' -Text ("Not installed: {0}" -f $_.Exception.Message)
        return
    }
    $c = $r.Certificate
    Write-PatchLog ('CERTIFICATE INSTALLED for {0}: {1}, issued by {2}, valid until {3}, {4} ({5})' -f (Get-OperatorIdentity), $c.Subject, $c.Issuer, $c.NotAfter.ToString('yyyy-MM-dd'), $c.Thumbprint, $r.How) 'OK'
    Update-AboutPage -Recheck
    $q = Show-PatcherMessage -Title 'Install the CA certificate' -Buttons 'YesNo' -Icon 'Question' -Default 'Button2' -Text ("Installed in your Personal store, with its private key:`n`n    {0}`n    issued by {1}`n    valid until {2}`n`nSign the tool's {3} scripts with it now?" -f $c.Subject, $c.Issuer, $c.NotAfter.ToString('yyyy-MM-dd'), @(Get-ToolkitScriptPaths).Count)
    if ($q -eq 'Yes') { Complete-ToolkitSigning -Certificate $c }
}

function Get-CertificateCrypto {
    # A certificate's own key size (RSA bits; 0 = not RSA / unreadable) and signature hash (SHA256 ...), for the ISM check.
    param($Certificate)
    $bits = 0; try { $bits = [int]$Certificate.PublicKey.Key.KeySize } catch { }
    $hash = 'SHA256'; if ([string]$Certificate.SignatureAlgorithm.FriendlyName -match '(?i)sha(\d+)') { $hash = 'SHA' + $Matches[1] }
    return [pscustomobject]@{ KeyBits = $bits; Hash = $hash }
}

function New-CertificatePickerForm {
    # The "Sign with a certificate" dialog, not shown yet: the certificate, and - for the one picked - its key and hash
    # against the ISM for the classification (shown, not chosen: they are the certificate's).  Returns the form.
    param([object[]]$Certificates)
    $dlg = New-ToolkitDialogForm
    $dlg.Text = 'Sign with a certificate'; $dlg.ClientSize = New-Object System.Drawing.Size(1000, 400); $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $l = New-Object System.Windows.Forms.Label; $l.Text = 'Code-signing certificate:'; $l.Location = New-Object System.Drawing.Point(12, 17); $l.AutoSize = $true
    $combo = New-Object System.Windows.Forms.ComboBox; $combo.DropDownStyle = 'DropDownList'; $combo.Location = New-Object System.Drawing.Point(200, 14); $combo.Width = 788
    foreach ($c in @($Certificates)) { [void]$combo.Items.Add(('{0}  -  issued by {1}, until {2}' -f $c.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false), $c.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $true), $c.NotAfter.ToString('yyyy-MM-dd'))) }
    $dlg.Controls.Add($l); $dlg.Controls.Add($combo)
    $first = Get-CertificateCrypto -Certificate @($Certificates)[0]
    Add-CodeSigningPanel -Dialog $dlg -Top 50 -HashNote 'the certificate''s' -KeyBits $first.KeyBits -Hash $first.Hash -Fixed
    $script:Gui['CodeSigningPanel'].Certificates = @($Certificates); $script:Gui['CodeSigningPanel'].CertCombo = $combo
    $combo.Add_SelectedIndexChanged({
        $ui = $script:Gui['CodeSigningPanel']
        if (-not $ui -or $this.SelectedIndex -lt 0) { return }
        $now = Get-CertificateCrypto -Certificate @($ui.Certificates)[$this.SelectedIndex]
        $ui.FixedKey = $now.KeyBits; $ui.FixedHash = $now.Hash
        Update-CodeSigningPanel -Refill
    })
    $combo.SelectedIndex = 0
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = 'Sign the scripts'; Result = 'OK'; Width = 130 }, @{ Text = 'Cancel'; Result = 'Cancel' }) -Hint 'any later edit of a script breaks its signature: sign again after every update'
    $dlg.AcceptButton = $null; $dlg.CancelButton = $bar.Buttons[1]
    return $dlg
}

function Start-ToolkitSignWithCertificate {
    $certs = @(Get-ToolkitSigningCertificates)
    if ($certs.Count -eq 0) { $null = Show-PatcherMessage -Title 'Sign with a certificate' -Text 'No code-signing certificate with its private key on this PC. Self-sign on this PC, or create a signing request for your certificate authority and install what it returns.'; return }
    $dlg = New-CertificatePickerForm -Certificates $certs
    $answer = $dlg.ShowDialog($script:Gui['Form'])
    $index = $script:Gui['CodeSigningPanel'].CertCombo.SelectedIndex
    $choice = Get-CodeSigningPanelChoice
    $dlg.Dispose()
    if ($answer -ne 'OK' -or $index -lt 0) { Write-PatchLog "Sign with a certificate: $(Get-OperatorIdentity) cancelled - nothing changed" 'WARN'; return }
    if (-not (Confirm-CodeSigningGaps -Rows $choice.Rows -Classification $choice.Classification -What 'Sign the scripts')) { return }
    $c = $certs[$index]
    Write-PatchLog ('Sign with a certificate by {0}: {1} (RSA {2}, {3}), {4}: {5}' -f (Get-OperatorIdentity), $c.Subject, $choice.KeyBits, $choice.Hash, $choice.Classification, (Format-CodeSigningCheck -Rows $choice.Rows)) 'INFO'
    Complete-ToolkitSigning -Certificate $c
}

# ---------------------------------------------------------------------
#  The classification / key / hash panel the three dialogs share, and the gate before a choice the ISM does not allow.
#  The controls live in $script:Gui['CodeSigningPanel'] (the event handlers read them there).
# ---------------------------------------------------------------------
function Add-CodeSigningPanel {
    # On $Dialog at $Top: classification, key and certificate hash (-Fixed: shown, not chosen), the fixed script-signature
    # hash, and the ISM controls that apply with their verdicts (a row's tool tip holds the control's whole text).
    param($Dialog, [int]$Top, [string]$HashNote = 'chosen', [string]$Classification = '', [int]$KeyBits = 0, [string]$Hash = '', [switch]$Fixed)
    if (-not $Classification) { $Classification = Get-DefaultClassification }
    $width = $Dialog.ClientSize.Width
    $head = New-Object System.Windows.Forms.Label; $head.Text = 'Cryptography and the ISM'; $head.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold); $head.AutoSize = $true; $head.Location = New-Object System.Drawing.Point(12, $Top)
    $rule = New-Object System.Windows.Forms.Label; $rule.BorderStyle = 'Fixed3D'; $rule.Height = 2; $rule.Location = New-Object System.Drawing.Point(12, ($Top + 22)); $rule.Width = $width - 24
    $y = $Top + 34
    $l1 = New-Object System.Windows.Forms.Label; $l1.Text = 'Classification of the network:'; $l1.AutoSize = $true; $l1.Location = New-Object System.Drawing.Point(12, ($y + 3))
    $cls = New-Object System.Windows.Forms.ComboBox; $cls.DropDownStyle = 'DropDownList'; $cls.Location = New-Object System.Drawing.Point(200, $y); $cls.Width = 170
    foreach ($n in $script:ClassificationNames) { [void]$cls.Items.Add($n) }
    $l2 = New-Object System.Windows.Forms.Label; $l2.Text = 'Key:'; $l2.AutoSize = $true; $l2.Location = New-Object System.Drawing.Point(395, ($y + 3))
    $keyBox = New-Object System.Windows.Forms.ComboBox; $keyBox.DropDownStyle = 'DropDownList'; $keyBox.Location = New-Object System.Drawing.Point(430, $y); $keyBox.Width = 100
    $l3 = New-Object System.Windows.Forms.Label; $l3.Text = 'Certificate hash:'; $l3.AutoSize = $true; $l3.Location = New-Object System.Drawing.Point(555, ($y + 3))
    $hashBox = New-Object System.Windows.Forms.ComboBox; $hashBox.DropDownStyle = 'DropDownList'; $hashBox.Location = New-Object System.Drawing.Point(660, $y); $hashBox.Width = 100
    $l4 = New-Object System.Windows.Forms.Label; $l4.Text = 'Script signatures: SHA-256'; $l4.AutoSize = $true; $l4.Location = New-Object System.Drawing.Point(785, ($y + 3))
    $script:Gui['Tips'].SetToolTip($cls, 'Picks the ISM controls that apply (data\ism-catalogue.psd1). It starts at the Security profile''s classification; changing it here changes only this choice.')
    $script:Gui['Tips'].SetToolTip($l4, 'Windows PowerShell 5.1 signs a script with SHA-256 whatever hash is asked for (tested): shown, and judged against the ISM, but not a choice.')
    if ($HashNote -eq 'asked of the CA') { $script:Gui['Tips'].SetToolTip($hashBox, 'Signs the request; the .txt for the CA asks for the certificate to be signed with it too (the CA signs the certificate).') }
    $grid = New-Object System.Windows.Forms.ListView; $grid.View = 'Details'; $grid.FullRowSelect = $true; $grid.GridLines = $true; $grid.HeaderStyle = 'Nonclickable'; $grid.ShowItemToolTips = $true
    $grid.Location = New-Object System.Drawing.Point(12, ($y + 34)); $grid.Size = New-Object System.Drawing.Size(($width - 24), 124)
    foreach ($col in @(@('Control', 78), @('Applies to', 235), @('Choice', 215), @('Verdict', ($width - 24 - 78 - 235 - 215 - 6)))) { [void]$grid.Columns.Add($col[0], $col[1]) }
    # the controls' own words, whole: what the verdicts above are judged against
    $words = New-Object System.Windows.Forms.TextBox; $words.Multiline = $true; $words.ReadOnly = $true; $words.ScrollBars = 'Vertical'; $words.BackColor = [System.Drawing.Color]::White
    $words.Location = New-Object System.Drawing.Point(12, ($y + 164)); $words.Size = New-Object System.Drawing.Size(($width - 24), 100)
    $Dialog.Controls.AddRange(@($head, $rule, $l1, $cls, $l2, $keyBox, $l3, $hashBox, $l4, $grid, $words))
    $script:Gui['CodeSigningPanel'] = @{ Cls = $cls; Key = $keyBox; Hash = $hashBox; Grid = $grid; Words = $words; HashNote = $HashNote; Fixed = [bool]$Fixed; FixedKey = $KeyBits; FixedHash = $Hash; WantKey = $KeyBits; WantHash = $Hash; Busy = $false }
    if ($Fixed) { $keyBox.Enabled = $false; $hashBox.Enabled = $false }
    $cls.Add_SelectedIndexChanged({ Update-CodeSigningPanel -Refill })
    $keyBox.Add_SelectedIndexChanged({ Update-CodeSigningPanel })
    $hashBox.Add_SelectedIndexChanged({ Update-CodeSigningPanel })
    $cls.SelectedItem = $Classification
}

function Update-CodeSigningPanel {
    # -Refill: the key and hash lists again (a new classification offers only what meets its minimum - the choice so far
    # stays when it still does); then the ISM rows for what is chosen.
    param([switch]$Refill)
    $ui = $script:Gui['CodeSigningPanel']
    if (-not $ui -or $ui.Busy) { return }
    $ui.Busy = $true
    try {
        if ($Refill) {
            if ($ui.Fixed) { $keys = @([int]$ui.FixedKey); $hashes = @([string]$ui.FixedHash) }
            else { $allowed = Get-CodeSigningChoices -Classification ([string]$ui.Cls.SelectedItem); $keys = @($allowed.Keys); $hashes = @($allowed.Hashes) }
            $wantKey = [int]$ui.WantKey; if ($ui.Key.SelectedItem) { $wantKey = [int]([string]$ui.Key.SelectedItem -replace '\D', '') }
            $wantHash = [string]$ui.WantHash; if ($ui.Hash.SelectedItem) { $wantHash = [string]$ui.Hash.SelectedItem -replace '-', '' }
            $ui.Key.Items.Clear(); foreach ($k in $keys) { [void]$ui.Key.Items.Add(('RSA {0}' -f $k)) }
            $ui.Hash.Items.Clear(); foreach ($h in $hashes) { [void]$ui.Hash.Items.Add(($h -replace '^SHA', 'SHA-')) }
            $ui.Key.SelectedIndex = [Math]::Max(0, [array]::IndexOf([int[]]$keys, $wantKey))
            $ui.Hash.SelectedIndex = [Math]::Max(0, [array]::IndexOf([string[]]$hashes, $wantHash))
        }
        $choice = Get-CodeSigningPanelChoice
        $ui.Grid.BeginUpdate()
        $ui.Grid.Items.Clear()
        $said = @()
        foreach ($r in @($choice.Rows)) {
            $it = New-Object System.Windows.Forms.ListViewItem ([string]$r.Control)
            foreach ($v in @($r.AppliesTo, $r.Choice, $r.Verdict)) { [void]$it.SubItems.Add([string]$v) }
            $line = ('{0} ({1}): {2}' -f $r.Control, $r.Rev, $r.Requirement)
            if ($said -notcontains $line) { $said += $line }
            $it.BackColor = [System.Drawing.Color]::FromName($(switch ($r.Light) { 'Green' { 'Honeydew' } 'Amber' { 'LemonChiffon' } 'Red' { 'MistyRose' } default { 'Gainsboro' } }))
            $it.ToolTipText = $line
            [void]$ui.Grid.Items.Add($it)
        }
        $ui.Grid.EndUpdate()
        $ui.Words.Text = ('ISM at {0} (data\ism-catalogue.psd1):' -f $choice.Classification) + "`r`n" + ($said -join "`r`n")
    } finally { $ui.Busy = $false }
}

function Get-CodeSigningPanelChoice {
    # What the panel shows now: Classification, KeyBits, Hash (SHA384 ...) and the ISM rows they meet.
    $ui = $script:Gui['CodeSigningPanel']
    $cls = [string]$ui.Cls.SelectedItem; if (-not $cls) { $cls = Get-DefaultClassification }
    $keyBits = 0; if ($ui.Key.SelectedItem) { $keyBits = [int]([string]$ui.Key.SelectedItem -replace '\D', '') }
    $hash = 'SHA384'; if ($ui.Hash.SelectedItem) { $hash = [string]$ui.Hash.SelectedItem -replace '-', '' }
    return [pscustomobject]@{ Classification = $cls; KeyBits = $keyBits; Hash = $hash; Rows = @(Get-CodeSigningCheck -Classification $cls -KeyBits $keyBits -CertHash $hash -CertHashNote $ui.HashNote) }
}

function Format-CodeSigningCheck {
    # The ISM rows in one log line: "ISM-0476 key Green, ISM-1766 script signatures Amber ...".
    param([object[]]$Rows)
    return ((@($Rows) | ForEach-Object { '{0} {1} {2}' -f $_.Control, $_.AppliesTo, $_.Light }) -join ', ')
}

function Confirm-CodeSigningGaps {
    # A control the choice does NOT meet (Red) - at TOP SECRET the script signatures' SHA-256 under ISM-1768, or a
    # certificate signed with less than the classification needs: named, and a Yes (default No) to go ahead regardless.
    # Returns $true when there is none, or the operator goes ahead.
    param([object[]]$Rows, [string]$Classification, [string]$What)
    $red = @($Rows | Where-Object { $_.Light -eq 'Red' })
    if ($red.Count -eq 0) { return $true }
    $list = ($red | ForEach-Object { '    {0} ({1}) - {2}: {3}' -f $_.Control, $_.AppliesTo, $_.Choice, $_.Verdict }) -join "`n"
    $q = Show-PatcherMessage -Title 'Below the ISM for this classification' -Buttons 'YesNo' -Icon 'Warning' -Default 'Button2' -Text ("At {0} this is NOT MET:`n`n{1}`n`nGo ahead only under a recorded risk decision (Security console, Tailoring).`n`n{2} anyway?" -f $Classification, $list, $What)
    if ($q -eq 'Yes') { Write-PatchLog ('{0} below the ISM at {1}, accepted by {2}: {3}' -f $What, $Classification, (Get-OperatorIdentity), (($red | ForEach-Object { $_.Control + ' ' + $_.AppliesTo }) -join ', ')) 'WARN'; return $true }
    return $false
}

function New-CodeSigningDialog {
    # The self-sign dialog, not shown yet: what will happen (-Intro), then the classification / key / hash panel.
    param([string]$Title, [string]$Intro, [string]$OkText, [string]$HashNote)
    $dlg = New-ToolkitDialogForm
    $dlg.Text = $Title; $dlg.ClientSize = New-Object System.Drawing.Size(1000, 520); $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $introLabel = New-Object System.Windows.Forms.Label; $introLabel.Text = $Intro; $introLabel.Location = New-Object System.Drawing.Point(12, 12); $introLabel.Size = New-Object System.Drawing.Size(976, 150)
    $dlg.Controls.Add($introLabel)
    Add-CodeSigningPanel -Dialog $dlg -Top 168 -HashNote $HashNote
    $bar = New-DialogButtonBar -Dialog $dlg -Buttons @(@{ Text = $OkText; Result = 'OK'; Width = 120 }, @{ Text = 'Cancel'; Result = 'Cancel' })
    $dlg.AcceptButton = $null; $dlg.CancelButton = $bar.Buttons[1]   # Enter must not trust a certificate by accident
    return $dlg
}

function Show-CodeSigningDialog {
    # Returns the panel's choice (Classification, KeyBits, Hash, Rows) after OK and the gate, or $null.
    param([string]$Title, [string]$Intro, [string]$OkText, [string]$HashNote)
    $dlg = New-CodeSigningDialog -Title $Title -Intro $Intro -OkText $OkText -HashNote $HashNote
    $answer = $dlg.ShowDialog($script:Gui['Form'])
    $choice = Get-CodeSigningPanelChoice
    $dlg.Dispose()
    if ($answer -ne 'OK') { return $null }
    if (-not (Confirm-CodeSigningGaps -Rows $choice.Rows -Classification $choice.Classification -What $OkText)) { return $null }
    return $choice
}

function Complete-ToolkitSigning {
    # Signs every script with an answered-for certificate, then says how it went.
    param($Certificate)
    $s = Invoke-ToolkitSign -Certificate $Certificate
    $lvl = 'OK'; if ($s.Failed.Count -gt 0) { $lvl = 'ERROR' }
    Write-PatchLog ('SIGNED {0} of {1} scripts by {2} with {3} ({4}){5}' -f $s.Signed, $s.Total, (Get-OperatorIdentity), $Certificate.Subject, $Certificate.Thumbprint, $(if ($s.Failed.Count -gt 0) { ' - FAILED: ' + ($s.Failed -join '; ') } else { '' })) $lvl
    Update-AboutPage -Recheck
    $trusted = @($script:Gui['AboutSignatures'] | Where-Object { $_.Thumbprint -eq $Certificate.Thumbprint -and $_.Status -eq 'Valid' }).Count
    $note = ''; if ($s.Signed -gt 0 -and $trusted -eq 0) { $note = "`n`nThis PC does not trust the certificate's chain yet: an AllSigned policy refuses the scripts until the CA is in Trusted Root Certification Authorities." }
    $null = Show-PatcherMessage -Title 'Sign with a certificate' -Icon $(if ($s.Failed.Count -gt 0) { 'Warning' } else { 'Information' }) -Text ("Signed {0} of {1} scripts.{2}{3}" -f $s.Signed, $s.Total, $(if ($s.Failed.Count -gt 0) { "`n`nNot signed:`n" + (($s.Failed | Select-Object -First 10) -join "`n") } else { '' }), $note)
}

function New-AboutConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'About' -Text 'About'
    # Fill control first, then the docked edges (WinForms docks the last-added control first).
    $view = New-Object System.Windows.Forms.WebBrowser
    $view.Dock = 'Fill'; $view.ScriptErrorsSuppressed = $true; $view.AllowWebBrowserDrop = $false; $view.IsWebBrowserContextMenuEnabled = $true
    # the page is set as DocumentText (about:blank); a click on the link, or any other address, is refused: the tool never goes online
    $view.Add_Navigating({ if ($_.Url -and $_.Url.Scheme -ne 'about') { $_.Cancel = $true; Set-GuiStatus 'The tool does not open web pages - use Copy GitHub link and open it on a PC with internet' } })
    $view.Add_DocumentCompleted({ Register-AboutActions })   # the signing buttons on the page
    $tab.Controls.Add($view)
    $script:Gui['AboutView'] = $view
    $toolbar = New-ConsoleToolbar -Tab $tab
    $toolbar.Controls.Add((New-GuiButton -Text 'Copy GitHub link' -X 8 -Y 10 -W 140 -H 36 -ReadOnly -Tip $script:Config.SourceUrl -OnClick {
        Invoke-GuiAction -Name 'Copy GitHub link' -ReadOnly -Action { [System.Windows.Forms.Clipboard]::SetText([string]$script:Config.SourceUrl); Write-PatchLog "Copied to the clipboard: $($script:Config.SourceUrl)" 'OK' } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Copy support email' -X 153 -Y 10 -W 150 -H 36 -ReadOnly -Tip $script:Config.SupportEmail -OnClick {
        Invoke-GuiAction -Name 'Copy support email' -ReadOnly -Action { [System.Windows.Forms.Clipboard]::SetText([string]$script:Config.SupportEmail); Write-PatchLog "Copied to the clipboard: $($script:Config.SupportEmail)" 'OK' } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Check signatures again' -X 308 -Y 10 -W 170 -H 36 -Colour 'Gainsboro' -ReadOnly -Tip 'Reads the code signature of every script again (after Sign-Toolkit.ps1, say)' -OnClick {
        Invoke-GuiAction -Name 'Check signatures' -ReadOnly -Action { Update-AboutPage -Recheck } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Save page as HTML...' -X 483 -Y 10 -W 160 -H 36 -Colour 'Gainsboro' -ReadOnly -Tip 'This page as one HTML file' -OnClick {
        Invoke-GuiAction -Name 'Save About page' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The save dialog')) { return }
            $p = Save-HtmlAs -Html $script:Gui['AboutHtml'] -BaseName 'About' -Owner $script:Gui['Form'] -What 'page'
            if ($p) { Set-GuiStatus ('Saved: ' + $p) }
        } }))
    $null = New-ConsoleBanner -Tab $tab -Console 'About' -Title 'ABOUT' -Subtitle ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion)
    $view.BringToFront()
    # built when the tab is first opened (07-Gui.ps1 runs OnFirstShow): reading every signature takes a moment, and most
    # sessions never open this tab
    $script:Gui['OnFirstShow']['About'] = { Invoke-GuiAction -Name 'About page' -ReadOnly -Action { Update-AboutPage } }
}
