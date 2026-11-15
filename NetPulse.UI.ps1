<#
    NetPulse WPF 界面
    ==================
    视觉规格来自 proto/ui-d-expanded.html：
      - 外壳 1.5px 渐变描边（LinearGradientBrush，健康度换色相）
      - 内部深色渐变底 + 两团径向光晕（RadialGradientBrush + BlurEffect）
      - 收起态 316x~200，展开态同宽向下生长
      - 大数字 28px FontWeight=Light，等宽表格数字
#>

[CmdletBinding()]
param(
    [switch]$NoTopMost,
    [switch]$Expanded,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

. (Join-Path $PSScriptRoot 'NetPulse.Core.ps1')
. (Join-Path $PSScriptRoot 'NetPulse.Elevated.ps1')

#region ---------- 调色板 ----------
# 健康度 -> 描边/光晕/折线主色。一个色相变量贯穿所有元素，不换主题只换色值。
$Palette = @{
    healthy   = @{ Border1='#7AA2FF'; Border2='#9678FF'; Border3='#48DEB2'
                   Glow1='#3B82F6'; Glow2='#10B981'; Text='#6EE7A8'; Label='链路正常' }
    loaded    = @{ Border1='#FFC46B'; Border2='#C79BFF'; Border3='#FFD97A'
                   Glow1='#F59E0B'; Glow2='#EAB308'; Text='#FCD34D'; Label='有负载' }
    congested = @{ Border1='#FFA24B'; Border2='#FF7B72'; Border3='#FFCB6B'
                   Glow1='#F97316'; Glow2='#EF4444'; Text='#FDBA74'; Label='拥塞' }
    unstable  = @{ Border1='#FFC46B'; Border2='#C79BFF'; Border3='#FFD97A'
                   Glow1='#F59E0B'; Glow2='#EAB308'; Text='#FCD34D'; Label='不稳定' }
    lossy     = @{ Border1='#FF7B72'; Border2='#B45AFF'; Border3='#FFA03C'
                   Glow1='#EF4444'; Glow2='#B91C1C'; Text='#FCA5A5'; Label='丢包' }
    down      = @{ Border1='#FF4B4B'; Border2='#B45AFF'; Border3='#FF7B00'
                   Glow1='#DC2626'; Glow2='#991B1B'; Text='#FF9D97'; Label='断线' }
    unknown   = @{ Border1='#7A8AA0'; Border2='#5A6A80'; Border3='#8A9AB0'
                   Glow1='#3B82F6'; Glow2='#10B981'; Text='#94A3B8'; Label='启动中' }
}

function Get-Palette([string]$health) {
    if ($Palette.ContainsKey($health)) { return $Palette[$health] }
    return $Palette['unknown']
}

$script:State = New-NetPulseState -ProbeIntervalMs 1000 -ProbeTimeoutMs 900
$script:Expanded = $Expanded.IsPresent
$script:Paused = $false
$script:LastSample = $null
$script:HistDown = New-Object System.Collections.Generic.List[double]
$script:HistRtt = New-Object System.Collections.Generic.List[double]
$script:HistLen = 120

# 提权数据刷新节奏慢（netsh / arp 都是重命令），5 秒一次足够
$script:ElevatedData = $null
$script:ElevatedAge = [datetime]::MinValue
$script:ElevatedIntervalSec = 5
#endregion

#region ---------- XAML ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="NetPulse" Width="316" Height="216"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ResizeMode="NoResize" ShowInTaskbar="False" Topmost="True"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Ideal"
        TextOptions.TextRenderingMode="ClearType"
        FontFamily="Segoe UI Variable Text, Segoe UI, Noto Sans SC, Microsoft YaHei">

  <Window.Resources>
    <FontFamily x:Key="MonoFont">Cascadia Mono, Consolas, Courier New</FontFamily>
    <Style x:Key="Cap" TargetType="TextBlock">
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#556072"/>
    </Style>
  </Window.Resources>

  <Border x:Name="Shell" CornerRadius="18" Padding="1.5">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop x:Name="ShellStop1" Color="#7AA2FF" Offset="0"/>
        <GradientStop x:Name="ShellStop2" Color="#9678FF" Offset="0.38"/>
        <GradientStop x:Name="ShellStop3" Color="#48DEB2" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>

    <Border CornerRadius="16.5" ClipToBounds="True">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="0.35,1">
          <GradientStop Color="#191E28" Offset="0"/>
          <GradientStop Color="#12151C" Offset="0.52"/>
          <GradientStop Color="#151A23" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>

      <Grid>
        <Ellipse x:Name="Glow1" Width="200" Height="200" HorizontalAlignment="Right"
                 VerticalAlignment="Top" Margin="0,-110,-70,0" IsHitTestVisible="False">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#3B82F6" Offset="0"/>
              <GradientStop Color="#003B82F6" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
          <Ellipse.Effect><BlurEffect Radius="58"/></Ellipse.Effect>
        </Ellipse>

        <Ellipse x:Name="Glow2" Width="210" Height="210" HorizontalAlignment="Left"
                 VerticalAlignment="Bottom" Margin="-80,0,0,-130" IsHitTestVisible="False">
          <Ellipse.Fill>
            <RadialGradientBrush>
              <GradientStop Color="#10B981" Offset="0"/>
              <GradientStop Color="#0010B981" Offset="1"/>
            </RadialGradientBrush>
          </Ellipse.Fill>
          <Ellipse.Effect><BlurEffect Radius="58"/></Ellipse.Effect>
        </Ellipse>

        <Grid Margin="17,15,17,13">
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
          </Grid.RowDefinitions>

          <Grid Grid.Row="0" Margin="0,0,0,12" Background="Transparent">
            <TextBlock x:Name="Brand" Text="NETPULSE" FontSize="10.5" FontWeight="SemiBold"
                       Foreground="#7D8A9C" VerticalAlignment="Center"/>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Grid Width="9" Height="9" VerticalAlignment="Center">
                <Ellipse x:Name="StateRing" Stroke="#6EE7A8" StrokeThickness="1.5" Fill="Transparent"/>
                <Ellipse x:Name="StateDot" Width="3.4" Height="3.4" Fill="#6EE7A8"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Grid>
              <TextBlock x:Name="StateText" Text="链路正常" FontSize="10.5" FontWeight="SemiBold"
                         Foreground="#6EE7A8" Margin="7,0,0,0" VerticalAlignment="Center"/>
              <TextBlock x:Name="Chevron" Text="⌄" FontSize="11" Foreground="#556072"
                         Margin="6,0,0,-4" VerticalAlignment="Center"/>
            </StackPanel>
          </Grid>

          <StackPanel Grid.Row="1" Orientation="Horizontal">
            <StackPanel Margin="0,0,22,0">
              <TextBlock Text="DOWN" Style="{StaticResource Cap}" Margin="0,0,0,4"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="DownVal" Text="0" FontSize="28" FontWeight="Light"
                           Foreground="#F1F5F9"/>
                <TextBlock x:Name="DownUnit" Text="B/s" FontSize="10" Foreground="#5B6678"
                           VerticalAlignment="Bottom" Margin="3,0,0,3"/>
              </StackPanel>
            </StackPanel>
            <StackPanel>
              <TextBlock Text="UP" Style="{StaticResource Cap}" Margin="0,0,0,4"/>
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="UpVal" Text="0" FontSize="28" FontWeight="Light"
                           Foreground="#93A2B5"/>
                <TextBlock x:Name="UpUnit" Text="B/s" FontSize="10" Foreground="#5B6678"
                           VerticalAlignment="Bottom" Margin="3,0,0,3"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>

          <Grid Grid.Row="2" Margin="-17,12,-17,0" Height="56" ClipToBounds="True">
            <Canvas x:Name="ChartCanvas" Height="56" HorizontalAlignment="Stretch" VerticalAlignment="Top" ClipToBounds="True"/>
          </Grid>

          <StackPanel x:Name="Legend" Grid.Row="3" Orientation="Horizontal"
                      HorizontalAlignment="Right" Margin="0,2,0,0" Visibility="Collapsed">
            <Rectangle Width="9" Height="2" Fill="#34D399" RadiusX="1" RadiusY="1" VerticalAlignment="Center"/>
            <TextBlock Text="吞吐" FontSize="9" Foreground="#4D5766" Margin="4,0,12,0" VerticalAlignment="Center"/>
            <Line X1="0" Y1="0" X2="9" Y2="0" Stroke="#5AA9FF" StrokeThickness="1.2"
                  StrokeDashArray="2 1.6" VerticalAlignment="Center"/>
            <TextBlock Text="RTT" FontSize="9" Foreground="#4D5766" Margin="4,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>

          <StackPanel Grid.Row="4">
            <Border x:Name="FootBorder" BorderThickness="0,1,0,0" BorderBrush="#14FFFFFF" Margin="0,12,0,0" Padding="0,11,0,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition/><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="RTT" Style="{StaticResource Cap}"/>
                  <TextBlock x:Name="FootRtt" Text="--" FontFamily="{StaticResource MonoFont}" FontSize="12.5" Foreground="#B8C4D4" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <TextBlock Text="抖动" Style="{StaticResource Cap}"/>
                  <TextBlock x:Name="FootJitter" Text="--" FontFamily="{StaticResource MonoFont}" FontSize="12.5" Foreground="#B8C4D4" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="丢包" Style="{StaticResource Cap}"/>
                  <TextBlock x:Name="FootLoss" Text="--" FontFamily="{StaticResource MonoFont}" FontSize="12.5" Foreground="#B8C4D4" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="3">
                  <TextBlock Text="出口" Style="{StaticResource Cap}"/>
                  <TextBlock x:Name="FootIface" Text="--" FontSize="12.5" Foreground="#B8C4D4" Margin="0,2,0,0"/>
                </StackPanel>
              </Grid>
            </Border>

            <StackPanel x:Name="DetailPanel" Visibility="Collapsed">
              <StackPanel x:Name="SecProbe" Margin="0,12,0,0">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="探针分层" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="62,0,0,0"/>
                </Grid>
                <Grid x:Name="ProbeRows"/>
              </StackPanel>

              <StackPanel x:Name="SecQuality" Margin="0,12,0,0">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="链路质量" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="62,0,0,0"/>
                </Grid>
                <Grid x:Name="QualityGrid">
                  <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
                  <Grid.RowDefinitions><RowDefinition/><RowDefinition/></Grid.RowDefinitions>
                </Grid>
              </StackPanel>

              <StackPanel x:Name="SecIf" Margin="0,12,0,0">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="各网卡速率" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="74,0,0,0"/>
                </Grid>
                <Grid x:Name="IfRows"/>
              </StackPanel>

              <StackPanel x:Name="SecWifi" Margin="0,12,0,0" Visibility="Collapsed">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="无线信号" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="62,0,0,0"/>
                </Grid>
                <Grid x:Name="WifiRows"/>
              </StackPanel>

              <StackPanel x:Name="SecRoute" Margin="0,12,0,0">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="出口判定" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="62,0,0,0"/>
                </Grid>
                <WrapPanel x:Name="RoutePanel"/>
              </StackPanel>

              <StackPanel x:Name="SecProc" Margin="0,12,0,0" Visibility="Collapsed">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="连接归属" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="62,0,0,0"/>
                </Grid>
                <Grid x:Name="ProcRows"/>
              </StackPanel>

              <StackPanel x:Name="SecOutage" Margin="0,12,0,2">
                <Grid Margin="0,0,0,8">
                  <TextBlock Text="断线记录" Style="{StaticResource Cap}" VerticalAlignment="Center"/>
                  <Rectangle Height="1" Fill="#0FFFFFFF" VerticalAlignment="Center" Margin="62,0,0,0"/>
                </Grid>
                <TextBlock x:Name="OutageText" FontSize="10.5" Foreground="#6EE7A8"/>
              </StackPanel>
            </StackPanel>
          </StackPanel>
        </Grid>
      </Grid>
    </Border>
  </Border>
</Window>
'@
#endregion

#region ---------- 载入 ----------
$reader = New-Object System.Xml.XmlNodeReader $xaml
$win = [System.Windows.Markup.XamlReader]::Load($reader)

$N = @{}
foreach ($node in $xaml.SelectNodes('//*[@*[local-name()="Name"]]')) {
    $N[$node.Name] = $win.FindName($node.Name)
}

$win.Topmost = (-not $NoTopMost)

$wa = [System.Windows.SystemParameters]::WorkArea
$win.Left = $wa.Right - $win.Width - 24
$win.Top = $wa.Bottom - $win.Height - 24
#endregion

#region ---------- 绘图工具 ----------
function New-Brush([string]$hex) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    $b = New-Object System.Windows.Media.SolidColorBrush($c)
    $b.Freeze()
    return $b
}

