# Here's some sets of apps
# Categorized
# The names must match a possible default local filename to be used if the chocolatey link fails
# We use a Function that acts as an Object constructor, letting us access selectedByDefault, useLocal, and the name

# Define an Application
# If default is set to true, the dropdown list will have it selected initially.
# If local is set to true, the app will use a local .exe or .msi installer
function App {
    param (
        [string]$name,
        [bool]$default,
        [bool]$local
    )
    $app = New-Object PSObject
    $app | Add-Member -MemberType NoteProperty -Name "name" -Value $name
    $app | Add-Member -MemberType NoteProperty -Name "default" -Value $default
    $app | Add-Member -MemberType NoteProperty -Name "local" -Value $local
    return $app
}

# All our apps, categorized. 
# The name should match the choco repo names, when fetching from choco it will lowercase it

# Web Browsers
$browsers = @(
    App -name "GoogleChrome" -default $true -local $false,
    App -name "Firefox" -default $false -local $false,
    App -name "Brave" -default $false -local $false
)

# Utility Programs
$utils = @(
    App -name "7zip" -default $true -local $false,
    App -name "Bleachbit" -default $true -local $false,
    App -name "Handbrake" -default $false -local $false,
    App -name "Filezilla" -default $false -local $false,
    App -name "QBittorrent" -default $false -local $false,
    App -name "f.lux" -default $false -local $false
)

# Documents and Stuff
$work = @(
    App -name "NotepadPlusPlus" -default $false -local $false,
    App -name "SumatraPDF" -default $false -local $false,
    App -name "LibreOffice-Fresh" -default $false -local $false
)

# Makin Stuff
$code = @(
    App -name "VSCode" -default $true -local $false,
    App -name "Git" -default $false -local $false,
    App -name "GitHub-Desktop" -default $false -local $false,
    App -name "IntelliJIdea-Community" -default $false -local $false,
    App -name "AndroidStudio" -default $false -local $false,
    App -name "NodeJS" -default $false -local $false,
    App -name "Postman" -default $false -local $false,
    App -name "Meld" -default $false -local $false
)

# Jaba
$java = @(
    App -name "OpenJDK" -default $false -local $false,
    App -name "jdk-7" -default $false -local $true,
    App -name "jdk-8" -default $false -local $true,
    App -name "jdk-11" -default $false -local $true,
    App -name "jdk-12" -default $false -local $true,
    App -name "jdk-17" -default $false -local $true,
    App -name "jdk-21" -default $false -local $true,
    App -name "jdk-22" -default $false -local $true
)

# Multimedia
$media = @(
    App -name "Spotify" -default $true -local $false,
    App -name "Ableton" -default $false -local $true,
    App -name "Audacity" -default $false -local $false,
    App -name "MuseHub" -default $false -local $true,
    App -name "MuseScore" -default $false -local $false,
    App -name "DaVinci-Resolve" -default $false -local $true,
    App -name "GIMP" -default $false -local $false,
    App -name "OBS-Studio" -default $false -local $false,
    App -name "Streamlabs-OBS" -default $false -local $false,
    App -name "Kodi" -default $false -local $false,
    App -name "mpc-hc" -default $false -local $false
)

# Society
$social = @(
    App -name "Discord" -default $true -local $false,
    App -name "em-client" -default $true -local $false
)

# Vidya Games
$gaming = @(
    App -name "Steam" -default $true -local $false,
    App -name "PCSX2" -default $false -local $false,
    App -name "DS4Windows" -default $false -local $false,
    App -name "Dolphin" -default $false -local $false,
    App -name "ppsspp" -default $false -local $false,
    App -name "SNES9x" -default $false -local $false,
    App -name "Mupen64plus" -default $false -local $false
)

$apps = $browsers + $utils + $work + $code + $java + $media + $social + $gaming

# Output the properties of each object in the array
foreach ($app in $apps) {
    Write-Output "name: $($app.name), default: $($app.default), local: $($app.local)"
}