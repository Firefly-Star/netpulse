# NetPulse — 不占带宽的网络状态实时监控

针对**国内校园网 / 手机热点 + VPN（TUN 虚拟网卡）/ 系统代理** 这类环境做的实时网络体检工具。
Windows 10/11，PowerShell 5.1+，**启动时会弹一次 UAC**（拒绝也能用）。

---

## 怎么启动

### 方式一：双击（推荐）

双击 **`NetPulse.cmd`**。

会弹一次 UAC 授权框 → 点「是」→ 右下角出现悬浮窗。
如果点「否」，程序照常启动，只是少了下面这三项提权数据。

### 方式二：命令行

```powershell
# 正常启动（会弹 UAC）
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-NetPulse.ps1

# 不提权，跳过 UAC（少 WiFi 信号 / 连接归属 / 网卡错误计数）
powershell -NoProfile -ExecutionPolicy Bypass -File .\NetPulse.UI.ps1

# 直接在展开态启动
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-NetPulse.ps1 -Expanded

# 不要置顶
powershell -NoProfile -ExecutionPolicy Bypass -File .\Start-NetPulse.ps1 -NoTopMost
```

### 方式三：只跑采集、不弹窗（排查用）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Test-Core.ps1 -Seconds 20
```

---

## 窗口怎么用

| 操作 | 效果 |
|---|---|
| **拖动** | 按住任意空白处拖动窗口 |
| **双击** | 展开 / 收起详细面板 |
| **右键** | 展开详情 / 暂停采样 / 置顶开关 / 退出 |

收起态 316×233，展开约 316×880（提权数据齐全时）。

---

## 界面上的三块区域

**① 顶部**：下行 / 上行速率，健康度状态灯（正常绿 / 有负载琥珀 / 拥塞橙 / 丢包红 / 断线红）。
外壳的渐变描边、背景光晕、折线颜色都跟着健康度换色相。

**② 折线图**：实线是吞吐，虚线是 RTT（展开态才有）。上限取 P90 而非最大值，避免单次突发把整条曲线压平。

**③ 展开后的六个分区**

| 分区 | 内容 |
|---|---|
| 探针分层 | 网关(ARP) → 本地DNS(UDP) → 公网DNS(UDP) → 两个国内目标(TCP)，逐层定位断在哪一段 |
| 链路质量 | 抖动 / 丢包 / TCP 重传率 / RTT 基线 |
| 各网卡速率 | 物理网卡、隧道（Wintun/Tailscale）、虚拟网卡分开统计 |
| 无线信号 | SSID、信号强度、RSSI、频段、协商速率　*（需提权）* |
| 出口判定 | 本机 → 网关 → 出口网卡 → 公网，标出全局 / 规则 / 直连 |
| 连接归属 | 哪个进程占了多少条连接　*（需提权）* |

---

## 为什么它几乎不占带宽

三种探针混用，按成本从低到高：

| 探针 | 单次开销 | 用途 |
|---|---|---|
| **ARP**（网关） | ≈ 0 字节，二层帧，不出本链路 | 最快的"局域网还在不在"信号 |
| **UDP DNS**（本地 + 公网各一） | 约 100 字节 | 自封包，绕过系统解析缓存 |
| **TCP SYN**（2 个国内目标） | 约 3 个包，不握手完、不发载荷 | 真实公网往返 |

1 Hz 全量监测合计约 **0.5~1 KB/s**，比看一张网页图片少一个数量级。
ARP 探针完全不产生网络流量。带宽测试是手动触发的一次性动作，默认不跑。

---

## 为什么不用 ping

这是在你机器上实测的，不是猜的：

```
ICMP (System.Net.NetworkInformation.Ping) → 所有目标全部异常，包括网关
TCP 223.5.5.5:443     → 50 ms   ✓
TCP 119.29.29.29:443  → 超时
TCP 1.1.1.1 / 8.8.8.8 → 一直挂在 SYN_SENT
```

所以：**不用 ICMP**；公网目标池启动时并行竞速，只保留当前真正连得上的（每 5 分钟复检一次），
通了国际就多测一条国际线，不通就不占预算。换网、换代理模式后能自动跟上。

---

## 提权拿到的三样东西

非管理员时这些字段恒为 0 或直接报 error 5，所以做成可降级：

1. **无线信号**：`netsh wlan show interfaces` → SSID / 信号% / RSSI / 频段 / 信道 / 协商速率
2. **连接归属**：`GetExtendedTcpTable` → 每条 ESTABLISHED 连接归属到 PID → 按进程聚合
3. **网卡错误与丢弃计数**：`GetIfEntry` → 每网卡的 in/out errors 和 discards

拒绝 UAC 时，这三块 `Available=false`，界面上直接不显示，不会报错。

---

## 文件说明

| 文件 | 作用 |
|---|---|
| `NetPulse.cmd` | **双击这个启动** |
| `Launch.vbs` | 隐藏窗口拉起 PowerShell（避免黑框） |
| `Start-NetPulse.ps1` | 启动器：检测权限、必要时 UAC 重启自己 |
| `NetPulse.UI.ps1` | WPF 界面（玻璃拟态、渐变描边、光晕） |
| `NetPulse.Core.ps1` | 采集引擎：网卡/路由/代理/探针/健康度判定 |
| `NetPulse.Elevated.ps1` | 提权专属采集，含安全降级 |
| `Test-Core.ps1` | 无窗口自测，打印采样明细 |
| `Test-Elevated.ps1` | 检查提权数据能不能拿到 |
| `proto/` | 界面原型（HTML + 截图） |

---

## 已知限制

- **没有 WiFi 信号强度**：非提权下 `netsh wlan show interfaces` 返回 error 5。要看得提权。
- **带宽上限不自动测**：链路协商速率（比如 72 Mbps）不等于实际可用带宽。
- **不做 HTTP 层探测**：只到传输层，判断不了"能连上但返回 502"这类应用层故障。
- **探针超时 900ms**：网络极慢时延迟数字有 1 秒量级的分辨率误差。
- **连接归属只给连接数**：真实流量需要 ETW，代价太大没做。

---

## 踩过的坑（给后来改代码的人）

1. **`MIB_IF_ROW2` 结构体在 `Add-Type` 下算错**
   `Marshal.SizeOf` 返回 1296，真实是 1352（257 字符的 inline 字符串字段被当成引用）。
   结果行偏移全错，读出 1.7e18 量级垃圾值。改用老的 `GetIfEntry(MIB_IFROW, 856B)`。

2. **netsh 输出编码前后不一致**
   管道捕获是 GBK，`-RedirectStandardOutput` 重定向到文件是 UTF-8，
   切 `chcp 65001` 又会变成英文输出导致中文字段直接消失。
   正解：读原始字节后自动探测哪套编码能解出「信号」。

3. **PowerShell 脚本必须存成带 BOM 的 UTF-8**
   否则 Windows PowerShell 5.1 按 ANSI 解析，中文全变乱码、直接语法错误。

4. **`GridLength` 别用绝对值**
   `GridLength(1)` 是 1 像素，不是 1 份。要 `GridLength(1, 'Star')`。

5. **VBS 文件保持纯 ASCII**
   VBScript 按系统 ANSI 代码页读文件，UTF-8 中文注释会变乱码并破坏语法。
