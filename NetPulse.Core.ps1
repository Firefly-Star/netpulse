<#
    NetPulse 核心引擎  (Windows PowerShell 5.1+ / 免管理员)
    ======================================================
    全部数据源都在本机实测过，没有一个是"应该有"的猜测：

      * WMI/CIM 被策略拒绝                → 改用 IP Helper API（GetIpForwardTable 1.3ms，
        比 route print 的 400ms 快两个数量级）
      * ICMP 被完全封锁                    → 不用 ping。改用三种探针：
          - ARP  （网关，≈0 流量，二层帧）
          - UDP DNS（自己封包，绕过系统解析缓存，≈100 字节）
          - TCP SYN（不握手完也不发载荷，≈3 个包）
      * 国际线路长时间挂在 SYN_SENT        → 目标池启动时竞速，只保留当前真正连得上的
      * 网关常兼任 DNS，所以"网关通 ≠ 能上网" → ARP / 本地DNS / 公网DNS / TCP 四层分开报
      * 逐端口试代理端口每次要 160ms        → 改成一次性读 GetActiveTcpListeners（9ms）

    开销：1 Hz 全量监测约 0.5~1 KB/s。ARP 探针不产生任何网络流量。
    带宽测试是手动触发的一次性大流量动作，默认不跑。
#>

