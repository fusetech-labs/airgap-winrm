# Download sources and integrity checks - research record

Checked live from the toolkit PC on **2026-11-11** with Windows PowerShell 5.1 over TLS 1.2, the way the Download
Toolkit itself talks to the internet. "Verified" in this record means: the installer was downloaded once, its SHA256
compared with the value the vendor publishes, and its Authenticode signature read. Nothing was installed or run.
Links, version numbers and signer names are what the sources served on that day; check them again before relying on them.

## 1. Windows and .NET cumulative updates (Microsoft Update Catalog)

### What a real run did

The companion was run for real into a scratch library with all four server builds, all three .NET lines and ESXi 8.0
ticked. First run: 13 files, 6.3 GB, 18 minutes, none failed. Second run straight after: nothing downloaded, 13
current, 60 seconds (the library hashed again).

| For | Update | Size | Compared with what the source publishes |
|---|---|---|---|
| Server 2016 | KB5131291, 2026-11 cumulative update | 1.81 GB | size, SHA1, signature |
| Server 2016 | KB5131083, 2026-11 servicing stack update | 12.4 MB | size, SHA1, signature |
| Server 2019 | KB5131085, 2026-11 cumulative update | 872 MB | size, SHA1, signature |
| Server 2022 | KB5131090, 2026-11 cumulative update | 589 MB | size, SHA1, signature |
| Server 2025 | KB5131080, 2026-11 cumulative update | 1.94 GB | size, SHA1, SHA256, signature |
| Server 2025 | KB5043080, the checkpoint it builds on | 509 MB | size, SHA1, SHA256, signature |
| Server 2016 | KB5127684, 2026-10 .NET Framework 4.8 | 59.4 MB | size, SHA1, signature |
| Server 2019 | KB5127666, 2026-10 .NET Framework 3.5 and 4.7.2 | 87.3 MB | size, SHA1, signature |
| Server 2019 | KB5127685, 2026-10 .NET Framework 3.5 and 4.8 | 92.1 MB | size, SHA1, signature |
| Server 2022 | KB5127687, 2026-10 .NET Framework 3.5 and 4.8 | 76.4 MB | size, SHA1, signature |
| Server 2022 | KB5127693, 2026-10 .NET Framework 3.5 and 4.8.1 | 92.1 MB | size, SHA1, signature |
| Server 2025 | KB5127690, 2026-10 .NET Framework 3.5 and 4.8.1 | 92.3 MB | size, SHA1, SHA256, signature |
| ESXi 8.0 | VMware Tools 12.5.4 | 106.8 MB | size, signature (no hash published) |

There was no .NET Framework release for 2026-11 on the day; the tool looked back a month, as designed.

Every file passed: the size the catalogue announced, the SHA1 the catalogue publishes (the link's digest and the
40 hex characters in the file name must agree with the file), the SHA256 where the catalogue gives one, and a valid
Authenticode signature by Microsoft Corporation. A second run straight after found everything current: nothing was
downloaded again and nothing was removed.

The November 2026 updates (released 2026-11-10) were found the day after release for all four server builds.

### Where the checksum comes from

* The catalogue's download dialog (`DownloadDialog.aspx`, the same form post the Download button sends) returns, per
  file: `url`, `fileName`, `digest` (SHA1, base64) and `sha256` (base64).
* `digest` is always filled and equals the 40 hex characters in the file name
  (`windows10.0-kb5131085-x64_5b4a0d0a...2054.msu`). The tool requires the two to agree before it downloads, then
  compares the file.
* `sha256` is **empty** for files on `catalog.s.download.windowsupdate.com` (Server 2016, 2019, 2022, .NET) and
  **filled** for files on `catalog.sf.dl.delivery.mp.microsoft.com` (Server 2025). Where it is filled the tool now
  compares it too.
* Both hosts are HTTPS. The Authenticode signature is checked on every file whatever the hash says.

So for Server 2016 to 2022 the source-published checksum is SHA1 only. SHA1 is weak against a deliberate collision,
which is why the signature check matters: a file must also be signed by Microsoft. The tool records its own SHA256
of every file in `library-manifest.json` and `CHECKSUMS.txt` for the check on the far side of the air gap.

### Faults found by the live run, and fixed

