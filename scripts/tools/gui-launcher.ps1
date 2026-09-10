#Requires -RunAsAdministrator
#Requires -Version 5.0

<#
.SYNOPSIS
    GUI Launcher for all PowerShell scripts (v3.0 - Improved List-Based UI)
    
.DESCRIPTION
    Modern graphical interface with list-based script selection,
    better organization, and cleaner UX.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Color Scheme
$Colors = @{
    Primary       = [System.Drawing.Color]::FromArgb(41, 128, 185)
    Secondary     = [System.Drawing.Color]::FromArgb(52, 152, 219)
    Background    = [System.Drawing.Color]::FromArgb(236, 240, 241)
    DarkBg        = [System.Drawing.Color]::FromArgb(44, 62, 80)
    Text          = [System.Drawing.Color]::FromArgb(52, 73, 94)
    TextLight     = [System.Drawing.Color]::FromArgb(189, 195, 199)
    Accent        = [System.Drawing.Color]::FromArgb(231, 76, 60)
    Success       = [System.Drawing.Color]::FromArgb(39, 174, 96)
    White         = [System.Drawing.Color]::White
    Hover         = [System.Drawing.Color]::FromArgb(236, 240, 241)
}

# Get script directory and paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ScriptsRoot = Split-Path -Parent $ScriptDir

# Source the GUI library
. (Join-Path $ScriptDir "gui-lib.ps1")

# Build catalog
$metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot

# Create main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Phoenix Script Launcher v3.0"
$form.Size = New-Object System.Drawing.Size(1400, 900)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$form.BackColor = $Colors.Background
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)

# Menu bar
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.BackColor = $Colors.DarkBg
$menuStrip.ForeColor = $Colors.TextLight

