using System;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;

namespace NetPulse
{
    /// <summary>
    /// netsh wlan show interfaces 的解析。
    ///
    /// 编码坑（实测）：同一个命令在不同捕获方式下编码不同——
    ///   管道捕获      → GBK 字节
    ///   重定向到文件  → UTF-8 字节
    ///   切 chcp 65001 → 变成英文输出，中文字段直接消失
    /// 所以这里读原始字节后自动探测，而不是写死编码。
    /// </summary>
    internal static class WifiProbe
    {
        private static bool? _elevated;

        public static bool IsElevated
        {
            get
            {
                if (_elevated.HasValue) return _elevated.Value;
                try
                {
                    using (var id = WindowsIdentity.GetCurrent())
                    {
                        var p = new WindowsPrincipal(id);
                        _elevated = p.IsInRole(WindowsBuiltInRole.Administrator);
                    }
                }
                catch { _elevated = false; }
                return _elevated.Value;
            }
        }

        public static WifiInfo Read()
        {
            var info = new WifiInfo();
            if (!IsElevated)
            {
                info.Available = false;
                info.Reason = "需要管理员权限";
                return info;
            }

            byte[] bytes = null;
            string tmp = Path.Combine(Path.GetTempPath(), $"np-wlan-{Environment.ProcessId}.txt");
            try
            {
                var psi = new ProcessStartInfo
                {
                    FileName = Path.Combine(Environment.SystemDirectory, "netsh.exe"),
                    Arguments = "wlan show interfaces",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                using (var p = Process.Start(psi))
                {
                    string s = p.StandardOutput.ReadToEnd();
                    p.WaitForExit(4000);
                    bytes = Encoding.UTF8.GetBytes(s);
                }

                // 用进程重定向到文件的方式再取一次原始字节（更贴近真实编码）
                try
                {
                    var psi2 = new ProcessStartInfo
                    {
                        FileName = Path.Combine(Environment.SystemDirectory, "netsh.exe"),
                        Arguments = "wlan show interfaces",
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };
                    var p2 = Process.Start(psi2);
                    var ms = new MemoryStream();
                    p2.StandardOutput.BaseStream.CopyTo(ms);
                    p2.WaitForExit(4000);
                    var raw = ms.ToArray();
                    if (raw.Length > 0) bytes = raw;
                }
                catch { }
            }
            catch
            {
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = Path.Combine(Environment.SystemDirectory, "netsh.exe"),
                        Arguments = "wlan show interfaces",
                        RedirectStandardOutput = true,
                        UseShellExecute = false,
                        CreateNoWindow = true
                    };
                    var p = Process.Start(psi);
                    var ms = new MemoryStream();
                    p.StandardOutput.BaseStream.CopyTo(ms);
                    p.WaitForExit(4000);
                    bytes = ms.ToArray();
                }
                catch { }
            }
            finally
            {
                try { if (File.Exists(tmp)) File.Delete(tmp); } catch { }
            }

            if (bytes == null || bytes.Length == 0)
            {
                info.Available = false;
                info.Reason = "netsh 无输出";
                return info;
            }

            // 自动探测编码：哪套能解出「信号」就用哪套
            string text = null;
            foreach (var enc in new[] { Encoding.UTF8, Encoding.GetEncoding(936), Encoding.Default })
            {
                try
                {
                    string cand = enc.GetString(bytes);
                    if (Regex.IsMatch(cand, "信号|Signal|Rssi"))
                    {
                        text = cand;
                        break;
                    }
                }
                catch { }
            }
            if (text == null) text = Encoding.UTF8.GetString(bytes);

            if (!Regex.IsMatch(text, @"\S"))
            {
                info.Available = false;
                info.Reason = "netsh 无输出";
                return info;
            }

            if (!Regex.IsMatch(text, "SSID"))
            {
                info.Available = true;
                info.Connected = false;
                info.Reason = "未连接 WiFi";
                return info;
            }

            info.Available = true;
            info.Connected = true;

            info.Ssid = Grab(text, @"(?m)^\s*SSID\s*[:：]\s*(.+)$");
            info.Bssid = Grab(text, @"(?m)^\s*(?:AP BSSID|BSSID)\s*[:：]\s*([0-9a-fA-F:-]{17})");
            info.Band = Grab(text, @"(?m)^\s*(?:广播|Band|频段)\s*[:：]\s*(.+)$");
            info.Radio = Grab(text, @"(?m)^\s*(?:无线电类型|Radio type)\s*[:：]\s*(.+)$");

            var ms2 = Regex.Match(text, @"(?m)^\s*(?:信号|Signal)\s*[:：]\s*(\d+)\s*%");
            if (ms2.Success) info.SignalPct = int.Parse(ms2.Groups[1].Value);

            var mr = Regex.Match(text, @"(?m)^\s*Rssi\s*[:：]\s*(-?\d+)");
            if (mr.Success) info.Rssi = int.Parse(mr.Groups[1].Value);
            else if (info.SignalPct > 0) info.Rssi = (int)(-90 + info.SignalPct * 0.6);

            var mc = Regex.Match(text, @"(?m)^\s*(?:通道|信道|Channel)\s*[:：]\s*(\d+)");
            if (mc.Success) info.Channel = int.Parse(mc.Groups[1].Value);

            var mrx = Regex.Match(text, @"(?m)^\s*接收速率[^\r\n:]*[:：]\s*([\d.]+)");
            if (mrx.Success) info.RxMbps = double.Parse(mrx.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);

            var mtx = Regex.Match(text, @"(?m)^\s*传输速率[^\r\n:]*[:：]\s*([\d.]+)");
            if (mtx.Success) info.TxMbps = double.Parse(mtx.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);

            string bandName = "";
            if (info.Band.Contains("2.4")) bandName = "2.4G";
            else if (info.Band.Contains("5")) bandName = "5G";
            else if (info.Band.Contains("6")) bandName = "6G";
            else if (info.Channel >= 1 && info.Channel <= 14) bandName = "2.4G";
            else if (info.Channel >= 32 && info.Channel < 200) bandName = "5G";
            else if (info.Channel >= 200) bandName = "6G";
            info.Band = bandName;

            return info;
        }

        private static string Grab(string text, string pattern)
        {
            var m = Regex.Match(text, pattern);
            return m.Success ? m.Groups[1].Value.Trim() : "";
        }
    }
}
