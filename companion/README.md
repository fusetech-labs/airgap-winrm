# Airgap Download Toolkit - the internet side of the Airgap WinRM Toolkit

The Airgap WinRM Toolkit patches and manages Windows Servers that never see the internet. This companion runs on the
side that does: it fetches the newest appropriate update of every product, checks every file, and keeps the library in
the folders the WinRM toolkit reads. Carry the library across; the WinRM toolkit does the rest.

* **Windows and .NET Framework cumulative updates** from the Microsoft Update Catalog, one per Windows build and .NET
  line the site runs.
* **VMware Tools** from the VMware package site, the version the site's ESXi line ships (or the newest of that line, the
  newest there is, or a pinned one).
* **Software installed offline**, each from its vendor's own source and checked against the SHA256 the vendor
  publishes: Microsoft Edge, PuTTY, WinSCP, Wireshark, Notepad++ and Firefox ESR. OpenSSH for Windows is in the list
  but not ticked: the supported OpenSSH is the one inside Windows Server.
* **Splunk Universal Forwarder** from a link a person gives: the version is the Splunk administrator's decision, so
  the tool reads no Splunk page; it fetches the pasted link and checks it against Splunk's checksum file.
* **Any product with a fixed download link or a vendor index page**, described in `data\products.psd1`.

