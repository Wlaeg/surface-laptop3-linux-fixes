# Troubleshooting / 故障排查

[English](#english) | [中文](#中文)

---

## English

### Quick self-check

```bash
sudo ./scripts/check-health.sh
```

### "The CPU is stuck at 200 MHz again"

```bash
# 1. Confirm — last digit must be EVEN
sudo rdmsr -a 0x1FC

# 2. If it is odd, re-apply
sudo wrmsr -a 0x1FC 0x24005e
sudo systemctl restart surface-bd-prochot.service

# 3. Inspect what the monitor captured
sudo tail -80 /var/log/surface-throttle.log
```

### "check-health reports lock-up events"

**Check the timestamps first.** The log is append-only and keeps historical events
from before the fix was installed — those are expected and not current problems.
`check-health.sh` already distinguishes them, but the monitor's own summary does not.

**Also verify the criterion.** When idle, individual cores deep-sleep to 400 MHz, so
*average* frequency can look low while the CPU is perfectly healthy. A real lock-up
pins **all** cores:

```
real lock-up:  ALL cores at 200–400 MHz
idle (normal): a few cores at 400 MHz, the rest at 2–3 GHz
```

### "surface-pl1-watch.service is not running after reboot"

Almost certainly a **systemd ordering cycle**. The unit must **not** declare
`After=` or `Wants=` on `power-profiles-daemon.service` — ppd itself has
`After=multi-user.target`, which forms a cycle and makes systemd drop the unit.

```bash
# Confirm
journalctl -b | grep 'ordering cycle'
systemctl show surface-pl1-watch.service -p After

# The After= list must NOT contain power-profiles-daemon.service
```

### "Switching power mode does not change PL1"

Check, in order:

1. `surface-pl1-watch.service` active? (`systemctl is-active`)
2. `python3 -c 'import dbus, gi'` works?
3. ppd reachable? `busctl get-property net.hadess.PowerProfiles \
   /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile`

The 3-minute `surface-pl1-limit.timer` is a safety net, but it means up to a 3-minute
delay if the watcher is down.

### "PL1 keeps reverting"

Some firmware re-applies its own limits. The `.timer` corrects this within 3 minutes.
If you need it faster, lower `OnUnitActiveSec` in `surface-pl1-limit.timer`.

### "wrmsr: Operation not permitted"

Kernel lockdown is blocking it:

```bash
cat /sys/kernel/security/lockdown
# [none] integrity confidentiality  → OK
# none [integrity] confidentiality  → BLOCKED
```

Disable Secure Boot in the firmware, or use `mokutil --disable-validation`.

### "rdmsr: No such file or directory" / "/dev/cpu/0/msr missing"

The `msr` module is unavailable. Check whether your kernel has `CONFIG_X86_MSR`:

```bash
sudo modprobe msr
ls /dev/cpu/0/msr
```

Some minimal kernels omit it; you would need a different kernel.

### "Temperatures are still high"

1. Confirm PL1 is actually applied **in both domains** (a mismatch means the MMIO
   domain — the one the firmware uses — was not set).
2. Lower the limits in `/usr/local/bin/surface-pl1-limit.sh`.
3. This machine has **no fan speed interface** on Linux (the fan is controlled by
   firmware), so you cannot observe or control it directly. It does have a fan —
   do not conclude otherwise.

### "No fan is detected at all"

Expected. Linux does not expose the Surface fan through standard `hwmon`. The fan
still works; it is managed by firmware.

### Reading the forensic monitor log

Each captured event contains:

- All key MSRs (`0x601` PL4, `0x19C`/`0x1B1` thermal, `0x1FC` BD PROCHOT,
  `0x198`/`0x199` perf, `0x770`–`0x777` HWP, …)
- PROCHOT flag decode (bits 0/2/3/4, 10/12/14)
- Per-core frequency, all thermal zones
- Power source, ppd profile, PL1/PL4

**Key diagnostic:** if `PROCHOT Event(bit2) = 1` while temperatures are low, the
external signal is spurious — exactly the case this project fixes.

> The log may contain **timestamps in two time zones** (`13:xx` and `20:xx` mixed).
> That is a clock jump during boot, not a malfunction.

---

## 中文

### 快速自检

```bash
sudo ./scripts/check-health.sh
```

### “CPU 又被锁在 200MHz 了”

```bash
# 1. 确认 —— 末位必须是【偶数】
sudo rdmsr -a 0x1FC

# 2. 若是奇数，重新应用
sudo wrmsr -a 0x1FC 0x24005e
sudo systemctl restart surface-bd-prochot.service

# 3. 查看监控抓到的现场
sudo tail -80 /var/log/surface-throttle.log
```

### “check-health 报告有锁频事件”

**先看时间戳。** 日志是只追加的，会保留修复安装前的历史事件 —— 那些属预期，
不是当前问题。`check-health.sh` 已会区分，但监控自身的摘要不会。

**同时要核对判据。** CPU 空闲时个别核心会深度休眠到 400MHz，
所以**平均**频率可能看起来很低，而 CPU 实际完全健康。真锁频会钉住**全部**核心：

```
真锁频:  全部核心都在 200~400MHz
空闲正常: 少数核心 400MHz，其余 2~3GHz
```

### “重启后 surface-pl1-watch.service 没在跑”

几乎肯定是 **systemd 依赖环**。该单元**不能**声明对
`power-profiles-daemon.service` 的 `After=` 或 `Wants=` —— ppd 自身有
`After=multi-user.target`，会形成环，导致 systemd 丢弃该单元。

```bash
# 确认
journalctl -b | grep 'ordering cycle'
systemctl show surface-pl1-watch.service -p After

# After= 列表中【不应】包含 power-profiles-daemon.service
```

### “切换电源模式后 PL1 没变”

依次检查：

1. `surface-pl1-watch.service` 是否 active？（`systemctl is-active`）
2. `python3 -c 'import dbus, gi'` 是否可用？
3. ppd 是否可达？`busctl get-property net.hadess.PowerProfiles \
   /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile`

3 分钟的 `surface-pl1-limit.timer` 是兜底，但若监听进程挂了，最多会有 3 分钟延迟。

### “PL1 老是变回去”

某些固件会重新应用自己的限制。`.timer` 会在 3 分钟内纠正。
若要更快，可改小 `surface-pl1-limit.timer` 里的 `OnUnitActiveSec`。

### “wrmsr: Operation not permitted”

内核 lockdown 拦截了：

```bash
cat /sys/kernel/security/lockdown
# [none] integrity confidentiality  → 正常
# none [integrity] confidentiality  → 被拦截
```

在固件里关闭 Secure Boot，或使用 `mokutil --disable-validation`。

### “rdmsr: No such file or directory” / 找不到 /dev/cpu/0/msr

`msr` 模块不可用。确认内核是否编译了 `CONFIG_X86_MSR`：

```bash
sudo modprobe msr
ls /dev/cpu/0/msr
```

部分精简内核未包含该模块，需要更换内核。

### “温度还是很高”

1. 确认 PL1 **两个域**都真的写进去了（不一致说明固件实际使用的 MMIO 域没设置）。
2. 调低 `/usr/local/bin/surface-pl1-limit.sh` 里的限制值。
3. 本机在 Linux 下**没有风扇转速接口**（风扇由固件控制），无法直接观测或控制。
   但**它是有风扇的**，不要得出相反结论。

### “完全检测不到风扇”

这是正常的。Linux 不通过标准 `hwmon` 暴露 Surface 风扇。风扇仍在工作，由固件管理。

### 如何阅读取证监控日志

每个事件记录包含：

- 全部关键 MSR（`0x601` PL4、`0x19C`/`0x1B1` 热状态、`0x1FC` BD PROCHOT、
  `0x198`/`0x199` 性能状态、`0x770`–`0x777` HWP 等）
- PROCHOT 标志位解析（bit 0/2/3/4、10/12/14）
- 各核频率、全部温区
- 供电状态、ppd 预设、PL1/PL4

**关键判据**：若 `PROCHOT Event(bit2) = 1` 而温度不高，说明外部信号是误报 ——
这正是本项目所修复的情形。

> 日志里可能有**两种时区的时间戳**（`13:xx` 与 `20:xx` 混排）。
> 那是开机时的时钟跳变，不是故障。
