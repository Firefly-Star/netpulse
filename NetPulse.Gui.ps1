<#
    NetPulse 悬浮窗  (WinForms，免管理员)
    =====================================
      * 置顶小窗：实时速率 / 延迟 / 抖动 / 丢包 / 健康色块
      * 双击展开详细面板：逐层探针、每网卡速率、代理与出口判定、断线历史
      * 断线时窗框变红并闪烁，同时记事件（可导出 CSV）
      * 右键菜单：暂停 / 置顶 / 透明度 / 导出记录 / 打开日志目录

    启动：双击 NetPulse.cmd，或 powershell -NoProfile -ExecutionPolicy Bypass -File .\NetPulse.Gui.ps1
#>

[CmdletBinding()]
param(
    [switch]$NoTopMost,
    [ValidateSet('normal', 'compact')][string]$Layout = 'normal',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Windows.Forms.DataVisualization

$root = $PSScriptRoot
$core = Join-Path $root 'NetPulse.Core.ps1'
. $core

#region ---------- 主题 ----------
$C = @{
    Bg      = [System.Drawing.Color]::FromArgb(22, 24, 29)
    Panel   = [System.Drawing.Color]::FromArgb(31, 34, 41)
    Line    = [System.Drawing.Color]::FromArgb(52, 57, 66)
    Text    = [System.Drawing.Color]::FromArgb(228, 232, 238)
    Dim     = [System.Drawing.Color]::FromArgb(140, 148, 160)
    Accent  = [System.Drawing.Color]::FromArgb(88, 166, 255)
    Good    = [System.Drawing.Color]::FromArgb(63, 185, 80)
    Warn    = [System.Drawing.Color]::FromArgb(210, 153, 34)
    Bad     = [System.Drawing.Color]::FromArgb(248, 81, 73)
    Crit    = [System.Drawing.Color]::FromArgb(255, 45, 45)
    Grid    = [System.Drawing.Color]::FromArgb(44, 49, 58)
}
$F = @{
    Big   = New-Object System.Drawing.Font('Segoe UI', 17, [System.Drawing.FontStyle]::Bold)
    Mid   = New-Object System.Drawing.Font('Segoe UI', 10.5, [System.Drawing.FontStyle]::Bold)
    Norm  = New-Object System.Drawing.Font('Segoe UI', 9)
    Small = New-Object System.Drawing.Font('Segoe UI', 8)
    Mono  = New-Object System.Drawing.Font('Consolas', 9)
    MonoSm= New-Object System.Drawing.Font('Consolas', 8)
}
$HealthStyle = @{
    healthy   = @{ Text='正常';   Color=$C.Good }
    loaded    = @{ Text='有负载'; Color=$C.Warn }
    congested = @{ Text='拥塞';   Color=[System.Drawing.Color]::FromArgb(255,120,60) }
    unstable  = @{ Text='不稳定'; Color=$C.Warn }
    lossy     = @{ Text='丢包';   Color=$C.Bad }
    down      = @{ Text='断线';   Color=$C.Crit }
    unknown   = @{ Text='启动中'; Color=$C.Dim }
}
#endregion

$script:State = New-NetPulseState -ProbeIntervalMs 1000 -ProbeTimeoutMs 900
$script:Paused = $false
$script:HistDown = New-Object System.Collections.ArrayList
$script:HistUp = New-Object System.Collections.ArrayList
$script:HistRtt = New-Object System.Collections.ArrayList
$script:HistLen = 120
$script:SamplesLog = New-Object System.Collections.ArrayList
$script:LastSample = $null
$script:FlashOn = $false

#region ---------- 主窗体 ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'NetPulse'
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.BackColor = $C.Bg
$form.TopMost = (-not $NoTopMost)
$form.ShowInTaskbar = $false
$form.Width = 300
$form.MinimumSize = New-Object System.Drawing.Size(280, 120)
$form.AutoScaleMode = 'None'

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Location = New-Object System.Drawing.Point(($screen.Right - $form.Width - 24), ($screen.Top + 24))

# 断线时闪的边框
$form.Add_Paint({
    param($s, $e)
    if ($script:FlashOn) {
        $pen = New-Object System.Drawing.Pen($C.Crit, 3)
        $e.Graphics.DrawRectangle($pen, 1, 1, $s.Width - 3, $s.Height - 3)
        $pen.Dispose()
    }
})
#endregion

#region ---------- 顶部：拖动条 + 按钮 ----------
function New-Label {
    param($text, $font, $color, $x, $y, $w, $h, $anchor = 'None', $align = 'MiddleLeft')
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Font = $font
    $l.ForeColor = $color
    $l.BackColor = [System.Drawing.Color]::Transparent
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.TextAlign = $align
    $l.AutoSize = $false
    Write-Output -NoEnumerate $l
}

$bar = New-Object System.Windows.Forms.Panel
$bar.Location = New-Object System.Drawing.Point(0, 0)
$bar.Size = New-Object System.Drawing.Size($form.Width, 26)
$bar.BackColor = $C.Panel
$bar.Anchor = 'Top,Left,Right'
$form.Controls.Add($bar)

$lblTitle = New-Label 'NetPulse' $F.Small $C.Dim 8 0 90 26
$bar.Controls.Add($lblTitle)

$lblMode = New-Label '' $F.Small $C.Accent 96 0 110 26
$bar.Controls.Add($lblMode)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '×'
$btnClose.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$btnClose.ForeColor = $C.Dim
$btnClose.BackColor = $C.Panel
$btnClose.FlatStyle = 'Flat'
$btnClose.FlatAppearance.BorderSize = 0
$btnClose.Size = New-Object System.Drawing.Size(26, 24)
$btnClose.Anchor = 'Top,Right'
$btnClose.Cursor = 'Hand'
$bar.Controls.Add($btnClose)
$btnClose.Add_Click({ $form.Close() })

$btnMin = New-Object System.Windows.Forms.Button
$btnMin.Text = '–'
$btnMin.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$btnMin.ForeColor = $C.Dim
$btnMin.BackColor = $C.Panel
$btnMin.FlatStyle = 'Flat'
$btnMin.FlatAppearance.BorderSize = 0
$btnMin.Size = New-Object System.Drawing.Size(26, 24)
$btnMin.Anchor = 'Top,Right'
$btnMin.Cursor = 'Hand'
$bar.Controls.Add($btnMin)

$bar.Add_Resize({ $btnClose.Left = $bar.Width - 28; $btnMin.Left = $bar.Width - 54 })

# 拖动
$dragOffset = $null
$startDrag = {
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:dragOffset = $e.Location }
}
$doDrag = {
    param($s, $e)
    if ($script:dragOffset) {
        $form.Left = [System.Windows.Forms.Cursor]::Position.X - $script:dragOffset.X
        $form.Top = [System.Windows.Forms.Cursor]::Position.Y - $script:dragOffset.Y
    }
}
$endDrag = { $script:dragOffset = $null }
foreach ($ctl in @($bar, $lblTitle, $lblMode)) {
    $ctl.Add_MouseDown($startDrag)
    $ctl.Add_MouseMove($doDrag)
    $ctl.Add_MouseUp($endDrag)
}
#endregion

