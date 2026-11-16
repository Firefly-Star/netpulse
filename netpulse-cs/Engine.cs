using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32;

namespace NetPulse
{
    public sealed class InterfaceInfo
    {
        public string Name, Desc, Category, Status;
        public int IfIndex;
        public int SpeedMbps;
        public double BytesIn, BytesOut;
        public string[] IPv4 = Array.Empty<string>();
    }

    public sealed class ThroughputRow
    {
        public string Name, Desc, Category, Status;
        public int IfIndex, SpeedMbps;
        public double DownBps, UpBps;
    }

    public sealed class ProbeResult
    {
        public string Key, Name, Kind, Type, Ip;
        public int RttMs = -2;      // -2 = 待测，-1 = 失败，>0 = 成功
        public bool Pending => RttMs == -2;
        public bool Ok => RttMs >= 0;
    }

    public sealed class RouteDetail
    {
        public string Key, Ip, IfName, Category;
        public int IfIndex;
        public bool ViaTunnel;
    }

    public sealed class WifiInfo
    {
        public bool Available, Connected;
        public string Ssid = "", Bssid = "", Band = "", Radio = "", Reason = "";
        public int SignalPct, Rssi, Channel;
        public double RxMbps, TxMbps;
    }

    public sealed class ProcConn
    {
        public int Pid, Count;
        public string Name = "";
        public string[] Peers = Array.Empty<string>();
    }

    public sealed class ProxyInfo
    {
        public string Mode = "direct", IeServer = "", PacUrl = "", Effective = "";
        public bool IeEnabled, HasTunnel, ProxyActive;
        public string[] Listening = Array.Empty<string>();
        public string TunIfDesc = "";
        public double TunRatio;
        public string RouteMode = "direct";
    }

    public sealed class Stats
    {
        public double RttNow, MinRtt, MedRtt, Jitter, LossPct, Retrans;
        public int WanOk, LanOk;
    }

    public sealed class Sample
    {
        public DateTime At;
        public long UptimeSec;
        public InterfaceInfo[] Interfaces = Array.Empty<InterfaceInfo>();
        public InterfaceInfo ActiveIface;
        public ThroughputRow[] ThroughputRows = Array.Empty<ThroughputRow>();
        public double PhysDown, PhysUp, AllDown, AllUp;
        public List<ProbeResult> Probes = new List<ProbeResult>();
        public List<RouteDetail> RouteDetail = new List<RouteDetail>();
        public string Gateway = "";
        public int DefaultIfIndex;
        public ProxyInfo Proxy = new ProxyInfo();
        public bool IsDown;
        public int OutageCount;
        public string LastOutageText = "";
        public string Health = "unknown";
        public List<string> HealthReasons = new List<string>();
        public Stats Stats = new Stats();
        public int ProbeAgeMs;
        public bool Elevated;
        public WifiInfo Wifi = new WifiInfo();
        public List<ProcConn> Connections = new List<ProcConn>();
        public Dictionary<int, Native.IfErrorInfo> IfErrors = new Dictionary<int, Native.IfErrorInfo>();
    }

    /// <summary>后台探针线程：界面只读快照，永远不会被网络卡住。</summary>
    public sealed class Prober : IDisposable
    {
        private readonly object _lock = new object();
        private string[] _specs = Array.Empty<string>();
        private int[] _latest = Array.Empty<int>();
        private long _latestTicks;
        private readonly int _timeoutMs, _intervalMs;
        private Thread _thread;
        private volatile bool _running;

        public Prober(int timeoutMs, int intervalMs)
        {
            _timeoutMs = timeoutMs;
            _intervalMs = intervalMs;
        }

        public void SetTargets(string[] specs)
        {
            lock (_lock)
            {
                _specs = specs ?? Array.Empty<string>();
                var arr = new int[_specs.Length];
                for (int i = 0; i < arr.Length; i++) arr[i] = -2;   // 待测
                _latest = arr;
                _latestTicks = 0;
            }
        }

        public void Start()
        {
            if (_running) return;
            _running = true;
            _thread = new Thread(Loop) { IsBackground = true, Name = "NetPulse-Prober", Priority = ThreadPriority.BelowNormal };
            _thread.Start();
        }

        public void Dispose()
        {
            _running = false;
            try { _thread?.Join(500); } catch { }
        }

