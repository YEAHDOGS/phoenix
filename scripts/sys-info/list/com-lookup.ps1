function Resolve-WindowsComGuid {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Guid
    )

    # Clean up brackets if they exist
    $CleanGuid = $Guid.Trim("{}")
    
    # Define primary registry lookup paths
    $LookupPaths = @(
        "HKLM:\Software\Classes\CLSID\{$CleanGuid}",
        "HKLM:\Software\Classes\Wow6432Node\CLSID\{$CleanGuid}",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\ApplicabilityEvaluationCache"
    )

    $FoundPath = $null
    $FriendlyName = "Unknown COM Component"

    foreach ($Path in $LookupPaths) {
        if (Test-Path $Path) {
            # Try to get the friendly descriptive name of the component
            $ProgId = Get-ItemProperty -Path $Path -Name "(Default)" -ErrorAction SilentlyContinue
            if ($ProgId -and $ProgId.'(Default)') { $FriendlyName = $ProgId.'(Default)' }

            # Check for In-Process DLL servers
            if (Test-Path "$Path\InprocServer32") {
                $Server = Get-ItemProperty -Path "$Path\InprocServer32" -Name "(Default)" -ErrorAction SilentlyContinue
                if ($Server -and $Server.'(Default)') { 
                    $FoundPath = $Server.'(Default)'
                    break
                }
            }
            # Check for Local EXE servers
            if (Test-Path "$Path\LocalServer32") {
                $Server = Get-ItemProperty -Path "$Path\LocalServer32" -Name "(Default)" -ErrorAction SilentlyContinue
                if ($Server -and $Server.'(Default)') { 
                    $FoundPath = $Server.'(Default)'
                    break
                }
            }
        }
    }

    # If it's an expanded system variable path (like %SystemRoot%\System32\...) expand it cleanly
    if ($null -ne $FoundPath) {
        $ExpandedPath = [Environment]::ExpandEnvironmentVariables($FoundPath)
    }
    else {
        $ExpandedPath = "No physical file path registered under this CLSID hive"
    }

    [PSCustomObject]@{
        TargetGuid     = "{$CleanGuid}"
        ComponentName  = $FriendlyName
        BinaryLocation = $ExpandedPath
    }
}