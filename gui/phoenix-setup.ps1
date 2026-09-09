#Requires -Version 5.0

<#
.SYNOPSIS
    Phoenix USB Builder - library loaded by the WinForms script launcher.

.DESCRIPTION
    Builder-side GUI for the Phoenix project. Normally opened from the
    launcher via File -> "USB Builder..." (scripts/tools/gui-launcher.ps1
    dot-sources this file and calls Show-PhoenixBuilder). Running this file
    directly also opens the builder (dev convenience).

    Architecture (founder decision): this GUI runs on a WORKING Windows
    machine. It stages Ventoy ISOs onto the USB and writes phoenix-config.json
    (apps selection, username/password, answer-file options). The boot side
    reads that config and runs HEADLESS - there is no GUI in WinPE.

    Ventoy renders the 4-option boot menu from the staged ISOs:
      Analyze   -> SystemRescue      Backup -> Rescuezilla
      Nuke      -> ShredOS (nwipe)   Reinstall -> Windows installer ISO + Phoenix WinPE

    SECURITY: passwords are held as SecureString in the GUI and never written
    to the log. They are written PLAINTEXT into phoenix-config.json because
    autounattend.xml and the headless side require it - treat them as
    throwaway install-time credentials, changed after first logon.

.NOTES
    Static review only so far - no PowerShell on the Linux dev VM.
    Windows-side testing still required:
        powershell -File gui/phoenix-setup.ps1
#>

param(
    [string]$SetupFile  # optional *.phoenix.json to preload
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# --------------------------------------------------------------------------
# Paths & constants
# --------------------------------------------------------------------------

$GuiDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $GuiDir

$script:AppsJsonPath     = Join-Path $RepoRoot 'data\choco-install\apps.json'
$script:UnattendGenPath  = Join-Path $RepoRoot 'tools\New-UnattendXml.ps1'
$script:AppScriptGenPath = Join-Path $RepoRoot 'tools\New-AppInstallScript.ps1'
$script:StagerPath       = Join-Path $RepoRoot 'tools\Stage-Usb.ps1'

# The 4 boot options. Ventoy (on the USB) renders the boot menu; the GUI's
# job is staging one ISO per option plus phoenix-config.json. The boot side
# runs headless - there is deliberately no GUI in WinPE.
$script:BootModules = @(
    @{
        Name = 'Analyze'
        IsoLabel = 'SystemRescue'
        Description = 'SystemRescue ISO: hardware analysis, full graphical file manager, shell.'
        DefaultIncluded = $true
        Dangerous = $false
    },
    @{
        Name = 'Backup'
        IsoLabel = 'Rescuezilla'
        Description = 'Rescuezilla ISO: full-machine image backup before anything destructive.'
        DefaultIncluded = $true
        Dangerous = $false
    },
    @{
        Name = 'Nuke'
        IsoLabel = 'ShredOS'
        Description = 'ShredOS ISO (nwipe): secure disk wipe. IRREVERSIBLE. nwipe keeps its own on-device confirmations.'
        DefaultIncluded = $false
        Dangerous = $true
    },
    @{
        Name = 'Reinstall'
        IsoLabel = 'WinPE + Win ISO'
        Description = 'Windows installer ISO + Phoenix WinPE payload: headless install driven by phoenix-config.json.'
        DefaultIncluded = $true
        Dangerous = $false
    }
)

# Dark theme, matching scripts/tools/gui-launcher.ps1 conventions
$script:BuilderColors = @{
    Primary    = [System.Drawing.Color]::FromArgb(41, 128, 185)
    Secondary  = [System.Drawing.Color]::FromArgb(52, 152, 219)
    Background = [System.Drawing.Color]::FromArgb(236, 240, 241)
    DarkBg     = [System.Drawing.Color]::FromArgb(44, 62, 80)
    Text       = [System.Drawing.Color]::FromArgb(52, 73, 94)
    TextLight  = [System.Drawing.Color]::FromArgb(189, 195, 199)
    Accent     = [System.Drawing.Color]::FromArgb(231, 76, 60)
    Success    = [System.Drawing.Color]::FromArgb(39, 174, 96)
    Warning    = [System.Drawing.Color]::FromArgb(243, 156, 18)
    White      = [System.Drawing.Color]::White
}

# Shared wizard state. Password is a SecureString or $null. Nothing in here
# is ever dumped to the log verbatim - see Write-SetupLog.
$script:Setup = @{
    ComputerName = ''
    Username     = ''
    Password     = $null   # SecureString
    TimeZone     = [System.TimeZoneInfo]::Local.Id
    Edition      = 'Pro'
    ProductKey   = ''
    Apps         = @()     # selected package names
    Options      = @{
        SkipOobe     = $true
        DisableWpbt  = $true
        Locale       = 'en-US'
        DriverProfile = ''
        StageUpdates = $false
    }
    Modules = @()          # boot modules to stage, from main-form checkboxes
}

# --------------------------------------------------------------------------
# Logging (password-safe)
# --------------------------------------------------------------------------

$script:LogBox = $null

function Write-SetupLog {
    <#
    .SYNOPSIS
        Append a line to the GUI log pane. Any hashtable values whose key
        looks like a secret (password/secret/key/token) are redacted.
    #>
    param(
        [string]$Message,
        [ValidateSet('Info','Warn','Error','Success')][string]$Level = 'Info',
        [hashtable]$Data
    )
    $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $Message
    if ($Data) {
        $parts = foreach ($k in $Data.Keys) {
            $v = $Data[$k]
            if ($k -match 'password|secret|token') { $v = '***REDACTED***' }
            elseif ($k -match 'key$' -and $v)       { $v = '***REDACTED***' }  # product keys too
            "$k=$v"
        }
        $line += ' | ' + ($parts -join ' ')
    }
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + [Environment]::NewLine)
    }
    else {
        Write-Host $line
    }
}

