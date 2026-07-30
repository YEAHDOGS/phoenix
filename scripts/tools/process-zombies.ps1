# #Requires -RunAsAdministrator
#Requires -Version 5.1

<#
.SYNOPSIS
    Process Zombies: Task Killer Arcade Game (v1.0)
.DESCRIPTION
    An interactive 2D arcade shooter built directly in PowerShell WinForms.
    Running processes on your machine are converted into zombies with health 
    scaling based on their RAM usage. Shoot them to recover RAM (score).
    
    Features:
    - Playable via two hands on keyboard (WASD to move, Arrow Keys to shoot).
    - "Safe Mode" (Emulated task killing) or "Real Kill Mode" (terminates real processes).
    - System critical process protections.
    - Thread Pool Ammo and Garbage Collection reloading system.
    - Shop upgrades (1-4 keys) to boost fire rate, damage, shields, and BSOD nukes.
    - Retro cyberpunk neon vectors, particle effects, and screen-shake feedback.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Set up global game configuration and colors
$global:Colors = @{
    Bg          = [System.Drawing.Color]::FromArgb(10, 16, 26)
    Grid        = [System.Drawing.Color]::FromArgb(24, 38, 59)
    GridActive  = [System.Drawing.Color]::FromArgb(40, 64, 98)
    Player      = [System.Drawing.Color]::Cyan
    PlayerGlow  = [System.Drawing.Color]::FromArgb(40, 0, 255, 255)
    Bullet      = [System.Drawing.Color]::FromArgb(57, 255, 20)      # Neon green
    BulletGlow  = [System.Drawing.Color]::FromArgb(60, 57, 255, 20)
    ZombieLow   = [System.Drawing.Color]::FromArgb(46, 204, 113)    # Emerald green
    ZombieMed   = [System.Drawing.Color]::FromArgb(241, 196, 15)    # Yellow
    ZombieHigh  = [System.Drawing.Color]::FromArgb(231, 76, 60)     # Red
    ZombieProtected = [System.Drawing.Color]::FromArgb(155, 89, 182) # Purple
    TextMain    = [System.Drawing.Color]::White
    TextDim     = [System.Drawing.Color]::FromArgb(149, 165, 166)
    Accent      = [System.Drawing.Color]::FromArgb(231, 76, 60)
    Success     = [System.Drawing.Color]::FromArgb(39, 174, 96)
    Shield      = [System.Drawing.Color]::FromArgb(52, 152, 219)
}

# Processes that can never be stopped in Real Kill Mode
$global:Exclusions = @(
    "explorer", "svchost", "lsass", "csrss", "winlogon", "services", 
    "smss", "wininit", "spoolsv", "pwsh", "powershell", "cmd", 
    "conhost", "taskmgr", "dwm", "system", "idle", "registry", 
    "process-zombies", "antigravity"
)

# Game State
$global:State = @{
    Screen = 'START' # 'START', 'PLAYING', 'GAMEOVER'
    RealKillMode = $false
    Wave = 0
    Points = 0 # RAM recovered in MB
    WaveInProgress = $false
    
    # Camera
    CamX = 0
    CamY = 0
    
    # Arena Size
    ArenaWidth = 1600
    ArenaHeight = 1200
    
    # Player
    PlayerX = 800
    PlayerY = 600
    PlayerSize = 24
    PlayerSpeed = 4.5
    PlayerHealth = 100
    PlayerMaxHealth = 100
    PlayerShield = $false
    
    # Weapons & Cooldowns
    BulletDamage = 10
    FireRateLevel = 1
    DamageLevel = 1
    ShieldLevel = 0
    AmmoMax = 30
    AmmoCurrent = 30
    IsReloading = $false
    ReloadDuration = 90 # in ticks (1.5 seconds)
    ReloadTimeRemaining = 0
    LastShotTick = 0
    TickCount = 0
    
    # Bullet Delay (Ticks)
    ShotCooldown = 15 # Base 250ms
    
    # Shop Costs
    CostFireRate = 500
    CostDamage = 800
    CostShield = 300
    CostNuke = 1500
    
    # Lists
    Enemies = [System.Collections.ArrayList]::new()
    Bullets = [System.Collections.ArrayList]::new()
    Particles = [System.Collections.ArrayList]::new()
    FloatingTexts = [System.Collections.ArrayList]::new()
    
    # Keys tracking
    KeysPressed = @{}
    
    # Running processes cache
    ProcessPool = @()
    
    # Wave spawner config
    WaveSpawnCount = 0
    WaveSpawnedSoFar = 0
    WaveSpawnTimer = 0
    WaveSpawnInterval = 60 # spawn every 1s
    WaveTransitionTimer = 0
    
    # Screen shake feedback
    ShakeIntensity = 0
}

# Fonts
$global:Fonts = @{
    Title      = New-Object System.Drawing.Font("Consolas", 36, [System.Drawing.FontStyle]::Bold)
    Header     = New-Object System.Drawing.Font("Consolas", 20, [System.Drawing.FontStyle]::Bold)
    SubHeader  = New-Object System.Drawing.Font("Consolas", 14, [System.Drawing.FontStyle]::Bold)
    Main       = New-Object System.Drawing.Font("Consolas", 10)
    Bold       = New-Object System.Drawing.Font("Consolas", 10, [System.Drawing.FontStyle]::Bold)
    Small      = New-Object System.Drawing.Font("Consolas", 8)
    ExtraSmall = New-Object System.Drawing.Font("Consolas", 7)
}

# Reusable brushes and pens to prevent GDI resource leaks
$global:Brushes = @{
    Bg          = New-Object System.Drawing.SolidBrush($global:Colors.Bg)
    Player      = New-Object System.Drawing.SolidBrush($global:Colors.Player)
    PlayerGlow  = New-Object System.Drawing.SolidBrush($global:Colors.PlayerGlow)
    Bullet      = New-Object System.Drawing.SolidBrush($global:Colors.Bullet)
    BulletGlow  = New-Object System.Drawing.SolidBrush($global:Colors.BulletGlow)
    TextMain    = New-Object System.Drawing.SolidBrush($global:Colors.TextMain)
    TextDim     = New-Object System.Drawing.SolidBrush($global:Colors.TextDim)
    TextRed     = New-Object System.Drawing.SolidBrush($global:Colors.Accent)
    TextGreen   = New-Object System.Drawing.SolidBrush($global:Colors.Success)
    TextYellow  = New-Object System.Drawing.SolidBrush($global:Colors.ZombieMed)
    HealthRed   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 231, 76, 60))
    HealthGreen = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(180, 46, 204, 113))
    Shield      = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(80, 52, 152, 219))
    ShopPanel   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(200, 15, 23, 37))
    NukeFlash   = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 255, 255, 255))
    GridActive  = New-Object System.Drawing.SolidBrush($global:Colors.GridActive)
}

