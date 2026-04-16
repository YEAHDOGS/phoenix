# This requires notepad to have an app alias. Go to Settings > Apps > Advanced Settings > App execution aliases and enable Notepad. This will allow us to use Start-Process "notepad.exe" to open the hosts file with admin privileges.

Start-Process "notepad.exe" -ArgumentList "$env:SystemRoot\System32\drivers\etc\hosts" -WorkingDirectory "$env:TEMP" -Verb RunAs