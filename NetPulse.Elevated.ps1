#region ---------- 提权专属采集 ----------
<#
    这些数据非管理员拿不到（本机实测：WlanQueryInterface 返回 error 5，
    GetIfEntry2 的 errors/discards 字段在非提权下也是零）。
    每条都带 Available 标志，界面据此决定显示还是灰掉。
#>

if (-not ('NetPulse.Elevated' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.dll', 'System.Core.dll' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace NetPulse
{
    public static class Elevated
    {
        // ---- GetExtendedTcpTable / GetExtendedUdpTable ----
        const int AF_INET = 2, AF_INET6 = 23;
        const int TCP_TABLE_OWNER_PID_ALL = 5;
        const int UDP_TABLE_OWNER_PID = 1;
        const int ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        public struct MIB_TCPROW_OWNER_PID
        {
            public uint state, localAddr, localPort, remoteAddr, remotePort, owningPid;
        }
        [StructLayout(LayoutKind.Sequential)]
        public struct MIB_UDPROW_OWNER_PID
        {
            public uint localAddr, localPort, owningPid;
        }

        [DllImport("iphlpapi.dll")] static extern int GetExtendedTcpTable(IntPtr p, ref int size, bool order, int af, int tbl, int reserved);
        [DllImport("iphlpapi.dll")] static extern int GetExtendedUdpTable(IntPtr p, ref int size, bool order, int af, int tbl, int reserved);

        /// <summary>所有 TCP 连接，格式 "state|localPort|remoteIp:remotePort|pid"</summary>
        public static string[] TcpConnections()
        {
            List<string> res = new List<string>();
            int size = 0;
            int rc = GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
            if (rc != ERROR_INSUFFICIENT_BUFFER && rc != 0) return res.ToArray();
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedTcpTable(buf, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) != 0) return res.ToArray();
                int n = Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                for (int i = 0; i < n; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * rowSize);
                    MIB_TCPROW_OWNER_PID r = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(p, typeof(MIB_TCPROW_OWNER_PID));
                    string lip = new System.Net.IPAddress(BitConverter.GetBytes(r.localAddr)).ToString();
                    string rip = new System.Net.IPAddress(BitConverter.GetBytes(r.remoteAddr)).ToString();
                    int lport = (int)(((r.localPort & 0xFF) << 8) | ((r.localPort >> 8) & 0xFF));
                    int rport = (int)(((r.remotePort & 0xFF) << 8) | ((r.remotePort >> 8) & 0xFF));
                    res.Add(r.state + "|" + lip + "|" + lport + "|" + rip + "|" + rport + "|" + r.owningPid);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return res.ToArray();
        }

        static string[] UdpTable()
        {
            List<string> res = new List<string>();
            int size = 0;
            int rc = GetExtendedUdpTable(IntPtr.Zero, ref size, false, AF_INET, UDP_TABLE_OWNER_PID, 0);
            if (rc != ERROR_INSUFFICIENT_BUFFER && rc != 0) return res.ToArray();
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedUdpTable(buf, ref size, false, AF_INET, UDP_TABLE_OWNER_PID, 0) != 0) return res.ToArray();
                int n = Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_UDPROW_OWNER_PID));
                for (int i = 0; i < n; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * rowSize);
                    MIB_UDPROW_OWNER_PID r = (MIB_UDPROW_OWNER_PID)Marshal.PtrToStructure(p, typeof(MIB_UDPROW_OWNER_PID));
                    int lport = (int)(((r.localPort & 0xFF) << 8) | ((r.localPort >> 8) & 0xFF));
                    res.Add("0|" + lport + "|-|0|0|" + r.owningPid);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return res.ToArray();
        }

        public static bool IsElevated()
        {
            try
            {
                using (System.Security.Principal.WindowsIdentity id = System.Security.Principal.WindowsIdentity.GetCurrent())
                {
                    System.Security.Principal.WindowsPrincipal p = new System.Security.Principal.WindowsPrincipal(id);
                    return p.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
                }
            }
            catch { return false; }
        }
    }
}
'@
}

