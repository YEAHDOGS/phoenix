param(
    [Parameter(Mandatory = $true)]
    [string]$Path
)

if ($Path -ccontains ":/") {
    
}

Import-Csv -Path $Path | Out-GridView