function Format-RatePair([double]$Bps) {
    if ($Bps -ge 1GB) { return @(('{0:N2}' -f ($Bps / 1GB)), 'GB/s') }
    if ($Bps -ge 1MB) { return @(('{0:N2}' -f ($Bps / 1MB)), 'MB/s') }
    if ($Bps -ge 1KB) { return @(('{0:N0}' -f ($Bps / 1KB)), 'KB/s') }
    return @(('{0:N0}' -f $Bps), 'B/s')
}

function Update-Chart {
    param($Sample, $Pal)

    $script:HistDown.Add([double]($Sample.Throughput.PhysDown * 8 / 1MB))
    $script:HistRtt.Add([double]$Sample.Stats.RttNow)
    while ($script:HistDown.Count -gt $script:HistLen) { $script:HistDown.RemoveAt(0) }
    while ($script:HistRtt.Count -gt $script:HistLen) { $script:HistRtt.RemoveAt(0) }

    $canvas = $N['ChartCanvas']
    $canvas.Children.Clear()

    $w = if ($canvas.ActualWidth -gt 10) { $canvas.ActualWidth } else { 316.0 }
    $h = 56.0
    $n = $script:HistDown.Count
    if ($n -lt 2) { return }

    # 上限取 P90 而非 max：单次突发不该把其余样本压成一条平线。
    $sortedD = @($script:HistDown | Sort-Object)
    $p90 = $sortedD[[int][math]::Min($sortedD.Count - 1, [math]::Floor($sortedD.Count * 0.9))]
    $downMax = [math]::Max(0.5, [double]$p90)
    $rttMax = 50.0
    foreach ($v in $script:HistRtt) { if ($v -gt $rttMax) { $rttMax = $v } }

    $step = if ($n -gt 1) { $w / ($n - 1) } else { $w }
    $accentHex = $Pal.Text

    $area = New-Object System.Windows.Shapes.Path
    $geo = New-Object System.Windows.Media.StreamGeometry
    $ctx = $geo.Open()
    $ctx.BeginFigure((New-Object System.Windows.Point(0, $h)), $true, $true)
    for ($i = 0; $i -lt $n; $i++) {
        $x = $i * $step
        $y = $h - ([double]$script:HistDown[$i] / $downMax) * ($h - 6)
        $ctx.LineTo((New-Object System.Windows.Point($x, $y)), $true, $false)
    }
    $ctx.LineTo((New-Object System.Windows.Point((($n - 1) * $step), $h)), $true, $false)
    $ctx.Close()
    $geo.Freeze()
    $area.Data = $geo
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = New-Object System.Windows.Point(0, 0)
    $lg.EndPoint = New-Object System.Windows.Point(0, 1)
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Brush $accentHex).Color, 1))) | Out-Null
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((New-Brush $accentHex).Color, 0))) | Out-Null
    $area.Fill = $lg
    $area.Opacity = 0.26
    $canvas.Children.Add($area) | Out-Null

    $line = New-Object System.Windows.Shapes.Path
    $lgeo = New-Object System.Windows.Media.StreamGeometry
    $lc = $lgeo.Open()
    for ($i = 0; $i -lt $n; $i++) {
        $x = $i * $step
        $y = $h - ([double]$script:HistDown[$i] / $downMax) * ($h - 6)
        if ($i -eq 0) { $lc.BeginFigure((New-Object System.Windows.Point($x, $y)), $false, $false) }
        else { $lc.LineTo((New-Object System.Windows.Point($x, $y)), $true, $false) }
    }
    $lgeo.Freeze()
    $line.Data = $lgeo
    $line.Stroke = New-Brush $accentHex
    $line.StrokeThickness = 1.5
    $line.StrokeLineJoin = 'Round'
    $canvas.Children.Add($line) | Out-Null

    if ($script:Expanded) {
        $rt = New-Object System.Windows.Shapes.Path
        $rgeo = New-Object System.Windows.Media.StreamGeometry
        $rc = $rgeo.Open()
        $any = $false
        for ($i = 0; $i -lt $n; $i++) {
            $r = [double]$script:HistRtt[$i]
            if ($r -le 0) { continue }
            $x = $i * $step
            $y = $h - ($r / $rttMax) * ($h - 6)
            if (-not $any) { $rc.BeginFigure((New-Object System.Windows.Point($x, $y)), $false, $false); $any = $true }
            else { $rc.LineTo((New-Object System.Windows.Point($x, $y)), $true, $false) }
        }
        $rgeo.Freeze()
        $rt.Data = $rgeo
        $rt.Stroke = New-Brush '#5AA9FF'
        $rt.StrokeThickness = 1.2
        $da = New-Object System.Windows.Media.DoubleCollection
        $da.Add(2) | Out-Null
        $da.Add(1.6) | Out-Null
        $rt.StrokeDashArray = $da
        $rt.Opacity = 0.78
        $canvas.Children.Add($rt) | Out-Null
    }
}