#region ---------- 原生层 ----------
if (-not ('NetPulse.Native' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.dll', 'System.Core.dll' -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading;

namespace NetPulse
{
    public static class Native
    {
        const int AF_INET = 2, SOCK_STREAM = 1, IPPROTO_TCP = 6;
        const uint WSA_FLAG_OVERLAPPED = 0x01;
        const int FIONBIO = unchecked((int)0x8004667E);
        const int SOL_SOCKET = 0xFFFF, SO_ERROR = 0x1007;
        const int IPPROTO_IP = 0, IP_TTL = 4;
        const int WSAEWOULDBLOCK = 10035;
        const int NO_ERROR = 0, ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        struct sockaddr_in { public ushort sin_family; public ushort sin_port; public uint sin_addr; public ulong sin_zero; }
        [StructLayout(LayoutKind.Sequential)]
        struct timeval { public int tv_sec; public int tv_usec; }

        [StructLayout(LayoutKind.Sequential)]
        public struct MIB_IPFORWARDROW
        {
            public uint dwForwardDest, dwForwardMask, dwForwardPolicy, dwForwardNextHop, dwForwardIfIndex,
                        dwForwardType, dwForwardProto, dwForwardAge, dwForwardNextHopAS,
                        dwForwardMetric1, dwForwardMetric2, dwForwardMetric3, dwForwardMetric4, dwForwardMetric5;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct TCPSTATS
        {
            public uint rtoAlg, rtoMin, rtoMax, maxConn, activeOpens, passiveOpens, attemptFails,
                estabResets, currEstab, inSegs, outSegs, retransSegs, inErrs, outRsts, numConns;
        }

        [DllImport("ws2_32.dll", SetLastError = true)] static extern IntPtr WSASocket(int af, int type, int pr, IntPtr lp, uint g, uint fl);
        [DllImport("ws2_32.dll", SetLastError = true)] static extern int connect(IntPtr s, ref sockaddr_in n, int l);
        [DllImport("ws2_32.dll", SetLastError = true)] static extern int select(int n, IntPtr r, IntPtr w, IntPtr e, ref timeval t);
        [DllImport("ws2_32.dll", SetLastError = true)] static extern int getsockopt(IntPtr s, int l, int o, ref int v, ref int len);
        [DllImport("ws2_32.dll", SetLastError = true)] static extern int setsockopt(IntPtr s, int l, int o, ref int v, int len);
        [DllImport("ws2_32.dll", SetLastError = true)] static extern int ioctlsocket(IntPtr s, int c, ref uint a);
        [DllImport("ws2_32.dll", SetLastError = true)] static extern int closesocket(IntPtr s);
        [DllImport("ws2_32.dll")] static extern int WSAGetLastError();
        [DllImport("iphlpapi.dll")] static extern int GetBestRoute(uint dest, uint src, out MIB_IPFORWARDROW row);
        [DllImport("iphlpapi.dll")] static extern int GetIpForwardTable(IntPtr p, ref int size, bool order);
        [DllImport("iphlpapi.dll")] static extern int GetTcpStatistics(out TCPSTATS s);
        [DllImport("iphlpapi.dll")] static extern int SendARP(int dest, int src, byte[] mac, ref int len);

        static ushort Htons(int p) { return (ushort)(((p & 0xFF) << 8) | ((p >> 8) & 0xFF)); }
        static uint ToUInt(string ip) { byte[] b = IPAddress.Parse(ip).GetAddressBytes(); return (uint)(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)); }

        /// <summary>非阻塞 TCP 连接计时；-1 = 超时/不可达。ttl=1 探的是第一跳。</summary>
        public static int TcpProbe(string ip, int port, int ttl, int timeoutMs)
        {
            IPAddress a;
            if (!IPAddress.TryParse(ip, out a) || a.AddressFamily != AddressFamily.InterNetwork) return -1;

            IntPtr s = WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, IntPtr.Zero, 0, WSA_FLAG_OVERLAPPED);
            if (s == new IntPtr(-1)) return -1;
            IntPtr fs = IntPtr.Zero;
            try
            {
                uint nb = 1;
                ioctlsocket(s, FIONBIO, ref nb);
                if (ttl > 0) { int t = ttl; setsockopt(s, IPPROTO_IP, IP_TTL, ref t, 4); }

                byte[] b = a.GetAddressBytes();
                sockaddr_in sa = new sockaddr_in();
                sa.sin_family = AF_INET;
                sa.sin_port = Htons(port);
                sa.sin_addr = BitConverter.ToUInt32(b, 0);

                Stopwatch sw = Stopwatch.StartNew();
                int rc = connect(s, ref sa, 16);
                int err = rc == 0 ? 0 : WSAGetLastError();
                if (rc != 0 && err != WSAEWOULDBLOCK) return -1;

                int size = 8 + 64 * 8;
                fs = Marshal.AllocHGlobal(size);
                for (int i = 0; i < size; i++) Marshal.WriteByte(fs, i, 0);
                Marshal.WriteInt32(fs, 0, 1);
                Marshal.WriteIntPtr(fs, 8, s);

                timeval tv = new timeval();
                tv.tv_sec = timeoutMs / 1000;
                tv.tv_usec = (timeoutMs % 1000) * 1000;

                if (select(0, IntPtr.Zero, fs, IntPtr.Zero, ref tv) <= 0) return -1;
                int ms = (int)sw.ElapsedMilliseconds;

                int se = 0, len = 4;
                getsockopt(s, SOL_SOCKET, SO_ERROR, ref se, ref len);
                if (se == 0 || se == 10061 || se == 10065 || se == 10051)
                    return ms < 1 ? 1 : ms;
                return -1;
            }
            catch { return -1; }
            finally { if (fs != IntPtr.Zero) Marshal.FreeHGlobal(fs); closesocket(s); }
        }

        /// <summary>自己发一封 UDP DNS 查询并计时（绕过系统解析缓存）。</summary>
        public static int DnsProbe(string server, string qname, int timeoutMs)
        {
            try
            {
                IPAddress srv;
                if (!IPAddress.TryParse(server, out srv)) return -1;
                ushort id = (ushort)(((int)(DateTime.UtcNow.Ticks & 0xFFFF)) ^ qname.Length);
                byte[] q = BuildQuery(qname, id);
                IPEndPoint ep = new IPEndPoint(srv, 53);
                using (UdpClient u = new UdpClient(srv.AddressFamily))
                {
                    u.Client.ReceiveTimeout = timeoutMs;
                    Stopwatch sw = Stopwatch.StartNew();
                    u.Send(q, q.Length, ep);
                    IPEndPoint from = new IPEndPoint(srv.AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any, 0);
                    u.Receive(ref from);
                    int ms = (int)sw.ElapsedMilliseconds;
                    return ms < 1 ? 1 : ms;
                }
            }
            catch { return -1; }
        }

        static byte[] BuildQuery(string qname, ushort id)
        {
            List<byte> b = new List<byte>(64);
            b.Add((byte)(id >> 8)); b.Add((byte)(id & 0xFF));
            b.Add(0x01); b.Add(0x00);
            b.Add(0x00); b.Add(0x01);
            b.Add(0); b.Add(0); b.Add(0); b.Add(0); b.Add(0); b.Add(0);
            foreach (string part in qname.Split('.'))
            {
                if (part.Length == 0) continue;
                b.Add((byte)part.Length);
                b.AddRange(System.Text.Encoding.ASCII.GetBytes(part));
            }
            b.Add(0x00);
            b.Add(0x00); b.Add(0x01);
            b.Add(0x00); b.Add(0x01);
            return b.ToArray();
        }

        /// <summary>目的地会被哪块网卡送出去（区分直连 / 走 TUN）。</summary>
        public static int BestRouteIfIndex(string ip)
        {
            try { MIB_IPFORWARDROW r; if (GetBestRoute(ToUInt(ip), 0, out r) == 0) return (int)r.dwForwardIfIndex; } catch { }
            return -1;
        }

        /// <summary>默认路由，每行 "ifIndex|nextHop|metric"，1.3ms 级别。</summary>
        public static string[] DefaultRoutes()
        {
            List<string> res = new List<string>();
            int size = 0;
            int rc = GetIpForwardTable(IntPtr.Zero, ref size, false);
            if (rc != NO_ERROR && rc != ERROR_INSUFFICIENT_BUFFER) return res.ToArray();
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetIpForwardTable(buf, ref size, false) != 0) return res.ToArray();
                int n = Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_IPFORWARDROW));
                for (int i = 0; i < n; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * rowSize);
                    MIB_IPFORWARDROW r = (MIB_IPFORWARDROW)Marshal.PtrToStructure(p, typeof(MIB_IPFORWARDROW));
                    if (r.dwForwardDest != 0 || r.dwForwardMask != 0) continue;
                    if (r.dwForwardNextHop == 0) continue;
                    string hop = new IPAddress(BitConverter.GetBytes(r.dwForwardNextHop)).ToString();
                    res.Add(r.dwForwardIfIndex + "|" + hop + "|" + r.dwForwardMetric1);
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return res.ToArray();
        }

        /// <summary>{currEstab, outSegs, retransSegs, inSegs, attemptFails, estabResets}</summary>
        public static long[] TcpStats()
        {
            try
            {
                TCPSTATS s;
                if (GetTcpStatistics(out s) == 0)
                    return new long[] { s.currEstab, s.outSegs, s.retransSegs, s.inSegs, s.attemptFails, s.estabResets };
            }
            catch { }
            return new long[] { 0, 0, 0, 0, 0, 0 };
        }

        /// <summary>二层 ARP 是否可达（≈0 流量，最快的本地链路存活信号）。</summary>
        public static bool ArpReachable(string ip)
        {
            try
            {
                byte[] mac = new byte[6];
                int len = 6;
                return SendARP((int)ToUInt(ip), 0, mac, ref len) == 0 && len == 6;
            }
            catch { return false; }
        }

        /// <summary>并行竞速，每项 "ip:port"，返回各目标 RTT（-1 不可达）。</summary>
        public static int[] RankPool(string[] targets, int timeoutMs)
        {
            int[] res = new int[targets.Length];
            System.Threading.Tasks.Parallel.For(0, targets.Length, delegate(int i)
            {
                try
                {
                    string[] p = targets[i].Split(':');
                    res[i] = TcpProbe(p[0], int.Parse(p[1]), 0, timeoutMs);
                }
                catch { res[i] = -1; }
            });
            return res;
        }
    }

    /// <summary>后台探针线程：UI 只读快照，永远不会被网络卡住。</summary>
    public class Prober : IDisposable
    {
        readonly object _lock = new object();
        string[] _specs = new string[0];
        int[] _latest = new int[0];
        long _latestTicks;
        const int PENDING = -2;
        readonly int _timeoutMs, _intervalMs;
        Thread _thread;
        volatile bool _running;
        public long Cycles;

        public Prober(int timeoutMs, int intervalMs) { _timeoutMs = timeoutMs; _intervalMs = intervalMs; }

        public void SetTargets(string[] specs)
        {
            lock (_lock)
            {
                _specs = specs ?? new string[0];
                if (_latest.Length != _specs.Length) _latest = Fill(_specs.Length, PENDING);
                _latestTicks = 0;   // 换了目标，旧结果作废
            }
        }

        static int[] Fill(int n, int v)
        {
            int[] a = new int[n];
            for (int i = 0; i < n; i++) a[i] = v;
            return a;
        }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _thread = new Thread(Loop) { IsBackground = true, Name = "NetPulse-Prober", Priority = ThreadPriority.BelowNormal };
            _thread.Start();
        }

        public void Stop() { _running = false; }
        public void Dispose() { Stop(); }

        void Loop()
        {
            while (_running)
            {
                string[] specs;
                lock (_lock) { specs = _specs; }
                int[] res = new int[specs.Length];
                if (specs.Length > 0)
                {
                    System.Threading.Tasks.Parallel.For(0, specs.Length, delegate(int i)
                    {
                        try
                        {
                            string[] p = specs[i].Split('|');
                            if (p[0] == "T") res[i] = Native.TcpProbe(p[1], int.Parse(p[2]), int.Parse(p[3]), _timeoutMs);
                            else if (p[0] == "D") res[i] = Native.DnsProbe(p[1], p[2], _timeoutMs);
                            else res[i] = -1;
                        }
                        catch { res[i] = -1; }
                    });
                }
                lock (_lock)
                {
                    if (_latest.Length != res.Length) _latest = new int[res.Length];
                    Array.Copy(res, _latest, res.Length);
                    _latestTicks = DateTime.UtcNow.Ticks;
                    Cycles++;
                }
                int slept = 0;
                while (_running && slept < _intervalMs) { Thread.Sleep(50); slept += 50; }
            }
        }

        public int[] Snapshot(out int ageMs)
        {
            lock (_lock)
            {
                int[] copy = new int[_latest.Length];
                Array.Copy(_latest, copy, _latest.Length);
                ageMs = _latestTicks == 0 ? int.MaxValue : (int)((DateTime.UtcNow.Ticks - _latestTicks) / TimeSpan.TicksPerMillisecond);
                return copy;
            }
        }
    }
}
'@
}
#endregion


