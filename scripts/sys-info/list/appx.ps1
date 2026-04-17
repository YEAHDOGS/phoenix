param (
    [Alias("t")]
    [switch]$TableView
)

#Requires -RunAsAdministrator

. "$PSScriptRoot\utils.ps1"
$ExportPath = Initialize-AuditFile -Name "AppxPackages"

$manifestData = Get-AppxPackage -AllUsers | ForEach-Object {
    $pkg = $_
    # Get-AppxPackageManifest returns a wrapper; the actual manifest is in the .Package property
    $manifest = $pkg | Get-AppxPackageManifest | Select-Object -ExpandProperty Package

    [PSCustomObject]@{
        Name                          = $pkg.Name
        PackageFullName               = $pkg.PackageFullName
        Publisher                     = $pkg.Publisher
        PublisherId                   = $pkg.PublisherId
        Version                       = $pkg.Version
        IsFramework                   = $pkg.IsFramework
        NonRemovable                  = $pkg.NonRemovable
        InstallLocation               = $pkg.InstallLocation
        SignatureKind                 = $pkg.SignatureKind
        # Identity is a nested object; we need to drill into its properties
        ManifestName                  = $manifest.Identity.Name
        ManifestVersion               = $manifest.Identity.Version
        ManifestPublisher             = $manifest.Identity.Publisher
        ManifestProcessorArchitecture = $manifest.Identity.ProcessorArchitecture
        # DisplayName and ResourceId are usually under 'Properties'
        DisplayName                   = $manifest.Properties.DisplayName
        ResourceId                    = $manifest.Identity.ResourceId
        # Dependencies is a collection; we need to map the 'Package' or 'Name' field
        Dependencies                  = ($manifest.Dependencies.Package | ForEach-Object { $_.Name }) -join ';'
    }
}

$manifestData | Export-Csv -Path $ExportPath -NoTypeInformation

Write-Host "APPX Packages and APPX Manifests audit exported to $ExportPath" -ForegroundColor Cyan

# Check for the -t (TableView) flag
if ($TableView) {
    Import-Csv -Path $ExportPath | Out-GridView -Title "AppX Packages and Manifests"
}