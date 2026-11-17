# Changelog

All notable changes to this project are recorded here. The format follows Keep a Changelog
(https://keepachangelog.com/en/1.1.0/).

The Airgap Download Toolkit in `companion\`, for the side that has internet, carries a version number of its own; its
entries are headed *Download Toolkit*.

## Download Toolkit [1.1] - 2026-11-18

### Added

- **The simple companion** (`companion\simple\Simple-Companion.html`): one page for a browser, for an internet-side PC
  where the Download Toolkit cannot run - application control (AppLocker, WDAC and similar) holds PowerShell in
  ConstrainedLanguage mode, or scripts are blocked altogether. A browser is all it needs; nothing is installed.
  - A plain text file, `deployed-versions.txt` (`Name = version`, a note after `#`), holds what the site has
    deployed. The page opens it, remembers it and saves it in place (Microsoft Edge, Google Chrome); the file is
    git-ignored and `deployed-versions.example.txt` is the list to start from.
  - A **Settings** tab says what the site runs, as ticks - the Windows Server versions, the .NET Framework versions,
    SQL Server 2016 to 2025 and Management Studio, the software - and each tick adds or removes rows. Software of the
    site's own is added with the page it is published on and its release notes.
  - Every product links the place it is published: the Update Catalog searched for the product (no month in the
    search, so a month without a release still lists the earlier ones, newest first), Microsoft's release list, the
    vendor's page, the release notes. .NET Framework has a row for each .NET version, and its search names it.
  - **Latest at the source** and a **Status** column (*Up to date*, *Update*): **Check sources** reads the newest
    version where the vendor lets a page read its list (WinSCP, Wireshark, Notepad++, OpenSSH, Firefox ESR - the
    addresses and patterns of `data\products.psd1`); elsewhere it is typed in from the link.
  - **Check a file** compares a downloaded file with the deployed version (*Deployed*, *Newer*, *Older*). The version
    is read from the file name and from inside the file as its Properties show it (an `.msi`'s ProductVersion or the
    version in its Comments, an `.exe`'s Product version). The page works out the SHA256 and SHA1, compares the SHA1
    in an Update Catalog file name, reads the vendor's published SHA256 where a page may (**Read from the source**),
    and searches a vendor's whole list of hashes for the file's own (**Search the copied list**, a paste, or the
    list's file dropped on the row). A .NET Framework or SQL Server file on the row of another version is a
    *Wrong file*; a hash that does not match is a *Mismatch*.
- **Start from text**, for a PC whose execution policy refuses the unsigned launcher (*"... is not digitally
  signed"*) while the language mode is FullLanguage: the launcher is read and run as text, reads its building blocks
  the same way, says so in the log and on the About tab, and a task registered from such a session starts the same
  way. No elevation and no signing; `companion\README.md`, *Where PowerShell refuses the file*.
- Schedule tab: a *Problem* row when the task ended with 1 and the tool recorded no run after it started (PowerShell
  did not get to run the tool), and when the task starts the launcher as a file although the session had to be
  started from text.

### Changed

- The launcher's message in ConstrainedLanguage mode, its header, the About page and the manuals name the simple
  companion as the way to work on such a PC. `companion\README.md` has a table of which one to use.
- The main manual describes the internet side (*The internet side: the Download Toolkit and the simple companion*).

## Download Toolkit [1.0] - 2026-11-17

### Added

- First release of the Airgap Download Toolkit (`companion\Start-DownloadToolkit.ps1`): on the side that has
  internet it finds the newest appropriate Windows and .NET Framework cumulative updates in the Microsoft Update
  Catalog, VMware Tools and the software installed offline, fetches each file, checks it (size, the hash the source
  publishes, the Authenticode signature, a SHA256 of its own) and keeps the library in the folders the WinRM toolkit
  reads, by hand or as a scheduled task. It runs as an ordinary user. See `companion\README.md` and
  `companion\SOURCES.md`.

## [2.2.0] - 2026-11-08

### Added

- Saved results (`lib\14-State.ps1`): the last result of every collector is kept per server in `state\servers\` and
  shown again at the next start, so every console opens with what it knew. Each grid has a **Last checked** column
  with the date and time of the result it paints, the cell green, amber or red by age (`ResultFreshDays`,
  `ResultStaleDays` on the Settings tab). A check that fails keeps the last good result and says so; an action never
  acts on it. `KeepResults` turns the writing off, `ResultsKeepDays` prunes old files. The window opens first and
  reads the files behind a small *Loading last data* box that counts them off.
- A row claims only what its own check collected: one console's check fills part of another's table (every button
  collects the status and the inventory, a Health check the settings), and such a row now says **partial** in grey,
  names what is missing, carries no pass rate and counts for nothing on the dashboards. A check whose collector was
  never run is grey (no verdict) instead of amber. *Last checked* is the oldest of the collectors a row relies on.
- Every pop-up window wears a frame in a darker shade of the brand blue, like the main window.
- Licensing (`lib\47-Licensing.ps1`): every software check, Security audit and self-check also collects, read-only,
  the hardware the licensing models count on (sockets, cores, physical or virtual, a Hyper-V host's VMs), the OS
  edition, the activation state and channel of Windows (and Office) with the KMS host used, a KMS host's counts, an
  RD Licensing server's CAL key packs (installed, issued, available) and issued CALs, an RD Session Host's licensing
  mode, licence servers and grace days; SQL Server and Exchange editions come from the inventory. The **Software
  report** gains three sections: the licensing models (Windows Server per core or per processor, Standard's two VMs
  per core set, Datacenter, the per-VM option, Essentials; SQL Server per core or Server + CAL by edition; Exchange;
  RDS CALs; Office; volume or direct activation) with the count each is driven by, the totals of the servers shown
  (core licences needed by product among them) and one row per server; **Licensing (shown)** on the Software console
  opens the same as a page; four Security checks (SEC-LIC-01 to 04) light the Servers grid. The counting rules were
  checked against Microsoft's Product Terms and licensing guides; the report and the page list the references.
- Health console: **Scripts and tasks (ticked)** (`lib\31-Health-Scripts.ps1`) reads, on the ticked servers, every
  scheduled task outside `\Microsoft\` (state, author, account and run level, triggers in words, the action and the
  script it runs, last run and result) and every PowerShell script under the folders named on the Settings tab
  (every fixed drive when none), each parsed and never run: its functions, what it does, the scripts it calls, its
  signature; a password in clear, an encoded command, code downloaded and run, a folder every user can write to and
  a missing script are flagged. The walk is bounded: a folder it cannot read is one line, junctions are never
  followed, vendor folders (the profiles' module folders too) are skipped by rule, each script is analysed the
  moment it is found, and a time budget per server ends the walk with a PARTIAL note and every script listed
  complete. The result goes to `reports\Scripts-<date>.html` + CSV and the server's Health page, and is saved like
  every collector's; a rescan that fails keeps the earlier scan for the report, with a note in its Scan column.
- The Software report now carries every installed product of every server (an inventory, not only the registered
  packages) and a server inventory table (OS, build, .NET, SQL Server, Exchange, roles and features).
- A copy written by **Copy for a server** starts as the spoke by itself (its `settings\spoke.json` is marked), so a
  plain start of the launcher is enough on the server; its `INSTRUCTIONS.txt` is never read as a server list.
- A spoke reads the hub's vetting caches (`patches\_info`, `software\_info`) and trusts them, so its first load does
  not read every update file over the share, and it never writes into the hub's folders. The software vetting cache
  is keyed by the path under `software\` instead of the full path, so one cache serves the hub and its spokes.
- O/S Patching: the inventory always rides along with a status check (the tick box is gone). **Clear saved data
  (ticked)** forgets everything held on this PC for the ticked servers: every console's results and their
  `state\servers\` file; the servers are not touched.
- Servers the toolkit cannot reach over WinRM (a hardened domain controller): `; winrm: no` on the server's line (or
  `# winrm: no` for a whole group file) keeps every console and action away from it. A small green block at the right
  end of the O/S Patching toolbar serves them: **Mark winrm: no (ticked)** writes the entry for the ticked servers and
  takes it off again; **Copy for a server** writes one `state\server-copies\<server>-local-winrm\` per ticked marked
  server (every marked server when nothing is ticked), a ready-to-carry copy of the toolkit
  (scripts, catalogues, standards, pictures, settings; no patches, installers, server lists or results) with
  `settings\spoke.json` filled in with this toolkit's folders as the server sees them (`\\<this PC>\<drive>$\...`),
  `INSTRUCTIONS.txt` and, when asked, `Run-SelfCheck.ps1`; **Import results** takes a results file in. On the server,
  `Start-WinRMToolkit.ps1 -SelfCheck` writes its one results file, and a file written into the hub's
  `state\servers\` share is picked up at the next Reload.
- `Start-WinRMToolkit.ps1 -Spoke`: the window on a server the hub cannot reach, working on that computer only, from
  the hub's `patches\` and `software\` (asked for at start, kept in `settings\spoke.json`), its results file written
  where the hub reads it.

### Changed

- The box **Stop the Trellix Agent services first** (O/S Patching and Software tabs) starts unticked; tick it, or set
  `StopTrellixAgentForInstall` on the Settings tab, where the agent blocks installs.
- Security grid: the Light column is gone (the row colour says it) and so is the Class column (the class is on the
  server's page and in the reports). A server marked `winrm: no` has a grey name cell in every console.
- HTML reports and pages: no table carries a Light column any more (the row colour says it); the CSV files beside a
  report keep it for filtering. A click on a column heading sorts the table by that column, a second click the other
  way round. A wide table (the Scripts report's tasks and scripts) is laid out in fixed column widths: a date or a
  size never breaks, a path wraps inside its cell at a backslash, and the page shows a task's full name and a
  script's name and folder while the CSV keeps the path and every column. In the Scripts report a script file named
  in a task's Scripts cell or a script's Calls cell is a link that filters the page by that name.
- The licensing counting rules are headed lists of short points (Windows Server, Essentials, CALs, SQL Server,
  Exchange, RDS, KMS, Office, the agreement) in the Software report, on the Licensing page and on a server's page,
  instead of one paragraph.
- Software console: the inventory list shows every product at start (**Show all products** ticked); untick it for
  only the products needing attention.
- A `CHECKSUMS.txt` in the root folder (a checksum list written beside `patches\` and `software\`) is not read as a
  server list.
- Security console: the ISM release the checks are modelled on (September 2026) is named on the Servers page header
  and the Security profile page, on every server and control page and in every security report; it comes from the
  catalogue's `Release` field, so a catalogue built from a newer ISM carries its own release name.
- Security console: a repaint is several times faster with many servers (the Controls page, the GPO recommendations
  and the tailoring lookups index their rows once instead of scanning them for every check), and while any console
  repaints the status bar says so with a wait pointer.

### Fixed

- A software install or stage plan refuses a server whose latest check failed, as the O/S patch plan already did; the
  grid may still show the last good result, but nothing acts on it.
- **Clear saved data (ticked)** also removes a results file a self-check or a spoke wrote under the server's own name
  with its domain, so the forgotten data does not come back at the next start.
- A spoke whose results folder is the hub's share reads only its own file there, never prunes the share, and never
  creates patch or package folders under the hub's `patches\` and `software\`.
- `Start-WinRMToolkit.ps1 -SelfCheck` run inside a copy for a server uses the results folder the hub baked into the
  copy unless one is typed.
- A results file that could not be read (being written, a share hiccup) is read again at the next Reload instead of
  being treated as read and unchanged.
- A list setting on the Settings tab (the scripts scan's folders) takes any number of items; the length limit is per
  item.

## [2.1.0] - 2026-11-03

### Changed

- The repository moved from `ChrisFryer/Offline-Updates` to `fusetech-labs/airgap-winrm`, and the product is now
  the Airgap WinRM Toolkit, published by Fusetech (https://fusetech.com.au). The source link in the About tab and
  the README point at the new repository.
- The toolkit is licensed under the PolyForm Noncommercial License 1.0.0 (see LICENSE and COMMERCIAL.md). Every
  published script now carries a licence header (Copyright Fusetech, SPDX-License-Identifier
  PolyForm-Noncommercial-1.0.0); the scripts need re-signing.
- Internal names are unchanged so existing deployments keep working: the `\WinRMToolkit\` task folder, the
  `OfflinePatcher` event source, `Start-WinRMToolkit.ps1`, the settings keys and the file layout.
- The window title ends "offline, over WinRM" instead of naming the port.
- Health grid: the Light column is gone (the row colour already says it), and every cell that stands for a check
  carries that check's own colour, so a green or amber cell shows inside a row that is red for another finding.
- SOE standards, Add by hand: the item form shows only the boxes the chosen type uses, offers a list wherever a
  value must match exactly (type, agents, setting keys, start types, states), fills a registry or file rule from the
  known configuration points, keeps what was typed when something is missing, and has a Help button.
- Support and licensing enquiries go to products@fusetech.com.au; the About tab shows it and the Fusetech website.

### Added

- LICENSE (PolyForm Noncommercial 1.0.0 with the required notice), COMMERCIAL.md (when a commercial licence is
  needed) and SECURITY.md (how to report a vulnerability).
- A trademark note at the foot of the README.
- The Fusetech look: a frame in the brand blue round the window, a window icon drawn at start-up (the logo's
  bolt on a blue square, no picture file to ship) and the same icon as the favicon of every HTML page.