#region ---------- 主读数区 ----------
$lblDown = New-Label '↓ 0 B/s' $F.Big $C.Text 10 30 170 34
$form.Controls.Add($lblDown)

$lblUp = New-Label '↑ 0 B/s' $F.Big $C.Dim 10 62 170 30
$form.Controls.Add($lblUp)

$lblHealth = New-Object System.Windows.Forms.Label
$lblHealth.Text = '启动中'
$lblHealth.Font = $F.Mid
$lblHealth.ForeColor = [System.Drawing.Color]::White
$lblHealth.BackColor = $C.Dim
$lblHealth.TextAlign = 'MiddleCenter'
$lblHealth.Size = New-Object System.Drawing.Size(88, 40)
$lblHealth.Location = New-Object System.Drawing.Point(190, 36)
$lblHealth.Anchor = 'Top,Right'
$form.Controls.Add($lblHealth)

$lblRtt = New-Label 'RTT    --' $F.Mono $C.Text 10 94 140 18
$form.Controls.Add($lblRtt)
$lblJit = New-Label '抖动   --' $F.Mono $C.Dim 10 112 140 18
$lblJit.ForeColor = $C.Dim
$form.Controls.Add($lblJit)
$lblLoss = New-Label '丢包   --' $F.Mono $C.Dim 10 130 140 18
$lblLoss.ForeColor = $C.Dim
$form.Controls.Add($lblLoss)

$lblWhy = New-Label '' $F.Small $C.Warn 152 94 138 54
$lblWhy.Anchor = 'Top,Right'
$form.Controls.Add($lblWhy)
#endregion

