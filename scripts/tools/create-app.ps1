param (
    [Alias("n")]
    [Parameter(Mandatory = $false, HelpMessage = "Enter the name for your new Svelte project")]
    [string]$Name
)

$TemplateRepo = "https://github.com/cptnbrando/svelte-template.git"

# Set the working directory to the Projects folder in the user's profile
Set-Location $env:USERPROFILE\Projects

Write-Host "--- Svelte App Creator ---" -ForegroundColor Cyan

# Interactive Check: If Name wasn't provided, ask for it now
if ([string]::IsNullOrWhiteSpace($Name)) {
    $Name = Read-Host "Enter your project name (e.g., my-svelte-app)"

    # Validation loop to make sure they don't just hit Enter
    while ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = Read-Host "Project name cannot be empty. Please enter a name"
    }
}

# Safety Check: Verify if npm is installed on the system
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    Write-Error "Error: 'npm' is not installed or not in your system PATH. Please install Node.js and try again."
    exit 1
}

# Safety Check: Verify if git is installed on the system
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Error "Error: 'git' is not installed or not in your system PATH. Please install Git and try again."
    exit 1
}

# Safety Check: Don't clobber an existing project
if (Test-Path $Name) {
    Write-Error "Error: A folder named '$Name' already exists in $(Get-Location). Pick a different name or remove it first."
    exit 1
}

# Save the directory you are currently in
$originalDir = Get-Location

Write-Host "`nCloning svelte-template into ./$Name..." -ForegroundColor Green

git clone --depth 1 $TemplateRepo $Name

if ($LASTEXITCODE -ne 0) {
    Write-Error "`n[Error] Failed to clone the template repo."
    Set-Location $originalDir
    exit 1
}

Set-Location $Name

# Detach from the template repo and start fresh history
Remove-Item -Recurse -Force .git
git init | Out-Null

# Personalize package.json with the new project name
$package = Get-Content package.json -Raw | ConvertFrom-Json
$package.name = $Name
$package | ConvertTo-Json -Depth 10 | Out-File -FilePath package.json -Encoding utf8

Write-Host "`nInstalling dependencies..." -ForegroundColor Green

npm install

if ($LASTEXITCODE -ne 0) {
    Write-Error "`n[Error] npm install failed."
    Set-Location $originalDir
    exit 1
}

Set-Location $originalDir

Write-Host "`n[Success] Project '$Name' created successfully!" -ForegroundColor Green
Write-Host "`nTo get started, run the following commands:" -ForegroundColor Yellow
Write-Host "  cd $Name"
Write-Host "  npm run dev`n"
