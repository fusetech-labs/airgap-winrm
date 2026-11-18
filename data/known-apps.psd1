@{
    # =================================================================
    #  known-apps.psd1  -  utilities the sysadmin cares about, and the
    #  latest version known to be current.  Maintained BY HAND, offline:
    #  check the vendor pages on an internet PC about once a month,
    #  update "Latest" and "AsOf", copy the file over.  The tool shows
    #  the AsOf date in the grid and the report so a stale table is
    #  visible.  Leave "Latest" empty when you do not track a product;
    #  the fleet itself still acts as a baseline (a newer version seen
    #  on any server flags the older ones as Behind).  So does the
    #  software library: a product that a registered package of the
    #  Software console covers is Behind as soon as software\ holds a
    #  newer installer, whether or not it is listed here.
    #
    #  Match          wildcard against the product's DisplayName
    #  Latest         version string that counts as current ('' = unknown)
    #  CadenceMonths  how often the vendor normally releases (for "Stale")
    #  EOL            $true = the product line is end of life
    #  Note           free text shown in the Reason column
    # =================================================================
    AsOf = '2026-06-01 (example values - verify against the vendor pages and update)'
    Apps = @(
        @{ Match = '7-Zip*';                 Latest = '24.09';   CadenceMonths = 12; EOL = $false; Note = '7-zip.org' }
        @{ Match = 'PuTTY*';                 Latest = '0.83';    CadenceMonths = 12; EOL = $false; Note = 'putty.org' }
        @{ Match = 'Notepad++*';             Latest = '8.7';     CadenceMonths = 3;  EOL = $false; Note = 'notepad-plus-plus.org' }
        @{ Match = 'WinSCP*';                Latest = '6.3';     CadenceMonths = 4;  EOL = $false; Note = 'winscp.net' }
        # the 2.x line only ("KeePass Password Safe 2.58"): 1.x is a line of its own with its own versions
        @{ Match = 'KeePass Password Safe 2*'; Latest = '2.62';  CadenceMonths = 4;  EOL = $false; Note = 'keepass.info - 2.62 of 2026-11-04 (checked 2026-11-19)' }
        @{ Match = 'VLC media player*';      Latest = '3.0.21';  CadenceMonths = 12; EOL = $false; Note = 'videolan.org' }
        @{ Match = 'Google Chrome*';         Latest = '';        CadenceMonths = 1;  EOL = $false; Note = 'monthly releases - compare within the fleet' }
        @{ Match = 'Microsoft Edge*';        Latest = '';        CadenceMonths = 1;  EOL = $false; Note = 'monthly releases - compare within the fleet' }
        @{ Match = 'Mozilla Firefox*';       Latest = '';        CadenceMonths = 1;  EOL = $false; Note = 'monthly releases - compare within the fleet' }
        @{ Match = 'Java 8 Update*';         Latest = '';        CadenceMonths = 3;  EOL = $false; Note = 'Oracle quarterly CPU; licence applies' }
        @{ Match = 'Java(TM) 6*';            Latest = '';        CadenceMonths = 0;  EOL = $true;  Note = 'Java 6 is out of support' }
        @{ Match = 'Java(TM) 7*';            Latest = '';        CadenceMonths = 0;  EOL = $true;  Note = 'Java 7 is out of support' }
        @{ Match = 'Adobe Acrobat Reader*';  Latest = '';        CadenceMonths = 1;  EOL = $false; Note = 'monthly releases - compare within the fleet' }
        @{ Match = 'Adobe Flash Player*';    Latest = '';        CadenceMonths = 0;  EOL = $true;  Note = 'Flash is end of life (ISM-1704: remove)' }
        @{ Match = 'VMware Tools*';          Latest = '';        CadenceMonths = 6;  EOL = $false; Note = 'from the vSphere release' }
        @{ Match = 'Microsoft Visual C++ 2008*'; Latest = '';    CadenceMonths = 0;  EOL = $true;  Note = 'VC++ 2008 runtime is out of support' }
        @{ Match = 'Microsoft Visual C++ 2010*'; Latest = '';    CadenceMonths = 0;  EOL = $true;  Note = 'VC++ 2010 runtime is out of support' }
        @{ Match = 'Microsoft SQL Server 2012*'; Latest = '';    CadenceMonths = 0;  EOL = $true;  Note = 'SQL Server 2012 is out of extended support' }
        @{ Match = 'Microsoft SQL Server 2014*'; Latest = '';    CadenceMonths = 0;  EOL = $true;  Note = 'SQL Server 2014 is out of extended support' }
        @{ Match = 'Microsoft ODBC Driver 1[0-9] for SQL Server*'; Latest = ''; CadenceMonths = 6; EOL = $false; Note = 'compare within the fleet' }
        @{ Match = 'Microsoft OLE DB Driver for SQL Server*';   Latest = ''; CadenceMonths = 6; EOL = $false; Note = 'compare within the fleet' }
        @{ Match = 'TeamViewer*';            Latest = '';        CadenceMonths = 1;  EOL = $false; Note = 'remote access tool - is it approved? (ISM-2149)' }
        @{ Match = 'AnyDesk*';               Latest = '';        CadenceMonths = 1;  EOL = $false; Note = 'remote access tool - is it approved? (ISM-2149)' }
    )
}
