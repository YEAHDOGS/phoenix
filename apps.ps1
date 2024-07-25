# This is to streamline installing necessary apps for all my use cases
# The Names must match a possible Default Local fileName to be used if the chocolatey link fails
# We use a Custom Object, letting us access Name (app / filename), Default (Have this selected initially), Local (Not on Chocolatey, use Local first), and Description

# Define an Application as a PSCustomObject
# If Default is set to True, the dropdown list will have it selected initially.
# If Local is set to True, the app will use a Local .exe or .msi installer
$app = [PSCustomObject]@{
    Name = "MyApp"
    Default = $false
    Local = $true
    Description = "A good App"
}

# All our apps, categorized. 
# The Name should match the choco repo Names, when fetching from choco it will lowercase it

# Utility Programs
$utils = @(
    [PSCustomObject]@{
        Name = "Nvidia-Display-Driver"
        Default = $true
        Local = $false
        Description = "Start gaming at 60fps in 4k in no time"
    },
    [PSCustomObject]@{
        Name = "7zip"
        Default = $true
        Local = $false
        Description = "zip, unzip, wow!"
    },
    [PSCustomObject]@{
        Name = "Bleachbit"
        Default = $true
        Local = $false
        Description = "When you need to erase all traces, or free up drive space"
    },
    [PSCustomObject]@{
        Name = "Handbrake"
        Default = $false
        Local = $false
        Description = "mp4 to everything else"
    },
    [PSCustomObject]@{
        Name = "QBittorrent"
        Default = $false
        Local = $false
        Description = "[insert pirate logo here]"
    },
    [PSCustomObject]@{
        Name = "f.lux"
        Default = $false
        Local = $false
        Description = "Makes your sexy computer easier on the eyes"
    },
    [PSCustomObject]@{
        Name = "Meld"
        Default = $false
        Local = $false
        Description = "Useful if you're playing Where's Waldo with folders"
    },
    [PSCustomObject]@{
        Name = "VirtualBox"
        Default = $false
        Local = $false
        Description = "When you want a machine, inside your machine!"
    },
    [PSCustomObject]@{
        Name = "cygwin"
        Default = $false
        Local = $false
        Description = "It's like a better terminal"
    }
)

# Util apps for File management
$files = @(
    [PSCustomObject]@{
        Name = "Filezilla"
        Default = $false
        Local = $false
        Description = "Drag and drop files to wherever you want"
    },
    [PSCustomObject]@{
        Name = "PuTTY"
        Default = $false
        Local = $false
        Description = "Connect to other machines"
    },
    [PSCustomObject]@{
        Name = "cURL"
        Default = $false
        Local = $false
        Description = "Get stuff"
    },
    [PSCustomObject]@{
        Name = "WinSCP"
        Default = $false
        Local = $false
        Description = "Networking"
    }
)

# Documents and Stuff
$work = @(
    [PSCustomObject]@{
        Name = "NotepadPlusPlus"
        Default = $false
        Local = $false
        Description = "The sequal to Notepad, created and adored by nerds everywhere!"
    },
    [PSCustomObject]@{
        Name = "SumatraPDF"
        Default = $false
        Local = $false
        Description = "Can you believe Adobe charges monthly now? Ew"
    },
    [PSCustomObject]@{
        Name = "LibreOffice-Fresh"
        Default = $false
        Local = $false
        Description = "Can you believe Microsoft charges monthly now? Ew"
    }
)

# Makin Stuff
$code = @(
    [PSCustomObject]@{
        Name = "VSCode"
        Default = $true
        Local = $false
        Description = "The Gen-Z Vim"
    },
    [PSCustomObject]@{
        Name = "Git"
        Default = $false
        Local = $false
        Description = "Git er done y'all"
    },
    [PSCustomObject]@{
        Name = "GitHub-Desktop"
        Default = $false
        Local = $false
        Description = "Git er done with a GUI and Microsoft cloud trackers y'all"
    },
    [PSCustomObject]@{
        Name = "IntelliJIdea-Community"
        Default = $false
        Local = $false
        Description = "It's like a Java sumo wrestler, heavy but crazy powerful"
    },
    [PSCustomObject]@{
        Name = "AndroidStudio"
        Default = $false
        Local = $false
        Description = "Now you can make your own TikTok"
    },
    [PSCustomObject]@{
        Name = "Postman"
        Default = $false
        Local = $false
        Description = "GET, POST, PUT, DELETE, wowee!"
    },
    [PSCustomObject]@{
        Name = "Docker-Desktop"
        Default = $false
        Local = $false
        Description = "Containerize the world, or die trying"
    },
    [PSCustomObject]@{
        Name = "wsl2"
        Default = $false
        Local = $false
        Description = "Windows Subsystem for Linux. Snazzy af"
    }
)