#region ---------- 迷你折线图（延迟 + 吞吐） ----------
$chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$chart.Location = New-Object System.Drawing.Point(8, 152)
$chart.Size = New-Object System.Drawing.Size(284, 62)
$chart.Anchor = 'Top,Left,Right'
$chart.BackColor = $C.Bg
$chart.AntiAliasing = 'All'
$form.Controls.Add($chart)

$ca = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$ca.BackColor = $C.Bg
$ca.AxisX.Enabled = 'False'
$ca.AxisY.Enabled = 'False'
$ca.AxisX.Minimum = 0
$ca.AxisX.Maximum = $script:HistLen
$ca.AxisY.Minimum = 0
$ca.AxisY.Maximum = 100
$ca.Position.Auto = $false
$ca.Position.X = 0; $ca.Position.Y = 0; $ca.Position.Width = 100; $ca.Position.Height = 100
$chart.ChartAreas.Add($ca)

$sRtt = New-Object System.Windows.Forms.DataVisualization.Charting.Series 'rtt'
$sRtt.ChartType = 'Spline'
$sRtt.BorderWidth = 2
$sRtt.Color = $C.Accent
$sRtt.IsVisibleInLegend = $false
$sRtt.XValueType = 'Int32'
$chart.Series.Add($sRtt)

$sDown = New-Object System.Windows.Forms.DataVisualization.Charting.Series 'down'
$sDown.ChartType = 'Area'
$sDown.BorderWidth = 1
$sDown.Color = [System.Drawing.Color]::FromArgb(70, 63, 185, 80)
$sDown.IsVisibleInLegend = $false
$sDown.XValueType = 'Int32'
$chart.Series.Add($sDown)
#endregion

#region ---------- 详情面板 ----------
$panelDetail = New-Object System.Windows.Forms.Panel
$panelDetail.Location = New-Object System.Drawing.Point(0, 220)
$panelDetail.Size = New-Object System.Drawing.Size($form.Width, 392)
$panelDetail.BackColor = $C.Bg
$panelDetail.Anchor = 'Top,Left,Right,Bottom'
$panelDetail.Visible = $false
$form.Controls.Add($panelDetail)

function New-SectionLabel($text, $y) {
    $l = New-Label $text $F.Small $C.Dim 10 $y 280 16
    $l.Anchor = 'Top,Left,Right'
    return $l
}

$panelDetail.Controls.Add((New-SectionLabel '各网卡实时速率' 4))

$gridIf = New-Object System.Windows.Forms.DataGridView
$gridIf.Location = New-Object System.Drawing.Point(10, 22)
$gridIf.Size = New-Object System.Drawing.Size(280, 96)
$gridIf.Anchor = 'Top,Left,Right'
$gridIf.BackgroundColor = $C.Bg
$gridIf.GridColor = $C.Grid
$gridIf.BorderStyle = 'None'
$gridIf.AllowUserToAddRows = $false
$gridIf.AllowUserToResizeRows = $false
$gridIf.RowHeadersVisible = $false
$gridIf.ReadOnly = $true
$gridIf.EnableHeadersVisualStyles = $false
$gridIf.ColumnHeadersDefaultCellStyle.BackColor = $C.Panel
$gridIf.ColumnHeadersDefaultCellStyle.ForeColor = $C.Dim
$gridIf.ColumnHeadersDefaultCellStyle.Font = $F.Small
$gridIf.ColumnHeadersHeightSizeMode = 'DisableResizing'
$gridIf.ColumnHeadersHeight = 20
$gridIf.DefaultCellStyle.BackColor = $C.Bg
$gridIf.DefaultCellStyle.ForeColor = $C.Text
$gridIf.DefaultCellStyle.Font = $F.MonoSm
$gridIf.DefaultCellStyle.SelectionBackColor = $C.Panel
$gridIf.DefaultCellStyle.SelectionForeColor = $C.Text
$gridIf.DefaultCellStyle.Padding = New-Object System.Windows.Forms.Padding(2, 0, 0, 0)
$gridIf.RowTemplate.Height = 18
$gridIf.ScrollBars = 'Vertical'
$null = $gridIf.Columns.Add('n', '网卡');  $gridIf.Columns['n'].Width = 118
$null = $gridIf.Columns.Add('c', '类型');  $gridIf.Columns['c'].Width = 48
$null = $gridIf.Columns.Add('d', '↓');     $gridIf.Columns['d'].Width = 56
$null = $gridIf.Columns.Add('u', '↑');     $gridIf.Columns['u'].Width = 56
$panelDetail.Controls.Add($gridIf)