        private void Loop()
        {
            while (_running)
            {
                string[] specs;
                lock (_lock) specs = _specs;

                var res = new int[specs.Length];
                if (specs.Length > 0)
                {
                    Parallel.For(0, specs.Length, i =>
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
                }

                int slept = 0;
                while (_running && slept < _intervalMs)
                {
                    Thread.Sleep(50);
                    slept += 50;
                }
            }
        }

        public int[] Snapshot(out int ageMs)
        {
            lock (_lock)
            {
                var copy = new int[_latest.Length];
                Array.Copy(_latest, copy, _latest.Length);
                ageMs = _latestTicks == 0
                    ? int.MaxValue
                    : (int)((DateTime.UtcNow.Ticks - _latestTicks) / TimeSpan.TicksPerMillisecond);
                return copy;
            }
        }
    }

    public sealed class Engine : IDisposable
    {
        // 目标池：只有当前连得上的才会被采用
        private static readonly (string Name, string Ip, int Port)[] TcpPool =
        {
            ("阿里云",   "223.5.5.5",       443),
            ("阿里云",   "223.6.6.6",       443),
            ("腾讯云",   "119.29.29.29",    443),
            ("腾讯云",   "1.12.12.12",      443),
            ("百度",     "180.76.76.76",    443),
            ("114DNS",   "114.114.114.114", 443),
            ("移动大区", "120.53.53.53",    443),
        };

        private static readonly (string Name, string Ip, int Port)[] IntlPool =
        {
            ("Cloudflare", "1.1.1.1", 443),
            ("Google",     "8.8.8.8", 443),
        };

        private static readonly int[] ProxyPorts = { 7890, 7891, 7897, 1080, 10808, 10809, 2080, 2081, 8889, 20171, 6152 };

        private readonly Prober _prober = new Prober(900, 1000);
        private readonly DateTime _startedAt = DateTime.Now;

        private readonly List<(string Key, string Name, string Kind, string Type, string Ip, int Port, string Spec)> _targets
            = new List<(string, string, string, string, string, int, string)>();

        private DateTime _targetAge = DateTime.MinValue;
        private readonly Dictionary<string, (double In, double Out)> _prevBytes = new Dictionary<string, (double, double)>();
        private DateTime _prevAt = DateTime.MinValue;

        private readonly Queue<double> _rttHist = new Queue<double>();
        private readonly Queue<bool> _lossHist = new Queue<bool>();

        private long[] _lastTcp;
        private DateTime _lastTcpAt = DateTime.MinValue;
        private double _retransPct;

        private bool _isDown;
        private int _dropStreak;
        private readonly List<(DateTime Start, DateTime? End, double Seconds)> _outages = new List<(DateTime, DateTime?, double)>();
        private string _lastHealth = "unknown";
        private readonly Dictionary<string, string> _linkState = new Dictionary<string, string>();



        private DateTime _elevAge = DateTime.MinValue;
        private WifiInfo _wifi = new WifiInfo();
        private List<ProcConn> _conns = new List<ProcConn>();
        private Dictionary<int, Native.IfErrorInfo> _ifErrors = new Dictionary<int, Native.IfErrorInfo>();

        public Engine()
        {
            _prober.Start();
        }

        public void Dispose() => _prober.Dispose();

        // ================= 发现 =================