# Coding Languages
$codeLangs = @(
    [PSCustomObject]@{
        Name = "NodeJS"
        Default = $false
        Local = $false
        Description = "A web developer's favorite Dollar Tree"
    },
    [PSCustomObject]@{
        Name = "Python"
        Default = $false
        Local = $false
        Description = "The most used language on planet earth"
    },
    [PSCustomObject]@{
        Name = "GOLang"
        Default = $false
        Local = $false
        Description = "Go go go go go go go!"
    },
    [PSCustomObject]@{
        Name = "OpenJDK"
        Default = $false
        Local = $false
        Description = "It's Java, but Open!"
    },
    [PSCustomObject]@{
        Name = "jdk-7"
        Default = $false
        Local = $true
    },
    [PSCustomObject]@{
        Name = "jdk-8"
        Default = $false
        Local = $true
    },
    [PSCustomObject]@{
        Name = "jdk-11"
        Default = $false
        Local = $true
    },
    [PSCustomObject]@{
        Name = "jdk-12"
        Default = $false
        Local = $true
    },
    [PSCustomObject]@{
        Name = "jdk-17"
        Default = $false
        Local = $true
    },
    [PSCustomObject]@{
        Name = "jdk-21"
        Default = $false
        Local = $true
    },
    [PSCustomObject]@{
        Name = "jdk-22"
        Default = $false
        Local = $true
    }
)

# Multimedia
$media = @(
    [PSCustomObject]@{
        Name = "Spotify"
        Default = $true
        Local = $false
        Description = "Gotta have the tunes bro"
    },
    [PSCustomObject]@{
        Name = "Ableton"
        Default = $false
        Local = $true
        Description = "Deadmau5, Skrillex, Flume, Charli XCX, Frank Ocean, they use this so it's gotta be good"
    },
    [PSCustomObject]@{
        Name = "Audacity"
        Default = $false
        Local = $false
        Description = "Makes anything audio file related a breeze"
    },
    [PSCustomObject]@{
        Name = "MuseHub"
        Default = $false
        Local = $true
        Description = "It's the new Splice, I think"
    },
    [PSCustomObject]@{
        Name = "MuseScore"
        Default = $false
        Local = $false
        Description = "Beethoven would have loved this"
    },
    [PSCustomObject]@{
        Name = "DaVinci-Resolve"
        Default = $false
        Local = $true
        Description = "Can you believe Adobe charges monthly for Premiere? No way jose"
    },
    [PSCustomObject]@{
        Name = "GIMP"
        Default = $false
        Local = $false
        Description = "Can you believe Adobe charges monthly for Photshop? No way jose"
    },
    [PSCustomObject]@{
        Name = "Inkscape"
        Default = $false
        Local = $false
        Description = "Vectors and stuff, good for logo design"
    },
    [PSCustomObject]@{
        Name = "OBS-Studio"
        Default = $false
        Local = $false
        Description = "Record yourself, record the screen, record everything"
    },
    [PSCustomObject]@{
        Name = "Streamlabs-OBS"
        Default = $false
        Local = $false
        Description = "Record everything, and share it live!"
    },
    [PSCustomObject]@{
        Name = "Kodi"
        Default = $false
        Local = $false
        Description = "If you've got Blu-Ray discs or video files, this will take care of you"
    },
    [PSCustomObject]@{
        Name = "mpc-hc"
        Default = $false
        Local = $false
        Description = "Because the Windows player is bloated and laggy"
    },
    [PSCustomObject]@{
        Name = "VLC"
        Default = $false
        Local = $false
        Description = "Because the Windows player is bloated and laggy"
    },
    [PSCustomObject]@{
        Name = "Blender"
        Default = $false
        Local = $false
        Description = "3D file editor"
    }
)

