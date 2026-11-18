@{
    # =================================================================
    #  product-patches.psd1  -  the newest patch level known for each
    #  Microsoft product line.  Maintained BY HAND, offline, monthly.
    #  Sources (open them on an internet PC, see "Where do I get patches?"):
    #    Windows   support.microsoft.com update history per Server version
    #    .NET      the LCU article's ".NET Framework updates" section
    #    SQL       learn.microsoft.com/sql/.../latest-updates-for-microsoft-sql-server
    #    Exchange  learn.microsoft.com/exchange/new-features/build-numbers-and-release-dates
    #  The Security console's patch-timeframe check (ISM-1694 and ISM-1695)
    #  uses the Windows entries: days between "Released" and today, compared
    #  with what the server has installed.  Empty or missing = "no reference".
    # =================================================================
    AsOf = '2026-09-09'

    # Windows: one entry per OS build (the number before the dot).  UBR = the number after the dot.
    Windows = @(
        @{ Build = 20348; Name = 'Server 2022'; KB = 'KB5122882'; UBR = 5622; Released = '2026-09-08'; Note = 'September 2026 cumulative update' }
        @{ Build = 17763; Name = 'Server 2019'; KB = 'KB5122876'; UBR = 0;    Released = '2026-09-08'; Note = 'September 2026 cumulative update - set the UBR from the history page' }
        @{ Build = 14393; Name = 'Server 2016'; KB = '';          UBR = 0;    Released = '';           Note = 'fill in from the Server 2016 history page' }
        @{ Build = 26100; Name = 'Server 2025'; KB = '';          UBR = 0;    Released = '';           Note = 'fill in from the Server 2025 history page' }
    )
    # Earlier cumulative updates (optional): Build, KB and UBR from the update-history page.  With an entry here a server
    # already past that KB shows "Installed (build)" for it instead of READY, and a removed update is recognised.
    WindowsHistory = @(
        # @{ Build = 20348; KB = 'KB5121234'; UBR = 5500 }
    )

    # End of support (extended support end).  A server past this date fails ISM-1501.
    WindowsSupport = @(
        @{ Build = 9600;  Name = 'Server 2012 R2'; EndOfSupport = '2023-10-10' }
        @{ Build = 14393; Name = 'Server 2016';    EndOfSupport = '2027-01-12' }
        @{ Build = 17763; Name = 'Server 2019';    EndOfSupport = '2029-01-09' }
        @{ Build = 20348; Name = 'Server 2022';    EndOfSupport = '2031-10-14' }
        @{ Build = 26100; Name = 'Server 2025';    EndOfSupport = '2034-10-10' }
    )

    # .NET Framework: the release number the newest cumulative update reports is not in the registry,
    # so the tool compares the installed .NET line only; the KB for the month comes from patches\DotNet.
    DotNet = @(
        @{ Line = '4.8.1'; Supported = $true }
        @{ Line = '4.8';   Supported = $true }
        @{ Line = '4.7.2'; Supported = $false; Note = 'out of support since 2022-04-26' }
    )

    # .NET runtimes (Microsoft.NETCore.App family): supported majors and end dates
    DotNetRuntime = @(
        @{ Major = 6; EndOfSupport = '2024-11-12' }
        @{ Major = 7; EndOfSupport = '2024-05-14' }
        @{ Major = 8; EndOfSupport = '2026-11-10' }
        @{ Major = 9; EndOfSupport = '2026-05-12' }
    )

    # SQL Server: fill "LatestBuild" from the Microsoft "latest updates" page (the CU or GDR build you want
    # the fleet on).  Major = first number of the Version the server reports (16 = 2022, 15 = 2019, 14 = 2017, 13 = 2016).
    Sql = @(
        @{ Major = 16; Name = 'SQL Server 2022'; LatestBuild = ''; Note = 'fill in' }
        @{ Major = 15; Name = 'SQL Server 2019'; LatestBuild = ''; Note = 'fill in' }
        @{ Major = 14; Name = 'SQL Server 2017'; LatestBuild = ''; Note = 'fill in' }
        @{ Major = 13; Name = 'SQL Server 2016'; LatestBuild = ''; Note = 'fill in' }
    )

    # Exchange: "LatestBuild" = the ExSetup.exe product version of the newest CU + SU.
    Exchange = @(
        @{ Match = '15.2.*'; Name = 'Exchange 2019'; LatestBuild = ''; Note = 'fill in' }
        @{ Match = '15.1.*'; Name = 'Exchange 2016'; LatestBuild = ''; Note = 'fill in' }
    )
}