$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$fileMenu.Text = "File"
$fileMenu.ForeColor = $Colors.TextLight
$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
$refreshItem.Text = "Refresh (F5)"
$fileMenu.DropDownItems.Add($refreshItem) | Out-Null
$fileMenu.DropDownItems.Add($(New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
# Phoenix USB Builder (gui/phoenix-setup.ps1, dot-sourced as a library).
# Additive: the Scripts view below is untouched.
$builderItem = New-Object System.Windows.Forms.ToolStripMenuItem
$builderItem.Text = "USB Builder..."
$builderItem.Add_Click({
    $builderPath = Join-Path (Split-Path (Split-Path $ScriptDir -Parent) -Parent) "gui\phoenix-setup.ps1"
    if (-not (Test-Path $builderPath)) {
        [System.Windows.Forms.MessageBox]::Show("USB Builder not found:`n$builderPath", "USB Builder",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    . $builderPath
    Show-PhoenixBuilder
})
$fileMenu.DropDownItems.Add($builderItem) | Out-Null
$fileMenu.DropDownItems.Add($(New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"
$exitItem.Add_Click({ $form.Close() })
$fileMenu.DropDownItems.Add($exitItem) | Out-Null
$menuStrip.Items.Add($fileMenu) | Out-Null

$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$helpMenu.Text = "Help"
$helpMenu.ForeColor = $Colors.TextLight
$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
$aboutItem.Text = "About"
$aboutItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show("Phoenix Script Launcher v3.0`n`nScripts: $($metadata.scripts.Count)`nCategories: 13","About") | Out-Null
})
$helpMenu.DropDownItems.Add($aboutItem) | Out-Null
$menuStrip.Items.Add($helpMenu) | Out-Null

# Top panel with search and category filter
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$topPanel.Height = 90
$topPanel.BackColor = $Colors.DarkBg
$topPanel.Padding = New-Object System.Windows.Forms.Padding(15)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "SCRIPTS - Script Manager"
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = $Colors.Secondary
$titleLabel.AutoSize = $true
$titleLabel.Location = New-Object System.Drawing.Point(15, 8)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "SEARCH:"
$searchLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$searchLabel.ForeColor = $Colors.TextLight
$searchLabel.AutoSize = $true
$searchLabel.Location = New-Object System.Drawing.Point(15, 45)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(100, 42)
$searchBox.Width = 350
$searchBox.Height = 28
$searchBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$searchBox.BackColor = $Colors.White

$categoryLabel = New-Object System.Windows.Forms.Label
$categoryLabel.Text = "CATEGORY:"
$categoryLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$categoryLabel.ForeColor = $Colors.TextLight
$categoryLabel.AutoSize = $true
$categoryLabel.Location = New-Object System.Drawing.Point(480, 45)

$categoryCombo = New-Object System.Windows.Forms.ComboBox
$categoryCombo.Location = New-Object System.Drawing.Point(570, 42)
$categoryCombo.Width = 250
$categoryCombo.Height = 28
$categoryCombo.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$categoryCombo.BackColor = $Colors.White
$categoryCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList

$topPanel.Controls.Add($titleLabel)
$topPanel.Controls.Add($searchLabel)
$topPanel.Controls.Add($searchBox)
$topPanel.Controls.Add($categoryLabel)
$topPanel.Controls.Add($categoryCombo)

# Main content split
$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitContainer.SplitterDistance = 550
$splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitContainer.BackColor = $Colors.Background

# Left panel - Script list
$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$leftPanel.BackColor = $Colors.Background
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(8)

$listLabel = New-Object System.Windows.Forms.Label
$listLabel.Text = "Available Scripts"
$listLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$listLabel.ForeColor = $Colors.Text
$listLabel.AutoSize = $true
$listLabel.Location = New-Object System.Drawing.Point(8, 8)

$scriptList = New-Object System.Windows.Forms.ListBox
$scriptList.Dock = [System.Windows.Forms.DockStyle]::Fill
$scriptList.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$scriptList.BackColor = $Colors.White
$scriptList.ForeColor = $Colors.Text
$scriptList.Location = New-Object System.Drawing.Point(8, 30)
$scriptList.Margin = New-Object System.Windows.Forms.Padding(0, 22, 0, 0)
$scriptList.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$leftPanel.Controls.Add($listLabel)
$leftPanel.Controls.Add($scriptList)

# Right panel - Details and output
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$rightPanel.BackColor = $Colors.Background
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(8)

# Details panel
$detailsPanel = New-Object System.Windows.Forms.Panel
$detailsPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$detailsPanel.Height = 180
$detailsPanel.BackColor = $Colors.White
$detailsPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$detailsPanel.Padding = New-Object System.Windows.Forms.Padding(15)

$scriptNameLabel = New-Object System.Windows.Forms.Label
$scriptNameLabel.Text = "Select a script"
$scriptNameLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$scriptNameLabel.ForeColor = $Colors.Primary
$scriptNameLabel.AutoSize = $false
$scriptNameLabel.Width = 350
$scriptNameLabel.Height = 30
$scriptNameLabel.Location = New-Object System.Drawing.Point(15, 15)

$scriptDetailsLabel = New-Object System.Windows.Forms.Label
$scriptDetailsLabel.Text = ""
$scriptDetailsLabel.AutoSize = $false
$scriptDetailsLabel.Width = 400
$scriptDetailsLabel.Height = 130
$scriptDetailsLabel.Location = New-Object System.Drawing.Point(15, 50)
$scriptDetailsLabel.ForeColor = $Colors.Text
$scriptDetailsLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$detailsPanel.Controls.Add($scriptNameLabel)
$detailsPanel.Controls.Add($scriptDetailsLabel)

# Buttons panel
$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$buttonPanel.Height = 50
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)
$buttonPanel.BackColor = $Colors.Background
$buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "RUN Script"
$runButton.Width = 120
$runButton.Height = 32
$runButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$runButton.BackColor = $Colors.Success
$runButton.ForeColor = $Colors.White
$runButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$runButton.FlatAppearance.BorderSize = 0
$runButton.Enabled = $false
$runButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$runButton.Location = New-Object System.Drawing.Point(15, 10)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "CLEAR Output"
$clearButton.Width = 120
$clearButton.Height = 32
$clearButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$clearButton.BackColor = $Colors.Accent
$clearButton.ForeColor = $Colors.White
$clearButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$clearButton.FlatAppearance.BorderSize = 0
$clearButton.Cursor = [System.Windows.Forms.Cursors]::Hand
$clearButton.Location = New-Object System.Drawing.Point(145, 10)

$buttonPanel.Controls.Add($runButton)
$buttonPanel.Controls.Add($clearButton)

# Output panel
$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "OUTPUT"
$outputLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$outputLabel.ForeColor = $Colors.Text
$outputLabel.AutoSize = $true
$outputLabel.Dock = [System.Windows.Forms.DockStyle]::Top
$outputLabel.Padding = New-Object System.Windows.Forms.Padding(15, 8, 15, 5)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$outputBox.ForeColor = $Colors.TextLight
$outputBox.BackColor = $Colors.DarkBg
$outputBox.Text = "Output will appear here"
$outputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$outputBox.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

$rightPanel.Controls.Add($outputBox)
$rightPanel.Controls.Add($outputLabel)
$rightPanel.Controls.Add($buttonPanel)
$rightPanel.Controls.Add($detailsPanel)

$splitContainer.Panel1.Controls.Add($leftPanel)
$splitContainer.Panel2.Controls.Add($rightPanel)

# Add to form
$form.Controls.Add($splitContainer)
$form.Controls.Add($topPanel)
$form.Controls.Add($menuStrip)

# Current selection
$selectedScript = $null
$filteredScripts = @()  # Keep track of filtered scripts for proper indexing

# Populate category combo and script list
function RefreshScriptList {
    $categoryCombo.Items.Clear()
    $categoryCombo.Items.Add("All Categories")
    $metadata.categories.Keys | Sort-Object | ForEach-Object {
        $categoryCombo.Items.Add($_) | Out-Null
    }
    $categoryCombo.SelectedIndex = 0
    
    UpdateScriptList
}

# Update script list based on category and search
function UpdateScriptList {
    $scriptList.Items.Clear()
    
    $selectedCategory = if ($categoryCombo.SelectedIndex -le 0) { $null } else { $categoryCombo.SelectedItem }
    $searchTerm = $searchBox.Text.ToLower()
    
    $script:filteredScripts = @($metadata.scripts | Where-Object {
        ($selectedCategory -eq $null -or $_.category -eq $selectedCategory) -and
        ($_.name.ToLower().Contains($searchTerm) -or $_.description.ToLower().Contains($searchTerm))
    })
    
    $script:filteredScripts | ForEach-Object {
        $folder = [System.IO.Path]::GetDirectoryName($_.path)
        $displayFolder = if ($folder) { "$folder/" } else { "" }
        $adminIcon = if ($_.requiresAdmin) { "ADMIN " } else { "" }
        $displayName = "$adminIcon$displayFolder$($_.name)"
        $scriptList.Items.Add($displayName) | Out-Null
    }
}

# Handle script selection
$scriptList.Add_SelectedIndexChanged({
    if ($scriptList.SelectedIndex -ge 0 -and $scriptList.SelectedIndex -lt $filteredScripts.Count) {
        $selectedScript = $filteredScripts[$scriptList.SelectedIndex]
        
        $scriptNameLabel.Text = "SCRIPT: $($selectedScript.name)"
        $scriptNameLabel.ForeColor = $Colors.Primary
        
        $details = "CATEGORY: $($selectedScript.category)`n"
        $details += "PATH: $($selectedScript.path)`n`n"
        if ($selectedScript.description) { $details += "DESCRIPTION: $($selectedScript.description)`n" }
        if ($selectedScript.requiresAdmin) { $details += "`nADMIN: Requires Admin Privileges" }
        if ($selectedScript.hasParameters) { $details += "`nPARAMS: Accepts Parameters" }
        
        $scriptDetailsLabel.Text = $details
        $runButton.Enabled = $true
    }
    else {
        $selectedScript = $null
        $scriptNameLabel.Text = "Select a script"
        $scriptNameLabel.ForeColor = $Colors.Text
        $scriptDetailsLabel.Text = ""
        $runButton.Enabled = $false
    }
})

# Run button
$runButton.Add_Click({
    if ($selectedScript -and $selectedScript.path) {
        $fullPath = Join-Path $ScriptsRoot $selectedScript.path.Replace("/", "\")
        
        if (Test-Path $fullPath) {
            $outputBox.Clear()
            $outputBox.AppendText("[+] Running: $($selectedScript.name)`r`n")
            $outputBox.AppendText("[*] Path: $fullPath`r`n")
            $outputBox.AppendText("`r`n" + ("="*70) + "`r`n")
            
            try {
                # Execute script and capture output
                $output = & $fullPath 2>&1
                if ($output) {
                    foreach ($line in $output) {
                        $outputBox.AppendText("$line`r`n")
                    }
                } else {
                    $outputBox.AppendText("[*] Script executed with no output`r`n")
                }
                $outputBox.AppendText("`r`n" + ("="*70) + "`r`n")
                $outputBox.AppendText("[OK] Script completed successfully`r`n")
            }
            catch {
                $outputBox.AppendText("[ERROR] $_`r`n")
                $outputBox.AppendText("[STACK] $($_.ScriptStackTrace)`r`n")
            }
            
            $outputBox.ScrollToCaret()
        }
        else {
            $outputBox.Clear()
            $outputBox.AppendText("[ERROR] Script not found: $fullPath`r`n")
        }
    }
    else {
        $outputBox.Clear()
        $outputBox.AppendText("[ERROR] No script selected`r`n")
    }
})

# Clear button
$clearButton.Add_Click({
    $outputBox.Clear()
})

# Search
$searchBox.Add_TextChanged({
    UpdateScriptList
})

# Category filter
$categoryCombo.Add_SelectedIndexChanged({
    UpdateScriptList
})

# Refresh
$refreshItem.Add_Click({
    $metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot
    RefreshScriptList
})

# F5 shortcut
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        $metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot
        RefreshScriptList
        $_.Handled = $true
    }
})

# Initial load
RefreshScriptList

# Show
$form.ShowDialog() | Out-Null
