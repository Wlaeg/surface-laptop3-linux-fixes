# Surface Laptop 3 (Ice Lake) Linux 修复方案

解决 Microsoft Surface Laptop 3（Intel Ice Lake 版）在 Linux 下的两个经典问题：

1. **CPU 随机被锁在 200MHz**，系统卡到几乎无法操作
2. **满载温度冲到 100°C**，持续降频

两个问题**相互独立**，需要分别修复。本仓库提供经过实测验证的脚本和 systemd 服务。

---

## 适用机型

| 项目 | 要求 |
|---|---|
| 机型 | **Surface Laptop 3**（13.5"，Intel 版） |
| CPU | Intel Ice Lake，如 **i5-1035G7** / i7-1065G7 |
| 系统 | Linux（已在 **Manjaro + linux-surface 内核 6.19.8** 实测） |
| 其他 | 需要 root（写 MSR 寄存器）；Secure Boot 需**关闭** |

> 理论上 Ice Lake 平台的其他 Surface（Pro 7 等）也可能适用，但**未经验证**。
> 其他平台的 BD PROCHOT 行为可能不同，请先确认症状一致再使用。

---

## 问题一：CPU 随机锁 200MHz

### 症状

- CPU 突然被钉在 **200MHz**（偶尔 400~770MHz），系统卡死般缓慢
- 持续约 1 分钟后**自行恢复**，或需重启
- 发作毫无规律，故称"随机"
- **机器摸起来不烫**，温度只有 50~70°C

### 根因：BD PROCHOT 被 EC 持续误报

`MSR 0x1FC`（`MSR_POWER_CTL`）的 **bit 0** 是 **BD PROCHOT 使能位**：

- `bit0 = 1` → CPU **听从**外部芯片（VRM / EC / 温度传感器）发来的降频信号
- `bit0 = 0` → CPU **忽略**这些外部信号

本机出厂即为 `1`。而嵌入式控制器（EC）**每隔约 200ms 就断言一次 PROCHOT**，
CPU 收到后就把自己钉在最低频率。

**关键：这与温度无关。** 现场取证数据：

| 指标 | 锁频时的实测值 | 说明 |
|---|---|---|
| CPU 封装温度 | **56 ~ 77 °C** | 远低于 100°C 阈值 ⇒ 不是过热 |
| `MSR 0x601` (PL4) | `0x3a8` = **117W** 正常 | 排除 PL4 |
| `MSR 0x19C` bit2 | **1** | EC 的 PROCHOT 信号**正在断言** |
| `MSR 0x19C` bit4 | **0** | 未达临界温度 |
| 全核频率 | **200MHz** | 被钉死 |

定量测量 EC 断言频率（用 `0x19C` 的粘性 bit3，写 1 可清除）：

```
清除后变回 1 的延迟（10 轮实测）：
  202ms 194ms 198ms 257ms 179ms 223ms 209ms 214ms 156ms 227ms
1 秒窗口内出现断言：20/20 = 100%
```

⇒ **EC 每约 200ms 断言一次，从不停止。** 这是**持续存在的错误信号**，
不是偶发故障。之所以表现为"随机锁频"，是因为 CPU 只在信号与内部状态叠加
（如正好请求高频）时才真正降频。

### 修复

清除 `0x1FC` 的 bit 0：

```bash
sudo modprobe msr
sudo wrmsr -a 0x1FC 0x24005e     # 末位变偶数(e)即成功
```

EC **不会**把它改回（实测连续 10 秒稳定保持），所以单次写入即可。

**日常自查就这一条命令**：

```bash
sudo rdmsr -a 0x1FC
```

- 末位是**偶数**（`e`）＝ 已禁用 ＝ 正常
- 末位是**奇数**（`f`）＝ 保护又回来了，需重跑修复

### 关于"真根治"

EC 误报的根源在固件层。软件层能做的是**屏蔽**该信号，这已是当前最优解。
理论上更新 BIOS 可能让 EC 停止误报，但 Surface 固件更新通常需要 Windows 环境。

