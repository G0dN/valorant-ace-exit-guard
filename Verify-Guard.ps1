$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$runtime=Join-Path $root '.runtime'
$data=Join-Path $runtime 'data'
function Require([bool]$Condition,[string]$Message) { if(-not $Condition){throw $Message} }
$task=Get-ScheduledTask -TaskName 'Valorant.AceExitGuard'
Require ($task.State -eq 'Running') 'Guard task is not running'
Require ($task.Principal.LogonType -eq 'Interactive' -and $task.Principal.RunLevel -eq 'Highest') 'Unexpected task principal'
Require (@($task.Triggers).Count -eq 1 -and $task.Triggers[0].CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') 'Unexpected task trigger'
Require ($task.Settings.ExecutionTimeLimit -eq 'PT0S') 'Unexpected task time limit'
Require ($task.Actions.Arguments.Contains('0x02200000') -and $task.Actions.Arguments.Contains('Lock-GuardDataPath') -and $task.Actions.Arguments.IndexOf((Join-Path $runtime 'Watch-Ace.ps1').Replace("'","''"),[StringComparison]::OrdinalIgnoreCase) -ge 0) 'Missing final protected runtime bootstrap'
$ready=Get-Content -LiteralPath (Join-Path $data 'watcher_ready.json') -Raw | ConvertFrom-Json
Require ($ready.phase -eq 'Ready' -and $null -ne (Get-Process -Id $ready.pid -ErrorAction SilentlyContinue)) 'Ready process is not alive'
$watcher=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$ready.pid)
Require (-not [string]::IsNullOrWhiteSpace($watcher.CommandLine)) 'Run verification in administrator Windows PowerShell to inspect watcher identity'
Require ($watcher.Name -eq 'powershell.exe' -and $watcher.CommandLine.IndexOf((Join-Path $runtime 'Watch-Ace.ps1').Replace("'","''"),[StringComparison]::OrdinalIgnoreCase) -ge 0) 'Ready PID does not identify this watcher'
$created=[datetimeoffset]$watcher.CreationDate
Require ([datetimeoffset]$ready.ready_at -ge $created -and [datetimeoffset]$ready.ready_at -le [datetimeoffset]::Now) 'Readiness receipt predates current process or is in the future'
$managementFile=Get-ChildItem -LiteralPath $data -Filter 'management_*.json' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$management=Get-Content -LiteralPath $managementFile.FullName -Raw | ConvertFrom-Json
Require ($management.watcher_healthy) 'No successful watcher deployment recorded'
Require (Test-Path -LiteralPath (Join-Path $data 'last_isolation.json')) 'No completed cleanup receipt yet; wait for a game exit and cleanup before verifying'
$last=Get-Content -LiteralPath (Join-Path $data 'last_isolation.json') -Raw | ConvertFrom-Json
Require ($last.outcome -eq 'Disabled' -and $last.disabled_count -gt 0 -and $last.disabled_count -eq @($last.after).Count -and @($last.errors).Count -eq 0) 'ACE startup disablement was not fully verified'
foreach($entry in $last.after){Require ((Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$entry.name)).Start -eq 4) ('ACE start changed again: '+$entry.name)}
$test=Get-Content -LiteralPath (Join-Path $data 'pre_install_test_results.json') -Raw | ConvertFrom-Json
Require ($test.passed -eq 20 -and $test.real_wmi_probe.start_observed -and $test.real_wmi_probe.stop_observed) 'Required tests did not pass'
$hashes=@(foreach($name in @('Guard.Core.ps1','Watch-Ace.ps1')){
    $source=(Get-FileHash -LiteralPath (Join-Path $root $name) -Algorithm SHA256).Hash
    $installed=(Get-FileHash -LiteralPath (Join-Path $runtime $name) -Algorithm SHA256).Hash
    Require ($source -eq $installed) ('Runtime/source mismatch: '+$name)
    [pscustomobject]@{file=$name;sha256=$installed}
})
foreach($path in @($runtime,$data,(Join-Path $runtime 'Guard.Core.ps1'),(Join-Path $runtime 'Watch-Ace.ps1'))){
    $acl=Get-Acl -LiteralPath $path
    Require ($acl.GetOwner([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-544') 'Unexpected runtime owner'
    foreach($rule in $acl.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){
        if($rule.AccessControlType -eq 'Allow' -and $rule.IdentityReference.Value -notin @('S-1-5-32-544','S-1-5-18')){
            $write=[Security.AccessControl.FileSystemRights]::Write -bor [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor [Security.AccessControl.FileSystemRights]::TakeOwnership
            Require (-not ($rule.FileSystemRights -band $write)) 'Nonadministrator can alter elevated runtime'
        }
    }
}
$events=@(Get-Content -LiteralPath (Join-Path $data 'events.jsonl') | ForEach-Object {$_ | ConvertFrom-Json})
$sessionEvents=@($events | Where-Object { [datetimeoffset]$_.time -ge $created })
$shown=@($sessionEvents | Where-Object { $_.kind -eq 'NotificationShown' -and $_.details.pid -eq $ready.pid })
Require ($shown.Count -ge 1) 'Shell notification display not observed for current watcher session'
Require (-not @($sessionEvents | Where-Object kind -in @('FatalError','WatcherError')).Count) 'Current watcher session logged an error'
$result=[ordered]@{verified_at=(Get-Date -Format o); all_assertions_passed=$true; task=[string]$task.State; watcher_pid=$ready.pid; user_logon_autostart=$true; exit_grace_seconds=30; state_and_real_event_checks_passed=$test.passed; current_ace_start_values_disabled=$last.disabled_count; last_admin_query_active_components=$last.active_count; last_admin_query_unknown_components=$last.unknown_count; shell_notification_shown_events=$shown.Count; protected_runtime_hashes=$hashes; runtime_owner_and_write_permissions_checked=$true; task_reparse_protection_checked=$true; actual_valorant_launched_by_verification=$false; driver_unload_or_process_stop_attempted=$false}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $root 'data\final_verification.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 6
