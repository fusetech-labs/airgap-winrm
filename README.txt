Sysadmin WinRM Toolkit  -  how to start it, and how to sign it
=================================================================

The full guide is README.md.  This file is only what you need when the tool
will not start.


1. START IT
-----------

Open a PowerShell window in this folder and run:

    powershell.exe -ExecutionPolicy Bypass -File .\Start-WinRMToolkit.ps1

or right-click Start-WinRMToolkit.ps1 and choose "Run with PowerShell".

On a server the toolkit cannot reach over WinRM (marked "winrm: no" in
its group file), run a copy of the toolkit folder there instead - the
hub writes one, ready to carry, with "Copy for a server" on its O/S
Patching toolbar (state\server-copies\<server>-local-winrm\, INSTRUCTIONS.txt inside):
    powershell.exe -ExecutionPolicy Bypass -File .\Start-WinRMToolkit.ps1 -SelfCheck -ResultsFolder <the hub's state\servers share>
        no window: every check runs on that computer and one results
        file is written for the hub (Import results on the O/S Patching tab)
    powershell.exe -ExecutionPolicy Bypass -File .\Start-WinRMToolkit.ps1 -Spoke
        the window, working on that computer only, patching it from the
        hub's patches\ and software\ (asked for at start); a copy written
        by "Copy for a server" starts so by itself - a plain start is enough

Run it as the account that is a local administrator on the target servers.
Keep the whole folder together (the launcher needs lib\ and data\ next to it),
on a local disk of this PC.


2. IF IT DOES NOT START
-----------------------

What PowerShell says                              What to do
------------------------------------------------  ----------------------------
"Do you want to run ...?  [D] Do not run          The files are marked as
 [R] Run once [S] Suspend"  - once per file        downloaded: step 3
"... is not digitally signed. You cannot run      Marked as downloaded (step 3),
 this script on the current system"                or the policy is AllSigned:
                                                   sign them (step 4)
"... cannot be loaded because running scripts     Start it with the command in
 is disabled on this system"                       step 1 (Bypass)
"Do you want to run software from this            Signed, but this PC does not
 untrusted publisher?  [V] [D] [R] [A]"            yet trust the signer: answer
                                                   A (Always run), once
"PowerShell is in ConstrainedLanguage mode"       Application control (AppLocker,
                                                   WDAC) does not trust the
                                                   scripts: sign them with a
                                                   certificate it trusts (step 4a)

Which policy applies?  Type in a PowerShell window:

    Get-ExecutionPolicy -List

MachinePolicy or UserPolicy is set by Group Policy, and it wins over the
"-ExecutionPolicy Bypass" of step 1.  AllSigned there means every script must
be signed (step 4).

Commands TYPED (or pasted) at the PowerShell prompt are not scripts: the
execution policy does not stop them.  That is why steps 3 and 4 work even
when the tool itself cannot start.  Each indented command below is ONE line:
copy and paste it whole.


3. UNBLOCK THE FILES (they were downloaded, or came in a zip)
---------------------------------------------------------------

Windows marks a downloaded file, and every file of a zip extracted from one,
as "from the internet".  In a PowerShell window in this folder:

    Get-ChildItem .\Start-WinRMToolkit.ps1, .\Sign-Toolkit.ps1, .\lib\*.ps1 | Unblock-File

Only do this for a copy from a source you trust.  The files themselves do
not change.  A folder on a network share can count as "from the internet"
whatever you do: copy the folder to a local disk instead.


4. SIGN THE SCRIPTS (when the policy is AllSigned, or application control
   trusts only signed scripts)
---------------------------------------------------------------------------

Only the .ps1 files need a signature: Start-WinRMToolkit.ps1,
Sign-Toolkit.ps1 and lib\*.ps1.  Any later edit of one of them breaks its
signature: sign again after every update.

4a. With your organisation's code-signing certificate (the managed way)

    Your PKI team issues a code-signing certificate into your Personal store.
    Then, if scripts may run here:

        powershell.exe -ExecutionPolicy Bypass -File .\Sign-Toolkit.ps1
            (lists your code-signing certificates and their thumbprints)
        powershell.exe -ExecutionPolicy Bypass -File .\Sign-Toolkit.ps1 -Thumbprint <thumbprint>

    If Sign-Toolkit.ps1 cannot run either (Group Policy AllSigned), type
    this instead, in a PowerShell window in this folder:

        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq '<thumbprint>' }
        foreach ($f in (Get-ChildItem .\Start-WinRMToolkit.ps1, .\Sign-Toolkit.ps1, .\lib\*.ps1)) { Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256 }

    The PCs that run the tool must trust your CA (usually by Group Policy).

4b. Self-signed, on this PC only

    A certificate made here, trusted here, its private key deleted after
    signing so nothing else can be signed with it.  RSA 3072 and SHA-384 are
    the ISM's preferred sizes up to PROTECTED (ISM-0476, ISM-1766); at SECRET
    and TOP SECRET use -KeyLength 3072 or 4096 (ISM-1765).  Your security team
    may want to know: this PC then trusts a certificate made on it.

    Type in a PowerShell window in this folder.  "CurrentUser" = for you;
    as an administrator write "LocalMachine" in the two Import lines for every
    user of this PC.  For CurrentUser\Root Windows asks you to confirm the
    certificate: answer Yes.

        $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=WinRM Toolkit self-signed ($env:COMPUTERNAME)" -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA384 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(2)
        Export-Certificate -Cert $cert -FilePath "$env:TEMP\toolkit-signing.cer" | Out-Null
        Import-Certificate -FilePath "$env:TEMP\toolkit-signing.cer" -CertStoreLocation Cert:\CurrentUser\Root
        Import-Certificate -FilePath "$env:TEMP\toolkit-signing.cer" -CertStoreLocation Cert:\CurrentUser\TrustedPublisher
        foreach ($f in (Get-ChildItem .\Start-WinRMToolkit.ps1, .\Sign-Toolkit.ps1, .\lib\*.ps1)) { Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $cert -HashAlgorithm SHA256 }
        Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -DeleteKey
        Remove-Item "$env:TEMP\toolkit-signing.cer"

    Windows PowerShell 5.1 signs a script with SHA-256 whatever hash is
    asked for; at TOP SECRET that does not meet ISM-1768 - record a risk
    decision.

Check the result:

    Get-ChildItem .\Start-WinRMToolkit.ps1, .\lib\*.ps1 | Get-AuthenticodeSignature | Format-Table Path, Status

"Valid" = signed and trusted here.  "UnknownError" = signed, but this PC does
not trust the certificate yet.  "HashMismatch" = changed after signing: sign
again.  Then start the tool (step 1).


5. ONCE IT RUNS
---------------

The About tab, "Loading the scripts on this PC", shows what the next start
will meet and has buttons for all of the above: Unblock the scripts,
Self-sign on this PC, Create a signing request (a file for your certificate
authority), Install the CA certificate, Sign with a certificate - with the
key size and hash checked against the ISM for your classification.

The tool never goes online.  It runs as YOU on every server you tick: keep
this folder writable only by the operators.
