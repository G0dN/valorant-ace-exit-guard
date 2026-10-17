param([ValidateSet('Watch','IsolateNow','NotifyTest')][string]$Mode='Watch')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Guard.Core.ps1')
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-GuardNotice($Notice) {
    $script:Tray.Text = $Notice.title.Substring(0, [Math]::Min(63,$Notice.title.Length))
    $script:Tray.ShowBalloonTip(15000,$Notice.title,$Notice.text,[Windows.Forms.ToolTipIcon]::$($Notice.icon))
    Write-GuardLog 'NotificationRequested' $Notice
}
$script:Tray = [Windows.Forms.NotifyIcon]::new()
$script:Tray.Icon = [Drawing.SystemIcons]::Shield
$script:Tray.Text='无畏契约退出后ACE隔离'
$script:Tray.Visible=$true
$script:Tray.add_BalloonTipShown({ Write-GuardLog 'NotificationShown' @{pid=$PID} })
$script:Tray.add_BalloonTipClicked({ Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"' + (Join-Path $script:DataRoot 'events.jsonl') + '"') })
$menu=[Windows.Forms.ContextMenuStrip]::new()
$open=$menu.Items.Add('打开最近隔离记录')
$open.add_Click({ $path=Join-Path $script:DataRoot 'last_isolation.json'; if (Test-Path -LiteralPath $path) { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\notepad.exe') -ArgumentList ('"'+$path+'"') } })
$exitItem=$menu.Items.Add('退出守护（下次登录重新启动）')
$exitItem.add_Click({ [Windows.Forms.Application]::ExitThread() })
$script:Tray.ContextMenuStrip=$menu
$timer=$null; $mutex=$null; $ownsMutex=$false
try {
    if ($Mode -ne 'Watch') {
        if ($Mode -eq 'IsolateNow') { $result=Invoke-AceIsolation; $notice=Get-IsolationNotice $result }
        else { $notice=[pscustomobject]@{title='ACE守护通知测试';text='这是通知测试，未修改ACE服务或游戏进程。';icon='Info'} }
        Show-GuardNotice $notice
        $timer=[Windows.Forms.Timer]::new(); $timer.Interval=16000
        $timer.add_Tick({ [Windows.Forms.Application]::ExitThread() }); $timer.Start()
        [Windows.Forms.Application]::Run()
        if ($Mode -eq 'IsolateNow' -and $result.outcome -eq 'PartialFailure') { exit 2 }
        exit 0
    }
    Assert-GuardAdmin
    $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $mutex=[Threading.Mutex]::new($false,('Local\ValorantAceExitGuard_'+$sid))
    try { $ownsMutex=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
    if (-not $ownsMutex) { exit 0 }
    $script:StatePath=Join-Path $script:DataRoot 'watcher_state.json'
    $script:Armed=$false; $script:Deadline=$null; $script:LastReconcile=0
    if (Test-Path -LiteralPath $script:StatePath) {
        $old=Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        $script:Armed=[bool]$old.game_seen
    }
    $filter="ProcessName='VALORANT.exe' OR ProcessName='VALORANT-Win64-Shipping.exe'"
    Register-WmiEvent -Query ('SELECT * FROM Win32_ProcessStartTrace WHERE '+$filter) -SourceIdentifier 'AceGuard.GameStart' | Out-Null
    Register-WmiEvent -Query ('SELECT * FROM Win32_ProcessStopTrace WHERE '+$filter) -SourceIdentifier 'AceGuard.GameStop' | Out-Null
    $script:Armed=$script:Armed -or @(Get-ValorantProcesses).Count -gt 0
    Write-GuardLog 'WatcherStarted' @{pid=$PID; mode='WMI process start/stop events'; grace_seconds=30}
    Write-GuardJson @{pid=$PID; started_at=(Get-Date -Format o); game_seen=$script:Armed; phase='Watching'; last_result=$null} $script:StatePath
    Show-GuardNotice ([pscustomobject]@{title='ACE退出守护已启用';text='无畏契约全部退出30秒后，将禁用ACE后续启动并通知结果。';icon='Info'})
    $timer=[Windows.Forms.Timer]::new(); $timer.Interval=1000
    $timer.add_Tick({
        try {
            $events=@(Get-Event -ErrorAction SilentlyContinue | Where-Object { $_.SourceIdentifier -in @('AceGuard.GameStart','AceGuard.GameStop') })
            $sawStart=@($events | Where-Object SourceIdentifier -eq 'AceGuard.GameStart').Count -gt 0
            $sawStop=@($events | Where-Object SourceIdentifier -eq 'AceGuard.GameStop').Count -gt 0
            foreach ($event in $events) { Remove-Event -EventIdentifier $event.EventIdentifier }
            $now=[datetime]::UtcNow.Subtract([datetime]'1970-01-01').TotalSeconds
            if (-not $events.Count -and -not $script:Armed) { return }
            if (-not $events.Count -and $null -eq $script:Deadline -and $now-$script:LastReconcile -lt 15) { return }
            if (-not $events.Count -and $script:Deadline -gt $now) { return }
            $present=@(Get-ValorantProcesses).Count -gt 0
            $script:LastReconcile=$now
            $next=Get-GuardTransition -Armed $script:Armed -Deadline $script:Deadline -GamePresent $present -SawStart $sawStart -SawStop $sawStop -Now $now
            $script:Armed=$next.armed; $script:Deadline=$next.deadline
            if ($events.Count) { Write-GuardLog 'GameLifecycle' @{starts=$sawStart; stops=$sawStop; game_present=$present} }
            if ($next.isolate) {
                $timer.Stop()
                try {
                    $result=Invoke-AceIsolation
                    Show-GuardNotice (Get-IsolationNotice $result)
                    if ($result.outcome -notin @('GameRunning','GameRestarted','Busy')) { $script:Armed=$false; $script:Deadline=$null }
                    else { $script:Deadline=$now+30 }
                    Write-GuardJson @{pid=$PID; game_seen=$script:Armed; phase='Watching'; last_result=$result; updated_at=(Get-Date -Format o)} $script:StatePath
                } finally { $timer.Start() }
            } elseif ($events.Count) {
                Write-GuardJson @{pid=$PID; game_seen=$script:Armed; phase='Watching'; exit_deadline=$script:Deadline; updated_at=(Get-Date -Format o)} $script:StatePath
            }
        } catch {
            Write-GuardLog 'WatcherError' @{error=$_.Exception.Message}
            Show-GuardNotice ([pscustomobject]@{title='ACE守护发生错误';text='自动隔离未能确认完成，请检查日志；没有强制停止游戏或驱动。';icon='Error'})
            $script:Armed=$false; $script:Deadline=$null
        }
    })
    # A recovered game session may already have ended while the watcher was absent.
    if ($script:Armed -and -not @(Get-ValorantProcesses).Count) {
        $script:Deadline=[datetime]::UtcNow.Subtract([datetime]'1970-01-01').TotalSeconds+30
    }
    $timer.Start()
    Write-GuardJson @{pid=$PID; ready_at=(Get-Date -Format o); phase='Ready'; admin=$true; subscriptions=@('AceGuard.GameStart','AceGuard.GameStop')} (Join-Path $script:DataRoot 'watcher_ready.json')
    [Windows.Forms.Application]::Run()
} catch {
    Write-GuardLog 'FatalError' @{error=$_.Exception.Message}
    throw
} finally {
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    foreach ($id in @('AceGuard.GameStart','AceGuard.GameStop')) {
        Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue
        Get-Event -SourceIdentifier $id -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
    }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    if ($mutex) { $mutex.Dispose() }
    $script:Tray.Visible=$false; $script:Tray.Dispose(); $menu.Dispose()
}
