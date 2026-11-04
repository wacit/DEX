#Requires -Version 5.1
<#
.SYNOPSIS
    AvdDex "monitor" - aggregates every host's agent output into fleet.json / trends.json for the dashboard.

.DESCRIPTION
    Run on a schedule (every 2-5 min) on any machine that can read the DEX share - a Proxmox VM, the
    Grafana box, or a utility server. It is the ControlUp "Monitor" equivalent:

      <SharePath>\latest\*.json            ->  <OutputPath>\fleet.json      (live fleet state + summary + right-sizing)
      <SharePath>\history\<HOST>\*.jsonl   ->  <OutputPath>\trends.json     (hourly + daily rollups, logons, app usage, alert history)
                                           ->  <OutputPath>\rollups\...      (cached per-host per-day rollups so a year of history stays cheap)
                                           ->  <OutputPath>\alerts\<date>.jsonl (de-duplicated alert history)
                                           ->  <OutputPath>\reports\*.csv    (daily CSV exports)

    Nothing is ever deleted by this script.

.EXAMPLE
    .\Merge-AvdDexFleet.ps1 -SharePath '\\fileserver\AvdDex'
    .\Merge-AvdDexFleet.ps1 -SharePath 'C:\ProgramData\AvdDex' -OutputPath 'C:\inetpub\dex'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SharePath,
    [string]$OutputPath = $SharePath,
    [int]$TrendDays = 7,            # hourly resolution window
    [int]$DailyDays = 90,           # daily resolution window (from cached rollups)
    [string]$OrgName = '',          # shown in the dashboard header
    [int]$StaleMinutes = 5,
    [int]$AgentIntervalSeconds = 30, # used to turn sample counts into app-usage minutes
    [switch]$SkipCsv
)
$ErrorActionPreference = 'Continue'
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$now = Get-Date

# ---------------------------------------------------------------- fast JSON line parser (JavaScriptSerializer on 5.1, ConvertFrom-Json on 7)
$script:Ser = $null
try { Add-Type -AssemblyName System.Web.Extensions -ErrorAction Stop; $script:Ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $script:Ser.MaxJsonLength = [int]::MaxValue } catch { }
function Parse-Line { param([string]$Line) if ($script:Ser) { try { return $script:Ser.DeserializeObject($Line) } catch { return $null } } else { try { return ($Line | ConvertFrom-Json) } catch { return $null } } }
function V { param($O, [string]$K) if ($null -eq $O) { return $null } ; if ($O -is [System.Collections.IDictionary]) { if ($O.Contains($K)) { return $O[$K] } else { return $null } } ; return $O.$K }
function Avg { param($Arr) $a = @($Arr | Where-Object { $null -ne $_ }); if ($a.Count -eq 0) { return $null } ; return [math]::Round((($a | Measure-Object -Average).Average), 1) }
function Pct { param($Arr, [double]$P = 0.95) $a = @($Arr | Where-Object { $null -ne $_ } | Sort-Object); if ($a.Count -eq 0) { return $null } ; $i = [math]::Max(0, [math]::Ceiling($P * $a.Count) - 1); return [math]::Round([double]$a[$i], 1) }
function Mx { param($Arr) $a = @($Arr | Where-Object { $null -ne $_ }); if ($a.Count -eq 0) { return $null } ; return ($a | Measure-Object -Maximum).Maximum }
function Mn { param($Arr) $a = @($Arr | Where-Object { $null -ne $_ }); if ($a.Count -eq 0) { return $null } ; return ($a | Measure-Object -Minimum).Minimum }
function Ensure-Dir { param([string]$P) if (-not (Test-Path -LiteralPath $P)) { New-Item -ItemType Directory -Path $P -Force | Out-Null } }
function Read-Lines {
    # Opens with FileShare.ReadWrite so agents can keep appending while the file is read.
    param([string]$Path)
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
    try { while ($null -ne ($l = $sr.ReadLine())) { $l } } finally { $sr.Dispose(); $fs.Dispose() }
}
function Write-Json { param([string]$Path, $Obj, [int]$Depth = 10) Ensure-Dir (Split-Path $Path -Parent); $tmp = "$Path.tmp"; ($Obj | ConvertTo-Json -Depth $Depth -Compress) | Set-Content -LiteralPath $tmp -Encoding UTF8; Move-Item -LiteralPath $tmp -Destination $Path -Force }

foreach ($d in @('rollups\hourly', 'alerts', 'reports')) { Ensure-Dir (Join-Path $OutputPath $d) }

