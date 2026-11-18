@{
    # =================================================================
    #  software-packages.psd1  -  what the Software console may deploy,
    #  update or remove, and exactly how.
    # -----------------------------------------------------------------
    #  Each package names a folder under software\ (Folder, else its Id);
    #  installer files there that match FilePattern are offered for the
    #  modes listed.  The command line is built from this file only:
    #  nothing typed in the window reaches the server's command line.
    #
    #  The easy way to add one: drop the installer into any folder under
    #  software\, then in the Software tab press Register... next to it
    #  (it shows as * NEW under the installers) - a form filled from the file writes
    #  the entry at the end of the Packages list.  To change an entry later,
    #  press Edit... next to one of its installers: the same form rewrites that
    #  entry only, comments kept.  To take one out: Software library... >
    #  Remove package... (its text goes to the log).  Hand edits work too.
    #
    #  Fields
    #    Id            the package's name in the tool, unique, any text:
    #                  its grid column, and its folder on the servers
    #                  (C:\PatchStaging\software\<Id, spaces as _>)
    #    Folder        optional: its folder under software\ on this PC -
    #                  any name, spaces and sub-folders (Vendor\Product)
    #                  allowed; without it the folder is the Id
    #    Name          shown in the window, the plan and the change log
    #    Match         -like pattern for the product's DisplayName in the
    #                  Uninstall registry (how "installed?" is answered)
    #    FilePattern   which files in software\<Folder>\ are installers
    #    VersionFrom   'name' = VersionRegex on the file name (its groups
    #                  joined with dots); 'msi' = ProductVersion inside the
    #                  .msi; 'file' = the .exe's ProductVersion
    #    Installer     'msi' = msiexec /i <file> /qn /norestart
    #                  REBOOT=ReallySuppress /l*v <log> + Arguments;
    #                  'exe' = the file itself + InstallArguments /
    #                  UpdateArguments, which MUST suppress the reboot
    #                  (REBOOT=R, REBOOT=ReallySuppress or /norestart) -
    #                  a package without it is blocked
    #    Modes         any of 'Install' (not installed yet), 'Update'
    #                  (installed, older version), 'Uninstall'.  Without
    #                  'Uninstall' the product is protected: UNINSTALL
    #                  never removes it (right for VMware Tools only)
    #    Requires      optional: Win32_ComputerSystem.Manufacturer must
    #                  match (-like), e.g. 'VMware*' = VMware VMs only
    #    Signers       the O= of the Authenticode signer must START with
    #                  one of these ('VMware' covers "VMware, Inc.");
    #                  checked here and again on the server
    #    AllowUnsigned optional, $true only for an internal MSI with no
    #                  signature (the SHA256 is still enforced)
    #    {log} in the arguments becomes the installer log path on the
    #    server (C:\PatchStaging\software\sw-<run>-<n>.log); {file} (exe
    #    arguments only) becomes the staged installer's own path.
    #
    #  Success: exit 0, 3010 (reboot required - suppressed, reboot with
    #  the OS patches) and 1641.  Everything else is a failure; the log
    #  path is in the result.
    # =================================================================
    AsOf = '2026-10-20'

    Packages = @(
        @{
            Id            = 'VMwareTools'
            Name          = 'VMware Tools'
            Match         = 'VMware Tools'
            # download, no Broadcom account needed: https://packages.vmware.com/tools/releases/<version>/windows/x64/
            # e.g. https://packages.vmware.com/tools/releases/12.5.4/windows/x64/ -> VMware-tools-12.5.4-24964629-x64.exe
            # the name ends -x64.exe from 12.5 on and -x86_64.exe before; both match (checked 2026-10-21 on packages.vmware.com:
            # 12.1.5, 12.2.0, 12.4.5 end -x86_64.exe; 12.5.0, 12.5.4, 13.1.5 end -x64.exe)
            FilePattern   = 'VMware-tools-*-x*64.exe'
            VersionFrom   = 'name'
            # VMware-tools-12.5.4-24964629-x64.exe -> 12.5.4.24964629, the form the Uninstall key's DisplayVersion uses (VERIFY on one server)
            # (?:...) does not capture: only the version and the build make up the version
            VersionRegex  = '^VMware-tools-(\d+\.\d+\.\d+)-(\d+)-(?:x64|x86_64)\.exe$'
            Installer     = 'exe'
            # never removed by the tool: without it the VM loses its paravirtual network and storage drivers
            Modes         = @('Install', 'Update')
            Requires      = 'VMware*'
            Signers       = @('VMware', 'Broadcom')
            # /S = silent wrapper, /v passes the rest to the MSI.  REBOOT=R suppresses the reboot.
            # ADDLOCAL=ALL installs every feature, including the NSX introspection drivers: narrow it to your build
            # standard with REMOVE=<feature,...> (VMware Tools documentation: "silent installation features") - VERIFY.
            InstallArguments = '/S /v "/qn REBOOT=R ADDLOCAL=ALL /l*v {log}"'
            # an update keeps the features already installed
            UpdateArguments  = '/S /v "/qn REBOOT=R /l*v {log}"'
            Note          = 'Replaces vCenter-managed VMware Tools upgrades: set the VMs to manual upgrade (see "Where do I get software?"). The installer may replace the VMXNET3 driver; the network can drop for a few seconds - the install runs as a task on the server and carries on.'
        }

        # ---- a template for an MSI package: copy it above the closing bracket, remove the #, fill it in ----
        # @{
        #     Id          = 'ExampleAgent'
        #     Name        = 'Example Agent'
        #     Match       = 'Example Agent*'
        #     FilePattern = 'ExampleAgent-*.msi'
        #     VersionFrom = 'msi'
        #     Installer   = 'msi'
        #     Arguments   = 'ADDLOCAL=ALL'          # extra MSI properties; /qn /norestart REBOOT=ReallySuppress and the log are always added
        #     Modes       = @('Install', 'Update', 'Uninstall')
        #     Signers     = @('Example Corporation')
        #     Note        = 'where the installer comes from, who owns the product'
        # }

        @{
            # registered in the Software tab on 2026-10-21 from Google Chrome\googlechromestandaloneenterprise64.msi
            # edited in the Software tab on 2026-10-21
            Id               = 'Google Chrome'
            Name             = 'Google Chrome'
            Folder           = 'Google Chrome'
            Match            = 'Google Chrome'
            FilePattern      = 'googlechromestandaloneenterprise64*.msi'
            VersionFrom      = 'msi'
            Installer        = 'msi'
            Arguments        = ''
            Modes            = @('Install', 'Update', 'Uninstall')
            Signers          = @('Google LLC')
        }
    )

    # Products the UNINSTALL button never removes, whatever is ticked (-like patterns against the DisplayName).
    # Security and management agents are removed through their own console; shared runtimes break other products.
    # The server's SOE standard protects its required software and agents as well.  Edit freely.
    ProtectedProducts = @(
        'VMware Tools*'
        'Trellix*', 'McAfee*', 'CrowdStrike*', 'Microsoft Defender*', '*Endpoint Security*', 'Airlock*'
        'Rapid7*', 'Qualys*', 'Tenable*', 'Nessus Agent*', 'UniversalForwarder*', 'Splunk*'
        'Microsoft Monitoring Agent*', 'Azure Connected Machine Agent*', 'Microsoft Azure*Agent*'
        'Microsoft Visual C++*'
        'Microsoft SQL Server*', 'SQL Server*', 'Microsoft Exchange*'
        'Microsoft Edge*', 'Microsoft Update Health Tools', 'Microsoft Policy Platform', 'Local Administrator Password Solution*'
    )
}
