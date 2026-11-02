# =====================================================================
#  Sign-Toolkit.ps1  -  SIGN THE TOOLKIT'S SCRIPTS WITH YOUR CODE-SIGNING CERTIFICATE
# ---------------------------------------------------------------------
#  Where PowerShell's execution policy is AllSigned, or application control
#  (AppLocker / WDAC script rules and similar products) trusts only signed
#  scripts, every .ps1 the tool runs needs an Authenticode signature from a
#  certificate that policy trusts - otherwise PowerShell refuses the file,
#  or runs it in ConstrainedLanguage mode, where the window cannot start.
#  This script signs them all in one go with YOUR organisation's code-
#  signing certificate, then reports each file's signature.
#
#  WHAT NEEDS A SIGNATURE (tested under AllSigned, 2026-10-21): the .ps1
#  files only - the launcher, lib\ and this script.  The
#  data files (data\*.psd1, read with Import-PowerShellDataFile or the
#  parser), the JSON files the tool writes and the script blocks it sends
#  to the servers are not checked by the execution policy.  So the
#  Software tab can still register packages in data\software-packages.psd1
#  after signing, and nothing has to be signed on the servers.
#
#  SIGN LAST: any later edit of a .ps1 breaks its signature (HashMismatch)
#  and an AllSigned policy refuses that file.  Sign again after every
#  update.  The About tab shows the signature of every script.
#
#  TRUST, on every PC that runs the tool (usually by Group Policy): the
#  issuing CA in Trusted Root Certification Authorities, and for AllSigned
#  without a prompt the signing certificate in Trusted Publishers.  For
#  application control: a publisher rule for the certificate.  A PC that
#  does not trust the chain refuses the files under AllSigned with the
#  misleading "is not digitally signed" - run -Check there to see why.
#
#  Run it on the PC that holds the certificate and its private key:
#    powershell.exe -ExecutionPolicy Bypass -File .\Sign-Toolkit.ps1
#        lists the code-signing certificates you can use
#    powershell.exe -ExecutionPolicy Bypass -File .\Sign-Toolkit.ps1 -Thumbprint <thumbprint>
#        signs the tool: the launcher, every lib\*.ps1 and this script
#    ... -Thumbprint <thumbprint> -TimestampServer <url of an RFC 3161 timestamp service>
#        adds a timestamp, so the signatures stay valid after the certificate expires
#    powershell.exe -ExecutionPolicy Bypass -File .\Sign-Toolkit.ps1 -Check
#        reports every file's signature and signs nothing
#  The timestamp is the ONLY network call this script can make, and only
#  when -TimestampServer is given (an internal timestamp authority works).
#  The toolkit itself never goes online.
#  Exit code 0 = every file signed (or, with -Check, every file read).
# ---------------------------------------------------------------------
#  REVIEW RECORD  -  Sign-Toolkit.ps1
#  New 2026-10-21.  2026-10-26: signs only the lib files the launcher
#  loads (read from its list with the parser).  Nothing here talks to a
#  server; the timestamp server is the one optional network call.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ______________________________   Date : ______________
#  Verdict    : [ ] Approved   [ ] Approved with comments   [ ] Changes required
#  Comments   :
#    -
# =====================================================================
#Requires -Version 5.1
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
[CmdletBinding()]
param(
    [string]$Thumbprint = '',
    [string]$TimestampServer = '',
    [switch]$Check
)

$root = $PSScriptRoot
if (-not $root) { throw 'Run Sign-Toolkit.ps1 as a file: powershell.exe -ExecutionPolicy Bypass -File .\Sign-Toolkit.ps1' }

function Get-LauncherLibFiles {
    # The lib files the launcher loads, read from its own $script:LibFiles list with the parser (never by running it):
    # the launcher refuses any other lib\*.ps1, so nothing else gets the organisation's signature either.
    $launcher = Join-Path $root 'Start-WinRMToolkit.ps1'
    if (-not (Test-Path -LiteralPath $launcher)) { return @() }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcher, [ref]$null, [ref]$null)
    $assign = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$script:LibFiles' }, $true)
    if (-not $assign) { return @() }
    return @($assign.Right.Find({ param($n) $n -is [System.Management.Automation.Language.ArrayLiteralAst] }, $true).SafeGetValue() | ForEach-Object { [string]$_ })
}