# ---------------------------------------------------------------- 1. fleet.json from latest\*.json
$hosts = @()
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $SharePath 'latest') -Filter '*.json' -ErrorAction SilentlyContinue)) {
    try {
        $s = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = [math]::Round(($now - [datetime]$s.Timestamp).TotalSeconds)
        $s | Add-Member -NotePropertyName AgeSeconds -NotePropertyValue $age -Force
        $s | Add-Member -NotePropertyName Stale -NotePropertyValue ($age -gt ($StaleMinutes * 60)) -Force
        $hosts += $s
    } catch { Write-Warning "Skipping $($f.Name): $($_.Exception.Message)" }
}
$hosts = @($hosts | Sort-Object Host)
$online = @($hosts | Where-Object { -not $_.Stale })
$allSessions = @(); foreach ($h in $online) { foreach ($s in @($h.Sessions)) { $allSessions += $s } }
$activeSessions = @($allSessions | Where-Object { $_.State -eq 'Active' })
$allAlerts = @(); foreach ($h in $online) { foreach ($a in @($h.Alerts)) { $a | Add-Member -NotePropertyName Host -NotePropertyValue $h.Host -Force; $a | Add-Member -NotePropertyName HostPool -NotePropertyValue $h.HostPool -Force; $allAlerts += $a } }
$stress = @{ Healthy = 0; Watch = 0; Stressed = 0; Critical = 0 }
foreach ($h in $online) { $k = [string]$h.Score.Stress; if ($stress.ContainsKey($k)) { $stress[$k]++ } }
$pools = @($hosts | ForEach-Object { $_.HostPool } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)

# ---------------------------------------------------------------- 2. alert history (de-dup against previous fleet.json)
$prevKeys = @{}
$fleetPath = Join-Path $OutputPath 'fleet.json'
if (Test-Path -LiteralPath $fleetPath) {
    try { $prev = Get-Content -LiteralPath $fleetPath -Raw | ConvertFrom-Json; foreach ($h in @($prev.Hosts)) { foreach ($a in @($h.Alerts)) { $prevKeys["{0}|{1}|{2}" -f $h.Host, $a.Id, $a.Target] = $true } } } catch { }
}
$newAlerts = @()
foreach ($a in $allAlerts) { $k = "{0}|{1}|{2}" -f $a.Host, $a.Id, $a.Target; if (-not $prevKeys.ContainsKey($k)) { $newAlerts += $a } }
if ($newAlerts.Count -gt 0) {
    $af = Join-Path $OutputPath ("alerts\{0}.jsonl" -f $now.ToString('yyyy-MM-dd'))
    foreach ($a in $newAlerts) { Add-Content -LiteralPath $af -Value (([ordered]@{ t = $a.Time; host = $a.Host; pool = $a.HostPool; id = $a.Id; sev = $a.Severity; scope = $a.Scope; target = $a.Target; msg = $a.Message; metric = $a.Metric; value = $a.Value; threshold = $a.Threshold; fix = $a.Remediation }) | ConvertTo-Json -Compress) -Encoding UTF8 }
}