        private static List<InterfaceInfo> GetInterfaces()
        {
            var list = new List<InterfaceInfo>();
            foreach (var n in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (n.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;

                string d = n.Description ?? "";
                string cat = "other";
                if (System.Text.RegularExpressions.Regex.IsMatch(d, "Wintun|WireGuard|Tailscale|TAP-Windows|OpenVPN|sing-box|mihomo|Clash|Netch"))
                    cat = "tunnel";
                else if (System.Text.RegularExpressions.Regex.IsMatch(d, "VMware|Hyper-V|VirtualBox|vEthernet|Npcap|Wi-Fi Direct"))
                    cat = "virtual";
                else if (n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211) cat = "wifi";
                else if (n.NetworkInterfaceType == NetworkInterfaceType.Ethernet) cat = "ethernet";
                else if (System.Text.RegularExpressions.Regex.IsMatch(d, "Wi-Fi|Wireless|802\\.11")) cat = "wifi";

                int speed = 0;
                try
                {
                    long sp = n.Speed;
                    if (sp > 0 && sp < 1000000000000000000L) speed = (int)(sp / 1000000);
                }
                catch { }

                // .NET 没有 GetIPv6Statistics；GetIPStatistics 已含 IPv4（且 IPv6 流量也会计入网卡计数）
                double bin = 0, bout = 0;
                try { var s4 = n.GetIPv4Statistics(); bin += s4.BytesReceived; bout += s4.BytesSent; } catch { }

                int idx = -1;
                string[] ips = Array.Empty<string>();
                try
                {
                    var props = n.GetIPProperties();
                    idx = props.GetIPv4Properties()?.Index ?? -1;
                    ips = props.UnicastAddresses
                        .Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
                        .Select(a => a.Address.ToString()).ToArray();
                }
                catch { }

                list.Add(new InterfaceInfo
                {
                    Name = n.Name, Desc = d, Category = cat, Status = n.OperationalStatus.ToString(),
                    IfIndex = idx, SpeedMbps = speed, BytesIn = bin, BytesOut = bout, IPv4 = ips
                });
            }
            return list;
        }

        private static ProxyInfo GetProxy()
        {
            var p = new ProxyInfo();
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Internet Settings"))
                {
                    if (k != null)
                    {
                        p.IeEnabled = Convert.ToInt32(k.GetValue("ProxyEnable") ?? 0) == 1;
                        p.IeServer = k.GetValue("ProxyServer") as string ?? "";
                        p.PacUrl = k.GetValue("AutoConfigURL") as string ?? "";
                    }
                }
            }
            catch { }

            try
            {
                var wp = WebRequest.GetSystemWebProxy();
                var u = wp.GetProxy(new Uri("http://netpulse-probe.example"));
                if (u != null && !u.AbsoluteUri.Contains("netpulse-probe.example"))
                    p.Effective = u.AbsoluteUri;
            }
            catch { }

            var open = new List<string>();
            try
            {
                var listeners = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners();
                open = listeners
                    .Where(l => l.Address.Equals(IPAddress.Loopback) || l.Address.Equals(IPAddress.Any))
                    .Select(l => l.Port)
                    .Where(port => ProxyPorts.Contains(port))
                    .Distinct().OrderBy(x => x)
                    .Select(x => x.ToString()).ToList();
            }
            catch { }

            p.Listening = open.ToArray();
            if (!string.IsNullOrEmpty(p.Effective)) p.Mode = "system-proxy";
            else if (!string.IsNullOrEmpty(p.PacUrl)) p.Mode = "pac";
            else if (open.Count > 0) p.Mode = "local-port";
            else p.Mode = "direct";

            return p;
        }

        // ================= 目标选择 =================

        private void UpdateTargets(bool force = false)
        {
            if (!force && _targets.Count > 0 && (DateTime.Now - _targetAge).TotalSeconds < 300) return;

            var list = new List<(string, string, string, string, string, int, string)>();

            // 1) 网关：ARP，≈0 流量
            var routes = Native.DefaultRoutes();
            var best = routes.OrderBy(r => r.Metric).FirstOrDefault();
            if (best.Gateway != null && IPAddress.TryParse(best.Gateway, out _))
                list.Add(("gw", "网关", "lan", "ARP", best.Gateway, 0, null));

            // 2) 系统解析器：UDP DNS
            var dns4 = new List<string>();
            foreach (var n in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (n.OperationalStatus != OperationalStatus.Up) continue;
                try
                {
                    dns4.AddRange(n.GetIPProperties().DnsAddresses
                        .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !a.ToString().StartsWith("127."))
                        .Select(a => a.ToString()));
                }
                catch { }
            }
            var dnsPick = dns4.Distinct().FirstOrDefault();
            if (dnsPick != null)
                list.Add(("dns", "本地DNS", "lan", "DNS", dnsPick, 53, $"D|{dnsPick}|www.baidu.com"));

            // 3) 公网 DNS
            list.Add(("dns2", "公网DNS", "cn", "DNS", "223.5.5.5", 53, "D|223.5.5.5|www.taobao.com"));

            // 4) TCP 竞速：只留当前最快的两个
            var cand = TcpPool.Concat(IntlPool).ToArray();
            var rtts = new int[cand.Length];
            Parallel.For(0, cand.Length, i => rtts[i] = Native.TcpProbe(cand[i].Ip, cand[i].Port, 0, 900));

