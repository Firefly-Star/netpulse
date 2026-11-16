using System;
using System.Linq;
using System.Text;

namespace NetPulse
{
    /// <summary>控制台自检：不建窗口，纯采集，验证引擎。</summary>
    internal static class ConsoleProbe
    {
        public static int Run()
        {
            Console.OutputEncoding = Encoding.UTF8;
            using (var e = new Engine())
            {
                for (int i = 0; i < 6; i++)
                {
                    var s = e.Capture();
                    string probes = string.Join(" ", s.Probes.Select(p =>
                        p.Pending ? $"{p.Key}=.." : p.Ok ? $"{p.Key}={p.RttMs}ms" : $"{p.Key}=X"));
                    Console.WriteLine($"{s.At:HH:mm:ss} dn={s.PhysDown/1024:N1}KB/s up={s.PhysUp/1024:N1}KB/s | {probes} | {s.Health} rtt={s.Stats.RttNow} loss={s.Stats.LossPct}%");
                    System.Threading.Thread.Sleep(1000);
                }
                var last = e.Capture();
                Console.WriteLine("--- 详情 ---");
                Console.WriteLine($"接口数={last.Interfaces.Length} 探针数={last.Probes.Count}");
                Console.WriteLine($"网关={last.Gateway} 出口={last.ActiveIface?.Name} 代理模式={last.Proxy.Mode} 路由={last.Proxy.RouteMode}");
                Console.WriteLine($"提权={last.Elevated} WiFi可用={last.Wifi.Available} SSID={last.Wifi.Ssid}");
                Console.WriteLine($"可看到 {last.Connections.Count} 个进程的连接");
            }
            return 0;
        }
    }
}