function New-RowGrid {
    param([double[]]$Columns, $Cells)
    $g = New-Object System.Windows.Controls.Grid
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        # 约定：列宽 <= 0 表示"占据剩余空间"，正数表示固定像素
        if ($Columns[$i] -le 0) { $cd.Width = [System.Windows.GridLength]::new(1, 'Star') }
        else { $cd.Width = [System.Windows.GridLength]::new($Columns[$i], 'Pixel') }
        $g.ColumnDefinitions.Add($cd) | Out-Null
    }
    for ($i = 0; $i -lt $Cells.Count; $i++) {
        $cell = $Cells[$i]
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = [string]$cell.Text
        $tb.FontSize = $(if ($cell.Header) { 8.5 } else { 11 })
        $tb.FontWeight = $(if ($cell.Header) { 'Bold' } else { 'Normal' })
        if (-not $cell.Header) { $tb.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas') }
        $col = '#4D5766'
        if (-not $cell.Header) {
            if ($cell.Color) { $col = $cell.Color } else { $col = '#B3BFD0' }
        }
        $tb.Foreground = New-Brush $col
        $tb.TextAlignment = $(if ($i -eq 0) { 'Left' } else { 'Right' })
        $tb.VerticalAlignment = 'Center'
        $tb.Margin = New-Object System.Windows.Thickness($(if ($i -eq 0) { 0 } else { 6 }), 2.5, 0, 2.5)
        [System.Windows.Controls.Grid]::SetColumn($tb, $i)
        $g.Children.Add($tb) | Out-Null
    }
    return $g
}
#endregion