# ---------------------------------------------------------------- 3. history rollups
function Get-DayRollup {
    param([string]$HostName, [string]$Day)   # Day = yyyy-MM-dd
    $cache = Join-Path $OutputPath "rollups\hourly\$HostName`_$Day.json"
    $isToday = ($Day -eq $now.ToString('yyyy-MM-dd'))
    if (-not $isToday -and (Test-Path -LiteralPath $cache)) { try { return (Get-Content -LiteralPath $cache -Raw | ConvertFrom-Json) } catch { } }
    $raw = Join-Path $SharePath "history\$HostName\$Day.jsonl"
    if (-not (Test-Path -LiteralPath $raw)) { return $null }
    $buckets = @{}; $logons = @{}; $apps = @{}
    foreach ($line in (Read-Lines $raw)) {
        if (-not $line) { continue }
        $o = Parse-Line $line; if ($null -eq $o) { continue }
        $t = [string](V $o 't'); if ($t.Length -lt 13) { continue }
        $hk = $t.Substring(0, 13)
        if (-not $buckets.ContainsKey($hk)) { $buckets[$hk] = @{ cpu = @(); mem = @(); dlat = @(); score = @(); sess = @(); act = @(); sscore = @(); rtt = @(); lag = @(); alerts = 0; n = 0; gpu = @() } }
        $b = $buckets[$hk]; $b.n++
        $b.cpu += V $o 'cpu'; $b.mem += V $o 'mem'; $b.dlat += V $o 'dlat'; $b.score += V $o 'score'; $b.sess += V $o 'sess'; $b.act += V $o 'act'; $b.gpu += V $o 'gpu'
        $b.alerts += [int](V $o 'alerts')
        foreach ($s in @(V $o 's')) {
            if ($null -eq $s) { continue }
            if ((V $s 'st') -eq 'A') { $b.sscore += V $s 'sc'; $b.rtt += V $s 'rtt'; $b.lag += V $s 'lag' }
            $lg = V $s 'lg'; $u = [string](V $s 'u')
            if ($null -ne $lg) { $lk = "{0}|{1}|{2}" -f (V $s 'id'), $u, $lg; if (-not $logons.ContainsKey($lk)) { $logons[$lk] = [ordered]@{ host = $HostName; u = $u; t = $t; lg = [double]$lg } } }
            $top = [string](V $s 'top'); if ($top -and (V $s 'st') -eq 'A') { if (-not $apps.ContainsKey($top)) { $apps[$top] = @{ n = 0; users = @{} } }; $apps[$top].n++; $apps[$top].users[$u] = $true }
        }
    }
    $hourly = @()
    foreach ($hk in ($buckets.Keys | Sort-Object)) {
        $b = $buckets[$hk]
        $hourly += [ordered]@{ t = "$hk:00:00"; n = $b.n; cpuAvg = Avg $b.cpu; cpuP95 = Pct $b.cpu; memAvg = Avg $b.mem; memP95 = Pct $b.mem; dlatAvg = Avg $b.dlat; dlatP95 = Pct $b.dlat; gpuP95 = Pct $b.gpu
            scoreAvg = Avg $b.score; scoreMin = Mn $b.score; sessAvg = Avg $b.sess; sessMax = Mx $b.sess; actMax = Mx $b.act; sscoreAvg = Avg $b.sscore; rttAvg = Avg $b.rtt; rttP95 = Pct $b.rtt; lagAvg = Avg $b.lag; lagP95 = Pct $b.lag; alerts = $b.alerts }
    }
    $appList = @(); foreach ($k in $apps.Keys) { $appList += [ordered]@{ name = $k; minutes = [math]::Round($apps[$k].n * $AgentIntervalSeconds / 60); users = $apps[$k].users.Count } }
    $roll = [ordered]@{ host = $HostName; day = $Day; hourly = $hourly; logons = @($logons.Values); apps = $appList }
    if (-not $isToday) { try { Write-Json $cache $roll 6 } catch { } }
    return $roll
}

$hourlyByHost = @{}; $dailyByHost = @{}; $allLogons = @(); $appTotals = @{}
$hostDirs = @(Get-ChildItem -LiteralPath (Join-Path $SharePath 'history') -Directory -ErrorAction SilentlyContinue)
foreach ($hd in $hostDirs) {
    $hn = $hd.Name; $hourlyByHost[$hn] = @(); $dailyByHost[$hn] = @()
    for ($i = $DailyDays - 1; $i -ge 0; $i--) {
        $day = $now.AddDays(-$i).ToString('yyyy-MM-dd')
        $r = Get-DayRollup -HostName $hn -Day $day
        if ($null -eq $r) { continue }
        $hr = @($r.hourly)
        if ($hr.Count -eq 0) { continue }
        $lgs = @($r.logons | ForEach-Object { $_.lg })
        $dailyByHost[$hn] += [ordered]@{ d = $day; cpuAvg = Avg ($hr | ForEach-Object { $_.cpuAvg }); cpuP95 = Mx ($hr | ForEach-Object { $_.cpuP95 }); memAvg = Avg ($hr | ForEach-Object { $_.memAvg }); memP95 = Mx ($hr | ForEach-Object { $_.memP95 })
            dlatP95 = Mx ($hr | ForEach-Object { $_.dlatP95 }); scoreAvg = Avg ($hr | ForEach-Object { $_.scoreAvg }); scoreMin = Mn ($hr | ForEach-Object { $_.scoreMin }); sessMax = Mx ($hr | ForEach-Object { $_.sessMax }); sscoreAvg = Avg ($hr | ForEach-Object { $_.sscoreAvg })
            rttP95 = Mx ($hr | ForEach-Object { $_.rttP95 }); lagP95 = Mx ($hr | ForEach-Object { $_.lagP95 }); alerts = (($hr | ForEach-Object { [int]$_.alerts }) | Measure-Object -Sum).Sum; logons = $lgs.Count; logonAvg = Avg $lgs; logonP95 = Pct $lgs }
        if ($i -lt $TrendDays) {
            $hourlyByHost[$hn] += $hr
            $allLogons += @($r.logons)
            foreach ($a in @($r.apps)) { if (-not $appTotals.ContainsKey($a.name)) { $appTotals[$a.name] = @{ minutes = 0; users = 0 } }; $appTotals[$a.name].minutes += [int]$a.minutes; $appTotals[$a.name].users = [math]::Max($appTotals[$a.name].users, [int]$a.users) }
        }
    }
}
$apps = @($appTotals.Keys | ForEach-Object { [ordered]@{ name = $_; minutes = $appTotals[$_].minutes; users = $appTotals[$_].users } } | Sort-Object { $_.minutes } -Descending | Select-Object -First 30)