function Test-NetPulseElevated {
    <# 当前进程是否管理员；非提权时 WiFi / 错误计数 / 进程归属 都拿不到 #>
    try { return [NetPulse.Elevated]::IsElevated() } catch { return $false }
}

function Get-NetPulseWifi {
    <#
        WiFi 信号强度、频段、真实协商速率。必须提权。
        实测字段（中文系统）：
            SSID                   : xxx
            广播                   : 2.4 GHz
            通道                   : 2
            接收速率(Mbps)         : 72.2
            传输速率 (Mbps)        : 57.8
            信号                   : 92%
            Rssi                   : -50
        注意 netsh 输出是 GBK，PowerShell 读进来可能是乱码，所以正则同时匹配中英文。
    #>
    if (-not (Test-NetPulseElevated)) {
        return [pscustomobject]@{ Available=$false; Ssid=''; Bssid=''; Rssi=0; SignalPct=0
            Channel=0; Band=''; Radio=''; RxMbps=0; TxMbps=0; Reason='需要管理员权限' }
    }
    try {
        # 编码实测结论：同样是 netsh wlan show interfaces，
        #   用 cmd /c 或 ProcessStartInfo 管道捕获 → GBK 字节；
        #   用 -RedirectStandardOutput 重定向到文件     → UTF-8 字节。
        # 所以不能写死编码，改为读原始字节后自动判定。
        $bytes = $null
        try {
            $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "np-wlan-$PID.txt")
            Start-Process -FilePath "$env:SystemRoot\System32\netsh.exe" `
                -ArgumentList "wlan","show","interfaces" `
                -RedirectStandardOutput $tmp -NoNewWindow -Wait -ErrorAction Stop
            if (Test-Path $tmp) {
                $bytes = [System.IO.File]::ReadAllBytes($tmp)
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        } catch { $bytes = $null }
        if (-not $bytes -or $bytes.Length -eq 0) {
            return [pscustomobject]@{ Available=$false; Ssid=""; Bssid=""; Rssi=0; SignalPct=0
                Channel=0; Band=""; Radio=""; RxMbps=0; TxMbps=0; Reason="netsh 无输出" }
        }

        # 自动探测：哪套编码能解出 "信号" 就用哪套
        $out = ""
        foreach ($encName in @("utf-8", "gbk")) {
            try {
                $cand = [System.Text.Encoding]::GetEncoding($encName).GetString($bytes)
                if ($cand -match "(?:信号|Signal|Rssi)") { $out = $cand; break }
            } catch { }
        }
        if (-not $out) { $out = [System.Text.Encoding]::UTF8.GetString($bytes) }

        function Grab([string]$pattern) {
            if ($out -match $pattern) { return $Matches[1].Trim() }
            return ''
        }

        $ssid  = Grab '(?m)^\s*SSID\s*[:：]\s*(.+)$'
        $bssid = Grab '(?m)^\s*(?:AP BSSID|BSSID)\s*:\s*([0-9a-fA-F:-]{17})'
        $band  = Grab '(?m)^\s*(?:广播|Band|频段)\s*[:：]\s*(.+)$'
        $radio = Grab '(?m)^\s*(?:无线电类型|Radio type)\s*[:：]\s*(.+)$'

        $signalPct = 0
        if ($out -match '(?m)^\s*(?:信号|Signal)\s*[:：]\s*(\d+)\s*%') { $signalPct = [int]$Matches[1] }

        # 新版 Windows 直接给 Rssi 字段，优先用它；老版本只有百分比，按 -30~-90dBm 换算
        $rssi = $null
        if ($out -match '(?m)^\s*Rssi\s*[:：]\s*(-?\d+)') { $rssi = [int]$Matches[1] }
        if ($null -eq $rssi -and $signalPct -gt 0) { $rssi = [int](-90 + ($signalPct * 0.6)) }

        $channel = 0
        if ($out -match '(?m)^\s*(?:通道|信道|Channel)\s*[:：]\s*(\d+)') { $channel = [int]$Matches[1] }

        $rxMbps = 0.0; $txMbps = 0.0
        if ($out -match '(?m)^\s*接收速率[^\r\n:]*[:：]\s*([\d.]+)') { $rxMbps = [double]$Matches[1] }
        if ($out -match '(?m)^\s*传输速率[^\r\n:]*[:：]\s*([\d.]+)') { $txMbps = [double]$Matches[1] }

        # 频段：优先用 "广播: 2.4 GHz" 字段，其次按信道推断
        $bandName = ''
        if ($band -match '2\.4') { $bandName = '2.4G' }
        elseif ($band -match '5') { $bandName = '5G' }
        elseif ($band -match '6') { $bandName = '6G' }
        elseif ($channel -ge 1 -and $channel -le 14) { $bandName = '2.4G' }
        elseif ($channel -ge 32 -and $channel -lt 200) { $bandName = '5G' }
        elseif ($channel -ge 200) { $bandName = '6G' }

        return [pscustomobject]@{
            Available = $true; Ssid = $ssid; Bssid = $bssid
            Rssi = $(if ($null -ne $rssi) { $rssi } else { 0 })
            SignalPct = $signalPct; Channel = $channel
            Band = $bandName; Radio = $radio
            RxMbps = $rxMbps; TxMbps = $txMbps; Reason = ''
        }
    } catch {
        return [pscustomobject]@{ Available=$false; Ssid=''; Bssid=''; Rssi=0; SignalPct=0
            Channel=0; Band=''; Radio=''; RxMbps=0; TxMbps=0; Reason=$_.Exception.Message }
    }
}
function Get-NetPulseArp {
    <#
        ARP 全表 + 网关 MAC。必须提权才能看到完整表。
        返回 @{ Available; Entries = @(ip/mac/ifIndex); GatewayMac }
    #>
    if (-not (Test-NetPulseElevated)) {
        return [pscustomobject]@{ Available = $false; Entries = @(); Reason = '需要管理员权限' }
    }
    try {
        $entries = New-Object System.Collections.ArrayList
        $text = (cmd /c 'arp -a 2>nul') -join "`n"
        $curIf = -1
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match 'Interface:\s*(\d+\.\d+\.\d+\.\d+)\s*---\s*(0x[0-9a-fA-F]+)') {
                $curIf = [Convert]::ToInt32($Matches[2], 16)
                continue
            }
            if ($line -match '^\s*(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F-]{17})\s+(\w+)') {
                [void]$entries.Add([pscustomobject]@{
                    Ip = $Matches[1]; Mac = $Matches[2].ToUpper(); Type = $Matches[3]; IfIndex = $curIf
                })
            }
        }
        return [pscustomobject]@{ Available = $true; Entries = $entries.ToArray(); Reason = '' }
    } catch {
        return [pscustomobject]@{ Available = $false; Entries = @(); Reason = $_.Exception.Message }
    }
}

