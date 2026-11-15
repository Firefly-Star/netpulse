# 验证提权采集层在两种权限下都安全降级
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'NetPulse.Elevated.ps1')

"elevated = " + (Test-NetPulseElevated)

$w = Get-NetPulseWifi
"wifi        : Available={0} Ssid='{1}' Rssi={2} Band={3} Rx={4} Reason='{5}'" -f $w.Available, $w.Ssid, $w.Rssi, $w.Band, $w.RxMbps, $w.Reason

$a = Get-NetPulseArp
"arp         : Available={0} entries={1} reason='{2}'" -f $a.Available, @($a.Entries).Count, $a.Reason

$c = Get-NetPulseConnections
"connections : Available={0} established={1} procs={2}" -f $c.Available, $c.Established, @($c.Processes).Count
@($c.Processes) | Select-Object -First 5 | ForEach-Object { "   {0,-22} pid={1,-6} conns={2}  {3}" -f $_.Name, $_.Pid, $_.Count, ($_.Peers -join ', ') }

$e = Get-NetPulseIfErrors
"ifErrors    : {0} 张网卡" -f $e.Keys.Count
$e.Keys | Where-Object { $e[$_].InErrors -gt 0 -or $e[$_].SpeedMbps -gt 0 } | Sort-Object | ForEach-Object {
    "   ifIndex={0,-4} inErr={1,-10} inDisc={2,-8} outErr={3,-8} speed={4}Mbps" -f $_, $e[$_].InErrors, $e[$_].InDiscards, $e[$_].OutErrors, $e[$_].SpeedMbps
}