#region ---------- 渲染 ----------
function Update-Ui {
    param($Sample)

    if ($null -eq $Sample) { return }
    $Pal = Get-Palette $Sample.Health

    $N['ShellStop1'].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Pal.Border1)
    $N['ShellStop2'].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Pal.Border2)
    $N['ShellStop3'].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Pal.Border3)
    $N['Glow1'].Fill.GradientStops[0].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Pal.Glow1)
    $N['Glow2'].Fill.GradientStops[0].Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Pal.Glow2)

    $stateColor = New-Brush $Pal.Text
    $N['StateText'].Text = $Pal.Label
    $N['StateText'].Foreground = $stateColor
    $N['StateRing'].Stroke = $stateColor
    $N['StateDot'].Fill = $stateColor

    $d = Format-RatePair $Sample.Throughput.PhysDown
    $N['DownVal'].Text = $d[0]
    $N['DownUnit'].Text = $d[1]
    $u = Format-RatePair $Sample.Throughput.PhysUp
    $N['UpVal'].Text = $u[0]
    $N['UpUnit'].Text = $u[1]

    $N['FootRtt'].Text = $(if ($Sample.Stats.RttNow -gt 0) { '{0:N0} ms' -f $Sample.Stats.RttNow } else { '--' })
    $N['FootJitter'].Text = $(if ($Sample.Stats.Jitter -gt 0) { '{0:N1} ms' -f $Sample.Stats.Jitter } else { '--' })
    $N['FootLoss'].Text = '{0:N0}%' -f $Sample.Stats.LossPct
    $N['FootIface'].Text = $(if ($Sample.ActiveIface) { $Sample.ActiveIface.Name } else { '--' })

    $rttColor = '#B8C4D4'
    if ($Sample.IsDown) { $rttColor = '#FF9D97' }
    elseif ($Sample.Stats.RttNow -ge 200) { $rttColor = '#FF7B72' }
    elseif ($Sample.Stats.RttNow -ge 100) { $rttColor = '#FCD34D' }
    $N['FootRtt'].Foreground = New-Brush $rttColor

    $lossColor = '#B8C4D4'
    if ($Sample.Stats.LossPct -ge 10) { $lossColor = '#FF7B72' }
    elseif ($Sample.Stats.LossPct -ge 3) { $lossColor = '#FCD34D' }
    $N['FootLoss'].Foreground = New-Brush $lossColor

    if (-not $script:Expanded) { return }

    $probePanel = $N['ProbeRows']
    $probePanel.Children.Clear()
    $probePanel.RowDefinitions.Clear()
    $cols = [double[]]@(0, 40, 54, 46, 40)
    $hdrCells = @(
        @{ Text='目标'; Header=$true }, @{ Text='方式'; Header=$true }, @{ Text='RTT'; Header=$true },
        @{ Text='状态'; Header=$true }, @{ Text=''; Header=$true })
    $hrow = New-RowGrid -Columns $cols -Cells $hdrCells
    $probePanel.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($hrow, 0)
    $probePanel.Children.Add($hrow) | Out-Null

    $ri = 1
    foreach ($p in $Sample.Probes) {
        $val = '…'
        $statusText = '检测中'
        $color = '#556072'
        if ($p.Pending) { }
        elseif ($p.Type -eq 'ARP') {
            if ($p.Ok) { $val = '可达'; $statusText = '正常'; $color = $Pal.Text }
            else { $val = '无响应'; $statusText = '失败'; $color = '#FF7B72' }
        }
        elseif ($p.Ok) {
            $val = "$($p.RttMs) ms"
            if ($p.RttMs -ge 150) { $statusText = '偏慢'; $color = '#FCD34D' }
            else { $statusText = '正常'; $color = $Pal.Text }
        }
        else { $val = '超时'; $statusText = '失败'; $color = '#FF7B72' }

        $cells = @(
            @{ Text=$p.Name; Color=$(if ($p.Pending) { '#7E8B9D' } else { '#B3BFD0' }) },
            @{ Text=$p.Type; Color='#7E8B9D' },
            @{ Text=$val; Color=$color },
            @{ Text=$statusText; Color=$color },
            @{ Text=''; Color='#00000000' })
        $rr = New-RowGrid -Columns $cols -Cells $cells
        $probePanel.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($rr, $ri)
        $probePanel.Children.Add($rr) | Out-Null
        $ri++
    }

    $qg = $N['QualityGrid']
    $qg.Children.Clear()
    $cards = @(
        @{ K='抖动'; V=('{0:N1}' -f $Sample.Stats.Jitter); U='ms'; Bad=($Sample.Stats.Jitter -ge 60) },
        @{ K='丢包'; V=('{0:N0}' -f $Sample.Stats.LossPct); U='%'; Bad=($Sample.Stats.LossPct -ge 10) },
        @{ K='TCP 重传'; V=('{0:N2}' -f $Sample.Stats.Retrans); U='%'; Bad=($Sample.Stats.Retrans -ge 8) },
        @{ K='RTT 基线'; V=('{0:N0}' -f $Sample.Stats.MinRtt); U='ms'; Bad=$false })
    for ($i = 0; $i -lt 4; $i++) {
        $c = $cards[$i]
        $col = $i % 2
        $row = [math]::Floor($i / 2)
        $b = New-Object System.Windows.Controls.Border
        $b.Background = New-Brush '#07FFFFFF'
        $b.BorderBrush = New-Brush '#0BFFFFFF'
        $b.BorderThickness = New-Object System.Windows.Thickness(1)
        $b.CornerRadius = New-Object System.Windows.CornerRadius(7)
        $b.Padding = New-Object System.Windows.Thickness(9, 7, 9, 7)
        $lm = if ($col -eq 0) { 0 } else { 5 }
        $rm = if ($col -eq 0) { 5 } else { 0 }
        $tm = if ($row -eq 0) { 0 } else { 5 }
        $b.Margin = New-Object System.Windows.Thickness($lm, $tm, $rm, 0)
        $sp = New-Object System.Windows.Controls.StackPanel
        $k = New-Object System.Windows.Controls.TextBlock
        $k.Text = $c.K; $k.FontSize = 8; $k.FontWeight = 'Bold'
        $k.Foreground = New-Brush '#556072'
        $v = New-Object System.Windows.Controls.TextBlock
        $v.FontFamily = New-Object System.Windows.Media.FontFamily('Cascadia Mono, Consolas')
        $v.FontSize = 14
        $v.Margin = New-Object System.Windows.Thickness(0, 2, 0, 0)
        $v.Foreground = New-Brush $(if ($c.Bad) { '#FF7B72' } else { '#DBE4EE' })
        $v.Text = $c.V
        $sp.Children.Add($k) | Out-Null
        $sp.Children.Add($v) | Out-Null
        $b.Child = $sp
        [System.Windows.Controls.Grid]::SetColumn($b, $col)
        [System.Windows.Controls.Grid]::SetRow($b, $row)
        $qg.Children.Add($b) | Out-Null
    }

    $ifp = $N['IfRows']
    $ifp.Children.Clear()
    $ifp.RowDefinitions.Clear()
    $icols = [double[]]@(0, 40, 62, 62)
    $ihdr = @(@{Text='网卡';Header=$true},@{Text='类型';Header=$true},@{Text='下行';Header=$true},@{Text='上行';Header=$true})
    $ih = New-RowGrid -Columns $icols -Cells $ihdr
    $ifp.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
    [System.Windows.Controls.Grid]::SetRow($ih, 0)
    $ifp.Children.Add($ih) | Out-Null

    $cmap = @{ wifi='无线'; ethernet='有线'; tunnel='隧道'; virtual='虚拟'; other='其他' }
    $list = @($Sample.Throughput.Interfaces | Where-Object {
        $_.Status -eq 'Up' -and $_.Category -in 'wifi','ethernet','tunnel' } |
        Sort-Object @{ Expression={ if ($_.Category -eq 'wifi') {0} elseif ($_.Category -eq 'ethernet') {1} else {2} } },
                    @{ Expression='DownBps'; Descending=$true } | Select-Object -First 4)
    $ir = 1
    foreach ($i in $list) {
        $isTun = ($i.Category -eq 'tunnel')
        $dn = Format-RatePair $i.DownBps
        $up = Format-RatePair $i.UpBps
        $cells = @(
            @{ Text=$i.Name; Color=$(if ($isTun) { $Pal.Text } else { '#B3BFD0' }) },
            @{ Text=$cmap[$i.Category]; Color='#7E8B9D' },
            @{ Text=($dn[0] + ' ' + $dn[1]); Color=$(if ($isTun) { '#7E8B9D' } else { $Pal.Text }) },
            @{ Text=($up[0] + ' ' + $up[1]); Color='#B3BFD0' })
        $rr = New-RowGrid -Columns $icols -Cells $cells
        $ifp.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($rr, $ir)
        $ifp.Children.Add($rr) | Out-Null
        $ir++
    }

    $rp = $N['RoutePanel']
    $rp.Children.Clear()
    $gw = if ($Sample.Gateway) { $Sample.Gateway } else { '--' }
    $ifaceName = if ($Sample.ActiveIface) { $Sample.ActiveIface.Name } else { '--' }
    $nodes = @('本机', $gw, $ifaceName, '公网')
    for ($i = 0; $i -lt $nodes.Count; $i++) {
        if ($i -gt 0) {
            $ar = New-Object System.Windows.Controls.TextBlock
            $ar.Text = '→'; $ar.FontSize = 10
            $ar.Foreground = New-Brush '#3F4854'
            $ar.Margin = New-Object System.Windows.Thickness(4, 0, 4, 0)
            $ar.VerticalAlignment = 'Center'
            $rp.Children.Add($ar) | Out-Null
        }
        $nb = New-Object System.Windows.Controls.Border
        $nb.Background = New-Brush '#0DFFFFFF'
        $nb.BorderBrush = New-Brush '#0FFFFFFF'
        $nb.BorderThickness = New-Object System.Windows.Thickness(1)
        $nb.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $nb.Padding = New-Object System.Windows.Thickness(8, 3, 8, 3)
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $nodes[$i]
        $tb.FontSize = 10
        $tb.Foreground = New-Brush '#8FA0B5'
        $nb.Child = $tb
        $rp.Children.Add($nb) | Out-Null
    }
    $tunTxt = New-Object System.Windows.Controls.TextBlock
    $modeText = switch ($Sample.Proxy.RouteMode) {
        'global'     { '全局 · 全部走 TUN' }
        'rule'       { '规则 · 部分走 TUN' }
        'tun-only'   { '仅 TUN' }
        'direct-out' { '代理在跑 · 目标直连' }
        default      { '无代理 · 直连' }
    }
    $tunTxt.Text = $modeText
    $tunTxt.Foreground = New-Brush '#4D5766'
    $tunTxt.FontSize = 10
    $tunTxt.Margin = New-Object System.Windows.Thickness(4, 0, 0, 0)
    $tunTxt.VerticalAlignment = 'Center'
    $rp.Children.Add($tunTxt) | Out-Null

    if ($Sample.OutageCount -eq 0) {
        $N['OutageText'].Text = '本次运行无断线'
        $N['OutageText'].Foreground = New-Brush $Pal.Text
    } else {
        $last = @($Sample.Outages | Select-Object -Last 1)[0]
        $dur = if ($last.End) { '{0:N1}s' -f $last.Seconds } else { '进行中' }
        $N['OutageText'].Text = "累计 {0} 次 · 最近 {1:HH:mm:ss} 断 {2}" -f $Sample.OutageCount, $last.Start, $dur
        $N['OutageText'].Foreground = New-Brush $(if ($Sample.IsDown) { '#FF9D97' } else { '#FCD34D' })
    }

    Update-ElevatedSections -Sample $Sample -Pal $Pal
}

