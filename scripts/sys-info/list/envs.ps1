# This lists all environment variables available on the system.

Get-ChildItem Env: |
Sort-Object Name |
Format-Table -AutoSize