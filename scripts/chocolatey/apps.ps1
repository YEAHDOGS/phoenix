$__app = [PSCustomObject]@{
    Package = "MyApp"
    Description = "A good App"
    Arguments = 
@"
    --install-arguments='SOME_ENV_VAR=1 SOME_OTHER_ENV_VAR=0'
"@
}

# All our apps, categorized. 
# The Package should match the Chocolatey repo Package name, when fetching from choco it will lowercase it

# Drivers and Firmware
$AppsDrivers = @(
    [PSCustomObject]@{
        Package = "Nvidia-App"
        Description = "Start gaming at 60fps in 4k in no time"
    },
    [PSCustomObject]@{
        Package = "Nvidia-Display-Driver"
        Description = "Like putting glasses on your monitor"
    }
)

# Utility Programs
$AppsUtilities = @(
    [PSCustomObject]@{
        Package = "7zip"
        Description = "zip, unzip, wow!"
    },
    [PSCustomObject]@{
        Package = "Bleachbit"
        Description = "When you need to erase all traces, or free up drive space"
    },
    [PSCustomObject]@{
        Package = "Handbrake"
        Description = "mp4 to everything else"
    },
    [PSCustomObject]@{
        Package = "QBittorrent"
        Description = "[insert pirate logo here]"
    },
    [PSCustomObject]@{
        Package = "f.lux"
        Description = "Makes your sexy computer easier on the eyes"
    },
    [PSCustomObject]@{
        Package = "Meld"
        Description = "Useful if you're playing Where's Waldo with folders"
    },
    [PSCustomObject]@{
        Package = "VirtualBox"
        Description = "When you want a machine, inside your machine!"
    },
    [PSCustomObject]@{
        Package = "QEMU"
        Description = "Like VirtualBox but sexier"
    },
    [PSCustomObject]@{
        Package = "PowerShell-Core"
        Description = "We live in a world where even the damn terminal gets updates now. And what are they even adding? It's a bit faster tho"
        Arguments = 
@"
        --install-arguments='"DISABLE_TELEMETRY=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1"'
"@
    },
)

# Util apps for File management
$AppsFiles = @(
    [PSCustomObject]@{
        Package = "Filezilla"
        Description = "Drag and drop files to wherever you want"
    },
    [PSCustomObject]@{
        Package = "PuTTY"
        Description = "Connect to other machines"
    },
    [PSCustomObject]@{
        Package = "cURL"
        Description = "Get stuff"
    },
    [PSCustomObject]@{
        Package = "WinSCP"
        Description = "Networking"
    }
)

# Documents and Stuff
$AppsWork = @(
    [PSCustomObject]@{
        Package = "NotepadPlusPlus"
        Description = "The sequal to Notepad, created and adored by nerds everywhere!"
    },
    [PSCustomObject]@{
        Package = "SumatraPDF"
        Description = "Can you believe Adobe charges monthly now? Ew"
    },
    [PSCustomObject]@{
        Package = "LibreOffice-Fresh"
        Description = "Can you believe Microsoft charges monthly now? Ew"
    }
)

# Makin Stuff
$AppsCode = @(
    [PSCustomObject]@{
        Package = "VSCode"
        Description = "The Gen-Z Vim"
    },
    [PSCustomObject]@{
        Package = "Git"
        Description = "Git er done y'all"
    },
    [PSCustomObject]@{
        Package = "GitHub-Desktop"
        Description = "Git er done with a GUI and Microsoft cloud trackers y'all"
    },
    [PSCustomObject]@{
        Package = "IntelliJIdea-Community"
        Description = "It's like a Java sumo wrestler, heavy but powerful"
    },
    [PSCustomObject]@{
        Package = "AndroidStudio"
        Description = "Now you can make your own TikTok"
    },
    [PSCustomObject]@{
        Package = "Postman"
        Description = "GET, POST, PUT, DELETE, wowee!"
    },
    [PSCustomObject]@{
        Package = "Docker-Desktop"
        Description = "Containerize the world, or die trying"
    },
    [PSCustomObject]@{
        Package = "wsl2"
        Description = "Windows Subsystem for Linux. Snazzy af"
    }
)