$global:Pens = @{
    Grid         = New-Object System.Drawing.Pen($global:Colors.Grid, 1)
    GridActive   = New-Object System.Drawing.Pen($global:Colors.GridActive, 2)
    Border       = New-Object System.Drawing.Pen($global:Colors.GridActive, 3)
    PlayerBorder = New-Object System.Drawing.Pen([System.Drawing.Color]::White, 1.5)
    ShieldBorder = New-Object System.Drawing.Pen($global:Colors.Shield, 2)
    Bullet       = New-Object System.Drawing.Pen($global:Colors.Bullet, 2)
}

# --- Game Functions ---

function Get-RunningProcesses {
    try {
        # Fetch real processes. Filter out exclusions for safety and only take processes that are actually doing something or have a window.
        $procs = Get-Process | Where-Object {
            $_.Id -ne $PID -and 
            $_.ProcessName -notmatch "idle|system" -and 
            $_.WorkingSet64 -gt 2MB
        }
        
        $results = @()
        foreach ($p in $procs) {
            # Base cost scales with Working Set size (RAM)
            $ramMB = [Math]::Round($p.WorkingSet64 / 1MB, 1)
            $isProtected = $global:Exclusions -contains $p.ProcessName.ToLower()
            
            $results += @{
                Name = $p.ProcessName
                PID = $p.Id
                RAM = $ramMB
                IsProtected = $isProtected
            }
        }
        $global:State.ProcessPool = $results
    }
    catch {
        # Fallback if Get-Process fails
        $global:State.ProcessPool = @(
            @{ Name = "chrome.exe"; PID = 9999; RAM = 450.2; IsProtected = $false },
            @{ Name = "slack.exe"; PID = 8888; RAM = 310.5; IsProtected = $false },
            @{ Name = "spotify.exe"; PID = 7777; RAM = 180.1; IsProtected = $false },
            @{ Name = "explorer.exe"; PID = 1111; RAM = 120.0; IsProtected = $true },
            @{ Name = "notepad.exe"; PID = 2222; RAM = 15.4; IsProtected = $false }
        )
    }
}

function Add-FloatingText {
    param($x, $y, $text, $colorBrush)
    $textObj = @{
        X = $x
        Y = $y
        Text = $text
        Brush = $colorBrush
        Life = 40 # ticks
        Vy = -1.0 # float upwards
    }
    [void]$global:State.FloatingTexts.Add($textObj)
}

function Add-Explosion {
    param($x, $y, $color, $count = 15)
    $rand = New-Object System.Random
    for ($i = 0; $i -lt $count; $i++) {
        $angle = $rand.NextDouble() * [Math]::PI * 2
        $speed = $rand.NextDouble() * 4 + 1.5
        $particle = @{
            X = $x
            Y = $y
            Vx = [Math]::Cos($angle) * $speed
            Vy = [Math]::Sin($angle) * $speed
            Color = $color
            Life = $rand.Next(20, 45)
            MaxLife = 45
            Size = $rand.Next(3, 7)
        }
        [void]$global:State.Particles.Add($particle)
    }
}

function Spawn-Zombie {
    if ($global:State.ProcessPool.Count -eq 0) {
        Get-RunningProcesses
    }
    
    $rand = New-Object System.Random
    # Select random process from the pool
    $procIndex = $rand.Next(0, $global:State.ProcessPool.Count)
    $proc = $global:State.ProcessPool[$procIndex]
    
    # HP and size scale with RAM usage
    $ram = $proc.RAM
    $maxHP = 15 + [int]($ram / 10)
    $size = 20 + [int]($ram / 30)
    if ($size -gt 60) { $size = 60 }
    if ($size -lt 20) { $size = 20 }
    
    # Speed is inversely proportional to size/RAM (heavy zombies are slower)
    $speed = 2.8 - ($size / 40)
    if ($speed -lt 0.8) { $speed = 0.8 }
    
    # Spawn off-screen but near the arena boundaries
    # 0 = Top, 1 = Right, 2 = Bottom, 3 = Left
    $side = $rand.Next(0, 4)
    $spawnX = 0
    $spawnY = 0
    $margin = 50
    
    switch ($side) {
        0 { # Top
            $spawnX = $rand.Next(0, $global:State.ArenaWidth)
            $spawnY = -$margin
        }
        1 { # Right
            $spawnX = $global:State.ArenaWidth + $margin
            $spawnY = $rand.Next(0, $global:State.ArenaHeight)
        }
        2 { # Bottom
            $spawnX = $rand.Next(0, $global:State.ArenaWidth)
            $spawnY = $global:State.ArenaHeight + $margin
        }
        3 { # Left
            $spawnX = -$margin
            $spawnY = $rand.Next(0, $global:State.ArenaHeight)
        }
    }
    
    $zombie = @{
        X = $spawnX
        Y = $spawnY
        Size = $size
        Speed = $speed
        Health = $maxHP
        MaxHealth = $maxHP
        Name = $proc.Name
        PID = $proc.PID
        RAM = $proc.RAM
        IsProtected = $proc.IsProtected
    }
    
    [void]$global:State.Enemies.Add($zombie)
}

function Start-Wave {
    $global:State.Wave++
    $global:State.WaveInProgress = $true
    
    # Enemies per wave: 5 + (Wave * 3)
    $global:State.WaveSpawnCount = 5 + ($global:State.Wave * 3)
    $global:State.WaveSpawnedSoFar = 0
    $global:State.WaveSpawnTimer = 0
    
    # Refresh running processes at wave start to capture any newly launched apps
    Get-RunningProcesses
    
    $global:State.FloatingTexts.Clear()
    Add-FloatingText ($global:State.PlayerX) ($global:State.PlayerY - 50) "WAVE $($global:State.Wave) INITIALIZED" $global:Brushes.TextGreen
}

