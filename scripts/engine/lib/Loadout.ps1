# Phoenix engine: loadout (commands: loadout, fetch).
# Downloads the software the Phoenix USB carries, verifies it, and records a
# SHA-512 trust-on-first-use lock in %LOCALAPPDATA%\Phoenix\cache\lock.json.
#
# On a built kit, every item lives at <kit>\config\loadout\<id>\ : zips are extracted
# there, files and nupkgs are copied there under their manifest filename.

function Get-PhxLoadoutManifest {
    $p = Join-Path (Get-PhxLoadoutRoot) 'manifest.json'
    if (-not (Test-Path -LiteralPath $p)) { throw "Loadout manifest not found: $p" }
    Read-PhxJson $p
}

function Get-PhxLoadoutItem([string]$Id) {
    $item = @((Get-PhxLoadoutManifest)['items']) | Where-Object { $_['id'] -eq $Id } | Select-Object -First 1
    if (-not $item) { throw "Unknown loadout item '$Id'." }
    $item
}

function Get-PhxLockPath { Join-Path (Get-PhxCacheRoot) 'lock.json' }

function Get-PhxLoadoutLock {
    $p = Get-PhxLockPath
    if (Test-Path -LiteralPath $p) {
        $l = Read-PhxJson $p
        if (-not $l['items']) { $l['items'] = @{} }
        return $l
    }
    @{ version = 1; items = @{} }
}

function Save-PhxLoadoutLock([hashtable]$Lock) { Write-PhxJson (Get-PhxLockPath) $Lock }

# Path of the cached file for an item (external user files live where the user keeps them).
function Get-PhxCachedFile([hashtable]$Item, $Entry) {
    if ($Entry -and $Entry['external']) { return [string]$Entry['external'] }
    Join-Path (Join-Path (Get-PhxCacheRoot) $Item['id']) $Item['filename']
}

function Enable-PhxTls {
    try {
        $p = [Net.SecurityProtocolType]::Tls12
        try { $p = $p -bor [Net.SecurityProtocolType]'Tls13' } catch { }
        [Net.ServicePointManager]::SecurityProtocol = $p
    } catch { }
}

function Get-PhxHttpHeaders { @{ 'User-Agent' = 'phoenix-engine'; 'Accept' = 'application/vnd.github+json' } }

# Returns @{ url; version } for an item.
function Resolve-PhxLoadoutSource([hashtable]$Item) {
    if ($Item['githubRelease']) {
        $gr = $Item['githubRelease']
        $rel = Invoke-RestMethod -UseBasicParsing -Headers (Get-PhxHttpHeaders) -Uri "https://api.github.com/repos/$($gr['repo'])/releases/latest" -TimeoutSec 30
        $asset = @($rel.assets) | Where-Object { $_.name -match $gr['asset'] } | Select-Object -First 1
        if (-not $asset) { throw "No asset matching '$($gr['asset'])' in $($gr['repo']) release $($rel.tag_name)." }
        return @{ url = $asset.browser_download_url; version = [string]$rel.tag_name; assetName = $asset.name }
    }
    if ($Item['url']) { return @{ url = [string]$Item['url']; version = '' } }
    throw "Loadout item '$($Item['id'])' has no download source."
}

function Save-PhxDownload([string]$Url, [string]$Dest, [string]$StepId) {
    Enable-PhxTls
    $tmp = "$Dest.partial"
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'phoenix-engine'
    $req.AllowAutoRedirect = $true
    $req.Timeout = 60000
    $req.ReadWriteTimeout = 120000
    $resp = $req.GetResponse()
    try {
        $total = $resp.ContentLength
        $finalUrl = $resp.ResponseUri.AbsoluteUri
        $in = $resp.GetResponseStream()
        $out = [IO.File]::Create($tmp)
        try {
            $buf = New-Object byte[] (1MB)
            $done = 0L; $lastPct = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n)
                $done += $n
                if ($total -gt 0) {
                    $pct = [int](($done * 100) / $total)
                    if ($pct -ge $lastPct + 2) { Write-PhxProgress -Step $StepId -Pct $pct -Msg ('{0:N1} / {1:N1} MB' -f ($done / 1MB), ($total / 1MB)); $lastPct = $pct }
                }
            }
        } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Close() }
    if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Force }
    Move-Item -LiteralPath $tmp -Destination $Dest
    $finalUrl
}

