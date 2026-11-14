# update-card.ps1 - make everything copied onto the R36S EASYROMS card show up in the menu.
# Usage:  pwsh -File update-card.ps1            (finds the mounted EASYROMS card by label)
#         pwsh -File update-card.ps1 -Drive G   (force a drive letter)
# Safe to run repeatedly. It never deletes a game file. It:
#   - checks every file against the extensions the OS accepts for that system folder
#   - PSX (only with -PsxPrep): writes .cue for bare .bin discs, .m3u playlists for multi-disc sets
#   - ports: extracts PortMaster zips so their launcher .sh is visible
#   - writes/updates gamelist.xml per system (clean names, artwork links, hides playlist members)
#   - copies the launchimages\ set next to this script onto the card (the DOGS launch flash)
#   - removes empty system folders (unless -KeepEmptyFolders)
param([string]$Drive, [switch]$KeepEmptyFolders, [switch]$PsxPrep)
$ErrorActionPreference = 'Stop'
if (-not $Drive) {
  $found = Get-Volume | Where-Object { $_.FileSystemLabel -eq 'EASYROMS' -and $_.DriveLetter }
  if (-not $found) { throw "No volume labelled EASYROMS is mounted. Plug the card in (or pass -Drive X)." }
  $Drive = [string]$found[0].DriveLetter
}
$root = "${Drive}:\"
$tools = Split-Path -Parent $MyInvocation.MyCommand.Path
$logDir = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'phoenix' } else { Join-Path $HOME '.cache/phoenix' }; New-Item -ItemType Directory -Force $logDir | Out-Null; $log = Join-Path $logDir 'update-card.log'
function L($m){ $line = "$(Get-Date -Format 'HH:mm:ss') $m"; Write-Host $line; Add-Content -Path $log -Value $line }
"---- update-card run $(Get-Date -Format 'yyyy-MM-dd HH:mm') ----" | Add-Content $log

$vol = Get-Volume -DriveLetter $Drive -ErrorAction SilentlyContinue
if (-not $vol -or $vol.FileSystemLabel -ne 'EASYROMS') { throw "Drive ${Drive}: is not the EASYROMS card" }
L "Card ${Drive}: $([math]::Round(($vol.Size-$vol.SizeRemaining)/1GB,2)) GB used of $([math]::Round($vol.Size/1GB,1)) GB"

# ---------- system definitions from the OS's es_systems.cfg ----------
$cfg = Get-Content (Join-Path $tools 'es_systems.cfg') -Raw
$systems = @{}   # folder name -> @{Name; Full; Ext(set)}
foreach ($m in [regex]::Matches($cfg, '<system>(.*?)</system>', 'Singleline')) {
  $blk = $m.Groups[1].Value
  $path = [regex]::Match($blk,'<path>(.*?)</path>').Groups[1].Value.Trim()
  if ($path -notmatch '^/roms/([^/]+)/?$') { continue }
  $folder = $Matches[1]
  $ext = [regex]::Match($blk,'<extension>(.*?)</extension>').Groups[1].Value.Trim().ToLower() -split '\s+' | Sort-Object -Unique
  $systems[$folder] = @{ Name=[regex]::Match($blk,'<name>(.*?)</name>').Groups[1].Value.Trim(); Full=[regex]::Match($blk,'<fullname>(.*?)</fullname>').Groups[1].Value.Trim(); Ext=$ext }
}
$support = 'bios','themes','tools','launchimages','backup','bgmusic','videos','movies','System Volume Information','_zips'
$artDirs = 'images','downloaded_images','media','boxart','miximages'

function Clean-Name([string]$base) {
  $n = $base -replace '\s*\[[^\]]*\]', '' -replace '\s*\([^)]*\)', ''
  $n = $n -replace '\s+', ' '
  return $n.Trim(' ', '-', '_')
}
function Disc-Key([string]$base) {  # returns title without the disc tag, or $null if not a disc
  if ($base -match '^(.*?)\s*[\(\[]Disc\s*(\d+)[^\)\]]*[\)\]](.*)$') { return @{ Title = ($Matches[1] + $Matches[3]).Trim(); Disc = [int]$Matches[2] } }
  return $null
}

