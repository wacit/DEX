#Requires -Version 5.1
<#
.SYNOPSIS
    AvdDex Agent - Digital Employee Experience (DEX) collector for AVD / RDS session hosts.

.DESCRIPTION
    Runs as SYSTEM on every session host. Each cycle it collects:
      * Host health   : CPU, run queue, memory, disk latency / free space, network, GPU, uptime, pending reboot
      * AVD agent     : RDAgentBootLoader service, registration state, agent version
      * FSLogix       : service state, per-session container attach state, errors in the interval
      * Sessions      : state, idle, RTT (TCP/UDP), bandwidth, user input delay, RemoteFX frame stats,
                        per-session CPU / memory, top processes, logon duration breakdown
      * Events        : disconnects / reconnects, application crashes and hangs in the interval
    It then computes a DEX score (0-100) + grade + stress level for the host and every session,
    evaluates alert rules (with "sustained" logic over the last N samples), and writes:
      * <OutputPath>\latest\<HOST>.json            - full snapshot (consumed by Merge-AvdDexFleet.ps1 and the dashboard)
      * <OutputPath>\history\<HOST>\<yyyy-MM-dd>.jsonl - one compact line per cycle for trending
      * same two paths under <SharePath> when a share is configured
      * Windows Application event log (source "AvdDex Agent") entries for warning / critical alerts
      * optional webhook POST of alerts (e.g. a FastAPI remediation broker)

.PARAMETER ConfigPath
    JSON config file. Values in the file override the defaults; command-line parameters override the file.
    Default: C:\ProgramData\AvdDex\agent.config.json

.PARAMETER Once
    Collect one sample and exit (for NinjaOne ad-hoc runs / troubleshooting). Default is to loop forever.

.EXAMPLE
    .\AvdDexAgent.ps1 -Once -Verbose
    .\AvdDexAgent.ps1 -SharePath '\\fileserver\AvdDex' -HostPool 'CAD-POOL'

.NOTES
    AvdDex v1.0 (2026-11) - https://github.com/wacit/AvdDex - MIT
    Windows Server 2019+/Win10/11 multi-session. PowerShell 5.1 and 7.x.
    User Input Delay counters need HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server\EnableLagCounter=1 (installer sets it).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = 'C:\ProgramData\AvdDex\agent.config.json',
    [string]$OutputPath,
    [string]$SharePath,
    [string]$HostPool,
    [int]$IntervalSeconds,
    [int]$TopProcesses,
    [string]$WebhookUrl,
    [switch]$Once
)

$ErrorActionPreference = 'Continue'
$script:AgentVersion = '1.0.0'
$script:HostName = $env:COMPUTERNAME

# ----------------------------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------------------------
function Get-DexConfig {
    $cfg = [ordered]@{
        OutputPath          = 'C:\ProgramData\AvdDex'
        SharePath           = ''                     # UNC root, e.g. \\server\share\DEX  (agent writes latest\ and history\ under it)
        HostPool            = ''                     # logical grouping shown in the dashboard (host pool / folder)
        Tags                = @()                    # free-form tags, e.g. "CAD","Bentley"
        IntervalSeconds     = 30                     # ControlUp samples every 3s; 30s is a sane PowerShell default (min 10)
        TopProcesses        = 8                      # top processes per session (by CPU) kept in the snapshot
        SustainedSamples    = 5                      # samples used for "sustained" alert logic
        WebhookUrl          = ''                     # POST alerts here (FastAPI broker / Freshservice / Teams connector)
        WebhookMinSeverity  = 'warning'              # info | warning | critical
        WriteEventLog       = $true
        HistoryRetentionDays= 0                      # 0 = never prune local history (default: keep everything)
        SyntheticProbePath  = ''                     # optional JSON written by the synthetic logon probe; merged into the snapshot
        Thresholds          = [ordered]@{
            CpuWarn = 80;  CpuCrit = 92
            MemWarn = 85;  MemCrit = 94
            DiskLatencyWarnMs = 20; DiskLatencyCritMs = 45
            DiskFreeWarnPct = 15;   DiskFreeCritPct = 7
            RttWarnMs = 120;        RttCritMs = 220
            InputDelayWarnMs = 400; InputDelayCritMs = 1000
            LogonWarnSec = 45;      LogonCritSec = 90
            SessionCpuWarnPct = 50; SessionCpuCritPct = 85
            GpuWarnPct = 85;        GpuCritPct = 97
            RetransmitWarnPerSec = 5
            UptimeWarnDays = 14
        }
    }
    if (Test-Path -LiteralPath $ConfigPath) {
        try {
            $file = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            foreach ($p in $file.PSObject.Properties) {
                if ($p.Name -eq 'Thresholds') {
                    foreach ($t in $p.Value.PSObject.Properties) { $cfg.Thresholds[$t.Name] = $t.Value }
                } else { $cfg[$p.Name] = $p.Value }
            }
        } catch { Write-Warning "Config file unreadable, using defaults: $($_.Exception.Message)" }
    }
    if ($OutputPath)      { $cfg.OutputPath = $OutputPath }
    if ($SharePath)       { $cfg.SharePath = $SharePath }
    if ($HostPool)        { $cfg.HostPool = $HostPool }
    if ($IntervalSeconds) { $cfg.IntervalSeconds = $IntervalSeconds }
    if ($TopProcesses)    { $cfg.TopProcesses = $TopProcesses }
    if ($WebhookUrl)      { $cfg.WebhookUrl = $WebhookUrl }
    if ($cfg.IntervalSeconds -lt 10) { $cfg.IntervalSeconds = 10 }
    return $cfg
}

# ----------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------
function Write-DexLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Verbose $line
    try {
        $logDir = Join-Path $script:Config.OutputPath 'logs'
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        $logFile = Join-Path $logDir ("agent-{0}.log" -f (Get-Date -Format 'yyyy-MM-dd'))
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
}

function Get-CounterGroup {
    # Get-Counter fails the whole call if ANY path is invalid, so counters are fetched in groups.
    param([string[]]$Paths)
    try { return @((Get-Counter -Counter $Paths -ErrorAction Stop).CounterSamples) } catch { Write-DexLog "Counter group unavailable ($($Paths[0]) ...): $($_.Exception.Message)" 'DEBUG'; return @() }
}

function Get-SampleValue {
    param($Samples, [string]$PathLike, [string]$Instance)
    foreach ($s in $Samples) {
        if ($s.Path -like $PathLike) {
            if (-not $Instance -or $s.InstanceName -eq $Instance) { return [math]::Round([double]$s.CookedValue, 2) }
        }
    }
    return $null
}

function Get-TrailingNumber { param([string]$Text) if ($Text -match '(\d+)\s*$') { return [int]$Matches[1] } ; return -1 }

function Round2 { param($v) if ($null -eq $v) { return $null } ; return [math]::Round([double]$v, 2) }

function Get-StateFile { Join-Path $script:Config.OutputPath 'state.json' }

function Load-State {
    $f = Get-StateFile
    $state = [ordered]@{ LastRun = $null; Samples = @(); Logons = @{} }
    if (Test-Path -LiteralPath $f) {
        try {
            $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
            if ($j.LastRun) { $state.LastRun = [datetime]$j.LastRun }
            if ($j.Samples) { $state.Samples = @($j.Samples) }
            if ($j.Logons)  { $h = @{}; foreach ($p in $j.Logons.PSObject.Properties) { $h[$p.Name] = $p.Value }; $state.Logons = $h }
        } catch { }
    }
    return $state
}

function Save-State { param($State) try { $State | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath (Get-StateFile) -Encoding UTF8 } catch { } }