            var ranked = new List<(string Name, string Ip, int Port, int Ms)>();
            (string Name, string Ip, int Port, int Ms)? intlBest = null;
            for (int i = 0; i < cand.Length; i++)
            {
                if (rtts[i] < 0) continue;
                if (i >= TcpPool.Length)
                {
                    if (intlBest == null || rtts[i] < intlBest.Value.Ms)
                        intlBest = (cand[i].Name, cand[i].Ip, cand[i].Port, rtts[i]);
                }
                else ranked.Add((cand[i].Name, cand[i].Ip, cand[i].Port, rtts[i]));
            }

            int idx = 0;
            foreach (var t in ranked.OrderBy(x => x.Ms).Take(2))
            {
                list.Add(($"cn{idx}", t.Name, "cn", "TCP", t.Ip, t.Port, $"T|{t.Ip}|{t.Port}|0"));
                idx++;
            }
            if (idx == 0)
            {
                var c = TcpPool[0];
                list.Add(("cn0", c.Name, "cn", "TCP", c.Ip, c.Port, $"T|{c.Ip}|{c.Port}|0"));
            }

            if (intlBest != null)
            {
                var t = intlBest.Value;
                list.Add(("intl", t.Name, "intl", "TCP", t.Ip, t.Port, $"T|{t.Ip}|{t.Port}|0"));
            }

            _targets.Clear();
            _targets.AddRange(list);
            _targetAge = DateTime.Now;
            _prober.SetTargets(_targets.Where(t => t.Spec != null).Select(t => t.Spec).ToArray());
        }

        // ================= 提权数据（5 秒一次）=================

        private void RefreshElevated()
        {
            if ((DateTime.Now - _elevAge).TotalSeconds < 5) return;
            _elevAge = DateTime.Now;

            try { _wifi = WifiProbe.Read(); } catch { }
            try { _ifErrors = Native.InterfaceErrors(); } catch { }

            try
            {
                var conns = Native.EstablishedConnections();
                var byPid = conns.GroupBy(c => c.Pid)
                    .Select(g => new ProcConn
                    {
                        Pid = g.Key,
                        Count = g.Count(),
                        Name = SafeProcName(g.Key),
                        Peers = g.Select(x => x.RemoteIp).Distinct().Take(3).ToArray()
                    })
                    .OrderByDescending(x => x.Count)
                    .Take(6).ToList();
                _conns = conns.Count > 0 ? byPid : new List<ProcConn>();
            }
            catch { _conns = new List<ProcConn>(); }
        }

        private static string SafeProcName(int pid)
        {
            try { return Process.GetProcessById(pid).ProcessName; }
            catch { return $"pid {pid}"; }
        }

        // ================= 采样 =================

