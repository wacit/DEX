#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs (or removes) the AvdDex Agent on a session host as a SYSTEM scheduled task.

.DESCRIPTION
    * Copies AvdDexAgent.ps1 to the install folder
    * Writes / merges C:\ProgramData\AvdDex\agent.config.json
    * Enables the "User Input Delay per Session" perf counters (EnableLagCounter = 1)
    * Registers the "AvdDex Agent" event log source
    * Registers a scheduled task that runs at startup as SYSTEM, restarts on failure, never times out
    * Starts the task immediately

    -Uninstall stops and removes the task only. Config, data and logs under C:\ProgramData\AvdDex are left in place.

.EXAMPLE
    .\Install-AvdDexAgent.ps1 -SharePath '\\fileserver\AvdDex' -HostPool 'CAD-POOL' -Tags CAD,Bentley
    .\Install-AvdDexAgent.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$SourcePath = $PSScriptRoot,
    [string]$InstallPath = 'C:\Program Files\AvdDex',
    [string]$DataPath = 'C:\ProgramData\AvdDex',
    [string]$SharePath,
    [string]$HostPool,
    [string[]]$Tags,
    [int]$IntervalSeconds = 30,
    [string]$WebhookUrl,
    [string]$SyntheticProbePath,
    [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$taskName = 'AvdDex Agent'

if ($Uninstall) {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $taskName -Confirm:$false; Write-Host "Removed scheduled task '$taskName'. Data left in $DataPath." }
    else { Write-Host "Task '$taskName' not present." }
    return
}

$agentSrc = Join-Path $SourcePath 'AvdDexAgent.ps1'
if (-not (Test-Path $agentSrc)) { throw "AvdDexAgent.ps1 not found in $SourcePath" }

foreach ($d in @($InstallPath, $DataPath)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
Copy-Item -LiteralPath $agentSrc -Destination (Join-Path $InstallPath 'AvdDexAgent.ps1') -Force
Write-Host "Agent copied to $InstallPath"

# --- config (merge with existing so re-running the installer doesn't wipe tuned thresholds) ---
$cfgPath = Join-Path $DataPath 'agent.config.json'
$cfg = [ordered]@{}
if (Test-Path $cfgPath) { try { $old = Get-Content $cfgPath -Raw | ConvertFrom-Json; foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value } } catch { } }
$cfg.OutputPath = $DataPath
if ($PSBoundParameters.ContainsKey('SharePath'))       { $cfg.SharePath = $SharePath }
if ($PSBoundParameters.ContainsKey('HostPool'))        { $cfg.HostPool = $HostPool }
if ($PSBoundParameters.ContainsKey('Tags'))            { $cfg.Tags = @($Tags) }
if ($PSBoundParameters.ContainsKey('IntervalSeconds')) { $cfg.IntervalSeconds = $IntervalSeconds }
if ($PSBoundParameters.ContainsKey('WebhookUrl'))      { $cfg.WebhookUrl = $WebhookUrl }
if ($PSBoundParameters.ContainsKey('SyntheticProbePath')) { $cfg.SyntheticProbePath = $SyntheticProbePath }
if (-not $cfg.Contains('IntervalSeconds')) { $cfg.IntervalSeconds = $IntervalSeconds }
$cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
Write-Host "Config written: $cfgPath"

# --- enable User Input Delay counters (requires a reboot or a new session to start populating) ---
$tsKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$cur = (Get-ItemProperty -Path $tsKey -Name EnableLagCounter -ErrorAction SilentlyContinue).EnableLagCounter
if ($cur -ne 1) { New-ItemProperty -Path $tsKey -Name EnableLagCounter -PropertyType DWord -Value 1 -Force | Out-Null; Write-Host 'EnableLagCounter set to 1 (input-delay counters appear for sessions started after this change).' }

# --- event log source ---
if (-not [System.Diagnostics.EventLog]::SourceExists('AvdDex Agent')) { New-EventLog -LogName Application -Source 'AvdDex Agent'; Write-Host 'Event log source registered.' }

# --- share pre-flight (informational) ---
if ($cfg.SharePath) {
    if (Test-Path -LiteralPath $cfg.SharePath) { Write-Host "Share reachable: $($cfg.SharePath)" }
    else { Write-Warning "Share '$($cfg.SharePath)' is not reachable from this account. The agent runs as SYSTEM - the computer account needs Modify rights on the share (Azure Files: AD DS/Kerberos auth + NTFS perms). Data will still be written locally." }
}

# --- scheduled task ---
$psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$action = New-ScheduledTaskAction -Execute $psExe -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $InstallPath 'AvdDexAgent.ps1'))
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.ExecutionTimeLimit = 'PT0S'   # unlimited
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) { Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName $taskName -Confirm:$false }
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'AvdDex Agent - session host / session telemetry collector' | Out-Null
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 3
$state = (Get-ScheduledTask -TaskName $taskName).State
Write-Host "Scheduled task '$taskName' registered and $state."
Write-Host "Latest snapshot will appear at $DataPath\latest\$env:COMPUTERNAME.json within ~$IntervalSeconds s."