function Get-PendingReboot {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
    try { $pfr = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop; if ($pfr.PendingFileRenameOperations) { $reasons += 'PendingFileRename' } } catch { }
    return $reasons
}

# ----------------------------------------------------------------------------------------------
# Collectors
# ----------------------------------------------------------------------------------------------
function Get-HostMetrics {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cores = [int]$cs.NumberOfLogicalProcessors
    $core = Get-CounterGroup @(
        '\Processor(_Total)\% Processor Time',
        '\System\Processor Queue Length',
        '\System\Context Switches/sec',
        '\Memory\Available MBytes',
        '\Memory\Pages/sec',
        '\Memory\% Committed Bytes In Use',
        '\LogicalDisk(*)\Avg. Disk sec/Read',
        '\LogicalDisk(*)\Avg. Disk sec/Write',
        '\LogicalDisk(*)\Current Disk Queue Length',
        '\LogicalDisk(*)\% Free Space',
        '\LogicalDisk(*)\Disk Transfers/sec',
        '\Network Interface(*)\Bytes Total/sec',
        '\Network Interface(*)\Output Queue Length',
        '\TCPv4\Segments Retransmitted/sec'
    )
    $totalMB = [math]::Round($os.TotalVisibleMemorySize / 1KB)
    $availMB = Get-SampleValue $core '*\memory\available mbytes'
    if ($null -eq $availMB) { $availMB = [math]::Round($os.FreePhysicalMemory / 1KB) }
    $usedPct = if ($totalMB -gt 0) { [math]::Round((($totalMB - $availMB) / $totalMB) * 100, 1) } else { 0 }

    # Disks
    $disks = @()
    $diskInstances = $core | Where-Object { $_.Path -like '*\logicaldisk(*)\% free space' -and $_.InstanceName -ne '_total' -and $_.InstanceName -match '^[a-z]:$' }
    foreach ($d in $diskInstances) {
        $inst = $d.InstanceName
        $disks += [ordered]@{
            Drive        = $inst.ToUpper()
            FreePct      = Round2 $d.CookedValue
            ReadLatencyMs  = Round2 ((Get-SampleValue $core '*\logicaldisk(*)\avg. disk sec/read'  $inst) * 1000)
            WriteLatencyMs = Round2 ((Get-SampleValue $core '*\logicaldisk(*)\avg. disk sec/write' $inst) * 1000)
            QueueLength  = Get-SampleValue $core '*\logicaldisk(*)\current disk queue length' $inst
            Iops         = Get-SampleValue $core '*\logicaldisk(*)\disk transfers/sec' $inst
        }
    }
    $sysDisk = $disks | Where-Object { $_.Drive -eq ($env:SystemDrive) } | Select-Object -First 1
    $worstLatency = 0; foreach ($d in $disks) { foreach ($v in @($d.ReadLatencyMs, $d.WriteLatencyMs)) { if ($v -gt $worstLatency) { $worstLatency = $v } } }

    # Network (sum of all non-loopback, non-isatap adapters)
    $netBytes = 0; $netQueue = 0
    foreach ($s in ($core | Where-Object { $_.Path -like '*\network interface(*)\bytes total/sec' })) {
        if ($s.InstanceName -match 'loopback|isatap|teredo') { continue }
        $netBytes += $s.CookedValue
        $q = Get-SampleValue $core '*\network interface(*)\output queue length' $s.InstanceName
        if ($q -gt $netQueue) { $netQueue = $q }
    }

    # GPU (only present on GPU SKUs - NV-series etc.)
    $gpu = $null
    $gpuSamples = Get-CounterGroup @('\GPU Engine(*)\Utilization Percentage', '\GPU Adapter Memory(*)\Dedicated Usage')
    if ($gpuSamples.Count -gt 0) {
        $util3d = 0; $utilAll = 0; $dedicated = 0
        foreach ($s in $gpuSamples) {
            if ($s.Path -like '*utilization percentage') { $utilAll += $s.CookedValue; if ($s.InstanceName -like '*engtype_3d*') { $util3d += $s.CookedValue } }
            elseif ($s.Path -like '*dedicated usage') { $dedicated += $s.CookedValue }
        }
        $gpu = [ordered]@{ Util3dPct = [math]::Min(100, (Round2 $util3d)); UtilTotalPct = [math]::Min(100, (Round2 $utilAll)); DedicatedMemMB = [math]::Round($dedicated / 1MB) }
    }

    $lastBoot = $os.LastBootUpTime
    $uptimeHours = [math]::Round(((Get-Date) - $lastBoot).TotalHours, 1)
    $pending = Get-PendingReboot

    return [ordered]@{
        OsCaption      = $os.Caption
        OsBuild        = $os.BuildNumber
        Model          = $cs.Model
        Cores          = $cores
        TotalMemoryMB  = $totalMB
        CpuPct         = Get-SampleValue $core '*\processor(_total)\% processor time'
        CpuQueue       = Get-SampleValue $core '*\system\processor queue length'
        CpuQueuePerCore= if ($cores -gt 0) { Round2 ((Get-SampleValue $core '*\system\processor queue length') / $cores) } else { 0 }
        ContextSwitches= Get-SampleValue $core '*\system\context switches/sec'
        MemUsedPct     = $usedPct
        MemAvailableMB = $availMB
        MemCommittedPct= Get-SampleValue $core '*\memory\% committed bytes in use'
        PagesPerSec    = Get-SampleValue $core '*\memory\pages/sec'
        Disks          = $disks
        SysDiskFreePct = if ($sysDisk) { $sysDisk.FreePct } else { $null }
        WorstDiskLatencyMs = Round2 $worstLatency
        NetBytesPerSec = [math]::Round($netBytes)
        NetOutputQueue = Round2 $netQueue
        TcpRetransmitsPerSec = Get-SampleValue $core '*\tcpv4\segments retransmitted/sec'
        Gpu            = $gpu
        LastBoot       = $lastBoot.ToString('o')
        UptimeHours    = $uptimeHours
        PendingReboot  = ($pending.Count -gt 0)
        PendingRebootReasons = $pending
    }
}

function Get-AvdAgentStatus {
    $svc = Get-Service -Name 'RDAgentBootLoader' -ErrorAction SilentlyContinue
    $installed = ($null -ne $svc)
    $registered = $null; $version = $null
    try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RDInfraAgent' -ErrorAction Stop
        if ($null -ne $reg.IsRegistered) { $registered = ([int]$reg.IsRegistered -eq 1) }
    } catch { }
    try {
        $dir = Get-ChildItem 'C:\Program Files\Microsoft RDInfra' -Directory -Filter 'RDAgent_*' -ErrorAction Stop | Sort-Object Name -Descending | Select-Object -First 1
        if ($dir) { $version = $dir.Name -replace '^RDAgent_', '' }
    } catch { }
    $rdagentProc = Get-Process -Name 'RDAgent' -ErrorAction SilentlyContinue
    return [ordered]@{
        Installed     = $installed
        ServiceStatus = if ($svc) { $svc.Status.ToString() } else { 'NotInstalled' }
        AgentRunning  = ($null -ne $rdagentProc)
        Registered    = $registered
        Version       = $version
        Healthy       = ($installed -and $svc.Status -eq 'Running' -and ($null -ne $rdagentProc) -and ($registered -ne $false))
    }
}

