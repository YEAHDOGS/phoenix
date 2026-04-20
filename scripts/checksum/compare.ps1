# Add this to your script to verify a stored list
function Confirm-Integrity ($ReferenceCsv) {
    $baseline = Import-Csv $ReferenceCsv
    foreach ($entry in $baseline) {
        $live = .\check.ps1 -Path $entry.Path
        if ($live.Hash -ne $entry.Hash) {
            Write-Host "ALERT: Hash mismatch for $($entry.Path)!" -ForegroundColor Red
            Write-Host "Expected: $($entry.Hash)"
            Write-Host "Found:    $($live.Hash)"
        }
        else {
            Write-Host "Verified: $($entry.Path)" -ForegroundColor Green
        }
    }
}