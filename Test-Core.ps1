<#
    采集内核自测：不弹窗，直接打印采样。
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Core.ps1
        powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Core.ps1 -Seconds 20
#>
[CmdletBinding()]
param(
    [int]$Seconds = 12,
    [int]$IntervalMs = 1000
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'NetPulse.Core.ps1')

function Show-Probe($p) {
    if ($p.Type -eq 'ARP') { if ($p.Ok) { "$($p.Key)=UP" } else { "$($p.Key)=X" } }
    elseif ($p.Pending) { "$($p.Key)=.." }
    elseif ($p.Ok) { "$($p.Key)=$($p.RttMs)ms" }
    else { "$($p.Key)=X" }
}

$state = New-NetPulseState
$deadline = (Get-Date).AddSeconds($Seconds)
$n = 0
$last = $null

while ((Get-Date) -lt $deadline) {
    $t0 = Get-Date
    try {
        $s = Update-NetPulse -State $state
        $last = $s
        $n++
        $down = Format-NetPulseRate $s.Throughput.PhysDown
        $up = Format-NetPulseRate $s.Throughput.PhysUp
        $lats = ($s.Probes | ForEach-Object { Show-Probe $_ }) -join ' '
        "{0:HH:mm:ss} dn={1,-10} up={2,-10} | {3,-40} | {4,-9} rtt={5,5} jit={6,5} loss={7,3}% retr={8,4}%" -f `
            $s.At, $down, $up, $lats, $s.Health, $s.Stats.RttNow, $s.Stats.Jitter, $s.Stats.LossPct, $s.Stats.Retrans
    }
    catch {
        "CAPTURE ERROR: $($_.Exception.Message)"
        "  at: $($_.InvocationInfo.PositionString)"
    }
    $elapsed = ((Get-Date) - $t0).TotalMilliseconds
    $sleep = $IntervalMs - $elapsed
    if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int]$sleep) }
}

""
"==================== 详细快照 ===================="
if ($last) {
    "采集次数: $n   探针结果年龄: $($last.ProbeAgeMs)ms"
    "接口:"
    $last.Interfaces | Format-Table Name, Category, Status, SpeedMbps, @{N='IPv4';E={$_.IPv4 -join ','}}, BytesIn, BytesOut -AutoSize | Out-String -Width 220
    "吞吐: 物理 down={0} up={1} / 全部 down={2} up={3}" -f `
        (Format-NetPulseRate $last.Throughput.PhysDown), (Format-NetPulseRate $last.Throughput.PhysUp), `
        (Format-NetPulseRate $last.Throughput.DownBps), (Format-NetPulseRate $last.Throughput.UpBps)
    "网关: {0}  （默认路由 ifIndex={1} metric={2}）" -f $last.Gateway, $last.Routing.DefaultRoute.IfIndex, $last.Routing.DefaultRoute.Metric
    "出口网卡: {0} [{1}]" -f $last.ActiveIface.Name, $last.ActiveIface.Category
    "代理: mode={0} ie={1}/{2} pac='{3}' eff='{4}' listening=[{5}]" -f `
        $last.Proxy.Mode, $last.Proxy.IeEnabled, $last.Proxy.IeServer, $last.Proxy.PacUrl, $last.Proxy.Effective, ($last.Proxy.Listening -join ',')
    "隧道: 命中={0} 比例={1} 网卡='{2}'" -f $last.Proxy.HasTunnel, $last.Proxy.TunRatio, $last.Proxy.TunIfDesc
    "探针:"
    $last.Probes | Format-Table Key, Name, Kind, Type, Ip, RttMs, Ok, Pending -AutoSize | Out-String
    "公网目标出口:"
    $last.RouteDetail | Format-Table Key, Ip, IfIndex, IfName, Category, ViaTunnel -AutoSize | Out-String -Width 160
    "健康: {0}  {1}" -f $last.Health, ($last.HealthReasons -join '; ')
    "统计: now={0} min={1} med={2} jitter={3} loss={4}% retrans={5}%" -f `
        $last.Stats.RttNow, $last.Stats.MinRtt, $last.Stats.MedRtt, $last.Stats.Jitter, $last.Stats.LossPct, $last.Stats.Retrans
    "中断: {0} 次   已运行 {1}s   采样 {2} 次" -f $last.OutageCount, $last.UptimeSec, $last.Samples
    if ($last.Events.Count -gt 0) {
        "事件:"; $last.Events | Select-Object -Last 8 | Format-Table At, Kind, Text -AutoSize | Out-String -Width 160
    }
}