function Get-FsLogixStatus {
    param([datetime]$Since)
    $svc = Get-Service -Name 'frxsvc' -ErrorAction SilentlyContinue
    if (-not $svc) { return [ordered]@{ Installed = $false } }
    $errors = @()
    try {
        $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-FSLogix-Apps/Operational'; Level = 1, 2; StartTime = $Since } -MaxEvents 50 -ErrorAction Stop
        foreach ($e in $ev) { $errors += [ordered]@{ Time = $e.TimeCreated.ToString('o'); Id = $e.Id; Message = ($e.Message -split "`n")[0].Trim() } }
    } catch { }
    $profilesEnabled = $null
    try { $profilesEnabled = ([int](Get-ItemProperty 'HKLM:\SOFTWARE\FSLogix\Profiles' -Name Enabled -ErrorAction Stop).Enabled -eq 1) } catch { }
    $version = $null
    try { $version = (Get-Item 'C:\Program Files\FSLogix\Apps\frxsvc.exe' -ErrorAction Stop).VersionInfo.ProductVersion } catch { }
    return [ordered]@{
        Installed       = $true
        Version         = $version
        ServiceStatus   = $svc.Status.ToString()
        ProfilesEnabled = $profilesEnabled
        ErrorsInInterval= $errors.Count
        RecentErrors    = $errors
    }
}

function Get-FsLogixSession {
    param([string]$Sid)
    if (-not $Sid) { return $null }
    try {
        $k = Get-ItemProperty "HKLM:\SOFTWARE\FSLogix\Profiles\Sessions\$Sid" -ErrorAction Stop
        return [ordered]@{ Attached = $true; Volume = $k.Volume; ProfilePath = $k.LoadedProfilePath; VhdPath = $k.VHDPath }
    } catch { return [ordered]@{ Attached = $false } }
}

function Get-QuserSessions {
    # Parses quser output. Columns: USERNAME SESSIONNAME ID STATE IDLE TIME LOGON TIME
    $sessions = @()
    $raw = $null
    try { $raw = & quser 2>$null } catch { }
    if (-not $raw) { return $sessions }
    foreach ($line in ($raw | Select-Object -Skip 1)) {
        if (-not $line.Trim()) { continue }
        $isCurrent = $line.StartsWith('>')
        $parts = ($line.TrimStart('>').Trim() -split '\s{2,}')
        if ($parts.Count -lt 4) { continue }
        $user = $parts[0]; $sessName = ''; $idx = 1
        if ($parts[1] -notmatch '^\d+$') { $sessName = $parts[1]; $idx = 2 }
        $id = [int]$parts[$idx]; $state = $parts[$idx + 1]; $idle = $parts[$idx + 2]; $logon = ($parts[($idx + 3)..($parts.Count - 1)] -join ' ')
        $idleMin = 0
        if ($idle -match '^(\d+)\+(\d+):(\d+)$') { $idleMin = [int]$Matches[1] * 1440 + [int]$Matches[2] * 60 + [int]$Matches[3] }
        elseif ($idle -match '^(\d+):(\d+)$') { $idleMin = [int]$Matches[1] * 60 + [int]$Matches[2] }
        elseif ($idle -match '^\d+$') { $idleMin = [int]$idle }
        $logonTime = $null; try { $logonTime = [datetime]::Parse($logon) } catch { }
        $sessions += [ordered]@{
            SessionId   = $id
            UserName    = $user
            SessionName = $sessName
            State       = if ($state -match '^Act') { 'Active' } elseif ($state -match '^Disc') { 'Disconnected' } else { $state }
            IdleMinutes = $idleMin
            LogonTime   = $logonTime
            IsConsole   = $isCurrent
        }
    }
    return $sessions
}

function Get-SessionCounters {
    # Returns hashtables keyed by trailing number of the instance name (session name number or session id).
    $net = Get-CounterGroup @(
        '\RemoteFX Network(*)\Current TCP RTT', '\RemoteFX Network(*)\Current UDP RTT',
        '\RemoteFX Network(*)\Current TCP Bandwidth', '\RemoteFX Network(*)\Current UDP Bandwidth',
        '\RemoteFX Network(*)\Total Sent Rate', '\RemoteFX Network(*)\Total Received Rate', '\RemoteFX Network(*)\Loss Rate'
    )
    $gfx = Get-CounterGroup @(
        '\RemoteFX Graphics(*)\Average Encoding Time', '\RemoteFX Graphics(*)\Output Frames/Second', '\RemoteFX Graphics(*)\Input Frames/Second',
        '\RemoteFX Graphics(*)\Frames Skipped/Second - Insufficient Server Resources',
        '\RemoteFX Graphics(*)\Frames Skipped/Second - Insufficient Network Resources',
        '\RemoteFX Graphics(*)\Frames Skipped/Second - Insufficient Client Resources'
    )
    $lag = Get-CounterGroup @('\User Input Delay per Session(*)\Max Input Delay', '\User Input Delay per Session(*)\Avg Input Delay')
    $byKey = @{}
    foreach ($s in (@($net) + @($gfx))) {
        $k = Get-TrailingNumber $s.InstanceName
        if ($k -lt 0) { continue }
        if (-not $byKey.ContainsKey($k)) { $byKey[$k] = @{} }
        $name = ($s.Path -split '\\')[-1]
        $byKey[$k][$name] = Round2 $s.CookedValue
    }
    $lagById = @{}
    foreach ($s in $lag) {
        if ($s.InstanceName -notmatch '^\d+$') { continue }
        $k = [int]$s.InstanceName
        if (-not $lagById.ContainsKey($k)) { $lagById[$k] = @{} }
        $name = ($s.Path -split '\\')[-1]
        $lagById[$k][$name] = Round2 $s.CookedValue
    }
    return @{ Proto = $byKey; Lag = $lagById; LagAvailable = ($lag.Count -gt 0) }
}

function Get-ProcessTable {
    param([int]$Cores)
    # Join perf counters (CPU %) with Get-Process (session id, memory, user).
    $cpuByPid = @{}
    $procCounters = Get-CounterGroup @('\Process(*)\% Processor Time', '\Process(*)\ID Process')
    $pidByInst = @{}
    foreach ($s in $procCounters) { if ($s.Path -like '*\id process') { $pidByInst[$s.InstanceName] = [int]$s.CookedValue } }
    foreach ($s in $procCounters) {
        if ($s.Path -like '*\% processor time' -and $pidByInst.ContainsKey($s.InstanceName)) {
            $p = $pidByInst[$s.InstanceName]
            if ($p -le 0) { continue }
            $cpuByPid[$p] = if ($Cores -gt 0) { [math]::Round($s.CookedValue / $Cores, 2) } else { Round2 $s.CookedValue }
        }
    }
    $procs = @()
    try { $procs = Get-Process -IncludeUserName -ErrorAction Stop } catch { $procs = Get-Process }
    $table = @()
    foreach ($p in $procs) {
        $cpu = 0; if ($cpuByPid.ContainsKey($p.Id)) { $cpu = $cpuByPid[$p.Id] }
        $table += [pscustomobject]@{
            Pid = $p.Id; Name = $p.ProcessName; SessionId = $p.SessionId; CpuPct = $cpu
            WorkingSetMB = [math]::Round($p.WorkingSet64 / 1MB, 1); UserName = $p.UserName
            StartTime = $(try { $p.StartTime } catch { $null }); Responding = $(try { $p.Responding } catch { $true })
        }
    }
    return $table
}