Every file is checked before it is kept: the size the source announced, the hash the source publishes (the catalogue's
SHA1 and, where it gives one, its SHA256; a vendor's SHA256), the Authenticode signature by the product's own signer, and
a SHA256 of its own recorded in `library-manifest.json` and `CHECKSUMS.txt` together with what was compared. Only the
newest file of each product, build and .NET line stays. The same window, colours and habits as the WinRM toolkit;
PowerShell 5.1 and WinForms, no modules, no agents.

## Running it

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Start-DownloadToolkit.ps1               # the window
powershell.exe -ExecutionPolicy Bypass -File .\Start-DownloadToolkit.ps1 -Unattended   # what the scheduled task runs
```

Beside the WinRM toolkit (this folder inside its folder) the library **is** that toolkit's `patches\` and `software\`
folders: a verified download is a column in its O/S Patching or Software console at the next *Reload*. Copied elsewhere,
the library is `library\` in this folder, or any folder named on the Settings tab (a USB drive to carry across). Nothing
in this folder is executed from a download; the files are only hashed, their signatures read, and written to the library.

## First run

1. **Settings tab**, the first box (*This site*): tick the Windows builds the managed servers run, the .NET Framework
   lines in use, type the ESXi line (7.0, 8.0, 9.0 ...) and pick the VMware Tools rule. *Save settings*. Nothing outside
   these parameters is ever fetched.
2. **Products tab**: every product is a row with a tick box. Tick what this site wants fetched and take the tick away
   from what it does not: a product without a tick is never fetched. The *From* column is the address the tool reads
   for that product - click it to open the source in the browser and check it. *Installers whose link is given by
   hand* (Splunk Universal Forwarder): click *Find it on*, copy the installer link from the vendor's page and paste it
   in the box, or leave it empty - the row then says *By hand* and nothing is fetched. *Save products*.
3. **Library tab**: *Check for updates* asks every source and fills the *Latest found* column - or, when rows are
   ticked, only the ticked rows; rows that say *Download* are new. *Download ticked* fetches the ticked rows after a Yes that lists the files and sizes; *Check and download*
   does the whole run at once. Double-click a row for the candidate, the rule and the library files of the product,
   and for the vendor's release notes as a link to click (the KB article of an update, the release notes or change
   log of an installer; `ReleaseNotes` in `data\products.psd1`).
4. **Schedule tab**: *Register task* makes the unattended run a scheduled task (daily at 03:00 by default; the time, day
   and logon type are on the Settings tab). The tab shows the Task Scheduler's state and the outcome of the last run.

## Folder layout

| Path | Purpose |
|---|---|
| `Start-DownloadToolkit.ps1` | The launcher: loads `lib\` from an explicit list, opens the window, or runs unattended with `-Unattended`. |
| `lib\01-Config.ps1` | The defaults: folders, limits, the task, the console colours. The Settings tab saves its changes over them. |
| `lib\03-Products.ps1` | The products, the environment (builds, .NET lines, ESXi line) and the targets they make; the .NET and VMware rules. |
| `lib\04-Web.ps1` | The only file that talks to the internet: pages, form posts, the streamed download with progress and a stop button. |
| `lib\05-Sources.ps1` | The adapters: the Update Catalog, the VMware package site, a fixed link, an index page. |
| `lib\06-Library.ps1` | The library: manifest, verification, pruning, the rows of the grid, the unattended run. |
| `lib\10-Task.ps1` | The scheduled task: register, watch, run now. |
| `lib\20-...70-*.ps1` | The consoles: Library, Products, Schedule, Settings, About. |
| `data\products.psd1` | The products: where each comes from, who must have signed it, and whether it is fetched when the site has not ticked otherwise. Values only. |
| `settings\settings.json`, `settings\environment.json` | What the Settings and Products tabs saved (the second: what the site runs, the product ticks, the links given by hand). Git-ignored. |
| `settings\last-run.json` | The outcome of the last run (every run writes it). Git-ignored. |
| `library\` | The library when this folder is not beside the WinRM toolkit. Git-ignored. |
| `logs\`, `reports\` | `Download-YYYYMMDD.log`, one file per day; the HTML + CSV reports. Git-ignored. |

In the library folder: `patches\Windows\`, `patches\DotNet\`, `software\<Folder>\` (the WinRM toolkit's layout),
`library-manifest.json` (every file the tool recorded: product, version, hashes, signer, source, date) and `CHECKSUMS.txt`
(`sha256  path` per file, for `Get-FileHash` or `certutil -hashfile` on the other side). The window and the scheduled
task may run at the same time: one of them at a time writes the manifest (`library-manifest.json.lock` exists only
for that moment).

## How a product is found

* **Windows cumulative update**: the catalogue is searched for *"<month> Cumulative Update for <the build's catalogue
  name> for x64-based Systems"*, this month first and then earlier months. A month may hold more than one: the monthly
  security release of Patch Tuesday and, some months, an out-of-band release after it. Each is cumulative, so the
  newest of the month is taken and the row names the ones it includes; a "Cumulative Update Preview" is left. Once
  Patch Tuesday is three days behind and only an older month is found, the row says *Stale* and the run fails:
  Microsoft has most likely changed how the catalogue names or classifies its updates, and the tool needs an update
  (the reason names Microsoft's release list to compare with). The download
  link is asked for as the catalogue's own Download button asks; the link's digest, the SHA1 in the file name and the file
  itself must all agree, and so must the SHA256 the catalogue gives for the files of its newer delivery service (Server
  2025). Every page of a search is read, and a page read that fails for a moment (no answer in time, HTTP 5xx, the
  catalogue's own "error number 8DDD0010" page) is tried again as often as a download is.
* **Server 2025**: the catalogue lists two files for the month's update, the update itself and the checkpoint cumulative
  update it builds on (KB5043080). Both are fetched; the checkpoint once, and it stays beside every later monthly update,
  because DISM needs it there on a server that has not had it.
* **Server 2016 servicing stack update**: Server 2016 still gets its servicing stack as a file of its own, one a month.
  It has its own row (only when build 14393 is ticked), and the WinRM toolkit installs it before the cumulative update.
  Server 2019 and later carry it inside the cumulative update.
* **.NET Framework cumulative update**: the same search for *.NET Framework*. A catalogue entry may hold one file per .NET
  line (Server 2022: *"3.5, 4.8 and 4.8.1"* is an `ndp48` file and an `ndp481` file, each its own KB). Each file is a
  candidate on its own; only those for the lines ticked on the Settings tab are fetched, the others show as *Held*.
* **VMware Tools**: the version map on the package site says which Tools each ESXi line ships. The rule on the Settings
  tab picks the release: `shipped` (exactly that one), `line` (the newest of that version line, the default), `latest`
  (check the Broadcom interoperability matrix first) or `pin`.
* **A fixed link** (`Source = 'url'`): the link always serves the current version, so the size and date of the link are
  compared with what was fetched last; a change means a new version. The version is read from inside the file after the
  download and becomes part of the file name.
* **An index page** (`Source = 'index'`): a regular expression in `data\products.psd1` picks the links and their versions;
  the newest wins; a checksum page, when the vendor has one, gives the SHA256 the download must have. The page may be
  HTML, a checksum list or a JSON answer (GitHub's release list). Where the page names only the version, `FileUrl` is
  the link as a template (Firefox ESR); where the link sits on a page of the file's own and carries a short-lived
  token, `FilePage` names that page and it is read again just before the download (WinSCP).
* **Microsoft Edge** (`Source = 'edge'`): Microsoft's list for administrators names the newest Stable release for
  Windows, its MSI and its SHA256.
* **A link given by hand** (`Source = 'manual'`): the operator pastes the installer link on the Products tab; the
  tool checks its shape, fetches it and compares it with the vendor's checksum file beside it (`{url}.sha256`).

The software entries and what each vendor publishes are in `data\products.psd1` and `SOURCES.md`. Two rules matter:
Wireshark's folder also holds development releases, so only even minor numbers are taken; and Npcap is listed but
switched off, because its free licence allows five systems and no silent install.

The verdicts: **Current** (green) the newest appropriate file is in the library and its hash still matches; **Download**
(amber) the source has a newer or missing file; **Unverified** (amber) a file of that name is in the library but a
person placed it there - *Download ticked* or a run checks it where it lies, exactly as a download is checked, and
records it when it passes (red when it did not pass; it is never deleted); **Held** (blue) the source has it but a
rule says no; **Stale** (red) only an older month's cumulative update was found although this month's must exist;
**Check failed**, **Download failed** and **Changed** (red) with the reason in the row; **Not checked**,
**Not set up** and **By hand** (grey; *By hand* = a product waiting for its link, never a failed run).

A download arrives in `_incoming\` inside the product's folder and takes its place in the library only when it has
passed every check, so a download that fails or is stopped never touches a file that was already there.

## The scheduled task

`\WinRMToolkit\Airgap Download Toolkit` runs the launcher with `-Unattended` as the account that registers it, at the
time of the Settings tab in local time, summer and winter alike. `Interactive` (the default) runs while that account
is logged on at the start time, with its full session, and needs no extra right. `S4U` (Settings tab) runs whether or
not the account is logged on and stores no password, but has no network credentials - a proxy that asks for a
password, or a library on a network drive, fails under it - and Windows may refuse it to an account without the right
to log on as a batch job. The run writes
`settings\last-run.json`, a report and the day's log; exit code 0 means nothing failed. A product the site does not
use (no ESXi version, no .NET line ticked) never fails a run.

## An ordinary user account is enough

The tool is made to run without privileges: nothing is installed, nothing asks for elevation, no machine-wide setting
is changed and nothing is signed. It writes only its own folder, the library folder and its own scheduled task (at the
Limited run level). The About tab shows what PowerShell sees for each script's signature; *not signed* is the normal
state. Where application control restricts PowerShell scripts (ConstrainedLanguage mode) the tool cannot run on that
PC: use one where it can.

## Requirements

Windows PowerShell 5.1 with .NET Framework 4.x in FullLanguage mode; internet access, direct or through the system
proxy, to `catalog.update.microsoft.com`, `catalog.s.download.windowsupdate.com`,
`catalog.sf.dl.delivery.mp.microsoft.com` (the Server 2025 files), `packages.vmware.com` and each vendor link in
`data\products.psd1`; the right to write the library folder. TLS 1.2 is used for every connection.

The hosts of the software entries, for a proxy or firewall allow-list:

| Product | Hosts |
|---|---|
| Microsoft Edge | `edgeupdates.microsoft.com`, `msedge.sf.dl.delivery.mp.microsoft.com` |
| PuTTY | `www.chiark.greenend.org.uk` (the team's page), `the.earth.li` (the download host that page links) |
| WinSCP | `winscp.net`, `cdn.winscp.net` |
| Notepad++, OpenSSH (when ticked) | `api.github.com`, `github.com`, `release-assets.githubusercontent.com` |
| Wireshark | `www.wireshark.org` |
| Firefox ESR | `product-details.mozilla.org`, `archive.mozilla.org` |
| Splunk Universal Forwarder | `download.splunk.com` (the link given by hand and its `.sha256`) |

## Licence

PolyForm Noncommercial License 1.0.0, as the Airgap WinRM Toolkit (see `LICENSE` and `COMMERCIAL.md` in the toolkit
folder). Support and licensing: products@fusetech.com.au.