---

## 问题二：满载过热 / 降频

### 根因：PL1 被固件设成 25W，而 TDP 只有 15W

| PL1 设置 | 满载温度 | 结果 |
|---|---|---|
| **25W**（固件默认） | **100°C** | 顶到温度墙，持续降频 |
| 15W | 77 ~ 82°C | 偏高 |
| **12.5W** | **70 ~ 74°C** | 3 分钟满载 0 次锁频 ✓ |

### 修复：按电源预设分档限制 PL1

| ppd 预设（GNOME 电源模式） | PL1 |
|---|---|
| 性能 performance | 15 W |
| 平衡 balanced | 13 W |
| 省电 power-saver | 8 W |

> **⚠️ 关键坑**：必须**同时写两个 RAPL 域**，固件实际使用的是 MMIO 域，
> 只改 MSR 域**不生效**：
> ```
> /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw       (MSR)
> /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw  (MMIO，固件用这个)
> ```

> **注意**：ppd 的三个预设**原本只切换 `platform_profile`，完全不碰功率限制**，
> 所以三个模式在功耗上本来毫无区别。本方案额外做了联动。

---

## 安装

```bash
git clone https://github.com/<你的用户名>/surface-laptop3-linux-fixes.git
cd surface-laptop3-linux-fixes
sudo ./install.sh
```

`install.sh` 会：

1. 检查环境（机型、CPU、lockdown 状态、msr 模块）
2. 安装脚本到 `/usr/local/bin/`
3. 安装 systemd 单元并**询问**是否启用
4. 立即应用一次修复并显示结果

**安装前请先读一遍 `install.sh`** —— 它会修改 systemd 配置。

### 手动安装

参照 `docs/INSTALL.md`，逐项手动执行。

---

## 安装了什么

| 路径 | 作用 |
|---|---|
| `/usr/local/bin/disable-bd-prochot.sh` | 清除 `0x1FC` bit0，**带写入校验** |
| `/usr/local/bin/surface-pl1-limit.sh` | 按 ppd 预设设置 PL1 |
| `/usr/local/bin/surface-pl1-watch.py` | 监听 ppd 的 D-Bus，切换预设时**立即**联动 |
| `/usr/local/bin/surface-throttle-monitor.sh` | 锁频取证监控 |
| `/etc/modules-load.d/msr.conf` | 开机加载 `msr` 模块 |

| systemd 单元 | 触发时机 |
|---|---|
| `surface-bd-prochot.service` | 开机 |
| `surface-bd-prochot-resume.service` | suspend / hibernate / hybrid-sleep / suspend-then-hibernate |
| `surface-pl1-watch.service` | 开机常驻 |
| `surface-pl1-limit.service` + `.timer` | 开机 + 每 3 分钟兜底 |
| `surface-throttle-monitor.service` | 开机常驻 |

---

## 验证

```bash
sudo ./scripts/check-health.sh
```

逐项检查 BD PROCHOT、PL1 双域、服务状态、依赖环、温度频率、电池、锁频统计。
**只读操作，不修改系统。**

---

## 排查记录：三个走过的弯路

公开发布这些是为了让其他人少走同样的路：

### ❌ 误判为"热保护"

最初以为锁频是固件在 80°C 触发的保守热保护。**错误** ——
实测锁频时温度仅 55~68°C **且在下降**，热保护不可能是这种表现。

### ❌ 误判为 PL4 被写坏

