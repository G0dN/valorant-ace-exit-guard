param([switch]$RunEventProbe)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Guard.Core.ps1')
$checks=[Collections.Generic.List[string]]::new()
function Check([bool]$Condition,[string]$Name) { if (-not $Condition) { throw ('FAILED: '+$Name) }; $checks.Add($Name) }
$idle=Get-GuardTransition $false $null $false $false $false 0
Check (-not $idle.armed -and -not $idle.isolate) 'Idle startup does not invent a game exit'
$running=Get-GuardTransition $false $null $true $true $false 1
Check ($running.armed -and $null -eq $running.deadline) 'Game start arms watcher'
$stopped=Get-GuardTransition $true $null $false $false $true 10
Check ($stopped.deadline -eq 40 -and -not $stopped.isolate) 'Exit waits30 seconds'
$waiting=Get-GuardTransition $true 40 $false $false $false 39
Check (-not $waiting.isolate) 'No early isolation'
$ready=Get-GuardTransition $true 40 $false $false $false 40
Check $ready.isolate 'Isolation requested at deadline'
$restarted=Get-GuardTransition $true 40 $true $true $false 39
Check ($null -eq $restarted.deadline -and -not $restarted.isolate) 'Game restart cancels deadline'
$multi=Get-GuardTransition $true $null $true $false $true 10
Check (-not $multi.isolate -and $null -eq $multi.deadline) 'Other game process remaining prevents cleanup'
$brief=Get-GuardTransition $false $null $false $true $true 10
Check ($brief.armed -and $brief.deadline -eq 40) 'Short session observed in a single event batch'
$recovery=Get-GuardTransition $true $null $false $false $false 10
Check ($recovery.deadline -eq 40) 'Persisted session receives recovery grace'
Check (Test-AceTarget 'ACE-GAME' ('\??\'+$env:SystemRoot+'\system32\drivers\ACE-GAME.sys')) 'Known kernel path allowed'
Check (Test-AceTarget 'AntiCheatExpert Service' ('"'+$env:ProgramFiles+'\AntiCheatExpert\SGuard\x64\SGuardSvc64.exe" -autorun')) 'Quoted service path allowed'
Check (Test-AceTarget 'ACE-CORE99999' ('\??\'+$env:ProgramFiles+'\AntiCheatExpert\ACE-CORE99999.sys')) 'New ACE version discovered within verified root'
Check (-not (Test-AceTarget 'UnrelatedService' ($env:ProgramFiles+'\AntiCheatExpert\ACE-GAME.sys'))) 'Unrelated service names excluded'
Check (-not (Test-AceTarget 'ACE-GAME' (Join-Path $env:SystemRoot 'not-ace\ACE-GAME.sys'))) 'Unrecognized image roots excluded'
Check (-not (Test-AceTarget 'ACE-GAME' ($env:ProgramFiles+'\AntiCheatExpert\..\Other\ACE-GAME.sys'))) 'Path traversal excluded'
Check (-not (Test-AceTarget 'ACE-GAME' ($env:ProgramFiles+'\AntiCheatExpertElse\ACE-GAME.sys'))) 'Prefix sibling excluded'
$good=Get-IsolationNotice ([pscustomobject]@{outcome='Disabled';disabled_count=9;active_count=0;unknown_count=0})
Check ($good.icon -eq 'Info') 'Success notification requires verified states'
$unknown=Get-IsolationNotice ([pscustomobject]@{outcome='Disabled';disabled_count=9;active_count=0;unknown_count=1})
Check ($unknown.icon -eq 'Warning') 'Unknown runtime state produces warning'
$partial=Get-IsolationNotice ([pscustomobject]@{outcome='PartialFailure';disabled_count=8})
Check ($partial.icon -eq 'Error') 'Partial failure cannot masquerade as success'
$probe=$null
if ($RunEventProbe) {
    $startId='AceGuard.TestStart'; $stopId='AceGuard.TestStop'
    try {
        Register-WmiEvent -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName='cmd.exe'" -SourceIdentifier $startId | Out-Null
        Register-WmiEvent -Query "SELECT * FROM Win32_ProcessStopTrace WHERE ProcessName='cmd.exe'" -SourceIdentifier $stopId | Out-Null
        $process=Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList '/d /c exit 0' -WindowStyle Hidden -PassThru
        $processId=$process.Id
        $deadline=(Get-Date).AddSeconds(12); $sawStart=$false; $sawStop=$false
        while ((Get-Date) -lt $deadline -and -not ($sawStart -and $sawStop)) {
            Wait-Event -Timeout 1 | Out-Null
            foreach ($event in @(Get-Event | Where-Object { $_.SourceIdentifier -in @($startId,$stopId) })) {
                if ($event.SourceEventArgs.NewEvent.ProcessID -eq $processId) {
                    if ($event.SourceIdentifier -eq $startId) { $sawStart=$true }
                    if ($event.SourceIdentifier -eq $stopId) { $sawStop=$true }
                }
                Remove-Event -EventIdentifier $event.EventIdentifier
            }
        }
        Check ($sawStart -and $sawStop) 'Real WMI start and exit events received for harmless probe'
        $probe=@{pid=$processId; start_observed=$sawStart; stop_observed=$sawStop; ace_changes=$false}
    } finally {
        foreach ($id in @($startId,$stopId)) { Unregister-Event -SourceIdentifier $id -ErrorAction SilentlyContinue }
    }
}
$result=[ordered]@{time=(Get-Date -Format o); checks=@($checks); passed=$checks.Count; real_wmi_probe=$probe; service_changes=$false; game_launches=$false; powershell=$PSVersionTable.PSVersion.ToString()}
Write-GuardJson $result (Join-Path $script:DataRoot 'test_results.json')
$result | ConvertTo-Json -Depth 5
