# 1. Define the PATHS
$WMI_Path = ".\WMI_Apps.csv"
$Reg_Path = ".\Registry_Apps.csv"

# 2. Check if the files exist
if (!(Test-Path $WMI_Path)) { Write-Error "Missing: $WMI_Path"; return }
if (!(Test-Path $Reg_Path)) { Write-Error "Missing: $Reg_Path"; return }

# 3. Import and Filter WMI
$WMI_Data = Import-Csv -Path $WMI_Path | Where-Object { ![string]::IsNullOrWhiteSpace($_.Name) } | Select-Object `
@{N = "Name"; E = { $_.Name.Trim() } }, 
@{N = "Version"; E = { $_.Version } }, 
@{N = "SourceFile"; E = { "WMI_Apps.csv" } }

# 4. Import and Filter Registry
$Reg_Raw = Import-Csv -Path $Reg_Path
$Reg_Data = $Reg_Raw | Where-Object { ![string]::IsNullOrWhiteSpace($_.DisplayName) } | Select-Object `
@{N = "Name"; E = { $_.DisplayName.Trim() } }, 
@{N = "Version"; E = { $_.DisplayVersion } }, 
@{N = "SourceFile"; E = { "Registry_Apps.csv" } }

# 5. Run the comparison with -IncludeEqual
if ($null -ne $WMI_Data -and $null -ne $Reg_Data) {
    # Adding -IncludeEqual here pulls the "Both" entries
    $Comparison = Compare-Object -ReferenceObject $WMI_Data -DifferenceObject $Reg_Data -Property Name -PassThru -IncludeEqual

    if ($null -eq $Comparison) {
        Write-Host "No data found to compare." -ForegroundColor Red
    }
    else {
        $i = 0
        $Comparison | Sort-Object Name | ForEach-Object {
            $i++
            
            # Determine the location status
            $Status = switch ($_.SideIndicator) {
                "==" { "Both Files" }
                "<=" { "Only in WMI" }
                "=>" { "Only in Registry" }
            }

            [PSCustomObject]@{
                ID       = $i
                Name     = $_.Name
                Version  = $_.Version
                Source   = if ($_.SideIndicator -eq "==") { "WMI & Registry" } else { $_.SourceFile }
                Location = $Status
            }
        } | Out-GridView -Title "Full Software Audit: Comparison & Matches"
    }
}