function Kill-ProcessInstance {
    param($enemy)
    if (-not $global:State.RealKillMode) {
        # Safe Mode
        return
    }
    
    # Exclusions validation
    $nameLower = $enemy.Name.ToLower()
    if ($enemy.IsProtected -or ($global:Exclusions -contains $nameLower)) {
        Add-FloatingText $enemy.X $enemy.Y "SYSTEM PROTECTED" $global:Brushes.TextYellow
        return
    }
    
    # Prevent self-killing
    if ($enemy.PID -eq $PID -or $enemy.PID -eq 0 -or $enemy.PID -eq 4) {
        Add-FloatingText $enemy.X $enemy.Y "ACCESS DENIED" $global:Brushes.TextRed
        return
    }
    
    try {
        # Verify process exists before killing
        $p = Get-Process -Id $enemy.PID -ErrorAction SilentlyContinue
        if ($p) {
            Stop-Process -Id $enemy.PID -Force -ErrorAction Stop
            # Signal success
            $global:State.ShakeIntensity = 12
        }
    }
    catch {
        # Permission denied or process already exited
    }
}

function Trigger-Nuke {
    if ($global:State.Points -lt $global:State.CostNuke) { return }
    $global:State.Points -= $global:State.CostNuke
    $global:State.ShakeIntensity = 25
    
    # Create flash effect by invalidating and drawing overlay
    # Kill all enemies on screen
    $enemiesCopy = $global:State.Enemies.Clone()
    foreach ($enemy in $enemiesCopy) {
        Add-Explosion $enemy.X $enemy.Y [System.Drawing.Color]::White 25
        
        # Determine reward
        $score = [Math]::Max(10, [int]($enemy.RAM / 15) * 10)
        $global:State.Points += $score
        
        Add-FloatingText $enemy.X $enemy.Y "BSOD Nuked" $global:Brushes.TextRed
        
        # Kill the real process if in Real Kill mode
        Kill-ProcessInstance -enemy $enemy
    }
    $global:State.Enemies.Clear()
    Add-FloatingText $global:State.PlayerX $global:State.PlayerY "BSOD NUKE DEPLOYED" $global:Brushes.TextRed
}

function Trigger-GC {
    if ($global:State.IsReloading -or $global:State.AmmoCurrent -eq $global:State.AmmoMax) { return }
    $global:State.IsReloading = $true
    $global:State.ReloadTimeRemaining = $global:State.ReloadDuration
    Add-FloatingText $global:State.PlayerX $global:State.PlayerY "System.GC.Collect()..." $global:Brushes.TextYellow
}

function Reset-Game {
    $global:State.Screen = 'PLAYING'
    $global:State.Wave = 0
    $global:State.Points = 0
    
    $global:State.PlayerX = 800
    $global:State.PlayerY = 600
    $global:State.PlayerHealth = 100
    $global:State.PlayerMaxHealth = 100
    $global:State.PlayerShield = $false
    
    $global:State.BulletDamage = 10
    $global:State.FireRateLevel = 1
    $global:State.DamageLevel = 1
    $global:State.ShieldLevel = 0
    $global:State.ShotCooldown = 15
    $global:State.AmmoCurrent = 30
    $global:State.IsReloading = $false
    
    $global:State.CostFireRate = 500
    $global:State.CostDamage = 800
    $global:State.CostShield = 300
    
    $global:State.Enemies.Clear()
    $global:State.Bullets.Clear()
    $global:State.Particles.Clear()
    $global:State.FloatingTexts.Clear()
    $global:State.KeysPressed.Clear()
    
    # Start Wave 1
    Start-Wave
}

# --- GUI Elements and Forms Layout ---

$form = New-Object System.Windows.Forms.Form
$form.Text = "Process Zombies - System Defense"
$form.Size = New-Object System.Drawing.Size(950, 750)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false
$form.BackColor = $global:Colors.Bg
$form.KeyPreview = $true

# Game Canvas
$canvas = New-Object System.Windows.Forms.PictureBox
$canvas.Dock = [System.Windows.Forms.DockStyle]::Fill
$canvas.BackColor = $global:Colors.Bg
$form.Controls.Add($canvas)

# Fix focus and key preview
$canvas.Focus() | Out-Null
$canvas.add_Click({ $canvas.Focus() | Out-Null })

# Enable Arrow Keys in WinForms PictureBox
$canvas.add_PreviewKeyDown({
    param($sender, $e)
    # Intercept arrows so they don't move control focus
    if ($e.KeyCode -eq "Up" -or $e.KeyCode -eq "Down" -or $e.KeyCode -eq "Left" -or $e.KeyCode -eq "Right") {
        $e.IsInputKey = $true
    }
})

# Keyboard Input Hooks
$form.add_KeyDown({
    param($sender, $e)
    $keyStr = $e.KeyCode.ToString()
    $global:State.KeysPressed[$keyStr] = $true
    
    if ($global:State.Screen -eq 'PLAYING') {
        # Shop Hotkeys
        if ($e.KeyCode -eq 'D1' -or $e.KeyCode -eq 'NumPad1') {
            # Buy Fire Rate
            if ($global:State.Points -eq $global:State.CostFireRate -or $global:State.Points -gt $global:State.CostFireRate) {
                $global:State.Points -= $global:State.CostFireRate
                $global:State.FireRateLevel++
                $global:State.ShotCooldown = [Math]::Max(4, 15 - ($global:State.FireRateLevel * 1.5))
                $global:State.CostFireRate = [int]($global:State.CostFireRate * 1.5)
                Add-FloatingText $global:State.PlayerX $global:State.PlayerY "CPU OVERCLOCKED (Speed Up!)" $global:Brushes.TextGreen
            }
        }
        elseif ($e.KeyCode -eq 'D2' -or $e.KeyCode -eq 'NumPad2') {
            # Buy Damage
            if ($global:State.Points -eq $global:State.CostDamage -or $global:State.Points -gt $global:State.CostDamage) {
                $global:State.Points -= $global:State.CostDamage
                $global:State.DamageLevel++
                $global:State.BulletDamage += 6
                $global:State.CostDamage = [int]($global:State.CostDamage * 1.5)
                Add-FloatingText $global:State.PlayerX $global:State.PlayerY "BUS WIDTH EXPANDED (Damage Up!)" $global:Brushes.TextGreen
            }
        }
        elseif ($e.KeyCode -eq 'D3' -or $e.KeyCode -eq 'NumPad3') {
            # Buy Shield
            if ($global:State.Points -eq $global:State.CostShield -or $global:State.Points -gt $global:State.CostShield) {
                if (-not $global:State.PlayerShield) {
                    $global:State.Points -= $global:State.CostShield
                    $global:State.PlayerShield = $true
                    Add-FloatingText $global:State.PlayerX $global:State.PlayerY "FIREWALL SHIELD INSTALLED" $global:Brushes.Shield
                } else {
                    Add-FloatingText $global:State.PlayerX $global:State.PlayerY "SHIELD ALREADY ACTIVE" $global:Brushes.TextDim
                }
            }
        }
        elseif ($e.KeyCode -eq 'D4' -or $e.KeyCode -eq 'NumPad4') {
            # Trigger BSOD Nuke
            if ($global:State.Points -eq $global:State.CostNuke -or $global:State.Points -gt $global:State.CostNuke) {
                Trigger-Nuke
            }
        }
        elseif ($e.KeyCode -eq 'R') {
            # Reload (Garbage Collect)
            Trigger-GC
        }
    }
})

