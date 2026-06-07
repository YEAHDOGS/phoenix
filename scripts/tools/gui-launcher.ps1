#Requires -RunAsAdministrator
#Requires -Version 5.0

<#
.SYNOPSIS
    GUI Launcher for all PowerShell scripts in the get-it-goin project
    
.DESCRIPTION
    Provides a unified graphical interface to browse, select, and execute
    PowerShell scripts organized by category. Handles parameter input,
    admin elevation, and output display.
#>

param(
    [switch]$NoElevation
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Get script directory and paths
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ScriptsRoot = Split-Path -Parent $ScriptDir
$MetadataFile = Join-Path $ScriptDir "script-metadata.json"

# Load metadata
$metadata = @{}
if (Test-Path $MetadataFile) {
    try {
        $metadata = Get-Content $MetadataFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "Warning: Could not load metadata file" -ForegroundColor Yellow
    }
}

# Create main form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Get-It-Goin Script Launcher"
$form.Size = New-Object System.Drawing.Size(1000, 700)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MinimumSize = New-Object System.Drawing.Size(800, 500)
$form.Icon = [System.Drawing.SystemIcons]::Application

# Create menu strip
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$fileMenu.Text = "&File"
$exitItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitItem.Text = "E&xit"
$exitItem.Add_Click({ $form.Close() })
$fileMenu.DropDownItems.Add($exitItem) | Out-Null
$menuStrip.Items.Add($fileMenu) | Out-Null

$helpMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$helpMenu.Text = "&Help"
$aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem
$aboutItem.Text = "&About"
$aboutItem.Add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        "Get-It-Goin Script Launcher v1.0`n`nA unified interface to run all scripts in the project.",
        "About",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
})
$helpMenu.DropDownItems.Add($aboutItem) | Out-Null
$menuStrip.Items.Add($helpMenu) | Out-Null

# Create panel layout - Top panel with controls
$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$topPanel.Height = 50
$topPanel.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)

$searchLabel = New-Object System.Windows.Forms.Label
$searchLabel.Text = "Search:"
$searchLabel.AutoSize = $true
$searchLabel.Location = New-Object System.Drawing.Point(10, 10)

$searchBox = New-Object System.Windows.Forms.TextBox
$searchBox.Location = New-Object System.Drawing.Point(60, 8)
$searchBox.Width = 300
$searchBox.Height = 24

$topPanel.Controls.Add($searchLabel)
$topPanel.Controls.Add($searchBox)

# Create split container for tree and script details
$splitContainer = New-Object System.Windows.Forms.SplitContainer
$splitContainer.Dock = [System.Windows.Forms.DockStyle]::Fill
$splitContainer.SplitterDistance = 300
$splitContainer.Orientation = [System.Windows.Forms.Orientation]::Vertical

# Left panel - Tree view
$treeView = New-Object System.Windows.Forms.TreeView
$treeView.Dock = [System.Windows.Forms.DockStyle]::Fill
$treeView.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$treeView.ImageList = New-Object System.Windows.Forms.ImageList
$treeView.FullRowSelect = $false

# Right panel - Script details and output
$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = [System.Windows.Forms.DockStyle]::Fill

# Script details panel (top of right)
$detailsPanel = New-Object System.Windows.Forms.Panel
$detailsPanel.Dock = [System.Windows.Forms.DockStyle]::Top
$detailsPanel.Height = 120
$detailsPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$detailsPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$scriptNameLabel = New-Object System.Windows.Forms.Label
$scriptNameLabel.Text = "No script selected"
$scriptNameLabel.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
$scriptNameLabel.AutoSize = $true
$scriptNameLabel.Location = New-Object System.Drawing.Point(10, 10)

$scriptPathLabel = New-Object System.Windows.Forms.Label
$scriptPathLabel.Text = ""
$scriptPathLabel.AutoSize = $false
$scriptPathLabel.Width = 400
$scriptPathLabel.Height = 50
$scriptPathLabel.Location = New-Object System.Drawing.Point(10, 35)
$scriptPathLabel.ForeColor = [System.Drawing.Color]::Gray

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$buttonPanel.Height = 40
$buttonPanel.Padding = New-Object System.Windows.Forms.Padding(10, 5, 10, 5)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "&Run Script"
$runButton.Width = 100
$runButton.Location = New-Object System.Drawing.Point(10, 8)
$runButton.Enabled = $false

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = "&Refresh"
$refreshButton.Width = 80
$refreshButton.Location = New-Object System.Drawing.Point(120, 8)

$buttonPanel.Controls.Add($runButton)
$buttonPanel.Controls.Add($refreshButton)

$detailsPanel.Controls.Add($scriptNameLabel)
$detailsPanel.Controls.Add($scriptPathLabel)
$detailsPanel.Controls.Add($buttonPanel)

# Output panel (bottom of right)
$outputPanel = New-Object System.Windows.Forms.Panel
$outputPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$outputPanel.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$outputPanel.Padding = New-Object System.Windows.Forms.Padding(10)

$outputLabel = New-Object System.Windows.Forms.Label
$outputLabel.Text = "Output"
$outputLabel.AutoSize = $true
$outputLabel.Location = New-Object System.Drawing.Point(10, 10)
$outputLabel.Font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Bold)