function Get-LogonBreakdown {
    # Logon phases for one session. Cached per (SessionId, LogonTime) in state because event-log queries are costly.
    param($Session, [string]$Sid, $ExplorerProc, $State)
    $key = "{0}|{1}" -f $Session.SessionId, $(if ($Session.LogonTime) { $Session.LogonTime.ToString('s') } else { 'na' })
    if ($State.Logons.ContainsKey($key)) { return $State.Logons[$key] }

    $result = [ordered]@{ TotalSec = $null; ProfileLoadSec = $null; GpoSec = $null; FsLogixSec = $null; ShellSec = $null; Method = 'none'; LogonStart = $null }
    if (-not $Session.LogonTime) { $State.Logons[$key] = $result; return $result }
    $winStart = $Session.LogonTime.AddMinutes(-2); $winEnd = $Session.LogonTime.AddMinutes(10)
    $sid = $Sid
    try {
        # LSM 21 = session logon succeeded, 22 = shell start notification received (both carry Session ID in the event data)
        $lsm = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 21, 22; StartTime = $winStart; EndTime = $winEnd } -ErrorAction Stop
        $e21 = $null; $e22 = $null
        foreach ($e in ($lsm | Sort-Object TimeCreated)) {
            $xml = [xml]$e.ToXml()
            $sidNode = $xml.Event.UserData.EventXML.SessionID
            if ([string]$sidNode -ne [string]$Session.SessionId) { continue }
            if ($e.Id -eq 21 -and -not $e21) { $e21 = $e }
            if ($e.Id -eq 22) { $e22 = $e }
        }
        if ($e21) {
            $result.LogonStart = $e21.TimeCreated.ToString('o')
            $shellTime = $null
            if ($e22) { $shellTime = $e22.TimeCreated; $result.Method = 'LSM 21->22' }
            elseif ($ExplorerProc -and $ExplorerProc.StartTime) { $shellTime = $ExplorerProc.StartTime; $result.Method = 'LSM 21->explorer' }
            if ($shellTime) { $result.TotalSec = Round2 (($shellTime - $e21.TimeCreated).TotalSeconds) }
            # Profile load: User Profile Service 1 (logon notification) -> 2 (finished)
            if ($sid) {
                try {
                    $ups = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-User Profile Service/Operational'; Id = 1, 2; StartTime = $e21.TimeCreated.AddSeconds(-5); EndTime = $winEnd; UserID = $sid } -ErrorAction Stop | Sort-Object TimeCreated
                    $p1 = $ups | Where-Object Id -eq 1 | Select-Object -First 1
                    $p2 = $ups | Where-Object Id -eq 2 | Select-Object -First 1
                    if ($p1 -and $p2) { $result.ProfileLoadSec = Round2 (($p2.TimeCreated - $p1.TimeCreated).TotalSeconds) }
                    if ($p2 -and $shellTime) { $result.ShellSec = Round2 (($shellTime - $p2.TimeCreated).TotalSeconds) }
                } catch { }
                # Group Policy 8001 = user logon policy processing completed (ElapsedTime in event data)
                try {
                    $gp = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-GroupPolicy/Operational'; Id = 8001; StartTime = $e21.TimeCreated.AddSeconds(-5); EndTime = $winEnd; UserID = $sid } -ErrorAction Stop | Select-Object -First 1
                    if ($gp) { $x = [xml]$gp.ToXml(); $d = $x.Event.EventData.Data | Where-Object { $_.Name -eq 'PolicyElaspedTimeInSeconds' -or $_.Name -eq 'PolicyElapsedTimeInSeconds' } | Select-Object -First 1; if ($d) { $result.GpoSec = [double]$d.'#text' } }
                } catch { }
                # FSLogix: span of FSLogix operational events for this SID during the logon window (approximation of container attach time)
                try {
                    $fx = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-FSLogix-Apps/Operational'; StartTime = $e21.TimeCreated.AddSeconds(-5); EndTime = $winEnd } -ErrorAction Stop | Where-Object { $_.Message -match [regex]::Escape($sid) -or $_.Message -match [regex]::Escape($Session.UserName) } | Sort-Object TimeCreated
                    if ($fx -and $fx.Count -ge 2) { $result.FsLogixSec = Round2 (($fx[-1].TimeCreated - $fx[0].TimeCreated).TotalSeconds) }
                } catch { }
            }
        } elseif ($ExplorerProc -and $ExplorerProc.StartTime) {
            $result.TotalSec = Round2 (($ExplorerProc.StartTime - $Session.LogonTime).TotalSeconds); $result.Method = 'quser->explorer (approx)'
        }
    } catch {
        if ($ExplorerProc -and $ExplorerProc.StartTime) { $result.TotalSec = Round2 (($ExplorerProc.StartTime - $Session.LogonTime).TotalSeconds); $result.Method = 'quser->explorer (approx)' }
    }
    if ($result.TotalSec -lt 0) { $result.TotalSec = $null }
    $State.Logons[$key] = $result
    return $result
}

function Get-IntervalEvents {
    param([datetime]$Since)
    $out = [ordered]@{ Disconnects = 0; Reconnects = 0; Logoffs = 0; AppCrashes = @(); AppHangs = @(); DisconnectSessions = @() }
    try {
        $lsm = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'; Id = 23, 24, 25; StartTime = $Since } -ErrorAction Stop
        foreach ($e in $lsm) {
            switch ($e.Id) {
                23 { $out.Logoffs++ }
                24 { $out.Disconnects++; try { $x = [xml]$e.ToXml(); $out.DisconnectSessions += [int]$x.Event.UserData.EventXML.SessionID } catch { } }
                25 { $out.Reconnects++ }
            }
        }
    } catch { }
    try {
        $app = Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error', 'Application Hang'; StartTime = $Since } -MaxEvents 40 -ErrorAction Stop
        foreach ($e in $app) {
            $faulting = ''; try { $faulting = [string]$e.Properties[0].Value } catch { }
            $rec = [ordered]@{ Time = $e.TimeCreated.ToString('o'); Process = $faulting; Id = $e.Id }
            if ($e.ProviderName -eq 'Application Hang') { $out.AppHangs += $rec } else { $out.AppCrashes += $rec }
        }
    } catch { }
    return $out
}

function Get-SyntheticProbe {
    $p = $script:Config.SyntheticProbePath
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json) } catch { return $null }
}

# ----------------------------------------------------------------------------------------------
# Scoring + alerting
# ----------------------------------------------------------------------------------------------
function Get-Grade { param([double]$Score) if ($Score -ge 90) { 'A' } elseif ($Score -ge 80) { 'B' } elseif ($Score -ge 70) { 'C' } elseif ($Score -ge 60) { 'D' } else { 'F' } }
function Get-Stress { param([double]$Score) if ($Score -ge 80) { 'Healthy' } elseif ($Score -ge 60) { 'Watch' } elseif ($Score -ge 40) { 'Stressed' } else { 'Critical' } }

function New-Alert {
    param([string]$Id, [string]$Severity, [string]$Scope, [string]$Target, [string]$Message, [string]$Metric, $Value, $Threshold, [string]$Remediation)
    return [ordered]@{ Id = $Id; Severity = $Severity; Scope = $Scope; Target = $Target; Message = $Message; Metric = $Metric; Value = $Value; Threshold = $Threshold; Remediation = $Remediation; Time = (Get-Date).ToString('o') }
}

function Get-SustainedAvg {
    param($State, [string]$Field, $Current)
    $vals = @(); foreach ($s in $State.Samples) { if ($null -ne $s.$Field) { $vals += [double]$s.$Field } }
    if ($null -ne $Current) { $vals += [double]$Current }
    if ($vals.Count -eq 0) { return $null }
    return [math]::Round((($vals | Measure-Object -Average).Average), 1)
}

