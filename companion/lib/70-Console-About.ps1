# =====================================================================
#  70-Console-About.ps1  -  THE ABOUT CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Version, author, support, the source link, this copy (PowerShell,
#  execution policy, the settings and environment files, the library),
#  the code signature of every script as PowerShell sees it, the
#  requirements, and how this session was started (as a file, or from
#  text).  The tool itself signs nothing and needs no elevation: it runs
#  as an ordinary user.
# =====================================================================

function Get-ToolkitScriptFiles {
    $files = @([pscustomobject]@{ Name = 'Start-DownloadToolkit.ps1'; Path = (Join-Path $script:RootFolder 'Start-DownloadToolkit.ps1') })
    foreach ($n in $script:LibFiles) { $files += [pscustomobject]@{ Name = 'lib\' + $n; Path = (Join-Path $script:RootFolder ('lib\' + $n)) } }
    return $files
}

function Get-ToolkitSignatureRows {
    $rows = @()
    foreach ($f in Get-ToolkitScriptFiles) {
        if (-not (Test-Path -LiteralPath $f.Path)) { $rows += [pscustomobject]@{ Light = 'Red'; File = $f.Name; Status = 'missing'; Meaning = 'the file is not there'; SignedBy = ''; ValidUntil = '' }; continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $f.Path
        $status = [string]$sig.Status
        $meaning = switch ($status) {
            'Valid'        { 'signed, and this PC trusts the certificate' }
            'NotSigned'    { 'not signed - fine where the execution policy allows local scripts (RemoteSigned, Bypass)' }
            'HashMismatch' { 'CHANGED after it was signed - a policy that wants signed scripts refuses it' }
            'UnknownError' { 'signed, but this PC does not trust the certificate' }
            default        { $status }
        }
        $light = switch ($status) { 'Valid' { 'Green' } 'NotSigned' { 'Grey' } default { 'Red' } }
        $by = ''; $until = ''
        if ($sig.SignerCertificate) { $by = Get-SignerOrg -Subject $sig.SignerCertificate.Subject; $until = $sig.SignerCertificate.NotAfter.ToString('yyyy-MM-dd') }
        $rows += [pscustomobject]@{ Light = $light; File = $f.Name; Status = $status; Meaning = $meaning; SignedBy = $by; ValidUntil = $until }
    }
    return $rows
}

function Get-AboutHtml {
    param([object[]]$Signatures = @())
    $policy = @(Get-ExecutionPolicy -List | ForEach-Object { '{0} {1}' -f $_.Scope, $_.ExecutionPolicy }) -join ', '
    $settings = 'none saved - the defaults of lib\01-Config.ps1'
    if ($script:SettingsInfo -and $script:SettingsInfo.Exists) { $settings = ('{0} (saved {1} by {2})' -f $script:SettingsInfo.Path, $script:SettingsInfo.Saved, $script:SettingsInfo.SavedBy) }
    $environment = 'none saved - the defaults; set what this site runs on the Settings tab'
    if ($script:EnvironmentInfo -and $script:EnvironmentInfo.Exists) { $environment = ('{0} (saved {1} by {2}): {3}' -f $script:EnvironmentInfo.Path, $script:EnvironmentInfo.Saved, $script:EnvironmentInfo.SavedBy, (Get-EnvironmentText)) }
    $facts = @(@('Version', $script:Config.ToolVersion), @('Companion of', $script:Config.CompanionOf), @('Author', $script:Config.Author), @('Support', $script:Config.SupportEmail), @('Website', $script:Config.Website), @('Source code', $script:Config.SourceUrl), @('This copy', $script:RootFolder), @('Running as', (Get-OperatorIdentity)))
    $consoles = @(
        [pscustomobject]@{ Console = 'Library'; Does = 'What the library holds against what the sources have: the Update Catalog per Windows build, the VMware package site per ESXi line, each fixed link. Check, download and verify, prune the superseded files, report.' }
        [pscustomobject]@{ Console = 'Products'; Does = 'Every product with its tick - fetched or left alone - and its source as a link to click and check. The installer links a person gives (Splunk Universal Forwarder).' }
        [pscustomobject]@{ Console = 'Schedule'; Does = 'This tool as a scheduled task: register, watch (the Task Scheduler and the last run), run now.' }
        [pscustomobject]@{ Console = 'Settings'; Does = 'What this site runs - the Windows builds, the .NET lines, the ESXi line and the VMware Tools rule - so the wrong update is never fetched. The library folder and retention, download limits and proxy, the task time and logon type, the log.' }
        [pscustomobject]@{ Console = 'About'; Does = 'This page.' })
    $copy = @(
        [pscustomobject]@{ Item = 'PowerShell'; Value = ('{0}, {1} language mode' -f $PSVersionTable.PSVersion, $ExecutionContext.SessionState.LanguageMode) }
        [pscustomobject]@{ Item = 'Execution policy'; Value = ('{0} in effect ({1})' -f (Get-ExecutionPolicy), $policy) }
        [pscustomobject]@{ Item = 'Started'; Value = $(if ($script:StartedFromText) { 'from text: the launcher and its building blocks were read from their files and run as text, which the execution policy does not check' } else { 'as a file' }) }
        [pscustomobject]@{ Item = 'Settings'; Value = $settings }
        [pscustomobject]@{ Item = 'This site'; Value = $environment }
        [pscustomobject]@{ Item = 'Library'; Value = ('{0} ({1})' -f $script:Config.LibraryFolder, (Get-LibraryPlaceText)) }
        [pscustomobject]@{ Item = "Today's log"; Value = (Get-PatchLogPath) }
        [pscustomobject]@{ Item = 'Computer'; Value = $env:COMPUTERNAME })
    $sections = @(
        @{ Heading = 'What it is'; Lines = @(
            ('The companion of the {0} for the side that has internet: it fetches the newest appropriate update of every product - Windows and .NET cumulative updates from the Microsoft Update Catalog, VMware Tools from the VMware package site, any product with a fixed link or an index page - checks every file (size, the published hash, the Authenticode signature, a SHA256 of its own) and keeps the library in the folders the WinRM toolkit reads.' -f $script:Config.CompanionOf),
            'The Settings tab names what this site runs and the Products tab what is fetched; nothing else is. The Schedule tab makes it a scheduled task. The library carries library-manifest.json and CHECKSUMS.txt so the other side can check every file by hand.',
            'Where this tool cannot run - PowerShell in ConstrainedLanguage mode under application control, or scripts blocked altogether - simple\Simple-Companion.html is the simple companion: one page in a browser that keeps the versions the site has deployed, links every product to the place it is published and checks each file fetched by hand.',
            ('Author: {0}.  Support: {1} - copy the address with the Copy support email button above.' -f $script:Config.Author, $script:Config.SupportEmail),
            ('Source code, issues and new versions: {0} - copy the link with the Copy GitHub link button above.' -f $script:Config.SourceUrl)) }
        @{ Heading = 'The consoles'; Rows = $consoles; Columns = @('Console', 'Does') }
        @{ Heading = 'This copy'; Rows = $copy; Columns = @('Item', 'Value') })
    if (@($Signatures).Count -gt 0) { $sections += @{ Heading = 'Code signature of the scripts'; Note = 'What PowerShell sees for each script. This tool signs nothing and asks for no elevation: it runs as an ordinary user. Not signed is the normal state and is fine where the execution policy allows local scripts.'; Rows = $Signatures; Columns = @('Light', 'File', 'Status', 'Meaning', 'SignedBy', 'ValidUntil') } }
    $sections += @{ Heading = 'Requirements'; Lines = @(
        'This PC: Windows PowerShell 5.1 with .NET Framework 4.x in FullLanguage mode, internet access (direct or through the system proxy) to catalog.update.microsoft.com, catalog.s.download.windowsupdate.com, packages.vmware.com and each vendor link, and the right to write the library folder.',
        'An ordinary user account is enough: nothing is installed, nothing asks for elevation, nothing is signed.',
        'The scheduled task runs as the account that registers it, at the Limited run level. Interactive (the default) runs while that account is logged on and needs nothing extra; S4U runs without a logon and stores no password, but has no network credentials and Windows may refuse it to an account without the right to log on as a batch job (Settings tab).') }
    return (New-DetailsHtml -Title ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion) -Subtitle ('the update library for the airgap, fetched and verified on the internet side - companion of the {0}' -f $script:Config.CompanionOf) -Console 'About' -Facts $facts -Sections $sections)
}

function Update-AboutPage {
    param([switch]$Recheck)
    if ($Recheck -or -not $script:Gui['AboutSignatures']) { $script:Gui['AboutSignatures'] = @(Get-ToolkitSignatureRows) }
    $page = Get-AboutHtml -Signatures $script:Gui['AboutSignatures']
    $script:Gui['AboutHtml'] = $page
    if ($script:Gui['AboutView']) { $script:Gui['AboutView'].DocumentText = $page }
}

function New-AboutConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'About' -Text 'About'
    $view = New-Object System.Windows.Forms.WebBrowser
    $view.Dock = 'Fill'; $view.ScriptErrorsSuppressed = $true; $view.AllowWebBrowserDrop = $false; $view.IsWebBrowserContextMenuEnabled = $true
    $view.Add_Navigating({ if ($_.Url -and $_.Url.Scheme -ne 'about') { $_.Cancel = $true; Set-GuiStatus 'This page opens no links - use Copy GitHub link' } })
    $tab.Controls.Add($view)
    $script:Gui['AboutView'] = $view
    $toolbar = New-ConsoleToolbar -Tab $tab
    $toolbar.Controls.Add((New-GuiButton -Text 'Copy GitHub link' -X 8 -Y 10 -W 140 -H 36 -ReadOnly -Tip $script:Config.SourceUrl -OnClick {
        Invoke-GuiAction -Name 'Copy GitHub link' -ReadOnly -Action { [System.Windows.Forms.Clipboard]::SetText([string]$script:Config.SourceUrl); Write-PatchLog "Copied to the clipboard: $($script:Config.SourceUrl)" 'OK' } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Copy support email' -X 153 -Y 10 -W 150 -H 36 -ReadOnly -Tip $script:Config.SupportEmail -OnClick {
        Invoke-GuiAction -Name 'Copy support email' -ReadOnly -Action { [System.Windows.Forms.Clipboard]::SetText([string]$script:Config.SupportEmail); Write-PatchLog "Copied to the clipboard: $($script:Config.SupportEmail)" 'OK' } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Check signatures again' -X 308 -Y 10 -W 170 -H 36 -ReadOnly -Tip 'Reads the code signature of every script again' -OnClick { Invoke-GuiAction -Name 'Check signatures' -ReadOnly -Action { Update-AboutPage -Recheck } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Save page as HTML...' -X 483 -Y 10 -W 160 -H 36 -ReadOnly -Tip 'This page as one HTML file' -OnClick {
        Invoke-GuiAction -Name 'Save About page' -ReadOnly -Action {
            if (-not (Test-GuiDialogAllowed 'The save dialog')) { return }
            $p = Save-HtmlAs -Html $script:Gui['AboutHtml'] -BaseName 'About' -Owner $script:Gui['Form'] -What 'page'
            if ($p) { Set-GuiStatus ('Saved: ' + $p) }
        } }))
    $null = New-ConsoleBanner -Tab $tab -Console 'About' -Title 'ABOUT' -Subtitle ('{0} {1}' -f $script:Config.ToolName, $script:Config.ToolVersion)
    $view.BringToFront()
    $script:Gui['OnFirstShow']['About'] = { Invoke-GuiAction -Name 'About page' -ReadOnly -Action { Update-AboutPage } }
}