$form.add_KeyUp({
    param($sender, $e)
    $keyStr = $e.KeyCode.ToString()
    $global:State.KeysPressed[$keyStr] = $false
})

# Start Screen Buttons (Visual rectangles click hit testing)
$startButtonRect = [System.Drawing.Rectangle]::new(350, 480, 250, 50)
$realKillCheckBox = [System.Drawing.Rectangle]::new(350, 430, 20, 20)

$canvas.add_MouseDown({
    param($sender, $e)
    if ($global:State.Screen -eq 'START') {
        # Clicked Start Game?
        if ($startButtonRect.Contains($e.Location)) {
            Reset-Game
        }
        # Clicked Real Kill Checkbox?
        if ($realKillCheckBox.Contains($e.Location)) {
            if (-not $global:State.RealKillMode) {
                # Prompt warning
                $response = [System.Windows.Forms.MessageBox]::Show(
                    "WARNING: REAL KILL MODE will actually terminate running applications on your machine when you destroy their zombies. Do not kill system-essential tasks, or your computer may lock up, crash, or lose unsaved data!`n`nProtected processes (explorer, svchost, powershell, etc.) are excluded, but you should still proceed with caution.`n`nAre you sure you want to enable Real Kill Mode?",
                    "Hazardous System Tool Mode",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($response -eq [System.Windows.Forms.DialogResult]::Yes) {
                    $global:State.RealKillMode = $true
                }
            } else {
                $global:State.RealKillMode = $false
            }
        }
    }
    elseif ($global:State.Screen -eq 'GAMEOVER') {
        # Any click restarts
        $global:State.Screen = 'START'
    }
})

# --- Draw Engine (GDI+) ---

$canvas.add_Paint({
    param($sender, $e)
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias
    
    $width = $canvas.Width
    $height = $canvas.Height
    
    if ($global:State.Screen -eq 'START') {
        # Draw Title Screen
        $g.Clear($global:Colors.Bg)
        
        # Grid Background
        for ($x = 0; $x -lt $width; $x += 60) { $g.DrawLine($global:Pens.Grid, $x, 0, $x, $height) }
        for ($y = 0; $y -lt $height; $y += 60) { $g.DrawLine($global:Pens.Grid, 0, $y, $width, $y) }
        
        # Logo with Glow
        $g.DrawString("PROCESS ZOMBIES", $global:Fonts.Title, $global:Brushes.PlayerGlow, 203, 103)
        $g.DrawString("PROCESS ZOMBIES", $global:Fonts.Title, $global:Brushes.Player, 200, 100)
        
        $g.DrawString("Task Killer Arcade Game", $global:Fonts.SubHeader, $global:Brushes.TextDim, 335, 170)
        
        # Instructions Panel
        $instrY = 220
        $g.FillRectangle($global:Brushes.ShopPanel, 150, $instrY, 650, 190)
        $g.DrawRectangle($global:Pens.GridActive, 150, $instrY, 650, 190)
        
        $g.DrawString("SYSTEM DIAGNOSTICS & CONTROL MANUAL", $global:Fonts.Bold, $global:Brushes.TextMain, 170, $instrY + 15)
        $g.DrawString("- Left Hand : W-A-S-D to MOVE the CPU Core.", $global:Fonts.Main, $global:Brushes.TextDim, 170, $instrY + 45)
        $g.DrawString("- Right Hand: ARROW KEYS to AIM & SHOOT in 4 directions.", $global:Fonts.Main, $global:Brushes.TextDim, 170, $instrY + 70)
        $g.DrawString("- Keyboard R: Force Garbage Collection (Reload Bullet Threads).", $global:Fonts.Main, $global:Brushes.TextDim, 170, $instrY + 95)
        $g.DrawString("- Keys 1-4  : Buy hardware upgrades or trigger a BSOD Nuke.", $global:Fonts.Main, $global:Brushes.TextDim, 170, $instrY + 120)
        $g.DrawString("- Objectives: Kill bloated process zombies before they consume system stability.", $global:Fonts.Main, $global:Brushes.TextDim, 170, $instrY + 145)
        
        # Mode Select Toggle
        $checkBrush = $(if ($global:State.RealKillMode) { $global:Brushes.TextRed } else { $global:Brushes.Bg })
        $g.FillRectangle($checkBrush, $realKillCheckBox)
        $g.DrawRectangle($global:Pens.PlayerBorder, $realKillCheckBox)
        
        $modeTextBrush = $(if ($global:State.RealKillMode) { $global:Brushes.TextRed } else { $global:Brushes.TextDim })
        $g.DrawString("Enable REAL KILL MODE (⚠️ Terminate actual Windows processes when shot)", $global:Fonts.Bold, $modeTextBrush, 380, 431)
        
        # Start Button
        $btnBrush = $(if ($startButtonRect.Contains($canvas.PointToClient([System.Windows.Forms.Cursor]::Position))) { $global:Brushes.GridActive } else { $global:Brushes.Bg })
        $g.FillRectangle($btnBrush, $startButtonRect)
        $g.DrawRectangle($global:Pens.Border, $startButtonRect)
        
        $g.DrawString("INITIALIZE SYSTEM", $global:Fonts.SubHeader, $global:Brushes.TextMain, 395, 492)
        
        # Footer
        $g.DrawString("Phoenix Security Automation Initiative - Windows 11", $global:Fonts.Small, $global:Brushes.TextDim, 290, 650)
    }
    elseif ($global:State.Screen -eq 'PLAYING') {
        # Camera Shake logic offset
        $shakeX = 0
        $shakeY = 0
        if ($global:State.ShakeIntensity -gt 0) {
            $rand = New-Object System.Random
            $shakeX = $rand.Next(-$global:State.ShakeIntensity, $global:State.ShakeIntensity)
            $shakeY = $rand.Next(-$global:State.ShakeIntensity, $global:State.ShakeIntensity)
        }
        
        # Render Game Field
        $g.Clear($global:Colors.Bg)
        
        # Viewport offsets
        $ox = -$global:State.CamX + $shakeX
        $oy = -$global:State.CamY + $shakeY
        
        # Render scrolling neon grid
        $gridSpacing = 60
        $startX = [int]($global:State.CamX / $gridSpacing) * $gridSpacing
        $startY = [int]($global:State.CamY / $gridSpacing) * $gridSpacing
        
        # Clamped to Arena
        $gridPen = $global:Pens.Grid
        
        for ($gx = 0; $gx -le $global:State.ArenaWidth; $gx += $gridSpacing) {
            if ($gx -eq 0 -or $gx -eq $global:State.ArenaWidth) {
                $g.DrawLine($global:Pens.Border, $gx + $ox, $oy, $gx + $ox, $global:State.ArenaHeight + $oy)
            } else {
                $g.DrawLine($gridPen, $gx + $ox, $oy, $gx + $ox, $global:State.ArenaHeight + $oy)
            }
        }
        for ($gy = 0; $gy -le $global:State.ArenaHeight; $gy += $gridSpacing) {
            if ($gy -eq 0 -or $gy -eq $global:State.ArenaHeight) {
                $g.DrawLine($global:Pens.Border, $ox, $gy + $oy, $global:State.ArenaWidth + $ox, $gy + $oy)
            } else {
                $g.DrawLine($gridPen, $ox, $gy + $oy, $global:State.ArenaWidth + $ox, $gy + $oy)
            }
        }
        
        # --- DRAW BULLETS ---
        $bulletsCopy = $global:State.Bullets.Clone()
        foreach ($b in $bulletsCopy) {
            # Bullet Glow Trail
            $g.DrawLine($global:Pens.Bullet, $b.X + $ox, $b.Y + $oy, $b.X - $b.Vx*1.4 + $ox, $b.Y - $b.Vy*1.4 + $oy)
            $g.FillEllipse($global:Brushes.BulletGlow, $b.X - 5 + $ox, $b.Y - 5 + $oy, 10, 10)
        }
        
        # --- DRAW PARTICLES ---
        $particlesCopy = $global:State.Particles.Clone()
        foreach ($p in $particlesCopy) {
            # Fade alpha based on remaining life
            $alpha = [int](255 * ($p.Life / $p.MaxLife))
            if ($alpha -lt 0) { $alpha = 0 }
            if ($alpha -gt 255) { $alpha = 255 }
            
            $pColor = [System.Drawing.Color]::FromArgb($alpha, $p.Color.R, $p.Color.G, $p.Color.B)
            $pBrush = New-Object System.Drawing.SolidBrush($pColor)
            $g.FillRectangle($pBrush, $p.X - $p.Size/2 + $ox, $p.Y - $p.Size/2 + $oy, $p.Size, $p.Size)
            $pBrush.Dispose()
        }
        
        # --- DRAW ENEMIES (ZOMBIE PROCESSES) ---
        $enemiesCopy = $global:State.Enemies.Clone()
        foreach ($enemy in $enemiesCopy) {
            $eX = $enemy.X + $ox
            $eY = $enemy.Y + $oy
            $size = $enemy.Size
            
            # Select color based on RAM size
            $enemyBrush = if ($enemy.IsProtected) { 
                New-Object System.Drawing.SolidBrush($global:Colors.ZombieProtected)
            } elseif ($enemy.RAM -lt 50) { 
                New-Object System.Drawing.SolidBrush($global:Colors.ZombieLow)
            } elseif ($enemy.RAM -lt 250) {
                New-Object System.Drawing.SolidBrush($global:Colors.ZombieMed)
            } else {
                New-Object System.Drawing.SolidBrush($global:Colors.ZombieHigh)
            }
            
            # Draw Core Shape
            $g.FillRectangle($enemyBrush, $eX - $size/2, $eY - $size/2, $size, $size)
            $g.DrawRectangle($global:Pens.PlayerBorder, $eX - $size/2, $eY - $size/2, $size, $size)
            
            # Health Bar background
            $barY = $eY - $size/2 - 10
            $g.FillRectangle($global:Brushes.HealthRed, $eX - $size/2, $barY, $size, 4)
            # Health Bar progress
            $healthPct = $enemy.Health / $enemy.MaxHealth
            if ($healthPct -gt 0) {
                $g.FillRectangle($global:Brushes.HealthGreen, $eX - $size/2, $barY, [int]($size * $healthPct), 4)
            }
            
            # Draw text tags
            $g.DrawString($enemy.Name, $global:Fonts.Small, $global:Brushes.TextMain, $eX - $size/2, $eY + $size/2 + 2)
            
            $ramStr = if ($enemy.RAM -ge 1024) { "$([Math]::Round($enemy.RAM/1024, 1)) GB" } else { "$([int]$enemy.RAM) MB" }
            $g.DrawString("PID:$($enemy.PID) ($ramStr)", $global:Fonts.ExtraSmall, $global:Brushes.TextDim, $eX - $size/2, $eY + $size/2 + 13)
            
            $enemyBrush.Dispose()
        }
        
        # --- DRAW PLAYER ---
        $pX = $global:State.PlayerX + $ox
        $pY = $global:State.PlayerY + $oy
        $pSize = $global:State.PlayerSize
        
        # Glow
        $g.FillEllipse($global:Brushes.PlayerGlow, $pX - $pSize, $pY - $pSize, $pSize*2, $pSize*2)
        
        # Base CPU Core
        $g.FillEllipse($global:Brushes.Player, $pX - $pSize/2, $pY - $pSize/2, $pSize, $pSize)
        $g.DrawEllipse($global:Pens.PlayerBorder, $pX - $pSize/2, $pY - $pSize/2, $pSize, $pSize)
        
        # Active Shield Overlay
        if ($global:State.PlayerShield) {
            $g.FillEllipse($global:Brushes.Shield, $pX - $pSize/2 - 5, $pY - $pSize/2 - 5, $pSize + 10, $pSize + 10)
            $g.DrawEllipse($global:Pens.ShieldBorder, $pX - $pSize/2 - 5, $pY - $pSize/2 - 5, $pSize + 10, $pSize + 10)
        }
        
        # Draw Reloading indicator
        if ($global:State.IsReloading) {
            $reloadPct = ($global:State.ReloadDuration - $global:State.ReloadTimeRemaining) / $global:State.ReloadDuration
            $g.DrawString("System.GC.Collect()...", $global:Fonts.Bold, $global:Brushes.TextYellow, $pX - 60, $pY - $pSize/2 - 25)
            # Loading Bar
            $g.FillRectangle($global:Brushes.HealthRed, $pX - 40, $pY - $pSize/2 - 10, 80, 5)
            $g.FillRectangle($global:Brushes.HealthGreen, $pX - 40, $pY - $pSize/2 - 10, [int](80 * $reloadPct), 5)
        }
        
        # --- DRAW FLOATING TEXT ---
        $textsCopy = $global:State.FloatingTexts.Clone()
        foreach ($t in $textsCopy) {
            $g.DrawString($t.Text, $global:Fonts.Bold, $t.Brush, $t.X + $ox, $t.Y + $oy)
        }
        
        # --- DRAW HUD & OVERLAYS ---
        # Stability (Health) HUD
        $g.DrawString("STABILITY:", $global:Fonts.Bold, $global:Brushes.TextMain, 20, 20)
        $g.FillRectangle($global:Brushes.HealthRed, 120, 20, 150, 16)
        $healthWidth = [int](150 * ($global:State.PlayerHealth / $global:State.PlayerMaxHealth))
        if ($healthWidth -gt 0) {
            $g.FillRectangle($global:Brushes.HealthGreen, 120, 20, $healthWidth, 16)
        }
        $g.DrawRectangle($global:Pens.PlayerBorder, 120, 20, 150, 16)
        $g.DrawString("$($global:State.PlayerHealth) %", $global:Fonts.Small, $global:Brushes.TextMain, 175, 22)
        
        # Score/RAM HUD
        $g.DrawString("RECLAIMED RAM:", $global:Fonts.Bold, $global:Brushes.TextMain, 290, 20)
        $scoreStr = if ($global:State.Points -ge 1024) { "$([Math]::Round($global:State.Points/1024, 2)) GB" } else { "$($global:State.Points) MB" }
        $g.DrawString($scoreStr, $global:Fonts.SubHeader, $global:Brushes.TextGreen, 420, 17)
        
        # Wave Counter
        $g.DrawString("ROUND: $($global:State.Wave)", $global:Fonts.Header, $global:Brushes.TextMain, 780, 15)
        
        # Threat Mode/Real Kill Blinker
        if ($global:State.RealKillMode) {
            # Flash warning text using tick timer module
            if (([int]($global:State.TickCount / 15) % 2) -eq 0) {
                $g.DrawString("⚠️ REAL KILL ACTIVE ⚠️", $global:Fonts.SubHeader, $global:Brushes.TextRed, 20, 50)
            }
        } else {
            $g.DrawString("EMULATION MODE (Safe)", $global:Fonts.SubHeader, $global:Brushes.TextGreen, 20, 50)
        }
        
        # Thread Pool (Ammo) Indicator
        $ammoStr = "THREADS: " + ("I" * $global:State.AmmoCurrent) + ("." * ($global:State.AmmoMax - $global:State.AmmoCurrent))
        $g.DrawString($ammoStr, $global:Fonts.Bold, (if ($global:State.AmmoCurrent -lt 10) { $global:Brushes.TextRed } else { $global:Brushes.Bullet }), 20, 80)
        
        # --- DRAW UPGRADE SHOP PANEL ---
        $shopX = 540
        $shopY = 570
        $g.FillRectangle($global:Brushes.ShopPanel, $shopX, $shopY, 380, 130)
        $g.DrawRectangle($global:Pens.Border, $shopX, $shopY, 380, 130)
        
        $g.DrawString("HARDWARE UPGRADES SHOP (HOTKEYS 1-4)", $global:Fonts.Bold, $global:Brushes.TextMain, $shopX + 15, $shopY + 8)
        
        $color1 = if ($global:State.Points -ge $global:State.CostFireRate) { $global:Brushes.TextGreen } else { $global:Brushes.TextDim }
        $g.DrawString("1. Overclock CPU (Fire Rate Lvl $($global:State.FireRateLevel)) : $($global:State.CostFireRate) MB", $global:Fonts.Small, $color1, $shopX + 15, $shopY + 32)
        
        $color2 = if ($global:State.Points -ge $global:State.CostDamage) { $global:Brushes.TextGreen } else { $global:Brushes.TextDim }
        $g.DrawString("2. Expand Bus Width (Dmg Lvl $($global:State.DamageLevel))   : $($global:State.CostDamage) MB", $global:Fonts.Small, $color2, $shopX + 15, $shopY + 54)
        
        $color3 = if ($global:State.Points -ge $global:State.CostShield -and -not $global:State.PlayerShield) { $global:Brushes.Shield } else { $global:Brushes.TextDim }
        $shieldText = if ($global:State.PlayerShield) { "ACTIVE" } else { "$($global:State.CostShield) MB" }
        $g.DrawString("3. Install Firewall Shield               : $shieldText", $global:Fonts.Small, $color3, $shopX + 15, $shopY + 76)
        
        $color4 = if ($global:State.Points -ge $global:State.CostNuke) { $global:Brushes.TextRed } else { $global:Brushes.TextDim }
        $g.DrawString("4. Trigger BSOD Nuke (Purge Wave)       : $($global:State.CostNuke) MB", $global:Fonts.Small, $color4, $shopX + 15, $shopY + 98)
        
        # System resource status simulation
        $g.DrawString("SYSTEM LOAD: CPU: $([Math]::Min(99, [int]($global:State.Enemies.Count * 3 + 12)))% | RAM: $((16 - [Math]::Round($global:State.Points / 5000, 1))) GB Free", $global:Fonts.Small, $global:Brushes.TextDim, 20, 680)
    }
    elseif ($global:State.Screen -eq 'GAMEOVER') {
        $g.Clear([System.Drawing.Color]::FromArgb(40, 10, 10))
        
        # Grid lines in blood red
        $errPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(80, 231, 76, 60), 1)
        for ($x = 0; $x -lt $width; $x += 60) { $g.DrawLine($errPen, $x, 0, $x, $height) }
        for ($y = 0; $y -lt $height; $y += 60) { $g.DrawLine($errPen, 0, $y, $width, $y) }
        $errPen.Dispose()
        
        $g.DrawString("SYSTEM CRASHED", $global:Fonts.Title, $global:Brushes.TextRed, 250, 150)
        $g.DrawString("A critical memory leak or process overflow compromised system core stability.", $global:Fonts.Main, $global:Brushes.TextMain, 200, 240)
        
        $scoreStr = if ($global:State.Points -ge 1024) { "$([Math]::Round($global:State.Points/1024, 2)) GB" } else { "$($global:State.Points) MB" }
        
        $g.DrawString("TOTAL RECLAIMED MEMORY: $scoreStr", $global:Fonts.Header, $global:Brushes.TextGreen, 230, 320)
        $g.DrawString("ROUNDS SURVIVED: $($global:State.Wave)", $global:Fonts.SubHeader, $global:Brushes.TextMain, 370, 370)
        
        $g.DrawString("Click anywhere on the screen to return to BIOS startup", $global:Fonts.Bold, $global:Brushes.TextDim, 245, 520)
    }
})

