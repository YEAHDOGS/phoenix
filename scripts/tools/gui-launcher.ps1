#Requires -RunAsAdministrator
#Requires -Version 5.0

<#
.SYNOPSIS
    GUI Launcher for all PowerShell scripts in the get-it-goin project (v2.0 - Modern UI)
    
.DESCRIPTION
    Provides a unified, modern graphical interface to browse, select, and execute
    PowerShell scripts organized by category. Features auto-sizing, animations,
    and professional UX design.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Color Scheme - Modern Dark Theme
$Colors = @{
    Primary       = [System.Drawing.Color]::FromArgb(41, 128, 185)      # Blue
    Secondary     = [System.Drawing.Color]::FromArgb(52, 152, 219)      # Light Blue
    Background    = [System.Drawing.Color]::FromArgb(236, 240, 241)     # Light Gray
    DarkBg        = [System.Drawing.Color]::FromArgb(44, 62, 80)        # Dark Gray
    Text          = [System.Drawing.Color]::FromArgb(52, 73, 94)        # Dark Text
    TextLight     = [System.Drawing.Color]::FromArgb(189, 195, 199)     # Light Text
    Accent        = [System.Drawing.Color]::FromArgb(231, 76, 60)       # Red for warnings
    Success       = [System.Drawing.Color]::FromArgb(39, 174, 96)       # Green
    White         = [System.Drawing.Color]::White
    Border        = [System.Drawing.Color]::FromArgb(189, 195, 199)     # Gray border
}

# Get script directory and paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ScriptsRoot = Split-Path -Parent $ScriptDir

# Source the GUI library for auto-discovery
. (Join-Path $ScriptDir "gui-lib.ps1")

# Build catalog dynamically from file structure
$metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot

# Create main form with modern styling
$form = New-Object System.Windows.Forms.Form
$form.Text = "Get-It-Goin Script Launcher v2.0"
$form.Size = New-Object System.Drawing.Size(1200, 800)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(900, 600)
$form.BackColor = $Colors.Background
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Icon = [System.Drawing.SystemIcons]::Application

# Create menu strip with styling
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.BackColor = $Colors.DarkBg
$menuStrip.ForeColor = $Colors.TextLight
$menuStrip.Font = New-Object System.Drawing.Font("Segoe UI", 10)

$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$fileMenu.Text = "File"
$fileMenu.ForeColor = $Colors.TextLight

$refreshItem = New-Object System.Windows.Forms.ToolStripMenuItem
$refreshItem.Text = "Refresh Catalog (F5)"
$refreshItem.ForeColor = $Colors.TextLight

$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "Exit"
$exitItem.ForeColor = $Colors.TextLight
$exitItem.Add_Click({ $form.Close() })

$fileMenu.DropDownItems.Add($refreshItem) | Out-Null
$fileMenu.DropDownItems.Add($(New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$fileMenu.DropDownItems.Add($exitItem) | Out-Null
$menuStrip.Items.Add($fileMenu) | Out-Null

$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$helpMenu.Text = "Help"
$helpMenu.ForeColor = $Colors.TextLight

$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
$aboutItem.Text = "About"
$aboutItem.ForeColor = $Colors.TextLight
$aboutItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Get-It-Goin Script Launcher v2.0`n`nModern GUI with auto-discovery`n`nScripts: $($metadata.scripts.Count) | Categories: 13`n`nFeatures:`n• Dynamic script discovery`n• Full-text search`n• Auto-sizing UI`n• Smooth animations",
        "About",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})
$helpMenu.DropDownItems.Add($aboutItem) | Out-Null
$menuStrip.Items.Add($helpMenu) | Out-Null

# Create top panel with search (styling enhanced)
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$topPanel.Height = 80
$topPanel.Padding = New-Object System.Windows.Forms.Padding(15, 12, 15, 12)
$topPanel.BackColor = $Colors.DarkBg

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text = "Script Manager"
$titleLabel.AutoSize = $true
$titleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$titleLabel.ForeColor = $Colors.Secondary
$titleLabel.Location = New-Object System.Drawing.Point(15, 8)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "🔍 Search Scripts:"
$searchLabel.AutoSize = $true
$searchLabel.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$searchLabel.ForeColor = $Colors.TextLight
$searchLabel.Location = New-Object System.Drawing.Point(15, 45)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(150, 42)
$searchBox.Width = 350
$searchBox.Height = 28
$searchBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$searchBox.BackColor = $Colors.White
$searchBox.ForeColor = $Colors.Text
$searchBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

$topPanel.Controls.Add($titleLabel)
$topPanel.Controls.Add($searchLabel)
$topPanel.Controls.Add($searchBox)