1. **Server 2025 was fetched wrongly.** The catalogue lists two files for the month's update: the update
   (KB5131080, 1.9 GB) and the checkpoint cumulative update it builds on (KB5043080, 0.5 GB). The tool took "the
   first", which was the checkpoint, and would then have refused it because the size did not match the row's total.
   Now every file is a candidate with its own size; the checkpoint is fetched once and kept.
2. **The catalogue's SHA256 was never read** (the page calls the field `sha256`; the code looked for `sha`).
3. **Pruning deleted a sibling file.** With two .NET rollups for one build (Server 2022: one for 4.8, one for 4.8.1)
   each download removed the other, so every run would have downloaded one of them again. Files are now pruned per
   product, build and .NET line; a checkpoint is never pruned by the monthly update.
4. **A search could lose its row to the page break.** The catalogue shows 25 rows a page and the Server 2025 search
   returns 26. Every page is read now.
5. **A page read was never retried.** A timeout, an HTTP 5xx or the catalogue's own "error number 8DDD0010" page
   failed the check for that build until the next run. Page reads are now tried again as often as downloads are.
6. **Server 2016 needs its servicing stack update first**, and it is a separate file, one a month in 2026 (13 MB).
   A new product, *Windows servicing stack update*, fetches it when build 14393 is ticked. Server 2019 and later
   carry the servicing stack inside the cumulative update.
7. A Server 2025 title ends "(KB5131080) (26100.33822)"; the KB was not read from it. Fixed.

### Known limits (by design, or not testable here)

* **Out-of-band releases (changed 2026-11-16).** Until then only the month's row classified *Security Updates* was
  taken, and a later row classified *Updates* was left as "the optional preview". That reading was wrong: Microsoft's
  release list (`https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info`, read on
  2026-11-16) shows no preview release for Windows Server since November 2022, and names those later rows as
  out-of-band releases - in 2026 for Server 2022 in January (two), February, April, September, October and November.
  On 2026-11-16 the tool's pick equalled Microsoft's "2026-11 B" release for all four builds (KB5131291, KB5131085,
  KB5131090, KB5131080), while the list's newest entry for 2019, 2022 and 2025 was the out-of-band release of
  2026-11-13 (KB5136490, KB5136487, KB5136489), which the tool neither fetched nor showed. Now every cumulative
  update of the month that is not a preview counts and the newest is taken: by the OS build where the titles carry
  one (Server 2025), else by the catalogue's date, then by the KB number. A title that says "Cumulative Update
  Preview" is still left, should previews return.
* **A month that stops matching (added 2026-11-16).** A month whose rows no longer match the title pattern or the
  classification used to fall back to the month before without a word, for as long as `CatalogMonthsBack` allows.
  The Windows cumulative update is now marked as monthly: once Patch Tuesday (the second Tuesday) is
  `CatalogStaleDays` (3) behind and only an older month is found, the row says *Stale*, the run fails, and the
  reason says that Microsoft may have changed the catalogue and that the tool may need an update. .NET and the
  Server 2016 servicing stack are not marked monthly: neither comes every month.
* **The WinRM toolkit side of the Server 2025 checkpoint is not tested.** A Server 2025 installed from release media
  (26100.1742 or later) should already have KB5043080, so the month's update installs on its own (background
  knowledge, not checked on a server). The checkpoint file sits in `patches\Windows` for the rare server that lacks
  it; how the O/S Patching console lists and orders it needs a look on a real Server 2025.
* **.NET Framework 4.7.2 on Server 2016** has no rollup of its own in the catalogue (the search returned only the
  4.8 rollup). Its fixes come inside the Windows cumulative update (background knowledge).
* **The source-published checksum is SHA1 for most files**, see above. That is the catalogue's choice, not the tool's.

## 2. Offline-installed software

