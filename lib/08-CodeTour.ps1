# =====================================================================
#  08-CodeTour.ps1  -  THE TRAINING CONTENT SHOWN IN THE "CODE TOUR" TAB
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Each entry = a Title, an Explain text, the name of the function (or
#  script block variable) whose LIVE source is printed underneath, and
#  optionally an Image (a PNG in images\).
#  "Live" means it is read from memory with Get-Command, so what you see
#  is exactly what is running - even if somebody edited a file.
#  Special sources (see Get-CodeTourSource at the bottom):
#     Config            the $Config table as it is right now
#     Remote*Script     a script block that runs on the servers
#     Checks:<Console>  the check catalogue rendered from $Checks
#     SettingsKeys      every key the Settings collector produces
#     DataFiles         the data\ catalogues with their dates and sizes
# =====================================================================

# ---------------------------------------------------------------------
#  REVIEW RECORD  -  08-CodeTour.ps1
# ---------------------------------------------------------------------
#  Independent review 2026-10-14 (see CODE-REVIEW.md): R-31 text that
#  disagreed with the code was corrected.  Version 2 (2026-10-16): the
#  tour was reorganised into parts A-F for the three consoles; the
#  check catalogues and the settings keys are rendered from the code so
#  they cannot drift.  Text only - nothing here runs on a server.
#  ---------------------------------------------------------------------
#  HUMAN REVIEW  (fill in by hand and keep it in the file)
#  Reviewer   : ________cf______________________   Date : __30-10-2026____________
#  Verdict    : [x] Approved   [ ] Approved with comments   [ ] Changes required
#  Checked    : [ ] every topic read against the live source it shows
#  Comments   :
#    -
# =====================================================================

$script:CodeTour = @(
    # =================================================================  PART A - START HERE
    [pscustomobject]@{ Title = 'A1. Start here - the toolkit in one page'; Source = ''; Explain = @'
WHAT THIS TOOL IS
  Five consoles (tabs) over ONE engine, all over WinRM on TCP 5985 (or 5986 over HTTPS), all offline:
    PATCHING  checks and installs Windows / .NET updates, reboots, shows roles and software
              currency, detects SQL / Exchange patch levels.
    SOFTWARE  stages, installs and updates third-party software from a catalogue (VMware
              Tools first) with the reboot suppressed, and removes old or dormant products.
              With Patching (and a Commands-tab command that may change a server), the only
              console that changes a server - every install, update, removal and reboot asks for
              a change record and the pre-action confirmations first.  STAGE ONLY copies files
              with no record by default; the Trellix Agent buttons ask one Yes/No and a change
              record (or a maintenance tick); the Settings tab decides the recording per action.
    HEALTH    read-only: automatic services not running, scheduled tasks failing, failed logons
              and lockouts, dormant software, disks, uptime, event-log errors, time sync,
              expiring certificates, memory, agents, Group Policy (what applies, errors, the last
              refresh, the domain trust) - plus SOE standards you compose yourself.
    SECURITY  read-only: an ISM audit (audit policy, local security policy, hardening, application
              control, AV / EDR, firewall, LAPS, logging, patch timeframes) with a security
              profile (classification, Essential Eight target), tailoring (recorded risk
              decisions) and Red / Amber / Green / Grey lights; GPO recommendations - what Group
              Policy is missing, which GPO to put it in, and whether its impact would be felt.
    COMMANDS  one PowerShell command on the ticked servers, every answer underneath, with a
              cheat sheet of one-line commands for an investigation.  Get-CommandRisk reads the
              command first: a read-only one runs at once; one that may change a server asks for
              a change record and a confirmation, and is recorded like every other change.
  The first four have a Report button: HTML (summary on top, data below) + CSV (data only);
  the Commands tab saves its output as text.
  Three more tabs: the CODE TOUR (this text), SETTINGS (which confirmations pop up before a
  change, what a change record holds and which actions need one, the running log, thresholds)
  and ABOUT (version, GitHub link, this copy, the code signature of every script).

THE FILES (root folder)
  Start-WinRMToolkit.ps1     the launcher - checks the folder, loads lib\*.ps1 (explicit list)
  lib\01-Config.ps1          the defaults + shared variables ($Config, $Results, $Checks ...)
  lib\02-Logging.ps1         Write-PatchLog: file + console + GUI, colour coded; audit identity
  lib\03-Groups.ps1          Get-PatchGroups: the *.txt lists, "# class:" and "# soe:" directives
  lib\04-Patches.ps1         Get-PatchFiles : scan patches\<type>\, read build/signature/hash
  lib\05-WinRM.ps1           Invoke-Collector (the fan-out engine), status, credentials, slice copy
  lib\06-Install.ps1         pre-action confirmations, plan, locked staging folder, DISM install, reboot
  lib\07-Gui.ps1             the window shell: tabs, banners, toolbars, grids, details, this tab
  lib\08-CodeTour.ps1        this text
  lib\09-Reports.ps1         Export-ConsoleReport: HTML + CSV
  lib\10-Checks.ps1          New-Check / Invoke-Checks, verdicts, lights, JSON + data-file readers
  lib\11-ChangeLog.ps1       the change record before every change; changes\change-log.csv
  lib\12-Settings.ps1        what the Settings tab may change; settings\settings.json over the defaults
  lib\13-GroupPolicy.ps1     the Group Policy collector (Health and Security): GPOs, errors, RSoP
  lib\20-Console-Patching.ps1   the O/S Patching tab
  lib\30-Console-Health.ps1     the Health tab
  lib\40-Console-Security.ps1   the Security tab
  lib\45-Security-Gpo.ps1       its GPO recommendations: impact checks, gaps, the GPO plan
  lib\46-Security-Compliance.ps1  its compliance dashboard and the executive summary
  lib\50-Console-Software.ps1   the Software tab (data\software-packages.psd1, installers in software\)
  lib\60-Console-Settings.ps1   the Settings tab
  lib\70-Console-About.ps1      the About tab
  lib\80-Console-Commands.ps1   the Commands tab (one command, Get-CommandRisk, the cheat sheet)
  data\*.psd1                catalogues (known apps, product patches, benign services, agents,
                             SOE configuration points, software packages, expected security
                             settings, the ISM catalogue, GPO guidance, the Commands cheat
                             sheet) - see data\README.txt
  Sign-Toolkit.ps1           signs every .ps1 with your code-signing certificate (topic F6)
  README.md / README.txt                    the manual; how to start and sign it
  Every .ps1 starts with a REVIEW RECORD block with space for a human reviewer.

RUNNING IT WITHOUT A GUI (handy for fault finding)
  cd to the root folder, then in PowerShell 5.1 load the building blocks only:
     $NoGui = $true
     . .\Start-WinRMToolkit.ps1
  then call any function by hand:
     Get-PatchGroups; Get-PatchFiles
     Get-ServerStatus -ComputerName SRV01      # everything is logged to logs\
     $Results['Status']['SRV01'] | Format-List # raw result ($ServerStatus is the same table)
     Get-ServerHealth -ComputerName SRV01; Invoke-Checks -Console Health -Server SRV01 | Format-Table Id, Light, Evidence
     & $RemoteStatusScript $false              # run the remote status block on THIS machine
     Show-ToolkitGui                           # open the window when you are ready

LOG LEVELS
  CMD    = the exact command sent - copy it into a console to reproduce by hand
  WHY    = the reasoning behind the next step
  Every INSTALL / CONFIRM / RESULT / REBOOT / CHANGE / AUDIT line names the operator (audit trail).
'@ }

    [pscustomobject]@{ Title = 'A2. PICTURE: the big picture'; Source = ''; Image = 'images\1-big-picture.png'; Explain = @'
Who talks to whom.  Three machines matter: the INTERNET PC where the .msu (and the ISM
spreadsheet) is downloaded - any PC, the tool is not involved - the OPERATOR PC where this
tool runs, and the TARGET SERVERS from the group files.  Only one connection is made by the
tool: operator PC -> server on TCP 5985, WinRM over HTTP, authenticated with Kerberos (use
FQDNs in the group files; an IP address forces NTLM and would need TrustedHosts - never set
that to *).  Servers with an HTTPS listener: set WinRMPort = 5986 in 01-Config.ps1 and every
call goes with -UseSSL (Test-WinRMUseSsl); the listener's certificate must chain to a CA the
operator PC trusts and carry the server's FQDN - no check is skipped.  The domain controller
is already in the picture for DNS and Kerberos; nothing new is opened.  The red box lists what
the tool deliberately never uses, which is also the answer to "what do I need to allow through
the firewall?": the one WinRM port and nothing else.
'@ }

    [pscustomobject]@{ Title = 'A3. PICTURE: ports and protocols'; Source = ''; Image = 'images\2-ports-and-protocols.png'; Explain = @'
The table is the firewall conversation in one page.  Below it, the layers inside 5985
from the outside in - HTTP, then the WS-Management SOAP envelope (whose size limit,
MaxEnvelopeSizekb, is why files are copied in slices), then PSRP carrying our commands,
then wsmprovhost.exe on the server actually running them.  Every collector of every
console - Get-Service, Get-HotFix, the registry, the event logs, auditpol, secedit, w32tm -
runs inside that same process, as you.  The yellow box lists the only WinRM settings on
a server that ever matter to this tool.
'@ }

    [pscustomobject]@{ Title = 'A4. PICTURE: five consoles, one engine'; Source = ''; Image = 'images\7-consoles-and-engine.png'; Explain = @'
The map of version 2.  The five boxes at the top are the tabs; each lists the collectors
it runs and what it shows.  The yellow box is the engine they share: Invoke-Collector (the
fan-out), the Remote*Script blocks (what runs on the servers), the check model, the data
files, the change records, the report writer, the GUI shell and this tour.  Only the
O/S Patching and Software paths (STAGE ONLY, installs, removals, reboots, the Trellix Agent
services), and a Commands-tab command that may change a server, write to a server - each
recorded as the Settings tab says per action; everything else reads (a status check also
removes the toolkit's own finished install tasks, B3).  The group
files feed every tab: a
server line may carry "; soe: <name>" and "; class: internet-facing" (Health standard,
Security rules), and "# soe:" / "# class:" comment lines are the group-wide fallbacks.
'@ }

    [pscustomobject]@{ Title = 'A5. Config - settings and shared state'; Source = 'Config'; Explain = @'
$script:Config is a plain hashtable, filled when the tool starts: the defaults of
lib\01-Config.ps1, then what the Settings tab saved in settings\settings.json laid over them
(Import-ToolkitSettings, topic F5).  To change a value for good, use the Settings tab - or for
a value it does not offer, edit lib\01-Config.ps1 and start the tool again.  To try a value right now, type in
the console behind the GUI, e.g.  $Config.MinFreeGB = 8  - it takes effect at the next
status check.  "Reload lists + patches" re-reads the group files and patches\ only.
  ToolName / ToolVersion / OperatorName  -> window title, banner, log header
  WinRMPort 5985      -> the HTTP WinRM listener; 5986 = HTTPS, every call then goes with -UseSSL
  OpenTimeoutSec      -> how long a silent server is given to open a session before we call it unreachable
  SilentServerSec     -> a read-only check gives up on a server that has not answered this long after
                         its turn began (unreachable with that reason; the others carry on) - Settings tab;
                         a check with a limit of its own (Impact 900 s, Analysis 300 s, a command at
                         CommandTimeoutSec) gives each server that long instead
  MaxParallel         -> servers checked at the same time (ThrottleLimit)
  RemoteStaging       -> folder created on the target where the .msu is copied (ACL locked down)
  MinFreeGB           -> below this the install is refused (DISM needs room)
  RequireValidSignature  -> the .msu must be Authenticode-signed by Microsoft (checked twice)
  AllowUnknownTargetBuild -> off: a file whose build cannot be read is blocked
  TreatPendingFileRenameAsReboot -> PendingFileRenameOperations is set by many installers and
                         AV products; it is NOT counted as "pending reboot" unless $true.
  ProgressEverySec / ProgressDetailEveryMin / InstallTimeoutMin -> the install wait loop
  PatchTypes          -> the patches\ sub-folders and whether the tool installs them
                         (Windows, DotNet = install; SQL, Exchange, Other = report only)
  ReportFolder / DataFolder / SoeFolder / SecurityFolder -> where reports, catalogues, SOE
                         standards and the security profile / tailoring live
  ConsoleColours / ConsoleText / ConsoleNames -> each console's colours and the name it is shown by
  BrandColour         -> the Fusetech blue: the frame round the window, the window icon (drawn at start-up,
                         no picture file) and the favicon of every HTML page
  SafetyChecks        -> the pre-action confirmations, in the order asked (topic B8)
  ChangeSystem / ChangeSystems / ChangeRequiredFields / ChangePolicy -> the change records (S9)
  LogShowCmd / LogShowWhy / LogKeepDays / MaxLogBoxChars -> the running log and the log files
  SettingsFile        -> settings\settings.json (what the Settings tab saved)
  Health thresholds   -> DiskWarnPercent, DiskFailGB, DiskSmallVolumeGB, UptimeWarnDays, EventErrorWarn,
                         EventWindowHours, LogonFailWindowHours, LogonFailWarn / LogonFailFail,
                         MaxEvents, TaskFailDays, DormantMonths, CertExpiryDays,
                         TimeOffsetFailSec, MemoryWarnPercent / MemoryFailPercent,
                         CpuWarnPercent / CpuFailPercent, CpuSampleSeconds, MaxProducts,
                         MinLogicalProcessors / MinMemoryGB / MinCpuScore (H-HW-01, hardware fit)
Shared state: $script:Credential (memory only, cleared when the GUI closes),
$script:Results[<collector>][<server>] (every collector result; $script:ServerStatus IS
$Results['Status']), $script:Groups, $script:Patches, $script:Checks (every check
definition), $script:Gui (the WinForms controls), $script:Operator (who is running the tool).
'@ }

    [pscustomobject]@{ Title = 'A6. PICTURE: the folder on the operator PC'; Source = ''; Image = 'images\3-operator-folder.png'; Explain = @'
Every file in the root folder and its one job.  lib\ is loaded in number order from an
explicit list; patches\<type>\ is yours to fill; data\ holds the catalogues the checks read;
soe\ and security\ hold what you compose (JSON, Notepad-friendly); settings\ what the Settings
tab saved; logs\ and reports\ are
written by the tool; software\ holds installers and changes\ the change log.  The yellow
box lists the variables you can inspect from the console while the GUI is open.
TRUST BOUNDARY: everything in this folder runs as you on every server.  Keep the folder
writable only by the operators.  Reports, logs, SOE standards and the security files contain
host names and findings - they are git-ignored on purpose.
'@ }

    [pscustomobject]@{ Title = 'A7. Write-PatchLog - one log, three outputs'; Source = 'Write-PatchLog'; Explain = @'
Every message goes to logs\Patcher-YYYYMMDD.log, to the console (colour) and to the
GUI log box.  The GUI part calls Application.DoEvents() so the window repaints while
a long job runs - that is the trick that keeps a single-threaded WinForms script alive.
AUDIT: the session header and every INSTALL / CONFIRM / RESULT / REBOOT / AUDIT line carry
the operator identity from Get-OperatorIdentity ("DOMAIN\user", plus "(WinRM as X)" when
alternate credentials are in use).  Each install also writes Application event 900
(source OfflinePatcher) and a result-*.txt on the server itself.  Saving a security profile,
a tailoring rule or an SOE standard logs who did it.  Passwords are never logged anywhere.
FAULT FINDING: the log file is plain text; search for [ERROR] or for a server name.
'@ }

    [pscustomobject]@{ Title = 'A8. Get-PatchGroups - reading the server lists'; Source = 'Get-PatchGroups'; Explain = @'
Any *.txt in the root folder is a candidate.  A line is a server if the part before the
first semicolon only has letters, digits, dots and dashes.  Comments start with #.  A few odd lines are
skipped with a warning that names them; a file that is mostly not host names (a README) is ignored.
The file name without .txt is the group name shown in every Group drop-down.
A server line may carry settings after the name, separated by semicolons (Read-GroupFile):
   srv-web01.corp.local; soe: Web tier; class: internet-facing   # comment
   soe:    the SOE standard the Health console compares THIS server with
   class:  internet-facing = the Security console applies the internet-facing rules
           (ML2 application control, two-week patch timeframe)
Two comment lines are the group-wide fallbacks for lines without their own:
   # class: internet-facing     # soe: Web servers
"Assign SOE standard..." on the Health console writes the soe entry (Set-ServerAttribute).
Names are de-duplicated case-insensitively (Get-UniqueNames), an IP address gets a
warning (no Kerberos), and the same first label written two ways (SRV01 and
srv01.corp.local) is flagged - the install de-duplicates again by the server's real
name after the status check so one box is never patched twice at once.
FAULT FINDING: a group missing from the drop-down?  Look for "Ignoring ... not a
server list" in the log - it names the offending line.
'@ }

    # =================================================================  PART B - PATCHING CONSOLE
    [pscustomobject]@{ Title = 'B1. Get-PatchFiles - scanning patches\<type>\'; Source = 'Get-PatchFiles'; Explain = @'
The tool creates five folders under patches\ and scans them one level deep:
   Windows\   cumulative updates, SSUs        -> installed by the tool (DISM)
   DotNet\    .NET Framework cumulative updates -> installed by the tool (DISM)
   SQL\       SQL Server CUs / GDRs           -> detected and reported only ("By hand")
   Exchange\  Exchange SUs / CUs              -> detected and reported only
   Other\     anything else you want tracked  -> detected and reported only
A file in the root of patches\ counts as Windows.  The KB number is pulled from the FILE
NAME with the regex (KB\d{6,7}), so keep the Microsoft Update Catalog name, e.g.
   windows10.0-kb5034770-x64_....msu   ->  KB5034770
A file without a KB in its name is skipped with a warning - just rename it.
For every installable file Get-PatchFileInfo reads, once, and caches in patches\_info\<file>.txt
(re-read when the size or date changes):
  TARGET BUILD   The name alone cannot say: Server 2016, 2019 and 2022 all use
                 "windows10.0-kb..." names.  expand.exe pulls the small .xml out of the
                 MSU (package versions like 20348.5614.1.3), or pkgProperties.txt
                 (Installer Version="10.0.20348.x"), or the SSU cab name.  A .NET rollup
                 names no build in those: its update.mum INSIDE the cab does (the parent
                 editions, 10.0.20348.1), read with a second expand.  14393 = 2016,
                 17763 = 2019, 20348 = 2022, 26100 = 2025.  Unknown = blocked, because
                 the file-name fallback cannot tell 2019 from 2022.
  SIGNATURE      Get-AuthenticodeSignature must say Valid AND the signer must be
                 Microsoft, otherwise "Blocked: signature".  Works offline.
  SHA256         used to verify the copy on the server and again right before DISM.
Report-only types get the signature check and a column in the grid; the cell says
"By hand" because SQL and Exchange setups need their own installers and service windows.
Mixed groups are fine: put the 2019 and the 2022 cumulative updates in Windows\ together
and each server gets a READY only in its own column.  DISM is the last line of defence
for a cumulative update - it refuses a wrong one with 0x800F081E.  NOT for a .NET rollup:
one for another build it takes as an empty wrapper, exit 0, nothing installed (field,
2026-11: the Server 2022 rollup on a Server 2019 toolkit PC), which is why the build is
read from inside its cab, and why an exit 0 without a reboot is checked against Get-HotFix
on the server afterwards.
This tool is OFFLINE: nothing is ever downloaded; you put the files there.
'@ }

    [pscustomobject]@{ Title = 'B2. Finding this month''s patch (catalog how-to)'; Source = ''; Explain = $script:PatchHowTo }

    [pscustomobject]@{ Title = 'B3. RemoteStatusScript - what runs ON the server'; Source = 'RemoteStatusScript'; Explain = @'
This script block is shipped to each server by Invoke-Command and executed there.
It must be self contained: it cannot see our functions or variables, only the
parameters passed with -ArgumentList.  It reads, with one exception: the scheduled task of an
OS patch run whose run marker says Finished (\WinRMToolkit\OSPatch-<stamp>) is removed - the
result files and the marker stay as the record (F3-03).
  Win32_OperatingSystem       -> caption, last boot time
  HKLM\...\CurrentVersion     -> CurrentBuildNumber + UBR  = e.g. 20348.2322
  Win32_LogicalDisk C:        -> free space
  Get-HotFix                  -> installed KB list (primary "is it installed?" source).  Only CBS
                                 packages still on disk: superseded cumulative updates drop off,
                                 so expect a SHORT list (current LCU, SSU, .NET, a few more).
  Microsoft.Update.Session    -> Windows Update Agent history = Settings > Update history.
     QueryHistory               Every install attempt ever, newest first (80 shown).  Read from
                                 the local database over COM, nothing goes online.  A KB whose
                                 newest entry is a successful Install counts as installed too.
  Registry keys               -> pending reboot.  HARD signs, always counted:
                                 CBS\RebootPending, CBS\PackagesPending, CBS\RebootInProgress,
                                 WU\RebootRequired, WU\PostRebootReporting, UpdateExeVolatile,
                                 a pending computer rename.
                                 WEAK sign, shown but not counted: PendingFileRenameOperations
                                 (PFRO) = files to rename/delete at next boot because they were
                                 locked.  AV products and installers add to it constantly and it
                                 is often left behind, hence "no (PFRO only, ignored)" in the grid.
  <staging>\software\result-*.txt -> the toolkit's own software runs (topic S7): a result written
                                 since the last boot with RebootRequired=True (exit 3010 / 1641)
                                 = SoftwareRebootPending.  The installer said a reboot completes
                                 it, but with the reboot suppressed Windows may set none of the
                                 flags above.  Kept apart from PendingReboot: it makes the reboot
                                 due (Get-PendingRebootText, Restart-PatchedServers) but does NOT
                                 block OS patches - they go first, one reboot finishes both.
                                 A successful REMOVAL since the last boot without a 3010 =
                                 RebootAdvised ("advised: removed X"), non-critical: an
                                 uninstaller often leaves a service marked for deletion or files
                                 for the next start.  It blocks nothing; the reboot button asks
                                 about such servers separately, No by default.
  \WinRMToolkit\WRT-* tasks   -> SoftwareLate: a software task finished after the tool stopped
                                 watching it (SoftwareTimeoutMin), with no result file yet - or
                                 with the Late=True result file a later run's sweep wrote for it.
                                 Read only; Update-SoftwareLateResults adds its real result to
                                 changes\change-log.csv on the PC while that item's newest row
                                 there is still the UNKNOWN (so once).  A 3010 / 1641 since the
                                 last boot also counts as SoftwareRebootPending.
  ServicingActive            -> somebody is servicing the box right now (another admin, Windows
                                 Update, a previous run).  Blocks installs and reboots.  Counted:
                                 dism.exe or wusa.exe running; TiWorker.exe ONLY while it is burning
                                 CPU (sampled over 2 s - it idles for minutes after routine
                                 maintenance, which is not servicing); the Windows Update agent's
                                 own "installing" flag (IUpdateInstaller.IsBusy).  A "Blocked:
                                 servicing" normally clears within a few minutes - re-check.
  Both update lists are sent as pre-formatted text lines because PowerShell remoting
  flattens nested objects to strings (serialization depth 1).  Every collector in the
  tool follows the same rule: flat text lines out, parsed on the operator PC.
  WHICH KB IS "THE" PATCH LEVEL?  None - the BUILD is.  The UBR (number after the dot in
  20348.5622) changes with every cumulative update and only moves after the reboot.  The
  "Newest hotfixes" column lists all Get-HotFix entries from the latest install date because
  the cumulative update and the .NET cumulative update land on the same day with different KBs.
Run it on THIS machine from the console to see the raw output:   & $RemoteStatusScript $false
'@ }

    [pscustomobject]@{ Title = 'B4. Invoke-Collector - the fan-out engine'; Source = 'Invoke-Collector'; Explain = @'
Every "ask the servers" action in every console is one call to Invoke-Collector: a NAME
(Status, Inventory, Health, Agents, Settings, SecurityPolicy), the self-contained script
block to run, the server list and an optional argument list.
One Invoke-Command with -ComputerName <many> -AsJob gives a parent job with one child job
per server, all running at the same time (up to MaxParallel).  We wait with Wait-PatcherJob
(which keeps the GUI alive and treats only Completed / Failed / Stopped / Disconnected as
finished), then harvest each child:
  * output received  -> reachable: the object is stored as $Results[<Name>][<server>] with
                        Reachable = $true, Error = '', Checked = now
  * no output        -> unreachable: Reachable = $false and the full error text (one line)
If a server answered "Access is denied" and no credential is stored yet, the tool asks ONCE
with Get-Credential (foreground) and retries just those servers.  A -Summary block turns the
raw result into the one [OK] log line per server ("build 20348.5622, 41 GB free ...").
Get-ServerStatus is a thin wrapper around this for the Status collector - kept by name
because the O/S Patching console and the log lines everybody reads are built on it.
Get-CollectorResult -Name X -Server Y returns the last result or $null; the checks never
read $Results directly.  Only objects that carry a Computer property count as results - a
stray string in the output stream is reported as "unexpected output", not stored.
ALONGSIDE AN INSTALL a collector started from a read-only button skips the servers being
installed on (a WHY line names them) and never offers the credential prompt: the install's
remaining sessions must keep the account the plan was made with.
FAULT FINDING: the CMD line in the log shows exactly what was sent.  Typical errors:
  "WinRM cannot complete the operation"  -> port 5985 (or 5986) blocked or service stopped
  "certificate ... unknown authority",
  "... does not match the CN"            -> WinRMPort is 5986: the listener's certificate must chain to
                                            a CA this PC trusts and carry the FQDN in the group file
  "Access is denied"                     -> account is not an admin on that server
  "Kerberos ... "                        -> use the FQDN in the group file.  Do NOT "fix"
                                            it with TrustedHosts=*; that turns off the
                                            check that you are talking to the right server.
'@ }

    [pscustomobject]@{ Title = 'B5. PICTURE: a status check, step by step'; Source = ''; Image = 'images\4-status-check.png'; Explain = @'
Three lanes: operator PC, the wire, target server.  One Invoke-Command fans out to every
server at once; on each server RemoteStatusScript reads the OS, build, disk, both update
lists, the reboot flags and the servicing processes - read-only, 2-5 seconds - and one
result object comes back per server.  The Health and Security collectors travel exactly the
same road; only the script block differs.  The two branches at the bottom are the only
things that ever go wrong at this stage: "Access is denied" (credential prompt, foreground)
and "no answer" (grey row, Test-WSMan button).
'@ }

    [pscustomobject]@{ Title = 'B6. Credentials - foreground only'; Source = 'Get-PatcherCredential'; Explain = @'
The tool never stores passwords on disk.  Get-Credential shows the standard Windows
dialog in the foreground, in the logged-on user's context.  The dialog belongs to the
console window, so it can appear BEHIND the GUI - the status bar says so, and the GUI is
brought back to the front afterwards.  If you cancel, the tool keeps using your current
Windows login (Kerberos single sign-on).  The credential is cleared from memory when the
GUI closes, so nothing is left behind in the console that started it.
Get-ConnectionArgs builds the same -Port / -SessionOption / -Credential set for every
call so all WinRM traffic is uniform - the Health and Security collectors included.
'@ }

    [pscustomobject]@{ Title = 'B7. Test-ServerWinRM - the no-auth check'; Source = 'Test-ServerWinRM'; Explain = @'
Test-WSMan sends a WS-Management "Identify" request.  WinRM answers it anonymously,
which is why "winrm get/enumerate" style calls worked without credentials in testing.
It proves: DNS resolves, the WinRM port is open, the WinRM service is running - and on 5986
that the listener's certificate is trusted here, because the probe goes with -UseSSL too.
It does NOT prove you are allowed in - that needs Invoke-Command.
'@ }

    [pscustomobject]@{ Title = 'B8. Confirm-SafetyChecks - the pre-action confirmations'; Source = 'Confirm-SafetyChecks'; Explain = @'
One Yes/No pop-up per step switched on in SafetyChecks (the Settings tab, first box), asked in
the list's order before every OS patch install, software install / update and removal:
   "Has a VMware SNAPSHOT been taken of every server below?"          on by default
   "Is TRELLIX SOLIDCORE in UPDATE MODE on every server below ...?"   on by default
   "Does AIRLOCK allow this change on every server below ...?"        offered, off by default
   ... and any step the operator adds (a backup job, a monitoring maintenance window).
Each names the servers; its title says "SAFETY CHECK 2 of 3 - <step>".  The default button is
No, so pressing Enter by accident can never approve.  -Activity names what is aborted (patching,
a software change, a removal); the questions are the same for all three.  With every step
switched off nothing is asked, and the log says so in a WARN line.
Any No -> the step's own "after a No" text, the function returns $false at once (the later
steps are not asked), Install-PatchOnServers returns without
opening a single session, and an [ERROR] ABORTED line with the operator's name goes in
the log.  With many servers the pop-up becomes a scrollable window with the same buttons.
A LESSON FROM THE REVIEW: a MessageBox RETURNS the button pressed.  The first version
showed an extra "Patching aborted" box without capturing its result, so the function
returned @('OK', $false) - which PowerShell treats as TRUE - and the install went ahead
after a No.  Every pop-up whose answer is not needed is now written  $null = Show-...
and the caller checks for a real [bool] $true.  Watch for this pattern in any script.
'@ }

    [pscustomobject]@{ Title = 'B9. Get-PatchVerdict - can it be installed?'; Source = 'Get-PatchVerdict'; Explain = @'
ONE function decides, and both the grid cell and the install plan call it, so they can
never disagree.  For every (server, file) pair, in this order:
  an open run on the server      -> INSTALLING (n min) for its KBs, Blocked: installing for the
                                     rest; RUN UNKNOWN / Blocked: run unknown once it ended without
                                     a result (settings\patch-runs.json - also with no status yet)
  not checked / unreachable      -> no verdict yet / "?"
  KB in Get-HotFix               -> Installed
  server build >= the KB's build -> Installed (build)   (data\product-patches.psd1 knows the build;
                                     a later cumulative update already contains it)
  KB in Windows Update history   -> Installed (history)  (unless the build is BELOW the KB's: removed again)
  report-only patch type         -> By hand  (SQL, Exchange, Other: the tool never installs these)
  a Dynamic Update (Safe OS)     -> Blocked: dynamic update  (a package for setup media and WinRE,
                                     read from the manifest inside: Kind; a running server's reboot
                                     undoes it - field test 2026-11)
  .NET file for another line     -> Not applicable  (the inventory's .NET line differs from the file's)
  pending reboot                 -> Blocked: reboot      (0x800F0922 territory otherwise)
  dism / TiWorker / wusa running -> Blocked: servicing   (re-check in a minute)
  Solidcore enforcing / unread   -> Blocked: Solidcore   (now OR on reboot; RequireSolidcoreUpdateMode)
  free space < MinFreeGB         -> Blocked: disk
  signature not Valid/Microsoft  -> Blocked: signature
  target build unknown           -> Blocked: OS unknown  (unless AllowUnknownTargetBuild, or a .NET
                                     rollup whose OS line is known)
  build does not match the server-> Blocked: wrong OS
  otherwise                      -> READY, or READY (staged) when the file is already on the server
New-PatchPlan turns the verdicts into the plan rows that are shown and logged.
The Help button on the O/S Patching tab (Get-PatchingHelpHtml, lib\20-Console-Patching.ps1)
draws every one of these cells the way the grid colours them, with the next step.
'@ }

    [pscustomobject]@{ Title = 'B10. Install-PatchOnServers - the orchestration'; Source = 'Install-PatchOnServers'; Explain = @'
  1. Fresh status check, duplicates by real computer name removed
  2. New-PatchPlan, logged line by line
  3. Plan pop-up (OK/Cancel), then the change record (S9): reference, approver, window
  4. Safety pop-up 1 - VMware snapshot        (strict: anything but a real $true aborts)
  5. Safety pop-up 2 - Trellix Solidcore Update Mode (the status check already read the
     mode: "Blocked: Solidcore" never reaches the plan; this is the human's word on top)
  6. Status check AGAIN - the pop-ups may have been open for minutes; any pair that is
     no longer READY is dropped.  With "Stop the Trellix Agent services first" ticked (the
     default) the two ePO agent services are now set to Disabled and stopped on each server
     (Invoke-TrellixAgentChange, under the install's change record; a server where that
     fails is dropped - B18).  Then, one server at a time: New-PSSession,
     RemoteStagingScript (C:\PatchStaging must be a real folder owned by admins; ACL
     locked to SYSTEM + Administrators), Copy-FileToSession ...
  7. ... and the moment that server's copy is verified, RemoteInstallLaunchScript writes
     install-<stamp>.ps1 (New-InstallTaskScript: this run's files, hashes, operator and
     change reference as literals, then the body of RemoteInstallScript) into the staging
     folder and starts it as the one-shot SYSTEM task \WinRMToolkit\OSPatch-<stamp> - so
     server 1 is already installing while server 2 is being copied, and the install
     belongs to the SERVER from then on: this session, this tool, this PC can go away.
     The run is noted in settings\patch-runs.json (Set-InstallFlag): the row turns cyan,
     the KB cell says INSTALLING, Get-PatchVerdict refuses another install meanwhile, and
     the note survives a restart of the tool.  The session is closed at once.
  8. Watch-PatchRuns, while "Auto-check status" is ticked: every N s (the field next to
     the box, changeable mid-run) RemoteRunStateScript reports the task's state, the run
     marker, the result files and the CBS progress; Resolve-InstallRun turns that into
     finished / running / unknown and Complete-InstallRun records a finished run (RESULT
     lines, change-log rows, flag cleared).  Unticking the box, "Let the servers go" on the
     status bar or InstallTimeoutMin end the watch - nothing stops on the server.  Ticking
     the box again (Request-PatchWatch) watches the open runs again (Resume-PatchWatch,
     after the action running then, if one is).  Any
     later status check (Update-InstallFlagsFromStatus, from RemoteStatusScript's
     PatchRuns / PatchResults lines) finishes the record - today, tomorrow, after a restart.
     A run that ended without a result stays flagged RUN UNKNOWN (purple) until "Analyse a
     failure" has looked at the server; the finish pop-up offers that at once.
  9. Fresh status check; a run the watch let go that finished meanwhile is recorded by it and
     joins the run's results (Get-ServerStatusWithRunResults) - one summary pop-up with one
     count (Show-InstallOutcome), one INSTALL FINISHED line

WHAT A GROUP RUN LOOKS LIKE (say 10 servers, one LCU)
  * Copies are sequential: about 3 min each at the default MaxEnvelopeSizekb (30 min for
    ten; STAGE the files ahead of the window and the window itself has no copy).  Each server's
    install starts as soon as its own copy is done, so by the time the last copy finishes
    the first servers are usually complete.
  * The log during the wait: ONE summary line every 45 s -
      "12 min elapsed - 7 servers installing, dism.exe alive on 7: CBS progress 23%..81% (avg 55%) on 6 of them"
    plus one line per server every ProgressDetailEveryMin (5 min).  With 3 servers or
    fewer the per-server line appears every poll.  The Patch-o-meter shows the average.
  * Then one RESULT line per server/KB, a fresh status check, and the summary pop-up.
  * While all that runs, every read-only button in every console still works (status
    checks, Health checks, Security audits, reports, details); PATCH IT!, Reboot, Reload
    and the credential buttons stay locked until the run finishes.
'@ }

    [pscustomobject]@{ Title = 'B11. Copy-FileToSession - the file goes over in slices'; Source = 'Copy-FileToSession'; Explain = @'
WHY NOT Copy-Item -ToSession?  Every WinRM request must fit inside the server's
MaxEnvelopeSizekb (default 500 KB).  Copy-Item -ToSession in PowerShell 5.1 sends
bigger requests and dies with "...exceeded the configured MaxEnvelopeSize quota".
WHAT WE DO INSTEAD
  1. Ask the server (RemoteFileInfoScript): is the file there, how big, and its
     MaxEnvelopeSizekb.  Only when the sizes match is the remote file hashed.
  2. Same size + same hash  -> nothing to copy.   Smaller -> resume from that byte.
  3. Slice size = 65% of the envelope, shrunk by the Base64 overhead (x1.37), rounded
     down to 16 KB: with the default 500 KB that is 224 KB per round trip.  Each slice is
     Base64 text passed as an argument to RemoteWriteSliceScript, which appends it.
  4. If the server still says "too big", the slice is halved and the copy resumes
     (six attempts, then a clear error naming the last slice size).
  5. Afterwards both sides hash the file; a mismatch DELETES the staged file and throws,
     so the next run starts clean and nothing is ever installed from a bad copy.
SPEED  A 560 MB LCU is ~2560 round trips; on a LAN that is a few minutes.  The slice size
follows whatever MaxEnvelopeSizekb the server has; the tool never changes it or suggests
changing it - it is the server owner's WinRM configuration.  (It limits one WinRM message,
not network frames: TCP splits every message into normal-sized segments either way.)  The
status bar shows MB sent and MB/s; the Patch-o-meter shows the percentage.
WITHOUT A SESSION  Pass no -Session and it copies locally through the same code path:
   Copy-FileToSession -Path .\patches\Windows\x.msu -Destination C:\Temp\x.msu -SliceKB 64
'@ }

    [pscustomobject]@{ Title = 'B12. PICTURE: an install, step by step'; Source = ''; Image = 'images\5-install-flow.png'; Explain = @'
The eight steps of PATCH IT!, left = operator PC, right = what runs on the server.  Step 2
is the only place a human says "go" (plan, change record, confirmations).  Step 3 re-checks
the servers, stops the Trellix Agent services (the box) and locks down the staging folder;
4 is the slice copy with its SHA256 check; 5 hands the install to the server as a one-shot
SYSTEM task - its guards (nothing else servicing, not even another toolkit task; Windows
Installer idle; no pending reboot; hash and signature re-checked), then expand + DISM, run
there whatever happens to this window.  Step 6 is the
watch while Auto-check is ticked (every N s, the field next to the box), step 7 the exit
codes and the result file - read now or by any later status check - and step 8 the reboot
button with its own guards.
'@ }

    [pscustomobject]@{ Title = 'B13. RemoteInstallScript - DISM on the server'; Source = 'RemoteInstallScript'; Explain = @'
WHY NOT wusa.exe?  Windows Update Standalone Installer refuses to run inside a WinRM
session (exit code 5 / 0x80070005).  DISM does not care.
GUARDS, in order, before anything is touched (each one throws = that KB is "failed"):
  1. dism.exe / TiWorker.exe / wusa.exe already running  -> somebody else is servicing
  2. hard pending-reboot keys set                         -> reboot first
  3. SHA256 of the staged file == the hash we copied       -> nobody swapped the file
  4. Get-AuthenticodeSignature Valid and signed by Microsoft (RequireValidSignature)
THEN
  expand.exe -F:* file.msu C:\PatchStaging\extract-KBxxxx-abcdef\   (unpack the container;
     the 6-char suffix comes from the file name so two files with one KB never collide)
  dism.exe /Online /Add-Package /PackagePath:<the .cab> /NoRestart /Quiet /LogPath:...
WSUSSCAN.cab is skipped (metadata only).  If a separate SSU cab exists it goes first.
A plain .cab in patches\Windows\ is passed straight to DISM.  .NET cumulative updates from
patches\DotNet\ take exactly the same road.
EXIT CODES (also in the log, one line per package):
  0           installed, no reboot needed - then the KB must be in Get-HotFix or the
              servicing store, else FAILED: a .NET rollup for another build goes in as
              an empty wrapper with exit 0 (field, 2026-11)
  3010        installed, REBOOT REQUIRED  (success!)
  0x800F081E  NOT APPLICABLE - wrong Windows build or missing prerequisite (failure)
  0x800F0922  failed - usually pending reboot, missing SSU, or full System Reserved partition
  anything else -> the last Error lines of the DISM log are copied into our log
If the SSU went in and the LCU then failed, the message starts with "PARTIAL" and lists
the packages that did install.
WHAT "STILL GOING" LOOKS LIKE  The DISM log (C:\PatchStaging\dism-KBxxxx-*.log) shows the
SSU install, then the LCU start, then "CBS session options=0x100!" - and then NOTHING for
the whole install, which is 10-30 minutes.  That silence is normal: CBS is doing the work
and writes its progress to C:\Windows\Logs\CBS\CBS.log as "Percent progress: NN".  The
tool reads that line every 45 s and logs it, together with whether dism.exe and TiWorker
are still busy.  To check by hand on the server:
   Get-Process dism, TiWorker
   Get-Content C:\Windows\Logs\CBS\CBS.log -Tail 3000 | Select-String 'Percent progress' | Select-Object -Last 1
AFTERWARDS the server writes C:\PatchStaging\result-KBxxxx-*.txt and Application event
900 (source OfflinePatcher) with the operator, KB and result - so the outcome survives a
lost connection.  On success the staged file and extract folder are deleted
(CleanupStaging); on failure they are kept, together with the DISM log, for you.
'@ }

    [pscustomobject]@{ Title = 'B14. PICTURE: what lands on the target server'; Source = ''; Image = 'images\6-endpoint-layout.png'; Explain = @'
Everything you will find on an endpoint during and after a patch: C:\PatchStaging\ and
what is inside the extracted MSU, the DISM log, the result file and the CBS log, the
registry keys the reboot flags and the build come from, the process chain while DISM
runs, the Application event the tool writes, and the two WinRM settings on the server
that matter.  Use it when you RDP to a server to look.  The Health and Security consoles
leave nothing of their own behind - no folder, no file, no event of the tool's.  What any
WinRM connection leaves: your profile folder on the server and logon events 4624 / 4672;
the Settings collector's feature query also writes to DISM's own log, and the secedit
export is deleted again before the collector returns.
'@ }

    [pscustomobject]@{ Title = 'B15. Restart-PatchedServers - reboot button'; Source = 'Restart-PatchedServers'; Explain = @'
Never automatic, and no longer "reboot whatever is ticked":
  1. A fresh status check of the ticked servers (duplicates removed).  A server whose OS
     patch run is still open (INSTALLING) is named and left alone - never rebooted from here.
  2. Servers that are PENDING A REBOOT are listed in a Yes/No pop-up (default No).
     Servers where a reboot is only ADVISED (software removed since the last boot) get their
     own Yes/No, default No.
  3. Servers that are NOT pending a reboot are listed in a SECOND pop-up and need their
     own explicit Yes - they are never rebooted by accident alongside the others.
  3b. With RequireSolidcoreUpdateMode, servers whose Trellix Solidcore is enforcing (or
     unreadable) are named in one more Yes/No: the update would be rolled back at this boot.
  4. The change record (S9) for the reboot - Cancel = no reboot.  One reboot finishes the OS
     patches and any software update that returned 3010 (the Software console's reboot
     button is this same function).
  5. On each server RemoteRebootScript refuses while servicing is really happening: dism,
     wusa or expand running, TiWorker actively using CPU, the Windows Update agent installing,
     or a toolkit task running in \WinRMToolkit\ (a
     reboot in the middle of CBS servicing is how a server ends up half patched), then
     schedules the restart with shutdown.exe /r /t 10 so the call returns before the
     connection drops - which is why the old Restart-Computer call sometimes logged
     "failed" for a server that was in fact rebooting.
  6. The toolkit PC itself (Test-ThisComputer, lib\03-Groups.ps1: localhost, 127.0.0.1, its
     name, its FQDN) is a managed server like any other, but nothing goes over WinRM to it:
     Invoke-Collector runs the collector here as a local background job (Start-Job),
     New-ToolkitSession hands the install and the software runs a LOCAL session marker that
     Invoke-RemoteBlock and Copy-FileToSession serve on this PC (a plain Copy-Item instead of
     slices), and Invoke-ToolkitCommand runs the reboot and the Trellix Agent script blocks in
     this process.  No listener on the toolkit PC, no loopback rights.  Its restart closes the
     toolkit, so the usual Reboot? question names it as this computer, it is sent last with a
     60 s countdown (shutdown /a cancels it), and the log and the change log are written first.
     The open run is on record (settings\patch-runs.json); the next status check after the
     toolkit is started again finishes it.  Every status check logs a WHY line for it.
The shutdown comment, Application event 920 and C:\PatchStaging\change-log.txt carry the reference.  Every REBOOT line in the log names the operator.  The stored status for that server is
thrown away because it is now stale.
'@ }

    [pscustomobject]@{ Title = 'B16. RemoteInventoryScript - roles, software, SQL and Exchange'; Source = 'RemoteInventoryScript'; Explain = @'
The Inventory collector (run by every Patching status check while the "Inventory (roles +
software)" tick box on the toolbar is on, and by the Health and Security consoles) reads,
read-only:
  Products     both Uninstall registry hives: Name|Version|Publisher|InstallDate|Location|
               KeyName|MSI|Quiet|Hive (the last four tell the Software console's UNINSTALL
               how, and in which hive: 7-Zip x64 and x86 share the key name "7-Zip")
               (capped at MaxProducts) - the raw material for software currency, dormant
               software and SOE standards
  Features     Get-WindowsFeature: installed roles and features (AD-Domain-Services tells the
               checks "this is a domain controller")
  .NET         the Release value under NDP\v4\Full -> 4.8 / 4.8.1, plus .NET runtimes found
  SqlInstances registry: instance name, version, patch level, edition - compared with
               data\product-patches.psd1 Sql table (CU / GDR currency, report only)
  Exchange     ExSetup.exe version -> the Exchange build table (report only)
  Services     Name|Display|StartMode|State|Account|Path   (also used by SOE and security)
  Processes    running image names   (dormant-software evidence, agent detection)
  Tasks        Path|Name|State|Result|LastRun|Action
Get-RoleSummary turns Features into "IIS, SQL, .NET 4.8.1" for the grid; Get-SoftwareRows
compares Products with data\known-apps.psd1 and with the rest of the fleet:
  Current      at or above the Latest version in the catalogue (or the newest in the fleet)
  Behind       a newer version is known, or another server runs a newer one
  Stale        installed long ago and nothing newer anywhere - verify with the owner; also an
               unknown product installed over UnknownStaleMonths (6) ago: updates likely waiting
  Ageing       an unknown product installed over UnknownAgeingMonths (12) ago: updates probably
               waiting, or no longer maintained - a cessation risk; confirm a patch source
  End of life  the catalogue's EOL date has passed
  Unknown      not in the catalogue, only one version in the fleet, installed recently
Keep data\known-apps.psd1 fresh by hand (it carries an AsOf date); the tool never goes online.
'@ }

    [pscustomobject]@{ Title = 'B17. Analyse a failure - where did it break?'; Source = 'RemoteFailureAnalysisScript'; Explain = @'
Field test, October 2026: an update installed (exit 3010), was rolled back at the reboot
(CBS.log full of poqexec.exe errors), and the second update of the run failed on the
pending reboot - with Trellix Solidcore in Update Mode by ePO's account.  Nobody could say
which control had denied what.  Three things came out of it:

  1. The Solidcore column (RemoteStatusScript runs "sadmin status", the one command the
     CLI answers in lockdown; Get-SolidcoreInfo reads the lines): the mode now and the mode
     ON REBOOT.  Enabled on either = "Blocked: Solidcore" on every KB and a separate Yes on
     the reboot button - the pending operations run at the boot under the on-reboot mode,
     and a Solidifier that is enforcing then denies poqexec.exe.  Read-only: the Update
     Mode task in ePO changes the mode, never the tool.
  2. One patch per server per run (Limit-PlanToOnePatch, Settings tab, on by default): the
     first ready file goes, the next waits for the reboot.  "First" is by what the package is
     (Kind, read from the manifest inside each file): a separate servicing stack update, then
     the cumulative update, then other Windows files, then .NET - never the smallest file
     first.  In the field (2026-11) a Dynamic Update went first for being the smallest and
     the reboot undid it, the servicing stack it needed being inside the cumulative update
     still waiting; a Dynamic Update is now Blocked: dynamic update and never installed.
  3. This page.  "Analyse a failure (ticked)" runs RemoteFailureAnalysisScript on the
     server (read-only, lib\21-Patching-Analysis.ps1) and brings back, for the last
     AnalysisHoursBack (72) hours:
       result-*.txt and dism-*.log   the tool's own records of each install
       CBS.log                       every Error line, every poqexec / Startup / rollback line
       the Setup event log           per package: reached Installed, or failed - and when
       the Windows Update history    with the HResult this time
       System log 6005/6006/6008/1074/41   boots, shutdowns, who asked for the restart
       solidcore.log                 every denied / blocked line with the process and the
                                     feature that denied it; the update-mode markers
       Application + System          events from McAfee, Trellix, Solidcore, Defender,
                                     CrowdStrike ... and the toolkit's own (OfflinePatcher)
       the state now                 pending-reboot flags, pending.xml, sadmin status
     Get-FailureFindings turns that into findings, worst first, each with WHERE it broke
     (the tool's run / at the boot / Trellix Solidcore / a security product / Windows
     Update / the state now), the evidence line and the next step; Get-FailureTimeline
     puts every dated line from every source on one list.  The page (Get-FailureAnalysisHtml)
     opens in the details window and is saved to reports\Analysis-<server>-<stamp>.html for
     the ticket.  The rules that matter most:
       - a package "successfully changed to the Installed state" in the Setup log and then
         a failure for the same KB = ROLLED BACK (red, "at the boot")
       - poqexec.exe lines with an error in CBS.log = the pending operations failed; with
         0x80070005 / ERROR_ACCESS_DENIED the text says a control denied them
       - a Solidcore line that denies poqexec / TrustedInstaller / TiWorker / dism = the
         smoking gun, with the feature named - the line the ePO team needs
       - a 3010 result followed by a failure that mentions a pending reboot = the second
         file of one run was refused by the first one's reboot flag
     Every source is also shown as the server gave it, so nothing is hidden behind a rule.
'@ }

    [pscustomobject]@{ Title = 'B18. The Trellix Agent services - stopped before, started after'; Source = 'Set-TrellixAgentOnServers'; Explain = @'
Field test, October 2026, second finding: the OS patch install only completed with the two
Trellix Agent (ePO agent) services - masvc "Trellix Agent Service" and macmnsvc "Trellix
Agent Common Services" - set to Disabled and stopped.  Most likely an ATP policy; the ePO
server kept no log of what the agent did and the client reports component status only, so
the cause stays open.  The tool therefore handles the two services, and nothing else of
Trellix (the Solidcore mode is read, never changed):

  the column      RemoteStatusScript sends one 'Name|DisplayName|State|StartMode' line per
                  service (TrellixAgentLines); Get-TrellixAgentInfo (04-Patches) reads them
                  into running / stopped / mixed and the cell text - Running (Auto), STOPPED
                  (Disabled), MIXED: ...  Stopped or mixed = the cell is orange in both
                  consoles, Get-ServerStatus writes a WARN line, a scan from the toolbar adds
                  a pop-up (Show-TrellixAgentWarning): ePO hears nothing from that server.
  the box         "Stop the Trellix Agent services first" on the O/S Patching and Software
                  tabs, ticked at start (StopTrellixAgentForInstall, Settings tab; unticking
                  it is named as a weakening).  Test-TrellixStopOn reads the tab's box.
                  PATCH IT! and INSTALL / UPDATE call Invoke-TrellixAgentChange -Mode stop
                  right after their second status check, under the install's own change
                  record: a server where the stop fails is not installed (fail closed; the
                  result row says why).  STAGE ONLY and UNINSTALL never touch the services.
  the buttons     "Start Trellix Agent (ticked)" and "Stop Trellix Agent (ticked)", wheat,
                  on both tabs: Set-TrellixAgentOnServers (below) - fresh status, the servers
                  it applies to (no agent / already so / unreachable are skipped; Start is
                  refused while an OS patch run is still open), one Yes/No naming them with
                  No as the default, Request-ChangeRecord for 'Trellix Agent services'
                  (Maintenance by default), the change, a fresh status, the summary.
  on the server   RemoteTrellixAgentScript: stop = Set-Service Disabled first (so nothing
                  starts them again, least of all the boot), then Stop-Service and a wait of
                  up to 90 s; start = Automatic on both first (a dependency must be
                  startable), then Start-Service and the wait.  Each service on its own; an
                  "access is denied" is reported with the hint that the agent's self-
                  protection may be on (an ePO policy).  The state is read back and sent; a
                  change writes Application event 940 and the line in change-log.txt.
  the reminder    Restart-PatchedServers names every rebooted server whose agent is disabled
                  ("start them when it is back"), Show-InstallOutcome counts them, the
                  Patching report keeps such a server off green.
  not used here   TrellixInUse off (Settings tab, Test-TrellixInUse): the grids leave out the
                  Solidcore and Trellix Agent columns as they are built; the boxes and buttons
                  are panel bands (Add-PanelBand) that Update-TrellixShown hides, moving what is
                  below up so no gap is left; Test-TrellixStopOn says no; Get-TrellixStoppedServers
                  names none, so the WARN line, the scan pop-up, the reboot reminder and the
                  outcome count go quiet; Get-SafetyChecks leaves a Trellix confirmation out; the
                  Help pages drop their Trellix rows and columns.  The Solidcore guard stays: it
                  acts only where Solidcore is found.
'@ }

    # =================================================================  PART S - SOFTWARE CONSOLE AND CHANGE RECORDS
    [pscustomobject]@{ Title = 'S1. The Software console - deploy, update, remove'; Source = 'Install-SoftwareOnServers'; Explain = @'
WHAT IT IS FOR
  Third-party software handled the way OS patches are: a new version is staged ahead of the
  change window, installed with the reboot SUPPRESSED, and the one reboot that finishes the
  OS patches finishes the software too.  The first package is VMware Tools, deployed by this
  tool instead of vCenter-managed upgrades.  Old or dormant software can be removed.

WHAT DECIDES WHAT
  data\software-packages.psd1   the only source of a command line: per package the folder,
                                the file pattern, the version source, the signer, the
                                allowed modes (Install, Update, Uninstall), the hardware it
                                needs, and the exact silent arguments
  software\<package Id>\        the installer files; each one is vetted (version, signer,
                                SHA256, reboot suppression) before it can be ticked
  Get-SoftwareVerdict           per server x installer: INSTALL / UPDATE / Installed /
                                N/A (hardware) / Blocked / Task running - grid, plan, report
  Get-UninstallVerdict          per product: MSI / quiet string / by hand / Protected / SOE

THE RUN (Install-SoftwareOnServers, below)
  1. Fresh facts: status, inventory and the software state (hardware, staged files, tasks)
  2. The plan (OK / Cancel), every server x installer with the reason
  3. The change record (S9) - Cancel = nothing happens
  4. The pre-action confirmations (B8) - No = an "aborted" row in the change log, nothing happens
  5. The facts AGAIN; anything that changed is dropped; "approved - starting" rows written
  6. Per server: a session, the locked staging folders, the verified copy
  7. Invoke-SoftwareRun: the run script queues the items as tasks (S6); polls collect the
     results and start the next item (S7); each result goes to the log and the change log
  8. A fresh inventory, so the grid shows the new versions
  STAGE ONLY stops after step 6 and asks for the plan only: nothing is installed.
  UNINSTALL (Uninstall-SoftwareOnServers) has the same steps without the copy, and a third
  confirmation that names every product, flagging the ones a service, process or task uses.
'@ }

    [pscustomobject]@{ Title = 'S2. PICTURE: a software run, step by step'; Source = ''; Image = 'images\11-software-run.png'; Explain = @'
The operator PC on the left, the server on the right, in the order things happen.  Steps 1
and 2 never touch a server.  From step 5 on, the server does the work as one-shot SYSTEM
tasks, so a dropped connection (the VMware Tools installer replaces the network driver) does
not stop it: step 6 reconnects and reads the result, from the result file if the answer was
lost.  Step 8 is the O/S Patching console's reboot, shared by both consoles.
'@ }

    [pscustomobject]@{ Title = 'S3. Finding software - VMware Tools first'; Source = ''; Explain = 'set by 50-Console-Software.ps1 ($SoftwareHowTo)' }

    [pscustomobject]@{ Title = 'S4. Get-SoftwarePackageFiles - vetting the installers'; Source = 'Get-SoftwarePackageFiles'; Explain = @'
The scan reads every folder under software\ - any name, spaces and sub-folders included.  A
package claims the files in its folder (Folder, else its Id) that match its FilePattern; any
other .msi or .exe is NEW (topic S10) and other file types are listed as not usable.  For
each claimed file it works out, once per file version (name, size, time) - and keeps it in
software\_info\vetting-cache.json (Read- / Save-SoftwareVettingCache), so a big library is
not read in full at every start, and the log names only new or blocked files:
  Version     from the file name (VersionRegex: VMware-tools-12.5.4-24964629-x64.exe gives
              12.5.4.24964629, the Uninstall key's DisplayVersion) or from inside the file
              (an MSI's ProductVersion through the Windows Installer COM object)
  Signature   Get-AuthenticodeSignature: Valid, and the signer's O= one of Signers
              (VMware or Broadcom for VMware Tools); AllowUnsigned only for an internal MSI
  SHA256      checked again on the server before the installer runs
Get-SoftwarePackageBlock gives the reason a file cannot be used: no readable version, a bad
or foreign signature, a mode list without Install or Update, or - for an .exe - arguments
that do not suppress the reboot (REBOOT=R, REBOOT=ReallySuppress or /norestart).  A blocked
file stays in the list with its reason and every cell for it reads "Blocked: file".
On a server each package stages into its own folder, C:\PatchStaging\software\<Id>\ (spaces as _),
so two installers that are both called setup.exe never share a path.
'@ }

    [pscustomobject]@{ Title = 'S5. Get-SoftwareVerdict - install, update or leave alone'; Source = 'Get-SoftwareVerdict'; Explain = @'
The Software twin of Get-PatchVerdict: ONE function, called by the grid, the plan, the
details page and the report.  For one server and one installer file, in this order:
  no inventory / unreachable       -> not checked / ?
  the file is blocked              -> Blocked: file
  Requires and hardware not read   -> not checked   (press Check)
  Requires and other hardware      -> N/A (hardware)  (VMware Tools on a physical server)
  installed, newer than the file   -> Newer x
  installed, the file's version    -> Installed x
  installed, older, Update allowed -> UPDATE -> y     (Go)
  installed, older, no Update      -> Behind
  not installed, Install allowed   -> INSTALL y       (Go)
  not installed, Update only       -> Not installed
  a toolkit task running there     -> Task running    (no Go)
  "(staged)" is added when the same file (name and size) is already in C:\PatchStaging\software.
The installed version comes from the Inventory collector's Uninstall keys (Match against the
DisplayName); the hardware from the SoftwareState collector (Win32_ComputerSystem).
'@ }

    [pscustomobject]@{ Title = 'S6. RemoteSoftwareRunScript - one SYSTEM task per item'; Source = 'RemoteSoftwareRunScript'; Explain = @'
WHY A SCHEDULED TASK AND NOT THE SESSION?
  The VMware Tools installer replaces the VMXNET3 network driver: the WinRM connection drops
  for a few seconds and anything running inside the session would die with it.  A one-shot
  task in \WinRMToolkit\ runs as SYSTEM with a full token, independent of the connection.
GUARDS, ONCE PER SERVER
  no toolkit task running, no queue of another run (under 3 h old), nothing servicing (dism,
  wusa, a busy TiWorker, the Windows Update agent), Windows Installer idle (the
  Global\_MSIExecute mutex), MinFreeGB free on C:.  Tasks an earlier run left behind are
  recorded on the server and removed: a finished one gets the result file the poll would have
  written (Late=True, under ITS change and operator, dated when it ran - so a 3010 stays a
  pending reboot and the status check still hands the exit code to the PC), a never-started
  one a "never started" line; a task still finishing (0x41301) is left alone.
PER ITEM
  install: the staged file exists, its SHA256 is the package's, its signer is allowed, the
  hardware matches Requires, the installed version still calls for Install / Update.
  removal: the Uninstall key still exists under the same name and DisplayName; MSI -> msiexec
  /x {code} /qn /norestart REBOOT=ReallySuppress; else its QuietUninstallString with that
  uninstaller's no-restart switches added ($noRestart: msiexec, Inno Setup, WiX bundles).
  The command line is built HERE from the catalogue's fields - {log} becomes
  C:\PatchStaging\software\sw-<run>-<n>.log - registered as a task (not started), a task-*.txt
  file beside it, and a START line in the server's change record.  Then the first task starts.
'@ }

    [pscustomobject]@{ Title = 'S7. RemoteSoftwarePollScript - results, the next item, the record'; Source = 'RemoteSoftwarePollScript'; Explain = @'
Asked every SoftwarePollSec (15 s) by Invoke-SoftwareRun.  For each task of the run:
  Running   how long, how big the installer log is
  Queued    never run (LastTaskResult 0x41303)
  Done      LastTaskResult is the installer's exit code: 0, 3010 (reboot needed - suppressed)
            and 1641 are success; 1603, 1618, 1619, 1638, 1639 ... are explained; a failure
            brings the log lines with "error", "failed" or "Return value 3"
A finished task is written down ON THE SERVER - result-<task>.txt, Application event 910 and a
line in C:\PatchStaging\change-log.txt, all with the change reference - then the task is
removed and, unless another item still needs it, the installer is deleted (CleanupStaging).
Only then the next queued task starts: Windows Installer runs one install at a time.
If the answer of a poll is lost, the next poll reads the result file back.  When the run
times out, -AbandonQueued withdraws the items that never started; a running one carries on.
The result files also feed the status check (topic B3): one written since the last boot with
RebootRequired=True makes the server's Pending reboot "YES: software: ..." until it reboots.
'@ }

    [pscustomobject]@{ Title = 'S8. Get-UninstallVerdict - what may be removed'; Source = 'Get-UninstallVerdict'; Explain = @'
UNINSTALL removes products ticked in the inventory list, and only what this function allows:
  Protected   ProtectedProducts in data\software-packages.psd1 (security and management agents,
              shared runtimes, SQL Server, Exchange ...), or a package that does not list
              Uninstall in its modes (VMware Tools)
  SOE         the server's SOE standard has a REQUIRED software item, or a required agent whose
              product patterns (data\soe-agents.psd1) match - optional items do not protect
  MSI         the Uninstall key is a product code {GUID} and WindowsInstaller = 1
  quiet string  the product has a QuietUninstallString whose uninstaller the tool knows how to
              keep from restarting the server; the run script adds the switches ($noRestart,
              the same block in RemoteInventoryScript and RemoteSoftwareRunScript):
              msiexec /norestart REBOOT=ReallySuppress, Inno Setup (unins000.exe) /NORESTART
              /SUPPRESSMSGBOXES, WiX bundles /norestart
  quiet (may restart)  any other QuietUninstallString: no known no-restart switch, so it may
              restart the server by itself - the plan and the last confirmation say so
  by hand     neither: the tool will not guess a command line
A removal never reboots on purpose; afterwards the server reads "advised: removed X" until it
restarts (topic B3), so the reboot that finishes the uninstaller's clean-up is planned.
WHAT THE UNINSTALLER LEFT BEHIND (Get-RemovalLeftovers)  Some uninstallers do not remove their
own service or task - an Inno Setup uninstaller has no service handling of its own, so the
service stays registered, a reboot or not.  After a successful removal the tool takes a fresh
inventory and lists every service whose program, and every scheduled task whose action, still
points INTO the removed product's folder (the folder plus "\", so "App Tools" is not inside
"App").  They go into the log, the change log ("left behind by the uninstaller: ...") and the
pop-up at the end.  Nothing is deleted by the tool; H-SVC-01 flags such a service too ("its
program no longer exists"), and sc.exe delete <name> on the Commands tab removes it under a
change record.
The Use column (Get-ProductUse, the rule of Health check H-SW-01): "in use (service X)" when a
service, process or task runs from the product's folder; "dormant" when nothing does and it
was installed over DormantMonths ago - the removal candidates.  The plan re-reads the
inventory first: a product that is gone or has a new key is dropped.
'@ }

    [pscustomobject]@{ Title = 'S9. Change records - Request-ChangeRecord and the change log'; Source = 'Write-ChangeLog'; Explain = @'
Before an OS patch install, a reboot, a software install, update or removal, or a command on the
Commands tab that may change a server, Request-ChangeRecord asks for the change it belongs to: the reference (a Jira key, a ServiceNow CHG number ...), the
system, who approved it, the window and a note.  It sits between the plan and the pre-action
confirmations; Cancel stops everything.  The last record is offered again, so one change window
is typed once.  THE SETTINGS TAB DECIDES (Get-ChangePolicy, Get-ChangeRecordGaps):
  ChangeSystem          filled into the form every time (not picked each time)
  ChangeRequiredFields  what must be filled in - Ref (the reference) by default; ApprovedBy,
                        Window and Notes can be required too.  A gap re-opens the form.
  ChangePolicy          per action: Required (the form); Maintenance (the form with a tick,
                        "Maintenance activity - no change required": the record reads
                        MAINTENANCE, no reference needed, the other required fields still are);
                        NotRecorded (no form; the record says so and Write-ChangeLog writes
                        no row - the running log still has every step).  STAGE ONLY in both
                        consoles is NotRecorded by default: it copies files and installs nothing.
WHERE IT IS KEPT
  changes\change-log.csv   Write-ChangeLog (below): one row per server per action - approved,
                           aborted, and every result - with the operator.  Append-only; a value
                           starting with = + - @ gets an apostrophe so Excel cannot run it
  each server              Application log, source OfflinePatcher: event 900 (OS patch), 910
                           (software), 920 (reboot, also the shutdown comment), 930 (command),
                           940 (the Trellix Agent services stopped or started);
                           and the line in C:\PatchStaging\change-log.txt (admin-only folder)
WHERE IT IS SHOWN
  every server's details page (Patching, Software, Health): its rows, newest first; the Change
  log button: every row, filterable, savable; the Software report: the rows of its servers.
'@ }

    [pscustomobject]@{ Title = 'S10. Registering software - NEW installers, Register and Edit'; Source = 'New-SoftwarePackageDraft'; Explain = @'
HOW A NEW PRODUCT GETS IN
  1. Its installer goes into any folder under software\ (software\Google Chrome\, Vendor\App\ ...).
  2. Reload: the scan finds a .msi / .exe no package claims and shows it as * NEW in a yellow box
     under the installer list (Update-SoftwareNewPanel), one row each with its own Register...
     button - it is not in the tickable list, because nothing is known about how to run it yet.
  3. Register...: Get-SoftwareFileFacts reads the file (signature and signer;
     ProductName / ProductVersion / Manufacturer from inside an .msi, the version resource of an
     .exe) and New-SoftwarePackageDraft, below, fills the form:
       Id, Name     the product name, made plain ASCII (a trademark sign becomes a space)
       Match        the same name with * for such signs; the list offers the names the fleet's
                    inventory has seen, because Programs and Features may say it differently
       FilePattern  the file name with its version-like parts as *  (Get-SoftwareNamePattern):
                    VMware-tools-12.5.4-24964629-x64.exe -> VMware-tools-*-*-x64.exe, so later
                    versions are picked up without registering again
       VersionFrom  msi for an .msi; name (with the matching VersionRegex) when the name holds a
                    version; else file (the .exe's ProductVersion)
       Signers      the O= of the file's signer; unsigned only by ticking it explicitly
       Modes        Install, Update and Uninstall.  A package without Uninstall protects its
                    product (Get-ProductProtection): right for VMware Tools, but an ordinary
                    application whose old version has to go would be stuck
  4. Every change in the form re-runs Test-SoftwarePackageDraft: a free Id, a usable folder,
     plain ASCII, the pattern matching the file - and Get-SoftwarePackageBlock, the scan's own
     vetting, on this very file.  The preview shows the exact command lines a server would run.
  5. Register: Add-SoftwarePackage finds the end of the Packages list with the PowerShell parser,
     inserts the entry there, leaves every other byte of data\software-packages.psd1 alone, reads
     the file back with Import-PowerShellDataFile and puts the original back if anything is off.
EDITING A REGISTRATION
  Every row of the installer list has its own Edit... (Update-SoftwarePackageList).  Edit-SoftwarePackage
  turns the entry back into a form draft (ConvertTo-SoftwarePackageDraft - a field the form does not
  show rides along) and opens the same form with -OriginalId, so the Id check ignores the entry's own
  name.  Save changes: Update-SoftwarePackage swaps that one @{ ... } for the new text.
  Get-SoftwarePackageEntry finds it with the parser and notes each comment written by hand with the
  field it belongs to, so the comments go back beside their fields; every other byte of the file stays.
  Register... and Edit... only record the job and start a 50 ms timer: the form opens after the click
  has finished, because saving rebuilds the rows - including the button that was clicked.
WHY NOT AUTOMATIC
  Registering decides which signer is trusted and which command line runs as SYSTEM on the
  servers.  A person confirms that once per product; after that, new versions are automatic.
'@ }

    [pscustomobject]@{ Title = 'S11. A big library - the packages shown and All packages'; Source = 'Get-SoftwareShownIds'; Explain = @'
THE UNIT IS THE PACKAGE, NOT THE FILE
  Get-SoftwareLibraryFiles: one installer per package - the ticked one, else the newest usable
  - for the whole library.  Get-SoftwareGridFiles: the packages shown, at most
  MaxSoftwareColumns (6; Settings tab).  Get-SoftwareShownIds (below) decides which: every
  package while the library is that small; else the operator's choice from the Software
  library window, kept in settings\software-shown.json; else the first by name.
WHAT THE CONSOLE SHOWS
  grid           one column per package shown, each cell coloured on its own
                 (Get-SoftwareCellColour: green = installed, yellow = to do, pink = blocked;
                 Set-GridRows -CellColourProperty), and - when the library is bigger - an
                 All packages column right after WinRM: Get-SoftwareSummary counts every
                 package's verdict ("3 to do (2 UPDATE, 1 INSTALL)"), the row's tooltip lists
                 them, and the row is yellow when anything at all is to do
  installer list the installers of the packages shown; a tick on a package no longer shown
                 is dropped (Get-CheckedSoftwareFiles reads only shown packages), so INSTALL
                 never acts on a tick the operator cannot see
  library window Show-SoftwareLibrary: every package with its counts over the servers shown
                 (Get-SoftwareLibraryRows) - update, install, current, not checked, newest
                 deployed - yellow where the library is newer than what is deployed; most to do
                 first; tick up to the limit (a NEW tick past it is refused), Most needed
  report         every package, always
WHY IT STAYS QUICK
  Get-SoftwareVerdictCached keeps each verdict under a key of the server, the times its
  status, inventory and software state were collected, and the file and its package: a
  refresh with nothing new is a table look-up, however many packages times servers.  A new
  scan of software\ empties it.  The vetting cache (topic S4) does the same for the files.
'@ }

    # =================================================================  PART C - THE CHECK ENGINE
    [pscustomobject]@{ Title = 'C1. New-Check and Invoke-Checks - how a check works'; Source = 'Invoke-Checks'; Explain = @'
A CHECK is one question asked of one server.  New-Check registers it in $script:Checks:
   Id        H-SVC-01, SEC-OS-02 ...        Console   Health or Security
   Title     the sentence in the grid       Group     the heading in details and reports
   Ism       ISM identifiers                ML        Essential Eight maturity level (0 = none)
   Severity  High / Medium / Low            Needs     collector names it depends on
   Test      { param($c) ... }              Fix       how to comply, in plain words
   Applies   all / dc / member / internet-facing       Data  anything the test needs (its table entry)
Invoke-Checks -Console X -Server Y builds ONE context object $c per server:
   $c.Status $c.Inventory $c.Health $c.Agents $c.Settings $c.SecurityPolicy  (collector results)
   $c.S      every Key=Value line of Settings + SecurityPolicy merged into one table
   $c.Check  the definition being evaluated (so a data-driven test can read $c.Check.Data)
then runs every check of that console and returns one row each: Verdict, Light, Evidence, Fix.
   collector missing      -> Verdict Error, "collector not available: Settings (reason)"
   Applies not matched    -> NotApplicable (grey) with the reason
   the test throws        -> Verdict Error with the exception text - shown, never swallowed
The -Resolve block (Security only) can change Verdict / Light / Note afterwards: that is where
the profile and the tailoring rules are applied (see the Security topics).
The verdict helpers are deliberately short so a test reads like a sentence; -Items carries the
separate findings, shown one per line on the details pages and in the HTML reports:
   if ($stopped.Count -eq 0) { return (Pass 'all automatic services running') }
   return (Fail ("{0} automatic service(s) not running" -f $stopped.Count) -Items $stopped)
WHY PLAIN SCRIPT BLOCKS: a closure (GetNewClosure) runs in its own module scope and cannot
see the toolkit's functions - the first Security build failed that way.  A test gets what it
needs through $c, never through captured variables.
Try it:  Invoke-Checks -Console Health -Server SRV01 | Format-Table Id, Light, Evidence -Wrap
'@ }

    [pscustomobject]@{ Title = 'C2. PICTURE: the life of a check'; Source = ''; Image = 'images\8-check-life.png'; Explain = @'
Six boxes, one check: the definition (code or a line in data\security-settings.psd1), the
collectors the Check / Audit button runs, the context object $c, the test and its verdict,
the resolve step that turns a verdict into a light (Health: fixed mapping; Security: the
profile's classification column, the maturity target and the tailoring rules), and the
places the row is shown.  The worked example follows SEC-OS-02 (SMB version 1) from the
expected value "False" to a red row and to the grey row a recorded risk decision would give.
'@ }

    [pscustomobject]@{ Title = 'C3. The data files - catalogues that replace the internet'; Source = 'DataFiles'; Explain = @'
The tool never goes online, so everything that would normally be looked up on a vendor page
is shipped as a plain data file in data\ (values only, never code, editable in Notepad):
  known-apps.psd1         third-party products: match pattern, latest version, cadence, EOL
  product-patches.psd1    latest cumulative update per Windows build (KB, UBR, release date),
                          end-of-support dates, .NET releases, SQL and Exchange build tables
  benign-services.psd1    automatic services allowed to be stopped, task result codes that
                          mean "fine", products ignored by the dormant-software check
  soe-agents.psd1         the agents every server should run (service, exe, product match)
  soe-config-points.psd1  the configuration points an SOE pins (update server, time source ...)
  software-packages.psd1  what the Software console may deploy, update or remove, and how
  security-settings.psd1  the expected value of every setting the Security console checks
  gpo-guidance.psd1       how to close each Security gap with Group Policy, and what could break
  command-cheatsheet.psd1 the Commands console's one-line commands
  ism-catalogue.psd1      GENERATED from the ISM annex spreadsheet (never edited by hand)
Each file carries an AsOf date.  Refresh them by hand (on a machine with internet, then copy
the file over) and the verdicts follow.  data\README.txt describes every field.
HOW THEY ARE READ  Import-ToolData parses a file once and keeps it until the file changes; an
edit to a catalogue shows at the next refresh.  The one exception is security-settings.psd1:
its entries become checks when the tool starts, so restart after editing it.
PowerShell's own Import-PowerShellDataFile stops with "Cannot generate a Windows PowerShell
object" once a file holds roughly 2,000 values (the ISM catalogue has 13,000), so files over
100 KB - and any file the standard loader refuses - go through Import-DataFileSafely: the
same file, parsed into a syntax tree and turned into values node by node; a command, an
expression or a variable other than $true/$false/$null is refused with its line number.
Nothing in data\ is ever executed.
The list below is rendered live from the data\ folder.
'@ }

    [pscustomobject]@{ Title = 'C4. Export-ConsoleReport - HTML + CSV'; Source = 'Export-ConsoleReport'; Explain = @'
Every console's Report button ends up here with a Summary (the rows of its main grid), one
or more Sections (name, rows, columns) and Notes.  The result:
  reports\<Console>-<yyyyMMdd-HHmmss>.html banner in the console colour, the operator and
                                           time, the notes, the summary table, then one
                                           table per section; a filter box searches every
                                           row; Light cells are coloured; inline CSS, no
                                           external files, opens anywhere offline
  reports\<Console>-<stamp>-<Section>.csv  one CSV per section (data only, UTF-8 with BOM
                                           so Excel reads it); a single section = one .csv
Arrays inside a cell become "a, b" so a CSV row stays one line.  Reports contain host names,
account names and findings: the folder is git-ignored and the footer says so.
'@ }

    # =================================================================  PART D - HEALTH CONSOLE
    [pscustomobject]@{ Title = 'D1. RemoteHealthScript - what the Health collector reads'; Source = 'RemoteHealthScript'; Explain = @'
"Check health (ticked or all)" runs Status + Inventory + Health on the servers; the Health
collector is this block (arguments: LogonFailWindowHours, MaxEvents, TaskFailDays,
CertExpiryDays, the task result codes that mean "fine", the event window, CpuSampleSeconds).
Read-only, 2-4 seconds plus the processor sample:
  StoppedAuto        Get-Service / Win32_Service: StartMode Automatic and not Running, with the
                     delayed-start and trigger-start services told apart; data\benign-services.psd1
                     lists the ones Windows itself leaves stopped.  For each, its program (from
                     PathName: quoted, or up to ".exe", %variables% and \SystemRoot\ expanded)
                     and whether that file still exists - a service whose program is gone was
                     left behind by an uninstall, and H-SVC-01 says to remove it (sc.exe delete)
                     rather than start it
  FailingTasks       Get-ScheduledTask + Get-ScheduledTaskInfo: tasks that ran within TaskFailDays whose last result
                     is not in TaskOkCodes (0, 267009 running, 267011 never run, 267045 ...; compared
                     as unsigned 32-bit numbers, so 0x8... codes can be listed too).
                     Codes are read as [int64]: 2147806724 overflows [int]
  LogonFailures      Security log event 4625 in the last LogonFailWindowHours, grouped by account
                     and source, capped at MaxEvents so a brute-force burst cannot stall the check;
                     LogonFailureTotal is the count the H-LOG-01 thresholds use
  Lockouts           Security log event 4740 (account lockouts) in the same window
  Disks              every fixed drive: size, free, percent
  ErrorCount/Top     Error and Critical entries in System + Application in EventWindowHours,
                     and the top sources
  TimeSource/Offset  w32tm /query /status /verbose: source, phase offset in seconds, and hours
                     since the last successful sync (computed on the server, not from the clock
                     of the operator PC)
  Certs              Cert:\LocalMachine\My certificates expiring within CertExpiryDays
  MemoryFreePct      free physical memory (and MemoryTotalGB); MemoryTop = the three processes with the
                     largest working set ("name|MB")
  CpuPercent         Win32_Processor.LoadPercentage read once a second for CpuSampleSeconds and
                     averaged - a snapshot, as H-CPU-01's evidence says; CpuTop = the three processes
                     that used the most processor time over the same seconds ("name|percent of the
                     machine", from the change in TotalProcessorTime - a process the account may not
                     inspect is skipped)
  Hw* / CpuScore     the hardware (sockets, cores, processor model and clock, machine model) and a
                     one-thread speed score: four million random integers sorted (Array.Sort, native
                     code, no cryptography) again and again for about a second - millions sorted a
                     second, with CpuScoreMs the time it took.  H-HW-01 holds the logical processors,
                     the memory and the score to MinLogicalProcessors / MinMemoryGB / MinCpuScore
                     (Settings tab): Microsoft's minimum installs Windows, it does not patch it in a
                     sensible time (field test 2026-11: 2 vCPU / 4 GB on a 2 GHz host at 100% for the
                     whole window).  The grid's Hardware and Speed columns show the figures
  Errors             every query that failed, with the reason - H-COL-01 shows them, so a
                     non-admin run or a locked-down log never looks like a clean bill of health
The same button runs the Agents collector (RemoteAgentsScript), the Settings collector
(RemoteSettingsScript) and the Probe collector (RemoteProbeScript: the configuration points of
data\soe-config-points.psd1 and of every standard - registry values and config-file lines,
nothing executed).  Their results feed the SOE standard check (H-SOE-01) and the Security console.
Run it on THIS machine:  & $RemoteHealthScript 24 500 7 30 @(0)
'@ }

    [pscustomobject]@{ Title = 'D2. RemoteSettingsScript - over 100 facts about a server'; Source = 'RemoteSettingsScript'; Explain = @'
One collector, one flat list of Key=Value lines, used by three things: the SOE "setting"
items (any key can become an SOE rule), the Health checks (time, uptime) and most of the
Security checks (hardening).  It reads registry values, Windows features, Defender,
AppLocker, LAPS, event-log sizes, TLS, SMB, RDP, WinRM, UAC, LSA, PowerShell logging ...
A value it cannot read is reported as ERROR:<reason> or Unknown - the checks turn that into
a Warn with the reason, never into a Pass.  Values that are simply not set come back as
NotConfigured, which the Security table treats as "the OS default applies" (Warn unless the
entry says NotConfiguredOk).
The complete key list is in the next topic; it is rendered from this block so it cannot be
out of date.  Run it on THIS machine:  (& $RemoteSettingsScript).Lines
'@ }

    [pscustomobject]@{ Title = 'D3. Settings keys - the complete list'; Source = 'SettingsKeys'; Explain = @'
Every key the Settings collector produces, read from the collector's own source right now.
Fixed keys are listed first; keys built in a loop (one per firewall profile, TLS protocol,
event log, Windows feature, AppLocker collection) are shown as the pattern that makes them.
Use these names in data\security-settings.psd1 (Key = ...) and in SOE "setting" items.
'@ }

    [pscustomobject]@{ Title = 'D4. Health checks - the catalogue'; Source = 'Checks:Health'; Explain = @'
The Health checks (17 at the time of writing), rendered from $script:Checks so the list below IS the code.
Lights in the Health tab are fixed: Fail = Red, Warn = Amber, Pass = Green, otherwise Grey.
The thresholds are in lib\01-Config.ps1 (A5); the lists of benign services, task codes and
ignored products in data\benign-services.psd1.  Double-click a server on the Health page
for every check with its evidence and fix.
'@ }

    [pscustomobject]@{ Title = 'D5. PICTURE: Health sources and SOE standards'; Source = ''; Image = 'images\9-health-and-soe.png'; Explain = @'
Left: where every Health number comes from and which threshold judges it.  Right: how an
SOE standard is composed - from one scanned server, from the fleet majority, or by hand -
what the JSON file holds, and how Compare-SoeStandard turns it into lights.  The bottom
boxes explain the terminology (Windows' own names, so Event Viewer and the tool agree) and
the Health lights.
'@ }

    [pscustomobject]@{ Title = 'D6. SOE standards - Compare-SoeStandard'; Source = 'Compare-SoeStandard'; Explain = @'
An SOE standard is a list of RULES, not a golden server.  It lives in soe\<name>.json
(several standards allowed; the group file's "# soe: <name>" line says which one a group
is compared with; a server line's own "; soe: <name>" overrides it - "Assign to servers..." and
"Assign SOE standard..." write that entry for you).  Item types:
   software    product name pattern + version rule (">= 10.7", "= 24.08", or any) + required?
   service     service name, must it run, expected start type
   agent       one of data\soe-agents.psd1 (name + version rule)
   feature     a Windows feature that must be installed
   setting     a Settings-collector key + the expected value (TimeZone, PowerPlan, RDP.NLA ...)
   registry    a registry key + value name + the expected value (WSUS server, KMS host, NTP ...)
   file        a config file + setting name (or re:<regex>) + the expected value (Zabbix Server=,
               Splunk outputs.conf server=, the Trellix site list ...) - read, never executed
   forbidden   a product pattern that must NOT be present (TeamViewer*, ...)
COMPOSING ("SOE standards" page - composing only): New -> then "Add from server..." (pick
from a checked server's software, services, agents, features, settings and configuration
points: Get-SoeCandidates), "Add fleet agents" (the agents and versions most servers share:
Get-FleetAgentItems), "Add by hand..." (the item editor: a Type list, under it only the boxes
that type uses; a list wherever the value must match exactly - the agents of soe-agents.psd1,
the keys the Settings collector writes, start types, states; for a registry or file rule the
known configuration points fill the path and the key; a Help button; Set-SoeItemEditorType,
Get-SoeItemProblem; a table that lays itself out at any display scaling), or tick rows in the
lower pane, PIN FROM THE REFERENCE SERVER: what one
checked server has.  "Show:" picks the CONFIGURATION POINTS it answers (data\soe-config-points.psd1
lists the registry values and config-file lines an SOE deployment customises per server - which
WSUS, KMS, NTP, monitoring or security server, the DNS suffixes, SNMP contact, the page file ...;
a point the server does not have, Zabbix's file on a server without Zabbix, is left out so the
pane never reads as if the agent were there - the "(all ...)" mode lists every point so a value
can be typed), or its installed SOFTWARE with versions, AGENTS, FEATURES, SERVICES or SETTINGS;
"Add to the standard (ticked)" turns each row into a rule (a point: "every server must have this
value"; a product: ">= this version", through ConvertTo-SoeItem).  The reference list is refilled
only from a console repaint, never from the box's own events (Update-SoeRefCombo: a type-ahead box
whose items change inside its own event took the tool down in the field).  Every addition, edit
or removal is written to soe\<name>.json at once - there is no separate Save step.  Standards are
ordinary JSON - edit in Notepad too.  The label says which groups use the selected standard.
COMPARING happens on the Health checks page, with "Check health": check H-SOE-01 holds each
server to the standard on its own group-file line ("; soe: <name>", set from the list with
"Assign SOE standard...", which writes the line), or to soe\default.json when the group
names none (DefaultSoeStandard in 01-Config.ps1), and Compare-SoeStandard
gives one row per item: Expected, Actual, Verdict, Light, Note.  Compare-VersionRule does the
version arithmetic ("Compliant / Below / Above / Different / Unknown"); a registry or file
rule is compared as plain text, with a * wildcard, or as re:<regex> (Test-SoeRegex: a
search, case ignored - ^ and $ make it the whole value; as the setting name of a file rule
the pattern finds the value in the file, the first (group) of the first match).  The SOE column, the
server's details page and the Health report show the result.  A new server joins the fleet
when it goes green against the standard; a drifted server shows exactly which item drifted.
'@ }

    [pscustomobject]@{ Title = 'D7. Get-SoeCandidates - what a server offers a standard'; Source = 'Get-SoeCandidates'; Explain = @'
"Add from server..." lists everything the collectors know about one server as candidate
items: each installed product (with its version as the suggested rule), each automatic
service, each agent found, each installed feature, every Settings key with its current
value, and every configuration point of the catalogue with the value the server returned.
A filter box and a type drop-down narrow the list; ticked candidates become items
through ConvertTo-SoeItem, which records where the item came from (Source = the server) so
a reviewer can see which server the rule was copied from.  Nothing is written to the server.
'@ }

    [pscustomobject]@{ Title = 'D8. RemoteProbeScript - configuration points'; Source = 'RemoteProbeScript'; Explain = @'
The one collector that reads what YOU ask for: the probe list is the catalogue
(data\soe-config-points.psd1) plus the registry and file items of every standard, as lines
   registry|HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate|WUServer
   file|C:\Program Files\Zabbix Agent\zabbix_agentd.conf|ServerActive
   file|C:\ProgramData\McAfee\Agent\SiteList.xml|re:ServerName="([^"]+)"
and the answer is the same line with the value appended: the registry data (a value name of
* lists every value as name=data), the first "Key = value" line of the file outside # and ;
comments, or the first capture group of the regular expression.  Not readable comes back as
words, never as a guess: NotConfigured, file missing, key missing, ERROR: <why>.
It reads registry values and files up to 2 MB.  It never runs a command, so a standard that
somebody edited by hand can only make it READ - that is the whole trust boundary of SOE
standards, and why there is no "command" item type.
Compare-SoeStandard turns the answer into the verdict: Compliant, Setting differs, Missing
(required and not there) - or Not checked when the server has not been probed yet.
Run it on THIS machine:  & $RemoteProbeScript ([string[]](Get-SoeProbeList))
'@ }

    [pscustomobject]@{ Title = 'D9. RemoteGpoScript - what Group Policy does on a server'; Source = 'RemoteGpoScript'; Explain = @'
One read-only collector ('Gpo', lib\13-GroupPolicy.ps1) for two consoles.  "Check health" and
AUDIT both run it.  What it reads, and from where:
  Gpos             HKLM\...\Group Policy\State\Machine\GPO-List: the GPOs of the last computer
                   policy run in the order they applied (0 = the local policy), each with where it
                   is linked (SOM), its version, and whether it applied - AccessDenied = security
                   filtering, WQLFilterPass = 0 = a WMI filter said no, GPO-Disabled.  Readable
                   without an administrator.  A version is two halves: computer edits (low 16 bits)
                   and user edits (high 16 bits).
  Extensions       ...\State\Machine\Extension-List: each client-side extension (Registry =
                   administrative templates, Security, Audit Policy Configuration, Preferences ...)
                   with its last result code (0 = OK; Format-GpoStatus turns 1355 into "the
                   specified domain either does not exist or could not be contacted") and end time.
                   The core extension {00000000-...} ends every refresh: its time is LastRefresh.
                   Registry DWORDs can arrive as negative Int32s or larger numbers - $u32 folds both
                   into the unsigned value (a FILETIME is two of them).
  Events           Group Policy errors and warnings (levels 1-3) in the System log and the
                   Group Policy log within EventWindowHours.
  SecureChannel    Test-ComputerSecureChannel - a broken trust stops every policy refresh.
  Rsop             root\rsop\computer (an administrator is needed; RsopError says why not):
                   which GPO sets which value, winning settings only (precedence 1) -
                   R administrative templates, S account policy, V security options, U user rights,
                   A legacy audit, G each GPO's extensions; D = the advanced audit policy Group
                   Policy applied (%windir%\security\audit\audit.csv - RSoP has no class for it).
HEALTH reads the first four: H-GPO-01 (an extension failed or a GP error = Red, warnings =
Amber), H-GPO-02 (no refresh for GpoStaleHours = Amber, 7 x that = Red), H-GPO-03 (secure
channel), the GPO column and the Group Policy page (Get-GpoFleetRows, Get-GpoServerRows).
A workgroup server answers Joined = $false and the three checks are not applicable.
SECURITY reads Rsop through Get-GpoSettingSource: "which GPO sets this" for a spec such as
'V:MACHINE\System\CurrentControlSet\Control\Lsa\LmCompatibilityLevel' - and, when the RSoP could not
be read, Known = $false, so "missing from Group Policy" is never claimed on a guess (topic E7).
Run it on THIS machine:  & $RemoteGpoScript 24 3000
'@ }

    [pscustomobject]@{ Title = 'D10. The Health summary - dials and what needs attention'; Source = 'Get-HealthAttentionRows'; Explain = @'
Under the Health checks page's grid, behind a divider (a SplitContainer with FixedPanel = Panel2,
as on the Security Servers page), New-HealthDashboard sums up the servers shown (lib\30-Console-Health.ps1).
THE DIALS - Get-HealthCapacity reads one server's three figures from the Health collector:
  Processor  CpuPercent  (Win32_Processor.LoadPercentage once a second for CpuSampleSeconds, averaged)
  Memory     100 - MemoryFreePct
  Disk       % used of the volume the disk check is about (Get-HealthWorstVolume: the one under
             the limits, else the fullest judged - a volume smaller than DiskSmallVolumeGB, a
             recovery partition given a letter, is listed and never moves the dot)
and takes each one's BAND from its own check - H-CPU-01, H-MEM-01, H-DSK-01: Pass = within,
Warn = warning, Fail = critical - so a dial can never disagree with the grid.  New-HealthGauge
draws a 270-degree dial with System.Drawing: zones from Get-HealthThresholds (the Settings tab
values turned into "% used"; the disk has no red zone because its critical limit needs DiskFailGB,
a size, as well as the percentage), a dot per server in its band's colour, the range from lowest
to highest as a dark band inside, the highest reading in the middle.
NEEDS ATTENTION - Get-HealthAttentionRows (below) walks every shown server's check rows (from the
cache the grid just filled) and keeps the red and amber ones, one row per check: Critical when
any server has it red ("2 of 3, 1 critical"), else Warning; plus Unreachable and Not checked.  A
check with no verdict (Error: a collector missing or refused) is folded into one "Checks that
could not run" row instead of one row per check.  Critical first, then by how many servers.
Get-HealthAttentionHtml is the double-click page: every server with the finding, the fix.
Only the Level cell is coloured - the word says it, the colour repeats it once.
'@ }

    # =================================================================  PART E - SECURITY CONSOLE
    [pscustomobject]@{ Title = 'E1. PICTURE: the Security console pipeline'; Source = ''; Image = 'images\10-security-pipeline.png'; Explain = @'
Top: the ISM annex spreadsheet becomes data\ism-catalogue.psd1, generated offline.  Middle: the 89 expected values, the 29 code checks and the collectors that feed
them.  Then the profile (what applies, what is red) and the tailoring file (recorded risk
decisions), and the one table that decides every light.  Bottom: the controls that cannot
be assessed from a server, and the pages the tab offers (Servers, Controls, Server config - one column per ticked server - Tailoring, Security profile; the GPO recommendations page came later, topic E7).
'@ }

    [pscustomobject]@{ Title = 'E2. RemoteSecurityPolicyScript - auditpol and secedit'; Source = 'RemoteSecurityPolicyScript'; Explain = @'
The one collector the Security console adds.  Both tools need an administrator; if they
refuse, the result carries the reason and every check that needs them says "not collected
(auditpol returned no rows - run as an administrator?)" - a Warn, never a Pass.
  auditpol /get /category:* /r    CSV: one row per subcategory -> Audit:<Subcategory>=<setting>
                                  e.g. Audit:Logon=Success and Failure
  secedit /export /cfg <tmp.inf>  the local security policy as INI text, deleted afterwards:
     [System Access]      -> Sec:<name>       Sec:LockoutBadCount=5, Sec:MinimumPasswordLength=14
     [Privilege Rights]   -> Right:<privilege> Right:SeDebugPrivilege=*S-1-5-32-544 (SIDs)
     [Registry Values]    -> Reg:<leaf>        the type prefix (1, / 4, / 7,) and quotes stripped
     [Event Audit]        -> LegacyAudit:<name> (the nine old categories, for reference)
The lines join the Settings lines in $c.S, so a check reads $c.S['Audit:Logon'] exactly
like $c.S['SMB.SMB1'].  GPO wins over local policy, and that is what these tools report:
the EFFECTIVE policy on the server, which is what an auditor asks for.
Run it on THIS machine (elevated):  (& $RemoteSecurityPolicyScript).Lines
'@ }

    [pscustomobject]@{ Title = 'E3. Test-SettingRule - the 89 expected values'; Source = 'Test-SettingRule'; Explain = @'
Each entry of data\security-settings.psd1 becomes one check (Register-SecuritySettingChecks)
whose test is this function, with the entry as $c.Check.Data.  Fields:
   Id Group Title    Key (a collector key)    Op + Expected    Ism  ML  Severity  Fix
   Applies (dc / member)    NotConfiguredOk ($true when the OS default already complies)
   ExpectedAt @{ S = ..; TS = .. }  the value the ISM asks for at that classification (the password
                            length: 15, then 17 on SECRET and 20 on TOP SECRET)
   ML                       the Essential Eight level the check evidences = the lowest ML among the
                            ISM controls it cites (every id must be in the catalogue)
Operators:  eq ne ge le (numbers compared as numbers)   between '1-900'   in 'a;b;c'
            contains   subset (every member of the actual list is allowed: user rights)
            match (regex)   report (show the value, never fail)
Missing or unreadable values never pass quietly:
   ERROR:<reason>           -> Warn "could not read <key> - <reason>"
   not collected at all     -> Warn with the collector's own reason (auditpol / secedit refused,
                               older OS, missing module)
   Unknown                  -> Warn "could not read <key>": the collector's query failed, so
                               the value is NOT READ - it is left out of the compliance figures
                               and gets no GPO recommended (Test-UnreadEvidence in 10-Checks)
   NotConfigured            -> Warn "the OS default applies" unless NotConfiguredOk, or the
                               expectation is "empty" / "anything but X"
A tailoring rule with action "threshold" replaces Expected for one check and scope
(Get-TailoredExpected) - the entry in the file stays as the organisation's standard.
'@ }

    [pscustomobject]@{ Title = 'E4. Security checks - the catalogue'; Source = 'Checks:Security'; Explain = @'
All Security checks rendered from $script:Checks: the 89 expected-value checks (their "why"
line shows the key, operator and expected value), the code checks (application control,
antivirus and EDR, firewall, LAPS, local administrators, built-in Administrator, service
accounts, event forwarding, time service, OS support and release, Internet Explorer 11,
patch timeframes, and at SECRET and above the cryptography and wireless checks SEC-CRY-01..05
and SEC-WLS-01) and the seven "not assessable from the server" controls.
ML is the Essential Eight maturity level a control belongs to (0 = not an Essential Eight
control); Severity High makes a failure Red regardless of the maturity target.
'@ }

    [pscustomobject]@{ Title = 'E5. Resolve-SecurityRow - profile, tailoring and the lights'; Source = 'Resolve-SecurityRow'; Explain = @'
Every Security row passes through this function after its test.  Three inputs:
THE PROFILE  security\profile.json (the Security profile tab of the console)
   classification        Non-classified / OFFICIAL / OFFICIAL: Sensitive / PROTECTED / SECRET /
                         TOP SECRET -> the catalogue column (NC OS P S TS).  A control whose
                         column is $false at your classification becomes NotApplicable (Grey).
   maturityTarget 1-3    a FAILED Essential Eight control with ML at or below the target is Red
   internet-facing       per SERVER, not in the profile: the Security profile tab ticks write
                         "; class: internet-facing" onto the server's group-file line (SEC-AC-01,
                         SEC-PAT-01 two weeks); a group's "# class:" line is the fallback (Get-ServerClass)
TAILORING  security\tailoring.json ("Tailoring (risk decisions)" page) - OpenSCAP-style:
   rule = check + scope (all / group:<name> / server:<name>) + action + reason + by + date + review
   disable    the row becomes RiskAccepted (Grey) with the reason and reviewer in its Note
   downgrade  a Red becomes Amber (a compensating control exists)
   threshold  another expected value for an expected-value check
   A rule whose review date has passed - or that has no readable review date - shows Amber with
   "REVIEW OVERDUE" (disable) or stops applying (downgrade, threshold) until it is renewed.  A
   reason is mandatory - it is a recorded decision.
THE LIGHT
   Red    Fail where (ML > 0 and ML <= maturityTarget) or Severity = High
   Amber  any other Fail, every Warn, a downgraded Red, an overdue acceptance
   Green  Pass
   Grey   NotApplicable, NotAssessable, RiskAccepted   (a check that threw an error is Amber, never hidden)
The worst light of a server is its row colour on the Servers page; the Controls page does the
same per check across the servers shown; the Pass rate is Green / (Red + Amber + Green), rounded down - a pass rate, not the compliance percentage of the dashboard, which counts accepted risks too.
Both JSON files are read once and re-read when they change on disk ("Reload from file").
'@ }

    [pscustomobject]@{ Title = 'E6. The ISM catalogue - Get-IsmCatalogue'; Source = 'Get-IsmCatalogue'; Explain = @'
data\ism-catalogue.psd1 holds every ISM control: Id, Section, Topic, Rev, Updated, ML
(Essential Eight maturity level or 0), the applicability columns NC / OS / P / S / TS, and the
control text.  It is GENERATED from the ISM annex spreadsheet (cyber.gov.au, "System security
plan annex template") and never edited by hand; the typographic quotes and dashes of the
spreadsheet are turned into plain ASCII (PowerShell treats a curly apostrophe as a string
delimiter).  Its header names the ISM release it was generated from.
Get-IsmCatalogue (below) reads it with Import-DataFileSafely - PowerShell's own loader gives up
on a data file this large - once per session.
Source material: Australian Signals Directorate, Information Security Manual, (c) Commonwealth
of Australia, licensed under Creative Commons Attribution 4.0.
In the console the catalogue gives: the ISM wording under every red or amber row in the
details window and the report, and the classification columns the resolver uses.
'@ }

    [pscustomobject]@{ Title = 'E7. GPO recommendations - the gap, the GPO, the impact light'; Source = 'Get-ImpactVerdict'; Explain = @'
The GPO recommendations page answers three questions per security setting and server
(Get-GpoGapRows, lib\45-Security-Gpo.ps1):
1. WHERE IT STANDS.  The check's verdict plus Get-GpoSettingSource (topic D9) on the guidance's
   Rsop spec: Missing from GPO (fails, no GPO sets it), Weaker in GPO (fails, a GPO sets it -
   "Set by now"), Not enforced (passes, nothing keeps it so), Enforced (no gap), Not compliant
   (not a Group Policy setting - a feature, firmware, Preferences - or the RSoP was not readable),
   Not read (the audit could not read the value: no recommendation on a guess).  Not applicable
   and risk-accepted checks are left out.
2. HOW TO CLOSE IT.  data\gpo-guidance.psd1: the recommended GPO (one per area, "Server Baseline -
   ..."), the path in the Group Policy Management Editor, the value, and what could break.
3. WOULD THE IMPACT BE FELT HERE.  Get-ImpactVerdict (below) asks the entry's impact checks
   (Get-ImpactProbeResult; the list is $ImpactProbes): Remote ones come from the Impact collector
   (topic E8), the others from what was already collected - SecurityLogSize (Settings),
   LockoutRisk (the Health collector's failed logons), RightHolders (the accounts a user right
   would be taken from, from the actual and expected value), DiskForLogs (Status).
   InUse anywhere = "Impact found" (red); not collected = "Not checked" (grey); Review or Unknown =
   "Check first" (amber); else "No impact found" (BLUE).  No impact check at all: the guidance's
   Expect - None / Low = "No impact expected" (blue), Review = "Check first".  A server that already
   complies is blue too: a GPO changes nothing there.  GREEN is kept for "Enforced" (a GPO sets it):
   a colour must never suggest a setting is in place when it is not (operator feedback 2026-10-22).
   Found = the answers that decided it - what the page's Impact details shows.
4. ITS VALUE NOW.  Get-GuidedNow: the value as read, "not set - <the guidance's Default>" when
   nothing sets it, user-right SIDs by name (Format-SidList), "(GPO: name)" when a GPO sets it.
Get-GpoGapSummaryRows rolls the servers into one row per setting, in the order of the recommended
GPOs: the worst outcome (Red beats Grey beats Amber beats Blue beats Green), the value now (one
line per distinct value, with how many servers when they differ), the impact details, and the
servers with no impact / to check / with an impact found.  Only the Impact cell is coloured
(Set-GridRows -CellColourProperty): the word says it, the row stays plain.  Get-GpoPlanHtml
groups the rows by recommended GPO under the approach: one GPO per area linked to the servers'
OU, a pilot first, servers with an impact found kept out by security filtering and recorded as
tailoring, a GPO edit raised as a change, AUDIT again afterwards.  Nothing here edits a GPO or a
server.
ADDING A SETTING: an entry in data\gpo-guidance.psd1 with the check's Id; the check, the GPO,
the impact probes and the Rsop spec it names must all exist.
'@ }

    [pscustomobject]@{ Title = 'E8. RemoteImpactScript - would applying it break something in use?'; Source = 'RemoteImpactScript'; Explain = @'
"Check impact" on the GPO recommendations page runs this on the servers (collector 'Impact').
Read-only: sessions, listening ports, the registry, event-log queries.  One line per check,
Name|Level|Evidence, Level = InUse (current use found), Review (something to look at), Clear
(no sign of use) or Unknown (cannot tell - and it says why).
THE SECURITY LOG (logon event 4624, the last ImpactDays): one XPath query per question, so the
event log service filters on the server and only matches travel - LmPackageName 'NTLM V1' / 'LM'
(NTLMv1), TargetUserSid S-1-5-7 (anonymous), LogonType 8 (Basic: clear-text), LogonType 10 (RDP),
the built-in Administrator's or Guest's SID.  Where the log has no 4624 at all in the window,
"none found" would be a guess: the answer is Unknown (logon auditing off, or the log too small).
The oldest event's date is quoted, so "none in 30 days" is not claimed of a log that holds two.
SMB: Get-SmbSession / Get-SmbConnection now (dialect 1.x = SMB1; 3.x clients all sign), and the
SMB1 access audit log (event 3000) when AuditSmb1Access is on - if it is off, Unknown.
LISTENING: TLS ports (443, 636, 1433, 5986, mail ...) with their process; port 139 and WINS for
NetBIOS; every listening port for the firewall.  PROGRAMS: PowerShell 2.0 engine starts (Windows
PowerShell log, event 400, EngineVersion=2), programs on the .NET 2.0 runtime (tasklist /m
mscorwks.dll), LSA packages that are not Windows', whether virtualization based security can run,
ASR audit hits (Defender event 1122), AppLocker audit hits (8003 / 8006), removable drives,
WinRM TrustedHosts.  "Now" answers only see what is connected or running at that moment - the
evidence says so.
Run it on THIS machine:  & $RemoteImpactScript 30 500
'@ }

    [pscustomobject]@{ Title = 'E9. The compliance dashboard and the executive summary'; Source = 'Get-ComplianceClass'; Explain = @'
Under the Servers page's grid, behind a divider (a SplitContainer with FixedPanel = Panel2, so the
dashboard keeps its height and the grid takes the rest): two donut charts for the servers shown and a
table for every group (lib\46-Security-Compliance.ps1).
HOW A CHECK COUNTS - Get-ComplianceClass (below) on each resolved row (Resolve-SecurityRow has already
applied the profile and the tailoring):
  Pass                       Compliant - or Accepted when only a tailored threshold made it pass
  RiskAccepted               Accepted ("compliant by tailoring") - but NonCompliant once the rule is
                             past its review date: a decision nobody reviewed stops counting
  Fail, Warn                 NonCompliant (a downgrade only changes the colour, not the answer)
  Warn "not collected", Error  NotRead - left out, counted separately
  NotApplicable, NotAssessable  left out (not at this classification / not a server setting)
Get-ComplianceFigures adds the rows up twice: ISM = every counted row; Essential Eight = the rows whose
ML is 1 up to the maturity target.  Percent = (Compliant + Accepted) / counted, rounded DOWN, so
"100%" never hides an open control.  Get-ComplianceGroupRows does the same per group of the group files.
Get-ServerCompliance classifies one server and keeps the result in the check-row cache under
"Compliance<ML>|<server>", so it is dropped with that server's rows (a new audit, a tailoring change)
and a fleet of hundreds is a sum of cached counts.
MORE THAN ONE GROUP - a server may be listed in several group files.  Get-ServerGroups returns all of
them: a tailoring rule for ANY of its groups applies (Get-TailoringRules), the server counts in each
group's figures and once in the totals.  Get-ServerGroup (the first group) still gives class and SOE.
THE CHARTS - New-ComplianceChart draws a bitmap with System.Drawing (FillPie for the slices, a white
circle for the hole, the percentage in it, the legend with counts underneath).  The dashboard shows it
in a PictureBox (the old image is disposed on every repaint); the executive summary embeds the same
picture as an inline PNG (ConvertTo-ImageTag), so the report is one file that can be mailed.
Green = compliant, BLUE = compliant by tailoring, red = not compliant: green only ever means "in place".
THE EXECUTIVE SUMMARY - Get-ComplianceExecutiveHtml: for a manager, not a technician - the charts first
with the headline in sentences, a card per group (two small donuts, New-ComplianceDonut; lowest first,
at most 24, every group in the table under them), the main gaps (controls not met on the most
servers, by name and priority), the risk decisions that reach a server in the report (who, why, the
review date, still in force or overdue), how the figures are worked out, and a line per server with
every group it is in.  A report for one group lists the other groups it shares servers with, figured on
the shared servers only ("1 of 1 audited (3 in the group)").  Export-ComplianceExecutiveReport writes
reports\Security-Summary-<stamp>.html.  Nothing here talks to a server.
PRINTING TO PDF - the report is laid out for A4 portrait (@page in the page itself); the print styles in
Get-ReportCss keep the colours, never split a chart, card or table row, repeat table headers, and keep
each heading off the foot of a page: an empty block after every h2 (cancelled by a negative margin)
must fit on the page with it, or the heading moves on.  Charts are drawn at twice the size they are
shown (New-ChartTag), so they print sharp.
'@ }

    # =================================================================  PART F - GUI AND FAULT FINDING
    [pscustomobject]@{ Title = 'F1. The GUI shell - Show-ToolkitGui'; Source = 'Show-ToolkitGui'; Explain = @'
Plain Windows Forms, no designer, no XAML.  The window is a SplitContainer: the console tabs
on top, the shared log box and status bar underneath.  Each console file adds its own tab
through the same helpers (New-PatchingConsole, New-SoftwareConsole, New-HealthConsole,
New-SecurityConsole, New-CommandsConsole, New-CodeTourTab, New-SettingsConsole, New-AboutConsole):
   Register-ConsoleTab   a TabPage whose header is painted in the console colour (owner-drawn
                         TabControl - the DrawItem handler in this function)
   New-ConsoleBanner     the coloured banner with title and subtitle
   New-ConsoleToolbar    the button strip (56 px: room for 40 px buttons)
   New-GroupPicker       the Group drop-down; Initialize-ToolkitData fills every one of them
   New-ConsoleGrid       a ListView with the given columns (tick boxes unless -NoCheckBoxes)
   Set-GridRows          rows in, cells out: cell text = the property named like the column,
                         row colour from a script block, tooltip from a property, ticks kept
   Show-DetailsWindow    the scrollable text window every double-click opens
Controls are kept in $script:Gui so the helper functions - and the event handlers - can reach
them.  A handler runs long after the function that built the control has returned, in whatever
scope is current when the event fires, so a local variable of that function is $null by then:
handlers read $this (the control that raised the event) or $script:Gui, never a local.  Docking order
matters: the Fill control is added first, then Right/Top/Bottom edges, then BringToFront()
on the Fill control.
Every button goes through Invoke-GuiAction: disable the state-changing buttons -> run ->
catch errors into the log -> repaint -> re-enable.  Invoke-ConsoleRefresh runs the refresher
of the console on screen (Register-ConsoleRefresher); the others are marked stale and repaint
when their tab is opened, so a click stays quick with hundreds of servers.  A crash in a
button never kills the window; it shows up as [ERROR] with the line that failed.
READ-ONLY buttons (every Health and Security button, status checks, reports, tick/untick)
are tagged -ReadOnly and stay enabled during an install: the install's wait loop pumps the
message queue (DoEvents), the click arrives in the middle of it, and Invoke-GuiAction runs
the read-only action nested, without touching the busy flag.  One nested action at a time.
"-ReadOnly" means: changes nothing a server runs on and starts no install (it may still save a
JSON file, and a status check removes the toolkit's own finished OS patch tasks - see B3).
A dialog opened from a nested action - an editor, a confirmation, "open the report?" - is
refused with a log line while the outer action runs (Test-GuiDialogAllowed), because a modal
window would suspend the install's wait loop; and a nested collector skips the servers being
installed on and never offers the credential prompt (see B4).
A console that builds its page only when first opened (About, and the Commands cheat sheet)
puts a script block in $script:Gui['OnFirstShow']; the tab-change handler runs it once.
While an action runs the window refuses to close (FormClosing) - the install itself is a
SYSTEM task on the server and would carry on, but the copies, the launches and the watch's
records belong to the window (untick Auto-check or press "Let the servers go" first); with
unsaved changes on the Settings tab it asks first.  When the GUI closes, any stored credential is cleared.
THE FIRST SIZE  Get-ToolkitStartSize measures the right-hand panels of the O/S Patching and
Software consoles (every control they hold, plus banner and toolbar) and opens the window tall
enough to show all of them without scrolling, up to the screen's working area and 1600 px wide.
The log underneath gets 220 px and gives way, down to 120 px, on a short screen; a screen
shorter still opens the window maximised.  The log's height is set before the first paint, so
nothing jumps.
From the console:  $f = Show-ToolkitGui -NoShow   (builds the form, no window)
'@ }

    [pscustomobject]@{ Title = 'F2. Update-ServerList - the O/S Patching grid'; Source = 'Update-ServerList'; Explain = @'
Rebuilds the O/S Patching ListView from three things: $script:Groups (rows), $script:Patches
(one column per file, with its [type]) and the Status results (cell values via
Get-PatchVerdict), plus the Roles and Software columns from the Inventory results.
Ticks survive a rebuild.  Row colour: white = not checked, grey = unreachable (hover =
reason), pink = pending reboot, yellow = something READY, green = everything installed,
cyan = an OS patch run is open (INSTALLING), purple = a run ended without a result (RUN
UNKNOWN).  One cell has its own colour: Trellix Agent, orange when the services are off.
The Health and Security grids are built the same way through Set-GridRows: a row object
per server, the row colour from Get-LightColour (the worst check).  The Health grid has no
Light column: each cell that stands for a check carries that check's own colour
(Get-HealthCellColours), so a green or amber cell shows inside a row that is red for
another finding; the Server, Group, Checked and Worst cells keep the row's colour.
'@ }

    [pscustomobject]@{ Title = 'F3. Troubleshooting checklist'; Source = ''; Explain = @'
GRID SHOWS "FAILED" / A GREY ROW FOR A SERVER (any console)
  1. Tick it, press "Test WinRM port (ticked)" (O/S Patching tab).  No answer -> network/firewall/
     service: on the server:  winrm quickconfig ; Get-Service WinRM
  2. Answers but status fails with Access is denied -> "Set credentials" (admin account).
  3. Kerberos errors -> use the FQDN in the group file.  Never set TrustedHosts=*.
  4. Hover the grey row: the tooltip is the error.  Full text in the log.

A SERVER 2019 BOX SHOWS "READY" FOR A SERVER 2022 PATCH
  Should not happen: the target build is read from inside the file and compared with
  the server build; an unreadable build is blocked.  If it does, check patches\_info\<file>.txt
  and the log line for that file.

TWO SERVERS SHOW DIFFERENT "NEWEST HOTFIX" KBs BUT THE SAME BUILD
  Compare the Build column, not the KB.  Same build = same cumulative update level.  A server
  patched by Windows Update also got the .NET cumulative update that day, so its newest entry
  may be the .NET KB; a server patched by this tool only got the one file you gave it.

"NO (PFRO ONLY, IGNORED)" IN THE PENDING REBOOT COLUMN
  No hard reboot flag is set, but PendingFileRenameOperations exists.  Double-click the server
  to see the file paths.  Temp or anti-virus files: ignore.  Windows servicing files: reboot.

"BLOCKED: SERVICING"  /  "REBOOT ... refused: servicing still running"
  dism or wusa is running, TiWorker is actively using CPU, or the Windows Update agent says it
  is installing.  Another admin, Windows Update, or a previous run that timed out.  Wait a few
  minutes and try again; on the server:  Get-Process dism, TiWorker, wusa | Select Name, CPU
  (an idle TiWorker - CPU not climbing - no longer blocks anything).

ONLY A FEW HOTFIXES ARE LISTED
  Normal.  Get-HotFix shows CBS packages still present; each cumulative update replaces the
  one before it.  Double-click the server: the details window shows both Get-HotFix AND the
  full Windows Update history, with dates, results and titles.

INSTALL FAILS
  * 0x800F0922 -> reboot the server first, then retry.  Check the SSU is included.
  * "staging failed" -> copy problem: free space on C:, the folder's owner/ACL, or the session dropped.
    "...exceeded the configured MaxEnvelopeSize quota" -> a request was bigger than the
    server allows; the tool halves its slice size and retries by itself.  The
    "failed at:" line under every error names the file and line of our code.
  * "signature check failed" -> the file is not the Microsoft original.  Download it again.
  * "staged file hash changed" -> something modified the file on the server between the copy
    and the install.  Investigate before retrying.

THE ROW STAYS CYAN, "INSTALLING (n min)" - OR TURNS PURPLE, "RUN UNKNOWN"
  The install is a SYSTEM task on the server; nothing on this PC holds it.  INSTALLING = the
  run is noted in settings\patch-runs.json and no result has been read yet: wait, or press
  "Check status (ticked)" - the status check reads the run marker and result files and
  records the result (a long DISM is normal; InstallTimeoutMin only ends the watching).
  RUN UNKNOWN = the run ended without a result (the task is gone, the server rebooted
  mid-way, the launch lost its answer): press "Analyse a failure (ticked)" - it reads the
  server's own logs, says where it broke, and clears the note.  A status check that later
  finds the run still going turns the row back to INSTALLING.

HEALTH / SECURITY: "COLLECTOR NOT AVAILABLE: Settings (...)"
  That collector was never run for the server, or it failed (the reason is in brackets).
  Press the tab's Check / Audit button for that server; look for [ERROR] lines in the log.

SECURITY: MANY AMBER ROWS SAYING "WAS NOT COLLECTED (auditpol returned no rows ...)"
  auditpol and secedit need an administrator on the server.  Set credentials with an admin
  account and audit again.  The Settings keys (SMB, TLS, UAC ...) are mostly readable anyway.

SECURITY: EVERYTHING IS GREY
  The profile's classification may be set to a level where those controls do not apply, or
  a tailoring rule with scope "all" disabled them.  Open the Security profile page and the Tailoring
  page; the Note column of a grey row says which it is.

"DATA FILE UNREADABLE" IN THE LOG
  A data\*.psd1 file has a syntax error (an unbalanced quote, a curly quote pasted from a web
  page) or contains something other than values.  The log line names the file and the line.
  The tool keeps running without that catalogue (the checks that need it say so).

A JSON FILE WILL NOT LOAD ("Could not read ... as JSON")
  soe\*.json, security\profile.json or security\tailoring.json was edited by hand and is no
  longer valid JSON (a missing comma or quote).  The tool falls back to defaults until the file
  is fixed; the log line names the file.

NOTHING HAPPENS WHEN I CLICK / THE WINDOW WILL NOT CLOSE
  The status bar says what it is busy with.  Buttons are disabled on purpose while a
  job runs, and the window refuses to close until the action finishes.  The console
  window behind the GUI shows the same log in colour.

A CHECK SAT ON ONE SERVER FOR MINUTES / "NO ANSWER WITHIN 180 S OF ITS TURN"
  A server that is down, wedged, or that the account gets no answer from used to hold a
  whole check until the collector's time limit (600 s).  Now each server has its own budget,
  SilentServerSec (Settings tab, 180 s): one that has not answered that long after its turn
  began is given up on its own - a grey row with that reason - and the others carry on.  A
  check with a limit of its own (Impact 900 s, Analysis 300 s, a command at CommandTimeoutSec)
  gives each server that long instead: a slow but working server is not a wedged one.
  "Stop waiting" on the status bar gives up on every silent server at once.  Neither touches
  an install or a command that may change a server: those run to their own limit.

DISM SAID INSTALLED (EXIT 0) BUT THE STATUS CHECK STILL SAYS READY
  A .NET Framework rollup for ANOTHER Windows build (the Server 2022 file on a Server 2019
  box) is not refused by DISM: its wrapper package goes in with every part skipped as not
  applicable, DISM returns 0, and Get-HotFix never lists the KB (field, 2026-11).  Now the
  build is read from the update.mum inside the rollup's cab, so such a file shows
  "Blocked: wrong OS" before anything is copied; and an install that ends with exit 0 and
  no reboot is checked against Get-HotFix and the servicing store - a KB that is not there
  is reported FAILED with that reason, never "Installed".  Get the rollup for the build.

THE INSTALL SEEMS STUCK
  It almost never is.  Watch for the progress lines every 45 s: "CBS stage 1 out of 1 at
  NN%".  As long as the percentage moves or TiWorker CPU seconds keep climbing, wait.
  Only if dism.exe is gone, TiWorker CPU stops climbing AND the percentage is frozen for
  10+ minutes should you look at C:\Windows\Logs\CBS\CBS.log on the server.

"POWERSHELL IS IN CONSTRAINEDLANGUAGE MODE"
  AppLocker / WDAC is blocking scripts on this PC.  Sign every .ps1 with a certificate the
  policy trusts (topic F6, README "Code signing"), or run the tool from a PC where PowerShell
  is in FullLanguage (and .ps1 files are allowed).

I WANT TO RUN A STEP BY HAND
  Open PowerShell in the root folder, set $NoGui = $true and dot-source the launcher (see
  topic A1), then call any function: Get-ServerStatus, Get-ServerHealth, Invoke-Checks,
  Get-SecurityRows, Export-HealthReport ...
'@ }

    [pscustomobject]@{ Title = 'F4. How to extend the tool'; Source = ''; Explain = @'
ADDING THINGS
  A benign stopped service / task code / ignored product -> data\benign-services.psd1
  An agent every server should run                       -> data\soe-agents.psd1
  A third-party product to track                         -> data\known-apps.psd1
  A new month's cumulative update or SQL / Exchange build -> data\product-patches.psd1
  An expected security setting (any collector key)       -> data\security-settings.psd1
  A new fact about a server                              -> one Add-S line in RemoteSettingsScript
  A logic check                                          -> New-Check in 30- or 40-Console-*.ps1
  A new remote collector                                 -> a self-contained Remote*Script block,
                                                            a Get-Server* wrapper calling
                                                            Invoke-Collector, a Needs name
  A new console                                          -> a lib\NN-Console-*.ps1 file with
                                                            New-<X>Console -Tabs, add it to the
                                                            launcher's list and to Show-ToolkitGui
After any edit, restart the tool.
HOUSE RULES: ASCII only (PowerShell 5.1 reads a file without a BOM as ANSI), "} else {" on one line, no closures in
checks, every remote block self-contained, every list sent as flat text lines, event handlers
read $this or $script:Gui (never a local of the function that built the control).
'@ }

    [pscustomobject]@{ Title = 'F5. The Settings tab - Save-ToolkitSettings'; Source = 'Save-ToolkitSettings'; Explain = @'
THE LAYERS  lib\01-Config.ps1 holds the defaults.  At start-up the launcher calls
Import-ToolkitSettings, which lays settings\settings.json over them - but only the keys listed in
$script:SettingSpecs (lib\12-Settings.ps1), and only after ConvertTo-SettingValue has checked each
one against its spec: bool, int with a range, plain-ASCII text with a length, a list, the change
fields, the per-action rules, the confirmation steps.  A value that does not fit (a hand edit gone
wrong) is skipped with a WARN line naming it, and its default stays - a typo can never switch a
safeguard off.  Not offered at all, among others: RequireValidSignature, AllowUnknownTargetBuild,
the WinRM port and timeouts, the folders, the query windows and intervals, the fleet caps
(01-Config.ps1 only - its comment lists them).
THE PAGE  (60-Console-Settings.ps1)  Eight boxes: the confirmations (an editable table - Ask, step,
question, the text after a No - with Add / Remove / Move up / Move down), the change records (system,
required fields, a Recording drop-down per action), the running log, warnings and safety limits,
the Software console (its timeout, packages shown at once), the Commands console (its timeout, how
much of an answer is kept), Health thresholds, the Security console (ImpactDays).  Any edit shows
UNSAVED CHANGES.  Set-SettingsForm fills the page, and
Get-SettingsFormValues reads it back - read back unchanged, the page changes nothing.
SAVE  Get-SettingsPreview lists every change and the ones that weaken a safeguard (a confirmation no
longer asked, an action recorded less strictly, a field no longer required); with any of those the
confirmation's default answer is No.  Save-ToolkitSettings (below) writes only what differs from the
defaults - so a default changed in a later version still reaches everything not set here - writes
the file beside the old one and moves it over (a half-written file never replaces a good one),
applies the values at once, logs every change with who made it, and the consoles re-judge their
rows with the new thresholds when next shown.
'@ }

    [pscustomobject]@{ Title = 'F6. Code signing and the About tab - Sign-Toolkit.ps1'; Source = 'Get-ToolkitSignatureRows'; Explain = @'
WHY  Where the execution policy is AllSigned, or application control (AppLocker / WDAC script
rules and similar) trusts only signed scripts, an unsigned .ps1 is refused - or runs in
ConstrainedLanguage, where Add-Type and WinForms do not work: the launcher stops with a message.
Sign-Toolkit.ps1 (root folder) signs every .ps1 with your organisation's certificate:
   -Thumbprint <tp>        sign (no -Thumbprint: list the code-signing certificates)
   -TimestampServer <url>  RFC 3161 timestamp - the only network call, and only when given
   -Check                  report every file's signature, sign nothing
TESTED UNDER AllSigned (2026-10-21)
  * only the .ps1 files are checked; Import-PowerShellDataFile and the parser read unsigned .psd1
    files, JSON is plain data, and script blocks (what Invoke-Command sends) are not files - so
    the Software tab can still write data\software-packages.psd1, and nothing on a server needs a
    signature
  * a signed copy runs exactly as before; the signature block is ASCII and the BOM stays
  * an edit inside a signed file -> HashMismatch; text added after the signature block -> NotSigned
  * a PC that does not trust the chain refuses the file with "is not digitally signed" - which
    is misleading: -Check, or the About tab, shows UnknownError (signed, chain not trusted)
TRUST comes from the PCs that run the tool (Group Policy): the issuing CA in Trusted Root, the
certificate in Trusted Publishers (AllSigned without a prompt), a publisher rule for application
control.  Sign LAST: sign again after every update.
THE ABOUT TAB (70-Console-About.ps1)  The version, the author and the support address (Copy support
email), the GitHub link (Copy GitHub link - the tool never opens it and sends no mail; the page refuses
any navigation), this copy's PowerShell version, language mode and
execution policy, and Get-ToolkitSignatureRows (below): every script, loaded at start or by hand,
its status in plain words, signer, expiry and timestamp.  The page is built when the tab is first
opened ('OnFirstShow') and on Check signatures again.
LOADING THE SCRIPTS ON THIS PC (2026-10-29: the field test of version 1 asked before every script)
Get-ScriptLoadingRows says what the next start meets: the execution policy a Group Policy sets
(Get-ScriptPolicySource - it overrides the launch command's Bypass), the "downloaded" mark of each
script (Get-ToolkitFileZone reads the Zone.Identifier stream: the zone API ignores it on a local
file - tested), a folder on a network path in the Internet zone, the signatures and whether the
signer is a Trusted Publisher.  Get-ScriptLoadVerdict turns that into green / amber / red.  The
buttons are ON THE PAGE in that section (Get-AboutActionsHtml; a click is wired after each load by
Register-AboutActions and run a moment later by a timer - the action rebuilds the page; a saved
copy has no buttons).  They act on THIS PC only, each after a Yes:
  Unblock the scripts         Unblock-File on the marked scripts
  Self-sign on this PC        Invoke-ToolkitSelfSign: a certificate made here (the key size and hash
                              chosen in the dialog against the ISM - 3072 / SHA-384 offered first - the
                              key not exportable), trusted in Root and Trusted Publishers (every user when
                              run as an administrator, else this user - Windows asks), every script
                              signed, then its private key deleted whatever happened.  Trust FIRST:
                              a No to Windows' question signs nothing
  Create a signing request    New-ToolkitSigningRequest: certreq -new makes the key (this user, not
                              exportable) and signing\*.req, with a .txt of what to ask the CA for -
                              the tool never talks to a CA
  Install the CA certificate  refused unless a request made here has its public key; then certreq
                              -accept, and where that refuses (the CA's root is not trusted here yet)
                              the certificate is joined to the request's key directly - never a
                              search of the key providers (the smart-card one asks for a card)
  Sign with a certificate     Invoke-ToolkitSign with a code-signing certificate whose key is here
KEY AND HASH AGAINST THE ISM  The three dialogs share Add-CodeSigningPanel: the classification (the
Security profile's to start), the key size and the certificate hash - only what meets the
classification's minimum is offered (Get-CodeSigningChoices) - and Get-CodeSigningCheck's rows:
ISM-0476 / 1765 (RSA modulus), 1766 / 1767 / 1768 (SHA-2 output), 0477 (a signing-only key pair),
1917 (post-quantum by 2030).  Which applies, and the words shown, come from data\ism-catalogue.psd1;
the thresholds are in $script:CodeSigningRules.  Script signatures are SHA-256 whatever is asked:
Windows PowerShell 5.1 writes SHA-256 into a script's signature even for SHA-384 (tested) - shown
as fixed, and at TOP SECRET it does not meet ISM-1768.  A red row asks again (Confirm-CodeSigningGaps).
'@ }

    [pscustomobject]@{ Title = 'F7. The Commands console - Get-CommandRisk'; Source = 'Get-CommandRisk'; Explain = @'
For an investigation, one step at a time: type ONE command, tick the servers, Enter.  Every
server's answer comes back under its own heading; read it, take what it shows into the next
command (a service's PathName into Test-Path, a process Id into Get-CimInstance Win32_Process).
The cheat sheet (data\command-cheatsheet.psd1) holds one-line commands by topic - deliberately no
chains: each answers one question.  Use this command (or a double-click) puts one in the box with
its first <placeholder> selected (Select-CommandPlaceholder, a moment later by timer, because a
double-click hands the focus back to the tree when it finishes).
BEFORE ANYTHING RUNS  Get-CommandRisk (below) reads the command with the PowerShell parser - it is
never run on the operator PC - and walks the syntax tree.  It is an ALLOW list: only what it can
show to be read-only is read-only; everything else MAY CHANGE a server.
  read-only    every command (CommandAst) is a Get- or Test- command, or one that only filters,
               sorts, picks, formats or converts ($CommandReadOnlyNames - Format-Table, not
               Format-Volume); or a tool on $CommandReadOnlyTools by its BARE name, with arguments
               matching its Allow pattern and not its Deny pattern (sc.exe qc, not sc.exe delete;
               ping, not ping -t).  Aliases are resolved first, from a table read once: sc is
               Set-Content, gsv is Get-Service, ? and % are Where- and ForEach-Object.
  may change   any other command; a tool given by path (C:\temp\ipconfig.exe could be anything)
               or with arguments worked out at run time; & $x; a method call not on
               $CommandSafeMethods (.Delete(), .Kill(), [IO.File]::Delete); ForEach-Object Kill;
               > file; setting a property ((Get-Item x).Attributes = ...); ${C:\file} = ...;
               -Repair on a Test- command.  Nested blocks are walked too: "$(Stop-Service x)",
               & { Stop-Service x }, a Where-Object filter.  Since the 2026-10-29 review (R6):
               a cast, typed variable or -as to a type outside $CommandValueTypes (a cast runs a
               constructor: [IO.StreamWriter]'file' empties the file); a static property of such
               a type outside a comparison; a write to function:, alias: or env:, or to
               $PSDefaultParameterValues and the *Preference variables; ForEach-Object
               -MemberName:<method>; Format / Replace except on a provable string; every native
               argument that is not a constant (brackets, variables, --%); netsh only as
               <known contexts> show; route print and arp -a/-g word by word; certutil -store /
               -hashfile with plain arguments; Win32_Product (reading it repairs every MSI);
               using / #requires that load code.
  refused      Restart-Computer and shutdown (Reboot (ticked) checks for servicing and
               records event 920), and commands that wait for someone at the server's screen.
A <placeholder> is replaced by x for the analysis, so a cheat-sheet entry is coloured by what it
WOULD do (dark red = may change) while Run waits for the real value ("Fill in").
RUN  Start-CommandRun.  Read-only: Invoke-GuiAction -ReadOnly (so it may run alongside an
install; the collector skips the servers being installed on).  May change: a normal action -
Request-ChangeRecord (action "Command (may change)", Settings tab), a Yes/No naming the command,
the reasons and the servers (No is the default), the pre-action confirmations when
CommandAskSafety is on, then change-log.csv rows (approved, then the result per server) and the
server's own record (topic F8).  The answer of each server lands in the grid's Last result.
'@ }

    [pscustomobject]@{ Title = 'F8. RemoteCommandScript - one command on the server'; Source = 'RemoteCommandScript'; Explain = @'
What runs on the server for the Commands tab (collector 'Command', Invoke-ServerCommand).  The
typed text becomes a script block THERE ([scriptblock]::Create) and runs as you, in a WinRM
session that loads no profile.  Every stream is merged (*>&1) and streamed into a list, so what
came out before a terminating error is kept; errors come back as "ERROR: ...", warnings as
"WARNING: ...", Write-Host lines as they are, a tool's own error text (stderr) unchanged.  The
objects are turned into text ON the server (Out-String -Width 250), so the answer reads as the
server's own console would show it - and nothing but a string travels back.
  CommandTimeoutSec   the job is stopped after this (per wave of MaxParallel servers)
  CommandMaxOutputKB  each answer is cut at this size (Truncated = $true, the pane says so)
  Result              ok / N error(s) / FAILED: <message>, plus ", exit code N" from a tool
-Record (only for a command that may change the server): a line in C:\PatchStaging\change-log.txt
and Application event 930 BEFORE it runs ("starting") and AFTER ("finished: <result>") - so even
a command that cuts the connection (Restart-Service WinRM) leaves its start on record.
Run it on THIS machine:
   & $RemoteCommandScript 'Get-Service WinRM' $false 'me' '' 'C:\Temp\x' 256 250
'@ }
)

function ConvertTo-TourValue {
    # A config value on one line (hashtables and arrays would otherwise print as their type name).
    param($Value)
    if ($Value -is [System.Collections.IDictionary]) { return (($Value.GetEnumerator() | ForEach-Object { '{0}={1}' -f $_.Key, $_.Value }) -join '; ') }
    # the confirmation steps (SafetyChecks): their names, on or off
    if ($Value -is [array]) { return ((@($Value) | ForEach-Object { if ($_ -is [System.Management.Automation.PSCustomObject] -and $_.PSObject.Properties['Name']) { '{0} ({1})' -f $_.Name, $(if ($_.Enabled) { 'on' } else { 'off' }) } else { [string]$_ } }) -join ', ') }
    return [string]$Value
}

function Get-CheckCatalogueText {
    # The checks of one console as a readable catalogue (rendered from $script:Checks).
    param([string]$Console)
    $sb = New-Object System.Text.StringBuilder
    $checks = @(Get-Checks -Console $Console)
    [void]$sb.AppendLine(('{0} checks for the {1} console' -f $checks.Count, $Console))
    foreach ($grp in ($checks | Group-Object Group)) {
        [void]$sb.AppendLine()
        [void]$sb.AppendLine(('== {0} ({1}) ==' -f $grp.Name.ToUpper(), $grp.Count))
        foreach ($chk in $grp.Group) {
            $ml = ''; if ($chk.ML -gt 0) { $ml = "ML$($chk.ML)" }
            [void]$sb.AppendLine(('{0,-11} {1}' -f $chk.Id, $chk.Title))
            [void]$sb.AppendLine(('            ISM: {0,-28} {1,-4} severity {2,-7} needs: {3}   applies: {4}' -f (($chk.Ism -join ' ') + ' '), $ml, $chk.Severity, (($chk.Needs -join ', ') + ' '), $chk.Applies))
            if ($chk.Why) { [void]$sb.AppendLine('            why: ' + $chk.Why) }
            if ($chk.Fix) { [void]$sb.AppendLine('            fix: ' + $chk.Fix) }
        }
    }
    return $sb.ToString()
}

function Get-SettingsKeyText {
    # Every key the Settings collector produces, read from the collector's own source.
    $src = ''
    $v = Get-Variable -Name 'RemoteSettingsScript' -Scope Script -ErrorAction SilentlyContinue
    if (-not $v) { $v = Get-Variable -Name 'RemoteSettingsScript' -ErrorAction SilentlyContinue }
    if (-not $v) { return '(RemoteSettingsScript is not loaded)' }
    $src = $v.Value.ToString()
    $fixed = @([regex]::Matches($src, "Add-S\s+'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    $dynamic = @([regex]::Matches($src, 'Add-S\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $dynamic += @([regex]::Matches($src, "Add-S\s+\(([^)]+)\)") | ForEach-Object { $_.Groups[1].Value })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('{0} fixed keys:' -f $fixed.Count))
    $col = 0
    foreach ($k in $fixed) {
        [void]$sb.Append(('  {0,-38}' -f $k))
        $col++
        if ($col % 3 -eq 0) { [void]$sb.AppendLine() }
    }
    if ($col % 3 -ne 0) { [void]$sb.AppendLine() }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine(('{0} keys built in loops (the pattern, one key per item):' -f $dynamic.Count))
    foreach ($k in $dynamic) { [void]$sb.AppendLine('  ' + $k) }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('Plus, from the SecurityPolicy collector:  Audit:<subcategory>  Sec:<name>  Right:<privilege>  Reg:<leaf>  LegacyAudit:<category>')
    return $sb.ToString()
}

function Get-DataFileText {
    # The data\ catalogues with their dates, sizes and entry counts.
    $sb = New-Object System.Text.StringBuilder
    $folder = $script:Config.DataFolder
    if (-not (Test-Path -LiteralPath $folder)) { return "(data folder not found: $folder)" }
    foreach ($f in (Get-ChildItem -LiteralPath $folder -Filter '*.psd1' | Sort-Object Name)) {
        $d = Import-ToolData -Name $f.Name
        $asOf = ''; $parts = @()
        if ($d) {
            foreach ($key in ($d.Keys | Sort-Object)) {
                $val = $d[$key]
                if ($key -in 'AsOf', 'Generated') { $asOf = [string]$val; continue }
                if ($val -is [array]) { $parts += ('{0}: {1} entries' -f $key, $val.Count) }
                elseif ($val -is [System.Collections.IDictionary]) { $parts += ('{0}: {1} keys' -f $key, $val.Count) }
                elseif ($key -notin 'Source', 'Count') { $parts += ('{0} = {1}' -f $key, $val) }
            }
        } else { $parts += 'UNREADABLE - see the log' }
        [void]$sb.AppendLine(('{0,-24} {1,6} KB   as of {2,-12} {3}' -f $f.Name, [int]($f.Length / 1KB), $asOf, ($parts -join '; ')))
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------
#  The Code Tour as HTML: one page per topic (Get-CodeTourHtml) and the whole tour in one file (Export-CodeTourHtml)
# ---------------------------------------------------------------------
$script:CodeTourParts = [ordered]@{ A = 'Start here'; B = 'O/S Patching console'; S = 'Software console and change records'; C = 'The check engine'; D = 'Health console'; E = 'Security console'; F = 'GUI and fault finding' }

function Get-CodeTourPart {
    # 'B' for 'B12. ...' - the part a topic belongs to.
    param($Entry)
    if ([string]$Entry.Title -match '^([A-Z])\d') { return $Matches[1] }
    return 'A'
}

function ConvertTo-TourInline {
    # One line of prose: escaped, web addresses in code style so they are easy to copy.
    param([string]$Line)
    $safe = [System.Net.WebUtility]::HtmlEncode($Line)
    return ([regex]::Replace($safe, '(https?://[^\s<]+|[a-z0-9.\-]+\.(?:microsoft|gov)\.(?:com|au)[^\s<]*)', '<code>$1</code>'))
}

function ConvertTo-TourProseHtml {
    # A topic's explanation -> HTML.  The text is written for a fixed-width pane, so the rules are conservative:
    #   * a line in CAPITALS (a short heading, maybe with "(...)" or a trailing ":") becomes a heading;
    #     "CAPITALS  more text" becomes a heading with the rest as its subtitle
    #   * "CAPITALS: sentence" keeps its label in bold at the start of the paragraph
    #   * lines that are indented or laid out in columns (3+ spaces between words, tree lines) stay exactly as
    #     written, in a monospaced block - tables and lists keep their alignment
    #   * every other run of lines is one paragraph
    param([string]$Text)
    $html = New-Object System.Text.StringBuilder
    $para = New-Object System.Collections.Generic.List[string]
    $block = New-Object System.Collections.Generic.List[string]
    $st = @{ Para = $para; Block = $block; Html = $html }
    $flush = {
        if ($st.Para.Count -gt 0) {
            $first = $st.Para[0]; $label = ''
            if ($first -cmatch '^([A-Z][A-Z0-9 /\-]{3,}):\s+(.*)$') { $label = $Matches[1]; $st.Para[0] = $Matches[2] }
            $body = (@($st.Para) | ForEach-Object { ConvertTo-TourInline $_ }) -join ' '
            if ($label) { $body = '<b>' + [System.Net.WebUtility]::HtmlEncode($label) + ':</b> ' + $body }
            [void]$st.Html.AppendLine('<p>' + $body + '</p>')
            $st.Para.Clear()
        }
        if ($st.Block.Count -gt 0) {
            # drop the common indentation so a table does not start half-way across the page
            $minLead = 99
            foreach ($b in $st.Block) { if ($b.Trim()) { $lead = $b.Length - $b.TrimStart().Length; if ($lead -lt $minLead) { $minLead = $lead } } }
            if ($minLead -eq 99) { $minLead = 0 }
            $out = @($st.Block | ForEach-Object { if ($_.Length -ge $minLead) { [System.Net.WebUtility]::HtmlEncode($_.Substring($minLead)) } else { [System.Net.WebUtility]::HtmlEncode($_.TrimStart()) } })
            [void]$st.Html.AppendLine('<pre class="lay">' + ($out -join "`n") + '</pre>')
            $st.Block.Clear()
        }
    }
    # The tour text indents a section's body under its heading, so "indented" alone does not mean "table": a line is
    # laid out when it sits DEEPER than the first line of its section, is a list item, has a column gap or is a tree.
    $base = -1
    $all = @(($Text -replace "`r", '') -split "`n")
    for ($n = 0; $n -lt $all.Count; $n++) {
        $line = $all[$n].TrimEnd()
        if (-not $line.Trim()) { & $flush; continue }
        $t = $line.Trim()
        $lead = $line.Length - $line.TrimStart().Length
        if ($base -lt 0) { $base = $lead }
        $isList = ($t -match '^(\d+[\.\)]|\*|-)\s')
        $isLayout = ($lead -gt $base) -or $isList -or ($line -match '\S {3,}\S') -or ($t -match '^(\||'')--')
        # the tour's own heading style: a flush-left line, mostly in capitals, with the next line indented under it
        $nextLead = -1
        for ($k = $n + 1; $k -lt $all.Count; $k++) { if ($all[$k].Trim()) { $nextLead = $all[$k].Length - $all[$k].TrimStart().Length; break } }
        $letters = ($t -replace '[^A-Za-z]', '').Length; $capitals = ($t -creplace '[^A-Z]', '').Length
        if ($lead -eq 0 -and $nextLead -gt 0 -and -not $isList -and $t.Length -le 110 -and $letters -ge 4 -and ($capitals / $letters) -ge 0.4) {
            & $flush
            [void]$html.AppendLine('<h3>' + [System.Net.WebUtility]::HtmlEncode($t.TrimEnd(':')) + '</h3>')
            $base = -1
            continue
        }
        if (-not $isLayout -and $t.Length -le 110 -and $t -cmatch '^([A-Z][A-Z0-9 ,/''"\-\.]{4,}?[A-Z0-9"])(\s*\([^)]*\))?\s*[:?]?$') {
            & $flush
            [void]$html.AppendLine('<h3>' + [System.Net.WebUtility]::HtmlEncode($t.TrimEnd(':')) + '</h3>')
            $base = -1
            continue
        }
        if (-not $isLayout -and $t -cmatch '^([A-Z][A-Z0-9 /\-]{3,}?[A-Z0-9])\s{2,}(\S.*)$') {
            & $flush
            [void]$html.AppendLine('<h3>' + [System.Net.WebUtility]::HtmlEncode($Matches[1]) + ' <span class="sub">' + [System.Net.WebUtility]::HtmlEncode($Matches[2]) + '</span></h3>')
            $base = -1
            continue
        }
        if ($isLayout) {
            if ($para.Count -gt 0) { & $flush }
            $block.Add($line)
        } else {
            if ($block.Count -gt 0) { & $flush }
            $para.Add($line.Trim())
        }
    }
    & $flush
    return $html.ToString()
}

function ConvertTo-TourSourceHtml {
    # Source code with its comment lines in green; kept exactly as written.
    param([string]$Source)
    $out = foreach ($line in (($Source -replace "`r", '') -split "`n")) {
        $e = [System.Net.WebUtility]::HtmlEncode($line)
        if ($line -match '^\s*#') { '<span class="cm">' + $e + '</span>' } else { $e }
    }
    return ('<pre class="src">' + ($out -join "`n") + '</pre>')
}

function Get-CodeTourSource {
    # The live source (or the text rendered from the code) a topic shows, and its label; '' when it has none.
    param($Entry)
    $src = ''
    switch -Regex ($Entry.Source) {
        '^$'                 { $src = '' }
        '^Config$'           { $src = ($script:Config.GetEnumerator() | Sort-Object Name | ForEach-Object { '  {0,-32} = {1}' -f $_.Name, (ConvertTo-TourValue $_.Value) }) -join "`n" }
        '^Remote\w+Script$'  {
            $v = Get-Variable -Name $Entry.Source -Scope Script -ErrorAction SilentlyContinue
            if (-not $v) { $v = Get-Variable -Name $Entry.Source -ErrorAction SilentlyContinue }
            if ($v) { $src = '$script:' + $Entry.Source + ' = {' + $v.Value.ToString() + '}' } else { $src = "(variable $($Entry.Source) is not loaded)" }
        }
        '^Checks:(\w+)$'     { $src = Get-CheckCatalogueText -Console $Matches[1] }
        '^SettingsKeys$'     { $src = Get-SettingsKeyText }
        '^DataFiles$'        { $src = Get-DataFileText }
        default {
            $fn = Get-Command -Name $Entry.Source -CommandType Function -ErrorAction SilentlyContinue
            if ($fn) { $src = "function $($Entry.Source) {" + $fn.Definition + '}' } else { $src = "(function $($Entry.Source) is not loaded)" }
        }
    }
    $label = 'Live source'
    if ($Entry.Source -match '^(Checks:|SettingsKeys|DataFiles)') { $label = 'Rendered from the code' }
    return @{ Text = $src; Label = $label }
}

function Get-CodeTourBodyHtml {
    # The body of one topic page: picture (embedded, so the page works offline and saved on its own), the
    # explanation, then the live source.
    param($Entry)
    $sb = New-Object System.Text.StringBuilder
    if ($Entry.Image) {
        $path = Join-Path $script:RootFolder $Entry.Image
        if (Test-Path -LiteralPath $path) {
            $b64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($path))
            [void]$sb.AppendLine('<div class="pic"><img src="data:image/png;base64,' + $b64 + '" alt="' + [System.Net.WebUtility]::HtmlEncode($Entry.Image) + '"><div class="cap">' + [System.Net.WebUtility]::HtmlEncode($Entry.Image) + ' - "Open picture" above shows it full size</div></div>')
        } else {
            [void]$sb.AppendLine('<p class="warn">PICTURE NOT FOUND: ' + [System.Net.WebUtility]::HtmlEncode($path) + ' - copy the images\ folder of the toolkit back.</p>')
        }
    }
    [void]$sb.AppendLine('<div class="tour">' + (ConvertTo-TourProseHtml -Text ([string]$Entry.Explain)) + '</div>')
    $src = Get-CodeTourSource -Entry $Entry
    if ($src.Text) {
        [void]$sb.AppendLine('<h2>' + [System.Net.WebUtility]::HtmlEncode(('{0}: {1}' -f $src.Label, $Entry.Source)) + ' <span class="sub">read from memory when this page was drawn</span></h2>')
        [void]$sb.AppendLine((ConvertTo-TourSourceHtml -Source $src.Text))
    }
    return $sb.ToString()
}

function Get-CodeTourHtml {
    # One topic as a page for the Code Tour tab.
    param($Entry, [int]$Index = 0)
    $part = Get-CodeTourPart -Entry $Entry
    $sub = ('Code Tour - part {0}: {1} - topic {2} of {3}' -f $part, $script:CodeTourParts[$part], ($Index + 1), @($script:CodeTour).Count)
    return (New-DetailsHtml -Title ([string]$Entry.Title) -Subtitle $sub -Console 'Tour' -Sections @(@{ Heading = ''; Html = (Get-CodeTourBodyHtml -Entry $Entry) }))
}

function Export-CodeTourHtml {
    # The whole tour in one page: a contents list by part, then every topic with its picture and source.
    $toc = New-Object System.Text.StringBuilder
    $body = New-Object System.Text.StringBuilder
    $i = 0
    foreach ($key in $script:CodeTourParts.Keys) {
        [void]$toc.AppendLine('<h3>Part ' + $key + ' - ' + [System.Net.WebUtility]::HtmlEncode($script:CodeTourParts[$key]) + '</h3><ul>')
        for ($j = 0; $j -lt @($script:CodeTour).Count; $j++) {
            $e = $script:CodeTour[$j]
            if ((Get-CodeTourPart -Entry $e) -ne $key) { continue }
            [void]$toc.AppendLine('<li><a href="#t' + $j + '">' + [System.Net.WebUtility]::HtmlEncode([string]$e.Title) + '</a></li>')
        }
        [void]$toc.AppendLine('</ul>')
    }
    foreach ($e in $script:CodeTour) {
        [void]$body.AppendLine('<hr><h2 id="t' + $i + '">' + [System.Net.WebUtility]::HtmlEncode([string]$e.Title) + '</h2>')
        [void]$body.AppendLine((Get-CodeTourBodyHtml -Entry $e))
        [void]$body.AppendLine('<p class="top"><a href="#contents">back to the contents</a></p>')
        $i++
    }
    return (New-DetailsHtml -Title 'Code Tour - the whole tour' -Subtitle ('{0} topics in {1} parts; pictures and live source included' -f @($script:CodeTour).Count, $script:CodeTourParts.Count) -Console 'Tour' -Sections @(
        @{ Heading = ''; Html = ('<h2 id="contents">Contents</h2>' + $toc.ToString()) },
        @{ Heading = ''; Html = $body.ToString() }))
}
