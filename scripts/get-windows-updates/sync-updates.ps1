# This will sync your newly installed updates with the Update History list in the Windows Update Settings page
# When Windows Update is disabled, this list does not sync automatically
(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=1").Updates | Select-Object -First 1