# Authenticode check. For a zip, checks the item's launch exe inside it.
function Test-PhxLoadoutSignature([hashtable]$Item, [string]$File) {
    $signer = [string]$Item['signer']
    if (-not $signer) { return @{ status = 'not-checked' } }
    $target = $File
    $tmpDir = $null
    if ($Item['kind'] -eq 'zip') {
        if (-not $Item['launch']) { return @{ status = 'not-checked' } }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($File)
        try {
            $want = ([string]$Item['launch']) -replace '\\', '/'
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $want -or $_.FullName -like "*/$want" } | Select-Object -First 1
            if (-not $entry) { return @{ status = 'not-checked'; note = "launch file $want not in zip" } }
            $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('phx-sig-' + [guid]::NewGuid())
            New-Item -ItemType Directory -Path $tmpDir | Out-Null
            $target = Join-Path $tmpDir ([IO.Path]::GetFileName($entry.FullName))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        } finally { $zip.Dispose() }
    } elseif ($File -notmatch '\.(exe|msi|dll|sys)$') {
        return @{ status = 'not-checked' }
    }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $target
        $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { '' }
        $ok = ($sig.Status -eq 'Valid') -and ($subject -like "*$signer*")
        @{ status = if ($ok) { 'valid' } else { 'invalid' }; signer = $subject; detail = [string]$sig.Status }
    } finally {
        if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# command: loadout
function Invoke-PhxLoadout([hashtable]$A) {
    $manifest = Get-PhxLoadoutManifest
    $lock = Get-PhxLoadoutLock
    $items = foreach ($it in @($manifest['items'])) {
        $e = $lock['items'][$it['id']]
        $file = Get-PhxCachedFile $it $e
        $cached = [bool]($e -and (Test-Path -LiteralPath $file))
        [ordered]@{
            id          = $it['id']
            name        = $it['name']
            category    = $it['category']
            description = $it['description']
            kind        = $it['kind']
            source      = if ($it['source']) { $it['source'] } elseif ($it['githubRelease']) { 'github-release' } else { 'url' }
            userFile    = ($it['source'] -eq 'user-file')
            optional    = [bool]$it['optional']
            homepage    = $it['homepage']
            license     = $it['license']
            cached      = $cached
            file        = if ($cached) { $file } else { $null }
            version     = if ($e) { $e['version'] } else { $null }
            sha512      = if ($e) { $e['sha512'] } else { $null }
            sizeBytes   = if ($e) { $e['sizeBytes'] } else { $null }
            fetchedAt   = if ($e) { $e['fetchedAt'] } else { $null }
            signature   = if ($e) { $e['signature'] } else { $null }
        }
    }
    [ordered]@{ cacheRoot = (Get-PhxCacheRoot); items = @($items) }
}

# command: fetch { items: [ids], force?: bool, files?: { id: "C:\path\to\user-file" } }
function Invoke-PhxFetch([hashtable]$A) {
    $ids = @($A['items'])
    if (-not $ids -or -not $ids[0]) { throw 'fetch needs items: [ids].' }
    $force = [bool]$A['force']
    $files = if ($A['files']) { $A['files'] } else { @{} }
    $lock = Get-PhxLoadoutLock
    $results = New-Object System.Collections.Generic.List[object]

    foreach ($id in $ids) {
        $stepId = "fetch.$id"
        Write-PhxStep -Step $stepId -Status start -Msg "Fetching $id"
        try {
            $item = Get-PhxLoadoutItem $id
            $prev = $lock['items'][$id]
            $userFile = if ($files.Contains($id)) { [string]$files[$id] } else { $null }

            if (-not $force -and -not $userFile -and $prev -and (Test-Path -LiteralPath (Get-PhxCachedFile $item $prev))) {
                Write-PhxStep -Step $stepId -Status skip -Msg 'Already cached (pass force to re-download).'
                $results.Add([ordered]@{ id = $id; ok = $true; skipped = $true; file = (Get-PhxCachedFile $item $prev); sha512 = $prev['sha512'] })
                continue
            }

            $entry = [ordered]@{ fetchedAt = (Get-Date).ToUniversalTime().ToString('s') + 'Z' }
            if ($userFile) {
                if (-not (Test-Path -LiteralPath $userFile -PathType Leaf)) { throw "File not found: $userFile" }
                $file = (Resolve-Path -LiteralPath $userFile).Path
                $entry['external'] = $file
                $entry['source'] = 'user-file'
                $entry['version'] = (Get-Item -LiteralPath $file).LastWriteTimeUtc.ToString('yyyy-MM-dd')
                Write-PhxLog "Hashing $file (large files take a while)."
            } else {
                try {
                    $src = Resolve-PhxLoadoutSource $item
                } catch {
                    if ($item['source'] -eq 'user-file') { throw "No download available for '$id' ($($_.Exception.Message)). Pick the file instead." }
                    throw
                }
                $dir = Join-Path (Get-PhxCacheRoot) $id
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                $file = Join-Path $dir $item['filename']
                Write-PhxLog "Downloading $($src['url'])"
                $final = Save-PhxDownload -Url $src['url'] -Dest $file -StepId $stepId
                $entry['url'] = $final
                $entry['source'] = if ($item['githubRelease']) { 'github-release' } else { 'url' }
                $entry['version'] = $src['version']
                if (-not $entry['version']) {
                    $vm = [regex]::Match($final, '(\d+\.\d+(\.\d+){0,2})')
                    $entry['version'] = if ($vm.Success) { $vm.Value } else { $entry['fetchedAt'].Substring(0, 10) }
                }
            }

            $entry['sizeBytes'] = (Get-Item -LiteralPath $file).Length
            $entry['sha512'] = Get-PhxSha $file 'SHA512'
            $sig = Test-PhxLoadoutSignature $item $file
            $entry['signature'] = $sig
            if ($sig['status'] -eq 'invalid') {
                if (-not $userFile) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
                throw "Signature check failed for ${id}: expected signer '$($item['signer'])', got '$($sig['signer'])' ($($sig['detail']))."
            }
            if ($prev -and $prev['sha512'] -and $prev['version'] -eq $entry['version'] -and $prev['sha512'] -ne $entry['sha512']) {
                Write-PhxLog -Level warn -Msg "$id changed content without changing version ($($entry['version'])). Previous SHA-512 $($prev['sha512'].Substring(0,16))..., now $($entry['sha512'].Substring(0,16))...."
            }
            $lock['items'][$id] = $entry
            Save-PhxLoadoutLock $lock
            Write-PhxStep -Step $stepId -Status ok -Msg ("{0} {1:N1} MB, signature {2}" -f $entry['version'], ($entry['sizeBytes'] / 1MB), $sig['status'])
            $results.Add([ordered]@{ id = $id; ok = $true; file = $file; version = $entry['version']; sha512 = $entry['sha512']; sizeBytes = $entry['sizeBytes']; signature = $sig['status'] })
        } catch {
            Write-PhxStep -Step $stepId -Status fail -Msg $_.Exception.Message
            $results.Add([ordered]@{ id = $id; ok = $false; error = $_.Exception.Message })
        }
    }
    $failed = @($results | Where-Object { -not $_['ok'] })
    [ordered]@{ items = $results.ToArray(); failed = $failed.Count }
}
