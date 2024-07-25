# Here's some sets of apps
# Categorized
# The Names must match a possible Default Local fileName to be used if the chocolatey link fails
# We use a Function that acts as an Object constructor, letting us access selectedByDefault, useLocal, and the Name

# Define an Application
# If Default is set to True, the dropdown list will have it selected initially.
# If Local is set to True, the app will use a Local .exe or .msi installer
# function App {
#     param (
#         [string]$Name,
#         [bool]$Default,
#         [bool]$Local
#     )
#     $app = New-Object PSObject
#     $app | Add-Member -MemberType NoteProperty -Name "Name" -Value $Name
#     $app | Add-Member -MemberType NoteProperty -Name "Default" -Value $Default
#     $app | Add-Member -MemberType NoteProperty -Name "Local" -Value $Local
#     return $app
# }
# Create a custom object with specified properties
function App {
    param (
        [string]$Name,
        [bool]$Default,
        [bool]$Local
    )
    $app = [PSCustomObject]@{
        Name = $Name
        Default = $Default
        Local = $Local
    }
    return $app
}

# All our apps, categorized. 
# The Name should match the choco repo Names, when fetching from choco it will lowercase it

# Web Browsers
$browsers = @(
    App -Name "GoogleChrome" -Default $True -Local $False,
    App -Name "Firefox" -Default $False -Local $False,
    App -Name "Brave" -Default $False -Local $False
)

# Utility Programs
$utils = @(
    App -Name "7zip" -Default $True -Local $False,
    App -Name "Bleachbit" -Default $True -Local $False,
    App -Name "Handbrake" -Default $False -Local $False,
    App -Name "Filezilla" -Default $False -Local $False,
    App -Name "QBittorrent" -Default $False -Local $False,
    App -Name "f.lux" -Default $False -Local $False
)

# Documents and Stuff
$work = @(
    App -Name "NotepadPlusPlus" -Default $False -Local $False,
    App -Name "SumatraPDF" -Default $False -Local $False,
    App -Name "LibreOffice-Fresh" -Default $False -Local $False
)

# Makin Stuff
$code = @(
    App -Name "VSCode" -Default $True -Local $False,
    App -Name "Git" -Default $False -Local $False,
    App -Name "GitHub-Desktop" -Default $False -Local $False,
    App -Name "IntelliJIdea-Community" -Default $False -Local $False,
    App -Name "AndroidStudio" -Default $False -Local $False,
    App -Name "NodeJS" -Default $False -Local $False,
    App -Name "Postman" -Default $False -Local $False,
    App -Name "Meld" -Default $False -Local $False
)

# Jaba
$java = @(
    App -Name "OpenJDK" -Default $False -Local $False,
    App -Name "jdk-7" -Default $False -Local $True,
    App -Name "jdk-8" -Default $False -Local $True,
    App -Name "jdk-11" -Default $False -Local $True,
    App -Name "jdk-12" -Default $False -Local $True,
    App -Name "jdk-17" -Default $False -Local $True,
    App -Name "jdk-21" -Default $False -Local $True,
    App -Name "jdk-22" -Default $False -Local $True
)

# Multimedia
$media = @(
    App -Name "Spotify" -Default $True -Local $False,
    App -Name "Ableton" -Default $False -Local $True,
    App -Name "Audacity" -Default $False -Local $False,
    App -Name "MuseHub" -Default $False -Local $True,
    App -Name "MuseScore" -Default $False -Local $False,
    App -Name "DaVinci-Resolve" -Default $False -Local $True,
    App -Name "GIMP" -Default $False -Local $False,
    App -Name "OBS-Studio" -Default $False -Local $False,
    App -Name "Streamlabs-OBS" -Default $False -Local $False,
    App -Name "Kodi" -Default $False -Local $False,
    App -Name "mpc-hc" -Default $False -Local $False
)

# Society
$social = @(
    App -Name "Discord" -Default $True -Local $False,
    App -Name "em-client" -Default $True -Local $False
)

# Vidya Games
$gaming = @(
    App -Name "Steam" -Default $True -Local $False,
    App -Name "PCSX2" -Default $False -Local $False,
    App -Name "DS4Windows" -Default $False -Local $False,
    App -Name "Dolphin" -Default $False -Local $False,
    App -Name "ppsspp" -Default $False -Local $False,
    App -Name "SNES9x" -Default $False -Local $False,
    App -Name "Mupen64plus" -Default $False -Local $False
)

$apps = $browsers + $utils + $work + $code + $java + $media + $social + $gaming

# Output the properties of each object in the array
foreach ($app in $apps) {
    Write-Output "Name: $($app.Name), Default: $($app.Default), Local: $($app.Local)"
}