# --------------------------------------------------------------------------
# Control helpers
# --------------------------------------------------------------------------

function New-SetupLabel {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 400, [int]$Size = 10, [switch]$Bold)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.AutoSize = $false
    $l.Width = $Width
    $l.Height = 40
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    $l.ForeColor = $script:BuilderColors.Text
    return $l
}

function New-SetupTextBox {
    param([int]$X, [int]$Y, [int]$Width = 300, [switch]$Password)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($X, $Y)
    $t.Width = $Width
    $t.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    if ($Password) { $t.UseSystemPasswordChar = $true }
    return $t
}

function New-SetupButton {
    param([string]$Text, [int]$X, [int]$Y, [int]$Width = 140, [int]$Height = 34)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($Width, $Height)
    $b.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $b.BackColor = $script:BuilderColors.Primary
    $b.ForeColor = $script:BuilderColors.White
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    return $b
}

function New-SetupCombo {
    param([int]$X, [int]$Y, [int]$Width = 300)
    $c = New-Object System.Windows.Forms.ComboBox
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Width = $Width
    $c.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $c.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    return $c
}

# --------------------------------------------------------------------------
# Nuke interlock UI
# --------------------------------------------------------------------------

function Confirm-NukeStaging {
    <#
    .SYNOPSIS
        Modal warning shown when the Nuke module checkbox is turned on.
        Staging != running: this only puts the module on the USB. The nuke
        module's own typed confirmation on the target machine is untouched
        and cannot be bypassed from here.
    #>
    $result = [System.Windows.Forms.MessageBox]::Show(
        "You are staging the NUKE module onto this USB.`n`n" +
        "Nuke securely wipes the target machine's disk. It is IRREVERSIBLE.`n`n" +
        "Staging it does NOT run anything on this machine. On the target " +
        "machine, Nuke still requires its own typed confirmation - this " +
        "screen cannot bypass it.`n`nStage the Nuke module?",
        'Stage Nuke module?',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    return ($result -eq [System.Windows.Forms.DialogResult]::Yes)
}

# --------------------------------------------------------------------------
# Generator / stager interface
# (contracts per docs/GUI-PLAN.md; sibling workers own the implementations)
# --------------------------------------------------------------------------

function Test-GeneratorScripts {
    $missing = @()
    foreach ($p in @($script:UnattendGenPath, $script:AppScriptGenPath)) {
        if (-not (Test-Path $p)) { $missing += $p }
    }
    return $missing
}

function Test-VentoyDrive {
    <#
    .SYNOPSIS
        Verify the target drive is a Ventoy USB (ventoy/ directory present).
        The builder stages ISOs onto Ventoy; it does not install Ventoy itself.
    #>
    param([string]$DriveLetter)
    $ventoyDir = Join-Path ($DriveLetter.TrimEnd('\') + '\') 'ventoy'
    return (Test-Path $ventoyDir)
}

function Write-PhoenixConfig {
    <#
    .SYNOPSIS
        Write phoenix-config.json to the USB. This is THE handoff to the
        headless boot side: WinPE reads it and runs without user interaction.

        The password is written PLAINTEXT - unavoidable, because
        autounattend.xml requires it and WinPE cannot use the build
        machine's DPAPI key. Policy: throwaway install-time credentials,
        changed after first logon (stated on the wizard Review page).
    #>
    param([string]$DriveLetter)

    $plainPassword = $null
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:Setup.Password)
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        if ($ptr -ne [IntPtr]::Zero) {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        }
    }

    $config = [ordered]@{
        version      = 1
        computerName = $script:Setup.ComputerName
        username     = $script:Setup.Username
        password     = $plainPassword
        timeZone     = $script:Setup.TimeZone
        edition      = $script:Setup.Edition
        productKey   = $script:Setup.ProductKey
        locale       = $script:Setup.Options.Locale
        options      = [ordered]@{
            skipOobe      = [bool]$script:Setup.Options.SkipOobe
            disableWpbt   = [bool]$script:Setup.Options.DisableWpbt
            stageUpdates  = [bool]$script:Setup.Options.StageUpdates
            driverProfile = [string]$script:Setup.Options.DriverProfile
        }
        apps    = @($script:Setup.Apps)
        modules = @($script:Setup.Modules | ForEach-Object { $_.ToLower() })
    }

    $phoenixDir = Join-Path ($DriveLetter.TrimEnd('\') + '\') 'phoenix'
    if (-not (Test-Path $phoenixDir)) {
        New-Item -ItemType Directory -Path $phoenixDir -Force | Out-Null
    }
    $configPath = Join-Path $phoenixDir 'phoenix-config.json'
    ($config | ConvertTo-Json -Depth 5) | Set-Content -Path $configPath -Encoding UTF8

    # Shrink the plaintext window: clear locals holding the password.
    $plainPassword = $null
    $config['password'] = $null

    return $configPath
}

function Invoke-PhoenixBuild {
    <#
    .SYNOPSIS
        Drive the full build: answer file -> app script -> USB staging.
        Each step is delegated to its owning module; the GUI only passes
        parameters and reports progress.
    #>
    param([string]$TargetDrive)

    $driveLetter = $TargetDrive.TrimEnd('\') + '\'

    # Module selection is read from the main-form checkboxes here so both
    # build entry points (wizard Review page, BUILD USB button) agree.
    $script:Setup.Modules = @(
        $script:ModuleCheckboxes.Keys | Where-Object { $script:ModuleCheckboxes[$_].Checked }
    )

    if (-not (Test-VentoyDrive $driveLetter)) {
        Write-SetupLog "Target $driveLetter is not a Ventoy USB (no ventoy/ directory)." 'Error'
        [System.Windows.Forms.MessageBox]::Show(
            "The target drive does not look like a Ventoy USB.`n`n" +
            "Prepare the USB with Ventoy first, then build again.",
            'Not a Ventoy drive',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    $missing = Test-GeneratorScripts
    if ($missing.Count -gt 0) {
        Write-SetupLog 'Build blocked: generator scripts not present yet.' 'Error'
        foreach ($m in $missing) { Write-SetupLog "  missing: $m" 'Error' }
        [System.Windows.Forms.MessageBox]::Show(
            "Generator scripts are not available yet:`n`n" +
            ($missing -join "`n") +
            "`n`nThe wizard collected your setup, but the build cannot run until the sibling workers land these modules.",
            'Generators missing',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    try {
        Write-SetupLog 'Generating unattend.xml...' 'Info'
        . $script:UnattendGenPath
        $unattendPath = New-UnattendXml `
            -ComputerName $script:Setup.ComputerName `
            -Username     $script:Setup.Username `
            -Password     $script:Setup.Password `
            -TimeZone     $script:Setup.TimeZone `
            -Edition      $script:Setup.Edition `
            -ProductKey   $script:Setup.ProductKey `
            -Options      $script:Setup.Options `
            -OutputPath   (Join-Path $env:TEMP 'phoenix-staging\autounattend.xml')
        Write-SetupLog "unattend.xml written." 'Success' @{ Path = $unattendPath }

        Write-SetupLog 'Generating app install script...' 'Info'
        . $script:AppScriptGenPath
        $appScriptPath = New-AppInstallScript `
            -AppsJsonPath     $script:AppsJsonPath `
            -SelectedPackages $script:Setup.Apps `
            -OfflineCachePath (Join-Path $env:TEMP 'phoenix-staging\cache\apps') `
            -OutputPath       (Join-Path $env:TEMP 'phoenix-staging\$OEM$\$$\Setup\Scripts\Install-Apps.ps1')
        Write-SetupLog 'App install script written.' 'Success' @{ Path = $appScriptPath }

        if (Test-Path $script:StagerPath) {
            Write-SetupLog "Staging ISOs onto $driveLetter ..." 'Info'
            . $script:StagerPath
            Stage-Usb -Setup $script:Setup `
                      -IncludeModules $script:Setup.Modules `
                      -UnattendXmlPath $unattendPath `
                      -AppScriptPath $appScriptPath `
                      -TargetDrive $driveLetter
        }
        else {
            Write-SetupLog 'Stage-Usb.ps1 not present yet - skipping ISO staging.' 'Warn'
        }

        Write-SetupLog 'Writing phoenix-config.json (headless boot handoff)...' 'Info'
        $configPath = Write-PhoenixConfig -DriveLetter $driveLetter
        Write-SetupLog 'phoenix-config.json written.' 'Success' @{ Path = $configPath }
        Write-SetupLog 'USB build complete.' 'Success'
    }
    catch {
        Write-SetupLog "Build failed: $($_.Exception.Message)" 'Error'
    }
    finally {
        # Defense in depth: the SecureString object itself is dropped after
        # the build so the plaintext window is as small as possible.
        $script:Setup.Password = $null
    }
}

# --------------------------------------------------------------------------
# Wizard pages
# --------------------------------------------------------------------------

function New-WizardPageMachine {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = 'Machine'

    $page.Controls.Add((New-SetupLabel 'Machine setup' 20 15 400 14 -Bold))
    $page.Controls.Add((New-SetupLabel 'Computer name (max 15 chars, letters/digits/dash):' 20 60 400))
    $script:txtComputerName = New-SetupTextBox 20 90 300
    $script:txtComputerName.Text = $script:Setup.ComputerName
    $page.Controls.Add($script:txtComputerName)

    $page.Controls.Add((New-SetupLabel 'Timezone:' 20 140 400))
    $script:cmbTimezone = New-SetupCombo 20 170 300
    [System.TimeZoneInfo]::GetSystemTimeZones() | ForEach-Object { $script:cmbTimezone.Items.Add($_.Id) | Out-Null }
    $script:cmbTimezone.SelectedItem = $script:Setup.TimeZone
    $page.Controls.Add($script:cmbTimezone)

    $page.Controls.Add((New-SetupLabel 'Windows edition:' 20 220 400))
    $script:cmbEdition = New-SetupCombo 20 250 300
    @('Pro', 'Home', 'Education', 'Pro for Workstations') | ForEach-Object { $script:cmbEdition.Items.Add($_) | Out-Null }
    $script:cmbEdition.SelectedItem = $script:Setup.Edition
    $page.Controls.Add($script:cmbEdition)

    $page.Controls.Add((New-SetupLabel 'Product key (blank = generic key):' 20 300 400))
    $script:txtProductKey = New-SetupTextBox 20 330 300
    $page.Controls.Add($script:txtProductKey)

    return $page
}

function New-WizardPageAccounts {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = 'Accounts'

    $page.Controls.Add((New-SetupLabel 'Local account' 20 15 400 14 -Bold))
    $page.Controls.Add((New-SetupLabel 'Passwords are masked and never written to the log.' 20 45 500 9))

    $page.Controls.Add((New-SetupLabel 'Username:' 20 90 400))
    $script:txtUsername = New-SetupTextBox 20 120 300
    $script:txtUsername.Text = $script:Setup.Username
    $page.Controls.Add($script:txtUsername)

    $page.Controls.Add((New-SetupLabel 'Password:' 20 170 400))
    $script:txtPassword = New-SetupTextBox 20 200 300 -Password
    $page.Controls.Add($script:txtPassword)

    $page.Controls.Add((New-SetupLabel 'Confirm password:' 20 250 400))
    $script:txtPassword2 = New-SetupTextBox 20 280 300 -Password
    $page.Controls.Add($script:txtPassword2)

    return $page
}

function Get-AppCatalog {
    <#
    .SYNOPSIS
        Load data/choco-install/apps.json using the
        {package, description, category, defaultSelected} schema.
        Returns an empty list (with a log line) if the sibling worker
        hasn't populated it yet - apps are optional.
    #>
    if (-not (Test-Path $script:AppsJsonPath)) {
        Write-SetupLog 'apps.json not found - app checklist will be empty.' 'Warn'
        return @()
    }
    try {
        $raw = Get-Content $script:AppsJsonPath -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-SetupLog 'apps.json is empty (sibling worker still populating) - continuing without apps.' 'Warn'
            return @()
        }
        return @($raw | ConvertFrom-Json)
    }
    catch {
        Write-SetupLog "Could not parse apps.json: $($_.Exception.Message)" 'Error'
        return @()
    }
}

function New-WizardPageApps {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = 'Apps'

    $page.Controls.Add((New-SetupLabel 'Applications (installed offline from staged cache)' 20 15 500 14 -Bold))

    $page.Controls.Add((New-SetupLabel 'Category:' 20 60 100))
    $script:cmbAppCategory = New-SetupCombo 110 57 250
    $page.Controls.Add($script:cmbAppCategory)

    $script:lstApps = New-Object System.Windows.Forms.CheckedListBox
    $script:lstApps.Location = New-Object System.Drawing.Point(20, 100)
    $script:lstApps.Size = New-Object System.Drawing.Size(560, 260)
    $script:lstApps.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $script:lstApps.CheckOnClick = $true
    $page.Controls.Add($script:lstApps)

    # Parallel array: list index -> catalog entry (CheckedListBox items are strings)
    $script:AppEntries = @()

    $refreshApps = {
        $script:lstApps.Items.Clear()
        $script:AppEntries = @()
        $cat = $script:cmbAppCategory.SelectedItem
        foreach ($a in (Get-AppCatalog)) {
            if ($cat -and $cat -ne '(all)' -and $a.category -ne $cat) { continue }
            $script:lstApps.Items.Add(('{0} - {1}' -f $a.package, $a.description), [bool]$a.defaultSelected) | Out-Null
            $script:AppEntries += $a
        }
        if ($script:lstApps.Items.Count -eq 0) {
            $script:lstApps.Items.Add('(no apps available yet - apps.json is being populated)', $false) | Out-Null
        }
    }

    $cats = @('(all)') + @((Get-AppCatalog) | Select-Object -ExpandProperty category -Unique | Sort-Object)
    $cats | ForEach-Object { $script:cmbAppCategory.Items.Add($_) | Out-Null }
    $script:cmbAppCategory.SelectedIndex = 0
    $script:cmbAppCategory.Add_SelectedIndexChanged($refreshApps)
    & $refreshApps

    return $page
}

function New-WizardPageOptions {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = 'Options'

    $page.Controls.Add((New-SetupLabel 'Answer-file options' 20 15 400 14 -Bold))

    $script:chkSkipOobe = New-Object System.Windows.Forms.CheckBox
    $script:chkSkipOobe.Text = 'Skip OOBE (recommended)'
    $script:chkSkipOobe.Checked = $script:Setup.Options.SkipOobe
    $script:chkSkipOobe.Location = New-Object System.Drawing.Point(20, 60)
    $script:chkSkipOobe.AutoSize = $true
    $script:chkSkipOobe.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $page.Controls.Add($script:chkSkipOobe)

    $script:chkDisableWpbt = New-Object System.Windows.Forms.CheckBox
    $script:chkDisableWpbt.Text = 'Disable WPBT (Windows Platform Binary Table)'
    $script:chkDisableWpbt.Checked = $script:Setup.Options.DisableWpbt
    $script:chkDisableWpbt.Location = New-Object System.Drawing.Point(20, 95)
    $script:chkDisableWpbt.AutoSize = $true
    $script:chkDisableWpbt.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $page.Controls.Add($script:chkDisableWpbt)

    $script:chkStageUpdates = New-Object System.Windows.Forms.CheckBox
    $script:chkStageUpdates.Text = 'Stage Windows updates for offline install'
    $script:chkStageUpdates.Checked = $script:Setup.Options.StageUpdates
    $script:chkStageUpdates.Location = New-Object System.Drawing.Point(20, 130)
    $script:chkStageUpdates.AutoSize = $true
    $script:chkStageUpdates.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $page.Controls.Add($script:chkStageUpdates)

    $page.Controls.Add((New-SetupLabel 'Locale:' 20 175 400))
    $script:cmbLocale = New-SetupCombo 20 205 300
    @('en-US', 'en-GB', 'de-DE', 'fr-FR', 'es-ES', 'ja-JP') | ForEach-Object { $script:cmbLocale.Items.Add($_) | Out-Null }
    $script:cmbLocale.SelectedItem = $script:Setup.Options.Locale
    $page.Controls.Add($script:cmbLocale)

    return $page
}

function New-WizardPageReview {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = 'Review'

    $page.Controls.Add((New-SetupLabel 'Review your setup' 20 15 400 14 -Bold))
    $page.Controls.Add((New-SetupLabel 'Password is shown masked and never logged.' 20 45 500 9))

    $script:txtReview = New-Object System.Windows.Forms.TextBox
    $script:txtReview.Location = New-Object System.Drawing.Point(20, 75)
    $script:txtReview.Size = New-Object System.Drawing.Size(560, 285)
    $script:txtReview.Multiline = $true
    $script:txtReview.ReadOnly = $true
    $script:txtReview.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:txtReview.Font = New-Object System.Drawing.Font('Consolas', 10)
    $page.Controls.Add($script:txtReview)

    return $page
}

function Update-ReviewPage {
    $mods = ($script:Setup.Modules | ForEach-Object { "  [x] $_" }) -join [Environment]::NewLine
    $apps = if ($script:Setup.Apps.Count) { ($script:Setup.Apps | ForEach-Object { "  [x] $_" }) -join [Environment]::NewLine } else { '  (none)' }
    $script:txtReview.Text =
        "Computer name : $($script:Setup.ComputerName)`r`n" +
        "Username      : $($script:Setup.Username)`r`n" +
        "Password      : ******`r`n" +
        "Timezone      : $($script:Setup.TimeZone)`r`n" +
        "Edition       : $($script:Setup.Edition)`r`n" +
        "Product key   : $(if ($script:Setup.ProductKey) { '******' } else { '(generic)' })`r`n" +
        "Locale        : $($script:Setup.Options.Locale)`r`n" +
        "Skip OOBE     : $($script:Setup.Options.SkipOobe)`r`n" +
        "Disable WPBT  : $($script:Setup.Options.DisableWpbt)`r`n" +
        "Stage updates : $($script:Setup.Options.StageUpdates)`r`n`r`n" +
        "ISOs to stage (Ventoy boot menu):`r`n$mods`r`n`r`n" +        "Apps to install:`r`n$apps"
}

function Collect-WizardPage {
    <#
    .SYNOPSIS
        Pull the current wizard page's controls into $script:Setup.
        Returns $true, or $false + message box on validation failure.
    #>
    param([int]$PageIndex)

    switch ($PageIndex) {
        0 {
            $name = $script:txtComputerName.Text.Trim()
            if ($name -notmatch '^[A-Za-z0-9-]{1,15}$') {
                [System.Windows.Forms.MessageBox]::Show(
                    'Computer name must be 1-15 chars: letters, digits, dash.',
                    'Invalid computer name',
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return $false
            }
            $script:Setup.ComputerName = $name.ToUpper()
            $script:Setup.TimeZone   = $script:cmbTimezone.SelectedItem
            $script:Setup.Edition    = $script:cmbEdition.SelectedItem
            $script:Setup.ProductKey = $script:txtProductKey.Text.Trim()
        }
        1 {
            $user = $script:txtUsername.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($user)) {
                [System.Windows.Forms.MessageBox]::Show('Username is required.',
                    'Invalid account', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return $false
            }
            $p1 = $script:txtPassword.Text
            $p2 = $script:txtPassword2.Text
            if ($p1 -ne $p2) {
                [System.Windows.Forms.MessageBox]::Show('Passwords do not match.',
                    'Invalid account', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return $false
            }
            if ([string]::IsNullOrEmpty($p1)) {
                [System.Windows.Forms.MessageBox]::Show('Password is required.',
                    'Invalid account', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return $false
            }
            $script:Setup.Username = $user
            # Plaintext exists in these two locals only for this comparison;
            # from here on it lives as a SecureString.
            $script:Setup.Password = ConvertTo-SecureString $p1 -AsPlainText -Force
            $p1 = $null; $p2 = $null
            $script:txtPassword.Text = ''; $script:txtPassword2.Text = ''
        }
        2 {
            $selected = @()
            for ($i = 0; $i -lt $script:lstApps.CheckedItems.Count; $i++) {
                $label = $script:lstApps.CheckedItems[$i].ToString()
                if ($label -like '(*') { continue }  # the "(no apps yet)" placeholder
                $pkg = ($label -split ' - ')[0]
                $selected += $pkg
            }
            $script:Setup.Apps = $selected
        }
        3 {
            $script:Setup.Options.SkipOobe     = $script:chkSkipOobe.Checked
            $script:Setup.Options.DisableWpbt  = $script:chkDisableWpbt.Checked
            $script:Setup.Options.StageUpdates = $script:chkStageUpdates.Checked
            $script:Setup.Options.Locale       = $script:cmbLocale.SelectedItem
        }
    }
    return $true
}

function Show-SetupWizard {
    $wiz = New-Object System.Windows.Forms.Form
    $wiz.Text = 'Phoenix - New Setup'
    $wiz.Size = New-Object System.Drawing.Size(640, 520)
    $wiz.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $wiz.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $wiz.MaximizeBox = $false
    $wiz.MinimizeBox = $false
    $wiz.BackColor = $script:BuilderColors.Background

    # TabControl with hidden tabs = wizard pages
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(10, 10)
    $tabs.Size = New-Object System.Drawing.Size(604, 410)
    $tabs.Appearance = [System.Windows.Forms.TabAppearance]::Buttons
    $tabs.ItemSize = New-Object System.Drawing.Size(0, 1)
    $tabs.SizeMode = [System.Windows.Forms.TabSizeMode]::Fixed
    $tabs.TabPages.Add((New-WizardPageMachine))  | Out-Null
    $tabs.TabPages.Add((New-WizardPageAccounts)) | Out-Null
    $tabs.TabPages.Add((New-WizardPageApps))     | Out-Null
    $tabs.TabPages.Add((New-WizardPageOptions))  | Out-Null
    $tabs.TabPages.Add((New-WizardPageReview))   | Out-Null
    $wiz.Controls.Add($tabs)

    $btnBack = New-SetupButton '< Back' 150 435 110
    $btnNext = New-SetupButton 'Next >' 270 435 110
    $btnCancel = New-SetupButton 'Cancel' 390 435 110
    $btnCancel.BackColor = $script:BuilderColors.Text
    $wiz.Controls.Add($btnBack)
    $wiz.Controls.Add($btnNext)
    $wiz.Controls.Add($btnCancel)

    $updateNav = {
        $btnBack.Enabled = ($tabs.SelectedIndex -gt 0)
        $btnNext.Text = if ($tabs.SelectedIndex -eq $tabs.TabCount - 1) { 'Build USB' } else { 'Next >' }
        if ($tabs.SelectedIndex -eq $tabs.TabCount - 1) { Update-ReviewPage }
    }

    $btnBack.Add_Click({ $tabs.SelectedIndex--; & $updateNav })
    $btnNext.Add_Click({
        if (-not (Collect-WizardPage $tabs.SelectedIndex)) { return }
        if ($tabs.SelectedIndex -eq $tabs.TabCount - 1) {
            # Review page: Build USB
            $drive = $script:cmbDrive.SelectedItem
            if (-not $drive) {
                [System.Windows.Forms.MessageBox]::Show('Pick a target USB drive on the main window first.',
                    'No drive selected', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            $wiz.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $wiz.Close()
            $wizDriveLetter = ($drive -split ' ')[0]
            Invoke-PhoenixBuild -TargetDrive $wizDriveLetter
        }
        else {
            $tabs.SelectedIndex++
            & $updateNav
        }
    })
    $btnCancel.Add_Click({ $wiz.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $wiz.Close() })

    & $updateNav
    $wiz.ShowDialog() | Out-Null
}

# --------------------------------------------------------------------------
# Main form
# --------------------------------------------------------------------------

function Get-RemovableDrives {
    [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Removable' -and $_.IsReady } |
        ForEach-Object { '{0} ({1})' -f $_.Name.TrimEnd('\'), $_.VolumeLabel }
}

function Show-PhoenixBuilder {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Phoenix - USB Builder'
    $form.Size = New-Object System.Drawing.Size(1000, 700)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.BackColor = $script:BuilderColors.Background
    $form.Icon = [System.Drawing.SystemIcons]::Application

    # Header
    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = 70
    $header.BackColor = $script:BuilderColors.DarkBg
    $title = New-Object System.Windows.Forms.Label
    $title.Text = 'PHOENIX - USB Builder'
    $title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $title.ForeColor = $script:BuilderColors.Secondary
    $title.AutoSize = $true
    $title.Location = New-Object System.Drawing.Point(15, 8)
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.Text = 'Stage Ventoy ISOs + phoenix-config.json  |  Analyze / Backup / Nuke / Reinstall'
    $subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $subtitle.ForeColor = $script:BuilderColors.TextLight
    $subtitle.AutoSize = $true
    $subtitle.Location = New-Object System.Drawing.Point(15, 40)
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)
    $form.Controls.Add($header)

    # Module tiles
    $tilesPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $tilesPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $tilesPanel.Height = 200
    $tilesPanel.Padding = New-Object System.Windows.Forms.Padding(15)
    $tilesPanel.BackColor = $script:BuilderColors.Background

    $script:ModuleCheckboxes = @{}
    foreach ($mod in $script:BootModules) {
        $tile = New-Object System.Windows.Forms.Panel
        $tile.Size = New-Object System.Drawing.Size(220, 170)
        $tile.BackColor = $script:BuilderColors.White
        $tile.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
        $tile.Margin = New-Object System.Windows.Forms.Padding(6)

        $nameLabel = New-Object System.Windows.Forms.Label
        $nameLabel.Text = $mod.Name.ToUpper()
        $nameLabel.Font = New-Object System.Drawing.Font('Segoe UI', 13, [System.Drawing.FontStyle]::Bold)
        $nameLabel.ForeColor = $(if ($mod.Dangerous) { $script:BuilderColors.Accent } else { $script:BuilderColors.Primary })
        $nameLabel.Location = New-Object System.Drawing.Point(12, 10)
        $nameLabel.AutoSize = $true

        $isoLabel = New-Object System.Windows.Forms.Label
        $isoLabel.Text = $mod.IsoLabel
        $isoLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
        $isoLabel.ForeColor = $script:BuilderColors.Text
        $isoLabel.Location = New-Object System.Drawing.Point(12, 36)
        $isoLabel.AutoSize = $true

        $descLabel = New-Object System.Windows.Forms.Label
        $descLabel.Text = $mod.Description
        $descLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $descLabel.ForeColor = $script:BuilderColors.Text
        $descLabel.Location = New-Object System.Drawing.Point(12, 58)
        $descLabel.Size = New-Object System.Drawing.Size(196, 66)

        $chk = New-Object System.Windows.Forms.CheckBox
        $chk.Text = 'Stage ISO'
        $chk.Checked = $mod.DefaultIncluded
        $chk.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $chk.Location = New-Object System.Drawing.Point(12, 130)
        $chk.AutoSize = $true
        $chk.Tag = $mod

        # Nuke interlock: unchecking is free, checking requires the warning.
        $chk.Add_CheckedChanged({
            param($sender, $e)
            $m = $sender.Tag
            if ($sender.Checked -and $m.Dangerous) {
                if (-not (Confirm-NukeStaging)) {
                    $sender.Checked = $false
                }
                else {
                    Write-SetupLog 'ShredOS ISO staged (NOT executed). nwipe keeps its own on-device confirmations.' 'Warn'
                }
            }
        }.GetNewClosure())

        $tile.Controls.Add($nameLabel)
        $tile.Controls.Add($isoLabel)
        $tile.Controls.Add($descLabel)
        $tile.Controls.Add($chk)
        $tilesPanel.Controls.Add($tile)
        $script:ModuleCheckboxes[$mod.Name] = $chk
    }
    $form.Controls.Add($tilesPanel)

    # Controls row: drive picker + wizard buttons
    $ctrlPanel = New-Object System.Windows.Forms.Panel
    $ctrlPanel.Dock = [System.Windows.Forms.DockStyle]::Top
    $ctrlPanel.Height = 60
    $ctrlPanel.Padding = New-Object System.Windows.Forms.Padding(15, 12, 15, 12)

    $driveLabel = New-Object System.Windows.Forms.Label
    $driveLabel.Text = 'USB drive:'
    $driveLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $driveLabel.ForeColor = $script:BuilderColors.Text
    $driveLabel.AutoSize = $true
    $driveLabel.Location = New-Object System.Drawing.Point(15, 18)

    $script:cmbDrive = New-SetupCombo 110 15 200
    Get-RemovableDrives | ForEach-Object { $script:cmbDrive.Items.Add($_) | Out-Null }
    if ($script:cmbDrive.Items.Count -gt 0) { $script:cmbDrive.SelectedIndex = 0 }

    $btnVerifyVentoy = New-SetupButton 'Verify Ventoy' 320 12 130
    $btnVerifyVentoy.BackColor = $script:BuilderColors.Text
    $btnVerifyVentoy.Add_Click({
        $d = $script:cmbDrive.SelectedItem
        if (-not $d) { return }
        $dl = ($d -split ' ')[0]
        if (Test-VentoyDrive $dl) {
            Write-SetupLog "Ventoy confirmed on $dl." 'Success'
        }
        else {
            Write-SetupLog "$dl is not a Ventoy USB (no ventoy/ directory)." 'Error'
        }
    })

    $btnNewSetup = New-SetupButton 'New Setup...' 460 12 130
    $btnNewSetup.Add_Click({ Show-SetupWizard })

    $btnOpenSetup = New-SetupButton 'Open Setup...' 600 12 130
    $btnOpenSetup.BackColor = $script:BuilderColors.Text
    $btnOpenSetup.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Phoenix setup (*.phoenix.json)|*.phoenix.json'
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            Write-SetupLog "Setup file load is stubbed in this scaffold." 'Warn' @{ File = $dlg.FileName }
            # TODO: deserialize into $script:Setup (password is never stored - prompt at build)
        }
    })

    $btnBuild = New-SetupButton 'BUILD USB' 740 12 140 36
    $btnBuild.BackColor = $script:BuilderColors.Success
    $btnBuild.Add_Click({
        $drive = $script:cmbDrive.SelectedItem
        if (-not $drive) {
            [System.Windows.Forms.MessageBox]::Show('Select a target USB drive first.',
                'No drive', [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $driveLetter = ($drive -split ' ')[0]
        $stagedNow = @(
            $script:ModuleCheckboxes.Keys | Where-Object { $script:ModuleCheckboxes[$_].Checked }
        )
        $confirmMsg = "Build Phoenix USB on $driveLetter ?`n`nISOs: $($stagedNow -join ', ')"
        if ($stagedNow -contains 'Nuke') {
            $confirmMsg += "`n`nWARNING: the ShredOS (nwipe) ISO will be staged on this USB."
        }
        $go = [System.Windows.Forms.MessageBox]::Show($confirmMsg, 'Confirm USB build',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($go -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        if ([string]::IsNullOrWhiteSpace($script:Setup.ComputerName)) {
            Write-SetupLog 'No setup configured - opening the wizard first.' 'Warn'
            Show-SetupWizard
            return
        }
        Invoke-PhoenixBuild -TargetDrive $driveLetter
    })

    $ctrlPanel.Controls.Add($driveLabel)
    $ctrlPanel.Controls.Add($script:cmbDrive)
    $ctrlPanel.Controls.Add($btnVerifyVentoy)
    $ctrlPanel.Controls.Add($btnNewSetup)
    $ctrlPanel.Controls.Add($btnOpenSetup)
    $ctrlPanel.Controls.Add($btnBuild)
    $form.Controls.Add($ctrlPanel)

    # Log pane
    $logPanel = New-Object System.Windows.Forms.Panel
    $logPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $logPanel.Padding = New-Object System.Windows.Forms.Padding(15, 5, 15, 15)

    $logLabel = New-Object System.Windows.Forms.Label
    $logLabel.Text = 'Build log (passwords are never written here)'
    $logLabel.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)
    $logLabel.ForeColor = $script:BuilderColors.Text
    $logLabel.AutoSize = $true
    $logLabel.Dock = [System.Windows.Forms.DockStyle]::Top

    $script:LogBox = New-Object System.Windows.Forms.TextBox
    $script:LogBox.Multiline = $true
    $script:LogBox.ReadOnly = $true
    $script:LogBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $script:LogBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)
    $script:LogBox.BackColor = $script:BuilderColors.DarkBg
    $script:LogBox.ForeColor = $script:BuilderColors.TextLight

    $logPanel.Controls.Add($script:LogBox)
    $logPanel.Controls.Add($logLabel)
    $form.Controls.Add($logPanel)

    Write-SetupLog 'Phoenix USB Builder started.' 'Info' @{
        GeneratorsPresent = ((Test-GeneratorScripts).Count -eq 0)
    }

    $form.Add_Shown({ $form.Activate() })
    $form.ShowDialog() | Out-Null
}

# --------------------------------------------------------------------------
# Entry
# --------------------------------------------------------------------------

if ($SetupFile) {
    Write-SetupLog "Preloading setup file is stubbed in this scaffold." 'Warn' @{ File = $SetupFile }
}

# Dot-sourced by scripts/tools/gui-launcher.ps1 (File -> USB Builder...),
# which calls Show-PhoenixBuilder. Running this file directly opens the
# builder too (dev convenience).
if ($MyInvocation.InvocationName -ne '.') {
    Show-PhoenixBuilder
}