$outputBox = New-Object System.Windows.Forms.RichTextBox
$outputBox.Dock = [System.Windows.Forms.DockStyle]::Fill
$outputBox.ReadOnly = $false
$outputBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$outputBox.ForeColor = [System.Drawing.Color]::White
$outputBox.BackColor = [System.Drawing.Color]::Black
$outputBox.Margin = New-Object System.Windows.Forms.Padding(0, 20, 0, 0)
$outputBox.Text = "Select a script and click 'Run Script' to execute it."

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear"
$clearButton.Width = 70
$clearButton.Location = New-Object System.Drawing.Point(10, 10)

$outputPanel.Controls.Add($clearButton)
$outputPanel.Controls.Add($outputBox)

$rightPanel.Controls.Add($detailsPanel)
$rightPanel.Controls.Add($outputPanel)

$splitContainer.Panel1.Controls.Add($treeView)
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
    
    if ($metadata.categories) {
        foreach ($category in ($metadata.categories | Get-Member -MemberType NoteProperty | Sort-Object Name)) {
            $catName = $category.Name
            $catNode = New-Object System.Windows.Forms.TreeNode
            $catNode.Text = $catName
            $catNode.Tag = @{ type = "category" }
            
            $scripts = $metadata.categories.$catName
            if ($scripts -is [object[]]) {
                foreach ($script in $scripts) {
                    $scriptNode = New-Object System.Windows.Forms.TreeNode
                    $scriptNode.Text = $script.name
                    $scriptNode.Tag = @{ 
                        type = "script"
                        name = $script.name
                        path = $script.path
                        requiresAdmin = $script.requiresAdmin
                        hasParameters = $script.hasParameters
                    }
                    $catNode.Nodes.Add($scriptNode) | Out-Null
                }
            }
            else {
                $scriptNode = New-Object System.Windows.Forms.TreeNode
                $scriptNode.Text = $scripts.name
                $scriptNode.Tag = @{ 
                    type = "script"
                    name = $scripts.name
                    path = $scripts.path
                    requiresAdmin = $scripts.requiresAdmin
                    hasParameters = $scripts.hasParameters
                }
                $catNode.Nodes.Add($scriptNode) | Out-Null
            }
            
            $treeView.Nodes.Add($catNode) | Out-Null
        }
    }
    else {
        $rootNode = New-Object System.Windows.Forms.TreeNode
        $rootNode.Text = "No scripts found - check metadata file"
        $treeView.Nodes.Add($rootNode) | Out-Null
    }
}

# Handle tree selection
$treeView.Add_AfterSelect({
    $node = $_.Node
    if ($node.Tag.type -eq "script") {
        $selectedScript = $node.Tag
        
        $scriptNameLabel.Text = $node.Tag.name
        $details = "Path: $($node.Tag.path)"
        if ($node.Tag.requiresAdmin) { $details += "`nRequires: Administrator" }
        if ($node.Tag.hasParameters) { $details += "`nNote: This script accepts parameters" }
        $scriptPathLabel.Text = $details
        
        $runButton.Enabled = $true
    }
    else {
        $selectedScript = $null
        $scriptNameLabel.Text = "No script selected"
        $scriptPathLabel.Text = ""
        $runButton.Enabled = $false
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
            $outputBox.AppendText("`n" + ("="*70) + "`r`n")
            
            try {
                # Capture output
                $output = & $fullPath 2>&1
                foreach ($line in $output) {
                    $outputBox.AppendText("$line`r`n")
                }
                $outputBox.AppendText("`r`n" + ("="*70) + "`r`n")
                $outputBox.AppendText("[✓] Script completed successfully")
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
    PopulateTree
})

# Search functionality
$searchBox.Add_TextChanged({
    $query = $searchBox.Text.ToLower()
    $treeView.Nodes.Clear()
    
    if ([string]::IsNullOrWhiteSpace($query)) {
        PopulateTree
    }
    else {
        foreach ($category in ($metadata.categories | Get-Member -MemberType NoteProperty | Sort-Object Name)) {
            $catName = $category.Name
            $catNode = New-Object System.Windows.Forms.TreeNode
            $catNode.Text = $catName
            
            $scripts = $metadata.categories.$catName
            $added = $false
            
            if ($scripts -is [object[]]) {
                foreach ($script in $scripts) {
                    if ($script.name.ToLower().Contains($query) -or $catName.ToLower().Contains($query)) {
                        $scriptNode = New-Object System.Windows.Forms.TreeNode
                        $scriptNode.Text = $script.name
                        $scriptNode.Tag = @{ 
                            type = "script"
                            name = $script.name
                            path = $script.path
                            requiresAdmin = $script.requiresAdmin
                            hasParameters = $script.hasParameters
                        }
                        $catNode.Nodes.Add($scriptNode) | Out-Null
                        $added = $true
                    }
                }
            }
            else {
                if ($scripts.name.ToLower().Contains($query) -or $catName.ToLower().Contains($query)) {
                    $scriptNode = New-Object System.Windows.Forms.TreeNode
                    $scriptNode.Text = $scripts.name
                    $scriptNode.Tag = @{ 
                        type = "script"
                        name = $scripts.name
                        path = $scripts.path
                        requiresAdmin = $scripts.requiresAdmin
                        hasParameters = $scripts.hasParameters
                    }
                    $catNode.Nodes.Add($scriptNode) | Out-Null
                    $added = $true
                }
            }
            
            if ($added) {
                $treeView.Nodes.Add($catNode) | Out-Null
            }
        }
    }
})

# Initial population
PopulateTree

# Show form
$form.ShowDialog() | Out-Null