function Get-NetPulseConnections {
    <#
        出站连接归属到进程，用来回答"到底是谁在占带宽"。
        必须提权：非提权时 owningPid 全是 0。
        按进程聚合 ESTABLISHED 连接数，并按 CPU 时间排不出流量——
        这里只给"连接数 + 远端地址"，真实流量需要 ETW，代价太大不做。
    #>
    if (-not (Test-NetPulseElevated)) {
        return [pscustomobject]@{ Available = $false; Processes = @(); Established = 0; Reason = '需要管理员权限' }
    }
    try {
        $rows = [NetPulse.Elevated]::TcpConnections()
        $byPid = @{}
        $estab = 0
        foreach ($r in $rows) {
            $p = $r.Split('|')
            if ($p[0] -ne '5') { continue }        # MIB_TCP_STATE_ESTAB = 5
            $estab++
            $pid_ = [int]$p[5]
            if ($pid_ -le 0) { continue }
            if (-not $byPid.ContainsKey($pid_)) { $byPid[$pid_] = New-Object System.Collections.ArrayList }
            [void]$byPid[$pid_].Add(($p[3] + ':' + $p[4]))
        }
        $procs = New-Object System.Collections.ArrayList
        foreach ($k in $byPid.Keys) {
            $name = ''
            try { $name = (Get-Process -Id $k -ErrorAction Stop).ProcessName } catch { $name = "pid $k" }
            $remotes = @($byPid[$k])
            [void]$procs.Add([pscustomobject]@{
                Pid = $k; Name = $name; Count = $remotes.Count
                Peers = @($remotes | Select-Object -Unique -First 3)
            })
        }
        $sorted = @($procs | Sort-Object Count -Descending)
        return [pscustomobject]@{ Available = $true; Processes = $sorted; Established = $estab; Reason = '' }
    } catch {
        return [pscustomobject]@{ Available = $false; Processes = @(); Established = 0; Reason = $_.Exception.Message }
    }
}

