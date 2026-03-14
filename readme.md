# Get it Goin
## _A way to automate a clean Windows 11 Pro installation_

[![Alice In Chains](https://img.youtube.com/vi/kq9MBnX00hs/maxresdefault.jpg)](https://youtu.be/kq9MBnX00hs)

I'm at a weird time in my life where my trust in technology is at an all-time low. I've been encountering malware everywhere, in any machine you can think of from cell phones to HVAC machines. Anyways, I need a laptop, and my operating system of choice is and always will be Windows. Sadly, Microsoft has been hard at work ruining Windows, obliterating privacy, slowing it down with bloatware to a crawl. Worse, they have added hundreds of services, apps, drivers, scripts, all in the name of convenience, all increasing the attack surface, easily exploitable by tactics such as Living off the Land vulnerabilities. [Here's a beautiful website detailing many compromisable apps baked into the OS, many impossible to remove](https://lolbas-project.github.io/). Every day more get added.

I'm currently plagued by Windows Update itself. Somehow malware has been entering my PCs via officially signed packages. I'm also suspicious of Windows Defender, as for security sakes, this app is able to bypass firewalls and hosts files entirely, downloading whatever it thinks is "critical" whenever it wants with no control given to the user at all. Furthermore, Windows comes default with different wake timers and scheduled update tasks, allowing it to turn itself on and update itself when it deems fit, usually overnight. Attackers are also exploiting settings and app sharing, where devices I do not own are being added to my Google and Microsoft Account "My Devices" pages. These malicious devices push whatever they want to my things. And this is good. These features makes things convenient, so this is all good.

> My privacy is raked

I've created this project to help automate the setup of freshly flashed PCs. This repo contains many scripts to remove bloatware, harden security, disable tasks, remove services, lock down settings, and install selected apps. The core idea is that I can wipe the SSD in the bios, plug in my Win 11 install USB, plug in another USB with this project on it, and get my system just the way I like it in one swoop.

This project goes hand in hand with [Ameliorated Playbooks and the AME Client](https://amelabs.net/). My current playbook of choice is [ReviOS by Revision](https://www.revi.cc/download). If you wish to use these tools on air-gapped machines offline, I have modified the ReviOS Playbook to allow compilation and offline installation [here](https://github.com/REDACTED/reviOS-offline).

Some people say it is impossible to use Windows 11 privately, as it is very shoddy by design. But I'll be damned if I'm switching to Linux. I'll be damned!

## Features

- ASR Rule scripts - Fetch available ASR Rules from [Microsoft](https://github.com/MicrosoftDocs/defender-docs/blob/public/defender-endpoint/attack-surface-reduction-rules-reference.md), enable and disable them, and check their status
- Answerfile AutoUnattend - My current template is in the repo or you can create your own via [Schneegans](https://schneegans.de/windows/unattend-generator) according to your own needs
- Firewall hardening - Scripts that add outbound and inbound rules to Windows Defender Firewall
- [Chocolatey](https://chocolatey.org) scripts - Select and automate software installations during the OS installation process
- Ghost Rider wallpapers - What good is a machine that isn't badass?

## Tech

- [Chocolatey](https://chocolatey.org) - Automate installation of the software you need
- [Schneegans Answer File AutoUnattend Generator](https://schneegans.de/windows/unattend-generator) - Create a file that tells the Windows installation media to behave differently. Extremely powerful
- [Ameliorated AME Beta](https://amelabs.net) - Install Playbooks to tune Windows in any way
- [ReviOS](https://www.revi.cc/download) - A Playbook by Revision focused on minimalism and privacy
- [SysInternals](https://learn.microsoft.com/en-us/sysinternals) - A very important toolset for disabling startup services, monitoring processes, and so much more
- [Ventoy](https://www.ventoy.net) - Create runnable USBs with your choice of operating systems or install isos

## Installation

Not sure yet, leaving this here so I can edit later.

```sh
cd blah
npm i
node app
```

## License

MIT

[//]: # (These are reference links used in the body of this note and get stripped out when the markdown processor does its job. There is no need to format nicely because it shouldn't be seen. Thanks SO - http://stackoverflow.com/questions/4823468/store-comments-in-markdown-syntax)

   [dill]: <https://github.com/joemccann/dillinger>
   [git-repo-url]: <https://github.com/joemccann/dillinger.git>
   [john gruber]: <http://daringfireball.net>
