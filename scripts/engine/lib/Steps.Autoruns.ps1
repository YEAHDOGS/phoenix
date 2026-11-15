# Phoenix engine: `autoruns` step kind (logon category).
#
# Disabling uses the Sysinternals Autoruns convention, so Autoruns itself shows
# the entries as disabled and can re-enable them:
#   registry Run/RunOnce value  -> moved to <key>\AutorunsDisabled
#   Startup folder item         -> moved to <Startup folder>\AutorunsDisabled\

$script:PhxAutorunKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'
)
# Never disabled unless an item explicitly says action: disable.
$script:PhxAutorunKeep = @('SecurityHealth', 'ctfmon', 'Phoenix*')

function Get-PhxStartupFolders {
    @(
        (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'),
        (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
}

# Logon autorun entries currently enabled: @{ name; location; kind = reg|file; path; value }
function Get-PhxAutorunEntries {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($k in $script:PhxAutorunKeys) {
        $rp = ConvertTo-PhxRegPath $k
        try {
            $key = Get-Item -LiteralPath $rp -ErrorAction Stop
            foreach ($n in $key.GetValueNames()) {
                if (-not $n) { continue }
                $out.Add(@{ name = $n; location = $k; kind = 'reg'; path = $rp; value = [string]$key.GetValue($n, $null, 'DoNotExpandEnvironmentNames'); valueKind = [string]$key.GetValueKind($n) })
            }
        } catch { }
    }
    foreach ($f in (Get-PhxStartupFolders)) {
        foreach ($i in @(Get-ChildItem -LiteralPath $f -File -Force -ErrorAction SilentlyContinue)) {
            if ($i.Name -ieq 'desktop.ini') { continue }
            $out.Add(@{ name = $i.Name; location = $f; kind = 'file'; path = $i.FullName; value = $i.FullName })
        }
    }
    , @($out.ToArray())
}

function Disable-PhxAutorunEntry($E) {
    if ($E.kind -eq 'reg') {
        $dis = $E.path + '\AutorunsDisabled'
        if (-not (Test-Path -LiteralPath $dis)) { New-Item -Path $dis -Force -ErrorAction Stop | Out-Null }
        $kind = if ($E.valueKind) { $E.valueKind } else { 'String' }
        New-ItemProperty -LiteralPath $dis -Name $E.name -PropertyType $kind -Value $E.value -Force -ErrorAction Stop | Out-Null
        Remove-ItemProperty -LiteralPath $E.path -Name $E.name -Force -ErrorAction Stop
        Add-PhxSnapshotRecord autoruns ([ordered]@{ kind = 'reg'; name = $E.name; from = $E.path; to = $dis; valueKind = $kind; value = $E.value })
    } else {
        $disDir = Join-Path $E.location 'AutorunsDisabled'
        if (-not (Test-Path -LiteralPath $disDir)) { New-Item -ItemType Directory -Force -Path $disDir -ErrorAction Stop | Out-Null }
        $dest = Join-Path $disDir $E.name
        Move-Item -LiteralPath $E.path -Destination $dest -Force -ErrorAction Stop
        Add-PhxSnapshotRecord autoruns ([ordered]@{ kind = 'file'; name = $E.name; from = $E.path; to = $dest })
    }
}

function Restore-PhxAutorunRecord($R) {
    if ($R['kind'] -eq 'reg') {
        New-ItemProperty -LiteralPath $R['from'] -Name $R['name'] -PropertyType ([string]$R['valueKind']) -Value $R['value'] -Force -ErrorAction Stop | Out-Null
        Remove-ItemProperty -LiteralPath $R['to'] -Name $R['name'] -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $R['to'] -Destination $R['from'] -Force -ErrorAction Stop
    }
}

function Invoke-PhxStep_autoruns {
    param([hashtable]$Step, [hashtable]$Ctx)
    $sid = [string]$Step['id']
    $cats = @(Get-PhxField $Step 'categories' @('logon'))
    if ($cats -notcontains 'logon') {
        Write-PhxLog -Level warn -Msg "autoruns step '$sid': only the 'logon' category is automated; other categories are handled by the services/tasks/devices steps."
        return
    }
    $items = Get-PhxEnabledItems $Step
    $keep = @($script:PhxAutorunKeep) + @(Get-PhxField $Step 'keep' @()) + @($items | Where-Object { $_['action'] -eq 'keep' } | ForEach-Object { [string]$_['name'] })
    $forced = @($items | Where-Object { (Get-PhxField $_ 'action' 'disable') -eq 'disable' } | ForEach-Object { [string]$_['name'] })
    $disableAll = [bool](Get-PhxField $Step 'disableAll' $true)

    if (-not $Ctx.IsAdmin) { Write-PhxLog -Level warn -Msg "autoruns: HKCU entries shown are for '$env:USERNAME' only." }
    foreach ($e in (Get-PhxAutorunEntries)) {
        $label = "$($e.name) [$($e.location)]"
        $isForced = [bool]($forced | Where-Object { $e.name -like $_ } | Select-Object -First 1)
        $keptBy = $keep | Where-Object { $e.name -like $_ } | Select-Object -First 1
        if (($keptBy -and -not $isForced) -or (-not $disableAll -and -not $isForced)) {
            $why = if ($keptBy) { "kept ($keptBy)" } else { 'not listed' }
            Write-PhxChange -Step $sid -Key $label -Current 'enabled' -Target 'enabled' -Action skip -Msg $why
            $Ctx.Stats.skipped++
            continue
        }
        $entry = $e
        Invoke-PhxChange -Ctx $Ctx -Step $sid -Key $label -Current 'enabled' -Target 'disabled' -Action disable -Msg ([string]$e.value) -Do {
            Disable-PhxAutorunEntry $entry
        }
    }
}