# ---------- PSX: cue sheets + m3u playlists ----------
function Prep-Psx([string]$dir) {
  $made = 0; $m3u = 0
  $dirs = @($dir) + @(Get-ChildItem $dir -Directory | Where-Object { $_.Name -notin $artDirs } | Select-Object -ExpandProperty FullName)
  foreach ($d in $dirs) {
    foreach ($bin in Get-ChildItem $d -File -Filter *.bin) {
      $cue = [IO.Path]::ChangeExtension($bin.FullName, '.cue')
      if (-not (Test-Path $cue)) {
        # a cue in a 'cue' subfolder next to the bins (as in the BIGSHIP copies)? use it
        $alt = Join-Path $d "cue\$([IO.Path]::GetFileNameWithoutExtension($bin.Name)).cue"
        if (Test-Path $alt) { Copy-Item $alt $cue } else {
          "FILE `"$($bin.Name)`" BINARY`r`n  TRACK 01 MODE2/2352`r`n    INDEX 01 00:00:00`r`n" | Set-Content $cue -NoNewline -Encoding ascii
        }
        $made++; L "  psx: wrote cue for $($bin.Name)"
      }
    }
    # multi-disc sets -> m3u
    $discs = Get-ChildItem $d -File | Where-Object { $_.Extension -match '^\.(cue|chd|pbp)$' } | ForEach-Object { $k = Disc-Key $_.BaseName; if ($k) { [PSCustomObject]@{ File=$_; Title=$k.Title; Disc=$k.Disc } } }
    foreach ($g in ($discs | Group-Object Title | Where-Object Count -ge 2)) {
      $target = Join-Path $d ((Clean-Name $g.Name) + '.m3u')
      $lines = $g.Group | Sort-Object Disc | ForEach-Object { $_.File.Name }
      $existing = if (Test-Path $target) { Get-Content $target } else { @() }
      if (-not $existing -or (Compare-Object $existing $lines)) { $lines | Set-Content $target -Encoding ascii; $m3u++; L "  psx: wrote m3u $([IO.Path]::GetFileName($target)) ($($lines.Count) discs)" }
    }
  }
  L "psx: $made cue(s) written, $m3u m3u(s) written"
}

# ---------- ports: extract PortMaster zips ----------
function Prep-Ports([string]$dir) {
  $7z = 'C:\Program Files\7-Zip\7z.exe'
  $zips = Get-ChildItem $dir -File -Filter *.zip
  if (-not $zips) { return }
  if (-not (Test-Path $7z)) { L "ports: 7-Zip not found, cannot extract $($zips.Count) zip(s)"; return }
  $archive = Join-Path $dir '_zips'; New-Item -ItemType Directory -Force $archive | Out-Null
  foreach ($z in $zips) {
    $list = & $7z l -slt $z.FullName 2>$null | Where-Object { $_ -like 'Path = *' } | ForEach-Object { $_.Substring(7) }
    $sh = $list | Where-Object { $_ -match '^[^/\\]+\.sh$' }
    if (-not $sh) { L "  ports: $($z.Name) has no top-level .sh - not a PortMaster package, left as is"; continue }
    & $7z x -y -o"$dir" $z.FullName | Out-Null
    Move-Item $z.FullName (Join-Path $archive $z.Name) -Force
    L "  ports: extracted $($z.Name) -> $($sh -join ', ')"
  }
}

# ---------- gamelist.xml per system ----------
function Update-Gamelist([string]$dir, [string]$folder, [string[]]$ext) {
  $glPath = Join-Path $dir 'gamelist.xml'
  $old = @{}
  if (Test-Path $glPath) {
    try { $x = [xml](Get-Content $glPath -Raw); foreach ($g in $x.gameList.game) { if ($g.path) { $old[$g.path.Trim()] = $g } } }
    catch { L "  ${folder}: existing gamelist.xml unreadable, rebuilding ($($_.Exception.Message))" }
  }
  $files = Get-ChildItem $dir -File -Recurse | Where-Object {
    $rel = $_.FullName.Substring($dir.Length).TrimStart('\'); $top = ($rel -split '\\')[0]
    ($ext -contains $_.Extension.ToLower()) -and ($top -notin $artDirs) -and ($top -ne '_zips') -and ($rel -notmatch '\\cue\\')
  }
  # members of m3u playlists get hidden
  $hidden = @{}
  foreach ($m in ($files | Where-Object Extension -eq '.m3u')) {
    foreach ($line in (Get-Content $m.FullName | Where-Object { $_.Trim() })) { $p = Join-Path $m.DirectoryName $line.Trim(); $hidden[(Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue).Path] = $true }
  }
  $doc = New-Object Xml.XmlDocument
  $doc.AppendChild($doc.CreateXmlDeclaration('1.0', $null, $null)) | Out-Null
  $gl = $doc.AppendChild($doc.CreateElement('gameList'))
  $n = 0; $nh = 0; $nimg = 0
  foreach ($f in ($files | Sort-Object FullName)) {
    $rel = './' + ($f.FullName.Substring($dir.Length).TrimStart('\') -replace '\\','/')
    $isHidden = $hidden.ContainsKey($f.FullName)
    if ($old.ContainsKey($rel)) { $g = $doc.ImportNode($old[$rel], $true) }
    else {
      $g = $doc.CreateElement('game')
      $g.AppendChild($doc.CreateElement('path')).InnerText = $rel
      $name = if ($isHidden) { ($f.BaseName -replace '\s*\[[^\]]*\]','' -replace '\s*\((?!Disc)[^)]*\)','').Trim() } else { Clean-Name $f.BaseName }
      $g.AppendChild($doc.CreateElement('name')).InnerText = $name
    }
    # artwork: keep existing, else look for <basename>.png/.jpg in art folders or beside the file
    if (-not $g.SelectSingleNode('image') -or -not (Test-Path (Join-Path $dir ($g.image -replace '^\./','' -replace '/','\')))) {
      $cands = @()
      foreach ($a in $artDirs) { $cands += "$a\$($f.BaseName).png", "$a\$($f.BaseName).jpg" }
      $cands += "$($f.BaseName).png", "$($f.BaseName).jpg"
      foreach ($c in $cands) { if (Test-Path (Join-Path $dir $c)) { $node = $g.SelectSingleNode('image'); if (-not $node) { $node = $g.AppendChild($doc.CreateElement('image')) }; $node.InnerText = './' + ($c -replace '\\','/'); $nimg++; break } }
    }
    $hNode = $g.SelectSingleNode('hidden')
    if ($isHidden) { if (-not $hNode) { $hNode = $g.AppendChild($doc.CreateElement('hidden')) }; $hNode.InnerText = 'true'; $nh++ }
    elseif ($hNode) { $g.RemoveChild($hNode) | Out-Null }
    $gl.AppendChild($g) | Out-Null; $n++
  }
  if ($n -eq 0) { if (Test-Path $glPath) { Remove-Item $glPath }; return 0 }
  $ws = New-Object Xml.XmlWriterSettings; $ws.Indent = $true; $ws.Encoding = New-Object Text.UTF8Encoding($false)
  $w = [Xml.XmlWriter]::Create($glPath, $ws); $doc.Save($w); $w.Close()
  L "$folder ($($systems[$folder].Full)): $($n - $nh) games listed, $nh hidden playlist members, $nimg with artwork"
  return ($n - $nh)
}

# ---------- main ----------
$total = 0
foreach ($d in Get-ChildItem $root -Directory -Force | Where-Object { $_.Name -notin $support }) {
  $folder = $d.Name
  if (-not $systems.ContainsKey($folder)) {
    L "!! '$folder' is not a system folder this OS knows - games in it will never appear (see systems-cheatsheet.txt)"; continue
  }
  $ext = $systems[$folder].Ext
  if ($folder -eq 'psx' -and $PsxPrep) { Prep-Psx $d.FullName }
  if ($folder -eq 'ports') { Prep-Ports $d.FullName }
  # top-level files the OS will ignore (sidecar/save files are not reported)
  $sidecar = '^\.(png|jpg|xml|txt|md|old|srm|sav|state\d*|cfg|ini|opt|toml|json|dsv|ppst|sfo|at3|pmf|cache|log|m3u|nfo|dat)$'
  $ignored = Get-ChildItem $d.FullName -File | Where-Object { ($ext -notcontains $_.Extension.ToLower()) -and ($_.Name -ne 'gamelist.xml') -and ($_.Extension -notmatch $sidecar) }
  foreach ($i in $ignored) { L "  note: $folder\$($i.Name) - '$($i.Extension)' is not a $folder game extension, it will not appear (accepted: $($ext -join ' '))" }
  $total += Update-Gamelist $d.FullName $folder $ext
}
# ---------- launch images: if this folder ships a launchimages\ set, put it on the card ----------
$li = Join-Path $tools 'launchimages'
if (Test-Path $li) {
  $dst = Join-Path $root 'launchimages'; New-Item -ItemType Directory -Force $dst | Out-Null
  $n = 0
  foreach ($f in Get-ChildItem $li -File) {
    $target = Join-Path $dst $f.Name
    if (-not (Test-Path $target) -or (Get-FileHash $target -Algorithm MD5).Hash -ne (Get-FileHash $f.FullName -Algorithm MD5).Hash) { Copy-Item $f.FullName $target -Force; $n++ }
  }
  if ($n) { L "launchimages: $n file(s) updated on the card (DOGS launch flash)" } else { L "launchimages: already up to date" }
}
if (-not $KeepEmptyFolders) {
  foreach ($d in Get-ChildItem $root -Directory -Force | Where-Object { $_.Name -notin $support }) {
    if (-not (Get-ChildItem $d.FullName -Recurse -File -Force | Select-Object -First 1)) { Remove-Item $d.FullName -Recurse -Force; L "removed empty folder $($d.Name)" }
  }
}
L "DONE: $total games listed across all systems. Eject the card and boot."
