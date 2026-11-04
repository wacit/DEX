#Requires -Version 5.1
<#
.SYNOPSIS
    AvdDex "triggers" - runs remediation actions against the alerts in the host's latest DEX snapshot.

.DESCRIPTION
    ControlUp links alerts to scripts; this does the same on the host. Run it from NinjaOne (as SYSTEM)
    on a schedule or as a condition-triggered automation, or let the FastAPI broker call it via NinjaOne
    when the agent's webhook fires.

    SAFETY: every action is OFF unless enabled in remediation.config.json, and nothing runs unless
    -Execute is given. Without -Execute it prints what it *would* do. Each executed action is written
    to the Application log (source "AvdDex Agent", event 1003).

    Alert Id                   Action (when enabled)
    ------------------------   -------------------------------------------------------------
    AVD_AGENT                  Restart RDAgentBootLoader service
    FSLOGIX_SERVICE            Start frxsvc
    HOST_DISK_FREE             Clear C:\Windows\Temp and per-user Temp files older than N days, WU download cache
    SESSION_STALE_DISCONNECT   Log off disconnected sessions idle longer than N minutes
    SESSION_APP_HUNG           End processes that are "not responding" for the session (allow-list only)
    HOST_CPU_SUSTAINED         No action - writes the top process to the event log for the ticket
    HOST_PENDING_REBOOT        Reboot only if no active sessions AND inside the maintenance window

.EXAMPLE
    .\Invoke-AvdDexRemediation.ps1              # dry run
    .\Invoke-AvdDexRemediation.ps1 -Execute
#>
[CmdletBinding()]
param(
    [string]$DataPath = 'C:\ProgramData\AvdDex',
    [string]$ConfigPath = 'C:\ProgramData\AvdDex\remediation.config.json',
    [switch]$Execute
)
$ErrorActionPreference = 'Continue'
$defaults = [ordered]@{
    AVD_AGENT                = @{ Enabled = $false }
    FSLOGIX_SERVICE          = @{ Enabled = $false }
    HOST_DISK_FREE           = @{ Enabled = $false; TempOlderThanDays = 7; ClearWindowsUpdateCache = $false }
    SESSION_STALE_DISCONNECT = @{ Enabled = $false; IdleMinutes = 480 }
    SESSION_APP_HUNG         = @{ Enabled = $false; ProcessAllowList = @('MicroStation', 'OpenRoadsDesigner', 'acad', 'Civil3D', 'EXCEL', 'WINWORD', 'OUTLOOK', 'chrome', 'msedge') }
    HOST_PENDING_REBOOT      = @{ Enabled = $false; WindowStartHour = 2; WindowEndHour = 5 }
}
$cfg = $defaults
if (Test-Path -LiteralPath $ConfigPath) {
    try { $j = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json; foreach ($p in $j.PSObject.Properties) { $h = @{}; foreach ($q in $p.Value.PSObject.Properties) { $h[$q.Name] = $q.Value }; $cfg[$p.Name] = $h } } catch { Write-Warning "Config unreadable, all actions disabled: $($_.Exception.Message)" }
} else {
    try { $defaults | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ConfigPath -Encoding UTF8; Write-Host "Wrote default (all-disabled) config to $ConfigPath" } catch { }
}

$latest = Join-Path $DataPath "latest\$env:COMPUTERNAME.json"
if (-not (Test-Path -LiteralPath $latest)) { Write-Output "No snapshot at $latest"; exit 1 }
$snap = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
$age = ((Get-Date) - [datetime]$snap.Timestamp).TotalMinutes
if ($age -gt 10) { Write-Output "Snapshot is $([math]::Round($age)) min old - refusing to act on stale data"; exit 1 }

$mode = if ($Execute) { 'EXECUTE' } else { 'DRY-RUN' }
function Log-Action { param([string]$Id, [string]$Target, [string]$Text)
    Write-Output ("[{0}] {1} {2}: {3}" -f $mode, $Id, $Target, $Text)
    if ($Execute) { try { if (-not [System.Diagnostics.EventLog]::SourceExists('AvdDex Agent')) { New-EventLog -LogName Application -Source 'AvdDex Agent' }; Write-EventLog -LogName Application -Source 'AvdDex Agent' -EntryType Information -EventId 1003 -Message ("Remediation {0} on {1}: {2}" -f $Id, $Target, $Text) } catch { } }
}
function Enabled { param([string]$Id) return ($cfg.Contains($Id) -and [bool]$cfg[$Id].Enabled) }