据 [linux-surface#706](https://github.com/linux-surface/linux-surface/issues/706)
推断 `MSR 0x601` (PL4) 被写坏，还装了修复服务。**已被现场取证推翻**：
锁频全程 PL4 = `0x3a8`(117W) 正常，毫无变化。

> `wrmsr 0x601` 方案在部分 Surface 机型（如 SP7）上确实有效，
> **但在 SL3 Ice Lake 上不是本问题的根因**。

### ❌ 误判为"电池老化导致"

拔电对照实验**否定**了这个假设：电池模式下 EC 断言率同样 100%，却不易锁频；
插电模式 18 秒就触发。说明触发条件与供电模式有关，但不只是"电池老化"。

### ⚠️ 坑：systemd 依赖环导致服务静默失效

`surface-pl1-watch.service` 若写 `After=` + `Wants=power-profiles-daemon.service`，
而 ppd 自身有 `After=multi-user.target`，会形成环：

```
multi-user.target → power-profiles-daemon → surface-pl1-watch → multi-user.target
```

systemd 为打破环会**直接丢弃该服务**，导致**重启后根本不启动**，
日志里只有一行 `Found ordering cycle ... Job deleted`，极易漏看。

**修法**：这类"客户端"服务不要声明对 ppd 的依赖，脚本自己重试连接即可。

### ⚠️ 坑：锁频判据不能只看平均频率

监控最初用「平均频率 < 600MHz」判定锁频，会**误报**：
CPU 空闲时个别核心会深度休眠到 400MHz，把平均值拉低，但其余核在 2~3GHz。

正确判据是「**低于 500MHz 的核数 ≥ 6/8**」：

```
真锁频:   201 200 200 200 201 200 200 200      → 8/8 低于阈值 ✓
空闲误报: 1572 3300 3096 2499 3429 400 400 3272 → 仅 2/8 ✗
```

### ⚠️ 安全警告：不要做满载压测

开发过程中跑 8 线程满载压测时，机器**硬复位回到 BIOS 界面**。
想验证修复，用下面 18 秒的快速诱发法，安全得多。

---

## 可复现的快速诱发法（验证修复是否生效）

想确认"屏蔽是否确实必要 / 修复是否还在起作用"，18 秒就能测：

```bash
# 1. 临时启用 BD PROCHOT（bit0 = 1）
sudo wrmsr -a 0x1FC 0x24005f

# 2. 观察约 20 秒，若全核掉到 200MHz，说明 EC 仍在误报、屏蔽确实必要
grep MHz /proc/cpuinfo

# 3. ★ 务必恢复 ★
sudo wrmsr -a 0x1FC 0x24005e
```

**风险**：过程中 CPU 会短暂被锁在 200MHz（约 1 分钟自行恢复，或立即手动恢复）。
**不要在锁频状态下关机或做重要操作。**

---

## 回滚

```bash
sudo ./uninstall.sh          # 或手动：
sudo wrmsr -a 0x1FC 0x24005f # 恢复 BD PROCHOT 保护
sudo systemctl disable --now surface-bd-prochot.service surface-bd-prochot-resume.service
sudo systemctl disable --now surface-pl1-watch.service surface-pl1-limit.timer
sudo systemctl disable --now surface-throttle-monitor.service
```

---

## 风险提示

1. **禁用 BD PROCHOT 会移除一层硬件降频保护。** 若外部信号是**真实**的
   过热/供电告警，CPU 将不再因此降频。本方案用 PL1 限制 + 取证监控作为缓解。
2. **写 MSR 需要 Secure Boot 关闭且内核 lockdown 为 `[none]`。**
   检查：`cat /sys/kernel/security/lockdown` 应显示 `[none]`。
3. **本仓库的方案是在特定机器上实测得出的。** 不同 BIOS 版本、不同批次
   可能行为不同。请先跑 `check-health.sh` 确认症状一致。
4. **不做任何担保。** 按 MIT 协议使用，风险自负。

---

## 相关资源

- [linux-surface 项目](https://github.com/linux-surface/linux-surface) —— Surface 上的 Linux 支持
- [linux-surface#706](https://github.com/linux-surface/linux-surface/issues/706) —— 相关锁频讨论
- [linux-surface#1917](https://github.com/linux-surface/linux-surface/issues/1917) —— SL3 的 PL1 问题
- [Disable-BD-PROCHOT-on-LINUX](https://github.com/fralapo/Disable-BD-PROCHOT-on-LINUX) —— BD PROCHOT 屏蔽思路来源

---

## License

MIT