$panelDetail.Controls.Add((New-SectionLabel '探针（分层定位断在哪一段）' 124))

$gridProbe = New-Object System.Windows.Forms.DataGridView
$gridProbe.Location = New-Object System.Drawing.Point(10, 142)
$gridProbe.Size = New-Object System.Drawing.Size(280, 88)
$gridProbe.Anchor = 'Top,Left,Right'
$gridProbe.BackgroundColor = $C.Bg
$gridProbe.GridColor = $C.Grid
$gridProbe.BorderStyle = 'None'
$gridProbe.AllowUserToAddRows = $false
$gridProbe.AllowUserToResizeRows = $false
$gridProbe.RowHeadersVisible = $false
$gridProbe.ReadOnly = $true
$gridProbe.EnableHeadersVisualStyles = $false
$gridProbe.ColumnHeadersDefaultCellStyle.BackColor = $C.Panel
$gridProbe.ColumnHeadersDefaultCellStyle.ForeColor = $C.Dim
$gridProbe.ColumnHeadersDefaultCellStyle.Font = $F.Small
$gridProbe.ColumnHeadersHeightSizeMode = 'DisableResizing'
$gridProbe.ColumnHeadersHeight = 20
$gridProbe.DefaultCellStyle.BackColor = $C.Bg
$gridProbe.DefaultCellStyle.ForeColor = $C.Text
$gridProbe.DefaultCellStyle.Font = $F.MonoSm
$gridProbe.DefaultCellStyle.SelectionBackColor = $C.Panel
$gridProbe.DefaultCellStyle.SelectionForeColor = $C.Text
$gridProbe.RowTemplate.Height = 18
$gridProbe.ScrollBars = 'Vertical'
$null = $gridProbe.Columns.Add('p', '探针'); $gridProbe.Columns['p'].Width = 74
$null = $gridProbe.Columns.Add('t', '方式'); $gridProbe.Columns['t'].Width = 40
$null = $gridProbe.Columns.Add('v', 'IP');   $gridProbe.Columns['v'].Width = 104
$null = $gridProbe.Columns.Add('r', 'RTT');  $gridProbe.Columns['r'].Width = 58
$panelDetail.Controls.Add($gridProbe)

$panelDetail.Controls.Add((New-SectionLabel '代理 / 出口' 238))
$lblProxy = New-Label '' $F.MonoSm $C.Text 10 254 282 58
$lblProxy.Anchor = 'Top,Left,Right'
$panelDetail.Controls.Add($lblProxy)

$panelDetail.Controls.Add((New-SectionLabel '断线记录' 316))
$lblOutage = New-Label '' $F.MonoSm $C.Text 10 332 282 26
$lblOutage.Anchor = 'Top,Left,Right'
$panelDetail.Controls.Add($lblOutage)
#endregion

#region ---------- 右键菜单 ----------
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.BackColor = $C.Panel
$menu.ForeColor = $C.Text
$menu.Renderer = New-Object System.Windows.Forms.ToolStripProfessionalRenderer

$miDetail = $menu.Items.Add('显示详细信息')
$miDetail.CheckOnClick = $false
$miPause = $menu.Items.Add('暂停采样')
$miPause.CheckOnClick = $true
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miTop = $menu.Items.Add('窗口置顶')
$miTop.CheckOnClick = $true
$miTop.Checked = (-not $NoTopMost)
$miCompact = $menu.Items.Add('精简模式')
$miCompact.CheckOnClick = $true
$miCompact.Checked = ($Layout -eq 'compact')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miExport = $menu.Items.Add('导出本次记录 CSV…')
$miCopy = $menu.Items.Add('复制当前状态')
$miReset = $menu.Items.Add('重置统计')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miQuit = $menu.Items.Add('退出')

$menu.Tag = $null
foreach ($x in @($lblDown, $lblUp, $lblHealth, $lblRtt, $lblJit, $lblLoss, $lblWhy, $chart, $bar, $lblTitle, $lblMode)) {
    $x.ContextMenuStrip = $menu
}
$gridIf.ContextMenuStrip = $menu
$gridProbe.ContextMenuStrip = $menu
#endregion