#region ---------- 配置 ----------
# 目标池：只有当前连得上的才会被采用（启动时竞速筛选，之后每 5 分钟复检）
$script:NetPulseTcpPool = @(
    @{ Name = '阿里云';   Ip = '223.5.5.5';       Port = 443 }
    @{ Name = '阿里云';   Ip = '223.6.6.6';       Port = 443 }
    @{ Name = '腾讯云';   Ip = '119.29.29.29';    Port = 443 }
    @{ Name = '腾讯云';   Ip = '1.12.12.12';      Port = 443 }
    @{ Name = '百度';     Ip = '180.76.76.76';    Port = 443 }
    @{ Name = '114DNS';   Ip = '114.114.114.114'; Port = 443 }
    @{ Name = '移动大区'; Ip = '120.53.53.53';    Port = 443 }
)
$script:NetPulseIntlPool = @(
    @{ Name = 'Cloudflare'; Ip = '1.1.1.1'; Port = 443 }
    @{ Name = 'Google';     Ip = '8.8.8.8'; Port = 443 }
)
$script:NetPulseProxyPorts = @(7890, 7891, 7897, 1080, 10808, 10809, 2080, 2081, 8889, 20171, 6152)
#endregion


#region ---------- 状态 ----------
function New-NetPulseState {
    param([int]$ProbeIntervalMs = 1000, [int]$ProbeTimeoutMs = 900)

    return @{
        StartedAt     = Get-Date
        ProbeInterval = $ProbeIntervalMs
        ProbeTimeout  = $ProbeTimeoutMs
        Prober        = $null
        Targets       = @()
        SpecKeys      = @()
        TargetAge     = [datetime]::MinValue

        PrevBytes     = @{}
        PrevAt        = [datetime]::MinValue

        RttHist       = New-Object System.Collections.Queue
        LossHist      = New-Object System.Collections.Queue
        Samples       = 0

        LastTcp       = $null
        LastTcpAt     = [datetime]::MinValue
        RetransPct    = 0.0

        IsDown        = $false
        DropStreak    = 0
        Outages       = New-Object System.Collections.ArrayList
        LastHealth    = 'unknown'
        Events        = New-Object System.Collections.ArrayList

        LinkState     = @{}
        LastProxyMode = ''
        LastActiveIf  = ''

        ScriptPath    = $(if ($PSScriptRoot) { Join-Path $PSScriptRoot 'NetPulse.Core.ps1' } else { '' })
        Refreshing    = $false
        PendingRefresh = $null
        RefreshStarted = [datetime]::MinValue
    }
}

