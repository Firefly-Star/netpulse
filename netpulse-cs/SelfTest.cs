using System;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace NetPulse
{
    internal static class SelfTest
    {
        public static int Run()
        {
            var log = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "selftest-log.txt");
            void L(string m) { try { File.AppendAllText(log, $"{DateTime.Now:HH:mm:ss.fff} {m}\n"); } catch { } }
            try
            {
                L("SelfTest start");
                var win = new MainWindow(noTopMost: true, startExpanded: false);
                L("window ctor done");
                win.Show();
                Pump();
                L("window shown");

                var engine = new Engine();
                for (int i = 0; i < 8; i++)
                {
                    var s = engine.Capture();
                    win.ApplySample(s);
                    Pump();
                    System.Threading.Thread.Sleep(800);
                }
                L("samples done");

                win.ExpandForTest();
                Pump();

                var outDir = Path.Combine(Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "selftest");
                Directory.CreateDirectory(outDir);
                win.RenderToPng(Path.Combine(outDir, "wpf-expanded.png"));
                L($"saved {win.ActualWidth}x{win.ActualHeight}");

                engine.Dispose();
                win.Close();
                return 0;
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(Path.Combine(Path.GetDirectoryName(Environment.ProcessPath) ?? ".", "selftest-error.log"), ex.ToString()); } catch { }
                return 1;
            }
        }

        private static void Pump()
        {
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,
                new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);
        }
    }
}
