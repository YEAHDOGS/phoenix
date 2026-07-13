# Phoenix
# Phoenix
## _Ways to secure, automate, diagnose, and streamline fresh Windows 11 and Android resets_

[![Alice In Chains](https://img.youtube.com/vi/kq9MBnX00hs/maxresdefault.jpg)](https://youtu.be/kq9MBnX00hs)

I'm at a weird time in my life where my trust in technology is at an all-time low. I've been encountering problems with technology everywhere, in any machine you can think of from cell phones to HVAC machines. Anyways, I need a laptop, and my operating system of choice is and always will be Windows. Sadly, over the last decade Microsoft has been hard at work ruining Windows, obliterating privacy, slowing it down with bloatware to a crawl. Worse than the programs, they have added hundreds of services, apps, drivers, scripts, all in the name of convenience, all increasing the attack surface, easily exploitable by tactics such as Living off the Land vulnerabilities. [Here's a beautiful website detailing many compromisable apps baked into the OS, many impossible to remove](https://lolbas-project.github.io/). Every day more get added.

I'm currently plagued by Windows Update itself. Somehow bothersome things that I don't understand have been entering my PCs via officially signed packages as seemingly legitimate driver updates. I'm also suspicious of Windows Defender, as for security sakes, this app is able to bypass firewalls and hosts files entirely, downloading whatever it thinks is "critical" whenever it wants with no control given to the user at all. Furthermore, Windows comes default with different wake timers and scheduled update tasks, allowing it to turn itself on and update itself when it deems fit, usually overnight. Attackers are also exploiting settings and app sharing, where devices I do not own are being added to my Google and Microsoft Account "My Devices" pages. These malicious devices push whatever they want to my things. And this is good. These features makes things convenient, so this is all good.

> My privacy is raked

I've created this project to help automate the setup of freshly flashed PCs. This repo contains many scripts to remove bloatware, harden security, disable tasks, remove services, lock down settings, and install selected apps. The core idea is that I can wipe the SSD via bios, plug in my Win 11 install USB, plug in another USB with this project on it, and get my system just the way I like it in one swoop.

This project goes hand in hand with Playbooks and [Ameliorated AME]. My current playbook of choice is [ReviOS]. If you wish to use these tools on air-gapped machines offline, I have modified the ReviOS Playbook to allow compilation and offline installation [here](https://github.com/cptnbrando/reviOS-offline).

Some people say it is impossible to use Windows 11 privately, as it is very shoddy by design. But I'll be damned if I'm switching to Linux. I'll be damned!

## Android

My telephone of choice in 2026 is Android. I really love my OnePlus phone, it is beautiful, but I'm plagued by similar issues on it. Locking it down is just as difficult, and apps seem to update or install themselves willy nilly. I've had severe issues with [Google Cross Device Services](https://play.google.com/store/apps/details?id=com.google.ambient.streaming) which was pinging my location all day everyday and sending it around the world. Apps like [Android System SafetyCore](https://play.google.com/store/apps/details?id=com.google.android.safetycore), [Android Device Policy](https://play.google.com/store/apps/details?id=com.google.android.apps.work.clouddpc&hl=en_US), [Android System Key Verifier](https://play.google.com/store/apps/details?id=com.google.android.contactkeys&hl=en_US), [Android System WebView](https://play.google.com/store/apps/details?id=com.google.android.webview&hl=en_US), [Digital Wellbeing](https://play.google.com/store/apps/details?id=com.google.android.apps.wellbeing), [Captive Portal Login](https://f-droid.org/en/packages/com.juliansparber.captiveportallogin/), [Sim Manager](https://play.google.com/store/apps/details?id=com.google.android.euicc&hl=en_US), [Support components](https://www.apkmirror.com/apk/google-inc/support-components/), [Network manager](https://www.apkmirror.com/apk/google-inc/networkstack/), [Device configuration](https://www.apkmirror.com/apk/google-inc/device-configuration-2/), [Main components](https://www.apkmirror.com/apk/google-inc/main-components/main-components-2026-05-01s-release/), I am constantly at war with these applications. They will install themselves (sometimes one, sometimes many of them in random order) if the Google Play Store has any network access even with auto-updates disabled, even while my phone is in battery-saver sleep mode off at 4am, and stopping the services running these updates is very difficult. Sometimes they come in even if the Play Store has no network access somehow. They'll just silently appear in my apps list, no prompt action or notification whatsoever. I do not know what any of these apps do, but they do not provide any feature whatsoever to my phone functionality. And I hate things installed on my device, without my permission, that seemingly do nothing except make dns requests. That's the definition of spyware.

OnePlus lets me disable mobile data and wifi network access for individual apps, which somewhat works. But even with the Google Play Store network access disabled in the settings fully, it still makes requests all the time, totally unblocked. My current main weapon against this terror is [RethinkDNS]. It features DNS filtering, Ad blocking, app network blocking, firewall and ip config blocks, app ip request logging, and a lot more. I previously used [Blokada 5](https://blokada.org/) but it did not have enough information for my needs. Rethink is a beautiful alternative, and so far it's my main way to track app installs, data requests, everything. It even displays apps that are invisible to the Android Settings menus. Hundreds of them. It's devastatingly terrifying.

I'll be adding ADB scripts to monitor and audit apps and services on Android soon. The goal being the ability to quickly detect malware and spyware including [Pegasus](https://en.wikipedia.org/wiki/Pegasus_(spyware)) and [Graphite](https://en.wikipedia.org/wiki/Paragon_Solutions) by analyzing installed components, and comparing recent dns requests with publicly available threat analysis docs. Tools like [Mobile Verification Toolkit (MVT)] created by the [Amnesty International Security Lab] are the only ways to detect threats like Pegasus. MVT uses .stix2 files that denote Indicators of Compromise (IOCs). By using sources that analyze these threats in these ways [like this](https://github.com/mvt-project/mvt-indicators), automating security to block this kind of invisible, heinous, insane malware may be possible. Still, it's insane that these threats are still very very powerful, they've been around for the past decade! My eyes are on these auto-update features. Perhaps if I disable them all, I can be safe. Maybe. Ah, damn...

This idea of comparing DNS requests to documented threat analysis is a fleeting solution though. Today, malware development is so robust and quick that entire systems, networks, APIs, endpoints, everything are developed for specific targets. The requests a pegasus installation makes on my device may be different than the requests it makes on yours. That's the kicker. This problem is why antivirus solutions fail across the board today, and why cyber security experts are so gaslit that they recommend Microsoft Defender and nothing else. Because there is no such thing as cyber security or antivirus anymore. It's all [kaputt](https://youtu.be/puu3IvKnSb4). Privacy is dead in a coffin, rotting away. If an entity wants to monitor you, they can, and they will. With entirely brand new threats tailored just for you and your specific devices. The only solution in that case? Get good 😎 

Android does not feature any answerfile automation system for re-installs, so I do a lot of manual work to get my system back to where it needs to be. Hopefully I can add info here for the future.

> [!IMPORTANT]
> 🚧 Work in Progress - This project is under active development and does not work rn. Some scripts are functional.

## Features

- Attack Surface Reduction (ASR) Rule scripts - Fetch all available [ASR Rules from Microsoft](https://github.com/MicrosoftDocs/defender-docs/blob/public/defender-endpoint/attack-surface-reduction-rules-reference.md), enable and disable them, and check their status
- Answerfile AutoUnattend - An xml file that configures a Windows Installation Media. Allows account setup, drive formatting, bloatware removal, reg edits, and much more all automated. Done right, you don't have to click anything in the install gui, you just sail right to the desktop. My current template is in the repo /win-install/autounattend.xml or you can create your own via [Schneegans] according to your own needs
- Firewall hardening - Scripts that add outbound and inbound rules to Windows Defender Firewall
- [Chocolatey] scripts - Select and automate software installations during the OS installation process
- Ghost Rider wallpapers - What good is a machine that isn't badass?

# Goals

- Custom setup mainly targetting an HP Omnibook 7 laptop running Windows 11 Pro
- [Yubico Yubikey] smart card lockdown of administrator privileges
- [Chocolatey] software install automation
- Security hardening with Windows Defender Firewall rules and MS Defender Attack Surface Reduction (ASR) rules
- Auto disabling or uninstalling of as many unnecessary services and drivers as possible
- Windows Telemetry, Bing integration, AI features like Windows Recall, and many more spyware features disabled
- Disable Windows Update and other auto-update features that come default, as these overwrite our changes and can even add malware
- Change various Windows settings to enhance privacy
- Use [QEMU] for a portable dev environment, to keep risky software and packages out of the main host pc
- Set up regular backup and restore capabilities
- Attack the registry, device manager (drivers), services, task scheduler, firewall, and control panel to minimize background services, cut the attack surface down, and turn Windows 11 into a lean mean silent machine
- 0 to 1. Wipe ssd from bios, plug Win 11 install media and this project on a usb in, press play, and get back to where I like to be in 15 minutes or less automatically

## Tech

- [Chocolatey] - Automate installation of the software you need
- [Schneegans Answer File AutoUnattend Generator](https://schneegans.de/windows/unattend-generator) - Create a file that tells the Windows installation media to behave differently. Extremely powerful
- [Ameliorated AME] - Install Playbooks to tune Windows in any way
- [ReviOS] - A Playbook by Revision focused on minimalism and privacy
- [SysInternals] - A very important toolset for disabling startup services, monitoring processes, and so much more
- [Ventoy](https://www.ventoy.net) - Create runnable USBs with your choice of operating systems or install isos
- [Yubico Yubikey] - A $50 USB FIDO smart card. Currently smart card login appears only accessible to Windows Enterprise users set up with Group Policies in Microsoft Intune. This is a shame, as a beautiful security setup would be to have 2 accounts, a user and an admin one that's added to the Administrators group, then only allow the admin account to be logged in via smart card. Then leave the yubikey at home, and do what you want to do in peace. This repo will contain documentation and scripts to enable this setup
- [QEMU] - Much slicker than VirtualBox albeit a bit more setup heavy. Allows fast emulation of other operating systems
- [Portmaster] - Windows Defender Firewall can only do so much. This is a modern solution for a proper dynamic firewall.
- [RethinkDNS] - Android app to filter dns/ip requests, log app traffic, and block malicious network behavior
- [Mobile Verification Toolkit (MVT)] - A way to detect threats like Pegasus, created by the [Amnesty International Security Lab]

## Installation

### Using the GUI Launcher (Recommended)

A unified GUI launcher is available to browse, search, and execute all scripts in this project:

```powershell
cd .\scripts\tools
.\gui-launcher.ps1
```

The launcher provides:
- **Organized Script Browser** - Browse all 50+ scripts organized by category
- **Search Functionality** - Quickly find scripts by name
- **Script Details** - View script path and requirements
- **Integrated Output** - See script results directly in the GUI
- **One-Click Execution** - Run scripts with a single click

### Manual Execution

For now, the ASR Scripts work well. Simply clone this repo, and run one of the main scripts in phoenix/scripts/asr/
- check-asr-rules.ps1 : Fetches rules from Microsoft and verifies if they are enabled on your machine
- add-all-asr-rules.ps1 : Fetches and adds all available ASR Rules in Block mode. I highly recommend running this script on every Windows machine you own
- add-asr-rule.ps1 : Adds an ASR Rule in Block mode given a GUID
- disable-all-asr-rules.ps1 : Disables or deletes all active ASR Rules
- disable-asr-rule.ps1 : Disables or deletes an active ASR Rule from your machine

I highly recommend running check-asr-rules, then add-all-asr-rules, then check-asr-rules again to confim they work. If you want to see them in action, I got one to trigger by installing [Idea IntelliJ](https://www.jetbrains.com/idea/download/?section=windows), which attempts to replace klist.exe (a Kerberos ticket caching thingy) in the Windows dir. Google Gemini tells me this is normal because IntelliJ contains a jdk and the jdk contains a klist.exe. So yeah. But this is exactly what I mean, all this software doing god knows what to the sanctity of the operating system's heart willy nilly, no more of this horseshit! Installing [GIMP](https://www.gimp.org) seems to trigger the same rule for a file called help.exe - Block use of copied or impersonated system tools. And the [EA App](https://www.ea.com/ea-app) with its anti-cheat triggered this one too - Block credential stealing from the Windows local security authority subsystem (lsass.exe). All of these apps are still entirely functional, it's just that Windows blocked the sketchy behavior. Which makes me feel better.

All actions blocked by these ASR rules are notified via Windows Security and viewable in the Protection History page.

Go to the ASR scripts folder and run check-asr-rules.ps1, it will display a list of all MS ASR rules present on their website, then report that you have 0 of them active
```powershell
cd .\phoenix\scripts\asr
.\check-asr-rules.ps1
```

Add them all
```powershell
.\add-all-asr-rules.ps1
```

Afterwards, check again to confirm they are now active
```powershell
.\check-asr-rules.ps1
```

There is a script that lists all installed and active drivers on the machine. It lists the version, installed date, associated PnP device, and more. There are also scripts to list all apps and services found in the registry. They will export the data as .csv files.

```powershell
cd .\phoenix\scripts\sys-info
.\info.ps1
```

There are some scripts to fetch, and install Windows Updates manually using the Windows Update Agent. This is separate from the Windows Update services, and can be used manually from Powershell even if Windows Update is disabled.

Fetch and list all incoming update info without installing any of them
```powershell
cd .\phoenix\scripts\get-windows-updates
.\fetch-updates.ps1
```

Install the specific update that you want with its ID (replace the ID below)
```powershell
.\install.ps1 a32ca1d0-ddd4-486b-b708-d941db4f1101
```

## License

MIT

[//]: # (These are reference links used in the body of this note and get stripped out when the markdown processor does its job. There is no need to format nicely because it shouldn't be seen. Thanks SO - http://stackoverflow.com/questions/4823468/store-comments-in-markdown-syntax)

   [Chocolatey]: <https://chocolatey.org>
   [ReviOS]: <https://www.revi.cc>
   [Schneegans]: <https://schneegans.de/windows/unattend-generator>
   [Ameliorated AME]: <https://amelabs.net>
   [SysInternals]: <https://learn.microsoft.com/en-us/sysinternals>
   [Yubico Yubikey]: <https://www.yubico.com>
   [QEMU]: <https://www.qemu.org>
   [Portmaster]: <https://safing.io/>
   [RethinkDNS]: <https://rethinkdns.com/>
   [Mobile Verification Toolkit (MVT)]: <https://github.com/mvt-project/mvt>
   [Amnesty International Security Lab]: <https://securitylab.amnesty.org/>