$acted = 0
foreach ($a in @($snap.Alerts)) {
    $id = [string]$a.Id
    if ($id -ne 'HOST_CPU_SUSTAINED' -and -not (Enabled $id)) { Write-Verbose "$id disabled - skipping ($($a.Message))"; continue }
    $c = $null; if ($cfg.Contains($id)) { $c = $cfg[$id] }
    switch ($id) {
        'AVD_AGENT' {
            Log-Action $id $a.Target 'Restart-Service RDAgentBootLoader'
            if ($Execute) { Restart-Service -Name RDAgentBootLoader -Force; Start-Sleep 5; Log-Action $id $a.Target ("Service now {0}" -f (Get-Service RDAgentBootLoader).Status) }
            $acted++
        }
        'FSLOGIX_SERVICE' {
            Log-Action $id $a.Target 'Start-Service frxsvc'
            if ($Execute) { Start-Service -Name frxsvc; Log-Action $id $a.Target ("Service now {0}" -f (Get-Service frxsvc).Status) }
            $acted++
        }
        'HOST_DISK_FREE' {
            $days = [int]$c.TempOlderThanDays; if ($days -lt 1) { $days = 7 }
            $cut = (Get-Date).AddDays(-$days)
            $targets = @("$env:SystemRoot\Temp") + @(Get-ChildItem 'C:\Users' -Directory -ErrorAction SilentlyContinue | ForEach-Object { Join-Path $_.FullName 'AppData\Local\Temp' } | Where-Object { Test-Path $_ })
            $files = @(); foreach ($t in $targets) { $files += Get-ChildItem -LiteralPath $t -File -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut } }
            $mb = [math]::Round((($files | Measure-Object Length -Sum).Sum) / 1MB)
            Log-Action $id $a.Target ("Remove {0} temp files older than {1}d ({2} MB) from {3} folders" -f $files.Count, $days, $mb, $targets.Count)
            if ($Execute) { $files | Remove-Item -Force -ErrorAction SilentlyContinue }
            if ([bool]$c.ClearWindowsUpdateCache) {
                Log-Action $id $a.Target 'Clear SoftwareDistribution\Download (stop/start wuauserv)'
                if ($Execute) { Stop-Service wuauserv -Force -ErrorAction SilentlyContinue; Remove-Item "$env:SystemRoot\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue; Start-Service wuauserv -ErrorAction SilentlyContinue }
            }
            $acted++
        }
        'SESSION_STALE_DISCONNECT' {
            $min = [int]$c.IdleMinutes; if ($min -lt 60) { $min = 60 }
            $sess = $snap.Sessions | Where-Object { ("{0}@{1}" -f $_.UserName, $snap.Host) -eq $a.Target } | Select-Object -First 1
            if ($sess -and $sess.State -eq 'Disconnected' -and $sess.IdleMinutes -ge $min) {
                Log-Action $id $a.Target ("logoff session {0} ({1}, disconnected {2} min, {3} MB)" -f $sess.SessionId, $sess.UserName, $sess.IdleMinutes, $sess.MemoryMB)
                if ($Execute) { & logoff $sess.SessionId }
                $acted++
            }
        }
        'SESSION_APP_HUNG' {
            $allow = @($c.ProcessAllowList)
            $sess = $snap.Sessions | Where-Object { ("{0}@{1}" -f $_.UserName, $snap.Host) -eq $a.Target } | Select-Object -First 1
            if ($sess) {
                foreach ($p in @($sess.TopProcesses | Where-Object { -not $_.Responding -and ($allow -contains $_.Name) })) {
                    $live = Get-Process -Id $p.Pid -ErrorAction SilentlyContinue
                    if ($live -and -not $live.Responding) {
                        Log-Action $id $a.Target ("Stop-Process {0} (PID {1}) - still not responding" -f $p.Name, $p.Pid)
                        if ($Execute) { Stop-Process -Id $p.Pid -Force -ErrorAction SilentlyContinue }
                        $acted++
                    }
                }
            }
        }
        'HOST_CPU_SUSTAINED' {
            $top = $snap.TopProcesses | Select-Object -First 3 | ForEach-Object { "{0} (PID {1}, session {2}, {3}%)" -f $_.Name, $_.Pid, $_.SessionId, $_.CpuPct }
            Log-Action $id $a.Target ("No automatic action. Top CPU: {0}" -f ($top -join '; '))
        }
        'HOST_PENDING_REBOOT' {
            $h = (Get-Date).Hour
            $inWindow = ($h -ge [int]$c.WindowStartHour -and $h -lt [int]$c.WindowEndHour)
            if ($snap.SessionSummary.Active -eq 0 -and $inWindow) {
                Log-Action $id $a.Target 'Restart-Computer (no active sessions, inside maintenance window)'
                if ($Execute) { Restart-Computer -Force }
                $acted++
            } else { Write-Verbose "Pending reboot: active sessions=$($snap.SessionSummary.Active), inWindow=$inWindow - not rebooting" }
        }
    }
}
Write-Output ("{0}: {1} alert(s) evaluated, {2} action(s) {3}" -f $mode, @($snap.Alerts).Count, $acted, $(if ($Execute) { 'executed' } else { 'would run' }))