# Society
$social = @(
    [PSCustomObject]@{
        Name = "Discord"
        Default = $true
        Local = $false
        Description = "The Gen-Z AOL Messenger"
    },
    [PSCustomObject]@{
        Name = "em-client"
        Default = $true
        Local = $false
        Description = "Because Windows Mail spies on you"
    },
    [PSCustomObject]@{
        Name = "Zoom"
        Default = $false
        Local = $false
        Description = "Still don't know how this overtook Skype so quickly"
    },
    [PSCustomObject]@{
        Name = "Slack"
        Default = $false
        Local = $false
        Description = "Say hello to all your unknown co-workers"
    },
    [PSCustomObject]@{
        Name = "Webex-Meetings"
        Default = $false
        Local = $false
        Description = "Like Zoom, which is like Skype, but this one is uh... not those ones"
    }
)

# Keep things secure
$security = @(
    [PSCustomObject]@{
        Name = "MalwareBytes"
        Default = $false
        Local = $false
        Description = "This used to be the de facto anti-virus. Now, it's still decent enough"
    },
    [PSCustomObject]@{
        Name = "Wireshark"
        Default = $false
        Local = $false
        Description = "Listen to the ticks of your router, what's it doing? Why's it sending ten thousand data packets every second?"
    }
)

# Vidya Games
$gaming = @(
    [PSCustomObject]@{
        Name = "Steam"
        Default = $true
        Local = $false
        Description = "A gamer's Wal-Mart"
    },
    [PSCustomObject]@{
        Name = "PCSX2"
        Default = $false
        Local = $false
        Description = "PlayStation 2 emulator"
    },
    [PSCustomObject]@{
        Name = "DS4Windows"
        Default = $false
        Local = $false
        Description = "Makes pairing and using DualShock4 controllers with Windows a bit easier"
    },
    [PSCustomObject]@{
        Name = "Dolphin"
        Default = $false
        Local = $false
        Description = "Wii and Gamecube emulator"
    },
    [PSCustomObject]@{
        Name = "ppsspp"
        Default = $false
        Local = $false
        Description = "PlayStation Portable emulator"
    },
    [PSCustomObject]@{
        Name = "SNES9x" 
        Default = $false
        Local = $false
        Description = "Super Nintendo Entertainment System emulator"
    },
    [PSCustomObject]@{
        Name = "Mupen64plus"
        Default = $false
        Local = $false
        Description = "Nintendo 64 emulator"
    }
)

# Web Browsers
$browsers = @(
    [PSCustomObject]@{
        Name = "GoogleChrome"
        Default = $true
        Local = $false
        Description = "Probably the most popular browser to ever browser"
    },
    [PSCustomObject]@{
        Name = "Firefox"
        Default = $false
        Local = $false
        Description = "For those fearful of big tech, yet unafraid of big corporation"
    },
    [PSCustomObject]@{
        Name = "Brave"
        Default = $false
        Local = $false
        Description = "When all else fails and the flies begin to come, it's all the same anyway"
    },
    [PSCustomObject]@{
        Name = "Tor-Browser"
        Default = $false
        Local = $false
        Description = "The true incognito mode, at the speed of snails"
    }
)

# Browser Extensions
$extensions = @(
    [PSCustomObject]@{
        Name = "ublockorigin-chrome"
        Default = $true
        Local = $false
        Description = "Get those trackers outta here"
    }
)

# $apps = $utils + $files + $work + $code + $codeLangs + $java + $media + $social + $security + $gaming + $browsers + $extensions

# # Output the properties of each object in the array
# foreach ($app in $apps) {
#     Write-Output "Name: $($app.Name), Default: $($app.Default), Local: $($app.Local), Description: $($app.Description)"
# }

function Show-Menu {
    param(
        [string[]]$Options
    )

    $selectedOption = 0

    while ($true) {
        Write-Host " " -NoNewline

        for ($i = 0; $i -lt $Options.Count; $i++) {
            Write-Host -NoNewline "`r"
            if ($i -eq $selectedOption) {
                Write-Host "=>" $Options[$i] -ForegroundColor Green
            } else {
                Write-Host "  " $Options[$i]
            }
        }

        $key = [System.Console]::ReadKey($true).KeyChar

        switch ($key) {
            'UpArrow' {
                $selectedOption = ($selectedOption - 1) % $Options.Count
                break
            }
            'DownArrow' {
                $selectedOption = ($selectedOption + 1) % $Options.Count
                break
            }
            'Enter' {
                Write-Host
                Write-Host "You selected: $($Options[$selectedOption])"
                break
            }
            default {
                # Handle other keys
            }
        }
    }
}

Write-Host "Welcome to the Installer"

$selectedOption = Read-Host "Select an option: "

$options = "Option 1", "Option 2", "Option 3"
Show-Menu -Options $options