#region ---------- 更新与渲染 ----------
function Update-Chart {
    param($Sample)

    if ($null -eq $Sample) { return }

    $script:HistRtt.Add([double]$Sample.Stats.RttNow) | Out-Null
    $script:HistDown.Add([double]($Sample.Throughput.PhysDown * 8 / 1MB)) | Out-Null   # Mbps
    while ($script:HistRtt.Count -gt $script:HistLen) { $script:HistRtt.RemoveAt(0) }
    while ($script:HistDown.Count -gt $script:HistLen) { $script:HistDown.RemoveAt(0) }

    $sRtt.Points.Clear()
    $sDown.Points.Clear()

    $downMax = 1.0
    foreach ($v in $script:HistDown) { if ($v -gt $downMax) { $downMax = $v } }
    $rttVals = @($script:HistRtt | Where-Object { $_ -gt 0 })
    $rttMax = 50.0
    if ($rttVals.Count -gt 0) { $rttMax = ($rttVals | Measure-Object -Maximum).Maximum }
    if ($rttMax -lt 50) { $rttMax = 50 }

    for ($i = 0; $i -lt $script:HistRtt.Count; $i++) {
        $x = $script:HistLen - $script:HistRtt.Count + $i
        $r = [double]$script:HistRtt[$i]
        if ($r -gt 0) {
            [void]$sRtt.Points.AddXY($x, ($r / $rttMax) * 100)
        }
        [void]$sDown.Points.AddXY($x, ([double]$script:HistDown[$i] / $downMax) * 100)
    }
    $ca.AxisY.Maximum = 100
    $ca.AxisY.Minimum = 0
    $sRtt.Color = if ($Sample.IsDown) { $C.Crit } else { $C.Accent }
}

function Format-RateShort([double]$Bps) {
    if ($Bps -ge 1MB) { return ('{0:N2} MB/s' -f ($Bps / 1MB)) }
    if ($Bps -ge 1KB) { return ('{0:N0} KB/s' -f ($Bps / 1KB)) }
    return ('{0:N0} B/s' -f $Bps)
}

function Get-ProxyText($s) {
    $pm = @{
        'direct'='直连'; 'system-proxy'='系统代理'; 'pac'='PAC 脚本'; 'local-port'='本地代理端口'
    }
    $parts = @()
    $parts += $pm[$s.Proxy.Mode]
    if ($s.Proxy.Effective) { $parts += $s.Proxy.Effective }
    if ($s.Proxy.Listening.Count -gt 0) { $parts += ('端口 ' + ($s.Proxy.Listening -join ',')) }
    if ($s.Proxy.HasTunnel) {
        $parts += ("全局/TUN({0})" -f $s.Proxy.TunIfDesc)
    } else {
        $parts += '未走 TUN'
    }
    return ($parts -join ' · ')
}