# --- Game Engine Update Loop ---

$gameTimer = New-Object System.Windows.Forms.Timer
$gameTimer.Interval = 16 # ~60 FPS update loop
$gameTimer.add_Tick({
    $global:State.TickCount++
    
    if ($global:State.Screen -eq 'PLAYING') {
        # 1. Update Camera (Smooth follow lerp target)
        $targetCamX = $global:State.PlayerX - ($canvas.Width / 2)
        $targetCamY = $global:State.PlayerY - ($canvas.Height / 2)
        
        # Clamp camera to arena bounds
        $maxCamX = $global:State.ArenaWidth - $canvas.Width
        $maxCamY = $global:State.ArenaHeight - $canvas.Height
        
        $targetCamX = [Math]::Max(0, [Math]::Min($maxCamX, $targetCamX))
        $targetCamY = [Math]::Max(0, [Math]::Min($maxCamY, $targetCamY))
        
        $global:State.CamX += ($targetCamX - $global:State.CamX) * 0.1
        $global:State.CamY += ($targetCamY - $global:State.CamY) * 0.1
        
        # Decelerate shake
        if ($global:State.ShakeIntensity -gt 0) {
            $global:State.ShakeIntensity--
        }
        
        # 2. Player Input Handling (Movement)
        $dx = 0
        $dy = 0
        if ($global:State.KeysPressed['W']) { $dy -= 1 }
        if ($global:State.KeysPressed['S']) { $dy += 1 }
        if ($global:State.KeysPressed['A']) { $dx -= 1 }
        if ($global:State.KeysPressed['D']) { $dx += 1 }
        
        if ($dx -ne 0 -or $dy -ne 0) {
            $speed = $global:State.PlayerSpeed
            if ($global:State.IsReloading) {
                $speed *= 0.5 # Slowed during garbage collection
            }
            
            # Diagonal velocity normalization
            if ($dx -ne 0 -and $dy -ne 0) {
                $speed *= 0.7071
            }
            
            $global:State.PlayerX += $dx * $speed
            $global:State.PlayerY += $dy * $speed
            
            # Clamp player inside Arena boundary
            $halfSize = $global:State.PlayerSize / 2
            $global:State.PlayerX = [Math]::Max($halfSize, [Math]::Min($global:State.ArenaWidth - $halfSize, $global:State.PlayerX))
            $global:State.PlayerY = [Math]::Max($halfSize, [Math]::Min($global:State.ArenaHeight - $halfSize, $global:State.PlayerY))
        }
        
        # 3. Reload (Garbage Collect) Handler
        if ($global:State.IsReloading) {
            $global:State.ReloadTimeRemaining--
            if ($global:State.ReloadTimeRemaining -le 0) {
                $global:State.IsReloading = $false
                $global:State.AmmoCurrent = $global:State.AmmoMax
                Add-FloatingText $global:State.PlayerX $global:State.PlayerY "GC Complete! Thread pool cleared" $global:Brushes.TextGreen
            }
        }
        
        # 4. Shooting Handler (Arrow Keys)
        $sdx = 0
        $sdy = 0
        if ($global:State.KeysPressed['Up'])    { $sdy -= 1 }
        if ($global:State.KeysPressed['Down'])  { $sdy += 1 }
        if ($global:State.KeysPressed['Left'])  { $sdx -= 1 }
        if ($global:State.KeysPressed['Right']) { $sdx += 1 }
        
        if (($sdx -ne 0 -or $sdy -ne 0) -and -not $global:State.IsReloading) {
            $currentTick = $global:State.TickCount
            if ($currentTick - $global:State.LastShotTick -ge $global:State.ShotCooldown) {
                if ($global:State.AmmoCurrent -gt 0) {
                    $global:State.LastShotTick = $currentTick
                    $global:State.AmmoCurrent--
                    
                    # Normalize shoot vector
                    $bulletSpeed = 11
                    $factor = 1.0
                    if ($sdx -ne 0 -and $sdy -ne 0) { $factor = 0.7071 }
                    $vx = $sdx * $bulletSpeed * $factor
                    $vy = $sdy * $bulletSpeed * $factor
                    
                    $bullet = @{
                        X = $global:State.PlayerX
                        Y = $global:State.PlayerY
                        Vx = $vx
                        Vy = $vy
                    }
                    [void]$global:State.Bullets.Add($bullet)
                    $global:State.ShakeIntensity = [Math]::Max($global:State.ShakeIntensity, 2)
                    
                    # If auto-reload?
                    if ($global:State.AmmoCurrent -eq 0) {
                        Trigger-GC
                    }
                }
            }
        }
        
        # 5. Move Bullets
        $bulletsToRemove = [System.Collections.ArrayList]::new()
        foreach ($b in $global:State.Bullets) {
            $b.X += $b.Vx
            $b.Y += $b.Vy
            
            # Check arena boundaries
            if ($b.X -lt 0 -or $b.X -gt $global:State.ArenaWidth -or $b.Y -lt 0 -or $b.Y -gt $global:State.ArenaHeight) {
                [void]$bulletsToRemove.Add($b)
            }
        }
        foreach ($b in $bulletsToRemove) { [void]$global:State.Bullets.Remove($b) }
        
        # 6. Move and Update Enemies (Zombie Processes)
        $enemiesToRemove = [System.Collections.ArrayList]::new()
        foreach ($enemy in $global:State.Enemies) {
            # Walk towards player
            $pdx = $global:State.PlayerX - $enemy.X
            $pdy = $global:State.PlayerY - $enemy.Y
            $dist = [Math]::Sqrt($pdx*$pdx + $pdy*$pdy)
            
            if ($dist -gt 0.1) {
                $enemy.X += ($pdx / $dist) * $enemy.Speed
                $enemy.Y += ($pdy / $dist) * $enemy.Speed
            }
            
            # Player Collision Detection
            $colDist = $enemy.Size/2 + $global:State.PlayerSize/2
            if ($dist -lt $colDist) {
                # Collision!
                if ($global:State.PlayerShield) {
                    $global:State.PlayerShield = $false
                    # Push back enemy
                    $enemy.X -= ($pdx / $dist) * 80
                    $enemy.Y -= ($pdy / $dist) * 80
                    $global:State.ShakeIntensity = 10
                    Add-Explosion $global:State.PlayerX $global:State.PlayerY $global:Colors.Shield 8
                    Add-FloatingText $global:State.PlayerX $global:State.PlayerY "FIREWALL SHIELD BROKEN" $global:Brushes.TextRed
                } else {
                    # Deduct stability
                    $damageAmt = 5 + [int]($enemy.RAM / 150)
                    if ($damageAmt -gt 25) { $damageAmt = 25 }
                    $global:State.PlayerHealth -= $damageAmt
                    
                    # Push back enemy
                    $enemy.X -= ($pdx / $dist) * 60
                    $enemy.Y -= ($pdy / $dist) * 60
                    $global:State.ShakeIntensity = 15
                    
                    Add-Explosion $global:State.PlayerX $global:State.PlayerY [System.Drawing.Color]::Red 12
                    Add-FloatingText $global:State.PlayerX $global:State.PlayerY "-$($damageAmt)% STABILITY" $global:Brushes.TextRed
                    
                    if ($global:State.PlayerHealth -le 0) {
                        $global:State.PlayerHealth = 0
                        $global:State.Screen = 'GAMEOVER'
                        $global:State.ShakeIntensity = 30
                    }
                }
            }
            
            # Bullet Collisions
            $bulletsCopy = $global:State.Bullets.Clone()
            foreach ($b in $bulletsCopy) {
                $bdx = $b.X - $enemy.X
                $bdy = $b.Y - $enemy.Y
                $bDist = [Math]::Sqrt($bdx*$bdx + $bdy*$bdy)
                
                if ($bDist -lt ($enemy.Size/2 + 4)) {
                    # Hit!
                    $enemy.Health -= $global:State.BulletDamage
                    # Remove bullet
                    [void]$global:State.Bullets.Remove($b)
                    
                    # Spawn small splash particles
                    $enemyColor = if ($enemy.IsProtected) { $global:Colors.ZombieProtected } else { $global:Colors.Bullet }
                    Add-Explosion $b.X $b.Y $enemyColor 4
                    
                    # Floating damage text
                    Add-FloatingText $enemy.X $enemy.Y "$($global:State.BulletDamage)" $global:Brushes.TextMain
                    
                    if ($enemy.Health -le 0) {
                        [void]$enemiesToRemove.Add($enemy)
                        
                        # Blow up zombie
                        Add-Explosion $enemy.X $enemy.Y $enemyColor 16
                        
                        # Reclaim RAM (Points)
                        $reclaimed = 10 + [int]($enemy.RAM / 15) * 10
                        $global:State.Points += $reclaimed
                        Add-FloatingText $enemy.X $enemy.Y "+$($reclaimed) MB RAM" $global:Brushes.TextGreen
                        
                        # Stop actual application in Real Kill Mode
                        Kill-ProcessInstance -enemy $enemy
                        break
                    }
                }
            }
        }
        
        # Clean up dead enemies
        foreach ($enemy in $enemiesToRemove) {
            [void]$global:State.Enemies.Remove($enemy)
        }
        
        # 7. Update Particles
        $particlesToRemove = [System.Collections.ArrayList]::new()
        foreach ($p in $global:State.Particles) {
            $p.X += $p.Vx
            $p.Y += $p.Vy
            $p.Life--
            if ($p.Life -le 0) {
                [void]$particlesToRemove.Add($p)
            }
        }
        foreach ($p in $particlesToRemove) { [void]$global:State.Particles.Remove($p) }
        
        # 8. Update Floating Texts
        $textsToRemove = [System.Collections.ArrayList]::new()
        foreach ($t in $global:State.FloatingTexts) {
            $t.Y += $t.Vy
            $t.Life--
            if ($t.Life -le 0) {
                [void]$textsToRemove.Add($t)
            }
        }
        foreach ($t in $textsToRemove) { [void]$global:State.FloatingTexts.Remove($t) }
        
        # 9. Spawner / Wave Progression Logic
        if ($global:State.WaveInProgress) {
            if ($global:State.WaveSpawnedSoFar -lt $global:State.WaveSpawnCount) {
                $global:State.WaveSpawnTimer++
                if ($global:State.WaveSpawnTimer -ge $global:State.WaveSpawnInterval) {
                    $global:State.WaveSpawnTimer = 0
                    Spawn-Zombie
                    $global:State.WaveSpawnedSoFar++
                }
            }
            elseif ($global:State.Enemies.Count -eq 0) {
                # All wave enemies killed! Show wave complete and wait
                $global:State.WaveInProgress = $false
                $global:State.WaveTransitionTimer = 180 # 3 seconds transition
                Add-FloatingText $global:State.PlayerX $global:State.PlayerY "WAVE SURVIVED - RAM OPTIMIZED" $global:Brushes.TextGreen
            }
        } else {
            # Transition to next wave
            $global:State.WaveTransitionTimer--
            if ($global:State.WaveTransitionTimer -le 0) {
                Start-Wave
            }
        }
    }
    
    # Redraw Form Canvas
    $canvas.Invalidate()
})

$form.add_Load({
    $gameTimer.Start()
})

$form.add_FormClosing({
    $gameTimer.Stop()
    
    # Dispose Brushes
    foreach ($b in $global:Brushes.Values) { $b.Dispose() }
    # Dispose Pens
    foreach ($p in $global:Pens.Values) { $p.Dispose() }
    # Dispose Fonts
    foreach ($f in $global:Fonts.Values) { $f.Dispose() }
})

# Show the GUI Form
$form.ShowDialog() | Out-Null