function Update-ElevatedSections {
    param($Sample, $Pal)

    $wifiSec = $N['SecWifi']
    $connSec = $N['SecProc']

    if ($null -eq $script:ElevatedData) {
        $wifiSec.Visibility = 'Collapsed'
        $connSec.Visibility = 'Collapsed'
        return
    }
    $e = $script:ElevatedData

    if ($e.Wifi.Available -and $e.Wifi.Ssid) {
        $wifiSec.Visibility = 'Visible'
        $wp = $N['WifiRows']
        $wp.Children.Clear()
        $wp.RowDefinitions.Clear()
        $wcols = [double[]]@(0, 74, 40, 58)
        $whdr = @(@{Text='SSID';Header=$true},@{Text='信号';Header=$true},@{Text='频段';Header=$true},@{Text='协商';Header=$true})
        $wh = New-RowGrid -Columns $wcols -Cells $whdr
        $wp.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($wh, 0)
        $wp.Children.Add($wh) | Out-Null

        if ($e.Wifi.SignalPct -lt 70) { $sigColor = '#FCD34D' }
        if ($e.Wifi.SignalPct -lt 40) { $sigColor = '#FF7B72' }
        $wrow = @(
            @{ Text=$e.Wifi.Ssid; Color='#B3BFD0' },
            @{ Text=('{0}% {1}dBm' -f $e.Wifi.SignalPct, $e.Wifi.Rssi); Color=$sigColor },
            @{ Text=$e.Wifi.Band; Color='#7E8B9D' },
            @{ Text=('{0}M' -f [int]$e.Wifi.RxMbps); Color='#7E8B9D' })
        $wr = New-RowGrid -Columns $wcols -Cells $wrow
        $wp.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($wr, 1)
        $wp.Children.Add($wr) | Out-Null
    } else {
        $wifiSec.Visibility = 'Collapsed'
    }

    $procs = @($e.Connections.Processes | Select-Object -First 3)
    if ($e.Connections.Available -and $procs.Count -gt 0) {
        $connSec.Visibility = 'Visible'
        $cp = $N['ProcRows']
        $cp.Children.Clear()
        $cp.RowDefinitions.Clear()
        $ccols = [double[]]@(0, 46, 96)
        $chdr = @(@{Text='进程';Header=$true},@{Text='连接';Header=$true},@{Text='主要远端';Header=$true})
        $ch = New-RowGrid -Columns $ccols -Cells $chdr
        $cp.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
        [System.Windows.Controls.Grid]::SetRow($ch, 0)
        $cp.Children.Add($ch) | Out-Null
        $ci = 1
        foreach ($pr in $procs) {
            $peer = '-'
            if ($pr.Peers.Count -gt 0) { $peer = ($pr.Peers[0] -split ':')[0] }
            $cells = @(
                @{ Text=$pr.Name; Color='#B3BFD0' },
                @{ Text=[string]$pr.Count; Color='#7E8B9D' },
                @{ Text=$peer; Color='#5C6674' })
            $rr = New-RowGrid -Columns $ccols -Cells $cells
            $cp.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition)) | Out-Null
            [System.Windows.Controls.Grid]::SetRow($rr, $ci)
            $cp.Children.Add($rr) | Out-Null
            $ci++
        }
    } else {
        $connSec.Visibility = 'Collapsed'
    }
}
#endregion