# Create split container for tree and details
$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitContainer.SplitterDistance = 320
$splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical
$splitContainer.BackColor = $Colors.Background

# Left panel - Tree view with better styling
$treePanel = New-Object System.Windows.Forms.Panel
$treePanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$treePanel.BackColor = $Colors.Background
$treePanel.Padding = New-Object System.Windows.Forms.Padding(8)

$treeTitleLabel = New-Object System.Windows.Forms.Label
$treeTitleLabel.Text = "📂 Categories & Scripts"
$treeTitleLabel.AutoSize = $true
$treeTitleLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$treeTitleLabel.ForeColor = $Colors.Text
$treeTitleLabel.Location = New-Object System.Drawing.Point(8, 8)
$treeTitleLabel.Height = 22

$treeView = New-Object System.Windows.Forms.TreeView
$treeView.Dock = [System.Windows.Forms.DockStyle]::Fill
$treeView.Location = New-Object System.Drawing.Point(8, 30)
$treeView.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$treeView.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$treeView.BackColor = $Colors.White
$treeView.ForeColor = $Colors.Text
$treeView.ImageList = New-Object System.Windows.Forms.ImageList
$treeView.FullRowSelect = $false
$treeView.Margin = New-Object System.Windows.Forms.Padding(0, 22, 0, 0)

$treePanel.Controls.Add($treeTitleLabel)
$treePanel.Controls.Add($treeView)

# Right panel - Script details and output
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$rightPanel.BackColor = $Colors.Background
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(8)

# Script details panel (top)
$detailsPanel = New-Object System.Windows.Forms.Panel
$detailsPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$detailsPanel.Height = 160
$detailsPanel.BackColor = $Colors.White
$detailsPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$detailsPanel.Padding = New-Object System.Windows.Forms.Padding(15)

$scriptNameLabel = New-Object System.Windows.Forms.Label
$scriptNameLabel.Text = "Select a script to view details"
$scriptNameLabel.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
$scriptNameLabel.ForeColor = $Colors.Primary
$scriptNameLabel.AutoSize = $false
$scriptNameLabel.Width = 350
$scriptNameLabel.Height = 30
$scriptNameLabel.Location = New-Object System.Drawing.Point(15, 15)

$scriptPathLabel = New-Object System.Windows.Forms.Label
$scriptPathLabel.Text = ""
$scriptPathLabel.AutoSize = $false
$scriptPathLabel.Width = 450
$scriptPathLabel.Height = 100
$scriptPathLabel.Location = New-Object System.Drawing.Point(15, 50)
$scriptPathLabel.ForeColor = $Colors.Text
$scriptPathLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$scriptPathLabel.WordWrap = $true

$detailsPanel.Controls.Add($scriptNameLabel)
$detailsPanel.Controls.Add($scriptPathLabel)

# Button panel with enhanced styling
$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$buttonPanel.Height = 50
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(15, 10, 15, 10)
$buttonPanel.BackColor = $Colors.Background
$buttonPanel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "▶ Run Script"
$runButton.Width = 120
$runButton.Height = 32
$runButton.Location = New-Object System.Drawing.Point(15, 10)
$runButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$runButton.BackColor = $Colors.Success
$runButton.ForeColor = $Colors.White
$runButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$runButton.FlatAppearance.BorderSize = 0
$runButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(30, 150, 80)
$runButton.Enabled = $false
$runButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "⟳ Refresh"
$refreshButton.Width = 100
$refreshButton.Height = 32
$refreshButton.Location = New-Object System.Drawing.Point(145, 10)
$refreshButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$refreshButton.BackColor = $Colors.Primary
$refreshButton.ForeColor = $Colors.White
$refreshButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$refreshButton.FlatAppearance.BorderSize = 0
$refreshButton.FlatAppearance.MouseOverBackColor = $Colors.Secondary
$refreshButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "🗑 Clear"
$clearButton.Width = 90
$clearButton.Height = 32
$clearButton.Location = New-Object System.Drawing.Point(255, 10)
$clearButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$clearButton.BackColor = $Colors.Accent
$clearButton.ForeColor = $Colors.White
$clearButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$clearButton.FlatAppearance.BorderSize = 0
$clearButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(200, 50, 30)
$clearButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$buttonPanel.Controls.Add($runButton)
$buttonPanel.Controls.Add($refreshButton)
$buttonPanel.Controls.Add($clearButton)