function Update-Ui {
    param($Sample)

    if ($null -eq $Sample) { return }

    # ---- 速率 ----
    $lblDown.Text = '↓ ' + (Format-RateShort $Sample.Throughput.PhysDown)
    $lblUp.Text = '↑ ' + (Format-RateShort $Sample.Throughput.PhysUp)

    # ---- 健康色块 ----
    $st = $HealthStyle[$Sample.Health]
    if (-not $st) { $st = $HealthStyle['unknown'] }
    $lblHealth.Text = $st.Text
    $lblHealth.BackColor = $st.Color

    # ---- 细项 ----
    $rttText = if ($Sample.Stats.RttNow -gt 0) { '{0:N0} ms' -f $Sample.Stats.RttNow } else { '--' }
    $lblRtt.Text = "RTT   $rttText"
    $lblRtt.ForeColor = if ($Sample.IsDown) { $C.Crit }
        elseif ($Sample.Stats.RttNow -ge 200) { $C.Bad }
        elseif ($Sample.Stats.RttNow -ge 100) { $C.Warn }
        else { $C.Text }

    $lblJit.Text = '抖动  ' + $(if ($Sample.Stats.Jitter -gt 0) { '{0:N0} ms' -f $Sample.Stats.Jitter } else { '--' })
    $lblJit.ForeColor = if ($Sample.Stats.Jitter -ge 60) { $C.Warn } else { $C.Dim }

    $lblLoss.Text = '丢包  ' + ('{0:N0}%' -f $Sample.Stats.LossPct) + '   重传 ' + ('{0:N1}%' -f $Sample.Stats.Retrans)
    $lblLoss.ForeColor = if ($Sample.Stats.LossPct -ge 10 -or $Sample.Stats.Retrans -ge 10) { $C.Warn } else { $C.Dim }

    $lblWhy.Text = ($Sample.HealthReasons -join "`r`n")
    $lblWhy.ForeColor = if ($Sample.Health -in 'down', 'lossy') { $C.Bad } else { $C.Warn }

    # ---- 顶栏模式 ----
    $modeText = @()
    if ($Sample.Proxy.HasTunnel) { $modeText += 'TUN' }
    elseif ($Sample.Proxy.Mode -ne 'direct') { $modeText += '代理' }
    else { $modeText += '直连' }
    if ($Sample.ActiveIface) { $modeText += $Sample.ActiveIface.Name }
    $lblMode.Text = ($modeText -join ' · ')

    # ---- 断线闪烁 ----
    if ($Sample.IsDown) {
        $bar.BackColor = if ($script:FlashOn) { $C.Crit } else { $C.Panel }
        $lblTitle.ForeColor = [System.Drawing.Color]::White
    } else {
        $bar.BackColor = $C.Panel
        $lblTitle.ForeColor = $C.Dim
    }

    if (-not $panelDetail.Visible) { return }

    # ---- 网卡表 ----
    $gridIf.SuspendLayout()
    $gridIf.Rows.Clear()
    $ifs = @($Sample.Throughput.Interfaces |
        Where-Object { $_.Status -eq 'Up' -and $_.Category -in 'wifi', 'ethernet', 'tunnel' } |
        Sort-Object -Property @{ Expression = { if ($_.Category -eq 'wifi') { 0 } elseif ($_.Category -eq 'ethernet') { 1 } else { 2 } } }, @{ Expression = 'DownBps'; Descending = $true })
    $cmap = @{ wifi='无线'; ethernet='有线'; tunnel='隧道'; virtual='虚拟'; other='其他' }
    foreach ($i in $ifs) {
        $idx = $gridIf.Rows.Add($i.Name, $cmap[$i.Category], (Format-RateShort $i.DownBps), (Format-RateShort $i.UpBps))
        if ($i.Category -eq 'tunnel') { $gridIf.Rows[$idx].DefaultCellStyle.ForeColor = $C.Accent }
    }
    $gridIf.ResumeLayout()

    # ---- 探针表 ----
    $gridProbe.SuspendLayout()
    $gridProbe.Rows.Clear()
    foreach ($p in $Sample.Probes) {
        $val = if ($p.Pending) { '…' } elseif ($p.Type -eq 'ARP') { if ($p.Ok) { '可达' } else { '无响应' } }
               elseif ($p.Ok) { "$($p.RttMs) ms" } else { '超时' }
        $idx = $gridProbe.Rows.Add($p.Name, $p.Type, $p.Ip, $val)
        $row = $gridProbe.Rows[$idx]
        if ($p.Pending) { $row.DefaultCellStyle.ForeColor = $C.Dim }
        elseif (-not $p.Ok) { $row.DefaultCellStyle.ForeColor = $C.Bad }
        elseif ($p.RttMs -ge 150) { $row.DefaultCellStyle.ForeColor = $C.Warn }
        else { $row.DefaultCellStyle.ForeColor = $C.Good }
    }
    $gridProbe.ResumeLayout()

    # ---- 代理 / 出口 ----
    $routeLines = @()
    if ($Sample.RouteDetail.Count -gt 0) {
        $via = @($Sample.RouteDetail | ForEach-Object {
            if ($_.ViaTunnel) { "$($_.Key)→$($_.IfName)[TUN]" } else { "$($_.Key)→$($_.IfName)" }
        }) -join '  '
        $routeLines += '出口  ' + $via
    }
    $gw = if ($Sample.Gateway) { $Sample.Gateway } else { '--' }
    $routeLines += ("网关  $gw   探针年龄 " + $Sample.ProbeAgeMs + ' ms')
    $lblProxy.Text = (Get-ProxyText $Sample) + "`r`n" + ($routeLines -join "`r`n")

    # ---- 断线记录 ----
    if ($Sample.OutageCount -eq 0) {
        $lblOutage.Text = '本次运行无断线'
        $lblOutage.ForeColor = $C.Good
    } else {
        $lastN = @($Sample.Outages | Select-Object -Last 3)
        $lines = foreach ($o in $lastN) {
            $dur = if ($o.End) { '{0:N1}s' -f $o.Seconds } else { '进行中' }
            '{0:HH:mm:ss} 断 {1}' -f $o.Start, $dur
        }
        $lblOutage.Text = ("累计 {0} 次：" -f $Sample.OutageCount) + (($lines -join '   '))
        $lblOutage.ForeColor = if ($Sample.IsDown) { $C.Crit } else { $C.Warn }
    }
}