#region ---------- 展开/收起 ----------
function Set-ExpandedState {
    param([bool]$On)

    $script:Expanded = $On
    $N['DetailPanel'].Visibility = $(if ($On) { 'Visible' } else { 'Collapsed' })
    $N['Legend'].Visibility = $(if ($On) { 'Visible' } else { 'Collapsed' })
    $N['Chevron'].Text = $(if ($On) { '⌃' } else { '⌄' })

    $win.SizeToContent = 'Height'
    $win.UpdateLayout()

    if ($script:LastSample) {
        Update-Ui -Sample $script:LastSample
        Update-Chart -Sample $script:LastSample -Pal (Get-Palette $script:LastSample.Health)
    }
    $win.UpdateLayout()

    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Top = $wa.Bottom - $win.ActualHeight - 24
}
#endregion

#region ---------- 交互 ----------
$N['Shell'].Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) {
        Set-ExpandedState (-not $script:Expanded)
    } else {
        try { $win.DragMove() } catch { }
    }
})

$menu = New-Object System.Windows.Controls.ContextMenu
$menu.Background = New-Brush '#1F2229'
$menu.BorderBrush = New-Brush '#343942'
$menu.Foreground = New-Brush '#E4E8EE'

function New-MenuItem([string]$text) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $text
    $mi.Foreground = New-Brush '#E4E8EE'
    $mi.FontSize = 12
    return $mi
}

