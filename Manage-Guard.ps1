param([ValidateSet('Install','Update','Uninstall','Status')][string]$Action='Status')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Guard.Core.ps1')
$taskName='Valorant.AceExitGuard'
$runtimeRoot=Join-Path $PSScriptRoot '.runtime'
$runtimeData=Join-Path $runtimeRoot 'data'
$receiptPath=Join-Path $script:DataRoot ('management_'+$Action.ToLower()+'_'+(Get-Date -Format 'yyyyMMddTHHmmssfff')+'.json')
$pins=$null
function New-ProtectedRuntime([string]$Directory,[string]$UserSid) {
    if (Test-Path -LiteralPath $Directory) { throw 'Runtime directory already exists; inspect before reinstalling.' }
    $acl=[Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true,$false)
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    foreach($sid in @('S-1-5-32-544','S-1-5-18')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl',$inherit,'None','Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($UserSid),'ReadAndExecute',$inherit,'None','Allow'))
    [IO.Directory]::CreateDirectory($Directory,$acl) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $Directory 'data'),$acl) | Out-Null
}
try {
    if ($Action -eq 'Status') {
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        [pscustomobject]@{task_name=$taskName; installed=($null -ne $task); state=if($task){[string]$task.State}else{'Absent'}; data_directory=$runtimeData} | ConvertTo-Json
        exit 0
    }
    Assert-GuardAdmin
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell 5.1 for installation and management.' }
    if ($Action -eq 'Uninstall') {
        $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($task) {
            if ($task.Actions.Arguments.IndexOf((Join-Path $runtimeRoot 'Watch-Ace.ps1').Replace("'","''"),[StringComparison]::OrdinalIgnoreCase) -lt 0) { throw 'Task action is not the expected guard; refusing to remove.' }
            Stop-ScheduledTask -TaskName $taskName
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
        Write-GuardJson @{action=$Action; success=$true; ace_start_values_restored=$false; evidence_preserved=$true} $receiptPath
        exit 0
    }
    $existingTask=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($Action -eq 'Install' -and $existingTask) { throw 'Task already exists; inspect it before replacing.' }
    if ($Action -eq 'Update' -and (-not $existingTask -or $existingTask.Actions.Arguments.IndexOf((Join-Path $runtimeRoot 'Watch-Ace.ps1').Replace("'","''"),[StringComparison]::OrdinalIgnoreCase) -lt 0)) { throw 'Update requires the existing managed task.' }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    $user=$identity.Name; $sid=$identity.User.Value
    $psExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-Guard.ps1') -RunEventProbe
    if ($LASTEXITCODE -ne 0) { throw 'Pre-install state-machine or real WMI event test failed.' }
    if ($Action -eq 'Install') { New-ProtectedRuntime $runtimeRoot $sid }
    else {
        Stop-ScheduledTask -TaskName $taskName
        $stopDeadline=(Get-Date).AddSeconds(5)
        while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running') {
            if ((Get-Date) -ge $stopDeadline) { throw 'Existing guard did not stop for update.' }
            Start-Sleep -Milliseconds 100
        }
    }
    . (Join-Path $PSScriptRoot 'Runtime.Security.ps1')
    $pins=Lock-GuardDataPath $runtimeData
    foreach($name in @('Guard.Core.ps1','Watch-Ace.ps1')) {
        $destination=Join-Path $runtimeRoot $name
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $destination
        $acl=Get-Acl -LiteralPath $destination
        $acl.SetAccessRuleProtection($false,$true)
        foreach($rule in @($acl.Access | Where-Object { -not $_.IsInherited })) { [void]$acl.RemoveAccessRuleSpecific($rule) }
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        Set-Acl -LiteralPath $destination -AclObject $acl
    }
    $script:DataRoot=$runtimeData
    $receiptPath=Join-Path $runtimeData ('management_'+$Action.ToLower()+'_'+(Get-Date -Format 'yyyyMMddTHHmmssfff')+'.json')
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'data\test_results.json') -Destination (Join-Path $runtimeData 'pre_install_test_results.json')
    $runtimeWatch=Join-Path $runtimeRoot 'Watch-Ace.ps1'
    $security=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Runtime.Security.ps1'))
    # The task definition holds this transparent bootstrap. Pin/check the path before loading any runtime code.
    $bootstrap='$ErrorActionPreference=''Stop''; '+"`n"+$security+"`n"+'$pins=Lock-GuardDataPath '''+$runtimeData.Replace("'","''")+'''; try { & '''+$runtimeWatch.Replace("'","''")+''' -Mode Watch } finally { foreach($pin in $pins){$pin.Dispose()} }'
    $parseTokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseInput($bootstrap,[ref]$parseTokens,[ref]$parseErrors)
    if ($parseErrors) { throw 'Task bootstrap syntax check failed.' }
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -Command "'+$bootstrap.Replace('"','\"')+'"'
    $taskAction=New-ScheduledTaskAction -Execute $psExe -Argument $arguments -WorkingDirectory $env:SystemRoot
    $trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $taskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force:($Action -eq 'Update') -Description 'After VALORANT exits for30s, disable verified ACE startup entries and show a tray notification. No live driver unload or game termination.' | Out-Null
    $taskCom=New-Object -ComObject 'Schedule.Service'; $taskCom.Connect()
    $registered=$taskCom.GetFolder('\').GetTask($taskName)
    $registered.SetSecurityDescriptor('O:BAG:BAD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;'+$sid+')',0)
    Export-ScheduledTask -TaskName $taskName | Set-Content -LiteralPath (Join-Path $runtimeData 'installed_task.xml') -Encoding UTF8
    $registered.GetSecurityDescriptor(7) | Set-Content -LiteralPath (Join-Path $runtimeData 'task_security_descriptor.txt') -Encoding UTF8
    $dispatchAt=Get-Date
    Start-ScheduledTask -TaskName $taskName
    $healthy=$false; $ready=$null; $deadline=(Get-Date).AddSeconds(12)
    while ((Get-Date) -lt $deadline) {
        $readyPath=Join-Path $runtimeData 'watcher_ready.json'
        if (Test-Path -LiteralPath $readyPath) {
            $ready=Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
            if ([datetimeoffset]$ready.ready_at -ge [datetimeoffset]$dispatchAt -and $ready.phase -eq 'Ready') {
                $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$ready.pid)
                $task=Get-ScheduledTask -TaskName $taskName
                if ($process -and $process.CommandLine.IndexOf($runtimeWatch.Replace("'","''"),[StringComparison]::OrdinalIgnoreCase) -ge 0 -and $task.State -eq 'Running') { $healthy=$true; break }
            }
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not $healthy) { throw 'Task registered but watcher did not reach verified Ready state; check protected runtime logs.' }
    $management=[ordered]@{action=$Action; success=$true; watcher_healthy=$true; user=$user; task_name=$taskName; time=(Get-Date -Format o); watcher_pid=$ready.pid; initial_cleanup='NotRunGamePresent'; task_bootstrap='Transparent inline path-pinning bootstrap; runtime scripts administrator owned'}
    if (-not @(Get-ValorantProcesses).Count) {
        $cleanupStarted=Get-Date
        & $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File $runtimeWatch -Mode IsolateNow
        $management.initial_cleanup_exit=$LASTEXITCODE
        $lastResult=Join-Path $runtimeData 'last_isolation.json'
        if ((Test-Path -LiteralPath $lastResult) -and (Get-Item -LiteralPath $lastResult).LastWriteTime -ge $cleanupStarted) {
            $management.initial_cleanup=Get-Content -LiteralPath $lastResult -Raw | ConvertFrom-Json
        } else { $management.initial_cleanup=[pscustomobject]@{outcome='NoFreshResult'} }
        if ($management.initial_cleanup_exit -ne 0 -or $management.initial_cleanup.outcome -ne 'Disabled') { $management.success=$false }
    }
    Write-GuardJson $management $receiptPath
    if (-not $management.success) {
        Write-Warning ('Watcher installation is healthy, but initial cleanup did not complete successfully. See '+$receiptPath)
        exit 2
    }
} catch {
    Write-GuardJson @{action=$Action; success=$false; error=$_.Exception.Message; time=(Get-Date -Format o)} $receiptPath
    throw
} finally { if ($pins) { foreach($pin in $pins){$pin.Dispose()} } }
