param(
    [string]$ConfigFile = "data/win-install/answerfile-config.json",
    [string]$EnvFile = ".env",
    [string]$OutputFile = "win-install/autounattend.xml"
)

function Get-DotEnv {
    param(
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        throw "Environment file '$Path' not found. Copy .env.example to .env and fill it in."
    }

    $data = @{}
    foreach ($line in Get-Content -Path $Path) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('#')) {
            continue
        }

        $index = $trimmed.IndexOf('=')
        if ($index -lt 0) {
            continue
        }

        $key = $trimmed.Substring(0, $index).Trim()
        $value = $trimmed.Substring($index + 1).Trim().Trim('"')
        $data[$key] = $value
    }

    return $data
}

function Build-QueryString {
    param(
        [hashtable]$Params,
        [hashtable]$Toggles
    )

    $pairs = @()
    foreach ($key in $Params.Keys) {
        if ($Toggles.ContainsKey($key) -and -not $Toggles[$key]) {
            continue
        }

        $value = [string]$Params[$key]
        if ($null -eq $value) { continue }

        $escaped = [System.Uri]::EscapeDataString($value)
        $pairs += "$key=$escaped"
    }

    return [string]::Join('&', $pairs)
}

if (-not (Test-Path $ConfigFile)) {
    throw "Configuration file '$ConfigFile' not found. Run parse-schneegans-url.ps1 first."
}

$config = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
$env = Get-DotEnv -Path $EnvFile

$overrides = @{
    ProductKey       = $env.WINDOWS_KEY
    ComputerName     = $env.COMPUTER_NAME
    AccountName0     = $env.ADMIN_USERNAME
    AccountPassword0 = $env.ADMIN_PASSWORD
    AccountName1     = $env.USER_USERNAME
    AccountPassword1 = $env.USER_PASSWORD
    InstallFromName  = $env.WINDOWS_VERSION
}

foreach ($name in $overrides.Keys) {
    if ($null -ne $overrides[$name] -and $overrides[$name] -ne '') {
        $config.params.$name = $overrides[$name]
    }
}

if ($null -ne $env.LOCALE -and $env.LOCALE -ne '') {
    $config.params.Locale = $env.LOCALE
}
if ($null -ne $env.TIME_ZONE -and $env.TIME_ZONE -ne '') {
    $config.params.TimeZone = $env.TIME_ZONE
}
if ($null -ne $env.COMPUTER_NAME -and $env.COMPUTER_NAME -ne '') {
    $config.params.ComputerName = $env.COMPUTER_NAME
}

$query = Build-QueryString -Params $config.params -Toggles $config.toggles
$url = "$($config.generatorBaseUrl)?$query"

Write-Host "Generating autounattend.xml from Schneegans URL..."
$response = Invoke-WebRequest -Uri $url -Headers @{ Accept = 'application/xml,text/xml,*/*' } -UseBasicParsing -ErrorAction Stop

if (-not $response.Content.TrimStart().StartsWith('<')) {
    throw "Downloaded content does not appear to be XML."
}

$comment = "<!--$url-->"
Set-Content -Path $OutputFile -Value "$comment`r`n$response.Content" -Encoding utf8
Write-Host "Generated $OutputFile"