function Resize-Layout {
    [int]$h = 220
    if ($Layout -eq 'compact') { [int]$h = 152 }
    if ($panelDetail.Visible) { [int]$h = $h + [int]$panelDetail.Height }
    $form.Height = [int]$h
    $chart.Visible = ($Layout -ne 'compact')
    if ($Layout -eq 'compact') {
        $lblDown.Location = New-Object System.Drawing.Point(10, 32)
        $lblUp.Location = New-Object System.Drawing.Point(10, 64)
    } else {
        $lblDown.Location = New-Object System.Drawing.Point(10, 32)
        $lblUp.Location = New-Object System.Drawing.Point(10, 64)
    }
    if ($panelDetail.Visible) {
        $panelDetail.Location = New-Object System.Drawing.Point(0, ([int]$h - [int]$panelDetail.Height))
        $panelDetail.Width = $form.Width
    }
}
#endregion

#region ---------- 定时器 ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:Paused) { return }
    try {
        $s = Update-NetPulse -State $script:State
        $script:LastSample = $s

        # 记录用于导出
        [void]$script:SamplesLog.Add([pscustomobject]@{
            Time = $s.At.ToString('yyyy-MM-dd HH:mm:ss')
            DownMbps = [math]::Round($s.Throughput.PhysDown * 8 / 1MB, 3)
            UpMbps = [math]::Round($s.Throughput.PhysUp * 8 / 1MB, 3)
            RttMs = $s.Stats.RttNow
            JitterMs = $s.Stats.Jitter
            LossPct = $s.Stats.LossPct
            RetransPct = $s.Stats.Retrans
            Health = $s.Health
            IsDown = $s.IsDown
            ProxyMode = $s.Proxy.Mode
            ViaTunnel = $s.Proxy.HasTunnel
            ActiveIface = if ($s.ActiveIface) { $s.ActiveIface.Name } else { '' }
        })
        if ($script:SamplesLog.Count -gt 86400) { $script:SamplesLog.RemoveAt(0) }

        Update-Ui -Sample $s
        Update-Chart -Sample $s
        $form.Invalidate()
    }
    catch {
        $lblMode.Text = '采集异常'
        $lblWhy.Text = $_.Exception.Message
        $lblWhy.ForeColor = $C.Bad
    }
})

# 断线闪烁（不复位采样，只切颜色）
$flash = New-Object System.Windows.Forms.Timer
$flash.Interval = 500
$flash.Add_Tick({
    if ($script:State.IsDown) {
        $script:FlashOn = -not $script:FlashOn
        $bar.BackColor = if ($script:FlashOn) { $C.Crit } else { $C.Panel }
        $form.Invalidate()
    } elseif ($script:FlashOn) {
        $script:FlashOn = $false
        $bar.BackColor = $C.Panel
        $form.Invalidate()
    }
})
#endregion

#region ---------- 交互 ----------
$toggleDetail = {
    $panelDetail.Visible = -not $panelDetail.Visible
    $miDetail.Checked = $panelDetail.Visible
    Resize-Layout
}
$miDetail.Add_Click($toggleDetail)
$lblHealth.Add_DoubleClick($toggleDetail)
$bar.Add_DoubleClick($toggleDetail)
$lblDown.Add_DoubleClick($toggleDetail)

$btnMin.Add_Click({
    $panelDetail.Visible = -not $panelDetail.Visible
    $miDetail.Checked = $panelDetail.Visible
    Resize-Layout
})

$miPause.Add_Click({ $script:Paused = $miPause.Checked })
$miTop.Add_Click({ $form.TopMost = $miTop.Checked })

$miCompact.Add_Click({
    $script:Layout = if ($miCompact.Checked) { 'compact' } else { 'normal' }
    $chart.Visible = ($script:Layout -ne 'compact')
    Resize-Layout
})

$miReset.Add_Click({
    $script:State = New-NetPulseState -ProbeIntervalMs 1000 -ProbeTimeoutMs 900
    $script:HistDown.Clear(); $script:HistUp.Clear(); $script:HistRtt.Clear()
    $script:SamplesLog.Clear()
    $sRtt.Points.Clear(); $sDown.Points.Clear()
    $lblOutage.Text = '已重置'
})