        public Sample Capture()
        {
            var now = DateTime.Now;
            UpdateTargets();
            RefreshElevated();

            var ifs = GetInterfaces();
            var proxy = GetProxy();

            // 吞吐
            double dt = _prevAt == DateTime.MinValue ? 0 : (now - _prevAt).TotalSeconds;
            var rows = new List<ThroughputRow>();
            double pDown = 0, pUp = 0, aDown = 0, aUp = 0;
            foreach (var i in ifs)
            {
                double dn = 0, up = 0;
                if (dt > 0.15 && _prevBytes.TryGetValue(i.Name, out var prev))
                {
                    dn = Math.Max(0, (i.BytesIn - prev.In) / dt);
                    up = Math.Max(0, (i.BytesOut - prev.Out) / dt);
                }
                _prevBytes[i.Name] = (i.BytesIn, i.BytesOut);
                if (i.Status == "Up")
                {
                    aDown += dn; aUp += up;
                    if (i.Category == "wifi" || i.Category == "ethernet") { pDown += dn; pUp += up; }
                }
                rows.Add(new ThroughputRow
                {
                    Name = i.Name, Desc = i.Desc, Category = i.Category, Status = i.Status,
                    IfIndex = i.IfIndex, SpeedMbps = i.SpeedMbps, DownBps = dn, UpBps = up
                });
            }
            _prevAt = now;

            // TCP 重传
            var cur = Native.TcpStats();
            if (_lastTcp != null && (now - _lastTcpAt).TotalSeconds > 0.2)
            {
                long dOut = cur[1] - _lastTcp[1];
                long dRe = cur[2] - _lastTcp[2];
                if (dOut > 0 && dRe >= 0) _retransPct = Math.Round((double)dRe / dOut * 100, 2);
            }
            _lastTcp = cur;
            _lastTcpAt = now;

            // 探针
            var raw = _prober.Snapshot(out int age);
            var specKeys = _targets.Where(t => t.Spec != null).Select(t => t.Key).ToArray();
            var map = new Dictionary<string, int>();
            for (int i = 0; i < specKeys.Length && i < raw.Length; i++) map[specKeys[i]] = raw[i];

            var probes = new List<ProbeResult>();
            foreach (var t in _targets)
            {
                var pr = new ProbeResult { Key = t.Key, Name = t.Name, Kind = t.Kind, Type = t.Type, Ip = t.Ip };
                if (t.Type == "ARP")
                {
                    bool ok = Native.ArpReachable(t.Ip);
                    pr.RttMs = ok ? 1 : -1;
                }
                else pr.RttMs = map.TryGetValue(t.Key, out int v) ? v : -2;
                probes.Add(pr);
            }

            var known = probes.Where(p => !p.Pending).ToList();

            // 断线判定
            bool arpOk = known.Any(p => p.Type == "ARP" && p.Ok);
            var wan = known.Where(p => p.Kind is "cn" or "intl").ToList();
            int wanOk = wan.Count(p => p.Ok);
            var lan = known.Where(p => p.Kind == "lan").ToList();
            int lanOk = lan.Count(p => p.Ok);

            bool isDown = false;
            if (known.Count > 0)
            {
                if (lan.Count > 0 && lanOk == 0 && wanOk == 0) isDown = true;
                else if (wan.Count > 0 && wanOk == 0 && !arpOk) isDown = true;
            }

            if (isDown)
            {
                _dropStreak++;
                if (_dropStreak == 2)
                {
                    _isDown = true;
                    _outages.Add((now.AddSeconds(-1), null, 0));
                }
                else if (_dropStreak > 2 && _outages.Count > 0)
                {
                    var o = _outages[_outages.Count - 1];
                    _outages[_outages.Count - 1] = (o.Start, o.End, Math.Round((DateTime.Now - o.Start).TotalSeconds, 1));
                }
            }
            else
            {
                if (_isDown && _outages.Count > 0)
                {
                    var o = _outages[_outages.Count - 1];
                    _outages[_outages.Count - 1] = (o.Start, now, Math.Round((now - o.Start).TotalSeconds, 1));
                }
                _dropStreak = 0;
                _isDown = false;
            }

            // RTT 基线
            var primary = known.Where(p => p.Kind is "cn" or "intl" && p.Type != "ARP" && p.Ok).ToList();
            if (primary.Count == 0) primary = known.Where(p => p.Key == "dns" && p.Ok).ToList();
            double rttNow = primary.Count > 0 ? primary.Average(p => p.RttMs) : 0;

            if (rttNow > 0)
            {
                _rttHist.Enqueue(rttNow);
                while (_rttHist.Count > 150) _rttHist.Dequeue();
            }

            var arr = _rttHist.ToArray();
            double minRtt = 0, medRtt = 0, jitter = 0;
            if (arr.Length > 0)
            {
                var sorted = arr.OrderBy(x => x).ToArray();
                minRtt = sorted[0];
                medRtt = sorted[sorted.Length / 2];
                if (arr.Length > 1)
                {
                    double sum = 0;
                    for (int i = 1; i < arr.Length; i++) sum += Math.Abs(arr[i] - arr[i - 1]);
                    jitter = sum / (arr.Length - 1);
                }
            }

            bool probeOk = wanOk > 0 || lanOk > 0;
            if (known.Count > 0)
            {
                _lossHist.Enqueue(probeOk);
                while (_lossHist.Count > 60) _lossHist.Dequeue();
            }
            double lossPct = _lossHist.Count > 0
                ? Math.Round(_lossHist.Count(x => !x) / (double)_lossHist.Count * 100, 0)
                : 0;

            // 健康度
            string health = "healthy";
            var reasons = new List<string>();
            if (_isDown) { health = "down"; reasons.Add("已经断线"); }
            else
            {
                if (medRtt > 0 && minRtt > 0)
                {
                    double inflate = (medRtt - minRtt) / Math.Max(1, minRtt);
                    if (inflate >= 1.0) { health = "congested"; reasons.Add($"RTT 比基线高 {inflate:P0}（队列堆积）"); }
                    else if (inflate >= 0.5) { health = "loaded"; reasons.Add($"RTT 比基线高 {inflate:P0}"); }
                }
                if (jitter > 50)
                {
                    if (health == "healthy") health = "unstable";
                    reasons.Add($"抖动 {jitter:N0} ms");
                }
                if (lossPct >= 15)
                {
                    if (health is "healthy" or "loaded" or "unstable") health = "lossy";
                    reasons.Add($"近一分钟丢包 {lossPct}%");
                }
                if (_retransPct >= 8)
                {
                    if (health is "healthy" or "loaded") health = "lossy";
                    reasons.Add($"TCP 重传 {_retransPct:N1}%");
                }
            }
            _lastHealth = health;

            // 出口网卡
            var bestRoute = Native.DefaultRoutes().OrderBy(r => r.Metric).FirstOrDefault();
            InterfaceInfo gwIface = null;
            if (bestRoute.Gateway != null)
                gwIface = ifs.FirstOrDefault(i => i.IfIndex == bestRoute.IfIndex);
            if (gwIface == null)
                gwIface = ifs.FirstOrDefault(i => i.Status == "Up" && (i.Category == "wifi" || i.Category == "ethernet"));

            // 隧道分流
            var tunnelIdx = ifs.Where(i => i.Category == "tunnel" && i.Status == "Up")
                               .ToDictionary(i => i.IfIndex, i => i.Name);
            var routeDetail = new List<RouteDetail>();
            int tunCount = 0, wanCount = 0;
            foreach (var p in wan)
            {
                int idx2 = Native.BestRouteIfIndex(p.Ip);
                bool viaTun = tunnelIdx.ContainsKey(idx2);
                wanCount++;
                if (viaTun) tunCount++;
                var iface = ifs.FirstOrDefault(i => i.IfIndex == idx2);
                routeDetail.Add(new RouteDetail
                {
                    Key = p.Key, Ip = p.Ip, IfIndex = idx2,
                    IfName = iface?.Name ?? "", Category = iface?.Category ?? "", ViaTunnel = viaTun
                });
            }

            proxy.HasTunnel = tunCount > 0;
            proxy.TunRatio = wanCount > 0 ? Math.Round((double)tunCount / wanCount, 2) : 0;
            proxy.TunIfDesc = string.Join(",", routeDetail.Where(r => r.ViaTunnel).Select(r => r.IfName).Distinct());
            proxy.ProxyActive = proxy.Mode != "direct";

            if (proxy.ProxyActive && wanCount > 0)
                proxy.RouteMode = tunCount == wanCount ? "global" : tunCount > 0 ? "rule" : "direct-out";
            else if (tunCount > 0) proxy.RouteMode = "tun-only";
            else proxy.RouteMode = "direct";

            string lastOutage = "";
            if (_outages.Count > 0)
            {
                var o = _outages[_outages.Count - 1];
                string dur = o.End.HasValue ? $"{o.Seconds:N1}s" : "进行中";
                lastOutage = $"累计 {_outages.Count} 次 · 最近 {o.Start:HH:mm:ss} 断 {dur}";
            }

            return new Sample
            {
                At = now,
                UptimeSec = (long)(now - _startedAt).TotalSeconds,
                Interfaces = ifs.ToArray(),
                ActiveIface = gwIface,
                ThroughputRows = rows.ToArray(),
                PhysDown = pDown, PhysUp = pUp, AllDown = aDown, AllUp = aUp,
                Probes = probes,
                RouteDetail = routeDetail,
                Gateway = bestRoute.Gateway ?? "",
                DefaultIfIndex = bestRoute.IfIndex,
                Proxy = proxy,
                IsDown = _isDown,
                OutageCount = _outages.Count,
                LastOutageText = lastOutage,
                Health = health,
                HealthReasons = reasons,
                ProbeAgeMs = age,
                Elevated = WifiProbe.IsElevated,
                Wifi = _wifi,
                Connections = _conns,
                IfErrors = _ifErrors,
                Stats = new Stats
                {
                    RttNow = Math.Round(rttNow, 1),
                    MinRtt = Math.Round(minRtt, 1),
                    MedRtt = Math.Round(medRtt, 1),
                    Jitter = Math.Round(jitter, 1),
                    LossPct = lossPct,
                    Retrans = _retransPct,
                    WanOk = wanOk,
                    LanOk = lanOk
                }
            };
        }
    }
}