# Coding SDKs
$AppsSDKs = @(
    [PSCustomObject]@{
        Package = "NodeJS"
        Description = "A web developer's favorite Dollar Tree"
    },
    [PSCustomObject]@{
        Package = "Python"
        Description = "The most used language on planet earth"
    },
    [PSCustomObject]@{
        Package = "GOLang"
        Description = "Go go go go go go go!"
    },
    [PSCustomObject]@{
        Package = "OpenJDK"
        Description = "It's Java, but Open!"
    },
    [PSCustomObject]@{
        Package = "jdk-7"
        Description = "Java before Oracle shoved their dick in it"
    },
    [PSCustomObject]@{
        Package = "jdk-8"
        Description = "Java Development Kit 8"
    },
    [PSCustomObject]@{
        Package = "jdk-11"
        Description = "Java Development Kit 11"
    },
    [PSCustomObject]@{
        Package = "jdk-12"
        Description = "Java Development Kit 12"
    },
    [PSCustomObject]@{
        Package = "jdk-17"
        Description = "Java Development Kit 17"
    },
    [PSCustomObject]@{
        Package = "jdk-21"
        Description = "Java Development Kit 21"

    },
    [PSCustomObject]@{
        Package = "jdk-22"
        Description = "Java Development Kit 22"
    }
)

# Multimedia
$AppsMedia = @(
    [PSCustomObject]@{
        Package = "Spotify"
        Description = "Gotta have the tunes bro"
    },
    [PSCustomObject]@{
        Package = "Audacity"
        Description = "Makes anything audio file related a breeze"
    },
    [PSCustomObject]@{
        Package = "MuseScore"
        Description = "Beethoven would have loved this"
    },
    [PSCustomObject]@{
        Package = "DaVinci-Resolve"
        Description = "Can you believe Adobe charges monthly for Premiere? No way jose"
    },
    [PSCustomObject]@{
        Package = "GIMP"
        Description = "Can you believe Adobe charges monthly for Photshop? No way jose"
    },
    [PSCustomObject]@{
        Package = "Inkscape"
        Description = "Vectors and stuff, good for logo design"
    },
    [PSCustomObject]@{
        Package = "OBS-Studio"
        Description = "Record yourself, record the screen, record everything"
    },
    [PSCustomObject]@{
        Package = "Streamlabs-OBS"
        Description = "Record everything, and share it live!"
    },
    [PSCustomObject]@{
        Package = "Kodi"
        Description = "If you've got Blu-Ray discs or video files, this will take care of you"
    },
    [PSCustomObject]@{
        Package = "VLC"
        Description = "Because the Windows player is bloated and laggy"
    },
    [PSCustomObject]@{
        Package = "mpc-hc"
        Description = "Because VLC is bloated and laggy"
    },
    [PSCustomObject]@{
        Package = "Blender"
        Description = "3D file editor"
    }
)

# Society
$AppsSocial = @(
    [PSCustomObject]@{
        Package = "Discord"
        Description = "The Gen-Z AOL Messenger"
    },
    [PSCustomObject]@{
        Package = "em-client"
        Description = "Because Windows Mail spies on you"
    },
    [PSCustomObject]@{
        Package = "Zoom"
        Description = "Still don't know how this overtook Skype so quickly"
    },
    [PSCustomObject]@{
        Package = "Slack"
        Description = "Say hello to all your unknown co-workers"
    },
    [PSCustomObject]@{
        Package = "Webex-Meetings"
        Description = "Like Zoom, which is like Skype, but this one is uh... not those ones"
    }
)