function Invoke-HostScoring {
    param($Host_, $Avd, $Fsx, $Events, $State)
    $t = $script:Config.Thresholds
    $score = 100.0; $factors = @(); $alerts = @()
    $hn = $script:HostName

    $cpuSust = Get-SustainedAvg $State 'CpuPct' $Host_.CpuPct
    $cpuEff = [math]::Max([double]$Host_.CpuPct, [double]$cpuSust)
    if ($cpuEff -ge 95) { $score -= 40; $factors += "CPU saturated ($cpuEff%)" } elseif ($cpuEff -ge $t.CpuCrit) { $score -= 25; $factors += "CPU critical ($cpuEff%)" } elseif ($cpuEff -ge $t.CpuWarn) { $score -= 10; $factors += "CPU high ($cpuEff%)" }
    if ($cpuSust -ge $t.CpuCrit) { $alerts += New-Alert 'HOST_CPU_SUSTAINED' 'critical' 'host' $hn "CPU sustained at $cpuSust% over last $($State.Samples.Count + 1) samples" 'CpuPct' $cpuSust $t.CpuCrit 'Identify top CPU process; consider draining host / scaling out' }
    elseif ($cpuSust -ge $t.CpuWarn) { $alerts += New-Alert 'HOST_CPU_SUSTAINED' 'warning' 'host' $hn "CPU sustained at $cpuSust%" 'CpuPct' $cpuSust $t.CpuWarn 'Review top processes' }
    if ($Host_.CpuQueuePerCore -ge 2) { $score -= 10; $factors += "Run queue $($Host_.CpuQueuePerCore)/core" }

    $memSust = Get-SustainedAvg $State 'MemUsedPct' $Host_.MemUsedPct
    $memEff = [math]::Max([double]$Host_.MemUsedPct, [double]$memSust)
    if ($memEff -ge 97) { $score -= 40; $factors += "Memory exhausted ($memEff%)" } elseif ($memEff -ge $t.MemCrit) { $score -= 25; $factors += "Memory critical ($memEff%)" } elseif ($memEff -ge $t.MemWarn) { $score -= 10; $factors += "Memory high ($memEff%)" }
    if ($memSust -ge $t.MemCrit) { $alerts += New-Alert 'HOST_MEM_SUSTAINED' 'critical' 'host' $hn "Memory sustained at $memSust%" 'MemUsedPct' $memSust $t.MemCrit 'Log off disconnected sessions; check for leaking process' }
    elseif ($memSust -ge $t.MemWarn) { $alerts += New-Alert 'HOST_MEM_SUSTAINED' 'warning' 'host' $hn "Memory sustained at $memSust%" 'MemUsedPct' $memSust $t.MemWarn 'Review memory per session' }
    if ($Host_.PagesPerSec -ge 1000) { $score -= 5; $factors += "Paging $($Host_.PagesPerSec)/s" }

    $lat = [double]$Host_.WorstDiskLatencyMs
    if ($lat -ge 100) { $score -= 40; $factors += "Disk latency ${lat}ms" } elseif ($lat -ge $t.DiskLatencyCritMs) { $score -= 25; $factors += "Disk latency ${lat}ms" } elseif ($lat -ge $t.DiskLatencyWarnMs) { $score -= 10; $factors += "Disk latency ${lat}ms" }
    if ($lat -ge $t.DiskLatencyCritMs) { $alerts += New-Alert 'HOST_DISK_LATENCY' 'critical' 'host' $hn "Disk latency ${lat}ms" 'WorstDiskLatencyMs' $lat $t.DiskLatencyCritMs 'Check OS disk tier / Performance Plus; check Defender real-time scanning of CAD paths' }
    elseif ($lat -ge $t.DiskLatencyWarnMs) { $alerts += New-Alert 'HOST_DISK_LATENCY' 'warning' 'host' $hn "Disk latency ${lat}ms" 'WorstDiskLatencyMs' $lat $t.DiskLatencyWarnMs 'Watch disk queue; review IOPS burst credits' }

    if ($null -ne $Host_.SysDiskFreePct) {
        $free = [double]$Host_.SysDiskFreePct
        if ($free -le 3) { $score -= 35; $factors += "System disk $free% free" } elseif ($free -le $t.DiskFreeCritPct) { $score -= 20; $factors += "System disk $free% free" } elseif ($free -le $t.DiskFreeWarnPct) { $score -= 10; $factors += "System disk $free% free" }
        if ($free -le $t.DiskFreeCritPct) { $alerts += New-Alert 'HOST_DISK_FREE' 'critical' 'host' $hn "System disk only $free% free" 'SysDiskFreePct' $free $t.DiskFreeCritPct 'Clear temp / Windows Update cache / stale profiles' }
        elseif ($free -le $t.DiskFreeWarnPct) { $alerts += New-Alert 'HOST_DISK_FREE' 'warning' 'host' $hn "System disk $free% free" 'SysDiskFreePct' $free $t.DiskFreeWarnPct 'Schedule disk cleanup' }
    }

    if ($Host_.TcpRetransmitsPerSec -ge $t.RetransmitWarnPerSec) { $score -= 10; $factors += "TCP retransmits $($Host_.TcpRetransmitsPerSec)/s"; $alerts += New-Alert 'HOST_NET_RETRANSMIT' 'warning' 'host' $hn "TCP retransmits $($Host_.TcpRetransmitsPerSec)/s" 'TcpRetransmitsPerSec' $Host_.TcpRetransmitsPerSec $t.RetransmitWarnPerSec 'Check vNIC / NSG / accelerated networking' }

    if ($Host_.Gpu) {
        $g = [double]$Host_.Gpu.UtilTotalPct
        if ($g -ge $t.GpuCritPct) { $score -= 20; $factors += "GPU $g%"; $alerts += New-Alert 'HOST_GPU' 'critical' 'host' $hn "GPU at $g%" 'GpuUtilPct' $g $t.GpuCritPct 'Rebalance CAD sessions across GPU hosts' }
        elseif ($g -ge $t.GpuWarnPct) { $score -= 10; $factors += "GPU $g%" }
    }

    if ($Avd.Installed -and -not $Avd.Healthy) { $score -= 50; $factors += "AVD agent unhealthy ($($Avd.ServiceStatus))"; $alerts += New-Alert 'AVD_AGENT' 'critical' 'host' $hn "AVD agent unhealthy: service=$($Avd.ServiceStatus) running=$($Avd.AgentRunning) registered=$($Avd.Registered)" 'AvdAgent' $Avd.ServiceStatus 'Running' 'Restart RDAgentBootLoader; re-register host if needed' }
    if ($Fsx.Installed) {
        if ($Fsx.ServiceStatus -ne 'Running') { $score -= 30; $factors += 'FSLogix service stopped'; $alerts += New-Alert 'FSLOGIX_SERVICE' 'critical' 'host' $hn 'FSLogix service (frxsvc) not running' 'FsLogixService' $Fsx.ServiceStatus 'Running' 'Start frxsvc; check profile share reachability' }
        if ($Fsx.ErrorsInInterval -gt 0) { $d = [math]::Min(30, 10 * $Fsx.ErrorsInInterval); $score -= $d; $factors += "FSLogix errors ($($Fsx.ErrorsInInterval))"; $alerts += New-Alert 'FSLOGIX_ERRORS' 'warning' 'host' $hn "$($Fsx.ErrorsInInterval) FSLogix error(s): $($Fsx.RecentErrors[0].Message)" 'FsLogixErrors' $Fsx.ErrorsInInterval 0 'Check profile share, VHD locks, orphaned sessions' }
    }
    $crashes = $Events.AppCrashes.Count + $Events.AppHangs.Count
    if ($crashes -gt 0) { $d = [math]::Min(20, 5 * $crashes); $score -= $d; $factors += "App crashes/hangs ($crashes)"; $alerts += New-Alert 'APP_CRASH' 'warning' 'host' $hn "$crashes app crash/hang event(s): $((@($Events.AppCrashes + $Events.AppHangs) | ForEach-Object { $_.Process } | Select-Object -Unique) -join ', ')" 'AppCrashes' $crashes 0 'Review Application log; check app version / GPU driver' }
    if ($Host_.PendingReboot) { $score -= 5; $factors += 'Pending reboot'; $alerts += New-Alert 'HOST_PENDING_REBOOT' 'info' 'host' $hn "Pending reboot ($($Host_.PendingRebootReasons -join ', '))" 'PendingReboot' $true $false 'Schedule reboot in maintenance window' }
    if ($Host_.UptimeHours -ge ($t.UptimeWarnDays * 24)) { $score -= 5; $factors += "Uptime $([math]::Round($Host_.UptimeHours/24))d"; $alerts += New-Alert 'HOST_UPTIME' 'info' 'host' $hn "Host up for $([math]::Round($Host_.UptimeHours/24)) days" 'UptimeHours' $Host_.UptimeHours ($t.UptimeWarnDays * 24) 'Schedule reboot' }

    $score = [math]::Max(0, [math]::Min(100, [math]::Round($score)))
    return @{ Score = $score; Grade = (Get-Grade $score); Stress = (Get-Stress $score); Factors = $factors; Alerts = $alerts }
}

