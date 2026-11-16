# =====================================================================
#  30-Console-Products.ps1  -  THE PRODUCTS CONSOLE
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Every product of data\products.psd1 as a row.  A tick fetches the
#  product, no tick leaves it alone - no file to edit.  The From column
#  is a link: a click opens the source in the browser, so the operator
#  sees for themselves where a file comes from.  Under the grid, the
#  installers whose link a person gives (products with Source =
#  'manual').  Ticks and links are saved for this site in
#  settings\environment.json (lib\03-Products.ps1 checks them).  What
#  the site runs - the Windows builds, the .NET lines, the ESXi line -
#  is on the Settings console.
# =====================================================================

function Get-ProductRows {
    # One row per product, as the grid shows it.  Enabled is what is in use (the file's choice, or the site's saved tick).
    return @(Get-Products | ForEach-Object {
        $prod = $_
        $goes = $(if ($prod.Source -eq 'catalog') { 'patches\' + $prod.PatchType } else { 'software\' + $prod.Folder })
        $address = Get-ProductSourceUrl -Product $prod
        $tip = [string]$prod.Note
        if ([bool]$prod.Enabled -ne [bool]$prod.EnabledInFile) { $tip = ('{0}  (data\products.psd1 has it {1}; this site''s tick is saved in settings\environment.json)' -f $tip, $(if ($prod.EnabledInFile) { 'on' } else { 'off' })).Trim() }
        [pscustomobject]@{ Product = $prod.Name; Id = $prod.Id; Source = $prod.Source; From = $address; 'Goes to' = $goes; Signers = ($prod.Signers -join ' / '); Note = $prod.Note; Url = $address; Enabled = [bool]$prod.Enabled; InFile = [bool]$prod.EnabledInFile; Tip = $tip }
    })
}

function Set-ProductRowLook {
    # A ticked product reads black on white, one left alone grey - and its link stays a link
    param($Grid, $Item)
    if ($Item.Checked) { $Item.BackColor = [System.Drawing.Color]::White; $Item.ForeColor = [System.Drawing.Color]::Black }
    else { $Item.BackColor = [System.Drawing.Color]::WhiteSmoke; $Item.ForeColor = [System.Drawing.Color]::DimGray }
    Set-GridLinkCell -Grid $Grid -Item $Item
}

function Update-ProductsDirty {
    # The page against what is saved: a tick or a link that differs shows UNSAVED CHANGES, a change taken back clears it.
    if ($script:Gui['ProductsFilling']) { return }
    $grid = $script:Gui['ProductGrid']; if (-not $grid) { return }
    $changed = $false; $ticked = 0
    foreach ($item in $grid.Items) {
        if ($item.Checked) { $ticked++ }
        if ($item.Tag -and ([bool]$item.Checked -ne [bool]$item.Tag.Enabled)) { $changed = $true }
    }
    $boxes = $script:Gui['ProductLinkBoxes']
    foreach ($id in @($boxes.Keys)) {
        $saved = ''; if ($script:Environment.ManualLinks -and $script:Environment.ManualLinks.Contains($id)) { $saved = ([string]$script:Environment.ManualLinks[$id]).Trim() }
        if (([string]$boxes[$id].Text).Trim() -cne $saved) { $changed = $true }
    }
    $script:Gui['ProductsDirty'] = $changed
    $script:Gui['ProductsDirtyLabel'].Visible = $changed
    $script:Gui['ProductHeader'].Info.Text = ('{0} product(s), {1} ticked' -f $grid.Items.Count, $ticked)
}

function Update-ProductsGrid {
    # The grid from data\products.psd1 and the site's saved ticks.  A tick changed on the page and not yet saved stays as it
    # is (the file may have been read again meanwhile); -Reset shows what is saved.
    param([switch]$Reset)
    $grid = $script:Gui['ProductGrid']; if (-not $grid) { return }
    $pending = @{}
    if (-not $Reset) { foreach ($item in $grid.Items) { if ($item.Tag -and ([bool]$item.Checked -ne [bool]$item.Tag.Enabled)) { $pending[[string]$item.Tag.Id] = [bool]$item.Checked } } }
    Set-GridRows -Grid $grid -Rows @(Get-ProductRows) -ToolTipProperty 'Tip' -NoKeepChecks
    $script:GridProgrammatic = $true
    try {
        foreach ($item in $grid.Items) {
            $on = [bool]$item.Tag.Enabled
            if ($pending.ContainsKey([string]$item.Tag.Id)) { $on = [bool]$pending[[string]$item.Tag.Id] }
            $item.Checked = $on
        }
    } finally { $script:GridProgrammatic = $false }
    Set-GridLinkColumn -Grid $grid -Column 'From' -UrlProperty 'Url'
    foreach ($item in $grid.Items) { Set-ProductRowLook -Grid $grid -Item $item }
    Update-ProductsDirty
}

function Set-ProductsForm {
    # The page shows what is saved again: the ticks, and the links given by hand
    $boxes = $script:Gui['ProductLinkBoxes']
    $script:Gui['ProductsFilling'] = $true
    try {
        foreach ($id in @($boxes.Keys)) {
            $saved = ''; if ($script:Environment.ManualLinks -and $script:Environment.ManualLinks.Contains($id)) { $saved = [string]$script:Environment.ManualLinks[$id] }
            $boxes[$id].Text = $saved
        }
    } finally { $script:Gui['ProductsFilling'] = $false }
    Update-ProductsGrid -Reset
}

function Get-ProductsFormValues {
    # What the page holds, as lib\03-Products.ps1 saves it: every product's tick (only those that differ from the file are
    # kept there) and every link typed.  No rows on the page (the products file could not be read) = the saved ticks stay.
    $v = @{}
    $grid = $script:Gui['ProductGrid']
    if ($grid -and $grid.Items.Count -gt 0) {
        $ticks = [ordered]@{}
        foreach ($item in $grid.Items) { if ($item.Tag) { $ticks[[string]$item.Tag.Id] = [bool]$item.Checked } }
        $v['Products'] = $ticks
    }
    $links = [ordered]@{}
    $boxes = $script:Gui['ProductLinkBoxes']
    foreach ($id in @($boxes.Keys)) { $typed = ([string]$boxes[$id].Text).Trim(); if ($typed) { $links[$id] = $typed } }
    $v['ManualLinks'] = $links
    return $v
}

function Get-ProductsChangeLines {
    # What Save would change, in words: a product fetched from now on or no longer, a link given, changed or taken away.
    # Throws with the reason when a value does not fit (a link of the wrong shape).
    param([hashtable]$Values)
    $lines = @()
    $ticks = $null; if ($Values.ContainsKey('Products')) { $ticks = Test-EnvironmentValue -Key 'Products' -Value $Values['Products'] }
    $links = Test-EnvironmentValue -Key 'ManualLinks' -Value $Values['ManualLinks']
    foreach ($prod in @(Get-Products)) {
        $id = [string]$prod.Id
        if ($null -ne $ticks) {
            $on = [bool]$prod.EnabledInFile; if ($ticks.Contains($id)) { $on = [bool]$ticks[$id] }
            if ($on -ne [bool]$prod.Enabled) { $lines += ('{0}: {1}' -f $prod.Name, $(if ($on) { 'fetched from now on' } else { 'no longer fetched' })) }
        }
        if ($prod.Source -eq 'manual') {
            $was = Get-ManualLink -Product $prod
            $now = ''; if ($links.Contains($id)) { $now = [string]$links[$id] }
            if ($was -cne $now) { $lines += ('{0}, its link: {1}  ->  {2}' -f $prod.Name, $(if ($was) { $was } else { '(none)' }), $(if ($now) { $now } else { '(none)' })) }
        }
    }
    return $lines
}

function Invoke-ProductsSave {
    $values = Get-ProductsFormValues
    try { $lines = @(Get-ProductsChangeLines -Values $values) }
    catch { $null = Show-PatcherMessage -Text ("Nothing was saved:`n`n{0}" -f $_.Exception.Message) -Title 'Products not saved' -Icon 'Warning'; return }
    if ($lines.Count -eq 0) { Write-PatchLog 'Products: nothing to save - the page shows what is in use' 'INFO'; Set-ProductsForm; return }
    $text = "Save these changes?`n`n" + (($lines | ForEach-Object { '- ' + $_ }) -join "`n") + "`n`nCheck for updates on the Library tab afterwards."
    if ((Show-PatcherMessage -Title 'Save products' -Buttons 'YesNo' -Icon 'Question' -Text $text) -ne 'Yes') { Write-PatchLog 'Products not saved (answered No) - the page still shows the unsaved changes' 'INFO'; return }
    $null = Save-Environment -Values $values
    Set-ProductsForm
    if ($script:Gui['SettingsStatus']) { Update-SettingsStatus }
    foreach ($k in @($script:Gui['RefreshByConsole'].Keys)) { $script:Gui['Stale'][$k] = $true }
}

function Get-ProductsHelpHtml {
    $notes = @'
WHAT THIS PAGE IS

Every product the Download Toolkit knows, one row each: what it is, where it is looked for, where its files go in the library and who must have signed them. A ticked product is fetched; one without a tick is left alone. Nothing here needs a file edited.

TICK WHAT THIS SITE WANTS

  * Tick a product to fetch it, take the tick away to leave it. Press Save products: the page shows what changes first. Undo unsaved changes goes back to what is saved.
  * The ticks are this site's own (settings\environment.json). data\products.psd1 keeps its own on / off for every product and is not written to: a product nobody ticked or unticked follows the file.
  * A product without a tick shows as "Off" on the Library tab and is never fetched, not by the buttons and not by the scheduled task.
  * Read a product's note (the last column, and the tip over the row) before ticking one that ships off: Npcap's free licence covers five systems and has no silent install.

CHECK WHERE A FILE COMES FROM

  * The From column is the address the tool reads for that product: the Microsoft Update Catalog, the VMware package site, a vendor's download page, Microsoft's Edge list for administrators. Click it and it opens in your browser.
  * Compare it with the vendor's own site before trusting it. The tool only ever takes a file from the address shown, checks it against the hash the vendor publishes there and against the signer in the Signers column.
  * The addresses in the running log can be clicked the same way.

INSTALLERS WHOSE LINK IS GIVEN BY HAND

  * Some vendors' download pages are for people, not for tools, and the version to run is the site's decision (Splunk Universal Forwarder must suit the indexers). For such a product the tool reads no vendor page: click "Find it on", find the installer there, copy its link, paste it in the box and save.
  * The tool then fetches that file like any other and checks it against the vendor's own checksum file beside it and against the signer. A new version is a new link: paste it, save, check for updates.
  * An empty box is not an error: the product's row on the Library tab says "By hand" and nothing is fetched. A file placed in the product's folder yourself shows as "placed by hand".

WHAT THE SITE RUNS

  * Which Windows builds, .NET Framework lines and ESXi line the updates are fetched for is set on the Settings tab (the first box).

A NEW PRODUCT

  * data\products.psd1 lists the products (Open data folder). It is plain text and is read again when it changes; a new product is a new block there, and it then shows here with its tick.
  * A product's Folder is the same folder the WinRM toolkit's package uses (data\software-packages.psd1), so the file lands where that package looks.
'@
    return (New-DetailsHtml -Title 'Help: the Products console' -Subtitle 'what is fetched, and from where' -Console 'Products' -Sections @(@{ Heading = ''; Html = (ConvertTo-HtmlFromNotes -Text $notes) }))
}

function New-ProductsConsole {
    param($Tabs)
    $tab = Register-ConsoleTab -Tabs $Tabs -Console 'Products' -Text 'Products'
    $script:Gui['ProductLinkBoxes'] = [ordered]@{}
    $script:Gui['ProductsDirty'] = $false
    $regular = New-Object System.Drawing.Font('Segoe UI', 9)
    $bold = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)

    # ---- the products: a tick fetches, the From column opens the source ----
    $main = New-Object System.Windows.Forms.Panel
    $main.Dock = 'Fill'; $main.BackColor = 'White'
    $tab.Controls.Add($main)
    $pgrid = New-ConsoleGrid -Columns @(@{ Name = 'Product'; Width = 250 }, @{ Name = 'Id'; Width = 100 }, @{ Name = 'Source'; Width = 90 }, @{ Name = 'From'; Width = 400 }, @{ Name = 'Goes to'; Width = 170 }, @{ Name = 'Signers'; Width = 180 }, @{ Name = 'Note'; Width = 200; Fill = $true })
    $pgrid.Add_ItemChecked({ if ($script:GridProgrammatic) { return }; Set-ProductRowLook -Grid $this -Item $_.Item; Update-ProductsDirty })
    $phead = New-GridHeader -Heading 'Products' -Detail '' -Tip 'Tick = fetched. Click a From address to open the source.'
    $script:Gui['ProductGrid'] = $pgrid; $script:Gui['ProductHeader'] = $phead

    # ---- installers whose link a person gives (Source = 'manual': the operator reads the vendor's page, never the tool;
    #      the tool fetches the link and checks the file against the vendor's checksum) ----
    $manual = @(Get-Products | Where-Object { $_.Source -eq 'manual' })
    $linkPanel = $null
    if ($manual.Count -gt 0) {
        $linkPanel = New-Object System.Windows.Forms.Panel
        $linkPanel.Dock = 'Bottom'; $linkPanel.Height = 36 + 48 * $manual.Count; $linkPanel.BackColor = 'White'; $linkPanel.Padding = New-Object System.Windows.Forms.Padding(8, 4, 8, 6)
        $box = New-Object System.Windows.Forms.GroupBox
        $box.Text = 'Installers whose link is given by hand'; $box.Dock = 'Fill'; $box.Font = $bold
        $box.Add_Resize({ foreach ($b in @($script:Gui['ProductLinkBoxes'].Values)) { $b.Width = [math]::Max(300, $this.ClientSize.Width - 284) } })
        $linkPanel.Controls.Add($box)
        $y = 24
        foreach ($mp in $manual) {
            $name = New-Object System.Windows.Forms.Label
            $name.Text = ($mp.Name + ':'); $name.Font = $regular; $name.AutoEllipsis = $true; $name.Location = New-Object System.Drawing.Point(12, ($y + 3)); $name.Size = New-Object System.Drawing.Size(250, 20)
            $box.Controls.Add($name)
            $linkBox = New-Object System.Windows.Forms.TextBox
            $linkBox.Font = $regular; $linkBox.MaxLength = 400; $linkBox.Location = New-Object System.Drawing.Point(268, $y); $linkBox.Width = 700
            $linkBox.Add_TextChanged({ Update-ProductsDirty })
            $box.Controls.Add($linkBox); $script:Gui['ProductLinkBoxes'][[string]$mp.Id] = $linkBox
            $script:Gui['Tips'].SetToolTip($linkBox, 'The installer link from the vendor''s page. Empty = not fetched.')
            # where to find the link: the vendor's page, opened with a click
            $find = New-Object System.Windows.Forms.LinkLabel
            $find.Font = $regular; $find.AutoSize = $true; $find.Location = New-Object System.Drawing.Point(266, ($y + 25))
            if ($mp.ManualPage) {
                $find.Text = ('Find it on: ' + $mp.ManualPage); $find.Tag = [string]$mp.ManualPage
                $find.LinkArea = New-Object System.Windows.Forms.LinkArea(12, ([string]$mp.ManualPage).Length)
                $find.Add_LinkClicked({ $null = Open-WebLink -Url ([string]$this.Tag) })
            } else {
                $find.Text = 'Find it on: the vendor''s download page'; $find.LinkArea = New-Object System.Windows.Forms.LinkArea(0, 0)
            }
            $box.Controls.Add($find)
            $y += 48
        }
    }
    $main.Controls.Add($pgrid); $main.Controls.Add($phead.Panel)
    if ($linkPanel) { $main.Controls.Add($linkPanel) }
    $pgrid.BringToFront()
    $script:Gui['ProductLinkPanel'] = $linkPanel

    # ---- toolbar ----
    $toolbar = New-ConsoleToolbar -Tab $tab -Height 50
    $toolbar.Controls.Add((New-GuiButton -Text 'Save products' -X 8 -Y 8 -W 130 -H 34 -Colour 'LightGreen' -Tip 'Shows what changes, then saves the ticks and the links for this site and uses them at once' -OnClick { Invoke-GuiAction -Name 'Save products' -Action { Invoke-ProductsSave } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Undo unsaved changes' -X 143 -Y 8 -W 165 -H 34 -ReadOnly -Tip 'The page shows what is saved again' -OnClick { Invoke-GuiAction -Name 'Undo product changes' -ReadOnly -Action { Set-ProductsForm } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Open data folder' -X 313 -Y 8 -W 130 -H 34 -ReadOnly -Tip 'data\ in Explorer: products.psd1, the list of products' -OnClick { Invoke-GuiAction -Name 'Open data folder' -ReadOnly -Action { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:Config.DataFolder) } }))
    $toolbar.Controls.Add((New-GuiButton -Text 'Help' -X 448 -Y 8 -W 70 -H 34 -ReadOnly -OnClick { Invoke-GuiAction -Name 'Products help' -ReadOnly -Action { Show-ConsoleHelp -Console 'Products' -Html (Get-ProductsHelpHtml) } }))
    $dirty = New-Object System.Windows.Forms.Label
    $dirty.Text = 'UNSAVED CHANGES'; $dirty.ForeColor = 'DarkRed'; $dirty.AutoSize = $true; $dirty.Visible = $false
    $dirty.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold); $dirty.Location = New-Object System.Drawing.Point(540, 16)
    $toolbar.Controls.Add($dirty); $script:Gui['ProductsDirtyLabel'] = $dirty

    $null = New-ConsoleBanner -Tab $tab -Console 'Products' -Title 'PRODUCTS' -Subtitle 'what is fetched, and from where - tick a product to fetch it, click its source to check it'
    $main.BringToFront()
    Set-ProductsForm
    Register-ConsoleRefresher -Console 'Products' -Refresh { Update-ProductsGrid }
}
