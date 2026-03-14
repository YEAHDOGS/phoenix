$AsrUrl = "https://raw.githubusercontent.com/MicrosoftDocs/defender-docs/refs/heads/public/defender-endpoint/attack-surface-reduction-rules-reference.md"

Write-Host "Fetching latest ASR rules from Microsoft Documentation..." -ForegroundColor Cyan
Write-Host "Url: $AsrUrl" -ForegroundColor Cyan

try {
    $rawContent = Invoke-RestMethod -Uri $AsrUrl

    # 1. Isolate the content starting from the 'ASR rule to GUID matrix' header
    # We split by the header and take the second part [1]
    $ruleSplit = ($rawContent -split "## ASR rule to GUID matrix")[1]
    $tablePart = ($ruleSplit -split "## ASR rule modes")[0]
    
    # 2. Extract lines that look like table rows (must contain a GUID)
    # This regex looks for: | Description | GUID |
    $regex = '\|(?<Description>.*?)\|(?<GUID>[0-9a-fA-F-]{36})\|'
    
    $OnlineRules = [regex]::Matches($tablePart, $regex) | ForEach-Object {
        [PSCustomObject]@{
            # Trim extra spaces, markdown line breaks (<br/>), and superscript markers (*)
            Description = $_.Groups['Description'].Value.Replace("<br/>", " ").Replace("<sup>\*</sup>", "").Trim()
            GUID        = $_.Groups['GUID'].Value.Trim()
        }
    }
}
catch {
    Write-Error "Failed to fetch rules."
    $LineNumber = $_.InvocationInfo.ScriptLineNumber
    $LineContent = $_.InvocationInfo.Line.Trim()

    Write-Host "`n--- ERROR TRACE ---" -ForegroundColor Red
    Write-Host "FAILED ON LINE $($LineNumber) : $LineContent" -ForegroundColor Yellow
    Write-Host "ERROR MESSAGE:  $($_.Exception.Message)" -ForegroundColor Yellow
}

if ($OnlineRules.Count -gt 0) {
    Write-Host "Successfully fetched $($OnlineRules.Count) ASR rules online from Microsoft.`n" -ForegroundColor Green
}
else {
    Write-Host "Failed to fetch online ASR ruleset." -ForegroundColor Cyan
    Write-Host "Using stored data." -ForegroundColor Cyan
    . ./asr-ruleset.ps1
    $OnlineRules = $rules
}

$OnlineRules | Format-Table -AutoSize