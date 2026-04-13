param(
    [string]$SourceFile = "win-install/autounattend.xml",
    [string]$DestinationFile = "data/win-install/answerfile-config.json"
)

function Parse-SchneegansQuery {
    param(
        [string]$Query
    )

    $pairs = $Query -split '&'
    $params = @{}
    $toggles = @{}

    foreach ($pair in $pairs) {
        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
        $parts = $pair -split '=', 2
        if ($parts.Count -ne 2) { continue }

        $key = $parts[0]
        $value = $parts[1] -replace '\+', ' '
        $value = [System.Uri]::UnescapeDataString($value)

        if ($params.ContainsKey($key)) {
            if ($params[$key] -is [System.Collections.ArrayList]) {
                $params[$key].Add($value)
            }
            else {
                $params[$key] = [System.Collections.ArrayList]@($params[$key], $value)
            }
        }
        else {
            $params[$key] = $value
        }

        if ($value -eq 'true' -or $value -eq 'false') {
            $toggles[$key] = [bool]::Parse($value)
        }
    }

    return [PSCustomObject]@{
        generatorBaseUrl = 'https://schneegans.de/windows/unattend-generator/'
        params           = $params
        toggles          = $toggles
    }
}

if (-not (Test-Path $SourceFile)) {
    throw "Source file '$SourceFile' was not found."
}

$content = Get-Content -Raw -Path $SourceFile
if ($content -notmatch '<!--(.*?)-->') {
    throw "No Schneegans URL comment was found in $SourceFile."
}

$url = $matches[1]
if ($url -notmatch '\?') {
    throw "The Schneegans URL in $SourceFile does not contain query parameters."
}

$query = $url.Substring($url.IndexOf('?') + 1)
$config = Parse-SchneegansQuery -Query $query
$config | ConvertTo-Json -Depth 20 | Set-Content -Path $DestinationFile -Encoding utf8
Write-Host "Wrote configuration to $DestinationFile"