function Get-ScriptsToSign {
    # The tool's own scripts: the launcher, this script and the lib files the launcher loads.  Development scripts (build
    # and test, kept out of the published tool) and any lib\*.ps1 the launcher does not list are not signed.
    $files = @(foreach ($name in 'Start-WinRMToolkit.ps1', 'Sign-Toolkit.ps1') { $p = Join-Path $root $name; if (Test-Path -LiteralPath $p) { Get-Item -LiteralPath $p } })
    $lib = Join-Path $root 'lib'
    $listed = @(Get-LauncherLibFiles)
    if (Test-Path -LiteralPath $lib) {
        $all = @(Get-ChildItem -LiteralPath $lib -Filter '*.ps1' -File)
        if ($listed.Count -gt 0) {
            $files += @($all | Where-Object { $listed -contains $_.Name })
            $extra = @($all | Where-Object { $listed -notcontains $_.Name } | ForEach-Object { $_.Name })
            if ($extra.Count -gt 0) { Write-Host ('Not signed - not in the launcher''s load list (the launcher will not run them either): {0}' -f ($extra -join ', ')) -ForegroundColor Yellow }
            $missing = @($listed | Where-Object { $n = $_; -not ($all | Where-Object { $_.Name -eq $n }) })
            if ($missing.Count -gt 0) { Write-Host ('Listed by the launcher but missing from lib\: {0}' -f ($missing -join ', ')) -ForegroundColor Yellow }
        } else { Write-Host 'The launcher''s file list could not be read - signing every lib\*.ps1' -ForegroundColor Yellow; $files += $all }
    }
    return @($files | Sort-Object FullName)
}

function Get-SignatureRow {
    # One file's signature as a row: what the About tab shows too.
    param($File)
    $sig = Get-AuthenticodeSignature -LiteralPath $File.FullName
    $by = ''; $until = ''; $stamp = ''
    if ($sig.SignerCertificate) {
        $by = $sig.SignerCertificate.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false)
        $until = $sig.SignerCertificate.NotAfter.ToString('yyyy-MM-dd')
        $stamp = $(if ($sig.TimeStamperCertificate) { 'yes' } else { 'no' })
    }
    return [pscustomobject]@{ File = $File.FullName.Substring($root.Length).TrimStart('\'); Status = [string]$sig.Status; SignedBy = $by; ValidUntil = $until; Timestamp = $stamp; Thumbprint = $(if ($sig.SignerCertificate) { $sig.SignerCertificate.Thumbprint } else { '' }) }
}

$files = @(Get-ScriptsToSign)

# ---- -Check: report only ----
if ($Check) {
    $rows = @($files | ForEach-Object { Get-SignatureRow $_ })
    $rows | Format-Table File, Status, SignedBy, ValidUntil, Timestamp -AutoSize | Out-String -Width 220 | Write-Host
    $count = @{}; foreach ($r in $rows) { $count[$r.Status] = 1 + [int]$count[$r.Status] }
    Write-Host ('{0} file(s): {1}' -f $rows.Count, ((@($count.Keys | Sort-Object) | ForEach-Object { '{0} {1}' -f $count[$_], $_ }) -join ', '))
    if ($count['HashMismatch']) { Write-Host 'HashMismatch = the file was changed after it was signed: sign again.' -ForegroundColor Yellow }
    if ($count['NotSigned'] -and $count['NotSigned'] -lt $rows.Count) { Write-Host 'NotSigned among signed files = a new file, or text added after its signature block: sign again.' -ForegroundColor Yellow }
    if ($count['UnknownError'] -or $count['NotTrusted']) { Write-Host 'UnknownError / NotTrusted = signed, but this PC does not trust the certificate chain. Note: an AllSigned policy then says the file "is not digitally signed".' -ForegroundColor Yellow }
    exit 0
}

# ---- the certificate: code signing, with its private key, not expired ----
$now = Get-Date
$certs = @()
foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
    $certs += @(Get-ChildItem -Path $store -CodeSigningCert -ErrorAction SilentlyContinue | Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt $now -and $_.NotBefore -le $now })
}
if (-not $Thumbprint) {
    if ($certs.Count -eq 0) {
        Write-Host 'No usable code-signing certificate (with its private key, not expired) in Cert:\CurrentUser\My or Cert:\LocalMachine\My.' -ForegroundColor Yellow
        Write-Host 'Ask your PKI team for a code-signing certificate (Enhanced Key Usage "Code Signing"), then run this again.'
        exit 1
    }
    Write-Host 'Code-signing certificates on this PC - run again with -Thumbprint <thumbprint>:' -ForegroundColor Cyan
    $certs | Sort-Object NotAfter -Descending | Format-Table @{ n = 'Thumbprint'; e = { $_.Thumbprint } }, @{ n = 'Subject'; e = { $_.Subject } }, @{ n = 'Issuer'; e = { $_.Issuer } }, @{ n = 'Valid until'; e = { $_.NotAfter.ToString('yyyy-MM-dd') } } -AutoSize | Out-String -Width 250 | Write-Host
    exit 1
}
$cert = @($certs | Where-Object { $_.Thumbprint -eq ($Thumbprint -replace '\s', '').ToUpper() })[0]
if (-not $cert) { Write-Host "No usable code-signing certificate with thumbprint $Thumbprint (it must hold its private key and be valid today). Run without -Thumbprint to list them." -ForegroundColor Red; exit 1 }

