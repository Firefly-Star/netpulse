<#
    NetPulse 启动器（带 UAC 提权）
    ================================
    为什么需要管理员：
      - WiFi 信号强度 / 频段 / 协商速率（WlanQueryInterface 非提权下 error 5）
      - 每网卡错误与丢弃计数（GetIfEntry 非提权下恒为 0）
      - ARP 全表 + 出站连接归属到进程（owningPid 非提权下全是 0）

    提权方式：检测到非管理员时，用 Start-Process -Verb RunAs 重启自己。
    用户拒绝 UAC 时降级运行 —— 界面照常工作，只是那三块数据不显示。
#>

param(
    [switch]$Elevated,
    [switch]$NoTopMost,
    [switch]$Expanded,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Test-Admin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

# ---- 提权：非管理员且未标记过，就重启自己 ----
if (-not $Elevated -and -not $SelfTest -and -not (Test-Admin)) {
    $ui = Join-Path $here 'NetPulse.UI.ps1'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ui`"")
    if ($NoTopMost) { $argList += '-NoTopMost' }
    if ($Expanded)  { $argList += '-Expanded' }
    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs | Out-Null
        exit 0
    } catch {
        # 用户拒绝了 UAC —— 降级继续，不弹错误框打断体验
        Write-Verbose "提权被拒，以降级模式启动：$($_.Exception.Message)"
    }
}

# 只转发 UI 认识的参数。@PSBoundParameters 会把 -Elevated 也带进去，
# 而 NetPulse.UI.ps1 没有这个参数，会直接报参数绑定失败、窗口根本起不来。
$forward = @{}
if ($NoTopMost) { $forward['NoTopMost'] = $true }
if ($Expanded)  { $forward['Expanded']  = $true }
if ($SelfTest)  { $forward['SelfTest']  = $true }

& (Join-Path $here 'NetPulse.UI.ps1') @forward