function Add-NetPulseEvent {
    param($State, [string]$Kind, [string]$Text)
    $e = [pscustomobject]@{ At = (Get-Date); Kind = $Kind; Text = $Text }
    [void]$State.Events.Add($e)
    if ($State.Events.Count -gt 500) { $State.Events.RemoveAt(0) }
    return $e
}
#endregion


#region ---------- 发现 ----------
function Get-NetPulseInterfaces {
    $list = New-Object System.Collections.ArrayList
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.NetworkInterfaceType -eq 'Loopback') { continue }

        $d = [string]$n.Description
        $cat = 'other'
        if ($d -match 'Wintun|WireGuard|Tailscale|TAP-Windows|OpenVPN|sing-box|mihomo|Clash|Netch') { $cat = 'tunnel' }
        elseif ($d -match 'VMware|Hyper-V|VirtualBox|vEthernet|Npcap|Wi-Fi Direct') { $cat = 'virtual' }
        elseif ($n.NetworkInterfaceType -eq 'Wireless80211') { $cat = 'wifi' }
        elseif ($n.NetworkInterfaceType -eq 'Ethernet') { $cat = 'ethernet' }
        elseif ($d -match 'Wi-Fi|Wireless|802\.11') { $cat = 'wifi' }

        $speed = 0
        try { if ($n.Speed -gt 0 -and $n.Speed -lt 1e18) { $speed = [double]$n.Speed } } catch { }

        $bytesIn = 0.0; $bytesOut = 0.0; $ips = @(); $ifIndex = -1
        try { $s4 = $n.GetIPv4Statistics(); $bytesIn += [double]$s4.BytesReceived; $bytesOut += [double]$s4.BytesSent } catch { }
        try { $s6 = $n.GetIPv6Statistics(); $bytesIn += [double]$s6.BytesReceived; $bytesOut += [double]$s6.BytesSent } catch { }
        try { $ifIndex = $n.GetIPProperties().GetIPv4Properties().Index } catch { }
        try {
            $ips = @($n.GetIPProperties().UnicastAddresses |
                Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } |
                ForEach-Object { $_.Address.ToString() })
        } catch { }

        [void]$list.Add([pscustomobject]@{
            Name      = $n.Name
            Desc      = $d
            Category  = $cat
            Status    = [string]$n.OperationalStatus
            IfIndex   = $ifIndex
            SpeedMbps = [math]::Round($speed / 1e6, 0)
            BytesIn   = $bytesIn
            BytesOut  = $bytesOut
            IPv4      = $ips
        })
    }
    return $list.ToArray()
}

function Get-NetPulseRouting {
    $defaults = @()
    foreach ($row in [NetPulse.Native]::DefaultRoutes()) {
        $p = $row.Split('|')
        $defaults += [pscustomobject]@{ IfIndex = [int]$p[0]; Gateway = $p[1]; Metric = [int]$p[2] }
    }
    $best = $defaults | Sort-Object Metric | Select-Object -First 1
    return [pscustomobject]@{ DefaultRoute = $best; Defaults = @($defaults) }
}

function Get-NetPulseProxy {
    $ie = $null
    try { $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop } catch { }

    $ieOn = $false; $ieServer = ''; $pac = ''
    if ($ie) {
        $ieOn = ([int]$ie.ProxyEnable -eq 1)
        $ieServer = [string]$ie.ProxyServer
        $pac = [string]$ie.AutoConfigURL
    }

    $eff = ''
    try {
        $wp = [System.Net.WebRequest]::GetSystemWebProxy()
        $u = $wp.GetProxy([uri]'http://netpulse-probe.example')
        if ($u -and $u.AbsoluteUri -notmatch 'netpulse-probe\.example') { $eff = $u.AbsoluteUri }
    } catch { }

    $listening = @()
    try {
        $lp = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        $local = @($lp | Where-Object {
            $_.Address.Equals([System.Net.IPAddress]::Loopback) -or $_.Address.Equals([System.Net.IPAddress]::Any)
        } | ForEach-Object { $_.Port })
        $listening = @($local | Where-Object { $script:NetPulseProxyPorts -contains $_ } | Sort-Object -Unique)
    } catch { }

    $mode = 'direct'
    if ($eff) { $mode = 'system-proxy' }
    elseif ($pac) { $mode = 'pac' }
    elseif ($listening.Count -gt 0) { $mode = 'local-port' }

    return [pscustomobject]@{
        Mode      = $mode
        IeEnabled = $ieOn
        IeServer  = $ieServer
        PacUrl    = $pac
        Effective = $eff
        Listening = $listening
        HasTunnel = $false
        TunIfDesc = ''
        TunRatio  = 0.0
        ProxyActive = $false
        RouteMode = 'direct'
    }
}
#endregion