# ---------------------------------------------------------------- 4. right-sizing (ControlUp-style utilization suggestions)
$rightSizing = @()
foreach ($h in $hosts) {
    $hr = @($hourlyByHost[[string]$h.Host])
    if ($hr.Count -lt 6) { $rightSizing += [ordered]@{ Host = $h.Host; HostPool = $h.HostPool; Cores = $h.Metrics.Cores; MemGB = [math]::Round($h.Metrics.TotalMemoryMB / 1024); Suggestion = 'Insufficient data'; Reason = "$($hr.Count) hourly samples"; CpuP95 = $null; MemP95 = $null; PeakSessions = $null; AvgSessions = $null }; continue }
    $cpu95 = Pct ($hr | ForEach-Object { $_.cpuP95 }); $mem95 = Pct ($hr | ForEach-Object { $_.memP95 }); $peak = Mx ($hr | ForEach-Object { $_.sessMax }); $avgS = Avg ($hr | ForEach-Object { $_.sessAvg })
    $busy = @($hr | Where-Object { $_.sessAvg -ge 1 })
    $cpuBusy = if ($busy.Count -gt 0) { Pct ($busy | ForEach-Object { $_.cpuP95 }) } else { $cpu95 }
    $sug = 'Right-sized'; $why = "P95 CPU $cpu95%, P95 memory $mem95%, peak $peak sessions"
    if ($cpu95 -ge 85 -or $mem95 -ge 88) { $sug = 'Scale up / add host'; $why = "Sustained pressure: P95 CPU $cpu95%, P95 memory $mem95% (peak $peak sessions)" }
    elseif ($cpu95 -le 35 -and $mem95 -le 50) { $sug = 'Downsize candidate'; $why = "Low utilization: P95 CPU $cpu95%, P95 memory $mem95% while hosting up to $peak sessions" }
    elseif ($avgS -lt 0.5 -and $hr.Count -ge 24) { $sug = 'Idle - consider deallocating'; $why = "Averaged $avgS sessions over the window" }
    $rightSizing += [ordered]@{ Host = $h.Host; HostPool = $h.HostPool; Cores = $h.Metrics.Cores; MemGB = [math]::Round($h.Metrics.TotalMemoryMB / 1024); CpuP95 = $cpu95; CpuP95Busy = $cpuBusy; MemP95 = $mem95; PeakSessions = $peak; AvgSessions = $avgS; MemPerSessionGB = $(if ($peak -gt 0) { [math]::Round(($h.Metrics.TotalMemoryMB * $mem95 / 100) / 1024 / $peak, 1) } else { $null }); Suggestion = $sug; Reason = $why }
}

# ---------------------------------------------------------------- 5. alert history for the dashboard
$alertHistory = @()
for ($i = $TrendDays - 1; $i -ge 0; $i--) {
    $af = Join-Path $OutputPath ("alerts\{0}.jsonl" -f $now.AddDays(-$i).ToString('yyyy-MM-dd'))
    if (Test-Path -LiteralPath $af) { foreach ($line in (Read-Lines $af)) { if ($line) { $o = Parse-Line $line; if ($o) { $alertHistory += $o } } } }
}
if ($alertHistory.Count -gt 3000) { $alertHistory = $alertHistory[($alertHistory.Count - 3000)..($alertHistory.Count - 1)] }

