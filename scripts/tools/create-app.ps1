param (
    [Alias("n")]
    [Parameter(Mandatory = $false, HelpMessage = "Enter the name for your new Svelte project")]
    [string]$Name,

    [Alias("b")]
    [Parameter(Mandatory = $false, HelpMessage = "Template branch to create the app from")]
    [string]$Branch = "master"
)

# Where the template comes from: any git URL or folder in $env:DOGS_SVELTE_TEMPLATE, otherwise the local
# svelte-template checkout in Projects. Read at run time so no personal repo URL is ever committed here.
$TEMPLATE_ENV_VAR = "DOGS_SVELTE_TEMPLATE"
$PROJECTS_DIR = Join-Path $env:USERPROFILE "Projects"
$LOCAL_TEMPLATE_DIR = Join-Path $PROJECTS_DIR "svelte-template"
$TemplateRepo = [Environment]::GetEnvironmentVariable($TEMPLATE_ENV_VAR)
if ([string]::IsNullOrWhiteSpace($TemplateRepo)) { $TemplateRepo = $LOCAL_TEMPLATE_DIR }

# Save the directory you are currently in
$originalDir = Get-Location

# Set the working directory to the Projects folder in the user's profile
Set-Location $PROJECTS_DIR

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

Write-Host "`nCopying svelte-template ($Branch) into ./$Name..." -ForegroundColor Green

if (Test-Path $TemplateRepo) {
    # A local checkout is exported with git archive: the branch's committed files, no history. Cloning a local repo
    # needs git-upload-pack, which minimal git builds leave out.
    $archive = Join-Path ([IO.Path]::GetTempPath()) "$Name-template.zip"
    git -C $TemplateRepo archive --format=zip --output=$archive $Branch
    if ($LASTEXITCODE -eq 0) {
        Expand-Archive -Path $archive -DestinationPath $Name
        Remove-Item $archive
    }
}
else {
    git clone --depth 1 --branch $Branch $TemplateRepo $Name
}

if ($LASTEXITCODE -ne 0) {
    Write-Error "`n[Error] Failed to copy the template from '$TemplateRepo' ($Branch). Set `$env:$TEMPLATE_ENV_VAR to the template's git URL, or keep a checkout at $LOCAL_TEMPLATE_DIR."
    Set-Location $originalDir
    exit 1
}

Set-Location $Name

# Detach from the template repo (a clone brings its .git along) and start fresh history
if (Test-Path .git) { Remove-Item -Recurse -Force .git }
git init | Out-Null

# Template setup: name, title, description, optional desktop app, agent git workflow and AGENTS.md details.
# It fills in package.json (the name defaults to this folder), then removes itself and addons/.
Write-Host "`nSetting up the app..." -ForegroundColor Green

node start.js

if ($LASTEXITCODE -ne 0) {
    Write-Error "`n[Error] App setup (start.js) failed."
    Set-Location $originalDir
    exit 1
}

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
