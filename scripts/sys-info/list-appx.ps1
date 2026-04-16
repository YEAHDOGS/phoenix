#Requires -RunAsAdministrator

$ExportPath = ".\Sys-AppxPackages.csv"

Get-AppxPackage -AllUsers |
Select-Object Name, Publisher, PublisherId, Version, IsFramework, NonRemovable, SignatureKind, PackageFullName, InstallLocation |
Export-Csv -Path $ExportPath -NoTypeInformation