Write-Host ('Signing {0} file(s) with "{1}" (valid until {2}){3}' -f $files.Count, $cert.Subject, $cert.NotAfter.ToString('yyyy-MM-dd'), $(if ($TimestampServer) { ", timestamp from $TimestampServer" } else { ', no timestamp' })) -ForegroundColor Cyan
$failed = @()
foreach ($f in $files) {
    $p = @{ LiteralPath = $f.FullName; Certificate = $cert; HashAlgorithm = 'SHA256'; ErrorAction = 'Stop' }
    if ($TimestampServer) { $p.TimestampServer = $TimestampServer }
    try {
        $r = Set-AuthenticodeSignature @p
        # Valid = signed and trusted here; UnknownError / NotTrusted = signed, but this PC does not trust the chain
        if ($r.Status -eq 'Valid' -or ($r.SignerCertificate -and $r.SignerCertificate.Thumbprint -eq $cert.Thumbprint -and $r.Status -in 'UnknownError', 'NotTrusted')) { Write-Host ('  signed   {0}' -f $f.Name) }
        else { $failed += $f.Name; Write-Host ('  FAILED   {0}: {1}' -f $f.Name, $r.StatusMessage) -ForegroundColor Red }
    } catch { $failed += $f.Name; Write-Host ('  FAILED   {0}: {1}' -f $f.Name, $_.Exception.Message) -ForegroundColor Red }
}

$rows = @($files | ForEach-Object { Get-SignatureRow $_ })
$rows | Format-Table File, Status, SignedBy, ValidUntil, Timestamp -AutoSize | Out-String -Width 220 | Write-Host
if (@($rows | Where-Object { $_.Status -ne 'Valid' -and $_.Thumbprint -eq $cert.Thumbprint }).Count -gt 0) {
    Write-Host 'Signed, but THIS PC does not trust the certificate chain (Status is not Valid). On the PCs that run the tool, trust the issuing CA (Trusted Root Certification Authorities) and, for AllSigned without a prompt, the certificate (Trusted Publishers) - usually by Group Policy.' -ForegroundColor Yellow
}
if (-not $TimestampServer) { Write-Host ('No timestamp: the signatures stop being valid when the certificate expires on {0}. Sign again before then, or use -TimestampServer.' -f $cert.NotAfter.ToString('yyyy-MM-dd')) -ForegroundColor Yellow }
Write-Host 'Any later edit of a .ps1 breaks its signature: sign again after every update. The About tab shows the signature of every script.'
if ($failed.Count -gt 0) { Write-Host ('{0} file(s) NOT signed: {1}' -f $failed.Count, ($failed -join ', ')) -ForegroundColor Red; exit 1 }
exit 0
