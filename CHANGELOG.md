# Changelog

All notable changes to this project are recorded here. The format follows Keep a Changelog
(https://keepachangelog.com/en/1.1.0/).

The Airgap Download Toolkit in `companion\`, for the side that has internet, carries a version number of its own; its
entries are headed *Download Toolkit*.

## [2.3.0] - in progress

### Added

- **Domain controllers and the domain: ten health checks and 37 security checks, with no PowerShell module.** On a
  domain controller the Health check, the Security audit and the self-check run one more collector, *Directory*
  (`lib\48-Directory.ps1`). It reads the directory on the server it runs on through ADSI, the registry, WMI and
  `dcdiag.exe` - not the ActiveDirectory module, not any other - and writes nothing. On every other server the
  checks read *not a domain controller*, without a call.
  - **Every domain controller** (H-AD-01..05, SEC-ADC-01..04): dcdiag, inbound replication as the directory records
    it, SYSVOL and NETLOGON, the directory's services, the five operations master roles; LDAP signing (ISM-1929),
    the Print Spooler (ISM-1828), other server roles on a domain controller (ISM-1926), strong certificate mapping
    (ISM-1943).
  - **The domain, once, on its PDC emulator** (H-AD-06, 07, 09 and SEC-AD-01..29): the last backup, the RID pool, the
    functional level; Kerberos pre-authentication, reversible encryption, accounts without a password, userPassword,
    passwords in descriptions, service principal names (who has one, AES, duplicates), delegation, SID history, who
    owns the domain and whether those accounts are protected, cannot be delegated and are in use, inactive
    accounts, disabled accounts in groups, Pre-Windows 2000 Compatible Access, the machine account quota, SID
    filtering on trusts, the KRBTGT and built-in Administrator passwords, computer account passwords, who may
    replicate the directory's secrets (DCSync), write permissions of Domain Computers, passwords in Group Policy
    Preferences. 45 ISM controls are cited; the manual has the table.
  - **The forest, once, on the PDC emulator of its root domain** (H-AD-08, H-AD-10, SEC-AD-30..33): the time
    source, the Recycle Bin, certificate templates that let a requester name the subject of a logon certificate or
    that ordinary accounts may change, the published templates good for logon, the templates changed lately.
  - **A domain controller that refuses WinRM** is read by its own local copy: the self-check and the local window
    run the collector there, and the results file written to the hub carries the checks into the hub's consoles.
  - **On the Health tab** a domain controller's details page (double-click its row) says `dcdiag 29/29` at its head,
    with what else of its directory checks is red or amber, and lists dcdiag test by test (a failed one with what
    dcdiag printed), every inbound replication link, the role holders, the directory's services and the domain's
    domain controllers. The Health report has the same as three tables. The grid has no column for it: the
    directory checks count in the row's Red, Amber and Green like any other.
  - A read that fails, or that the collector's four minutes no longer allow, is Amber with the reason - never a
    pass. A sweep that returns more than `DirectoryMaxObjects` objects stops there, judges what it read and says
    *there may be more*; with nothing found up to there it is Amber too. A domain controller with results from before 2.3 shows the checks grey (*not collected yet*) until it is
    checked again.
  - Seven thresholds on the Settings tab: `DirectoryMaxObjects` (20000), `DirectoryReplicationMaxHours` (24),
    `DirectoryBackupMaxDays` (7), `DomainAccountInactiveDays` (45), `DomainAdminsMax` (5),
    `KrbtgtPasswordMaxAgeDays` (180), `ComputerPasswordMaxAgeDays` (30).
  - Not judged: what cannot be read from a server (ISM-1827, ISM-1833, ISM-1927, ISM-1928), and whether the
    reviews the ISM asks for took place - the checks give the list to review. The certification authority's own
    flags and web enrolment are read on the authority itself (the next entry).
- **Local users and groups: eight security checks and two health checks.** The Settings collector lists every local
  user account and local group of a server - through ADSI (the WinNT provider), so no PowerShell module is loaded -
  and the checks judge them. Not applicable on a domain controller; a list that could not be read is Amber, never a
  pass. The built-in Administrator has its own check, SEC-CRD-03, stricter from this version (see *Changed*).
  - SEC-ACC-01 Guest, DefaultAccount and WDAGUtilityAccount are disabled (ISM-0383); SEC-ACC-02 no enabled account
    may have an empty password (ISM-0421, ISM-1557, ISM-0422); SEC-ACC-03 and SEC-ACC-04 local administrator accounts and other local
    accounts not logged on for 45 days (ISM-1648, ISM-1404); SEC-ACC-05 shared local accounts on a domain member
    (ISM-0415); SEC-ACC-06 the password of any enabled local administrator account, whatever it is called, older
    than a year: not rotated (ISM-1685); SEC-ACC-07 who is in the
    privileged and remote-logon groups (ISM-1508, ISM-1852); SEC-ACC-08 group members left over from deleted accounts
    (ISM-0430).
  - Health: H-ACC-01 a local account locked out, or its password expired or about to; H-ACC-02 a service that runs
    as a local account which is gone, disabled or locked out, or whose password has expired.
  - Three thresholds on the Settings tab: `LocalAccountInactiveDays` (45), `LocalAdminPasswordMaxAgeDays` (365),
    `LocalPasswordExpiryWarnDays` (14).
- **The computer the toolkit runs on says when it was read without administrator rights.** That computer is read by
  the window itself, and a window not started with *Run as administrator* is refused the Security log, the policy
  results (RSoP), the audit policy, the user rights and a few settings there - whatever groups the account is in.
  The values showed as *not read* with a hint about the account's groups. Now the answer of every collector run on
  the computer itself carries the rights it was read with: the Health and Security rows begin with *NOT ALL READ
  (not run as administrator)*, the checks concerned (failed logons, lockouts, the collector's own errors, RSoP) name
  the reason, and every check writes one warning to the log. Every other server is read in full, as before. The same mark travels in the
  results file of a copy run on a server.
- **NOT ELEVATED, in the top right corner of every console**, while the window runs without administrator rights. A
  click opens a page: what is not read on the PC the toolkit runs on (the Security log, Group Policy results, the
  audit policy and user rights, some settings and features), what is not done there (installs and removals, the
  Trellix Agent services), whether that concerns the PC today - only when it is in a group file, or the window is
  the copy on a server - and how to start with the rights. A window that has them shows no mark.
- **SQL Server and Certificate Services: six health checks and 13 security checks, read from the server.** Every
  Health check, every Security audit and the self-check run one more collector, *Roles* (`lib\49-ServerRoles.ps1`),
  on every server. It reads the registry, the services, the access lists of folders, the Application log, the
  certificate store and the web server's configuration file - and writes nothing. No connection is made to a
  database instance. A server with neither role answers at once and its checks read *not applicable*.
  - **SQL Server** (H-SQL-01..03, SEC-SQL-01..07), per instance: the engine and Agent services; errors in the
    Application log, damaged pages in red; backups as that log records them; the accounts the services run as
    (ISM-1249, ISM-1250); how the instance listens (ISM-1247); Force Encryption and its certificate (ISM-1277);
    who may reach the data, log and backup folders (ISM-1256); a web server on the same machine (ISM-1269);
    Windows logons only (ISM-1260); logon auditing (ISM-1537). What is decided inside the instance - who is a
    sysadmin, `sa`, the server audit - is not read, and the checks say so.
  - **A certification authority** (H-CA-01..03, SEC-CA-01..06): the service, the next revocation list, its own
    certificate; `EDITF_ATTRIBUTESUBJECTALTNAME2` (ISM-1944); the provider that holds its key (ISM-1957); web
    enrolment with HTTPS and Extended Protection (ISM-2130); its audit filter (ISM-2132); who may manage it
    (ISM-1508); encrypted requests (ISM-1246). Read as the configuration of Certificate Services is documented:
    no certification authority was at hand, so try these on yours.
  - **Certificate templates**, with the domain's other checks: SEC-AD-32 lists the published templates good for
    logon (ISM-1947) and SEC-AD-33 the templates changed in the last 90 days, for the quarterly review (ISM-2131).
  - On the Health tab the server's page lists its instances, their services, folders, errors and backups, or its
    certification authority; the Health report has both as tables. One threshold on the Settings tab:
    `SqlBackupMaxDays` (7).
- **Software library: Remove package...** takes the selected package out of `data\software-packages.psd1` - no hand
  edit - and, asked separately, deletes its installer files from `software\`. The removed entry is written to the
  log; every other byte of the catalogue stays; nothing changes on a server.
- `data\known-apps.psd1` knows KeePass 2.x (2.62 of 2026-11-04, from the vendor's release list): an older copy reads
  **Behind** in the software inventory, where it read *not in known-apps.psd1*. KeePass 1.x is a line of its own
  and is not matched.
- Software console, registering an `.exe`: the form reads which setup program built the file - Inno Setup, a WiX
  bundle, InstallShield or NSIS - says so in its preview (*Built with*) and starts a new registration with that
  program's usual silent switches, instead of leaving the choice to the operator. Help on the Software tab and the
  manual have the table of setup programs, their marks and their switches.

### Changed

- **Tool tips are a few words.** Every tool tip of the window - buttons, headings, tick boxes, the page tabs of the
  Security console, the settings - is now at most 70 characters on one line, where some ran to a paragraph. What
  they explained is in the manual: the row colours of the Health grid, the pass rate, what unticking an
  internet-facing server writes. The tool tip of a setting ends with the setting's name.
- **The manual's ten screenshots are of version 2.3**: every console as it is now, taken from the running window with
  the results of a test fleet; the servers' names and the login are blurred, as before.
- **Health console: the button is now Scripts and tasks audit (ticked)**, and it is told apart from the checks beside
  it: the one plum button of the window, in bold. What it does is unchanged - read-only, the ticked servers, then
  the Scripts report.
- **TCP 445 is described as it is used.** The ports picture and the Code Tour (A2, A3) listed SMB as never used.
  That holds from this PC to a server - the tool never opens `\\server\C$`. The other way it is optional: the copy
  on a server marked `winrm: no` may read `patches\` and `software\` from, and write its results file to, a share
  of this PC. The picture's row now says so (*optional*, a `winrm: no` server to the operator PC), and the manual
  and the copy's `INSTRUCTIONS.txt` name the port. Carried by hand, the copy and its results file use no port.
- No installer restarts a server, also where the switches cannot say so: an `.exe` built with NSIS has no switch that
  holds back a restart, so it is refused whatever is typed in the argument boxes (**Blocked: file**, in the form and at
  every scan). Before, `/S /norestart` passed the check although the installer ignores `/norestart`. Take the
  vendor's `.msi`. The setup program is kept with the file's vetting.
- No removal restarts a server either. UNINSTALL runs an uninstaller only where the tool knows the switch that holds
  a restart back (MSI, Inno Setup, WiX bundles) and adds it. Any other uninstaller - NSIS, InstallShield and the
  rest - could restart the server by itself: its product now reads **by hand** in the Removal column and is never
  run, refused on the operator PC and again on the server. Before, such a product read **quiet (may restart)** and
  was removed after a warning. Remove it on the server in a reboot window.
- **SEC-CRD-03, the built-in Administrator: enabled is a failure, whatever the account is called.** The check passed
  a renamed account and only warned about an enabled one still named Administrator. A rename does not change which
  account it is - the same identifier on every Windows server - and the ISM has default accounts changed, disabled
  or removed (ISM-0383): local administration runs on an account of your own, any name, and the built-in one is
  disabled. The check now fails on an enabled built-in Administrator under any name and names the local
  administrator accounts used in its place. On a domain controller, where the account is the domain's break glass
  account, renamed is still enough. A server that passed on a rename fails until the account is disabled, or the
  check is tailored with a reason.

### Fixed

- **The buttons of the pop-up windows look like buttons.** The buttons at the foot of a pop-up window - the Software
  library, Register, the plan before an install, a change record, Copy for a server, code signing, the SOE and
  tailoring forms - were left to the Windows theme and could draw as bare text, like labels. They wear the flat face
  with an edge that the buttons of the consoles have; the pop-up windows of the Download Toolkit too.
- **Software library window: the buttons say what a press does.** *Most needed* is **Tick most to do**: it ticks the
  packages with the most servers to update or install, as many as the console shows. *Show ticked*, which read like a
  filter of the list, is **OK**: it shows the ticked packages in the console and closes the window. Each button has
  a tool tip, and the line of text beside them is gone.
- From the last code review before release:
  - **Compliance figures.** A finding whose text happened to hold the words *not read* was left out of the figures
    as if its value had not been read: SQL Server in mixed mode (SEC-SQL-06), a certification authority that records
    only part (SEC-CA-04). And local groups, or the members of Administrators, that did not come back counted as
    not compliant where they were not read (SEC-ACC-07, SEC-ACC-08, SEC-CRD-02). The texts now say what they mean.
  - **The log line of a Group Policy check** counted an extension's old failed result as *failing*, while the check
    and the page call it stale. It counts the two as they do.
  - **A self-check asked for the Directory alone** (`-Only Directory`), or one whose settings read failed, ended as
    a failed collector on a healthy server: the collector waited for another one to say whether the computer is a
    domain controller. The computer it runs on now says so itself; a server left out on the hub is named in the log.
  - **Local accounts on a domain controller.** Where the domain role could not be read, the Settings collector went
    on to list local accounts - on a domain controller that is every account of the domain. It lists nothing then
    and says why.
  - **Nearly everybody** (Everyone, Authenticated Users, Domain Users ...) was written out five times and the lists
    differed: INTERACTIVE and NETWORK counted for the local groups only. One list now, the same in every check.
  - An installer that cannot be read no longer has the vetting cache written again at every scan; Help on the
    Software tab names the library window's buttons as they are.
- **ISM citations, each read against the control's text** (ISM of September 2026). Every control a check or the
  manual names is in the catalogue, and the catalogue is ASD's spreadsheet line for line. One rule for all 180
  Security checks: a check cites a control only where the check's own result is evidence for that control. 23 checks
  cited one that does not meet it:
  - **A control about something else.** *SMB signing required* (SEC-OPT-13, SEC-OPT-14) cited ISM-1962, which is
    about SMB version 1; User Account Control (SEC-OPT-15..17) cited ISM-1584, about unprivileged users; the two
    logon rights (SEC-RGT-05, SEC-RGT-06) cited the privileged access control; the event log sizes (SEC-LOG-02..04)
    cited the 12-month retention control, which a size does not show. All cite the hardening control, ISM-1409, whose
    guidance their expected values come from. *Maximum password age*, a report (SEC-POL-06), cited the password
    length control and now cites ISM-1590, which says when a password is changed.
  - **Audit subcategories cite a logging control, not the control about the thing audited.** Account Lockout (was
    ISM-1403), Audit Policy Change (ISM-1815), Removable Storage and PNP Activity (ISM-1418), Computer Account
    Management and Other Account Management Events (ISM-1650, which names user accounts and security groups) cite
    ISM-0582.
  - **A pass that would have vouched for more than was read.** *Local Administrators group membership* (SEC-CRD-02)
    no longer cites ISM-0445, dedicated privileged accounts: the membership does not show that. The patch timeframe
    (SEC-PAT-01) cites the two timeframes it judges, two weeks and one month (ISM-1694, ISM-1695), and no longer
    the 48-hour controls (ISM-1877, ISM-1696), which need the vendor's rating; its text names them as not judged.
    *SQL Server listens only the ways it is used* (SEC-SQL-02) cites ISM-1247, unneeded functionality, in place of
    ISM-1272, which holds only where local access is all that is needed - not something the check can tell.
  - **Every classification.** *Every enabled account must have a password* (SEC-ACC-02, SEC-AD-03) cited only the
    length control for networks up to PROTECTED, so on a SECRET or TOP SECRET network the check went grey and such
    an account was not named. It cites the length control of every classification (ISM-0421, ISM-1557, ISM-0422).
  - *Vulnerability scanner used for online services and operating systems* (SEC-NA-06) cited the online services
    control only; ISM-1702, operating systems, is added.
  - **What it changes on screen.** SEC-AUD-09, SEC-AUD-10 and SEC-AUD-12 are no longer Essential Eight checks
    (they were ML2), nor are SEC-RGT-05 and SEC-RGT-06 (ML3); SEC-CRD-02 is ML3 where it was ML1. A failure of
    SEC-AUD-09, SEC-AUD-10, SEC-AUD-12 or SEC-RGT-05 is amber where it was red; SEC-CRD-02 stays red.
  - Three texts said more than their control: the lockout duration (ISM-1403 names no "15 minutes"), password
    complexity (ISM-2080 has no "when the length is 15 or more") and the patch timeframe shown with SEC-PAT-01.
- Health, *Trust with the domain* (H-GPO-03) on a domain controller that holds the PDC emulator role: the check was
  Amber, *the secure channel could not be tested*. That domain controller is the domain's end of every secure
  channel and has none of its own, and Windows answers the test there with *the specified domain either does not
  exist or could not be contacted*. The Group Policy collector no longer runs the test there, and the check reads
  *not applicable* - also for a result collected before this version. Any other domain controller is tested as
  before.
- Security, SEC-CRD-03 on a domain controller: the check read *built-in Administrator not read* (Amber), because a
  domain controller has no local accounts to read it from. It now judges the domain's built-in Administrator as the
  directory holds it, on the domain's PDC emulator; the other domain controllers say where it is judged.
- Four values that were never read, found by going through a full set of results:
  - **Group Policy, each extension's last result.** The list was empty on every server, so *every policy extension
    succeeded* was said of nothing and a failed extension could not be seen. Windows Server keeps the results under
    `Status\GPExtensions`, not where the collector looked; they are read from there now, with the time each
    extension last had policy to apply.
  - **SEC-OS-01, PowerShell 2.0 engine removed, passed on a blank.** The feature name asked for does not exist on a
    server, the answer was empty, and empty is not *Enabled*. The engine is now read from the server's roles and
    features, where it reads removed once .NET Framework 3.5 is gone; a state that cannot be read is *Unknown* -
    Amber, never a pass. A server that has the engine installed fails the check from now on.
  - **SEC-NET-05, WinRM TrustedHosts, read *not collected* wherever the list was empty** - the good case. `winrm`
    prints an empty list as the name alone; that is read as not configured, and the check passes.
  - **SEC-PLT-01, exploit protection, read *could not read* on Windows Server 2016**, which has no
    `Get-ProcessMitigation`. The collector falls back to the registry value that cmdlet reads: absent means nothing
    is set system-wide, the same answer the later versions give.
- A SQL Server instance whose name begins with PS (PSOFT, PSQL01) was missing from the inventory: the collector
  left out every registry value beginning with PS to drop the five properties PowerShell adds. They are left out by
  name now; the configuration points of an SOE standard had the same fault.
- Health, *Group Policy applies without errors*: a failed result that an extension left behind long before the last
  refresh - it has had nothing to apply since - is named in amber and no longer counts as failing today; a failure
  at the last refresh is red, as before.
- Software console, Register form: a file version of 4.6.9.0 beside an installed 4.6.7 drew the warning that the two
  are *written differently*. A trailing `.0` is not a difference (the two compare, and UPDATE was offered all along);
  the warning now leaves it out and keeps to real ones such as 2409 against 24.09.
- Software console: Wireshark, registered from its `.msi`, was offered as INSTALL on servers that already had it, and
  its row in the inventory list stayed *not in known-apps.psd1*. Three causes, each fixed:
  - **Match.** The Register form took Match from the installer's own product name, and a copy from the vendor's `.exe`
    installer is listed under another one (*Wireshark 4.4.2 x64* against *Wireshark*). The form now starts Match wide
    enough for the names the inventory lists the product under (`Wireshark*`), turns a version number in the name
    into `*` (*PuTTY release 0.85 (64-bit)*), never widens onto another product, offers that Match first in the list,
    and its preview names any such name Match leaves out.
  - **The software library is a reference for the currency verdict.** A product that a registered package covers is
    **Behind** while `software\` holds a newer installer and **Current** when it does not, whether or not
    `data\known-apps.psd1` names the product. Registering is enough; nothing is typed into the catalogue.
  - **An `.msi` that refuses the `.exe` installer's copy.** Wireshark's `.msi` carries a launch condition that names
    the copy its `.exe` installer leaves, and ends with error 1603 while that copy is there. The tool reads such a
    rule from the `.msi` itself (LaunchCondition, AppSearch, RegLocator), keeps it with the file's vetting, and the
    server's cell reads **Remove 4.4.2 first** instead of INSTALL or UPDATE: remove that copy, then INSTALL. The
    copy a Wireshark `.exe` leaves has an uninstaller the tool does not run (it reads **by hand**, see *Changed*),
    so it is removed on the server. The inventory row says the same, and the Register form lists the rule.

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
