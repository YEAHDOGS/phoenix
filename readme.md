# Get it Goin
## _A way to automate a clean Windows 11 Pro installation_

[![Alice In Chains](https://img.youtube.com/vi/kq9MBnX00hs/maxresdefault.jpg)](https://youtu.be/kq9MBnX00hs)

I'm at a weird time in my life where my trust in technology is at an all-time low. I've been encountering malware everywhere, in any machine you can think of from cell phones to HVAC machines. Anyways, I need a laptop, and my operating system of choice is and always will be Windows. Sadly, Microsoft has been hard at work ruining Windows, obliterating privacy, slowing it down with bloatware to a crawl. Worse, they have added hundreds of services, apps, drivers, scripts, all in the name of convenience, all increasing the attack surface, easily exploitable by tactics such as Living off the Land vulnerabilities. [Here's a beautiful website detailing many compromisable apps baked into the OS, many impossible to remove](https://lolbas-project.github.io/). Every day more get added.

I'm currently plagued by Windows Update itself. Somehow malware has been entering my PCs via officially signed packages. I'm also suspicious of Windows Defender, as for security sakes, this app is able to bypass firewalls and hosts files entirely, downloading whatever it thinks is "critical" whenever it wants with no control given to the user at all. Furthermore, Windows comes default with different wake timers and scheduled update tasks, allowing it to turn itself on and update itself when it deems fit, usually overnight. Attackers are also exploiting settings and app sharing, where devices I do not own are being added to my Google and Microsoft Account "My Devices" pages. These malicious devices push whatever they want to my things. And this is good. These features makes things convenient, so this is all good.

> My privacy is raked

I've created this project to help automate the setup of freshly flashed PCs. This repo contains many scripts to remove bloatware, harden security, disable tasks, remove services, lock down settings, and install selected apps. The core idea is that I can wipe the SSD via bios, plug in my Win 11 install USB, plug in another USB with this project on it, and get my system just the way I like it in one swoop.

This project goes hand in hand with Playbooks and [Ameliorated AME]. My current playbook of choice is [ReviOS]. If you wish to use these tools on air-gapped machines offline, I have modified the ReviOS Playbook to allow compilation and offline installation [here](https://github.com/REDACTED/reviOS-offline).

Some people say it is impossible to use Windows 11 privately, as it is very shoddy by design. But I'll be damned if I'm switching to Linux. I'll be damned!

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

## Installation

For now, the ASR Scripts work well. Simply clone this repo, and run one of the main scripts in Get-It-Goin/scripts/asr/
- check-asr-rules.ps1 : Fetches rules from Microsoft and verifies if they are enabled on your machine
- add-all-asr-rules.ps1 : Fetches and adds all available ASR Rules in Block mode. I highly recommend running this script on every Windows machine you own
- add-asr-rule.ps1 : Adds an ASR Rule in Block mode given a GUID
- disable-all-asr-rules.ps1 : Disables or deletes all active ASR Rules
- disable-asr-rule.ps1 : Disables or deletes an active ASR Rule from your machine

I highly recommend running check-asr-rules, then add-all-asr-rules, then check-asr-rules again to confim they work. If you want to see them in action, I got one to trigger by installing [Idea IntelliJ](https://www.jetbrains.com/idea/download/?section=windows), which attempts to replace klist.exe (a Kerberos ticket caching thingy) in the Windows dir. Google Gemini tells me this is normal because IntelliJ contains a jdk and the jdk contains a klist.exe. So yeah. But this is exactly what I mean, all this software doing god knows what to the sanctity of the operating system's heart willy nilly, no more of this horseshit!

Go to the ASR scripts folder and run check-asr-rules.ps1, it will display a list of all MS ASR rules present on their website, then report that you have 0 of them active
```powershell
cd .\get-it-goin\scripts\asr
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
