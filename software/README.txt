software\  -  installer files for the Software console
=================================================================

Put an installer in any folder you like under software\ - any name, spaces
and sub-folders are fine, e.g.  software\Google Chrome\  or
software\Vendor\Product\.  Press Reload lists + packages in the Software tab:

  * a file a package already claims is offered (ready to tick)
  * any other .msi or .exe shows as * NEW in a yellow box under the
    installer list, with its own Register... button: a form filled from the file (name,
    version, signer, file pattern) writes the package into
    data\software-packages.psd1.  Register once per product; later versions
    dropped into the same folder are picked up by the file pattern.
    Uninstall starts ticked; unticked, the tool never removes the product.
  * every offered file has an Edit... button: the same form, to change its
    package's registration later (only that entry is rewritten).
  * Match in that form is the name Programs and Features shows.  It starts
    wide enough for the names the inventory lists the product under (a copy
    from the vendor's .exe installer is often named differently from the
    .msi: "Wireshark 4.4.2 x64" against "Wireshark").
  * an .msi that will not install over the .exe installer's copy (Wireshark's
    says so itself) shows "Remove <version> first" on such a server: remove
    that copy (UNINSTALL from the inventory list where its Removal column
    offers it, by hand on the server where it reads "by hand"), then INSTALL.
  * to take a package out again: Software library... > select it > Remove
    package...  It asks first, and asks separately whether the package's
    installer files are to be deleted from this folder.
  * other file types (.msp, .zip, .iso ...) are listed as not usable.

Each offered file is vetted before it can be ticked:
  * version   from the file name (VersionRegex) or from inside the file
  * signature Authenticode Valid, signed by one of the package's Signers
  * SHA256    checked again on the server right before it runs
  * arguments an .exe package must suppress the reboot

Keep the vendor's file name.  Older versions may stay in the folder; tick
the one to deploy (one version per package per run).

Installer files are git-ignored (*.exe, *.msi, *.msp, *.zip): they are
large and they are not ours to publish.

software\_info\ is the tool's own: vetting-cache.json keeps the SHA256,
signature and version of every installer, so a big library is not read in
full at every start.  Safe to delete (the next start vets every file
again).  It is git-ignored, and no package may use _info as its folder.

A big library: the Software tab shows at most MaxSoftwareColumns packages
at once (6 by default, Settings tab); its "Software library..." window
lists them all and picks which.

VMware Tools - no Broadcom account needed:
  https://packages.vmware.com/tools/releases/<version>/windows/x64/
  e.g. https://packages.vmware.com/tools/releases/12.5.4/windows/x64/
  take VMware-tools-12.5.4-24964629-x64.exe and put it in software\VMwareTools\.
  Before deploying a release, check it against your ESXi hosts (Broadcom Product
  Interoperability Matrix) and your Windows versions (its release notes).
Everything else: the "Where do I get software?" button on the Software tab.
