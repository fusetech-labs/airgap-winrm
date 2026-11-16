# =====================================================================
#  01-Config.ps1  -  SETTINGS AND SHARED STATE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Everything an operator might want to tweak lives in $script:Config.
#  These are the defaults: the Settings tab saves the operator's changes
#  in settings\settings.json and lib\12-Settings.ps1 lays them over the
#  defaults at start-up.  What the site runs (which Windows builds,
#  which .NET lines, which ESXi line - the first box of the Settings
#  tab) and the Products tab's ticks and links live in
#  settings\environment.json (lib\03-Products.ps1).
#  "$script:" simply means "a variable shared by all the files of this tool".
# =====================================================================

# The launcher sets $script:RootFolder before loading this file.
if (-not $script:RootFolder) { $script:RootFolder = (Get-Location).Path }

# Beside the WinRM toolkit (this folder inside its folder) the library IS that toolkit's own patches\ and software\
# folders, so a download lands where the toolkit reads it.  Anywhere else, the library is library\ in this folder.
$script:CompanionParent = Split-Path -Path $script:RootFolder -Parent
$script:BesideToolkit = ($script:CompanionParent -and (Test-Path -LiteralPath (Join-Path $script:CompanionParent 'Start-WinRMToolkit.ps1')))
$script:DefaultLibraryFolder = $(if ($script:BesideToolkit) { $script:CompanionParent } else { Join-Path $script:RootFolder 'library' })

$script:Config = @{
    # ---- Identity ----
    ToolName       = 'Sysadmin Download Toolkit'   # banner, window title, reports
    ToolVersion    = '1.0'
    CompanionOf    = 'Sysadmin WinRM Toolkit'      # the toolkit whose library this tool keeps
    SourceUrl      = 'https://github.com/fusetech-labs/airgap-winrm'   # the About tab shows it to copy
    Author         = 'Chris Fryer'
    SupportEmail   = 'products@fusetech.com.au'    # the About tab shows it to copy; the tool sends no mail
    Website        = 'https://fusetech.com.au'

    # ---- Folders ----
    LibraryFolder  = $script:DefaultLibraryFolder   # Settings tab: where patches\ and software\ are kept (the WinRM toolkit's folder, a USB drive ...)
    LogFolder      = $(if ($script:LogFolderOverride) { $script:LogFolderOverride } else { Join-Path $script:RootFolder 'logs' })
    ReportFolder   = Join-Path $script:RootFolder 'reports'
    DataFolder     = Join-Path $script:RootFolder 'data'      # products.psd1: what to fetch and from where
    SettingsFile   = $(if ($script:SettingsFileOverride) { $script:SettingsFileOverride } else { Join-Path $script:RootFolder 'settings\settings.json' })
    EnvironmentFile = $(if ($script:EnvironmentFileOverride) { $script:EnvironmentFileOverride } else { Join-Path $script:RootFolder 'settings\environment.json' })
    LastRunFile    = $(if ($script:LastRunFileOverride) { $script:LastRunFileOverride } else { Join-Path $script:RootFolder 'settings\last-run.json' })
    ManifestName   = 'library-manifest.json'   # in the library folder: every file the tool put there, with its hashes and where it came from
    ChecksumsName  = 'CHECKSUMS.txt'           # in the library folder: "sha256  relative path" per file, for a check by hand on the other side

    # ---- Patch types = sub-folders of patches\ (the WinRM toolkit's layout) ----
    PatchTypes     = [ordered]@{ Windows = 'install'; DotNet = 'install' }

    # ---- Console colours (tab header + banner) and the names shown for them ----
    ConsoleColours = @{ Library = 'MidnightBlue'; Products = 'DarkGreen'; Schedule = 'DarkCyan'; Settings = 'DarkSlateGray'; About = 'SteelBlue' }
    ConsoleText    = @{ Library = 'Gold';         Products = 'White';     Schedule = 'White';    Settings = 'White';         About = 'White' }
    ConsoleNames   = @{}
    BrandColour    = 'DodgerBlue'   # the Fusetech blue: the frame round the window, the window icon and the favicon of every HTML page

    # =================================================================
    #  DEFAULTS the Settings tab can change ($script:SettingSpecs in lib\12-Settings.ps1)
    # =================================================================
    # ---- The library ----
    KeepPrevious         = 0       # older files of a product kept beside the newest (0 = the latest only; the WinRM toolkit shows every file as a column)
    RequireValidSignature = $true  # a download must be Authenticode-signed by one of its product's signers, else it is deleted and the row is red
    VerifyEveryStart     = $true   # the hashes of the library are checked again at every start (a file changed or truncated since is flagged)

    # ---- Downloads ----
    DownloadTimeoutMin   = 60      # one file still downloading after this long is given up (the whole download, from the request to the last byte)
    DownloadRetries      = 2       # ... and tried again this many times
    MaxDownloadMB        = 4096    # a file the source says is bigger than this is refused (a wrong link, an ISO)
    UseSystemProxy       = $true   # the proxy Windows is configured with (Internet Options), with the logged-on user's credentials
    CatalogMonthsBack    = 3       # the Update Catalog is searched for this month, then earlier months, until a cumulative update is found
    UserAgent            = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AirgapDownloadToolkit'

    # ---- The scheduled task (Schedule tab; the task runs this script with -Unattended) ----
    TaskName             = 'Airgap Download Toolkit'
    TaskFolder           = '\WinRMToolkit\'
    TaskTime             = '03:00'     # HH:mm, local time
    TaskDays             = 'Daily'     # Daily, or a weekday name (Monday ...) for once a week
    TaskLogon            = 'Interactive'   # Interactive = runs while the operator is logged on, with the full session, and needs no extra right; S4U = runs whether or not logged on, no password stored (no network drives, no proxy that asks for a password), but Windows gives it only to an account that may log on as a batch job

    # ---- The running log and the log files ----
    LogShowCmd           = $true
    LogShowWhy           = $true
    LogKeepDays          = 0
    MaxLogBoxChars       = 1500000
    OperatorName         = 'sys-admin'

    # =================================================================
    #  Not on the Settings tab (changed here by hand only)
    # =================================================================
    CatalogUrl           = 'https://www.catalog.update.microsoft.com'
    VMwareToolsUrl       = 'https://packages.vmware.com/tools/'
    CatalogStaleDays     = 3       # this many days after Patch Tuesday the month's cumulative update must be in the catalogue; a check that still finds only an older month marks the row Stale
    ReleaseInfoUrl       = 'https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info'   # Microsoft's own list of every release, named when a row is Stale
}

