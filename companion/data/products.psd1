@{
    # =================================================================
    #  products.psd1  -  what the Download Toolkit fetches, from where,
    #  and who must have signed it.  Values only, never code.
    # -----------------------------------------------------------------
    #  Fields
    #    Id             the product's name in the tool, unique
    #    Name           shown in the window and the reports
    #    Enabled        $false = Off unless the site ticks it on the Products tab (the tick is saved per site, not here)
    #    Source         catalog       the Microsoft Update Catalog (Windows and .NET cumulative updates)
    #                   vmware-tools  packages.vmware.com/tools (the version the environment's ESXi line ships)
    #                   url           one fixed link that always serves the current version
    #                   index         a vendor index page read with LinkRegex (named groups file and version)
    #                   edge          Microsoft's Edge list for administrators: the newest release of Channel, with its SHA256
    #                   manual        a link the operator gives on the Products tab (a vendor page a person reads)
    #    PatchType      catalog only: Windows or DotNet - the folder under patches\ (the WinRM toolkit's layout)
    #    Folder         the others: the folder under software\ (the same Folder as in the WinRM toolkit's
    #                   data\software-packages.psd1, so the file lands where its package looks)
    #    Query          catalog: the search, {month} = yyyy-MM, {product} = the build's catalogue name, {arch}
    #    TitleMatch     catalog: the titles that are this product (a regular expression with the same placeholders;
    #                   a .NET product names a group "lines")
    #    Classification catalog: the classification column that is wanted (Security Updates); several = any of them
    #    Exclude        catalog: titles to leave out (Preview, Dynamic Update)
    #    Monthly        catalog: $true when a release comes every month - a check that finds none for the month that
    #                   must exist by now (CatalogStaleDays after Patch Tuesday) marks the row Stale and fails the run
    #    Lines          catalog: $true for .NET - the rollup must cover the .NET lines ticked on the Settings tab
    #    Builds         catalog: only these Windows builds, e.g. @(14393) (left out = every build ticked on the Settings tab)
    #    Url            url: the link
    #    IndexUrl       index: the page that names the current version (HTML, a checksum list, a JSON answer)
    #    LinkRegex      index: over that page; group "version", and group "file" = the link unless FileUrl or FilePage gives it
    #    FileUrl        index: the link as a template ({version}) when the page names only the version
    #    FilePage       index: a page of the file's own that holds the link ({version}); FilePageRegex (group "file") picks
    #                   it - for a link with a short-lived token; the page is read again just before the download
    #    ChecksumUrl    index, manual: where the vendor publishes the SHA256 ({version}, {file}, {url}); ChecksumRegex (group
    #                   "hash", {file} and {version} allowed) picks it, else the 64 hex characters on the line naming the file
    #    Channel        edge: Stable (the default)
    #    ManualPage     manual: the vendor page the operator reads, shown beside the link box
    #    LinkPattern    manual: what a given link must look like (group "version"); LinkExample is shown when it does not
    #    FilePattern    which files in the folder are this product (-like)
    #    VersionFrom    name (VersionRegex on the file name) | msi (ProductVersion inside) | file (the exe's version)
    #    Signers        the O= of the Authenticode signer must START with one of these; a download signed by anyone
    #                   else is deleted.  The same Signers as the WinRM toolkit's package.
    #    ReleaseNotes   the vendor's release notes, as a link shown in the details of a row (double-click) for a person
    #                   to open: {version}, {major}, {minor}, {patch} = the version and its first three parts;
    #                   {kb} / {kbnumber} = an update's KB5136487 / 5136487.  Left out = no link.  Never read by the tool.
    #    Note           where the rule comes from, what to check by hand
    #
    #  CatalogProducts  the Update Catalog's name for each Windows build (the number before the dot in 17763.1234)
    # =================================================================
    AsOf = '2026-11-16'

    Products = @(
        @{
            Id             = 'WindowsCU'
            Name           = 'Windows cumulative update'
            Enabled        = $true
            Source         = 'catalog'
            PatchType      = 'Windows'
            # one search per Windows build ticked on the Settings tab, e.g.
            #   2026-10 Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems
            Query          = '{month} Cumulative Update for {product} for {arch}-based Systems'
            # Server 2025 titles end "(KB5126646) (26100.33650)": the build after the KB is allowed
            TitleMatch     = '^\d{4}-\d{2} Cumulative Update for {product} for {arch}-based Systems \(KB\d+\)( \(\d+\.\d+\))?$'
            # the monthly security release (Security Updates) and an out-of-band release after it (Updates), which includes
            # it: the newest of the month is taken.  The optional preview is an "Updates" row too, but its title says
            # "Cumulative Update Preview", which TitleMatch and Exclude leave out.
            Classification = @('Security Updates', 'Updates')
            Exclude        = 'Preview|Dynamic Update'
            Monthly        = $true                 # one is released every month: an older month than there must be by now marks the row Stale
            FilePattern    = 'windows1*-kb*.msu'
            Signers        = @('Microsoft Corporation')
            ReleaseNotes   = 'https://support.microsoft.com/help/{kbnumber}'
            Note           = 'The newest cumulative update of the month is taken: the monthly security release, or an out-of-band release after it (each is cumulative, so the later one includes the earlier). The optional preview is left. The servicing stack is inside the cumulative update for Server 2019 and later (Server 2016: the separate product below). Server 2025: the catalogue lists two files, the month''s update and the checkpoint cumulative update it builds on (KB5043080) - both are fetched, the checkpoint once; DISM needs it beside the update only on a server that has not had it. The file name carries the SHA1 of the file; the tool checks it, the SHA256 the catalogue gives for Server 2025 files, the signature and the size.'
        }
        @{
            Id             = 'WindowsSSU'
            Name           = 'Windows servicing stack update'
            Enabled        = $true
            Source         = 'catalog'
            PatchType      = 'Windows'
            Builds         = @(14393)              # Server 2016 only: from Server 2019 on the servicing stack is inside the cumulative update
            #   2026-11 Servicing Stack Update for Windows Server 2016 for x64-based Systems (KB5131083)
            Query          = '{month} Servicing Stack Update for {product} for {arch}-based Systems'
            TitleMatch     = '^\d{4}-\d{2} Servicing Stack Update for {product} for {arch}-based Systems \(KB\d+\)$'
            Classification = 'Security Updates'
            Exclude        = 'Preview'
            FilePattern    = 'windows10.0-kb*-x64_*.msu'
            Signers        = @('Microsoft Corporation')
            ReleaseNotes   = 'https://support.microsoft.com/help/{kbnumber}'
            Note           = 'Server 2016 still gets its servicing stack as a file of its own, one a month since 2026 (about 13 MB): Microsoft asks for the latest one before the cumulative update, and the WinRM toolkit installs a servicing stack file first. No row appears unless build 14393 is ticked on the Settings tab.'
        }
        @{
            Id             = 'DotNetCU'
            Name           = '.NET Framework cumulative update'
            Enabled        = $true
            Source         = 'catalog'
            PatchType      = 'DotNet'
            Query          = '{month} Cumulative Update for .NET Framework {product} for {arch}'
            # "3.5, 4.7.2 and 4.8" is the group "lines"; a rollup that covers a line not ticked on the Settings tab is held
            TitleMatch     = '^\d{4}-\d{2} Cumulative Update for \.NET Framework (?<lines>[\d., and]+?) for {product} for {arch} \(KB\d+\)( \(\d+\.\d+\))?$'
            Classification = 'Security Updates'
            Exclude        = 'Preview'
            Lines          = $true
            FilePattern    = 'windows1*-kb*-ndp*.msu'
            Signers        = @('Microsoft Corporation')
            ReleaseNotes   = 'https://support.microsoft.com/help/{kbnumber}'
            Note           = 'A catalogue entry may hold one file per .NET line (Server 2022: "3.5, 4.8 and 4.8.1" is an ndp48 file and an ndp481 file, each its own KB): each file is a candidate on its own and only those for the ticked lines are fetched. The WinRM toolkit installs each like a Windows update. Not every month has a .NET release: the tool looks back CatalogMonthsBack months.'
        }
        @{
            Id             = 'VMwareTools'
            Name           = 'VMware Tools'
            Enabled        = $true
            Source         = 'vmware-tools'
            Folder         = 'VMwareTools'
            FilePattern    = 'VMware-tools-*-x*64.exe'
            VersionFrom    = 'name'
            VersionRegex   = '^VMware-tools-(\d+\.\d+\.\d+)-(\d+)-(?:x64|x86_64)\.exe$'
            Signers        = @('VMware', 'Broadcom')
            ReleaseNotes   = 'https://techdocs.broadcom.com/us/en/vmware-cis/vsphere/tools/{major}-{minor}-0/release-notes/vmware-tools-{major}{minor}{patch}-release-notes.html'
            Note           = 'The version map on the package site says which Tools each ESXi line ships; the ESXi version and the rule on the Settings tab decide (shipped / the newest of that line / latest / pinned). Check a new line against the Broadcom interoperability matrix before deploying it.'
        }
        @{
            Id             = 'Google Chrome'
            Name           = 'Google Chrome (enterprise MSI)'
            Enabled        = $false
            Source         = 'url'
            Folder         = 'Google Chrome'
            Url            = 'https://dl.google.com/dl/chrome/install/googlechromestandaloneenterprise64.msi'
            FilePattern    = 'googlechromestandaloneenterprise64*.msi'
            VersionFrom    = 'msi'
            Signers        = @('Google LLC')
            ReleaseNotes   = 'https://support.google.com/chrome/a/answer/7679408'
            Note           = 'An example of a fixed link: it always serves the current version. The file is kept as googlechromestandaloneenterprise64-<version>.msi (the version read from inside it), which the WinRM toolkit''s package pattern matches. Enable it when Chrome is part of the SOE.'
        }

        # ---- Software installed offline.  Sources, checksums and signers checked live on 2026-11-11 (SOURCES.md): every
        #      installer was fetched once, its SHA256 matched what the vendor publishes, its signature was valid.
        #      Folder = the folder under software\ - give the WinRM toolkit's package the same Folder. ----
        @{
            Id          = 'Edge'
            Name        = 'Microsoft Edge (Stable, enterprise MSI)'
            Enabled     = $true
            Source      = 'edge'
            Folder      = 'Microsoft Edge'
            Channel     = 'Stable'
            FilePattern = 'MicrosoftEdgeEnterprise*.msi'
            VersionFrom = 'msi'
            Signers     = @('Microsoft Corporation')
            ReleaseNotes = 'https://learn.microsoft.com/en-us/deployedge/microsoft-edge-relnote-stable-channel'
            Note        = 'Microsoft''s own list for administrators (edgeupdates.microsoft.com/api/products?view=enterprise) names the newest Stable release for Windows and the SHA256 of its MSI. The link''s file name is the same for every version, so the file is kept as MicrosoftEdgeEnterpriseX64-<version>.msi.'
        }
        @{
            Id          = 'PuTTY'
            Name        = 'PuTTY (64-bit MSI)'
            Enabled     = $true
            Source      = 'index'
            Folder      = 'PuTTY'
            # the PuTTY team's own download page (putty.software, the team's landing page, leads to it).  It links the
            # installer and the checksum list on the.earth.li, the team's download host: only a link to that host is taken
            IndexUrl    = 'https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html'
            LinkRegex   = 'href="(?<file>https://the\.earth\.li/~sgtatham/putty/[^"/]+/w64/putty-64bit-(?<version>[\d.]+)-installer\.msi)"'
            ChecksumUrl = 'https://the.earth.li/~sgtatham/putty/latest/sha256sums'
            FilePattern = 'putty-64bit-*-installer.msi'
            VersionFrom = 'msi'
            Signers     = @('Simon Tatham')
            ReleaseNotes = 'https://www.chiark.greenend.org.uk/~sgtatham/putty/changes.html'
            Note        = 'The PuTTY team''s own download page (chiark.greenend.org.uk, where putty.software leads) names the current release and links its installer and its sha256sums file. Both sit on the.earth.li: that is the download host the team''s page links, not a mirror. The checksum file''s PGP signature is not checked (no PGP in Windows PowerShell); HTTPS and the Authenticode signer are.'
        }
        @{
            Id            = 'WinSCP'
            Name          = 'WinSCP (MSI)'
            Enabled       = $true
            Source        = 'index'
            Folder        = 'WinSCP'
            IndexUrl      = 'https://winscp.net/eng/downloads.php'
            LinkRegex     = 'WinSCP-(?<version>\d+\.\d+(?:\.\d+)?)-Setup\.exe'
            # the link sits on the file's own page and carries a token that lives for minutes: read at the check, read again at the download
            FilePage      = 'https://winscp.net/download/WinSCP-{version}.msi/download'
            FilePageRegex = 'href="(?<file>https://cdn\.winscp\.net/files/WinSCP-{version}\.msi\?secure=[^"]+)"'
            ChecksumUrl   = 'https://winscp.net/download/{file}/download'
            ChecksumRegex = '(?is)SHA-?256[^0-9a-f]{0,80}(?<hash>[0-9a-f]{64})'
            FilePattern   = 'WinSCP-*.msi'
            VersionFrom   = 'msi'
            Signers       = @('Martin P')
            ReleaseNotes  = 'https://winscp.net/eng/docs/history'
            Note          = 'The downloads page names the current version; the file''s own page prints its SHA-256 and holds the download link. The signer is the author, Martin Prikryl (the certificate spells the name with a hacek, so only its start is matched).'
        }
        @{
            Id            = 'OpenSSH'
            Name          = 'OpenSSH for Windows (x64 MSI)'
            Enabled       = $false
            Source        = 'index'
            Folder        = 'OpenSSH'
            IndexUrl      = 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
            LinkRegex     = '"browser_download_url":\s*"(?<file>https://github\.com/PowerShell/Win32-OpenSSH/releases/download/[^"]+/OpenSSH-Win64-v(?<version>[\d.]+)\.msi)"'
            ChecksumUrl   = 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
            ChecksumRegex = '"name":\s*"{file}"(?s:.*?)"digest":\s*"sha256:(?<hash>[0-9a-f]{64})"'
            FilePattern   = 'OpenSSH-Win64-v*.msi'
            VersionFrom   = 'msi'
            Signers       = @('Microsoft Corporation')
            ReleaseNotes  = 'https://github.com/PowerShell/Win32-OpenSSH/releases'
            Note          = 'Microsoft''s own builds on GitHub (PowerShell/Win32-OpenSSH); the release list gives the SHA256 of every file. These builds are named "Preview": the supported OpenSSH is the one inside Windows Server (an optional feature on 2019 and 2022, installed on 2025, patched by the cumulative update). Not ticked for that reason: tick it only where a newer OpenSSH than the in-box one is required.'
        }
        @{
            Id            = 'Wireshark'
            Name          = 'Wireshark (x64 MSI)'
            Enabled       = $true
            Source        = 'index'
            Folder        = 'Wireshark'
            IndexUrl      = 'https://www.wireshark.org/download/win64/'
            # stable releases only: an even minor number (4.6.x).  The folder also holds development releases (4.7.x) -
            # on 2026-11-11 the newest file there was 4.7.4 while stable was 4.6.9
            LinkRegex     = 'href="(?<file>Wireshark-(?<version>\d+\.\d*[02468]\.\d+)-x64\.msi)"'
            ChecksumUrl   = 'https://www.wireshark.org/download/SIGNATURES-{version}.txt'
            ChecksumRegex = 'SHA256\({file}\)=(?<hash>[0-9a-f]{64})'
            FilePattern   = 'Wireshark-*-x64.msi'
            VersionFrom   = 'msi'
            Signers       = @('Wireshark Foundation')
            ReleaseNotes  = 'https://www.wireshark.org/docs/relnotes/wireshark-{version}.html'
            Note          = 'The project''s download folder and its SIGNATURES file (sizes and SHA256 of every file). Installed silently, Wireshark comes without Npcap, so it reads captures but cannot capture: see Npcap below.'
        }
        @{
            Id          = 'Npcap'
            Name        = 'Npcap (free edition)'
            Enabled     = $false
            Source      = 'index'
            Folder      = 'Npcap'
            IndexUrl    = 'https://npcap.com/dist/'
            LinkRegex   = 'href="(?<file>npcap-(?<version>[\d.]+)\.exe)"'
            FilePattern = 'npcap-*.exe'
            VersionFrom = 'name'
            Signers     = @('Nmap Software')
            ReleaseNotes = 'https://npcap.com/changelog'
            Note        = 'OFF ON PURPOSE. npcap.com: the free edition "may be used (but not externally redistributed) on up to 5 systems", and only the paid Npcap OEM edition installs silently - the WinRM toolkit installs silently, so it cannot deploy this file. For more than five servers buy Npcap OEM (its download is behind a customer login: place the file by hand), or capture with the built-in pktmon. No hash is published; the signature is the check.'
        }
        @{
            Id          = 'NotepadPP'
            Name        = 'Notepad++ (x64 MSI)'
            Enabled     = $true
            Source      = 'index'
            Folder      = 'Notepad++'
            IndexUrl    = 'https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest'
            LinkRegex   = '"browser_download_url":\s*"(?<file>https://github\.com/notepad-plus-plus/notepad-plus-plus/releases/download/[^"]+/npp\.(?<version>[\d.]+)\.Installer\.x64\.msi)"'
            ChecksumUrl = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v{version}/npp.{version}.checksums.sha256'
            FilePattern = 'npp.*.Installer.x64.msi'
            VersionFrom = 'msi'
            Signers     = @('NOTEPAD++')
            ReleaseNotes = 'https://notepad-plus-plus.org/downloads/v{version}/'
            Note        = 'The project''s GitHub release: the installer and the checksums file published with it. Taken from the release, never from the program''s own updater.'
        }
        @{
            Id            = 'FirefoxESR'
            Name          = 'Firefox ESR (x64 MSI, en-US)'
            Enabled       = $true
            Source        = 'index'
            Folder        = 'Firefox ESR'
            IndexUrl      = 'https://product-details.mozilla.org/1.0/firefox_versions.json'
            LinkRegex     = '"FIREFOX_ESR":\s*"(?<version>\d+\.\d+(?:\.\d+)?)esr"'
            FileUrl       = 'https://archive.mozilla.org/pub/firefox/releases/{version}esr/win64/en-US/Firefox%20Setup%20{version}esr.msi'
            ChecksumUrl   = 'https://archive.mozilla.org/pub/firefox/releases/{version}esr/SHA256SUMS'
            ChecksumRegex = '(?m)^(?<hash>[0-9a-f]{64})\s+win64/en-US/{file}\s*$'
            FilePattern   = 'Firefox Setup *esr.msi'
            VersionFrom   = 'msi'
            Signers       = @('Mozilla Corporation')
            ReleaseNotes  = 'https://www.firefox.com/en-US/firefox/{version}/releasenotes/'
            Note          = 'Mozilla''s version list names the current ESR (the release line for managed fleets); the file and its SHA256SUMS are in that release''s folder on archive.mozilla.org. For another language change en-US in FileUrl and ChecksumRegex.'
        }
        @{
            Id          = 'SplunkUF'
            Name        = 'Splunk Universal Forwarder (x64 MSI)'
            Enabled     = $true
            Source      = 'manual'
            Folder      = 'Splunk Universal Forwarder'
            ManualPage  = 'https://www.splunk.com/en_us/download/universal-forwarder.html'
            LinkPattern = '^https://download\.splunk\.com/products/universalforwarder/releases/(?<version>\d+(?:\.\d+){1,3})/windows/splunkforwarder-[\d.]+-[0-9a-f]+-(?:windows-x64|x64-release)\.msi$'
            LinkExample = 'https://download.splunk.com/products/universalforwarder/releases/<version>/windows/splunkforwarder-<version>-<build>-windows-x64.msi'
            ChecksumUrl = '{url}.sha256'
            FilePattern = 'splunkforwarder-*.msi'
            VersionFrom = 'msi'
            Signers     = @('Splunk')
            ReleaseNotes = 'https://help.splunk.com/en/splunk-enterprise/forward-and-process-data/universal-forwarder-manual/{major}.{minor}/release-notes/fixed-issues'
            Note        = 'BY HAND: the forwarder must suit the indexers, so the Splunk administrator picks the version, and Splunk''s download page is read by a person, never by this tool. Paste the installer link on the Products tab; the tool fetches it and checks it against the .sha256 file Splunk publishes beside it. Without a link the row says "By hand" and nothing is fetched.'
        }

        # ---- a template for a vendor index page: copy it above, remove the #, fill it in ----
        # @{
        #     Id          = 'ExampleAgent'
        #     Name        = 'Example Agent'
        #     Enabled     = $true
        #     Source      = 'index'
        #     Folder      = 'ExampleAgent'
        #     IndexUrl    = 'https://downloads.example.com/agent/windows/'
        #     LinkRegex   = 'href="(?<file>ExampleAgent-(?<version>\d+\.\d+\.\d+)-x64\.msi)"'
        #     ChecksumUrl = 'https://downloads.example.com/agent/windows/{file}.sha256'   # optional: a text page with the SHA256
        #     FilePattern = 'ExampleAgent-*-x64.msi'
        #     VersionFrom = 'msi'
        #     Signers     = @('Example Corporation')
        #     ReleaseNotes = 'https://downloads.example.com/agent/release-notes/{version}.html'   # optional
        #     Note        = 'where the rule comes from'
        # }
    )

    # The Update Catalog's product names, by Windows build.  Server 2022 is listed as "version 21H2", Server 2025 as
    # "version 24H2" (all four checked against the live catalogue on 2026-11-11: the 2026-11 updates were found).
    CatalogProducts = @{
        '14393' = 'Windows Server 2016'
        '17763' = 'Windows Server 2019'
        '20348' = 'Microsoft server operating system version 21H2'
        '26100' = 'Microsoft server operating system version 24H2'
    }
}
