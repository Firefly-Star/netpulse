using System;
using System.IO;
using System.Windows;

namespace NetPulse
{
    public sealed class App : Application
    {
        [STAThread]
        public static void Main(string[] args)
        {
            var log = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "boot.log");
            void L(string m) { try { File.AppendAllText(log, $"{DateTime.Now:HH:mm:ss.fff} {m}\n"); } catch { } }
            try
            {
                L("Main start, args=" + string.Join(" ", args));

                bool noTopMost = Array.Exists(args, a => a.Equals("--no-topmost", StringComparison.OrdinalIgnoreCase));
                bool expanded  = Array.Exists(args, a => a.Equals("--expanded", StringComparison.OrdinalIgnoreCase));

                if (Array.Exists(args, a => a.Equals("--probe", StringComparison.OrdinalIgnoreCase)))
                {
                    L("probe mode");
                    Environment.Exit(ConsoleProbe.Run());
                }

                if (Array.Exists(args, a => a.Equals("--selftest", StringComparison.OrdinalIgnoreCase)))
                {
                    L("selftest mode");
                    int rc = SelfTest.Run();
                    L("selftest done rc=" + rc);
                    Environment.Exit(rc);
                }

                L("normal mode");
                var app = new App();
                L("app created");
                var win = new MainWindow(noTopMost, expanded);
                L("window created");
                app.Run(win);
                L("app exited");
            }
            catch (Exception ex)
            {
                L("FATAL: " + ex);
                throw;
            }
        }
    }
}