#region ---------- 探针目标 ----------
function Update-NetPulseTargets {
    param($State, [switch]$Force, [switch]$NoSpawn)

    $age = ((Get-Date) - $State.TargetAge).TotalSeconds
    if (-not $Force -and $State.Targets.Count -gt 0 -and $age -lt 300) { return }

    # 体检要竞速整个池子，放到后台线程做，别让前端掉帧
    if (-not $Force -and -not $NoSpawn) {
        if (-not $State.Refreshing) {
            $State.Refreshing = $true
            $ps = [PowerShell]::Create()
            [void]$ps.AddScript({
                param($path, $interval, $timeout)
                . $path
                $st = @{
                    TargetAge = [datetime]::MinValue; Targets = @(); SpecKeys = @()
                    ProbeInterval = $interval; ProbeTimeout = $timeout
                    Prober = $null; PrevBytes = @{}; PrevAt = [datetime]::MinValue
                    RttHist = New-Object System.Collections.Queue; LossHist = New-Object System.Collections.Queue
                    Samples = 0; LastTcp = $null; LastTcpAt = [datetime]::MinValue; RetransPct = 0.0
                    IsDown = $false; DropStreak = 0; Outages = New-Object System.Collections.ArrayList
                    LastHealth = 'unknown'; Events = New-Object System.Collections.ArrayList
                    LinkState = @{}; LastProxyMode = ''; LastActiveIf = ''; StartedAt = Get-Date
                }
                Update-NetPulseTargets -State $st -Force -NoSpawn
                ,@($st.Targets)
            }).AddArgument($State.ScriptPath).AddArgument($State.ProbeInterval).AddArgument($State.ProbeTimeout)
            [void]$ps.BeginInvoke()
            $State.PendingRefresh = $ps
            $State.RefreshStarted = Get-Date
        }
        return
    }

    $targets = New-Object System.Collections.ArrayList
    $routing = Get-NetPulseRouting

    $gw = ''
    if ($routing.DefaultRoute) { $gw = $routing.DefaultRoute.Gateway }
    if ($gw -match '^\d+\.\d+\.\d+\.\d+$' -and $gw -ne '0.0.0.0') {
        [void]$targets.Add([pscustomobject]@{ Key='gw'; Name='网关'; Kind='lan'; Type='ARP'; Ip=$gw; Port=0; Spec=$null })
    }

    $dns4 = @()
    foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($n.OperationalStatus -ne 'Up') { continue }
        try {
            $dns4 += @($n.GetIPProperties().DnsAddresses |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') } |
                ForEach-Object { $_.ToString() })
        } catch { }
    }
    $dns4 = @($dns4 | Select-Object -Unique)
    if ($dns4.Count -gt 0) {
        $d = $dns4[0]
        [void]$targets.Add([pscustomobject]@{ Key='dns'; Name='本地DNS'; Kind='lan'; Type='DNS'; Ip=$d; Port=53; Spec="D|$d|www.baidu.com" })
    }

    [void]$targets.Add([pscustomobject]@{ Key='dns2'; Name='公网DNS'; Kind='cn'; Type='DNS'; Ip='223.5.5.5'; Port=53; Spec='D|223.5.5.5|www.taobao.com' })

    # 候选池 + 国际线路一起并行竞速（串行要 6 秒，并行 1 秒内）
    $cand = @($script:NetPulseTcpPool) + @($script:NetPulseIntlPool)
    $specsIn = [string[]]@($cand | ForEach-Object { "$($_.Ip):$($_.Port)" })
    $rtts = [NetPulse.Native]::RankPool($specsIn, 900)

    $ranked = New-Object System.Collections.ArrayList
    $intlBest = $null
    for ($i = 0; $i -lt $cand.Count; $i++) {
        if ($rtts[$i] -lt 0) { continue }
        $c = $cand[$i]
        $isIntl = ($i -ge $script:NetPulseTcpPool.Count)
        if ($isIntl) {
            if (-not $intlBest -or $rtts[$i] -lt $intlBest.Ms) {
                $intlBest = [pscustomobject]@{ Ip=$c.Ip; Port=$c.Port; Name=$c.Name; Ms=$rtts[$i] }
            }
        } else {
            [void]$ranked.Add([pscustomobject]@{ Ip=$c.Ip; Port=$c.Port; Name=$c.Name; Ms=$rtts[$i] })
        }
    }

    $top = @($ranked | Sort-Object Ms | Select-Object -First 2)
    $idx = 0
    foreach ($t in $top) {
        [void]$targets.Add([pscustomobject]@{
            Key = "cn$idx"; Name=$t.Name; Kind='cn'; Type='TCP'; Ip=$t.Ip; Port=$t.Port
            Spec = "T|$($t.Ip)|$($t.Port)|0"
        })
        $idx++
    }
    if ($top.Count -eq 0) {
        $c = $script:NetPulseTcpPool[0]
        [void]$targets.Add([pscustomobject]@{ Key='cn0'; Name=$c.Name; Kind='cn'; Type='TCP'; Ip=$c.Ip; Port=$c.Port; Spec="T|$($c.Ip)|$($c.Port)|0" })
    }

    if ($intlBest) {
        [void]$targets.Add([pscustomobject]@{
            Key='intl'; Name=$intlBest.Name; Kind='intl'; Type='TCP'; Ip=$intlBest.Ip; Port=$intlBest.Port
            Spec="T|$($intlBest.Ip)|$($intlBest.Port)|0"
        })
    }

    $State.Targets = @($targets)
    $State.SpecKeys = @($targets | Where-Object { $_.Spec } | ForEach-Object { $_.Key })
    $State.TargetAge = Get-Date

    $specs = [string[]]@($targets | Where-Object { $_.Spec } | ForEach-Object { $_.Spec })
    if (-not $State.Prober) {
        $State.Prober = New-Object NetPulse.Prober($State.ProbeTimeout, $State.ProbeInterval)
        $State.Prober.Start()
    }
    $State.Prober.SetTargets($specs)
}
#endregion