function Invoke-SessionScoring {
    param($S, [double]$HostScore, $Events)
    $t = $script:Config.Thresholds
    $score = 100.0; $factors = @(); $alerts = @()
    $target = "{0}@{1}" -f $S.UserName, $script:HostName
    if ($S.State -ne 'Active') {
        # Disconnected sessions: only resource hygiene matters
        if ($S.IdleMinutes -ge 480) { $score -= 20; $factors += "Disconnected $([math]::Round($S.IdleMinutes/60,1))h" ; $alerts += New-Alert 'SESSION_STALE_DISCONNECT' 'info' 'session' $target "Disconnected for $([math]::Round($S.IdleMinutes/60,1))h, holding $($S.MemoryMB) MB" 'IdleMinutes' $S.IdleMinutes 480 'Log off stale disconnected session' }
        $score = [math]::Max(0, [math]::Round($score))
        return @{ Score = $score; Grade = (Get-Grade $score); Stress = (Get-Stress $score); Factors = $factors; Alerts = $alerts }
    }
    $rtt = $S.RttMs
    if ($null -ne $rtt) {
        if ($rtt -ge 350) { $score -= 45; $factors += "RTT ${rtt}ms" } elseif ($rtt -ge $t.RttCritMs) { $score -= 25; $factors += "RTT ${rtt}ms" } elseif ($rtt -ge $t.RttWarnMs) { $score -= 10; $factors += "RTT ${rtt}ms" }
        if ($rtt -ge $t.RttCritMs) { $alerts += New-Alert 'SESSION_RTT' 'critical' 'session' $target "Round-trip latency ${rtt}ms ($($S.Transport))" 'RttMs' $rtt $t.RttCritMs 'Check client network / Wi-Fi; verify UDP (Shortpath) is in use' }
        elseif ($rtt -ge $t.RttWarnMs) { $alerts += New-Alert 'SESSION_RTT' 'warning' 'session' $target "Round-trip latency ${rtt}ms" 'RttMs' $rtt $t.RttWarnMs 'Check client network' }
    }
    $lag = $S.InputDelayMaxMs
    if ($null -ne $lag) {
        if ($lag -ge 2000) { $score -= 45; $factors += "Input delay ${lag}ms" } elseif ($lag -ge $t.InputDelayCritMs) { $score -= 25; $factors += "Input delay ${lag}ms" } elseif ($lag -ge $t.InputDelayWarnMs) { $score -= 10; $factors += "Input delay ${lag}ms" }
        if ($lag -ge $t.InputDelayCritMs) { $alerts += New-Alert 'SESSION_INPUT_DELAY' 'critical' 'session' $target "User input delay ${lag}ms (session feels frozen)" 'InputDelayMaxMs' $lag $t.InputDelayCritMs 'Check session CPU / host CPU; identify hung foreground app' }
        elseif ($lag -ge $t.InputDelayWarnMs) { $alerts += New-Alert 'SESSION_INPUT_DELAY' 'warning' 'session' $target "User input delay ${lag}ms" 'InputDelayMaxMs' $lag $t.InputDelayWarnMs 'Review top processes in session' }
    }
    $skip = [double]$S.FramesSkippedServer + [double]$S.FramesSkippedNetwork
    if ($skip -ge 15) { $score -= 25; $factors += "Frames skipped $skip/s" } elseif ($skip -ge 5) { $score -= 10; $factors += "Frames skipped $skip/s" }
    if ($S.FramesSkippedServer -ge 10) { $alerts += New-Alert 'SESSION_FRAMES_SERVER' 'warning' 'session' $target "Frames skipped (server resources) $($S.FramesSkippedServer)/s" 'FramesSkippedServer' $S.FramesSkippedServer 10 'Host is encoder/CPU/GPU bound' }
    if ($S.FramesSkippedNetwork -ge 10) { $alerts += New-Alert 'SESSION_FRAMES_NETWORK' 'warning' 'session' $target "Frames skipped (network) $($S.FramesSkippedNetwork)/s" 'FramesSkippedNetwork' $S.FramesSkippedNetwork 10 'Client bandwidth constrained' }
    $scpu = [double]$S.CpuPct
    if ($scpu -ge $t.SessionCpuCritPct) { $score -= 25; $factors += "Session CPU $scpu%"; $alerts += New-Alert 'SESSION_CPU' 'warning' 'session' $target "Session using $scpu% of host CPU (top: $($S.TopProcessName))" 'CpuPct' $scpu $t.SessionCpuCritPct 'Check runaway process' }
    elseif ($scpu -ge $t.SessionCpuWarnPct) { $score -= 10; $factors += "Session CPU $scpu%" }
    if ($S.MemoryMB -ge 16384) { $score -= 10; $factors += "Session memory $([math]::Round($S.MemoryMB/1024,1)) GB" } elseif ($S.MemoryMB -ge 8192) { $score -= 5; $factors += "Session memory $([math]::Round($S.MemoryMB/1024,1)) GB" }
    $lg = $S.Logon.TotalSec
    if ($null -ne $lg) {
        if ($lg -ge 180) { $score -= 40; $factors += "Logon ${lg}s" } elseif ($lg -ge $t.LogonCritSec) { $score -= 25; $factors += "Logon ${lg}s" } elseif ($lg -ge $t.LogonWarnSec) { $score -= 10; $factors += "Logon ${lg}s" }
        if ($lg -ge $t.LogonCritSec) { $alerts += New-Alert 'SESSION_LOGON_SLOW' 'warning' 'session' $target "Logon took ${lg}s (profile $($S.Logon.ProfileLoadSec)s, GPO $($S.Logon.GpoSec)s, FSLogix $($S.Logon.FsLogixSec)s)" 'LogonTotalSec' $lg $t.LogonCritSec 'Review FSLogix container size / GPO count / logon scripts' }
    }
    if ($S.NotRespondingCount -gt 0) { $score -= 15; $factors += "$($S.NotRespondingCount) app(s) not responding"; $alerts += New-Alert 'SESSION_APP_HUNG' 'warning' 'session' $target "Not responding: $($S.NotRespondingNames -join ', ')" 'NotResponding' $S.NotRespondingCount 0 'Wait / end hung process' }
    if ($Events.DisconnectSessions -contains $S.SessionId) { $score -= 10; $factors += 'Disconnected during interval' }
    if ($HostScore -lt 60) { $d = [math]::Round((60 - $HostScore) / 2); $score -= $d; $factors += "Host pressure (host score $HostScore)" }
    $score = [math]::Max(0, [math]::Min(100, [math]::Round($score)))
    return @{ Score = $score; Grade = (Get-Grade $score); Stress = (Get-Stress $score); Factors = $factors; Alerts = $alerts }
}

