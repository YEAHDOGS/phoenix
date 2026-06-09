param (
    [Alias("n")]
    [Parameter(Mandatory = $false, HelpMessage = "Enter the name for your new Svelte project")]
    [string]$Name
)

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

Write-Host "`nScaffolding your Svelte project in folder: ./$Name..." -ForegroundColor Green

# Save the directory you are currently in
$originalDir = Get-Location

# Using --no-immediate prevents Vite from prompting for install
npm create vite@latest $Name -- --template svelte --no-immediate

# Success Info: Friendly next steps
if ($LASTEXITCODE -eq 0) {
    Write-Host "`n[Success] Project '$Name' created successfully!" -ForegroundColor Green
}
else {
    Write-Error "`n[Error] Vite project creation failed."
    Set-Location $originalDir
    exit 1
}

Set-Location $Name

npm install

npm install -D tailwindcss @tailwindcss/vite sass-embedded

Write-Host "`n[Success] Tailwind CSS and dependencies installed!" -ForegroundColor Green
Write-Host "Next, you can set up Tailwind CSS by following the official guide:
https://tailwindcss.com/docs/guides/vite`n" -ForegroundColor Yellow

Remove-Item vite.config.js -ErrorAction SilentlyContinue
New-Item vite.config.js

"import { defineConfig } from 'vite'
import { svelte } from '@sveltejs/vite-plugin-svelte'
import tailwindcss from '@tailwindcss/vite'

// https://vite.dev/config/
export default defineConfig({
  plugins: [
    tailwindcss(),
    svelte()
  ],
})" | Out-File -FilePath vite.config.js -Encoding utf8

Set-Location $originalDir

Write-Host "`nTo get started, run the following commands:" -ForegroundColor Yellow
Write-Host "  cd $Name"
Write-Host "  npm run dev`n"
