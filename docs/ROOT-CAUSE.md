# Root Cause Analysis / 根因分析

[English](#english) | [中文](#中文)

---

## English

This document records the measurements behind the fixes, including the dead ends.
Methodology was on-site forensics: capture MSR and sysfs state *during* a lock-up,
rather than reproducing it afterwards.

### Test platform

| Item | Value |
|---|---|
| Device | Microsoft Surface Laptop 3 (13.5", Intel) |
| CPU | Intel Core i5-1035G7 (Ice Lake, 4C/8T, **TDP 15 W**, 3.7 GHz turbo) |
| RAM / Disk | 7.4 GiB / WD PC SN520 256 GB NVMe |
| OS | Manjaro Linux, kernel `6.19.8-arch1-3-surface` (linux-surface) |
| Microcode | `0xce` |
| Secure Boot | Disabled; kernel lockdown `[none]` |
| Battery | SMP M1087272, health ~80.5 %, ~490 cycles |

### Problem 1 — random 200 MHz lock

#### Hypothesis A: thermal protection ❌

First guess: conservative firmware throttling around 80 °C.

**Refuted.** During lock-ups the package temperature measured **56–68 °C and falling**.
Thermal protection cannot engage below its threshold, and certainly not while cooling.

#### Hypothesis B: corrupted PL4 (`MSR 0x601`) ❌

[linux-surface#706](https://github.com/linux-surface/linux-surface/issues/706) documents
the firmware writing a bad PL4 value after low-battery resume, pinning the CPU low. A
fix service was built for it.

**Refuted.**
- PL4 read `0x3a8` (117 W) **throughout** every captured lock-up — never changed.
- Directly setting PL4 to `0x78` (15 W) *did* reproduce low frequency (2200 → 475 MHz),
  confirming PL4 *can* limit frequency — but it is **not what happens** in the real fault.

> The PL4 fix does work on other Surface models (SP7, SLG3). On SL3 Ice Lake the real
> cause is elsewhere.

#### Hypothesis C: aging battery ❌

The battery is at ~80.5 % health / 490 cycles, and upstream docs name "dying battery"
as a typical trigger.

**Refuted by a controlled comparison.** Temporarily re-enabling BD PROCHOT:

| Power source | Lock-up within 60 s | EC assertion rate |
|---|---|---|
| AC connected | **yes, at 18 s** | 100 % |
| On battery | no | 100 % |

Both sources show a 100 % assertion rate, yet only AC reliably triggers a lock-up.
So the source of the signal is not simply battery wear.

#### Root cause: BD PROCHOT asserted continuously by the EC ✅

`MSR 0x1FC` (`MSR_POWER_CTL`) bit 0 enables BD PROCHOT — whether the CPU obeys external
throttle requests. The machine ships with `0x24005f` (bit0 = 1).

**Forensic capture during a real lock-up:**

```
PL4            0x601 = 0x3a8        (117 W — normal)
THERM_STATUS   0x19C = 0x8823080c   bit2 PROCHOT Event = 1
                                    bit3 PROCHOT Log   = 1
                                    bit4 CritTemp      = 0
POWER_CTL      0x1FC = 0x24005f     BD PROCHOT enabled
Temperature           ~65 °C
All-core frequency    200 MHz
```

**The EC asserts PROCHOT roughly every 200 ms, indefinitely.** Measured by clearing the
sticky bit3 of `0x19C` and timing its re-assertion:

```
202 194 198 257 179 223 209 214 156 227   (ms)
20/20 one-second windows contained an assertion
```

This explains every apparent contradiction:

- **Why it looks random:** the signal is always present, but the CPU only throttles when
  it coincides with an internal high-frequency request.
- **Why it is not thermal:** the throttle request comes from *outside* the CPU.
- **Why it self-recovers:** the assertion eventually de-asserts on its own.

#### Fix

Clear bit 0: `wrmsr -a 0x1FC 0x24005e`. The EC does not revert it.

Verified by a reproducible 18-second induction: temporarily setting bit0 back to 1
reproduced the full lock-up in 18 s, and clearing it restored ~3.2 GHz within 1 s.

---

### Problem 2 — overheating under load

The second issue is the **PL1** power limit, not PL4:

```
package-0 constraint_0 (long_term): limit = 25 W
                                     max   = 15 W   ← hardware TDP ceiling
```

The firmware sets a 25 W long-term limit on a 15 W part.

| PL1 | Load temperature |
|---|---|
| 25 W (default) | **100 °C** |
| 15 W | 77–82 °C |
| 12.5 W | **70–74 °C** |

Both RAPL domains must be written — the firmware uses the **MMIO** domain:

```
/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
```

---

### Methodology notes

#### Never run sustained full-load stress tests

An 8-thread stress test caused a **hard reset to the BIOS screen**. Prefer read-only
sampling, and use the 18-second induction if you must provoke the fault.

#### Do not judge a lock-up by average frequency

When idle, individual cores deep-sleep to 400 MHz:

```
real lock-up:  201 200 200 200 201 200 200 200       → 8/8 below 500 MHz
idle:          1572 3300 3096 2499 3429 400 400 3272 → only 2/8
```

Criterion: **cores below 500 MHz ≥ 6 of 8**.

#### systemd ordering cycles fail silently

`After=`/`Wants=` on a unit that transitively depends on `multi-user.target` (like ppd)
creates a cycle; systemd drops the unit rather than warning loudly. Always verify with:

```bash
journalctl -b | grep 'ordering cycle'
systemctl show <unit> -p After
```

---

## 中文

本文记录修复背后的实测数据，**包括走过的弯路**。
方法是现场取证：在锁频**发生时**抓取 MSR 与 sysfs 状态，而不是事后复现。

### 测试平台

| 项目 | 值 |
|---|---|
| 设备 | Microsoft Surface Laptop 3（13.5"，Intel 版） |
| CPU | Intel Core i5-1035G7（Ice Lake，4 核 8 线程，**TDP 15W**，睿频 3.7GHz） |
| 内存 / 硬盘 | 7.4 GiB / WD PC SN520 256GB NVMe |
| 系统 | Manjaro Linux，内核 `6.19.8-arch1-3-surface`（linux-surface） |
| 微码 | `0xce` |
| Secure Boot | 已关闭；内核 lockdown `[none]` |
| 电池 | SMP M1087272，健康度约 80.5%，约 490 次循环 |

### 问题一 —— 随机锁 200MHz

#### 假设 A：热保护 ❌

最初怀疑是固件在 80°C 附近的保守降频。

**被推翻。** 锁频期间封装温度实测 **56~68°C 且在下降**。
热保护不会在阈值以下触发，更不会在降温过程中触发。

#### 假设 B：PL4（`MSR 0x601`）被写坏 ❌

[linux-surface#706](https://github.com/linux-surface/linux-surface/issues/706) 记录了
固件在低电量恢复后写入错误 PL4 值、把 CPU 压低的现象，甚至为此写了修复服务。

**被推翻。**
- 每一次抓到的锁频中，PL4 都是 `0x3a8`（117W），**从未变化**。
- 直接把 PL4 设成 `0x78`（15W）**确实**能复现低频（2200 → 475MHz），
  说明 PL4 有能力限制频率 —— 但它**不是**真实故障的成因。

> PL4 修复在其他 Surface 机型（SP7、SLG3）上确实有效。
> 在 SL3 Ice Lake 上，真正的原因在别处。

#### 假设 C：电池老化 ❌

电池健康度约 80.5%、循环 490 次，而上游文档点名"老化电池"是典型诱因。

**被对照实验推翻。** 临时启用 BD PROCHOT 后对比：

| 供电方式 | 60 秒内是否锁频 | EC 断言率 |
|---|---|---|
| 插电 | **是，18 秒触发** | 100% |
| 电池 | 否 | 100% |

两种供电下断言率都是 100%，却只有插电容易触发锁频。
所以信号来源不能简单归因为电池老化。

#### 根因：EC 持续断言 BD PROCHOT ✅

`MSR 0x1FC`（`MSR_POWER_CTL`）的 bit 0 控制 BD PROCHOT —— 即 CPU 是否听从外部降频请求。
本机出厂值为 `0x24005f`（bit0 = 1）。

**真实锁频期间的现场取证：**

```
PL4            0x601 = 0x3a8        (117W，正常)
THERM_STATUS   0x19C = 0x8823080c   bit2 PROCHOT Event = 1
                                    bit3 PROCHOT Log   = 1
                                    bit4 CritTemp      = 0
POWER_CTL      0x1FC = 0x24005f     BD PROCHOT 处于启用状态
温度                 约 65°C
全核频率             200MHz
```

**EC 每约 200ms 断言一次 PROCHOT，从不停止。**
方法：清除 `0x19C` 的粘性 bit3，测量其重新置位的延迟：

```
202 194 198 257 179 223 209 214 156 227   (ms)
20/20 个 1 秒窗口内都出现了断言
```

这一下解释了所有看似矛盾的现象：

- **为什么像"随机"**：信号一直存在，但 CPU 只在它与内部高频请求叠加时才降频。
- **为什么与温度无关**：降频请求来自 CPU **外部**。
- **为什么能自行恢复**：断言最终会自行撤销。

#### 修复

清除 bit 0：`wrmsr -a 0x1FC 0x24005e`。EC 不会改回。

用可复现的 18 秒诱发法验证：临时把 bit0 置回 1，18 秒内完整复现锁频；
清回后 1 秒内恢复到约 3.2GHz。

---

### 问题二 —— 满载过热

第二个问题是 **PL1**：

```
package-0 constraint_0 (long_term): limit = 25 W
                                     max   = 15 W   ← 硬件 TDP 上限
```

固件给一颗 15W 的芯片设了 25W 的长时功率上限。

| PL1 | 满载温度 |
|---|---|
| 25W（默认） | **100°C** |
| 15W | 77~82°C |
| 12.5W | **70~74°C** |

必须同时写**两个** RAPL 域 —— 固件使用的是 **MMIO** 域：

```
/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
```

---

### 方法论备注

#### 不要做持续满载压测

8 线程压测曾导致**硬复位回到 BIOS 界面**。
优先用只读采样；确需诱发故障时，用 18 秒诱发法。

#### 不要用平均频率判断锁频

空闲时个别核心会深度休眠到 400MHz：

```
真锁频:   201 200 200 200 201 200 200 200      → 8/8 低于 500MHz
空闲:     1572 3300 3096 2499 3429 400 400 3272 → 仅 2/8
```

判据：**低于 500MHz 的核数 ≥ 6/8**。

#### systemd 依赖环是静默失败

对「传递依赖 `multi-user.target` 的单元」（如 ppd）声明 `After=`/`Wants=` 会成环，
systemd 会**直接丢弃该单元**而非大声报警。务必核查：

```bash
journalctl -b | grep 'ordering cycle'
systemctl show <unit> -p After
```
