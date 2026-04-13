param(
    [string[]]$Set,
    [string[]]$Toggle,
    [string]$ConfigFile = "data/win-install/answerfile-config.json"
)

function Parse-KeyValue {
    param(
        [string]$Input
    )

    if ($Input -notmatch '=') {
        throw "Invalid key/value pair: '$Input'. Use Name=Value."
    }

    $parts = $Input -split '=', 2
    return @{ Key = $parts[0].Trim(); Value = $parts[1].Trim() }
}

if (-not (Test-Path $ConfigFile)) {
    throw "Configuration file '$ConfigFile' not found. Run parse-schneegans-url.ps1 first."
}

$config = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json

if ($Set) {
    foreach ($entry in $Set) {
        $pair = Parse-KeyValue -Input $entry
        $config.params.$($pair.Key) = $pair.Value
        Write-Host "Set param $($pair.Key) = $($pair.Value)"
    }
}

if ($Toggle) {
    foreach ($entry in $Toggle) {
        $pair = Parse-KeyValue -Input $entry
        $value = $pair.Value.ToLower()
        if ($value -eq 'true' -or $value -eq 'false') {
            $config.toggles.$($pair.Key) = [bool]::Parse($value)
            Write-Host "Toggled $($pair.Key) = $value"
        }
        else {
            throw "Toggle value for '$($pair.Key)' must be true or false."
        }
    }
}

$config | ConvertTo-Json -Depth 20 | Set-Content -Path $ConfigFile -Encoding utf8
Write-Host "Updated configuration file $ConfigFile"