# ----------------------------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------------------------
function Write-AtomicFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-Snapshot {
    param($Snapshot, $HistoryLine)
    $json = $Snapshot | ConvertTo-Json -Depth 12
    $day = Get-Date -Format 'yyyy-MM-dd'
    foreach ($root in @($script:Config.OutputPath, $script:Config.SharePath)) {
        if (-not $root) { continue }
        try {
            Write-AtomicFile (Join-Path $root "latest\$script:HostName.json") $json
            $hDir = Join-Path $root "history\$script:HostName"
            if (-not (Test-Path -LiteralPath $hDir)) { New-Item -ItemType Directory -Path $hDir -Force | Out-Null }
            Add-Content -LiteralPath (Join-Path $hDir "$day.jsonl") -Value $HistoryLine -Encoding UTF8
        } catch { Write-DexLog "Write to $root failed: $($_.Exception.Message)" 'WARN' }
    }
    $keep = [int]$script:Config.HistoryRetentionDays
    if ($keep -gt 0) {
        try {
            $hDir = Join-Path $script:Config.OutputPath "history\$script:HostName"
            Get-ChildItem -LiteralPath $hDir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$keep) } | Remove-Item -Force -ErrorAction SilentlyContinue
        } catch { }
    }
}

function Send-Alerts {
    param($Snapshot)
    $alerts = @($Snapshot.Alerts)
    if ($alerts.Count -eq 0) { return }
    $rank = @{ info = 0; warning = 1; critical = 2 }
    if ($script:Config.WriteEventLog) {
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('AvdDex Agent')) { New-EventLog -LogName Application -Source 'AvdDex Agent' -ErrorAction Stop }
            foreach ($a in $alerts) {
                if ($a.Severity -eq 'info') { continue }
                $type = if ($a.Severity -eq 'critical') { 'Error' } else { 'Warning' }
                $id = if ($a.Severity -eq 'critical') { 1002 } else { 1001 }
                Write-EventLog -LogName Application -Source 'AvdDex Agent' -EntryType $type -EventId $id -Message ("[{0}] {1} | {2} | {3}={4} (threshold {5}) | Remediation: {6}" -f $a.Id, $a.Target, $a.Message, $a.Metric, $a.Value, $a.Threshold, $a.Remediation) -ErrorAction Stop
            }
        } catch { Write-DexLog "Event log write failed: $($_.Exception.Message)" 'WARN' }
    }
    if ($script:Config.WebhookUrl) {
        $min = $rank[[string]$script:Config.WebhookMinSeverity]; if ($null -eq $min) { $min = 1 }
        $send = @($alerts | Where-Object { $rank[[string]$_.Severity] -ge $min })
        if ($send.Count -gt 0) {
            $body = [ordered]@{ source = 'AvdDex Agent'; host = $script:HostName; hostPool = $script:Config.HostPool; timestamp = $Snapshot.Timestamp; hostScore = $Snapshot.Score.Score; alerts = $send } | ConvertTo-Json -Depth 6
            try { Invoke-RestMethod -Uri $script:Config.WebhookUrl -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 10 -ErrorAction Stop | Out-Null } catch { Write-DexLog "Webhook failed: $($_.Exception.Message)" 'WARN' }
        }
    }
}

