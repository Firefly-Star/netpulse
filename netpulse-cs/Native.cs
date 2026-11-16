using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace NetPulse
{
    /// <summary>原生互操作：全部用 P/Invoke 直连，避免依赖 PowerShell/WMI。</summary>
    public static class Native
    {
        // ---------- WS2_32 ----------
        private const int AF_INET = 2, SOCK_STREAM = 1, IPPROTO_TCP = 6;
        private const uint WSA_FLAG_OVERLAPPED = 0x01;
        private const int FIONBIO = unchecked((int)0x8004667E);
        private const int SOL_SOCKET = 0xFFFF, SO_ERROR = 0x1007;
        private const int IPPROTO_IP = 0, IP_TTL = 4;
        private const int WSAEWOULDBLOCK = 10035;
        private const int NO_ERROR = 0, ERROR_INSUFFICIENT_BUFFER = 122;

        [StructLayout(LayoutKind.Sequential)]
        private struct sockaddr_in
        {
            public ushort sin_family;
            public ushort sin_port;
            public uint sin_addr;
            public ulong sin_zero;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct TimeVal
        {
            public int tv_sec;
            public int tv_usec;
        }

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

        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern IntPtr WSASocket(int af, int type, int pr, IntPtr lp, uint g, uint fl);
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int connect(IntPtr s, ref sockaddr_in n, int l);
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int select(int n, IntPtr r, IntPtr w, IntPtr e, ref TimeVal t);
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int getsockopt(IntPtr s, int l, int o, ref int v, ref int len);
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int setsockopt(IntPtr s, int l, int o, ref int v, int len);
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int ioctlsocket(IntPtr s, int c, ref uint a);
        [DllImport("ws2_32.dll", SetLastError = true)]
        private static extern int closesocket(IntPtr s);
        [DllImport("ws2_32.dll")]
        private static extern int WSAGetLastError();

        // ---------- IPHLPAPI ----------
        [DllImport("iphlpapi.dll")]
        private static extern int GetBestRoute(uint dest, uint src, out MIB_IPFORWARDROW row);
        [DllImport("iphlpapi.dll")]
        private static extern int GetIpForwardTable(IntPtr p, ref int size, bool order);
        [DllImport("iphlpapi.dll")]
        private static extern int GetTcpStatistics(out TCPSTATS s);
        [DllImport("iphlpapi.dll")]
        private static extern int SendARP(int dest, int src, byte[] mac, ref int len);
        [DllImport("iphlpapi.dll")]
        private static extern int GetExtendedTcpTable(IntPtr p, ref int size, bool order, int af, int tbl, int reserved);

        private static ushort Htons(int p) => (ushort)(((p & 0xFF) << 8) | ((p >> 8) & 0xFF));

        private static uint ToUInt(string ip)
        {
            byte[] b = IPAddress.Parse(ip).GetAddressBytes();
            return (uint)(b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24));
        }

        /// <summary>非阻塞 TCP 连接计时；-1 = 超时/不可达。ttl=1 时探的是第一跳。</summary>
        public static int TcpProbe(string ip, int port, int ttl, int timeoutMs)
        {
            if (!IPAddress.TryParse(ip, out var addr) || addr.AddressFamily != AddressFamily.InterNetwork)
                return -1;

            IntPtr s = WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, IntPtr.Zero, 0, WSA_FLAG_OVERLAPPED);
            if (s == new IntPtr(-1)) return -1;
            IntPtr fs = IntPtr.Zero;
            try
            {
                uint nb = 1;
                ioctlsocket(s, FIONBIO, ref nb);
                if (ttl > 0)
                {
                    int t = ttl;
                    setsockopt(s, IPPROTO_IP, IP_TTL, ref t, 4);
                }

                byte[] b = addr.GetAddressBytes();
                var sa = new sockaddr_in
                {
                    sin_family = AF_INET,
                    sin_port = Htons(port),
                    sin_addr = BitConverter.ToUInt32(b, 0)
                };

                var sw = Stopwatch.StartNew();
                int rc = connect(s, ref sa, 16);
                int err = rc == 0 ? 0 : WSAGetLastError();
                if (rc != 0 && err != WSAEWOULDBLOCK) return -1;

                int size = 8 + 64 * 8;
                fs = Marshal.AllocHGlobal(size);
                for (int i = 0; i < size; i++) Marshal.WriteByte(fs, i, 0);
                Marshal.WriteInt32(fs, 0, 1);
                Marshal.WriteIntPtr(fs, 8, s);

                var tv = new TimeVal { tv_sec = timeoutMs / 1000, tv_usec = (timeoutMs % 1000) * 1000 };

                if (select(0, IntPtr.Zero, fs, IntPtr.Zero, ref tv) <= 0) return -1;
                int ms = (int)sw.ElapsedMilliseconds;

                int se = 0, len = 4;
                getsockopt(s, SOL_SOCKET, SO_ERROR, ref se, ref len);
                // 0=握手完成 10061=拒绝但主机在线 10065/10051=途中 ICMP 不可达：都算有真实往返
                if (se == 0 || se == 10061 || se == 10065 || se == 10051)
                    return ms < 1 ? 1 : ms;
                return -1;
            }
            catch { return -1; }
            finally
            {
                if (fs != IntPtr.Zero) Marshal.FreeHGlobal(fs);
                closesocket(s);
            }
        }

        /// <summary>自封包 UDP DNS 查询，绕过系统解析缓存。</summary>
        public static int DnsProbe(string server, string qname, int timeoutMs)
        {
            try
            {
                if (!IPAddress.TryParse(server, out var srv)) return -1;
                byte[] q = BuildQuery(qname, (ushort)(DateTime.UtcNow.Ticks & 0xFFFF));
                var ep = new IPEndPoint(srv, 53);
                using (var u = new UdpClient(srv.AddressFamily))
                {
                    u.Client.ReceiveTimeout = timeoutMs;
                    var sw = Stopwatch.StartNew();
                    u.Send(q, q.Length, ep);
                    var from = new IPEndPoint(
                        srv.AddressFamily == AddressFamily.InterNetworkV6 ? IPAddress.IPv6Any : IPAddress.Any, 0);
                    u.Receive(ref from);
                    int ms = (int)sw.ElapsedMilliseconds;
                    return ms < 1 ? 1 : ms;
                }
            }
            catch { return -1; }
        }

        private static byte[] BuildQuery(string qname, ushort id)
        {
            var b = new List<byte>(64);
            b.Add((byte)(id >> 8)); b.Add((byte)(id & 0xFF));
            b.Add(0x01); b.Add(0x00);
            b.Add(0x00); b.Add(0x01);
            b.AddRange(new byte[6]);
            foreach (string part in qname.Split('.'))
            {
                if (part.Length == 0) continue;
                b.Add((byte)part.Length);
                b.AddRange(Encoding.ASCII.GetBytes(part));
            }
            b.Add(0x00);
            b.Add(0x00); b.Add(0x01);
            b.Add(0x00); b.Add(0x01);
            return b.ToArray();
        }

        /// <summary>目的地会被哪块网卡送出去（区分直连 / 走 TUN）。</summary>
        public static int BestRouteIfIndex(string ip)
        {
            try
            {
                if (GetBestRoute(ToUInt(ip), 0, out var r) == 0) return (int)r.dwForwardIfIndex;
            }
            catch { }
            return -1;
        }

        /// <summary>默认路由：仅返回 dest=0 且 mask=0 的行。</summary>
        public static List<(int IfIndex, string Gateway, int Metric)> DefaultRoutes()
        {
            var res = new List<(int, string, int)>();
            int size = 0;
            int rc = GetIpForwardTable(IntPtr.Zero, ref size, false);
            if (rc != NO_ERROR && rc != ERROR_INSUFFICIENT_BUFFER) return res;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetIpForwardTable(buf, ref size, false) != 0) return res;
                int n = Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_IPFORWARDROW));
                for (int i = 0; i < n; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * rowSize);
                    var r = (MIB_IPFORWARDROW)Marshal.PtrToStructure(p, typeof(MIB_IPFORWARDROW));
                    if (r.dwForwardDest != 0 || r.dwForwardMask != 0) continue;
                    if (r.dwForwardNextHop == 0) continue;
                    string hop = new IPAddress(BitConverter.GetBytes(r.dwForwardNextHop)).ToString();
                    res.Add(((int)r.dwForwardIfIndex, hop, (int)r.dwForwardMetric1));
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return res;
        }

        /// <summary>{currEstab, outSegs, retransSegs, inSegs, attemptFails, estabResets}</summary>
        public static long[] TcpStats()
        {
            try
            {
                if (GetTcpStatistics(out var s) == 0)
                    return new long[] { s.currEstab, s.outSegs, s.retransSegs, s.inSegs, s.attemptFails, s.estabResets };
            }
            catch { }
            return new long[6];
        }

        /// <summary>二层 ARP 是否可达（≈0 流量）。</summary>
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

        // ---------- 连接归属 ----------
        [StructLayout(LayoutKind.Sequential)]
        private struct MIB_TCPROW_OWNER_PID
        {
            public uint state, localAddr, localPort, remoteAddr, remotePort, owningPid;
        }

        private const int TCP_TABLE_OWNER_PID_ALL = 5;
        private const int MIB_TCP_STATE_ESTAB = 5;

        public sealed class TcpConn
        {
            public string RemoteIp;
            public int RemotePort;
            public int Pid;
        }

        public static List<TcpConn> EstablishedConnections()
        {
            var res = new List<TcpConn>();
            int size = 0;
            int rc = GetExtendedTcpTable(IntPtr.Zero, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
            if (rc != ERROR_INSUFFICIENT_BUFFER && rc != 0) return res;
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                if (GetExtendedTcpTable(buf, ref size, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) != 0) return res;
                int n = Marshal.ReadInt32(buf);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                for (int i = 0; i < n; i++)
                {
                    IntPtr p = new IntPtr(buf.ToInt64() + 4 + i * rowSize);
                    var r = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(p, typeof(MIB_TCPROW_OWNER_PID));
                    if (r.state != MIB_TCP_STATE_ESTAB) continue;
                    if (r.owningPid == 0) continue;
                    res.Add(new TcpConn
                    {
                        RemoteIp = new IPAddress(BitConverter.GetBytes(r.remoteAddr)).ToString(),
                        RemotePort = (int)(((r.remotePort & 0xFF) << 8) | ((r.remotePort >> 8) & 0xFF)),
                        Pid = (int)r.owningPid
                    });
                }
            }
            finally { Marshal.FreeHGlobal(buf); }
            return res;
        }

        // ---------- 每网卡错误计数 ----------
        // 注意：刻意用老的 GetIfEntry(MIB_IFROW)，不用 GetIfTable2(MIB_IF_ROW2)。
        // MIB_IF_ROW2 有 257 字符的 inline 字段，在托管侧极易算错大小
        // （实测 PowerShell 的 Add-Type 算出 1296，真实 1352），导致整个表读成垃圾。
        // MIB_IFROW 是纯值类型 + byte[]，大小稳定 856。
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct MIB_IFROW
        {
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public char[] wszName;
            public uint dwIndex, dwType, dwMtu, dwSpeed, dwPhysAddrLen;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)] public byte[] bPhysAddr;
            public uint dwAdminStatus, dwOperStatus, dwLastChange, dwInOctets, dwOutOctets,
                        dwInUcastPkts, dwInNucastPkts, dwOutUcastPkts, dwOutNucastPkts,
                        dwInErrors, dwInDiscards, dwInUnknownProtos, dwOutErrors, dwOutQLen, dwDescrLen;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 256)] public byte[] bDescr;
        }

        [DllImport("iphlpapi.dll")]
        private static extern int GetIfEntry(ref MIB_IFROW pIfRow);
        [DllImport("iphlpapi.dll")]
        private static extern int GetNumberOfInterfaces(out uint num);

        public sealed class IfErrorInfo
        {
            public uint InErrors, InDiscards, OutErrors, OutQLen, SpeedMbps;
        }

        public static Dictionary<int, IfErrorInfo> InterfaceErrors()
        {
            var map = new Dictionary<int, IfErrorInfo>();
            try
            {
                if (GetNumberOfInterfaces(out uint count) != 0) return map;
                for (uint i = 1; i <= count; i++)
                {
                    var row = new MIB_IFROW { dwIndex = i };
                    if (GetIfEntry(ref row) != 0) continue;
                    map[(int)row.dwIndex] = new IfErrorInfo
                    {
                        InErrors = row.dwInErrors,
                        InDiscards = row.dwInDiscards,
                        OutErrors = row.dwOutErrors,
                        OutQLen = row.dwOutQLen,
                        SpeedMbps = (uint)(row.dwSpeed / 1000000)
                    };
                }
            }
            catch { }
            return map;
        }
    }
}
