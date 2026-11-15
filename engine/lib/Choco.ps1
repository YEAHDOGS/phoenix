# Phoenix engine: `choco-search` - community feed search with offline catalog fallback.
# Returns an array of @{ id; title; version; summary; downloads; source = online|catalog }.

function Search-PhxChocoCatalog([string]$Query) {
    $p = Join-Path (Get-PhxKitRoot) 'catalog\apps.json'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $cat = Read-PhxJson $p
    $list = if ($cat -is [System.Collections.IDictionary] -and $cat.Contains('apps')) { @($cat['apps']) } else { @($cat) }
    $q = $Query.ToLower()
    @($list | Where-Object {
            -not $q -or ([string]$_['id']).ToLower().Contains($q) -or ([string]$_['name']).ToLower().Contains($q) -or ([string]$_['description']).ToLower().Contains($q) -or ([string]$_['category']).ToLower().Contains($q)
        } | ForEach-Object {
            [ordered]@{ id = $_['id']; title = $(if ($_['name']) { $_['name'] } else { $_['id'] }); version = $_['version']; summary = $_['description']; downloads = $null; category = $_['category']; source = 'catalog' }
        })
}

function Invoke-PhxChocoSearch([hashtable]$A) {
    $q = ([string]$A['query']).Trim()
    $top = if ($A['top']) { [int]$A['top'] } else { 30 }
    if ($q -and -not $A['offline']) {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072
            $term = [Uri]::EscapeDataString("'" + $q.Replace("'", "''") + "'")
            $url = "https://community.chocolatey.org/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=$term&targetFramework=%27%27&includePrerelease=false&`$top=$top"
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Phoenix' } -ErrorAction Stop
            [xml]$x = $resp.Content
            $ns = New-Object Xml.XmlNamespaceManager $x.NameTable
            $ns.AddNamespace('a', 'http://www.w3.org/2005/Atom')
            $ns.AddNamespace('m', 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata')
            $ns.AddNamespace('d', 'http://schemas.microsoft.com/ado/2007/08/dataservices')
            $res = foreach ($e in $x.SelectNodes('//a:entry', $ns)) {
                $p = $e.SelectSingleNode('m:properties', $ns)
                $get = { param($n) $node = $p.SelectSingleNode("d:$n", $ns); if ($node) { $node.InnerText } else { $null } }
                $id = & $get 'Id'
                if (-not $id) { $id = $e.SelectSingleNode('a:title', $ns).InnerText }
                $dl = & $get 'DownloadCount'
                [ordered]@{
                    id = $id; title = $(& $get 'Title'); version = $(& $get 'Version')
                    summary = $(if (& $get 'Summary') { & $get 'Summary' } else { $d = & $get 'Description'; if ($d -and $d.Length -gt 240) { $d.Substring(0, 240) + '...' } else { $d } })
                    downloads = $(if ($dl) { [int64]$dl } else { $null })
                    tags = $(& $get 'Tags'); projectUrl = $(& $get 'ProjectUrl'); source = 'online'
                }
            }
            return , @($res)
        } catch {
            Write-PhxLog -Level warn -Msg "Chocolatey community feed unreachable ($($_.Exception.Message)); searching the offline catalog."
        }
    }
    , @(Search-PhxChocoCatalog $q | Select-Object -First $top)
}