| Product | Official source and how the current version is found | What the vendor publishes for integrity | Signer (verified) | In the companion (2026-11-11) |
|---|---|---|---|---|
| Microsoft Edge (Stable, x64 MSI) | `https://edgeupdates.microsoft.com/api/products?view=enterprise` (JSON): product *Stable*, platform *Windows*, architecture *x64*, the newest `ProductVersion`; its `Artifacts[]` entry gives `Location`, `Hash`, `HashAlgorithm` (SHA256) and `SizeInBytes` | SHA256 in the API | Microsoft Corporation | In the catalogue (`edge` source): hash checked |
| VMware Tools | `https://packages.vmware.com/tools/` (already in the companion: version map, releases index, x64 folder) | Nothing beside the `.exe`. Only the ISO has a `.sha` (a binary VMware hash file, not a hex line) and a `.sig` | Broadcom Inc | Yes (as now): size and signature |
| PuTTY (64-bit MSI) | The team's download page `https://www.chiark.greenend.org.uk/~sgtatham/putty/latest.html` names the release and links the installer on the team's download host: `https://the.earth.li/~sgtatham/putty/latest/` redirects to the current version; the installer is `w64/putty-64bit-<ver>-installer.msi` | `sha256sums` (also md5, sha1, sha512) in the same folder, each with a `.gpg` signature; a `.gpg` beside every file | Simon Tatham | In the catalogue: read from the team's page, hash checked |
| WinSCP (MSI or Setup.exe) | `https://winscp.net/eng/downloads.php` names the version; the file's own page `https://winscp.net/download/<file>/download` holds the link | SHA-256 and SHA-1 printed on the file's page | Martin Prikryl (the certificate spells it with a hacek on the r) | In the catalogue: hash checked. The link carries a short-lived token (`cdn.winscp.net/files/<file>?secure=...`), so the file's page is read again just before the download |
| OpenSSH for Windows (x64 MSI) | GitHub `PowerShell/Win32-OpenSSH`, `https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest` | SHA256 `digest` per release asset in the GitHub API | Microsoft Corporation | In the catalogue, not ticked: hash checked |
| Wireshark (x64 MSI or EXE) | `https://www.wireshark.org/download/win64/` (folder listing); stable releases have an even minor number | `https://www.wireshark.org/download/SIGNATURES-<ver>.txt`: sizes, SHA256 and SHA1 of every file, PGP clear-signed | Wireshark Foundation | In the catalogue: hash checked, with a stable-only rule |
| Npcap | `https://npcap.com/dist/npcap-<ver>.exe` | Nothing published | Nmap Software LLC | In the catalogue, switched off, see below |
| Notepad++ (x64 MSI or EXE) | GitHub `notepad-plus-plus/notepad-plus-plus`, `.../releases/latest` | Release asset `npp.<ver>.checksums.sha256` (with a `.sig`), a `.sig` per installer, and the GitHub asset digest | NOTEPAD++ | In the catalogue: hash checked |
| Firefox ESR (x64 MSI) | `https://product-details.mozilla.org/1.0/firefox_versions.json` (`FIREFOX_ESR`); files under `https://archive.mozilla.org/pub/firefox/releases/<ver>esr/` | `SHA256SUMS` and `SHA512SUMS` in the release folder, with `SHA256SUMS.asc` (PGP) | Mozilla Corporation | In the catalogue: the version from Mozilla's list, the link from a template, hash checked |

Every row except Npcap and VMware Tools has a vendor-published SHA256, and every one of those matched the
downloaded file. All eleven installers tested carry a valid, time-stamped Authenticode signature. Section 6 has the
evidence.

### Notes that change what to do

* **Wireshark: the newest file is not the stable one.** The download folder also holds development releases. On
  2026-11-11 the newest file was 4.7.4 (development) while stable was 4.6.9. A rule that takes "the newest" fetches
  the wrong one; the rule must keep to even minor numbers.
* **Npcap cannot be deployed by this toolkit.** npcap.com says the free edition "may be used (but not externally
  redistributed) on up to 5 systems", and the silent installer is part of the paid Npcap OEM edition. The WinRM
  toolkit installs silently as SYSTEM, so the free installer cannot be used, and a server estate is over five
  systems. Wireshark installed silently therefore comes without live capture. Either buy Npcap OEM (its download is
  behind a customer login) or capture with the built-in `pktmon` and read the capture in Wireshark.
* **OpenSSH: the GitHub builds are named "Preview".** The supported OpenSSH for Windows Server is the in-box one:
  an optional feature on Server 2019 and 2022, installed by default on Server 2025, and patched by the Windows
  cumulative update. Fetch the GitHub MSI only where a newer version than the in-box one is required. (Background
  knowledge, not re-checked today.) Since 2026-11-16 the entry is not ticked until the site ticks it.
