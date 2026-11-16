using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace NetPulse
{
    /// <summary>健康度配色：一个色相变量贯穿描边 / 光晕 / 折线 / 状态点。</summary>
    internal sealed class Palette
    {
        public string Border1, Border2, Border3, Glow1, Glow2, Text, Label;

        public static readonly Dictionary<string, Palette> All = new Dictionary<string, Palette>
        {
            ["healthy"]   = new Palette { Border1="#7AA2FF", Border2="#9678FF", Border3="#48DEB2", Glow1="#3B82F6", Glow2="#10B981", Text="#6EE7A8", Label="链路正常" },
            ["loaded"]    = new Palette { Border1="#FFC46B", Border2="#C79BFF", Border3="#FFD97A", Glow1="#F59E0B", Glow2="#EAB308", Text="#FCD34D", Label="有负载" },
            ["congested"] = new Palette { Border1="#FFA24B", Border2="#FF7B72", Border3="#FFCB6B", Glow1="#F97316", Glow2="#EF4444", Text="#FDBA74", Label="拥塞" },
            ["unstable"]  = new Palette { Border1="#FFC46B", Border2="#C79BFF", Border3="#FFD97A", Glow1="#F59E0B", Glow2="#EAB308", Text="#FCD34D", Label="不稳定" },
            ["lossy"]     = new Palette { Border1="#FF7B72", Border2="#B45AFF", Border3="#FFA03C", Glow1="#EF4444", Glow2="#B91C1C", Text="#FCA5A5", Label="丢包" },
            ["down"]      = new Palette { Border1="#FF4B4B", Border2="#B45AFF", Border3="#FF7B00", Glow1="#DC2626", Glow2="#991B1B", Text="#FF9D97", Label="断线" },
            ["unknown"]   = new Palette { Border1="#7A8AA0", Border2="#5A6A80", Border3="#8A9AB0", Glow1="#3B82F6", Glow2="#10B981", Text="#94A3B8", Label="启动中" }
        };

        public static Palette Get(string health) =>
            All.TryGetValue(health ?? "", out var p) ? p : All["unknown"];
    }

    public sealed class MainWindow : Window
    {
        private readonly Engine _engine = new Engine();
        private readonly DispatcherTimer _timer = new DispatcherTimer();
        private readonly DispatcherTimer _animTimer = new DispatcherTimer();

        private readonly List<double> _histDown = new List<double>();
        private readonly List<double> _histRtt = new List<double>();
        private const int HistLen = 120;

        private Sample _last;
        private bool _expanded;
        private bool _paused;
        private bool _flashOn;
        private readonly bool _noTopMost;

        // ---- 控件引用 ----
        private LinearGradientBrush _shellBrush;
        private Ellipse _glow1, _glow2, _stateRing, _stateDot;
        private TextBlock _stateText, _chevron, _brand;
        private TextBlock _downVal, _downUnit, _upVal, _upUnit;
        private Canvas _chart;
        private StackPanel _legend, _detail;
        private TextBlock _footRtt, _footJitter, _footLoss, _footIface;
        private Grid _probeRows, _qualityGrid, _ifRows, _wifiRows, _procRows;
        private WrapPanel _routePanel;
        private TextBlock _outageText;
        private Border _footBorder;
        private StackPanel _secWifi, _secProc;

        private readonly bool _selfTest;

        public MainWindow(bool noTopMost, bool startExpanded, bool selfTest = false)
        {
            _noTopMost = noTopMost;
            _expanded = startExpanded;
            _selfTest = selfTest;

            Title = "NetPulse";
            Width = 316;
            SizeToContent = SizeToContent.Height;
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            ResizeMode = ResizeMode.NoResize;
            ShowInTaskbar = false;
            Topmost = !noTopMost;
            UseLayoutRounding = true;
            SnapsToDevicePixels = true;
            TextOptions.SetTextFormattingMode(this, TextFormattingMode.Ideal);
            TextOptions.SetTextRenderingMode(this, TextRenderingMode.ClearType);
            FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI, Noto Sans SC, Microsoft YaHei");

            BuildUi();

            var wa = SystemParameters.WorkArea;
            Left = wa.Right - Width - 24;
            Top = wa.Bottom - 260 - 24;
            Loaded += (_, __) =>
            {
                var w = SystemParameters.WorkArea;
                Top = w.Bottom - ActualHeight - 24;
                if (_expanded) SetExpanded(true);
                if (_selfTest) RunSelfTest();
            };

            _timer.Interval = TimeSpan.FromSeconds(1);
            _timer.Tick += OnTick;
            _timer.Start();

            _animTimer.Interval = TimeSpan.FromMilliseconds(500);
            _animTimer.Tick += (_, __) =>
            {
                if (_last?.IsDown == true)
                {
                    _flashOn = !_flashOn;
                    _brand.Foreground = Brush(_flashOn ? "#FF7B72" : "#7D8A9C");
                }
                else if (_flashOn)
                {
                    _flashOn = false;
                    _brand.Foreground = Brush("#7D8A9C");
                }
            };
            _animTimer.Start();

            Closing += (_, __) =>
            {
                _timer.Stop();
                _animTimer.Stop();
                _engine.Dispose();
            };
        }

        // ======================= 构建界面 =======================

        private static SolidColorBrush Brush(string hex)
        {
            var c = (Color)ColorConverter.ConvertFromString(hex);
            var b = new SolidColorBrush(c);
            b.Freeze();
            return b;
        }

        private static TextBlock Cap(string text) => new TextBlock
        {
            Text = text,
            FontSize = 9,
            FontWeight = FontWeights.Bold,
            Foreground = Brush("#556072")
        };

        private static readonly FontFamily MonoFont = new FontFamily("Cascadia Mono, Consolas, Courier New");

        private void BuildUi()
        {
            // 外壳：渐变描边用 1.5px Padding 实现
            _shellBrush = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0),
                EndPoint = new Point(1, 1)
            };
            _shellBrush.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#7AA2FF"), 0));
            _shellBrush.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#9678FF"), 0.38));
            _shellBrush.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#48DEB2"), 1));

            var shell = new Border
            {
                CornerRadius = new CornerRadius(18),
                Padding = new Thickness(1.5),
                Background = _shellBrush
            };

            var inner = new Border { CornerRadius = new CornerRadius(16.5), ClipToBounds = true };
            var bg = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0.35, 1) };
            bg.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#191E28"), 0));
            bg.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#12151C"), 0.52));
            bg.GradientStops.Add(new GradientStop((Color)ColorConverter.ConvertFromString("#151A23"), 1));
            inner.Background = bg;

            var root = new Grid();
            inner.Child = root;

            // 光晕
            _glow1 = MakeGlow(200, HorizontalAlignment.Right, VerticalAlignment.Top, new Thickness(0, -110, -70, 0), "#3B82F6");
            _glow2 = MakeGlow(210, HorizontalAlignment.Left, VerticalAlignment.Bottom, new Thickness(-80, 0, 0, -130), "#10B981");
            root.Children.Add(_glow1);
            root.Children.Add(_glow2);

            var content = new Grid { Margin = new Thickness(17, 15, 17, 13) };
            for (int i = 0; i < 5; i++) content.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.Children.Add(content);

            // ---- 顶栏 ----
            var top = new Grid { Margin = new Thickness(0, 0, 0, 12), Background = Brushes.Transparent };
            _brand = new TextBlock
            {
                Text = "NETPULSE",
                FontSize = 10.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = Brush("#7D8A9C"),
                VerticalAlignment = VerticalAlignment.Center
            };
            top.Children.Add(_brand);

            var statePanel = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center
            };
            var ringGrid = new Grid { Width = 9, Height = 9, VerticalAlignment = VerticalAlignment.Center };
            _stateRing = new Ellipse { Stroke = Brush("#6EE7A8"), StrokeThickness = 1.5, Fill = Brushes.Transparent };
            _stateDot = new Ellipse { Width = 3.4, Height = 3.4, Fill = Brush("#6EE7A8"), HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            ringGrid.Children.Add(_stateRing);
            ringGrid.Children.Add(_stateDot);
            statePanel.Children.Add(ringGrid);

            _stateText = new TextBlock
            {
                Text = "启动中",
                FontSize = 10.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = Brush("#94A3B8"),
                Margin = new Thickness(7, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center
            };
            statePanel.Children.Add(_stateText);

            _chevron = new TextBlock
            {
                Text = "⌄",
                FontSize = 11,
                Foreground = Brush("#556072"),
                Margin = new Thickness(6, 0, 0, -4),
                VerticalAlignment = VerticalAlignment.Center
            };
            statePanel.Children.Add(_chevron);
            top.Children.Add(statePanel);
            Grid.SetRow(top, 0);
            content.Children.Add(top);

            // ---- 大数字 ----
            var nums = new StackPanel { Orientation = Orientation.Horizontal };
            nums.Children.Add(MakeNumBlock("DOWN", out _downVal, out _downUnit, "#F1F5F9", 22));
            nums.Children.Add(MakeNumBlock("UP", out _upVal, out _upUnit, "#93A2B5", 0));
            Grid.SetRow(nums, 1);
            content.Children.Add(nums);

            // ---- 图表 ----
            var chartHost = new Grid { Margin = new Thickness(-17, 12, -17, 0), Height = 56, ClipToBounds = true };
            _chart = new Canvas { Height = 56, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top, ClipToBounds = true };
            chartHost.Children.Add(_chart);
            Grid.SetRow(chartHost, 2);
            content.Children.Add(chartHost);

            // ---- 图例 ----
            _legend = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Margin = new Thickness(0, 2, 0, 0),
                Visibility = Visibility.Collapsed
            };
            _legend.Children.Add(new Rectangle { Width = 9, Height = 2, Fill = Brush("#34D399"), RadiusX = 1, RadiusY = 1, VerticalAlignment = VerticalAlignment.Center });
            _legend.Children.Add(new TextBlock { Text = "吞吐", FontSize = 9, Foreground = Brush("#4D5766"), Margin = new Thickness(4, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center });
            var dash = new Line { X1 = 0, Y1 = 0, X2 = 9, Y2 = 0, Stroke = Brush("#5AA9FF"), StrokeThickness = 1.2, StrokeDashArray = new DoubleCollection { 2, 1.6 }, VerticalAlignment = VerticalAlignment.Center };
            _legend.Children.Add(dash);
            _legend.Children.Add(new TextBlock { Text = "RTT", FontSize = 9, Foreground = Brush("#4D5766"), Margin = new Thickness(4, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
            Grid.SetRow(_legend, 3);
            content.Children.Add(_legend);

            // ---- 底部 ----
            var bottom = new StackPanel();
            _footBorder = new Border
            {
                BorderThickness = new Thickness(0, 1, 0, 0),
                BorderBrush = Brush("#14FFFFFF"),
                Margin = new Thickness(0, 12, 0, 0),
                Padding = new Thickness(0, 11, 0, 0)
            };
            var footGrid = new Grid();
            for (int i = 0; i < 4; i++) footGrid.ColumnDefinitions.Add(new ColumnDefinition());
            _footRtt = AddFootCell(footGrid, 0, "RTT", out _);
            _footJitter = AddFootCell(footGrid, 1, "抖动", out _);
            _footLoss = AddFootCell(footGrid, 2, "丢包", out _);
            _footIface = AddFootCell(footGrid, 3, "出口", out _, mono: false);
            _footBorder.Child = footGrid;
            bottom.Children.Add(_footBorder);

            _detail = new StackPanel { Visibility = Visibility.Collapsed };
            BuildDetail(_detail);
            bottom.Children.Add(_detail);

            Grid.SetRow(bottom, 4);
            content.Children.Add(bottom);

            shell.Child = inner;
            Content = shell;

            // ---- 交互 ----
            shell.MouseLeftButtonDown += (s, e) =>
            {
                if (e.ClickCount == 2) { SetExpanded(!_expanded); return; }
                try { DragMove(); } catch { }
            };

            var menu = new ContextMenu
            {
                Background = Brush("#1F2229"),
                BorderBrush = Brush("#343942"),
                Foreground = Brush("#E4E8EE")
            };
            var miExpand = MenuItem("展开详情");
            var miPause = MenuItem("暂停采样");
            var miTop = MenuItem("窗口置顶");
            miTop.IsChecked = !_noTopMost;
            var miQuit = MenuItem("退出");
            menu.Items.Add(miExpand);
            menu.Items.Add(miPause);
            menu.Items.Add(miTop);
            menu.Items.Add(new Separator());
            menu.Items.Add(miQuit);
            ContextMenu = menu;

            miExpand.Click += (_, __) => SetExpanded(!_expanded);
            miPause.Click += (_, __) =>
            {
                _paused = !_paused;
                miPause.IsChecked = _paused;
            };
            miTop.Click += (_, __) => Topmost = miTop.IsChecked;
            miQuit.Click += (_, __) => Close();
        }

        private static MenuItem MenuItem(string text) => new MenuItem
        {
            Header = text,
            Foreground = Brush("#E4E8EE"),
            FontSize = 12
        };

        private static Ellipse MakeGlow(double size, HorizontalAlignment ha, VerticalAlignment va, Thickness margin, string color)
        {
            var e = new Ellipse
            {
                Width = size,
                Height = size,
                HorizontalAlignment = ha,
                VerticalAlignment = va,
                Margin = margin,
                IsHitTestVisible = false
            };
            var rgb = (Color)ColorConverter.ConvertFromString(color);
            var brush = new RadialGradientBrush();
            brush.GradientStops.Add(new GradientStop(rgb, 0));
            brush.GradientStops.Add(new GradientStop(Color.FromArgb(0, rgb.R, rgb.G, rgb.B), 1));
            e.Fill = brush;
            e.Effect = new BlurEffect { Radius = 58 };
            return e;
        }

        private static StackPanel MakeNumBlock(string caption, out TextBlock val, out TextBlock unit, string color, double rightMargin)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 0, rightMargin, 0) };
            sp.Children.Add(new TextBlock
            {
                Text = caption,
                FontSize = 9,
                FontWeight = FontWeights.Bold,
                Foreground = Brush("#556072"),
                Margin = new Thickness(0, 0, 0, 4)
            });
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            val = new TextBlock { Text = "0", FontSize = 28, FontWeight = FontWeights.Light, Foreground = Brush(color) };
            unit = new TextBlock { Text = "B/s", FontSize = 10, Foreground = Brush("#5B6678"), VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(3, 0, 0, 3) };
            row.Children.Add(val);
            row.Children.Add(unit);
            sp.Children.Add(row);
            return sp;
        }

        private static TextBlock AddFootCell(Grid g, int col, string caption, out TextBlock unused, bool mono = true)
        {
            unused = null;
            var sp = new StackPanel();
            sp.Children.Add(Cap(caption));
            var v = new TextBlock
            {
                Text = "--",
                FontSize = 12.5,
                Foreground = Brush("#B8C4D4"),
                Margin = new Thickness(0, 2, 0, 0)
            };
            if (mono) v.FontFamily = MonoFont;
            sp.Children.Add(v);
            Grid.SetColumn(sp, col);
            g.Children.Add(sp);
            return v;
        }

        // ---------------- 展开区 ----------------

        private void BuildDetail(StackPanel host)
        {
            host.Children.Add(MakeSection("探针分层", 62, out _probeRows));
            host.Children.Add(MakeSection("链路质量", 62, out _qualityGrid));

            _qualityGrid.ColumnDefinitions.Add(new ColumnDefinition());
            _qualityGrid.ColumnDefinitions.Add(new ColumnDefinition());
            _qualityGrid.RowDefinitions.Add(new RowDefinition());
            _qualityGrid.RowDefinitions.Add(new RowDefinition());

            host.Children.Add(MakeSection("各网卡速率", 74, out _ifRows));

            var wifiSec = MakeSection("无线信号", 62, out _wifiRows);
            wifiSec.Visibility = Visibility.Collapsed;
            _secWifi = wifiSec;
            host.Children.Add(wifiSec);

            var routeSec = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
            routeSec.Children.Add(SectionHeader("出口判定", 62));
            _routePanel = new WrapPanel();
            routeSec.Children.Add(_routePanel);
            host.Children.Add(routeSec);

            var procSec = MakeSection("连接归属", 62, out _procRows);
            procSec.Visibility = Visibility.Collapsed;
            _secProc = procSec;
            host.Children.Add(procSec);

            var outageSec = new StackPanel { Margin = new Thickness(0, 12, 0, 2) };
            outageSec.Children.Add(SectionHeader("断线记录", 62));
            _outageText = new TextBlock { Text = "本次运行无断线", FontSize = 10.5, Foreground = Brush("#6EE7A8") };
            outageSec.Children.Add(_outageText);
            host.Children.Add(outageSec);
        }

        private static StackPanel MakeSection(string title, double lineMargin, out Grid body)
        {
            var sp = new StackPanel { Margin = new Thickness(0, 12, 0, 0) };
            sp.Children.Add(SectionHeader(title, lineMargin));
            body = new Grid();
            sp.Children.Add(body);
            return sp;
        }

        private static Grid SectionHeader(string title, double lineMargin)
        {
            var g = new Grid { Margin = new Thickness(0, 0, 0, 8) };
            g.Children.Add(new TextBlock
            {
                Text = title,
                FontSize = 9,
                FontWeight = FontWeights.Bold,
                Foreground = Brush("#556072"),
                VerticalAlignment = VerticalAlignment.Center
            });
            g.Children.Add(new Rectangle
            {
                Height = 1,
                Fill = Brush("#0FFFFFFF"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(lineMargin, 0, 0, 0)
            });
            return g;
        }

        // ======================= 渲染 =======================

        private void OnTick(object sender, EventArgs e)
        {
            if (_paused) return;
            try
            {
                _last = _engine.Capture();
                Render(_last);
                DrawChart(_last);
                if (_expanded) { SizeToContent = SizeToContent.Height; UpdateLayout(); }
            }
            catch
            {
                _stateText.Text = "采集异常";
                _stateText.Foreground = Brush("#FF7B72");
            }
        }

        private void Render(Sample s)
        {
            var pal = Palette.Get(s.Health);

            // 描边 / 光晕换色相
            _shellBrush.GradientStops[0].Color = (Color)ColorConverter.ConvertFromString(pal.Border1);
            _shellBrush.GradientStops[1].Color = (Color)ColorConverter.ConvertFromString(pal.Border2);
            _shellBrush.GradientStops[2].Color = (Color)ColorConverter.ConvertFromString(pal.Border3);
            if (_glow1.Fill is RadialGradientBrush b1)
                b1.GradientStops[0].Color = (Color)ColorConverter.ConvertFromString(pal.Glow1);
            if (_glow2.Fill is RadialGradientBrush b2)
                b2.GradientStops[0].Color = (Color)ColorConverter.ConvertFromString(pal.Glow2);

            var sc = Brush(pal.Text);
            _stateText.Text = pal.Label;
            _stateText.Foreground = sc;
            _stateRing.Stroke = sc;
            _stateDot.Fill = sc;

            var d = RatePair(s.PhysDown);
            _downVal.Text = d.Item1;
            _downUnit.Text = d.Item2;
            var u = RatePair(s.PhysUp);
            _upVal.Text = u.Item1;
            _upUnit.Text = u.Item2;

            _footRtt.Text = s.Stats.RttNow > 0 ? $"{s.Stats.RttNow:N0} ms" : "--";
            _footRtt.Foreground = Brush(s.IsDown ? "#FF9D97"
                : s.Stats.RttNow >= 200 ? "#FF7B72"
                : s.Stats.RttNow >= 100 ? "#FCD34D" : "#B8C4D4");

            _footJitter.Text = s.Stats.Jitter > 0 ? $"{s.Stats.Jitter:N1} ms" : "--";
            _footLoss.Text = $"{s.Stats.LossPct:N0}%";
            _footLoss.Foreground = Brush(s.Stats.LossPct >= 10 ? "#FF7B72"
                : s.Stats.LossPct >= 3 ? "#FCD34D" : "#B8C4D4");
            _footIface.Text = s.ActiveIface?.Name ?? "--";

            if (!_expanded) return;

            RenderProbes(s, pal);
            RenderQuality(s);
            RenderInterfaces(s, pal);
            RenderWifi(s, pal);
            RenderRoute(s);
            RenderProcs(s);
            RenderOutage(s, pal);
        }

        private void RenderProbes(Sample s, Palette pal)
        {
            _probeRows.Children.Clear();
            _probeRows.RowDefinitions.Clear();
            var cols = new[] { 0.0, 40, 54, 46, 40 };

            var hdr = new[] { ("目标", true), ("方式", true), ("RTT", true), ("状态", true), ("", true) };
            AddRow(_probeRows, cols, hdr.Select(x => (x.Item1, "#4D5766", true)).ToArray(), 0);

            int r = 1;
            foreach (var p in s.Probes)
            {
                string val, status, color;
                if (p.Pending) { val = "…"; status = "检测中"; color = "#556072"; }
                else if (p.Type == "ARP")
                {
                    if (p.Ok) { val = "可达"; status = "正常"; color = pal.Text; }
                    else { val = "无响应"; status = "失败"; color = "#FF7B72"; }
                }
                else if (p.Ok)
                {
                    val = $"{p.RttMs} ms";
                    if (p.RttMs >= 150) { status = "偏慢"; color = "#FCD34D"; }
                    else { status = "正常"; color = pal.Text; }
                }
                else { val = "超时"; status = "失败"; color = "#FF7B72"; }

                var cells = new (string, string, bool)[]
                {
                    (p.Name, p.Pending ? "#7E8B9D" : "#B3BFD0", false),
                    (p.Type, "#7E8B9D", false),
                    (val, color, false),
                    (status, color, false),
                    ("", "#00000000", false)
                };
                AddRow(_probeRows, cols, cells, r++);
            }
        }

        private void RenderQuality(Sample s)
        {
            _qualityGrid.Children.Clear();
            var cards = new[]
            {
                ("抖动", $"{s.Stats.Jitter:N1}", "ms", s.Stats.Jitter >= 60),
                ("丢包", $"{s.Stats.LossPct:N0}", "%", s.Stats.LossPct >= 10),
                ("TCP 重传", $"{s.Stats.Retrans:N2}", "%", s.Stats.Retrans >= 8),
                ("RTT 基线", $"{s.Stats.MinRtt:N0}", "ms", false)
            };

            for (int i = 0; i < 4; i++)
            {
                var c = cards[i];
                int col = i % 2, row = i / 2;
                var b = new Border
                {
                    Background = Brush("#07FFFFFF"),
                    BorderBrush = Brush("#0BFFFFFF"),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(7),
                    Padding = new Thickness(9, 7, 9, 7),
                    Margin = new Thickness(col == 0 ? 0 : 5, row == 0 ? 0 : 5, col == 0 ? 5 : 0, 0)
                };
                var sp = new StackPanel();
                sp.Children.Add(new TextBlock
                {
                    Text = c.Item1,
                    FontSize = 8,
                    FontWeight = FontWeights.Bold,
                    Foreground = Brush("#556072")
                });
                var vp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 0) };
                vp.Children.Add(new TextBlock
                {
                    Text = c.Item2,
                    FontFamily = MonoFont,
                    FontSize = 14,
                    Foreground = Brush(c.Item4 ? "#FF7B72" : "#DBE4EE")
                });
                vp.Children.Add(new TextBlock
                {
                    Text = " " + c.Item3,
                    FontSize = 9,
                    Foreground = Brush("#63707F"),
                    VerticalAlignment = VerticalAlignment.Bottom,
                    Margin = new Thickness(0, 0, 0, 2)
                });
                sp.Children.Add(vp);
                b.Child = sp;
                Grid.SetColumn(b, col);
                Grid.SetRow(b, row);
                _qualityGrid.Children.Add(b);
            }
        }

        private void RenderInterfaces(Sample s, Palette pal)
        {
            _ifRows.Children.Clear();
            _ifRows.RowDefinitions.Clear();
            var cols = new[] { 0.0, 40, 62, 62 };

            AddRow(_ifRows, cols, new[]
            {
                ("网卡", "#4D5766", true), ("类型", "#4D5766", true),
                ("下行", "#4D5766", true), ("上行", "#4D5766", true)
            }, 0);

            var cmap = new Dictionary<string, string>
            {
                ["wifi"] = "无线", ["ethernet"] = "有线", ["tunnel"] = "隧道",
                ["virtual"] = "虚拟", ["other"] = "其他"
            };

            var list = s.ThroughputRows
                .Where(x => x.Status == "Up" && (x.Category == "wifi" || x.Category == "ethernet" || x.Category == "tunnel"))
                .OrderBy(x => x.Category == "wifi" ? 0 : x.Category == "ethernet" ? 1 : 2)
                .ThenByDescending(x => x.DownBps)
                .Take(4).ToList();

            int r = 1;
            foreach (var i in list)
            {
                bool tun = i.Category == "tunnel";
                var dn = RatePair(i.DownBps);
                var up = RatePair(i.UpBps);
                AddRow(_ifRows, cols, new[]
                {
                    (i.Name, tun ? pal.Text : "#B3BFD0", false),
                    (cmap.TryGetValue(i.Category, out var c) ? c : "其他", "#7E8B9D", false),
                    ($"{dn.Item1} {dn.Item2}", tun ? "#7E8B9D" : pal.Text, false),
                    ($"{up.Item1} {up.Item2}", "#B3BFD0", false)
                }, r++);
            }
        }

        private void RenderWifi(Sample s, Palette pal)
        {
            var w = s.Wifi;
            if (w == null || !w.Available || !w.Connected || string.IsNullOrEmpty(w.Ssid))
            {
                _secWifi.Visibility = Visibility.Collapsed;
                return;
            }
            _secWifi.Visibility = Visibility.Visible;

            _wifiRows.Children.Clear();
            _wifiRows.RowDefinitions.Clear();
            var cols = new[] { 0.0, 74, 40, 58 };

            AddRow(_wifiRows, cols, new[]
            {
                ("SSID", "#4D5766", true), ("信号", "#4D5766", true),
                ("频段", "#4D5766", true), ("协商", "#4D5766", true)
            }, 0);

            string sig = w.SignalPct >= 70 ? pal.Text : w.SignalPct >= 40 ? "#FCD34D" : "#FF7B72";
            AddRow(_wifiRows, cols, new[]
            {
                (w.Ssid, "#B3BFD0", false),
                ($"{w.SignalPct}% {w.Rssi}dBm", sig, false),
                (w.Band, "#7E8B9D", false),
                ($"{(int)w.RxMbps}M", "#7E8B9D", false)
            }, 1);
        }

        private void RenderRoute(Sample s)
        {
            _routePanel.Children.Clear();
            var nodes = new[] { "本机", string.IsNullOrEmpty(s.Gateway) ? "--" : s.Gateway, s.ActiveIface?.Name ?? "--", "公网" };
            for (int i = 0; i < nodes.Length; i++)
            {
                if (i > 0)
                {
                    _routePanel.Children.Add(new TextBlock
                    {
                        Text = "→",
                        FontSize = 10,
                        Foreground = Brush("#3F4854"),
                        Margin = new Thickness(4, 0, 4, 0),
                        VerticalAlignment = VerticalAlignment.Center
                    });
                }
                var nb = new Border
                {
                    Background = Brush("#0DFFFFFF"),
                    BorderBrush = Brush("#0FFFFFFF"),
                    BorderThickness = new Thickness(1),
                    CornerRadius = new CornerRadius(6),
                    Padding = new Thickness(8, 3, 8, 3)
                };
                nb.Child = new TextBlock { Text = nodes[i], FontSize = 10, Foreground = Brush("#8FA0B5") };
                _routePanel.Children.Add(nb);
            }

            string mode = s.Proxy.RouteMode switch
            {
                "global" => "全局 · 全部走 TUN",
                "rule" => "规则 · 部分走 TUN",
                "tun-only" => "仅 TUN",
                "direct-out" => "代理在跑 · 目标直连",
                _ => "无代理 · 直连"
            };
            _routePanel.Children.Add(new TextBlock
            {
                Text = mode,
                FontSize = 10,
                Foreground = Brush("#4D5766"),
                Margin = new Thickness(4, 0, 0, 0),
                VerticalAlignment = VerticalAlignment.Center
            });
        }

        private void RenderProcs(Sample s)
        {
            var procs = s.Connections?.Take(3).ToList() ?? new List<ProcConn>();
            if (procs.Count == 0)
            {
                _secProc.Visibility = Visibility.Collapsed;
                return;
            }
            _secProc.Visibility = Visibility.Visible;

            _procRows.Children.Clear();
            _procRows.RowDefinitions.Clear();
            var cols = new[] { 0.0, 46, 96 };

            AddRow(_procRows, cols, new[]
            {
                ("进程", "#4D5766", true), ("连接", "#4D5766", true), ("主要远端", "#4D5766", true)
            }, 0);

            int r = 1;
            foreach (var p in procs)
            {
                string peer = p.Peers.Length > 0 ? p.Peers[0] : "-";
                AddRow(_procRows, cols, new[]
                {
                    (p.Name, "#B3BFD0", false),
                    (p.Count.ToString(), "#7E8B9D", false),
                    (peer, "#5C6674", false)
                }, r++);
            }
        }

        private void RenderOutage(Sample s, Palette pal)
        {
            if (s.OutageCount == 0)
            {
                _outageText.Text = "本次运行无断线";
                _outageText.Foreground = Brush(pal.Text);
            }
            else
            {
                _outageText.Text = s.LastOutageText;
                _outageText.Foreground = Brush(s.IsDown ? "#FF9D97" : "#FCD34D");
            }
        }

        private static void AddRow(Grid host, double[] cols, (string Text, string Color, bool Header)[] cells, int rowIndex)
        {
            // 每行建一个独立 Grid 并自带列定义。
            // 之前把 ColumnDefinitions 加在 host 上、数据行再塞进 host.Children，
            // 结果是每行的 Grid 自己没有列定义，所有 TextBlock 全堆在第 0 列 —— 文字重叠。
            var g = new Grid();
            for (int i = 0; i < cols.Length; i++)
            {
                // 约定：<=0 表示占据剩余空间，正数是固定像素
                g.ColumnDefinitions.Add(new ColumnDefinition
                {
                    Width = cols[i] <= 0
                        ? new GridLength(1, GridUnitType.Star)
                        : new GridLength(cols[i], GridUnitType.Pixel)
                });
            }

            for (int i = 0; i < cells.Length && i < cols.Length; i++)
            {
                var c = cells[i];
                var tb = new TextBlock
                {
                    Text = c.Text ?? "",
                    FontSize = c.Header ? 8.5 : 11,
                    FontWeight = c.Header ? FontWeights.Bold : FontWeights.Normal,
                    Foreground = Brush(c.Color ?? "#B3BFD0"),
                    TextAlignment = i == 0 ? TextAlignment.Left : TextAlignment.Right,
                    VerticalAlignment = VerticalAlignment.Center,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    Margin = new Thickness(i == 0 ? 0 : 6, 2.5, 0, 2.5)
                };
                if (!c.Header) tb.FontFamily = MonoFont;
                Grid.SetColumn(tb, i);
                g.Children.Add(tb);
            }

            while (host.RowDefinitions.Count <= rowIndex)
                host.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(g, rowIndex);
            host.Children.Add(g);
        }
        private void DrawChart(Sample s)
        {
            _histDown.Add(s.PhysDown * 8 / 1048576.0);
            _histRtt.Add(s.Stats.RttNow);
            while (_histDown.Count > HistLen) _histDown.RemoveAt(0);
            while (_histRtt.Count > HistLen) _histRtt.RemoveAt(0);

            _chart.Children.Clear();
            int n = _histDown.Count;
            if (n < 2) return;

            double w = _chart.ActualWidth > 10 ? _chart.ActualWidth : 316;
            double h = 56;

            // 上限取 P90：单次突发不该把其余样本压成平线
            var sorted = _histDown.OrderBy(x => x).ToArray();
            double p90 = sorted[Math.Min(sorted.Length - 1, (int)Math.Floor(sorted.Length * 0.9))];
            double downMax = Math.Max(0.5, p90);

            double rttMax = 50;
            foreach (var v in _histRtt) if (v > rttMax) rttMax = v;

            double step = w / (n - 1);
            string accent = Palette.Get(s.Health).Text;

            // 面积
            var areaGeo = new StreamGeometry();
            using (var ctx = areaGeo.Open())
            {
                ctx.BeginFigure(new Point(0, h), true, true);
                for (int i = 0; i < n; i++)
                {
                    double x = i * step;
                    double y = h - _histDown[i] / downMax * (h - 6);
                    ctx.LineTo(new Point(x, y), true, false);
                }
                ctx.LineTo(new Point((n - 1) * step, h), true, false);
                ctx.Close();
            }
            areaGeo.Freeze();

            var areaColor = (Color)ColorConverter.ConvertFromString(accent);
            var fill = new LinearGradientBrush
            {
                StartPoint = new Point(0, 0),
                EndPoint = new Point(0, 1)
            };
            fill.GradientStops.Add(new GradientStop(areaColor, 1));
            fill.GradientStops.Add(new GradientStop(Color.FromArgb(0, areaColor.R, areaColor.G, areaColor.B), 0));
            _chart.Children.Add(new Path { Data = areaGeo, Fill = fill, Opacity = 0.26 });

            // 折线
            var lineGeo = new StreamGeometry();
            using (var ctx = lineGeo.Open())
            {
                for (int i = 0; i < n; i++)
                {
                    double x = i * step;
                    double y = h - _histDown[i] / downMax * (h - 6);
                    if (i == 0) ctx.BeginFigure(new Point(x, y), false, false);
                    else ctx.LineTo(new Point(x, y), true, false);
                }
            }
            lineGeo.Freeze();
            _chart.Children.Add(new Path
            {
                Data = lineGeo,
                Stroke = Brush(accent),
                StrokeThickness = 1.5,
                StrokeLineJoin = PenLineJoin.Round
            });

            // RTT 虚线（展开态）
            if (_expanded)
            {
                var rttGeo = new StreamGeometry();
                bool any = false;
                using (var ctx = rttGeo.Open())
                {
                    for (int i = 0; i < n; i++)
                    {
                        double r = _histRtt[i];
                        if (r <= 0) continue;
                        double x = i * step;
                        double y = h - r / rttMax * (h - 6);
                        if (!any) { ctx.BeginFigure(new Point(x, y), false, false); any = true; }
                        else ctx.LineTo(new Point(x, y), true, false);
                    }
                }
                rttGeo.Freeze();
                _chart.Children.Add(new Path
                {
                    Data = rttGeo,
                    Stroke = Brush("#5AA9FF"),
                    StrokeThickness = 1.2,
                    StrokeDashArray = new DoubleCollection { 2, 1.6 },
                    Opacity = 0.78
                });
            }
        }

        private void SetExpanded(bool on)
        {
            _expanded = on;
            _detail.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            _legend.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            _chevron.Text = on ? "⌃" : "⌄";

            SizeToContent = SizeToContent.Height;
            UpdateLayout();

            if (_last != null) { Render(_last); DrawChart(_last); }
            UpdateLayout();

            var wa = SystemParameters.WorkArea;
            Top = wa.Bottom - ActualHeight - 24;
        }

        /// <summary>自检：跑若干轮真实采样后把窗口渲染成 PNG，用于无人值守验证。</summary>
        private void RunSelfTest()
        {
            _timer.Stop();
            Dispatcher.BeginInvoke(new Action(() =>
            {
                try
                {
                    for (int i = 0; i < 10; i++)
                    {
                        _last = _engine.Capture();
                        Render(_last);
                        DrawChart(_last);
                        DoEvents();
                        System.Threading.Thread.Sleep(900);
                    }
                    SetExpanded(true);
                    DoEvents();

                    var outDir = System.IO.Path.Combine(AppContext.BaseDirectory, "selftest");
                    System.IO.Directory.CreateDirectory(outDir);
                    System.IO.File.WriteAllText(System.IO.Path.Combine(outDir, "ok.txt"), "rendered");
                    SavePng(System.IO.Path.Combine(outDir, "wpf-expanded.png"));
                    Console.WriteLine($"saved wpf-expanded.png ({ActualWidth}x{ActualHeight})");

                    Close();
                }
                catch (Exception ex)
                {
                    try
                    {
                        var log = System.IO.Path.Combine(AppContext.BaseDirectory, "selftest-error.log");
                        System.IO.File.WriteAllText(log, ex.ToString());
                    }
                    catch { }
                    Close();
                }
            }), DispatcherPriority.ApplicationIdle);
        }

        private static void DoEvents()
        {
            var frame = new DispatcherFrame();
            Dispatcher.CurrentDispatcher.BeginInvoke(DispatcherPriority.Background,
                new Action(() => frame.Continue = false));
            Dispatcher.PushFrame(frame);
        }

        private void SavePng(string path)
        {
            UpdateLayout();
            int w = (int)Math.Ceiling(ActualWidth);
            int h = (int)Math.Ceiling(ActualHeight);
            var bmp = new System.Windows.Media.Imaging.RenderTargetBitmap(
                w, h, 96, 96, PixelFormats.Pbgra32);
            bmp.Render(this);
            var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
            enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(bmp));
            using (var fs = System.IO.File.Create(path)) enc.Save(fs);
        }

        // ---- 供自检使用 ----
        public void ApplySample(Sample s) { _last = s; Render(s); DrawChart(s); }
        public void ExpandForTest() { SetExpanded(true); }
        public void RenderToPng(string path) { SavePng(path); }

        private static (string, string) RatePair(double bps)
        {
            if (bps >= 1073741824) return ($"{bps / 1073741824:N2}", "GB/s");
            if (bps >= 1048576) return ($"{bps / 1048576:N2}", "MB/s");
            if (bps >= 1024) return ($"{bps / 1024:N0}", "KB/s");
            return ($"{bps:N0}", "B/s");
        }
    }
}