# Keep things secure
$AppsSecurity = @(
    [PSCustomObject]@{
        Package = "MalwareBytes"
        Description = "This used to be the de facto anti-virus. Now, it's still decent enough"
    },
    [PSCustomObject]@{
        Package = "Wireshark"
        Description = "Listen to the ticks of your router, what's it doing? Why's it sending ten thousand data packets every second?"
    },
    [PSCustomObject]@{
        Package = "SysInternals"
        Description = "Like a stethoscope for Windows"
    }
)

# VPNs
$AppsVPNs = @(
    [PSCustomObject]@{
        Package = "WireGuard",
        Description = "When you need to connect to your own things"
    },
    [PSCustomObject]@{
        Package = "Tailscale",
        Description = "Wireguard on steroids"
    },
    [PSCustomObject]@{
        Package = "ProtonVPN"
        Description = "It's probably government spyware but you didn't hear that from me lol"
    },
    [PSCustomObject]@{
        Package = "NordVPN"
        Description = "I think Pewdiepie advertised this once, so it must be good"
    },
    [PSCustomObject]@{
        Package = "ExpressVPN"
        Description = "I think LinusTechTips advertised this once, so it must be good"
    },
    [PSCustomObject]@{
        Package = "MullvadVPN"
        Description = "My VPN of choice. 5 bucks and they don't id you. Nice"
    },
    [PSCustomObject]@{
        Package = "Windscribe"
        Description = "They got the coolest vpn website ngl"
    }
)

# Vidya Games
$AppsGaming = @(
    [PSCustomObject]@{
        Package = "Steam"
        Description = "A gamer's Wal-Mart"
    },
    [PSCustomObject]@{
        Package = "EA-App"
        Description = "A gamer's Wendy's"
    },
    [PSCustomObject]@{
        Package = "EpicGamesLauncher"
        Description = "A gamer's Ross"
    },
    [PSCustomObject]@{
        Package = "PCSX2"
        Description = "PlayStation 2 emulator"
    },
    [PSCustomObject]@{
        Package = "DS4Windows"
        Description = "Makes pairing and using DualShock4 controllers with Windows a bit easier"
    },
    [PSCustomObject]@{
        Package = "Dolphin"
        Description = "Wii and Gamecube emulator"
    },
    [PSCustomObject]@{
        Package = "ppsspp"
        Description = "PlayStation Portable emulator"
    },
    [PSCustomObject]@{
        Package = "SNES9x"
        Description = "Super Nintendo Entertainment System emulator"
    },
    [PSCustomObject]@{
        Package = "Mupen64plus"
        Description = "Nintendo 64 emulator"
    },
    [PSCustomObject]@{
        Package = "LeagueOfLegends"
        Description = "Bop it twist it pull it, you know the drill"
    },
    [PSCustomObject]@{
        Package = "Valorant"
        Description = "Pew pew pew PHOENIX STOP FLASHING ME"
    }
)

# Web Browsers
$AppsBrowsers = @(
    [PSCustomObject]@{
        Package = "GoogleChrome"
        Description = "Probably the most popular browser to ever browser"
    },
    [PSCustomObject]@{
        Package = "Firefox"
        Description = "For those fearful of big tech, yet unafraid of big corporation"
    },
    [PSCustomObject]@{
        Package = "Brave"
        Description = "When all else fails and the flies begin to come, it's all the same anyway"
    },
    [PSCustomObject]@{
        Package = "Tor-Browser"
        Description = "The true incognito mode, at the speed of snails"
    }
)

# Browser Extensions
$AppsBrowserExtensions = @(
    [PSCustomObject]@{
        Package = "ublockorigin-chrome"
        Description = "Get those trackers outta here"
    }
)

# Apps that aren't on Chocolatey
$AppsLocal = @(
    [PSCustomObject]@{
        Package = "Ableton"
        Description = "Deadmau5, Skrillex, Flume, Charli XCX, Frank Ocean, they use this so it's gotta be good"
    }
)