* **PuTTY: the files are not on the address people know.** The team's site is
  `https://www.chiark.greenend.org.uk/~sgtatham/putty/`; `https://putty.software/` is the team's own landing page and
  leads there (the site's news of 2025-08-14: "run by the PuTTY team itself, and not by a third party"). The download
  page links every file on `the.earth.li`. Checked on 2026-11-16. The catalogue reads the team's page, so the source
  an operator sees and clicks is the one they can recognise, and takes only the link that page gives to
  `the.earth.li`.
* **Notepad++: take the installer from the GitHub release**, with its checksum file, not from the program's own
  updater. In early 2026 the project reported that its update traffic had been redirected through its former
  hosting provider during 2025. (Background knowledge, not re-checked today.)
* **PGP signatures are not checked.** PuTTY, Wireshark, Firefox and Notepad++ sign their checksum files with PGP.
  Windows PowerShell has no PGP, so the tool relies on the checksum file arriving over HTTPS from the vendor's own
  host, plus the Authenticode signer. Checking the PGP signature would need `gpg.exe` beside the tool.
* **A fixed link gives no published hash.** Edge and Firefox ESR also have "always current" links
  (`https://go.microsoft.com/fwlink/?LinkID=2093437` and Mozilla's `download.mozilla.org/?product=firefox-esr-msi-latest-ssl`),
  and both passed a trial through the `url` source, but then the checks are size and signature only. The catalogue
  entries use the vendor's SHA256 instead (section 4).
* **GitHub's API allows 60 anonymous requests an hour per address.** One check a day per product is far inside it.

## 3. In-place upgrades of agents

| Agent | Can the internet side fetch it without a login? | Vendor's upgrade path | Verdict |
|---|---|---|---|
| Splunk Universal Forwarder | Yes. `https://download.splunk.com/products/universalforwarder/releases/<ver>/windows/splunkforwarder-<ver>-<build>-windows-x64.msi`, with `.sha256`, `.sha512` and `.md5` beside it | The MSI run over the top; Splunk has no server push for the forwarder binary | **In the catalogue, by hand**: the operator pastes the release link, the tool fetches it and checks it against the `.sha256` beside it |
| Tenable Nessus Agent | Yes. `https://www.tenable.com/downloads/api/v2/pages/nessus-agents` (JSON: file, version, size, md5, sha256, sha512); the file at `.../nessus-agents/files/<file>` | Nessus Manager pushes updates to its agents; offline, the manager is fed `nessus-agent-updates-<ver>.tar.gz`. The MSI run over the top also works | **Left to Nessus Manager** (decided 2026-11-11): the source is public and verified if that ever changes |
| Trellix Agent and Endpoint Security | No. Product downloads need a grant number or a Trellix login | ePO deploys from its Main Repository; the agent package (FramePkg.exe) is made by the site's own ePO with that server's keys | **Not possible, and the wrong path**: a person downloads the ePO packages, ePO deploys them |
| ManageEngine OpManager agent | No. The agent comes from the site's OpManager server (Settings, Discovery, Deploy Agent) | The server upgrades its agents after it is upgraded itself (Agent Auto Upgrade) | **Wrong path for the agent**. The server's service pack (`.ppm`) is public with a SHA256 on the service pack page |
| ManageEngine ADSelfService Plus login agent | No. The MSI is in the server's own `bin` folder (`ADSelfServicePlusClientSoftware.msi`) | After a server service pack, the console reinstalls the agent on the machines (GINA/Mac/Linux Installation, Reinstall) | **Nothing to fetch**: the new MSI is already inside the air gap, in the server's folder |

### Verified here

* **Splunk Universal Forwarder 10.6.1.1** (386 MB): SHA256 and SHA512 from the `.sha256` and `.sha512` files matched
  the download; signature valid, signer **Splunk LLC**.
* **Nessus Agent 11.2.3** (19.8 MB): SHA256 and SHA512 from the API matched; signature valid, signer **TENABLE, INC.**
  The API marks the file `requires_auth: false`; the plugins archive in the same API needs a token.

### Read from vendor documentation (not re-checked by hand)

* Splunk, *Upgrade the universal forwarder*: `msiexec.exe /i <msi> AGREETOLICENSE=Yes /quiet`; "the installer updates
  the software without changing its configuration"; "There is no means of downgrading to a previous version";
  forwarders on the same major release as the indexers are compatible, otherwise check the compatibility matrix.
* Tenable, *Upgrade Nessus Agent* and *Air-gapped environments*: the agent "automatically retrieves updates from its
  manager"; offline, "perform an offline software update (nessus-agent-updates-X.X.X.tar.gz on the Tenable Downloads
  site) on your Tenable Nessus Manager"; by hand, `msiexec /i NessusAgent-<version>.msi /qn`.
* Trellix, *Download Trellix Agent and the extension package*, *Check in packages manually*, *Install or upgrade
  Trellix Agent*: grant number and registered email; packages are checked in to the Main Repository; the agent is
  upgraded by an ePO client task.
* ManageEngine OpManager, *Agent installation* and *Agent upgrade*: the agent zip is downloaded from the server and
  holds the server's details; "When you upgrade OpManager, agents are upgraded automatically to the compatible
  version".
* ManageEngine ADSelfService Plus, *How to update the login agent*: select the machines and click Reinstall; the
  installation key shown in the console is "similar to a password".

### What an in-place agent upgrade through the toolkit would and would not give

* **Benefit** for Splunk and Nessus: the same verified, signed, recorded file handling as every other package, a
  change record per server, and no hand-carried installers.
* **Risk** for both: the agent version must suit the server it reports to. "The newest" is the wrong rule. The
  version must be pinned to what the Splunk or Tenable administrator approves, the way VMware Tools is pinned to the
  ESXi line.
* For Nessus, feeding the manager the offline update file is the vendor's intended route, and the manager can pull
  an agent back to its own plan's version.
* For Trellix, OpManager and ADSelfService Plus the management server is the source of the agent. The toolkit could
  at most deploy an MSI the administrator copies out of that server; the Download Toolkit has nothing to fetch.

### The Splunk download page

`https://www.splunk.com/en_us/download/universal-forwarder.html` names the current version, link and checksum links
in its HTML. It answered **403** to the Download Toolkit's own user agent and answered a curl and a browser user
agent. During this research the page was read with a curl user agent to see what it holds; the tool itself never
does that. The download host itself serves the installer and its checksum files to the toolkit's own user agent.

A shipped tool should not pretend to be another client to get past a site's filter. **Decided 2026-11-11: by
hand.** The tool reads no Splunk page. The Products tab has a box for the installer link, with the page to find it
on beside it; the Splunk administrator picks the version, the operator pastes the link, and the tool fetches it and
checks it against `<link>.sha256` and the signer. Without a link the row says *By hand* and no run fails.

## 4. What was added to the companion on 2026-11-11

| Addition | For | Where |
|---|---|---|
| A link template (`FileUrl` with `{version}`) | Firefox ESR: Mozilla's list names the version, the file and its SHA256SUMS are elsewhere | index source |
| A page of the file's own (`FilePage`, `FilePageRegex`), read again just before the download | WinSCP: the link carries a token that lives for minutes | index source |
| The Edge list for administrators (JSON: newest *Stable*, Windows, the architecture, its MSI and SHA256) | Microsoft Edge | new source `edge` |
| A link given by hand, checked for shape, with the vendor's checksum file beside it (`ChecksumUrl = '{url}.sha256'`) | Splunk Universal Forwarder | new source `manual`, a box on the Products tab, the verdict *By hand* |

Still open:

* **A matching package in the WinRM toolkit** (`data\software-packages.psd1`: folder, silent switches, signer) for
  every new product. The companion fills `software\<Folder>`; the Software console registers what it finds there.
* **A version rule per product** (a pinned version, or one release line). Only VMware Tools has one. OpenSSH, Wireshark
  and the others take the newest stable release.
* **PGP signatures** of checksum files are not checked.

## 5. The catalogue entries and their real run

The entries are in `data\products.psd1`: Edge, PuTTY, WinSCP, Wireshark, Notepad++ and Firefox ESR switched on,
OpenSSH switched off (the in-box one is the supported one), Npcap switched off with the licence reason, Splunk
Universal Forwarder by hand. `Folder` must match the WinRM toolkit's package folder.

Changed on 2026-11-16: OpenSSH was switched on until then; and PuTTY's index was the `sha256sums` file on
`the.earth.li`, now it is the team's download page (section 2). The link the page gives is the one the run below
fetched.

Since 2026-11-15 the on / off of an entry is a tick on the Products tab, saved per site in
`settings\environment.json`; `Enabled` in the file is what applies while nobody has ticked otherwise. The same tab
shows each entry's source address as a link to click, so the operator can compare it with the vendor's own site.

A real run of those entries from the shipped catalogue into a scratch library (the Splunk link pasted as an operator
would): 8 files, 780 MB, 126 seconds, none failed; every one compared with the vendor's SHA256 and its signer. A
second run fetched nothing and found all 8 current.

The first trial, through the adapters as they were before the additions, used these entries. The two fixed-link ones
are superseded by the hash-checked entries in the catalogue and are kept here for reference.

```powershell
@{
    Id = 'PuTTY'; Name = 'PuTTY (64-bit MSI)'; Enabled = $false; Source = 'index'; Folder = 'PuTTY'
    IndexUrl    = 'https://the.earth.li/~sgtatham/putty/latest/sha256sums'
    LinkRegex   = '(?<file>w64/putty-64bit-(?<version>[\d.]+)-installer\.msi)'
    ChecksumUrl = 'https://the.earth.li/~sgtatham/putty/latest/sha256sums'
    FilePattern = 'putty-64bit-*-installer.msi'; VersionFrom = 'msi'; Signers = @('Simon Tatham')
}
@{
    Id = 'Wireshark'; Name = 'Wireshark (x64 MSI)'; Enabled = $false; Source = 'index'; Folder = 'Wireshark'
    IndexUrl      = 'https://www.wireshark.org/download/win64/'
    # stable releases only: an even minor number (4.6.x); the folder also holds development releases (4.7.x)
    LinkRegex     = 'href="(?<file>Wireshark-(?<version>\d+\.\d*[02468]\.\d+)-x64\.msi)"'
    ChecksumUrl   = 'https://www.wireshark.org/download/SIGNATURES-{version}.txt'
    ChecksumRegex = 'SHA256\({file}\)=(?<hash>[0-9a-f]{64})'
    FilePattern = 'Wireshark-*-x64.msi'; VersionFrom = 'msi'; Signers = @('Wireshark Foundation')
}
@{
    Id = 'NotepadPP'; Name = 'Notepad++ (x64 MSI)'; Enabled = $false; Source = 'index'; Folder = 'Notepad++'
    IndexUrl    = 'https://api.github.com/repos/notepad-plus-plus/notepad-plus-plus/releases/latest'
    LinkRegex   = '"browser_download_url":\s*"(?<file>https://github\.com/notepad-plus-plus/notepad-plus-plus/releases/download/[^"]+/npp\.(?<version>[\d.]+)\.Installer\.x64\.msi)"'
    ChecksumUrl = 'https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v{version}/npp.{version}.checksums.sha256'
    FilePattern = 'npp.*.Installer.x64.msi'; VersionFrom = 'msi'; Signers = @('NOTEPAD++')
}
@{
    Id = 'OpenSSH'; Name = 'OpenSSH for Windows (x64 MSI)'; Enabled = $false; Source = 'index'; Folder = 'OpenSSH'
    IndexUrl      = 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
    LinkRegex     = '"browser_download_url":\s*"(?<file>https://github\.com/PowerShell/Win32-OpenSSH/releases/download/[^"]+/OpenSSH-Win64-v(?<version>[\d.]+)\.msi)"'
    ChecksumUrl   = 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
    ChecksumRegex = '"name":\s*"{file}"(?s:.*?)"digest":\s*"sha256:(?<hash>[0-9a-f]{64})"'
    FilePattern = 'OpenSSH-Win64-v*.msi'; VersionFrom = 'msi'; Signers = @('Microsoft Corporation')
}
@{
    Id = 'Edge'; Name = 'Microsoft Edge (enterprise MSI, fixed link)'; Enabled = $false; Source = 'url'; Folder = 'Microsoft Edge'
    Url = 'https://go.microsoft.com/fwlink/?LinkID=2093437'
    FilePattern = 'MicrosoftEdgeEnterpriseX64*.msi'; VersionFrom = 'msi'; Signers = @('Microsoft Corporation')
}
@{
    Id = 'FirefoxESR'; Name = 'Firefox ESR (x64 MSI, fixed link)'; Enabled = $false; Source = 'url'; Folder = 'Firefox ESR'
    Url = 'https://download.mozilla.org/?product=firefox-esr-msi-latest-ssl&os=win64&lang=en-US'
    FilePattern = 'Firefox Setup *.msi'; VersionFrom = 'msi'; Signers = @('Mozilla Corporation')
}
```

A Nessus Agent entry failed the same trial: the index adapter built the link beside the API page and got HTTP 404.

## 6. Evidence (2026-11-11)

| File | Version read from the file | SHA256 of the download | Published hash | Signature |
|---|---|---|---|---|
| MicrosoftEdgeEnterpriseX64.msi | 157.0.4341.46 | `0bdba24e2d64a4de639468cb1b196d2540d2b50adf198b637f43cf563852bb58` | matches (Edge API) | Valid, Microsoft Corporation |
| VMware-tools-13.1.5-25544008-x64.exe | 13.1.5.0 | `104f99acf67f09cb92586eeab9fa6defa49d9f7556ba3cf1a12dda9dcfc4b871` | none published | Valid, Broadcom Inc |
| putty-64bit-0.85-installer.msi | 0.85.0.0 | `2213ebacf962b709411d654a40087508a694756bc4e41c5a1c24ad86596b2511` | matches (sha256sums) | Valid, Simon Tatham |
| WinSCP-6.7-Setup.exe | 6.7 | `c8e603088b608b6620ca8e06846486cfed48969b76b111f05a83a386a829207c` | matches (file page) | Valid, Martin Prikryl |
| WinSCP-6.7.msi | 6.7 | `bf69fb2ef3345ba7639f7ee4dcceac53198db9e5644926b39b2853931299e53e` | matches (file page) | Valid, Martin Prikryl |
| OpenSSH-Win64-v10.4.0.0.msi | 10.4.0.0 | `788d8643464a01eb63640a2fd746f9ed23d106b5a901a35f88dc8cd40e446ac9` | matches (GitHub digest) | Valid, Microsoft Corporation |
| Wireshark-4.6.9-x64.msi | 4.6.9.0 | `1975dfc96581a9b674fda3f41ac1585963b4ba52ea9459f3b6d9cedfac3a7217` | matches (SIGNATURES file) | Valid, Wireshark Foundation |
| npcap-1.90.exe | 1.90 | `682b57e1c05ef375931975c9d6ded40888f4bfdf9f4b11571e654f962f1199b6` | none published | Valid, Nmap Software LLC |
| npp.8.9.9.Installer.x64.exe | 8.99 | `a18cfb33d616c8eecda0059604d40bdb9d607fbc4ede857c8be6e41986464367` | matches (checksums file, GitHub digest) | Valid, NOTEPAD++ |
| npp.8.9.9.Installer.x64.msi | 8.9.9 | `52260e91dd98adda3413de1555e042debebc89615fab7a9bb0c20e4292491d3c` | matches (checksums file, GitHub digest) | Valid, NOTEPAD++ |
| Firefox Setup 153.7.0esr.msi | 153.7.0.0 | `bf0362dcb431e67d813dd394be50a5e0492eca3a64b40c9811389efdd53dd40f` | matches (SHA256SUMS) | Valid, Mozilla Corporation |
| splunkforwarder-10.6.1.1-b2ae2962645c-windows-x64.msi | 10.6.1.1 | `3a42233e387dc28d9e9ecc4c9dc41f184a006862762aa9213f7cd3cc97145a03` | matches (.sha256 and .sha512) | Valid, Splunk LLC |
| NessusAgent-11.2.3-x64.msi | 11.2.3.20022 | `80562755f498a2820b224e229a21203689a398981a0c771e29da1eba4cccba35` | matches (API sha256 and sha512) | Valid, TENABLE, INC. |

The Wireshark certificate had expired on 2026-09-25; the signature is valid because it carries a time stamp from
before that date.