# ---- Shared runtime state (filled in while the tool runs) ----
$script:Operator     = "$env:USERDOMAIN\$env:USERNAME"
$script:Gui          = @{}
$script:Candidates   = @{}     # product id|target -> the candidate found by the last check (Get-ProductCandidates)
$script:Checked      = @{}     # product id|target -> when it was last checked, and the error if the check failed
$script:Results      = @{}     # product id|target#file name -> what the last download, or check of a hand-placed file, of that candidate came to
$script:LibraryCache = $null   # Get-LibraryFiles: the files of the library, keyed on the folder listing
$script:PreGuiLines  = @()
$script:LogFileBroken = ''; $script:LogFileBrokenShown = $false
$script:SettingsDefaults = $null
$script:DataCache    = $null

$script:Banner = @'
   _____   _   _   ____    _____   _____   _____    ____   _   _     _          _      ____    ____
  |  ___| | | | | / ___|  | ____| |_   _| | ____|  / ___| | | | |   | |        / \    | __ )  / ___|
  | |_    | | | | \___ \  |  _|     | |   |  _|   | |     | |_| |   | |       / _ \   |  _ \  \___ \
  |  _|   | |_| |  ___) | | |___    | |   | |___  | |___  |  _  |   | |___   / ___ \  | |_) |  ___) |
  |_|      \___/  |____/  |_____|   |_|   |_____|  \____| |_| |_|   |_____| /_/   \_\ |____/  |____/
   Sysadmin Download Toolkit: the update library for the airgap, fetched and verified on the internet side
'@