function Get-NetPulseIfErrors {
    <#
        每网卡错误/丢弃计数。GetIfEntry2 才给，且非提权下恒为 0。
        用 netsh interface ipv4 show subinterfaces 只能拿 MTU/字节，拿不到错误，
        所以走 GetIfTable2 的 InErrors/InDiscards/OutErrors/OutDiscards。
    #>
    if (-not ('NetPulse.IfErrors' -as [type])) {
        # 注意：故意用老的 GetIfEntry(MIB_IFROW) 而不是 GetIfTable2(MIB_IF_ROW2)。
        # MIB_IF_ROW2 含 257 字符的 inline 字符串字段，PowerShell 的 Add-Type 里
        # 无论用 ByValTStr+string 还是 ByValArray+char[]，Marshal.SizeOf 都算成 1296
        # （真实 1352），导致行偏移全错、读出 1e16 量级的垃圾值。
        # MIB_IFROW 是纯值类型 + byte[]，SizeOf=856 正确，字段也够用。
        Add-Type -ReferencedAssemblies 'System.dll' -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace NetPulse
{
    public static class IfErrors
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MIB_IFROW
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public char[] wszName;
            public uint dwIndex;
            public uint dwType;
            public uint dwMtu;
            public uint dwSpeed;
            public uint dwPhysAddrLen;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public byte[] bPhysAddr;
            public uint dwAdminStatus;
            public uint dwOperStatus;
            public uint dwLastChange;
            public uint dwInOctets;
            public uint dwOutOctets;
            public uint dwInUcastPkts;
            public uint dwInNucastPkts;
            public uint dwOutUcastPkts;
            public uint dwOutNucastPkts;
            public uint dwInErrors;
            public uint dwInDiscards;
            public uint dwInUnknownProtos;
            public uint dwOutErrors;
            public uint dwOutQLen;
            public uint dwDescrLen;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public byte[] bDescr;
        }

        [DllImport("iphlpapi.dll")]
        static extern int GetIfEntry(ref MIB_IFROW pIfRow);
        [DllImport("iphlpapi.dll")]
        static extern int GetNumberOfInterfaces(out uint num);

        /// <summary>每行 "ifIndex|inErrors|inDiscards|outErrors|outQLen|speed"</summary>
        public static string[] Dump()
        {
            List<string> res = new List<string>();
            uint count;
            if (GetNumberOfInterfaces(out count) != 0) return res.ToArray();
            for (uint i = 1; i <= count; i++)
            {
                MIB_IFROW row = new MIB_IFROW();
                row.dwIndex = i;
                if (GetIfEntry(ref row) != 0) continue;
                res.Add(row.dwIndex + "|" + row.dwInErrors + "|" + row.dwInDiscards + "|"
                        + row.dwOutErrors + "|" + row.dwOutQLen + "|" + row.dwSpeed);
            }
            return res.ToArray();
        }
    }
}
"@
    }
    $map = @{}
    try {
        foreach ($row in [NetPulse.IfErrors]::Dump()) {
            $p = $row.Split('|')
            $map[[int]$p[0]] = [pscustomobject]@{
                InErrors = [double]$p[1]; InDiscards = [double]$p[2]
                OutErrors = [double]$p[3]; OutQLen = [double]$p[4]
                SpeedMbps = [math]::Round([double]$p[5] / 1e6, 0)
            }
        }
    } catch { }
    return $map
}
#endregion