# ---------------------------------------------------------------- 6. write outputs
$fleet = [ordered]@{
    SchemaVersion = 1; GeneratedAt = $now.ToString('o'); GeneratedBy = $env:COMPUTERNAME; OrgName = $OrgName; StaleMinutes = $StaleMinutes; MergeMs = 0
    Summary = [ordered]@{
        Hosts = $hosts.Count; Online = $online.Count; Stale = ($hosts.Count - $online.Count)
        Sessions = $allSessions.Count; ActiveSessions = $activeSessions.Count; DisconnectedSessions = ($allSessions.Count - $activeSessions.Count)
        AvgHostScore = Avg ($online | ForEach-Object { $_.Score.Score }); AvgSessionScore = Avg ($activeSessions | ForEach-Object { $_.Score.Score })
        Stress = $stress
        Alerts = [ordered]@{ critical = @($allAlerts | Where-Object { $_.Severity -eq 'critical' }).Count; warning = @($allAlerts | Where-Object { $_.Severity -eq 'warning' }).Count; info = @($allAlerts | Where-Object { $_.Severity -eq 'info' }).Count }
        Pools = $pools
    }
    Hosts = $hosts
    RightSizing = $rightSizing
}
$fleet.MergeMs = $sw.ElapsedMilliseconds
Write-Json $fleetPath $fleet 14
$trends = [ordered]@{ SchemaVersion = 1; GeneratedAt = $now.ToString('o'); TrendDays = $TrendDays; DailyDays = $DailyDays; Hourly = $hourlyByHost; Daily = $dailyByHost; Logons = @($allLogons | Sort-Object { $_.t } -Descending | Select-Object -First 2000); Apps = $apps; AlertHistory = $alertHistory }
Write-Json (Join-Path $OutputPath 'trends.json') $trends 8

if (-not $SkipCsv) {
    $stamp = $now.ToString('yyyy-MM-dd')
    $hosts | ForEach-Object { [pscustomobject]@{ Time = $_.Timestamp; Host = $_.Host; HostPool = $_.HostPool; Stale = $_.Stale; Score = $_.Score.Score; Grade = $_.Score.Grade; Stress = $_.Score.Stress; CpuPct = $_.Metrics.CpuPct; MemUsedPct = $_.Metrics.MemUsedPct; DiskLatencyMs = $_.Metrics.WorstDiskLatencyMs; SysDiskFreePct = $_.Metrics.SysDiskFreePct; Sessions = $_.SessionSummary.Total; Active = $_.SessionSummary.Active; Alerts = @($_.Alerts).Count; AvdAgentHealthy = $_.AvdAgent.Healthy; PendingReboot = $_.Metrics.PendingReboot; UptimeHours = $_.Metrics.UptimeHours } } | Export-Csv -LiteralPath (Join-Path $OutputPath "reports\hosts-$stamp.csv") -NoTypeInformation -Encoding UTF8
    $rows = @(); foreach ($h in $hosts) { foreach ($s in @($h.Sessions)) { $rows += [pscustomobject]@{ Time = $h.Timestamp; Host = $h.Host; HostPool = $h.HostPool; User = $s.UserName; SessionId = $s.SessionId; State = $s.State; Score = $s.Score.Score; Stress = $s.Score.Stress; Transport = $s.Transport; RttMs = $s.RttMs; InputDelayMaxMs = $s.InputDelayMaxMs; CpuPct = $s.CpuPct; MemoryMB = $s.MemoryMB; LogonSec = $s.Logon.TotalSec; ProfileLoadSec = $s.Logon.ProfileLoadSec; GpoSec = $s.Logon.GpoSec; FsLogixSec = $s.Logon.FsLogixSec; TopProcess = $s.TopProcessName; Factors = ($s.Score.Factors -join '; ') } } }
    if ($rows.Count -gt 0) { $rows | Export-Csv -LiteralPath (Join-Path $OutputPath "reports\sessions-$stamp.csv") -NoTypeInformation -Encoding UTF8 }
    if ($allLogons.Count -gt 0) { $allLogons | ForEach-Object { [pscustomobject]@{ Time = $_.t; Host = $_.host; User = $_.u; LogonSec = $_.lg } } | Export-Csv -LiteralPath (Join-Path $OutputPath "reports\logons-last$TrendDays`d.csv") -NoTypeInformation -Encoding UTF8 }
    $rightSizing | ForEach-Object { [pscustomobject]$_ } | Export-Csv -LiteralPath (Join-Path $OutputPath "reports\rightsizing-$stamp.csv") -NoTypeInformation -Encoding UTF8
}
Write-Host ("Merged {0} hosts ({1} online), {2} sessions, {3} alerts ({4} new) in {5} ms -> {6}" -f $hosts.Count, $online.Count, $allSessions.Count, $allAlerts.Count, $newAlerts.Count, $sw.ElapsedMilliseconds, $fleetPath)