#region ---------- 采样 ----------
function Get-NetPulseThroughput {
    param($Interfaces, $State, [datetime]$Now)

    $dt = 0.0
    if ($State.PrevAt -ne [datetime]::MinValue) { $dt = ($Now - $State.PrevAt).TotalSeconds }

    $rows = New-Object System.Collections.ArrayList
    $totalDown = 0.0; $totalUp = 0.0; $physDown = 0.0; $physUp = 0.0

    foreach ($i in $Interfaces) {
        $key = $i.Name
        $down = 0.0; $up = 0.0
        if ($dt -gt 0.15 -and $State.PrevBytes.ContainsKey($key)) {
            $p = $State.PrevBytes[$key]
            $down = [math]::Max(0, ($i.BytesIn - $p.In) / $dt)
            $up = [math]::Max(0, ($i.BytesOut - $p.Out) / $dt)
        }
        $State.PrevBytes[$key] = @{ In = $i.BytesIn; Out = $i.BytesOut }
        if ($i.Status -eq 'Up') {
            $totalDown += $down; $totalUp += $up
            if ($i.Category -in 'wifi', 'ethernet') { $physDown += $down; $physUp += $up }
        }
        [void]$rows.Add([pscustomobject]@{
            Name=$i.Name; Desc=$i.Desc; Category=$i.Category; Status=$i.Status
            IfIndex=$i.IfIndex; DownBps=$down; UpBps=$up; SpeedMbps=$i.SpeedMbps
        })
    }
    $State.PrevAt = $Now
    return [pscustomobject]@{ Interfaces=@($rows); DownBps=$totalDown; UpBps=$totalUp; PhysDown=$physDown; PhysUp=$physUp; ElapsedSec=$dt }
}

function Get-NetPulseTcpHealth {
    param($State)
    $now = Get-Date
    $cur = [NetPulse.Native]::TcpStats()
    if ($State.LastTcp -and ((($now - $State.LastTcpAt).TotalSeconds) -gt 0.2)) {
        $dOut = $cur[1] - $State.LastTcp[1]
        $dRe = $cur[2] - $State.LastTcp[2]
        if ($dOut -gt 0 -and $dRe -ge 0) {
            $State.RetransPct = [math]::Round(($dRe / [double]$dOut) * 100, 2)
        }
    }
    $State.LastTcp = $cur
    $State.LastTcpAt = $now
    return [pscustomobject]@{ CurrEstab = [int]$cur[0]; RetransPct = $State.RetransPct }
}

