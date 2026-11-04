#Requires -Version 5.1
<#
.SYNOPSIS
    NinjaOne deployment wrapper for the AvdDex Agent (runs as SYSTEM).

.DESCRIPTION
    Pulls AvdDexAgent.ps1 + Install-AvdDexAgent.ps1 from the DEX share's bin\ folder (or from the
    SourceUrl if the share isn't reachable), then runs the installer.

    NinjaOne script variables are exposed as environment variables - define these in the script's
    "Script Variables" so the same script serves every host pool:
        dexSharePath   (text)   e.g. \\fileserver\AvdDex
        dexHostPool    (text)   e.g. CAD-POOL
        dexTags        (text)   comma separated, e.g. CAD,Bentley
        dexInterval    (int)    default 30
        dexWebhook     (text)   optional broker URL
        dexAction      (dropdown) install | uninstall | status | sample

    Exit code 0 = success, 1 = failure (so NinjaOne can report it).
#>
param(
    [string]$SharePath = $env:dexSharePath,
    [string]$HostPool = $env:dexHostPool,
    [string]$Tags = $env:dexTags,
    [int]$IntervalSeconds = $(if ($env:dexInterval) { [int]$env:dexInterval } else { 30 }),
    [string]$WebhookUrl = $env:dexWebhook,
    [string]$Action = $(if ($env:dexAction) { $env:dexAction } else { 'install' }),
    [string]$SourceUrl = ''   # optional https fallback hosting the two .ps1 files
)
$ErrorActionPreference = 'Stop'
$staging = Join-Path $env:TEMP 'AvdDex'
$installPath = 'C:\Program Files\AvdDex'
$dataPath = 'C:\ProgramData\AvdDex'

try {
    switch ($Action.ToLower()) {
        'status' {
            $t = Get-ScheduledTask -TaskName 'AvdDex Agent' -ErrorAction SilentlyContinue
            $latest = Join-Path $dataPath "latest\$env:COMPUTERNAME.json"
            if (-not $t) { Write-Output 'NOT INSTALLED'; exit 1 }
            Write-Output ("Task state: {0}" -f $t.State)
            if (Test-Path $latest) {
                $s = Get-Content $latest -Raw | ConvertFrom-Json
                $age = [math]::Round(((Get-Date) - [datetime]$s.Timestamp).TotalSeconds)
                Write-Output ("Last sample {0}s ago | host score {1} ({2}) | sessions {3} | alerts {4}" -f $age, $s.Score.Score, $s.Score.Stress, $s.SessionSummary.Total, $s.Alerts.Count)
                foreach ($a in $s.Alerts) { Write-Output ("  [{0}] {1}: {2}" -f $a.Severity.ToUpper(), $a.Target, $a.Message) }
                if ($age -gt 300) { Write-Output 'STALE - agent not writing'; exit 1 }
            } else { Write-Output 'No snapshot yet'; exit 1 }
            exit 0
        }
        'sample' {
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installPath 'AvdDexAgent.ps1') -Once
            exit $LASTEXITCODE
        }
        'uninstall' {
            if (Test-Path (Join-Path $installPath 'Install-AvdDexAgent.ps1')) { & (Join-Path $installPath 'Install-AvdDexAgent.ps1') -Uninstall }
            else { Unregister-ScheduledTask -TaskName 'AvdDex Agent' -Confirm:$false -ErrorAction SilentlyContinue; Write-Output 'Task removed.' }
            exit 0
        }
        default {
            if (-not (Test-Path $staging)) { New-Item -ItemType Directory -Path $staging -Force | Out-Null }
            $files = @('AvdDexAgent.ps1', 'Install-AvdDexAgent.ps1')
            $got = $false
            if ($SharePath -and (Test-Path (Join-Path $SharePath 'bin\AvdDexAgent.ps1'))) {
                foreach ($f in $files) { Copy-Item -LiteralPath (Join-Path $SharePath "bin\$f") -Destination (Join-Path $staging $f) -Force }
                $got = $true; Write-Output "Pulled agent from $SharePath\bin"
            } elseif ($SourceUrl) {
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                foreach ($f in $files) { Invoke-WebRequest -Uri ("{0}/{1}" -f $SourceUrl.TrimEnd('/'), $f) -OutFile (Join-Path $staging $f) -UseBasicParsing }
                $got = $true; Write-Output "Pulled agent from $SourceUrl"
            }
            if (-not $got) { throw "Agent files not found at '$SharePath\bin' and no SourceUrl given." }
            Copy-Item -LiteralPath (Join-Path $staging 'Install-AvdDexAgent.ps1') -Destination $installPath -Force -ErrorAction SilentlyContinue
            $installArgs = @{ SourcePath = $staging; IntervalSeconds = $IntervalSeconds }
            if ($SharePath)  { $installArgs.SharePath = $SharePath }
            if ($HostPool)   { $installArgs.HostPool = $HostPool }
            if ($Tags)       { $installArgs.Tags = ($Tags -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
            if ($WebhookUrl) { $installArgs.WebhookUrl = $WebhookUrl }
            & (Join-Path $staging 'Install-AvdDexAgent.ps1') @installArgs
            exit 0
        }
    }
} catch {
    Write-Output "FAILED: $($_.Exception.Message)"
    exit 1
}
