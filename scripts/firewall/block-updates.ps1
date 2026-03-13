# BLOCK UPDATE ORCHESTRATOR AND WINDOWS UPDATE AUTOUPDATE CLIENT VIA FIREWALL
New-NetFirewallRule -DisplayName "BLOCK_UPDATE_ORCHESTRATOR_CLIENT_OUT" -Direction Outbound -Program "%systemroot%\system32\usoclient.exe" -Action Block
New-NetFirewallRule -DisplayName "BLOCK_WUA_MGR_OUT" -Direction Outbound -Program "%systemroot%\system32\wuauclt.exe" -Action Block
