#Requires -RunAsAdministrator

# I fucking hate filters

$ExportPath = ".\Sys-Filters.csv"
$rawOutput = fltmc filters | Select-Object -Skip 3

$results = foreach ($line in $rawOutput) {
    # Split by whitespace
    $parts = $line -split '\s{1,}'

    if ($parts.Count -ge 3) {
        [PSCustomObject]@{
            FilterName = $parts[0].Trim()
            Instances  = $parts[1].Trim()
            Altitude   = $parts[2].Trim()
            Frame      = $parts[3].Trim()
        }
    }
}

$results | Export-Csv -Path $ExportPath -NoTypeInformation