$miExpand = New-MenuItem '展开详情'
$miPause  = New-MenuItem '暂停采样'
$miTop    = New-MenuItem '窗口置顶'
$miTop.IsChecked = (-not $NoTopMost)
$miQuit   = New-MenuItem '退出'
$null = $menu.Items.Add($miExpand)
$null = $menu.Items.Add($miPause)
$null = $menu.Items.Add($miTop)
$null = $menu.Items.Add((New-Object System.Windows.Controls.Separator))
$null = $menu.Items.Add($miQuit)
$win.ContextMenu = $menu

$miExpand.Add_Click({ Set-ExpandedState (-not $script:Expanded) })
$miPause.Add_Click({
    $script:Paused = -not $script:Paused
    $miPause.IsChecked = $script:Paused
})
$miTop.Add_Click({ $win.Topmost = $miTop.IsChecked })
$miQuit.Add_Click({ $win.Close() })
#endregion

#region ---------- 主循环 ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(1)
$timer.Add_Tick({
    if ($script:Paused) { return }
    try {
        $s = Update-NetPulse -State $script:State
        $script:LastSample = $s

        $ageSec = ((Get-Date) - $script:ElevatedAge).TotalSeconds
        if ($ageSec -ge $script:ElevatedIntervalSec) {
            $script:ElevatedAge = Get-Date
            $script:ElevatedData = [pscustomobject]@{
                Wifi        = Get-NetPulseWifi
                Arp         = Get-NetPulseArp
                Connections = Get-NetPulseConnections
                IfErrors    = Get-NetPulseIfErrors
                Elevated    = Test-NetPulseElevated
            }
        }

        Update-Ui -Sample $s
        Update-Chart -Sample $s -Pal (Get-Palette $s.Health)

        if ($script:Expanded) {
            $win.SizeToContent = 'Height'
            $win.UpdateLayout()
        }
    } catch {
        $N['StateText'].Text = '采集异常'
        $N['StateText'].Foreground = New-Brush '#FF7B72'
    }
})
#endregion