function Update-NetPulse {
    param($State)

    $now = Get-Date
    $State.Samples++

    # 首次启动同步体检（慢一次，1 秒左右）；之后每 5 分钟放后台做
    if ($State.Targets.Count -eq 0) {
        Update-NetPulseTargets -State $State -Force -NoSpawn
    } else {
        Update-NetPulseTargets -State $State
        if ($State.PendingRefresh) {
            $async = $State.PendingRefresh
            if ($async.InvocationStateInfo.State -eq 'Completed') {
                try {
                    $got = $async.EndInvoke($async.InvocationId)
                    if ($got -and $got.Count -gt 0) {
                        $State.Targets = @($got[0])
                        $State.SpecKeys = @($State.Targets | Where-Object { $_.Spec } | ForEach-Object { $_.Key })
                        $State.TargetAge = Get-Date
                        $specs = [string[]]@($State.Targets | Where-Object { $_.Spec } | ForEach-Object { $_.Spec })
                        if ($State.Prober) { $State.Prober.SetTargets($specs) }
                    }
                } catch { }
                $async.Dispose()
                $State.PendingRefresh = $null
                $State.Refreshing = $false
            } elseif ($async.InvocationStateInfo.State -eq 'Failed' -or $async.InvocationStateInfo.State -eq 'Stopped') {
                $async.Dispose()
                $State.PendingRefresh = $null
                $State.Refreshing = $false
            }
        }
    }

    $ifs = Get-NetPulseInterfaces
    $routing = Get-NetPulseRouting
    $proxy = Get-NetPulseProxy
    $tp = Get-NetPulseThroughput -Interfaces $ifs -State $State -Now $now
    $tcp = Get-NetPulseTcpHealth -State $State

    foreach ($i in $ifs) {
        $prev = $State.LinkState[$i.Name]
        if ($null -ne $prev -and $prev -ne $i.Status -and $i.Category -in 'wifi', 'ethernet', 'tunnel') {
            $txt = if ($i.Status -eq 'Up') { "$($i.Name) 链路恢复" } else { "$($i.Name) 链路中断" }
            [void](Add-NetPulseEvent -State $State -Kind 'link' -Text $txt)
        }
        $State.LinkState[$i.Name] = $i.Status
    }

    $gwIface = $null
    if ($routing.DefaultRoute) {
        $gwIface = $ifs | Where-Object { $_.IfIndex -eq $routing.DefaultRoute.IfIndex } | Select-Object -First 1
    }
    if (-not $gwIface) {
        $gwIface = $ifs | Where-Object { $_.Status -eq 'Up' -and $_.Category -in 'wifi', 'ethernet' } | Select-Object -First 1
    }

    $age = 0
    $raw = @()
    if ($State.Prober) { $raw = @($State.Prober.Snapshot([ref]$age)) }
    $specKeys = @($State.SpecKeys)
    $result = @{}
    for ($i = 0; $i -lt $specKeys.Count -and $i -lt $raw.Count; $i++) { $result[$specKeys[$i]] = [int]$raw[$i] }

    $probes = New-Object System.Collections.ArrayList
    foreach ($t in $State.Targets) {
        if ($t.Type -eq 'ARP') {
            $ok = [NetPulse.Native]::ArpReachable($t.Ip)
            [void]$probes.Add([pscustomobject]@{ Key=$t.Key; Name=$t.Name; Kind=$t.Kind; Type='ARP'; Ip=$t.Ip; RttMs=$(if($ok){1}else{-1}); Ok=$ok; Pending=$false })
        } else {
            # -2 = 探针线程还没出第一轮结果，不能当成"超时"统计，否则开屏就是 100% 丢包
            $ms = if ($result.ContainsKey($t.Key)) { $result[$t.Key] } else { -2 }
            $pending = ($ms -eq -2)
            [void]$probes.Add([pscustomobject]@{ Key=$t.Key; Name=$t.Name; Kind=$t.Kind; Type=$t.Type; Ip=$t.Ip; RttMs=$ms; Ok=($ms -ge 0); Pending=$pending })
        }
    }
    $known = @($probes | Where-Object { -not $_.Pending })
    $arpOk = (@($known | Where-Object { $_.Type -eq 'ARP' -and $_.Ok }).Count -gt 0)
    $wanProbes = @($known | Where-Object { $_.Kind -in 'cn', 'intl' })
    $wanOk = @($wanProbes | Where-Object { $_.Ok }).Count
    $lanProbes = @($known | Where-Object { $_.Kind -eq 'lan' })
    $lanOk = @($lanProbes | Where-Object { $_.Ok }).Count

    $isDown = $false
    if ($known.Count -gt 0) {
        if ($lanProbes.Count -gt 0 -and $lanOk -eq 0 -and $wanOk -eq 0) { $isDown = $true }
        elseif ($wanProbes.Count -gt 0 -and $wanOk -eq 0 -and -not $arpOk) { $isDown = $true }
    }

    if ($isDown) {
        $State.DropStreak++
        if ($State.DropStreak -eq 2) {
            $State.IsDown = $true
            [void]$State.Outages.Add([pscustomobject]@{ Start = $now.AddSeconds(-1); End = $null; Seconds = 0 })
            [void](Add-NetPulseEvent -State $State -Kind 'down' -Text '网络中断')
        } elseif ($State.DropStreak -gt 2 -and $State.Outages.Count -gt 0) {
            $o = $State.Outages[$State.Outages.Count - 1]
            $o.Seconds = [math]::Round(((Get-Date) - $o.Start).TotalSeconds, 1)
        }
    } else {
        if ($State.IsDown -and $State.Outages.Count -gt 0) {
            $o = $State.Outages[$State.Outages.Count - 1]
            $o.End = $now
            $o.Seconds = [math]::Round(($now - $o.Start).TotalSeconds, 1)
            [void](Add-NetPulseEvent -State $State -Kind 'up' -Text ("网络恢复（中断 {0:N1}s）" -f $o.Seconds))
        }
        $State.DropStreak = 0
        $State.IsDown = $false
    }

    $primary = @($known | Where-Object { $_.Kind -in 'cn', 'intl' -and $_.Type -ne 'ARP' -and $_.Ok })
    if ($primary.Count -eq 0) { $primary = @($known | Where-Object { $_.Key -eq 'dns' -and $_.Ok }) }
    $rttNow = 0.0
    if ($primary.Count -gt 0) { $rttNow = ($primary | Measure-Object RttMs -Average).Average }

    if ($rttNow -gt 0) {
        $State.RttHist.Enqueue($rttNow)
        while ($State.RttHist.Count -gt 150) { [void]$State.RttHist.Dequeue() }
    }

    $arr = @($State.RttHist.ToArray())
    $minRtt = 0.0; $medRtt = 0.0; $jitter = 0.0
    if ($arr.Count -gt 0) {
        $sorted = @($arr | Sort-Object)
        $minRtt = [double]$sorted[0]
        $medRtt = [double]$sorted[[int][math]::Floor($sorted.Count / 2)]
        $d = @()
        for ($k = 1; $k -lt $arr.Count; $k++) { $d += [math]::Abs($arr[$k] - $arr[$k - 1]) }
        if ($d.Count -gt 0) { $jitter = ($d | Measure-Object -Average).Average }
    }

    $probeOk = ($wanOk -gt 0) -or ($lanOk -gt 0)
    if ($known.Count -gt 0) {          # 还没有任何探针结果时不要污染丢包窗口
        $State.LossHist.Enqueue($probeOk)
        while ($State.LossHist.Count -gt 60) { [void]$State.LossHist.Dequeue() }
    }
    $lossArr = @($State.LossHist.ToArray())
    $lossPct = 0.0
    if ($lossArr.Count -gt 0) {
        $lossPct = [math]::Round(((@($lossArr | Where-Object { -not $_ }).Count) / $lossArr.Count) * 100, 0)
    }

    $health = 'healthy'
    $reasons = @()
    if ($State.IsDown) {
        $health = 'down'; $reasons += '已经断线'
    } else {
        if ($medRtt -gt 0 -and $minRtt -gt 0) {
            $inflate = ($medRtt - $minRtt) / [math]::Max(1, $minRtt)
            if ($inflate -ge 1.0) { $health = 'congested'; $reasons += ("RTT 比基线高 {0:P0}（队列堆积）" -f $inflate) }
            elseif ($inflate -ge 0.5) { $health = 'loaded'; $reasons += ("RTT 比基线高 {0:P0}" -f $inflate) }
        }
        if ($jitter -gt 50) {
            if ($health -eq 'healthy') { $health = 'unstable' }
            $reasons += ("抖动 {0:N0} ms" -f $jitter)
        }
        if ($lossPct -ge 15) {
            if ($health -in 'healthy', 'loaded', 'unstable') { $health = 'lossy' }
            $reasons += ("近一分钟丢包 {0}%" -f $lossPct)
        }
        if ($State.RetransPct -ge 8) {
            if ($health -in 'healthy', 'loaded') { $health = 'lossy' }
            $reasons += ("TCP 重传 {0:N1}%" -f $State.RetransPct)
        }
    }

    if ($health -ne $State.LastHealth) {
        if ($State.LastHealth -ne 'unknown') {
            $map = @{ healthy='正常'; loaded='有负载'; congested='拥塞'; unstable='不稳定'; lossy='丢包'; down='断线' }
            [void](Add-NetPulseEvent -State $State -Kind 'health' -Text ("状态 → {0}" -f $map[$health]))
        }
        $State.LastHealth = $health
    }

    $activeName = if ($gwIface) { $gwIface.Name } else { '' }
    if ($State.LastProxyMode -and $State.LastProxyMode -ne $proxy.Mode) {
        $pm = @{ 'direct'='直连'; 'system-proxy'='系统代理'; 'pac'='PAC'; 'local-port'='本地代理端口' }
        [void](Add-NetPulseEvent -State $State -Kind 'mode' -Text ("代理模式 → {0}" -f $pm[$proxy.Mode]))
    }
    $State.LastProxyMode = $proxy.Mode

    if ($State.LastActiveIf -and $State.LastActiveIf -ne $activeName) {
        [void](Add-NetPulseEvent -State $State -Kind 'mode' -Text ("出口网卡 → $activeName"))
    }
    $State.LastActiveIf = $activeName

    $tunnelIdx = @{}
    foreach ($i in $ifs) { if ($i.Category -eq 'tunnel' -and $i.Status -eq 'Up') { $tunnelIdx[$i.IfIndex] = $i.Name } }
    $routeDetail = @()
    $tunCount = 0; $wanCount = 0
    foreach ($p in $wanProbes) {
        $idx = [NetPulse.Native]::BestRouteIfIndex($p.Ip)
        $isTun = $tunnelIdx.ContainsKey($idx)
        $wanCount++
        if ($isTun) { $tunCount++ }
        $iface = @($ifs | Where-Object { $_.IfIndex -eq $idx }) | Select-Object -First 1
        $routeDetail += [pscustomobject]@{
            Key = $p.Key; Ip = $p.Ip; IfIndex = $idx
            IfName = if ($iface) { $iface.Name } else { '' }
            Category = if ($iface) { $iface.Category } else { '' }
            ViaTunnel = $isTun
        }
    }
    $proxy.HasTunnel = ($tunCount -gt 0)
    $proxy.TunRatio = if ($wanCount -gt 0) { [math]::Round($tunCount / [double]$wanCount, 2) } else { 0 }
    $tunNames = @($routeDetail | Where-Object { $_.ViaTunnel } | ForEach-Object { $_.IfName } | Select-Object -Unique)
    $proxy.TunIfDesc = ($tunNames -join ',')

    # 代理开着但目标走物理网卡 = 规则模式（分流）；目标全走 TUN = 全局模式。
    # 这比单看"有没有 TUN 网卡"有用：规则模式下 TUN 网卡存在，但你的目标并不经过它。
    $proxy.ProxyActive = ($proxy.Mode -ne 'direct')
    if ($proxy.ProxyActive -and $wanCount -gt 0) {
        if ($tunCount -eq $wanCount) { $proxy.RouteMode = 'global' }      # 全部走隧道
        elseif ($tunCount -gt 0)     { $proxy.RouteMode = 'rule' }        # 部分走隧道
        else                         { $proxy.RouteMode = 'direct-out' }  # 代理在跑但这几个目标直连
    } elseif ($tunCount -gt 0) {
        $proxy.RouteMode = 'tun-only'
    } else {
        $proxy.RouteMode = 'direct'
    }

    return [pscustomobject]@{
        At            = $now
        UptimeSec     = [math]::Round(((Get-Date) - $State.StartedAt).TotalSeconds, 0)
        Samples       = $State.Samples
        Interfaces    = $ifs
        ActiveIface   = $gwIface
        Throughput    = $tp
        Routing       = $routing
        Proxy         = $proxy
        RouteDetail   = $routeDetail
        Probes        = @($probes)
        ProbeAgeMs    = $age
        Gateway       = if ($routing.DefaultRoute) { $routing.DefaultRoute.Gateway } else { '' }
        IsDown        = $State.IsDown
        Outages       = $State.Outages.ToArray()
        OutageCount   = $State.Outages.Count
        Health        = $health
        HealthReasons = $reasons
        Tcp           = $tcp
        Stats         = [pscustomobject]@{
            RttNow  = [math]::Round($rttNow, 1)
            MinRtt  = [math]::Round($minRtt, 1)
            MedRtt  = [math]::Round($medRtt, 1)
            Jitter  = [math]::Round($jitter, 1)
            LossPct = $lossPct
            Retrans = $State.RetransPct
            WanOk   = $wanOk
            LanOk   = $lanOk
        }
        Events        = $State.Events.ToArray()
    }
}

function Format-NetPulseRate {
    param([double]$Bps, [switch]$Bits)
    $v = if ($Bits) { $Bps * 8 } else { $Bps }
    $unit = if ($Bits) { 'bps' } else { 'B/s' }
    $scale = if ($Bits) { 1000.0 } else { 1024.0 }
    if ($v -ge $scale * $scale * $scale) { return ('{0:N2} G{1}' -f ($v / ($scale * $scale * $scale)), $unit) }
    if ($v -ge $scale * $scale) { return ('{0:N2} M{1}' -f ($v / ($scale * $scale)), $unit) }
    if ($v -ge $scale) { return ('{0:N1} K{1}' -f ($v / $scale), $unit) }
    return ('{0:N0} {1}' -f $v, $unit)
}

function Stop-NetPulse {
    param($State)
    if ($State -and $State.Prober) { $State.Prober.Stop() }
}
#endregion