# Output panel with header
$outputHeaderPanel = New-Object System.Windows.Forms.Panel
$outputHeaderPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$outputHeaderPanel.Height = 35
$outputHeaderPanel.BackColor = $Colors.Background
$outputHeaderPanel.Margin = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "📋 Execution Output"
$outputLabel.AutoSize = $true
$outputLabel.Location = New-Object System.Drawing.Point(15, 10)
$outputLabel.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$outputLabel.ForeColor = $Colors.Text

$outputHeaderPanel.Controls.Add($outputLabel)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$outputBox.ReadOnly = $false
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$outputBox.ForeColor = $Colors.TextLight
$outputBox.BackColor = $Colors.DarkBg
$outputBox.Text = "Select a script and click 'Run Script' to execute. Output will appear here."
$outputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

# Assemble right panel
$rightPanel.Controls.Add($outputBox)
$rightPanel.Controls.Add($outputHeaderPanel)
$rightPanel.Controls.Add($buttonPanel)
$rightPanel.Controls.Add($detailsPanel)

$splitContainer.Panel1.Controls.Add($treePanel)
$splitContainer.Panel2.Controls.Add($rightPanel)

# Add controls to form
$form.Controls.Add($splitContainer)
$form.Controls.Add($topPanel)
$form.Controls.Add($menuStrip)

# Current selected script
$selectedScript = $null

# Populate tree view
function PopulateTree {
    $treeView.Nodes.Clear()
    
    $nodes = ConvertTo-TreeViewNodes -Catalog $metadata
    foreach ($node in $nodes) {
        $treeView.Nodes.Add($node) | Out-Null
    }
}

# Handle tree selection with visual feedback
$treeView.Add_AfterSelect({
    $node = $_.Node
    if ($node.Tag.type -eq "script") {
        $selectedScript = $node.Tag
        
        $scriptNameLabel.Text = "📜 $($node.Tag.name)"
        $scriptNameLabel.ForeColor = $Colors.Primary
        
        $details = "📁 Path: $($node.Tag.path)`n"
        if ($node.Tag.description) { $details += "`n📝 Description:`n   $($node.Tag.description)`n" }
        if ($node.Tag.requiresAdmin) { $details += "`n⚠️  Requires Administrator privileges" }
        if ($node.Tag.hasParameters) { $details += "`n🔧 Accepts parameters" }
        
        $scriptPathLabel.Text = $details
        $runButton.Enabled = $true
        $runButton.BackColor = $Colors.Success
    }
    else {
        $selectedScript = $null
        $scriptNameLabel.Text = "Select a script to view details"
        $scriptNameLabel.ForeColor = $Colors.Text
        $scriptPathLabel.Text = ""
        $runButton.Enabled = $false
        $runButton.BackColor = [System.Drawing.Color]::FromArgb(180, 180, 180)
    }
})

# Run script handler
$runButton.Add_Click({
    if ($selectedScript) {
        $fullPath = Join-Path $ScriptsRoot $selectedScript.path
        
        if (Test-Path $fullPath) {
            $outputBox.Clear()
            $outputBox.AppendText("[+] Running: $($selectedScript.name)`r`n")
            $outputBox.AppendText("[*] Path: $fullPath`r`n")
            $outputBox.AppendText("`r`n" + ("="*70) + "`r`n")
            
            try {
                $output = & $fullPath 2>&1
                foreach ($line in $output) {
                    $outputBox.AppendText("$line`r`n")
                }
                $outputBox.AppendText("`r`n" + ("="*70) + "`r`n")
                $outputBox.AppendText("[✓] Script completed successfully`r`n")
            }
            catch {
                $outputBox.AppendText("[✗] Error: $_`r`n")
            }
            
            $outputBox.ScrollToCaret()
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Script not found: $fullPath", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        }
    }
})

# Clear output handler
$clearButton.Add_Click({
    $outputBox.Clear()
})

# Refresh handler
$refreshButton.Add_Click({
    $metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot
    PopulateTree
})

$refreshItem.Add_Click({
    $metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot
    PopulateTree
})

# Search functionality with live filtering
$searchBox.Add_TextChanged({
    $query = $searchBox.Text.ToLower()
    
    if ([string]::IsNullOrWhiteSpace($query)) {
        PopulateTree
    }
    else {
        $filtered = Filter-CatalogBySearch -Catalog $metadata -Query $query
        $treeView.Nodes.Clear()
        
        $nodes = ConvertTo-TreeViewNodes -Catalog $filtered
        foreach ($node in $nodes) {
            $treeView.Nodes.Add($node) | Out-Null
        }
    }
})

# F5 key for refresh
$form.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        $metadata = Build-ScriptCatalog -ScriptsRoot $ScriptsRoot
        PopulateTree
        $_.Handled = $true
    }
})

# Initial population
PopulateTree

# Show form
$form.ShowDialog() | Out-Null