#region ---------- 启动 ----------
$win.Add_Loaded({
    if ($script:Expanded) { Set-ExpandedState $true }
    $timer.Start()
})

if ($SelfTest) {
    $win.Show()
    for ($i = 0; $i -lt 10; $i++) {
        $s = Update-NetPulse -State $script:State
        $script:LastSample = $s
        $script:ElevatedData = [pscustomobject]@{
            Wifi        = Get-NetPulseWifi
            Arp         = Get-NetPulseArp
            Connections = Get-NetPulseConnections
            IfErrors    = Get-NetPulseIfErrors
            Elevated    = Test-NetPulseElevated
        }
        Update-Ui -Sample $s
        Update-Chart -Sample $s -Pal (Get-Palette $s.Health)
        $win.UpdateLayout()
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
        Start-Sleep -Milliseconds 900
    }
    if ($Expanded) {
        $script:Expanded = $true
        $N['DetailPanel'].Visibility = 'Visible'
        $N['Legend'].Visibility = 'Visible'
        $N['Chevron'].Text = '⌃'
        $win.SizeToContent = 'Height'
        $win.UpdateLayout()
        Update-Ui -Sample $script:LastSample
        $win.UpdateLayout()
    }

    # 收起态按内容撑高（自检截图前先量真实高度）
    $win.SizeToContent = 'Height'
    $win.UpdateLayout()

    $outDir = Join-Path $PSScriptRoot 'selftest'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    function Save-Window($w, $name) {
        $w.UpdateLayout()
        $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(
            [int][math]::Ceiling($w.ActualWidth), [int][math]::Ceiling($w.ActualHeight),
            96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bmp.Render($w)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
        $fs = [System.IO.File]::Create((Join-Path $outDir $name))
        $enc.Save($fs)
        $fs.Close()
        "saved $name  ($([int]$w.ActualWidth)x$([int]$w.ActualHeight))"
    }

    Save-Window $win 'wpf-expanded.png'
    "--- 读数 ---"
    "Down   = $($N['DownVal'].Text) $($N['DownUnit'].Text)"
    "Up     = $($N['UpVal'].Text) $($N['UpUnit'].Text)"
    "State  = $($N['StateText'].Text)"
    "RTT    = $($N['FootRtt'].Text)"
    "Loss   = $($N['FootLoss'].Text)"
    "Window = $([int]$win.ActualWidth) x $([int]$win.ActualHeight)"
    $win.Close()
    return
}

$null = $win.ShowDialog()
#endregion