$miCopy.Add_Click({
    $s = $script:LastSample
    if (-not $s) { return }
    $txt = @(
        "时间      $($s.At.ToString('HH:mm:ss'))"
        "下行      $(Format-RateShort $s.Throughput.PhysDown)"
        "上行      $(Format-RateShort $s.Throughput.PhysUp)"
        "RTT       $($s.Stats.RttNow) ms  (基线最低 $($s.Stats.MinRtt)ms)"
        "抖动      $($s.Stats.Jitter) ms"
        "丢包      $($s.Stats.LossPct)%"
        "TCP重传   $($s.Stats.Retrans)%"
        "健康      $($s.Health)  $($s.HealthReasons -join '; ')"
        "代理      $(Get-ProxyText $s)"
        "网关      $($s.Gateway)"
        "出口网卡  $(if ($s.ActiveIface) { $s.ActiveIface.Name } else { '-' })"
        "断线次数  $($s.OutageCount)"
    ) -join "`r`n"
    [System.Windows.Forms.Clipboard]::SetText($txt)
    $lblMode.Text = '已复制'
})

$miExport.Add_Click({
    if ($script:SamplesLog.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('还没有采样数据。', 'NetPulse') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'CSV 文件 (*.csv)|*.csv'
    $dlg.FileName = ('netpulse-{0:yyyyMMdd-HHmmss}.csv' -f (Get-Date))
    if ($dlg.ShowDialog() -eq 'OK') {
        $script:SamplesLog | Export-Csv -Path $dlg.FileName -NoTypeInformation -Encoding UTF8
        $lblMode.Text = '已导出'
    }
})

$miQuit.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    $timer.Stop(); $flash.Stop()
    try { Stop-NetPulse -State $script:State } catch { }
})
#endregion

#region ---------- 启动 ----------
if ($SelfTest) {
    # 自检：把窗体和控件渲染成 PNG，验证布局有没有真的画出来
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    try {
        for ($i = 0; $i -lt 4; $i++) {
            $s = Update-NetPulse -State $script:State
            $script:LastSample = $s
            Update-Ui -Sample $s
            Update-Chart -Sample $s
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 1000
        }
        $panelDetail.Visible = $true
        Resize-Layout
        Update-Ui -Sample $s
        [System.Windows.Forms.Application]::DoEvents()
    } catch {
        "SELFTEST CAPTURE ERROR: $($_.Exception.Message)`r`nSTACK:`r`n$($_.ScriptStackTrace)"
    }
    [System.Windows.Forms.Application]::DoEvents()
    $outDir = Join-Path $PSScriptRoot 'selftest'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    function Save-Shot($ctl, $name) {
        $bmp = New-Object System.Drawing.Bitmap($ctl.Width, $ctl.Height)
        $ctl.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $ctl.Width, $ctl.Height)))
        $f = Join-Path $outDir $name
        $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        "saved $f"
    }
    # 先截折叠态，再展开详情截一次

    Save-Shot $form 'main.png'

    "--- 控件树 ---"
    function Walk($c, $depth) {
        $pad = ' ' * ($depth * 2)
        "$pad{0,-22} {1,-6} vis={2} ({3},{4}) {5}x{6} text='{7}'" -f $c.GetType().Name, $c.Name, $c.Visible, $c.Left, $c.Top, $c.Width, $c.Height, $c.Text
        foreach ($ch in $c.Controls) { Walk $ch ($depth + 1) }
    }
    Walk $form 0
    "--- 关键读数 ---"
    "lblDown  = '$($lblDown.Text)'  fore=$($lblDown.ForeColor)"
    "lblUp    = '$($lblUp.Text)'"
    "lblHealth= '$($lblHealth.Text)'  back=$($lblHealth.BackColor)"
    "lblRtt   = '$($lblRtt.Text)'"
    "lblMode  = '$($lblMode.Text)'"
    "chart    = points rtt=$($sRtt.Points.Count) down=$($sDown.Points.Count)"
    "form     = $($form.Width)x$($form.Height)"
    $form.Close()
    return
}

$form.Add_Shown({
    Resize-Layout
    Update-Ui -Sample $script:LastSample
    $timer.Start()
    $flash.Start()
})
#endregion

[void]$form.ShowDialog()