# ----------------------------------------------------------------------------------------------
# One collection cycle
# ----------------------------------------------------------------------------------------------
function Invoke-DexCycle {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $state = Load-State
    $now = Get-Date
    $since = if ($state.LastRun) { $state.LastRun } else { $now.AddSeconds(-$script:Config.IntervalSeconds) }
    if (($now - $since).TotalMinutes -gt 30) { $since = $now.AddMinutes(-30) }

    $hostM  = Get-HostMetrics
    $avd    = Get-AvdAgentStatus
    $fsx    = Get-FsLogixStatus -Since $since
    $events = Get-IntervalEvents -Since $since
    $qs     = Get-QuserSessions
    $sc     = Get-SessionCounters
    $procs  = Get-ProcessTable -Cores $hostM.Cores

    $hostScore = Invoke-HostScoring -Host_ $hostM -Avd $avd -Fsx $fsx -Events $events -State $state
    $allAlerts = @($hostScore.Alerts)
    $sessions = @()
    foreach ($q in $qs) {
        $sid = $null; $fullUser = $q.UserName
        $sessProcs = @($procs | Where-Object { $_.SessionId -eq $q.SessionId })
        $explorer = $sessProcs | Where-Object { $_.Name -eq 'explorer' } | Sort-Object StartTime | Select-Object -First 1
        if ($explorer -and $explorer.UserName) { $fullUser = $explorer.UserName }
        try { $sid = (New-Object System.Security.Principal.NTAccount($fullUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { }
        $cpu = 0; $mem = 0; foreach ($p in $sessProcs) { $cpu += $p.CpuPct; $mem += $p.WorkingSetMB }
        $top = @($sessProcs | Sort-Object CpuPct, WorkingSetMB -Descending | Select-Object -First $script:Config.TopProcesses | ForEach-Object { [ordered]@{ Name = $_.Name; Pid = $_.Pid; CpuPct = $_.CpuPct; WorkingSetMB = $_.WorkingSetMB; Responding = $_.Responding } })
        $hung = @($sessProcs | Where-Object { -not $_.Responding -and $_.Name -notmatch '^(explorer|ApplicationFrameHost)$' })
        $key = Get-TrailingNumber $q.SessionName; if ($key -lt 0) { $key = $q.SessionId }
        $proto = $null; if ($sc.Proto.ContainsKey($key)) { $proto = $sc.Proto[$key] } elseif ($sc.Proto.ContainsKey($q.SessionId)) { $proto = $sc.Proto[$q.SessionId] }
        $lag = $null; if ($sc.Lag.ContainsKey($q.SessionId)) { $lag = $sc.Lag[$q.SessionId] }
        $tcpRtt = $null; $udpRtt = $null; $transport = 'n/a'
        if ($proto) {
            $tcpRtt = $proto['Current TCP RTT']; $udpRtt = $proto['Current UDP RTT']
            if ($udpRtt -gt 0) { $transport = 'UDP (Shortpath)' } elseif ($tcpRtt -gt 0) { $transport = 'TCP' }
        }
        $rtt = if ($udpRtt -gt 0) { $udpRtt } elseif ($tcpRtt -gt 0) { $tcpRtt } else { $null }
        $logon = Get-LogonBreakdown -Session $q -Sid $sid -ExplorerProc $explorer -State $state
        $s = [ordered]@{
            SessionId   = $q.SessionId
            UserName    = $fullUser
            Sid         = $sid
            SessionName = $q.SessionName
            State       = $q.State
            IdleMinutes = $q.IdleMinutes
            LogonTime   = if ($q.LogonTime) { $q.LogonTime.ToString('o') } else { $null }
            Transport   = $transport
            RttMs       = $rtt
            TcpRttMs    = $tcpRtt
            UdpRttMs    = $udpRtt
            BandwidthKbps = if ($proto) { Round2 (([double]$proto['Current TCP Bandwidth'] + [double]$proto['Current UDP Bandwidth']) / 1000) } else { $null }
            SentKbps    = if ($proto) { Round2 ([double]$proto['Total Sent Rate'] * 8 / 1000) } else { $null }
            LossRate    = if ($proto) { $proto['Loss Rate'] } else { $null }
            InputDelayMaxMs = if ($lag) { $lag['Max Input Delay'] } else { $null }
            InputDelayAvgMs = if ($lag) { $lag['Avg Input Delay'] } else { $null }
            EncodingTimeMs  = if ($proto) { $proto['Average Encoding Time'] } else { $null }
            OutputFps       = if ($proto) { $proto['Output Frames/Second'] } else { $null }
            InputFps        = if ($proto) { $proto['Input Frames/Second'] } else { $null }
            FramesSkippedServer  = if ($proto) { $proto['Frames Skipped/Second - Insufficient Server Resources'] } else { 0 }
            FramesSkippedNetwork = if ($proto) { $proto['Frames Skipped/Second - Insufficient Network Resources'] } else { 0 }
            FramesSkippedClient  = if ($proto) { $proto['Frames Skipped/Second - Insufficient Client Resources'] } else { 0 }
            CpuPct      = Round2 $cpu
            MemoryMB    = [math]::Round($mem)
            ProcessCount= $sessProcs.Count
            TopProcessName = if ($top.Count -gt 0) { $top[0].Name } else { $null }
            TopProcesses= $top
            NotRespondingCount = $hung.Count
            NotRespondingNames = @($hung | ForEach-Object { $_.Name } | Select-Object -Unique)
            FsLogix     = Get-FsLogixSession -Sid $sid
            Logon       = $logon
        }
        $ss = Invoke-SessionScoring -S $s -HostScore $hostScore.Score -Events $events
        $s.Score = [ordered]@{ Score = $ss.Score; Grade = $ss.Grade; Stress = $ss.Stress; Factors = $ss.Factors }
        $allAlerts += $ss.Alerts
        $sessions += $s
    }
    # Host-level top processes (any session) for root-cause view
    $hostTop = @($procs | Sort-Object CpuPct, WorkingSetMB -Descending | Select-Object -First 10 | ForEach-Object { [ordered]@{ Name = $_.Name; Pid = $_.Pid; SessionId = $_.SessionId; UserName = $_.UserName; CpuPct = $_.CpuPct; WorkingSetMB = $_.WorkingSetMB } })

    $active = @($sessions | Where-Object { $_.State -eq 'Active' })
    $avgSess = if ($active.Count -gt 0) { [math]::Round((($active | ForEach-Object { $_.Score.Score }) | Measure-Object -Average).Average) } else { $null }
    $snapshot = [ordered]@{
        SchemaVersion = 1
        AgentVersion  = $script:AgentVersion
        Timestamp     = $now.ToString('o')
        Host          = $script:HostName
        HostPool      = $script:Config.HostPool
        Tags          = @($script:Config.Tags)
        CollectionMs  = 0
        Score         = [ordered]@{ Score = $hostScore.Score; Grade = $hostScore.Grade; Stress = $hostScore.Stress; Factors = $hostScore.Factors; AvgSessionScore = $avgSess }
        Metrics       = $hostM
        AvdAgent      = $avd
        FsLogix       = $fsx
        Events        = [ordered]@{ Since = $since.ToString('o'); Disconnects = $events.Disconnects; Reconnects = $events.Reconnects; Logoffs = $events.Logoffs; AppCrashes = $events.AppCrashes; AppHangs = $events.AppHangs }
        Capabilities  = [ordered]@{ InputDelayCounters = $sc.LagAvailable; Gpu = ($null -ne $hostM.Gpu); FsLogix = $fsx.Installed }
        SessionSummary= [ordered]@{ Total = $sessions.Count; Active = $active.Count; Disconnected = @($sessions | Where-Object { $_.State -eq 'Disconnected' }).Count }
        Sessions      = $sessions
        TopProcesses  = $hostTop
        Alerts        = $allAlerts
        SyntheticProbe= Get-SyntheticProbe
    }
    $snapshot.CollectionMs = $sw.ElapsedMilliseconds

    # Compact history line for trending
    $hist = [ordered]@{
        t = $now.ToString('o'); score = $hostScore.Score; cpu = $hostM.CpuPct; mem = $hostM.MemUsedPct; dlat = $hostM.WorstDiskLatencyMs; dfree = $hostM.SysDiskFreePct
        net = $hostM.NetBytesPerSec; gpu = $(if ($hostM.Gpu) { $hostM.Gpu.UtilTotalPct } else { $null }); sess = $sessions.Count; act = $active.Count; alerts = $allAlerts.Count
        s = @($sessions | ForEach-Object { [ordered]@{ u = $_.UserName; id = $_.SessionId; st = $_.State.Substring(0,1); sc = $_.Score.Score; rtt = $_.RttMs; lag = $_.InputDelayMaxMs; cpu = $_.CpuPct; mem = $_.MemoryMB; lg = $_.Logon.TotalSec; top = $_.TopProcessName } })
    }
    Write-Snapshot -Snapshot $snapshot -HistoryLine ($hist | ConvertTo-Json -Depth 5 -Compress)
    Send-Alerts -Snapshot $snapshot

    # Rolling samples for sustained logic
    $samples = @($state.Samples) + @([ordered]@{ t = $now.ToString('o'); CpuPct = $hostM.CpuPct; MemUsedPct = $hostM.MemUsedPct })
    $n = [int]$script:Config.SustainedSamples; if ($n -lt 2) { $n = 2 }
    if ($samples.Count -gt ($n - 1)) { $samples = $samples[($samples.Count - ($n - 1))..($samples.Count - 1)] }
    $state.Samples = $samples
    $state.LastRun = $now
    # Prune logon cache for sessions that are gone
    $live = @{}; foreach ($q in $qs) { $live["{0}|{1}" -f $q.SessionId, $(if ($q.LogonTime) { $q.LogonTime.ToString('s') } else { 'na' })] = $true }
    $keys = @($state.Logons.Keys); foreach ($k in $keys) { if (-not $live.ContainsKey($k)) { $state.Logons.Remove($k) } }
    Save-State $state

    Write-DexLog ("Cycle done in {0}ms: host score {1} ({2}), {3} sessions, {4} alerts" -f $snapshot.CollectionMs, $hostScore.Score, $hostScore.Stress, $sessions.Count, $allAlerts.Count)
    return $snapshot
}

# ----------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------
$script:Config = Get-DexConfig
if (-not (Test-Path -LiteralPath $script:Config.OutputPath)) { New-Item -ItemType Directory -Path $script:Config.OutputPath -Force | Out-Null }
Write-DexLog "AvdDex Agent v$script:AgentVersion starting on $script:HostName (interval $($script:Config.IntervalSeconds)s, share '$($script:Config.SharePath)')"

$mutex = New-Object System.Threading.Mutex($false, 'Global\AvdDexAgent')
if (-not $mutex.WaitOne(0)) { Write-DexLog 'Another instance is already running - exiting' 'WARN'; exit 0 }
try {
    if ($Once) {
        $snap = Invoke-DexCycle
        Write-Output ("Host {0}: score {1} ({2}) - {3} sessions, {4} alerts" -f $snap.Host, $snap.Score.Score, $snap.Score.Stress, $snap.SessionSummary.Total, $snap.Alerts.Count)
        foreach ($a in $snap.Alerts) { Write-Output ("  [{0}] {1}: {2}" -f $a.Severity.ToUpper(), $a.Target, $a.Message) }
        exit 0
    }
    while ($true) {
        $started = Get-Date
        try { Invoke-DexCycle | Out-Null } catch { Write-DexLog "Cycle failed: $($_.Exception.Message) $($_.ScriptStackTrace)" 'ERROR' }
        # Re-read config each cycle so interval / share / thresholds can change without a restart
        try { $script:Config = Get-DexConfig } catch { }
        $elapsed = ((Get-Date) - $started).TotalSeconds
        $sleep = [math]::Max(5, $script:Config.IntervalSeconds - $elapsed)
        Start-Sleep -Seconds $sleep
    }
} finally { try { $mutex.ReleaseMutex() } catch { } }
