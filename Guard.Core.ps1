$script:GuardRoot = $PSScriptRoot
$script:DataRoot = Join-Path $script:GuardRoot 'data'
[void][IO.Directory]::CreateDirectory($script:DataRoot)
$script:GameNames = @('VALORANT', 'VALORANT-Win64-Shipping')

function Write-GuardJson($Value, [string]$Path) {
    $temporary = $Path + '.tmp'
    ConvertTo-Json -InputObject $Value -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Write-GuardLog([string]$Kind, $Details) {
    $path = Join-Path $script:DataRoot 'events.jsonl'
    if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 5MB) {
        Move-Item -LiteralPath $path -Destination ($path + '.previous') -Force
    }
    [ordered]@{time=(Get-Date -Format o); kind=$Kind; details=$Details} |
        ConvertTo-Json -Depth 10 -Compress | Add-Content -LiteralPath $path -Encoding UTF8
}
function Assert-GuardAdmin {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Administrator rights are required. Use Manage-Guard.ps1 -Action Install.'
    }
}
function Get-ValorantProcesses {
    @(Get-Process -Name $script:GameNames -ErrorAction SilentlyContinue)
}
function Resolve-AceImage([string]$ImagePath) {
    $expanded = [Environment]::ExpandEnvironmentVariables($ImagePath.Trim())
    if ($expanded -match '^"([^"]+)"') { $expanded = $Matches[1] }
    elseif ($expanded -match '^(.+?\.(?:sys|exe))(?:\s|$)') { $expanded = $Matches[1] }
    else { return $null }
    if ($expanded.StartsWith('\??\')) { $expanded = $expanded.Substring(4) }
    if ($expanded.StartsWith('\SystemRoot\', [StringComparison]::OrdinalIgnoreCase)) {
        $expanded = Join-Path $env:SystemRoot $expanded.Substring(12)
    }
    try { [IO.Path]::GetFullPath($expanded) } catch { $null }
}
function Test-AceTarget([string]$Name, [string]$ImagePath) {
    if ($Name -notmatch '^(?:ACE-[A-Za-z0-9_.-]+|AntiCheatExpert (?:Protection|Service))$') { return $false }
    $resolved = Resolve-AceImage $ImagePath
    if (-not $resolved) { return $false }
    $aceRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'AntiCheatExpert')) + '\'
    $driverRoot = [IO.Path]::GetFullPath((Join-Path $env:SystemRoot 'System32\drivers')) + '\'
    if ($resolved.StartsWith($aceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return [IO.Path]::GetExtension($resolved) -in @('.sys','.exe')
    }
    return ($resolved.StartsWith($driverRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetDirectoryName($resolved) -eq $driverRoot.TrimEnd('\') -and
        [IO.Path]::GetFileName($resolved) -match '^ACE-[A-Za-z0-9_.-]+\.sys$')
}
function Get-AceInventory {
    foreach ($key in Get-ChildItem -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services') {
        if ($key.PSChildName -notmatch '^(?:ACE-[A-Za-z0-9_.-]+|AntiCheatExpert (?:Protection|Service))$') { continue }
        $values = Get-ItemProperty -LiteralPath $key.PSPath
        $query = @(& "$env:SystemRoot\System32\sc.exe" query $key.PSChildName 2>&1)
        $queryExit = $LASTEXITCODE
        $state = 'Unknown'
        if ($queryExit -eq 0 -and ($query -join "`n") -match 'STATE\s+:\s+(\d+)') {
            $state = if ([int]$Matches[1] -eq 1) { 'Stopped' } else { 'Active' }
        }
        [pscustomobject]@{
            name=$key.PSChildName; start=[int]$values.Start; image_path=[string]$values.ImagePath
            allowed=(Test-AceTarget $key.PSChildName ([string]$values.ImagePath))
            state=$state; query_exit=$queryExit
        }
    }
}
function Get-GuardTransition([bool]$Armed, [Nullable[double]]$Deadline, [bool]$GamePresent,
    [bool]$SawStart, [bool]$SawStop, [double]$Now, [int]$GraceSeconds=30) {
    if ($GamePresent -or $SawStart) {
        # A queued stop after a very short start still needs a grace period.
        $newDeadline = if (-not $GamePresent -and $SawStop) { $Now + $GraceSeconds } else { $null }
        return [pscustomobject]@{armed=$true; deadline=$newDeadline; isolate=$false}
    }
    if ($Armed -and $null -eq $Deadline) { $Deadline = $Now + $GraceSeconds }
    [pscustomobject]@{armed=$Armed; deadline=$Deadline; isolate=($Armed -and $null -ne $Deadline -and $Now -ge $Deadline)}
}
function Invoke-AceIsolation {
    Assert-GuardAdmin
    $result = [ordered]@{
        time=(Get-Date -Format o); outcome='Pending'; before=@(); after=@(); disabled_count=0
        active_count=0; unknown_count=0; errors=@(); rebooted=$false; driver_unload_attempted=$false
        process_stop_attempted=$false; experiment_processes_touched=$false
    }
    if (@(Get-ValorantProcesses).Count) { $result.outcome='GameRunning'; return [pscustomobject]$result }
    $mutex = [Threading.Mutex]::new($false, 'Local\ValorantAceIsolation')
    $ownsMutex = $false
    try {
        try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
        if (-not $ownsMutex) { $result.outcome='Busy'; return [pscustomobject]$result }
        $result.before = @(Get-AceInventory)
        $ledgerPath = Join-Path $script:DataRoot 'original_start_values.json'
        $ledger = [pscustomobject]@{created_at=(Get-Date -Format o); entries=@()}
        if (Test-Path -LiteralPath $ledgerPath) { $ledger = Get-Content -LiteralPath $ledgerPath -Raw | ConvertFrom-Json }
        foreach ($entry in $result.before) {
            if (-not $entry.allowed) { $result.errors += ('Skipped unrecognized image path: ' + $entry.name); continue }
            if (-not @($ledger.entries | Where-Object { $_.name -eq $entry.name -and $_.image_path -eq $entry.image_path }).Count) {
                $ledger.entries = @($ledger.entries) + $entry
            }
        }
        # Save before any mutation; preserve every first-seen entry and existing backups.
        Write-GuardJson $ledger $ledgerPath
        if (-not $result.before.Count) { $result.errors += 'No ACE entries found.' }
        foreach ($entry in $result.before) {
            if (-not $entry.allowed) { continue }
            if (@(Get-ValorantProcesses).Count) { $result.outcome='GameRestarted'; break }
            try {
                $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\' + $entry.name
                $current = Get-ItemProperty -LiteralPath $keyPath
                if ($current.ImagePath -ne $entry.image_path) { throw 'Image path changed during operation.' }
                if ([int]$current.Start -ne 4) {
                    $output = @(& "$env:SystemRoot\System32\sc.exe" config $entry.name 'start=' 'disabled' 2>&1)
                    if ($LASTEXITCODE -ne 0) { throw ($output -join ' ') }
                }
                if ((Get-ItemProperty -LiteralPath $keyPath).Start -ne 4) { throw 'Disabled value readback failed.' }
            } catch { $result.errors += ($entry.name + ': ' + $_.Exception.Message) }
        }
        $result.after = @(Get-AceInventory)
        foreach ($entry in $result.before) {
            $post = @($result.after | Where-Object { $_.name -eq $entry.name })
            if ($post.Count -ne 1 -or $post[0].image_path -ne $entry.image_path -or -not $post[0].allowed) {
                $result.errors += ('ACE identity missing or changed during verification: ' + $entry.name)
            }
        }
        foreach ($entry in $result.after) {
            if (-not $entry.allowed) { $result.errors += ('Unrecognized post-change ACE image: ' + $entry.name) }
            elseif (-not @($result.before | Where-Object { $_.name -eq $entry.name -and $_.image_path -eq $entry.image_path }).Count) {
                $result.errors += ('ACE entry appeared during verification; not isolated this run: ' + $entry.name)
            }
        }
        $result.disabled_count = @($result.after | Where-Object { $_.allowed -and $_.start -eq 4 }).Count
        $result.active_count = @($result.after | Where-Object { $_.allowed -and $_.state -eq 'Active' }).Count
        $result.unknown_count = @($result.after | Where-Object { $_.allowed -and $_.state -eq 'Unknown' }).Count
        if ($result.outcome -ne 'GameRestarted') {
            if (@(Get-ValorantProcesses).Count) { $result.outcome='GameRestarted' }
        }
        if ($result.outcome -ne 'GameRestarted') {
            if (@($result.after | Where-Object { $_.allowed -and $_.start -ne 4 }).Count) { $result.errors += 'Some ACE entries are not disabled.' }
            if ($result.disabled_count -lt 1) { $result.errors += 'No ACE entry was verified disabled.' }
            $result.outcome = if ($result.errors.Count) { 'PartialFailure' } else { 'Disabled' }
        }
        $object = [pscustomobject]$result
        Write-GuardJson $object (Join-Path $script:DataRoot 'last_isolation.json')
        Write-GuardJson $object (Join-Path $script:DataRoot ('isolation_' + (Get-Date -Format 'yyyyMMddTHHmmssfff') + '.json'))
        Write-GuardLog 'IsolationCompleted' $object
        return $object
    } finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
function Get-IsolationNotice($Result) {
    if ($Result.outcome -eq 'Disabled') {
        if ($Result.active_count -or $Result.unknown_count) {
            return [pscustomobject]@{title='ACE后续启动已禁用'; text=('已核验{0}项禁用；仍运行{1}项、状态未知{2}项。未卸载驱动。' -f $Result.disabled_count,$Result.active_count,$Result.unknown_count); icon='Warning'}
        }
        return [pscustomobject]@{title='ACE已禁用'; text=('已核验{0}项禁用，已识别组件均停止。记录已保存。' -f $Result.disabled_count); icon='Info'}
    }
    if ($Result.outcome -in @('GameRunning','GameRestarted','Busy')) {
        return [pscustomobject]@{title='ACE隔离已暂缓'; text='游戏正在运行、重新启动，或另一次隔离尚未结束。'; icon='Warning'}
    }
    [pscustomobject]@{title='ACE隔离未完全成功'; text=('已禁用{0}项，但存在权限或状态错误；请查看托盘菜单中的日志。' -f $Result.disabled_count); icon='Error'}
}
